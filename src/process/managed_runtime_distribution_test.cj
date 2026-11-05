package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getVariable, getVariables}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, remove}
import std.fs.copy as copyFile
import std.posix.chmod
import std.process.ProcessRedirect
import std.runtime.{getThreadCount, getBlockingThreadCount}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func distributionCheck(value: Bool): Unit {
    @Expect(value, true)
    if (!value) { throw Exception("managed_distribution_contract_failed") }
}

private func distributionText(bytes: Array<Byte>): String {
    try { String.fromUtf8(bytes) }
    catch (_: Exception) { throw Exception("managed_distribution_invalid_encoding") }
}

private func distributionReadBlock(file: File, buffer: Array<Byte>): Int64 {
    var used: Int64 = 0
    while (used < buffer.size) {
        let count = file.read(buffer[used..])
        if (count == 0) { break }
        used += count
    }
    used
}

private func distributionSameFiles(left: Path, right: Path): Bool {
    let leftBuffer = Array<Byte>(4096, repeat: 0)
    let rightBuffer = Array<Byte>(4096, repeat: 0)
    var equal = true
    try (leftFile = File(left, OpenMode.Read), rightFile = File(right, OpenMode.Read)) {
        while (equal) {
            let leftCount = distributionReadBlock(leftFile, leftBuffer)
            let rightCount = distributionReadBlock(rightFile, rightBuffer)
            if (leftCount != rightCount) { equal = false; break }
            if (leftCount == 0) { break }
            for (index in 0..leftCount) {
                if (leftBuffer[index] != rightBuffer[index]) { equal = false; break }
            }
        }
    }
    equal
}

private func distributionQuote(value: String): String { "'" + value.replace("'", "'\"'\"'") + "'" }

@When[os == "macOS"]
private func distributionGroupGone(pid: Int64): Bool {
    if (pid <= 1 || pid > 2147483647) { return false }
    unsafe { kill(-Int32(pid), Int32(0)) } != 0 && unsafe { __error().read() } == 3
}

@When[os == "macOS"]
private class DistributionFixture {
    let home = Directory.createTemp("/private/tmp")
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT") ?? "."))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let environment = HashMap<String, String>()
    let children = ArrayList<ManagedOwnedChild>()
    let initialFd = ownedTestFdCount()
    let initialTasks = getThreadCount()
    let initialBlocking = getBlockingThreadCount()
    var passed = false
    var pendingLaunch = false

    init() {
        for ((key, value) in getVariables()) {
            if (["PATH", "CANGJIE_HOME", "SDKROOT", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "LANG", "cjHeapSize"].contains(key)) {
                environment[key] = value
            }
        }
        environment["HOME"] = home.toString(); environment["TMPDIR"] = home.toString()
        File.writeTo(home.join("owner"), ("distribution-fixture-v1\n" + nonce).toArray())
        println("R-NG-DISTRIBUTION fixture=${home.fileName};nonce=${nonce}")
    }

    func directory(name: String): Path {
        let value = home.join(name)
        if (!exists(value)) { Directory.create(value, recursive: true) }
        value
    }

    func write(path: Path, bytes: Array<Byte>): Unit {
        if (!exists(path.parent)) { Directory.create(path.parent, recursive: true) }
        File.writeTo(path, bytes)
    }

    func copy(relative: String, target: Path): Unit {
        let source = project.join(relative)
        distributionCheck(FileInfo(source).isRegular() && !FileInfo(source).isSymbolicLink())
        if (!exists(target.parent)) { Directory.create(target.parent, recursive: true) }
        copyFile(source, to: target)
        distributionCheck(distributionSameFiles(source, target))
    }

    func executable(path: Path, script: String): Unit {
        write(path, script.toArray()); distributionCheck(unsafe { chmod(path.toString(), 0o755) } == 0)
    }

