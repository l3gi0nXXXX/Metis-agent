package metis.gateway.gitcode_plugin

import metis.gateway.service_plugin.{ServicePluginDeliveryTarget, hashRawPayload, servicePluginDeliveryTargetToJson}
import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.Parsable
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

public class GitCodePluginCommandParseResult {
    public let handled: Bool
    public let action: String
    public let args: Array<String>
    public let query: String
    public let diagnostic: String

    public init(handled: Bool, action!: String = "", args!: Array<String> = [], query!: String = "", diagnostic!: String = "") {
        this.handled = handled
        this.action = action
        this.args = args
        this.query = query
        this.diagnostic = diagnostic
    }
}

public class GatewayCommandContext {
    public let channel: String
    public let accountId: String
    public let peerId: String
    public let threadId: String
    public let senderId: String
    public let sessionKey: String
    public let authorized: Bool
    public let isOperator: Bool

    public init(
        channel!: String = "telegram",
        accountId!: String = "default",
        peerId!: String = "peer",
        threadId!: String = "",
        senderId!: String = "sender",
        sessionKey!: String = "session",
        authorized!: Bool = true,
        isOperator!: Bool = false
    ) {
        this.channel = channel.trimAscii()
        this.accountId = accountId.trimAscii()
        this.peerId = peerId.trimAscii()
        this.threadId = threadId.trimAscii()
        this.senderId = senderId.trimAscii()
        this.sessionKey = sessionKey.trimAscii()
        this.authorized = authorized
        this.isOperator = isOperator
    }
}

public class GatewayCommandResult {
    public let ok: Bool
    public let status: String
    public let message: String
    public init(ok: Bool, status: String, message!: String = "") {
        this.ok = ok
        this.status = status
        this.message = message
    }
}

public class GitCodePluginStatusView {
    public let enabled: Bool
    public let running: Bool
    public let lastScan: String
    public let nextScan: String
    public let degradedReason: String
    public init(enabled!: Bool = false, running!: Bool = false, lastScan!: String = "", nextScan!: String = "", degradedReason!: String = "") {
        this.enabled = enabled
        this.running = running
        this.lastScan = lastScan
        this.nextScan = nextScan
        this.degradedReason = degradedReason
    }
}

public class GitCodeSubscriptionScope {
    public let rawEvents: Bool
    public let generatedReplies: Bool
    public init(rawEvents!: Bool = true, generatedReplies!: Bool = true) {
        this.rawEvents = rawEvents
        this.generatedReplies = generatedReplies
    }
}

public class GitCodeSubscriptionTarget {
    public let channel: String
    public let accountId: String
    public let peerId: String
    public let threadId: String
    public let targetKey: String
    public init(channel: String, accountId: String, peerId: String, threadId!: String = "") {
        this.channel = channel.trimAscii()
        this.accountId = accountId.trimAscii()
        this.peerId = peerId.trimAscii()
        this.threadId = threadId.trimAscii()
        this.targetKey = "${this.channel}:${this.accountId}:${this.peerId}:${this.threadId}"
    }
}

public class GitCodeSubscriptionSnapshot {
    public let target: GitCodeSubscriptionTarget
    public let scope: GitCodeSubscriptionScope
    public let active: Bool
    public init(target: GitCodeSubscriptionTarget, scope: GitCodeSubscriptionScope, active!: Bool = true) {
        this.target = target
        this.scope = scope
        this.active = active
    }
}

public class SubscriptionSaveResult {
    public let ok: Bool
    public let status: String
    public let targetKey: String
    public init(ok: Bool, status: String, targetKey!: String = "") {
        this.ok = ok
        this.status = status
        this.targetKey = targetKey
    }
}

public class SubscriptionRemoveResult {
    public let ok: Bool
    public let status: String
    public let targetKey: String
    public init(ok: Bool, status: String, targetKey!: String = "") {
        this.ok = ok
        this.status = status
        this.targetKey = targetKey
    }
}

public class GitCodeSubscriptionFilter {
    public let channel: String
    public init(channel!: String = "") {
        this.channel = channel.trimAscii()
    }
}

public class GitCodeScanOnceArgs {
    public let dryRun: Bool
    public let maxRepos: Int64
    public let maxItems: Int64
    public let timeoutMillis: Int64
    public let offlineFixture: Bool
    public init(dryRun!: Bool = true, maxRepos!: Int64 = 0, maxItems!: Int64 = 0, timeoutMillis!: Int64 = 0, offlineFixture!: Bool = false) {
        this.dryRun = dryRun
        this.maxRepos = maxRepos
        this.maxItems = maxItems
        this.timeoutMillis = timeoutMillis
        this.offlineFixture = offlineFixture
    }
}

public class GitCodeScanOnceArgsParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let args: GitCodeScanOnceArgs

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", args!: GitCodeScanOnceArgs = GitCodeScanOnceArgs()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.args = args
    }
}

public class GitCodeDeliveryCommandArgs {
    public let deliveryId: String
    public init(deliveryId!: String = "") {
        this.deliveryId = deliveryId.trimAscii()
    }
}

public class GitCodeDeliveryCommandArgsParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let args: GitCodeDeliveryCommandArgs

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", args!: GitCodeDeliveryCommandArgs = GitCodeDeliveryCommandArgs()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.args = args
    }
}

public class GitCodeHookReconcileArgs {
    public let apply: Bool
    public init(apply!: Bool = false) {
        this.apply = apply
    }
}

public class GitCodeHookReconcileArgsParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let args: GitCodeHookReconcileArgs

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", args!: GitCodeHookReconcileArgs = GitCodeHookReconcileArgs()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.args = args
    }
}

public class GitCodeEventReconcileArgs {
    public let lookbackHours: Int64
    public let maxRepos: Int64
    public let maxItems: Int64
    public let dryRun: Bool

    public init(lookbackHours!: Int64 = 24, maxRepos!: Int64 = 0, maxItems!: Int64 = 0, dryRun!: Bool = true) {
        this.lookbackHours = if (lookbackHours <= 0) { 24 } else { lookbackHours }
        this.maxRepos = boundedNonNegative(maxRepos)
        this.maxItems = boundedNonNegative(maxItems)
        this.dryRun = dryRun
    }
}

public class GitCodeEventReconcileArgsParseResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public let args: GitCodeEventReconcileArgs

    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "", args!: GitCodeEventReconcileArgs = GitCodeEventReconcileArgs()) {
        this.ok = ok
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
        this.args = args
    }
}

public class GitCodeWebhookStatusArgs {
    public let includeDeadLetter: Bool
    public init(includeDeadLetter!: Bool = false) {
        this.includeDeadLetter = includeDeadLetter
    }
}

