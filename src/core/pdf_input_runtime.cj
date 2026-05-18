package metis.core

import metis.core.config.CliConfig
import metis.utils.{ShellTimeoutException, ShellUtils}

import std.collection.{ArrayList, HashSet}
import std.convert.*
import std.env.getVariable
import std.fs.{File, Path, canonicalize, exists}
import std.sort.sort
import std.time.*
import stdx.encoding.json.{JsonObject, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public let PDF_TOOL_DEFAULT_PROMPT = "Analyze this PDF document."
public let PDF_TOOL_DEFAULT_MAX_PDFS: Int64 = 10
public let PDF_TOOL_DEFAULT_MAX_BYTES: Int64 = 10 * 1024 * 1024
public let PDF_TOOL_DEFAULT_MAX_PAGES: Int64 = 20
public let PDF_EXTRACTOR_DEFAULT_MAX_PIXELS: Int64 = 4_000_000
public let PDF_EXTRACTOR_DEFAULT_MIN_TEXT_CHARS: Int64 = 200
public let PDF_EXTRACTOR_DEFAULT_TIMEOUT_MS: Int64 = 120_000
public let PDF_EXTRACTOR_DEFAULT_MAX_OUTPUT_BYTES: Int64 = 8 * 1024 * 1024

public class PdfToolInputNormalizationResult {
    public let ok: Bool
    public let status: String
    public let message: String
    public let pdfs: Array<String>
    public let prompt: String
    public let pages: String
    public let model: String
    public let maxBytesMb: Float64
    public let count: Int64
    public let max: Int64

    public init(
        ok: Bool,
        status!: String = "ok",
        message!: String = "",
        pdfs!: Array<String> = [],
        prompt!: String = PDF_TOOL_DEFAULT_PROMPT,
        pages!: String = "",
        model!: String = "",
        maxBytesMb!: Float64 = 0.0,
        count!: Int64 = 0,
        max!: Int64 = PDF_TOOL_DEFAULT_MAX_PDFS
    ) {
        this.ok = ok
        this.status = status
        this.message = message
        this.pdfs = pdfs
        this.prompt = prompt
        this.pages = pages
        this.model = model
        this.maxBytesMb = maxBytesMb
        this.count = count
        this.max = max
    }
}

public func normalizePdfToolInputs(
    pdf: Option<String>,
    pdfs: Option<Array<String>>,
    prompt!: Option<String> = None<String>,
    pages!: Option<String> = None<String>,
    model!: Option<String> = None<String>,
    maxBytesMb!: Option<Float64> = None<Float64>,
    maxPdfs!: Int64 = PDF_TOOL_DEFAULT_MAX_PDFS
): PdfToolInputNormalizationResult {
    let candidates = ArrayList<String>()
    match (pdf) {
        case Some(raw) => candidates.add(raw)
        case None => ()
    }
    match (pdfs) {
        case Some(items) =>
            for (raw in items) {
                candidates.add(raw)
            }
        case None => ()
    }

    let seen = HashSet<String>()
    let normalized = ArrayList<String>()
    for (candidate in candidates) {
        let trimmed = candidate.trimAscii()
        if (trimmed.isEmpty() || seen.contains(trimmed)) {
            continue
        }
        seen.add(trimmed)
        normalized.add(trimmed)
    }

    if (normalized.size == 0) {
        return PdfToolInputNormalizationResult(
            false,
            status: "missing_pdf",
            message: "pdf required: provide a path or URL to a PDF document",
            max: maxPdfs
        )
    }
    if (Int64(normalized.size) > maxPdfs) {
        return PdfToolInputNormalizationResult(
            false,
            status: "too_many_pdfs",
            message: "Too many PDFs: ${normalized.size} provided, maximum is ${maxPdfs}.",
            pdfs: normalized.toArray(),
            count: Int64(normalized.size),
            max: maxPdfs
        )
    }

    let effectivePrompt = match (prompt) {
        case Some(raw) =>
            let trimmed = raw.trimAscii()
            if (trimmed.isEmpty()) { PDF_TOOL_DEFAULT_PROMPT } else { trimmed }
        case None => PDF_TOOL_DEFAULT_PROMPT
    }
    let effectivePages = match (pages) {
        case Some(raw) => raw.trimAscii()
        case None => ""
    }
    let effectiveModel = match (model) {
        case Some(raw) => raw.trimAscii()
        case None => ""
    }
    let effectiveMaxBytesMb = match (maxBytesMb) {
        case Some(value) => if (value > 0.0) { value } else { 0.0 }
        case None => 0.0
    }

    PdfToolInputNormalizationResult(
        true,
        pdfs: normalized.toArray(),
        prompt: effectivePrompt,
        pages: effectivePages,
        model: effectiveModel,
        maxBytesMb: effectiveMaxBytesMb,
        count: Int64(normalized.size),
        max: maxPdfs
    )
}

public func parsePdfPageRange(range: String, maxPages: Int64): Array<Int64> {
    let trimmedRange = range.trimAscii()
    if (maxPages <= 0) {
        throw Exception("Invalid page range: maxPages must be positive")
    }
    if (trimmedRange.isEmpty()) {
        return []
    }
    let pages = HashSet<Int64>()
    for (rawPart in trimmedRange.split(",")) {
        let part = rawPart.trimAscii()
        if (part.isEmpty()) {
            continue
        }
        if (part.indexOf("-").isSome()) {
            let pieces = part.split("-")
            if (pieces.size != 2) {
                throw Exception("Invalid page range: \"${part}\"")
            }
            let start = try {
                Int64.parse(pieces[0].trimAscii())
            } catch (_: Exception) {
                throw Exception("Invalid page range: \"${part}\"")
            }
            let end = try {
                Int64.parse(pieces[1].trimAscii())
            } catch (_: Exception) {
                throw Exception("Invalid page range: \"${part}\"")
            }
            if (start < 1 || end < start) {
                throw Exception("Invalid page range: \"${part}\"")
            }
            let clippedEnd = if (end < maxPages) { end } else { maxPages }
            var page = start
            while (page <= clippedEnd) {
                pages.add(page)
                page += 1
            }
        } else {
            let page = try {
                Int64.parse(part)
            } catch (_: Exception) {
                throw Exception("Invalid page number: \"${part}\"")
            }
            if (page < 1) {
                throw Exception("Invalid page number: \"${part}\"")
            }
            if (page <= maxPages) {
                pages.add(page)
            }
        }
    }
    let out = ArrayList<Int64>()
    for (page in pages) {
        out.add(page)
    }
    let arr = out.toArray()
    sort(arr)
    arr
}

public class PdfReferenceHttpResult {
    public let statusCode: Int64
    public let bodyBytes: Array<Byte>
    public let error: String
    public let contentType: String
    public let fileName: String

    public init(statusCode: Int64, bodyBytes!: Array<Byte> = [], error!: String = "", contentType!: String = "", fileName!: String = "") {
        this.statusCode = statusCode
        this.bodyBytes = bodyBytes
        this.error = error
        this.contentType = contentType
        this.fileName = fileName
    }
}

public class PdfReferenceLoadResult {
    public let ok: Bool
    public let status: String
    public let message: String
    public let reference: String
    public let resolvedPath: String
    public let fileName: String
    public let contentType: String
    public let bytes: Array<Byte>
    public let rewrittenFrom: String

    public init(
        ok: Bool,
        status!: String = "ok",
        message!: String = "",
        reference!: String = "",
        resolvedPath!: String = "",
        fileName!: String = "document.pdf",
        contentType!: String = "application/pdf",
        bytes!: Array<Byte> = [],
        rewrittenFrom!: String = ""
    ) {
        this.ok = ok
        this.status = status
        this.message = message
        this.reference = reference
        this.resolvedPath = resolvedPath
        this.fileName = fileName
        this.contentType = contentType
        this.bytes = bytes
        this.rewrittenFrom = rewrittenFrom
    }
}

private var pdfReferenceHttpRunnerOverride: Option<(String, Int64, Int64) -> PdfReferenceHttpResult> =
    None<(String, Int64, Int64) -> PdfReferenceHttpResult>

public func setPdfReferenceHttpRunnerForTest(runner: Option<(String, Int64, Int64) -> PdfReferenceHttpResult>): Unit {
    pdfReferenceHttpRunnerOverride = runner
}

private func pdfInputReadAllBytes(response: HttpResponse): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = response.body.read(buffer)
        if (n <= 0) {
            break
        }
        out.add(all: buffer[..n])
    }
    out.toArray()
}

