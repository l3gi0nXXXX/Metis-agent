package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.env.{getCommand, getProcessId, getVariable, getVariables, setVariable, removeVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.io.InputStream
import std.convert.Parsable
import std.posix.chmod
import std.process.{ProcessRedirect, executeWithOutput}
import std.runtime.{gc, getGCCount, getThreadCount, getBlockingThreadCount}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func getpgid(pid: Int32): Int32
    func getrlimit(resource: Int32, value: CPointer<UInt64>): Int32
    func setrlimit(resource: Int32, value: CPointer<UInt64>): Int32
    func umask(mask: UInt16): UInt16
    func signal(code: Int32, handler: UIntNative): UIntNative
}

@When[os == "macOS"]
func ownedTestFdCount(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let size = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (size <= 0 || size >= 32768 || size % 8 != 0) { throw Exception("fixture_fd_snapshot_failed") }
        Int64(size / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedTestCollectPriorSdkFixtureGarbage(): Unit {
    let before = getGCCount()
    gc(heavy: true)
    let deadline = MonoTime.now() + Duration.second * 2
    var after = getGCCount()
    while (after <= before && MonoTime.now() < deadline) {
        sleep(Duration.millisecond)
        after = getGCCount()
    }
    if (after <= before) { throw Exception("fixture_prior_sdk_gc_not_observed") }
    println("native_fixture_gc before=${before} after=${after}")
}

private func ownedTestFdSummary(): String {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let size = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (size <= 0 || size >= 32768 || size % 8 != 0) { return "unknown" }
        let entries = ArrayList<String>()
        for (index in 0..Int64(size / 8)) {
            let value = unsafe { buffer.read(index) }
            entries.add("${value & 0xffffffff}:${value >> 32}:${managedNativeDescriptorIsNullForTest(Int32(value & 0xffffffff))}")
        }
        String.join(entries.toArray(), delimiter: ",")
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedTestReadAll(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        bytes.add(all: buffer[..count])
    }
    bytes.toArray()
}

private func ownedTestExpectCapture(actual: (Int64, Array<Byte>, Array<Byte>), expected: (Int64, Array<Byte>, Array<Byte>)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
    @Expect(actual[2], expected[2])
}

private func ownedTestContext(action: (Path, String) -> Unit): Unit {
    let directory = Path("/private/tmp/metis-owned-launch-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    let previous = managedRecoveryContext()
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    try {
        @Expect(managedRecoveryInitialize(directory, parent, "owned-launch-fixture"), true)
        action(directory, parent)
    } finally {
        let stopped = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
        setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", previous[0])
        setVariable("METIS_PROCESS_RECOVERY_PARENT", previous[1])
        if (stopped && exists(directory)) { remove(directory, recursive: true) }
    }
}

@When[os == "macOS"]
@Test
public class ManagedOwnedChildTest {
    @TestCase
    public func rS1LU1NativeGroupRawBytesAndExit(): Unit {
        let bytes = ArrayList<Byte>()
        for (_ in 0..8192) { bytes.add(all: "中文😀".toArray()); bytes.add(all: [0u8, 0xffu8, 0xfeu8, 0x80u8]) }
        let expected = bytes.toArray()
        let environment = HashMap<String, String>(getVariables())
        environment["METIS_OWNED_TEST_VALUE"] = "中文😀"
        let baselineDescriptors = ownedTestFdSummary()
        let baseline = ownedTestFdCount()
        let baselineGc = getGCCount()
        let child = managedNativeLaunch("/bin/sh", ["-c", "[ \"$METIS_OWNED_TEST_VALUE\" = '中文😀' ] && [ \"$PWD\" = '/private/tmp' ] || exit 63; cat; printf 'stderr中文😀' >&2; exit 7"],
            Some(Path("/private/tmp")), Some<Map<String, String>>(environment), [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Pipe])
        let stdout = spawn { ownedTestReadAll(child.stdOutPipe) }
        let stderr = spawn { ownedTestReadAll(child.stdErrPipe) }
        try {
            @Expect(Int64(unsafe { getpgid(Int32(child.pid)) }), child.pid)
            child.stdInPipe.write(expected)
            child.closeInput()
            @Expect(child.wait(timeout: Some(Duration.second * 5)), 7)
            @Expect(child.wait(), 7)
            @Expect(stdout.get(Duration.second * 5), expected)
            @Expect(stderr.get(Duration.second * 5), "stderr中文😀".toArray())
        } finally {
            if (child.isAlive()) { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second * 5)) }
            child.closeStreams()
            let _ = stdout.get(Duration.second * 5)
            let _ = stderr.get(Duration.second * 5)
        }
        let finalFd = ownedTestFdCount()
        if (finalFd != baseline) {
            println("native_raw_fd_mismatch before=${baselineDescriptors} after=${ownedTestFdSummary()} gcBefore=${baselineGc} gcAfter=${getGCCount()}")
        }
        @Expect(finalFd, baseline)
    }

    @TestCase
    public func rS1LP1HundredOwnedCapturesAreTerminal(): Unit {
        ownedTestContext({ directory, parent =>
            ownedTestCollectPriorSdkFixtureGarbage()
            let baseline = ownedTestFdCount()
            let baselineDescriptors = ownedTestFdSummary()
            for (sequence in 0..100) {
                let output = try { managedRecoveryExecuteWithOutput("/bin/sh", ["-c", "[ ! -e /dev/fd/3 ] || exit 64; printf '中文😀'; printf '\\377\\000' >&2; exit 7"]) }
                catch (error: Exception) {
                    let proof = managedRecoveryProbeRecords(directory, parent, "owned-launch-fixture", MonoTime.now() + Duration.second)
                    println("native_capture_failed sequence=${sequence} inventoryStatus=${proof.status}")
                    throw error
                }
                @Expect(output[0], 7)
                @Expect(output[1], "中文😀".toArray())
                @Expect(output[2], [0xffu8, 0u8])
            }
            let proof = managedRecoveryProbeRecords(directory, parent, "owned-launch-fixture", MonoTime.now() + Duration.second)
            @Expect(proof.ok && proof.terminal, true)
            if (ownedTestFdCount() != baseline) { println("native_hundred_fd_mismatch before=${baselineDescriptors} after=${ownedTestFdSummary()}") }
            @Expect(ownedTestFdCount(), baseline)
        })
    }

    @TestCase
    public func rS1LB1SpawnFailureReleasesEveryOwnedPipe(): Unit {
        let baseline = ownedTestFdCount()
        for (_ in 0..100) {
            var failed = false
            try {
                let _ = managedNativeLaunch("/metis-fixture-does-not-exist", [], None, None,
                    [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Pipe])
            } catch (_: Exception) { failed = true }
            @Expect(failed, true)
        }
        @Expect(ownedTestFdCount(), baseline)
    }

    @TestCase
    public func rS1LB1AttributeAndActionFailuresReleaseAllocatedPipes(): Unit {
        let baseline = ownedTestFdCount()
        let marker = Path("/private/tmp/metis-owned-no-spawn-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try {
            for (fault in [ManagedNativeLaunchFault.InvalidProcessGroup, ManagedNativeLaunchFault.InvalidDupAction]) {
                for (_ in 0..100) {
                    var status = ""
                    try {
                        let _ = managedNativeLaunch("/usr/bin/touch", [marker.toString()], None, None,
                            [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Pipe], fault: fault)
                    } catch (error: Exception) { status = error.message }
                    let expected = match (fault) {
                        case ManagedNativeLaunchFault.InvalidProcessGroup => "owned_process_attributes_failed"
                        case _ => "owned_process_actions_failed"
                    }
                    @Expect(status, expected)
                    @Expect(exists(marker), false)
                    @Expect(ownedTestFdCount(), baseline)
                    for (descriptor in 0..3) { @Expect(unsafe { fcntl(Int32(descriptor), 1) } >= 0, true) }
                }
            }
        } finally { if (exists(marker)) { remove(marker) } }
    }

    @TestCase
    public func rS1LN1ClosedPeerWriteDoesNotSignalTheHost(): Unit {
        let baseline = ownedTestFdCount()
        let child = try { managedNativeLaunch("/usr/bin/true", [], None, None,
            [ProcessRedirect.Pipe, ProcessRedirect.Discard, ProcessRedirect.Discard]) } catch (error: ManagedNativeSpawnException) {
            println("native_spawn_failed code=${error.errorCode}")
            throw error
        }
        try {
            @Expect(child.wait(timeout: Some(Duration.second)), 0)
            var status = ""
            try { child.stdInPipe.write([0xffu8, 0u8]) } catch (error: Exception) { status = error.message }
            @Expect(status, "owned_process_write_failed")
        } finally { child.closeStreams() }
        @Expect(ownedTestFdCount(), baseline)
    }

    @TestCase
    public func rS1LN1TimeoutStopAndReapStayOwned(): Unit {
        ownedTestContext({ directory, parent =>
            let baseline = ownedTestFdCount()
            let child = managedRecoveryLaunchOwned("/bin/sleep", ["30"], stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            var timedOut = false
            try { let _ = child.wait(timeout: Some(Duration.millisecond * 5)) }
            catch (_: TimeoutException) { timedOut = true }
            @Expect(timedOut, true)
            @Expect(managedRecoveryStopOwnedChildren(managedRecoveryContext(), MonoTime.now() + Duration.second * 5), true)
            @Expect(child.isAlive(), false)
            var rejected = false
            try { let _ = managedRecoveryLaunchOwned("/bin/true", []) } catch (_: Exception) { rejected = true }
            @Expect(rejected, true)
            @Expect(managedRecoveryProbeRecords(directory, parent, "owned-launch-fixture", MonoTime.now() + Duration.second).terminal, true)
            @Expect(ownedTestFdCount(), baseline)
        })
    }

    @TestCase
    public func rS1LB2UnassignedSiblingPipeIsNotInherited(): Unit {
        let baseline = ownedTestFdCount()
        let first = managedNativeLaunch("/bin/cat", [], None, None,
            [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Discard])
        let second = managedNativeLaunch("/bin/sleep", ["30"], None, None,
            [ProcessRedirect.Discard, ProcessRedirect.Discard, ProcessRedirect.Discard])
        try {
            first.closeInput()
            @Expect(first.wait(timeout: Some(Duration.second)), 0)
            @Expect(second.isAlive(), true)
        } finally {
            first.closeStreams()
            if (first.isAlive()) { first.terminate(force: true); let _ = first.wait(timeout: Some(Duration.second)) }
            second.terminate(force: true); let _ = second.wait(timeout: Some(Duration.second)); second.closeStreams()
        }
        @Expect(ownedTestFdCount(), baseline)
    }

    @TestCase
    public func rS1LN2EmfileKeepsExistingPipesAndPartialFailureOwned(): Unit {
        let marker = getVariable("METIS_OWNED_NATIVE_TEST_CHILD").getOrDefault({ => "" })
        if (marker == "emfile") { ownedTestEmfileChild(); return }
        var before = VArray<UInt64, $2>(repeat: 0)
        var after = VArray<UInt64, $2>(repeat: 0)
        @Expect(unsafe { getrlimit(8, inout before) }, 0)
        let environment = HashMap<String, String>(getVariables())
        environment["METIS_OWNED_NATIVE_TEST_CHILD"] = "emfile"
        let result = executeWithOutput(getCommand(),
            ["--filter=ManagedOwnedChildTest.rS1LN2EmfileKeepsExistingPipesAndPartialFailureOwned"], environment: environment)
        @Expect(result[0], 0)
        @Expect(unsafe { getrlimit(8, inout after) }, 0)
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }

    @TestCase
    public func rS1LU2OwnershipMetadataIsPrivateAndReadable(): Unit {
        if (getVariable("METIS_OWNED_NATIVE_TEST_CHILD").getOrDefault({ => "" }) == "permissions") {
            let previousMask = unsafe { umask(UInt16(0o777)) }
            try {
                ownedTestContext({ directory, parent =>
                    let key = managedRecoveryNativeIntent()
                    let paths = [directory.join("inventory"), directory.join(".issued"),
                        directory.join(".resource-claim"), directory.join("${key}.intent")]
                    for (path in paths) {
                        let mode = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", path.toString()])
                        @Expect(mode[0], 0)
                        let text = try { String.fromUtf8(mode[1]).trimAscii() } catch (_: Exception) { "invalid_response_encoding" }
                        @Expect(text, "600")
                        @Expect(managedRecoveryReadText(path).isSome(), true)
                        let name = unsafe { LibC.mallocCString(path.toString()) }
                        try {
                            let descriptor = processOpenNativeFile(name, 2, 0)
                            @Expect(descriptor >= 0, true)
                            if (descriptor >= 0) { let _ = unsafe { close(descriptor) } }
                        } finally { unsafe { LibC.free(name) } }
                    }
                    managedRecoveryNativeTerminal(key, 0, 0, false, true)
                    @Expect(managedRecoveryProbeRecords(directory, parent, "owned-launch-fixture", MonoTime.now() + Duration.second).terminal, true)
                })
            } finally { let _ = unsafe { umask(previousMask) } }
            return
        }
        let environment = HashMap<String, String>(getVariables())
        environment["METIS_OWNED_NATIVE_TEST_CHILD"] = "permissions"
        let result = executeWithOutput(getCommand(),
            ["--filter=ManagedOwnedChildTest.rS1LU2OwnershipMetadataIsPrivateAndReadable"], environment: environment)
        @Expect(result[0], 0)
    }
    @TestCase
    public func rS1LN2BlockingReadCloseDefersDescriptorReuse(): Unit {
        ownedTestCollectPriorSdkFixtureGarbage()
        let baseline = ownedTestFdCount()
        let baselineDescriptors = ownedTestFdSummary()
        let child = managedNativeLaunch("/bin/cat", [], None, None,
            [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Discard])
        let stream = child.stdOutPipe
        let oldDescriptor = managedNativePipeStateForTest(stream)[1]
        let buffer = Array<Byte>(32, repeat: 0)
        let reader = spawn { stream.read(buffer) }
        let name = unsafe { LibC.mallocCString("/dev/null") }
        var opened: Int32 = -1
        var replacement: Int32 = -1
        try {
            let deadline = MonoTime.now() + Duration.second * 2
            while (managedNativePipeStateForTest(stream)[0] != 1 && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(managedNativePipeStateForTest(stream)[0], 1)
            (stream as Resource).getOrThrow().close()
            @Expect(managedNativePipeStateForTest(stream)[1], oldDescriptor)
            opened = processOpenNativeFile(name, 0, 0)
            @Expect(opened >= 0 && opened != oldDescriptor, true)
            let expected = "唤醒😀".toArray()
            child.stdInPipe.write(expected)
            @Expect(reader.get(Duration.second * 2), expected.size)
            @Expect(buffer[..expected.size], expected)
            @Expect(managedNativePipeStateForTest(stream)[1], -1)
            replacement = managedNativeDuplicateAtLeast(opened, oldDescriptor)
            @Expect(replacement, oldDescriptor)
            child.closeStreams()
            @Expect(unsafe { fcntl(replacement, 1) } >= 0, true)
            @Expect(child.wait(timeout: Some(Duration.second * 2)), 0)
        } finally {
            child.closeInput()
            if (child.isAlive()) { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second * 2)) }
            child.closeStreams()
            let _ = reader.get(Duration.second * 2)
            if (opened >= 0) { let _ = unsafe { close(opened) } }
            if (replacement >= 0) { let _ = unsafe { close(replacement) } }
            unsafe { LibC.free(name) }
        }
        if (ownedTestFdCount() != baseline) { println("native_close_fd_mismatch before=${baselineDescriptors} after=${ownedTestFdSummary()}") }
        @Expect(ownedTestFdCount(), baseline)
    }

    @TestCase
    public func lH1ExplicitHandoffSurvivesOldFenceAndKeepsRawBytes(): Unit {
        ownedTestContext({ directory, parent =>
            let baseline = ownedTestFdCount()
            let ready = directory.join("handoff-ready")
            let release = directory.join("handoff-release")
            let script = "const fs=require('fs');for(const k of ['DIRECTORY','PARENT','BROKER_KEY','OWNER_PID','OWNER_BIRTH'])if(process.env['METIS_PROCESS_RECOVERY_'+k]!==undefined)process.exit(61);fs.writeFileSync(process.argv[1],String(process.pid));const timer=setInterval(()=>{if(!fs.existsSync(process.argv[2]))return;clearInterval(timer);process.stdout.write(Buffer.concat([Buffer.from('中文😀'),Buffer.from([0,255,254,128])]));process.stderr.write(Buffer.from([255,0]));process.exitCode=7;},10)"
            let captured = spawn { managedRecoveryExecuteHandoffWithOutput("node", ["-e", script, ready.toString(), release.toString()]) }
            try {
                let deadline = MonoTime.now() + Duration.second * 5
                while (!exists(ready) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                @Expect(exists(ready), true)
                let text = try { String.fromUtf8(File.readFrom(ready)) } catch (_: Exception) { throw Exception("handoff_marker_invalid_encoding") }
                let pid = Int64.parse(text)
                @Expect(Int64(unsafe { getpgid(Int32(pid)) }), pid)
                @Expect(managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second), true)
                @Expect(observeProcessBirthIdentity(pid).isSome(), true)
                @Expect(exists(directory.join(".issued")), false)
                File.writeTo(release, [1u8])
                let result = captured.get(Duration.second * 5)
                @Expect(result[0], 7)
                let expected = ArrayList<Byte>("中文😀".toArray())
                expected.add(all: [0u8, 0xffu8, 0xfeu8, 0x80u8])
                @Expect(result[1], expected.toArray())
                @Expect(result[2], [0xffu8, 0u8])
                @Expect(observeProcessBirthIdentity(pid).isNone(), true)
            } finally {
                File.writeTo(release, [1u8])
                let _ = captured.get(Duration.second * 5)
            }
            @Expect(ownedTestFdCount(), baseline)
        })
    }

    @TestCase
    public func rS1LN2ClosedStdinElevationAndInheritedOutput(): Unit {
        if (getVariable("METIS_OWNED_NATIVE_TEST_CHILD").getOrDefault({ => "" }) == "closed-stdio") {
            @Expect(unsafe { close(0) }, 0)
            let baseline = ownedTestFdCount()
            let child = managedNativeLaunch("/bin/cat", [], None, None,
                [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Discard])
            let bytes = "低描述符😀".toArray()
            let reader = spawn { ownedTestReadAll(child.stdOutPipe) }
            try {
                child.stdInPipe.write(bytes); child.closeInput()
                @Expect(child.wait(timeout: Some(Duration.second * 2)), 0)
                @Expect(reader.get(Duration.second * 2), bytes)
            } finally { child.closeStreams(); let _ = reader.get(Duration.second * 2) }
            @Expect(ownedTestFdCount(), baseline)
            let inherited = managedNativeLaunch("/bin/sh", ["-c", "printf 'owned_inherit_stdout'; printf 'owned_inherit_stderr' >&2"],
                None, None, [ProcessRedirect.Inherit, ProcessRedirect.Inherit, ProcessRedirect.Inherit])
            try { @Expect(inherited.wait(timeout: Some(Duration.second * 2)), 0) } finally { inherited.closeStreams() }
            @Expect(ownedTestFdCount(), baseline)
            @Expect(unsafe { fcntl(0, 1) }, -1)
            @Expect(unsafe { __error().read() }, 9)
            return
        }
        let baseline = ownedTestFdCount()
        let environment = HashMap<String, String>(getVariables())
        environment["METIS_OWNED_NATIVE_TEST_CHILD"] = "closed-stdio"
        let child = managedNativeLaunch(getCommand(), ["--filter=ManagedOwnedChildTest.rS1LN2ClosedStdinElevationAndInheritedOutput"],
            None, Some<Map<String, String>>(environment), [ProcessRedirect.Discard, ProcessRedirect.Pipe, ProcessRedirect.Pipe])
        let stdout = spawn { ownedTestReadAll(child.stdOutPipe) }
        let stderr = spawn { ownedTestReadAll(child.stdErrPipe) }
        try {
            @Expect(child.wait(timeout: Some(Duration.second * 10)), 0)
            let out = try { String.fromUtf8(stdout.get(Duration.second * 2)) } catch (_: Exception) { "invalid_response_encoding" }
            let err = try { String.fromUtf8(stderr.get(Duration.second * 2)) } catch (_: Exception) { "invalid_response_encoding" }
            @Expect(out.contains("owned_inherit_stdout"), true)
            @Expect(err.contains("owned_inherit_stderr"), true)
        } finally {
            if (child.isAlive()) { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second * 2)) }
            child.closeStreams(); let _ = stdout.get(Duration.second * 2); let _ = stderr.get(Duration.second * 2)
        }
        @Expect(ownedTestFdCount(), baseline)
    }

    @TestCase
    public func lCompatEnvironmentPathTextAndSignals(): Unit {
        let directory = Path("/private/tmp/metis-native-compat-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let priorPath = getVariable("PATH")
        let controls = ArrayList<(String, Array<String>, ?Map<String, String>, ?Path, (Int64, Array<Byte>, Array<Byte>))>()
        Directory.create(directory, recursive: true)
        try {
            for (label in ["A", "B"]) {
                let bin = directory.join(label)
                Directory.create(bin)
                let command = bin.join("metis-owned-compat-command")
                File.writeTo(command, "printf '${label}中文😀'; exit 7\n".toArray())
                chmod(command.toString(), 0o700)
                for (path in [bin.toString(), ""]) {
                    let environment = HashMap<String, String>(getVariables())
                    environment["PATH"] = path
                    let cwd = if (path.isEmpty()) { Some(bin) } else { None<Path> }
                    let expected = executeWithOutput("metis-owned-compat-command", [], workingDirectory: cwd, environment: environment)
                    @Expect(expected[0], 7)
                    @Expect(expected[1], "${label}中文😀".toArray())
                    controls.add(("metis-owned-compat-command", [], Some<Map<String, String>>(HashMap<String, String>(environment)), cwd, expected))
                    @Expect(getVariable("PATH"), priorPath)
                }
            }
            for (signal in ["TERM", "KILL"]) {
                let arguments = ["-c", "kill -${signal} $$"]
                let expected = executeWithOutput("/bin/sh", arguments)
                @Expect(expected[0], if (signal == "TERM") { 15 } else { 9 })
                controls.add(("/bin/sh", arguments, None, None, expected))
            }
            // Isolate SDK controls' GC-owned /dev/null files before measuring any native IO.
            ownedTestCollectPriorSdkFixtureGarbage()
            for ((command, arguments, environment, cwd, expected) in controls) {
                ownedTestExpectCapture(ownedTestNativeCapture(command, arguments, environment, cwd: cwd), expected)
                ownedTestContext({ _, _ =>
                    ownedTestExpectCapture(managedRecoveryExecuteWithOutput(command, arguments,
                        workingDirectory: cwd, environment: environment), expected)
                })
                @Expect(getVariable("PATH"), priorPath)
            }
        } finally { remove(directory, recursive: true) }
    }

    @TestCase
    public func lN3BrokerHandshakeFailureReapsAndJoins(): Unit {
        ownedTestContext({ directory, parent =>
            ownedTestCollectPriorSdkFixtureGarbage()
            let baseline = ownedTestFdCount()
            let baselineDescriptors = ownedTestFdSummary()
            for (mode in ["eof", "timeout"]) {
                for (round in 0..4) {
                    let script = directory.join("hello-${mode}-${round}.mjs")
                    let ready = directory.join("hello-${mode}-${round}.ready")
                    let release = directory.join("hello-${mode}-${round}.release")
                    File.writeTo(script, ("import{StdioBroker}from'file://${managedStdioResolveBrokerScriptPath()}';import{writeFileSync,existsSync}from'node:fs';new StdioBroker();writeFileSync('${ready.toString()}',String(process.pid)+'\\n'+process.env.METIS_PROCESS_RECOVERY_BROKER_KEY);setInterval(()=>{if('${mode}'==='eof'&&existsSync('${release.toString()}'))process.exit(0)},5);\n").toArray())
                    let client = ManagedStdioBrokerClient(brokerScriptPath: script.toString())
                    let start = spawn { client.ensureBrokerRunning(timeoutMs: 500) }
                    try {
                        let deadline = MonoTime.now() + Duration.second * 2
                        while (!exists(ready) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                        @Expect(exists(ready), true)
                        let text = try { String.fromUtf8(File.readFrom(ready)) } catch (_: Exception) { throw Exception("broker_fixture_invalid_encoding") }
                        let fields = text.split("\n")
                        @Expect(fields.size, 2)
                        let pid = Int64.parse(fields[0])
                        let birth = observeProcessBirthIdentity(pid).getOrThrow()
                        @Expect(managedRecoveryPublishFact(directory, fields[1], "birth", parent, pid: pid, birth: birth.serialize()), true)
                        File.writeTo(release, [1u8])
                        @Expect(start.get(Duration.second * 5).ok, false)
                        @Expect(client.snapshot().running, false)
                        @Expect(client.snapshot().readerCount, 0)
                        @Expect(client.snapshot().dispatcherCount, 0)
                        @Expect(observeProcessBirthIdentity(pid).isNone(), true)
                        if (ownedTestFdCount() != baseline) { println("native_hello_fd_mismatch mode=${mode} round=${round} before=${baselineDescriptors} after=${ownedTestFdSummary()}") }
                        @Expect(ownedTestFdCount(), baseline)
                    } finally {
                        File.writeTo(release, [1u8])
                        let _ = start.get(Duration.second * 5)
                        let _ = client.close()
                    }
                }
            }
        })
    }

    @TestCase
    public func rS1LB2NativeNestedOuterGroupHardKill(): Unit {
        if (getVariable("METIS_OWNED_NATIVE_TEST_CHILD").getOrDefault({ => "" }) == "outer-group") {
            let _ = unsafe { signal(15, UIntNative(1)) }
            let ready = getVariable("METIS_OWNED_OUTER_READY").getOrThrow()
            let helper = getVariable("METIS_OWNED_OUTER_HELPER").getOrThrow()
            let script = "process.on('SIGTERM',()=>{});const c=require('child_process').spawn(process.execPath,['-e',\"process.on('SIGTERM',()=>{});setInterval(()=>{},1000)\"],{stdio:'ignore'});c.once('spawn',()=>require('fs').writeFileSync(process.argv[1],[process.pid,c.pid,process.env.METIS_PROCESS_RECOVERY_OWNER_PID,process.env.METIS_PROCESS_RECOVERY_OWNER_BIRTH].join('\\n')));setInterval(()=>{},1000)"
            let child = managedRecoveryLaunchOwned("node", ["-e", script, ready])
            File.writeTo(Path(helper), child.pid.toString().toArray())
            sleep(Duration.second * 60)
            child.terminate(); let _ = child.wait(timeout: Some(Duration.second * 5)); child.closeStreams()
            return
        }
        ownedTestContext({ directory, parent =>
            let baseline = ownedTestFdCount()
            let fixture = Path("${directory.toString()}-fixture")
            Directory.create(fixture)
            let ready = fixture.join("outer-ready")
            let helper = fixture.join("outer-helper")
            let environment = HashMap<String, String>(getVariables())
            environment["METIS_OWNED_NATIVE_TEST_CHILD"] = "outer-group"
            environment["METIS_OWNED_OUTER_READY"] = ready.toString()
            environment["METIS_OWNED_OUTER_HELPER"] = helper.toString()
            let outer = managedNativeLaunch(getCommand(), ["--filter=ManagedOwnedChildTest.rS1LB2NativeNestedOuterGroupHardKill"],
                None, Some<Map<String, String>>(environment), [ProcessRedirect.Discard, ProcessRedirect.Discard, ProcessRedirect.Discard])
            let captured = ArrayList<ProcessBirthIdentity>()
            try {
                @Expect(Int64(unsafe { getpgid(Int32(outer.pid)) }), outer.pid)
                let outerBirth = observeProcessBirthIdentity(outer.pid).getOrThrow()
                let deadline = MonoTime.now() + Duration.second * 5
                while ((!exists(ready) || !exists(helper)) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                @Expect(exists(ready) && exists(helper), true)
                let values = try { String.fromUtf8(File.readFrom(ready)).split("\n") }
                    catch (_: Exception) { throw Exception("outer_fixture_invalid_encoding") }
                let helperText = try { String.fromUtf8(File.readFrom(helper)) }
                    catch (_: Exception) { throw Exception("outer_fixture_invalid_encoding") }
                let helperPid = Int64.parse(helperText)
                @Expect(values[2], outer.pid.toString())
                @Expect(values[3], outerBirth.serialize())
                let businessPid = Int64.parse(values[0]); let grandPid = Int64.parse(values[1])
                for (pid in [helperPid, businessPid, grandPid]) { captured.add(observeProcessBirthIdentity(pid).getOrThrow()) }
                @Expect(Int64(unsafe { getpgid(Int32(helperPid)) }), helperPid)
                @Expect(helperPid != outer.pid, true)
                @Expect(Int64(unsafe { getpgid(Int32(businessPid)) }), businessPid)
                @Expect(Int64(unsafe { getpgid(Int32(grandPid)) }), businessPid)
                @Expect(unsafe { kill(-Int32(outer.pid), 15) }, 0)
                sleep(Duration.millisecond * 250)
                @Expect(unsafe { kill(-Int32(outer.pid), 9) }, 0)
                @Expect(outer.wait(timeout: Some(Duration.second * 2)), 9)
                let terminalDeadline = MonoTime.now() + Duration.second * 5
                var gone = false
                while (MonoTime.now() < terminalDeadline) {
                    gone = true
                    for (birth in captured) { if (observeProcessBirthIdentity(birth.pid).isSome()) { gone = false } }
                    if (gone) { break }
                    sleep(Duration.millisecond * 10)
                }
                @Expect(gone, true)
                let proof = managedRecoveryProbeRecords(directory, parent, "owned-launch-fixture", terminalDeadline)
                println("native_outer_formal gone=${gone} inventoryStatus=${proof.status} terminal=${proof.terminal} fixtureReadyInsideInventory=${exists(directory.join("outer-ready"))} fixtureHelperInsideInventory=${exists(directory.join("outer-helper"))}")
                @Expect(proof.terminal, true)
            } finally {
                if (outer.isAlive()) { let _ = unsafe { kill(-Int32(outer.pid), 9) }; let _ = outer.wait(timeout: Some(Duration.second * 2)) }
                outer.closeStreams()
                // Formal assertions above run before any test-only fallback signal.
                for (birth in captured) {
                    if (observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize())) {
                        let _ = unsafe { kill(Int32(birth.pid), 9) }
                    }
                }
                var fixtureSettled = !outer.isAlive()
                for (birth in captured) { if (observeProcessBirthIdentity(birth.pid).isSome()) { fixtureSettled = false } }
                if (fixtureSettled && exists(fixture)) { remove(fixture, recursive: true) }
            }
            @Expect(ownedTestFdCount(), baseline)
        })
    }

    @TestCase
    public func lN2AfterSpawnFailureKeepsActualOwnershipPhase(): Unit {
        let directory = Path("/private/tmp/metis-after-spawn-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(directory)
        let ready = directory.join("grand-ready")
        let baseline = ownedTestFdCount()
        var grand = None<ProcessBirthIdentity>
        try {
            let script = "const c=require('child_process').spawn(process.execPath,['-e',\"setInterval(()=>{},1000)\"],{stdio:'ignore'});c.once('spawn',()=>{require('fs').writeFileSync(process.argv[1],String(c.pid));process.stdout.write('R')});setInterval(()=>{},1000)"
            var rejected = false
            try {
                let _ = managedNativeLaunch("node", ["-e", script, ready.toString()], None, None,
                    [ProcessRedirect.Discard, ProcessRedirect.Pipe, ProcessRedirect.Discard], fault: ManagedNativeLaunchFault.AfterSpawnSetup)
            } catch (error: ManagedNativeSetupException) {
                rejected = true
                @Expect(error.child.pid > 1, true)
                @Expect(error.birth.isSome(), true)
                @Expect(error.child.wait(timeout: Some(Duration.second)), 15)
                @Expect(error.child.streamsAreClosed(), true)
                let text = try { String.fromUtf8(File.readFrom(ready)) } catch (_: Exception) { throw Exception("after_spawn_fixture_invalid_encoding") }
                grand = observeProcessBirthIdentity(Int64.parse(text))
                // A reaped direct actor is not evidence that its still-live grandchild is terminal.
                @Expect(grand.isSome(), true)
            }
            @Expect(rejected, true)
            @Expect(ownedTestFdCount(), baseline)
        } finally {
            if (let Some(birth) <- grand) {
                if (observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize())) {
                    let _ = unsafe { kill(Int32(birth.pid), 9) }
                    let deadline = MonoTime.now() + Duration.second * 5
                    while (observeProcessBirthIdentity(birth.pid).isSome() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                }
            }
            remove(directory, recursive: true)
        }
        ownedTestContext({ contextDirectory, parent =>
            var rejected = false
            try {
                let _ = managedRecoveryLaunchInContext((contextDirectory.toString(), parent), "/bin/sleep", ["30"], None, None,
                    ProcessRedirect.Discard, ProcessRedirect.Discard, ProcessRedirect.Discard, fault: ManagedNativeLaunchFault.AfterSpawnSetup)
            } catch (error: ManagedNativeSetupException) {
                rejected = true
                @Expect(error.child.pid > 1, true)
                @Expect(error.child.isAlive(), false)
                @Expect(error.child.streamsAreClosed(), true)
                @Expect(exists(contextDirectory.join("r-1.not_spawned")), false)
                let proof = managedRecoveryProbeRecords(contextDirectory, parent, "owned-launch-fixture", MonoTime.now() + Duration.second)
                @Expect(proof.terminal || proof.status == "resources_unknown", true)
            }
            @Expect(rejected, true)
        })
    }

    @TestCase
    public func rS1LB3LateWaitAfterNativeReapAndRootCompaction(): Unit {
        for (code in [0, 7]) { ownedLateWaitScenario("positive", code) }
    }

    @TestCase
    public func rS1LN3CompactedWaitKeepsBindingCheckpointAndExecErrorsStrict(): Unit {
        for (mode in ["binding", "checkpoint", "source-spawned", "source-terminal", "exec-error"]) {
            ownedLateWaitScenario(mode, 7)
        }
    }

}

@When[os == "macOS"]
private func ownedTestEmfileChild(): Unit {
    var original = VArray<UInt64, $2>(repeat: 0)
    @Expect(unsafe { getrlimit(8, inout original) }, 0)
    let baseline = ownedTestFdCount()
    let child = managedNativeLaunch("/bin/cat", [], None, None,
        [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Discard])
    let held = ArrayList<Int32>()
    let nullPath = unsafe { LibC.mallocCString("/dev/null") }
    var exhausted = false
    try {
        var limited = VArray<UInt64, $2>(repeat: original[1])
        limited[0] = min(original[0], UInt64(baseline + 32))
        @Expect(unsafe { setrlimit(8, inout limited) }, 0)
        while (true) {
            let descriptor = unsafe { processOpenNativeFile(nullPath, Int32(0), UInt32(0)) }
            if (descriptor < 0) { exhausted = unsafe { __error().read() } == 24; break }
            held.add(descriptor)
        }
        @Expect(exhausted, true)
        child.stdInPipe.write([0xffu8, 0u8, 65u8])
        let echoed = Array<Byte>(3, repeat: 0)
        var used: Int64 = 0
        while (used < 3) { used += child.stdOutPipe.read(echoed[used..]) }
        @Expect(echoed, [0xffu8, 0u8, 65u8])
        // Leave room for exactly the first pipe; the second must fail with EMFILE
        // and release the first pair without touching a borrowed descriptor.
        for (_ in 0..3) { let _ = unsafe { close(held.remove(at: held.size - 1)) } }
        let beforeFailure = ownedTestFdCount()
        var failed = false
        try {
            let _ = managedNativeLaunch("/usr/bin/true", [], None, None,
                [ProcessRedirect.Pipe, ProcessRedirect.Pipe, ProcessRedirect.Pipe])
        } catch (_: Exception) { failed = true }
        @Expect(failed, true)
        @Expect(ownedTestFdCount(), beforeFailure)
        child.closeInput()
        @Expect(child.wait(timeout: Some(Duration.second)), 0)
        child.closeStreams()
    } finally {
        for (descriptor in held) { let _ = unsafe { close(descriptor) } }
        let _ = unsafe { setrlimit(8, inout original) }
        unsafe { LibC.free(nullPath) }
        if (child.isAlive()) { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second)) }
        child.closeStreams()
    }
    @Expect(ownedTestFdCount(), baseline)
}