public class CapabilityInvokeResult {
    public let ok: Bool
    public let status: String
    public let capabilityId: String
    public let payload: String
    public init(ok: Bool, status: String, capabilityId!: String = "", payload!: String = "{}") {
        this.ok = ok
        this.status = status
        this.capabilityId = capabilityId
        this.payload = payload
    }
}

public class AgentInvokeRequest {
    public let prompt: String
    public let sessionKey: String
    public let ckbRequired: Bool
    public let knowledgeVersion: String
    public init(prompt: String, sessionKey!: String = "", ckbRequired!: Bool = false, knowledgeVersion!: String = "") {
        this.prompt = prompt
        this.sessionKey = sessionKey
        this.ckbRequired = ckbRequired
        this.knowledgeVersion = knowledgeVersion
    }
}

public class GitCodeAcceptedEvent {
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let author: String
    public let url: String
    public let content: String
    public init(eventId: String, repo: String, kind: String, number: String, author: String, url: String, content: String) {
        this.eventId = eventId.trimAscii()
        this.repo = repo.trimAscii()
        this.kind = kind.trimAscii()
        this.number = number.trimAscii()
        this.author = author.trimAscii()
        this.url = url.trimAscii()
        this.content = content
    }
}

public class GitCodeEventNormalizeResult {
    public let ok: Bool
    public let event: GitCodeAcceptedEvent
    public let diagnostic: String
    public init(ok: Bool, event!: GitCodeAcceptedEvent = GitCodeAcceptedEvent("", "", "", "", "", "", ""), diagnostic!: String = "") {
        this.ok = ok
        this.event = event
        this.diagnostic = diagnostic
    }
}

public class DedupeResult {
    public let duplicate: Bool
    public let eventId: String
    public init(duplicate: Bool, eventId: String) {
        this.duplicate = duplicate
        this.eventId = eventId
    }
}

public class NotificationResult {
    public let ok: Bool
    public let status: String
    public let delivered: Int64
    public let message: String
    public init(ok: Bool, status: String, delivered!: Int64 = 0, message!: String = "") {
        this.ok = ok
        this.status = status
        this.delivered = delivered
        this.message = message
    }
}

public class GitCodeDraftResult {
    public let summary: String
    public let draft: String
    public let safety: String
    public let citations: Array<String>
    public let knowledgeVersion: String
    public let degraded: Bool
    public let needsHumanReview: Bool
    public init(
        summary: String,
        draft: String,
        safety!: String = "approved",
        citations!: Array<String> = [],
        knowledgeVersion!: String = "",
        degraded!: Bool = false,
        needsHumanReview!: Bool = false
    ) {
        this.summary = summary
        this.draft = draft
        this.safety = safety
        this.citations = citations
        this.knowledgeVersion = knowledgeVersion
        this.degraded = degraded
        this.needsHumanReview = needsHumanReview
    }
}

public class GitCodeAgentDraftRequest {
    public let event: GitCodeAcceptedEvent
    public let ckbRequired: Bool
    public let sourceAnalysisAllowed: Bool
    public init(event: GitCodeAcceptedEvent, ckbRequired!: Bool = true, sourceAnalysisAllowed!: Bool = true) {
        this.event = event
        this.ckbRequired = ckbRequired
        this.sourceAnalysisAllowed = sourceAnalysisAllowed
    }
}

public class GitCodeWritebackApplyPayload {
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let url: String
    public let draft: String
    public let safety: String
    public let citations: Array<String>
    public let needsHumanReview: Bool
    public init(event: GitCodeAcceptedEvent, result: GitCodeDraftResult) {
        this.eventId = event.eventId
        this.repo = event.repo
        this.kind = event.kind
        this.number = event.number
        this.url = event.url
        this.draft = result.draft
        this.safety = result.safety
        this.citations = result.citations
        this.needsHumanReview = result.needsHumanReview
    }
}

public class MetisGcmSmokeConfig {
    public let subscribers: Int64
    public init(subscribers!: Int64 = 1) {
        this.subscribers = subscribers
    }
}

public class SmokeTestResult {
    public let ok: Bool
    public let status: String
    public let notificationCount: Int64
    public let diagnostic: String
    public init(ok: Bool, status: String, notificationCount!: Int64 = 0, diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.notificationCount = notificationCount
        this.diagnostic = diagnostic
    }
}

public class MetisCkbSmokeConfig {
    public let ckbAvailable: Bool
    public init(ckbAvailable!: Bool = true) {
        this.ckbAvailable = ckbAvailable
    }
}

public class EndToEndSmokeConfig {
    public let autoReplyEnabled: Bool
    public let ckbAvailable: Bool
    public let subscribers: Int64
    public init(autoReplyEnabled!: Bool = false, ckbAvailable!: Bool = true, subscribers!: Int64 = 1) {
        this.autoReplyEnabled = autoReplyEnabled
        this.ckbAvailable = ckbAvailable
        this.subscribers = subscribers
    }
}

public class EndToEndSmokeResult {
    public let ok: Bool
    public let generatedReplySent: Bool
    public let writebackRequested: Bool
    public let needsHumanReview: Bool
    public let secretLeak: Bool
    public init(ok: Bool, generatedReplySent: Bool, writebackRequested: Bool, needsHumanReview!: Bool = false, secretLeak!: Bool = false) {
        this.ok = ok
        this.generatedReplySent = generatedReplySent
        this.writebackRequested = writebackRequested
        this.needsHumanReview = needsHumanReview
        this.secretLeak = secretLeak
    }
}

private var gitcodeSubscriptions = HashMap<String, GitCodeSubscriptionSnapshot>()
private var gitcodeSeenEvents = HashSet<String>()

public func resetGitCodePluginHostForTest(): Unit {
    gitcodeSubscriptions = HashMap<String, GitCodeSubscriptionSnapshot>()
    gitcodeSeenEvents = HashSet<String>()
}