private func pdfNativeHttpGet(url: String, timeoutMs: Int64): PdfReferenceHttpResult {
    let builder = ClientBuilder()
    builder.readTimeout(Duration.millisecond * max(timeoutMs, 1))
    if (url.toAsciiLower().startsWith("https://")) {
        var tlsConfig = TlsClientConfig()
        tlsConfig.domain = URL.parse(url).hostName
        tlsConfig.alpnProtocolsList = ["http/1.1"]
        builder.tlsConfig(tlsConfig)
    }
    let client = builder.build()
    try {
        let reqBuilder = HttpRequestBuilder().url(url).get()
        reqBuilder.header("Accept", "application/pdf, */*")
        let response = client.send(reqBuilder.build())
        let contentType = response.headers.getFirst("content-type") ?? response.headers.getFirst("Content-Type") ?? ""
        PdfReferenceHttpResult(Int64(response.status), bodyBytes: pdfInputReadAllBytes(response), contentType: contentType)
    } catch (e: Exception) {
        PdfReferenceHttpResult(0, error: e.message)
    } finally {
        client.close()
    }
}

private func pdfHttpGet(url: String, maxBytes: Int64, timeoutMs: Int64): PdfReferenceHttpResult {
    match (pdfReferenceHttpRunnerOverride) {
        case Some(runner) => runner(url, maxBytes, timeoutMs)
        case None => pdfNativeHttpGet(url, timeoutMs)
    }
}

