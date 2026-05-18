package metis.core.tools

import metis.core.setGatewayPdfAnalyzeRunnerForTest

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

@Test
public class PdfToolsetTest {
    @TestCase
    public func pdfToolNormalizesInputsAndCallsRuntimeBoundary(): Unit {
        setGatewayPdfAnalyzeRunnerForTest(Some({ request: JsonObject =>
            let pdfs = request.get("pdfs").getOrThrow().asArray()
            let prompt = request.get("prompt").getOrThrow().asString().getValue()
            let pages = request.get("pages").getOrThrow().asString().getValue()
            let model = request.get("model").getOrThrow().asString().getValue()
            let out = JsonObject()
            out.put("ok", JsonBool(true))
            out.put("status", JsonString("ok"))
            out.put("text", JsonString("pdf summary: pdfs=${pdfs.size()} prompt=${prompt} pages=${pages} model=${model}"))
            out.put("model", JsonString("fake:pdf"))
            out.put("provider", JsonString("fake"))
            out.put("native", JsonBool(false))
            out.put("details", request)
            out
        }))
        try {
            let out = PdfToolset().debugPdfForTest(
                Some("/tmp/a.pdf"),
                Some(["/tmp/a.pdf", "/tmp/b.pdf", " "]),
                Some("Summarize"),
                Some("1-2"),
                Some("fake/pdf"),
                Some(4.0)
            )

            @Expect(out.contains("pdf summary"), true)
            @Expect(out.contains("pdfs=2"), true)
            @Expect(out.contains("prompt=Summarize"), true)
            @Expect(out.contains("pages=1-2"), true)
            @Expect(out.contains("model=fake/pdf"), true)
            @Expect(out.contains("- pdfs: 2 document(s)"), true)
            @Expect(out.contains("\"ok\""), false)
        } finally {
            setGatewayPdfAnalyzeRunnerForTest(None<(JsonObject) -> JsonObject>)
        }
    }

    @TestCase
    public func pdfToolReturnsReadableErrorsWithoutRuntimeCalls(): Unit {
        setGatewayPdfAnalyzeRunnerForTest(Some({ _request: JsonObject =>
            let out = JsonObject()
            out.put("ok", JsonBool(false))
            out.put("status", JsonString("called"))
            out.put("message", JsonString("runtime should not be called"))
            out
        }))
        try {
            let missing = PdfToolset().debugPdfForTest(None<String>, None<Array<String>>, None<String>, None<String>, None<String>, None<Float64>)
            @Expect(missing.contains("PDF input required"), true)
            @Expect(missing.contains("{"), false)
            @Expect(missing.contains("runtime should not be called"), false)

            let tooMany = PdfToolset().debugPdfForTest(
                None<String>,
                Some(["/tmp/0.pdf", "/tmp/1.pdf", "/tmp/2.pdf", "/tmp/3.pdf", "/tmp/4.pdf", "/tmp/5.pdf", "/tmp/6.pdf", "/tmp/7.pdf", "/tmp/8.pdf", "/tmp/9.pdf", "/tmp/10.pdf"]),
                None<String>,
                None<String>,
                None<String>,
                None<Float64>
            )
            @Expect(tooMany.contains("Too many PDFs"), true)
            @Expect(tooMany.contains("\"ok\""), false)
            @Expect(tooMany.contains("runtime should not be called"), false)

            let unsupported = PdfToolset().debugPdfForTest(Some("ftp://example.com/a.pdf"), None<Array<String>>, None<String>, None<String>, None<String>, None<Float64>)
            @Expect(unsupported.contains("Unsupported PDF reference"), true)
            @Expect(unsupported.contains("\"error\""), false)
            @Expect(unsupported.contains("runtime should not be called"), false)
        } finally {
            setGatewayPdfAnalyzeRunnerForTest(None<(JsonObject) -> JsonObject>)
        }
    }
}