public func parseGitCodeCommand(text: String): GitCodePluginCommandParseResult {
    let trimmed = text.trimAscii()
    if (!trimmed.toAsciiLower().startsWith("/gitcode")) {
        return GitCodePluginCommandParseResult(false, diagnostic: "not_gitcode")
    }
    let parts = trimmed.split(" ")
    if (parts.size == 1) {
        return GitCodePluginCommandParseResult(true, action: "help")
    }
    let first = parts[1].trimAscii().toAsciiLower()
    if (first == "status" || first == "config") {
        return GitCodePluginCommandParseResult(true, action: first, args: parts[2..])
    }
    if (first == "subscribe" || first == "unsubscribe") {
        return GitCodePluginCommandParseResult(true, action: first, args: parts[2..])
    }
    if (first == "webhook") {
        if (parts.size > 2) {
            let second = parts[2].trimAscii().toAsciiLower()
            if (second == "status") {
                return GitCodePluginCommandParseResult(true, action: "webhook_status", args: parts[3..])
            }
            if (second == "dead-letter" && parts.size > 3) {
                let third = parts[3].trimAscii().toAsciiLower()
                if (third == "list") {
                    return GitCodePluginCommandParseResult(true, action: "webhook_dead_letter_list", args: parts[4..])
                }
                if (third == "inspect") {
                    return GitCodePluginCommandParseResult(true, action: "webhook_dead_letter_inspect", args: parts[4..])
                }
            }
            if (second == "replay") {
                return GitCodePluginCommandParseResult(true, action: "webhook_replay", args: parts[3..])
            }
            if (second == "cancel") {
                return GitCodePluginCommandParseResult(true, action: "webhook_cancel", args: parts[3..])
            }
        }
        return GitCodePluginCommandParseResult(true, action: "unknown", args: parts[1..], diagnostic: "unknown gitcode webhook command")
    }
    if (first == "reconcile") {
        if (parts.size > 2) {
            let second = parts[2].trimAscii().toAsciiLower()
            if (second == "hooks") {
                let args = parts[3..]
                for (arg in args) {
                    if (arg.trimAscii() == "--apply") {
                        return GitCodePluginCommandParseResult(true, action: "reconcile_hooks_apply", args: args)
                    }
                }
                return GitCodePluginCommandParseResult(true, action: "reconcile_hooks", args: args)
            }
            if (second == "once") {
                return GitCodePluginCommandParseResult(true, action: "reconcile_once", args: parts[3..])
            }
        }
        return GitCodePluginCommandParseResult(true, action: "unknown", args: parts[1..], diagnostic: "unknown gitcode reconcile command")
    }
    if (first == "scan" && parts.size > 3 && parts[2].trimAscii().toAsciiLower() == "status") {
        return GitCodePluginCommandParseResult(true, action: "scan_status", args: parts[3..])
    }
    if (first == "scan" && parts.size > 3 && parts[2].trimAscii().toAsciiLower() == "cancel") {
        return GitCodePluginCommandParseResult(true, action: "scan_cancel", args: parts[3..])
    }
    if (first == "scan" && parts.size > 2 && parts[2].trimAscii().toAsciiLower() == "once") {
        return GitCodePluginCommandParseResult(true, action: "scan_once_alias", args: parts[3..])
    }
    if (first == "auto-reply") {
        return GitCodePluginCommandParseResult(true, action: "auto_reply", args: parts[2..])
    }
    if (first == "query") {
        let query = if (trimmed.contains("/gitcode query ")) { trimmed.split("/gitcode query ", 2)[1].trimAscii() } else { "" }
        return GitCodePluginCommandParseResult(true, action: "query", query: query)
    }
    GitCodePluginCommandParseResult(true, action: "unknown", args: parts[1..], diagnostic: "unknown gitcode command")
}

public func handleGitCodeStatusCommand(context: GatewayCommandContext): GatewayCommandResult {
    if (!context.authorized) {
        return GatewayCommandResult(false, "unauthorized", message: "sender is not authorized")
    }
    GatewayCommandResult(true, "ok", message: formatGitCodeStatusMessage(GitCodePluginStatusView(enabled: true, running: true, lastScan: "available", nextScan: "scheduled")))
}

public func formatGitCodeStatusMessage(status: GitCodePluginStatusView): String {
    let reason = redactGitCodePluginText(status.degradedReason)
    "gitcode enabled=${status.enabled} running=${status.running} lastScan=${status.lastScan} nextScan=${status.nextScan} degradedReason=${reason}"
}

public func buildGitCodeSubscriptionTarget(context: GatewayCommandContext): GitCodeSubscriptionTarget {
    GitCodeSubscriptionTarget(context.channel, context.accountId, context.peerId, threadId: context.threadId)
}

public func saveGitCodeSubscription(target: GitCodeSubscriptionTarget, scope!: GitCodeSubscriptionScope = GitCodeSubscriptionScope()): SubscriptionSaveResult {
    if (target.channel.isEmpty() || target.accountId.isEmpty() || target.peerId.isEmpty()) {
        return SubscriptionSaveResult(false, "invalid_target", targetKey: target.targetKey)
    }
    let status = if (gitcodeSubscriptions.contains(target.targetKey)) { "already_present" } else { "created" }
    gitcodeSubscriptions[target.targetKey] = GitCodeSubscriptionSnapshot(target, scope, active: true)
    SubscriptionSaveResult(true, status, targetKey: target.targetKey)
}

public func formatGitCodeSubscribeResult(result: SubscriptionSaveResult): String {
    "gitcode subscribe status=${result.status} target=${safeTargetKey(result.targetKey)}"
}

public func removeGitCodeSubscription(target: GitCodeSubscriptionTarget): SubscriptionRemoveResult {
    if (!gitcodeSubscriptions.contains(target.targetKey)) {
        return SubscriptionRemoveResult(true, "already_absent", targetKey: target.targetKey)
    }
    let current = gitcodeSubscriptions[target.targetKey]
    if (!current.active) {
        return SubscriptionRemoveResult(true, "already_absent", targetKey: target.targetKey)
    }
    gitcodeSubscriptions[target.targetKey] = GitCodeSubscriptionSnapshot(current.target, current.scope, active: false)
    SubscriptionRemoveResult(true, "removed", targetKey: target.targetKey)
}

public func listGitCodeSubscriptions(filter!: GitCodeSubscriptionFilter = GitCodeSubscriptionFilter()): ArrayList<GitCodeSubscriptionSnapshot> {
    let out = ArrayList<GitCodeSubscriptionSnapshot>()
    for ((_, row) in gitcodeSubscriptions) {
        if (row.active && (filter.channel.isEmpty() || row.target.channel == filter.channel)) {
            out.add(row)
        }
    }
    out
}

public func handleGitCodeScanOnceCommand(context: GatewayCommandContext, args: GitCodeScanOnceArgs): GatewayCommandResult {
    if (!context.isOperator) {
        return GatewayCommandResult(false, "unauthorized", message: "operator permission required")
    }
    let payload = buildGitCodeScanOncePayload(args)
    let invoke = CapabilityInvokeResult(true, "queued", capabilityId: "gitcode.monitor.scan_once", payload: payload)
    GatewayCommandResult(invoke.ok, invoke.status, message: formatGitCodeScanOnceResult(invoke))
}

public func buildGitCodeScanOncePayload(args: GitCodeScanOnceArgs): String {
    "{\"dryRun\":${args.dryRun},\"maxRepos\":${boundedNonNegative(args.maxRepos)},\"maxItems\":${boundedNonNegative(args.maxItems)}}"
}