private func pdfIsMagic(bytes: Array<Byte>): Bool {
    bytes.size >= 5 &&
        UInt8(bytes[0]) == 37u8 &&
        UInt8(bytes[1]) == 80u8 &&
        UInt8(bytes[2]) == 68u8 &&
        UInt8(bytes[3]) == 70u8 &&
        UInt8(bytes[4]) == 45u8
}

private func pdfScheme(raw: String): String {
    let trimmed = raw.trimAscii()
    match (trimmed.indexOf(":")) {
        case Some(colon) =>
            if (colon == 1) {
                return ""
            }
            match (trimmed.indexOf("/")) {
                case Some(slash) =>
                    if (slash < colon) {
                        return ""
                    }
                case None => ()
            }
            trimmed[..colon].toAsciiLower()
        case None => ""
    }
}

private func pdfFileUrlPath(raw: String): String {
    var path = raw["file://".size..]
    if (path.startsWith("localhost/")) {
        path = path["localhost".size..]
    }
    path
}

private func pdfExpandUserPath(raw: String, homeDir: String): String {
    let trimmed = raw.trimAscii()
    if (!trimmed.startsWith("~")) {
        return trimmed
    }
    let home = if (!homeDir.trimAscii().isEmpty()) {
        homeDir.trimAscii()
    } else {
        getVariable("HOME") ?? ""
    }
    if (home.isEmpty()) {
        return trimmed
    }
    if (trimmed == "~") {
        return home
    }
    if (trimmed.startsWith("~/")) {
        return "${home}/${trimmed[2..]}"
    }
    trimmed
}

