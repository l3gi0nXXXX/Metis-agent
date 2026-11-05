package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, rename, remove}
import std.io.{InputStream, SeekPosition}
import std.posix.chmod
import std.process.{ProcessException, ProcessRedirect, launch as lxSdkLaunch}
import std.runtime.{getMaxHeapSize, getThreadCount, getBlockingThreadCount}
import std.sync.AtomicBool
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func lxRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("inherited_launch_contract_failed") }
}
private func lxText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("inherited_launch_fixture_invalid_encoding") }
}
private func lxJson(path: Path): JsonObject {
    try { JsonValue.fromStr(lxText(path)).asObject() }
    catch (_: Exception) { throw Exception("inherited_launch_fixture_malformed_json") }
}
private func lxAtomic(path: Path, bytes: Array<Byte>): Unit {
    File.writeTo(path.parent.join(path.fileName + ".pending"), bytes)
    rename(path.parent.join(path.fileName + ".pending"), to: path)
}
private func lxWait(deadline: MonoTime, test: () -> Bool): Bool {
    while (MonoTime.now() < deadline) { if (test()) { return true }; sleep(Duration.millisecond) }
    test()
}
private func lxRead(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        lxRequire(count > 0 && bytes.size + count <= 1048576)
        bytes.add(all: buffer[..count])
    }
    bytes.toArray()
}
private func lxSegment(path: Path, start: Int64, expected: Array<Byte>): Unit {
    lxRequire(FileInfo(path).size == start + expected.size)
    let bytes = Array<Byte>(expected.size, repeat: 0)
    try (file = File(path, OpenMode.Read)) {
        let _ = file.seek(SeekPosition.Begin(start)); var used: Int64 = 0
        while (used < bytes.size) { let n = file.read(bytes[used..]); lxRequire(n > 0); used += n }
    }
    lxRequire(bytes == expected)
}
private func lxOutput(): Array<Byte> {
    let result = ArrayList<Byte>(); result.add(all: "输出中文😀".toArray()); result.add(all: [0u8, 0xffu8, 0xfeu8]); result.toArray()
}
private func lxError(): Array<Byte> {
    let result = ArrayList<Byte>(); result.add(all: "错误😀".toArray()); result.add(all: [0xfeu8, 0u8]); result.toArray()
}
private func lxCategory(action: () -> Unit): String {
    try { action(); "returned" }
    catch (_: IllegalArgumentException) { "illegal_argument" }
    catch (_: ProcessException) { "process_exception" }
    catch (error: Exception) { if (error.message == "owned_process_exec_outcome_unknown") { "ordinary_unknown" } else { "other_exception" } }
}
@When[os == "macOS"]
private func lxGroupGone(pid: Int64): Bool { unsafe { kill(Int32(-pid), 0) } != 0 && unsafe { __error().read() } == 3 }

@When[os == "macOS"]
private class LxChild {
    let home = canonicalize(Path(getVariable("METIS_INHERITED_HOME").getOrThrow()))
    let nonce = getVariable("METIS_INHERITED_NONCE").getOrThrow()
    let mode = getVariable("METIS_INHERITED_MODE").getOrThrow()
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let inventory = home.join("inventory")
    let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let previousScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
    let handles = ArrayList<ManagedOwnedChild>()
    let readers = ArrayList<Future<Array<Byte>>>()
    let readerJoined = ArrayList<Bool>()
    let waiters = ArrayList<Future<Int64>>()
    let waiterJoined = ArrayList<Bool>()
    let observations = JsonArray()
    let readRelease = AtomicBool(false)
    var baselineFd: Int64 = 0
    var baselineTasks: Int64 = 0
    var baselineBlocking: Int64 = 0
    var calls: Int64 = 0
    var formal = false