    func run(command: String, args: Array<String>, cwd: Path, name: String,
        variables!: ?HashMap<String, String> = None): (Int64, Array<Byte>, Array<Byte>) {
        let stdin = home.join("empty-stdin")
        write(stdin, [])
        let output = home.join("${name}.stdout"); let error = home.join("${name}.stderr")
        var code: Int64 = -1
        try (input = File(stdin, OpenMode.Read), out = File(output, OpenMode.Write), err = File(error, OpenMode.Write)) {
            pendingLaunch = true
            let child = launchManagedRawChild(command, args, workingDirectory: Some(cwd),
                environment: Some<Map<String, String>>(variables ?? environment), newGeneration: true,
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(out), stdErr: ProcessRedirect.FromFile(err))
            children.add(child); pendingLaunch = false
            distributionCheck(unsafe { getpgid(Int32(child.pid)) } == Int32(child.pid))
            code = child.wait(timeout: Some(Duration.second * 60))
            distributionCheck(code >= 0 && code <= 255 && child.wait() == code)
            child.closeStreams()
            distributionCheck(!child.isAlive() && child.streamsAreClosed() && distributionGroupGone(child.pid) && !input.isClosed() && !out.isClosed() && !err.isClosed())
        }
        distributionCheck(ownedTestFdCount() == initialFd)
        distributionCheck(getThreadCount() <= initialTasks && getBlockingThreadCount() <= initialBlocking)
        let result = JsonObject(); result.put("code", JsonInt(code)); result.put("actualWait", JsonBool(true))
        result.put("streamsClosed", JsonBool(true)); result.put("fd", JsonInt(ownedTestFdCount()))
        write(home.join("${name}.result.json"), result.toJsonString().toArray())
        (code, File.readFrom(output), File.readFrom(error))
    }

    func finish(): Unit {
        var before = !pendingLaunch
        var saved = false
        var terminal = !pendingLaunch
        var firstFailure = None<Exception>
        try {
            for (child in children) { before = before && !child.isAlive() && child.streamsAreClosed() && distributionGroupGone(child.pid) }
            let proof = JsonObject(); proof.put("formal", JsonBool(passed)); proof.put("terminalBeforeFallback", JsonBool(before))
            proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("retained", JsonBool(true))
            write(home.join("formal-before-fallback.json"), proof.toJsonString().toArray()); saved = true
        } catch (failure: Exception) { firstFailure = Some(failure) }
        finally {
            for (child in children) {
                var waited = false
                var code: Int64 = -1
                try { if (child.isAlive()) { child.terminate() } }
                catch (failure: Exception) { terminal = false; if (firstFailure.isNone()) { firstFailure = Some(failure) } }
                try { code = child.wait(timeout: Some(Duration.second * 3)); waited = true }
                catch (failure: Exception) { terminal = false; if (firstFailure.isNone()) { firstFailure = Some(failure) } }
                finally {
                    try { child.closeStreams() }
                    catch (failure: Exception) { terminal = false; if (firstFailure.isNone()) { firstFailure = Some(failure) } }
                }
                try { terminal = terminal && waited && code >= 0 && code <= 255 && !child.isAlive() && child.streamsAreClosed() && distributionGroupGone(child.pid) }
                catch (failure: Exception) { terminal = false; if (firstFailure.isNone()) { firstFailure = Some(failure) } }
            }
            try {
                let final = JsonObject(); final.put("terminal", JsonBool(terminal)); final.put("retained", JsonBool(true))
                write(home.join("cleanup.json"), final.toJsonString().toArray())
            } catch (failure: Exception) { if (firstFailure.isNone()) { firstFailure = Some(failure) } }
            @Expect(saved && before && terminal && firstFailure.isNone(), true)
        }
        // The two callers set passed only after their complete body returned normally.
        // Preserve a body exception already unwinding instead of replacing it in finally.
        if (passed) {
            if (let Some(failure) <- firstFailure) { throw failure }
            distributionCheck(saved && before && terminal)
        }
    }