@When[os == "macOS"]
private func ownedTestNativeCapture(command: String, args: Array<String>, environment: ?Map<String, String>, cwd!: ?Path = None): (Int64, Array<Byte>, Array<Byte>) {
    let baseline = ownedTestFdCount()
    let baselineDescriptors = ownedTestFdSummary()
    let child = managedNativeLaunch(command, args, cwd, environment,
        [ProcessRedirect.Discard, ProcessRedirect.Pipe, ProcessRedirect.Pipe])
    let stdout = spawn { ownedTestReadAll(child.stdOutPipe) }
    let stderr = spawn { ownedTestReadAll(child.stdErrPipe) }
    var result = (0i64, Array<Byte>(), Array<Byte>())
    try { result = (child.wait(timeout: Some(Duration.second * 5)), stdout.get(Duration.second * 2), stderr.get(Duration.second * 2)) }
    finally {
        if (child.isAlive()) { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second * 2)) }
        child.closeStreams(); let _ = stdout.get(Duration.second * 2); let _ = stderr.get(Duration.second * 2)
    }
    if (ownedTestFdCount() != baseline) { println("native_compat_fd_mismatch before=${baselineDescriptors} after=${ownedTestFdSummary()}") }
    @Expect(ownedTestFdCount(), baseline)
    result
}

