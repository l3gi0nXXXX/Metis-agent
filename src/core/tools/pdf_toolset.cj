package metis.core.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.core.gatewayPdfAnalyze
import metis.io.PrintUtils

import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonFloat, JsonObject, JsonString}

private let PDF_TOOL_DEFAULT_PROMPT = "Analyze this PDF document."
private let PDF_TOOL_MAX_INPUTS: Int64 = 10

private func pdfToolAddInput(inputs: ArrayList<String>, seen: ArrayList<String>, raw: String): Unit {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty() || seen.contains(trimmed)) {
        return
    }
    seen.add(trimmed)
    inputs.add(trimmed)
}

private func pdfToolIsAsciiLetter(b: UInt8): Bool {
    (b >= 65u8 && b <= 90u8) || (b >= 97u8 && b <= 122u8)
}

private func pdfToolIsAsciiDigit(b: UInt8): Bool {
    b >= 48u8 && b <= 57u8
}

private func pdfToolLooksLikeWindowsDrive(path: String): Bool {
    let bytes = path.toArray()
    if (bytes.size < 3) {
        return false
    }
    let first = UInt8(bytes[0])
    let second = UInt8(bytes[1])
    let third = UInt8(bytes[2])
    pdfToolIsAsciiLetter(first) && second == 58u8 && (third == 47u8 || third == 92u8)
}

private func pdfToolLooksLikeSchemeName(text: String): Bool {
    let bytes = text.toArray()
    if (bytes.isEmpty()) {
        return false
    }
    if (!pdfToolIsAsciiLetter(UInt8(bytes[0]))) {
        return false
    }
    for (idx in 1..bytes.size) {
        let b = UInt8(bytes[idx])
        if (!(pdfToolIsAsciiLetter(b) || pdfToolIsAsciiDigit(b) || b == 43u8 || b == 45u8 || b == 46u8)) {
            return false
        }
    }
    true
}

private func pdfToolHasUnsupportedScheme(raw: String): Bool {
    let trimmed = raw.trimAscii()
    let lower = trimmed.toAsciiLower()
    if (lower.startsWith("http://") || lower.startsWith("https://") || lower.startsWith("file://")) {
        return false
    }
    if (pdfToolLooksLikeWindowsDrive(trimmed)) {
        return false
    }
    match (lower.indexOf(b':')) {
        case Some(colon) =>
            match (lower.indexOf(b'/')) {
                case Some(slash) =>
                    if (slash < colon) {
                        return false
                    }
                case None => ()
            }
            let scheme = lower[0..colon]
            pdfToolLooksLikeSchemeName(scheme)
        case None => false
    }
}