public func parseGitCodeScanOnceArgs(args: Array<String>): GitCodeScanOnceArgsParseResult {
    var maxRepos: Int64 = 0
    var maxItems: Int64 = 0
    var timeoutMs: Int64 = 0
    var offlineFixture = false
    var i = 0
    while (i < args.size) {
        let arg = args[i].trimAscii()
        if (arg.isEmpty()) {
            i++
            continue
        }
        if (arg == "--offline-fixture") {
            offlineFixture = true
            i++
            continue
        }
        if (arg == "--timeout-ms") {
            return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "--timeout-ms is no longer supported for async scan jobs")
        }
        if (arg == "--max-repos" || arg == "--max-items") {
            if (i + 1 >= args.size) {
                return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} requires a numeric value")
            }
            let parsed = try {
                Int64.parse(args[i + 1].trimAscii())
            } catch (_: Exception) {
                return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} requires a numeric value")
            }
            if (parsed < 0) {
                return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} must be non-negative")
            }
            if (arg == "--max-repos") {
                maxRepos = parsed
            } else {
                maxItems = parsed
            }
            i += 2
            continue
        }
        return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "unknown scan option: ${arg}")
    }
    GitCodeScanOnceArgsParseResult(true, args: GitCodeScanOnceArgs(maxRepos: maxRepos, maxItems: maxItems, timeoutMillis: timeoutMs, offlineFixture: offlineFixture))
}

public func parseGitCodeDeliveryArgs(args: Array<String>): GitCodeDeliveryCommandArgsParseResult {
    if (args.size != 1) {
        return GitCodeDeliveryCommandArgsParseResult(false, status: "invalid_delivery_id", diagnostic: "deliveryId is required")
    }
    let deliveryId = args[0].trimAscii()
    if (!gitCodeDeliveryIdValid(deliveryId)) {
        return GitCodeDeliveryCommandArgsParseResult(false, status: "invalid_delivery_id", diagnostic: "deliveryId contains unsupported characters")
    }
    GitCodeDeliveryCommandArgsParseResult(true, args: GitCodeDeliveryCommandArgs(deliveryId: deliveryId))
}

public func parseGitCodeHookReconcileArgs(args: Array<String>): GitCodeHookReconcileArgsParseResult {
    var apply = false
    for (arg in args) {
        let value = arg.trimAscii()
        if (value.isEmpty()) { continue }
        if (value == "--apply") {
            apply = true
            continue
        }
        return GitCodeHookReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "unknown reconcile hooks option: ${value}")
    }
    GitCodeHookReconcileArgsParseResult(true, args: GitCodeHookReconcileArgs(apply: apply))
}

public func parseGitCodeReconcileOnceArgs(args: Array<String>): GitCodeEventReconcileArgsParseResult {
    var lookbackHours: Int64 = 24
    var maxRepos: Int64 = 0
    var maxItems: Int64 = 0
    var dryRun = true
    var i = 0
    while (i < args.size) {
        let arg = args[i].trimAscii()
        if (arg.isEmpty()) {
            i++
            continue
        }
        if (arg == "--apply") {
            dryRun = false
            i++
            continue
        }
        if (arg == "--timeout-ms") {
            return GitCodeEventReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "--timeout-ms is not supported for webhook-first reconcile")
        }
        if (arg == "--lookback-hours" || arg == "--max-repos" || arg == "--max-items") {
            if (i + 1 >= args.size) {
                return GitCodeEventReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} requires a numeric value")
            }
            let parsed = try {
                Int64.parse(args[i + 1].trimAscii())
            } catch (_: Exception) {
                return GitCodeEventReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} requires a numeric value")
            }
            if (parsed < 0 || (arg == "--lookback-hours" && parsed == 0)) {
                return GitCodeEventReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "${arg} must be positive")
            }
            if (arg == "--lookback-hours") {
                lookbackHours = parsed
            } else if (arg == "--max-repos") {
                maxRepos = parsed
            } else {
                maxItems = parsed
            }
            i += 2
            continue
        }
        return GitCodeEventReconcileArgsParseResult(false, status: "invalid_args", diagnostic: "unknown reconcile option: ${arg}")
    }
    GitCodeEventReconcileArgsParseResult(true, args: GitCodeEventReconcileArgs(lookbackHours: lookbackHours, maxRepos: maxRepos, maxItems: maxItems, dryRun: dryRun))
}

public func buildGitCodeAsyncScanPayload(
    context: GatewayCommandContext,
    args: GitCodeScanOnceArgs,
    jobId: String,
    idempotencyKey: String,
    deliveryTarget: ServicePluginDeliveryTarget
): String {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("mode", JsonString("async"))
    root.put("jobId", JsonString(jobId.trimAscii()))
    root.put("idempotencyKey", JsonString(idempotencyKey.trimAscii()))
    let requestedBy = JsonObject()
    requestedBy.put("channel", JsonString(context.channel))
    requestedBy.put("accountId", JsonString(context.accountId))
    requestedBy.put("peerHash", JsonString(hashRawPayload(context.peerId)))
    requestedBy.put("senderHash", JsonString(hashRawPayload(context.senderId)))
    root.put("requestedBy", requestedBy)
    root.put("deliveryTarget", servicePluginDeliveryTargetToJson(deliveryTarget))
    let limits = JsonObject()
    limits.put("maxRepos", JsonInt(boundedNonNegative(args.maxRepos)))
    limits.put("maxItems", JsonInt(boundedNonNegative(args.maxItems)))
    limits.put("maxDurationMillis", JsonInt(0))
    limits.put("perRequestTimeoutMillis", JsonInt(30000))
    limits.put("progressIntervalMillis", JsonInt(10000))
    root.put("limits", limits)
    let options = JsonObject()
    options.put("offlineFixture", JsonBool(args.offlineFixture))
    options.put("dryRun", JsonBool(args.dryRun))
    root.put("options", options)
    root.toJsonString()
}

public func buildGitCodeWebhookStatusPayload(context: GatewayCommandContext): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.status")
    root.toJsonString()
}

public func buildGitCodeDeadLetterListPayload(context: GatewayCommandContext): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.dead_letter_list")
    root.toJsonString()
}

public func buildGitCodeDeadLetterInspectPayload(context: GatewayCommandContext, deliveryId: String): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.dead_letter_inspect")
    root.put("deliveryId", JsonString(deliveryId.trimAscii()))
    root.toJsonString()
}

public func buildGitCodeWebhookReplayPayload(context: GatewayCommandContext, deliveryId: String): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.replay")
    root.put("deliveryId", JsonString(deliveryId.trimAscii()))
    root.put("operatorIntent", JsonBool(true))
    root.toJsonString()
}

public func buildGitCodeWebhookCancelPayload(context: GatewayCommandContext, deliveryId: String): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.cancel")
    root.put("deliveryId", JsonString(deliveryId.trimAscii()))
    root.put("operatorIntent", JsonBool(true))
    root.toJsonString()
}

