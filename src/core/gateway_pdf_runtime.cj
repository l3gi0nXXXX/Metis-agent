package metis.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisPaths}
import metis.core.model.{modelVisionSupportIsSupported, resolveModelImageCapability}

import std.collection.ArrayList
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists}
import std.process.executeWithOutput
import std.time.*
import stdx.encoding.base64.toBase64String
import stdx.encoding.json.{JsonArray, JsonBool, JsonFloat, JsonInt, JsonObject, JsonString, JsonValue}

private let PDF_DEFAULT_MAX_BYTES_MB: Float64 = 10.0
private let PDF_DEFAULT_MAX_PAGES: Int64 = 20

private var gatewayPdfAnalyzeRunnerOverride: Option<(JsonObject) -> JsonObject> =
    None<(JsonObject) -> JsonObject>

public func setGatewayPdfAnalyzeRunnerForTest(runner: Option<(JsonObject) -> JsonObject>): Unit {
    gatewayPdfAnalyzeRunnerOverride = runner
}

public func gatewayPdfAnalyze(request: JsonObject): JsonObject {
    match (gatewayPdfAnalyzeRunnerOverride) {
        case Some(runner) =>
            try {
                return runner(request)
            } catch (e: Exception) {
                let out = JsonObject()
                out.put("ok", JsonBool(false))
                out.put("status", JsonString("runtime_error"))
                out.put("message", JsonString("PDF runtime failed: ${e.message}"))
                return out
            }
        case None => ()
    }

    let normalized = normalizePdfToolInputs(
        pdfOptionalString(request, "pdf"),
        pdfOptionalStringArray(request, "pdfs"),
        prompt: pdfOptionalString(request, "prompt"),
        pages: pdfOptionalString(request, "pages"),
        model: pdfOptionalString(request, "model"),
        maxBytesMb: pdfOptionalFloat(request, "maxBytesMb"),
        maxPdfs: PDF_TOOL_DEFAULT_MAX_PDFS
    )
    if (!normalized.ok) {
        return pdfRuntimeFailure(normalized.status, normalized.message)
    }

    let pageNumbers = try {
        parsePdfPageRange(normalized.pages, gatewayPdfMaxPages())
    } catch (e: Exception) {
        return pdfRuntimeFailure("invalid_pages", e.message)
    }

    let maxBytes = if (normalized.maxBytesMb > 0.0) {
        Int64(normalized.maxBytesMb * 1024.0 * 1024.0)
    } else {
        gatewayPdfMaxBytes()
    }
    let loaded = ArrayList<GatewayPdfLoadedReference>()
    let pdfInputs = ArrayList<GatewayPdfInput>()
    for (pdfRef in normalized.pdfs) {
        let load = loadPdfReference(
            pdfRef,
            maxBytes: maxBytes,
            baseDir: CliConfig.cwd.toString(),
            timeoutMs: 30000
        )
        if (!load.ok) {
            return pdfRuntimeFailure(load.status, load.message, pdf: pdfRef, fileBytes: Int64(load.bytes.size), limitBytes: maxBytes)
        }
        let extractionPath = try {
            pdfRuntimeExtractionPath(load, loaded.size)
        } catch (e: Exception) {
            return pdfRuntimeFailure("read_error", "Failed to prepare PDF for fallback extraction: ${e.message}", pdf: pdfRef)
        }
        loaded.add(GatewayPdfLoadedReference(load, extractionPath))
        pdfInputs.add(GatewayPdfInput(toBase64String(load.bytes), filename: load.fileName))
    }

    let channel = pdfRuntimeJsonString(request, "channel").toAsciiLower()
    let candidates = pdfRuntimePromptCandidates(normalized.model, channel)
    if (candidates.isEmpty()) {
        return pdfRuntimeFailure(
            "not_configured",
            "PDF runtime is not configured. Configure agents.defaults.pdfModel.primary, agents.defaults.imageModel.primary, gateway.media.image.models, or pass a model override."
        )
    }

    let result = gatewayPdfRunPrompt(
        pdfInputs.toArray(),
        normalized.prompt,
        candidates,
        { => pdfRuntimeExtractLoaded(loaded.toArray(), pageNumbers) },
        pageNumbers: pageNumbers
    )
    pdfRuntimePromptResultToJson(result, normalized.pdfs, pageNumbers)
}

private class GatewayPdfLoadedReference {
    public let load: PdfReferenceLoadResult
    public let extractionPath: String

    public init(load: PdfReferenceLoadResult, extractionPath: String) {
        this.load = load
        this.extractionPath = extractionPath
    }
}

