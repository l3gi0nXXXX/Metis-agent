package metis.cron

import metis.process.{ManagedStdioOperationResult, managedStdioBroker, resetManagedStdioBrokerForTest}
import metis.utils.ShellUtils

import std.collection.ArrayList
import std.convert.Parsable
import std.core.Duration
import std.fs.{Directory, File, Path, canonicalize, exists, remove}
import std.sync.{AtomicBool, AtomicInt64}
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

private func cronScriptRunnerFixturePath(): String {
    let path = Path("scripts").join("gateway-stdio-fake-cron-child.mjs")
    try { canonicalize(path).toString() } catch (_: Exception) { path.toString() }
}

private func cronScriptRunnerWriteFixture(root: Path, name: String, mode: String, args!: Array<String> = []): Unit {
    let renderedArgs = if (args.isEmpty()) { "" } else { " " + String.join(args, delimiter: " ") }
    File.writeTo(
        cronScriptsDir(root).join(name),
        "exec node '${cronScriptRunnerFixturePath()}' '${mode}'${renderedArgs}\n".toArray()
    )
}

private func cronScriptRunnerWaitUntil(predicate: () -> Bool, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (!predicate() && DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        sleep(Duration.millisecond * 5)
    }
    predicate()
}

private func cronScriptRunnerPidValues(path: Path): Array<Int64> {
    let values = ArrayList<Int64>()
    let raw = try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { return values.toArray() }
    for (line in raw.split("\n")) {
        for (part in line.split(",")) {
            let pieces = part.split("=", 2)
            if (pieces.size == 2 && (pieces[0] == "root" || pieces[0] == "child")) {
                try { values.add(Int64.parse(pieces[1].trimAscii())) } catch (_: Exception) { () }
            }
        }
    }
    values.toArray()
}

private func cronScriptRunnerPidGone(pid: Int64): Bool {
    if (pid <= 0) { return false }
    let probe = ShellUtils.execute(["/bin/sh", "-c", "kill -0 ${pid} >/dev/null 2>&1"], withWrap: false, logFailures: false)
    probe[0] != 0
}

private func cronScriptRunnerPgid(pid: Int64): Int64 {
    if (pid <= 0) { return 0 }
    let probe = ShellUtils.execute(["ps", "-o", "pgid=", "-p", "${pid}"], withWrap: false, logFailures: false)
    try { Int64.parse(probe[1].trimAscii()) } catch (_: Exception) { 0 }
}

