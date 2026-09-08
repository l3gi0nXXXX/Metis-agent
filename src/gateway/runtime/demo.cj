package metis.gateway.runtime

import metis.core.{gatewayClearSubagentNoticeDeliveryHook, gatewayClearSubagentNoticeEventHook, gatewayRegisterSubagentNoticeDeliveryHook}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisConfigWriteNotificationListener}
import metis.gateway.config.buildGatewayConfigFromUserSettings
import metis.gateway.gatewayPrepareStartupAuth
import metis.gateway.core.{GatewayStopResult, gatewayLogMeta, gatewayLogProcessMemory, gatewayRuntimeHeapSnapshot}
import metis.gateway.logging.{MetisLogEvent, gatewayLoggingCurrentLogFile, metisCreateSubsystemLogger}
import metis.core.memory.{DreamingPhaseRuntime, MemoryRuntime}
import metis.io.PrintUtils
import metis.gateway.model.ChatType
import metis.utils.InfoUtils
import std.env.{getVariable, setVariable}
import std.time.*
import stdx.encoding.json.JsonObject

private let gatewayServeLogger = metisCreateSubsystemLogger("gateway/runtime")
private let gatewayHeartbeatCadenceTestNonce = "heartbeat-e2e-v1"
private const GATEWAY_RECOMMENDED_MIN_HEAP_BYTES: Int64 = 1073741824
private const GATEWAY_RUNTIME_MIN_HEAP_BYTES: Int64 = 4194304

public class GatewayRuntimeHeapPolicyResult {
    public let ok: Bool
    public let configured: Bool
    public let expectedBytes: Int64
    public let status: String

    public init(ok: Bool, configured: Bool, expectedBytes: Int64, status: String) {
        this.ok = ok
        this.configured = configured
        this.expectedBytes = expectedBytes
        this.status = status
    }
}

private func gatewayRuntimeHeapDigitValue(value: Rune): Int64 {
    match (value) {
        case r'0' => 0
        case r'1' => 1
        case r'2' => 2
        case r'3' => 3
        case r'4' => 4
        case r'5' => 5
        case r'6' => 6
        case r'7' => 7
        case r'8' => 8
        case r'9' => 9
        case _ => -1
    }
}

/** Parses the documented integer KB/MB/GB subset without retaining or logging the raw value. */
public func gatewayValidateRuntimeHeapPolicy(raw: Option<String>, actualMaxHeapBytes: Int64,
                                             platform: String): GatewayRuntimeHeapPolicyResult {
    if (platform != "macos" && platform != "linux") {
        return GatewayRuntimeHeapPolicyResult(false, raw.isSome(), -1, "unsupported_platform")
    }
    let configured = match (raw) {
        case Some(value) => value
        case None => return GatewayRuntimeHeapPolicyResult(true, false, -1, "unset")
    }
    let runes = configured.toAsciiLower().toRuneArray()
    if (runes.size < 3) {
        return GatewayRuntimeHeapPolicyResult(false, true, -1, "invalid_syntax")
    }
    let suffixStart = runes.size - 2
    let factor: Int64 = if (runes[suffixStart] == r'k' && runes[suffixStart + 1] == r'b') {
        1024
    } else if (runes[suffixStart] == r'm' && runes[suffixStart + 1] == r'b') {
        1048576
    } else if (runes[suffixStart] == r'g' && runes[suffixStart + 1] == r'b') {
        1073741824
    } else {
        return GatewayRuntimeHeapPolicyResult(false, true, -1, "invalid_syntax")
    }
    var amount: Int64 = 0
    for (i in 0..suffixStart) {
        let digit = gatewayRuntimeHeapDigitValue(runes[i])
        if (digit < 0) {
            return GatewayRuntimeHeapPolicyResult(false, true, -1, "invalid_syntax")
        }
        if (amount > (Int64.Max - digit) / 10) {
            return GatewayRuntimeHeapPolicyResult(false, true, -1, "overflow")
        }
        amount = amount * 10 + digit
    }
    if (amount > Int64.Max / factor) {
        return GatewayRuntimeHeapPolicyResult(false, true, -1, "overflow")
    }
    let expectedBytes = amount * factor
    if (expectedBytes < GATEWAY_RUNTIME_MIN_HEAP_BYTES) {
        return GatewayRuntimeHeapPolicyResult(false, true, expectedBytes, "below_runtime_minimum")
    }
    if (actualMaxHeapBytes != expectedBytes) {
        return GatewayRuntimeHeapPolicyResult(false, true, expectedBytes, "effective_mismatch")
    }
    GatewayRuntimeHeapPolicyResult(true, true, expectedBytes, "ok")
}