    func snapshot(): Unit {
        let names = ["build.cj", "src/process/managed_exec_gate.c", "scripts/metis-stdio-broker.mjs",
            "scripts/build-static/stage-managed-runtime.sh", "scripts/build-static/build-magic-cli.sh",
            "scripts/release/gitcode_release.sh", "scripts/release/gitcode_release.py"]
        let args = ArrayList<String>(["-a", "256"])
        for (name in names) {
            let target = home.join("source-inputs").join(name)
            copy(name, target); args.add(target.toString())
        }
        distributionCheck(run("/usr/bin/shasum", args.toArray(), home, "source-sha256")[0] == 0)
    }

    func platform(): String {
        @When[arch == "aarch64"]
        let value = "macos-aarch64"
        @When[arch == "x86_64"]
        let value = "macos-x86_64"
        @When[arch != "aarch64" && arch != "x86_64"]
        let value = "unsupported"
        value
    }

    func stageInputs(root: Path): Path {
        let binary = root.join("binary"); Directory.create(binary, recursive: true)
        copy("target/release/bin/metis", binary.join("magic-cli"))
        copy("scripts/metis-stdio-broker.mjs", root.join("scripts/metis-stdio-broker.mjs"))
        copy("src/process/managed_exec_gate.c", root.join("src/process/managed_exec_gate.c"))
        copy("build.cj", root.join("build.cj"))
        let original = project.join("target/native/metis-exec-gate-v1")
        distributionCheck(FileInfo(original).lastModificationTime >= FileInfo(project.join("build.cj")).lastModificationTime &&
            FileInfo(original).lastModificationTime >= FileInfo(project.join("src/process/managed_exec_gate.c")).lastModificationTime)
        copy("target/native/metis-exec-gate-v1", root.join("target/native/metis-exec-gate-v1"))
        distributionCheck(unsafe { chmod(binary.join("magic-cli").toString(), 0o755) } == 0)
        distributionCheck(unsafe { chmod(root.join("target/native/metis-exec-gate-v1").toString(), 0o755) } == 0)
        copy("scripts/build-static/stage-managed-runtime.sh", root.join("scripts/build-static/stage-managed-runtime.sh"))
        binary
    }
}

@When[os == "macOS"]
private func distributionBuildFailure(fixture: DistributionFixture): Unit {
    let root = fixture.directory("prebuild 中文😀")
    fixture.copy("build.cj", root.join("build.cj"))
    fixture.copy("src/process/managed_exec_gate.c", root.join("src/process/managed_exec_gate.c"))
    let sdk = Path(getVariable("CANGJIE_HOME").getOrThrow())
    let compiled = fixture.run(sdk.join("bin/cjc").toString(), [root.join("build.cj").toString(), "-o", root.join("build-hook").toString()], root, "compile-build-hook")
    distributionCheck(compiled[0] == 0)
    let magic = root.join("magic")
    @When[arch == "aarch64"]
    let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1")
    @When[arch == "x86_64"]
    let stdx = magic.join("libs/cangjie-stdx-mac-x64-1.0.0.1")
    Directory.create(stdx, recursive: true)
    fixture.write(root.join("cjpm.toml"), "[package]\nenable_tree_sitter=false\n".toArray())
    fixture.write(root.join("ffi/raw_input_linux.c"), "/* owned dependency bypass */\n".toArray())
    fixture.write(root.join("ffi/librawinput.dylib"), "owned existing FFI\n".toArray())
    let gate = root.join("target/native/metis-exec-gate-v1")
    let original = "previous owned gate bytes\n".toArray(); fixture.write(gate, original)
    let bin = root.join("fake-bin"); Directory.create(bin)
    let receipt = root.join("gcc.argv")
    fixture.executable(bin.join("gcc"), "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + distributionQuote(receipt.toString()) + "\nexit 73\n")
    let env = fixture.environment.clone(); env["PATH"] = bin.toString() + ":/usr/bin:/bin"; env["MAGIC_PATH"] = magic.toString()
    let result = fixture.run(root.join("build-hook").toString(), ["pre-build"], root, "actual-prebuild-failure", variables: Some(env))
    distributionCheck(result[0] != 0 && File.readFrom(gate) == original && !exists(gate.parent.join("metis-exec-gate-v1.building")))
    let args = distributionText(File.readFrom(receipt))
    let expectedArgs = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "./src/process/managed_exec_gate.c", "-o",
        Path("./target/native").join("metis-exec-gate-v1.building").toString()]
    distributionCheck(args == String.join(expectedArgs, delimiter: "\n") + "\n")
    let node = managedStdioResolveNodeCommand()
    let delegated = fixture.run(node, ["--test", "--test-name-pattern=R-NG-(ASSET-N1|PRODUCER-N1)",
        fixture.project.join("scripts/gateway-native-exec-recovery.test.mjs").toString()], fixture.project, "delegated-asset-hello-negative")
    distributionCheck(delegated[0] == 0)
    let raw = distributionText(delegated[1])
    distributionCheck(raw.contains("R-NG-ASSET-N1") && raw.contains("R-NG-PRODUCER-N1"))
}

