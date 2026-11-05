package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getVariables}
import std.fs.{Directory, File, OpenMode, Path, canonicalize, exists, remove}
import std.process.{ProcessException, ProcessRedirect, executeWithOutput}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.*

private func captureNoContextRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_fixture_encoding" }
}

private func captureNoContextCheck(value: Bool): Unit {
    @Expect(value, true)
    if (!value) { throw Exception("capture_without_context_contract_failed") }
}

private func captureNoContextInput(): Array<Byte> {
    let value = ArrayList<Byte>(); value.add(all: "继承输入中文😀".toArray())
    value.add(all: [0u8, 0xffu8, 0xfeu8, 0x80u8]); value.toArray()
}

@When[os == "macOS"]
private func captureNoContextChild(mode: String): Unit {
    let home = canonicalize(Path(getVariable("METIS_CAPTURE_TEST_HOME").getOrThrow()))
    let nonce = getVariable("METIS_CAPTURE_TEST_NONCE").getOrThrow()
    if (!home.toString().startsWith("/private/tmp/") || nonce.isEmpty() ||
        captureNoContextRead(home.join("owner")) != "capture-without-context-v1\n" + nonce ||
        !["sdk", "public", "negative"].contains(mode)) { throw Exception("capture_without_context_scope_invalid") }
    captureNoContextCheck(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").isNone())
    captureNoContextCheck(getVariable("METIS_PROCESS_RECOVERY_PARENT").isNone())
    let baseline = ownedTestFdCount()
    let group = Int64(unsafe { getpgid(Int32(getProcessId())) })
    captureNoContextCheck(group > 1)
    var completed: Int64 = 0
    var invalidDirectoryExceptions: Int64 = 0
    var missingCommandExceptions: Int64 = 0
    var passed = false
    var emptyEnvironmentKey = false
    let stdout = ArrayList<Byte>(); let stderr = ArrayList<Byte>()
    let proof = JsonObject()
    try {
        if (mode == "negative") {
            for (kind in [1, 0]) {
                for (sequence in 0..100) {
                    let marker = home.join("unexpected-${kind}-${sequence}")
                    var actualKind = "none"
                    try {
                        if (kind == 0) {
                            let _ = managedRecoveryExecuteWithOutput("/metis-capture-command-does-not-exist", [marker.toString()])
                        } else {
                            let _ = managedRecoveryExecuteWithOutput("/usr/bin/touch", [marker.toString()],
                                workingDirectory: Some(home.join("missing-directory")))
                        }
                    } catch (_: ProcessException) { actualKind = "process_exception" }
                    catch (_: IllegalArgumentException) { actualKind = "illegal_argument" }
                    catch (_: Exception) { actualKind = "other_exception" }
                    let expectedKind = if (kind == 1) { "illegal_argument" } else { "process_exception" }
                    if (actualKind == expectedKind) {
                        if (kind == 1) { invalidDirectoryExceptions += 1 } else { missingCommandExceptions += 1 }
                    }
                    captureNoContextCheck(actualKind == expectedKind && !exists(marker))
                    captureNoContextCheck(ownedTestFdCount() == baseline)
                    completed += 1
                }
            }
            captureNoContextCheck(completed == 200 && invalidDirectoryExceptions == 100 && missingCommandExceptions == 100)
        } else {
            let expectedInput = captureNoContextInput()
            let expectedError = ArrayList<Byte>(); expectedError.add(all: "错误😀".toArray()); expectedError.add(all: [0u8, 0xfeu8])
            for (sequence in 0..100) {
                let groupFile = home.join("group-${sequence}")
                let pidFile = home.join("pid-${sequence}")
                let environment = HashMap<String, String>()
                environment["PATH"] = "/bin:/usr/bin"; environment["LANG"] = "C"
                environment["METIS_CAPTURE_VALUE"] = "中文😀-${sequence}"
                let script = "[ \"$PATH\" = '/bin:/usr/bin' ] && [ \"$METIS_CAPTURE_VALUE\" = \"$3\" ] && [ \"$PWD\" = \"$4\" ] || exit 63; /bin/ps -o pgid= -p $$ > \"$1\"; printf '%s' \"$$\" > \"$2\"; dd bs=${expectedInput.size} count=1 2>/dev/null; printf '错误😀\\000\\376' >&2; exit 7"
                let arguments = ["-c", script, "fixture", groupFile.toString(), pidFile.toString(), environment["METIS_CAPTURE_VALUE"], home.toString()]
                let result = if (mode == "sdk") {
                    executeWithOutput("sh", arguments, workingDirectory: Some(home), environment: Some<Map<String, String>>(environment))
                } else {
                    managedRecoveryExecuteWithOutput("sh", arguments, workingDirectory: Some(home), environment: Some<Map<String, String>>(environment))
                }
                captureNoContextCheck(result[0] == 7)
                captureNoContextCheck(result[1] == expectedInput && result[2] == expectedError.toArray())
                captureNoContextCheck(Int64.parse(captureNoContextRead(groupFile).trimAscii()) == group)
                let pid = Int64.parse(captureNoContextRead(pidFile))
                captureNoContextCheck(pid > 1 && unsafe { getpgid(Int32(pid)) } == -1)
                stdout.add(all: result[1]); stderr.add(all: result[2])
                if (mode == "public") { captureNoContextCheck(ownedTestFdCount() == baseline) }
                completed += 1
            }
            captureNoContextCheck(completed == 100)
            let emptyEnvironment = HashMap<String, String>()
            emptyEnvironment[""] = "固定合成中文😀"
            let emptyResult = if (mode == "sdk") {
                executeWithOutput("/usr/bin/env", [], environment: Some<Map<String, String>>(emptyEnvironment))
            } else {
                managedRecoveryExecuteWithOutput("/usr/bin/env", [], environment: Some<Map<String, String>>(emptyEnvironment))
            }
            emptyEnvironmentKey = emptyResult[0] == 0 && emptyResult[1] == "=固定合成中文😀\n".toArray() && emptyResult[2].isEmpty()
            captureNoContextCheck(emptyEnvironmentKey)
            if (mode == "public") { captureNoContextCheck(ownedTestFdCount() == baseline) }
            File.writeTo(home.join("captured.stdout"), stdout.toArray())
            File.writeTo(home.join("captured.stderr"), stderr.toArray())
        }
        passed = true
    } finally {
        proof.put("formalOk", JsonBool(passed)); proof.put("recordedBeforeFallback", JsonBool(true))
        proof.put("completed", JsonInt(completed)); proof.put("mode", JsonString(mode))
        proof.put("invalidDirectoryExceptions", JsonInt(invalidDirectoryExceptions))
        proof.put("missingCommandExceptions", JsonInt(missingCommandExceptions))
        proof.put("emptyEnvironmentKey", JsonBool(emptyEnvironmentKey))
        proof.put("warmFd", JsonInt(baseline)); proof.put("finalFd", JsonInt(ownedTestFdCount()))
        File.writeTo(home.join("child-formal.json"), proof.toJsonString().toArray())
    }
}

@When[os == "macOS"]
private func captureNoContextParent(negative: Bool, testName: String): Unit {
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let children = ArrayList<ManagedOwnedChild>()
    var passed = false
    let formal = JsonObject(); formal.put("formalOk", JsonBool(false))
    try {
        let modes = if (negative) { ["negative"] } else { ["sdk", "public"] }
        for (mode in modes) {
            let directory = home.join(mode); Directory.create(directory)
            File.writeTo(directory.join("owner"), ("capture-without-context-v1\n" + nonce).toArray())
            let inputBytes = ArrayList<Byte>()
            for (_ in 0..100) { inputBytes.add(all: captureNoContextInput()) }
            File.writeTo(directory.join("input"), inputBytes.toArray())
            let environment = HashMap<String, String>(getVariables())
            for (key in environment.keys().toArray()) {
                let upper = key.toAsciiUpper()
                if (key.startsWith("METIS_PROCESS_RECOVERY_") || upper.endsWith("_API_KEY") || upper.endsWith("_TOKEN") ||
                    upper.contains("PROXY") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL")) { environment.remove(key) }
            }
            environment["METIS_CAPTURE_TEST_HOME"] = directory.toString()
            environment["METIS_CAPTURE_TEST_NONCE"] = nonce; environment["METIS_CAPTURE_TEST_MODE"] = mode
            environment["METIS_HOME"] = directory.toString(); environment["METIS_LOG_FILE"] = directory.join("test.log").toString()
            try (input = File(directory.join("input"), OpenMode.Read), output = File(directory.join("stdout"), OpenMode.Write),
                error = File(directory.join("stderr"), OpenMode.Write)) {
                let child = launchManagedRawChild(getCommand(), ["--filter=ManagedCaptureWithoutContextTest.${testName}",
                    "--parallel=1", "--no-progress", "--no-color", "--no-capture-output"],
                    environment: Some<Map<String, String>>(environment), stdIn: ProcessRedirect.FromFile(input),
                    stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error), newGeneration: true)
                children.add(child)
                captureNoContextCheck(child.wait(timeout: Some(Duration.second * 60)) == 0)
                captureNoContextCheck(child.wait() == 0)
                child.closeStreams()
                captureNoContextCheck(!child.isAlive() && child.streamsAreClosed())
                captureNoContextCheck(!input.isClosed() && !output.isClosed() && !error.isClosed())
            }
            let proof = JsonValue.fromStr(captureNoContextRead(directory.join("child-formal.json"))).asObject()
            captureNoContextCheck(proof.get("formalOk").getOrThrow().asBool().getValue())
            captureNoContextCheck(proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue())
            captureNoContextCheck(proof.get("completed").getOrThrow().asInt().getValue() == if (negative) { 200 } else { 100 })
            if (!negative) { captureNoContextCheck(proof.get("emptyEnvironmentKey").getOrThrow().asBool().getValue()) }
        }
        if (!negative) {
            captureNoContextCheck(File.readFrom(home.join("sdk/captured.stdout")) == File.readFrom(home.join("public/captured.stdout")))
            captureNoContextCheck(File.readFrom(home.join("sdk/captured.stderr")) == File.readFrom(home.join("public/captured.stderr")))
        }
        passed = true; formal.put("formalOk", JsonBool(true))
        println("R-NATIVE-CAPTURE negative=${negative};formalBeforeFallback=true")
    } finally {
        formal.put("recordedBeforeFallback", JsonBool(true))
        var saved = false
        try { File.writeTo(home.join("parent-formal.json"), formal.toJsonString().toArray()); saved = true }
        finally {
            var terminal = true
            for (child in children) {
                try {
                    if (child.isAlive()) { child.terminate() }
                    let _ = child.wait(timeout: Some(Duration.second * 3)); child.closeStreams()
                    terminal = terminal && !child.isAlive() && child.streamsAreClosed()
                } catch (_: Exception) { terminal = false }
            }
            if (passed && saved && terminal) { remove(home, recursive: true) }
            else { println("R-NATIVE-CAPTURE owned_failure_evidence_retained terminal=${terminal}") }
        }
    }
}

@When[os == "macOS"]
@Test
public class ManagedCaptureWithoutContextTest {
    @TestCase
    public func nativeCaptureP1OneHundredPreserveInheritedInputGroupAndRawResults(): Unit {
        if (let Some(mode) <- getVariable("METIS_CAPTURE_TEST_MODE")) { captureNoContextChild(mode); return }
        captureNoContextParent(false, "nativeCaptureP1OneHundredPreserveInheritedInputGroupAndRawResults")
    }

    @TestCase
    public func nativeCaptureN1MissingCommandAndInvalidDirectoryDoNotLeak(): Unit {
        if (getVariable("METIS_CAPTURE_TEST_MODE") == Some("negative")) { captureNoContextChild("negative"); return }
        captureNoContextParent(true, "nativeCaptureN1MissingCommandAndInvalidDirectoryDoNotLeak")
    }
}
