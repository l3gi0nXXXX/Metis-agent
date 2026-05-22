package metis.gateway.channels.feishu

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private class FeishuSidecarApiClientFakeRunner <: FeishuSidecarRequestRunner {
    public let requests = ArrayList<JsonObject>()
    private let responses = ArrayList<JsonObject>()
    private var cursor: Int64 = 0

    public init() {}

    public func enqueue(response: JsonObject): Unit {
        this.responses.add(response)
    }

    public func run(request: JsonObject): JsonObject {
        this.requests.add(request)
        if (this.cursor >= this.responses.size) {
            return feishuSidecarTestResult(false, status: "api_error", error: "fake sidecar response not queued")
        }
        let response = this.responses[this.cursor]
        this.cursor++
        response
    }

    public func operation(index: Int64): String {
        sidecarTestString(this.requests[index], "operation")
    }

    public func params(index: Int64): JsonObject {
        sidecarTestObject(this.requests[index], "params")
    }
}

private class FeishuSidecarApiProcessFakeProcess <: FeishuSidecarProtocolProcess {
    public let stdoutLines = ArrayList<String>()
    public let stdinLines = ArrayList<String>()
    public var alive: Bool = true
    public var terminated: Bool = false

    public init(stdout!: Array<String> = []) {
        for (line in stdout) {
            this.stdoutLines.add(line)
        }
    }

    public func pid(): Int64 {
        1777
    }

    public func writeLine(line: String): Unit {
        this.stdinLines.add(line)
    }

    public func readLine(_timeoutMs: Int64): Option<String> {
        if (this.stdoutLines.isEmpty()) {
            return None<String>
        }
        let line = this.stdoutLines[0]
        this.stdoutLines.remove(at: 0)
        Some(line)
    }

    public func isAlive(): Bool {
        this.alive
    }

    public func wait(_timeoutMs: Int64): Option<Int64> {
        this.alive = false
        Some(0)
    }

    public func terminate(_force: Bool): Unit {
        this.terminated = true
        this.alive = false
    }

    public func stdoutSummary(): String {
        String.join(this.stdinLines.toArray(), delimiter: "\n")
    }

    public func stderrSummary(): String {
        ""
    }
}

private class FeishuSidecarApiProcessFakeRunner <: FeishuSidecarProtocolRunner {
    public let process: FeishuSidecarApiProcessFakeProcess
    public var launch: FeishuSidecarLaunchSpec = FeishuSidecarLaunchSpec(command: "", args: [])
    public var failWith: String = ""

    public init(process: FeishuSidecarApiProcessFakeProcess) {
        this.process = process
    }

    public func start(spec: FeishuSidecarLaunchSpec): FeishuSidecarProtocolStartResult {
        this.launch = spec
        if (!this.failWith.trimAscii().isEmpty()) {
            return FeishuSidecarProtocolStartResult.Failed(this.failWith)
        }
        FeishuSidecarProtocolStartResult.Started(this.process)
    }
}

private func feishuSidecarTestResult(
    ok: Bool,
    status!: String = "",
    messageId!: String = "",
    mediaKey!: String = "",
    error!: String = "",
    contentType!: String = "",
    fileName!: String = "",
    bytesBase64!: String = ""
): JsonObject {
    let out = JsonObject()
    out.put("ok", JsonBool(ok))
    if (!status.trimAscii().isEmpty()) {
        out.put("status", JsonString(status.trimAscii()))
    }
    if (!messageId.trimAscii().isEmpty()) {
        out.put("messageId", JsonString(messageId.trimAscii()))
    }
    if (!mediaKey.trimAscii().isEmpty()) {
        out.put("mediaKey", JsonString(mediaKey.trimAscii()))
    }
    if (!error.trimAscii().isEmpty()) {
        out.put("error", JsonString(error.trimAscii()))
    }
    if (!contentType.trimAscii().isEmpty()) {
        out.put("contentType", JsonString(contentType.trimAscii()))
    }
    if (!fileName.trimAscii().isEmpty()) {
        out.put("fileName", JsonString(fileName.trimAscii()))
    }
    if (!bytesBase64.trimAscii().isEmpty()) {
        out.put("bytesBase64", JsonString(bytesBase64.trimAscii()))
    }
    out
}

private func sidecarTestMessage(messageId: String, messageType: String, content: String): JsonObject {
    let out = feishuSidecarTestResult(true, status: "ok", messageId: messageId)
    out.put("messageType", JsonString(messageType))
    out.put("content", JsonString(content))
    out.put("raw", JsonString("{\"redacted\":true}"))
    out
}