public func buildGitCodeHookReconcilePayload(context: GatewayCommandContext, args: GitCodeHookReconcileArgs): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.reconcile_hooks")
    root.put("apply", JsonBool(args.apply))
    root.put("operatorIntent", JsonBool(args.apply))
    root.toJsonString()
}

public func buildGitCodeEventReconcilePayload(context: GatewayCommandContext, args: GitCodeEventReconcileArgs, deliveryTarget: ServicePluginDeliveryTarget, jobId!: String = "", idempotencyKey!: String = ""): String {
    let root = gitCodeCommandPayloadBase(context, "gitcode.webhook.reconcile_events")
    root.put("mode", JsonString("async"))
    if (!jobId.trimAscii().isEmpty()) { root.put("jobId", JsonString(jobId.trimAscii())) }
    if (!idempotencyKey.trimAscii().isEmpty()) { root.put("idempotencyKey", JsonString(idempotencyKey.trimAscii())) }
    root.put("lookbackHours", JsonInt(args.lookbackHours))
    root.put("dryRun", JsonBool(args.dryRun))
    let limits = JsonObject()
    limits.put("maxRepos", JsonInt(args.maxRepos))
    limits.put("maxItems", JsonInt(args.maxItems))
    root.put("limits", limits)
    root.put("deliveryTarget", servicePluginDeliveryTargetToJson(deliveryTarget))
    root.toJsonString()
}

public func formatGitCodeScanOnceResult(result: CapabilityInvokeResult): String {
    "gitcode scan_once status=${result.status} capability=${result.capabilityId}"
}

public func renderGitCodeWebhookStatusResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode Webhook 状态：插件返回无法解析的响应。"
    }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let listenerJson = jsonObjectField(payload, "listener")
    let queueJson = jsonObjectField(payload, "queue")
    let processorJson = jsonObjectField(payload, "processor")
    let stateSaveJson = jsonObjectField(payload, "stateSave")
    let listenerStatusValue = jsonStringField(payload, "listenerStatus")
    let listenerStatus = if (!listenerStatusValue.isEmpty()) { listenerStatusValue } else { jsonStringField(listenerJson, "status", fallback: "unknown") }
    let processorStatusValue = jsonStringField(payload, "processorStatus")
    let processorStatus = if (!processorStatusValue.isEmpty()) { processorStatusValue } else { jsonStringField(processorJson, "status", fallback: "unknown") }
    let receiver = jsonStringField(payload, "receiver", fallback: deriveGitCodeWebhookReceiverStatus(listenerStatus, processorStatus))
    let bindValue = jsonStringField(payload, "webhookBind")
    let bind = if (!bindValue.isEmpty()) { bindValue } else { jsonStringField(listenerJson, "bind") }
    let pending = jsonIntField(queueJson, "pending", fallback: jsonIntField(payload, "pending", fallback: jsonIntField(payload, "pendingCount", fallback: 0)))
    let processing = jsonIntField(queueJson, "processing", fallback: jsonIntField(payload, "processing", fallback: 0))
    let processed = jsonIntField(queueJson, "processed", fallback: jsonIntField(payload, "processed", fallback: 0))
    let dead = jsonIntField(queueJson, "deadLetter", fallback: jsonIntField(payload, "deadLetter", fallback: jsonIntField(payload, "deadLetterCount", fallback: 0)))
    let cancelled = jsonIntField(queueJson, "cancelled", fallback: jsonIntField(payload, "cancelled", fallback: 0))
    let lastBatchProcessed = jsonIntField(payload, "lastBatchProcessed", fallback: jsonIntField(processorJson, "processed", fallback: processed))
    let lastBatchClaimed = jsonIntField(payload, "lastBatchClaimed", fallback: 0)
    let emptyTickCount = jsonIntField(payload, "emptyTickCount", fallback: jsonIntField(processorJson, "emptyTicks", fallback: 0))
    let listenerLastStatus = jsonIntField(payload, "listenerLastStatus", fallback: jsonIntField(listenerJson, "lastStatus", fallback: 0))
    let listenerLastDurationMs = jsonIntField(payload, "listenerLastDurationMs", fallback: jsonIntField(listenerJson, "lastDurationMs", fallback: 0))
    let healthzValue = jsonStringField(listenerJson, "healthz")
    let healthzText = if (!healthzValue.isEmpty()) { healthzValue } else if (payload.contains("\"healthzCount\":")) { "${jsonIntField(payload, "healthzCount", fallback: 0)}" } else { "" }
    let activeRequestCount = jsonIntField(payload, "activeRequestCount", fallback: 0)
    let stateSaveStatusValue = jsonStringField(payload, "stateSaveStatus")
    let stateSaveStatus = if (!stateSaveStatusValue.isEmpty()) { stateSaveStatusValue } else { jsonStringField(stateSaveJson, "status") }
    let stateSaveSkipped = jsonBoolField(payload, "stateSaveSkipped")
    let stateSaveDurationMs = jsonIntField(payload, "stateSaveDurationMs", fallback: jsonIntField(stateSaveJson, "lastDurationMs", fallback: 0))
    let stateSaveBytes = jsonIntField(payload, "stateSaveBytes", fallback: jsonIntField(stateSaveJson, "bytes", fallback: 0))
    let auditCount = jsonIntField(payload, "auditCount", fallback: jsonIntField(stateSaveJson, "auditCount", fallback: 0))
    let auditMax = jsonIntField(payload, "auditMax", fallback: jsonIntField(stateSaveJson, "auditMax", fallback: 0))
    let publicBaseUrl = if (jsonBoolField(payload, "publicBaseUrlConfigured")) { "configured" } else { "missing" }
    let lastError = redactGitCodePluginText(jsonStringField(payload, "lastError"))
    let listenerError = redactGitCodePluginText(jsonStringField(listenerJson, "lastError"))
    let errorKind = redactGitCodePluginText(jsonStringField(payload, "errorKind"))
    let listenerLine = if (!bind.isEmpty()) { "${bind} ${listenerStatus}" } else { listenerStatus }
    let listenerRuntimeLine = if (payload.contains("\"listenerLastStatus\":") || payload.contains("\"listenerLastDurationMs\":") || payload.contains("\"healthzCount\":") || payload.contains("\"activeRequestCount\":") || !listenerJson.isEmpty()) {
        let healthzPart = if (healthzText.isEmpty()) { "" } else { " healthz=${healthzText}" }
        let activePart = if (payload.contains("\"activeRequestCount\":")) { " active=${activeRequestCount}" } else { "" }
        " lastStatus=${listenerLastStatus} lastDuration=${listenerLastDurationMs}ms${healthzPart}${activePart}"
    } else {
        ""
    }
    let processorRuntimeLine = if (payload.contains("\"lastBatchClaimed\":") || payload.contains("\"emptyTickCount\":") || !processorJson.isEmpty()) {
        " lastBatchProcessed=${lastBatchProcessed} claimed=${lastBatchClaimed} emptyTicks=${emptyTickCount}"
    } else {
        " lastBatchProcessed=${lastBatchProcessed}"
    }
    let stateSaveLine = if (stateSaveStatus.isEmpty()) {
        "stateSave: diagnostics-missing\nmissing diagnostics: stateSave"
    } else {
        let skippedPart = if (payload.contains("\"stateSaveSkipped\":")) { " skipped=${stateSaveSkipped}" } else { "" }
        "stateSave: ${stateSaveStatus}${skippedPart} lastDuration=${stateSaveDurationMs}ms bytes=${stateSaveBytes} audit=${auditCount}/${auditMax}"
    }
    let errorKindLine = if (errorKind.isEmpty()) { "" } else { "\nerrorKind: ${errorKind}" }
    let mergedLastError = if (!lastError.isEmpty()) { lastError } else { listenerError }
    "GitCode Webhook 状态\n" +
        "status: ${status}\n" +
        "receiver: ${receiver}${errorKindLine}\n" +
        "listener: ${listenerLine}${listenerRuntimeLine}\n" +
        "queue: pending=${pending} processing=${processing} processed=${processed} dead-letter=${dead} cancelled=${cancelled}\n" +
        "processor: ${processorStatus}${processorRuntimeLine}\n" +
        "${stateSaveLine}\n" +
        "publicBaseUrl: ${publicBaseUrl}${if (mergedLastError.isEmpty()) { "" } else { "\nlastError: ${mergedLastError}" }}"
}

public func renderGitCodeDeadLetterListResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode webhook dead-letter：插件返回无法解析的响应。"
    }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let count = jsonIntField(payload, "count", fallback: jsonIntField(payload, "deadLetter", fallback: 0))
    let latest = jsonStringField(payload, "latest", fallback: jsonStringField(payload, "deliveryId"))
    let errorKind = jsonStringField(payload, "errorKind")
    "GitCode webhook dead-letter：status=${status} count=${count} latest=${safeDeliveryForDisplay(latest)} error=${redactGitCodePluginText(errorKind)}"
}

public func renderGitCodeDeadLetterInspectResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode webhook dead-letter inspect：插件返回无法解析的响应。"
    }
    let deliveryId = safeDeliveryForDisplay(jsonStringField(payload, "deliveryId"))
    let stage = jsonStringField(payload, "stage", fallback: "unknown")
    let errorKind = redactGitCodePluginText(jsonStringField(payload, "errorKind"))
    let diagnostic = redactGitCodePluginText(jsonStringField(payload, "diagnostic"))
    "GitCode webhook dead-letter 诊断：deliveryId=${deliveryId} stage=${stage} error=${errorKind} diagnostic=${diagnostic}"
}

public func renderGitCodeWebhookReplayResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode webhook replay：插件返回无法解析的响应。"
    }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let deliveryId = safeDeliveryForDisplay(jsonStringField(payload, "deliveryId"))
    let previous = jsonStringField(payload, "previousStatus")
    let next = jsonStringField(payload, "newStatus", fallback: jsonStringField(payload, "statusAfter", fallback: "pending"))
    "GitCode webhook replay：status=${status} deliveryId=${deliveryId} ${previous}->${next}"
}

public func renderGitCodeWebhookCancelResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode webhook cancel：插件返回无法解析的响应。"
    }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let deliveryId = safeDeliveryForDisplay(jsonStringField(payload, "deliveryId"))
    let reason = redactGitCodePluginText(jsonStringField(payload, "reason"))
    "GitCode webhook cancel：status=${status} deliveryId=${deliveryId} reason=${reason}"
}

public func renderGitCodeHookReconcileResult(payload: String): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode webhook hook reconcile：插件返回无法解析的响应。"
    }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let applyRejected = status == "apply_rejected" || jsonBoolField(payload, "applyRejected")
    let aligned = jsonIntField(payload, "aligned", fallback: 0)
    let missing = jsonIntField(payload, "missing", fallback: 0)
    let drifted = jsonIntField(payload, "drifted", fallback: 0)
    let wrongUrl = jsonIntField(payload, "wrong_url", fallback: jsonIntField(payload, "wrongUrl", fallback: 0))
    let wrongEvents = jsonIntField(payload, "wrong_events", fallback: jsonIntField(payload, "wrongEvents", fallback: 0))
    let authFailed = jsonIntField(payload, "auth_failed", fallback: jsonIntField(payload, "authFailed", fallback: 0))
    let created = jsonIntField(payload, "created", fallback: 0)
    let updated = jsonIntField(payload, "updated", fallback: 0)
    let failed = jsonIntField(payload, "failed", fallback: 0)
    let reason = redactGitCodePluginText(jsonStringField(payload, "rejectReason"))
    let rejectLine = if (applyRejected) { " apply rejected reason=${if (reason.isEmpty()) { "unknown" } else { reason }}" } else { "" }
    "GitCode webhook hook reconcile：status=${status}${rejectLine} aligned=${aligned} missing=${missing} drifted=${drifted} wrong_url=${wrongUrl} wrong_events=${wrongEvents} auth_failed=${authFailed} created=${created} updated=${updated} failed=${failed}"
}

public func renderGitCodeEventReconcileResult(payload: String, aliasFromScanOnce!: Bool = false): String {
    if (!payload.trimAscii().startsWith("{")) {
        return "GitCode reconcile：插件返回无法解析的响应。"
    }
    let prefix = if (aliasFromScanOnce) { "已切换为 webhook-first，/gitcode scan once 按 reconcile/fallback 执行，不做历史全量扫描。\n" } else { "" }
    let status = jsonStringField(payload, "status", fallback: "ok")
    let lookback = jsonIntField(payload, "lookbackHours", fallback: 24)
    let repos = jsonIntField(payload, "repos", fallback: jsonIntField(payload, "scannedRepos", fallback: 0))
    let candidates = jsonIntField(payload, "candidates", fallback: jsonIntField(payload, "checkedItems", fallback: 0))
    let newEvents = jsonIntField(payload, "newEvents", fallback: 0)
    let drafts = jsonIntField(payload, "drafts", fallback: jsonIntField(payload, "draftsGenerated", fallback: 0))
    let notifications = jsonIntField(payload, "notifications", fallback: jsonIntField(payload, "notificationsSent", fallback: 0))
    let writes = jsonIntField(payload, "writes", fallback: 0)
    prefix + "GitCode reconcile 完成：status=${status} 窗口=${lookback}h 仓库 ${repos} 个，候选事件 ${candidates} 条，新增事件 ${newEvents} 条，草稿 ${drafts} 条，通知 ${notifications} 条，写回 ${writes} 条。"
}