private func pdfResolveLocalPath(raw: String, baseDir: String, homeDir: String): String {
    var pathText = if (raw.toAsciiLower().startsWith("file://")) {
        pdfFileUrlPath(raw)
    } else {
        raw
    }
    pathText = pdfExpandUserPath(pathText, homeDir)
    let path = Path(pathText)
    if (path.isAbsolute()) {
        return path.toString()
    }
    let base = if (!baseDir.trimAscii().isEmpty()) {
        Path(baseDir.trimAscii())
    } else {
        CliConfig.cwd
    }
    base.join(pathText).toString()
}

private func pdfBasename(raw: String): String {
    var text = raw.trimAscii()
    match (text.indexOf("?")) {
        case Some(idx) => text = text[..idx]
        case None => ()
    }
    while (text.endsWith("/") && text.size > 1) {
        text = text[..text.size - 1]
    }
    let pieces = text.split("/")
    if (pieces.size == 0) {
        return "document.pdf"
    }
    let name = pieces[pieces.size - 1].trimAscii()
    if (name.isEmpty()) { "document.pdf" } else { name }
}

private func pdfPathAllowedByRoots(pathText: String, roots: Array<String>): Bool {
    if (roots.size == 0) {
        return true
    }
    let candidate = try {
        canonicalize(Path(pathText)).toString().replace("\\", "/")
    } catch (_: Exception) {
        return false
    }
    for (root in roots) {
        let trimmed = root.trimAscii()
        if (trimmed.isEmpty()) {
            continue
        }
        let rootPath = try {
            canonicalize(Path(trimmed)).toString().replace("\\", "/")
        } catch (_: Exception) {
            continue
        }
        if (candidate == rootPath || candidate.startsWith("${rootPath}/")) {
            return true
        }
    }
    false
}

private func pdfValidateBytes(bytes: Array<Byte>, reference: String, contentType: String): PdfReferenceLoadResult {
    if (!pdfIsMagic(bytes)) {
        let detail = if (contentType.trimAscii().isEmpty()) { "unknown content" } else { contentType.trimAscii() }
        return PdfReferenceLoadResult(
            false,
            status: "not_pdf",
            message: "Expected PDF but got ${detail}: ${reference}",
            reference: reference,
            contentType: contentType,
            bytes: bytes
        )
    }
    PdfReferenceLoadResult(true, reference: reference, contentType: if (contentType.trimAscii().isEmpty()) { "application/pdf" } else { contentType }, bytes: bytes)
}

