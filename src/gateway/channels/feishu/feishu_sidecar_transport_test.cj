package metis.gateway.channels.feishu

import std.collection.ArrayList
import std.core.Duration
import std.process.*
import std.sync.Mutex
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private class FeishuSidecarFakeProcess <: FeishuSidecarProtocolProcess {
    private let lock = Mutex()
    private let stdoutLines = ArrayList<String>()
    public let stdinLines = ArrayList<String>()
    public var alive: Bool = true
    public var waitResult: Option<Int64> = Some(0)
    public var waitCalls: Int64 = 0
    public var terminateCalls: Int64 = 0
    public var readCalls: Int64 = 0
    private let processPid: Int64

    public init(pid!: Int64 = 9010, stdout!: Array<String> = []) {
        this.processPid = pid
        for (line in stdout) {
            this.stdoutLines.add(line)
        }
    }

    public func pid(): Int64 {
        this.processPid
    }

    public func writeLine(line: String): Unit {
        synchronized(this.lock) {
            this.stdinLines.add(line)
        }
    }

    public func readLine(_timeoutMs: Int64): Option<String> {
        synchronized(this.lock) {
            this.readCalls += 1
            if (this.stdoutLines.isEmpty()) {
                return None<String>
            }
            let line = this.stdoutLines[0]
            this.stdoutLines.remove(at: 0)
            Some(line)
        }
    }

    public func isAlive(): Bool {
        synchronized(this.lock) {
            this.alive
        }
    }

    public func wait(_timeoutMs: Int64): Option<Int64> {
        synchronized(this.lock) {
            this.waitCalls += 1
            this.waitResult
        }
    }

    public func terminate(_force: Bool): Unit {
        synchronized(this.lock) {
            this.terminateCalls += 1
            this.alive = false
        }
    }

    public func stdoutSummary(): String {
        synchronized(this.lock) {
            String.join(this.stdinLines.toArray(), delimiter: "\n")
        }
    }

    public func stderrSummary(): String {
        ""
    }

    public func push(line: String): Unit {
        synchronized(this.lock) {
            this.stdoutLines.add(line)
        }
    }

    public func exitNow(): Unit {
        synchronized(this.lock) {
            this.alive = false
        }
    }

    public func modelsBlockingPipeReader(): Bool {
        false
    }
}

private class FeishuSidecarFakeRunner <: FeishuSidecarProtocolRunner {
    public let process: FeishuSidecarFakeProcess
    private let processes = ArrayList<FeishuSidecarFakeProcess>()
    private var processCursor: Int64 = 0
    public var lastLaunch: FeishuSidecarLaunchSpec = FeishuSidecarLaunchSpec(command: "", args: [])
    public var startCount: Int64 = 0
    public var failWith: String = ""

    public init(process: FeishuSidecarFakeProcess) {
        this.process = process
        this.processes.add(process)
    }

    public func enqueueProcess(process: FeishuSidecarFakeProcess): Unit {
        this.processes.add(process)
    }

    public func start(spec: FeishuSidecarLaunchSpec): FeishuSidecarProtocolStartResult {
        this.startCount += 1
        this.lastLaunch = spec
        if (!this.failWith.trimAscii().isEmpty()) {
            return FeishuSidecarProtocolStartResult.Failed(this.failWith)
        }
        let selected = if (this.processCursor < this.processes.size) {
            let value = this.processes[this.processCursor]
            this.processCursor += 1
            value
        } else {
            this.process
        }
        FeishuSidecarProtocolStartResult.Started(selected)
    }

    public func modelsBlockingPipeReader(): Bool {
        this.process.modelsBlockingPipeReader()
    }
}

@Test
public class FeishuSidecarTransportTest {
    private func spec(): FeishuLongConnectStartSpec {
        FeishuLongConnectStartSpec(
            accountId: "tenant-a",
            appId: "cli_app",
            appSecret: "secret-app",
            domain: "https://open.feishu.cn",
            verificationToken: "secret-verification",
            encryptKey: "secret-encrypt"
        )
    }

    private func specFor(accountId: String): FeishuLongConnectStartSpec {
        FeishuLongConnectStartSpec(
            accountId: accountId,
            appId: "cli_app_${accountId}",
            appSecret: "secret-app-${accountId}",
            domain: "https://open.feishu.cn",
            verificationToken: "secret-verification-${accountId}",
            encryptKey: "secret-encrypt-${accountId}"
        )
    }

