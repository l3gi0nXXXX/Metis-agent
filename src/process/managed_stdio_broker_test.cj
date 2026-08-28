package metis.process

import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{File, Path, exists, remove}
import std.sync.*
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

private class ManagedStdioTestGate {
    private let lock = Mutex()
    private var condition: Condition
    private var entered: Bool = false
    private var released: Bool = false

    init() {
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    func enterAndWait(): Unit {
        synchronized(this.lock) {
            this.entered = true
            this.condition.notifyAll()
            while (!this.released) { this.condition.wait() }
        }
    }

    func awaitEntered(timeoutMs: Int64): Bool {
        let deadline = managedStdioTestNowMs() + timeoutMs
        synchronized(this.lock) {
            while (!this.entered) {
                let remaining = deadline - managedStdioTestNowMs()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }
}

private class ManagedStdioTestSubscriber <: ManagedStdioOwnerSubscriber {
    private let lock = Mutex()
    private let events = ArrayList<ManagedStdioEvent>()

    public func onManagedStdioEvent(event: ManagedStdioEvent): Unit {
        synchronized(this.lock) { this.events.add(event) }
    }

    func terminalCount(): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (event in this.events) {
                if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") { count += 1 }
            }
            count
        }
    }

    func containsText(text: String): Bool {
        synchronized(this.lock) {
            for (event in this.events) {
                if (event.text == text) { return true }
            }
            false
        }
    }

    func regularCount(): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (event in this.events) {
                if (event.eventType == "owner.stdout" || event.eventType == "owner.stderr") { count += 1 }
            }
            count
        }
    }

    func terminalStatus(): String {
        synchronized(this.lock) {
            for (event in this.events) {
                if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") { return event.status }
            }
            ""
        }
    }
}

private class ManagedStdioBlockingSubscriber <: ManagedStdioOwnerSubscriber {
    private let lock = Mutex()
    private var condition: Condition
    private let events = ArrayList<ManagedStdioEvent>()
    private var entered: Bool = false
    private var released: Bool = false
    private var reenterSingleton: Bool = false
    private var singletonReentered: Bool = false
    private var blockTerminal: Bool = false

    init(reenterSingleton!: Bool = false, blockTerminal!: Bool = false) {
        synchronized(this.lock) { this.condition = this.lock.condition() }
        this.reenterSingleton = reenterSingleton
        this.blockTerminal = blockTerminal
    }

    public func onManagedStdioEvent(event: ManagedStdioEvent): Unit {
        var shouldReenter = false
        synchronized(this.lock) {
            this.events.add(event)
            let terminal = event.eventType == "owner.exit" || event.eventType == "owner.error" ||
                event.eventType == "owner.timeout"
            if (!this.entered && (event.eventType == "owner.stdout" || event.eventType == "owner.stderr" ||
                (this.blockTerminal && terminal))) {
                this.entered = true
                this.condition.notifyAll()
                while (!this.released) { this.condition.wait() }
                shouldReenter = this.reenterSingleton
            }
        }
        if (shouldReenter) {
            let _ = managedStdioBroker().debugSnapshotForTest()
            synchronized(this.lock) {
                this.singletonReentered = true
                this.condition.notifyAll()
            }
        }
    }

    func awaitEntered(timeoutMs: Int64): Bool {
        let deadline = managedStdioTestNowMs() + timeoutMs
        synchronized(this.lock) {
            while (!this.entered) {
                let remaining = deadline - managedStdioTestNowMs()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }

    func terminalCount(): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (event in this.events) {
                if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") { count += 1 }
            }
            count
        }
    }

    func terminalStatus(): String {
        synchronized(this.lock) {
            for (event in this.events) {
                if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") { return event.status }
            }
            ""
        }
    }

    func regularCount(): Int64 {
        synchronized(this.lock) {
            var count: Int64 = 0
            for (event in this.events) {
                if (event.eventType == "owner.stdout" || event.eventType == "owner.stderr") { count += 1 }
            }
            count
        }
    }

    func didReenterSingleton(): Bool { synchronized(this.lock) { this.singletonReentered } }
}

private class ManagedStdioThrowingSubscriber <: ManagedStdioOwnerSubscriber {
    public func onManagedStdioEvent(_event: ManagedStdioEvent): Unit {
        throw Exception("subscriber test failure must stay isolated")
    }
}