@When[os == "macOS"]
private func ownedLateWaitStrictCheck(value: Bool): Unit {
    @Expect(value, true)
    if (!value) { throw Exception("owned_late_wait_contract_failed") }
}

@When[os == "macOS"]
private func ownedLateWaitReadText(path: Path): String {
    match (managedRecoveryReadText(path)) {
        case Some(value) => value
        case None => throw Exception("owned_late_wait_metadata_invalid")
    }
}

@When[os == "macOS"]
private func ownedLateWaitAwaitTerminal(child: ManagedOwnedChild, directory: Path, key: String,
    spawned: String, helperBirth: ProcessBirthIdentity, ownerBirth: ProcessBirthIdentity,
    ownerPgid: Int64, deadline: MonoTime): Unit {
    while (MonoTime.now() < deadline) {
        // On macOS this is a real waitpid(WNOHANG) reap in the underlying native
        // handle. It deliberately does not call/cache ManagedRecoveryChild.wait.
        if (!child.isAlive() && exists(directory.join("${key}.terminal"))) {
            ownedLateWaitStrictCheck(ownedLateWaitReadText(directory.join("${key}.terminal")) ==
                spawned.replace("phase:spawned\n", "phase:terminal\n"))
            let helper = probeProcessBirthIdentity(helperBirth, deadline)
            let owner = probeProcessBirthIdentity(ownerBirth, deadline)
            let groupGone = unsafe { kill(-Int32(ownerPgid), 0) } != 0 && unsafe { __error().read() } == 3
            if (helper.conclusive && helper.status == "gone" && !helper.alive &&
                owner.conclusive && owner.status == "gone" && !owner.alive && groupGone) { return }
        }
        sleep(Duration.millisecond * 5)
    }
    throw Exception("owned_late_wait_terminal_timeout")
}