public func handleGitCodeKnowledgeQueryCommand(context: GatewayCommandContext, query: String): GatewayCommandResult {
    if (!context.authorized) {
        return GatewayCommandResult(false, "unauthorized", message: "sender is not authorized")
    }
    let request = buildCangjieKnowledgeAgentRequest(context, query)
    GatewayCommandResult(true, "agent_request", message: request.prompt)
}

public func buildCangjieKnowledgeAgentRequest(context: GatewayCommandContext, query: String): AgentInvokeRequest {
    AgentInvokeRequest("Answer with Cangjie community knowledge and cite CKB evidence: ${query.trimAscii()}", sessionKey: context.sessionKey, ckbRequired: true)
}

public func normalizeGitCodeAcceptedEvent(payload: String): GitCodeEventNormalizeResult {
    if (payload.contains("token=") || payload.toAsciiLower().contains("authorization")) {
        return GitCodeEventNormalizeResult(false, diagnostic: "payload_contains_secret")
    }
    let eventId = fieldValue(payload, "eventId")
    let repo = fieldValue(payload, "repo")
    let url = fieldValue(payload, "url")
    if (eventId.isEmpty() || repo.isEmpty() || url.isEmpty()) {
        return GitCodeEventNormalizeResult(false, diagnostic: "missing eventId/repo/url")
    }
    GitCodeEventNormalizeResult(true, event: GitCodeAcceptedEvent(eventId, repo, fieldValue(payload, "kind"), fieldValue(payload, "number"), fieldValue(payload, "author"), url, fieldValue(payload, "content")))
}

public func dedupeGitCodeEvent(event: GitCodeAcceptedEvent): DedupeResult {
    if (gitcodeSeenEvents.contains(event.eventId)) {
        return DedupeResult(true, event.eventId)
    }
    gitcodeSeenEvents.add(event.eventId)
    DedupeResult(false, event.eventId)
}

public func publishGitCodeRawEventNotification(event: GitCodeAcceptedEvent): NotificationResult {
    let targets = buildGitCodeNotificationTargets(GitCodeSubscriptionScope(rawEvents: true, generatedReplies: false))
    if (targets.size == 0) {
        return NotificationResult(true, "no_subscribers", delivered: 0)
    }
    NotificationResult(true, "delivered", delivered: targets.size, message: formatGitCodeEventNotification(event))
}

public func formatGitCodeEventNotification(event: GitCodeAcceptedEvent): String {
    "GitCode ${event.kind} ${event.repo}#${event.number} by ${event.author}: ${compactNotificationText(event.content)} ${event.url}"
}

public func publishGeneratedReplyNotification(event: GitCodeAcceptedEvent, result: GitCodeDraftResult): NotificationResult {
    let targets = buildGitCodeNotificationTargets(GitCodeSubscriptionScope(rawEvents: false, generatedReplies: true))
    if (targets.size == 0) {
        return NotificationResult(true, "no_subscribers", delivered: 0, message: formatGeneratedReplyNotification(event, result))
    }
    NotificationResult(true, "delivered", delivered: targets.size, message: formatGeneratedReplyNotification(event, result))
}

public func formatGeneratedReplyNotification(event: GitCodeAcceptedEvent, result: GitCodeDraftResult): String {
    "GitCode generated_reply ${event.url}\nsummary=${compactNotificationText(result.summary)}\ndraft=${compactNotificationText(result.draft)}\nsafety=${result.safety} needsHumanReview=${result.needsHumanReview}\ncitations=${joinStrings(result.citations, ",")} knowledgeVersion=${result.knowledgeVersion}"
}

public func buildGitCodeNotificationTargets(scope: GitCodeSubscriptionScope): ArrayList<GitCodeSubscriptionTarget> {
    let out = ArrayList<GitCodeSubscriptionTarget>()
    for ((_, row) in gitcodeSubscriptions) {
        if (!row.active) { continue }
        if ((scope.rawEvents && row.scope.rawEvents) || (scope.generatedReplies && row.scope.generatedReplies)) {
            out.add(row.target)
        }
    }
    out
}

public func buildGitCodeAgentDraftRequest(event: GitCodeAcceptedEvent): GitCodeAgentDraftRequest {
    GitCodeAgentDraftRequest(event, ckbRequired: true, sourceAnalysisAllowed: true)
}

public func attachCkbEvidencePolicy(request: GitCodeAgentDraftRequest): AgentInvokeRequest {
    AgentInvokeRequest("Summarize and draft reply for ${request.event.url}; use CKB evidence and source_analysis when code context is needed.", ckbRequired: request.ckbRequired)
}

public func invokeGitCodeDraftAgent(request: GitCodeAgentDraftRequest, ckbAvailable!: Bool = true): GitCodeDraftResult {
    if (!ckbAvailable) {
        return GitCodeDraftResult("CKB unavailable", "", safety: "needs_human_review", citations: [], degraded: true, needsHumanReview: true)
    }
    GitCodeDraftResult("Issue summary for ${request.event.repo}", "Thanks for the report. We will inspect the linked context.", citations: ["ckb://evidence/${request.event.repo}"], knowledgeVersion: "ckb-test")
}

public func buildGeneratedReplyResult(event: GitCodeAcceptedEvent, result: GitCodeDraftResult): GitCodeDraftResult {
    if (result.citations.size == 0 || result.degraded) {
        return GitCodeDraftResult(result.summary, result.draft, safety: result.safety, citations: result.citations, knowledgeVersion: result.knowledgeVersion, degraded: true, needsHumanReview: true)
    }
    result
}

public func buildGcmWritebackApplyPayload(event: GitCodeAcceptedEvent, result: GitCodeDraftResult): GitCodeWritebackApplyPayload {
    GitCodeWritebackApplyPayload(event, result)
}

public func dispatchWritebackApplyResult(payload: GitCodeWritebackApplyPayload, autoReplyEnabled!: Bool = false): CapabilityInvokeResult {
    let body = "{\"eventId\":\"${payload.eventId}\",\"repo\":\"${payload.repo}\",\"safety\":\"${payload.safety}\",\"needsHumanReview\":${payload.needsHumanReview}}"
    CapabilityInvokeResult(true, if (autoReplyEnabled) { "writeback_requested" } else { "writeback_dry_run" }, capabilityId: "gitcode.writeback.apply_result", payload: body)
}

public func runMetisGcmPluginSmoke(config: MetisGcmSmokeConfig): SmokeTestResult {
    resetGitCodePluginHostForTest()
    if (config.subscribers > 0) {
        let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "default", "peer"))
    }
    let event = GitCodeAcceptedEvent("e1", "Cangjie/community", "issue", "1", "alice", "https://gitcode.com/Cangjie/community/issues/1", "hello")
    let notification = publishGitCodeRawEventNotification(event)
    SmokeTestResult(notification.ok, notification.status, notificationCount: notification.delivered)
}

