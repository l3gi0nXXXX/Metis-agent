package metis.gateway.logging

import metis.core.{GatewayMediaDiagnosticSink, setGatewayMediaDiagnosticSinkForRuntime}

import stdx.encoding.json.JsonObject

private func gatewayMediaDiagnosticString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayMediaDiagnosticGenerationSubsystem(meta: JsonObject): String {
    let capability = gatewayMediaDiagnosticString(meta, "capability").toAsciiLower()
    let mediaKind = gatewayMediaDiagnosticString(meta, "mediaKind").toAsciiLower()
    let generationKind = gatewayMediaDiagnosticString(meta, "generationKind").toAsciiLower()
    let selected = if (!generationKind.isEmpty()) { generationKind } else if (!capability.isEmpty()) { capability } else { mediaKind }
    match (selected) {
        case "image" => "gateway/media/generation/image"
        case "photo" => "gateway/media/generation/image"
        case "sticker" => "gateway/media/generation/image"
        case "video" => "gateway/media/generation/video"
        case "audio" => "gateway/media/generation/audio"
        case "voice" => "gateway/media/generation/audio"
        case "tts" => "gateway/media/generation/audio"
        case _ => "gateway/media"
    }
}

private func gatewayMediaDiagnosticSubsystem(event: String, meta: JsonObject): String {
    let normalized = event.trimAscii()
    if (normalized.startsWith("media.understanding.") || normalized.startsWith("media.preflight.")) {
        return "gateway/media/understanding"
    }
    if (normalized.startsWith("media.generation.")) {
        return gatewayMediaDiagnosticGenerationSubsystem(meta)
    }
    if (normalized.startsWith("media.outbound.")) {
        return "gateway/media/outbound"
    }
    if (normalized.startsWith("media.tool.")) {
        return "gateway/tool/media"
    }
    "gateway/media"
}

private class GatewayMediaDiagnosticLoggingSink <: GatewayMediaDiagnosticSink {
    public func emit(level: String, event: String, message: String, meta: JsonObject): Unit {
        let logger = metisCreateSubsystemLogger(gatewayMediaDiagnosticSubsystem(event, meta))
        match (level.trimAscii().toAsciiLower()) {
            case "trace" => logger.trace(event, message, meta: meta)
            case "debug" => logger.debug(event, message, meta: meta)
            case "warn" => logger.warn(event, message, meta: meta)
            case "error" => logger.error(event, message, meta: meta)
            case "fatal" => logger.fatal(event, message, meta: meta)
            case _ => logger.info(event, message, meta: meta)
        }
    }
}

public func gatewayInstallMediaDiagnosticLoggingSinkForRuntime(): Unit {
    setGatewayMediaDiagnosticSinkForRuntime(Some(GatewayMediaDiagnosticLoggingSink()))
}
