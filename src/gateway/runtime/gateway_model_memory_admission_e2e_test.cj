package metis.gateway.runtime

import magic.config.Config
import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.cron.{CronJob, CronJobState, CronSchedule, cronLoadOrEmpty, cronSave}
import metis.gateway.core.*
import metis.gateway.gitcode_plugin.*
import metis.gateway.logging.gatewayLoggingResetForTest
import metis.gateway.model.{ChannelPolicyConfig, InboundMessage, OutboundMessage, SendResult}
import metis.gateway.service_plugin.*
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest}
import metis.process.{managedStdioBroker, resetManagedStdioBrokerForTest}
import metis.utils.ShellUtils

import std.collection.{ArrayList, HashMap}
import std.convert.Parsable
import std.core.Duration
import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, remove}
import std.sync.{Condition, Mutex}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString, JsonValue}

private const S3I_GIB: Int64 = 1024 * 1024 * 1024
private const S3I_ORDINARY_PROMPT = "s3-i ordinary barrier 中文🙂"
private const S3I_CRON_PROMPT = "s3-i cron barrier 中文🙂"
private const S3I_SERVICE_DRAFT = "建议补充边界测试。"
private const S3I_DELIVERY_ID = "s3-i-delivery"
private const S3I_EVENT_ID = "gitcode:Cangjie/community:issue:s3-i"
private const S3I_TOKEN_A = "s3-i-attempt-a"
private const S3I_TOKEN_B = "s3-i-attempt-b"
private const S3I_PRIVATE_SENTINEL = "s3-i-private-sentinel"

private class S3IShortReader {
    private var offset: Int64 = 0
    private let bytes = "short-read-中文🙂".toArray()
    func read(buffer: Array<UInt8>): Int64 {
        if (this.offset >= this.bytes.size) { return 0 }
        let count = min(3, this.bytes.size - this.offset)
        for (index in 0..count) { buffer[index] = this.bytes[this.offset + index] }
        this.offset += count
        count
    }
}

private func s3IRestoreEnv(name: String, old: Option<String>): Unit {
    match (old) {
        case Some(value) => setVariable(name, value)
        case None => removeVariable(name)
    }
}

private class S3IBarrier {
    private let lock = Mutex()
    private var condition: Condition
    private var ordinary = 0
    private var cron = 0
    private var service = 0
    private var released = false
    private var failNext = false
    private var configured = false
    private var ordinaryKey = ""
    private var cronKey = ""
    private let serviceKey = "agent:main:explicit:service-plugin/gitcode/webhook/${S3I_EVENT_ID.toAsciiLower()}"
    private var servicePrompt = ""

    init() { synchronized(this.lock) { this.condition = this.lock.condition() } }

    func configure(ordinaryKey: String, cronKey: String, servicePrompt!: String = "service-prompt"): Unit {
        synchronized(this.lock) {
            if (this.configured) { throw Exception("s3_i_barrier_already_configured") }
            this.ordinaryKey = ordinaryKey
            this.cronKey = cronKey
            this.servicePrompt = servicePrompt
            this.configured = true
        }
    }

    func run(sessionKey: String, prompt: String): String {
        var shouldWait = false
        var matched = false
        synchronized(this.lock) {
            if (this.configured && sessionKey == this.ordinaryKey && prompt == S3I_ORDINARY_PROMPT && this.ordinary == 0) {
                this.ordinary++
                shouldWait = true
                matched = true
            } else if (this.configured && sessionKey == this.cronKey && prompt == S3I_CRON_PROMPT && this.cron == 0) {
                this.cron++
                shouldWait = true
                matched = true
            } else if (this.configured && sessionKey == this.serviceKey && prompt == this.servicePrompt && this.service == 0) {
                this.service++
                matched = true
            } else if ((sessionKey == this.ordinaryKey && prompt == S3I_ORDINARY_PROMPT) ||
                (sessionKey == this.cronKey && prompt == S3I_CRON_PROMPT) ||
                (sessionKey == this.serviceKey && prompt == this.servicePrompt)) {
                throw Exception("s3_i_identity_already_consumed")
            }
            this.condition.notifyAll()
            while (shouldWait && !this.released) { this.condition.wait() }
            if (matched && this.failNext) {
                this.failNext = false
                throw Exception("s3_i_runner_failure private Authorization token /Users/private stack")
            }
        }
        if (prompt.contains(S3I_ORDINARY_PROMPT) || prompt.contains(S3I_CRON_PROMPT)) {
            "{\"name\":\"_answer_\",\"arguments\":{\"result\":\"route-complete\"}}"
        } else {
            S3I_SERVICE_DRAFT
        }
    }

    func awaitHeld(timeoutMs: Int64): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        synchronized(this.lock) {
            while (this.ordinary < 1 || this.cron < 1) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) { return false }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            true
        }
    }

    func release(): Unit { synchronized(this.lock) { this.released = true; this.condition.notifyAll() } }
    func failOnce(): Unit { synchronized(this.lock) { this.failNext = true } }
    func truth(): (Int64, Int64, Int64) { synchronized(this.lock) { (this.ordinary, this.cron, this.service) } }
}

private class S3IAdapter <: ChannelAdapter {
    private let lock = Mutex()
    private var sends = ArrayList<String>()
    private var running = false
    public prop name: String { get() { "telegram" } }
    public func start(): Unit { synchronized(this.lock) { this.running = true } }
    public func stop(): Unit { synchronized(this.lock) { this.running = false } }
    public func pullInbound(): Array<InboundMessage> { [] }
    public func send(message: OutboundMessage): SendResult { synchronized(this.lock) { this.sends.add(message.text) }; SendResult.Success }
    public func sendWithMessageId(message: OutboundMessage): String { synchronized(this.lock) { this.sends.add(message.text) }; "s3-i-message" }
    func count(): Int64 { synchronized(this.lock) { this.sends.size } }
    func onlyText(): String { synchronized(this.lock) { if (this.sends.size == 1) { this.sends[0] } else { "" } } }
    func isRunning(): Bool { synchronized(this.lock) { this.running } }
}

private class S3IAckTruth {
    let acceptedA: Int64
    let retryA: Int64
    let completionA: Int64
    let acceptedB: Int64
    let completionB: Int64
    let invalid: Int64
    init(acceptedA: Int64, retryA: Int64, completionA: Int64, acceptedB: Int64, completionB: Int64, invalid: Int64) {
        this.acceptedA = acceptedA; this.retryA = retryA; this.completionA = completionA
        this.acceptedB = acceptedB; this.completionB = completionB; this.invalid = invalid
    }
}

private class S3IPhaseTruth {
    let initWritten: Int64
    let signalSeen: Int64
    let eventWriteBefore: Int64
    let eventWriteAfter: Int64
    let aborted: Int64
    let signalTimeout: Int64
    let invalid: Int64
    init(initWritten: Int64, signalSeen: Int64, eventWriteBefore: Int64, eventWriteAfter: Int64,
        aborted: Int64, signalTimeout: Int64, invalid: Int64) {
        this.initWritten = initWritten; this.signalSeen = signalSeen
        this.eventWriteBefore = eventWriteBefore; this.eventWriteAfter = eventWriteAfter
        this.aborted = aborted; this.signalTimeout = signalTimeout; this.invalid = invalid
    }
}

private func s3IBoundedMarkerReadFrom(reader: (Array<UInt8>) -> Int64): (String, Bool) {
    let retained = ArrayList<UInt8>()
    let chunk = Array<UInt8>(4096) { _index => UInt8(0) }
    while (true) {
        let count = try { reader(chunk) } catch (_: Exception) { return ("", true) }
        if (count < 0 || count > chunk.size) { return ("", true) }
        if (count == 0) { break }
        if (retained.size + count > 65536) { return ("", true) }
        for (index in 0..count) { retained.add(chunk[index]) }
    }
    try { (String.fromUtf8(retained.toArray()), false) } catch (_: Exception) { ("", true) }
}

