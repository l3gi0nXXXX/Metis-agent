package metis.gateway.channels.telegram

import metis.gateway.model.*
import std.collection.ArrayList
import std.env.getVariable
import std.fs.{Directory, Path, exists, remove}
import std.net.*
import std.sync.*
import std.time.*
import std.unittest.*
import stdx.encoding.json.*

private func shutdownWaitFor(condition: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.second * 2
    while (!condition() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
    condition()
}

private func shutdownRoot(name: String): Path {
    let parent = getVariable("METIS_TGSTOP_TEST_ROOT").getOrDefault { "/tmp" }
    let root = Path(parent).join("telegram-shutdown-${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private let shutdownUpdate42 = "{\"update_id\":42,\"message\":{\"message_id\":11,\"text\":\"中文😀\",\"chat\":{\"id\":123,\"type\":\"private\"},\"from\":{\"id\":123}}}"

private func shutdownAdapter(root: Path, nativeCommands!: Bool = false): TelegramAdapter {
    TelegramAdapter(
        config: TelegramConfig(enabled: true, botToken: "synthetic-stop-token", dmPolicy: "open", allowFrom: ["*"]),
        pairingRoot: root.toString(),
        registerNativeCommandsOnStart: nativeCommands
    )
}

private func shutdownOrdinaryResponse(): TelegramTransportResponse {
    TelegramTransportResponse(true, body: "{\"ok\":true,\"result\":[]}", outcome: "ok")
}

private class ShutdownHeldPeer {
    let listener = TcpServerSocket(bindAt: 0u16)
    let entered = AtomicBool(false)
    let eof = AtomicInt64(0)
    let mode: String

    init(mode: String) {
        this.mode = mode
        this.listener.bind()
    }

    prop port: UInt16 {
        get() { (this.listener.localAddress as IPSocketAddress)?.port ?? 0u16 }
    }

    func serve(): Unit {
        try (peer = this.listener.accept(timeout: Some(Duration.second * 3))) {
            peer.readTimeout = Some(Duration.second * 3)
            let bytes = ArrayList<Byte>()
            let one = Array<Byte>(1, repeat: 0)
            if (this.mode == "tls" || this.mode == "bad-tls") {
                peer.read(one)
            } else {
                while (bytes.size < 8192) {
                    if (peer.read(one) == 0) { return }
                    bytes.add(one[0])
                    let n = bytes.size
                    if (n >= 4 && bytes[n - 4] == 13 && bytes[n - 3] == 10 && bytes[n - 2] == 13 && bytes[n - 1] == 10) { break }
                }
            }
            if (this.mode == "body") {
                peer.write("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n{}".toArray())
            } else if (this.mode == "invalid-utf8") {
                peer.write("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n".toArray())
                peer.write([255u8])
                this.entered.store(true)
                return
            } else if (this.mode == "bad-tls") {
                peer.write("not TLS 中文😀".toArray())
                this.entered.store(true)
                return
            }
            this.entered.store(true)
            let buffer = Array<Byte>(1024, repeat: 0)
            try {
                while (peer.read(buffer) > 0) { () }
                this.eof.fetchAdd(1)
            } catch (_: SocketTimeoutException) {
                // A peer timeout is not proof that the client released its socket.
            } catch (_: SocketException) {
                this.eof.fetchAdd(1)
            }
        }
    }

    func close(): Unit { this.listener.close() }
}

private func shutdownCheckNativeCancellation(mode: String): Unit {
    setTelegramTransportRunnerForTest(None)
    let peer = ShutdownHeldPeer(mode)
    let serving = TelegramShutdownWorker()
    serving.start({ => peer.serve() })
    let owner = TelegramRequestOwner()
    let proxy = if (mode == "connect") { "http://127.0.0.1:${peer.port}" } else { "" }
    let transport = TelegramTransport(proxy: proxy, timeoutSeconds: 30, insecureSkipTlsVerify: true, dangerouslyAllowPrivateNetwork: true)
    transport.useRequestOwner(owner)
    let outcome = AtomicInt64(0)
    let polling = TelegramPollingRunner(
        { =>
            let scheme = if (mode == "connect" || mode == "tls") { "https" } else { "http" }
            let response = transport.get("${scheme}://127.0.0.1:${peer.port}/owned")
            outcome.store(if (response.outcome == "cancelled") { 1 } else { 2 })
            ""
        },
        { _: String => 0 },
        { => true }
    )
    try {
        polling.start()
        @Expect(shutdownWaitFor({ => peer.entered.load() }), true)
        @Expect(owner.activeCount(), 1)
        let deadline = MonoTime.now() + Duration.millisecond * 500
        polling.stop()
        owner.cancel()
        @Expect(polling.awaitShutdown(deadline), 0)
        @Expect(owner.awaitUntil(deadline), 0)
        @Expect(serving.awaitUntil(deadline), true)
        @Expect(peer.eof.load(), 1)
        @Expect(outcome.load(), 1)
        @Expect(polling.pendingWorkerCount(), 0)
        @Expect(transport.get("http://127.0.0.1:${peer.port}/forbidden").outcome, "cancelled")
        @Expect(owner.activeCount(), 0)
    } finally {
        polling.stop()
        owner.cancel()
        peer.close()
        polling.awaitShutdown(MonoTime.now() + Duration.second * 3)
        serving.awaitUntil(MonoTime.now() + Duration.second * 3)
    }
}

@Test
public class TelegramShutdownTest {
    @TestCase
    public func s1U1NativePollWatchdogAndRequestsReallySettle(): Unit {
        for (mode in ["header", "body", "connect", "tls"]) { shutdownCheckNativeCancellation(mode) }
    }

    @TestCase
    public func s1B1CancelledRegistrationAndOldOwnerCannotCloseNewOwner(): Unit {
        let oldOwner = TelegramRequestOwner()
        let old = oldOwner.beginRequest().getOrThrow()
        oldOwner.cancel()
        let unhanded = TcpSocket("127.0.0.1", 1u16)
        @Expect(old.attachSocket(unhanded), false)
        @Expect(unhanded.isClosed(), true)
        @Expect(oldOwner.activeCount(), 1)
        let newOwner = TelegramRequestOwner()
        let current = newOwner.beginRequest().getOrThrow()
        old.finish()
        oldOwner.cancel()
        @Expect(oldOwner.awaitUntil(MonoTime.now() + Duration.second), 0)
        @Expect(newOwner.activeCount(), 1)
        @Expect(current.isCancelled(), false)
        current.finish()
        @Expect(newOwner.activeCount(), 0)
    }

    @TestCase
    public func s1P1OffsetConfirmedOnceAndRestartDoesNotReplay(): Unit {
        let root = shutdownRoot("positive")
        let confirmations = AtomicInt64(0)
        let correctOffset = AtomicBool(false)
        let polls = AtomicInt64(0)
        setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
            if (request.context == "getUpdates:stop-confirm") {
                confirmations.fetchAdd(1)
                let body = JsonValue.fromStr(request.body).asObject()
                correctOffset.store(body.get("offset").getOrThrow().asInt().getValue() == 43)
            } else if (request.context == "getUpdates") { polls.fetchAdd(1) }
            shutdownOrdinaryResponse()
        }))
        let adapter = shutdownAdapter(root)
        try {
            adapter.start()
            @Expect(shutdownWaitFor({ => polls.load() > 0 }), true)
            adapter.ingestWebhookPayload(shutdownUpdate42)
            @Expect(adapter.debugLastInboundUpdateId(), "42")
            @Expect(adapter.pullInbound().size, 1)
            let deadline = MonoTime.now() + Duration.second
            adapter.beginShutdown(deadline)
            let result = adapter.awaitShutdown(deadline)
            @Expect(result.ok, true)
            @Expect(result.pendingCount, 0)
            @Expect(confirmations.load(), 1)
            @Expect(correctOffset.load(), true)
            @Expect(adapter.debugLastConfirmedPollingOffsetForTest(), "43")
            @Expect(adapter.awaitShutdown(deadline).ok, true)
            @Expect(confirmations.load(), 1)
            let previousPolls = polls.load()
            adapter.start()
            @Expect(shutdownWaitFor({ => polls.load() > previousPolls }), true)
            @Expect(adapter.debugIngestPollingResponse("{\"ok\":true,\"result\":[${shutdownUpdate42}]}"), 0)
            @Expect(adapter.pullInbound().size, 0)
        } finally {
            adapter.stop()
            setTelegramTransportRunnerForTest(None)
            remove(root, recursive: true)
        }
        @Expect(exists(root), false)
    }

    @TestCase
    public func s1B1ExpiredAndTinyDeadlinesNeverStartConfirmation(): Unit {
        for (budget in [0, 1]) {
            let root = shutdownRoot("deadline")
            let confirmations = AtomicInt64(0)
            let polls = AtomicInt64(0)
            setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
                if (request.context == "getUpdates:stop-confirm") { confirmations.fetchAdd(1) }
                if (request.context == "getUpdates") { polls.fetchAdd(1) }
                shutdownOrdinaryResponse()
            }))
            let adapter = shutdownAdapter(root)
            try {
                adapter.start()
                @Expect(shutdownWaitFor({ => polls.load() > 0 }), true)
                adapter.ingestWebhookPayload(shutdownUpdate42)
                let deadline = MonoTime.now() + Duration.millisecond * budget
                adapter.beginShutdown(deadline)
                adapter.awaitShutdown(deadline)
                @Expect(confirmations.load(), 0)
                sleep(Duration.millisecond * 50)
                @Expect(adapter.awaitShutdown(MonoTime.now() + Duration.second).pendingCount, 0)
                @Expect(confirmations.load(), 0)
                @Expect(adapter.debugLastInboundUpdateId(), "42")
                @Expect(adapter.debugLastConfirmedPollingOffsetForTest(), "")
            } finally {
                adapter.stop()
                setTelegramTransportRunnerForTest(None)
                remove(root, recursive: true)
            }
        }
    }

    @TestCase
    public func s1N1UncooperativeOverrideKeepsOwnerUntilExecutionFinally(): Unit {
        let root = shutdownRoot("pending")
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let executionFinally = AtomicBool(false)
        let polls = AtomicInt64(0)
        setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
            if (request.context == "getUpdates") {
                polls.fetchAdd(1)
                entered.store(true)
                try {
                    while (!release.load()) { sleep(Duration.millisecond) }
                } finally { executionFinally.store(true) }
            }
            shutdownOrdinaryResponse()
        }))
        let adapter = shutdownAdapter(root)
        try {
            adapter.start()
            @Expect(shutdownWaitFor({ => entered.load() }), true)
            let before = MonoTime.now()
            let deadline = before + Duration.millisecond * 30
            adapter.beginShutdown(deadline)
            let result = adapter.awaitShutdown(deadline)
            @Expect((MonoTime.now() - before).toMilliseconds() < 200, true)
            @Expect(result.ok, false)
            @Expect(result.status, "cleanup_pending")
            @Expect(result.pendingCount > 0, true)
            @Expect(executionFinally.load(), false)
            adapter.start()
            sleep(Duration.millisecond * 20)
            @Expect(polls.load(), 1)
            @Expect(adapter.awaitShutdown(deadline).pendingCount > 0, true)
            release.store(true)
            @Expect(shutdownWaitFor({ => executionFinally.load() }), true)
            @Expect(shutdownWaitFor({ => adapter.awaitShutdown(deadline).pendingCount == 0 }), true)
            adapter.start()
            @Expect(shutdownWaitFor({ => polls.load() >= 2 }), true)
        } finally {
            release.store(true)
            adapter.stop()
            setTelegramTransportRunnerForTest(None)
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func s1B2ConfirmationFailuresAreIsolatedAndDoNotExposePayloads(): Unit {
        let secretBody = "中文😀synthetic-stop-token https://private.example/body /private/fixture " + String(Array<Rune>(10000, repeat: r'中'))
        for (kind in ["malformed", "encoding", "exception", "api"]) {
            let root = shutdownRoot("safe")
            let polls = AtomicInt64(0)
            setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
                if (request.context == "getUpdates") { polls.fetchAdd(1) }
                if (request.context != "getUpdates:stop-confirm") { return shutdownOrdinaryResponse() }
                if (kind == "exception") { throw Exception(secretBody) }
                if (kind == "encoding") { return TelegramTransportResponse(false, error: secretBody, outcome: "invalid-response-body") }
                TelegramTransportResponse(true, body: if (kind == "malformed") { "{${secretBody}" } else { "{\"ok\":false}" }, outcome: "ok")
            }))
            let adapter = shutdownAdapter(root)
            try {
                adapter.start()
                @Expect(shutdownWaitFor({ => polls.load() > 0 }), true)
                adapter.ingestWebhookPayload(shutdownUpdate42)
                let deadline = MonoTime.now() + Duration.second
                adapter.beginShutdown(deadline)
                let result = adapter.awaitShutdown(deadline)
                @Expect(result.ok, true)
                @Expect(result.pendingCount, 0)
                let expected = if (kind == "malformed") { "offset_confirm_malformed_json" } else if (kind == "encoding") { "offset_confirm_invalid_response_encoding" } else { "offset_confirm_failed" }
                @Expect(result.diagnostic, expected)
                @Expect(result.diagnostic.contains("synthetic-stop-token"), false)
                @Expect(result.diagnostic.contains("private"), false)
                @Expect(result.diagnostic.contains("中文"), false)
                @Expect(adapter.debugLastInboundUpdateId(), "42")
                @Expect(adapter.debugLastConfirmedPollingOffsetForTest(), "")
            } finally {
                adapter.stop()
                setTelegramTransportRunnerForTest(None)
                remove(root, recursive: true)
            }
        }
    }

    @TestCase
    public func s1N1ConfirmationCapAndRepeatedAwaitKeepPendingOwner(): Unit {
        let root = shutdownRoot("confirm-cap")
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let finallyDone = AtomicBool(false)
        let confirmations = AtomicInt64(0)
        setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
            if (request.context == "getUpdates:stop-confirm") {
                confirmations.fetchAdd(1)
                entered.store(true)
                try {
                    while (!release.load()) { sleep(Duration.millisecond) }
                } finally { finallyDone.store(true) }
            }
            shutdownOrdinaryResponse()
        }))
        let adapter = shutdownAdapter(root)
        try {
            adapter.start()
            adapter.ingestWebhookPayload(shutdownUpdate42)
            let before = MonoTime.now()
            let deadline = before + Duration.millisecond * 350
            adapter.beginShutdown(deadline)
            let result = adapter.awaitShutdown(deadline)
            let elapsed = (MonoTime.now() - before).toMilliseconds()
            @Expect(entered.load(), true)
            @Expect(elapsed >= 250 && elapsed < 550, true)
            @Expect(result.ok, false)
            @Expect(result.pendingCount > 0, true)
            @Expect(finallyDone.load(), false)
            @Expect(confirmations.load(), 1)
            let secondStarted = MonoTime.now()
            @Expect(adapter.awaitShutdown(MonoTime.now() + Duration.second * 5).pendingCount > 0, true)
            @Expect((MonoTime.now() - secondStarted).toMilliseconds() < 50, true)
            @Expect(adapter.debugLastConfirmedPollingOffsetForTest(), "")
            release.store(true)
            @Expect(shutdownWaitFor({ => adapter.awaitShutdown(deadline).pendingCount == 0 }), true)
            let settled = adapter.awaitShutdown(deadline)
            @Expect(settled.ok, true)
            @Expect(settled.diagnostic, "offset_confirm_timeout")
            @Expect(adapter.debugLastInboundUpdateId(), "42")
            @Expect(adapter.debugLastConfirmedPollingOffsetForTest(), "")
        } finally {
            release.store(true)
            adapter.stop()
            shutdownWaitFor({ => adapter.awaitShutdown(MonoTime.now()).pendingCount == 0 })
            setTelegramTransportRunnerForTest(None)
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func s1N1NativeCommandWorkerAlsoRetainsItsExecutionHandle(): Unit {
        let root = shutdownRoot("native-worker")
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let finallyDone = AtomicBool(false)
        setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
            if (request.context == "deleteMyCommands") {
                entered.store(true)
                try {
                    while (!release.load()) { sleep(Duration.millisecond) }
                } finally { finallyDone.store(true) }
            }
            shutdownOrdinaryResponse()
        }))
        let adapter = shutdownAdapter(root, nativeCommands: true)
        try {
            adapter.start()
            @Expect(shutdownWaitFor({ => entered.load() }), true)
            let deadline = MonoTime.now() + Duration.millisecond * 20
            adapter.beginShutdown(deadline)
            @Expect(adapter.awaitShutdown(deadline).pendingCount > 0, true)
            @Expect(finallyDone.load(), false)
            release.store(true)
            @Expect(shutdownWaitFor({ => adapter.awaitShutdown(deadline).pendingCount == 0 }), true)
            @Expect(finallyDone.load(), true)
        } finally {
            release.store(true)
            adapter.stop()
            shutdownWaitFor({ => adapter.awaitShutdown(MonoTime.now()).pendingCount == 0 })
            setTelegramTransportRunnerForTest(None)
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func s1B1WatchdogRestartRetainsEveryOldLoopUntilFinally(): Unit {
        let release = AtomicBool(false)
        let fetches = AtomicInt64(0)
        let ingests = AtomicInt64(0)
        let runner = TelegramPollingRunner(
            { =>
                fetches.fetchAdd(1)
                while (!release.load()) { sleep(Duration.millisecond) }
                "old-or-current-generation"
            },
            { _: String => ingests.fetchAdd(1); 1 },
            { => true },
            watchdogStallMs: 10,
            watchdogIntervalMs: 2
        )
        try {
            runner.start()
            @Expect(shutdownWaitFor({ => fetches.load() >= 2 }), true)
            runner.stop()
            @Expect(runner.awaitShutdown(MonoTime.now() + Duration.millisecond * 10) >= 2, true)
            @Expect(ingests.load(), 0)
            runner.start()
            let stoppedFetches = fetches.load()
            sleep(Duration.millisecond * 15)
            @Expect(fetches.load(), stoppedFetches)
            release.store(true)
            @Expect(runner.awaitShutdown(MonoTime.now() + Duration.second), 0)
            @Expect(ingests.load(), 0)
            runner.start()
            @Expect(shutdownWaitFor({ => ingests.load() > 0 }), true)
        } finally {
            release.store(true)
            runner.stop()
            @Expect(runner.awaitShutdown(MonoTime.now() + Duration.second), 0)
        }
    }

    @TestCase
    public func s1N1B2RefusalTlsFailureAndBinaryUtf8ReleaseTheirScopes(): Unit {
        setTelegramTransportRunnerForTest(None)
        for (mode in ["invalid-utf8", "bad-tls"]) {
            let peer = ShutdownHeldPeer(mode)
            let serving = TelegramShutdownWorker()
            serving.start({ => peer.serve() })
            let owner = TelegramRequestOwner()
            let transport = TelegramTransport(timeoutSeconds: 1, insecureSkipTlsVerify: true, dangerouslyAllowPrivateNetwork: true)
            transport.useRequestOwner(owner)
            try {
                let scheme = if (mode == "bad-tls") { "https" } else { "http" }
                let response = transport.get("${scheme}://127.0.0.1:${peer.port}/synthetic")
                @Expect(response.ok, false)
                if (mode == "invalid-utf8") { @Expect(response.outcome, "invalid-response-body") }
                @Expect(owner.activeCount(), 0)
                @Expect(serving.awaitUntil(MonoTime.now() + Duration.second), true)
            } finally {
                owner.cancel()
                peer.close()
                serving.awaitUntil(MonoTime.now() + Duration.second * 3)
            }
        }
        let refused = TcpServerSocket(bindAt: 0u16)
        refused.bind()
        let port = (refused.localAddress as IPSocketAddress)?.port ?? 0u16
        refused.close()
        let owner = TelegramRequestOwner()
        let transport = TelegramTransport(timeoutSeconds: 1, dangerouslyAllowPrivateNetwork: true)
        transport.useRequestOwner(owner)
        @Expect(transport.get("http://127.0.0.1:${port}/refused").ok, false)
        @Expect(owner.activeCount(), 0)
    }

    @TestCase
    public func s0B1NoProcessedInboundNeverRequestsConfirmation(): Unit {
        let root = shutdownRoot("no-offset")
        let confirmations = AtomicInt64(0)
        setTelegramTransportRunnerForTest(Some({ request: TelegramTransportRequest =>
            if (request.context == "getUpdates:stop-confirm") { confirmations.fetchAdd(1) }
            shutdownOrdinaryResponse()
        }))
        let adapter = shutdownAdapter(root)
        try {
            adapter.start()
            adapter.stop()
            @Expect(confirmations.load(), 0)
        } finally {
            adapter.stop()
            setTelegramTransportRunnerForTest(None)
            remove(root, recursive: true)
        }
    }
}
