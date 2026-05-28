package metis.gateway.service_plugin

import std.collection.{ArrayList, HashMap, HashSet}
import std.fs.{File, Path, exists}
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public let METIS_SERVICE_PLUGIN_SCHEMA = "metis.servicePlugin.v1"
public let METIS_SERVICE_PLUGIN_PROTOCOL_VERSION = "1.0"

public class ServiceCapabilityRecord {
    public let capabilityId: String
    public let kind: String
    public let route: String
    public let inputSchema: String
    public let outputSchema: String
    public let requiredHostApis: Array<String>

    public init(
        capabilityId: String,
        kind: String,
        route!: String = "",
        inputSchema!: String = "",
        outputSchema!: String = "",
        requiredHostApis!: Array<String> = []
    ) {
        this.capabilityId = capabilityId.trimAscii()
        this.kind = kind.trimAscii()
        this.route = route.trimAscii()
        this.inputSchema = inputSchema.trimAscii()
        this.outputSchema = outputSchema.trimAscii()
        this.requiredHostApis = requiredHostApis
    }
}

public class ServicePluginManifest {
    public let schema: String
    public let pluginId: String
    public let displayName: String
    public let kind: String
    public let protocolVersion: String
    public let entryCommand: String
    public let entryArgs: Array<String>
    public let hasConfigSchema: Bool
    public let capabilityDeclarations: ArrayList<ServiceCapabilityRecord>

    public init(
        schema!: String = "",
        pluginId!: String = "",
        displayName!: String = "",
        kind!: String = "",
        protocolVersion!: String = "",
        entryCommand!: String = "",
        entryArgs!: Array<String> = [],
        hasConfigSchema!: Bool = false,
        capabilityDeclarations!: ArrayList<ServiceCapabilityRecord> = ArrayList<ServiceCapabilityRecord>()
    ) {
        this.schema = schema.trimAscii()
        this.pluginId = pluginId.trimAscii()
        this.displayName = displayName.trimAscii()
        this.kind = kind.trimAscii()
        this.protocolVersion = protocolVersion.trimAscii()
        this.entryCommand = entryCommand.trimAscii()
        this.entryArgs = entryArgs
        this.hasConfigSchema = hasConfigSchema
        this.capabilityDeclarations = capabilityDeclarations
    }
}

public class ManifestValidationResult {
    public let ok: Bool
    public let status: String
    public let diagnostics: Array<String>

    public init(ok: Bool, status!: String = "accepted", diagnostics!: Array<String> = []) {
        this.ok = ok
        this.status = status
        this.diagnostics = diagnostics
    }
}

public class ServicePluginManifestResult {
    public let ok: Bool
    public let status: String
    public let errorKind: String
    public let diagnostics: Array<String>
    public let manifest: ServicePluginManifest

    public init(
        ok: Bool,
        status!: String = "accepted",
        errorKind!: String = "",
        diagnostics!: Array<String> = [],
        manifest!: ServicePluginManifest = ServicePluginManifest()
    ) {
        this.ok = ok
        this.status = status
        this.errorKind = errorKind
        this.diagnostics = diagnostics
        this.manifest = manifest
    }
}

public func loadServicePluginManifest(path: String): ServicePluginManifestResult {
    let p = Path(path)
    if (!exists(p)) {
        return ServicePluginManifestResult(false, status: "setup-required", errorKind: "manifest_missing", diagnostics: ["manifest file is missing"])
    }
    let raw = try {
        String.fromUtf8(File.readFrom(p))
    } catch (_: Exception) {
        return ServicePluginManifestResult(false, status: "setup-required", errorKind: "manifest_read_error", diagnostics: ["manifest file is not readable UTF-8"])
    }
    parseServicePluginManifest(raw)
}

public func parseServicePluginManifest(raw: String): ServicePluginManifestResult {
    if (raw.trimAscii().isEmpty()) {
        return ServicePluginManifestResult(false, status: "setup-required", errorKind: "manifest_empty", diagnostics: ["manifest is empty"])
    }
    if (servicePayloadContainsSecret(raw)) {
        return ServicePluginManifestResult(false, status: "invalid-manifest", errorKind: "manifest_contains_secret", diagnostics: ["manifest must not contain credentials or local paths"])
    }
    let root = try {
        JsonValue.fromStr(raw).asObject()
    } catch (_: Exception) {
        return ServicePluginManifestResult(false, status: "invalid-manifest", errorKind: "invalid_json", diagnostics: ["manifest is not valid JSON"])
    }
    let manifest = serviceManifestFromJson(root)
    let validation = validateServicePluginManifest(manifest)
    ServicePluginManifestResult(validation.ok, status: validation.status, errorKind: if (validation.ok) { "" } else { "validation_error" }, diagnostics: validation.diagnostics, manifest: manifest)
}