@When[os == "macOS"]
private func distributionComparePreflight(fixture: DistributionFixture): Unit {
    let directory = fixture.directory("compare-preflight")
    let left = directory.join("original.bin")
    let right = directory.join("candidate.bin")
    let original = Array<Byte>(8193, { index => UInt8(index % 256) })
    fixture.write(left, original)
    copyFile(left, to: right)
    let baselineFd = ownedTestFdCount()
    distributionCheck(distributionSameFiles(left, right))
    distributionCheck(ownedTestFdCount() == baselineFd)
    for (offset in [0, 4095, 4096, 8192]) {
        let changed = original.clone()
        changed[offset] = if (changed[offset] == 0u8) { 1u8 } else { 0u8 }
        fixture.write(right, changed)
        distributionCheck(!distributionSameFiles(left, right))
        distributionCheck(ownedTestFdCount() == baselineFd)
    }
    fixture.write(right, original[..8192])
    distributionCheck(!distributionSameFiles(left, right))
    distributionCheck(ownedTestFdCount() == baselineFd)
    let longer = Array<Byte>(8194, { index => if (index < original.size) { original[index] } else { 1u8 } })
    fixture.write(right, longer)
    distributionCheck(!distributionSameFiles(left, right))
    distributionCheck(ownedTestFdCount() == baselineFd)
}