public func loadPdfReference(
    reference: String,
    maxBytes!: Int64 = PDF_TOOL_DEFAULT_MAX_BYTES,
    baseDir!: String = "",
    homeDir!: String = "",
    sandboxed!: Bool = false,
    allowedRoots!: Array<String> = [],
    timeoutMs!: Int64 = 30_000
): PdfReferenceLoadResult {
    let trimmed = reference.trimAscii()
    if (trimmed.isEmpty()) {
        return PdfReferenceLoadResult(false, status: "missing_pdf", message: "pdf required: provide a path or URL to a PDF document", reference: reference)
    }
    let scheme = pdfScheme(trimmed)
    let lower = trimmed.toAsciiLower()
    let isHttp = lower.startsWith("http://") || lower.startsWith("https://")
    if (!scheme.isEmpty() && scheme != "file" && scheme != "http" && scheme != "https") {
        return PdfReferenceLoadResult(
            false,
            status: "unsupported_pdf_reference",
            message: "Unsupported PDF reference: ${reference}. Use a file path, file:// URL, or http(s) URL.",
            reference: reference
        )
    }
    if (sandboxed && isHttp) {
        return PdfReferenceLoadResult(false, status: "sandbox_remote_disallowed", message: "Sandboxed PDF tool does not allow remote URLs.", reference: reference)
    }

    let effectiveMaxBytes = if (maxBytes > 0) { maxBytes } else { PDF_TOOL_DEFAULT_MAX_BYTES }
    if (isHttp) {
        let http = pdfHttpGet(trimmed, effectiveMaxBytes, timeoutMs)
        if (!http.error.trimAscii().isEmpty()) {
            return PdfReferenceLoadResult(false, status: "http_error", message: http.error.trimAscii(), reference: reference, resolvedPath: trimmed, contentType: http.contentType)
        }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            return PdfReferenceLoadResult(false, status: "http_error", message: "HTTP ${http.statusCode} while loading PDF reference.", reference: reference, resolvedPath: trimmed, contentType: http.contentType)
        }
        if (Int64(http.bodyBytes.size) > effectiveMaxBytes) {
            return PdfReferenceLoadResult(false, status: "too_large", message: "PDF exceeds maxBytes (${http.bodyBytes.size} > ${effectiveMaxBytes}).", reference: reference, resolvedPath: trimmed, contentType: http.contentType)
        }
        let validated = pdfValidateBytes(http.bodyBytes, reference, http.contentType)
        if (!validated.ok) {
            return validated
        }
        return PdfReferenceLoadResult(
            true,
            reference: reference,
            resolvedPath: trimmed,
            fileName: if (!http.fileName.trimAscii().isEmpty()) { http.fileName.trimAscii() } else { pdfBasename(trimmed) },
            contentType: validated.contentType,
            bytes: http.bodyBytes
        )
    }

    let pathText = pdfResolveLocalPath(trimmed, baseDir, homeDir)
    if (!exists(Path(pathText))) {
        return PdfReferenceLoadResult(false, status: "not_found", message: "PDF file does not exist: ${pathText}", reference: reference, resolvedPath: pathText)
    }
    if (!pdfPathAllowedByRoots(pathText, allowedRoots)) {
        return PdfReferenceLoadResult(false, status: "outside_allowed_roots", message: "PDF file is outside the allowed roots.", reference: reference, resolvedPath: pathText)
    }
    let bytes = try {
        File.readFrom(Path(pathText))
    } catch (e: Exception) {
        return PdfReferenceLoadResult(false, status: "read_error", message: "Failed to read PDF file: ${e.message}", reference: reference, resolvedPath: pathText)
    }
    if (Int64(bytes.size) > effectiveMaxBytes) {
        return PdfReferenceLoadResult(false, status: "too_large", message: "PDF exceeds maxBytes (${bytes.size} > ${effectiveMaxBytes}).", reference: reference, resolvedPath: pathText)
    }
    let validated = pdfValidateBytes(bytes, reference, "application/pdf")
    if (!validated.ok) {
        return PdfReferenceLoadResult(false, status: validated.status, message: validated.message, reference: reference, resolvedPath: pathText, contentType: validated.contentType, bytes: bytes)
    }
    PdfReferenceLoadResult(true, reference: reference, resolvedPath: pathText, fileName: pdfBasename(pathText), contentType: "application/pdf", bytes: bytes)
}

public class PdfExtractedPageImage {
    public let mimeType: String
    public let data: String

    public init(mimeType: String, data: String) {
        this.mimeType = mimeType
        this.data = data
    }
}

public class PdfExtractorBridgeRequest {
    public let inputPath: String
    public let maxPages: Int64
    public let maxPixels: Int64
    public let minTextChars: Int64
    public let pageNumbers: Array<Int64>
    public let helperPath: String
    public let nodeCommand: String

    public init(
        inputPath: String,
        maxPages!: Int64 = PDF_TOOL_DEFAULT_MAX_PAGES,
        maxPixels!: Int64 = PDF_EXTRACTOR_DEFAULT_MAX_PIXELS,
        minTextChars!: Int64 = PDF_EXTRACTOR_DEFAULT_MIN_TEXT_CHARS,
        pageNumbers!: Array<Int64> = [],
        helperPath!: String = "",
        nodeCommand!: String = "node"
    ) {
        this.inputPath = inputPath
        this.maxPages = maxPages
        this.maxPixels = maxPixels
        this.minTextChars = minTextChars
        this.pageNumbers = pageNumbers
        this.helperPath = helperPath
        this.nodeCommand = nodeCommand
    }
}

