package metis.cron

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withCronScriptRunnerTestRoot<T>(block: (Path) -> T): T {
    let root = Path("/tmp/metis-cron-script-runner-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try { remove(root, recursive: true) } catch (_: Exception) { () }
    Directory.create(cronScriptsDir(root), recursive: true)
    try {
        return block(root)
    } finally {
        try { remove(root, recursive: true) } catch (_: Exception) { () }
    }
}

private func cronScriptRunnerJob(path: String, mode!: String = "noAgent"): CronJob {
    CronJob(
        "script-job",
        "hello cron",
        CronSchedule.every(60000),
        scriptPath: path,
        scriptMode: mode
    )
}

private func cronScriptRunnerRepeated(text: String, count: Int64): String {
    let out = StringBuilder()
    var i: Int64 = 0
    while (i < count) {
        out.append(text)
        i += 1
    }
    out.toString()
}

@Test
public class CronScriptRunnerTest {
    @TestCase
    public func resolveCronScriptPathRejectsTraversalAbsoluteAndTilde(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            @Expect(resolveCronScriptPath(root, "../x.sh").ok, false)
            @Expect(resolveCronScriptPath(root, "/tmp/x.sh").ok, false)
            @Expect(resolveCronScriptPath(root, "~/x.sh").ok, false)
            @Expect(resolveCronScriptPath(root, "nested/report.sh").ok, true)
        })
    }

    @TestCase
    public func runCronJobScriptExecutesBashAndKeepsUtf8Output(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let script = cronScriptsDir(root).join("report.sh")
            File.writeTo(script, "printf '天气 🙂 ok'\n".toArray())

            let result = runCronJobScriptForJob(root, cronScriptRunnerJob("report.sh"))
            @Expect(result.ok, true)
            @Expect(result.output.contains("天气"), true)
            @Expect(result.output.contains("🙂"), true)
            @Expect(result.exitCode, 0)
        })
    }

    @TestCase
    public func runCronJobScriptRedactsAndTruncatesOutputSafely(): Unit {
        let long = cronScriptSanitizeOutputForTest(
            "TOKEN=secret-value " + cronScriptRunnerRepeated("中文🙂", 100),
            maxRunes: 24
        )
        @Expect(long.contains("secret-value"), false)
        @Expect(long.contains("中文"), true)
        @Expect(long.endsWith("..."), true)
    }

    @TestCase
    public func runCronJobScriptRejectsUnsupportedExtensionWithoutExecuting(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let script = cronScriptsDir(root).join("report.txt")
            File.writeTo(script, "printf should-not-run\n".toArray())

            let result = runCronJobScriptForJob(root, cronScriptRunnerJob("report.txt"))
            @Expect(result.ok, false)
            @Expect(result.errorCode, "cron_script_unsupported_extension")
        })
    }

    @TestCase
    public func runCronJobScriptReportsNonZeroExitWithStderr(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let script = cronScriptsDir(root).join("fail.sh")
            File.writeTo(script, "printf 'bad' >&2\nexit 7\n".toArray())

            let result = runCronJobScriptForJob(root, cronScriptRunnerJob("fail.sh"))
            @Expect(result.ok, false)
            @Expect(result.errorCode, "cron_script_exit_nonzero")
            @Expect(result.exitCode, 7)
            @Expect(result.message.contains("bad"), true)
        })
    }

    @TestCase
    public func cronScriptDecodeBytesReportsInvalidUtf8(): Unit {
        let result = cronScriptDecodeBytesForTest(Array<Byte>(2, { i => if (i == 0) { 195 } else { 40 } }))
        @Expect(result.ok, false)
        @Expect(result.status, "invalid_response_encoding")
    }
}
