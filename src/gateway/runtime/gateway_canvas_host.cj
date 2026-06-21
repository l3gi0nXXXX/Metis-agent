package metis.gateway.runtime

import magic.jsonable.*

import metis.gateway.model.GatewayConfig

import std.collection.ArrayList
import std.fs.{FileInfo, Path, canonicalize, exists}
import stdx.encoding.json.{JsonObject, JsonString}

public class GatewayCanvasResolveResult {
    public let ok: Bool
    public let status: String
    public let path: String
    public let relativePath: String
    public let mimeType: String

    public init(
        ok: Bool,
        status: String,
        path!: String = "",
        relativePath!: String = "",
        mimeType!: String = ""
    ) {
        this.ok = ok
        this.status = status
        this.path = path
        this.relativePath = relativePath
        this.mimeType = mimeType
    }
}

private func gatewayCanvasHexNibble(r: Rune): Int64 {
    match (r) {
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
        case r'a' | r'A' => 10
        case r'b' | r'B' => 11
        case r'c' | r'C' => 12
        case r'd' | r'D' => 13
        case r'e' | r'E' => 14
        case r'f' | r'F' => 15
        case _ => -1
    }
}

private func gatewayCanvasPercentDecodePath(raw: String): String {
    let runes = raw.toRuneArray()
    let out = StringBuilder()
    var i: Int64 = 0
    while (i < runes.size) {
        let ch = runes[i]
        if (ch == r'?' || ch == r'#') {
            break
        }
        if (ch == r'%' && i + 2 < runes.size) {
            let hi = gatewayCanvasHexNibble(runes[i + 1])
            let lo = gatewayCanvasHexNibble(runes[i + 2])
            if (hi >= 0 && lo >= 0) {
                let value = hi * 16 + lo
                if (value >= 0 && value <= 127) {
                    out.append(String.fromUtf8([UInt8(value)]))
                    i += 3
                    continue
                }
            }
        }
        if (ch == r'\\') {
            out.append(r'/')
        } else {
            out.append(ch)
        }
        i += 1
    }
    out.toString()
}

private func gatewayCanvasPathHasTraversal(decoded: String): Bool {
    for (part in decoded.split("/")) {
        let seg = part.trimAscii()
        if (seg == ".." || seg.contains("\u{0}")) {
            return true
        }
    }
    false
}

public func gatewayCanvasNormalizeUrlPath(raw: String): String {
    let decoded = gatewayCanvasPercentDecodePath(raw.trimAscii())
    let parts = ArrayList<String>()
    for (part in decoded.split("/")) {
        let seg = part.trimAscii()
        if (seg.isEmpty() || seg == ".") {
            continue
        }
        if (seg == "..") {
            parts.add("..")
        } else {
            parts.add(seg)
        }
    }
    if (parts.isEmpty()) {
        return "/"
    }
    let out = StringBuilder("/")
    var first = true
    for (part in parts) {
        if (!first) {
            out.append(r'/')
        }
        out.append(part)
        first = false
    }
    out.toString()
}

private func gatewayCanvasPathInsideRoot(root: String, candidate: String): Bool {
    candidate == root || candidate.startsWith(root + "/")
}

private func gatewayCanvasRelativeFromNormalized(normalized: String): String {
    if (normalized == "/") {
        return "index.html"
    }
    let runes = normalized.toRuneArray()
    if (runes.size <= 1) {
        return "index.html"
    }
    if (runes[0] == r'/') {
        return String(runes[1..])
    }
    normalized
}

