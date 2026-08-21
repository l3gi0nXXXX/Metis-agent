package metis.process

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private class RecordingManagedStdioPlatformRunner <: ManagedStdioPlatformRunner {
    let calls = ArrayList<String>()
    private let delegate = ManagedStdioDefaultPlatformRunner()

    public func terminateTree(pid: Int64, pgid: Int64, force: Bool): Bool {
        this.calls.add("${pid}:${pgid}:${if (force) { "force" } else { "term" }}")
        this.delegate.terminateTree(pid, pgid, force)
    }

    public func treeAlive(pid: Int64, pgid: Int64): Bool { this.delegate.treeAlive(pid, pgid) }
}

private class ManagedStdioTestBoolBox {
    var value: Bool
    init(value!: Bool = false) { this.value = value }
}

private class ManagedStdioTestStringBox {
    var value: String
    init(value!: String = "") { this.value = value }
}

private class ManagedStdioTestInt64Box {
    var value: Int64
    init(value!: Int64 = 0) { this.value = value }
}

private func managedStdioTestNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func managedStdioWaitUntil(timeoutMs: Int64, predicate: () -> Bool): Bool {
    let deadline = managedStdioTestNowMs() + timeoutMs
    while (managedStdioTestNowMs() < deadline) {
        if (predicate()) { return true }
        sleep(Duration.millisecond * 10)
    }
    predicate()
}

private func managedStdioTestReadUtf8(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_response_encoding" }
}

@Test
public class ManagedStdioBrokerTest {
    @TestCase
    public func p1U1OwnerSpecAndPlatformCommandsPreserveNeutralContract(): Unit {
        let valid = ManagedStdioOwnerSpec(
            "owner-中文🙂",
            "node",
            args: ["-e", "console.log('ok')"],
            environment: [("SAFE_PLACEHOLDER", "value")],
            stdinMode: "closed",
            outputMode: "stream"
        )
        @Expect(valid.validate(), "ok")
        @Expect(ManagedStdioOwnerSpec("", "node").validate(), "invalid_owner_spec")
        @Expect(ManagedStdioOwnerSpec("owner", "").validate(), "invalid_owner_spec")
        @Expect(ManagedStdioOwnerSpec("owner", "node", environment: [("bad\nkey", "value")]).validate(), "invalid_owner_spec")
        @Expect(ManagedStdioOwnerSpec("owner", "node", workingDirectory: Some("bad\u{0}cwd")).validate(), "invalid_owner_spec")
        @Expect(ManagedStdioOwnerSpec("owner", "node", maxLineBytes: -1).validate(), "invalid_owner_spec")
        let (posixCommand, posixArgs) = managedStdioTerminationArgv("posix", 41, 42, false)
        let (windowsTerm, windowsTermArgs) = managedStdioTerminationArgv("windows", 51, 0, false)
        let (_, windowsKillArgs) = managedStdioTerminationArgv("windows", 51, 0, true)
        @Expect(posixCommand, "/bin/kill")
        @Expect(posixArgs, ["-TERM", "--", "-42"])
        @Expect(windowsTerm, "taskkill")
        @Expect(windowsTermArgs, ["/PID", "51", "/T"])
        @Expect(windowsKillArgs, ["/PID", "51", "/T", "/F"])
        @Expect(managedStdioOwnerIdentitySafeForReap("windows", 51, 0), true)
        @Expect(managedStdioOwnerIdentitySafeForReap("posix", 51, 51), true)
        @Expect(managedStdioOwnerIdentitySafeForReap("posix", 51, 52), false)
        @Expect(managedStdioOwnerIdentitySafeForReap("posix", 1, 1), false)
        let guardedPosix = ManagedStdioDefaultPlatformRunner(platform: "posix")
        @Expect(guardedPosix.terminateTree(41001, 41002, false), false)
        @Expect(guardedPosix.treeAlive(41001, 41002), false)
        let resolvedBroker = Path(managedStdioResolveBrokerScriptPath())
        @Expect(resolvedBroker.isAbsolute(), true)
        @Expect(exists(resolvedBroker), true)
        let oldRoot = getVariable("METIS_CJPM_ROOT")
        let oldScript = getVariable("METIS_STDIO_BROKER_SCRIPT")
        try {
            setVariable("METIS_STDIO_BROKER_SCRIPT", "")
            setVariable("METIS_CJPM_ROOT", resolvedBroker.parent.parent.toString())
            @Expect(
                managedStdioResolveBrokerScriptPath(startDirectory: Path("/tmp/metis-stdio-outside-repository")),
                resolvedBroker.toString()
            )
            setVariable("METIS_CJPM_ROOT", "")
            @Expect(
                managedStdioResolveBrokerScriptPath(startDirectory: Path("/tmp/metis-stdio-outside-repository")),
                ""
            )
        } finally {
            match (oldRoot) {
                case Some(value) => setVariable("METIS_CJPM_ROOT", value)
                case None => setVariable("METIS_CJPM_ROOT", "")
            }
            match (oldScript) {
                case Some(value) => setVariable("METIS_STDIO_BROKER_SCRIPT", value)
                case None => setVariable("METIS_STDIO_BROKER_SCRIPT", "")
            }
        }
    }

