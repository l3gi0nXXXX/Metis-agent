package metis.core.support_surface_tests

import metis.utils.*
import metis.process.{ManagedStdioBrokerClient, ManagedStdioOwnerSpec, managedStdioResolveBrokerScriptPath}
import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.sync.*
import std.time.*
import std.unittest.testmacro.*

private func shellFakeCommandPath(): String {
    Path(managedStdioResolveBrokerScriptPath()).parent.join("gateway-stdio-fake-command-child.mjs").toString()
}

private func shellWaitUntil(timeoutMs: Int64, predicate: () -> Bool): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        if (predicate()) {
            return true
        }
        sleep(Duration.millisecond * 10)
    }
    predicate()
}

private func shellCommandTimesOut(command: Array<String>, timeoutMs: Int64): Bool {
    try {
        let _ = ShellUtils.execute(
            command,
            timeout: Some(Duration.millisecond * timeoutMs),
            withWrap: false,
            logFailures: false
        )
        false
    } catch (_: ShellTimeoutException) {
        true
    }
}

private func shellPidGone(pid: String): Bool {
    ShellUtils.execute(["/bin/kill", "-0", pid], withWrap: false, logFailures: false)[0] != 0
}

private func shellProcessTreeGone(pids: Array<String>, timeoutMs: Int64): Bool {
    if (pids.size < 2) { return false }
    let rootPid = pids[0]
    let childPid = pids[1]
    shellWaitUntil(timeoutMs, { => shellPidGone(rootPid) && shellPidGone(childPid) })
}

private func shellProcessGroup(pid: String): String {
    ShellUtils.execute(["/bin/ps", "-o", "pgid=", "-p", pid], withWrap: false, logFailures: false)[1].trimAscii()
}

private func shellDeadlineTempArtifactCount(): Int64 {
    var count: Int64 = 0
    for (entry in Directory.readFrom(Path("/private/tmp"))) {
        if (entry.name.startsWith("metis-shell-deadline-")) {
            count += 1
        }
    }
    count
}

@Test
public class ShellUtilsTest {
    @TestCase
    public func executeUsesStdProcessCaptureForNoTimeoutCommands(): Unit {
        let (exitCode, stdout, stderr) = ShellUtils.execute(
            ["printf", "hello-shell-utils"],
            withWrap: false
        )
        @Expect(exitCode, 0)
        @Expect(stdout, "hello-shell-utils")
        @Expect(stderr, "")
    }

    @TestCase
    public func p3U5NoneAndInteractiveRemainIndependentFromBroker(): Unit {
        let missing = ManagedStdioBrokerClient(nodeCommand: "metis-node-command-does-not-exist")
        debugSetShellBrokerProviderForTest(Some({=> missing}))
        try {
            let capture = ShellUtils.execute(["printf", "none-path"], withWrap: false)
            @Expect(capture[0], 0)
            @Expect(capture[1], "none-path")
            @Expect(ShellUtils.executeInteractive(["/usr/bin/true"], withWrap: false), 0)

            let timed = ShellUtils.execute(
                ["printf", "must-not-run"],
                timeout: Some(Duration.second),
                withWrap: false,
                logFailures: false
            )
            @Expect(timed[0] != 0, true)
            @Expect(timed[2], "broker_unavailable")
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = missing.close(timeoutMs: 500)
        }
    }

    @TestCase
    public func p3U5TimedCapturePreservesUnicodeAndStrictlyRejectsInvalidUtf8(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        try {
            let unicode = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "unicode"],
                timeout: Some(Duration.second * 2),
                withWrap: false
            )
            @Expect(unicode[0], 0)
            @Expect(unicode[1], "中文🙂stdout")
            @Expect(unicode[2], "中文🚀stderr")