private func pdfOptionalString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(value) =>
            let text = try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
            if (text.isEmpty()) { None<String> } else { Some(text) }
        case None => None<String>
    }
}

private func pdfOptionalStringArray(obj: JsonObject, key: String): Option<Array<String>> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                let arr = value.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    try {
                        let text = item.asString().getValue().trimAscii()
                        if (!text.isEmpty()) {
                            out.add(text)
                        }
                    } catch (_: Exception) {
                        ()
                    }
                }
                if (out.isEmpty()) { None<Array<String>> } else { Some(out.toArray()) }
            } catch (_: Exception) {
                None<Array<String>>
            }
        case None => None<Array<String>>
    }
}

private func pdfOptionalFloat(obj: JsonObject, key: String): Option<Float64> {
    match (obj.get(key)) {
        case Some(value) =>
            let parsed = try { Float64.parse(value.toJsonString()) } catch (_: Exception) {
                try { Float64.parse(value.asString().getValue().trimAscii()) } catch (_inner: Exception) { 0.0 }
            }
            if (parsed > 0.0) { Some(parsed) } else { None<Float64> }
        case None => None<Float64>
    }
}

private func pdfRuntimeFailure(
    status: String,
    message: String,
    pdf!: String = "",
    fileBytes!: Int64 = -1,
    limitBytes!: Int64 = -1
): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(false))
    out.put("status", JsonString(status.trimAscii()))
    out.put("message", JsonString(message.trimAscii()))
    out.put("error", JsonString(message.trimAscii()))
    if (!pdf.trimAscii().isEmpty()) {
        out.put("pdf", JsonString(pdf.trimAscii()))
    }
    if (fileBytes >= 0) {
        out.put("fileBytes", JsonInt(fileBytes))
    }
    if (limitBytes >= 0) {
        out.put("limitBytes", JsonInt(limitBytes))
    }
    out
}

private func pdfRuntimeExtractionCacheDir(): Path {
    let root = Path("/tmp/metis-pdf-runtime")
    if (!exists(root)) {
        Directory.create(root, recursive: true)
    }
    root
}

private func pdfRuntimeExtractionPath(load: PdfReferenceLoadResult, index: Int64): String {
    let path = load.resolvedPath.trimAscii()
    if (!path.isEmpty() && !path.toAsciiLower().startsWith("http://") && !path.toAsciiLower().startsWith("https://") && exists(Path(path))) {
        return path
    }
    let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds()
    let fileName = load.fileName.trimAscii()
    let safeName = if (fileName.isEmpty()) { "document-${index}.pdf" } else { fileName.replace("/", "_").replace("\\", "_") }
    let target = pdfRuntimeExtractionCacheDir().join("${stamp}-${index}-${safeName}")
    File.writeTo(target, load.bytes)
    target.toString()
}

private func pdfRuntimePromptCandidates(modelOverride: String, channel: String): Array<GatewayPdfPromptCandidate> {
    let out = ArrayList<GatewayPdfPromptCandidate>()
    let overrideRef = modelOverride.trimAscii()
    if (!overrideRef.isEmpty()) {
        let decision = resolveModelImageCapability(overrideRef)
        out.add(pdfRuntimePromptCandidateFromParts(
            decision.normalizedRef,
            "request.model",
            providerSupportsNativePdf(decision.provider),
            modelVisionSupportIsSupported(decision.vision)
        ))
        return out.toArray()
    }
    let user = CliSettingManager.readGatewaySettings()
    for (candidate in gatewayPdfBuildCandidates(user, channel: channel)) {
        out.add(pdfRuntimePromptCandidateFromParts(
            candidate.modelRef,
            candidate.source,
            candidate.nativePdfSupported,
            candidate.imageSupported
        ))
    }
    out.toArray()
}

private func pdfRuntimePromptCandidateFromParts(
    modelRef: String,
    source: String,
    nativePdfSupported: Bool,
    imageSupported: Bool
): GatewayPdfPromptCandidate {
    let provider = pdfProviderFromModelRef(MetisConfigManager.canonicalModelRef(modelRef))
    GatewayPdfPromptCandidate(
        modelRef,
        source: source,
        nativePdfSupported: nativePdfSupported,
        imageSupported: imageSupported,
        apiKey: MetisConfigManager.readProviderApiKey(provider),
        baseUrl: MetisConfigManager.readProviderBaseUrl(provider),
        maxTokens: 4096,
        timeoutMs: 120000
    )
}