public func injectFakeGcmAcceptedEvent(event: GitCodeAcceptedEvent): NotificationResult {
    let dup = dedupeGitCodeEvent(event)
    if (dup.duplicate) {
        return NotificationResult(true, "duplicate", delivered: 0)
    }
    publishGitCodeRawEventNotification(event)
}

public func runMetisCkbEvidenceSmoke(config: MetisCkbSmokeConfig): GitCodeDraftResult {
    let event = GitCodeAcceptedEvent("e2", "Cangjie/stdx", "issue", "2", "bob", "https://gitcode.com/Cangjie/stdx/issues/2", "HttpClient")
    invokeGitCodeDraftAgent(buildGitCodeAgentDraftRequest(event), ckbAvailable: config.ckbAvailable)
}

public func assertCkbCitationPresent(result: GitCodeDraftResult): Bool {
    result.citations.size > 0 && !result.knowledgeVersion.isEmpty() && !result.needsHumanReview
}

public func runGitCodeMonitorEndToEndSmoke(config: EndToEndSmokeConfig): EndToEndSmokeResult {
    resetGitCodePluginHostForTest()
    if (config.subscribers > 0) {
        let _ = saveGitCodeSubscription(GitCodeSubscriptionTarget("telegram", "default", "peer"))
    }
    let event = GitCodeAcceptedEvent("e2e", "Cangjie/community", "issue", "3", "alice", "https://gitcode.com/Cangjie/community/issues/3", "build failed")
    let draft = buildGeneratedReplyResult(event, invokeGitCodeDraftAgent(buildGitCodeAgentDraftRequest(event), ckbAvailable: config.ckbAvailable))
    let notification = publishGeneratedReplyNotification(event, draft)
    let writeback = dispatchWritebackApplyResult(buildGcmWritebackApplyPayload(event, draft), autoReplyEnabled: config.autoReplyEnabled && !draft.needsHumanReview)
    let text = notification.message + writeback.payload
    EndToEndSmokeResult(notification.ok && writeback.ok && !containsSecret(text), notification.delivered > 0 || notification.status == "no_subscribers", writeback.status == "writeback_requested", needsHumanReview: draft.needsHumanReview, secretLeak: containsSecret(text))
}

public func assertEndToEndBoundaries(result: EndToEndSmokeResult): Bool {
    result.ok && result.generatedReplySent && !result.secretLeak
}

private func gitCodeCommandPayloadBase(context: GatewayCommandContext, action: String): JsonObject {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("action", JsonString(action))
    let requestedBy = JsonObject()
    requestedBy.put("channel", JsonString(context.channel))
    requestedBy.put("accountId", JsonString(context.accountId))
    requestedBy.put("peerHash", JsonString(hashRawPayload(context.peerId)))
    requestedBy.put("senderHash", JsonString(hashRawPayload(context.senderId)))
    requestedBy.put("sessionHash", JsonString(hashRawPayload(context.sessionKey)))
    requestedBy.put("operator", JsonBool(context.isOperator))
    root.put("requestedBy", requestedBy)
    root
}

private func gitCodeDeliveryIdValid(deliveryId: String): Bool {
    if (deliveryId.isEmpty() || deliveryId.size > 160) { return false }
    if (deliveryId.contains("..")) { return false }
    for (r in deliveryId.runes()) {
        let ok = (r >= r'a' && r <= r'z') ||
            (r >= r'A' && r <= r'Z') ||
            (r >= r'0' && r <= r'9') ||
            r == r'-' ||
            r == r'_' ||
            r == r'.'
        if (!ok) { return false }
    }
    true
}

private func safeDeliveryForDisplay(deliveryId: String): String {
    if (deliveryId.isEmpty()) { return "(unknown)" }
    if (gitCodeDeliveryIdValid(deliveryId)) { return deliveryId }
    "delivery-${deliveryId.size}"
}

private func jsonObjectField(raw: String, key: String): String {
    let needle = "\"${key}\":{"
    if (!raw.contains(needle)) { return "" }
    let tail = raw.split(needle, 2)[1]
    "{" + tail.split("}", 2)[0] + "}"
}

private func jsonStringField(raw: String, key: String, fallback!: String = ""): String {
    let value = fieldValue(raw, key)
    if (value.isEmpty()) { fallback } else { redactGitCodePluginText(value) }
}

private func jsonIntField(raw: String, key: String, fallback!: Int64 = 0): Int64 {
    let needle = "\"${key}\":"
    if (!raw.contains(needle)) { return fallback }
    let tail = raw.split(needle, 2)[1].trimAscii()
    let text = tail.split(",", 2)[0].split("}", 2)[0].trimAscii()
    if (text.isEmpty() || text == "-") { return fallback }
    try { Int64.parse(text) } catch (_: Exception) { fallback }
}

private func jsonBoolField(raw: String, key: String): Bool {
    let needle = "\"${key}\":"
    if (!raw.contains(needle)) { return false }
    let tail = raw.split(needle, 2)[1].trimAscii()
    tail.startsWith("true")
}

private func deriveGitCodeWebhookReceiverStatus(listenerStatus: String, processorStatus: String): String {
    if (listenerStatus == "unknown" && processorStatus == "unknown") { return "unknown" }
    if (listenerStatus == "listening" && (processorStatus == "running" || processorStatus == "disabled")) { return "running" }
    "degraded"
}

private func boundedNonNegative(value: Int64): Int64 {
    if (value < 0) { 0 } else { value }
}

private func fieldValue(raw: String, key: String): String {
    let needle = "\"${key}\":\""
    if (!raw.contains(needle)) { return "" }
    let tail = raw.split(needle, 2)[1]
    tail.split("\"", 2)[0]
}

private func compactNotificationText(text: String, limit!: Int64 = 180): String {
    let normalized = redactGitCodePluginText(text.replace("\n", " ").replace("\r", " ").trimAscii())
    if (normalized.size <= limit) { return normalized }
    normalized[0..limit] + "...[truncated]"
}

private func containsSecret(text: String): Bool {
    let lower = text.toAsciiLower()
    lower.contains("authorization:") || lower.contains("bearer ") || lower.contains("token=") || lower.contains("\"token\"") || lower.contains("cookie=") || lower.contains("appsecret") || lower.contains("/Users/")
}

private func redactGitCodePluginText(text: String): String {
    if (containsSecret(text)) {
        return "[redacted]"
    }
    text
}

private func joinStrings(items: Array<String>, separator: String): String {
    var out = ""
    for (item in items) {
        if (out.isEmpty()) {
            out = item
        } else {
            out += separator + item
        }
    }
    out
}

private func safeTargetKey(targetKey: String): String {
    "target-${targetKey.size}"
}