    init() {
        lxRequire(home.toString().startsWith("/private/tmp/") && lxText(home.join("owner")) == "inherited-launch-v1\n" + nonce)
        lxRequire(getMaxHeapSize() == 67108864 && previousDirectory.isNone() && previousParent.isNone())
        lxRequire(lxWait(MonoTime.now() + Duration.second * 5, { => exists(home.join("expected-writer")) }))
        let proof = lxJson(home.join("expected-writer"))
        lxRequire(proof.getFields().size == 3 && proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
            proof.get("pid").getOrThrow().asInt().getValue() == getProcessId() &&
            observeProcessBirthIdentity(getProcessId())?.serialize() == Some(proof.get("birth").getOrThrow().asString().getValue()))
        lxRequire(unsafe { getpgid(Int32(getProcessId())) } == Int32(getProcessId()))
    }
    func prepare(): Unit {
        for (_ in 0..2) {
            let warm = launch("/usr/bin/true", []); lxRequire(warm.wait(timeout: Some(Duration.second * 5)) == 0)
            warm.closeStreams(); lxRequire(warm.wait() == 0 && !warm.isAlive() && warm.streamsAreClosed())
        }
        baselineFd = ownedTestFdCount(); baselineTasks = getThreadCount(); baselineBlocking = getBlockingThreadCount()
        if (mode == "bound") { lxRequire(managedRecoveryInitialize(inventory, parent, nonce)) }
        File.writeTo(home.join("parent-identity"), parent.toArray())
    }
    func launch(command: String, args: Array<String>, workingDirectory!: ?Path = None,
        environment!: ?Map<String, String> = None, input!: ProcessRedirect = ProcessRedirect.Inherit,
        output!: ProcessRedirect = ProcessRedirect.Inherit, error!: ProcessRedirect = ProcessRedirect.Inherit): ManagedOwnedChild {
        let child = if (mode == "sdk") {
            ManagedSdkChild(lxSdkLaunch(command, args, workingDirectory: workingDirectory, environment: environment, stdIn: input, stdOut: output, stdErr: error), [input, output, error])
        } else {
            managedRecoveryLaunchOwned(command, args, workingDirectory: workingDirectory, environment: environment, stdIn: input, stdOut: output, stdErr: error)
        }
        handles.add(child); child
    }
    func sourceTerminal(deadline: MonoTime): Bool {
        if (mode != "bound") { return !exists(inventory) }
        let proof = managedRecoveryProbeRecords(inventory, parent, nonce, deadline)
        proof.ok && proof.terminal
    }
    func checkpoint(): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        let settled = lxWait(deadline, { => sourceTerminal(deadline) && (mode == "sdk" ||
            (ownedTestFdCount() == baselineFd && getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking)) })
        let proof = JsonObject(); proof.put("settled", JsonBool(settled)); proof.put("fd", JsonInt(ownedTestFdCount()))
        proof.put("baselineFd", JsonInt(baselineFd)); proof.put("tasks", JsonInt(getThreadCount())); proof.put("baselineTasks", JsonInt(baselineTasks))
        proof.put("blocking", JsonInt(getBlockingThreadCount())); proof.put("baselineBlocking", JsonInt(baselineBlocking)); proof.put("calls", JsonInt(calls))
        File.writeTo(home.join("resource-checkpoint.json"), proof.toJsonString().toArray()); lxRequire(settled)
    }
    func observe(label: String, category: String, code!: Int64 = -1): Unit {
        let row = JsonObject(); row.put("label", JsonString(label)); row.put("category", JsonString(category)); row.put("code", JsonInt(code))
        observations.add(row); File.writeTo(home.join("observations.json"), observations.toJsonString().toArray())
    }
    func readyLaunch(label: String, body: String, input!: ProcessRedirect = ProcessRedirect.Inherit,
        output!: ProcessRedirect = ProcessRedirect.Inherit, error!: ProcessRedirect = ProcessRedirect.Inherit): ManagedOwnedChild {
        let run = home.join(label); Directory.create(run)
        let script = "printf '%s' \"$$\" > \"$1/ready.pending\"; /bin/mv \"$1/ready.pending\" \"$1/ready\"; " +
            "while [ ! -f \"$1/release\" ]; do /bin/sleep 0.005; done; " + body
        let child = launch("/bin/sh", ["-c", script, "owned", run.toString()], input: input, output: output, error: error)
        lxRequire(lxWait(MonoTime.now() + Duration.second * 5, { => exists(run.join("ready")) }))
        let businessPid = Int64.parse(lxText(run.join("ready")))
        let birth = observeProcessBirthIdentity(businessPid).getOrThrow()
        lxRequire(observeProcessBirthIdentity(businessPid)?.serialize() == Some(birth.serialize()))
        let group = Int64(unsafe { getpgid(Int32(businessPid)) })
        lxRequire(group == if (mode == "bound") { businessPid } else { Int64(unsafe { getpgid(Int32(getProcessId())) }) })
        let identity = JsonObject(); identity.put("pid", JsonInt(businessPid)); identity.put("birth", JsonString(birth.serialize())); identity.put("pgid", JsonInt(group))
        File.writeTo(run.join("actual-birth.json"), identity.toJsonString().toArray())
        lxAtomic(run.join("release"), nonce.toArray()); child
    }
    func inherited(): Unit {
        let bytes = lxOutput(); let expectedError = lxError()
        for (index in 0..32) {
            let outStart = FileInfo(home.join("stdout")).size; let errStart = FileInfo(home.join("stderr")).size
            let child = readyLaunch("inherited-${index}", "/bin/dd bs=${bytes.size} count=1 2>/dev/null; printf '错误😀\\376\\000' >&2; exit 7")
            lxRequire(child.wait(timeout: Some(Duration.second * 5)) == 7 && child.wait() == 7)
            lxSegment(home.join("stdout"), outStart, bytes); lxSegment(home.join("stderr"), errStart, expectedError)
            child.closeStreams(); lxRequire(child.streamsAreClosed() && !child.isAlive())
            calls += 1; observe("inherited-${index}", "returned", code: 7); checkpoint()
        }
        lxRequire(calls == 32)
    }
    func pipeRetention(): Unit {
        let child = readyLaunch("retained", "printf '输出中文😀\\000\\377\\376'; printf '错误😀\\376\\000' >&2; exit 7",
            input: ProcessRedirect.Pipe, output: ProcessRedirect.Pipe, error: ProcessRedirect.Pipe)
        lxRequire((child.stdInPipe as Resource).isNone() && (child.stdOutPipe as Resource).isNone() && (child.stdErrPipe as Resource).isNone())
        let stdoutReady = AtomicBool(false); let stderrReady = AtomicBool(false)
        readers.add(spawn { stdoutReady.store(true); lxRequire(lxWait(MonoTime.now() + Duration.second * 5, { => readRelease.load() })); lxRead(child.stdOutPipe) }); readerJoined.add(false)
        readers.add(spawn { stderrReady.store(true); lxRequire(lxWait(MonoTime.now() + Duration.second * 5, { => readRelease.load() })); lxRead(child.stdErrPipe) }); readerJoined.add(false)
        lxRequire(lxWait(MonoTime.now() + Duration.second * 2, { => stdoutReady.load() && stderrReady.load() }))
        lxRequire(child.wait(timeout: Some(Duration.second * 2)) == 7 && child.wait() == 7 && !child.streamsAreClosed())
        readRelease.store(true)
        let out = readers[0].get(Duration.second * 2); readerJoined[0] = true
        let err = readers[1].get(Duration.second * 2); readerJoined[1] = true
        File.writeTo(home.join("actual.stdout.bin"), out); File.writeTo(home.join("actual.stderr.bin"), err)
        lxRequire(out == lxOutput() && err == lxError())
        child.closeStreams(); lxRequire(child.streamsAreClosed() && !child.isAlive()); calls = 1; checkpoint()
    }
    func getter(child: ManagedOwnedChild): Unit {
        lxRequire(child.stdOutPipe.read(Array<Byte>(1, repeat: 0)) == -1 && child.stdErrPipe.read(Array<Byte>(1, repeat: 0)) == -1)
        lxRequire(lxCategory({ => child.stdInPipe.write([1u8]) }) == "process_exception")
        child.stdInPipe.flush()
        for (resource in [(child.stdInPipe as Resource).getOrThrow(), (child.stdOutPipe as Resource).getOrThrow(), (child.stdErrPipe as Resource).getOrThrow()]) {
            lxRequire(resource.isClosed()); resource.close(); lxRequire(resource.isClosed())
        }
    }
    func redirects(): Unit {
        for (label in ["inherit", "discard", "file"]) {
            let directory = home.join(label); Directory.create(directory)
            File.writeTo(directory.join("input"), lxOutput())
            try (input = File(directory.join("input"), OpenMode.Read), out = File(directory.join("out"), OpenMode.Write), err = File(directory.join("err"), OpenMode.Write)) {
                let inputMode = if (label == "file") { ProcessRedirect.FromFile(input) } else if (label == "discard") { ProcessRedirect.Discard } else { ProcessRedirect.Inherit }
                let outMode = if (label == "file") { ProcessRedirect.FromFile(out) } else if (label == "discard") { ProcessRedirect.Discard } else { ProcessRedirect.Inherit }
                let errMode = if (label == "file") { ProcessRedirect.FromFile(err) } else if (label == "discard") { ProcessRedirect.Discard } else { ProcessRedirect.Inherit }
                let child = launch("/bin/sh", ["-c", if (label == "file") { "/bin/cat; printf '错误😀\\376\\000' >&2; exit 7" } else { "exit 7" }], input: inputMode, output: outMode, error: errMode)
                getter(child); lxRequire(child.wait(timeout: Some(Duration.second * 5)) == 7 && child.wait() == 7)
                child.closeInput(); child.closeStreams(); getter(child)
                lxRequire(!input.isClosed() && !out.isClosed() && !err.isClosed())
                let _ = input.seek(SeekPosition.Begin(0)); let reread = Array<Byte>(lxOutput().size, repeat: 0)
                lxRequire(input.read(reread) == reread.size && reread == lxOutput())
                out.write("sentinel中文😀".toArray()); err.write("sentinel错误😀".toArray())
            }
            if (label == "file") {
                lxRequire(File.readFrom(directory.join("out")) == lxOutput().concat("sentinel中文😀".toArray()))
                lxRequire(File.readFrom(directory.join("err")) == lxError().concat("sentinel错误😀".toArray()))
            }
            calls += 1; checkpoint()
        }
        let closed = File(home.join("closed"), OpenMode.Write); closed.close()
        lxRequire(lxCategory({ => let _ = launch("/usr/bin/true", [], output: ProcessRedirect.FromFile(closed)) }) == "process_exception")
        let unlinked = File(home.join("unlinked"), OpenMode.Write)
        try {
            remove(home.join("unlinked"))
            lxRequire(lxCategory({ => let _ = launch("/usr/bin/true", [], output: ProcessRedirect.FromFile(unlinked)) }) == "process_exception")
            lxRequire(!unlinked.isClosed()); unlinked.write("caller-owned".toArray())
        } finally { unlinked.close() }
        calls += 2; checkpoint(); lxRequire(calls == 5)
    }
    func timeout(): Unit {
        let child = launch("/bin/sleep", ["30"], input: ProcessRedirect.Pipe, output: ProcessRedirect.Pipe, error: ProcessRedirect.Pipe)
        var timedOut = false
        try { let _ = child.wait(timeout: Some(Duration.millisecond * 5)) } catch (_: TimeoutException) { timedOut = true }
        lxRequire(timedOut && child.isAlive() && !child.streamsAreClosed())
        child.terminate(); lxRequire(child.wait(timeout: Some(Duration.second * 2)) == 15 && child.wait() == 15 && !child.streamsAreClosed())
        let out = lxRead(child.stdOutPipe); let err = lxRead(child.stdErrPipe)
        File.writeTo(home.join("actual.stdout.bin"), out); File.writeTo(home.join("actual.stderr.bin"), err)
        lxRequire(out.isEmpty() && err.isEmpty())
        child.closeStreams(); lxRequire(child.streamsAreClosed() && !child.isAlive()); calls = 1; checkpoint()
    }
    func concurrent(): Unit {
        let child = readyLaunch("concurrent", "printf '输出中文😀\\000\\377\\376'; printf '错误😀\\376\\000' >&2; exit 7",
            input: ProcessRedirect.Pipe, output: ProcessRedirect.Pipe, error: ProcessRedirect.Pipe)
        waiters.add(spawn { child.wait(timeout: Some(Duration.second * 2)) }); waiterJoined.add(false)
        waiters.add(spawn { child.wait(timeout: Some(Duration.second * 2)) }); waiterJoined.add(false)
        for (index in 0..2) { let code = waiters[index].get(Duration.second * 3); waiterJoined[index] = true; lxRequire(code == 7) }
        lxRequire(child.wait() == 7 && !child.streamsAreClosed())
        let out = lxRead(child.stdOutPipe); let err = lxRead(child.stdErrPipe)
        File.writeTo(home.join("actual.stdout.bin"), out); File.writeTo(home.join("actual.stderr.bin"), err)
        lxRequire(out == lxOutput() && err == lxError()); child.closeStreams()
        lxRequire(child.streamsAreClosed() && !child.isAlive()); calls = 1; checkpoint()
    }
    func validation(): Unit {
        File.writeTo(home.join("cwd-file"), "owned".toArray())
        for (index in 0..9) {
            var command = "/usr/bin/true"; var args = Array<String>(); var cwd = None<Path>
            let env = HashMap<String, String>([("PATH", "/usr/bin:/bin")])
            if (index == 0) { command = "/usr/bin/true\u{0}" }
            if (index == 1) { args = ["bad\u{0}"] }
            if (index == 2) { env["BAD\u{0}"] = "owned" }
            if (index == 3) { env["BAD"] = "owned\u{0}" }
            if (index == 4) { env["BAD=KEY"] = "owned" }
            if (index == 5 || index == 8) { cwd = Some(home.join("missing-cwd")) }
            if (index == 6) { cwd = Some(home.join("cwd-file")) }
            if (index == 7 || index == 8) { command = "" }
            let before = if (mode == "bound") { managedRecoveryReadIssued(inventory, parent) } else { 0 }
            let actualCommand = command; let actualArgs = args; let actualCwd = cwd
            let category = lxCategory({ => let _ = launch(actualCommand, actualArgs, workingDirectory: actualCwd, environment: Some<Map<String, String>>(env)) })
            observe("validation-${index}", category)
            lxRequire(category == if (index == 7) { "process_exception" } else { "illegal_argument" })
            if (mode == "bound") { lxRequire(managedRecoveryReadIssued(inventory, parent) == before && before == 0) }
            calls += 1; checkpoint()
        }
        lxRequire(calls == 9)
    }
    func ordinary(): Unit {
        for (code in [125i64, 126i64, 127i64]) {
            let directory = home.join("ordinary-${code}"); Directory.create(directory)
            try (output = File(directory.join("out"), OpenMode.Write), error = File(directory.join("err"), OpenMode.Write)) {
                let child = readyLaunch("ordinary-ready-${code}", "printf '输出中文😀\\000\\377\\376'; printf '错误😀\\376\\000' >&2; exit ${code}",
                    output: ProcessRedirect.FromFile(output), error: ProcessRedirect.FromFile(error))
                lxRequire(child.wait(timeout: Some(Duration.second * 5)) == code && child.wait() == code)
                lxRequire(managedRecoveryWaitForCommand(child) == code && child.wait() == code)
                child.closeStreams(); lxRequire(child.streamsAreClosed() && !child.isAlive() && !output.isClosed() && !error.isClosed())
            }
            lxRequire(File.readFrom(directory.join("out")) == lxOutput() && File.readFrom(directory.join("err")) == lxError())
            calls += 1; observe("business-${code}", "returned", code: code); checkpoint()
        }
        lxRequire(calls == 3)
    }
    func privateGate(label: String): Path {
        let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
        let dev = home.join("dev-" + label)
        Directory.create(dev.join("scripts"), recursive: true); Directory.create(dev.join("src/process"), recursive: true)
        Directory.create(dev.join("target/native"), recursive: true)
        for (name in ["scripts/metis-stdio-broker.mjs", "src/process/managed_exec_gate.c", "build.cj"]) {
            let bytes = File.readFrom(project.join(name)); File.writeTo(dev.join(name), bytes)
            lxRequire(File.readFrom(dev.join(name)) == bytes)
        }
        let actor = if (label == "spawn") { "#!" + home.join("missing-interpreter").toString() + "\n" } else {
            "#!/bin/sh\njournal=$METIS_PROCESS_RECOVERY_DIRECTORY\nkey=$METIS_PROCESS_RECOVERY_BROKER_KEY\n" +
            "while [ ! -f \"$journal/$key-o-1.birth\" ]; do /bin/sleep 0.01; done\n" +
            "/bin/cat \"$journal/$key.birth\" > \"$METIS_INHERITED_HOME/unknown-helper.birth\" || exit 125\n" +
            "/bin/cat \"$journal/$key-o-1.birth\" > \"$METIS_INHERITED_HOME/unknown-owner.birth\" || exit 125\n" +
            "printf 'METIS-EXEC-GATE:9:00000000000000000000000000000000\\n' >&3\nexec /bin/sleep 300\n"
        }
        let gate = dev.join("target/native/metis-exec-gate-v1")
        File.writeTo(gate, actor.toArray()); lxRequire(chmod(gate.toString(), UInt32(0o755)) == 0)
        dev.join("scripts/metis-stdio-broker.mjs")
    }
    func facts(): Unit {
        lxRequire(mode == "bound")
        let originalScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
        for (label in ["exec", "spawn", "unknown"]) {
            if (label == "exec") {
                match (originalScript) { case Some(value) => setVariable("METIS_STDIO_BROKER_SCRIPT", value) case None => removeVariable("METIS_STDIO_BROKER_SCRIPT") }
            } else { setVariable("METIS_STDIO_BROKER_SCRIPT", privateGate(label).toString()) }
            let issued = managedRecoveryReadIssued(inventory, parent)
            let marker = home.join("business-marker-" + label)
            let child = launch(if (label == "exec") { home.join("missing-business").toString() } else { "/usr/bin/touch" },
                if (label == "exec") { [] } else { [marker.toString()] }, input: ProcessRedirect.Discard, output: ProcessRedirect.Discard, error: ProcessRedirect.Discard)
            lxRequire(lxWait(MonoTime.now() + Duration.second * 5, { => !child.isAlive() }))
            let key = "r-${issued + 1}"
            let outcome = managedRecoveryReadExecError(inventory, parent, nonce, key + "-o-1").getOrThrow()
            lxRequire(outcome.phase == if (label == "unknown") { "channel" } else { label })
            if (label != "unknown") { lxRequire(outcome.error == 2) }
            File.writeTo(home.join(label + "-original.exec_error"), outcome.originalText.toArray())
            let fields = HashMap<String, String>()
            for (line in outcome.originalText.split("\n")) {
                let parts = line.split(":")
                if (parts.size >= 2) { fields[parts[0]] = String.join(parts[1..], delimiter: ":") }
            }
            lxRequire(fields["binding"] == nonce && fields["parent"] == parent && fields["helper_pid"] == child.pid.toString())
            let helperBirth = parseProcessBirthIdentity(fields["helper_birth"]).getOrThrow()
            let helperGone = probeProcessBirthIdentity(helperBirth, MonoTime.now() + Duration.second * 2)
            lxRequire(helperBirth.pid == child.pid && helperGone.conclusive && !helperGone.alive)
            if (label == "spawn") {
                lxRequire(fields["owner_pid"] == "0" && fields["owner_pgid"] == "0" && fields["owner_birth"].isEmpty())
                lxRequire(!exists(inventory.join(key + "-o-1.spawned")) && !exists(inventory.join(key + "-o-1.birth")))
            } else {
                let ownerBirth = parseProcessBirthIdentity(fields["owner_birth"]).getOrThrow()
                let ownerGone = probeProcessBirthIdentity(ownerBirth, MonoTime.now() + Duration.second * 2)
                lxRequire(ownerGone.conclusive && !ownerGone.alive && lxGroupGone(ownerBirth.pid))
            }
            let raw = child.wait(timeout: Some(Duration.second * 5))
            lxRequire(child.wait() == raw)
            if (label != "unknown") { lxRequire(raw == 125) }
            let category = lxCategory({ => let _ = managedRecoveryWaitForCommand(child) })
            observe("bridge-" + label, category, code: raw)
            lxRequire(category == if (label == "unknown") { "ordinary_unknown" } else { "process_exception" })
            lxRequire(lxCategory({ => let _ = managedRecoveryWaitForCommand(child) }) == category && child.wait() == raw)
            child.closeStreams(); lxRequire(child.streamsAreClosed() && !child.isAlive() && !exists(marker))
            lxRequire(managedRecoveryReadIssued(inventory, parent) == issued + 1 &&
                managedRecoveryReadRootCheckpoint(inventory, parent).getOrThrow().covers(key))
            calls += 1; checkpoint()
        }
        lxRequire(calls == 3)
    }
    func finish(): Unit {
        var proofSaved = false; var sourceBefore = false; var terminal = false
        try {
            try {
                sourceBefore = sourceTerminal(MonoTime.now() + Duration.second * 2)
                var joined = true
                for (value in readerJoined) { joined = joined && value }; for (value in waiterJoined) { joined = joined && value }
                let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("nonce", JsonString(nonce)); proof.put("mode", JsonString(mode))
                proof.put("calls", JsonInt(calls)); proof.put("sourceTerminalBeforeFallback", JsonBool(sourceBefore)); proof.put("workersJoined", JsonBool(joined))
                proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("heapBytes", JsonInt(getMaxHeapSize()))
                File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray()); proofSaved = true
            } catch (_: Exception) { @Expect(false, true) }
        } finally {
            readRelease.store(true)
            let deadline = MonoTime.now() + Duration.second * 3
            terminal = true
            for (child in handles) {
                try {
                    if (child.isAlive()) { child.terminate() }
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { terminal = false; continue }
                    let code = child.wait(timeout: Some(remaining))
                    terminal = terminal && code >= 0 && code <= 255 && child.wait() == code && !child.isAlive() && observeProcessBirthIdentity(child.pid).isNone()
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                finally { try { child.closeStreams(); terminal = terminal && child.streamsAreClosed() } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            for (index in 0..readers.size) {
                if (!readerJoined[index]) {
                    let remaining = deadline - MonoTime.now()
                    if (remaining > Duration.Zero) { try { let _ = readers[index].get(remaining); readerJoined[index] = true } catch (_: Exception) { terminal = false; @Expect(false, true) } }
                    else { terminal = false }
                }
            }
            for (index in 0..waiters.size) {
                if (!waiterJoined[index]) {
                    let remaining = deadline - MonoTime.now()
                    if (remaining > Duration.Zero) { try { let _ = waiters[index].get(remaining); waiterJoined[index] = true } catch (_: Exception) { terminal = false; @Expect(false, true) } }
                    else { terminal = false }
                }
            }
            try {
                if (mode == "bound") { terminal = managedRecoveryStopOwnedChildren((inventory.toString(), parent), deadline) && terminal }
                terminal = terminal && MonoTime.now() < deadline && sourceTerminal(deadline) && MonoTime.now() <= deadline
            } catch (_: Exception) { terminal = false; @Expect(false, true) }
            try {
                File.writeTo(home.join("child-cleanup.json"), ("{\"terminal\":${terminal},\"proofSaved\":${proofSaved},\"formal\":${formal && sourceBefore && proofSaved},\"retained\":true}").toArray())
            } catch (_: Exception) { @Expect(false, true) }
            finally {
                if (terminal) {
                    try {
                        match (previousDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
                        match (previousParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
                        match (previousScript) { case Some(value) => setVariable("METIS_STDIO_BROKER_SCRIPT", value) case None => removeVariable("METIS_STDIO_BROKER_SCRIPT") }
                    } catch (_: Exception) { @Expect(false, true) }
                }
            }
            @Expect(terminal, true); @Expect(proofSaved, true)
        }
    }
}

@When[os == "macOS"]
private func lxChild(kind: String): Unit {
    let fixture = LxChild()
    try {
        fixture.prepare()
        if (kind == "inherit") { fixture.inherited() }
        else if (kind == "pipe") { fixture.pipeRetention() }
        else if (kind == "getters") { fixture.redirects() }
        else if (kind == "timeout") { fixture.timeout() }
        else if (kind == "concurrent") { fixture.concurrent() }
        else if (kind == "validation") { fixture.validation() }
        else if (kind == "ordinary") { fixture.ordinary() }
        else if (kind == "facts") { fixture.facts() }
        else { throw Exception("inherited_launch_fixture_kind_invalid") }
        fixture.formal = true
    } finally { fixture.finish() }
}

@When[os == "macOS"]
private func lxParent(kind: String, method: String): Unit {
    if (getVariable("METIS_INHERITED_KIND") == Some(kind)) { lxChild(kind); return }
    lxRequire(getMaxHeapSize() == 67108864)
    let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
    let node = managedStdioResolveNodeCommand(); lxRequire(Path(node).isAbsolute() && exists(Path(node)))
    let home = canonicalize(Directory.createTemp("/private/tmp")); let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let handles = ArrayList<ManagedOwnedChild>(); let births = ArrayList<ProcessBirthIdentity>()
    let baselineFd = ownedTestFdCount(); let baselineTasks = getThreadCount(); let baselineBlocking = getBlockingThreadCount()
    var formal = false; var proofSaved = false; var pendingLaunch = false
    File.writeTo(home.join("owner"), ("inherited-launch-parent-v1\n" + nonce).toArray())
    println("R-LAUNCH-COMPAT fixture=${home.fileName};nonce=${nonce};kind=${kind}")
    try {
        let inputs = home.join("source-inputs"); Directory.create(inputs)
        for (name in ["src/process/managed_owned_child.cj", "src/process/managed_inherited_launch_compat_test.cj", "src/process/managed_sdk_child_compat_test.cj",
            "src/sandbox/sandbox_macos.cj", "src/sandbox/sandbox_docker.cj", "scripts/metis-stdio-broker.mjs"]) {
            File.writeTo(inputs.join(Path(name).fileName), File.readFrom(project.join(name)))
        }
        let modes = if (kind == "inherit" || kind == "getters") { ["sdk", "absent"] } else if (kind == "validation") { ["sdk", "absent", "bound"] }
            else if (kind == "ordinary") { ["absent", "bound"] } else if (kind == "facts") { ["bound"] } else { ["absent"] }
        for (mode in modes) {
            let directory = home.join(mode); Directory.create(directory)
            File.writeTo(directory.join("owner"), ("inherited-launch-v1\n" + nonce).toArray())
            let inputBytes = ArrayList<Byte>(); for (_ in 0..32) { inputBytes.add(all: lxOutput()) }
            File.writeTo(directory.join("input"), inputBytes.toArray())
            let env = HashMap<String, String>()
            for ((name, value) in getVariables()) {
                if (["PATH", "LANG", "CANGJIE_HOME", "CANGJIE_PATH", "CANGJIE_STDX_PATH", "MAGIC_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SDKROOT", "cjHeapSize"].contains(name)) { env[name] = value }
            }
            env["HOME"] = directory.toString(); env["TMPDIR"] = directory.toString(); env["METIS_HOME"] = directory.toString()
            env["METIS_INHERITED_HOME"] = directory.toString(); env["METIS_INHERITED_NONCE"] = nonce; env["METIS_INHERITED_MODE"] = mode
            env["METIS_INHERITED_KIND"] = kind; env["METIS_CJPM_ROOT"] = project.toString(); env["METIS_STDIO_BROKER_NODE_COMMAND"] = node
            try (input = File(directory.join("input"), OpenMode.Read), output = File(directory.join("stdout"), OpenMode.Write), error = File(directory.join("stderr"), OpenMode.Write)) {
                pendingLaunch = true
                let child = launchManagedRawChild(getCommand(), ["--filter=ManagedInheritedLaunchCompatTest.${method}", "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"],
                    newGeneration: true, workingDirectory: Some(directory), environment: Some<Map<String, String>>(env),
                    stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
                handles.add(child); pendingLaunch = false
                let birth = observeProcessBirthIdentity(child.pid).getOrThrow(); births.add(birth)
                lxRequire(unsafe { getpgid(Int32(child.pid)) } == Int32(child.pid))
                let writer = JsonObject(); writer.put("nonce", JsonString(nonce)); writer.put("pid", JsonInt(child.pid)); writer.put("birth", JsonString(birth.serialize()))
                lxAtomic(directory.join("expected-writer"), writer.toJsonString().toArray())
                let code = child.wait(timeout: Some(Duration.second * 60)); child.closeStreams()
                lxRequire(code == 0 && child.wait() == 0 && !child.isAlive() && child.streamsAreClosed() && lxGroupGone(child.pid) &&
                    observeProcessBirthIdentity(child.pid).isNone() && !input.isClosed() && !output.isClosed() && !error.isClosed())
            }
            let childProof = lxJson(directory.join("child-formal-before-fallback.json")); let cleanup = lxJson(directory.join("child-cleanup.json"))
            let expectedCalls = if (kind == "inherit") { 32 } else if (kind == "getters") { 5 } else if (kind == "validation") { 9 }
                else if (kind == "ordinary" || kind == "facts") { 3 } else { 1 }
            lxRequire(childProof.get("nonce").getOrThrow().asString().getValue() == nonce && childProof.get("mode").getOrThrow().asString().getValue() == mode &&
                childProof.get("formal").getOrThrow().asBool().getValue() && childProof.get("sourceTerminalBeforeFallback").getOrThrow().asBool().getValue() &&
                childProof.get("workersJoined").getOrThrow().asBool().getValue() && childProof.get("recordedBeforeFallback").getOrThrow().asBool().getValue() &&
                childProof.get("heapBytes").getOrThrow().asInt().getValue() == 67108864 && childProof.get("calls").getOrThrow().asInt().getValue() == expectedCalls &&
                cleanup.get("terminal").getOrThrow().asBool().getValue() && cleanup.get("proofSaved").getOrThrow().asBool().getValue())
            if (mode == "bound") {
                let parent = lxText(directory.join("parent-identity"))
                let source = managedRecoveryProbeRecords(directory.join("inventory"), parent, nonce, MonoTime.now() + Duration.second * 2)
                File.writeTo(directory.join("parent-original-source"), source.original.toArray()); lxRequire(source.ok && source.terminal)
            } else { lxRequire(!exists(directory.join("inventory"))) }
            lxRequire(lxWait(MonoTime.now() + Duration.second * 2, { => ownedTestFdCount() == baselineFd && getThreadCount() <= baselineTasks && getBlockingThreadCount() <= baselineBlocking }))
        }
        formal = true
    } finally {
        try {
            try {
                File.writeTo(home.join("parent-formal-before-fallback.json"), ("{\"formal\":${formal},\"recordedBeforeFallback\":true,\"retained\":true}").toArray()); proofSaved = true
            } catch (_: Exception) { @Expect(false, true) }
        } finally {
            let deadline = MonoTime.now() + Duration.second * 3; var terminal = !pendingLaunch
            for (index in 0..handles.size) {
                let child = handles[index]
                try {
                    if (child.isAlive() && index < births.size && observeProcessBirthIdentity(child.pid)?.serialize() == Some(births[index].serialize())) { child.terminate() }
                    let remaining = deadline - MonoTime.now()
                    if (remaining <= Duration.Zero) { terminal = false; continue }
                    let code = child.wait(timeout: Some(remaining))
                    terminal = terminal && code >= 0 && code <= 255 && child.wait() == code && !child.isAlive() && lxGroupGone(child.pid) && observeProcessBirthIdentity(child.pid).isNone()
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                finally { try { child.closeStreams(); terminal = terminal && child.streamsAreClosed() } catch (_: Exception) { terminal = false; @Expect(false, true) } }
            }
            terminal = terminal && MonoTime.now() <= deadline
            try { File.writeTo(home.join("parent-cleanup.json"), ("{\"driverTerminal\":${terminal},\"proofSaved\":${proofSaved},\"retained\":true}").toArray()) }
            catch (_: Exception) { @Expect(false, true) }
            @Expect(terminal, true); @Expect(proofSaved, true)
        }
    }
}

@When[os == "macOS"]
@Test
public class ManagedInheritedLaunchCompatTest {
    @TestCase public func noContextP1ThirtyTwoInheritedLaunchesPreserveBytesAndResources(): Unit { lxParent("inherit", "noContextP1ThirtyTwoInheritedLaunchesPreserveBytesAndResources") }
    @TestCase public func noContextU1WaitRetainsUnreadPipeBytesUntilExplicitClose(): Unit { lxParent("pipe", "noContextU1WaitRetainsUnreadPipeBytesUntilExplicitClose") }
    @TestCase public func noContextU2NonPipeGettersAndBorrowedFilesStayCompatible(): Unit { lxParent("getters", "noContextU2NonPipeGettersAndBorrowedFilesStayCompatible") }
    @TestCase public func noContextU3TimeoutRetainsLiveProcessAndExplicitCloseOwner(): Unit { lxParent("timeout", "noContextU3TimeoutRetainsLiveProcessAndExplicitCloseOwner") }
    @TestCase public func noContextU4ConcurrentRawWaitersKeepSameCodeAndReadOwnership(): Unit { lxParent("concurrent", "noContextU4ConcurrentRawWaitersKeepSameCodeAndReadOwnership") }
    @TestCase public func launchN1SdkCategoriesPrecedeAnyRecoveryAdmission(): Unit { lxParent("validation", "launchN1SdkCategoriesPrecedeAnyRecoveryAdmission") }
    @TestCase public func commandP1Ordinary125126127KeepRawCachedCodes(): Unit { lxParent("ordinary", "commandP1Ordinary125126127KeepRawCachedCodes") }
    @TestCase public func commandN1ExecSpawnAndUnknownUseRealFactsWithoutChangingRawWait(): Unit { lxParent("facts", "commandN1ExecSpawnAndUnknownUseRealFactsWithoutChangingRawWait") }
}