private func s3IMarkerIdentity(path: Path): (Bool, String, Int64, Int64) {
    try {
        let info = FileInfo(path)
        (
            info.isRegular() && !info.isSymbolicLink() && canonicalize(path).toString() == path.normalize().toString(),
            canonicalize(path).toString(),
            info.size,
            info.lastModificationTime.toUnixTimeStamp().toNanoseconds()
        )
    } catch (_: Exception) { (false, "", -1, -1) }
}

private func s3IBoundedMarkerRead(path: Path): (String, Bool) {
    if (!exists(path)) { return ("", false) }
    let before = s3IMarkerIdentity(path)
    if (!before[0]) { return ("", true) }
    try {
        var read: (String, Bool) = ("", true)
        try (file = File(path, OpenMode.Read)) {
            read = s3IBoundedMarkerReadFrom({ buffer: Array<UInt8> => file.read(buffer) })
        }
        let after = s3IMarkerIdentity(path)
        if (!after[0] || after[1] != before[1] || after[2] != before[2] || after[3] != before[3]) {
            return ("", true)
        }
        read
    } catch (_: Exception) { ("", true) }
}

private func s3IAckTruth(path: Path): S3IAckTruth {
    var acceptedA = 0; var retryA = 0; var completionA = 0
    var acceptedB = 0; var completionB = 0; var invalid = 0
    let read = s3IBoundedMarkerRead(path)
    if (read[1]) { return S3IAckTruth(0, 0, 0, 0, 0, 1) }
    let raw = read[0]
    for (line in raw.split("\n")) {
        if (line.trimAscii().isEmpty()) { continue }
        let decoded = decodeServiceFrame(line)
        if (!decoded.ok || decoded.frame.serviceId != "gitcode-monitor" ||
            decoded.frame.method != "emitCapabilityEvent" || decoded.frame.capabilityId != "gitcode.event.accepted") { invalid++; continue }
        let parsed = parseServiceEventAckPayload(decoded.frame.payload)
        if (!parsed.ok || parsed.ack.deliveryId != S3I_DELIVERY_ID || parsed.ack.eventId != S3I_EVENT_ID) { invalid++; continue }
        let ack = parsed.ack
        if (ack.phase == "admission") {
            if (decoded.frame.frameType != "response" || decoded.frame.correlationId != ack.attemptToken) { invalid++; continue }
        } else if (ack.phase == "completion") {
            let framePrefix = "event-confirm-"
            let correlationPrefix = "event-confirm-service-plugin:gitcode-monitor:"
            if (decoded.frame.frameType != "request" || !decoded.frame.frameId.startsWith(framePrefix) ||
                !decoded.frame.correlationId.startsWith(correlationPrefix)) { invalid++; continue }
            let frameSuffix = decoded.frame.frameId.removePrefix(framePrefix)
            let frameParts = frameSuffix.split("-")
            let correlationParts = decoded.frame.correlationId.removePrefix(correlationPrefix).split("-")
            var completionIdentityValid = frameParts.size == 2 && correlationParts.size >= 3 && !correlationParts[0].isEmpty()
            if (completionIdentityValid) {
                try {
                    let generation = Int64.parse(frameParts[0])
                    let sequence = Int64.parse(frameParts[1])
                    completionIdentityValid = generation > 0 && sequence > 0 && generation.toString() == frameParts[0] &&
                        sequence.toString() == frameParts[1] && correlationParts[correlationParts.size - 2] == frameParts[0] &&
                        correlationParts[correlationParts.size - 1] == frameParts[1]
                } catch (_: Exception) { completionIdentityValid = false }
            }
            if (!completionIdentityValid) { invalid++; continue }
        } else { invalid++; continue }
        if (ack.attemptToken == S3I_TOKEN_A && ack.phase == "admission" && ack.status == "accepted") { acceptedA++
        } else if (ack.attemptToken == S3I_TOKEN_A && ack.phase == "admission" && ack.status == "retry") { retryA++
        } else if (ack.attemptToken == S3I_TOKEN_A && ack.phase == "completion" && ack.status == "completed") { completionA++
        } else if (ack.attemptToken == S3I_TOKEN_B && ack.phase == "admission" && ack.status == "accepted") { acceptedB++
        } else if (ack.attemptToken == S3I_TOKEN_B && ack.phase == "completion" && ack.status == "completed") { completionB++
        } else { invalid++ }
    }
    S3IAckTruth(acceptedA, retryA, completionA, acceptedB, completionB, invalid)
}

private func s3IPhaseTruth(path: Path): S3IPhaseTruth {
    let read = s3IBoundedMarkerRead(path)
    if (read[1]) { return S3IPhaseTruth(0, 0, 0, 0, 0, 0, 1) }
    var initWritten: Int64 = 0; var signalSeen: Int64 = 0
    var eventWriteBefore: Int64 = 0; var eventWriteAfter: Int64 = 0
    var aborted: Int64 = 0; var signalTimeout: Int64 = 0; var invalid: Int64 = 0
    for (line in read[0].split("\n")) {
        match (line.trimAscii()) {
            case "init_written" => initWritten++
            case "signal_seen" => signalSeen++
            case "event_write_before" => eventWriteBefore++
            case "event_write_after" => eventWriteAfter++
            case "aborted" => aborted++
            case "signal_timeout" => signalTimeout++
            case "" => ()
            case _ => invalid++
        }
    }
    if (initWritten > 1 || signalSeen > 1 || eventWriteBefore > 1 || eventWriteAfter > 1 ||
        aborted > 1 || signalTimeout > 1) { invalid++ }
    S3IPhaseTruth(initWritten, signalSeen, eventWriteBefore, eventWriteAfter, aborted, signalTimeout, invalid)
}

private func s3IAcceptedAckTimeoutDiagnostic(home: Path): String {
    let phase = s3IPhaseTruth(home.join("phase.marker"))
    let snapshot = getServicePluginSnapshot("gitcode-monitor")
    let status = match (snapshot) { case Some(value) => value.status case None => "missing" }
    let pidPositive = match (snapshot) { case Some(value) => value.pid > 0 case None => false }
    let active = match (snapshot) { case Some(value) => value.dispatch.active case None => -1 }
    let queued = match (snapshot) { case Some(value) => value.dispatch.queued case None => -1 }
    let accepted = match (snapshot) { case Some(value) => value.dispatch.admissionAccepted case None => -1 }
    let retried = match (snapshot) { case Some(value) => value.dispatch.admissionRetried case None => -1 }
    let completion = match (snapshot) { case Some(value) => value.dispatch.completionAck case None => -1 }
    let fenced = match (snapshot) { case Some(value) => value.dispatch.fenced case None => true }
    let retained = match (snapshot) { case Some(value) => value.retainedEventFrames case None => -1 }
    let errorKind = match (snapshot) {
        case Some(value) =>
            if (value.lastError.isEmpty()) { "none"
            } else if (value.lastError == "invalid_event_ack_identity") { "invalid_event_ack_identity"
            } else { "other_redacted" }
        case None => "none"
    }
    let classification = if (phase.invalid > 0 || phase.initWritten != 1) { "phase_invalid"
        } else if (phase.signalSeen != 1) { "signal_missing"
        } else if (phase.eventWriteBefore == 1 && phase.eventWriteAfter == 0) { "stdout_write_incomplete"
        } else if (phase.eventWriteAfter == 1 && accepted > 0) { "ack_write_or_child_marker"
        } else if (phase.eventWriteAfter == 1 && errorKind != "none") { "frame_or_route_${errorKind}"
        } else if (phase.eventWriteAfter == 1 && accepted == 0) { "pump_not_consumed"
        } else { "unclassified" }
    "s3_i_accepted_ack_timeout_${classification}_status_${status}_pid_${pidPositive}_active_${active}_queued_${queued}_accepted_${accepted}_retried_${retried}_completion_${completion}_fenced_${fenced}_retained_${retained}_phase_${phase.initWritten}_${phase.signalSeen}_${phase.eventWriteBefore}_${phase.eventWriteAfter}_${phase.aborted}_${phase.signalTimeout}_${phase.invalid}"
}