public func gatewayHeartbeatPollCadenceForTest(): Int64 {
    let mode = getVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_MODE").getOrDefault { "" }.trimAscii()
    let nonce = getVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_NONCE").getOrDefault { "" }.trimAscii()
    let cadence = getVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_POLLS").getOrDefault { "" }.trimAscii()
    setVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_MODE", "")
    setVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_NONCE", "")
    setVariable("METIS_TEST_GATEWAY_HEARTBEAT_CADENCE_POLLS", "")
    if (mode == "1" && nonce == gatewayHeartbeatCadenceTestNonce) {
        if (cadence == "2") { return 2 }
        if (cadence == "5") { return 5 }
    }
    50
}

private func gatewayServeNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toNanoseconds() / 1000000
}

private func gatewayServeTimingLog(step: String, startMs: Int64): Unit {
    let elapsedMs = gatewayServeNowMs() - startMs
    gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve.timing: step=${step} elapsedMs=${elapsedMs}")
    gatewayLogProcessMemory("serve:${step}", note: "elapsedMs=${elapsedMs}")
}

/**
 * Gateway P0 本地联调示例。
 *
 * 运行流程：
 * 1) 组装 Gateway + FeishuAdapter
 * 2) 启动网关
 * 3) 模拟一条飞书私聊入站消息
 * 4) 处理一次消息循环
 * 5) 输出发送日志，验证链路已打通
 */
public func runGatewayP0Demo(): Unit {
    let (gateway, feishu) = buildP0Gateway()
    gateway.start()

    // 注入一条模拟消息用于端到端验证。
    feishu.simulateIncomingText(
        "msg-demo-1",
        "chat-demo-1",
        "user-demo-1",
        "你好，Gateway P0",
        chatType: ChatType.Direct,
        mentioned: true
    )

    gateway.processOnce()
    let logs = feishu.getOutboundLog()

    // Demo-only shell output; production `runGatewayService` reports through gatewayShellPrintLines/logger.
    PrintUtils.printLine("Gateway P0 demo finished. Outbound messages: ${logs.size}")
    for (msg in logs) {
        PrintUtils.printLine(" - channel=feishu peer=${msg.peerId} text=${msg.text}")
    }

    gateway.stop()
}

/**
 * Gateway P1 联调示例（飞书 webhook 文本事件）。
 */
public func runGatewayP1DemoWithFeishuWebhook(): Unit {
    let (gateway, feishu) = buildP0Gateway()
    gateway.start()

    let webhookPayload = """
{
  "schema": "2.0",
  "header": {
    "event_type": "im.message.receive_v1"
  },
  "event": {
    "sender": {
      "sender_id": {
        "open_id": "ou_demo_user"
      }
    },
    "message": {
      "message_id": "om_demo_message",
      "chat_id": "oc_demo_chat",
      "chat_type": "p2p",
      "message_type": "text",
      "content": "{\"text\":\"你好，请介绍一下你自己\"}"
    }
  }
}
"""
    let ack = feishu.ingestWebhookPayload(webhookPayload)
    // Demo-only shell output; production `runGatewayService` reports through gatewayShellPrintLines/logger.
    PrintUtils.printLine("Feishu webhook ack: ${ack}")

    gateway.processOnce()
    let logs = feishu.getOutboundLog()
    PrintUtils.printLine("Gateway P1 demo finished. Outbound messages: ${logs.size}")
    for (msg in logs) {
        PrintUtils.printLine(" - channel=feishu peer=${msg.peerId} text=${msg.text}")
    }
    gateway.stop()
}

