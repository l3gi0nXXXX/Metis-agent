package metis.gateway.channels.feishu

import metis.gateway.model.FeishuConfig
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

private class FeishuRuntimeStateFakeLongConnectTransport <: FeishuLongConnectTransport {
    private let events: Array<JsonObject>
    private let result: FeishuLongConnectStartResult

    public init(
        events!: Array<JsonObject> = [],
        result!: FeishuLongConnectStartResult = FeishuLongConnectStartResult(ok: true, status: "ready")
    ) {
        this.events = events
        this.result = result
    }

    public func start(_spec: FeishuLongConnectStartSpec, eventHandler: (JsonObject) -> Unit): FeishuLongConnectStartResult {
        for (event in this.events) {
            eventHandler(event)
        }
        this.result
    }

    public func stop(): Unit {}
}

@Test
public class FeishuAdapterRuntimeStateTest {
    private func jsonString(obj: JsonObject, key: String): String {
        try { obj.get(key).getOrThrow().asString().getValue() } catch (_: Exception) { "" }
    }

    private func jsonBool(obj: JsonObject, key: String): Bool {
        try { obj.get(key).getOrThrow().asBool().getValue() } catch (_: Exception) { false }
    }

    private func jsonInt(obj: JsonObject, key: String): Int64 {
        try { obj.get(key).getOrThrow().asInt().getValue() } catch (_: Exception) { 0 }
    }

    private func sidecarDiagnosticRoot(
        accountId: String,
        phase!: String = "background",
        status!: String = "failed",
        message!: String = "",
        error!: String = ""
    ): JsonObject {
        let header = JsonObject()
        header.put("event_type", JsonString("metis.feishu.sidecar.diagnostic"))
        header.put("account_id", JsonString(accountId))
        let sidecar = JsonObject()
        sidecar.put("phase", JsonString(phase))
        sidecar.put("status", JsonString(status))
        sidecar.put("message", JsonString(message))
        if (!error.trimAscii().isEmpty()) {
            sidecar.put("error", JsonString(error))
        }
        let root = JsonObject()
        root.put("header", header)
        root.put("sidecar", sidecar)
        root
    }

    private func readyFrame(accountId: String): JsonObject {
        let root = JsonObject()
        root.put("type", JsonString("ready"))
        root.put("accountId", JsonString(accountId))
        root.put("transport", JsonString("websocket"))
        root.put("supervisorPid", JsonInt(4321))
        root.put("sidecarProtocolVersion", JsonString("metis.feishu.sidecar.v1"))
        root
    }

    private func closedFrame(accountId: String, reason: String): JsonObject {
        let root = JsonObject()
        root.put("type", JsonString("closed"))
        root.put("accountId", JsonString(accountId))
        root.put("reason", JsonString(reason))
        root
    }

    private func inboundFrame(accountId: String, messageId: String): JsonObject {
        let senderId = JsonObject()
        senderId.put("open_id", JsonString("ou_runtime_sender"))
        let sender = JsonObject()
        sender.put("sender_id", senderId)
        let message = JsonObject()
        message.put("message_id", JsonString(messageId))
        message.put("chat_id", JsonString("oc_runtime"))
        message.put("chat_type", JsonString("group"))
        message.put("message_type", JsonString("text"))
        message.put("content", JsonString("{\"text\":\"runtime hello\"}"))
        let event = JsonObject()
        event.put("sender", sender)
        event.put("message", message)
        let root = JsonObject()
        root.put("type", JsonString("inbound"))
        root.put("accountId", JsonString(accountId))
        root.put("eventType", JsonString("im.message.receive_v1"))
        root.put("event", event)
        root
    }

    private func startedAdapter(events: Array<JsonObject>, accountId!: String = "tenant-a", config!: FeishuConfig = FeishuConfig(enabled: true, appId: "runtime-app", appSecret: "runtime-secret", receiveMode: "long_connect")): FeishuAdapter {
        let adapter = FeishuAdapter(
            config: config,
            accountId: accountId,
            longConnectTransport: FeishuRuntimeStateFakeLongConnectTransport(events: events)
        )
        adapter.start()
        adapter
    }

    @TestCase
    public func initFailureWritesAccountLastError(): Unit {
        let adapter = FeishuAdapter(
            config: FeishuConfig(enabled: true, appId: "runtime-app", appSecret: "runtime-secret", receiveMode: "long_connect"),
            accountId: "tenant-a",
            longConnectTransport: FeishuRuntimeStateFakeLongConnectTransport(
                result: FeishuLongConnectStartResult(ok: false, status: "missing_dependency", error: "sidecar package missing")
            )
        )
        try { adapter.start() } catch (_: Exception) { () }

        let runtime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a")

        @Expect(this.jsonString(runtime, "lifecycleState"), "failed")
        @Expect(this.jsonBool(runtime, "running"), false)
        @Expect(this.jsonBool(runtime, "connected"), false)
        @Expect(this.jsonString(runtime, "errorKind"), "missing_dependency")
        @Expect(this.jsonString(runtime, "lastError").contains("sidecar package missing"), true)
    }