private func s3IWaitAck(path: Path, probe: (S3IAckTruth) -> Bool, timeoutMs!: Int64 = 5000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        if (probe(s3IAckTruth(path))) { return true }
        sleep(Duration.millisecond * 10)
    }
    probe(s3IAckTruth(path))
}

private func s3IRequire(ok: Bool, code: String): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception(code) }
}

private func s3IWritebackCount(path: Path): (Int64, Int64) {
    if (!exists(path)) { return (0, 0) }
    let read = s3IBoundedMarkerRead(path)
    if (read[1]) { return (0, 1) }
    let raw = read[0]
    var count = 0; var invalid = 0
    for (line in raw.split("\n")) {
        if (line.trimAscii().isEmpty()) { continue }
        let decoded = decodeServiceFrame(line)
        let payload = try { Some(JsonValue.fromStr(decoded.frame.payload).asObject()) } catch (_: Exception) { None<JsonObject> }
        var exactPayload = false
        match (payload) {
            case Some(root) =>
                exactPayload = try { root.size() == 11 &&
                    root.get("contractVersion").getOrThrow().asString().getValue() == GITCODE_REVIEW_CONTRACT_VERSION &&
                    root.get("eventId").getOrThrow().asString().getValue() == S3I_EVENT_ID &&
                    root.get("repo").getOrThrow().asString().getValue() == "Cangjie/community" &&
                    root.get("kind").getOrThrow().asString().getValue() == "issue" &&
                    root.get("number").getOrThrow().asString().getValue() == "3" &&
                    root.get("commentId").getOrThrow().asString().getValue().isEmpty() &&
                    root.get("url").getOrThrow().asString().getValue() == "https://gitcode.com/Cangjie/community/issues/3" &&
                    root.get("draft").getOrThrow().asString().getValue() == S3I_SERVICE_DRAFT &&
                    root.get("summary").getOrThrow().asString().getValue().isEmpty() &&
                    root.get("safety").getOrThrow().asString().getValue() == "approved" &&
                    !root.get("needsHumanReview").getOrThrow().asBool().getValue()
                } catch (_: Exception) { false }
            case None => ()
        }
        let framePrefix = "invoke-"
        let correlationPrefix = "corr-service-plugin:gitcode-monitor:"
        var exactFrame = decoded.frame.frameId.startsWith(framePrefix) &&
            decoded.frame.correlationId.startsWith(correlationPrefix)
        if (exactFrame) {
            let frameParts = decoded.frame.frameId.removePrefix(framePrefix).split("-")
            let correlationParts = decoded.frame.correlationId.removePrefix(correlationPrefix).split("-")
            exactFrame = frameParts.size == 2 && correlationParts.size >= 4 && !correlationParts[0].isEmpty() &&
                correlationParts[correlationParts.size - 3] == frameParts[0] &&
                correlationParts[correlationParts.size - 2] == frameParts[1] &&
                correlationParts[correlationParts.size - 1] == "gitcode.writeback.apply_result"
            if (exactFrame) {
                try {
                    let generation = Int64.parse(frameParts[0])
                    let sequence = Int64.parse(frameParts[1])
                    exactFrame = generation > 0 && sequence > 0 && generation.toString() == frameParts[0] &&
                        sequence.toString() == frameParts[1]
                } catch (_: Exception) { exactFrame = false }
            }
        }
        if (!decoded.ok || decoded.frame.frameType != "request" || decoded.frame.serviceId != "gitcode-monitor" ||
            decoded.frame.method != "invokeCapability" || decoded.frame.capabilityId != "gitcode.writeback.apply_result" ||
            !exactFrame || !exactPayload) { invalid++ } else { count++ }
    }
    (count, invalid)
}

private func s3IWritebackPayload(contractVersion: String, includeContractVersion!: Bool = true): String {
    let root = JsonObject()
    if (includeContractVersion) { root.put("contractVersion", JsonString(contractVersion)) }
    root.put("eventId", JsonString(S3I_EVENT_ID))
    root.put("repo", JsonString("Cangjie/community"))
    root.put("kind", JsonString("issue"))
    root.put("number", JsonString("3"))
    root.put("commentId", JsonString(""))
    root.put("url", JsonString("https://gitcode.com/Cangjie/community/issues/3"))
    root.put("draft", JsonString(S3I_SERVICE_DRAFT))
    root.put("summary", JsonString(""))
    root.put("safety", JsonString("approved"))
    root.put("needsHumanReview", JsonBool(false))
    root.toJsonString()
}

private func s3IWritebackFrame(frameId: String, correlationId: String, payload: String): String {
    encodeServiceFrame(ServiceFrame(
        "request",
        frameId,
        "gitcode-monitor",
        method: "invokeCapability",
        capabilityId: "gitcode.writeback.apply_result",
        correlationId: correlationId,
        payload: payload
    ))
}

private func s3IExpectedDelivery(): String {
    "GitCode 回复草稿\n" +
        "来源: Cangjie/community Issue #3 https://gitcode.com/Cangjie/community/issues/3\n" +
        "标题: bounded test\n" +
        "状态: GitCode 回复已写回\n" +
        "写回链接: https://gitcode.com/Cangjie/community/issues/3#s3-i\n\n" +
        "草稿:\n${S3I_SERVICE_DRAFT}"
}

private func s3IEventLine(token: String, frame: String): String {
    "{\"type\":\"event\",\"frameId\":\"${frame}\",\"serviceId\":\"gitcode-monitor\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"gitcode.event.accepted\",\"correlationId\":\"${token}\",\"payload\":{\"jobId\":\"webhook-${S3I_EVENT_ID}\",\"eventId\":\"${S3I_EVENT_ID}\",\"deliveryId\":\"${S3I_DELIVERY_ID}\",\"attemptToken\":\"${token}\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"3\",\"title\":\"bounded test\",\"url\":\"https://gitcode.com/Cangjie/community/issues/3\",\"author\":\"external-user\",\"content\":\"please review\"}}"
}

private func s3IAcceptedEvent(): ServicePluginAcceptedGitCodeEvent {
    ServicePluginAcceptedGitCodeEvent(
        jobId: "webhook-${S3I_EVENT_ID}", eventId: S3I_EVENT_ID, repo: "Cangjie/community", kind: "issue",
        number: "3", title: "bounded test", url: "https://gitcode.com/Cangjie/community/issues/3",
        author: "external-user", content: "please review"
    )
}