            let empty = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "exit", "0"],
                timeout: Some(Duration.second * 2),
                withWrap: false
            )
            @Expect(empty[0], 0)
            @Expect(empty[1], "")
            @Expect(empty[2], "")

            let nonzero = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "exit", "7", "中文🙂out", "错误🚀err"],
                timeout: Some(Duration.second * 2),
                withWrap: false,
                logFailures: false
            )
            @Expect(nonzero[0], 7)
            @Expect(nonzero[1], "中文🙂out")
            @Expect(nonzero[2], "错误🚀err")

            let tempArtifactsBefore = shellDeadlineTempArtifactCount()
            let deadline = ShellUtils.executeWithDeadline("printf deadline-capture", 2000)
            @Expect(deadline[0], 0)
            @Expect(deadline[1], "deadline-capture")
            @Expect(deadline[2], "")
            @Expect(shellDeadlineTempArtifactCount(), tempArtifactsBefore)

            for (mode in ["invalid-stdout", "invalid-stderr"]) {
                let invalid = ShellUtils.execute(
                    ["node", shellFakeCommandPath(), mode],
                    timeout: Some(Duration.second * 2),
                    withWrap: false,
                    logFailures: false
                )
                @Expect(invalid[0], SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE)
                @Expect(invalid[1], "")
                @Expect(invalid[2], SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC)
            }
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3B5TimedCaptureBoundsBurstAtLimitMinusOneLimitAndLimitPlusOne(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        try {
            let burst = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "burst", "262144"],
                timeout: Some(Duration.second * 5),
                withWrap: false
            )
            @Expect(burst[0], 0)
            @Expect(burst[1].size, 262144)
            @Expect(burst[2].size, 262144)

            for (size in [
                    SHELL_CAPTURE_OUTPUT_LIMIT_BYTES - 1,
                    SHELL_CAPTURE_OUTPUT_LIMIT_BYTES
                ]) {
                let accepted = ShellUtils.execute(
                    ["node", shellFakeCommandPath(), "bytes", size.toString()],
                    timeout: Some(Duration.second * 10),
                    withWrap: false
                )
                @Expect(accepted[0], 0)
                @Expect(accepted[1].size, size)
                @Expect(accepted[2], "")
            }
            let rejected = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "bytes", (SHELL_CAPTURE_OUTPUT_LIMIT_BYTES + 1).toString()],
                timeout: Some(Duration.second * 10),
                withWrap: false,
                logFailures: false
            )
            @Expect(rejected[0] != 0, true)
            @Expect(rejected[2], "output_too_large")
            @Expect(shellWaitUntil(3000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            @Expect(client.debugSnapshotForTest().readerCount, 1)
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3P5ConcurrentTimedCommandsShareBrokerWithoutPerCommandReaders(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        let futures = ArrayList<Future<Bool>>()
        try {
            for (_ in 0..8) {
                futures.add(spawn {
                    shellCommandTimesOut(["node", shellFakeCommandPath(), "delay", "1000"], 40)
                })
            }
            for (future in futures) {
                @Expect(future.get(Duration.second * 5), true)
            }
            @Expect(shellWaitUntil(3000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)

            // Historical no-timeout capture remains on std.process and is not coupled to the broker.
            let historical = ShellUtils.execute(["printf", "no-timeout-still-works"], withWrap: false)
            @Expect(historical[0], 0)
            @Expect(historical[1], "no-timeout-still-works")
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            for (future in futures) {
                try {
                    let _ = future.get(Duration.second)
                } catch (_: Exception) {
                    ()
                }
            }
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3B5ConcurrentTaggedDualStreamBurstsStayOwnerScoped(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        let futures = ArrayList<Future<(Int64, String, String)>>()
        try {
            for (index in 0..8) {
                futures.add(
                    spawn {
                        ShellUtils.execute(
                            ["node", shellFakeCommandPath(), "tagged-burst", "owner-${index}", "262144"],
                            timeout: Some(Duration.second * 10),
                            withWrap: false
                        )
                    })
            }
            for (index in 0..8) {
                let result = futures[index].get(Duration.second * 15)
                @Expect(result[0], 0)
                @Expect(result[1].contains("stdout-owner-${index}-中文🙂"), true)
                @Expect(result[2].contains("stderr-owner-${index}-中文🚀"), true)
                let neighbor = (index + 1) % 8
                @Expect(result[1].contains("stdout-owner-${neighbor}-"), false)
                @Expect(result[2].contains("stderr-owner-${neighbor}-"), false)
            }
            @Expect(shellWaitUntil(3000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            @Expect(client.debugSnapshotForTest().readerCount, 1)
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            for (future in futures) {
                try {
                    let _ = future.get(Duration.second * 5)
                } catch (_: Exception) {
                    ()
                }
            }
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3N5TimeoutExceptionIsStableAndBounded(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var message = ""
        try {
            try {
                let _ = ShellUtils.execute(
                    ["node", shellFakeCommandPath(), "delay", "2000"],
                    timeout: Some(Duration.millisecond * 50),
                    withWrap: false,
                    logFailures: false
                )
            } catch (e: ShellTimeoutException) {
                message = e.message
            }
            let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
            @Expect(message, "Shell command execution timed out")
            @Expect(elapsed < 3000, true)
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3N5TimeoutReapsIgnoreTermTreeAndKeepsAnotherOwnerAlive(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        let pidFile = Path("/tmp/metis-shell-p3n5-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.pid")
        try {
            let other = client.startOwner(
                ManagedStdioOwnerSpec(
                    "shell-other-owner",
                    "node",
                    args: [shellFakeCommandPath(), "ignore-term"],
                    stdinMode: "closed",
                    outputMode: "stream",
                    deadlineMs: 10000
                )
            )
            @Expect(other.ok, true)
            @Expect(shellCommandTimesOut(
                ["node", shellFakeCommandPath(), "ignore-term-tree", pidFile.toString()],
                200
            ), true)
            @Expect(shellWaitUntil(2000, { => exists(pidFile) }), true)
            let pids = String.fromUtf8(File.readFrom(pidFile)).split("\n")
            @Expect(pids.size >= 2, true)
            @Expect(shellWaitUntil(4000, { => shellPidGone(pids[0]) && shellPidGone(pids[1]) }), true)
            @Expect(client.debugSnapshotForTest().ownerCount, 1)
            @Expect(client.stopOwner(
                "shell-other-owner", timeoutMs: 3000, expectedGeneration: Some(other.generation)
            ).ok, true)
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = client.close(timeoutMs: 3000)
            try {
                remove(pidFile)
            } catch (_: Exception) {
                ()
            }
        }
    }

    @TestCase
    public func p3N5BrokerUnavailableAndKilledGenerationReturnStableFailureThenRecover(): Unit {
        let missing = ManagedStdioBrokerClient(nodeCommand: "metis-node-command-does-not-exist")
        debugSetShellBrokerProviderForTest(Some({=> missing}))
        try {
            let unavailable = ShellUtils.execute(
                ["printf", "must-not-run"],
                timeout: Some(Duration.second),
                withWrap: false,
                logFailures: false
            )
            @Expect(unavailable[0] != 0, true)
            @Expect(unavailable[1], "")
            @Expect(unavailable[2], "broker_unavailable")
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = missing.close(timeoutMs: 500)
        }

        let client = ManagedStdioBrokerClient()
        let pidFile = Path("/tmp/metis-shell-p3n5-kill-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.pid")
        let replayMarker = Path("${pidFile}.replay")
        var running = None<Future<(Int64, String, String)>>
        debugSetShellBrokerProviderForTest(Some({=> client}))
        try {
            running = Some(
                spawn {
                    ShellUtils.execute(
                        [
                            "node",
                            shellFakeCommandPath(),
                            "ignore-term-tree",
                            pidFile.toString(),
                            replayMarker.toString()
                        ],
                        timeout: Some(Duration.second * 5),
                        withWrap: false,
                        logFailures: false
                    )
                })
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 1 }), true)
            @Expect(shellWaitUntil(2000, { => exists(pidFile) && exists(replayMarker) }), true)
            let oldPids = String.fromUtf8(File.readFrom(pidFile)).split("\n")
            @Expect(oldPids.size >= 2, true)
            @Expect(shellProcessGroup(oldPids[0]), oldPids[0])
            @Expect(shellProcessGroup(oldPids[1]), oldPids[0])
            let healthy = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "unicode"],
                timeout: Some(Duration.second * 2),
                withWrap: false
            )
            @Expect(healthy[0], 0)
            @Expect(healthy[1], "中文🙂stdout")
            let oldGeneration = client.debugSnapshotForTest().generation
            client.debugKillBrokerForTest()
            let failed = running.getOrThrow().get(Duration.second * 5)
            @Expect(failed[0] != 0, true)
            @Expect(failed[2], "broker_exited")
            @Expect(shellWaitUntil(4000, { => shellPidGone(oldPids[0]) && shellPidGone(oldPids[1]) }), true)
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            @Expect(String.fromUtf8(File.readFrom(replayMarker)), "x")

            let recovered = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "unicode"],
                timeout: Some(Duration.second * 2),
                withWrap: false
            )
            @Expect(recovered[0], 0)
            @Expect(recovered[1], "中文🙂stdout")
            @Expect(client.debugSnapshotForTest().generation > oldGeneration, true)
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            @Expect(String.fromUtf8(File.readFrom(replayMarker)), "x")
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            match (running) {
                case Some(value) => try {
                    let _ = value.get(Duration.second * 5)
                } catch (_: Exception) {
                    ()
                }
                case None => ()
            }
            let _ = client.close(timeoutMs: 3000)
            try {
                remove(pidFile)
            } catch (_: Exception) {
                ()
            }
            try {
                remove(replayMarker)
            } catch (_: Exception) {
                ()
            }
        }
    }

    @TestCase
    public func p3N5HungBrokerCleanupFailureIsNonSuccessAndCloseReapsTree(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        let pidFile = Path("/tmp/metis-shell-p3n5-cleanup-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.pid")
        var running = None<Future<(Int64, String, String)>>
        var pids: Array<String> = []
        var oldGeneration: Int64 = 0
        debugSetShellBrokerProviderForTest(Some({=> client}))
        try {
            running = Some(
                spawn {
                    ShellUtils.execute(
                        ["node", shellFakeCommandPath(), "ignore-term-tree", pidFile.toString()],
                        timeout: Some(Duration.millisecond * 5000),
                        withWrap: false,
                        logFailures: false
                    )
                })
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 1 && exists(pidFile) }), true)
            pids = String.fromUtf8(File.readFrom(pidFile)).split("\n")
            @Expect(pids.size >= 2, true)
            oldGeneration = client.debugSnapshotForTest().generation
            @Expect(client.debugHangBrokerForTest(), true)
            @Expect(shellProcessGroup(pids[0]), pids[0])
            @Expect(shellProcessGroup(pids[1]), pids[0])

            let failed = running.getOrThrow().get(Duration.second * 20)
            @Expect(failed[0] != 0, true)
            @Expect(failed[2], SHELL_BROKER_CLEANUP_FAILED_DIAGNOSTIC)
            @Expect(failed[2].contains("timed_out"), false)
            let failedGeneration = client.debugSnapshotForTest()
            @Expect(failedGeneration.generation, oldGeneration)
            @Expect(failedGeneration.running, false)
            @Expect(failedGeneration.ownerCount, 0)
            @Expect(shellProcessTreeGone(pids, 2000), true)

            let recovered = ShellUtils.execute(
                ["node", shellFakeCommandPath(), "unicode"],
                timeout: Some(Duration.second * 2),
                withWrap: false
            )
            @Expect(recovered[0], 0)
            @Expect(recovered[1], "中文🙂stdout")
            @Expect(client.debugSnapshotForTest().generation > oldGeneration, true)
            @Expect(shellWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            match (running) {
                case Some(value) => try { let _ = value.get(Duration.second * 2) } catch (_: Exception) { () }
                case None => ()
            }
            let _ = client.close(timeoutMs: 1000)
            try { remove(pidFile) } catch (_: Exception) { () }
        }
        if (pids.size >= 2) {
            @Expect(shellProcessTreeGone(pids, 4000), true)
        }
    }

    @TestCase
    public func p3N5TransportDiagnosticsDoNotEchoSensitiveCommandOrPaths(): Unit {
        let client = ManagedStdioBrokerClient()
        debugSetShellBrokerProviderForTest(Some({=> client}))
        let sensitive = [
            "token-secret-never-visible",
            "Authorization: Bearer never-visible",
            "/Users/private/workspace/never-visible",
            "C:\\Users\\private\\never-visible"
        ]
        try {
            let failed = ShellUtils.execute(
                ["metis-missing-token-secret-never-visible", sensitive[1], sensitive[2], sensitive[3]],
                timeout: Some(Duration.second * 2),
                withWrap: false,
                logFailures: false
            )
            @Expect(failed[0] != 0, true)
            @Expect(failed[1], "")
            @Expect(failed[2], "spawn_failed")
            let diagnostic = "${failed[0]}:${failed[1]}:${failed[2]}"
            for (value in sensitive) {
                @Expect(diagnostic.contains(value), false)
            }
        } finally {
            debugSetShellBrokerProviderForTest(None<() -> ManagedStdioBrokerClient>)
            let _ = client.close(timeoutMs: 3000)
        }
    }
}
