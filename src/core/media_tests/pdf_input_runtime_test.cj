package metis.core.media_tests

import metis.core.*

import std.collection.ArrayList
import std.fs.{Directory, File, Path, remove}
import std.time.*
import std.unittest.*

private func pdfInputTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-pdf-input-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func pdfInputTestBytes(): Array<Byte> {
    "%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".toArray()
}

private func pdfInputTestExpectThrowsContains(run: () -> Unit, expected: String): Unit {
    var thrown = false
    try {
        run()
    } catch (e: Exception) {
        thrown = true
        @Expect(e.message.contains(expected), true)
    }
    @Expect(thrown, true)
}

@Test
public class PdfInputRuntimeTest {
    @TestCase
    public func normalizePdfToolInputsMergesTrimsDedupesAndDefaultsPrompt(): Unit {
        let result = normalizePdfToolInputs(
            Some<String>("/tmp/a.pdf"),
            Some<Array<String>>([" /tmp/a.pdf ", " /tmp/b.pdf ", " "]),
            prompt: Some<String>("")
        )

        @Expect(result.ok, true)
        @Expect(result.pdfs.size, 2)
        @Expect(result.pdfs[0], "/tmp/a.pdf")
        @Expect(result.pdfs[1], "/tmp/b.pdf")
        @Expect(result.prompt, PDF_TOOL_DEFAULT_PROMPT)
    }

    @TestCase
    public func normalizePdfToolInputsRejectsMissingAndTooManyPdfs(): Unit {
        let missing = normalizePdfToolInputs(None<String>, None<Array<String>>)
        @Expect(missing.ok, false)
        @Expect(missing.status, "missing_pdf")
        @Expect(missing.message.contains("pdf required"), true)

        let many = ArrayList<String>()
        for (i in 0..11) {
            many.add("/tmp/${i}.pdf")
        }
        let tooMany = normalizePdfToolInputs(None<String>, Some<Array<String>>(many.toArray()))
        @Expect(tooMany.ok, false)
        @Expect(tooMany.status, "too_many_pdfs")
        @Expect(tooMany.count, 11)
        @Expect(tooMany.max, 10)
    }

    @TestCase
    public func parsePdfPageRangeSupportsCombinationsDedupeSortAndClip(): Unit {
        let combo = parsePdfPageRange("1,3,7-9", 20)
        @Expect(combo.size, 5)
        @Expect(combo[0], 1)
        @Expect(combo[1], 3)
        @Expect(combo[2], 7)
        @Expect(combo[3], 8)
        @Expect(combo[4], 9)

        let deduped = parsePdfPageRange("3,1,3", 20)
        @Expect(deduped.size, 2)
        @Expect(deduped[0], 1)
        @Expect(deduped[1], 3)

        let clipped = parsePdfPageRange("1-100", 5)
        @Expect(clipped.size, 5)
        @Expect(clipped[0], 1)
        @Expect(clipped[4], 5)
    }

    @TestCase
    public func parsePdfPageRangeReportsInvalidPagesClearly(): Unit {
        pdfInputTestExpectThrowsContains({ => let _ = parsePdfPageRange("0", 20) }, "Invalid page")
        pdfInputTestExpectThrowsContains({ => let _ = parsePdfPageRange("5-3", 20) }, "Invalid page")
        pdfInputTestExpectThrowsContains({ => let _ = parsePdfPageRange("abc", 20) }, "Invalid page")
    }

