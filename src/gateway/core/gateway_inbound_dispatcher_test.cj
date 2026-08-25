package metis.gateway.core

import metis.core.config.GatewayUserSettings
import metis.gateway.model.{ChannelType, ChatType, InboundMessage, RouteDecision}
import std.core.Duration
import std.sync.AtomicBool
import std.time.DateTime
import std.unittest.testmacro.*

private func gatewayInboundDispatcherTestPrepared(id: String, key: String): GatewayPreparedInbound {
    let message = InboundMessage(
        ChannelType.Feishu,
        id,
        "peer-${id}",
        "sender-${id}",
        ChatType.Direct,
        "消息-${id}-中文🙂",
        false,
        DateTime.now()
    )
    GatewayPreparedInbound(
        message,
        "default",
        GatewayUserSettings(),
        RouteDecision(true, "accepted", conversationKey: Some(key)),
        key,
        key
    )
}

private func gatewayInboundDispatcherTestWait(check: () -> Bool, timeoutMs!: Int64 = 2000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        if (check()) { return true }
        sleep(Duration.millisecond)
    }
    check()
}

@Test
public class GatewayInboundDispatcherTest {
    @TestCase
    public func p4U1SameKeyIsOrderedWhileDifferentKeyRunsInParallel(): Unit {
        let dispatcher = GatewayInboundDispatcher(maxActive: 2, maxQueued: 4)
        let releaseA = AtomicBool(false)
        let releaseB = AtomicBool(false)
        let a1Started = AtomicBool(false)
        let a1Ended = AtomicBool(false)
        let a2Started = AtomicBool(false)
        let a2ObservedA1End = AtomicBool(false)
        let b1Started = AtomicBool(false)
        let run = { prepared: GatewayPreparedInbound, _control: GatewayInboundExecutionControl =>
            if (prepared.message.messageId == "a1") {
                a1Started.store(true)
                while (!releaseA.load()) { sleep(Duration.millisecond) }
                a1Ended.store(true)
            }
            if (prepared.message.messageId == "a2") {
                a2Started.store(true)
                a2ObservedA1End.store(a1Ended.load())
            }
            if (prepared.message.messageId == "b1") {
                b1Started.store(true)
                while (!releaseB.load()) { sleep(Duration.millisecond) }
            }
        }
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("a1", "session-a"), run).ok, true)
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("a2", "session-a"), run).status, "queued")
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("b1", "session-b"), run).ok, true)
        @Expect(gatewayInboundDispatcherTestWait({ =>
            dispatcher.activeCount() == 2 && dispatcher.queuedCount() == 1 && a1Started.load() && b1Started.load()
        }), true)
        @Expect(a1Started.load(), true)
        @Expect(b1Started.load(), true)
        @Expect(a2Started.load(), false)
        releaseB.store(true)
        releaseA.store(true)
        @Expect(gatewayInboundDispatcherTestWait({ => dispatcher.activeCount() == 0 && dispatcher.queuedCount() == 0 }), true)
        @Expect(a2Started.load(), true)
        @Expect(a2ObservedA1End.load(), true)
        @Expect(dispatcher.stop(timeoutMs: 100).ok, true)
    }

    @TestCase
    public func p4B1QueueCapacityPlusOneRejectsAndStopCancelsQueuedAndActive(): Unit {
        let dispatcher = GatewayInboundDispatcher(maxActive: 1, maxQueued: 2)
        let activeStarted = AtomicBool(false)
        let queuedRan = AtomicBool(false)
        let active = { _prepared: GatewayPreparedInbound, control: GatewayInboundExecutionControl =>
            activeStarted.store(true)
            while (!control.isCancelled()) { sleep(Duration.millisecond) }
        }
        let queued = { _prepared: GatewayPreparedInbound, _control: GatewayInboundExecutionControl => queuedRan.store(true) }
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("active", "key-active"), active).status, "started")
        @Expect(gatewayInboundDispatcherTestWait({ => activeStarted.load() }), true)
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("q1", "key-q1"), queued).status, "queued")
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("q2", "key-q2"), queued).status, "queued")
        let overflow = dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("q3", "key-q3"), queued)
        @Expect(overflow.ok, false)
        @Expect(overflow.status, "inbound_queue_full")
        @Expect(overflow.messageId, "q3")
        @Expect(overflow.orderKey, "key-q3")
        let stopped = dispatcher.stop(timeoutMs: 500)
        @Expect(stopped.ok, true)
        @Expect(stopped.status, "stopped")
        @Expect(queuedRan.load(), false)
        @Expect(dispatcher.isAccepting(), false)
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("late", "key-late"), queued).status, "inbound_stopping")
    }

    @TestCase
    public func p4N1NonCooperativeActiveTaskMakesStopTimeoutObservable(): Unit {
        let dispatcher = GatewayInboundDispatcher(maxActive: 1, maxQueued: 0)
        let release = AtomicBool(false)
        let started = AtomicBool(false)
        @Expect(dispatcher.enqueue(gatewayInboundDispatcherTestPrepared("slow", "key"), { _, _ =>
            started.store(true)
            while (!release.load()) { sleep(Duration.millisecond) }
        }).ok, true)
        @Expect(gatewayInboundDispatcherTestWait({ => started.load() }), true)
        let stopped = dispatcher.stop(timeoutMs: 10)
        @Expect(stopped.ok, false)
        @Expect(stopped.status, "inbound_drain_timeout")
        @Expect(stopped.active, 1)
        release.store(true)
        @Expect(gatewayInboundDispatcherTestWait({ => dispatcher.activeCount() == 0 }), true)
    }
}