public func validateServicePluginManifest(manifest: ServicePluginManifest): ManifestValidationResult {
    let diagnostics = ArrayList<String>()
    if (manifest.schema != METIS_SERVICE_PLUGIN_SCHEMA) { diagnostics.add("schema must be ${METIS_SERVICE_PLUGIN_SCHEMA}") }
    if (manifest.pluginId.isEmpty()) { diagnostics.add("missing field: pluginId") }
    if (manifest.kind.isEmpty()) {
        diagnostics.add("missing field: kind")
    } else if (manifest.kind != "service") {
        diagnostics.add("kind must be service")
    }
    if (manifest.protocolVersion.isEmpty()) {
        diagnostics.add("missing field: protocolVersion")
    } else if (!manifest.protocolVersion.startsWith("1.")) {
        diagnostics.add("unsupported protocolVersion: ${manifest.protocolVersion}")
    }
    if (manifest.entryCommand.isEmpty()) { diagnostics.add("missing field: entry.command") }
    if (!manifest.hasConfigSchema) { diagnostics.add("missing field: configSchema") }
    if (manifest.capabilityDeclarations.size == 0) { diagnostics.add("missing field: capabilityDeclarations") }
    for (record in manifest.capabilityDeclarations) {
        let cap = validateCapabilityRecord(record)
        if (!cap.ok) {
            for (diagnostic in cap.diagnostics) {
                diagnostics.add("capability ${record.capabilityId}: ${diagnostic}")
            }
        }
    }
    ManifestValidationResult(diagnostics.size == 0, status: if (diagnostics.size == 0) { "accepted" } else { "setup-required" }, diagnostics: diagnostics.toArray())
}

public class CapabilityValidationResult {
    public let ok: Bool
    public let diagnostics: Array<String>

    public init(ok: Bool, diagnostics!: Array<String> = []) {
        this.ok = ok
        this.diagnostics = diagnostics
    }
}

public class CapabilityRegistrationPlan {
    public let accepted: ArrayList<ServiceCapabilityRecord>
    public let conflicts: Array<String>
    public let diagnostics: Array<String>

    public init(accepted: ArrayList<ServiceCapabilityRecord>, conflicts!: Array<String> = [], diagnostics!: Array<String> = []) {
        this.accepted = accepted
        this.conflicts = conflicts
        this.diagnostics = diagnostics
    }
}

public class CapabilityRegistrationResult {
    public let ok: Bool
    public let serviceId: String
    public let accepted: ArrayList<ServiceCapabilityRecord>
    public let conflicts: Array<String>
    public let diagnostics: Array<String>

    public init(ok: Bool, serviceId: String, accepted: ArrayList<ServiceCapabilityRecord>, conflicts!: Array<String> = [], diagnostics!: Array<String> = []) {
        this.ok = ok
        this.serviceId = serviceId
        this.accepted = accepted
        this.conflicts = conflicts
        this.diagnostics = diagnostics
    }
}

public func validateCapabilityRecord(record: ServiceCapabilityRecord): CapabilityValidationResult {
    let diagnostics = ArrayList<String>()
    if (record.capabilityId.isEmpty()) { diagnostics.add("missing capabilityId") }
    if (!record.capabilityId.isEmpty() && record.capabilityId.contains(" ")) { diagnostics.add("capabilityId must not contain spaces") }
    if (record.kind.isEmpty()) {
        diagnostics.add("missing kind")
    } else if (!serviceCapabilityKindSupported(record.kind)) {
        diagnostics.add("unsupported kind: ${record.kind}")
    }
    for (api in record.requiredHostApis) {
        if (!serviceHostApiSupported(api)) {
            diagnostics.add("unsupported host API: ${api}")
        }
    }
    CapabilityValidationResult(diagnostics.size == 0, diagnostics: diagnostics.toArray())
}

public func normalizeCapabilityRecords(records: ArrayList<ServiceCapabilityRecord>): CapabilityRegistrationPlan {
    let accepted = ArrayList<ServiceCapabilityRecord>()
    let seen = HashSet<String>()
    let conflicts = ArrayList<String>()
    let diagnostics = ArrayList<String>()
    for (record in records) {
        let validation = validateCapabilityRecord(record)
        if (!validation.ok) {
            for (diagnostic in validation.diagnostics) { diagnostics.add("${record.capabilityId}:${diagnostic}") }
            continue
        }
        if (seen.contains(record.capabilityId)) {
            conflicts.add(record.capabilityId)
            continue
        }
        seen.add(record.capabilityId)
        accepted.add(record)
    }
    CapabilityRegistrationPlan(accepted, conflicts: conflicts.toArray(), diagnostics: diagnostics.toArray())
}

