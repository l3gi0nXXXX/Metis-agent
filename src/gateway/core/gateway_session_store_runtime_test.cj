package metis.gateway.core

import metis.core.config.{
    CliConfig,
    CliSettingManager,
    GatewayUserSettings,
    MetisConfigManager,
    MetisProcessEnvironmentLock
}
import metis.gateway.session.{
    GatewayDeliveryTarget,
    GatewayIngressSource,
    GatewaySessionRequest,
    gatewaySessionRequestFromRpcParams
}

import magic.jsonable.*
import std.collection.ArrayList
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private var gatewaySessionStoreRuntimePreviousHome = None<String>
private var gatewaySessionStoreRuntimeTestHome = ""

private func s2A1HistoryRecord(role: String, text: String): String {
    let row = JsonObject()
    row.put("role", JsonString(role))
    row.put("text", JsonString(text))
    row.toJsonString() + "\n"
}

private func s2A1WriteHistoryRecords(path: Path, count: Int64, textPrefix!: String = "entry-"): Unit {
    try (file = File(path, OpenMode.Write)) {
        for (index in 0..count) {
            file.write(s2A1HistoryRecord(if (index % 2 == 0) { "user" } else { "assistant" }, "${textPrefix}${index}").toArray())
        }
    }
}

private func s2A1AppendBytes(path: Path, bytes: Array<Byte>): Unit {
    try (file = File(path, OpenMode.Append)) {
        file.write(bytes)
    }
}

private func s2A1HistoryRecordAtEncodedSize(role: String, encodedBytes: Int64): String {
    let emptyRecord = s2A1HistoryRecord(role, "")
    let emptyEncodedBytes = Int64(emptyRecord.size) - 1
    if (encodedBytes < emptyEncodedBytes) {
        throw IllegalArgumentException("encoded history record target is too small")
    }
    let record = s2A1HistoryRecord(role, "x" * (encodedBytes - emptyEncodedBytes))
    if (Int64(record.size) - 1 != encodedBytes) {
        throw IllegalStateException("encoded history record target mismatch")
    }
    record
}

private func s2A1HistoryRecordAtLineSize(role: String, lineBytes: Int64): String {
    let prefix = "${role}: "
    if (lineBytes < Int64(prefix.size)) {
        throw IllegalArgumentException("history line target is too small")
    }
    s2A1HistoryRecord(role, "x" * (lineBytes - Int64(prefix.size)))
}

private func s2A1HistoryLineAtSize(role: String, lineBytes: Int64): String {
    let prefix = "${role}: "
    prefix + ("x" * (lineBytes - Int64(prefix.size)))
}