private func cronScriptRunnerPgidGone(pgid: Int64): Bool {
    if (pgid <= 0) { return false }
    let probe = ShellUtils.execute(["/bin/sh", "-c", "kill -0 -- -${pgid} >/dev/null 2>&1"], withWrap: false, logFailures: false)
    probe[0] != 0
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

    @TestCase
    public func m3N1ScriptDeadlineTerminatesChildAndRejectsLateOutput(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let script = cronScriptsDir(root).join("slow.sh")
            File.writeTo(script, "sleep 2\nprintf 'late-success-中文🙂'\n".toArray())
            let result = runCronJobScriptForJob(
                root,
                cronScriptRunnerJob("slow.sh"),
                remainingMs: 20
            )
            @Expect(result.ok, false)
            @Expect(result.message, "cron script timed out after 20ms")
            @Expect(result.timedOut, true)
            @Expect(result.errorCode, "cron_script_timeout")
            @Expect(result.output.contains("late-success"), false)
        })
    }

    @TestCase
    public func m3N1ScriptCancellationBeforeLaunchCreatesNoProcess(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let marker = cronScriptsDir(root).join("marker")
            let script = cronScriptsDir(root).join("cancel.sh")
            File.writeTo(script, "printf x > marker\n".toArray())
            let result = runCronJobScriptForJob(
                root,
                cronScriptRunnerJob("cancel.sh"),
                cancellationCheck: { => throw Exception("cancelled-by-test") }
            )
            @Expect(result.ok, false)
            @Expect(result.errorCode, "cron_script_cancelled")
            @Expect(exists(marker), false)
        })
    }

    @TestCase
    public func p3U4BrokerPreservesSuccessNonzeroUnicodeDualStreamAndEncodingContracts(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            cronScriptRunnerWriteFixture(root, "success.sh", "success")
            let success = runCronJobScriptForJob(root, cronScriptRunnerJob("success.sh"))
            @Expect(success.ok, true)
            @Expect(success.output, "cron-stdout-中文🙂")
            @Expect(success.stderr, "cron-stderr-中文🙂")
            @Expect(success.exitCode, 0)
            @Expect(success.status, "ok")
            @Expect(success.errorCode, "")
            @Expect(success.timedOut, false)
            @Expect(success.empty, false)
            @Expect(success.message, "")

            cronScriptRunnerWriteFixture(root, "nonzero.sh", "nonzero", args: ["7"])
            let failed = runCronJobScriptForJob(root, cronScriptRunnerJob("nonzero.sh"))
            @Expect(failed.ok, false)
            @Expect(failed.status, "exit_nonzero")
            @Expect(failed.errorCode, "cron_script_exit_nonzero")
            @Expect(failed.exitCode, 7)
            @Expect(failed.stderr.contains("cron-failure-中文🙂"), true)
            @Expect(failed.output, "")
            @Expect(failed.timedOut, false)
            @Expect(failed.empty, true)
            @Expect(failed.message.contains("cron-failure-中文🙂"), true)

            cronScriptRunnerWriteFixture(root, "burst.sh", "dual-burst", args: ["64"])
            let burst = runCronJobScriptForJob(root, cronScriptRunnerJob("burst.sh"))
            @Expect(burst.ok, true)
            @Expect(burst.output.contains("out-0-中文🙂"), true)
            @Expect(burst.output.contains("out-63-中文🙂"), true)
            @Expect(burst.stderr.contains("err-0-中文🙂"), true)
            @Expect(burst.stderr.contains("err-63-中文🙂"), true)
            @Expect(burst.status, "ok")
            @Expect(burst.errorCode, "")
            @Expect(burst.exitCode, 0)
            @Expect(burst.timedOut, false)
            @Expect(burst.empty, false)
            @Expect(burst.message, "")

            cronScriptRunnerWriteFixture(root, "invalid.sh", "invalid-utf8")
            let invalid = runCronJobScriptForJob(root, cronScriptRunnerJob("invalid.sh"))
            @Expect(invalid.ok, false)
            @Expect(invalid.status, "invalid_response_encoding")
            @Expect(invalid.errorCode, "invalid_response_encoding")
            @Expect(invalid.message.contains("invalid utf8"), true)
            @Expect(invalid.output, "")
            @Expect(invalid.stderr, "")
            @Expect(invalid.exitCode, 0)
            @Expect(invalid.timedOut, false)
            @Expect(invalid.empty, true)

            cronScriptRunnerWriteFixture(root, "sensitive.sh", "sensitive")
            let sensitive = runCronJobScriptForJob(root, cronScriptRunnerJob("sensitive.sh"))
            @Expect(sensitive.ok, true)
            @Expect(sensitive.status, "ok")
            @Expect(sensitive.errorCode, "")
            @Expect(sensitive.output.contains("cron-secret-value"), false)
            @Expect(sensitive.output.contains("private-cron-user"), false)
            @Expect(sensitive.output.contains("中文🙂"), true)
            @Expect(sensitive.stderr.contains("cron-secret-authorization-value"), false)
            @Expect(sensitive.exitCode, 0)
            @Expect(sensitive.timedOut, false)
            @Expect(sensitive.empty, false)
            @Expect(sensitive.message, "")
            @Expect(managedStdioBroker().snapshot().ownerCount, 0)
        })
    }

    @TestCase
    public func p3B4BrokerEnforcesExactCapacityAndRunsThirtyTwoCronOwners(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            let limit = cronScriptOutputMaxBytesForTest()
            cronScriptRunnerWriteFixture(root, "exact.sh", "bytes", args: ["${limit}"])
            cronScriptRunnerWriteFixture(root, "overflow.sh", "bytes", args: ["${limit + 1}"])
            let exact = runCronJobScriptForJob(root, cronScriptRunnerJob("exact.sh"))
            @Expect(exact.ok, true)
            @Expect(exact.status, "ok")
            @Expect(exact.errorCode, "")
            @Expect(exact.output.endsWith("..."), true)
            @Expect(exact.stderr, "")
            @Expect(exact.exitCode, 0)
            @Expect(exact.timedOut, false)
            @Expect(exact.empty, false)
            @Expect(exact.message, "")
            let overflow = runCronJobScriptForJob(root, cronScriptRunnerJob("overflow.sh"))
            @Expect(overflow.ok, false)
            @Expect(overflow.status, "output_limit")
            @Expect(overflow.errorCode, "cron_script_output_too_large")
            @Expect(overflow.output.endsWith("..."), true)
            @Expect(overflow.stderr, "")
            @Expect(overflow.exitCode, 0)
            @Expect(overflow.timedOut, false)
            @Expect(overflow.empty, false)
            @Expect(overflow.message.contains("output_too_large"), true)

            let futures = ArrayList<Future<CronScriptRunResult>>()
            try {
                for (index in 0..32) {
                    let tag = "tag-${index}-end"
                    File.writeTo(
                        cronScriptsDir(root).join("parallel-${index}.sh"),
                        "exec node '${cronScriptRunnerFixturePath()}' 'dual-burst' 8 '${tag}'\n".toArray()
                    )
                }
                for (index in 0..32) {
                    futures.add(spawn {
                        runCronJobScriptForJob(root, cronScriptRunnerJob("parallel-${index}.sh"))
                    })
                }
                var passed: Int64 = 0
                var index: Int64 = 0
                for (future in futures) {
                    let result = future.get(Duration.second * 10)
                    let ownTag = "tag-${index}-end"
                    let neighbourTag = "tag-${(index + 1) % 32}-end"
                    @Expect(result.ok, true)
                    @Expect(result.status, "ok")
                    @Expect(result.errorCode, "")
                    @Expect(result.output.contains("${ownTag}-out-0-中文🙂"), true)
                    @Expect(result.output.contains("${ownTag}-out-7-中文🙂"), true)
                    @Expect(result.stderr.contains("${ownTag}-err-0-中文🙂"), true)
                    @Expect(result.stderr.contains("${ownTag}-err-7-中文🙂"), true)
                    @Expect(result.output.contains(neighbourTag), false)
                    @Expect(result.stderr.contains(neighbourTag), false)
                    @Expect(result.exitCode, 0)
                    @Expect(result.timedOut, false)
                    @Expect(result.empty, false)
                    @Expect(result.message, "")
                    passed += 1
                    index += 1
                }
                @Expect(passed, 32)
                @Expect(managedStdioBroker().snapshot().readerCount, 1)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)
            } finally {
                for (future in futures) { try { let _ = future.get(Duration.second * 10) } catch (_: Exception) { () } }
                if (managedStdioBroker().snapshot().ownerCount != 0) { let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000) }
            }
        })
    }

    @TestCase
    public func p3N4TimeoutCancelInheritedPipesAndBrokerGenerationAreBounded(): Unit {
        withCronScriptRunnerTestRoot({ root =>
            var timedFuture = None<Future<CronScriptRunResult>>
            var cancelFuture = None<Future<CronScriptRunResult>>
            var killedFuture = None<Future<CronScriptRunResult>>
            var healthyFuture = None<Future<CronScriptRunResult>>
            var cleanupFuture = None<Future<CronScriptRunResult>>
            var cleanupHealthyFuture = None<Future<CronScriptRunResult>>
            try {
                let pidFile = cronScriptsDir(root).join("tree.pids")
                cronScriptRunnerWriteFixture(root, "tree.sh", "hang-tree", args: ["'${pidFile.toString()}'"])
                timedFuture = Some(spawn {
                    runCronJobScriptForJob(root, cronScriptRunnerJob("tree.sh"), remainingMs: 500)
                })
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidValues(pidFile).size == 2 }), true)
                let pids = cronScriptRunnerPidValues(pidFile)
                @Expect(pids.size, 2)
                let rootPgid = cronScriptRunnerPgid(pids[0])
                @Expect(rootPgid > 0, true)
                @Expect(cronScriptRunnerPgid(pids[1]), rootPgid)
                let timed = timedFuture.getOrThrow().get(Duration.second * 5)
                @Expect(timed.ok, false)
                @Expect(timed.status, "timeout")
                @Expect(timed.errorCode, "cron_script_timeout")
                @Expect(timed.output, "")
                @Expect(timed.stderr, "")
                @Expect(timed.exitCode, 0)
                @Expect(timed.timedOut, true)
                @Expect(timed.empty, true)
                for (pid in pids) { @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidGone(pid) }), true) }
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPgidGone(rootPgid) }), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)

                let cancelPidFile = cronScriptsDir(root).join("cancel-tree.pids")
                cronScriptRunnerWriteFixture(root, "cancel-tree.sh", "hang-tree", args: ["'${cancelPidFile.toString()}'"])
                let cancel = AtomicBool(false)
                cancelFuture = Some(spawn {
                    runCronJobScriptForJob(
                        root,
                        cronScriptRunnerJob("cancel-tree.sh"),
                        remainingMs: 5000,
                        cancellationCheck: { => if (cancel.load()) { throw Exception("cancelled-中文🙂") } }
                    )
                })
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidValues(cancelPidFile).size == 2 }), true)
                let cancelPids = cronScriptRunnerPidValues(cancelPidFile)
                let cancelPgid = cronScriptRunnerPgid(cancelPids[0])
                cancel.store(true)
                let cancelled = cancelFuture.getOrThrow().get(Duration.second * 5)
                @Expect(cancelled.ok, false)
                @Expect(cancelled.status, "cancelled")
                @Expect(cancelled.errorCode, "cron_script_cancelled")
                @Expect(cancelled.output, "")
                @Expect(cancelled.stderr, "")
                @Expect(cancelled.exitCode, 0)
                @Expect(cancelled.timedOut, false)
                @Expect(cancelled.empty, true)
                @Expect(cancelled.message.contains("cancelled-中文🙂"), true)
                for (pid in cancelPids) { @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidGone(pid) }), true) }
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPgidGone(cancelPgid) }), true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)

                let killPidFile = cronScriptsDir(root).join("broker-kill-tree.pids")
                let lateMarker = cronScriptsDir(root).join("broker-kill-late-marker")
                cronScriptRunnerWriteFixture(root, "broker-kill.sh", "hang-tree", args: ["'${killPidFile.toString()}'", "'${lateMarker.toString()}'"])
                cronScriptRunnerWriteFixture(root, "broker-healthy.sh", "success")
                let oldGeneration = managedStdioBroker().snapshot().generation
                killedFuture = Some(spawn {
                    runCronJobScriptForJob(root, cronScriptRunnerJob("broker-kill.sh"), remainingMs: 5000)
                })
                healthyFuture = Some(spawn {
                    runCronJobScriptForJob(root, cronScriptRunnerJob("broker-healthy.sh"), remainingMs: 5000)
                })
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidValues(killPidFile).size == 2 }), true)
                let healthy = healthyFuture.getOrThrow().get(Duration.second * 5)
                @Expect(healthy.ok, true)
                @Expect(healthy.output.contains("cron-stdout-中文🙂"), true)
                let killPids = cronScriptRunnerPidValues(killPidFile)
                let killPgid = cronScriptRunnerPgid(killPids[0])
                managedStdioBroker().debugKillBrokerForTest()
                let killed = killedFuture.getOrThrow().get(Duration.second * 5)
                @Expect(killed.ok, false)
                @Expect(killed.status, "failed")
                @Expect(killed.errorCode, "cron_script_failed")
                @Expect(killed.message.contains("broker_exited"), true)
                @Expect(killed.output, "")
                @Expect(killed.stderr, "")
                @Expect(killed.exitCode, 0)
                @Expect(killed.timedOut, false)
                @Expect(killed.empty, true)
                for (pid in killPids) { @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidGone(pid) }), true) }
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPgidGone(killPgid) }), true)
                @Expect(exists(lateMarker), false)
                cronScriptRunnerWriteFixture(root, "recovered.sh", "success")
                let recovered = runCronJobScriptForJob(root, cronScriptRunnerJob("recovered.sh"))
                @Expect(recovered.ok, true)
                @Expect(managedStdioBroker().snapshot().generation > oldGeneration, true)
                @Expect(managedStdioBroker().snapshot().ownerCount, 0)

                let cleanupReady = cronScriptsDir(root).join("cleanup-healthy.ready")
                let cleanupRelease = cronScriptsDir(root).join("cleanup-healthy.release")
                let cleanupPidFile = cronScriptsDir(root).join("cleanup-failure-tree.pids")
                cronScriptRunnerWriteFixture(
                    root,
                    "cleanup-healthy.sh",
                    "wait-release",
                    args: ["'${cleanupReady.toString()}'", "'${cleanupRelease.toString()}'"]
                )
                cronScriptRunnerWriteFixture(
                    root,
                    "cleanup-failure.sh",
                    "hang-tree",
                    args: ["'${cleanupPidFile.toString()}'"]
                )
                let cleanupCancel = AtomicBool(false)
                let cleanupStopBudgetMs = AtomicInt64(0)
                cleanupHealthyFuture = Some(spawn {
                    runCronJobScriptForJob(root, cronScriptRunnerJob("cleanup-healthy.sh"), remainingMs: 5000)
                })
                @Expect(cronScriptRunnerWaitUntil({ => exists(cleanupReady) }), true)
                setCronScriptStopRunnerForTest(Some({ _ownerId, generation, timeoutMs =>
                    cleanupStopBudgetMs.store(timeoutMs)
                    ManagedStdioOperationResult(false, "stop_timeout", generation: generation)
                }))
                cleanupFuture = Some(spawn {
                    runCronJobScriptForJob(
                        root,
                        cronScriptRunnerJob("cleanup-failure.sh"),
                        remainingMs: 600,
                        cancellationCheck: { => if (cleanupCancel.load()) { throw Exception("cancel-cleanup") } }
                    )
                })
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidValues(cleanupPidFile).size == 2 }), true)
                let cleanupPids = cronScriptRunnerPidValues(cleanupPidFile)
                let cleanupPgid = cronScriptRunnerPgid(cleanupPids[0])
                @Expect(cronScriptRunnerPgid(cleanupPids[1]), cleanupPgid)
                cleanupCancel.store(true)
                let cleanupFailed = cleanupFuture.getOrThrow().get(Duration.second * 3)
                @Expect(cleanupFailed.ok, false)
                @Expect(cleanupFailed.status, "cleanup_failed")
                @Expect(cleanupFailed.errorCode, "cron_script_cleanup_failed")
                @Expect(cleanupFailed.output, "")
                @Expect(cleanupFailed.stderr, "")
                @Expect(cleanupFailed.exitCode, 0)
                @Expect(cleanupFailed.timedOut, false)
                @Expect(cleanupFailed.empty, true)
                @Expect(cleanupFailed.message.contains("stop_timeout"), true)
                @Expect(cleanupStopBudgetMs.load() >= 4250, true)
                @Expect(cleanupStopBudgetMs.load() <= 5000, true)
                @Expect(managedStdioBroker().snapshot().ownerCount >= 1, true)
                setCronScriptStopRunnerForTest(None<(String, Int64, Int64) -> ManagedStdioOperationResult>)
                File.writeTo(cleanupRelease, "release".toArray())
                let cleanupHealthy = cleanupHealthyFuture.getOrThrow().get(Duration.second * 3)
                @Expect(cleanupHealthy.ok, true)
                @Expect(cleanupHealthy.output.contains("released-中文🙂"), true)
                for (pid in cleanupPids) { @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPidGone(pid) }), true) }
                @Expect(cronScriptRunnerWaitUntil({ => cronScriptRunnerPgidGone(cleanupPgid) }), true)
                @Expect(cronScriptRunnerWaitUntil({ => managedStdioBroker().snapshot().ownerCount == 0 }), true)
            } finally {
                setCronScriptStopRunnerForTest(None<(String, Int64, Int64) -> ManagedStdioOperationResult>)
                try { File.writeTo(cronScriptsDir(root).join("cleanup-healthy.release"), "release".toArray()) } catch (_: Exception) { () }
                var futuresSettled = true
                for (future in [timedFuture, cancelFuture, killedFuture, healthyFuture, cleanupFuture, cleanupHealthyFuture]) {
                    match (future) {
                        case Some(value) => try { let _ = value.get(Duration.second * 5) } catch (_: Exception) { futuresSettled = false }
                        case None => ()
                    }
                }
                @Expect(futuresSettled, true)
                var resetResult = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                if (!resetResult.ok && resetResult.status == "broker_shutdown_timeout") {
                    resetResult = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                }
                @Expect(resetResult.ok, true)
                let resetSnapshot = managedStdioBroker().snapshot()
                @Expect(resetSnapshot.ownerCount, 0)
                @Expect(resetSnapshot.brokerPid, 0)
                @Expect(resetSnapshot.readerCount, 0)
            }
        })
    }
}