public func registerServiceCapabilities(serviceId: String, records: ArrayList<ServiceCapabilityRecord>): CapabilityRegistrationResult {
    let normalized = normalizeCapabilityRecords(records)
    let diagnostics = ArrayList<String>()
    for (item in normalized.diagnostics) { diagnostics.add(item) }
    if (serviceId.trimAscii().isEmpty()) { diagnostics.add("missing serviceId") }
    CapabilityRegistrationResult(
        diagnostics.size == 0 && normalized.conflicts.size == 0,
        serviceId.trimAscii(),
        normalized.accepted,
        conflicts: normalized.conflicts,
        diagnostics: diagnostics.toArray()
    )
}

public class ServiceFrame {
    public let frameType: String
    public let frameId: String
    public let serviceId: String
    public let method: String
    public let capabilityId: String
    public let correlationId: String
    public let payload: String

    public init(frameType: String, frameId: String, serviceId: String, method!: String = "", capabilityId!: String = "", correlationId!: String = "", payload!: String = "{}") {
        this.frameType = frameType.trimAscii()
        this.frameId = frameId.trimAscii()
        this.serviceId = serviceId.trimAscii()
        this.method = method.trimAscii()
        this.capabilityId = capabilityId.trimAscii()
        this.correlationId = correlationId.trimAscii()
        this.payload = payload
    }
}

public class ServiceFrameDecodeResult {
    public let ok: Bool
    public let frame: ServiceFrame
    public let errorKind: String
    public let diagnostic: String

    public init(ok: Bool, frame!: ServiceFrame = ServiceFrame("", "", ""), errorKind!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.frame = frame
        this.errorKind = errorKind
        this.diagnostic = diagnostic
    }
}

public func encodeServiceFrame(frame: ServiceFrame): String {
    let root = JsonObject()
    root.put("type", JsonString(frame.frameType))
    root.put("frameId", JsonString(frame.frameId))
    root.put("serviceId", JsonString(frame.serviceId))
    if (!frame.method.isEmpty()) { root.put("method", JsonString(frame.method)) }
    if (!frame.capabilityId.isEmpty()) { root.put("capabilityId", JsonString(frame.capabilityId)) }
    if (!frame.correlationId.isEmpty()) { root.put("correlationId", JsonString(frame.correlationId)) }
    root.put("payload", servicePayloadJson(frame.payload))
    serviceCompactFrameJson(root.toJsonString()) + "\n"
}