private func s3IPluginScript(): String {
    let initFrame = "{\"type\":\"response\",\"frameId\":\"init-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ready\"}}"
    let eventA = s3IEventLine(S3I_TOKEN_A, "s3-i-a")
    let eventB = s3IEventLine(S3I_TOKEN_B, "s3-i-b")
    let writeback = "{\"type\":\"response\",\"frameId\":\"writeback-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"invokeCapability\",\"capabilityId\":\"gitcode.writeback.apply_result\",\"correlationId\":\"__CORR__\",\"payload\":{\"ok\":true,\"status\":\"posted\",\"posted\":true,\"replyUrl\":\"https://gitcode.com/Cangjie/community/issues/3#s3-i\"}}"
    "printf '%s\\n' '${initFrame}'; printf '%s\\n' init_written >> \"$METIS_S3_I_PHASE_MARKER\"; n=0; while [ ! -f \"$METIS_S3_I_EMIT_SIGNAL\" ] && [ ! -f \"$METIS_S3_I_RELEASE_SIGNAL\" ] && [ $n -lt 500 ]; do sleep 0.01; n=$((n+1)); done; " +
        "if [ -f \"$METIS_S3_I_EMIT_SIGNAL\" ]; then printf '%s\\n' signal_seen >> \"$METIS_S3_I_PHASE_MARKER\"; printf '%s\\n' event_write_before >> \"$METIS_S3_I_PHASE_MARKER\"; printf '%s\\n' '${eventA}'; printf '%s\\n' event_write_after >> \"$METIS_S3_I_PHASE_MARKER\"; elif [ -f \"$METIS_S3_I_RELEASE_SIGNAL\" ]; then printf '%s\\n' aborted >> \"$METIS_S3_I_PHASE_MARKER\"; else printf '%s\\n' signal_timeout >> \"$METIS_S3_I_PHASE_MARKER\"; fi; armed=0; " +
        "while IFS= read -r request; do " +
        "case \"$request\" in *emitCapabilityEvent*) printf '%s\\n' \"$request\" >> \"$METIS_S3_I_ACK_MARKER\"; " +
        "if printf '%s\\n' \"$request\" | grep -Eq '\"phase\"[[:space:]]*:[[:space:]]*\"admission\"' && printf '%s\\n' \"$request\" | grep -Eq '\"status\"[[:space:]]*:[[:space:]]*\"retry\"' && printf '%s\\n' \"$request\" | grep -Eq '\"attemptToken\"[[:space:]]*:[[:space:]]*\"${S3I_TOKEN_A}\"'; then armed=1; fi; " +
        "if [ \"$armed\" = 1 ]; then n=0; while [ ! -f \"$METIS_S3_I_RELEASE_SIGNAL\" ] && [ $n -lt 100 ]; do sleep 0.01; n=$((n+1)); done; if [ -f \"$METIS_S3_I_RELEASE_SIGNAL\" ]; then printf '%s\\n' '${eventB}'; armed=2; fi; fi; " +
        "if printf '%s\\n' \"$request\" | grep -Eq '\"phase\"[[:space:]]*:[[:space:]]*\"completion\"'; then corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '{\"type\":\"response\",\"frameId\":\"completion-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"emitCapabilityEvent\",\"capabilityId\":\"gitcode.event.accepted\",\"correlationId\":\"%s\",\"payload\":{\"ok\":true,\"status\":\"host_completed\",\"protocolVersion\":\"1.0\",\"deliveryId\":\"${S3I_DELIVERY_ID}\",\"eventId\":\"${S3I_EVENT_ID}\",\"attemptToken\":\"${S3I_TOKEN_B}\"}}\\n' \"$corr\"; fi;; " +
        "*gitcode.writeback.apply_result*) printf '%s\\n' \"$request\" >> \"$METIS_S3_I_WRITEBACK_MARKER\"; corr=$(printf '%s\\n' \"$request\" | sed -n 's/.*\"correlationId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'); printf '%s\\n' '${writeback}' | sed \"s/__CORR__/$corr/\";; " +
        "*) if printf '%s\\n' \"$request\" | grep -Eq '\"method\"[[:space:]]*:[[:space:]]*\"stop\"'; then break; fi;; esac; done"
}

private func s3IManifest(script: String): ServicePluginManifest {
    let caps = ArrayList<ServiceCapabilityRecord>()
    caps.add(ServiceCapabilityRecord("gitcode.event.accepted", "event"))
    caps.add(ServiceCapabilityRecord("gitcode.writeback.apply_result", "controlAction"))
    ServicePluginManifest(schema: METIS_SERVICE_PLUGIN_SCHEMA, pluginId: "gitcode-monitor", displayName: "GitCode Monitor",
        kind: "service", protocolVersion: "1.0", entryCommand: "/bin/zsh", entryArgs: ["-lc", script],
        hasConfigSchema: true, capabilityDeclarations: caps)
}

private func s3IService(adapter: S3IAdapter): GatewayService {
    let service = GatewayService(GatewayRouter(HashMap<String, ChannelPolicyConfig>()))
    service.registerAdapter(adapter, channelId: "telegram", accountId: "default")
    service
}

private func s3IInstallSubscription(): Unit {
    let path = CliConfig.dotDir.join("service-plugin").join("gitcode").join("subscriptions.jsonl")
    let store = GitCodeSubscriptionStore(path.toString())
    let result = store.createOrUpdate(GitCodeSubscriptionTarget("telegram", "default", "s3-i-peer"),
        scope: GitCodeSubscriptionScope(rawEvents: false, generatedReplies: true))
    s3IRequire(result.ok, "s3_i_subscription_save_failed")
}

private func s3IStartRoutes(service: GatewayService, storePath: Path, barrier: S3IBarrier): (Future<GatewayResolvedSessionTurnResult>, Future<JsonObject>) {
    let request = GatewaySessionRequest(GatewayIngressSource.DashboardRpc,
        sessionHint: "s3-i-ordinary", agentId: "general", text: S3I_ORDINARY_PROMPT)
    let job = CronJob("s3-i-cron", S3I_CRON_PROMPT, CronSchedule.every(60000),
        state: CronJobState(nextRunAtMs: 1), sessionTarget: "main", agentId: "general")
    let cronRequest = cronBuildSessionRequestWithPrompt(job, 1, S3I_CRON_PROMPT)
    let servicePlan = service.debugBuildGitCodePromptPlanForTest(s3IAcceptedEvent())
    @Expect(servicePlan.expectsJsonOutput, false)
    s3IRequire(!servicePlan.expectsJsonOutput, "s3_i_service_prompt_mode_mismatch")
    barrier.configure(
        gatewayResolveSessionContextWithAgentRoute(request).sessionKey,
        gatewayResolveSessionContextWithAgentRoute(cronRequest).sessionKey,
        servicePrompt: servicePlan.prompt
    )
    cronSave(storePath, [job])
    let ordinary = spawn {
        gatewayExecuteSessionRequestTurnForUser(GatewayUserSettings(), request, S3I_ORDINARY_PROMPT)
    }
    let cron = spawn { CronRunner.runJobOnceFromStore(Some(service), storePath, job.id, true) }
    (ordinary, cron)
}

private func s3IJoin<T>(future: Future<T>, timeoutMs!: Int64 = 5000): Bool {
    try { let _ = future.get(Duration.millisecond * timeoutMs); true } catch (_: Exception) { false }
}

private func s3IEnsurePluginRunning(): Unit {
    let started = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
    @Expect(started.ok, true); @Expect(started.status, "running")
    s3IRequire(started.ok && started.status == "running", "s3_i_plugin_start_failed")
    match (getServicePluginSnapshot("gitcode-monitor")) {
        case Some(snapshot) =>
            @Expect(snapshot.status, "running"); @Expect(snapshot.pid > 0, true)
            @Expect(snapshot.dispatch.fenced, false)
            s3IRequire(snapshot.status == "running" && snapshot.pid > 0 && !snapshot.dispatch.fenced,
                "s3_i_plugin_dispatch_not_ready")
        case None => throw Exception("s3_i_plugin_snapshot_missing")
    }
}

