package metis.gateway.core

import metis.core.config.GatewayUserSettings
import metis.gateway.model.{InboundMessage, RouteDecision}
import std.collection.{ArrayList, HashSet}
import std.sync.{Condition, Mutex}
import std.time.DateTime
import std.core.Duration

public class GatewayPreparedInbound {
    public let message: InboundMessage
    public let effectiveAccountId: String
    public let user: GatewayUserSettings
    public let decision: RouteDecision
    public let conversationKey: String
    public let orderKey: String
    public let bindingAccountId: String
    public let bindingConversationId: String

    public init(
        message: InboundMessage,
        effectiveAccountId: String,
        user: GatewayUserSettings,
        decision: RouteDecision,
        conversationKey: String,
        orderKey: String,
        bindingAccountId!: String = "",
        bindingConversationId!: String = ""
    ) {
        this.message = message
        this.effectiveAccountId = effectiveAccountId.trimAscii()
        this.user = user
        this.decision = decision
        this.conversationKey = conversationKey.trimAscii()
        this.orderKey = orderKey.trimAscii()
        this.bindingAccountId = bindingAccountId.trimAscii()
        this.bindingConversationId = bindingConversationId.trimAscii()
    }
}

public class GatewayInboundExecutionControl {
    private let lock = Mutex()
    private var cancelled: Bool = false

    public init() {}

    public func cancel(): Unit { synchronized(this.lock) { this.cancelled = true } }

    public func isCancelled(): Bool { synchronized(this.lock) { this.cancelled } }
}

public class GatewayInboundEnqueueResult {
    public let ok: Bool
    public let status: String
    public let sequence: Int64
    public let messageId: String
    public let orderKey: String

    public init(ok: Bool, status: String, sequence!: Int64 = 0, messageId!: String = "", orderKey!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.sequence = sequence
        this.messageId = messageId.trimAscii()
        this.orderKey = orderKey.trimAscii()
    }
}

public class GatewayInboundStopResult {
    public let ok: Bool
    public let status: String
    public let active: Int64
    public let queued: Int64

    public init(ok: Bool, status: String, active!: Int64 = 0, queued!: Int64 = 0) {
        this.ok = ok
        this.status = status.trimAscii()
        this.active = active
        this.queued = queued
    }
}

private class GatewayInboundDispatchTask {
    let prepared: GatewayPreparedInbound
    let sequence: Int64
    let control = GatewayInboundExecutionControl()
    let execute: (GatewayPreparedInbound, GatewayInboundExecutionControl) -> Unit

    init(
        prepared: GatewayPreparedInbound,
        sequence: Int64,
        execute: (GatewayPreparedInbound, GatewayInboundExecutionControl) -> Unit
    ) {
        this.prepared = prepared
        this.sequence = sequence
        this.execute = execute
    }
}

/** Bounded per-order-key dispatcher. No caller callback executes while `lock` is held. */
public class GatewayInboundDispatcher {
    private let lock = Mutex()
    private let condition: Condition
    private let maxActive: Int64
    private let maxQueued: Int64
    private var accepting: Bool = true
    private var active: Int64 = 0
    private var sequence: Int64 = 0
    private let activeKeys = HashSet<String>()
    private let activeTasks = ArrayList<GatewayInboundDispatchTask>()
    private let queued = ArrayList<GatewayInboundDispatchTask>()

    public init(maxActive!: Int64 = 8, maxQueued!: Int64 = 128) {
        this.maxActive = max(1, maxActive)
        this.maxQueued = max(0, maxQueued)
        synchronized(this.lock) { this.condition = this.lock.condition() }
    }

    private func nowMs(): Int64 { DateTime.now().toUnixTimeStamp().toMilliseconds() }

    public func enqueue(
        prepared: GatewayPreparedInbound,
        execute: (GatewayPreparedInbound, GatewayInboundExecutionControl) -> Unit
    ): GatewayInboundEnqueueResult {
        var launch = None<GatewayInboundDispatchTask>
        let result = synchronized(this.lock) {
            if (!this.accepting) {
                return GatewayInboundEnqueueResult(
                    false,
                    "inbound_stopping",
                    messageId: prepared.message.messageId,
                    orderKey: prepared.orderKey
                )
            }
            this.sequence += 1
            let task = GatewayInboundDispatchTask(prepared, this.sequence, execute)
            if (this.active < this.maxActive && !this.activeKeys.contains(prepared.orderKey)) {
                this.reserveLocked(task)
                launch = Some(task)
            } else {
                if (Int64(this.queued.size) >= this.maxQueued) {
                    return GatewayInboundEnqueueResult(
                        false,
                        "inbound_queue_full",
                        sequence: task.sequence,
                        messageId: prepared.message.messageId,
                        orderKey: prepared.orderKey
                    )
                }
                this.queued.add(task)
            }
            GatewayInboundEnqueueResult(
                true,
                if (launch.isSome()) { "started" } else { "queued" },
                sequence: task.sequence,
                messageId: prepared.message.messageId,
                orderKey: prepared.orderKey
            )
        }
        match (launch) { case Some(task) => this.launch(task) case None => () }
        result
    }

    private func reserveLocked(task: GatewayInboundDispatchTask): Unit {
        this.active += 1
        this.activeKeys.add(task.prepared.orderKey)
        this.activeTasks.add(task)
    }

    private func launch(task: GatewayInboundDispatchTask): Unit {
        spawn {
            try {
                if (!task.control.isCancelled()) { task.execute(task.prepared, task.control) }
            } finally {
                this.complete(task)
            }
        }
    }

    private func complete(task: GatewayInboundDispatchTask): Unit {
        var next = None<GatewayInboundDispatchTask>
        synchronized(this.lock) {
            this.active -= 1
            this.activeKeys.remove(task.prepared.orderKey)
            let retained = ArrayList<GatewayInboundDispatchTask>()
            for (activeTask in this.activeTasks) {
                if (activeTask.sequence != task.sequence) { retained.add(activeTask) }
            }
            this.activeTasks.clear()
            for (activeTask in retained) { this.activeTasks.add(activeTask) }
            if (this.accepting && this.active < this.maxActive) {
                var index: Int64 = -1
                for (i in 0..this.queued.size) {
                    if (!this.activeKeys.contains(this.queued[i].prepared.orderKey)) {
                        index = Int64(i)
                        break
                    }
                }
                if (index >= 0) {
                    let selected = this.queued.remove(at: index)
                    this.reserveLocked(selected)
                    next = Some(selected)
                }
            }
            this.condition.notifyAll()
        }
        match (next) { case Some(value) => this.launch(value) case None => () }
    }

    public func stop(timeoutMs!: Int64 = 3000): GatewayInboundStopResult {
        let deadline = this.nowMs() + max(1, timeoutMs)
        synchronized(this.lock) {
            this.accepting = false
            for (task in this.queued) { task.control.cancel() }
            this.queued.clear()
            for (task in this.activeTasks) { task.control.cancel() }
            while (this.active > 0) {
                let remaining = deadline - this.nowMs()
                if (remaining <= 0) {
                    return GatewayInboundStopResult(false, "inbound_drain_timeout", active: this.active)
                }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            GatewayInboundStopResult(true, "stopped")
        }
    }

    public func activeCount(): Int64 { synchronized(this.lock) { this.active } }

    public func queuedCount(): Int64 { synchronized(this.lock) { Int64(this.queued.size) } }

    public func isAccepting(): Bool { synchronized(this.lock) { this.accepting } }
}