@When[os == "macOS"]
private func ownedLateWaitScenario(mode: String, expectedCode: Int64): Unit {
    let nonce = "late-wait-${getProcessId()}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
    let home = Directory.createTemp("/private/tmp")
    let directory = home.join("inventory")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let context = (directory.toString(), parent)
    let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let handles = ArrayList<ManagedOwnedChild>()
    let hasB = mode != "source-spawned" && mode != "source-terminal"
    let execErrorCase = mode == "exec-error"
    var initialized = false
    var launchPending = false
    var nativeReaped = false
    var compactedBeforeWait = false
    var negativeRejected = false
    var wrapperWaited = false
    var cachedCode: Int64 = -1
    var bWaited = false
    var formal = false
    var proofSaved = false
    var cleanupTerminal = false
    var finalSource = false
    var finalResources = false
    var baselineFd: Int64 = -1
    var baselineTasks: Int64 = -1
    var baselineBlocking: Int64 = -1
    var finalFd: Int64 = -1
    var finalTasks: Int64 = -1
    var finalBlocking: Int64 = -1
    var restoreMutation = None<(Path, Array<Byte>)>
    var failure = None<Exception>
    var step = "initialize"
    try {
        File.writeTo(home.join("owned.owner"),
            "metis-owned-late-wait-v1\nnonce:${nonce}\ntestPid:${getProcessId()}\nmode:${mode}\n".toArray())
        println("owned_late_wait_evidence basename=${home.fileName}")
        ownedLateWaitStrictCheck(managedRecoveryInitialize(directory, parent, nonce))
        initialized = true
        baselineFd = ownedTestFdCount()
        baselineTasks = getThreadCount()
        baselineBlocking = getBlockingThreadCount()
        let environment = HashMap<String, String>(getVariables())
        for (name in ["HOME", "TMPDIR", "METIS_HOME"]) { environment[name] = home.toString() }
        for (name in ["NODE_OPTIONS", "BASH_ENV", "ENV"]) { environment.remove(name) }
        let script = "IFS= read -r released || exit 64; [ \"$released\" = release ] || exit 65; " +
            "printf '迟等中文😀\\000\\377'; printf '错误😀\\376' >&2; exit ${expectedCode}"
        File.writeTo(home.join("a.script.input"), script.toArray())
        step = "launch-a"
        launchPending = true
        let a = managedRecoveryLaunchInContext(context,
            if (execErrorCase) { home.join("missing-command").toString() } else { "/bin/sh" },
            if (execErrorCase) { Array<String>() } else { ["-c", script] }, None,
            Some<Map<String, String>>(environment),
            if (execErrorCase) { ProcessRedirect.Discard } else { ProcessRedirect.Pipe },
            ProcessRedirect.Pipe, ProcessRedirect.Pipe)
        handles.add(a)
        launchPending = false
        ownedLateWaitStrictCheck(managedRecoveryReadIssued(directory, parent) == 1)
        let key = "r-1"
        let ownerKey = "${key}-o-1"
        let spawned = ownedLateWaitReadText(directory.join("${key}.spawned"))
        let helperFields = managedRecoveryParseFields(spawned).getOrThrow()
        ownedLateWaitStrictCheck(helperFields["key"] == key && helperFields["parent"] == parent &&
            Int64.parse(helperFields["pid"]) == a.pid && helperFields["pgid"] == "0")
        ownedLateWaitStrictCheck(spawned ==
            "managed-recovery-v1\nkey:${key}\nphase:spawned\nparent:${parent}\npid:${a.pid}\npgid:0\nbirth:\n")
        let helperBirthText = ownedLateWaitReadText(directory.join("${key}.birth"))
        let helperBorn = managedRecoveryParseFields(helperBirthText).getOrThrow()
        let helperBirth = parseProcessBirthIdentity(helperBorn["birth"]).getOrThrow()
        ownedLateWaitStrictCheck(helperBirth.pid == a.pid && helperBirthText ==
            "managed-recovery-v1\nkey:${key}\nphase:birth\nparent:${parent}\npid:${a.pid}\npgid:0\nbirth:${helperBirth.serialize()}\n")
        let ownerSpawned = ownedLateWaitReadText(directory.join("${ownerKey}.spawned"))
        let ownerFields = managedRecoveryParseFields(ownerSpawned).getOrThrow()
        let ownerPid = Int64.parse(ownerFields["pid"])
        let ownerPgid = Int64.parse(ownerFields["pgid"])
        ownedLateWaitStrictCheck(ownerPid > 1 && ownerPid <= 2147483647 && ownerPgid == ownerPid &&
            ownerFields["key"] == ownerKey && ownerFields["parent"] == parent)
        ownedLateWaitStrictCheck(ownerSpawned ==
            "managed-recovery-v1\nkey:${ownerKey}\nphase:spawned\nparent:${parent}\npid:${ownerPid}\npgid:${ownerPgid}\nbirth:\n")
        let ownerBirthText = ownedLateWaitReadText(directory.join("${ownerKey}.birth"))
        let ownerBorn = managedRecoveryParseFields(ownerBirthText).getOrThrow()
        let ownerBirth = parseProcessBirthIdentity(ownerBorn["birth"]).getOrThrow()
        ownedLateWaitStrictCheck(ownerBirth.pid == ownerPid && ownerBirthText ==
            "managed-recovery-v1\nkey:${ownerKey}\nphase:birth\nparent:${parent}\npid:${ownerPid}\npgid:${ownerPgid}\nbirth:${ownerBirth.serialize()}\n")
        // The builtin-read barrier leaves both real births available before the
        // successful owner is compacted by the attached broker's own publisher.
        for (entry in Directory.readFrom(directory)) {
            ownedLateWaitStrictCheck(entry.isRegular() && !entry.isSymbolicLink() && entry.size <= 16384)
            File.writeTo(home.join("original-${entry.name}"), File.readFrom(entry.path))
        }
        if (!execErrorCase) {
            ownedLateWaitStrictCheck(Int64(unsafe { getpgid(Int32(ownerPid)) }) == ownerPgid)
            a.stdInPipe.write("release\n".toArray())
            a.closeInput()
        }
        step = "native-reap-before-wrapper-wait"
        ownedLateWaitAwaitTerminal(a, directory, key, spawned, helperBirth, ownerBirth,
            ownerPgid, MonoTime.now() + Duration.second * 5)
        nativeReaped = true
        for (entry in Directory.readFrom(directory)) {
            ownedLateWaitStrictCheck(entry.isRegular() && !entry.isSymbolicLink() && entry.size <= 16384)
            File.writeTo(home.join("terminal-${entry.name}"), File.readFrom(entry.path))
        }
        let rawOut = ownedTestReadAll(a.stdOutPipe)
        let rawErr = ownedTestReadAll(a.stdErrPipe)
        File.writeTo(home.join("a.stdout.bin"), rawOut)
        File.writeTo(home.join("a.stderr.bin"), rawErr)
        let expectedOut = ArrayList<Byte>()
        let expectedErr = ArrayList<Byte>()
        if (!execErrorCase) {
            expectedOut.add(all: "迟等中文😀".toArray()); expectedOut.add(all: [0u8, 0xffu8])
            expectedErr.add(all: "错误😀".toArray()); expectedErr.add(0xfeu8)
        }
        ownedLateWaitStrictCheck(rawOut == expectedOut.toArray() && rawErr == expectedErr.toArray())
        let errorText = if (execErrorCase) {
            let outcome = managedRecoveryReadExecError(directory, parent, nonce, ownerKey).getOrThrow()
            ownedLateWaitStrictCheck(outcome.phase == "exec" && outcome.error == 2)
            outcome.originalText
        } else { "" }
        if (execErrorCase) { File.writeTo(home.join("original-exec-error"), errorText.toArray()) }
        ownedLateWaitStrictCheck(!managedRecoveryReadRootCheckpoint(directory, parent).getOrThrow().covers(key))
        if (hasB) {
            step = "allocate-b-side-compaction"
            launchPending = true
            let b = managedRecoveryLaunchInContext(context, "/bin/sh", ["-c", "exit 0"], None,
                Some<Map<String, String>>(environment), ProcessRedirect.Discard, ProcessRedirect.Pipe, ProcessRedirect.Pipe)
            handles.add(b)
            launchPending = false
            ownedLateWaitStrictCheck(managedRecoveryReadIssued(directory, parent) == 2)
            let checkpoint = managedRecoveryReadRootCheckpoint(directory, parent).getOrThrow()
            if (execErrorCase) {
                ownedLateWaitStrictCheck(!checkpoint.covers(key) &&
                    ownedLateWaitReadText(directory.join("${ownerKey}.exec_error")) == errorText)
                for (suffix in ["intent", "spawned", "birth", "terminal"]) {
                    ownedLateWaitStrictCheck(exists(directory.join("${key}.${suffix}")))
                }
            } else {
                ownedLateWaitStrictCheck(checkpoint.covers(key))
                for (suffix in ["intent", "spawned", "birth", "terminal"]) {
                    ownedLateWaitStrictCheck(!exists(directory.join("${key}.${suffix}")))
                }
                compactedBeforeWait = true
                File.writeTo(home.join("compacted-before-wait.closed"),
                    File.readFrom(directory.join("roots.closed")))
            }
            step = "wait-b"
            let bDeadline = MonoTime.now() + Duration.second * 5
            try {
                let remaining = bDeadline - MonoTime.now()
                if (remaining <= Duration.Zero) { throw Exception("owned_late_wait_deadline") }
                ownedLateWaitStrictCheck(b.wait(timeout: Some(remaining)) == 0)
                let cachedRemaining = bDeadline - MonoTime.now()
                if (cachedRemaining <= Duration.Zero) { throw Exception("owned_late_wait_deadline") }
                ownedLateWaitStrictCheck(b.wait(timeout: Some(cachedRemaining)) == 0)
                bWaited = true
                ownedLateWaitStrictCheck(ownedTestReadAll(b.stdOutPipe).isEmpty() && ownedTestReadAll(b.stdErrPipe).isEmpty())
            } finally { b.closeStreams() }
            ownedLateWaitStrictCheck(b.streamsAreClosed())
            if (execErrorCase) {
                ownedLateWaitStrictCheck(ownedLateWaitReadText(directory.join("${ownerKey}.exec_error")) == errorText)
            }
        }
        if (mode != "positive" && !execErrorCase) {
            step = "negative-source-guard"
            let target = if (mode == "binding") { directory.join("inventory") }
                else if (mode == "checkpoint") { directory.join("roots.closed") }
                else if (mode == "source-spawned") { directory.join("${key}.spawned") }
                else { directory.join("${key}.terminal") }
            let original = File.readFrom(target)
            let text = ownedLateWaitReadText(target)
            let variant = if (mode == "binding") { text.replace("binding:${nonce}\n", "binding:wrong-binding\n") }
                else if (mode == "checkpoint") { text.replace("issued:2\n", "issued:3\n") }
                else { text.replace("pid:${a.pid}\n", "pid:${a.pid + 1}\n") }
            ownedLateWaitStrictCheck(variant.toArray() != original)
            File.writeTo(home.join("negative-original.bin"), original)
            File.writeTo(home.join("negative-variant.bin"), variant.toArray())
            restoreMutation = Some((target, original))
            File.writeTo(target, variant.toArray())
            let unchanged = HashMap<String, Array<Byte>>()
            for (entry in Directory.readFrom(directory)) { unchanged[entry.name] = File.readFrom(entry.path) }
            let rejectDeadline = MonoTime.now() + Duration.second * 5
            try {
                let remaining = rejectDeadline - MonoTime.now()
                if (remaining <= Duration.Zero) { throw Exception("owned_late_wait_deadline") }
                let _ = a.wait(timeout: Some(remaining))
            } catch (error: TimeoutException) { throw error }
            catch (_: Exception) { negativeRejected = true }
            finally { a.closeStreams() }
            ownedLateWaitStrictCheck(negativeRejected && MonoTime.now() <= rejectDeadline &&
                Directory.readFrom(directory).size == unchanged.size)
            for ((name, bytes) in unchanged) { ownedLateWaitStrictCheck(File.readFrom(directory.join(name)) == bytes) }
            File.writeTo(home.join("negative-before-restore.proof"),
                "metis-owned-late-wait-negative-v1\nmode:${mode}\nrejected:true\ninputUnchanged:true\n".toArray())
            File.writeTo(target, original)
            restoreMutation = None<(Path, Array<Byte>)>
        }
        step = "late-wrapper-wait"
        let aDeadline = MonoTime.now() + Duration.second * 5
        try {
            let remaining = aDeadline - MonoTime.now()
            if (remaining <= Duration.Zero) { throw Exception("owned_late_wait_deadline") }
            cachedCode = a.wait(timeout: Some(remaining))
            ownedLateWaitStrictCheck(cachedCode == if (execErrorCase) { 125 } else { expectedCode })
            let cachedRemaining = aDeadline - MonoTime.now()
            if (cachedRemaining <= Duration.Zero) { throw Exception("owned_late_wait_deadline") }
            ownedLateWaitStrictCheck(a.wait(timeout: Some(cachedRemaining)) == cachedCode)
            wrapperWaited = true
        } finally { a.closeStreams() }
        ownedLateWaitStrictCheck(a.streamsAreClosed())
        step = "formal-generation-drain"
        let drainDeadline = MonoTime.now() + Duration.second * 5
        ownedLateWaitStrictCheck(managedRecoveryStopOwnedChildren(context, drainDeadline) && MonoTime.now() <= drainDeadline)
        let resourceDeadline = MonoTime.now() + Duration.second * 2
        let source = managedRecoveryProbeRecords(directory, parent, nonce, resourceDeadline)
        finalSource = source.ok && source.terminal
        ownedLateWaitStrictCheck(finalSource)
        while (MonoTime.now() < resourceDeadline) {
            finalFd = ownedTestFdCount()
            finalTasks = getThreadCount()
            finalBlocking = getBlockingThreadCount()
            finalResources = finalFd == baselineFd && finalTasks <= baselineTasks && finalBlocking <= baselineBlocking
            if (finalResources) { break }
            sleep(Duration.millisecond * 5)
        }
        ownedLateWaitStrictCheck(finalResources && MonoTime.now() <= resourceDeadline)
        let finalCheckpoint = managedRecoveryReadRootCheckpoint(directory, parent).getOrThrow()
        ownedLateWaitStrictCheck(finalCheckpoint.covers(key) && (!hasB || finalCheckpoint.covers("r-2")) &&
            managedRecoveryReadIssued(directory, parent) == if (hasB) { 2 } else { 1 })
        formal = true
        step = "formal-complete"
    } catch (error: Exception) { failure = Some(error) }
    finally {
        try {
            File.writeTo(home.join("formal-before-fallback.proof"),
                ("metis-owned-late-wait-formal-v1\nnonce:${nonce}\nmode:${mode}\nstep:${step}\n" +
                "formal:${formal}\nnativeReaped:${nativeReaped}\ncompactedBeforeWait:${compactedBeforeWait}\n" +
                "negativeRejected:${negativeRejected}\nwrapperWaited:${wrapperWaited}\ncachedCode:${cachedCode}\n" +
                "bWaited:${bWaited}\nlaunchPending:${launchPending}\nreturnedHandles:${handles.size}\n" +
                "sourceTerminal:${finalSource}\nresourcesReturned:${finalResources}\n" +
                "warmFd:${baselineFd}\nfinalFd:${finalFd}\nwarmCjTasks:${baselineTasks}\nfinalCjTasks:${finalTasks}\n" +
                "warmCjBlocking:${baselineBlocking}\nfinalCjBlocking:${finalBlocking}\nbodyFailed:${failure.isSome()}\n").toArray())
            proofSaved = true
        } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
        finally {
            let cleanupDeadline = MonoTime.now() + Duration.second * 5
            try {
                if (let Some(original) <- restoreMutation) {
                    try { File.writeTo(original[0], original[1]) }
                    catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                }
                for (child in handles) {
                    try {
                        try { if (child.isAlive()) { child.terminate() } }
                        catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                        let remaining = cleanupDeadline - MonoTime.now()
                        if (remaining <= Duration.Zero) { throw Exception("owned_late_wait_cleanup_pending") }
                        let _ = child.wait(timeout: Some(remaining))
                    } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                    finally {
                        try { child.closeStreams() }
                        catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                    }
                }
                var stopped = !initialized
                try {
                    if (initialized && MonoTime.now() < cleanupDeadline) {
                        stopped = managedRecoveryStopOwnedChildren(context, cleanupDeadline)
                    }
                } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                var streamsClosed = true
                for (child in handles) {
                    try { if (!child.streamsAreClosed()) { streamsClosed = false } }
                    catch (error: Exception) {
                        streamsClosed = false
                        if (failure.isNone()) { failure = Some(error) }
                    }
                }
                cleanupTerminal = stopped && streamsClosed && !launchPending && MonoTime.now() <= cleanupDeadline
                if (!cleanupTerminal && failure.isNone()) { failure = Some(Exception("owned_late_wait_cleanup_pending")) }
                try {
                    File.writeTo(home.join("cleanup-receipt.proof"),
                        "metis-owned-late-wait-cleanup-v1\nnonce:${nonce}\nterminal:${cleanupTerminal}\nproofSaved:${proofSaved}\n".toArray())
                } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
            } finally {
                try {
                    match (previousDirectory) {
                        case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value)
                        case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
                    }
                } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                finally {
                    try {
                        match (previousParent) {
                            case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value)
                            case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT")
                        }
                    } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
                }
            }
        }
    }
    try {
        ownedLateWaitStrictCheck(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY") == previousDirectory &&
            getVariable("METIS_PROCESS_RECOVERY_PARENT") == previousParent)
        File.writeTo(home.join("environment-restore.proof"),
            "metis-owned-late-wait-environment-v1\nnonce:${nonce}\ndirectoryOptionRestored:true\nparentOptionRestored:true\n".toArray())
    } catch (error: Exception) { if (failure.isNone()) { failure = Some(error) } }
    // Always retain this finite owned fixture, including successful negative
    // inputs. No fallback operation can promote formal or erase first failure.
    if (let Some(error) <- failure) { throw error }
    ownedLateWaitStrictCheck(formal && proofSaved && cleanupTerminal)
}