public func gatewayCanvasResolveFileWithinRoot(root: Path, requestPath: String): GatewayCanvasResolveResult {
    let decoded = gatewayCanvasPercentDecodePath(requestPath.trimAscii())
    if (decoded.isEmpty() || gatewayCanvasPathHasTraversal(decoded)) {
        return GatewayCanvasResolveResult(false, "blocked")
    }
    let rootCanonical = try {
        canonicalize(root).toString()
    } catch (_: Exception) {
        return GatewayCanvasResolveResult(false, "root-missing")
    }
    if (!exists(Path(rootCanonical)) || !FileInfo(Path(rootCanonical)).isDirectory()) {
        return GatewayCanvasResolveResult(false, "root-unavailable")
    }
    let normalized = gatewayCanvasNormalizeUrlPath(decoded)
    let relative = gatewayCanvasRelativeFromNormalized(normalized)
    let candidate = Path(rootCanonical).join(relative)
    let candidateCanonical = try {
        canonicalize(candidate).toString()
    } catch (_: Exception) {
        return GatewayCanvasResolveResult(false, "missing", relativePath: relative)
    }
    if (!gatewayCanvasPathInsideRoot(rootCanonical, candidateCanonical)) {
        return GatewayCanvasResolveResult(false, "blocked", relativePath: relative)
    }
    GatewayCanvasResolveResult(
        true,
        "ok",
        path: candidateCanonical,
        relativePath: relative,
        mimeType: gatewayCanvasMimeType(relative)
    )
}

public func gatewayCanvasMimeType(path: String): String {
    let lower = path.toAsciiLower()
    if (lower.endsWith(".html") || lower.endsWith(".htm")) { return "text/html; charset=utf-8" }
    if (lower.endsWith(".js") || lower.endsWith(".mjs")) { return "text/javascript; charset=utf-8" }
    if (lower.endsWith(".css")) { return "text/css; charset=utf-8" }
    if (lower.endsWith(".json")) { return "application/json; charset=utf-8" }
    if (lower.endsWith(".svg")) { return "image/svg+xml" }
    if (lower.endsWith(".png")) { return "image/png" }
    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) { return "image/jpeg" }
    if (lower.endsWith(".webp")) { return "image/webp" }
    if (lower.endsWith(".wasm")) { return "application/wasm" }
    "application/octet-stream"
}

public func gatewayCanvasResolveRootState(cfg: GatewayConfig): JsonObject {
    let root = JsonObject()
    let enabled = cfg.canvas.enabled
    let rootText = cfg.canvas.root.trimAscii()
    root.put("enabled", enabled.toJsonValue())
    root.put("root", JsonString(cfg.canvas.root))
    root.put("port", cfg.canvas.port.toJsonValue())
    root.put("liveReload", cfg.canvas.liveReload.toJsonValue())
    root.put("hostStarted", false.toJsonValue())
    root.put("httpUrl", JsonString(""))
    root.put("healthy", false.toJsonValue())

    if (!enabled) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("disabled"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("disabled"))
        root.put("errorKind", JsonString(""))
        return root
    }
    if (rootText.isEmpty()) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("missing-root"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("misconfigured"))
        root.put("errorKind", JsonString("root-empty"))
        return root
    }

    let rootPath = Path(rootText)
    if (!exists(rootPath)) {
        root.put("rootPresent", false.toJsonValue())
        root.put("rootReadable", false.toJsonValue())
        root.put("assetState", JsonString("missing-root"))
        root.put("watchState", JsonString("disabled"))
        root.put("phase", JsonString("misconfigured"))
        root.put("errorKind", JsonString("missing-root"))
        return root
    }
    let readable = try {
        FileInfo(rootPath).isDirectory()
    } catch (_: Exception) {
        false
    }
    root.put("rootPresent", true.toJsonValue())
    root.put("rootReadable", readable.toJsonValue())
    root.put("assetState", JsonString(if (readable) { "mounted" } else { "unreadable-root" }))
    root.put("watchState", JsonString(if (readable && cfg.canvas.liveReload) { "static" } else { "disabled" }))
    root.put("phase", JsonString(if (readable) { "configured" } else { "misconfigured" }))
    root.put("errorKind", JsonString(if (readable) { "host-not-started" } else { "unreadable-root" }))
    root
}