public class PdfExtractorProcessResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int64, stdout!: String = "", stderr!: String = "", timedOut!: Bool = false) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
    }
}

public class PdfExtractorBridgeResult {
    public let ok: Bool
    public let status: String
    public let message: String
    public let text: String
    public let images: Array<PdfExtractedPageImage>
    public let pageCount: Int64
    public let selectedPages: Array<Int64>
    public let warnings: Array<String>

    public init(
        ok: Bool,
        status!: String = "ok",
        message!: String = "",
        text!: String = "",
        images!: Array<PdfExtractedPageImage> = [],
        pageCount!: Int64 = 0,
        selectedPages!: Array<Int64> = [],
        warnings!: Array<String> = []
    ) {
        this.ok = ok
        this.status = status
        this.message = message
        this.text = text
        this.images = images
        this.pageCount = pageCount
        this.selectedPages = selectedPages
        this.warnings = warnings
    }
}

private var pdfExtractorBridgeRunnerOverride: Option<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult> =
    None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>

public func setPdfExtractorBridgeRunnerForTest(runner: Option<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>): Unit {
    pdfExtractorBridgeRunnerOverride = runner
}

private func pdfDefaultHelperPath(): String {
    CliConfig.cwd.join("tools").join("pdf_extract").join("pdf_extract.mjs").toString()
}

private func pdfJoinPages(pages: Array<Int64>): String {
    let parts = ArrayList<String>()
    for (page in pages) {
        parts.add("${page}")
    }
    String.join(parts.toArray(), delimiter: ",")
}

private func pdfRunExtractorProcess(request: PdfExtractorBridgeRequest, timeoutMs: Int64): PdfExtractorProcessResult {
    match (pdfExtractorBridgeRunnerOverride) {
        case Some(runner) => return runner(request)
        case None => ()
    }
    let helperPath = if (request.helperPath.trimAscii().isEmpty()) { pdfDefaultHelperPath() } else { request.helperPath.trimAscii() }
    let args = ArrayList<String>([
        request.nodeCommand,
        helperPath,
        "--input",
        request.inputPath,
        "--max-pages",
        "${request.maxPages}",
        "--max-pixels",
        "${request.maxPixels}",
        "--min-text-chars",
        "${request.minTextChars}"
    ])
    if (request.pageNumbers.size > 0) {
        args.add("--pages")
        args.add(pdfJoinPages(request.pageNumbers))
    }
    try {
        let (exitCode, stdout, stderr) = ShellUtils.execute(
            args.toArray(),
            timeout: Some(Duration.millisecond * max(timeoutMs, 1)),
            withWrap: false,
            workDir: CliConfig.cwd
        )
        PdfExtractorProcessResult(exitCode, stdout: stdout, stderr: stderr)
    } catch (_: ShellTimeoutException) {
        PdfExtractorProcessResult(-1, timedOut: true)
    }
}

private func pdfInputJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfInputJsonInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asInt().getValue() } catch (_: Exception) {
                try { Int64.parse(v.toJsonString()) } catch (_inner: Exception) { 0 }
            }
        case None => 0
    }
}

private func pdfInputJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func pdfInputJsonStringArray(obj: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    let arr = match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { return [] }
        case None => return []
    }
    for (i in 0..arr.size()) {
        let text = try { arr[i].asString().getValue() } catch (_: Exception) { continue }
        out.add(text)
    }
    out.toArray()
}

private func pdfInputJsonIntArray(obj: JsonObject, key: String): Array<Int64> {
    let out = ArrayList<Int64>()
    let arr = match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { return [] }
        case None => return []
    }
    for (i in 0..arr.size()) {
        let value = try { arr[i].asInt().getValue() } catch (_: Exception) {
            try { Int64.parse(arr[i].toJsonString()) } catch (_inner: Exception) { continue }
        }
        out.add(value)
    }
    out.toArray()
}