    @TestCase
    public func pdfReferenceLoaderExpandsHomeAndLoadsFileUrl(): Unit {
        let root = pdfInputTestTempRoot("loader-home")
        try {
            let home = root.join("home")
            Directory.create(home, recursive: true)
            let homePdf = home.join("fixture.pdf")
            File.writeTo(homePdf, pdfInputTestBytes())
            let homeResult = loadPdfReference("~/fixture.pdf", maxBytes: 4096, baseDir: root.toString(), homeDir: home.toString())
            @Expect(homeResult.ok, true)
            @Expect(homeResult.resolvedPath, homePdf.toString())
            @Expect(homeResult.bytes.size > 5, true)

            let filePdf = root.join("file-url.pdf")
            File.writeTo(filePdf, pdfInputTestBytes())
            let fileResult = loadPdfReference("file://${filePdf.toString()}", maxBytes: 4096, baseDir: root.toString(), homeDir: home.toString())
            @Expect(fileResult.ok, true)
            @Expect(fileResult.resolvedPath, filePdf.toString())
            @Expect(fileResult.fileName, "file-url.pdf")
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func pdfReferenceLoaderRejectsUnsupportedSchemeWithoutHttpRunner(): Unit {
        setPdfReferenceHttpRunnerForTest(Some({ _url: String, _maxBytes: Int64, _timeoutMs: Int64 =>
            throw Exception("HTTP runner should not be called for unsupported PDF schemes")
        }))
        try {
            let result = loadPdfReference("ftp://example.invalid/a.pdf", maxBytes: 4096)
            @Expect(result.ok, false)
            @Expect(result.status, "unsupported_pdf_reference")
        } finally {
            setPdfReferenceHttpRunnerForTest(None<(String, Int64, Int64) -> PdfReferenceHttpResult>)
        }
    }

    @TestCase
    public func pdfReferenceLoaderUsesFakeHttpAndEnforcesMaxBytes(): Unit {
        setPdfReferenceHttpRunnerForTest(Some({ url: String, maxBytes: Int64, _timeoutMs: Int64 =>
            @Expect(url, "https://example.invalid/doc.pdf")
            @Expect(maxBytes, 5)
            PdfReferenceHttpResult(200, bodyBytes: pdfInputTestBytes(), contentType: "application/pdf")
        }))
        try {
            let result = loadPdfReference("https://example.invalid/doc.pdf", maxBytes: 5)
            @Expect(result.ok, false)
            @Expect(result.status, "too_large")
        } finally {
            setPdfReferenceHttpRunnerForTest(None<(String, Int64, Int64) -> PdfReferenceHttpResult>)
        }
    }

    @TestCase
    public func pdfReferenceLoaderRejectsSandboxRemoteAndNonPdfContent(): Unit {
        setPdfReferenceHttpRunnerForTest(Some({ _url: String, _maxBytes: Int64, _timeoutMs: Int64 =>
            throw Exception("HTTP runner should not be called for sandboxed remote PDFs")
        }))
        try {
            let sandboxed = loadPdfReference("https://example.invalid/doc.pdf", sandboxed: true)
            @Expect(sandboxed.ok, false)
            @Expect(sandboxed.status, "sandbox_remote_disallowed")
            @Expect(sandboxed.message, "Sandboxed PDF tool does not allow remote URLs.")
        } finally {
            setPdfReferenceHttpRunnerForTest(None<(String, Int64, Int64) -> PdfReferenceHttpResult>)
        }

        let root = pdfInputTestTempRoot("loader-not-pdf")
        try {
            let textFile = root.join("not.pdf")
            File.writeTo(textFile, "not a pdf".toArray())
            let result = loadPdfReference(textFile.toString(), maxBytes: 4096)
            @Expect(result.ok, false)
            @Expect(result.status, "not_pdf")
            @Expect(result.message.contains("Expected PDF"), true)
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func pdfExtractorBridgeParsesFakeJsonOutput(): Unit {
        setPdfExtractorBridgeRunnerForTest(Some({ request: PdfExtractorBridgeRequest =>
            @Expect(request.inputPath, "/tmp/fake.pdf")
            @Expect(request.pageNumbers.size, 2)
            PdfExtractorProcessResult(
                0,
                stdout: "{\"ok\":true,\"status\":\"ok\",\"text\":\"hello pdf\",\"pageCount\":2,\"selectedPages\":[1,2],\"images\":[{\"mimeType\":\"image/png\",\"data\":\"QUJD\"}],\"warnings\":[\"canvas missing\"]}"
            )
        }))
        try {
            let result = extractPdfWithNodeBridge("/tmp/fake.pdf", pageNumbers: [1, 2], timeoutMs: 10)
            @Expect(result.ok, true)
            @Expect(result.status, "ok")
            @Expect(result.text, "hello pdf")
            @Expect(result.pageCount, 2)
            @Expect(result.selectedPages[1], 2)
            @Expect(result.images.size, 1)
            @Expect(result.images[0].mimeType, "image/png")
            @Expect(result.warnings[0], "canvas missing")
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
        }
    }

    @TestCase
    public func pdfExtractorBridgeReportsTimeoutAndInvalidOutput(): Unit {
        setPdfExtractorBridgeRunnerForTest(Some({ _request: PdfExtractorBridgeRequest =>
            PdfExtractorProcessResult(-1, timedOut: true)
        }))
        try {
            let timedOut = extractPdfWithNodeBridge("/tmp/fake.pdf", timeoutMs: 1)
            @Expect(timedOut.ok, false)
            @Expect(timedOut.status, "extractor_timeout")
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
        }

        setPdfExtractorBridgeRunnerForTest(Some({ _request: PdfExtractorBridgeRequest =>
            PdfExtractorProcessResult(0, stdout: "not-json")
        }))
        try {
            let invalid = extractPdfWithNodeBridge("/tmp/fake.pdf", timeoutMs: 10)
            @Expect(invalid.ok, false)
            @Expect(invalid.status, "extractor_invalid_output")
        } finally {
            setPdfExtractorBridgeRunnerForTest(None<(PdfExtractorBridgeRequest) -> PdfExtractorProcessResult>)
        }
    }
}