private func pdfRuntimeExtractLoaded(
    loaded: Array<GatewayPdfLoadedReference>,
    pageNumbers: Array<Int64>
): Array<GatewayPdfExtraction> {
    let out = ArrayList<GatewayPdfExtraction>()
    for (item in loaded) {
        let extracted = extractPdfWithNodeBridge(
            item.extractionPath,
            maxPages: gatewayPdfMaxPages(),
            pageNumbers: pageNumbers
        )
        if (!extracted.ok) {
            throw Exception(if (!extracted.message.trimAscii().isEmpty()) { extracted.message } else { extracted.status })
        }
        let images = ArrayList<GatewayPdfExtractedImage>()
        for (image in extracted.images) {
            images.add(GatewayPdfExtractedImage(image.mimeType, image.data))
        }
        out.add(GatewayPdfExtraction(
            extracted.text,
            images: images.toArray(),
            pageCount: extracted.pageCount,
            selectedPages: extracted.selectedPages
        ))
    }
    out.toArray()
}

private func pdfRuntimeStatusFromPrompt(result: GatewayPdfPromptResult): String {
    if (result.ok) {
        return "ok"
    }
    if (!result.attempts.isEmpty()) {
        let status = result.attempts[result.attempts.size - 1].status.trimAscii()
        if (!status.isEmpty()) {
            return status
        }
    }
    "provider_error"
}

private func pdfRuntimePromptResultToJson(
    result: GatewayPdfPromptResult,
    pdfs: Array<String>,
    pageNumbers: Array<Int64>
): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(result.ok))
    out.put("status", JsonString(pdfRuntimeStatusFromPrompt(result)))
    if (result.ok) {
        out.put("text", JsonString(result.text))
        out.put("message", JsonString(result.text))
    } else {
        out.put("message", JsonString(result.error))
        out.put("error", JsonString(result.error))
    }
    out.put("provider", JsonString(result.provider))
    out.put("model", JsonString(result.model))
    out.put("native", JsonBool(result.native))
    out.put("attempts", result.attemptsJson())
    if (pdfs.size == 1) {
        out.put("pdf", JsonString(pdfs[0]))
    }
    let pdfArray = JsonArray([])
    for (pdf in pdfs) {
        pdfArray.add(JsonString(pdf))
    }
    let details = JsonObject()
    details.put("pdfs", pdfArray)
    details.put("provider", JsonString(result.provider))
    details.put("model", JsonString(result.model))
    details.put("native", JsonBool(result.native))
    details.put("attempts", result.attemptsJson())
    if (!pageNumbers.isEmpty()) {
        let pages = JsonArray([])
        for (page in pageNumbers) {
            pages.add(JsonInt(page))
        }
        details.put("pages", pages)
    }
    out.put("details", details)
    out
}

private func pdfRuntimeJsonObject(obj: JsonObject, key: String): Option<JsonObject> {
    match (obj.get(key)) {
        case Some(value) =>
            try { Some(value.asObject()) } catch (_: Exception) { None<JsonObject> }
        case None => None<JsonObject>
    }
}