    @TestCase
    public func p1P1RealBrokerUsesOneReaderAndRoutesUnicodeOutput(): Unit {
        let client = ManagedStdioBrokerClient()
        try {
            let start = client.startOwner(ManagedStdioOwnerSpec(
                "unicode-owner",
                "node",
                args: ["-e", "process.stdout.write('中文🙂\\n尾巴🚀')"],
                stdinMode: "closed",
                outputMode: "line",
                deadlineMs: 2000
            ))
            @Expect(start.ok, true)
            @Expect(start.pid > 0, true)
            @Expect(start.pgid > 0, true)
            let texts = ArrayList<String>()
            let sawExit = ManagedStdioTestBoolBox()
            let completed = managedStdioWaitUntil(4000, {
                =>
                match (client.readOwnerLine("unicode-owner", timeoutMs: 50)) {
                    case Some(event) =>
                        if (event.eventType == "owner.stdout") { texts.add(event.text) }
                        if (event.eventType == "owner.exit") { sawExit.value = true }
                    case None => ()
                }
                sawExit.value
            })
            @Expect(completed, true)
            @Expect(texts.toArray(), ["中文🙂", "尾巴🚀"])
            let snapshot = client.debugSnapshotForTest()
            @Expect(snapshot.readerCount, 1)
            @Expect(snapshot.ownerCount, 0)
            @Expect(client.probeBroker(timeoutMs: 500).ok, true)
            let echo = client.startOwner(ManagedStdioOwnerSpec(
                "write-owner",
                "node",
                args: ["-e", "process.stdin.once('data',d=>{process.stdout.write(d);process.exit(0)})"],
                stdinMode: "line",
                deadlineMs: 2000
            ))
            @Expect(echo.ok, true)
            @Expect(client.writeOwnerLine("write-owner", "你好🙂").status, "written")
            let echoed = ManagedStdioTestStringBox()
            @Expect(managedStdioWaitUntil(3000, {
                =>
                match (client.readOwnerLine("write-owner", timeoutMs: 50)) {
                    case Some(event) =>
                        if (event.eventType == "owner.stdout") { echoed.value = event.text }
                        event.eventType == "owner.exit"
                    case None => false
                }
            }), true)
            @Expect(echoed.value, "你好🙂")
        } finally {
            let _ = client.close(timeoutMs: 2000)
        }
    }