private func s3IEmitFirstEvent(home: Path): Unit {
    let admission = gatewayModelMemoryAdmissionSnapshotForTest()
    @Expect(admission.active, 2)
    s3IRequire(admission.active == 2, "s3_i_emit_before_routes_held")
    match (getServicePluginSnapshot("gitcode-monitor")) {
        case Some(snapshot) =>
            @Expect(snapshot.status, "running"); @Expect(snapshot.pid > 0, true)
            @Expect(snapshot.dispatch.fenced, false)
            s3IRequire(snapshot.status == "running" && snapshot.pid > 0 && !snapshot.dispatch.fenced,
                "s3_i_emit_before_plugin_ready")
        case None => throw Exception("s3_i_emit_plugin_snapshot_missing")
    }
    File.writeTo(home.join("emit.signal"), "emit".toArray())
}

private func s3IReleasePluginWaits(home: Path): Unit {
    try { File.writeTo(home.join("release.signal"), "release".toArray()) } catch (_: Exception) { () }
}

private func s3IClearGlobals(): Unit {
    setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
    setServicePluginEventDelivery(None<(ServicePluginDeliveryTarget, String) -> ServicePluginEventDeliveryResult>)
    setServicePluginGeneratedReplyHandler(None<(ServicePluginPendingJob, ServicePluginAcceptedGitCodeEvent) -> ServicePluginGeneratedReplyResult>)
    setServicePluginWebhookGeneratedReplyHandler(None<(ServicePluginAcceptedGitCodeEvent, ServicePluginDeliveryTarget) -> ServicePluginGeneratedReplyResult>)
    setServicePluginWebhookSubscribersProvider(None<(ServicePluginAcceptedGitCodeEvent) -> ArrayList<ServicePluginDeliveryTarget>>)
    setGitCodeSubscriptionStore(None<GitCodeSubscriptionStore>)
}

private func s3IStopResources(service: GatewayService, adapter: S3IAdapter, label: String): Unit {
    var pluginStopped = false
    try { pluginStopped = stopServicePlugin("gitcode-monitor", reason: label, timeoutMillis: 3000).ok } catch (_: Exception) { () }
    @Expect(pluginStopped, true)
    var serviceStopped = false
    try { serviceStopped = service.stop().ok } catch (_: Exception) { () }
    @Expect(serviceStopped, true)
    @Expect(adapter.isRunning(), false)
    match (getServicePluginSnapshot("gitcode-monitor")) {
        case Some(snapshot) => @Expect(snapshot.pid, 0)
        case None => ()
    }
    let broker = managedStdioBroker().snapshot()
    @Expect(broker.running, false); @Expect(broker.brokerPid, 0); @Expect(broker.ownerCount, 0)
    @Expect(broker.readerCount, 0); @Expect(broker.dispatcherCount, 0)
}

private func s3IWithHome<T>(label: String, body: (Path, Path, Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/private/tmp/metis-s3-i-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let ack = home.join("ack.marker"); let writeback = home.join("writeback.marker")
        let oldHome = getVariable("METIS_HOME"); let oldAck = getVariable("METIS_S3_I_ACK_MARKER")
        let oldWriteback = getVariable("METIS_S3_I_WRITEBACK_MARKER"); let oldSignal = getVariable("METIS_S3_I_RELEASE_SIGNAL")
        let oldEmit = getVariable("METIS_S3_I_EMIT_SIGNAL"); let oldPhase = getVariable("METIS_S3_I_PHASE_MARKER")
        let oldLog = Config.logFile
        let approvedParent = try {
            let parent = FileInfo(home.parent)
            parent.isDirectory() && !parent.isSymbolicLink() && canonicalize(home.parent).toString() == "/private/tmp" &&
                home.parent.normalize().toString() == "/private/tmp"
        } catch (_: Exception) { false }
        s3IRequire(approvedParent, "s3_i_home_parent_not_owned")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home.toString()); setVariable("METIS_S3_I_ACK_MARKER", ack.toString())
        setVariable("METIS_S3_I_WRITEBACK_MARKER", writeback.toString()); setVariable("METIS_S3_I_RELEASE_SIGNAL", home.join("release.signal").toString())
        setVariable("METIS_S3_I_EMIT_SIGNAL", home.join("emit.signal").toString())
        setVariable("METIS_S3_I_PHASE_MARKER", home.join("phase.marker").toString())
        CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
        s3IClearGlobals(); resetServicePluginGeneratedReplyStateForTest(); resetServicePluginHostForTest(); resetGatewayModelMemoryAdmissionForTest()
        setGatewayModelMemoryAdmissionSnapshotProviderForTest(Some({=> GatewayRuntimeHeapSnapshot(2 * S3I_GIB, S3I_GIB, S3I_GIB, 50, "ok", 1, "ok") }))
        try { return body(home, ack, writeback) } finally {
            s3IClearGlobals(); resetServicePluginGeneratedReplyStateForTest(); resetServicePluginHostForTest()
            resetGatewayModelMemoryAdmissionForTest()
            let reset = resetManagedStdioBrokerForTest()
            @Expect(reset.ok, true)
            s3IRestoreEnv("METIS_HOME", oldHome); s3IRestoreEnv("METIS_S3_I_ACK_MARKER", oldAck)
            s3IRestoreEnv("METIS_S3_I_WRITEBACK_MARKER", oldWriteback); s3IRestoreEnv("METIS_S3_I_RELEASE_SIGNAL", oldSignal)
            s3IRestoreEnv("METIS_S3_I_EMIT_SIGNAL", oldEmit)
            s3IRestoreEnv("METIS_S3_I_PHASE_MARKER", oldPhase)
            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
            gatewayLoggingResetForTest(); Config.logFile = oldLog; @Expect(Config.logFile, oldLog)
            let broker = managedStdioBroker().snapshot()
            @Expect(broker.running, false); @Expect(broker.brokerPid, 0); @Expect(broker.ownerCount, 0)
            @Expect(broker.readerCount, 0); @Expect(broker.dispatcherCount, 0)
            try { remove(home, recursive: true) } catch (_: Exception) { () }
            @Expect(exists(home), false)
            setGatewayModelMemoryAdmissionSnapshotProviderForTest(Some({=> GatewayRuntimeHeapSnapshot(2 * S3I_GIB, S3I_GIB, S3I_GIB, 50, "ok", 1, "ok") }))
        }
    }
}