private func pdfRuntimeJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfRuntimeJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func pdfRuntimeJsonInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(value) =>
            try { Int64.parse(value.toJsonString()) } catch (_: Exception) {
                try { Int64.parse(value.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func pdfRuntimeJsonFloat(obj: JsonObject, key: String, fallback: Float64): Float64 {
    match (obj.get(key)) {
        case Some(value) =>
            try { Float64.parse(value.toJsonString()) } catch (_: Exception) {
                try { Float64.parse(value.asString().getValue().trimAscii()) } catch (_inner: Exception) { fallback }
            }
        case None => fallback
    }
}

private func pdfRuntimeJsonStringArray(obj: JsonObject, key: String): Array<String> {
    match (obj.get(key)) {
        case Some(value) =>
            try {
                let arr = value.asArray()
                let out = ArrayList<String>()
                for (item in arr.getItems()) {
                    try {
                        let text = item.asString().getValue().trimAscii()
                        if (!text.isEmpty()) {
                            out.add(text)
                        }
                    } catch (_: Exception) {
                        ()
                    }
                }
                out.toArray()
            } catch (_: Exception) {
                []
            }
        case None => []
    }
}

private func pdfAgentsDefaults(root: JsonObject): JsonObject {
    match (pdfRuntimeJsonObject(root, "agents")) {
        case Some(agents) =>
            match (pdfRuntimeJsonObject(agents, "defaults")) {
                case Some(defaults) => defaults
                case None => JsonObject()
            }
        case None => JsonObject()
    }
}

private func pdfProviderFromModelRef(modelRef: String): String {
    let normalized = modelRef.trimAscii()
    match (normalized.indexOf(b':')) {
        case Some(index) => normalized[0..index].trimAscii().toAsciiLower()
        case None =>
            match (normalized.indexOf(b'/')) {
                case Some(index) => normalized[0..index].trimAscii().toAsciiLower()
                case None => ""
            }
    }
}

private func pdfProviderSupportsNativePdf(provider: String): Bool {
    let p = provider.trimAscii().toAsciiLower()
    p == "anthropic" || p == "google"
}

private func pdfAppendCandidate(
    rows: JsonArray,
    seen: ArrayList<String>,
    modelRef: String,
    source: String
): Unit {
    let canonical = MetisConfigManager.canonicalModelRef(modelRef).trimAscii()
    if (canonical.isEmpty() || seen.contains(canonical)) {
        return
    }
    seen.add(canonical)
    let provider = pdfProviderFromModelRef(canonical)
    let row = JsonObject()
    row.put("modelRef", JsonString(canonical))
    row.put("source", JsonString(source))
    row.put("provider", JsonString(provider))
    row.put("nativePdfSupported", JsonBool(pdfProviderSupportsNativePdf(provider)))
    row.put("authConfigured", JsonBool(!provider.isEmpty() && !MetisConfigManager.readProviderApiKey(provider).trimAscii().isEmpty()))
    rows.add(row)
}

private func pdfAppendModelObjectCandidates(
    rows: JsonArray,
    seen: ArrayList<String>,
    defaults: JsonObject,
    key: String,
    sourcePrefix: String
): Unit {
    match (pdfRuntimeJsonObject(defaults, key)) {
        case Some(modelObj) =>
            pdfAppendCandidate(rows, seen, pdfRuntimeJsonString(modelObj, "primary"), "${sourcePrefix}.primary")
            for (fallback in pdfRuntimeJsonStringArray(modelObj, "fallbacks")) {
                pdfAppendCandidate(rows, seen, fallback, "${sourcePrefix}.fallbacks")
            }
        case None => ()
    }
}

private func pdfDependencyStatus(packageName: String): JsonObject {
    let out = JsonObject()
    out.put("package", JsonString(packageName))
    out.put("loadable", JsonBool(false))

    match (MetisPaths.projectRoot()) {
        case Some(root) =>
            let helperRoot = root.join("tools").join("pdf_extract")
            out.put("helperRoot", JsonString(helperRoot.toString()))
            if (!exists(helperRoot)) {
                out.put("status", JsonString("missing_helper"))
                out.put("message", JsonString("tools/pdf_extract is not present yet; install the PDF runner worker before enabling fallback extraction."))
                return out
            }
            if (!exists(helperRoot.join("package.json"))) {
                out.put("status", JsonString("missing_package_json"))
                out.put("message", JsonString("tools/pdf_extract/package.json is missing."))
                return out
            }
            try {
                let script = "require.resolve(\"${packageName}\")"
                let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput("node", ["-e", script], workingDirectory: helperRoot)
                if (exitCode == 0) {
                    out.put("loadable", JsonBool(true))
                    out.put("status", JsonString("loadable"))
                    let resolved = try { String.fromUtf8(stdoutBytes).trimAscii() } catch (_: Exception) { "" }
                    if (!resolved.isEmpty()) {
                        out.put("resolved", JsonString(resolved))
                    }
                    return out
                }
                let stderr = try { String.fromUtf8(stderrBytes).trimAscii() } catch (_: Exception) { "" }
                out.put("status", JsonString("not_loadable"))
                if (!stderr.isEmpty()) {
                    out.put("message", JsonString(stderr))
                }
                return out
            } catch (e: Exception) {
                out.put("status", JsonString("node_unavailable"))
                out.put("message", JsonString(e.message))
                return out
            }
        case None =>
            out.put("status", JsonString("project_root_unknown"))
            out.put("message", JsonString("Metis project root could not be resolved."))
            out
    }
}

public func gatewayPdfDiagnosticSnapshot(): JsonObject {
    let root = MetisConfigManager.rawConfig() ?? JsonObject()
    let defaults = pdfAgentsDefaults(root)
    let candidates = JsonArray([])
    let seen = ArrayList<String>()
    pdfAppendModelObjectCandidates(candidates, seen, defaults, "pdfModel", "agents.defaults.pdfModel")
    pdfAppendModelObjectCandidates(candidates, seen, defaults, "imageModel", "agents.defaults.imageModel")
    pdfAppendModelObjectCandidates(candidates, seen, defaults, "model", "agents.defaults.model")

    let dependencies = JsonObject()
    dependencies.put("pdfjsDist", pdfDependencyStatus("pdfjs-dist"))
    dependencies.put("canvas", pdfDependencyStatus("@napi-rs/canvas"))

    let out = JsonObject()
    out.put("ok", JsonBool(true))
    out.put("status", JsonString("ok"))
    out.put("tool", JsonString("pdf"))
    out.put("runtimeAdapter", JsonString("connected"))
    out.put("configured", JsonBool(candidates.size() > 0))
    out.put("candidateCount", JsonInt(candidates.size()))
    out.put("candidates", candidates)
    out.put("nativeProviders", JsonArray([JsonString("anthropic"), JsonString("google")]))
    out.put("maxBytesMb", JsonFloat(pdfRuntimeJsonFloat(defaults, "pdfMaxBytesMb", PDF_DEFAULT_MAX_BYTES_MB)))
    out.put("maxPages", JsonInt(pdfRuntimeJsonInt(defaults, "pdfMaxPages", PDF_DEFAULT_MAX_PAGES)))
    out.put("dependencies", dependencies)
    out
}

private func pdfSnapshotArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func pdfSnapshotObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func pdfYesNo(value: Bool): String {
    if (value) { "yes" } else { "no" }
}

private func pdfAppendDependencyLine(lines: ArrayList<String>, dependencies: JsonObject, key: String, label: String): Unit {
    let dep = pdfSnapshotObject(dependencies, key)
    let loadable = pdfRuntimeJsonBool(dep, "loadable", false)
    let status = pdfRuntimeJsonString(dep, "status")
    let rendered = if (loadable) { "loadable" } else if (!status.isEmpty()) { status } else { "unknown" }
    lines.add("  ${label}: ${rendered}")
    let message = pdfRuntimeHumanMessage(pdfRuntimeJsonString(dep, "message"))
    if (!message.isEmpty() && !loadable) {
        lines.add("    ${message}")
    }
}

private func pdfRuntimeHumanMessage(raw: String): String {
    var out = raw.trimAscii()
    if (out.size > 240) {
        out = out[..240]
    }
    out.replace("{", "(").replace("}", ")").replace("\"", "'")
}

public func gatewayPdfDiagnosticStatusText(snapshot: JsonObject): String {
    let lines = ArrayList<String>()
    let candidates = pdfSnapshotArray(snapshot, "candidates")
    let configured = pdfRuntimeJsonBool(snapshot, "configured", false)
    lines.add("PDF tool status")
    lines.add("  Tool: registered as `pdf` for agent use")
    lines.add("  Runtime adapter: ${pdfRuntimeJsonString(snapshot, "runtimeAdapter")}")
    lines.add("  Model candidates: ${candidates.size()} (${if (configured) { "configured" } else { "not configured" }})")
    let limit = if (candidates.size() < 5) { candidates.size() } else { 5 }
    for (idx in 0..limit) {
        let row = try { candidates[idx].asObject() } catch (_: Exception) { JsonObject() }
        let modelRef = pdfRuntimeJsonString(row, "modelRef")
        if (modelRef.isEmpty()) {
            continue
        }
        lines.add(
            "  - ${modelRef} via ${pdfRuntimeJsonString(row, "source")} | native PDF: ${pdfYesNo(pdfRuntimeJsonBool(row, "nativePdfSupported", false))} | auth: ${if (pdfRuntimeJsonBool(row, "authConfigured", false)) { "configured" } else { "not configured" }}"
        )
    }
    if (candidates.size() > limit) {
        lines.add("  - ... ${candidates.size() - limit} more candidate(s)")
    }
    lines.add("  Defaults: maxBytesMb=${pdfRuntimeJsonFloat(snapshot, "maxBytesMb", PDF_DEFAULT_MAX_BYTES_MB)}, maxPages=${pdfRuntimeJsonInt(snapshot, "maxPages", PDF_DEFAULT_MAX_PAGES)}")
    lines.add("Fallback dependencies")
    let dependencies = pdfSnapshotObject(snapshot, "dependencies")
    pdfAppendDependencyLine(lines, dependencies, "pdfjsDist", "pdfjs-dist")
    pdfAppendDependencyLine(lines, dependencies, "canvas", "@napi-rs/canvas")
    lines.add("Next steps")
    if (!configured) {
        lines.add("  - Configure agents.defaults.pdfModel.primary or agents.defaults.imageModel.primary.")
    }
    lines.add("  - Install tools/pdf_extract npm dependencies if fallback extraction reports pdfjs-dist or @napi-rs/canvas as not_loadable.")
    lines.add("  - Use: metis agent --message \"Please use the pdf tool to summarize /tmp/report.pdf\"")
    String.join(lines.toArray(), delimiter: "\n")
}