    @TestCase
    public func p1B1InjectedOwnerAndQueueLimitsRejectOverflowWithoutUnboundedState(): Unit {
        let client = ManagedStdioBrokerClient(ownerHardLimit: 2, ownerQueueLimit: 2)
        try {
            let first = client.startOwner(ManagedStdioOwnerSpec(
                "limit-1", "node",
                args: ["-e", "for(let i=0;i<3;i++)console.log(i);setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            let second = client.startOwner(ManagedStdioOwnerSpec(
                "limit-2", "node",
                args: ["-e", "setInterval(()=>{},1000)"],
                stdinMode: "closed", deadlineMs: 10000
            ))
            @Expect(first.ok, true)
            @Expect(second.ok, true)
            let third = client.startOwner(ManagedStdioOwnerSpec(
                "limit-3", "node", args: ["-e", "console.log('must-not-start')"], stdinMode: "closed"
            ))
            @Expect(third.ok, false)
            @Expect(third.status, "broker_capacity_exceeded")
            @Expect(client.writeOwnerLine("limit-1", "bad\nline").status, "invalid_owner_write")
            sleep(Duration.millisecond * 200)
            @Expect(managedStdioWaitUntil(3000, {
                =>
                match (client.readOwnerLine("limit-1", timeoutMs: 50)) {
                    case Some(event) => event.status == "buffer_capacity_exceeded"
                    case None => false
                }
            }), true)
            @Expect(client.debugSnapshotForTest().ownerCount <= 1, true)
        } finally {
            let _ = client.close(timeoutMs: 3000)
        }

        let byteBounded = ManagedStdioBrokerClient(ownerQueueLimit: 32)
        try {
            let started = byteBounded.startOwner(ManagedStdioOwnerSpec(
                "byte-limit", "node",
                args: ["-e", "let i=0;const t=setInterval(()=>{process.stdout.write('1234\\n');if(++i===3)clearInterval(t)},30);setInterval(()=>{},1000)"],
                stdinMode: "closed", deadlineMs: 10000, maxBufferedBytes: 8
            ))
            @Expect(started.ok, true)
            sleep(Duration.millisecond * 200)
            let sawByteOverflow = ManagedStdioTestBoolBox()
            @Expect(managedStdioWaitUntil(3000, {
                =>
                match (byteBounded.readOwnerLine("byte-limit", timeoutMs: 50)) {
                    case Some(event) =>
                        if (event.status == "buffer_capacity_exceeded") { sawByteOverflow.value = true }
                    case None => ()
                }
                sawByteOverflow.value
            }), true)
        } finally {
            let _ = byteBounded.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p1N2BrokerKillFailsOldGenerationWithoutReplayAndRecovers(): Unit {
        let client = ManagedStdioBrokerClient()
        let runner = ManagedStdioDefaultPlatformRunner()
        let replayMarker = Path("/tmp/metis-stdio-no-replay-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let oldPgid = ManagedStdioTestInt64Box()
        try {
            for (index in 0..3) {
                let script = if (index == 0) {
                    "process.stdin.on('data',()=>require('fs').appendFileSync('${replayMarker.toString()}','x'));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"
                } else {
                    "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"
                }
                let started = client.startOwner(ManagedStdioOwnerSpec(
                    "old-${index}",
                    "node",
                    args: ["-e", script],
                    stdinMode: if (index == 0) { "line" } else { "closed" },
                    deadlineMs: 10000
                ))
                @Expect(started.ok, true)
                if (index == 0) { oldPgid.value = started.pgid }
            }
            @Expect(client.writeOwnerLine("old-0", "side-effect-once").status, "written")
            @Expect(managedStdioWaitUntil(1000, { => exists(replayMarker) }), true)
            @Expect(managedStdioTestReadUtf8(replayMarker), "x")
            let oldGeneration = client.debugSnapshotForTest().generation
            client.debugKillBrokerForTest()
            @Expect(managedStdioWaitUntil(4000, { => !client.debugSnapshotForTest().running }), true)
            @Expect(managedStdioWaitUntil(3000, { => !runner.treeAlive(oldPgid.value, oldPgid.value) }), true)
            for (index in 0..3) {
                let event = client.readOwnerLine("old-${index}", timeoutMs: 100)
                @Expect(event.isSome(), true)
                @Expect(event.getOrThrow().status, "broker_exited")
            }
            let next = client.startOwner(ManagedStdioOwnerSpec(
                "new-owner",
                "node",
                args: ["-e", "console.log('new-generation')"],
                stdinMode: "closed",
                deadlineMs: 2000
            ))
            @Expect(next.ok, true)
            @Expect(next.generation, oldGeneration + 1)
            let output = ManagedStdioTestStringBox()
            @Expect(managedStdioWaitUntil(3000, {
                =>
                match (client.readOwnerLine("new-owner", timeoutMs: 50)) {
                    case Some(event) =>
                        if (event.eventType == "owner.stdout") { output.value = event.text }
                        event.eventType == "owner.exit"
                    case None => false
                }
            }), true)
            @Expect(output.value, "new-generation")
            sleep(Duration.millisecond * 200)
            @Expect(managedStdioTestReadUtf8(replayMarker), "x")
        } finally {
            let _ = client.close(timeoutMs: 2000)
            try { if (exists(replayMarker)) { remove(replayMarker) } } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func p1N3HungProtocolEmergencyReapsAndNodeMissingIsStable(): Unit {
        let recording = RecordingManagedStdioPlatformRunner()
        let client = ManagedStdioBrokerClient(platformRunner: recording, brokerTestMode: true)
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "hung-owner",
                "node",
                args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "closed",
                deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            let ping = client.probeBroker(timeoutMs: 80)
            @Expect(ping.ok, false)
            @Expect(ping.status, "broker_unresponsive")
            @Expect(recording.calls.size >= 2, true)
            @Expect(recording.calls[0], "${started.pid}:${started.pgid}:term")
            @Expect(recording.calls[1], "${started.pid}:${started.pgid}:force")
            @Expect(managedStdioWaitUntil(2000, { => !recording.treeAlive(started.pid, started.pgid) }), true)
        } finally {
            let _ = client.close(timeoutMs: 500)
        }

        let startHung = ManagedStdioBrokerClient(brokerTestMode: true)
        try {
            @Expect(startHung.ensureBrokerRunning(timeoutMs: 500).ok, true)
            @Expect(startHung.debugHangBrokerForTest(), true)
            let startedAt = managedStdioTestNowMs()
            let timedOutStart = startHung.startOwner(ManagedStdioOwnerSpec(
                "start-timeout-owner", "node", args: ["-e", "setInterval(()=>{},1000)"], stdinMode: "closed"
            ), timeoutMs: 80)
            @Expect(timedOutStart.ok, false)
            @Expect(timedOutStart.status, "start_timeout")
            @Expect(managedStdioTestNowMs() - startedAt < 1000, true)
            @Expect(startHung.snapshot().ownerCount, 0)
        } finally {
            let _ = startHung.close(timeoutMs: 500)
        }

        let missing = ManagedStdioBrokerClient(nodeCommand: "metis-node-command-does-not-exist")
        var previousGeneration: Int64 = 0
        for (_ in 0..3) {
            let unavailable = missing.ensureBrokerRunning(timeoutMs: 100)
            @Expect(unavailable.ok, false)
            @Expect(unavailable.status, "broker_unavailable")
            @Expect(unavailable.generation, previousGeneration + 1)
            previousGeneration = unavailable.generation
        }
        let closeStarted = managedStdioTestNowMs()
        @Expect(missing.close(timeoutMs: 100).ok, true)
        @Expect(managedStdioTestNowMs() - closeStarted < 1000, true)
    }
}