@Test
public class GatewayModelMemoryAdmissionE2eTest {
    @TestCase
    public func s3IU1BarrierAndWireFixtureAreIdentityBoundOneShotAndFailureIsolated(): Unit {
        let barrier = S3IBarrier()
        barrier.configure("ordinary-key", "cron-key", servicePrompt: "service-prompt")
        let initial = barrier.truth()
        @Expect(initial[0], 0); @Expect(initial[1], 0); @Expect(initial[2], 0)
        let _ = barrier.run("wrong-key", S3I_ORDINARY_PROMPT)
        let afterWrongKey = barrier.truth()
        @Expect(afterWrongKey[0], 0); @Expect(afterWrongKey[1], 0); @Expect(afterWrongKey[2], 0)
        barrier.release()
        let _ = barrier.run("ordinary-key", S3I_ORDINARY_PROMPT)
        let afterOrdinary = barrier.truth()
        @Expect(afterOrdinary[0], 1); @Expect(afterOrdinary[1], 0); @Expect(afterOrdinary[2], 0)
        var duplicateFailed = false
        try { let _ = barrier.run("ordinary-key", S3I_ORDINARY_PROMPT) } catch (_: Exception) { duplicateFailed = true }
        @Expect(duplicateFailed, true)
        barrier.failOnce()
        var failed = false
        let _ = barrier.run("agent:main:explicit:service-plugin/gitcode/webhook/${S3I_EVENT_ID.toAsciiLower()}", "wrong-service-prompt")
        let afterWrongPrompt = barrier.truth()
        @Expect(afterWrongPrompt[0], 1); @Expect(afterWrongPrompt[1], 0); @Expect(afterWrongPrompt[2], 0)
        try { let _ = barrier.run("agent:main:explicit:service-plugin/gitcode/webhook/${S3I_EVENT_ID.toAsciiLower()}", "service-prompt") } catch (_: Exception) { failed = true }
        @Expect(failed, true)
        let afterFailure = barrier.truth()
        @Expect(afterFailure[0], 1); @Expect(afterFailure[1], 0); @Expect(afterFailure[2], 1)
        s3IWithHome<Unit>("u1", { home: Path, _ack: Path, _writeback: Path =>
            @Expect(s3IAckTruth(home.join("missing.marker")).invalid, 0)
            let accepted = ServiceEventAck(
                METIS_SERVICE_PLUGIN_PROTOCOL_VERSION,
                S3I_DELIVERY_ID,
                S3I_EVENT_ID,
                S3I_TOKEN_A,
                "admission",
                "accepted"
            )
            let acceptedPayload = encodeServiceEventAckPayload(accepted)
            let responsePath = home.join("response-ack.marker")
            File.writeTo(responsePath, encodeServiceFrame(ServiceFrame(
                "response",
                "event-ack-u1-response",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: S3I_TOKEN_A,
                payload: acceptedPayload
            )).toArray())
            let responseTruth = s3IAckTruth(responsePath)
            @Expect(responseTruth.acceptedA, 1); @Expect(responseTruth.invalid, 0)
            let requestPath = home.join("request-ack.marker")
            File.writeTo(requestPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-ack-u1-request",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: S3I_TOKEN_A,
                payload: acceptedPayload
            )).toArray())
            let requestTruth = s3IAckTruth(requestPath)
            @Expect(requestTruth.acceptedA, 0); @Expect(requestTruth.invalid, 1)
            let completion = ServiceEventAck(
                METIS_SERVICE_PLUGIN_PROTOCOL_VERSION,
                S3I_DELIVERY_ID,
                S3I_EVENT_ID,
                S3I_TOKEN_B,
                "completion",
                "completed"
            )
            let completionPayload = encodeServiceEventAckPayload(completion)
            let completionRequestPath = home.join("completion-request-ack.marker")
            File.writeTo(completionRequestPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-7-9",
                payload: completionPayload
            )).toArray())
            let completionRequestTruth = s3IAckTruth(completionRequestPath)
            @Expect(completionRequestTruth.completionB, 1); @Expect(completionRequestTruth.invalid, 0)
            let completionResponsePath = home.join("completion-response-ack.marker")
            File.writeTo(completionResponsePath, encodeServiceFrame(ServiceFrame(
                "response",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-7-9",
                payload: completionPayload
            )).toArray())
            let completionResponseTruth = s3IAckTruth(completionResponsePath)
            @Expect(completionResponseTruth.completionB, 0); @Expect(completionResponseTruth.invalid, 1)
            let completionTokenCorrelationPath = home.join("completion-token-correlation-ack.marker")
            File.writeTo(completionTokenCorrelationPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: S3I_TOKEN_B,
                payload: completionPayload
            )).toArray())
            let completionTokenCorrelationTruth = s3IAckTruth(completionTokenCorrelationPath)
            @Expect(completionTokenCorrelationTruth.completionB, 0); @Expect(completionTokenCorrelationTruth.invalid, 1)
            let completionAmbiguousSuffixPath = home.join("completion-ambiguous-suffix-ack.marker")
            File.writeTo(completionAmbiguousSuffixPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-17-9",
                payload: completionPayload
            )).toArray())
            let completionAmbiguousSuffixTruth = s3IAckTruth(completionAmbiguousSuffixPath)
            @Expect(completionAmbiguousSuffixTruth.completionB, 0); @Expect(completionAmbiguousSuffixTruth.invalid, 1)
            let completionSequenceMismatchPath = home.join("completion-sequence-mismatch-ack.marker")
            File.writeTo(completionSequenceMismatchPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-7-19",
                payload: completionPayload
            )).toArray())
            let completionSequenceMismatchTruth = s3IAckTruth(completionSequenceMismatchPath)
            @Expect(completionSequenceMismatchTruth.completionB, 0); @Expect(completionSequenceMismatchTruth.invalid, 1)
            let completionEmptyOwnerPath = home.join("completion-empty-owner-ack.marker")
            File.writeTo(completionEmptyOwnerPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-7-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:-7-9",
                payload: completionPayload
            )).toArray())
            let completionEmptyOwnerTruth = s3IAckTruth(completionEmptyOwnerPath)
            @Expect(completionEmptyOwnerTruth.completionB, 0); @Expect(completionEmptyOwnerTruth.invalid, 1)
            let completionNonNumericPath = home.join("completion-nonnumeric-ack.marker")
            File.writeTo(completionNonNumericPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-seven-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-seven-9",
                payload: completionPayload
            )).toArray())
            let completionNonNumericTruth = s3IAckTruth(completionNonNumericPath)
            @Expect(completionNonNumericTruth.completionB, 0); @Expect(completionNonNumericTruth.invalid, 1)
            let completionLeadingZeroPath = home.join("completion-leading-zero-ack.marker")
            File.writeTo(completionLeadingZeroPath, encodeServiceFrame(ServiceFrame(
                "request",
                "event-confirm-07-9",
                "gitcode-monitor",
                method: "emitCapabilityEvent",
                capabilityId: "gitcode.event.accepted",
                correlationId: "event-confirm-service-plugin:gitcode-monitor:u1-07-9",
                payload: completionPayload
            )).toArray())
            let completionLeadingZeroTruth = s3IAckTruth(completionLeadingZeroPath)
            @Expect(completionLeadingZeroTruth.completionB, 0); @Expect(completionLeadingZeroTruth.invalid, 1)
            let writebackPayload = s3IWritebackPayload(GITCODE_REVIEW_CONTRACT_VERSION)
            let writebackPositivePath = home.join("writeback-positive.marker")
            File.writeTo(writebackPositivePath, s3IWritebackFrame(
                "invoke-7-9",
                "corr-service-plugin:gitcode-monitor:u1-7-9-gitcode.writeback.apply_result",
                writebackPayload
            ).toArray())
            let writebackPositive = s3IWritebackCount(writebackPositivePath)
            @Expect(writebackPositive[0], 1); @Expect(writebackPositive[1], 0)
            let writebackGenerationMismatchPath = home.join("writeback-generation-mismatch.marker")
            File.writeTo(writebackGenerationMismatchPath, s3IWritebackFrame(
                "invoke-7-9",
                "corr-service-plugin:gitcode-monitor:u1-17-9-gitcode.writeback.apply_result",
                writebackPayload
            ).toArray())
            let writebackGenerationMismatch = s3IWritebackCount(writebackGenerationMismatchPath)
            @Expect(writebackGenerationMismatch[0], 0); @Expect(writebackGenerationMismatch[1], 1)
            let writebackSequenceMismatchPath = home.join("writeback-sequence-mismatch.marker")
            File.writeTo(writebackSequenceMismatchPath, s3IWritebackFrame(
                "invoke-7-9",
                "corr-service-plugin:gitcode-monitor:u1-7-19-gitcode.writeback.apply_result",
                writebackPayload
            ).toArray())
            let writebackSequenceMismatch = s3IWritebackCount(writebackSequenceMismatchPath)
            @Expect(writebackSequenceMismatch[0], 0); @Expect(writebackSequenceMismatch[1], 1)
            let writebackMissingContractPath = home.join("writeback-missing-contract.marker")
            File.writeTo(writebackMissingContractPath, s3IWritebackFrame(
                "invoke-7-9",
                "corr-service-plugin:gitcode-monitor:u1-7-9-gitcode.writeback.apply_result",
                s3IWritebackPayload(GITCODE_REVIEW_CONTRACT_VERSION, includeContractVersion: false)
            ).toArray())
            let writebackMissingContract = s3IWritebackCount(writebackMissingContractPath)
            @Expect(writebackMissingContract[0], 0); @Expect(writebackMissingContract[1], 1)
            let writebackWrongContractPath = home.join("writeback-wrong-contract.marker")
            File.writeTo(writebackWrongContractPath, s3IWritebackFrame(
                "invoke-7-9",
                "corr-service-plugin:gitcode-monitor:u1-7-9-gitcode.writeback.apply_result",
                s3IWritebackPayload("wrong-contract")
            ).toArray())
            let writebackWrongContract = s3IWritebackCount(writebackWrongContractPath)
            @Expect(writebackWrongContract[0], 0); @Expect(writebackWrongContract[1], 1)
            let shortReader = S3IShortReader()
            let shortRead = s3IBoundedMarkerReadFrom({ buffer: Array<UInt8> => shortReader.read(buffer) })
            @Expect(shortRead[0], "short-read-中文🙂"); @Expect(shortRead[1], false)
            let invalidPath = home.join("invalid.marker")
            File.writeTo(invalidPath, [UInt8(0xff), UInt8(0xfe)])
            @Expect(s3IAckTruth(invalidPath).invalid, 1)
            let oversizePath = home.join("oversize.marker")
            File.writeTo(oversizePath, Array<UInt8>(65537) { _index => UInt8(0x61) })
            @Expect(s3IAckTruth(oversizePath).invalid, 1)
            let targetPath = home.join("symlink-target.marker")
            let symlinkPath = home.join("symlink.marker")
            File.writeTo(targetPath, "must-not-follow".toArray())
            let link = ShellUtils.execute(["ln", "-s", targetPath.toString(), symlinkPath.toString()], withWrap: false)
            s3IRequire(link[0] == 0, "s3_i_symlink_fixture_failed")
            @Expect(s3IAckTruth(symlinkPath).invalid, 1)
        })
    }

    @TestCase
    public func s3IB1OrdinaryAndCronHeldForceServiceRetryBeforeSideEffects(): Unit {
        s3IWithHome<Unit>("b1", { home: Path, ack: Path, writeback: Path =>
            let barrier = S3IBarrier(); let adapter = S3IAdapter(); let service = s3IService(adapter)
            var ordinary: Option<Future<GatewayResolvedSessionTurnResult>> = None; var cron: Option<Future<JsonObject>> = None
            setGatewayAgentBridgeReplyRunnerForTest(Some({ key: String, prompt: String, _channel: String, _agent: String, _stream: Bool, _hook: Option<(String) -> Unit> => barrier.run(key, prompt) }))
            try {
                s3IInstallSubscription(); service.start()
                let registered = registerServicePlugin(ServicePluginRegistration(s3IManifest(s3IPluginScript())))
                s3IRequire(registered.ok, "s3_i_registration_failed")
                s3IEnsurePluginRunning()
                let routes = s3IStartRoutes(service, home.join("cron.json"), barrier); ordinary = Some(routes[0]); cron = Some(routes[1])
                s3IRequire(barrier.awaitHeld(5000), "s3_i_routes_not_held")
                s3IEmitFirstEvent(home)
                if (!s3IWaitAck(ack, { row: S3IAckTruth => row.acceptedA == 1 })) {
                    throw Exception(s3IAcceptedAckTimeoutDiagnostic(home))
                }
                s3IRequire(s3IWaitAck(ack, { row: S3IAckTruth => row.retryA == 1 }), "s3_i_retry_ack_timeout")
                let truth = gatewayModelMemoryAdmissionSnapshotForTest(); let wire = s3IAckTruth(ack)
                @Expect(truth.active, 2); @Expect(truth.maxActiveSeen, 2); @Expect(truth.rejectedServicePlugin, 1)
                @Expect(truth.acceptedOrdinary, 1); @Expect(truth.acceptedCron, 1)
                @Expect(wire.acceptedA, 1); @Expect(wire.retryA, 1); @Expect(wire.completionA, 0); @Expect(wire.invalid, 0)
                @Expect(adapter.count(), 0); @Expect(exists(writeback), false); @Expect(barrier.truth()[2], 0)
            } finally {
                barrier.release()
                s3IReleasePluginWaits(home)
                var ordinaryJoined = true; var cronJoined = true
                match (ordinary) { case Some(value) => ordinaryJoined = s3IJoin(value); ordinary = None case None => () }
                match (cron) { case Some(value) => cronJoined = s3IJoin(value); cron = None case None => () }
                try { s3IStopResources(service, adapter, "s3-i-b1") } finally {
                    setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
                }
                s3IRequire(ordinaryJoined && cronJoined, "s3_i_b1_future_join_failed")
            }
        })
    }

    @TestCase
    public func s3IP1SameDeliveryNewAttemptCompletesExactlyOnceAfterRelease(): Unit {
        s3IWithHome<Unit>("p1", { home: Path, ack: Path, writeback: Path =>
            let barrier = S3IBarrier(); let adapter = S3IAdapter(); let service = s3IService(adapter)
            var ordinary: Option<Future<GatewayResolvedSessionTurnResult>> = None; var cron: Option<Future<JsonObject>> = None
            setGatewayAgentBridgeReplyRunnerForTest(Some({ key: String, prompt: String, _channel: String, _agent: String, _stream: Bool, _hook: Option<(String) -> Unit> => barrier.run(key, prompt) }))
            try {
                s3IInstallSubscription(); service.start()
                s3IRequire(registerServicePlugin(ServicePluginRegistration(s3IManifest(s3IPluginScript()))).ok, "s3_i_registration_failed")
                s3IEnsurePluginRunning()
                let routes = s3IStartRoutes(service, home.join("cron.json"), barrier); ordinary = Some(routes[0]); cron = Some(routes[1])
                s3IRequire(barrier.awaitHeld(5000), "s3_i_routes_not_held")
                s3IEmitFirstEvent(home)
                s3IRequire(s3IWaitAck(ack, { row: S3IAckTruth => row.acceptedA == 1 }), "s3_i_accepted_ack_timeout")
                s3IRequire(s3IWaitAck(ack, { row: S3IAckTruth => row.retryA == 1 }), "s3_i_retry_ack_timeout")
                @Expect(adapter.count(), 0); @Expect(exists(writeback), false)
                barrier.release()
                s3IRequire(s3IJoin(routes[0]), "s3_i_ordinary_join_timeout")
                s3IRequire(s3IJoin(routes[1]), "s3_i_cron_join_timeout")
                ordinary = None; cron = None
                File.writeTo(home.join("release.signal"), "release".toArray())
                s3IRequire(s3IWaitAck(ack, { row: S3IAckTruth => row.completionB == 1 }), "s3_i_completion_ack_timeout")
                let wire = s3IAckTruth(ack); let calls = barrier.truth(); let admission = gatewayModelMemoryAdmissionSnapshotForTest()
                @Expect(wire.acceptedA, 1); @Expect(wire.retryA, 1); @Expect(wire.completionA, 0)
                @Expect(wire.acceptedB, 1); @Expect(wire.completionB, 1); @Expect(wire.invalid, 0)
                @Expect(calls[0], 1); @Expect(calls[1], 1); @Expect(calls[2], 1)
                @Expect(adapter.count(), 1); @Expect(adapter.onlyText(), s3IExpectedDelivery())
                @Expect(adapter.onlyText().contains("Authorization"), false); @Expect(adapter.onlyText().contains("{\""), false)
                @Expect(adapter.onlyText().contains(S3I_PRIVATE_SENTINEL), false)
                let writebackCount = s3IWritebackCount(writeback)
                @Expect(writebackCount[0], 1); @Expect(writebackCount[1], 0)
                @Expect(servicePluginWebhookReceiptStore().state("gitcode-monitor", S3I_DELIVERY_ID, S3I_EVENT_ID), "missing")
                let stats = servicePluginWebhookDispatchStatsSnapshot()
                @Expect(stats.size, 1)
                if (stats.size != 1) { throw Exception("s3_i_stats_count_mismatch") }
                @Expect(stats[0].eventId, S3I_EVENT_ID); @Expect(stats[0].status, "generated_reply_delivered")
                @Expect(stats[0].targetCount, 1); @Expect(stats[0].deliverySuccess, 1); @Expect(stats[0].deliveryFailed, 0)
                @Expect(stats[0].telegram, 1); @Expect(stats[0].feishu, 0); @Expect(stats[0].noSubscriberCount, 0)
                @Expect(stats[0].eventIdHash.size, 64); @Expect(stats[0].diagnosticHash.size, 64)
                @Expect(stats[0].updatedAtMs, 0)
                match (getServicePluginSnapshot("gitcode-monitor")) {
                    case Some(snapshot) => @Expect(snapshot.dispatch.completionAck, 1)
                    case None => @Expect(true, false)
                }
                @Expect(admission.maxActiveSeen, 2); @Expect(admission.active, 0)
                @Expect(admission.acceptedOrdinary, 1); @Expect(admission.acceptedCron, 1)
                @Expect(admission.rejectedServicePlugin, 1); @Expect(admission.acceptedServicePlugin, 1)
            } finally {
                barrier.release()
                s3IReleasePluginWaits(home)
                var ordinaryJoined = true; var cronJoined = true
                match (ordinary) { case Some(value) => ordinaryJoined = s3IJoin(value); ordinary = None case None => () }
                match (cron) { case Some(value) => cronJoined = s3IJoin(value); cron = None case None => () }
                try { s3IStopResources(service, adapter, "s3-i-p1") } finally {
                    setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
                }
                s3IRequire(ordinaryJoined && cronJoined, "s3_i_p1_future_join_failed")
            }
        })
    }

    @TestCase
    public func s3IN1FailurePathsReleasePermitsAndLeaveNoOwnedResources(): Unit {
        s3IWithHome<Unit>("n1", { home: Path, ack: Path, _writeback: Path =>
            let barrier = S3IBarrier()
            barrier.configure("agent:general:explicit:s3-i-n1", "unused-cron")
            barrier.release(); barrier.failOnce()
            setGatewayAgentBridgeReplyRunnerForTest(Some({ key: String, prompt: String, _channel: String, _agent: String, _stream: Bool, _hook: Option<(String) -> Unit> => barrier.run(key, prompt) }))
            var failed = false
            try {
                let _ = gatewayExecuteSessionRequestTurnForUser(GatewayUserSettings(), GatewaySessionRequest(
                    GatewayIngressSource.DashboardRpc, sessionHint: "s3-i-n1", agentId: "general", text: S3I_ORDINARY_PROMPT), S3I_ORDINARY_PROMPT)
            } catch (e: Exception) {
                failed = true
                // This is an internal typed boundary: it must preserve the original failure for its caller.
                @Expect(e.message.contains("private"), true)
                @Expect(e.message.contains("Authorization"), true)
                @Expect(e.message.contains("/Users/private"), true)
                @Expect(e.message.contains("stack"), true)
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }
            @Expect(failed, true)
            setGatewayAgentBridgeReplyRunnerForTest(Some({ _key: String, prompt: String, _channel: String, _agent: String, _stream: Bool, _hook: Option<(String) -> Unit> =>
                if (prompt == S3I_CRON_PROMPT) { throw Exception("s3_i_cron_runner_failure ${S3I_PRIVATE_SENTINEL} private Authorization token /Users/private stack") }
                "{\"name\":\"_answer_\",\"arguments\":{\"result\":\"unexpected\"}}"
            }))
            try {
                let cronJob = CronJob("s3-i-n1-cron", S3I_CRON_PROMPT, CronSchedule.every(60000),
                    state: CronJobState(nextRunAtMs: 1), sessionTarget: "main", agentId: "general", maxRetries: 0)
                let cronPath = home.join("cron.json")
                cronSave(cronPath, [cronJob])
                let cronResult = CronRunner.runJobOnceFromStore(None<GatewayService>, cronPath, cronJob.id, true)
                let cronRendered = cronResult.toJsonString()
                // The public manual result is redacted; the durable internal job state preserves the failure.
                @Expect(cronResult.get("ok").getOrThrow().asBool().getValue(), true)
                @Expect(cronResult.get("ran").getOrThrow().asBool().getValue(), true)
                @Expect(cronResult.get("jobId").getOrThrow().asString().getValue(), cronJob.id)
                @Expect(cronRendered.contains("diagnosticMessage"), false)
                @Expect(cronRendered.contains(S3I_PRIVATE_SENTINEL), false)
                @Expect(cronRendered.contains("private"), false)
                @Expect(cronRendered.contains("Authorization"), false)
                @Expect(cronRendered.contains("token"), false)
                @Expect(cronRendered.contains("/Users/"), false)
                @Expect(cronRendered.contains("stack"), false)
                let persisted = cronLoadOrEmpty(cronPath)
                @Expect(persisted.size, 1)
                s3IRequire(persisted.size == 1, "s3_i_cron_persisted_job_count_mismatch")
                @Expect(persisted[0].state.lastError.contains(S3I_PRIVATE_SENTINEL), true)
                @Expect(persisted[0].state.lastError.contains("Authorization"), true)
                @Expect(persisted[0].state.lastError.contains("/Users/private"), true)
                @Expect(persisted[0].state.lastError.contains("stack"), true)
            } finally {
                setGatewayAgentBridgeReplyRunnerForTest(None<(String, String, String, String, Bool, Option<(String) -> Unit>) -> String>)
            }

            resetServicePluginHostForTest()
            @Expect(registerServicePlugin(ServicePluginRegistration(s3IManifest(
                "printf '%s\\n' '${S3I_PRIVATE_SENTINEL} private Authorization token /Users/private stack' >&2; exit 7"
            ))).ok, true)
            let failedStart = ensureRegisteredServicePluginStarted("gitcode-monitor", startupTimeoutMs: 5000)
            @Expect(failedStart.ok, false)
            @Expect(failedStart.diagnostic.contains(S3I_PRIVATE_SENTINEL), false)
            @Expect(failedStart.diagnostic.contains("private"), false); @Expect(failedStart.diagnostic.contains("token"), false)
            @Expect(failedStart.diagnostic.contains("Authorization"), false); @Expect(failedStart.diagnostic.contains("/Users/"), false)
            @Expect(failedStart.diagnostic.contains("stack"), false)
            let _ = stopServicePlugin("gitcode-monitor", reason: "s3-i-n1", timeoutMillis: 500)
            @Expect(s3IWaitAck(ack, { _row: S3IAckTruth => false }, timeoutMs: 20), false)
            let truth = gatewayModelMemoryAdmissionSnapshotForTest()
            @Expect(truth.active, 0); @Expect(truth.released, 2)
            @Expect(truth.acceptedOrdinary, 1); @Expect(truth.acceptedCron, 1)
            @Expect(truth.acceptedServicePlugin, 0); @Expect(truth.rejectedServicePlugin, 0)
            let broker = managedStdioBroker().snapshot()
            @Expect(broker.running, true); @Expect(broker.ownerCount, 0)
            @Expect(broker.readerCount, 1); @Expect(broker.dispatcherCount, 0)
        })
    }
}