    private func options(): FeishuSidecarTransportOptions {
        FeishuSidecarTransportOptions(
            command: "node",
            args: ["scripts/feishu-sidecar.mjs"],
            readyTimeoutMs: 1,
            readTimeoutMs: 1,
            stopTimeoutMs: 1,
            startBackgroundReader: false
        )
    }

    private func jsonEvent(messageId: String): String {
        "{\"message\":{\"message_id\":\"${messageId}\"}}"
    }

    private func delayedStdioScript(): String {
        "read ignored; printf '%s\\n' '{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}'; sleep 0.35; printf '%s\\n' '{\"type\":\"inbound\",\"accountId\":\"tenant-a\",\"eventType\":\"im.message.receive_v1\",\"event\":{\"message\":{\"message_id\":\"om_delayed_stdio\"}}}'; sleep 0.2"
    }

    private func delayedPlainLineScript(): String {
        "read ignored; printf '%s\\n' 'line-after-timeouts'; sleep 0.2"
    }

    private func unicodeLineScript(): String {
        "read ignored; printf '%s\\n' '中文🙂🚀'; sleep 0.1"
    }

    private func invalidUtf8LineScript(): String {
        "read ignored; printf '\\377\\n'; sleep 0.1"
    }

    private func stderrBurstScript(): String {
        "for i in {0..129}; do printf 'stderr-line-%s\\n' \"$i\" >&2; done; sleep 0.8"
    }

    private func startStdioScript(script: String): FeishuSidecarProtocolProcess {
        match (FeishuSidecarStdioRunner().start(FeishuSidecarLaunchSpec(command: "/bin/zsh", args: ["-lc", script]))) {
            case FeishuSidecarProtocolStartResult.Started(proc) => proc
            case FeishuSidecarProtocolStartResult.Failed(reason) => throw Exception(reason)
        }
    }

    @TestCase
    public func lineBufferReturnsQueuedLineWithoutReaderSpawn(): Unit {
        let buffer = FeishuSidecarLineBuffer(name: "stdout", maxLines: 4, maxLineChars: 1024)

        buffer.appendLine("queued-line")

        @Expect(buffer.readLine(30000).getOrThrow(), "queued-line")
        @Expect(buffer.readLine(1).isNone(), true)
        @Expect(buffer.droppedCount(), 0)
    }

    @TestCase
    public func blockingReaderShapeIsNotAcceptedAsLivenessProof(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [])
        let runner = FeishuSidecarFakeRunner(process)