@When[os == "macOS"]
private func distributionArchive(fixture: DistributionFixture): Unit {
    let root = fixture.directory("archive 中文😀")
    let output = fixture.stageInputs(root)
    let archive = output.join("magic-cli-${fixture.platform()}-runtime.tar.gz")
    let stage = root.join("scripts/build-static/stage-managed-runtime.sh")
    let args = [stage.toString(), root.toString(), output.toString(), fixture.platform()]
    distributionCheck(fixture.run("/bin/bash", args, root, "stage-positive")[0] == 0)
    let extract = fixture.directory("archive-extracted 中文😀")
    distributionCheck(fixture.run("/usr/bin/tar", ["-xzf", archive.toString(), "-C", extract.toString()], root, "archive-extract")[0] == 0)
    let listing = fixture.run("/usr/bin/tar", ["-tzf", archive.toString()], root, "archive-list")
    distributionCheck(listing[0] == 0)
    let names = distributionText(listing[1]).split("\n")
    var files: Int64 = 0
    for (name in names) {
        if (name.isEmpty() || ["bin/", "scripts/", "libexec/"].contains(name)) { continue }
        distributionCheck(["bin/magic-cli", "scripts/metis-stdio-broker.mjs", "libexec/metis-exec-gate-v1"].contains(name)); files += 1
    }
    distributionCheck(files == 3)
    for ((one, two, mode) in [(output.join("magic-cli"), extract.join("bin/magic-cli"), "755"),
        (root.join("scripts/metis-stdio-broker.mjs"), extract.join("scripts/metis-stdio-broker.mjs"), "644"),
        (root.join("target/native/metis-exec-gate-v1"), extract.join("libexec/metis-exec-gate-v1"), "755")]) {
        distributionCheck(distributionSameFiles(one, two))
        let actual = fixture.run("/usr/bin/stat", ["-f", "%Lp", two.toString()], root, "archive-mode-${mode}-${files}")
        distributionCheck(actual[0] == 0 && distributionText(actual[1]).trimAscii() == mode); files += 1
    }
    let originalArchive = root.join("original-runtime-archive.bin")
    copyFile(archive, to: originalArchive)
    distributionCheck(distributionSameFiles(archive, originalArchive))
    let gate = root.join("target/native/metis-exec-gate-v1")
    let originalGate = root.join("original-native-gate.bin")
    copyFile(gate, to: originalGate)
    distributionCheck(distributionSameFiles(gate, originalGate))
    for (kind in ["missing", "directory", "symlink", "writable", "stale", "tar_failure"]) {
        let env = fixture.environment.clone()
        if (kind == "missing") { remove(gate) }
        else if (kind == "directory") { remove(gate); Directory.create(gate) }
        else if (kind == "symlink") {
            distributionCheck(fixture.run("/bin/mv", [gate.toString(), gate.toString() + ".original"], root, "gate-original")[0] == 0)
            distributionCheck(fixture.run("/bin/ln", ["-s", gate.toString() + ".original", gate.toString()], root, "gate-symlink")[0] == 0)
        } else if (kind == "writable") { distributionCheck(unsafe { chmod(gate.toString(), 0o777) } == 0) }
        else if (kind == "stale") {
            distributionCheck(fixture.run("/usr/bin/touch", ["-t", "200001010000", gate.toString()], root, "gate-stale")[0] == 0)
        } else {
            let fake = root.join("tar-failure"); Directory.create(fake)
            fixture.executable(fake.join("tar"), "#!/bin/sh\nexit 74\n"); env["PATH"] = fake.toString() + ":/usr/bin:/bin"
        }
        distributionCheck(fixture.run("/bin/bash", args, root, "stage-negative-${kind}", variables: Some(env))[0] != 0)
        distributionCheck(distributionSameFiles(archive, originalArchive))
        for (entry in Directory.readFrom(output)) { distributionCheck(!entry.name.startsWith(".managed-runtime.")) }
        if (kind == "directory") { remove(gate, recursive: true) }
        else if (exists(gate) || kind == "symlink") { remove(gate) }
        copyFile(originalGate, to: gate); distributionCheck(distributionSameFiles(gate, originalGate))
        distributionCheck(unsafe { chmod(gate.toString(), 0o755) } == 0)
    }
}