private func managedStdioSubscribersSettled(subscribers: ArrayList<ManagedStdioTestSubscriber>): Bool {
    for (subscriber in subscribers) {
        if (subscriber.terminalCount() != 1) { return false }
    }
    true
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

private func managedStdioJoinFuture<T>(future: Option<Future<T>>, timeoutMs: Int64): Unit {
    match (future) {
        case Some(value) => try { let _ = value.get(Duration.millisecond * timeoutMs) } catch (_: Exception) { () }
        case None => ()
    }
}

@Test
public class ManagedStdioBrokerTest {
    @TestCase
    public func writeCorrelationU1TwoConcurrentWritesReceiveOwnAcknowledgements(): Unit {
        let client = ManagedStdioBrokerClient()
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-u1", "node",
                args: ["-e", "process.stdin.on('data',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            let first = spawn {
                client.writeOwnerLine(
                    "write-correlation-u1", "first", timeoutMs: 2000,
                    expectedGeneration: Some(started.generation)
                )
            }
            let second = spawn {
                client.writeOwnerLine(
                    "write-correlation-u1", "second", timeoutMs: 2000,
                    expectedGeneration: Some(started.generation)
                )
            }
            let firstResult = first.get(Duration.second * 3)
            let secondResult = second.get(Duration.second * 3)
            @Expect(firstResult.ok, true)
            @Expect(firstResult.status, "written")
            @Expect(secondResult.ok, true)
            @Expect(secondResult.status, "written")
        } finally {
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func writeCorrelationB1HungAcknowledgementsKeepIndependentEntryDeadlines(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-b1", "node",
                args: ["-e", "process.stdin.on('data',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            let begin = managedStdioTestNowMs()
            let first = spawn {
                client.writeOwnerLine(
                    "write-correlation-b1", "first", timeoutMs: 300,
                    expectedGeneration: Some(started.generation)
                )
            }
            let second = spawn {
                client.writeOwnerLine(
                    "write-correlation-b1", "second", timeoutMs: 300,
                    expectedGeneration: Some(started.generation)
                )
            }
            let firstResult = first.get(Duration.second * 2)
            let secondResult = second.get(Duration.second * 2)
            let elapsed = managedStdioTestNowMs() - begin
            @Expect(firstResult.ok, false)
            @Expect(firstResult.status, "broker_unresponsive")
            @Expect(secondResult.ok, false)
            @Expect(secondResult.status, "broker_unresponsive")
            @Expect(elapsed < 500, true)
            @Expect(client.pendingWriteCountForTest("write-correlation-b1"), 0)
        } finally {
            let _ = client.close(timeoutMs: 500)
        }
    }

    @TestCase
    public func writeCorrelationN1PendingCapacityAndAbsoluteDeadlinesStayBounded(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        let futures = ArrayList<Future<ManagedStdioOperationResult>>()
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-n1", "node",
                args: ["-e", "process.stdin.on('data',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            for (index in 0..256) {
                let writeIndex = index
                futures.add(spawn {
                    client.writeOwnerLine(
                        "write-correlation-n1", "line-${writeIndex}", timeoutMs: 5000,
                        expectedGeneration: Some(started.generation)
                    )
                })
            }
            @Expect(managedStdioWaitUntil(3000, {
                => client.pendingWriteCountForTest("write-correlation-n1") == 256
            }), true)
            let overflow = client.writeOwnerLine(
                "write-correlation-n1", "overflow", timeoutMs: 5000,
                expectedGeneration: Some(started.generation)
            )
            @Expect(overflow.ok, false)
            @Expect(overflow.status, "broker_write_capacity_exceeded")
            @Expect(client.pendingWriteCountForTest("write-correlation-n1"), 256)
            for (future in futures) { try { future.cancel() } catch (_: Exception) { () } }
            let cleanupStarted = managedStdioTestNowMs()
            @Expect(managedStdioWaitUntil(6500, {
                => client.pendingWriteCountForTest("write-correlation-n1") == 0
            }), true)
            @Expect(managedStdioTestNowMs() - cleanupStarted < 7000, true)
        } finally {
            for (future in futures) { try { future.cancel() } catch (_: Exception) { () } }
            let _ = client.close(timeoutMs: 500)
        }
    }

    @TestCase
    public func writeCorrelationN2OwnerTerminationWithoutWriteAckCleansPending(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-n2", "node",
                args: ["-e", "process.stdin.on('data',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            let pending = spawn {
                client.writeOwnerLine(
                    "write-correlation-n2", "pending", timeoutMs: 5000,
                    expectedGeneration: Some(started.generation)
                )
            }
            @Expect(managedStdioWaitUntil(2000, {
                => client.pendingWriteCountForTest("write-correlation-n2") == 1
            }), true)
            client.debugKillBrokerForTest()
            let result = pending.get(Duration.second * 3)
            @Expect(result.ok, false)
            @Expect(result.status, "broker_exited")
            @Expect(client.pendingWriteCountForTest("write-correlation-n2"), 0)
            let stopped = client.stopOwner(
                "write-correlation-n2",
                timeoutMs: 500,
                expectedGeneration: Some(started.generation)
            )
            @Expect(stopped.ok, false)
            @Expect(stopped.status, "broker_exited")
        } finally {
            let _ = client.close(timeoutMs: 500)
        }
    }

    @TestCase
    public func writeCorrelationN3MissingAndWrongIncarnationCannotSettlePendingWrite(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        var pending = None<Future<ManagedStdioOperationResult>>
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-n3", "node",
                args: ["-e", "process.stdin.on('data',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            pending = Some(spawn {
                client.writeOwnerLine(
                    "write-correlation-n3", "pending", timeoutMs: 3000,
                    expectedGeneration: Some(started.generation)
                )
            })
            @Expect(managedStdioWaitUntil(2000, {
                => client.pendingWriteCountForTest("write-correlation-n3") == 1
            }), true)
            let requestId = client.firstPendingWriteRequestIdForTest("write-correlation-n3")
            let incarnation = client.ownerIncarnationForTest("write-correlation-n3")
            @Expect(requestId.isEmpty(), false)
            @Expect(incarnation.isEmpty(), false)

            client.injectOwnerWrittenForTest("write-correlation-n3", requestId, None<String>)
            @Expect(client.pendingWriteCountForTest("write-correlation-n3"), 1)
            client.injectOwnerWrittenForTest("write-correlation-n3", requestId, Some("wrong-incarnation"))
            @Expect(client.pendingWriteCountForTest("write-correlation-n3"), 1)
            client.injectOwnerWrittenForTest("write-correlation-n3", requestId, Some(incarnation))
            let result = pending.getOrThrow().get(Duration.second * 2)
            pending = None<Future<ManagedStdioOperationResult>>
            @Expect(result.ok, true)
            @Expect(result.status, "written")
            @Expect(client.pendingWriteCountForTest("write-correlation-n3"), 0)
        } finally {
            match (pending) {
                case Some(future) => try { future.cancel() } catch (_: Exception) { () }
                case None => ()
            }
            let _ = client.close(timeoutMs: 500)
        }
    }

    @TestCase
    public func writeCorrelationP1SixtyFourConcurrentWritesReceiveOwnAcknowledgements(): Unit {
        let client = ManagedStdioBrokerClient()
        let futures = ArrayList<Future<ManagedStdioOperationResult>>()
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "write-correlation-p1", "node",
                args: [
                    "-e",
                    "let n=0;require('readline').createInterface({input:process.stdin}).on('line',()=>{n++;if(n===64)console.log('received:64')});setInterval(()=>{},1000)"
                ],
                stdinMode: "line", outputMode: "line", deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            for (index in 0..64) {
                let writeIndex = index
                futures.add(spawn {
                    client.writeOwnerLine(
                        "write-correlation-p1", "line-${writeIndex}", timeoutMs: 2000,
                        expectedGeneration: Some(started.generation)
                    )
                })
            }
            for (future in futures) {
                let result = future.get(Duration.second * 10)
                @Expect(result.ok, true)
                @Expect(result.status, "written")
            }
            @Expect(managedStdioWaitUntil(3000, {
                =>
                match (client.readOwnerLine("write-correlation-p1", timeoutMs: 50)) {
                    case Some(event) => event.eventType == "owner.stdout" && event.text == "received:64"
                    case None => false
                }
            }), true)
        } finally {
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3U3OwnerSubscriptionsUseOneDispatcherForTwoAndThirtyTwoClients(): Unit {
        for (count in [2, 32]) {
            let client = ManagedStdioBrokerClient()
            let subscribers = ArrayList<ManagedStdioTestSubscriber>()
            try {
                for (index in 0..count) {
                    let ownerId = "subscription-${count}-${index}"
                    let started = client.startOwner(ManagedStdioOwnerSpec(
                        ownerId,
                        "node",
                        args: ["-e", "console.log('event-${index}-中文🙂')"],
                        stdinMode: "closed",
                        deadlineMs: 2000
                    ))
                    @Expect(started.ok, true)
                    let subscriber = ManagedStdioTestSubscriber()
                    subscribers.add(subscriber)
                    @Expect(client.subscribeOwner(ownerId, started.generation, subscriber).status, "subscribed")
                }
                @Expect(managedStdioWaitUntil(8000, { => managedStdioSubscribersSettled(subscribers) }), true)
                for (index in 0..count) {
                    @Expect(subscribers[index].containsText("event-${index}-中文🙂"), true)
                    @Expect(subscribers[index].terminalCount(), 1)
                }
                let snapshot = client.debugSnapshotForTest()
                @Expect(snapshot.readerCount, 1)
                @Expect(snapshot.dispatcherCount, 1)
                @Expect(snapshot.ownerCount, 0)
            } finally {
                let _ = client.close(timeoutMs: 3000)
            }
        }
    }

    @TestCase
    public func p3B3SubscriptionAtomicallyAdoptsQueuedEventsAndRejectsMixedReaders(): Unit {
        let client = ManagedStdioBrokerClient()
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "atomic-subscription",
                "node",
                args: ["-e", "console.log('queued-before-subscribe-中文🙂');setTimeout(()=>{},500)"],
                stdinMode: "closed",
                deadlineMs: 2000
            ))
            @Expect(started.ok, true)
            sleep(Duration.millisecond * 100)
            let subscriber = ManagedStdioTestSubscriber()
            @Expect(client.subscribeOwner("atomic-subscription", started.generation, subscriber).ok, true)
            @Expect(
                client.stopOwner(
                    "atomic-subscription",
                    timeoutMs: 10,
                    expectedGeneration: Some(started.generation + 1)
                ).status,
                "stale_generation"
            )
            let conflict = client.readOwnerLine("atomic-subscription", timeoutMs: 0)
            @Expect(conflict.isSome(), true)
            @Expect(conflict.getOrThrow().status, "owner_delivery_conflict")
            @Expect(managedStdioWaitUntil(3000, { => subscriber.terminalCount() == 1 }), true)
            @Expect(subscriber.containsText("queued-before-subscribe-中文🙂"), true)
            @Expect(subscriber.terminalCount(), 1)
        } finally {
            let _ = client.close(timeoutMs: 2000)
        }
    }

    @TestCase
    public func p3N3SubscriberFailureDoesNotKillDispatcherOrAnotherOwner(): Unit {
        let client = ManagedStdioBrokerClient()
        try {
            let failed = client.startOwner(ManagedStdioOwnerSpec(
                "throwing-subscriber", "node",
                args: ["-e", "console.log('throw');setInterval(()=>{},1000)"],
                stdinMode: "closed", deadlineMs: 5000
            ))
            let healthy = client.startOwner(ManagedStdioOwnerSpec(
                "healthy-subscriber", "node",
                args: ["-e", "console.log('healthy-中文🙂')"],
                stdinMode: "closed", deadlineMs: 2000
            ))
            @Expect(failed.ok, true)
            @Expect(healthy.ok, true)
            @Expect(client.subscribeOwner("throwing-subscriber", failed.generation, ManagedStdioThrowingSubscriber()).ok, true)
            let healthySubscriber = ManagedStdioTestSubscriber()
            @Expect(client.subscribeOwner("healthy-subscriber", healthy.generation, healthySubscriber).ok, true)
            @Expect(managedStdioWaitUntil(3000, { => healthySubscriber.terminalCount() == 1 }), true)
            @Expect(healthySubscriber.containsText("healthy-中文🙂"), true)
            @Expect(client.debugSnapshotForTest().dispatcherCount, 1)
            @Expect(managedStdioWaitUntil(3000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)

            let reused = client.startOwner(ManagedStdioOwnerSpec(
                "throwing-subscriber", "node",
                args: ["-e", "console.log('reused-after-subscriber-failure-中文🙂')"],
                stdinMode: "closed", deadlineMs: 2000
            ))
            @Expect(reused.ok, true)
            let reusedSubscriber = ManagedStdioTestSubscriber()
            @Expect(client.subscribeOwner("throwing-subscriber", reused.generation, reusedSubscriber).ok, true)
            @Expect(managedStdioWaitUntil(3000, { => reusedSubscriber.terminalCount() == 1 }), true)
            @Expect(reusedSubscriber.containsText("reused-after-subscriber-failure-中文🙂"), true)
            @Expect(managedStdioWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
        } finally {
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func t4N1SettledSameGenerationStopIsIdempotent(): Unit {
        let recording = RecordingManagedStdioPlatformRunner()
        let client = ManagedStdioBrokerClient(platformRunner: recording)
        let blocked = ManagedStdioBlockingSubscriber(blockTerminal: true)
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "settled-idempotent-stop",
                "node",
                args: ["-e", "process.exit(0)"],
                stdinMode: "closed",
                deadlineMs: 2000
            ))
            @Expect(started.ok, true)
            @Expect(client.subscribeOwner(
                "settled-idempotent-stop",
                started.generation,
                blocked
            ).ok, true)
            @Expect(blocked.awaitEntered(2000), true)
            @Expect(managedStdioWaitUntil(2000, { => !recording.treeAlive(started.pid, started.pgid) }), true)

            let stopped = client.stopOwner(
                "settled-idempotent-stop",
                timeoutMs: 1000,
                expectedGeneration: Some(started.generation)
            )
            @Expect(stopped.ok, true)
            @Expect(stopped.status, "already_stopped")
            @Expect(stopped.generation, started.generation)
        } finally {
            blocked.release()
            @Expect(managedStdioWaitUntil(2000, { => blocked.terminalCount() == 1 }), true)
            @Expect(managedStdioWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func t4N2AcknowledgedStopCannotHideUnsafeBrokerTerminal(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        try {
            let started = client.startOwner(ManagedStdioOwnerSpec(
                "ack-then-broker-exit",
                "node",
                args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "closed",
                deadlineMs: 10000
            ))
            @Expect(started.ok, true)
            @Expect(client.debugInjectStopAckThenTerminalForTest(
                "ack-then-broker-exit",
                "broker_exited"
            ), true)

            let stopped = client.stopOwner(
                "ack-then-broker-exit",
                timeoutMs: 1000,
                expectedGeneration: Some(started.generation)
            )
            @Expect(stopped.ok, false)
            @Expect(stopped.status, "broker_exited")
            @Expect(stopped.generation, started.generation)
        } finally {
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3B3SubscriptionReservesTerminalAtLimitAndIsolatesCapacityFailure(): Unit {
        for (lineCount in [2, 3, 4]) {
            let client = ManagedStdioBrokerClient(ownerHardLimit: 2, ownerQueueLimit: 4, dispatchQueueLimit: 8)
            let blocked = ManagedStdioBlockingSubscriber()
            try {
                let started = client.startOwner(ManagedStdioOwnerSpec(
                    "capacity-${lineCount}", "node",
                    args: ["-e", "setTimeout(()=>{for(let i=0;i<${lineCount};i++)console.log('line-'+i);setInterval(()=>{},1000)},100)"],
                    stdinMode: "closed", deadlineMs: 5000
                ))
                @Expect(started.ok, true)
                @Expect(client.subscribeOwner("capacity-${lineCount}", started.generation, blocked).ok, true)
                @Expect(blocked.awaitEntered(2000), true)
                sleep(Duration.millisecond * 150)
                if (lineCount == 4) {
                    let healthy = client.startOwner(ManagedStdioOwnerSpec(
                        "capacity-healthy", "node", args: ["-e", "console.log('healthy-owner-中文🙂')"],
                        stdinMode: "closed", deadlineMs: 2000
                    ))
                    let healthySubscriber = ManagedStdioTestSubscriber()
                    @Expect(healthy.ok, true)
                    @Expect(client.subscribeOwner("capacity-healthy", healthy.generation, healthySubscriber).ok, true)
                    blocked.release()
                    @Expect(managedStdioWaitUntil(4000, { => blocked.terminalCount() == 1 }), true)
                    @Expect(blocked.regularCount(), 3)
                    @Expect(blocked.terminalStatus(), "subscriber_capacity_exceeded")
                    @Expect(managedStdioWaitUntil(4000, { => healthySubscriber.terminalCount() == 1 }), true)
                    @Expect(healthySubscriber.containsText("healthy-owner-中文🙂"), true)
                    @Expect(managedStdioWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
                } else {
                    blocked.release()
                    @Expect(client.stopOwner(
                        "capacity-${lineCount}", timeoutMs: 2000, expectedGeneration: Some(started.generation)
                    ).ok, true)
                    @Expect(managedStdioWaitUntil(3000, { => blocked.terminalCount() == 1 }), true)
                    @Expect(blocked.regularCount(), Int64(lineCount))
                    @Expect(blocked.terminalStatus() == "subscriber_capacity_exceeded", false)
                }
                @Expect(blocked.terminalCount(), 1)
            } finally {
                blocked.release()
                let _ = client.close(timeoutMs: 3000)
            }
        }
    }

    @TestCase
    public func p3B3SubscriptionMigrationCapacityFailureIsAtomicAndReapsOnlyRejectedOwner(): Unit {
        let client = ManagedStdioBrokerClient(ownerHardLimit: 2, ownerQueueLimit: 4, dispatchQueueLimit: 3)
        let occupied = ManagedStdioBlockingSubscriber()
        try {
            let first = client.startOwner(ManagedStdioOwnerSpec(
                "migration-occupied", "node",
                args: ["-e", "setTimeout(()=>{console.log('occupy');setInterval(()=>{},1000)},100)"],
                stdinMode: "closed", deadlineMs: 5000
            ))
            @Expect(first.ok, true)
            @Expect(client.subscribeOwner("migration-occupied", first.generation, occupied).ok, true)
            @Expect(occupied.awaitEntered(2000), true)
            let rejected = client.startOwner(ManagedStdioOwnerSpec(
                "migration-rejected", "node",
                args: ["-e", "console.log('queued-before-migration');setInterval(()=>{},1000)"],
                stdinMode: "closed", deadlineMs: 5000
            ))
            @Expect(rejected.ok, true)
            sleep(Duration.millisecond * 150)
            let rejectedSubscriber = ManagedStdioTestSubscriber()
            let firstAttempt = client.subscribeOwner("migration-rejected", rejected.generation, rejectedSubscriber)
            @Expect(firstAttempt.ok, false)
            @Expect(firstAttempt.status, "subscriber_capacity_exceeded")
            @Expect(rejectedSubscriber.regularCount(), 0)
            @Expect(rejectedSubscriber.terminalCount(), 0)
            @Expect(managedStdioWaitUntil(3000, { => client.debugSnapshotForTest().ownerCount == 1 }), true)
            occupied.release()
            @Expect(client.stopOwner(
                "migration-occupied", timeoutMs: 2000, expectedGeneration: Some(first.generation)
            ).ok, true)
            @Expect(managedStdioWaitUntil(3000, { => occupied.terminalCount() == 1 }), true)
            @Expect(managedStdioWaitUntil(2000, { => client.debugSnapshotForTest().ownerCount == 0 }), true)
            let healthy = client.startOwner(ManagedStdioOwnerSpec(
                "migration-healthy", "node", args: ["-e", "console.log('after-rejection-中文🙂')"],
                stdinMode: "closed", deadlineMs: 2000
            ))
            let healthySubscriber = ManagedStdioTestSubscriber()
            @Expect(healthy.ok, true)
            @Expect(client.subscribeOwner("migration-healthy", healthy.generation, healthySubscriber).ok, true)
            @Expect(managedStdioWaitUntil(3000, { => healthySubscriber.terminalCount() == 1 }), true)
            @Expect(healthySubscriber.containsText("after-rejection-中文🙂"), true)
        } finally {
            occupied.release()
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3B3WaitingPollConflictsWithSubscribeAndUnsubscribeHandlesInflightCallback(): Unit {
        let client = ManagedStdioBrokerClient()
        var pollFuture = None<Future<Option<ManagedStdioEvent>>>
        let blocked = ManagedStdioBlockingSubscriber()
        try {
            let polling = client.startOwner(ManagedStdioOwnerSpec(
                "poll-subscribe-race", "node", args: ["-e", "setTimeout(()=>console.log('late-poll'),500)"],
                stdinMode: "closed", deadlineMs: 2000
            ))
            @Expect(polling.ok, true)
            pollFuture = Some(spawn { client.readOwnerLine("poll-subscribe-race", timeoutMs: 1500) })
            sleep(Duration.millisecond * 100)
            @Expect(client.subscribeOwner(
                "poll-subscribe-race", polling.generation, ManagedStdioTestSubscriber()
            ).status, "owner_delivery_conflict")
            let inflight = client.startOwner(ManagedStdioOwnerSpec(
                "unsubscribe-inflight", "node",
                args: ["-e", "setTimeout(()=>{console.log('inflight');setInterval(()=>{},1000)},100)"],
                stdinMode: "closed", deadlineMs: 5000
            ))
            @Expect(inflight.ok, true)
            @Expect(client.subscribeOwner("unsubscribe-inflight", inflight.generation, blocked).ok, true)
            @Expect(blocked.awaitEntered(2000), true)
            @Expect(client.unsubscribeOwner("unsubscribe-inflight", inflight.generation).status, "unsubscribed")
            blocked.release()
            @Expect(client.stopOwner(
                "unsubscribe-inflight", timeoutMs: 2000, expectedGeneration: Some(inflight.generation)
            ).ok, true)
            let terminal = client.readOwnerLine("unsubscribe-inflight", timeoutMs: 1000)
            @Expect(terminal.isSome(), true)
            @Expect(terminal.getOrThrow().eventType == "owner.exit" || terminal.getOrThrow().eventType == "owner.error", true)
            @Expect(client.readOwnerLine("unsubscribe-inflight", timeoutMs: 0).isNone(), true)
        } finally {
            blocked.release()
            managedStdioJoinFuture(pollFuture, 2500)
            let _ = client.close(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3N3SingletonResetAllowsCallbackReentryAndRejectsCompetingReset(): Unit {
        let _ = resetManagedStdioBrokerForTest(timeoutMs: 2000)
        let old = managedStdioBroker()
        let blocked = ManagedStdioBlockingSubscriber(reenterSingleton: true)
        var resetFuture = None<Future<ManagedStdioOperationResult>>
        try {
            let started = old.startOwner(ManagedStdioOwnerSpec(
                "reset-reentry", "node",
                args: ["-e", "setTimeout(()=>{console.log('reset');setInterval(()=>{},1000)},100)"],
                stdinMode: "closed", deadlineMs: 5000
            ))
            @Expect(started.ok, true)
            @Expect(old.subscribeOwner("reset-reentry", started.generation, blocked).ok, true)
            @Expect(blocked.awaitEntered(2000), true)
            resetFuture = Some(spawn { resetManagedStdioBrokerForTest(timeoutMs: 3000) })
            @Expect(managedStdioWaitUntil(1000, { => managedStdioBrokerResetInProgressForTest() }), true)
            let competingReset = resetManagedStdioBrokerForTest(timeoutMs: 10)
            @Expect(competingReset.ok, false)
            @Expect(competingReset.status, "reset_in_progress")
            blocked.release()
            @Expect(managedStdioWaitUntil(2000, { => blocked.didReenterSingleton() }), true)
            match (resetFuture) {
                case Some(value) => @Expect(value.get(Duration.second * 4).ok, true)
                case None => @Expect(false, true)
            }
            resetFuture = None<Future<ManagedStdioOperationResult>>
            let oldSnapshot = old.debugSnapshotForTest()
            @Expect(oldSnapshot.readerCount, 0)
            @Expect(oldSnapshot.dispatcherCount, 0)
            let replacement = managedStdioBroker()
            @Expect(replacement.ensureBrokerRunning(timeoutMs: 2000).ok, true)
            let replacementSnapshot = replacement.debugSnapshotForTest()
            @Expect(replacementSnapshot.readerCount, 1)
            @Expect(replacementSnapshot.dispatcherCount, 0)
            let sameReplacement = managedStdioBroker().debugSnapshotForTest()
            @Expect(sameReplacement.generation, replacementSnapshot.generation)
            @Expect(sameReplacement.brokerPid, replacementSnapshot.brokerPid)
        } finally {
            blocked.release()
            managedStdioJoinFuture(resetFuture, 4000)
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
        }
    }

    @TestCase
    public func p3N3SingletonResetClosesBeforeReplacingTestBroker(): Unit {
        let oldNode = getVariable("METIS_STDIO_BROKER_NODE_COMMAND")
        try {
            @Expect(resetManagedStdioBrokerForTest(timeoutMs: 2000).ok, true)
            setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "/missing/metis-node-for-reset-test")
            let unavailable = managedStdioBroker().ensureBrokerRunning(timeoutMs: 100)
            @Expect(unavailable.ok, false)
            @Expect(unavailable.status, "broker_unavailable")
        } finally {
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 2000)
            match (oldNode) {
                case Some(value) => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", value)
                case None => setVariable("METIS_STDIO_BROKER_NODE_COMMAND", "")
            }
        }
    }

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
                    case Some(event) => event.status == "subscriber_capacity_exceeded"
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
                        if (event.status == "subscriber_capacity_exceeded") { sawByteOverflow.value = true }
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
    public func s3N1GenerationBoundOwnerWriteRejectsReplacementAndHonorsTimeout(): Unit {
        let client = ManagedStdioBrokerClient(brokerTestMode: true)
        let marker = Path("/tmp/metis-stdio-stale-write-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try {
            let old = client.startOwner(ManagedStdioOwnerSpec(
                "s3-write-owner",
                "node",
                args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "closed",
                deadlineMs: 10000
            ))
            @Expect(old.ok, true)
            client.debugKillBrokerForTest()
            @Expect(managedStdioWaitUntil(4000, { => !client.debugSnapshotForTest().running }), true)
            let _ = client.readOwnerLine("s3-write-owner", timeoutMs: 100)

            let replacement = client.startOwner(ManagedStdioOwnerSpec(
                "s3-write-owner",
                "node",
                args: ["-e", "process.stdin.once('data',()=>require('fs').writeFileSync('${marker.toString()}','written'));setInterval(()=>{},1000)"],
                stdinMode: "line",
                deadlineMs: 10000
            ))
            @Expect(replacement.ok, true)
            @Expect(replacement.generation > old.generation, true)
            let stale = client.writeOwnerLine(
                "s3-write-owner",
                "must-not-write",
                timeoutMs: 25,
                expectedGeneration: Some(old.generation)
            )
            @Expect(stale.ok, false)
            @Expect(stale.status, "stale_generation")
            sleep(Duration.millisecond * 50)
            @Expect(exists(marker), false)

            @Expect(client.debugHangBrokerForTest(), true)
            let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let timed = client.writeOwnerLine(
                "s3-write-owner",
                "bounded",
                timeoutMs: 25,
                expectedGeneration: Some(replacement.generation)
            )
            let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
            @Expect(timed.ok, false)
            @Expect(timed.status, "broker_unresponsive")
            @Expect(elapsed < 500, true)
        } finally {
            let _ = client.close(timeoutMs: 3000)
            try { remove(marker) } catch (_: Exception) { () }
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

    @TestCase
    public func p3N5GenerationBoundProbeNeverTouchesConcurrentReplacement(): Unit {
        let recording = RecordingManagedStdioPlatformRunner()
        let client = ManagedStdioBrokerClient(platformRunner: recording, brokerTestMode: true)
        let gate = ManagedStdioTestGate()
        var delayedProbe = None<Future<ManagedStdioOperationResult>>
        try {
            let old = client.startOwner(ManagedStdioOwnerSpec(
                "generation-probe-old",
                "node",
                args: ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
                stdinMode: "closed",
                deadlineMs: 10000
            ))
            @Expect(old.ok, true)
            @Expect(client.debugHangBrokerForTest(), true)
            delayedProbe = Some(spawn {
                gate.enterAndWait()
                client.probeBrokerForGeneration(old.generation, timeoutMs: 80)
            })
            @Expect(gate.awaitEntered(2000), true)

            client.debugKillBrokerForTest()
            @Expect(managedStdioWaitUntil(3000, { => !client.debugSnapshotForTest().running }), true)
            @Expect(managedStdioWaitUntil(2000, {
                =>
                match (client.readOwnerLine("generation-probe-old", timeoutMs: 50)) {
                    case Some(event) => event.eventType == "owner.error"
                    case None => false
                }
            }), true)
            @Expect(client.readOwnerLine("generation-probe-old", timeoutMs: 0).isNone(), true)

            let replacement = client.startOwner(ManagedStdioOwnerSpec(
                "generation-probe-replacement",
                "node",
                args: ["-e", "setInterval(()=>{},1000)"],
                stdinMode: "closed",
                deadlineMs: 10000
            ))
            @Expect(replacement.ok, true)
            @Expect(replacement.generation > old.generation, true)
            let beforeStaleProbe = client.debugSnapshotForTest()
            let terminationCallsBefore = recording.calls.size

            gate.release()
            let stale = delayedProbe.getOrThrow().get(Duration.second * 2)
            delayedProbe = None<Future<ManagedStdioOperationResult>>
            @Expect(stale.ok, false)
            @Expect(stale.status, "stale_generation")
            @Expect(stale.generation, replacement.generation)
            let afterStaleProbe = client.debugSnapshotForTest()
            @Expect(afterStaleProbe.generation, beforeStaleProbe.generation)
            @Expect(afterStaleProbe.brokerPid, beforeStaleProbe.brokerPid)
            @Expect(afterStaleProbe.running, true)
            @Expect(afterStaleProbe.responsive, true)
            @Expect(afterStaleProbe.ownerCount, 1)
            @Expect(recording.calls.size, terminationCallsBefore)

            @Expect(client.stopOwner(
                "generation-probe-replacement",
                timeoutMs: 2000,
                expectedGeneration: Some(replacement.generation)
            ).ok, true)
            @Expect(managedStdioWaitUntil(2000, {
                =>
                match (client.readOwnerLine("generation-probe-replacement", timeoutMs: 50)) {
                    case Some(event) => event.eventType == "owner.exit" || event.eventType == "owner.error"
                    case None => false
                }
            }), true)
            @Expect(client.readOwnerLine("generation-probe-replacement", timeoutMs: 0).isNone(), true)
        } finally {
            gate.release()
            managedStdioJoinFuture(delayedProbe, 2000)
            let _ = client.close(timeoutMs: 3000)
        }
    }
}