/**
 * 常驻模式：启动网关并循环处理消息。
 * 配置来自 `~/.metis/metis.json` 的 `gateway` 与可选环境变量；总开关为 `gateway.enabled`。
 */
public func runGatewayService(verbose!: Bool = false): Int64 {
    let startMs = gatewayServeNowMs()
    let startupHeap = gatewayRuntimeHeapSnapshot()
    let heapPolicy = gatewayValidateRuntimeHeapPolicy(getVariable("cjHeapSize"), startupHeap.maxHeapBytes, InfoUtils.os)
    if (!heapPolicy.ok) {
        gatewayServeLogger.error(
            MetisLogEvent.processMemory,
            "gateway runtime heap configuration is invalid",
            meta: gatewayLogMeta()
                .string("status", "runtime_heap_configuration_invalid")
                .string("reason", heapPolicy.status)
                .int("actualMaxHeapBytes", startupHeap.maxHeapBytes)
                .object()
        )
        return 1
    }
    let heartbeatPollCadence = gatewayHeartbeatPollCadenceForTest()
    gatewayLogProcessMemory("serve:startup_begin")
    if (startupHeap.managedHeapStatus == "ok" && startupHeap.maxHeapBytes < GATEWAY_RECOMMENDED_MIN_HEAP_BYTES) {
        gatewayServeLogger.warn(
            MetisLogEvent.processMemory,
            "gateway runtime heap is below the recommended minimum",
            meta: gatewayLogMeta()
                .string("status", "runtime_heap_below_recommended")
                .int("maxHeapBytes", startupHeap.maxHeapBytes)
                .int("recommendedMinHeapBytes", GATEWAY_RECOMMENDED_MIN_HEAP_BYTES)
                .object()
        )
    }
    gatewayServeLogger.info(MetisLogEvent.gatewayStarting, "Gateway serve starting")
    gatewayServeTimingLog("enter", startMs)
    let persistedUser = CliSettingManager.readGatewaySettings()
    let (user, generatedAuthToken, _) = gatewayPrepareStartupAuth(persistedUser)
    gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: read settings gateway.enabled=${user.enabled}")
    gatewayServeTimingLog("settings-ready", startMs)
    if (!user.enabled) {
        gatewayRuntimeMarkStopped(reason: "disabled")
        gatewayServeLogger.warn(MetisLogEvent.gatewayShutdown, "Gateway serve aborted because gateway.enabled=false")
        gatewayServeTimingLog("disabled", startMs)
        gatewayShellPrintLines(["网关总开关已关闭（metis.json 中 gateway.enabled=false）。执行：metis gateway master on"])
        return 0
    }
    if (!gatewayAcquireServeLockForRunningProcess()) {
        gatewayRuntimeMarkStopped(reason: "lock-not-acquired")
        gatewayServeLogger.error(MetisLogEvent.gatewayShutdown, "Gateway serve aborted because serve lock was not acquired")
        gatewayServeTimingLog("lock-failed", startMs)
        gatewayShellPrintLines(["[网关] 无法启动：检测到已有网关实例在运行，或锁文件 ~/.metis/gateway-serve.lock 仍有效。请先关闭旧网关窗口后再试。"])
        return 0
    }
    gatewayRuntimeMarkStarting()
    gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: serve lock acquired, building gateway service")
    gatewayServeTimingLog("lock-acquired", startMs)
    let (gateway, feishu) = buildGatewayServiceFromUserSettings(user)
    let gatewayCfg = buildGatewayConfigFromUserSettings(user)
    let serveIdentity = gatewayCurrentServeIdentity()
    gatewayServeTimingLog("service-built", startMs)
    gatewayRegisterActiveService(gateway)
    gatewayRegisterSubagentNoticeDeliveryHook({ channelName, accountId, peerId, notice, replyToMessageId, replyInThread =>
        gateway.sendTextToPeerDetailed(
            channelName,
            peerId,
            notice,
            replyToMessageId: if (replyToMessageId.trimAscii().isEmpty()) { None<String> } else { Some<String>(replyToMessageId.trimAscii()) },
            replyInThread: replyInThread,
            accountId: accountId
        )
    })
    gatewayEnsureSubagentNoticeEventPublisherRegistered()
    GatewayServer.startGatewayServer(options: gatewayServerOptionsFromConfig(gatewayCfg))
    gatewayServeTimingLog("rpc-server-started", startMs)
    let cronRunner = CronRunner(
        gatewayOpt: Some(gateway),
        cronEnabled: user.cronEnabled,
        maxConcurrentRuns: user.cronMaxConcurrentRuns,
        cronDefaultTimeoutMs: user.cronDefaultTimeoutMs,
        cronSafetyTimeoutMs: user.cronSafetyTimeoutMs,
        cronIdleTimeoutMs: user.cronIdleTimeoutMs
    )
    cronRunner.start()
    registerGatewayCronRunHookForRunner(cronRunner)
    try {
        if (generatedAuthToken) {
            gatewayServeLogger.debug(
                MetisLogEvent.loggingRaw,
                "Gateway.serve: startup auth generated runtime-only gateway.auth.token for this startup; config was not modified."
            )
        }
        let reconcileOut = DreamingPhaseRuntime.reconcileManagedCronJobs()
        if (!reconcileOut.trimAscii().isEmpty()) {
            gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: dreaming reconcile => ${reconcileOut.replace("\n", " | ")}")
        }
        // Keep gateway control-plane startup compact. QMD maintenance/indexing can be
        // triggered manually instead of scanning the workspace during gateway boot.
        if (gatewayHttpAnyEndpointEnabled(gatewayCfg)) {
            GatewayHttpSurface.startIfNeeded(gatewayCfg)
            gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: HTTP surface started at ${GatewayHttpSurface.baseUrl(gatewayCfg)}")
            gatewayServeTimingLog("http-started", startMs)
        }
        if (gatewayCfg.controlUi.enabled) {
            GatewayControlUiRuntime.startIfEnabled(gatewayCfg)
            let snapshot = GatewayControlUiRuntime.controlUiSnapshot(gatewayCfg)
            let rootState = gatewayControlUiRootStateJson(gatewayCfg)
            let assetMode = match (gatewayControlUiSnapshotJson(gatewayCfg).get("assetMode")) {
                case Some(v) =>
                    try { v.asString().getValue() } catch (_e: Exception) { "inline-fallback" }
                case None => "inline-fallback"
            }
            let rootKind = match (rootState.get("kind")) {
                case Some(v) =>
                    try { v.asString().getValue() } catch (_e: Exception) { "" }
                case None => ""
            }
            gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: control UI embedded at ${snapshot.httpUrl} assetMode=${assetMode} rootState=${rootKind}")
            if (assetMode == "inline-fallback") {
                gatewayServeLogger.warn(MetisLogEvent.loggingRaw, "Gateway.serve: control UI is using legacy inline fallback; restore bundled static assets or set gateway.controlUi.root to a built static UI directory for the formal production path.")
            }
            gatewayServeTimingLog("control-ui-started", startMs)
        }
        if (gatewayCfg.canvas.enabled) {
            GatewayCanvasHostRuntime.startIfNeeded(gatewayCfg)
            let canvas = GatewayCanvasHostRuntime.snapshot(gatewayCfg)
            let phase = match (canvas.get("phase")) {
                case Some(v) =>
                    try { v.asString().getValue() } catch (_e: Exception) { "" }
                case None => ""
            }
            let errorKind = match (canvas.get("errorKind")) {
                case Some(v) =>
                    try { v.asString().getValue() } catch (_e: Exception) { "" }
                case None => ""
            }
            gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: canvas host phase=${phase} errorKind=${errorKind}")
            gatewayServeTimingLog("canvas-host-started", startMs)
        }
        gatewayPlatformMarkRunning(gatewayCfg)
        gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: calling gateway.start()")
        gatewayServeTimingLog("gateway-start-begin", startMs)
        gatewayLogProcessMemory("serve:gateway_start_before")
        gateway.start()
        gatewayLogProcessMemory("serve:gateway_start_after")
        gatewayRuntimeMarkRunning()
        gatewayLogProcessMemory("serve:ready")
        gatewayServeLogger.info(MetisLogEvent.gatewayReady, "Gateway serve ready")
        gatewayShellPrintLines(gatewayShellReadySummaryLines(
            CliConfig.model,
            gatewayLoggingCurrentLogFile(),
            GatewayHttpSurface.baseUrl(gatewayCfg),
            if (gatewayCfg.controlUi.enabled) { GatewayControlUiRuntime.controlUiSnapshot(gatewayCfg).httpUrl } else { "" },
            gateway.liveChannelSnapshot(),
            gatewayServeNowMs() - startMs,
            verbose: verbose
        ))
        gatewayServeTimingLog("gateway-start-done", startMs)
        let reloadSnapshot = readGatewayConfigSnapshot()
        let reloadRoot = if (reloadSnapshot.valid) { reloadSnapshot.root } else { JsonObject() }
        let configReloader = GatewayConfigReloader(
            reloadRoot,
            GatewayServiceConfigReloadCallbacks(GatewayServiceReloadChannelRuntime(gateway))
        )
        let memoryArm = MemoryRuntime.armSearchBackend(purpose: "gateway-startup")
        match (memoryArm.manager) {
            case Some(manager) =>
                gatewayServeLogger.debug(
                    MetisLogEvent.loggingRaw,
                    "Gateway.serve: memory backend armed provider=${manager.backendConfig.providerId} backend=${manager.backendConfig.backend}"
                )
            case None =>
                let error = memoryArm.error.trimAscii()
                if (!error.isEmpty()) {
                    gatewayServeLogger.error(MetisLogEvent.loggingRaw, "Gateway.serve: memory backend arm failed: ${error}")
                }
        }
        gatewayServeLogger.debug(
            MetisLogEvent.loggingRaw,
            "Gateway.serve: gateway.start() returned, entering poll loop (IM/processOnce 200ms; cron tick 按需，臂长≤60s 对齐当前 armTimer 语义)"
        )
        gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: cron store=${cronRunner.storeFilePath().toString()}")
        gatewayServeTimingLog("poll-loop-enter", startMs)
        feishu.printFeishuIngressHints()

        var heartbeatTick: Int64 = 0
        while (true) {
            match (serveIdentity) {
                case Some(identity) => if (gatewayServeStopRequested(identity)) { break }
                case None => ()
            }
            gateway.processOnce()
            gatewayRuntimeMarkPollCompleted(gateway.operationalSnapshot())
            configReloader.pollOnce()
            cronRunner.tick()
            heartbeatTick += 1
            if (heartbeatTick % heartbeatPollCadence == 0) {
                gatewayRefreshServeLockMtime()
                gatewayRuntimeHeartbeat()
                gatewayPlatformHeartbeat(gatewayCfg)
                // 无入站消息时文件里仍应有迹可循，便于区分「未拉到消息」与「进程未进循环」
                gatewayServeLogger.debug(MetisLogEvent.loggingRaw, "Gateway.serve: heartbeat pollTicks=${heartbeatTick} (~${heartbeatTick * 200 / 1000}s)")
            }
            sleep(Duration.millisecond * 200)
        }
    } finally {
        gatewayLogProcessMemory("serve:stop_begin")
        let shutdownDeadline = MonoTime.now() + Duration.millisecond * GATEWAY_SERVE_GRACEFUL_SHUTDOWN_TIMEOUT_MS
        // Cron 清理仍可能需要 channel/session；必须在 Gateway teardown 前完成有界取消与收割。
        let _ = cronRunner.stop(reason: "gateway_shutdown", drainTimeoutMs: 5000)
        MetisConfigManager.setWriteRootNotificationHook(None<MetisConfigWriteNotificationListener>)
        MemoryRuntime.stopActiveMaintenance()
        let canvasStop = try {
            GatewayCanvasHostRuntime.stopDetailed(shutdownDeadline)
        } catch (_: Exception) {
            GatewaySurfaceStopResult(false, "close_failed")
        }
        match (serveIdentity) {
            case Some(identity) => let _ = gatewayPublishShutdownPhaseForTest(identity, "canvas_done")
            case None => ()
        }
        let httpStop = try {
            GatewayHttpSurface.stopDetailed(shutdownDeadline, shutdownIdentity: serveIdentity)
        } catch (_: Exception) {
            GatewaySurfaceStopResult(false, "close_failed")
        }
        let gatewayServerStop = try {
            GatewayServer.defaultServer().stopServerDetailed(reason: "gateway-serve-shutdown")
        } catch (_: Exception) {
            GatewaySurfaceStopResult(false, "persistence_failed")
        }
        match (serveIdentity) {
            case Some(identity) => let _ = gatewayPublishShutdownPhaseForTest(identity, "gateway_stop_enter")
            case None => ()
        }
        let gatewayStop = try {
            let shutdownObserver = match (serveIdentity) {
                case Some(identity) => Some<(String) -> Unit>({ phase: String =>
                    let _ = gatewayPublishShutdownPhaseForTest(identity, phase)
                })
                case None => None<(String) -> Unit>
            }
            let result = gateway.stop(shutdownObserver: shutdownObserver)
            match (serveIdentity) {
                case Some(identity) => let _ = gatewayPublishShutdownPhaseForTest(identity, "gateway_stop_returned")
                case None => ()
            }
            result
        } catch (_: Exception) {
            GatewayStopResult(false, "cleanup_pending", diagnostic: "gateway_stop_exception")
        }
        gatewayClearActiveService()
        gatewayClearSubagentNoticeDeliveryHook()
        gatewayClearSubagentNoticeEventHook()
        gatewayResetSubagentNoticeEventPublisherRegistration()
        gatewayPlatformMarkStopped(gatewayCfg)
        gatewayRuntimeMarkStopped(reason: if (gatewayStop.ok) { "shutdown" } else { "cleanup_pending" })
        match (serveIdentity) {
            case Some(identity) =>
                let completionWritten = gatewayWriteServeCompletionMarker(
                    identity,
                    gatewayStop,
                    httpStatus: httpStop.status,
                    canvasStatus: canvasStop.status,
                    gatewayServerStatus: gatewayServerStop.status
                )
                if (completionWritten) { let _ = gatewayPublishShutdownPhaseForTest(identity, "completion_written") }
                let _ = gatewayReleaseServeLockForIdentity(identity)
            case None => gatewayReleaseServeLockQuiet()
        }
        if (gatewayStop.ok && canvasStop.ok && httpStop.ok && gatewayServerStop.ok) {
            gatewayServeLogger.info(MetisLogEvent.gatewayShutdown, "Gateway serve stopped")
        } else {
            gatewayServeLogger.error(MetisLogEvent.gatewayShutdown, "Gateway serve stopped with cleanup pending")
        }
    }
    0
}

/** 兼容旧参数 `--gateway-feishu-webhook`，行为与 `magic-cli gateway serve` 一致。 */
public func runFeishuWebhookGatewayService(): Int64 {
    runGatewayService()
}
