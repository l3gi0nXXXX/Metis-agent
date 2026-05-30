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
    public init(dryRun!: Bool = true, maxRepos!: Int64 = 5, maxItems!: Int64 = 30, timeoutMillis!: Int64 = 30000, offlineFixture!: Bool = false) {
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
    if (first == "scan" && parts.size > 3 && parts[2].trimAscii().toAsciiLower() == "status") {
        return GitCodePluginCommandParseResult(true, action: "scan_status", args: parts[3..])
    }
    if (first == "scan" && parts.size > 3 && parts[2].trimAscii().toAsciiLower() == "cancel") {
        return GitCodePluginCommandParseResult(true, action: "scan_cancel", args: parts[3..])
    }
    if (first == "scan" && parts.size > 2 && parts[2].trimAscii().toAsciiLower() == "once") {
        return GitCodePluginCommandParseResult(true, action: "scan_once", args: parts[3..])
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
    "{\"dryRun\":${args.dryRun},\"maxRepos\":${boundedNonNegative(args.maxRepos)},\"maxItems\":${boundedNonNegative(args.maxItems)},\"timeoutMillis\":${boundedNonNegative(args.timeoutMillis)}}"
}

public func parseGitCodeScanOnceArgs(args: Array<String>): GitCodeScanOnceArgsParseResult {
    var maxRepos: Int64 = 5
    var maxItems: Int64 = 30
    var timeoutMs: Int64 = 30000
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
        if (arg == "--max-repos" || arg == "--max-items" || arg == "--timeout-ms") {
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
            } else if (arg == "--max-items") {
                maxItems = parsed
            } else {
                timeoutMs = parsed
            }
            i += 2
            continue
        }
        return GitCodeScanOnceArgsParseResult(false, status: "invalid_args", diagnostic: "unknown scan option: ${arg}")
    }
    GitCodeScanOnceArgsParseResult(true, args: GitCodeScanOnceArgs(maxRepos: maxRepos, maxItems: maxItems, timeoutMillis: timeoutMs, offlineFixture: offlineFixture))
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
    limits.put("maxDurationMillis", JsonInt(boundedNonNegative(args.timeoutMillis)))
    limits.put("perRequestTimeoutMillis", JsonInt(30000))
    limits.put("progressIntervalMillis", JsonInt(10000))
    root.put("limits", limits)
    let options = JsonObject()
    options.put("offlineFixture", JsonBool(args.offlineFixture))
    options.put("dryRun", JsonBool(args.dryRun))
    root.put("options", options)
    root.toJsonString()
}

public func formatGitCodeScanOnceResult(result: CapabilityInvokeResult): String {
    "gitcode scan_once status=${result.status} capability=${result.capabilityId}"
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