public func decodeServiceFrame(line: String, maxBytes!: Int64 = 65536): ServiceFrameDecodeResult {
    let normalized = serviceNormalizeFrameLine(line)
    if (normalized.contains("\n") || normalized.contains("\r")) {
        return ServiceFrameDecodeResult(false, errorKind: "multiline_frame", diagnostic: "service frames must be one line")
    }
    if (normalized.size > maxBytes) {
        return ServiceFrameDecodeResult(false, errorKind: "frame_too_large", diagnostic: "frame exceeds ${maxBytes} bytes")
    }
    let root = try {
        JsonValue.fromStr(normalized).asObject()
    } catch (_: Exception) {
        return ServiceFrameDecodeResult(false, errorKind: "invalid_json", diagnostic: "frame is not valid JSON")
    }
    let frameType = serviceJsonString(root, "type")
    let frameId = serviceJsonString(root, "frameId")
    let serviceId = serviceJsonString(root, "serviceId")
    if (frameType.isEmpty()) { return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: type") }
    if (frameId.isEmpty()) { return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: frameId") }
    if (serviceId.isEmpty()) { return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: serviceId") }
    if (!serviceFrameTypeSupported(frameType)) {
        return ServiceFrameDecodeResult(false, errorKind: "unknown_frame_type", diagnostic: "unknown frame type: ${frameType}")
    }
    let method = serviceJsonString(root, "method")
    if (!method.isEmpty() && !serviceFrameMethodSupported(method)) {
        return ServiceFrameDecodeResult(false, errorKind: "unknown_method", diagnostic: "unknown method: ${method}")
    }
    let capabilityId = serviceJsonString(root, "capabilityId")
    let correlationId = serviceJsonString(root, "correlationId")
    let payload = match (root.get("payload")) {
        case Some(value) => value.toJsonString()
        case None => "{}"
    }
    ServiceFrameDecodeResult(true, frame: ServiceFrame(frameType, frameId, serviceId, method: method, capabilityId: capabilityId, correlationId: correlationId, payload: payload))
}

public class PendingFrameStore {
    private let pending = HashSet<String>()
    public init() {}
    public func add(correlationId: String): Unit {
        if (!correlationId.trimAscii().isEmpty()) { pending.add(correlationId.trimAscii()) }
    }
    public func contains(correlationId: String): Bool { pending.contains(correlationId.trimAscii()) }
    public func remove(correlationId: String): Unit {
        let id = correlationId.trimAscii()
        if (pending.contains(id)) { pending.remove(id) }
    }
}

public class CorrelationResult {
    public let matched: Bool
    public let correlationId: String
    public let errorKind: String

    public init(matched: Bool, correlationId!: String = "", errorKind!: String = "") {
        this.matched = matched
        this.correlationId = correlationId
        this.errorKind = errorKind
    }
}

public func correlateServiceFrame(frame: ServiceFrame, pending: PendingFrameStore): CorrelationResult {
    if (frame.correlationId.isEmpty()) {
        return CorrelationResult(false, errorKind: "correlation_missing")
    }
    if (!pending.contains(frame.correlationId)) {
        return CorrelationResult(false, correlationId: frame.correlationId, errorKind: "correlation_unknown")
    }
    pending.remove(frame.correlationId)
    CorrelationResult(true, correlationId: frame.correlationId)
}

public class RedactionPolicy {
    public let maxPayloadBytes: Int64
    public init(maxPayloadBytes!: Int64 = 4096) {
        this.maxPayloadBytes = maxPayloadBytes
    }
}

public class RedactedPayload {
    public let text: String
    public let rawHash: String
    public let truncated: Bool

    public init(text: String, rawHash: String, truncated!: Bool = false) {
        this.text = text
        this.rawHash = rawHash
        this.truncated = truncated
    }
}

public func redactServicePayload(payload: String, policy!: RedactionPolicy = RedactionPolicy()): RedactedPayload {
    let hash = hashRawPayload(payload)
    var text = if (servicePayloadContainsSecret(payload)) { "[REDACTED]" } else { payload }
    if (serviceContainsLocalPath(payload)) {
        text = "[REDACTED_LOCAL_PATH]"
    }
    let truncated = serviceRuneSize(text) > policy.maxPayloadBytes
    if (truncated) {
        text = serviceTruncateRunes(text, policy.maxPayloadBytes) + "...[TRUNCATED]"
    }
    RedactedPayload(text, hash, truncated: truncated)
}

public class ServiceFrameLimits {
    public let maxFrameBytes: Int64
    public let maxPayloadBytes: Int64
    public let maxFieldBytes: Int64
    public let maxArrayItems: Int64

    public init(maxFrameBytes!: Int64 = 65536, maxPayloadBytes!: Int64 = 16384, maxFieldBytes!: Int64 = 4096, maxArrayItems!: Int64 = 128) {
        this.maxFrameBytes = maxFrameBytes
        this.maxPayloadBytes = maxPayloadBytes
        this.maxFieldBytes = maxFieldBytes
        this.maxArrayItems = maxArrayItems
    }
}

public class ServiceFrameLimitResult {
    public let ok: Bool
    public let rejected: Bool
    public let reason: String
    public let payloadHash: String

    public init(ok: Bool, rejected!: Bool = false, reason!: String = "", payloadHash!: String = "") {
        this.ok = ok
        this.rejected = rejected
        this.reason = reason
        this.payloadHash = payloadHash
    }
}

public func enforceServiceFrameLimits(frame: ServiceFrame, limits!: ServiceFrameLimits = ServiceFrameLimits()): ServiceFrameLimitResult {
    let encoded = encodeServiceFrame(frame)
    if (encoded.size > limits.maxFrameBytes) {
        return ServiceFrameLimitResult(false, rejected: true, reason: "frame_too_large", payloadHash: hashRawPayload(frame.payload))
    }
    if (frame.payload.size > limits.maxPayloadBytes) {
        return ServiceFrameLimitResult(false, rejected: true, reason: "payload_too_large", payloadHash: hashRawPayload(frame.payload))
    }
    for (field in [frame.frameType, frame.frameId, frame.serviceId, frame.method, frame.capabilityId, frame.correlationId]) {
        if (field.size > limits.maxFieldBytes) {
            return ServiceFrameLimitResult(false, rejected: true, reason: "field_too_large", payloadHash: hashRawPayload(frame.payload))
        }
    }
    ServiceFrameLimitResult(true, payloadHash: hashRawPayload(frame.payload))
}

public func hashRawPayload(payload: String): String {
    "payload-${payload.size}-${payload.toRuneArray().size}"
}

private func serviceManifestFromJson(root: JsonObject): ServicePluginManifest {
    let entry = serviceJsonObject(root, "entry")
    let capabilities = ArrayList<ServiceCapabilityRecord>()
    for (item in serviceJsonArray(root, "capabilityDeclarations").getItems()) {
        let obj = try { item.asObject() } catch (_: Exception) { JsonObject() }
        capabilities.add(serviceCapabilityFromJson(obj))
    }
    ServicePluginManifest(
        schema: serviceJsonString(root, "schema"),
        pluginId: serviceJsonString(root, "pluginId"),
        displayName: serviceJsonString(root, "displayName"),
        kind: serviceJsonString(root, "kind"),
        protocolVersion: serviceJsonString(root, "protocolVersion"),
        entryCommand: serviceJsonString(entry, "command"),
        entryArgs: serviceJsonStringArray(entry, "args"),
        hasConfigSchema: root.get("configSchema").isSome(),
        capabilityDeclarations: capabilities
    )
}

private func serviceCapabilityFromJson(obj: JsonObject): ServiceCapabilityRecord {
    ServiceCapabilityRecord(
        serviceJsonString(obj, "capabilityId"),
        serviceJsonString(obj, "kind"),
        route: serviceJsonString(obj, "route"),
        inputSchema: serviceJsonString(obj, "inputSchema"),
        outputSchema: serviceJsonString(obj, "outputSchema"),
        requiredHostApis: serviceJsonStringArray(obj, "requiredHostApis")
    )
}

private func servicePayloadJson(payload: String): JsonValue {
    try { JsonValue.fromStr(payload) } catch (_: Exception) { JsonString(payload) }
}

private func serviceJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func serviceJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func serviceJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func serviceJsonStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    for (item in serviceJsonArray(obj, key).getItems()) {
        let value = try { item.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        if (!value.isEmpty()) { out.add(value) }
    }
    out.toArray()
}

private func serviceCapabilityKindSupported(kind: String): Bool {
    kind == "command" ||
        kind == "controlAction" ||
        kind == "event" ||
        kind == "notificationTopic" ||
        kind == "agentRequest" ||
        kind == "tool" ||
        kind == "resource"
}

private func serviceHostApiSupported(api: String): Bool {
    api == "host.agent.invoke" ||
        api == "host.notification.publish" ||
        api == "host.audit.append" ||
        api == "host.capability.invoke"
}

private func serviceFrameTypeSupported(frameType: String): Bool {
    frameType == "request" ||
        frameType == "response" ||
        frameType == "event" ||
        frameType == "audit" ||
        frameType == "heartbeat"
}

private func serviceFrameMethodSupported(method: String): Bool {
    method == "initialize" ||
        method == "registerCapabilities" ||
        method == "invokeCapability" ||
        method == "emitCapabilityEvent" ||
        method == "requestHostApi" ||
        method == "status" ||
        method == "heartbeat" ||
        method == "audit"
}

private func servicePayloadContainsSecret(text: String): Bool {
    let lower = text.toAsciiLower()
    lower.contains("authorization:") ||
        lower.contains("\"authorization\"") ||
        lower.contains("bearer ") ||
        lower.contains("private-token") ||
        lower.contains("access_token=") ||
        lower.contains("\"token\"") ||
        lower.contains("token=") ||
        lower.contains("cookie:") ||
        lower.contains("\"cookie\"") ||
        lower.contains("cookie=") ||
        lower.contains("password=") ||
        lower.contains("\"password\"") ||
        lower.contains("appsecret") ||
        serviceContainsLocalPath(text)
}

private func serviceContainsLocalPath(text: String): Bool {
    text.contains("/Users/") || text.contains("/home/") || text.contains("C:\\")
}

private func serviceRuneSize(text: String): Int64 {
    text.toRuneArray().size
}

private func serviceTruncateRunes(text: String, maxRunes: Int64): String {
    if (maxRunes <= 0) { return "" }
    let runes = text.toRuneArray()
    if (runes.size <= maxRunes) { return text }
    String(runes[0..maxRunes])
}

private func serviceNormalizeFrameLine(line: String): String {
    if (line.endsWith("\r\n") && line.size >= 2) {
        return line[0..line.size - 2]
    }
    if ((line.endsWith("\n") || line.endsWith("\r")) && line.size >= 1) {
        return line[0..line.size - 1]
    }
    line
}

private func serviceCompactFrameJson(raw: String): String {
    raw.replace("\n", "").replace("\r", "")
}