        @Expect(process.readLine(30000).isNone(), true)
        @Expect(process.readCalls, 1)
        @Expect(runner.modelsBlockingPipeReader(), false)
    }

    @TestCase
    public func readLineTimeoutDoesNotSpawnUnboundedReaders(): Unit {
        let process = this.startStdioScript(this.delayedPlainLineScript())

        for (_ in 0..100) {
            @Expect(process.readLine(1).isNone(), true)
        }
        process.writeLine("go")

        @Expect(process.readLine(1000).getOrThrow(), "line-after-timeouts")
        process.terminate(true)
    }

    @TestCase
    public func brokerBackedStdioPreservesUnicodeAndContainsInvalidUtf8(): Unit {
        let unicode = this.startStdioScript(this.unicodeLineScript())
        unicode.writeLine("go")
        @Expect(unicode.readLine(1000).getOrThrow(), "中文🙂🚀")
        unicode.terminate(true)

        let invalid = this.startStdioScript(this.invalidUtf8LineScript())
        invalid.writeLine("go")
        @Expect(invalid.readLine(300).isNone(), true)
        @Expect(invalid.wait(1000).getOrThrow(), -1)
        @Expect(invalid.stderrSummary().contains("invalid_response_encoding"), true)
        invalid.terminate(true)
    }

    @TestCase
    public func stderrReaderUsesBoundedRingBuffer(): Unit {
        let process = this.startStdioScript(this.stderrBurstScript())
        sleep(Duration.millisecond * 300)

        let summary = process.stderrSummary()

        @Expect(summary.contains("stderr-line-129"), true)
        @Expect(summary.contains("stderr-line-0"), false)
        @Expect(Int64(summary.size) < 4096, true)
        process.terminate(true)
    }

    @TestCase
    public func diagnosticSummaryTruncatesAtRuneBoundary(): Unit {
        var asciiPrefix = ""
        for (_ in 0..510) {
            asciiPrefix += "a"
        }
        let boundary = "${asciiPrefix}中🙂"
        let exact = FeishuSidecarLineBuffer(name: "stderr", maxLines: 1, maxLineChars: 2048)
        exact.appendLine(boundary)

        @Expect(exact.summary(), boundary)
        @Expect(exact.summary().toRuneArray().size, 512)

        let over = FeishuSidecarLineBuffer(name: "stderr", maxLines: 1, maxLineChars: 2048)
        over.appendLine("${boundary}🚀")
        let truncated = over.summary()

        @Expect(truncated, "${boundary}...")
        @Expect(truncated.toRuneArray().size, 515)
        @Expect(truncated.contains("🚀"), false)
    }

    @TestCase
    public func closeWakesPendingReadLine(): Unit {
        let buffer = FeishuSidecarLineBuffer(name: "stdout", maxLines: 4, maxLineChars: 1024)
        let pending = spawn {
            buffer.readLine(30000)
        }
        sleep(Duration.millisecond * 50)

        buffer.close(error: "closed for test")

        @Expect(pending.get(Duration.millisecond * 500).isNone(), true)
        @Expect(buffer.lastError(), "closed for test")
    }

    @TestCase
    public func oversizedLineIsDroppedWithDiagnostic(): Unit {
        let buffer = FeishuSidecarLineBuffer(name: "stdout", maxLines: 4, maxLineChars: 8)

        buffer.appendLine("0123456789")
        buffer.appendLine("ok")

        @Expect(buffer.readLine(1).getOrThrow(), "ok")
        @Expect(buffer.droppedCount(), 1)
        @Expect(buffer.summary().contains("dropped=1"), true)
        @Expect(buffer.summary().contains("0123456789"), false)
    }

    @TestCase
    public func readyWritesInitFrameThroughStdinAndMarksHealth(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())

        let result = transport.start(this.spec(), { _root => () })

        @Expect(result.ok, true)
        @Expect(result.status, "ready")
        @Expect(process.stdinLines.size, 1)
        @Expect(process.stdinLines[0].contains("\"type\":\"init\""), true)
        @Expect(process.stdinLines[0].contains("secret-app"), true)
        @Expect(String.join(runner.lastLaunch.args, delimiter: " ").contains("secret-app"), false)
        @Expect(transport.healthSnapshot().ready, true)
        @Expect(transport.healthSnapshot().connected, true)
        @Expect(transport.healthSnapshot().pid, 9010)
    }

    @TestCase
    public func launchSpecCarriesRuntimeRootWorkingDirectoryAndEnvForLongConnect(): Unit {
        let runtimeRoot = "/tmp/metis-sidecar-runtime"
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(
            runner: runner,
            options: FeishuSidecarTransportOptions(
                command: "node",
                args: ["scripts/feishu-sidecar.mjs"],
                runtimeRoot: runtimeRoot,
                workingDirectory: "/tmp/metis",
                env: [("METIS_FEISHU_SIDECAR_RUNTIME_ROOT", runtimeRoot)],
                readyTimeoutMs: 1,
                readTimeoutMs: 1,
                stopTimeoutMs: 1,
                startBackgroundReader: false
            )
        )

        let result = transport.start(this.spec(), { _root => () })

        @Expect(result.ok, true)
        @Expect(runner.lastLaunch.runtimeRoot, runtimeRoot)
        @Expect(runner.lastLaunch.workingDirectory.getOrThrow(), "/tmp/metis")
        @Expect(runner.lastLaunch.env.size, 1)
        @Expect(runner.lastLaunch.env[0][0], "METIS_FEISHU_SIDECAR_RUNTIME_ROOT")
        @Expect(runner.lastLaunch.env[0][1], runtimeRoot)
        @Expect(process.stdinLines[0].contains("\"runtimeRoot\":\"${runtimeRoot}\""), true)
        @Expect(String.join(runner.lastLaunch.args, delimiter: " ").contains(runtimeRoot), false)
        @Expect(String.join(runner.lastLaunch.args, delimiter: " ").contains("secret-app"), false)
    }

    @TestCase
    public func inboundFrameDispatchesOnlyJsonEventRoot(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"inbound\",\"accountId\":\"tenant-a\",\"eventType\":\"im.message.receive_v1\",\"event\":${this.jsonEvent("om_sidecar")}}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let events = ArrayList<JsonObject>()

        let result = transport.start(this.spec(), { root => events.add(root) })
        transport.debugDrainAvailableForTest()

        @Expect(result.ok, true)
        @Expect(events.size, 1)
        let header = events[0].get("header").getOrThrow().asObject()
        @Expect(header.get("event_type").getOrThrow().asString().getValue(), "im.message.receive_v1")
        @Expect(header.get("account_id").getOrThrow().asString().getValue(), "tenant-a")
        let event = events[0].get("event").getOrThrow().asObject()
        let message = event.get("message").getOrThrow().asObject()
        @Expect(message.get("message_id").getOrThrow().asString().getValue(), "om_sidecar")
        @Expect(transport.healthSnapshot().lastInboundAt > 0, true)
    }

    @TestCase
    public func stdioBackgroundReaderKeepsDelayedInboundAfterReadTimeouts(): Unit {
        let transport = FeishuSidecarTransport(
            runner: FeishuSidecarStdioRunner(),
            options: FeishuSidecarTransportOptions(
                command: "/bin/zsh",
                args: ["-lc", this.delayedStdioScript()],
                readyTimeoutMs: 1000,
                readTimeoutMs: 20,
                stopTimeoutMs: 100,
                startBackgroundReader: true
            )
        )
        let events = ArrayList<JsonObject>()

        let result = transport.start(this.spec(), { root => events.add(root) })
        @Expect(result.ok, true)
        sleep(Duration.millisecond * 700)

        @Expect(events.size, 1)
        let header = events[0].get("header").getOrThrow().asObject()
        @Expect(header.get("event_type").getOrThrow().asString().getValue(), "im.message.receive_v1")
        let event = events[0].get("event").getOrThrow().asObject()
        let message = event.get("message").getOrThrow().asObject()
        @Expect(message.get("message_id").getOrThrow().asString().getValue(), "om_delayed_stdio")
        transport.stop()
    }

    @TestCase
    public func failureFramesAndMalformedLinesUpdateLastError(): Unit {
        let timeoutProcess = FeishuSidecarFakeProcess(stdout: [])
        let timeoutTransport = FeishuSidecarTransport(runner: FeishuSidecarFakeRunner(timeoutProcess), options: this.options())
        let timeoutResult = timeoutTransport.start(this.spec(), { _root => () })
        @Expect(timeoutResult.ok, false)
        @Expect(timeoutResult.status, "ready_timeout")
        @Expect(timeoutTransport.healthSnapshot().lastError.contains("ready timeout"), true)

        let badProcess = FeishuSidecarFakeProcess(stdout: ["not json"])
        let badTransport = FeishuSidecarTransport(runner: FeishuSidecarFakeRunner(badProcess), options: this.options())
        let badResult = badTransport.start(this.spec(), { _root => () })
        @Expect(badResult.ok, false)
        @Expect(badResult.status, "protocol_error")
        @Expect(badTransport.healthSnapshot().lastError.contains("non-json"), true)

        let errorProcess = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"error\",\"phase\":\"start\",\"status\":\"sdk_error\",\"message\":\"sdk failed\"}"
        ])
        let errorTransport = FeishuSidecarTransport(runner: FeishuSidecarFakeRunner(errorProcess), options: this.options())
        let errorResult = errorTransport.start(this.spec(), { _root => () })
        @Expect(errorResult.ok, false)
        @Expect(errorResult.status, "sdk_error")
        @Expect(errorTransport.healthSnapshot().lastError.contains("sdk failed"), true)
    }

    @TestCase
    public func diagnosticClosedAndUnexpectedExitAreReflectedInSnapshots(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let result = transport.start(this.spec(), { _root => () })
        @Expect(result.ok, true)

        process.push("{\"type\":\"diagnostic\",\"level\":\"warn\",\"phase\":\"websocket.open\",\"status\":\"retry\",\"message\":\"retrying\"}")
        transport.debugDrainAvailableForTest()
        @Expect(transport.diagnosticsSnapshot().size, 2)
        @Expect(transport.diagnosticsSnapshot()[1].phase, "websocket.open")

        process.push("{\"type\":\"closed\",\"accountId\":\"tenant-a\",\"reason\":\"websocket.close\"}")
        transport.debugDrainAvailableForTest()
        @Expect(transport.healthSnapshot().ready, false)
        @Expect(transport.healthSnapshot().connected, false)
        @Expect(transport.healthSnapshot().lastError.contains("websocket.close"), true)

        process.exitNow()
        transport.debugDrainAvailableForTest()
        @Expect(transport.healthSnapshot().lastError.contains("unexpected exit"), true)
    }

    @TestCase
    public func errorFrameAfterReadyMarksTransportUnavailable(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let result = transport.start(this.spec(), { _root => () })
        @Expect(result.ok, true)

        process.push("{\"type\":\"error\",\"phase\":\"websocket.read\",\"status\":\"sdk_error\",\"message\":\"sdk failed\"}")
        transport.debugDrainAvailableForTest()

        @Expect(transport.healthSnapshot().ready, false)
        @Expect(transport.healthSnapshot().connected, false)
        @Expect(transport.healthSnapshot().lastError.contains("sdk failed"), true)
    }

    @TestCase
    public func diagnosticFailureAfterReadyMarksUnavailableAndReportsBackgroundFailure(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let diagnostics = ArrayList<JsonObject>()
        let result = transport.start(this.spec(), { root => diagnostics.add(root) })
        @Expect(result.ok, true)

        process.push("{\"type\":\"diagnostic\",\"level\":\"error\",\"phase\":\"websocket.read\",\"status\":\"failed\",\"message\":\"websocket closed 1006\"}")
        transport.debugDrainAvailableForTest()

        @Expect(transport.healthSnapshot().ready, false)
        @Expect(transport.healthSnapshot().connected, false)
        @Expect(transport.healthSnapshot().lastError.contains("websocket closed 1006"), true)
        @Expect(diagnostics.size, 1)
        let header = diagnostics[0].get("header").getOrThrow().asObject()
        @Expect(header.get("event_type").getOrThrow().asString().getValue(), "metis.feishu.sidecar.diagnostic")
        let sidecar = diagnostics[0].get("sidecar").getOrThrow().asObject()
        @Expect(sidecar.get("phase").getOrThrow().asString().getValue(), "websocket.read")
        @Expect(sidecar.get("status").getOrThrow().asString().getValue(), "failed")
        @Expect(sidecar.get("message").getOrThrow().asString().getValue(), "websocket closed 1006")
    }

    @TestCase
    public func diagnosticRingKeepsLast64EntriesAndStopTerminatesHungProcess(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        process.waitResult = None<Int64>
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let result = transport.start(this.spec(), { _root => () })
        @Expect(result.ok, true)

        for (i in 0..70) {
            process.push("{\"type\":\"diagnostic\",\"level\":\"info\",\"phase\":\"phase-${i}\",\"status\":\"ok\"}")
        }
        transport.debugDrainAvailableForTest()
        let diagnostics = transport.diagnosticsSnapshot()
        @Expect(diagnostics.size, 64)
        @Expect(diagnostics[0].phase, "phase-6")
        @Expect(transport.healthSnapshot().diagnosticRingSize, 64)

        transport.stop()
        @Expect(process.waitCalls, 1)
        @Expect(process.terminateCalls, 1)
        @Expect(transport.healthSnapshot().connected, false)
    }

    @TestCase
    public func defaultRunnerFailsClosedInsteadOfReportingConnected(): Unit {
        let transport = FeishuSidecarTransport(options: this.options())
        let result = transport.start(this.spec(), { _root => () })

        @Expect(result.ok, false)
        @Expect(result.status, "not_configured")
        @Expect(transport.healthSnapshot().ready, false)
        @Expect(transport.healthSnapshot().connected, false)
    }

    @TestCase
    public func diagnosticErrorRedactsSecretsFromHealthAndRing(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"diagnostic\",\"level\":\"error\",\"phase\":\"dependency.preflight\",\"status\":\"missing_dependency\",\"message\":\"missing @larksuiteoapi/node-sdk appSecret=secret-app token=secret-verification\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let transport = FeishuSidecarTransport(runner: runner, options: this.options())
        let result = transport.start(this.spec(), { _root => () })
        @Expect(result.ok, true)

        transport.debugDrainAvailableForTest()

        @Expect(transport.healthSnapshot().lastError.contains("secret-app"), false)
        @Expect(transport.healthSnapshot().lastError.contains("secret-verification"), false)
        let diagnostics = transport.diagnosticsSnapshot()
        @Expect(diagnostics[1].message.contains("secret-app"), false)
        @Expect(diagnostics[1].message.contains("secret-verification"), false)
    }

    @TestCase
    public func supervisorStartsTwoAccountsThroughOneSidecarProcess(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"ready\",\"accountId\":\"tenant-b\",\"transport\":\"websocket\"}"
        ])
        let runner = FeishuSidecarFakeRunner(process)
        let registry = FeishuSidecarSupervisorRegistry(runner: runner, options: this.options())
        let transportA = FeishuSidecarSupervisorTransport(registry: registry)
        let transportB = FeishuSidecarSupervisorTransport(registry: registry)

        let resultA = transportA.start(this.specFor("tenant-a"), { _root => () })
        let resultB = transportB.start(this.specFor("tenant-b"), { _root => () })

        @Expect(resultA.ok, true)
        @Expect(resultB.ok, true)
        @Expect(runner.startCount, 1)
        @Expect(process.stdinLines.size, 2)
        @Expect(process.stdinLines[0].contains("\"type\":\"initAccount\""), true)
        @Expect(process.stdinLines[0].contains("\"accountId\":\"tenant-a\""), true)
        @Expect(process.stdinLines[1].contains("\"type\":\"initAccount\""), true)
        @Expect(process.stdinLines[1].contains("\"accountId\":\"tenant-b\""), true)
        @Expect(transportA.healthSnapshot().ready, true)
        @Expect(transportB.healthSnapshot().ready, true)
    }

    @TestCase
    public func supervisorRoutesInboundFramesByAccountId(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"ready\",\"accountId\":\"tenant-b\",\"transport\":\"websocket\"}",
            "{\"type\":\"inbound\",\"accountId\":\"tenant-b\",\"eventType\":\"im.message.receive_v1\",\"event\":${this.jsonEvent("om_b")}}",
            "{\"type\":\"inbound\",\"accountId\":\"tenant-a\",\"eventType\":\"im.message.receive_v1\",\"event\":${this.jsonEvent("om_a")}}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        let transportA = FeishuSidecarSupervisorTransport(registry: registry)
        let transportB = FeishuSidecarSupervisorTransport(registry: registry)
        let eventsA = ArrayList<JsonObject>()
        let eventsB = ArrayList<JsonObject>()

        @Expect(transportA.start(this.specFor("tenant-a"), { root => eventsA.add(root) }).ok, true)
        @Expect(transportB.start(this.specFor("tenant-b"), { root => eventsB.add(root) }).ok, true)
        registry.debugDrainAvailableForTest()

        @Expect(eventsA.size, 1)
        @Expect(eventsB.size, 1)
        let headerA = eventsA[0].get("header").getOrThrow().asObject()
        let headerB = eventsB[0].get("header").getOrThrow().asObject()
        @Expect(headerA.get("account_id").getOrThrow().asString().getValue(), "tenant-a")
        @Expect(headerB.get("account_id").getOrThrow().asString().getValue(), "tenant-b")
        let messageA = eventsA[0].get("event").getOrThrow().asObject().get("message").getOrThrow().asObject()
        let messageB = eventsB[0].get("event").getOrThrow().asObject().get("message").getOrThrow().asObject()
        @Expect(messageA.get("message_id").getOrThrow().asString().getValue(), "om_a")
        @Expect(messageB.get("message_id").getOrThrow().asString().getValue(), "om_b")
    }

    @TestCase
    public func supervisorBackgroundReaderCompletesReadyAndInboundDispatch(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"inbound\",\"accountId\":\"tenant-a\",\"eventType\":\"im.message.receive_v1\",\"event\":${this.jsonEvent("om_background")}}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(
            runner: FeishuSidecarFakeRunner(process),
            options: FeishuSidecarTransportOptions(
                command: "node",
                args: ["scripts/feishu-sidecar.mjs"],
                readyTimeoutMs: 200,
                readTimeoutMs: 1,
                stopTimeoutMs: 1,
                startBackgroundReader: true
            )
        )
        let transport = FeishuSidecarSupervisorTransport(registry: registry)
        let events = ArrayList<JsonObject>()

        let result = transport.start(this.specFor("tenant-a"), { root => events.add(root) })
        sleep(Duration.millisecond * 20)

        @Expect(result.ok, true)
        @Expect(events.size, 1)
        let message = events[0].get("event").getOrThrow().asObject().get("message").getOrThrow().asObject()
        @Expect(message.get("message_id").getOrThrow().asString().getValue(), "om_background")
        transport.stop()
    }

    @TestCase
    public func supervisorAccountFailureDoesNotPoisonReadyAccount(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"error\",\"accountId\":\"tenant-b\",\"phase\":\"start\",\"status\":\"sdk_error\",\"message\":\"tenant b failed\"}",
            "{\"type\":\"inbound\",\"accountId\":\"tenant-a\",\"eventType\":\"im.message.receive_v1\",\"event\":${this.jsonEvent("om_a_after_b_failure")}}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        let transportA = FeishuSidecarSupervisorTransport(registry: registry)
        let transportB = FeishuSidecarSupervisorTransport(registry: registry)
        let eventsA = ArrayList<JsonObject>()

        let resultA = transportA.start(this.specFor("tenant-a"), { root => eventsA.add(root) })
        let resultB = transportB.start(this.specFor("tenant-b"), { _root => () })
        registry.debugDrainAvailableForTest()

        @Expect(resultA.ok, true)
        @Expect(resultB.ok, false)
        @Expect(resultB.status, "sdk_error")
        @Expect(transportA.healthSnapshot().ready, true)
        @Expect(transportA.healthSnapshot().connected, true)
        @Expect(transportB.healthSnapshot().lastError.contains("tenant b failed"), true)
        @Expect(eventsA.size, 1)
    }

    @TestCase
    public func supervisorStopOneAccountKeepsOtherAccountProcessAlive(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"ready\",\"accountId\":\"tenant-b\",\"transport\":\"websocket\"}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        let transportA = FeishuSidecarSupervisorTransport(registry: registry)
        let transportB = FeishuSidecarSupervisorTransport(registry: registry)

        @Expect(transportA.start(this.specFor("tenant-a"), { _root => () }).ok, true)
        @Expect(transportB.start(this.specFor("tenant-b"), { _root => () }).ok, true)

        transportA.stop()
        @Expect(process.waitCalls, 0)
        @Expect(process.stdinLines[2].contains("\"type\":\"closeAccount\""), true)
        @Expect(process.stdinLines[2].contains("\"accountId\":\"tenant-a\""), true)

        transportB.stop()
        @Expect(process.waitCalls, 1)
        @Expect(process.stdinLines[3].contains("\"accountId\":\"tenant-b\""), true)
    }

    @TestCase
    public func p2U1SupervisorCorrelatesInterleavedSameRequestIdsByAccount(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"ready\",\"accountId\":\"tenant-b\",\"transport\":\"websocket\"}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        @Expect(registry.startAccount(this.specFor("tenant-a"), { _root => () }).ok, true)
        @Expect(registry.startAccount(this.specFor("tenant-b"), { _root => () }).ok, true)
        let frameA = JsonObject()
        frameA.put("type", JsonString("request"))
        frameA.put("accountId", JsonString("tenant-a"))
        frameA.put("requestId", JsonString("same-id"))
        let frameB = JsonObject()
        frameB.put("type", JsonString("request"))
        frameB.put("accountId", JsonString("tenant-b"))
        frameB.put("requestId", JsonString("same-id"))
        let resultA = spawn { registry.requestAccount("tenant-a", "same-id", frameA, 500) }
        let resultB = spawn { registry.requestAccount("tenant-b", "same-id", frameB, 500) }
        while (registry.debugPendingRequestCountForTest() < 2) { sleep(Duration.millisecond) }
        process.push("{\"type\":\"sendResult\",\"accountId\":\"tenant-b\",\"requestId\":\"same-id\",\"ok\":true,\"messageId\":\"om_b\"}")
        process.push("{\"type\":\"sendResult\",\"accountId\":\"tenant-a\",\"requestId\":\"same-id\",\"ok\":true,\"messageId\":\"om_a\"}")
        registry.debugDrainAvailableForTest()

        @Expect(resultA.get(Duration.second).get("messageId").getOrThrow().asString().getValue(), "om_a")
        @Expect(resultB.get(Duration.second).get("messageId").getOrThrow().asString().getValue(), "om_b")
        @Expect(registry.debugPendingRequestCountForTest(), 0)
        @Expect(registry.debugProcessStartCountForTest(), 1)
    }

    @TestCase
    public func p2B1StoppingAccountFailsOnlyItsPendingRequest(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}",
            "{\"type\":\"ready\",\"accountId\":\"tenant-b\",\"transport\":\"websocket\"}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        @Expect(registry.startAccount(this.specFor("tenant-a"), { _root => () }).ok, true)
        @Expect(registry.startAccount(this.specFor("tenant-b"), { _root => () }).ok, true)
        let frame = JsonObject()
        frame.put("type", JsonString("request"))
        frame.put("accountId", JsonString("tenant-a"))
        frame.put("requestId", JsonString("pending-stop"))
        let result = spawn { registry.requestAccount("tenant-a", "pending-stop", frame, 500) }
        while (registry.debugPendingRequestCountForTest() < 1) { sleep(Duration.millisecond) }

        registry.stopAccount("tenant-a")

        @Expect(result.get(Duration.second).get("status").getOrThrow().asString().getValue(), "closed")
        @Expect(registry.debugPendingRequestCountForTest(), 0)
        @Expect(process.waitCalls, 0)
        registry.stopAccount("tenant-b")
    }

    @TestCase
    public func p2B1LateResponseAfterDeadlineDoesNotPoisonAccountHealth(): Unit {
        let process = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let registry = FeishuSidecarSupervisorRegistry(runner: FeishuSidecarFakeRunner(process), options: this.options())
        @Expect(registry.startAccount(this.specFor("tenant-a"), { _root => () }).ok, true)
        let request = JsonObject()
        request.put("type", JsonString("request"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("requestId", JsonString("deadline-race"))

        let timeout = registry.requestAccount("tenant-a", "deadline-race", request, 2)
        @Expect(timeout.get("status").getOrThrow().asString().getValue(), "request_timeout")
        process.push("{\"type\":\"error\",\"accountId\":\"tenant-a\",\"requestId\":\"deadline-race\",\"status\":\"api_error\",\"message\":\"late secret-app\"}")
        registry.debugDrainAvailableForTest()

        let health = registry.healthSnapshot("tenant-a")
        @Expect(health.ready, true)
        @Expect(health.connected, true)
        @Expect(health.lastError, "")
        let diagnostics = registry.diagnosticsSnapshot("tenant-a")
        @Expect(diagnostics[diagnostics.size - 1].status, "late_result_dropped")
        @Expect(diagnostics[diagnostics.size - 1].message.contains("secret-app"), false)
        registry.stopAccount("tenant-a")
    }

    @TestCase
    public func p2N1RecycleStartsOnceReinitializesAccountsAndDoesNotReplayRequests(): Unit {
        let first = FeishuSidecarFakeProcess(stdout: [
            "{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}"
        ])
        let second = FeishuSidecarFakeProcess()
        let runner = FeishuSidecarFakeRunner(first)
        runner.enqueueProcess(second)
        let registry = FeishuSidecarSupervisorRegistry(runner: runner, options: this.options())
        @Expect(registry.startAccount(this.specFor("tenant-a"), { _root => () }).ok, true)
        first.push("{\"type\":\"diagnostic\",\"accountId\":\"tenant-a\",\"phase\":\"operation.lifecycle\",\"status\":\"recycle_required\",\"message\":\"orphan threshold\"}")

        registry.debugDrainAvailableForTest()

        @Expect(registry.debugProcessStartCountForTest(), 2)
        @Expect(first.terminateCalls, 1)
        @Expect(second.stdinLines.size, 1)
        @Expect(second.stdinLines[0].contains("\"type\":\"initAccount\""), true)
        @Expect(second.stdinLines[0].contains("\"accountId\":\"tenant-a\""), true)
        second.push("{\"type\":\"ready\",\"accountId\":\"tenant-a\",\"transport\":\"websocket\"}")
        registry.debugDrainAvailableForTest()
        let request = JsonObject()
        request.put("type", JsonString("request"))
        request.put("accountId", JsonString("tenant-a"))
        request.put("requestId", JsonString("after-recycle"))
        let result = spawn { registry.requestAccount("tenant-a", "after-recycle", request, 500) }
        while (registry.debugPendingRequestCountForTest() < 1) { sleep(Duration.millisecond) }
        second.push("{\"type\":\"sendResult\",\"accountId\":\"tenant-a\",\"requestId\":\"after-recycle\",\"ok\":true,\"messageId\":\"om_recovered\"}")
        registry.debugDrainAvailableForTest()

        @Expect(result.get(Duration.second).get("messageId").getOrThrow().asString().getValue(), "om_recovered")
        @Expect(first.stdinLines.size, 1)
        @Expect(second.stdinLines.size, 2)
        registry.stopAccount("tenant-a")
    }
}