@Test
public class GatewaySessionStoreRuntimeTest {
    @BeforeAll
    public func isolateGatewaySessionStoreRuntimeHome(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            gatewaySessionStoreRuntimePreviousHome = getVariable("METIS_HOME")
            gatewaySessionStoreRuntimeTestHome = "/tmp/metis-session-store-runtime-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            let home = Path(gatewaySessionStoreRuntimeTestHome)
            try { remove(home, recursive: true) } catch (_: Exception) { () }
            Directory.create(home, recursive: true)
            setVariable("METIS_HOME", gatewaySessionStoreRuntimeTestHome)
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
        }
    }

    @AfterAll
    public func restoreGatewaySessionStoreRuntimeHome(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            match (gatewaySessionStoreRuntimePreviousHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            if (!gatewaySessionStoreRuntimeTestHome.isEmpty()) {
                try { remove(Path(gatewaySessionStoreRuntimeTestHome), recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func s1P1MemoryFootprintStatsTranscriptAndIndexWithoutDecodingContents(): Unit {
        let root = Path(gatewaySessionStoreRuntimeTestHome).join("memory-footprint")
        let store = GatewaySessionStore(root, enabled: true, agentId: "main")
        let sessionKey = "agent:main:memory-footprint"
        store.appendUser(sessionKey, "中文🙂")
        store.appendAssistant(sessionKey, "answer")
        File.writeTo(root.join("sessions.json"), "{}".toArray())
        let first = store.memoryFootprint(sessionKey)
        @Expect(first.transcriptBytes > 0, true)
        @Expect(first.sessionsIndexBytes > 0, true)

        let malformed: Array<UInt8> = [0xFF, 0xFE, 0x80]
        File.writeTo(store.transcriptPath(sessionKey), malformed)
        let malformedFootprint = store.memoryFootprint(sessionKey)
        @Expect(malformedFootprint.transcriptBytes, 3)
        @Expect(malformedFootprint.sessionsIndexBytes, first.sessionsIndexBytes)
        let missing = store.memoryFootprint("agent:main:missing")
        @Expect(missing.transcriptBytes, -1)
    }

    @TestCase
    public func s2A1U1RecentLoaderRetainsLastTwelveFromTenThousandRecords(): Unit {
        let root = Path(gatewaySessionStoreRuntimeTestHome).join("s2-a1-u1")
        Directory.create(root, recursive: true)
        let store = GatewaySessionStore(root, enabled: true, agentId: "main")
        let sessionKey = "agent:main:s2-a1-u1"
        s2A1WriteHistoryRecords(store.transcriptPath(sessionKey), 10000)

        let result = store.loadRecentHistoryLines(sessionKey, 12)
        let full = store.loadHistoryLines(sessionKey)
        @Expect(result.lines.size, 12)
        @Expect(result.lines[0], "user: entry-9988")
        @Expect(result.lines[11], "assistant: entry-9999")
        @Expect(result.validHistoryRecords, 10000)
        @Expect(result.droppedHistoryRecords, 9988)
        @Expect(result.totalScannedBytes, FileInfo(store.transcriptPath(sessionKey)).size)
        @Expect(result.retainedPayloadBytes <= 512 * 1024, true)
        @Expect(result.maxRetainedPayloadBytes <= 512 * 1024, true)
        @Expect(result.maxReadCallBytes > 0, true)
        @Expect(result.maxReadCallBytes <= 64 * 1024, true)
        @Expect(result.maxBufferedRecordBytes > 0, true)
        @Expect(result.maxBufferedRecordBytes <= 256 * 1024, true)
        @Expect(result.oversizeRecords, 0)
        @Expect(result.malformedRecords, 0)
        @Expect(result.invalidEncodingRecords, 0)
        @Expect(full.size, 10000)
        for (index in 0..12) {
            @Expect(result.lines[index], full[full.size - 12 + index])
        }
    }

    @TestCase
    public func s2A1B1RecentLoaderPreservesEntryAndFormattedMultilineBoundaries(): Unit {
        let root = Path(gatewaySessionStoreRuntimeTestHome).join("s2-a1-b1")
        Directory.create(root, recursive: true)
        let store = GatewaySessionStore(root, enabled: true, agentId: "main")
        for (count in [0, 1, 12, 13]) {
            let sessionKey = "agent:main:s2-a1-b1-${count}"
            s2A1WriteHistoryRecords(store.transcriptPath(sessionKey), count, textPrefix: "b-")
            let result = store.loadRecentHistoryLines(sessionKey, 12)
            @Expect(result.lines.size, min(count, 12))
            @Expect(result.droppedHistoryRecords, max(0, count - 12))
        }

        let multilineKey = "agent:main:s2-a1-b1-multiline"
        let multiline = """
{
  "role": "user",
  "text": "多行中文🙂"
}
{"role":"assistant","text":"尾记录"}
"""
        File.writeTo(store.transcriptPath(multilineKey), multiline.toArray())
        let multilineResult = store.loadRecentHistoryLines(multilineKey, 12)
        @Expect(multilineResult.lines, ["user: 多行中文🙂", "assistant: 尾记录"])
        @Expect(multilineResult.malformedRecords, 0)
        @Expect(multilineResult.unclosedRecords, 0)

        let roleKey = "agent:main:s2-a1-b1-role-compatibility"
        try (file = File(store.transcriptPath(roleKey), OpenMode.Write)) {
            file.write(s2A1HistoryRecord("system", "系统中文🙂").toArray())
            file.write(s2A1HistoryRecord("custom-tool", "工具结果🙂").toArray())
        }
        let roleResult = store.loadRecentHistoryLines(roleKey, 12)
        let fullRoleLines = store.loadHistoryLines(roleKey)
        @Expect(roleResult.lines, ["system: 系统中文🙂", "custom-tool: 工具结果🙂"])
        @Expect(roleResult.lines, fullRoleLines.toArray())

        let recordBoundaryKey = "agent:main:s2-a1-b1-record-boundary"
        let exactRecord = s2A1HistoryRecordAtEncodedSize("system", 256 * 1024)
        let oversizeRecord = s2A1HistoryRecordAtEncodedSize("custom-tool", 256 * 1024 + 1)
        let boundaryTail = s2A1HistoryRecord("assistant", "boundary-tail")
        try (file = File(store.transcriptPath(recordBoundaryKey), OpenMode.Write)) {
            file.write(exactRecord.toArray())
            file.write(oversizeRecord.toArray())
            file.write(boundaryTail.toArray())
        }
        let recordBoundary = store.loadRecentHistoryLines(recordBoundaryKey, 12)
        let exactRecordTextBytes = 256 * 1024 - (Int64(s2A1HistoryRecord("system", "").size) - 1)
        let exactRecordLine = "system: " + ("x" * exactRecordTextBytes)
        @Expect(Int64(exactRecord.size) - 1, 256 * 1024)
        @Expect(Int64(oversizeRecord.size) - 1, 256 * 1024 + 1)
        @Expect(recordBoundary.lines, [exactRecordLine, "assistant: boundary-tail"])
        @Expect(recordBoundary.validHistoryRecords, 2)
        @Expect(recordBoundary.oversizeRecords, 1)
        @Expect(recordBoundary.maxBufferedRecordBytes, 256 * 1024)
    }

    @TestCase
    public func s2A1P1RecentLoaderBoundsChunkRecordAndAggregatePayload(): Unit {
        let root = Path(gatewaySessionStoreRuntimeTestHome).join("s2-a1-p1")
        Directory.create(root, recursive: true)
        let store = GatewaySessionStore(root, enabled: true, agentId: "main")
        let exactKey = "agent:main:s2-a1-p1-exact"
        let exactRecords = [
            s2A1HistoryRecordAtLineSize("first", 174762),
            s2A1HistoryRecordAtLineSize("second", 174762),
            s2A1HistoryRecordAtLineSize("third", 174764)
        ]
        try (file = File(store.transcriptPath(exactKey), OpenMode.Write)) {
            for (record in exactRecords) {
                file.write(record.toArray())
            }
        }
        let exact = store.loadRecentHistoryLines(exactKey, 12)
        let exactExpected = [
            s2A1HistoryLineAtSize("first", 174762),
            s2A1HistoryLineAtSize("second", 174762),
            s2A1HistoryLineAtSize("third", 174764)
        ]
        @Expect(exact.lines, exactExpected)
        @Expect(exact.validHistoryRecords, 3)
        @Expect(exact.droppedHistoryRecords, 0)
        @Expect(exact.retainedPayloadBytes, 512 * 1024)
        @Expect(exact.maxRetainedPayloadBytes, 512 * 1024)
        @Expect(exact.maxReadCallBytes > 0, true)
        @Expect(exact.maxReadCallBytes <= 64 * 1024, true)
        @Expect(exact.maxBufferedRecordBytes > 0, true)
        @Expect(exact.maxBufferedRecordBytes <= 256 * 1024, true)

        let overflowKey = "agent:main:s2-a1-p1-overflow"
        let overflowRecords = [
            s2A1HistoryRecordAtLineSize("first", 174762),
            s2A1HistoryRecordAtLineSize("second", 174762),
            s2A1HistoryRecordAtLineSize("third", 174762),
            s2A1HistoryRecord("x", "")
        ]
        try (file = File(store.transcriptPath(overflowKey), OpenMode.Write)) {
            for (record in overflowRecords) {
                file.write(record.toArray())
            }
        }
        let overflow = store.loadRecentHistoryLines(overflowKey, 12)
        let overflowExpected = [
            s2A1HistoryLineAtSize("second", 174762),
            s2A1HistoryLineAtSize("third", 174762),
            "x: "
        ]
        @Expect(174762 * 3 + Int64("x: ".size), 512 * 1024 + 1)
        @Expect(overflow.lines, overflowExpected)
        @Expect(overflow.validHistoryRecords, 4)
        @Expect(overflow.droppedHistoryRecords, 1)
        @Expect(overflow.retainedPayloadBytes, 174762 * 2 + Int64("x: ".size))
        @Expect(overflow.maxRetainedPayloadBytes, 174762 * 3)
    }

    @TestCase
    public func s2A1N1RecentLoaderIsolatesInvalidOversizeMalformedAndUnclosedRecords(): Unit {
        let root = Path(gatewaySessionStoreRuntimeTestHome).join("s2-a1-n1")
        Directory.create(root, recursive: true)
        let store = GatewaySessionStore(root, enabled: true, agentId: "main")
        let sessionKey = "agent:main:s2-a1-n1"
        let path = store.transcriptPath(sessionKey)
        File.writeTo(path, s2A1HistoryRecord("user", "安全开始中文🙂").toArray())

        let invalid = ArrayList<Byte>()
        invalid.add(all: "{\"role\":\"user\",\"text\":\"".toArray())
        invalid.add(0xFF)
        invalid.add(all: "\"}\n".toArray())
        s2A1AppendBytes(path, invalid.toArray())
        s2A1AppendBytes(path, "{not-json}\n".toArray())
        s2A1AppendBytes(path, s2A1HistoryRecord("assistant", "x" * (256 * 1024 + 32)).toArray())
        s2A1AppendBytes(path, s2A1HistoryRecord("assistant", "oversize后安全🙂").toArray())
        s2A1AppendBytes(path, "{\"role\":\"user\",\"text\":\"未闭合🙂\"".toArray())

        let result = store.loadRecentHistoryLines(sessionKey, 12)
        @Expect(result.lines, ["user: 安全开始中文🙂", "assistant: oversize后安全🙂"])
        @Expect(result.invalidEncodingRecords, 1)
        @Expect(result.oversizeRecords, 1)
        @Expect(result.unclosedRecords, 1)
        @Expect(result.malformedRecords, 2)
        @Expect(result.maxBufferedRecordBytes <= 256 * 1024, true)
        @Expect(result.maxReadCallBytes <= 64 * 1024, true)
        let retainedText = String.join(result.lines, delimiter: "\n")
        @Expect(retainedText.contains("not-json"), false)
        @Expect(retainedText.contains("未闭合"), false)
    }

    @TestCase
    public func concurrentLegacySessionMigrationSerializesDirectoryWalks(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let oldHome = getVariable("METIS_HOME")
            let home = Path("/tmp/metis-session-migration-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            try { remove(home, recursive: true) } catch (_: Exception) { () }
            Directory.create(home, recursive: true)
            setVariable("METIS_HOME", home.toString())
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            try {
                let root = home.join("agents").join("main").join("sessions")
                let futures = ArrayList<Future<Unit>>()
                for (_ in 0..8) {
                    futures.add(spawn { gatewayMigrateLegacyGatewaySessionsIfNeeded(root) })
                }
                for (future in futures) {
                    future.get()
                }
                @Expect(exists(root), true)

                let store = GatewaySessionStore(root, enabled: true, agentId: "main")
                store.appendUser("agent:main:concurrent-migration", "中文🙂")
                let user = GatewayUserSettings()
                let listings = ArrayList<Future<Int64>>()
                for (_ in 0..8) {
                    listings.add(spawn { gatewayListSessionLocationsForUser(user).size })
                }
                for (listing in listings) {
                    @Expect(listing.get() > 0, true)
                }

                let cronStores = ArrayList<Future<String>>()
                for (idx in 0..8) {
                    let jobId = "job-${idx}"
                    cronStores.add(spawn {
                        gatewaySessionStoreForResolvedRequest(
                            user,
                            GatewaySessionRequest(
                                GatewayIngressSource.Cron,
                                channelName: "cron",
                                sessionHint: "cron:${jobId}",
                                agentId: "main",
                                cronJobId: jobId
                            )
                        ).sessionsRoot().toString()
                    })
                }
                for (cronStore in cronStores) {
                    @Expect(cronStore.get(), root.toString())
                }

                remove(root, recursive: true)
                gatewayMigrateLegacyGatewaySessionsIfNeeded(root)
                @Expect(exists(root), true)
            } finally {
                match (oldHome) {
                    case Some(value) => setVariable("METIS_HOME", value)
                    case None => setVariable("METIS_HOME", "")
                }
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                try { remove(home, recursive: true) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func listSessionLocationsAggregatesAcrossAgentRoots(): Unit {
        let user = GatewayUserSettings()
        let mainStore = gatewaySessionStoreForUserWithAgentId(user, "main")
        let generalStore = gatewaySessionStoreForUserWithAgentId(user, "general")
        let mainKey = "agent:main:runtime-test"
        let generalKey = "agent:general:runtime-test"
        mainStore.deleteSession(mainKey)
        generalStore.deleteSession(generalKey)
        mainStore.appendUser(mainKey, "main")
        generalStore.appendUser(generalKey, "general")

        let locations = gatewayListSessionLocationsForUser(user)
        var sawMain = false
        var sawGeneral = false
        for (entry in locations) {
            if (entry.sessionKey == mainKey && entry.agentId == "main") {
                sawMain = true
            }
            if (entry.sessionKey == generalKey && entry.agentId == "general") {
                sawGeneral = true
            }
        }
        @Expect(sawMain, true)
        @Expect(sawGeneral, true)

        mainStore.deleteSession(mainKey)
        generalStore.deleteSession(generalKey)
    }

    @TestCase
    public func findSessionLocationReturnsOwningAgentRoot(): Unit {
        let user = GatewayUserSettings()
        let generalStore = gatewaySessionStoreForUserWithAgentId(user, "general")
        let sessionKey = "agent:general:location-test"
        generalStore.deleteSession(sessionKey)
        generalStore.appendUser(sessionKey, "hello")

        let location = gatewayFindSessionLocationForUser(user, sessionKey).getOrThrow()
        @Expect(location.agentId, "general")
        @Expect(location.sessionKey, sessionKey)
        @Expect(location.root.toString(), generalStore.sessionsRoot().toString())

        generalStore.deleteSession(sessionKey)
    }

    @TestCase
    public func resolvedRequestStoreUsesResolvedAgentContext(): Unit {
        let user = GatewayUserSettings()
        let params = JsonObject()
        params.put("session", JsonString("agent:general:main"))
        let request = gatewaySessionRequestFromRpcParams(params, fallbackSource: GatewayIngressSource.Cli)
        let store = gatewaySessionStoreForResolvedRequest(user, request)
        let generalStore = gatewaySessionStoreForUserWithAgentId(user, "general")
        @Expect(store.sessionsRoot().toString(), generalStore.sessionsRoot().toString())
    }

    @TestCase
    public func sessionKeyStoreHelperUsesResolvedAgentContext(): Unit {
        let user = GatewayUserSettings()
        let store = gatewaySessionStoreForSessionKey(user, "agent:general:main")
        let generalStore = gatewaySessionStoreForUserWithAgentId(user, "general")
        @Expect(store.sessionsRoot().toString(), generalStore.sessionsRoot().toString())
    }

    @TestCase
    public func sessionCatalogRowsExposeTranscriptMetadata(): Unit {
        let user = GatewayUserSettings()
        let store = gatewaySessionStoreForUserWithAgentId(user, "general")
        let sessionKey = "agent:general:catalog-row-test"
        store.deleteSession(sessionKey)
        store.appendUser(sessionKey, "hello")

        let rows = gatewayListSessionCatalogRowsForUser(user)
        var found = false
        for (row in rows) {
            if (row.sessionKey != sessionKey) {
                continue
            }
            found = true
            @Expect(row.agentId, "general")
            @Expect(row.sessionId.contains(".jsonl"), false)
            @Expect(row.sessionFile.endsWith(".jsonl"), true)
            @Expect(row.root.toString(), store.sessionsRoot().toString())
            @Expect(row.updatedAt > 0, true)
        }
        @Expect(found, true)

        store.deleteSession(sessionKey)
    }

    @TestCase
    public func findSessionCatalogRowReturnsOwningMetadata(): Unit {
        let user = GatewayUserSettings()
        let store = gatewaySessionStoreForUserWithAgentId(user, "general")
        let sessionKey = "agent:general:catalog-find-test"
        store.deleteSession(sessionKey)
        store.appendUser(sessionKey, "hello")

        let row = gatewayFindSessionCatalogRowForUser(user, sessionKey).getOrThrow()
        @Expect(row.agentId, "general")
        @Expect(row.sessionKey, sessionKey)
        @Expect(row.root.toString(), store.sessionsRoot().toString())

        store.deleteSession(sessionKey)
    }

    @TestCase
    public func projectSessionCatalogRowDerivesChannelAndDisplayName(): Unit {
        let qqRow = GatewaySessionCatalogRow(
            "main",
            "qq:group:chat-42",
            gatewaySessionStoreForUserWithAgentId(GatewayUserSettings(), "main").sessionsRoot(),
            "qq_group_chat_42",
            "qq_group_chat_42.jsonl",
            1
        )
        let qqView = gatewayProjectSessionCatalogRow(qqRow)
        @Expect(qqView.channel, "qq")
        @Expect(qqView.chatType, "group")
        @Expect(qqView.peer, "chat-42")
        @Expect(qqView.displayName, "chat-42")

        let cliRow = GatewaySessionCatalogRow(
            "main",
            "cli:main",
            gatewaySessionStoreForUserWithAgentId(GatewayUserSettings(), "main").sessionsRoot(),
            "cli_main",
            "cli_main.jsonl",
            1
        )
        let cliView = gatewayProjectSessionCatalogRow(cliRow)
        @Expect(cliView.channel, "cli")
        @Expect(cliView.chatType, "direct")
        @Expect(cliView.displayName, "CLI")

        let qqOrigin = gatewayBuildSessionCatalogOrigin(qqView)
        @Expect(qqOrigin.get("provider").getOrThrow().asString().getValue(), "qq")
        @Expect(qqOrigin.get("to").getOrThrow().asString().getValue(), "chat-42")

        let cliOrigin = gatewayBuildSessionCatalogOrigin(cliView)
        @Expect(cliOrigin.get("surface").getOrThrow().asString().getValue(), "cli")
        @Expect(cliOrigin.get("from").getOrThrow().asString().getValue(), "local-user")

        let qqConversation = gatewayBuildSessionConversationView(qqView)
        @Expect(qqConversation.displayName, "chat-42")
        @Expect(qqConversation.origin.get("to").getOrThrow().asString().getValue(), "chat-42")
        @Expect(qqConversation.delivery.get("channel").getOrThrow().asString().getValue(), "qq")
        @Expect(qqConversation.delivery.get("replyTo").getOrThrow().asString().getValue(), "chat-42")
        @Expect(qqConversation.delivery.get("conversationId").getOrThrow().asString().getValue(), "chat-42")
        @Expect(qqConversation.delivery.get("replyToMessageId").getOrThrow().asString().getValue(), "")
        @Expect(qqConversation.delivery.get("replyInThread").getOrThrow().asBool().getValue(), false)
        @Expect(qqConversation.binding.get("conversationId").getOrThrow().asString().getValue(), "chat-42")
        @Expect(qqConversation.binding.get("replyTargetMessageId").getOrThrow().asString().getValue(), "")
    }

    @TestCase
    public func catalogRowReplaysLatestBindingSnapshotFromTranscript(): Unit {
        let user = GatewayUserSettings()
        let store = gatewaySessionStoreForUserWithAgentId(user, "main")
        let sessionKey = "feishu:group:chat-ou_phase10"
        store.deleteSession(sessionKey)
        store.appendUser(sessionKey, "hello")
        store.appendBindingSnapshot(
            sessionKey,
            GatewayDeliveryTarget(
                "feishu",
                "chat-ou_phase10",
                accountId: "feishu:bot-default",
                conversationId: "chat-ou_phase10",
                threadId: "thread-42",
                sourceMessageId: "msg-source-42",
                replyToMessageId: "msg-root-42",
                replyInThread: true
            )
        )

        let row = gatewayFindSessionCatalogRowForUser(user, sessionKey).getOrThrow()
        @Expect(row.deliverySnapshot.get("threadId").getOrThrow().asString().getValue(), "thread-42")
        @Expect(row.bindingSnapshot.get("replyTargetMessageId").getOrThrow().asString().getValue(), "msg-root-42")

        let conversation = gatewayFindSessionConversationViewForUser(user, sessionKey).getOrThrow()
        @Expect(conversation.delivery.get("threadId").getOrThrow().asString().getValue(), "thread-42")
        @Expect(conversation.delivery.get("sourceMessageId").getOrThrow().asString().getValue(), "msg-source-42")
        @Expect(conversation.delivery.get("replyToMessageId").getOrThrow().asString().getValue(), "msg-root-42")
        @Expect(conversation.binding.get("replyTargetMessageId").getOrThrow().asString().getValue(), "msg-root-42")
        @Expect(conversation.binding.get("replyInThread").getOrThrow().asBool().getValue(), true)

        store.deleteSession(sessionKey)
    }

    @TestCase
    public func projectSessionCatalogRowPrefersBindingSnapshotIdentity(): Unit {
        let binding = JsonObject()
        binding.put("channel", JsonString("plugin-demo"))
        binding.put("peer", JsonString("conversation-99"))
        binding.put("conversationId", JsonString("conversation-99"))
        binding.put("accountId", JsonString("plugin-demo:acct-1"))
        let row = GatewaySessionCatalogRow(
            "main",
            "gateway:peer:user-42",
            gatewaySessionStoreForUserWithAgentId(GatewayUserSettings(), "main").sessionsRoot(),
            "gateway_peer_user_42",
            "gateway_peer_user_42.jsonl",
            1,
            bindingSnapshot: binding
        )
        let view = gatewayProjectSessionCatalogRow(row)
        @Expect(view.channel, "plugin-demo")
        @Expect(view.peer, "conversation-99")
        @Expect(view.displayName, "conversation-99")
        let origin = gatewayBuildSessionCatalogOrigin(view)
        @Expect(origin.get("provider").getOrThrow().asString().getValue(), "plugin-demo")
        @Expect(origin.get("to").getOrThrow().asString().getValue(), "conversation-99")
        @Expect(origin.get("accountId").getOrThrow().asString().getValue(), "plugin-demo:acct-1")
    }

    @TestCase
    public func catalogRowsReplaySessionsJsonMetadata(): Unit {
        let user = GatewayUserSettings()
        let store = gatewaySessionStoreForUserWithAgentId(user, "general")
        let sessionKey = "agent:general:metadata-row-test"
        store.deleteSession(sessionKey)
        store.appendUser(sessionKey, "hello")

        let root = JsonObject()
        let entry = JsonObject()
        entry.put("sessionKey", JsonString(sessionKey))
        entry.put("updatedAt", 123.toJsonValue())
        entry.put("sessionFile", JsonString("agent_general_metadata-row-test.jsonl"))
        entry.put("sessionId", JsonString("agent_general_metadata-row-test"))
        entry.put("sendPolicy", JsonString("deny"))
        entry.put("verboseLevel", JsonString("on"))
        entry.put("responseUsage", JsonString("full"))
        entry.put("fastMode", true.toJsonValue())
        entry.put("lastChannel", JsonString("telegram"))
        entry.put("lastTo", JsonString("-100123"))
        entry.put("lastAccountId", JsonString("acct-1"))
        entry.put("lastThreadId", 42.toJsonValue())
        entry.put("modelProvider", JsonString("openai"))
        entry.put("model", JsonString("gpt-5.4"))
        entry.put("contextTokens", 123456.toJsonValue())
        entry.put("totalTokens", 2400.toJsonValue())
        entry.put("totalTokensFresh", true.toJsonValue())
        entry.put("estimatedCostUsd", 0.0042.toJsonValue())
        entry.put("spawnedBy", JsonString("agent:main:main"))
        entry.put("spawnedWorkspaceDir", JsonString("/tmp/subagent-workspace"))
        entry.put("forkedFromParent", true.toJsonValue())
        entry.put("spawnDepth", 2.toJsonValue())
        entry.put("subagentRole", JsonString("orchestrator"))
        entry.put("subagentControlScope", JsonString("children"))
        entry.put("parentSessionKey", JsonString("agent:main:main"))
        let children = JsonArray([])
        children.add(JsonString("agent:general:child"))
        entry.put("childSessions", children)
        root.put(sessionKey, entry)
        File.writeTo(store.sessionsRoot().join("sessions.json"), root.toJsonString().toArray())

        let row = gatewayFindSessionCatalogRowForUser(user, sessionKey).getOrThrow()
        @Expect(row.sendPolicy, "deny")
        @Expect(row.verboseLevel, "on")
        @Expect(row.responseUsage, "full")
        @Expect(row.fastMode, true)
        @Expect(row.lastChannel, "telegram")
        @Expect(row.lastTo, "-100123")
        @Expect(row.lastAccountId, "acct-1")
        @Expect(row.lastThreadId, 42)
        @Expect(row.modelProvider, "openai")
        @Expect(row.model, "gpt-5.4")
        @Expect(row.contextTokens, 123456)
        @Expect(row.totalTokens, 2400)
        @Expect(row.totalTokensFresh, true)
        @Expect(row.spawnedBy, "agent:main:main")
        @Expect(row.spawnedWorkspaceDir, "/tmp/subagent-workspace")
        @Expect(row.forkedFromParent, true)
        @Expect(row.spawnDepth, 2)
        @Expect(row.subagentRole, "orchestrator")
        @Expect(row.subagentControlScope, "children")
        @Expect(row.parentSessionKey, "agent:main:main")
        @Expect(row.childSessions.size, 1)
        @Expect(row.childSessions[0], "agent:general:child")

        store.deleteSession(sessionKey)
    }
}
