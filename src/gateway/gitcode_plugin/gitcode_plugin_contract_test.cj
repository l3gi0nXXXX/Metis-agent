package metis.gateway.gitcode_plugin

import metis.gateway.service_plugin.{ServicePluginDeliveryTarget, parseServicePluginJobStartPayload}
import std.fs.{File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonObject

@Test
public class GitCodePluginContractTest {
    private func tempSubscriptionPath(label: String): String {
        "/tmp/metis-gitcode-subscription-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.jsonl"
    }

    private func jsonInt(obj: JsonObject, key: String): Int64 {
        try { obj.get(key).getOrThrow().asInt().getValue() } catch (_: Exception) { -1 }
    }

    @TestCase
    public func parseGitCodeCommandsCoversStatusSubscribeScanQueryAndUnknown(): Unit {
        @Expect(parseGitCodeCommand("hello").handled, false)
        @Expect(parseGitCodeCommand("/gitcode status").action, "status")
        @Expect(parseGitCodeCommand("/gitcode subscribe").action, "subscribe")
        @Expect(parseGitCodeCommand("/gitcode unsubscribe").action, "unsubscribe")
        @Expect(parseGitCodeCommand("/gitcode scan once --max-repos 1").action, "scan_once_alias")
        @Expect(parseGitCodeCommand("/gitcode scan status gcm-scan-1").action, "scan_status")
        @Expect(parseGitCodeCommand("/gitcode scan cancel gcm-scan-1").action, "scan_cancel")
        @Expect(parseGitCodeCommand("/gitcode webhook status").action, "webhook_status")
        @Expect(parseGitCodeCommand("/gitcode webhook dead-letter list").action, "webhook_dead_letter_list")
        @Expect(parseGitCodeCommand("/gitcode webhook dead-letter inspect d-1").action, "webhook_dead_letter_inspect")
        @Expect(parseGitCodeCommand("/gitcode webhook replay d-1").action, "webhook_replay")
        @Expect(parseGitCodeCommand("/gitcode webhook cancel d-1").action, "webhook_cancel")
        @Expect(parseGitCodeCommand("/gitcode reconcile hooks").action, "reconcile_hooks")
        @Expect(parseGitCodeCommand("/gitcode reconcile hooks --apply").action, "reconcile_hooks_apply")
        @Expect(parseGitCodeCommand("/gitcode reconcile once --lookback-hours 24").action, "reconcile_once")
        let query = parseGitCodeCommand("/gitcode query 如何使用 HttpClient")
        @Expect(query.action, "query")
        @Expect(query.query.contains("HttpClient"), true)
        @Expect(parseGitCodeCommand("/gitcode nope").action, "unknown")
    }

    @TestCase
    public func webhookCommandArgsValidateDeliveryIdsAndReconcileOptions(): Unit {
        let delivery = parseGitCodeDeliveryArgs(["abc-123_456.789"])
        @Expect(delivery.ok, true)
        @Expect(delivery.args.deliveryId, "abc-123_456.789")
        @Expect(parseGitCodeDeliveryArgs([]).ok, false)
        @Expect(parseGitCodeDeliveryArgs(["../x"]).status, "invalid_delivery_id")
        @Expect(parseGitCodeDeliveryArgs(["a/b"]).status, "invalid_delivery_id")
        @Expect(parseGitCodeDeliveryArgs(["a b"]).status, "invalid_delivery_id")

        let hooks = parseGitCodeHookReconcileArgs([])
        @Expect(hooks.ok, true)
        @Expect(hooks.args.apply, false)
        let hooksApply = parseGitCodeHookReconcileArgs(["--apply"])
        @Expect(hooksApply.ok, true)
        @Expect(hooksApply.args.apply, true)
        @Expect(parseGitCodeHookReconcileArgs(["--bad"]).ok, false)

        let reconcile = parseGitCodeReconcileOnceArgs(["--lookback-hours", "24", "--max-repos", "10", "--max-items", "100", "--apply"])
        @Expect(reconcile.ok, true)
        @Expect(reconcile.args.lookbackHours, 24)
        @Expect(reconcile.args.maxRepos, 10)
        @Expect(reconcile.args.maxItems, 100)
        @Expect(reconcile.args.dryRun, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--timeout-ms", "1"]).ok, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--max-repos", "-1"]).ok, false)
        @Expect(parseGitCodeReconcileOnceArgs(["--unknown"]).ok, false)
    }

    @TestCase
    public func webhookPayloadBuildersRedactRequesterAndRenderHumanReadableOutput(): Unit {
        let context = GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret")
        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let statusPayload = buildGitCodeWebhookStatusPayload(context)
        @Expect(statusPayload.contains("chat-secret"), false)
        @Expect(statusPayload.contains("sender-secret"), false)
        @Expect(statusPayload.contains("peerHash"), true)

        let replayPayload = buildGitCodeWebhookReplayPayload(context, "delivery-1")
        @Expect(replayPayload.contains("deliveryId"), true)
        @Expect(replayPayload.contains("delivery-1"), true)
        @Expect(replayPayload.contains("Authorization"), false)
        @Expect(replayPayload.contains("token"), false)

        let reconcilePayload = buildGitCodeEventReconcilePayload(context, GitCodeEventReconcileArgs(lookbackHours: 12, maxRepos: 3, maxItems: 9, dryRun: true), target, jobId: "gcm-reconcile-1", idempotencyKey: "idem-1")
        @Expect(reconcilePayload.contains("lookbackHours"), true)
        @Expect(reconcilePayload.contains("12"), true)
        @Expect(reconcilePayload.contains("gcm-reconcile-1"), true)
        @Expect(reconcilePayload.contains("idem-1"), true)
        @Expect(reconcilePayload.contains("chat-secret"), true)
        @Expect(reconcilePayload.contains("sender-secret"), false)

        let status = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"pending\":2,\"deadLetter\":1,\"lastError\":\"\"}")
        @Expect(status.contains("GitCode Webhook 状态"), true)
        @Expect(status.contains("{\"status\""), false)
        let dead = renderGitCodeDeadLetterListResult("{\"status\":\"ok\",\"count\":1,\"latest\":\"delivery-1\",\"errorKind\":\"payload_invalid\"}")
        @Expect(dead.contains("dead-letter"), true)
        @Expect(dead.contains("payload_invalid"), true)
        let event = renderGitCodeEventReconcileResult("{\"status\":\"completed\",\"lookbackHours\":12,\"repos\":2,\"candidates\":8,\"newEvents\":1,\"drafts\":1,\"notifications\":1,\"writes\":0}", aliasFromScanOnce: true)
        @Expect(event.contains("webhook-first"), true)
        @Expect(event.contains("新增事件 1"), true)
        @Expect(event.contains("\"status\""), false)
    }

    @TestCase
    public func gitCodeSubscriptionStorePersistsReloadsAndKeepsSubscribeIdempotent(): Unit {
        let path = this.tempSubscriptionPath("persist")
        resetGitCodePluginHostForTest()
        setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
        try {
            let target = GitCodeSubscriptionTarget("telegram", "tg-gitcode", "peer-1")
            let first = saveGitCodeSubscription(target)
            let second = saveGitCodeSubscription(target)
            @Expect(first.ok, true)
            @Expect(first.status, "created")
            @Expect(second.ok, true)
            @Expect(second.status, "already_present")
            @Expect(listGitCodeSubscriptions().size, 1)
            @Expect(exists(Path(path)), true)

            resetGitCodePluginHostForTest()
            setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
            let loaded = listGitCodeSubscriptions()
            @Expect(loaded.size, 1)
            @Expect(loaded[0].target.channel, "telegram")
            @Expect(loaded[0].target.accountId, "tg-gitcode")
            @Expect(loaded[0].target.peerId, "peer-1")
        } finally {
            resetGitCodePluginHostForTest()
            try { remove(Path(path)) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func gitCodeSubscriptionStoreRemoveInvalidCorruptAndLimitCasesAreSafe(): Unit {
        let path = this.tempSubscriptionPath("negative")
        resetGitCodePluginHostForTest()
        setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
        try {
            let invalid = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "acct", ""))
            @Expect(invalid.ok, false)
            @Expect(invalid.status, "invalid_target")
            @Expect(exists(Path(path)), false)

            let target = GitCodeSubscriptionTarget("feishu", "fs", "peer-2")
            @Expect(saveGitCodeSubscription(target).status, "created")
            @Expect(removeGitCodeSubscription(target).status, "removed")
            @Expect(listGitCodeSubscriptions().size, 0)

            resetGitCodePluginHostForTest()
            File.writeTo(Path(path), "bad-line\n".toArray())
            setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
            @Expect(listGitCodeSubscriptions().size, 0)

            resetGitCodePluginHostForTest()
            setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
            let inactiveAtLimit = GitCodeSubscriptionTarget("telegram", "acct", "peer-inactive-at-limit")
            @Expect(saveGitCodeSubscription(inactiveAtLimit).status, "created")
            @Expect(removeGitCodeSubscription(inactiveAtLimit).status, "removed")
            for (i in 0..100) {
                let saved = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "acct", "peer-${i}"))
                @Expect(saved.ok, true)
            }
            let overflow = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "acct", "peer-overflow"))
            @Expect(overflow.ok, false)
            @Expect(overflow.status, "subscription_limit_reached")
            let reactivationOverflow = saveGitCodeSubscription(inactiveAtLimit)
            @Expect(reactivationOverflow.ok, false)
            @Expect(reactivationOverflow.status, "subscription_limit_reached")
            @Expect(listGitCodeSubscriptions().size, 100)
        } finally {
            resetGitCodePluginHostForTest()
            try { remove(Path(path)) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func a3SubscriptionStatusJsonCountsTargetsAndNeverLeaksPeerIds(): Unit {
        // A3-SUB-UT-001, A3-SUB-UT-002
        let path = this.tempSubscriptionPath("a3-status")
        resetGitCodePluginHostForTest()
        setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
        try {
            let empty = gitCodeSubscriptionStatusJson()
            @Expect(this.jsonInt(empty, "total"), 0)
            @Expect(this.jsonInt(empty, "telegram"), 0)
            @Expect(this.jsonInt(empty, "feishu"), 0)
            let emptyText = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"subscribers\":${empty.toJsonString()}}")
            @Expect(emptyText.contains("当前没有 GitCode Webhook 通知目标"), true)
            @Expect(emptyText.contains("/gitcode subscribe"), true)
            @Expect(emptyText.contains("\"total\""), false)

            let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "tg-gitcode", "tg-peer-secret"))
            let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("feishu", "fs-gitcode", "fs-peer-secret"))
            let status = gitCodeSubscriptionStatusJson()
            let statusText = status.toJsonString()
            @Expect(this.jsonInt(status, "total"), 2)
            @Expect(this.jsonInt(status, "telegram"), 1)
            @Expect(this.jsonInt(status, "feishu"), 1)
            @Expect(this.jsonInt(status, "generatedReplies"), 2)
            @Expect(statusText.contains("tg-peer-secret"), false)
            @Expect(statusText.contains("fs-peer-secret"), false)
        } finally {
            resetGitCodePluginHostForTest()
            try { remove(Path(path)) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func a3SubscribeHumanOutputIdempotentAndInvalidTargetSafe(): Unit {
        // A3-SUB-POS-001, A3-SUB-NEG-001, A3-SUB-BND-001
        let path = this.tempSubscriptionPath("a3-subscribe")
        resetGitCodePluginHostForTest()
        setGitCodeSubscriptionStoreForTest(Some(loadGitCodeSubscriptionStore(path)))
        try {
            let invalidText = formatGitCodeSubscribeResult(saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "tg-gitcode", "")))
            @Expect(invalidText.contains("GitCode 订阅失败"), true)
            @Expect(invalidText.contains("peerId is empty"), true)
            @Expect(listGitCodeSubscriptions().size, 0)

            let target = GitCodeSubscriptionTarget("telegram", "tg-gitcode", "tg-peer-secret")
            let firstText = formatGitCodeSubscribeResult(saveGitCodeSubscription(target))
            @Expect(firstText.split("\n")[0], "GitCode 订阅已开启")
            @Expect(firstText.contains("created"), true)
            @Expect(firstText.contains("后续 GitCode webhook 生成的回复草稿会发送到当前会话"), true)
            for (_ in 0..9) {
                let text = formatGitCodeSubscribeResult(saveGitCodeSubscription(target))
                @Expect(text.contains("already_present"), true)
            }
            @Expect(listGitCodeSubscriptions().size, 1)

            let statusText = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"subscribers\":${gitCodeSubscriptionStatusJson().toJsonString()}}")
            @Expect(statusText.contains("订阅：TG 1 个"), true)
            @Expect(statusText.contains("tg-peer-secret"), false)
            @Expect(statusText.contains("\"subscribers\""), false)
        } finally {
            resetGitCodePluginHostForTest()
            try { remove(Path(path)) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func a0AndA4WebhookStatusRendererExplainsNoSubscribersAndDispatchStats(): Unit {
        // A0-SUB-NEG-001, A4-DIAG-POS-001, A4-DIAG-NEG-001
        let noSubscribers = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"subscribers\":{\"total\":0,\"telegram\":0,\"feishu\":0,\"generatedReplies\":0,\"rawEvents\":0},\"dispatch\":{\"latestStatus\":\"no_subscribers\",\"noSubscribers\":1,\"success\":0,\"failed\":0}}")
        @Expect(noSubscribers.contains("当前没有 GitCode Webhook 通知目标"), true)
        @Expect(noSubscribers.contains("servicePlugins.imBindings"), true)
        @Expect(noSubscribers.contains("/gitcode subscribe"), true)
        @Expect(noSubscribers.contains("\"ok\""), false)

        let delivered = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"subscribers\":{\"total\":2,\"telegram\":1,\"feishu\":1,\"generatedReplies\":2},\"dispatch\":{\"telegram\":1,\"feishu\":1,\"failed\":0,\"latestStatus\":\"generated_reply_delivered\"}}")
        @Expect(delivered.contains("订阅：TG 1 个，Feishu 1 个，生成草稿通知 2 个。"), true)
        @Expect(delivered.contains("投递：最近事件已发送到 TG 1 个、Feishu 1 个；最近失败 0 个"), true)

        let partial = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"subscribers\":{\"total\":2,\"telegram\":1,\"feishu\":1},\"dispatch\":{\"telegram\":0,\"feishu\":1,\"failed\":1,\"latestStatus\":\"generated_reply_partially_delivered\",\"diagnostic\":\"Authorization: Bearer secret token=abc\"}}")
        @Expect(partial.contains("最近失败 1 个"), true)
        @Expect(partial.contains("Bearer secret"), false)
        @Expect(partial.contains("token=abc"), false)
    }

    @TestCase
    public func webhookStatusRendererUsesRuntimeFieldsAndNeverFallsBackToRawJson(): Unit {
        let running = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"configStatus\":\"valid\",\"queueStatus\":\"ready\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"webhookBind\":\"127.0.0.1:18080\",\"publicBaseUrlConfigured\":true,\"queue\":{\"pending\":0,\"processing\":1,\"processed\":3,\"deadLetter\":0,\"cancelled\":0},\"lastBatchProcessed\":1,\"lastError\":\"\"}")
        @Expect(running.contains("GitCode Webhook 状态：运行正常"), true)
        @Expect(running.contains("接收端：正在监听（地址 127.0.0.1:18080）"), true)
        @Expect(running.contains("队列：正在处理 1 条，已处理 3 条，失败 0 条，取消 0 条。"), true)
        @Expect(running.contains("处理器：正在运行；最近处理 1 条。"), true)
        @Expect(running.contains("状态保存：插件没有返回状态保存诊断，暂时无法判断最近一次状态是否写入。"), true)
        @Expect(running.contains("公网地址：已配置"), true)
        @Expect(running.contains("{\"status\""), false)
        @Expect(running.contains("\"listenerStatus\""), false)
        @Expect(running.contains("unknown"), false)
        @Expect(running.contains("diagnostics-missing"), false)

        let flat = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"configStatus\":\"valid\",\"queueStatus\":\"ready\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"webhookBind\":\"127.0.0.1:18080\",\"publicBaseUrlConfigured\":true,\"queue\":{\"pending\":0,\"processing\":1,\"processed\":3,\"deadLetter\":0,\"cancelled\":0},\"lastBatchClaimed\":1,\"lastBatchProcessed\":1,\"emptyTickCount\":7,\"listenerLastStatus\":202,\"listenerLastDurationMs\":3,\"healthzCount\":2,\"activeRequestCount\":0,\"stateSaveStatus\":\"saved\",\"stateSaveSkipped\":false,\"stateSaveDurationMs\":4,\"stateSaveBytes\":512,\"auditCount\":12,\"auditMax\":1000,\"lastError\":\"\"}")
        @Expect(flat.contains("接收端：正在监听（地址 127.0.0.1:18080）；最近 HTTP 202，耗时 3ms；健康检查成功 2 次；当前没有正在处理的请求。"), true)
        @Expect(flat.contains("处理器：正在运行；最近领取 1 条，处理 1 条；空闲轮询 7 次。"), true)
        @Expect(flat.contains("状态保存：最近一次状态保存成功，耗时 4ms，写入 512 字节，审计记录 12/1000。"), true)
        @Expect(flat.contains("{\"status\""), false)

        let delivery = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"queue\":{\"pending\":0,\"processing\":0,\"processed\":3,\"deadLetter\":0,\"cancelled\":0},\"dispatch\":{\"telegram\":1,\"feishu\":1,\"failed\":0,\"orphan\":0},\"subscribers\":{\"telegram\":1,\"feishu\":1},\"publicBaseUrlConfigured\":true}")
        @Expect(delivery.contains("投递：最近事件已发送到 TG 1 个、Feishu 1 个；最近失败 0 个；无对应任务事件 0 个。"), true)
        @Expect(delivery.contains("订阅：TG 1 个，Feishu 1 个。"), true)
        @Expect(delivery.contains("\"dispatch\""), false)
        @Expect(delivery.contains("\"subscribers\""), false)

        let degraded = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"configStatus\":\"valid\",\"queueStatus\":\"ready\",\"listenerStatus\":\"not_started\",\"processorStatus\":\"running\",\"lastError\":\"Authorization: Bearer secret /Users/name/private\"}")
        @Expect(degraded.contains("GitCode Webhook 状态：降级或异常"), true)
        @Expect(degraded.contains("接收端：未启动。"), true)
        @Expect(degraded.contains("最近错误：[redacted]"), true)
        @Expect(degraded.contains("secret"), false)
        @Expect(degraded.contains("/Users/"), false)

        let missingFields = renderGitCodeWebhookStatusResult("{\"status\":\"ok\"}")
        @Expect(missingFields.contains("GitCode Webhook 状态：状态信息不完整，无法判断整体健康"), true)
        @Expect(missingFields.contains("接收端：插件未返回监听状态。"), true)
        @Expect(missingFields.contains("状态保存：插件没有返回状态保存诊断，暂时无法判断最近一次状态是否写入。"), true)
        @Expect(missingFields.contains("unknown"), false)
        @Expect(missingFields.contains("diagnostics-missing"), false)
        @Expect(missingFields.contains("{\"status\""), false)
    }

    @TestCase
    public func wbScopeP3Pos001WebhookStatusRendererShowsWritebackScopeSummary(): Unit {
        let flat = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"publicBaseUrlConfigured\":true,\"writebackAllowedOrgs\":3,\"writebackAllowedRepos\":0,\"writebackDeniedRepos\":1,\"writebackLegacyRepoAllowlist\":2}")
        @Expect(flat.contains("写回范围：组织 3 个，仓库 0 个，排除仓库 1 个，旧 allowlist 2 个。"), true)
        @Expect(flat.contains("\"writebackAllowedOrgs\""), false)
        @Expect(flat.contains("{"), false)

        let nested = renderGitCodeWebhookStatusResult("{\"status\":\"ok\",\"receiver\":\"running\",\"listenerStatus\":\"listening\",\"processorStatus\":\"running\",\"publicBaseUrlConfigured\":true,\"writebackScope\":{\"allowedOrgs\":3,\"allowedRepos\":4,\"deniedRepos\":5,\"legacyRepoAllowlist\":6}}")
        @Expect(nested.contains("写回范围：组织 3 个，仓库 4 个，排除仓库 5 个，旧 allowlist 6 个。"), true)
        @Expect(nested.contains("\"writebackScope\""), false)
        @Expect(nested.contains("{"), false)
    }

    @TestCase
    public func webhookStatusRendererExplainsPartialLivePayloadWithoutInternalUnknownWords(): Unit {
        let payload = "{\"status\":\"ok\",\"receiver\":\"unknown\",\"listenerLastStatus\":202,\"listenerLastDurationMs\":1,\"healthzCount\":1,\"activeRequestCount\":0,\"pending\":0,\"processing\":0,\"processed\":10,\"deadLetter\":0,\"cancelled\":0,\"lastBatchProcessed\":0,\"lastBatchClaimed\":0,\"emptyTickCount\":482,\"publicBaseUrlConfigured\":true}"
        let text = renderGitCodeWebhookStatusResult(payload)
        @Expect(text.contains("GitCode Webhook 状态：可接收请求，但插件运行诊断不完整"), true)
        @Expect(text.contains("接收端：最近一次请求成功，但插件未返回监听状态；最近 HTTP 202，耗时 1ms；健康检查成功 1 次；当前没有正在处理的请求。"), true)
        @Expect(text.contains("队列：没有积压，已处理 10 条，失败 0 条，取消 0 条。"), true)
        @Expect(text.contains("处理器：正在空闲轮询，但插件未返回生命周期状态；最近未领取新事件，处理 0 条；空闲轮询 482 次。"), true)
        @Expect(text.contains("状态保存：插件没有返回状态保存诊断，暂时无法判断最近一次状态是否写入。"), true)
        @Expect(text.contains("公网地址：已配置"), true)
        @Expect(text.contains("unknown"), false)
        @Expect(text.contains("diagnostics-missing"), false)
        @Expect(text.contains("lastStatus"), false)
        @Expect(text.contains("emptyTicks"), false)
        @Expect(text.contains("{"), false)
    }

    @TestCase
    public func webhookStatusRendererShowsGcmDiagnosticsAndRedactsSensitivePayloadFields(): Unit {
        let payload = "{\"ok\":true,\"status\":\"running\",\"receiver\":\"running\",\"token\":\"must-not-show\"," +
            "\"listener\":{\"status\":\"listening\",\"bind\":\"127.0.0.1:18080\",\"lastStatus\":202,\"lastDurationMs\":2,\"healthz\":\"ok\"}," +
            "\"queue\":{\"pending\":0,\"processing\":0,\"processed\":10,\"deadLetter\":0,\"cancelled\":0}," +
            "\"processor\":{\"status\":\"running\",\"pending\":0,\"processing\":0,\"processed\":10,\"deadLetter\":0,\"emptyTicks\":42}," +
            "\"stateSave\":{\"status\":\"skipped_empty_queue\",\"lastDurationMs\":0,\"bytes\":215647,\"auditCount\":595,\"auditMax\":1000,\"secretPath\":\"/Users/name/.gitcodemonitor/state.json\"}}"
        let text = renderGitCodeWebhookStatusResult(payload)
        @Expect(text.contains("GitCode Webhook 状态"), true)
        @Expect(text.contains("GitCode Webhook 状态：运行正常"), true)
        @Expect(text.contains("接收端：正在监听（地址 127.0.0.1:18080）；最近 HTTP 202，耗时 2ms；健康检查正常。"), true)
        @Expect(text.contains("队列：没有积压，已处理 10 条，失败 0 条，取消 0 条。"), true)
        @Expect(text.contains("处理器：正在运行；最近未领取新事件，处理 10 条；空闲轮询 42 次。"), true)
        @Expect(text.contains("状态保存：空队列，无需保存状态，耗时 0ms，写入 215647 字节，审计记录 595/1000。"), true)
        @Expect(text.contains("diagnostics-missing"), false)
        @Expect(text.contains("{"), false)
        @Expect(text.contains("}"), false)
        @Expect(text.contains("\"status\""), false)
        @Expect(text.contains("must-not-show"), false)
        @Expect(text.contains("secretPath"), false)
        @Expect(text.contains("/Users/"), false)
    }

    @TestCase
    public func webhookStatusRendererShowsDegradedErrorKindWithoutRawJsonOrSecrets(): Unit {
        let payload = "{\"ok\":false,\"status\":\"degraded\",\"receiver\":\"degraded\",\"errorKind\":\"listener_unhealthy\"," +
            "\"listener\":{\"status\":\"error\",\"bind\":\"127.0.0.1:18080\",\"lastStatus\":524,\"lastDurationMs\":5006,\"healthz\":\"timeout\",\"lastError\":\"Authorization: Bearer secret /Users/name/private\"}," +
            "\"queue\":{\"pending\":7,\"processing\":1,\"processed\":9,\"deadLetter\":2}," +
            "\"processor\":{\"status\":\"running\",\"pending\":7,\"processing\":1,\"processed\":9,\"deadLetter\":2,\"emptyTicks\":0}," +
            "\"stateSave\":{\"status\":\"error\",\"lastDurationMs\":1200,\"bytes\":215647,\"auditCount\":1000,\"auditMax\":1000}}"
        let text = renderGitCodeWebhookStatusResult(payload)
        @Expect(text.contains("GitCode Webhook 状态：降级或异常"), true)
        @Expect(text.contains("错误类型：listener_unhealthy"), true)
        @Expect(text.contains("接收端：异常（地址 127.0.0.1:18080）；最近 HTTP 524，耗时 5006ms；健康检查超时。"), true)
        @Expect(text.contains("队列：待处理 7 条，正在处理 1 条，已处理 9 条，失败 2 条，取消 0 条。"), true)
        @Expect(text.contains("处理器：正在运行；最近未领取新事件，处理 9 条；空闲轮询 0 次。"), true)
        @Expect(text.contains("状态保存：状态保存异常，耗时 1200ms，写入 215647 字节，审计记录 1000/1000。"), true)
        @Expect(text.contains("{"), false)
        @Expect(text.contains("\"ok\""), false)
        @Expect(text.contains("Authorization"), false)
        @Expect(text.contains("secret"), false)
        @Expect(text.contains("/Users/"), false)
    }

    @TestCase
    public func hookReconcileRendererShowsHumanReadableDriftAndApplyRejection(): Unit {
        let dryRun = renderGitCodeHookReconcileResult("{\"status\":\"ok\",\"apply\":false,\"aligned\":2,\"missing\":1,\"wrong_url\":3,\"wrong_events\":4,\"auth_failed\":5,\"failed\":0}")
        @Expect(dryRun.contains("GitCode webhook hook reconcile"), true)
        @Expect(dryRun.contains("aligned=2"), true)
        @Expect(dryRun.contains("missing=1"), true)
        @Expect(dryRun.contains("wrong_url=3"), true)
        @Expect(dryRun.contains("wrong_events=4"), true)
        @Expect(dryRun.contains("auth_failed=5"), true)
        @Expect(dryRun.contains("\"status\""), false)

        let rejected = renderGitCodeHookReconcileResult("{\"status\":\"apply_rejected\",\"applyRejected\":true,\"rejectReason\":\"publicBaseUrl missing token=secret /Users/name/private\",\"aligned\":0,\"missing\":1}")
        @Expect(rejected.contains("apply rejected"), true)
        @Expect(rejected.contains("reason=[redacted]"), true)
        @Expect(rejected.contains("token=secret"), false)
        @Expect(rejected.contains("/Users/"), false)
        @Expect(rejected.contains("{\"status\""), false)
    }

    @TestCase
    public func defaultScanOnceArgsAreUnboundedAndHaveNoUserTimeout(): Unit {
        let args = parseGitCodeScanOnceArgs([])
        @Expect(args.ok, true)
        @Expect(args.args.maxRepos, 0)
        @Expect(args.args.maxItems, 0)
        @Expect(args.args.timeoutMillis, 0)

        let payload = buildGitCodeScanOncePayload(args.args)
        @Expect(payload.contains("\"maxRepos\":0"), true)
        @Expect(payload.contains("\"maxItems\":0"), true)
        @Expect(payload.contains("timeoutMillis"), false)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func parseAndBuildAsyncScanPayloadIncludesDeliveryTargetAndExplicitLimits(): Unit {
        let parsed = parseGitCodeCommand("/gitcode scan once --max-repos 2 --max-items 20 --offline-fixture")
        let args = parseGitCodeScanOnceArgs(parsed.args)
        @Expect(args.ok, true)
        @Expect(args.args.maxRepos, 2)
        @Expect(args.args.maxItems, 20)
        @Expect(args.args.timeoutMillis, 0)
        @Expect(args.args.offlineFixture, true)

        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let payload = buildGitCodeAsyncScanPayload(
            GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret"),
            args.args,
            "gcm-scan-1",
            "idem-1",
            target
        )
        let parsedPayload = parseServicePluginJobStartPayload(payload)
        @Expect(parsedPayload.ok, true)
        @Expect(parsedPayload.payload.mode, "async")
        @Expect(parsedPayload.payload.jobId, "gcm-scan-1")
        @Expect(parsedPayload.payload.deliveryTarget.peerId, "chat-secret")
        @Expect(parsedPayload.payload.offlineFixture, true)
        @Expect(parsedPayload.payload.limits.maxRepos, 2)
        @Expect(parsedPayload.payload.limits.maxItems, 20)
        @Expect(parsedPayload.payload.limits.maxDurationMillis, 0)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func defaultAsyncScanPayloadCarriesNoRepoItemOrDurationLimit(): Unit {
        let target = ServicePluginDeliveryTarget("telegram", "tg-gitcode-monitor", "chat-secret", replyToMessageId: "24")
        let payload = buildGitCodeAsyncScanPayload(
            GatewayCommandContext(channel: "telegram", accountId: "tg-gitcode-monitor", peerId: "chat-secret", senderId: "sender-secret"),
            GitCodeScanOnceArgs(),
            "gcm-scan-1",
            "idem-1",
            target
        )
        let parsedPayload = parseServicePluginJobStartPayload(payload)
        @Expect(parsedPayload.ok, true)
        @Expect(parsedPayload.payload.limits.maxRepos, 0)
        @Expect(parsedPayload.payload.limits.maxItems, 0)
        @Expect(parsedPayload.payload.limits.maxDurationMillis, 0)
        @Expect(payload.contains("\"maxRepos\":5"), false)
        @Expect(payload.contains("\"maxItems\":30"), false)
        @Expect(payload.contains("\"timeoutMillis\":30000"), false)
    }

    @TestCase
    public func scanArgsRejectInvalidNumbersBeforeInvokingGcm(): Unit {
        let negative = parseGitCodeScanOnceArgs(["--max-repos", "-1"])
        @Expect(negative.ok, false)
        @Expect(negative.status, "invalid_args")
        let missing = parseGitCodeScanOnceArgs(["--max-items"])
        @Expect(missing.ok, false)
        @Expect(missing.diagnostic.contains("requires"), true)
        let unknown = parseGitCodeScanOnceArgs(["--bad"])
        @Expect(unknown.ok, false)
        @Expect(unknown.diagnostic.contains("unknown"), true)

        let timeout = parseGitCodeScanOnceArgs(["--timeout-ms", "30000"])
        @Expect(timeout.ok, false)
        @Expect(timeout.status, "invalid_args")
        @Expect(timeout.diagnostic, "--timeout-ms is no longer supported for async scan jobs")
        @Expect(timeout.diagnostic.contains("{"), false)
        @Expect(timeout.diagnostic.contains("\"ok\""), false)

        let timeoutMissing = parseGitCodeScanOnceArgs(["--timeout-ms"])
        @Expect(timeoutMissing.ok, false)
        @Expect(timeoutMissing.diagnostic, "--timeout-ms is no longer supported for async scan jobs")
    }

    @TestCase
    public func statusAndScanCommandsRespectAuthorizationAndDoNotNeedGitCodeCredentials(): Unit {
        let unauthorized = handleGitCodeStatusCommand(GatewayCommandContext(authorized: false))
        @Expect(unauthorized.ok, false)
        @Expect(unauthorized.status, "unauthorized")
        let status = handleGitCodeStatusCommand(GatewayCommandContext())
        @Expect(status.ok, true)
        @Expect(status.message.contains("running=true"), true)

        let scanDenied = handleGitCodeScanOnceCommand(GatewayCommandContext(isOperator: false), GitCodeScanOnceArgs())
        @Expect(scanDenied.ok, false)
        @Expect(scanDenied.status, "unauthorized")
        let scan = handleGitCodeScanOnceCommand(GatewayCommandContext(isOperator: true), GitCodeScanOnceArgs(maxRepos: 1, maxItems: 2))
        @Expect(scan.ok, true)
        @Expect(scan.message.contains("gitcode.monitor.scan_once"), true)
        let payload = buildGitCodeScanOncePayload(GitCodeScanOnceArgs(maxRepos: -1, maxItems: 3))
        @Expect(payload.contains("\"maxRepos\":0"), true)
        @Expect(payload.contains("token"), false)
    }

    @TestCase
    public func subscriptionsAreIdempotentScopedAndDoNotExposeBotSecrets(): Unit {
        resetGitCodePluginHostForTest()
        let target = buildGitCodeSubscriptionTarget(GatewayCommandContext(channel: "telegram", accountId: "bot-a", peerId: "chat-1", threadId: "topic-2"))
        let first = saveGitCodeSubscription(target)
        @Expect(first.ok, true)
        @Expect(first.status, "created")
        let duplicate = saveGitCodeSubscription(target)
        @Expect(duplicate.ok, true)
        @Expect(duplicate.status, "already_present")
        @Expect(listGitCodeSubscriptions().size, 1)
        @Expect(formatGitCodeSubscribeResult(first).contains("chat-1"), false)
        let removed = removeGitCodeSubscription(target)
        @Expect(removed.ok, true)
        @Expect(removed.status, "removed")
        @Expect(listGitCodeSubscriptions().size, 0)
        @Expect(removeGitCodeSubscription(target).status, "already_absent")
    }

    @TestCase
    public func knowledgeQueryBuildsAgentRequestAndBypassesGcm(): Unit {
        let result = handleGitCodeKnowledgeQueryCommand(GatewayCommandContext(sessionKey: "s1"), "HttpClient 怎么用")
        @Expect(result.ok, true)
        @Expect(result.status, "agent_request")
        @Expect(result.message.contains("CKB"), true)
        let request = buildCangjieKnowledgeAgentRequest(GatewayCommandContext(sessionKey: "s1"), "query")
        @Expect(request.ckbRequired, true)
        @Expect(request.sessionKey, "s1")
    }

    @TestCase
    public func acceptedEventsNormalizeDedupeAndRawNotificationsFanout(): Unit {
        resetGitCodePluginHostForTest()
        let target = GitCodeSubscriptionTarget("feishu", "default", "chat")
        let _ = saveGitCodeSubscription(target, scope: GitCodeSubscriptionScope(rawEvents: true, generatedReplies: false))
        let payload = "{\"eventId\":\"e1\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"author\":\"alice\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"content\":\"hello\"}"
        let normalized = normalizeGitCodeAcceptedEvent(payload)
        @Expect(normalized.ok, true)
        @Expect(normalized.event.repo, "Cangjie/community")
        @Expect(normalizeGitCodeAcceptedEvent("{\"token\":\"secret\"}").ok, false)
        @Expect(dedupeGitCodeEvent(normalized.event).duplicate, false)
        @Expect(dedupeGitCodeEvent(normalized.event).duplicate, true)
        let notification = publishGitCodeRawEventNotification(normalized.event)
        @Expect(notification.ok, true)
        @Expect(notification.delivered, 1)
        @Expect(notification.message.contains("https://gitcode.com"), true)
    }

    @TestCase
    public func generatedReplyNotificationAlwaysPublishesIndependentOfAutoReply(): Unit {
        resetGitCodePluginHostForTest()
        let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "default", "peer"), scope: GitCodeSubscriptionScope(rawEvents: false, generatedReplies: true))
        let event = GitCodeAcceptedEvent("e2", "Cangjie/stdx", "issue", "2", "bob", "https://gitcode.com/Cangjie/stdx/issues/2", "HttpClient")
        let draft = GitCodeDraftResult("summary", "draft", citations: ["ckb://evidence"], knowledgeVersion: "ckb-v1")
        let notification = publishGeneratedReplyNotification(event, draft)
        @Expect(notification.ok, true)
        @Expect(notification.delivered, 1)
        @Expect(notification.message.contains("summary"), true)
        @Expect(notification.message.contains("ckb-v1"), true)
        let disabledWriteback = dispatchWritebackApplyResult(buildGcmWritebackApplyPayload(event, draft), autoReplyEnabled: false)
        @Expect(disabledWriteback.status, "writeback_dry_run")
        let enabledWriteback = dispatchWritebackApplyResult(buildGcmWritebackApplyPayload(event, draft), autoReplyEnabled: true)
        @Expect(enabledWriteback.status, "writeback_requested")
    }

    @TestCase
    public func agentBridgeRequiresCkbEvidenceAndDegradesSafely(): Unit {
        let event = GitCodeAcceptedEvent("e3", "Cangjie/compiler", "pr", "3", "carol", "https://gitcode.com/Cangjie/compiler/pulls/3", "panic")
        let request = buildGitCodeAgentDraftRequest(event)
        @Expect(request.ckbRequired, true)
        @Expect(attachCkbEvidencePolicy(request).prompt.contains("CKB"), true)
        let ok = invokeGitCodeDraftAgent(request, ckbAvailable: true)
        @Expect(assertCkbCitationPresent(ok), true)
        let degraded = invokeGitCodeDraftAgent(request, ckbAvailable: false)
        @Expect(degraded.degraded, true)
        @Expect(degraded.needsHumanReview, true)
        @Expect(assertCkbCitationPresent(degraded), false)
    }

    @TestCase
    public func fakeSmokesCoverMetisGcmMetisCkbAndEndToEndBoundaries(): Unit {
        let gcm = runMetisGcmPluginSmoke(MetisGcmSmokeConfig(subscribers: 1))
        @Expect(gcm.ok, true)
        @Expect(gcm.notificationCount, 1)
        let ckb = runMetisCkbEvidenceSmoke(MetisCkbSmokeConfig(ckbAvailable: true))
        @Expect(assertCkbCitationPresent(ckb), true)
        let degraded = runMetisCkbEvidenceSmoke(MetisCkbSmokeConfig(ckbAvailable: false))
        @Expect(degraded.needsHumanReview, true)

        let dry = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: false, ckbAvailable: true, subscribers: 1))
        @Expect(assertEndToEndBoundaries(dry), true)
        @Expect(dry.generatedReplySent, true)
        @Expect(dry.writebackRequested, false)
        let write = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: true, ckbAvailable: true, subscribers: 1))
        @Expect(write.writebackRequested, true)
        let blocked = runGitCodeMonitorEndToEndSmoke(EndToEndSmokeConfig(autoReplyEnabled: true, ckbAvailable: false, subscribers: 1))
        @Expect(blocked.needsHumanReview, true)
        @Expect(blocked.writebackRequested, false)
    }
}