private func sidecarTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func sidecarTestObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_e: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func sidecarTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_e: Exception) { false }
        case None => false
    }
}

@Test
public class FeishuSidecarApiClientTest {
    @TestCase
    public func processRunnerInitializesSidecarAndMapsApiFramesWithoutSecretsInArgv(): Unit {
        let process = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"sendResult\",\"requestId\":\"metis-sidecar-api\",\"ok\":true,\"mediaKey\":\"img_uploaded\",\"contentBase64\":\"cmVzb3VyY2U=\",\"contentType\":\"image/png\"}"
        ])
        let protocol = FeishuSidecarApiProcessFakeRunner(process)
        let runner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(
                accountId: "tenant-a",
                appId: "cli_app",
                appSecret: "secret-app",
                domain: "https://open.feishu.cn",
                verificationToken: "secret-verification",
                encryptKey: "secret-encrypt"
            ),
            runner: protocol,
            options: FeishuSidecarRequestRunnerOptions(
                command: "node",
                args: ["scripts/feishu-sidecar.mjs"],
                readyTimeoutMs: 1,
                requestTimeoutMs: 1,
                readTimeoutMs: 1,
                stopTimeoutMs: 1
            )
        )
        let params = JsonObject()
        params.put("mediaType", JsonString("image"))
        params.put("bytesBase64", JsonString("ZmFrZQ=="))
        params.put("fileName", JsonString("a.png"))
        let request = JsonObject()
        request.put("operation", JsonString("media.upload"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("params", params)

        let result = runner.run(request)

        @Expect(sidecarTestBool(result, "ok"), true)
        @Expect(sidecarTestString(result, "mediaKey"), "img_uploaded")
        @Expect(sidecarTestString(result, "bytesBase64"), "cmVzb3VyY2U=")
        @Expect(protocol.launch.command, "node")
        @Expect(String.join(protocol.launch.args, delimiter: " ").contains("secret-app"), false)
        @Expect(process.stdinLines[0].contains("\"type\":\"init\""), true)
        @Expect(process.stdinLines[0].contains("secret-app"), true)
        @Expect(process.stdinLines[1].contains("\"type\":\"request\""), true)
        @Expect(process.stdinLines[1].contains("\"action\":\"uploadMedia\""), true)
        @Expect(process.stdinLines[1].contains("\"contentBase64\":\"ZmFrZQ==\""), true)
        @Expect(process.stdinLines[2].contains("\"type\":\"close\""), true)
    }

    @TestCase
    public func processRunnerCarriesSameRuntimeRootWorkingDirectoryAndEnvAsTransport(): Unit {
        let runtimeRoot = "/tmp/metis-sidecar-runtime"
        let process = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"sendResult\",\"requestId\":\"metis-sidecar-api\",\"ok\":true,\"messageId\":\"om_sent\"}"
        ])
        let protocol = FeishuSidecarApiProcessFakeRunner(process)
        let runner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: protocol,
            options: FeishuSidecarRequestRunnerOptions(
                command: "node",
                args: ["scripts/feishu-sidecar.mjs"],
                runtimeRoot: runtimeRoot,
                workingDirectory: "/tmp/metis",
                env: [("METIS_FEISHU_SIDECAR_RUNTIME_ROOT", runtimeRoot)],
                readyTimeoutMs: 1,
                requestTimeoutMs: 1,
                readTimeoutMs: 1,
                stopTimeoutMs: 1
            )
        )
        let request = JsonObject()
        request.put("operation", JsonString("message.create"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("params", JsonObject())

        let result = runner.run(request)

        @Expect(sidecarTestBool(result, "ok"), true)
        @Expect(protocol.launch.runtimeRoot, runtimeRoot)
        @Expect(protocol.launch.workingDirectory.getOrThrow(), "/tmp/metis")
        @Expect(protocol.launch.env.size, 1)
        @Expect(protocol.launch.env[0][0], "METIS_FEISHU_SIDECAR_RUNTIME_ROOT")
        @Expect(protocol.launch.env[0][1], runtimeRoot)
        @Expect(process.stdinLines[0].contains("\"runtimeRoot\":\"${runtimeRoot}\""), true)
        @Expect(String.join(protocol.launch.args, delimiter: " ").contains(runtimeRoot), false)
        @Expect(String.join(protocol.launch.args, delimiter: " ").contains("secret-app"), false)
    }

    @TestCase
    public func processRunnerMissingDependencyReturnsStructuredFailure(): Unit {
        let process = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"error\",\"phase\":\"dependency.preflight\",\"status\":\"missing_dependency\",\"message\":\"missing @larksuiteoapi/node-sdk under /tmp/metis-sidecar-runtime appSecret=secret-app\"}"
        ])
        let protocol = FeishuSidecarApiProcessFakeRunner(process)
        let runner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: protocol,
            options: FeishuSidecarRequestRunnerOptions(
                runtimeRoot: "/tmp/metis-sidecar-runtime",
                readyTimeoutMs: 1,
                requestTimeoutMs: 1,
                readTimeoutMs: 1,
                stopTimeoutMs: 1
            )
        )
        let request = JsonObject()
        request.put("operation", JsonString("message.create"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("params", JsonObject())

        let result = runner.run(request)

        @Expect(sidecarTestBool(result, "ok"), false)
        @Expect(sidecarTestString(result, "status"), "missing_dependency")
        @Expect(sidecarTestString(result, "error").contains("@larksuiteoapi/node-sdk"), true)
        @Expect(sidecarTestString(result, "error").contains("/tmp/metis-sidecar-runtime"), true)
        @Expect(sidecarTestString(result, "error").contains("secret-app"), false)
    }

    @TestCase
    public func processRunnerLaunchFailureReturnsStructuredFailureWithOutputSummaries(): Unit {
        let process = FeishuSidecarApiProcessFakeProcess()
        let protocol = FeishuSidecarApiProcessFakeRunner(process)
        protocol.failWith = "launch_failed: Cannot find module @larksuiteoapi/node-sdk stdout=preflight stderr=missing package"
        let runner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: protocol,
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let request = JsonObject()
        request.put("operation", JsonString("message.create"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("params", JsonObject())

        let result = runner.run(request)

        @Expect(sidecarTestBool(result, "ok"), false)
        @Expect(sidecarTestString(result, "status"), "launch_failed")
        @Expect(sidecarTestString(result, "error").contains("missing package"), true)
    }

    @TestCase
    public func processRunnerMapsResourceDownloadToImageOrMessageResourceActions(): Unit {
        let imageProcess = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"sendResult\",\"requestId\":\"metis-sidecar-api\",\"ok\":true,\"contentBase64\":\"aW1hZ2U=\",\"contentType\":\"image/png\",\"fileName\":\"a.png\",\"size\":5}"
        ])
        let imageProtocol = FeishuSidecarApiProcessFakeRunner(imageProcess)
        let imageRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: imageProtocol,
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let imageParams = JsonObject()
        imageParams.put("messageId", JsonString("om_1"))
        imageParams.put("fileKey", JsonString("img_1"))
        imageParams.put("resourceType", JsonString("image"))
        let imageRequest = JsonObject()
        imageRequest.put("operation", JsonString("resource.download"))
        imageRequest.put("accountId", JsonString("tenant-a"))
        imageRequest.put("params", imageParams)

        let imageResult = imageRunner.run(imageRequest)

        @Expect(sidecarTestBool(imageResult, "ok"), true)
        @Expect(sidecarTestString(imageResult, "bytesBase64"), "aW1hZ2U=")
        @Expect(imageProcess.stdinLines[1].contains("\"action\":\"downloadImage\""), true)
        @Expect(imageProcess.stdinLines[1].contains("\"messageId\":\"om_1\""), true)
        @Expect(imageProcess.stdinLines[1].contains("\"fileKey\":\"img_1\""), true)
        @Expect(imageProcess.stdinLines[1].contains("\"resourceType\":\"image\""), true)
        @Expect(imageProcess.stdinLines[1].contains("\"imageKey\":\"img_1\""), true)

        let fileProcess = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"sendResult\",\"requestId\":\"metis-sidecar-api\",\"ok\":true,\"bytesBase64\":\"ZmlsZQ==\",\"contentType\":\"application/octet-stream\",\"fileName\":\"a.bin\",\"size\":4}"
        ])
        let fileProtocol = FeishuSidecarApiProcessFakeRunner(fileProcess)
        let fileRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: fileProtocol,
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let fileParams = JsonObject()
        fileParams.put("messageId", JsonString("om_1"))
        fileParams.put("fileKey", JsonString("file_1"))
        fileParams.put("resourceType", JsonString("file"))
        let fileRequest = JsonObject()
        fileRequest.put("operation", JsonString("resource.download"))
        fileRequest.put("accountId", JsonString("tenant-a"))
        fileRequest.put("params", fileParams)

        let fileResult = fileRunner.run(fileRequest)

        @Expect(sidecarTestBool(fileResult, "ok"), true)
        @Expect(sidecarTestString(fileResult, "bytesBase64"), "ZmlsZQ==")
        @Expect(fileProcess.stdinLines[1].contains("\"action\":\"downloadResource\""), true)
        @Expect(fileProcess.stdinLines[1].contains("\"messageId\":\"om_1\""), true)
        @Expect(fileProcess.stdinLines[1].contains("\"fileKey\":\"file_1\""), true)
        @Expect(fileProcess.stdinLines[1].contains("\"resourceType\":\"file\""), true)
    }

    @TestCase
    public func processRunnerDiagnosticFailuresAreStructuredAndNeverRunning(): Unit {
        let errorProcess = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"error\",\"requestId\":\"metis-sidecar-api\",\"status\":\"scope_missing\",\"message\":\"missing scope appSecret=secret-app\"}"
        ])
        let errorRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: FeishuSidecarApiProcessFakeRunner(errorProcess),
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let request = JsonObject()
        request.put("operation", JsonString("message.create"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("params", JsonObject())
        let errorResult = errorRunner.run(request)

        @Expect(sidecarTestBool(errorResult, "ok"), false)
        @Expect(sidecarTestString(errorResult, "status"), "scope_missing")
        @Expect(sidecarTestString(errorResult, "status") == "running", false)
        @Expect(sidecarTestString(errorResult, "error").contains("secret-app"), false)

        let exitProcess = FeishuSidecarApiProcessFakeProcess()
        exitProcess.alive = false
        let exitRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: FeishuSidecarApiProcessFakeRunner(exitProcess),
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let exitResult = exitRunner.run(request)
        @Expect(sidecarTestBool(exitResult, "ok"), false)
        @Expect(sidecarTestString(exitResult, "status"), "unexpected_exit")
        @Expect(sidecarTestString(exitResult, "status") == "running", false)

        let readyTimeoutProcess = FeishuSidecarApiProcessFakeProcess()
        let readyTimeoutRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: FeishuSidecarApiProcessFakeRunner(readyTimeoutProcess),
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let readyTimeoutResult = readyTimeoutRunner.run(request)
        @Expect(sidecarTestBool(readyTimeoutResult, "ok"), false)
        @Expect(sidecarTestString(readyTimeoutResult, "status"), "ready_timeout")
        @Expect(sidecarTestString(readyTimeoutResult, "status") == "running", false)

        let requestTimeoutProcess = FeishuSidecarApiProcessFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let requestTimeoutRunner = FeishuSidecarProcessRequestRunner(
            account: FeishuSidecarRequestAccount(accountId: "tenant-a", appId: "cli_app", appSecret: "secret-app"),
            runner: FeishuSidecarApiProcessFakeRunner(requestTimeoutProcess),
            options: FeishuSidecarRequestRunnerOptions(readyTimeoutMs: 1, requestTimeoutMs: 1, readTimeoutMs: 1)
        )
        let requestTimeoutResult = requestTimeoutRunner.run(request)
        @Expect(sidecarTestBool(requestTimeoutResult, "ok"), false)
        @Expect(sidecarTestString(requestTimeoutResult, "status"), "request_timeout")
        @Expect(sidecarTestString(requestTimeoutResult, "status") == "running", false)
    }

    @TestCase
    public func textCreateReplyAndFallbackUseExpectedSidecarOperations(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_create"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_reply"))
        runner.enqueue(feishuSidecarTestResult(false, status: "message_unavailable", error: "reply target recalled"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_fallback"))
        let client = FeishuSidecarApiClient(runner: runner)

        let created = client.sendTextMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "hello", None<String>, false)
        let replied = client.sendTextMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "reply", Some("om_parent"), true)
        let fallback = client.sendTextMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "fallback", Some("om_missing"), false)

        @Expect(created.messageId, "om_create")
        @Expect(replied.messageId, "om_reply")
        @Expect(fallback.messageId, "om_fallback")
        @Expect(runner.operation(0), "message.create")
        @Expect(sidecarTestString(runner.params(0), "text"), "hello")
        @Expect(runner.operation(1), "message.reply")
        @Expect(sidecarTestString(runner.params(1), "replyToMessageId"), "om_parent")
        @Expect(sidecarTestBool(runner.params(1), "replyInThread"), true)
        @Expect(runner.operation(2), "message.reply")
        @Expect(runner.operation(3), "message.create")
        @Expect(sidecarTestString(runner.params(3), "fallbackFromReplyToMessageId"), "om_missing")
    }

    @TestCase
    public func mediaUploadAndSendShapesCoverImageFileAudioVideo(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", mediaKey: "img_key"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_img"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", mediaKey: "file_key"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_file"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", mediaKey: "audio_key"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_audio"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", mediaKey: "video_key"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_video"))
        let client = FeishuSidecarApiClient(runner: runner)

        let imageKey = client.uploadMedia("tenant-a", "image", "/tmp/a.png", "fake-image".toArray(), "image/png", "a.png").messageId
        let imageSend = client.sendMediaMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "image", imageKey, "diagram", None<String>, false)
        let fileKey = client.uploadMedia("tenant-a", "file", "/tmp/report.pdf", "fake-pdf".toArray(), "application/pdf", "report.pdf").messageId
        let fileSend = client.sendMediaMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "file", fileKey, "report", None<String>, false)
        let audioKey = client.uploadMedia("tenant-a", "audio", "/tmp/voice.ogg", "fake-audio".toArray(), "audio/ogg", "voice.ogg").messageId
        let audioSend = client.sendMediaMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "audio", audioKey, "voice", None<String>, false)
        let videoKey = client.uploadMedia("tenant-a", "video", "/tmp/clip.mp4", "fake-video".toArray(), "video/mp4", "clip.mp4").messageId
        let videoSend = client.sendMediaMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "media", videoKey, "clip", None<String>, false)

        @Expect(imageKey, "img_key")
        @Expect(imageSend.messageId, "om_img")
        @Expect(fileSend.messageId, "om_file")
        @Expect(audioSend.messageId, "om_audio")
        @Expect(videoSend.messageId, "om_video")
        @Expect(runner.operation(0), "media.upload")
        @Expect(sidecarTestString(runner.params(0), "mediaType"), "image")
        @Expect(sidecarTestString(runner.params(0), "fileName"), "a.png")
        @Expect(sidecarTestString(runner.params(0), "bytesBase64"), "ZmFrZS1pbWFnZQ==")
        @Expect(runner.operation(1), "message.send_media")
        @Expect(sidecarTestString(runner.params(1), "messageType"), "image")
        @Expect(runner.operation(5), "message.send_media")
        @Expect(sidecarTestString(runner.params(5), "messageType"), "audio")
        @Expect(runner.operation(7), "message.send_media")
        @Expect(sidecarTestString(runner.params(7), "messageType"), "media")
    }

    @TestCase
    public func interactiveCardCreatePatchFinalAndAbortKeepCardJsonShapes(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_card"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_card"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_card"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_card"))
        let client = FeishuSidecarApiClient(runner: runner)

        let created = client.sendInteractiveCard("tenant-a", "oc_chat", "oc_chat", "chat_id", FeishuInteractiveCard(title: "Metis", text: "start"), None<String>, false)
        let patched = client.patchInteractiveCard("tenant-a", "om_card", FeishuInteractiveCard(title: "Metis", text: "patch"))
        let finalized = client.patchInteractiveCard("tenant-a", "om_card", FeishuInteractiveCard(title: "Metis", text: "final", footerText: "done"))
        let aborted = client.patchInteractiveCard("tenant-a", "om_card", FeishuInteractiveCard(title: "Metis", text: "abort", footerText: "cancelled"))

        @Expect(created.messageId, "om_card")
        @Expect(patched.ok, true)
        @Expect(finalized.ok, true)
        @Expect(aborted.ok, true)
        @Expect(runner.operation(0), "card.create")
        @Expect(runner.operation(1), "card.patch")
        @Expect(runner.operation(2), "card.patch")
        @Expect(runner.operation(3), "card.patch")
        @Expect(sidecarTestObject(runner.params(0), "card").toJsonString().contains("start"), true)
        @Expect(sidecarTestObject(runner.params(2), "card").toJsonString().contains("done"), true)
        @Expect(sidecarTestObject(runner.params(3), "card").toJsonString().contains("cancelled"), true)
    }

    @TestCase
    public func reactionAddRemoveListAndDeleteUseSidecarActions(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_target"))
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_target"))
        let list = feishuSidecarTestResult(true, status: "ok")
        list.put("reactions", JsonArray([JsonString("THUMBSUP"), JsonString("HEART")]))
        runner.enqueue(list)
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", messageId: "om_target"))
        let client = FeishuSidecarApiClient(runner: runner)

        let added = client.addMessageReaction("tenant-a", "om_target", "THUMBSUP")
        let removed = client.removeMessageReaction("tenant-a", "om_target", "THUMBSUP")
        let reactions = client.listMessageReactions("tenant-a", "om_target")
        let deleted = client.deleteMessage("tenant-a", "om_target")

        @Expect(added.messageId, "om_target")
        @Expect(removed.messageId, "om_target")
        @Expect(reactions.size, 2)
        @Expect(reactions[0], "THUMBSUP")
        @Expect(deleted.messageId, "om_target")
        @Expect(runner.operation(0), "reaction.add")
        @Expect(runner.operation(1), "reaction.remove")
        @Expect(runner.operation(2), "reaction.list")
        @Expect(runner.operation(3), "message.delete")
    }

    @TestCase
    public func fetchMessageMergeForwardAndResourceDownloadMapResponses(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(sidecarTestMessage("om_1", "text", "hello"))
        let merge = feishuSidecarTestResult(true, status: "ok")
        merge.put("messages", JsonArray([sidecarTestMessage("om_child", "image", "[image]")]))
        runner.enqueue(merge)
        runner.enqueue(feishuSidecarTestResult(true, status: "ok", contentType: "image/png", fileName: "a.png", bytesBase64: "cmVzb3VyY2U="))
        let client = FeishuSidecarApiClient(runner: runner)

        let message = client.fetchMessage("tenant-a", "om_1")
        let children = client.listMergeForwardMessages("tenant-a", "om_1")
        let resource = client.fetchMessageResource("tenant-a", "om_1", "img_key", "image")

        @Expect(message.ok, true)
        @Expect(message.messageType, "text")
        @Expect(children.ok, true)
        @Expect(children.messages.size, 1)
        @Expect(children.messages[0].messageId, "om_child")
        @Expect(resource.ok, true)
        @Expect(resource.bytes, "resource".toArray())
        @Expect(resource.contentType, "image/png")
        @Expect(resource.fileName, "a.png")
        @Expect(runner.operation(0), "message.fetch")
        @Expect(runner.operation(1), "message.list_merge_forward")
        @Expect(runner.operation(2), "resource.download")
    }

    @TestCase
    public func structuredErrorsArePreservedAndSecretBearingJsonIsRedacted(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(false, status: "scope_missing", error: "missing im:message"))
        runner.enqueue(feishuSidecarTestResult(false, status: "auth_required", error: "auth required"))
        runner.enqueue(feishuSidecarTestResult(false, status: "api_error", error: "{\"ok\":false,\"Authorization\":\"Bearer live-token\",\"app_secret\":\"secret\"}"))
        let client = FeishuSidecarApiClient(runner: runner)

        let upload = client.uploadMedia("tenant-a", "image", "/tmp/a.png", "fake".toArray(), "image/png", "a.png")
        let fetched = client.fetchMessageResource("tenant-a", "om_1", "img_key", "image")
        let sent = client.sendTextMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "hello", None<String>, false)

        @Expect(upload.status, "scope_missing")
        @Expect(fetched.status, "auth_required")
        @Expect(sent.status, "api_error")
        @Expect(sent.error.contains("Bearer"), false)
        @Expect(sent.error.contains("live-token"), false)
        @Expect(sent.error.contains("app_secret"), false)
        @Expect(sent.error.contains("\"ok\""), false)
        @Expect(sent.error.contains("\"Authorization\""), false)
    }

    @TestCase
    public func apiClientSendTextFailsClosedOnMissingSdk(): Unit {
        let runner = FeishuSidecarApiClientFakeRunner()
        runner.enqueue(feishuSidecarTestResult(false, status: "missing_dependency", error: "Feishu sidecar dependency missing: @larksuiteoapi/node-sdk under tools/feishu-sidecar"))
        let client = FeishuSidecarApiClient(runner: runner)

        let sent = client.sendTextMessage("tenant-a", "oc_chat", "oc_chat", "chat_id", "hello", None<String>, false)

        @Expect(sent.ok, false)
        @Expect(sent.status, "missing_dependency")
        @Expect(sent.error.contains("@larksuiteoapi/node-sdk"), true)
        @Expect(runner.operation(0), "message.create")
    }
}