    @TestCase
    public func diagnosticFrameUpdatesLastDiagnosticPhase(): Unit {
        let adapter = this.startedAdapter([
            this.sidecarDiagnosticRoot("tenant-a", phase: "websocket.open", status: "ok", message: "connected")
        ])

        let runtime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a")

        @Expect(this.jsonString(runtime, "lastDiagnosticPhase"), "websocket.open")
        @Expect(this.jsonString(runtime, "lastError"), "")
        @Expect(this.jsonString(runtime, "lifecycleState"), "running")
    }

    @TestCase
    public func inboundFrameUpdatesLastInboundAt(): Unit {
        let adapter = this.startedAdapter([
            this.inboundFrame("tenant-a", "om_runtime_inbound")
        ])

        let runtime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a")

        @Expect(this.jsonInt(runtime, "lastInboundAt") > 0, true)
        @Expect(this.jsonBool(runtime, "connected"), true)
        @Expect(adapter.pullInbound().size, 1)
    }

    @TestCase
    public func readyFrameUpdatesLastReadyAtAndConnected(): Unit {
        let adapter = this.startedAdapter([
            this.readyFrame("tenant-a")
        ])

        let runtime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a")

        @Expect(this.jsonInt(runtime, "lastReadyAt") > 0, true)
        @Expect(this.jsonBool(runtime, "connected"), true)
        @Expect(this.jsonBool(runtime, "running"), true)
        @Expect(this.jsonString(runtime, "transportMode"), "websocket")
        @Expect(this.jsonInt(runtime, "supervisorPid"), 4321)
        @Expect(this.jsonString(runtime, "sidecarProtocolVersion"), "metis.feishu.sidecar.v1")
    }

    @TestCase
    public func backgroundDisconnectWritesAccountError(): Unit {
        let adapter = this.startedAdapter([
            this.closedFrame("tenant-a", "websocket.close")
        ])

        let runtime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a")
        var threw = false
        try {
            let _ = adapter.pullInbound()
        } catch (_: Exception) {
            threw = true
        }

        @Expect(this.jsonString(runtime, "lifecycleState"), "disconnected")
        @Expect(this.jsonBool(runtime, "connected"), false)
        @Expect(this.jsonString(runtime, "errorKind"), "closed")
        @Expect(this.jsonString(runtime, "lastError").contains("websocket.close"), true)
        @Expect(threw, true)
    }

    @TestCase
    public func unknownDiagnosticAccountDoesNotPolluteDefaultAccount(): Unit {
        let adapter = this.startedAdapter([
            this.sidecarDiagnosticRoot("tenant-ghost", phase: "background", status: "failed", error: "ghost disconnect")
        ], accountId: "default")

        let defaultRuntime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("default")
        let ghostRuntime = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-ghost")

        @Expect(this.jsonString(defaultRuntime, "lastError"), "")
        @Expect(this.jsonString(defaultRuntime, "lifecycleState"), "running")
        @Expect(this.jsonString(ghostRuntime, "lastError").contains("ghost disconnect"), true)
        @Expect(this.jsonString(ghostRuntime, "lifecycleState"), "failed")
    }

    @TestCase
    public func runtimeDiagnosticsRedactSecrets(): Unit {
        let config = FeishuConfig(
            enabled: true,
            appId: "runtime-app",
            appSecret: "actual-app-secret-value",
            receiveMode: "long_connect",
            verificationToken: "actual-verification-token",
            encryptKey: "actual-encrypt-key"
        )
        let adapter = this.startedAdapter([
            this.sidecarDiagnosticRoot(
                "tenant-a",
                phase: "dependency.preflight",
                status: "failed",
                error: "actual-app-secret-value actual-verification-token actual-encrypt-key Authorization: Bearer bearer-secret"
            )
        ], config: config)

        let raw = adapter.debugFeishuLongConnectRuntimeDiagnosticsForAccountForTest("tenant-a").toJsonString()

        @Expect(raw.contains("actual-app-secret-value"), false)
        @Expect(raw.contains("actual-verification-token"), false)
        @Expect(raw.contains("actual-encrypt-key"), false)
        @Expect(raw.contains("bearer-secret"), false)
        @Expect(raw.contains("[redacted]"), true)
    }
}