private func pdfJsonImages(obj: JsonObject): Array<PdfExtractedPageImage> {
    let out = ArrayList<PdfExtractedPageImage>()
    let arr = match (obj.get("images")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { return [] }
        case None => return []
    }
    for (i in 0..arr.size()) {
        let image = try { arr[i].asObject() } catch (_: Exception) { continue }
        let mimeType = pdfInputJsonString(image, "mimeType")
        let data = pdfInputJsonString(image, "data")
        if (!mimeType.isEmpty() && !data.isEmpty()) {
            out.add(PdfExtractedPageImage(mimeType, data))
        }
    }
    out.toArray()
}

private func pdfExtractorInvalidOutput(message: String): PdfExtractorBridgeResult {
    PdfExtractorBridgeResult(false, status: "extractor_invalid_output", message: message)
}

public func extractPdfWithNodeBridge(
    inputPath: String,
    maxPages!: Int64 = PDF_TOOL_DEFAULT_MAX_PAGES,
    maxPixels!: Int64 = PDF_EXTRACTOR_DEFAULT_MAX_PIXELS,
    minTextChars!: Int64 = PDF_EXTRACTOR_DEFAULT_MIN_TEXT_CHARS,
    pageNumbers!: Array<Int64> = [],
    timeoutMs!: Int64 = PDF_EXTRACTOR_DEFAULT_TIMEOUT_MS,
    maxOutputBytes!: Int64 = PDF_EXTRACTOR_DEFAULT_MAX_OUTPUT_BYTES,
    helperPath!: String = "",
    nodeCommand!: String = "node"
): PdfExtractorBridgeResult {
    let trimmedPath = inputPath.trimAscii()
    if (trimmedPath.isEmpty()) {
        return PdfExtractorBridgeResult(false, status: "invalid_request", message: "PDF input path is required.")
    }
    let request = PdfExtractorBridgeRequest(
        trimmedPath,
        maxPages: maxPages,
        maxPixels: maxPixels,
        minTextChars: minTextChars,
        pageNumbers: pageNumbers,
        helperPath: helperPath,
        nodeCommand: nodeCommand
    )
    let process = pdfRunExtractorProcess(request, timeoutMs)
    if (process.timedOut) {
        return PdfExtractorBridgeResult(false, status: "extractor_timeout", message: "PDF extractor timed out.")
    }
    if (Int64(process.stdout.size) > maxOutputBytes) {
        return PdfExtractorBridgeResult(false, status: "extractor_output_too_large", message: "PDF extractor output exceeded maxOutputBytes.")
    }
    if (process.exitCode != 0) {
        let stderr = process.stderr.trimAscii()
        return PdfExtractorBridgeResult(false, status: "extractor_failed", message: if (stderr.isEmpty()) { "PDF extractor failed." } else { stderr })
    }
    let raw = process.stdout.trimAscii()
    if (raw.isEmpty()) {
        return pdfExtractorInvalidOutput("PDF extractor returned empty output.")
    }
    let obj = try {
        JsonValue.fromStr(raw).asObject()
    } catch (_: Exception) {
        return pdfExtractorInvalidOutput("PDF extractor returned invalid JSON.")
    }
    let ok = pdfInputJsonBool(obj, "ok", true)
    let status = pdfInputJsonString(obj, "status")
    let message = pdfInputJsonString(obj, "message")
    PdfExtractorBridgeResult(
        ok,
        status: if (status.isEmpty()) { if (ok) { "ok" } else { "extractor_failed" } } else { status },
        message: message,
        text: pdfInputJsonString(obj, "text"),
        images: pdfJsonImages(obj),
        pageCount: pdfInputJsonInt(obj, "pageCount"),
        selectedPages: pdfInputJsonIntArray(obj, "selectedPages"),
        warnings: pdfInputJsonStringArray(obj, "warnings")
    )
}