private func pdfToolJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func pdfToolJsonBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func pdfToolJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func pdfToolJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(value) =>
            try { value.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func pdfToolFirstDetailString(result: JsonObject, details: JsonObject, key: String): String {
    let direct = pdfToolJsonString(result, key)
    if (!direct.isEmpty()) {
        return direct
    }
    pdfToolJsonString(details, key)
}

private func pdfToolAppendDetail(lines: ArrayList<String>, label: String, value: String): Unit {
    let clean = value.trimAscii()
    if (!clean.isEmpty()) {
        lines.add("- ${label}: ${clean}")
    }
}

private func pdfToolFormatResult(result: JsonObject): String {
    let ok = pdfToolJsonBool(result, "ok", false)
    let status = pdfToolJsonString(result, "status")
    let details = pdfToolJsonObject(result, "details")
    let text = pdfToolFirstDetailString(result, details, "text")
    let message = if (!text.isEmpty()) {
        text
    } else {
        let m = pdfToolFirstDetailString(result, details, "message")
        if (!m.isEmpty()) {
            m
        } else {
            pdfToolFirstDetailString(result, details, "error")
        }
    }

    if (!ok) {
        if (!message.isEmpty()) {
            return "PDF analysis failed${if (status.isEmpty()) { "" } else { " (${status})" }}: ${message}"
        }
        return "PDF analysis failed${if (status.isEmpty()) { "" } else { " (${status})" }}."
    }

    let lines = ArrayList<String>()
    lines.add(if (message.isEmpty()) { "PDF analysis completed." } else { message })
    let detailLines = ArrayList<String>()
    pdfToolAppendDetail(detailLines, "model", pdfToolFirstDetailString(result, details, "model"))
    pdfToolAppendDetail(detailLines, "provider", pdfToolFirstDetailString(result, details, "provider"))
    match (result.get("native")) {
        case Some(_) => pdfToolAppendDetail(detailLines, "native", "${pdfToolJsonBool(result, "native", false)}")
        case None =>
            match (details.get("native")) {
                case Some(_) => pdfToolAppendDetail(detailLines, "native", "${pdfToolJsonBool(details, "native", false)}")
                case None => ()
            }
    }
    pdfToolAppendDetail(detailLines, "pdf", pdfToolFirstDetailString(result, details, "pdf"))
    let pdfs = pdfToolJsonArray(details, "pdfs")
    if (pdfs.size() > 0) {
        detailLines.add("- pdfs: ${pdfs.size()} document(s)")
    }
    if (!detailLines.isEmpty()) {
        lines.add("")
        lines.add("PDF details:")
        for (line in detailLines) {
            lines.add(line)
        }
    }
    String.join(lines.toArray(), delimiter: "\n")
}

@toolset
public class PdfToolset {
    public func debugPdfForTest(
        pdf: Option<String>,
        pdfs: Option<Array<String>>,
        prompt: Option<String>,
        pages: Option<String>,
        model: Option<String>,
        maxBytesMb: Option<Float64>
    ): String {
        this.runPdf(pdf, pdfs, prompt, pages, model, maxBytesMb)
    }

    @tool[
        description: "Analyze one or more PDF documents using the configured PDF runtime. Supports a single local path or URL via pdf, multiple PDFs via pdfs (max 10), optional prompt, pages, model override, and per-PDF maxBytesMb. Prefer this for reading, summarizing, comparing, or extracting PDF content.",
        parameters: {
            pdf: "Single PDF path or URL. Supports local path, file://, http://, and https:// references.",
            pdfs: "Optional list of PDF paths or URLs. Combined with pdf, deduplicated, maximum 10.",
            prompt: "Optional analysis prompt. Defaults to Analyze this PDF document.",
            pages: "Optional page range such as 1-5 or 1,3,7-9.",
            model: "Optional provider/model override for this PDF call.",
            maxBytesMb: "Optional per-PDF size cap in MiB."
        }
    ]
    public func pdf(
        pdf: Option<String>,
        pdfs: Option<Array<String>>,
        prompt: Option<String>,
        pages: Option<String>,
        model: Option<String>,
        maxBytesMb: Option<Float64>
    ): String {
        this.runPdf(pdf, pdfs, prompt, pages, model, maxBytesMb)
    }

    private func runPdf(
        pdf: Option<String>,
        pdfs: Option<Array<String>>,
        prompt: Option<String>,
        pages: Option<String>,
        model: Option<String>,
        maxBytesMb: Option<Float64>
    ): String {
        PrintUtils.printTool("pdf", shortMessage: "PDF")
        let inputs = ArrayList<String>()
        let seen = ArrayList<String>()
        match (pdf) {
            case Some(value) => pdfToolAddInput(inputs, seen, value)
            case None => ()
        }
        match (pdfs) {
            case Some(values) =>
                for (value in values) {
                    pdfToolAddInput(inputs, seen, value)
                }
            case None => ()
        }

        if (inputs.isEmpty()) {
            let out = "PDF input required: provide a path or URL to a PDF document."
            PrintUtils.printToolResult(out)
            return out
        }
        if (inputs.size > PDF_TOOL_MAX_INPUTS) {
            let out = "Too many PDFs: ${inputs.size} provided, maximum is ${PDF_TOOL_MAX_INPUTS}. Please reduce the number."
            PrintUtils.printToolResult(out)
            return out
        }
        for (input in inputs) {
            if (pdfToolHasUnsupportedScheme(input)) {
                let out = "Unsupported PDF reference: ${input}. Use a file path, file:// URL, or http(s) URL."
                PrintUtils.printToolResult(out)
                return out
            }
        }

        let request = JsonObject()
        request.put("tool", JsonString("pdf"))
        let arr = JsonArray([])
        for (input in inputs) {
            arr.add(JsonString(input))
        }
        request.put("pdfs", arr)
        if (inputs.size == 1) {
            request.put("pdf", JsonString(inputs[0]))
        }
        let promptText = match (prompt) {
            case Some(value) =>
                let clean = value.trimAscii()
                if (clean.isEmpty()) { PDF_TOOL_DEFAULT_PROMPT } else { clean }
            case None => PDF_TOOL_DEFAULT_PROMPT
        }
        request.put("prompt", JsonString(promptText))
        match (pages) {
            case Some(value) =>
                let clean = value.trimAscii()
                if (!clean.isEmpty()) { request.put("pages", JsonString(clean)) }
            case None => ()
        }
        match (model) {
            case Some(value) =>
                let clean = value.trimAscii()
                if (!clean.isEmpty()) { request.put("model", JsonString(clean)) }
            case None => ()
        }
        match (maxBytesMb) {
            case Some(value) =>
                if (value > 0.0) { request.put("maxBytesMb", JsonFloat(value)) }
            case None => ()
        }

        let result = gatewayPdfAnalyze(request)
        let out = pdfToolFormatResult(result)
        PrintUtils.printToolResult(out)
        out
    }
}
