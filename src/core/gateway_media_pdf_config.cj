package metis.core

import metis.core.config.{CliConfig, GatewayUserSettings, MetisConfigManager, cliRuntimeModelProviderId}
import metis.core.model.{
    ModelCapabilityDecision,
    modelCapabilityDecisionToJson,
    modelVisionSupportIsSupported,
    resolveModelImageCapability,
    resolveModelImageCapabilityFromEntry
}

import magic.jsonable.*
import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

public struct GatewayPdfModelCandidate {
    public GatewayPdfModelCandidate(
        public let modelRef: String,
        public let source: String,
        public let nativePdfSupported: Bool,
        public let imageSupported: Bool,
        public let decision: ModelCapabilityDecision,
        public let entry: JsonObject
    ) {}
}

private func pdfReadArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func pdfReadString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfCandidateRefFromEntry(entry: JsonObject): String {
    let modelRef = pdfReadString(entry, "modelRef")
    if (!modelRef.isEmpty()) {
        return modelRef
    }
    let provider = pdfReadString(entry, "provider")
    let model = pdfReadString(entry, "model")
    if (!provider.isEmpty() && !model.isEmpty()) {
        return "${provider}:${model}"
    }
    model
}

private func pdfProviderId(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.contains(":")) {
        let parts = trimmed.split(":")
        if (parts.size >= 1) {
            return parts[0].trimAscii()
        }
    }
    if (trimmed.contains("/")) {
        let parts = trimmed.split("/")
        if (parts.size >= 1) {
            return parts[0].trimAscii()
        }
    }
    trimmed
}

public func providerSupportsNativePdf(provider: String): Bool {
    let providerId = pdfProviderId(provider)
    let runtime = cliRuntimeModelProviderId(providerId).trimAscii().toAsciiLower()
    let canonical = MetisConfigManager.canonicalModelProviderId(providerId).trimAscii().toAsciiLower()
    runtime == "anthropic" || runtime == "google" || canonical == "anthropic" || canonical == "google"
}

private func pdfAppendDecisionCandidate(
    out: ArrayList<GatewayPdfModelCandidate>,
    seen: ArrayList<String>,
    decision: ModelCapabilityDecision,
    source: String,
    entry: JsonObject
): Unit {
    let normalized = decision.normalizedRef.trimAscii()
    if (normalized.isEmpty() || seen.contains(normalized)) {
        return
    }
    seen.add(normalized)
    out.add(GatewayPdfModelCandidate(
        normalized,
        source,
        providerSupportsNativePdf(decision.provider),
        modelVisionSupportIsSupported(decision.vision),
        decision,
        entry
    ))
}

private func pdfAppendModelRefCandidate(
    out: ArrayList<GatewayPdfModelCandidate>,
    seen: ArrayList<String>,
    modelRef: String,
    source: String
): Unit {
    let normalized = modelRef.trimAscii()
    if (normalized.isEmpty()) {
        return
    }
    pdfAppendDecisionCandidate(out, seen, resolveModelImageCapability(normalized), source, JsonObject())
}

private func pdfAppendImageModelEntryCandidates(
    out: ArrayList<GatewayPdfModelCandidate>,
    seen: ArrayList<String>,
    user: GatewayUserSettings,
    channel: String
): Unit {
    let config = gatewayMediaResolveImageConfig(user, channel: channel)
    let models = pdfReadArray(config, "models")
    for (entryValue in models.getItems()) {
        try {
            let entry = entryValue.asObject()
            if (pdfCandidateRefFromEntry(entry).isEmpty()) {
                continue
            }
            let decision = resolveModelImageCapabilityFromEntry(entry)
            if (modelVisionSupportIsSupported(decision.vision)) {
                pdfAppendDecisionCandidate(out, seen, decision, "gateway.media.image.models", entry)
            }
        } catch (_: Exception) {
            ()
        }
    }
}

public func gatewayPdfMaxBytesMb(): Float64 {
    let configured = CliConfig.pdfMaxBytesMb
    if (configured > 0.0) { configured } else { 10.0 }
}

public func gatewayPdfMaxBytes(): Int64 {
    Int64(gatewayPdfMaxBytesMb() * 1024.0 * 1024.0)
}

public func gatewayPdfMaxPages(): Int64 {
    let configured = CliConfig.pdfMaxPages
    if (configured > 0) { configured } else { 20 }
}

public func gatewayPdfBuildCandidates(
    user: GatewayUserSettings,
    channel!: String = ""
): Array<GatewayPdfModelCandidate> {
    let out = ArrayList<GatewayPdfModelCandidate>()
    let seen = ArrayList<String>()
    let normalizedChannel = channel.trimAscii().toAsciiLower()

    pdfAppendModelRefCandidate(out, seen, CliConfig.pdfModelOrEmpty(), "agents.defaults.pdfModel.primary")
    for (modelRef in CliConfig.pdfFallbackModels) {
        pdfAppendModelRefCandidate(out, seen, modelRef, "agents.defaults.pdfModel.fallbacks")
    }
    pdfAppendImageModelEntryCandidates(out, seen, user, normalizedChannel)
    pdfAppendModelRefCandidate(out, seen, CliConfig.imageModelOrEmpty(), "agents.defaults.imageModel.primary")
    for (modelRef in CliConfig.imageFallbackModels) {
        pdfAppendModelRefCandidate(out, seen, modelRef, "agents.defaults.imageModel.fallbacks")
    }
    pdfAppendModelRefCandidate(
        out,
        seen,
        user.channelModels.get(normalizedChannel) ?? "",
        "gateway.channelModels.${normalizedChannel}"
    )
    pdfAppendModelRefCandidate(out, seen, CliConfig.modelOrEmpty(), "agents.defaults.model.primary")
    for (modelRef in CliConfig.fallbackModels) {
        pdfAppendModelRefCandidate(out, seen, modelRef, "agents.defaults.model.fallbacks")
    }
    out.toArray()
}

public func gatewayPdfCandidateToJson(candidate: GatewayPdfModelCandidate): JsonObject {
    let row = JsonObject()
    row.put("modelRef", JsonString(candidate.modelRef))
    row.put("source", JsonString(candidate.source))
    row.put("nativePdfSupported", JsonBool(candidate.nativePdfSupported))
    row.put("imageSupported", JsonBool(candidate.imageSupported))
    row.put("capability", modelCapabilityDecisionToJson(candidate.decision).toJsonValue())
    row
}

public func gatewayPdfCandidateSummary(user: GatewayUserSettings, channel!: String = ""): JsonArray {
    let out = JsonArray([])
    for (candidate in gatewayPdfBuildCandidates(user, channel: channel)) {
        out.add(gatewayPdfCandidateToJson(candidate))
    }
    out
}
