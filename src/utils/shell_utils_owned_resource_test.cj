package metis.utils

import metis.process.{currentProcessInstanceIdentity, managedRecoveryInitialize, managedRecoveryStopOwnedChildren, managedRecoveryProbeRecords}
import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Path, File, Directory, exists, remove}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32 }

@When[os == "macOS"]
private func ownedFixtureFds(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("owned_fixture_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedFixtureContext(action: (Path, String) -> Unit): Unit {
    let directory = Path("/private/tmp/metis-caller-owned-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    let priorDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let priorParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    try {
        @Expect(managedRecoveryInitialize(directory, parent, "caller-fixture"), true)
        action(directory, parent)
    } finally {
        let terminal = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
        match (priorDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value)
            case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
        match (priorParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value)
            case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
        if (terminal && exists(directory)) { remove(directory, recursive: true) }
    }
}

@When[os == "macOS"]
@Test
public class ShellUtilsOwnedResourceTest {
    @TestCase
    public func lN3NoneAndInteractiveCloseEveryOwnedStream(): Unit {
        ownedFixtureContext({ directory, parent =>
            let warm = ShellUtils.execute(["/bin/sh", "-c", "exit 0"], withWrap: false, logFailures: false)
            @Expect(warm[0], 0)
            let baseline = ownedFixtureFds()
            for (_ in 0..8) {
                let value = ShellUtils.execute(["node", "-e", "process.stdout.write('中文😀'.repeat(32768));process.stderr.write('错误😀'.repeat(32768));process.exitCode=7"], withWrap: false, logFailures: false)
                @Expect(value[0], 7)
                @Expect(value[1], String.join(Array<String>(32768, repeat: "中文😀"), delimiter: ""))
                @Expect(value[2], String.join(Array<String>(32768, repeat: "错误😀"), delimiter: ""))
                for (fd in ["stdout", "stderr"]) {
                    let invalid = ShellUtils.execute(["node", "-e", "process.${fd}.write(Buffer.from([255,0,254]))"], withWrap: false, logFailures: false)
                    @Expect(invalid[0], SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE)
                    @Expect(invalid[2], SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC)
                }
                @Expect(ShellUtils.executeInteractive(["/bin/sh", "-c", "exit 7"], withWrap: false), 7)
                @Expect(ownedFixtureFds(), baseline)
            }
            var timedOut = false
            try { let _ = ShellUtils.executeInteractive(["/bin/sleep", "30"], timeout: Some(Duration.millisecond * 50), withWrap: false) }
            catch (_: ShellTimeoutException) { timedOut = true }
            @Expect(timedOut, true)
            @Expect(ownedFixtureFds(), baseline)
            @Expect(managedRecoveryProbeRecords(directory, parent, "caller-fixture", MonoTime.now() + Duration.second).terminal, true)
        })
    }
}