@When[os == "macOS"]
private func distributionRelease(fixture: DistributionFixture, python: Bool, scenario: String): Unit {
    let root = fixture.directory("release-${python}-${scenario}")
    let script = root.join("scripts/release")
    Directory.create(script, recursive: true)
    let binary = root.join("binary"); Directory.create(binary)
    fixture.write(binary.join("magic-cli"), "owned binary\n".toArray())
    let archive = binary.join("magic-cli-${fixture.platform()}-runtime.tar.gz")
    if (scenario != "missing") { fixture.write(archive, "owned selected archive\n".toArray()) }
    let receipt = root.join("upload.jsonl")
    let fake = "import json,sys\nfrom pathlib import Path\np=Path('" + receipt.toString().replace("'", "\\'") + "')\nwith p.open('a') as f: f.write(json.dumps(sys.argv[1:],ensure_ascii=False)+chr(10))\nsys.exit(71 if " + (if (scenario == "archive_fails") { "True" } else { "False" }) + " and sys.argv[1]=='upload' and sys.argv[-1].endswith('-runtime.tar.gz') else 0)\n"
    fixture.write(script.join("gitcode.py"), fake.toArray())
    var result: (Int64, Array<Byte>, Array<Byte>) = (0, [], [])
    if (python) {
        fixture.copy("scripts/release/gitcode_release.py", script.join("gitcode_release.py"))
        let runner = "import importlib.util,sys\ns=importlib.util.spec_from_file_location('owned_release',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\nr=m.ReleaseManager('fixture-owner','fixture-repo','fixture-token'); sys.exit(0 if r.upload_binary() else 1)\n"
        fixture.write(root.join("run.py"), runner.toArray())
        result = fixture.run("/usr/bin/env", ["python3", root.join("run.py").toString(), script.join("gitcode_release.py").toString()], root, "python-release-${scenario}")
    } else {
        let source = distributionText(File.readFrom(fixture.project.join("scripts/release/gitcode_release.sh")))
        fixture.write(script.join("gitcode_release.sh"), source.replace("<username>", "fixture-owner").replace("<repo-name>", "fixture-repo").replace("<gitcode-access-token>", "fixture-token").toArray())
        fixture.executable(root.join("scripts/build-static/build-magic-cli.sh"), "#!/bin/sh\nexit 0\n")
        result = fixture.run("/bin/bash", [script.join("gitcode_release.sh").toString()], root, "shell-release-${scenario}")
    }
    distributionCheck(result[0] == if (scenario == "positive") { 0 } else { 1 })
    let lines: Array<String> = if (exists(receipt)) { distributionText(File.readFrom(receipt)).split("\n") } else { [] }
    let uploads = ArrayList<Array<String>>()
    for (line in lines) {
        if (line.isEmpty()) { continue }
        let values = ArrayList<String>()
        try {
            for (value in JsonValue.fromStr(line).asArray().getItems()) { values.add(value.asString().getValue()) }
        } catch (_: Exception) { throw Exception("managed_distribution_invalid_receipt") }
        distributionCheck(!values.isEmpty())
        if (values[0] == "upload") { uploads.add(values.toArray()) }
    }
    distributionCheck(uploads.size == if (scenario == "missing") { 0 } else { 2 })
    for (index in 0..uploads.size) {
        let values = uploads[index]
        distributionCheck(values.size == 12 && values[1] == "--owner" && values[2] == "fixture-owner" &&
            values[3] == "--repo" && values[4] == "fixture-repo" && values[5] == "--tag" &&
            values[6] == "v0.0.1-${fixture.platform()}" && values[7] == "--access-token" && values[8] == "fixture-token")
        let expected = if (index == 0) { "magic-cli-${fixture.platform()}" } else { archive.fileName }
        distributionCheck(values[values.size - 2] == "--remote-name")
        distributionCheck(values[values.size - 1] == expected)
        let rawFile = Path(values[values.size - 3])
        let actualFile = canonicalize(if (rawFile.isAbsolute()) { rawFile } else { root.join(rawFile) })
        distributionCheck(actualFile == if (index == 0) { binary.join("magic-cli") } else { archive })
    }
}

@When[os == "macOS"]
private func distributionStaticFailure(fixture: DistributionFixture, failed: String): Unit {
    let root = fixture.directory("static-${failed}")
    for (name in ["scripts/build-static/build-magic-cli.sh", "scripts/build-static/magic-static.toml", "scripts/build-static/cli-static.toml", "scripts/build_lock.sh"]) {
        fixture.copy(name, root.join(name))
    }
    let magic = root.join("magic"); Directory.create(magic)
    let local = "owned local original中文😀\n".toArray(); let dependency = "owned magic original中文😀\n".toArray()
    fixture.write(root.join("cjpm.toml"), local); fixture.write(magic.join("cjpm.toml"), dependency)
    let sdk = root.join("sdk"); Directory.create(sdk)
    let fake = root.join("fake-bin"); Directory.create(fake)
    let receipt = root.join("cjpm.argv")
    fixture.executable(fake.join("cjpm"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + distributionQuote(receipt.toString()) +
        "\n[ \"$1\" = " + distributionQuote(failed) + " ] && exit 75\nexit 0\n")
    let startup = root.join("owned-startup")
    fixture.write(startup, ("export PATH=" + distributionQuote(fake.toString() + ":/usr/bin:/bin") + "\n").toArray())
    fixture.write(sdk.join("envsetup.sh"), (". " + distributionQuote(startup.toString()) + "\n").toArray())
    let oldCli = "old owned CLI中文😀\n".toArray()
    let oldArchive = "old owned archive中文😀\n".toArray()
    let oldCliPath = root.join("binary/magic-cli")
    let oldArchivePath = root.join("binary/magic-cli-${fixture.platform()}-runtime.tar.gz")
    if (failed == "copy") {
        fixture.executable(root.join("target/release/bin/metis"), "#!/bin/sh\nexit 0\n")
        fixture.write(oldCliPath, oldCli); fixture.write(oldArchivePath, oldArchive)
        distributionCheck(unsafe { chmod(oldCliPath.toString(), 0o755) } == 0)
        let copyReceipt = root.join("copy-failed.receipt")
        fixture.executable(fake.join("cp"), "#!/bin/sh\nif [ \"$#\" -eq 2 ] && [ \"$1\" = './target/release/bin/metis' ] && [ \"$2\" = './binary/magic-cli' ]; then\n" +
            "  printf 'target-cli-copy\\n' >> " + distributionQuote(copyReceipt.toString()) + "\n  exit 76\nfi\nexec /bin/cp \"$@\"\n")
        fixture.executable(root.join("scripts/build-static/stage-managed-runtime.sh"), "#!/bin/sh\nprintf 'stage-called\\n' > " +
            distributionQuote(root.join("stage-called").toString()) + "\nexit 0\n")
        let release = distributionText(File.readFrom(fixture.project.join("scripts/release/gitcode_release.sh")))
        fixture.write(root.join("scripts/release/gitcode_release.sh"), release.replace("<username>", "fixture-owner")
            .replace("<repo-name>", "fixture-repo").replace("<gitcode-access-token>", "fixture-token").toArray())
        let spy = "from pathlib import Path\nPath('" + root.join("gitcode-called").toString() + "').write_text('invoked')\n"
        fixture.write(root.join("scripts/release/gitcode.py"), spy.toArray())
    }
    let env = fixture.environment.clone(); env["CANGJIE_HOME"] = sdk.toString(); env["MAGIC_PATH"] = magic.toString()
    env["BASH_ENV"] = startup.toString(); env["HOME"] = root.toString(); env["TMPDIR"] = root.toString()
    let entry = if (failed == "copy") { "scripts/release/gitcode_release.sh" } else { "scripts/build-static/build-magic-cli.sh" }
    let result = fixture.run("/bin/bash", [root.join(entry).toString()], root, "static-fails-${failed}", variables: Some(env))
    distributionCheck(result[0] != 0 && File.readFrom(root.join("cjpm.toml")) == local && File.readFrom(magic.join("cjpm.toml")) == dependency)
    distributionCheck(!exists(root.join("cjpm.toml.backup")) && !exists(magic.join("cjpm.toml.backup")))
    if (failed == "copy") {
        distributionCheck(File.readFrom(oldCliPath) == oldCli && File.readFrom(oldArchivePath) == oldArchive)
        distributionCheck(distributionText(File.readFrom(root.join("copy-failed.receipt"))) == "target-cli-copy\n")
        distributionCheck(!exists(root.join("stage-called")) && !exists(root.join("gitcode-called")))
    } else { distributionCheck(!exists(root.join("binary/magic-cli-${fixture.platform()}-runtime.tar.gz"))) }
    let calls = distributionText(File.readFrom(receipt))
    distributionCheck(calls == if (failed == "clean") { "clean\n" } else { "clean\nbuild\n" })
}

@When[os == "macOS"]
@Test
public class ManagedRuntimeDistributionTest {
    @TestCase
    public func rNgB1ActualPrebuildRejectsCompilerFailure(): Unit {
        let fixture = DistributionFixture()
        try { fixture.snapshot(); distributionBuildFailure(fixture); fixture.passed = true } finally { fixture.finish() }
    }

    @TestCase
    public func rNgB3ArchiveAndBothReleaseEntrypointsFailClosed(): Unit {
        let fixture = DistributionFixture()
        try {
            fixture.snapshot(); distributionComparePreflight(fixture); distributionArchive(fixture)
            for (python in [false, true]) {
                for (scenario in ["positive", "missing", "archive_fails"]) { distributionRelease(fixture, python, scenario) }
            }
            for (failed in ["clean", "build", "copy"]) { distributionStaticFailure(fixture, failed) }
            fixture.passed = true
        } finally { fixture.finish() }
    }
}
