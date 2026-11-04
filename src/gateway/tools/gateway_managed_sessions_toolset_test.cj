package metis.gateway.tools

import std.runtime.{getThreadCount, getBlockingThreadCount}

import metis.core.config.cliModelProviderCatalogDescriptors

import std.collection.HashMap
import std.collection.Map
import std.convert.Parsable
import std.env.getVariables
import std.env.getProcessId
import std.env.getCommand
import std.env.removeVariable
import std.fs.FileInfo
import std.fs.OpenMode
import std.fs.copy
import std.io.InputStream
import std.posix.chmod
import std.process.ProcessRedirect
import std.time.MonoTime
import stdx.encoding.json.*
import metis.process.ManagedOwnedChild
import metis.process.currentProcessInstanceIdentity
import metis.process.launchManagedRawChild
import metis.process.managedRecoveryInitialize
import metis.process.managedRecoveryLaunchOwned
import metis.process.managedRecoveryExecuteWithOutput
import metis.process.managedRecoveryProbeRecords
import metis.process.managedRecoveryStopOwnedChildren

import metis.core.{GatewayToolRuntimeContext, gatewayClearSubagentNoticeDeliveryHook, gatewayRegisterSubagentNoticeDeliveryHook, gatewaySubagentCreateRunRecord, gatewaySubagentMarkRunSucceeded, gatewaySubagentResolveAgent, gatewaySubagentResolveRunRecord, gatewaySubagentRunRecordString, gatewaySubagentRunStatusIsTerminal, gatewaySubagentWriteRunRecord, gatewayWithToolRuntimeContext}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.core.memory.memorySessionStoreForGatewayUser
import metis.gateway.process.gatewayStdioBroker
import metis.utils.ShellUtils

import std.env.{getVariable, setVariable}
import std.collection.ArrayList
import std.fs.{Directory, File, Path, canonicalize, exists, remove}
import std.core.Duration
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func withManagedSessionsToolsetResolvedTestHome<T>(actualHome: String, workerSettleTimeoutMs: Int64, block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        try {
            remove(Path(actualHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(actualHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", actualHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block()
        } finally {
            let workersSettled = GatewayManagedSessionsToolset().debugWaitManagedWorkersSettledForTest(workerSettleTimeoutMs)
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            if (workersSettled) {
                try {
                    remove(Path(actualHome), recursive: true)
                } catch (_: Exception) {
                    ()
                }
            } else {
                throw Exception("managed_test_workers_not_settled")
            }
        }
    }
}

private func withManagedSessionsToolsetTestHome<T>(home: String, block: () -> T): T {
    withManagedSessionsToolsetResolvedTestHome(
        "${home}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}",
        5000,
        block
    )
}

private func managedSubagentsJson(raw: String): JsonObject {
    JsonValue.fromStr(raw).asObject()
}

private func managedSubagentsSome(v: String): Option<String> {
    Some<String>(v)
}

private func managedSubagentsString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func managedSubagentsInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { 0 }
        case None => 0
    }
}

private func managedSubagentsBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) { case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false } case None => false }
}

private func managedSubagentsWaitForTerminal(toolset: GatewayManagedSessionsToolset, runId: String, timeoutMs!: Int64 = 5000): JsonObject {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    var last = JsonObject()
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        last = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
        let run = match (last.get("run")) {
            case Some(value) => try { value.asObject() } catch (_: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let status = managedSubagentsString(run, "status")
        if (status == "succeeded" || status == "failed" || status == "timed_out" || status == "cancelled") {
            return last
        }
        sleep(Duration.millisecond * 20)
    }
    last
}

private func managedSubagentsSpawnFakeAcp(
    toolset: GatewayManagedSessionsToolset,
    mode: String,
    timeoutSeconds!: Int64 = 5
): JsonObject {
    managedSubagentsJson(toolset.sessionsSpawnForCommand(
        "fixture-task",
        Some("broker-fixture"),
        Some("acp"),
        Some("cmd:node scripts/gateway-stdio-p3b-fake-child.mjs ${mode}"),
        None<String>,
        None<String>,
        None<String>,
        None<String>,
        Some(timeoutSeconds),
        None<Int64>,
        None<String>,
        None<String>,
        None<Bool>,
        None<String>,
        None<String>,
        None<String>,
        None<String>
    ))
}

private func managedSubagentsWaitPidGone(pid: String, timeoutMs!: Int64 = 3000): Bool {
    let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
        let (exitCode, _, _) = ShellUtils.execute(["/bin/kill", "-0", pid], withWrap: false)
        if (exitCode != 0) {
            return true
        }
        sleep(Duration.millisecond * 20)
    }
    let (exitCode, _, _) = ShellUtils.execute(["/bin/kill", "-0", pid], withWrap: false)
    exitCode != 0
}

private func createManagedSubagentsCustomAgentFixture(id: String, background: Bool): Path {
    let agentDir = CliConfig.dotDir.join("agents").join(id)
    Directory.create(agentDir, recursive: true)
    File.writeTo(
        agentDir.join("AGENT.md"),
        (
            "id: ${id}\n" +
            "name: ${id}\n" +
            "description: Phase 9 custom subagent fixture\n" +
            "model: openai/gpt-test\n" +
            "tools: fileRead,grepSearch\n" +
            "background: ${background}\n" +
            "isolation: shared\n" +
            "maxTurns: 7\n" +
            "---\n" +
            "# Fixture Instructions\n" +
            "Always answer as the phase 9 custom fixture.\n"
        ).toArray()
    )
    CliConfig.invalidatePathCache()
    agentDir
}

private func writeManagedSubagentsAgentToolPolicy(agentId: String, deny: Array<String>): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    agents.put("defaults", JsonObject())
    let entries = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString(agentId))
    let tools = JsonObject()
    let denied = JsonArray([])
    for (name in deny) {
        denied.add(JsonString(name))
    }
    tools.put("deny", denied)
    entry.put("tools", tools)
    entries.add(entry)
    agents.put("list", entries)
    root.put("agents", agents)
    let configDir = MetisConfigManager.configPath().parent
    if (!exists(configDir)) {
        Directory.create(configDir, recursive: true)
    }
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func managedSubagentsRunGit(repo: Path, args: Array<String>): Bool {
    let command = ArrayList<String>()
    command.add("git")
    for (arg in args) {
        command.add(arg)
    }
    let result = ShellUtils.execute(command.toArray(), timeout: Some(Duration.second * 30), workDir: Some(repo), withWrap: false)
    result[0] == 0
}

private func managedSubagentsWorktreeRegistered(repo: Path, worktreePath: String): Bool {
    let result = ShellUtils.execute(["git", "worktree", "list", "--porcelain"], timeout: Some(Duration.second * 30), workDir: Some(repo), withWrap: false)
    if (result[0] != 0) { return true }
    let targetPath = Path(worktreePath)
    let target = if (exists(targetPath)) { canonicalize(targetPath).toString() } else { targetPath.normalize().toString() }
    for (line in result[1].split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("worktree ")) {
            let listedPath = Path(trimmed.removePrefix("worktree ").trimAscii())
            let listed = if (exists(listedPath)) { canonicalize(listedPath).toString() } else { listedPath.normalize().toString() }
            if (listed == target) { return true }
        }
    }
    false
}

private func createManagedSubagentsGitRepo(name: String): Path {
    let repo = CliConfig.dotDir.join(name)
    Directory.create(repo, recursive: true)
    File.writeTo(repo.join("README.md"), "# phase 11\n".toArray())
    @Expect(managedSubagentsRunGit(repo, ["init"]), true)
    @Expect(managedSubagentsRunGit(repo, ["config", "user.email", "metis-test@example.invalid"]), true)
    @Expect(managedSubagentsRunGit(repo, ["config", "user.name", "Metis Test"]), true)
    @Expect(managedSubagentsRunGit(repo, ["add", "README.md"]), true)
    @Expect(managedSubagentsRunGit(repo, ["commit", "-m", "init"]), true)
    repo
}

private func installManagedSubagentsWorktreeStderrBurstHook(repo: Path): Path {
    let hook = repo.join(".git").join("hooks").join("post-checkout")
    let marker = repo.join(".git").join("p3b-worktree-hook-ran")
    File.writeTo(
        hook,
        "#!/bin/sh\nnode -e 'const fs=require(\"node:fs\");process.stderr.write(\"w\".repeat(60000));fs.writeFileSync(process.argv[1],\"ran\")' '${marker.toString()}'\n".toArray()
    )
    let (exitCode, _, _) = ShellUtils.execute(["/bin/chmod", "+x", hook.toString()], withWrap: false)
    @Expect(exitCode, 0)
    marker
}

private func appendManagedSubagentsBindingSnapshot(
    sessionKey: String,
    channelName: String,
    peerId: String,
    accountId: String,
    conversationId: String,
    threadId: String,
    sourceMessageId: String,
    replyToMessageId: String,
    replyInThread: Bool
): Unit {
    let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
    store.appendTranscriptEntry(sessionKey, "system", "binding fixture")
    let binding = JsonObject()
    binding.put("kind", JsonString("binding"))
    binding.put("channel", JsonString(channelName))
    binding.put("peer", JsonString(peerId))
    binding.put("accountId", JsonString(accountId))
    binding.put("conversationId", JsonString(conversationId))
    binding.put("threadId", JsonString(threadId))
    binding.put("sourceMessageId", JsonString(sourceMessageId))
    binding.put("replyToMessageId", JsonString(replyToMessageId))
    binding.put("replyTargetMessageId", JsonString(replyToMessageId))
    binding.put("replyInThread", JsonBool(replyInThread))
    binding.put("deliverable", JsonBool(true))
    binding.put("mode", JsonString("delivery-target"))
    let p = store.transcriptPath(sessionKey)
    let existing = String.fromUtf8(File.readFrom(p))
    File.writeTo(p, (existing + binding.toJsonString() + "\n").toArray())
}

@Test
public class GatewayManagedSessionsToolsetTest {
    @TestCase
    public func subagentsListStatusAndLogsReturnRunStoreData(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-list-status-logs") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-session-a"
            store.appendTranscriptEntry(sessionKey, "assistant", "analysis ready")
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                parentSessionKey: "cli:main",
                requesterSessionKey: "cli:main",
                agentId: "explorer",
                runtime: "subagent",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let listed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("agent:explorer"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(listed, "action"), "list")
                @Expect(managedSubagentsString(listed, "filter"), "agent:explorer")
                @Expect(listed.get("sessions").getOrThrow().asArray().size(), 1)
                @Expect(managedSubagentsString(listed.get("sessions").getOrThrow().asArray()[0].asObject(), "runId"), runId)

                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(status, "action"), "status")
                @Expect(managedSubagentsString(status, "runId"), runId)
                @Expect(managedSubagentsString(status, "effectiveState"), "stale")
                @Expect(status.get("isStale").getOrThrow().asBool().getValue(), true)
                @Expect(status.get("run").getOrThrow().asObject().get("runId").getOrThrow().asString().getValue(), runId)

                let logs = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("logs"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(logs, "action"), "logs")
                @Expect(managedSubagentsString(logs, "effectiveState"), "stale")
                @Expect(managedSubagentsString(logs, "logs").contains("analysis ready"), true)
                @Expect(managedSubagentsString(logs, "transcriptPath").isEmpty(), false)
            }
        }
    }

    @TestCase
    public func subagentsListSeparatesActiveRowsFromStaleAndHistoryRows(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-list-active-history") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let staleRunning = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                "child-session-stale-running",
                requesterSessionKey: "cli:main",
                agentId: "explorer",
                status: "running"
            )
            let succeeded = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                "child-session-succeeded",
                requesterSessionKey: "cli:main",
                agentId: "reviewer",
                status: "succeeded"
            )
            let failed = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                "child-session-failed",
                requesterSessionKey: "cli:main",
                agentId: "planner",
                status: "failed"
            )
            let recorded = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                "child-session-recorded",
                requesterSessionKey: "cli:main",
                agentId: "custom-recorded",
                status: "queued"
            )
            let metadata = JsonObject()
            let agent = JsonObject()
            agent.put("background", JsonBool(false))
            metadata.put("agent", agent)
            recorded.put("metadata", metadata)
            let _ = gatewaySubagentWriteRunRecord(store.sessionsRoot(), recorded)
            let staleRunId = gatewaySubagentRunRecordString(staleRunning, "runId")
            let succeededRunId = gatewaySubagentRunRecordString(succeeded, "runId")
            let failedRunId = gatewaySubagentRunRecordString(failed, "runId")
            let recordedRunId = gatewaySubagentRunRecordString(recorded, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let all = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("all"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(all, "filter"), "all")
                @Expect(managedSubagentsInt(all, "total"), 4)
                @Expect(managedSubagentsInt(all, "activeCount"), 0)
                @Expect(managedSubagentsInt(all, "staleCount"), 1)
                @Expect(managedSubagentsInt(all, "recordedCount"), 1)
                @Expect(managedSubagentsInt(all, "terminalCount"), 2)
                @Expect(all.get("sessions").getOrThrow().asArray().size(), 4)
                @Expect(all.get("runs").getOrThrow().asArray().size(), 4)
                @Expect(all.get("active").getOrThrow().asArray().size(), 0)
                @Expect(all.get("stale").getOrThrow().asArray().size(), 1)
                @Expect(all.get("recorded").getOrThrow().asArray().size(), 1)
                @Expect(managedSubagentsString(all.get("stale").getOrThrow().asArray()[0].asObject(), "runId"), staleRunId)
                @Expect(all.get("stale").getOrThrow().asArray()[0].asObject().get("isStale").getOrThrow().asBool().getValue(), true)
                @Expect(managedSubagentsString(all.get("recorded").getOrThrow().asArray()[0].asObject(), "runId"), recordedRunId)
                @Expect(all.get("recorded").getOrThrow().asArray()[0].asObject().get("isRecordedOnly").getOrThrow().asBool().getValue(), true)

                let active = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("active"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(active, "filter"), "active")
                @Expect(managedSubagentsInt(active, "total"), 0)
                @Expect(managedSubagentsInt(active, "activeCount"), 0)
                @Expect(managedSubagentsInt(active, "terminalCount"), 0)
                @Expect(managedSubagentsInt(active, "staleCount"), 0)
                @Expect(active.get("sessions").getOrThrow().asArray().size(), 0)

                let stale = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("stale"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(stale, "filter"), "stale")
                @Expect(managedSubagentsInt(stale, "total"), 1)
                @Expect(managedSubagentsInt(stale, "activeCount"), 0)
                @Expect(managedSubagentsInt(stale, "staleCount"), 1)
                @Expect(managedSubagentsInt(stale, "terminalCount"), 0)
                @Expect(managedSubagentsString(stale.get("sessions").getOrThrow().asArray()[0].asObject(), "runId"), staleRunId)

                let recordedRows = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("recorded"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(recordedRows, "filter"), "recorded")
                @Expect(managedSubagentsInt(recordedRows, "total"), 1)
                @Expect(managedSubagentsInt(recordedRows, "recordedCount"), 1)
                @Expect(managedSubagentsString(recordedRows.get("sessions").getOrThrow().asArray()[0].asObject(), "runId"), recordedRunId)

                let history = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("history"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(history, "filter"), "history")
                @Expect(managedSubagentsInt(history, "total"), 2)
                @Expect(managedSubagentsInt(history, "activeCount"), 0)
                @Expect(managedSubagentsInt(history, "staleCount"), 0)
                @Expect(managedSubagentsInt(history, "terminalCount"), 2)
                @Expect(history.get("active").getOrThrow().asArray().size(), 0)
                let historyJson = history.get("sessions").getOrThrow().asArray().toJsonString()
                @Expect(historyJson.contains(succeededRunId), true)
                @Expect(historyJson.contains(failedRunId), true)
            }
        }
    }

    @TestCase
    public func subagentsKillCancelsStaleNonTerminalRunWithoutDeletingTranscript(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-kill-running") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-session-kill"
            store.appendTranscriptEntry(sessionKey, "assistant", "work in progress")
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                requesterSessionKey: "cli:main",
                agentId: "reviewer",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(killed, "status"), "cancelled")
                @Expect(killed.get("deleted").getOrThrow().asBool().getValue(), false)
                @Expect(exists(store.transcriptPath(sessionKey)), true)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) => @Expect(gatewaySubagentRunRecordString(found, "status"), "cancelled")
                    case None => @Expect("missing", "record")
                }
            }
        }
    }

    @TestCase
    public func subagentsCleanupStaleMarksRunCancelledWithoutDeletingTranscript(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-cleanup-stale") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-session-cleanup"
            store.appendTranscriptEntry(sessionKey, "assistant", "stale work")
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                requesterSessionKey: "cli:main",
                agentId: "reviewer",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let cleaned = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("cleanup"), managedSubagentsSome("stale"), None<String>, None<Int64>))
                @Expect(managedSubagentsString(cleaned, "status"), "ok")
                @Expect(managedSubagentsInt(cleaned, "count"), 1)
                @Expect(exists(store.transcriptPath(sessionKey)), true)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) => @Expect(gatewaySubagentRunRecordString(found, "status"), "cancelled")
                    case None => @Expect("missing", "record")
                }
                let stale = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("stale"), None<String>, None<Int64>))
                @Expect(managedSubagentsInt(stale, "total"), 0)
            }
        }
    }

    @TestCase
    public func subagentsKillCompletedRunIsIdempotent(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-kill-completed") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-session-completed"
            store.appendTranscriptEntry(sessionKey, "assistant", "done")
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                requesterSessionKey: "cli:main",
                agentId: "planner",
                status: "succeeded",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(killed, "status"), "noop")
                @Expect(killed.get("deleted").getOrThrow().asBool().getValue(), false)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) => @Expect(gatewaySubagentRunRecordString(found, "status"), "succeeded")
                    case None => @Expect("missing", "record")
                }
            }
        }
    }

    @TestCase
    public func subagentsKillParentCascadesToChildRuns(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-kill-cascade") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let parentSessionKey = "parent-orchestrator"
            let childSessionKey = "child-worker"
            store.appendTranscriptEntry(parentSessionKey, "assistant", "parent work")
            store.appendTranscriptEntry(childSessionKey, "assistant", "child work")
            let parent = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                parentSessionKey,
                requesterSessionKey: "cli:main",
                agentId: "planner",
                status: "running",
                transcriptPath: store.transcriptPath(parentSessionKey).toString()
            )
            let child = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                childSessionKey,
                parentSessionKey: parentSessionKey,
                requesterSessionKey: parentSessionKey,
                agentId: "reviewer",
                status: "running",
                transcriptPath: store.transcriptPath(childSessionKey).toString()
            )
            let parentRunId = gatewaySubagentRunRecordString(parent, "runId")
            let childRunId = gatewaySubagentRunRecordString(child, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(parentRunId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(killed, "status"), "cancelled")
                @Expect(killed.get("cascadeCancelled").getOrThrow().asArray().size(), 1)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), childRunId)) {
                    case Some(found) =>
                        @Expect(gatewaySubagentRunRecordString(found, "status"), "cancelled")
                        @Expect(gatewaySubagentRunRecordString(found, "error").contains(parentRunId), true)
                    case None => @Expect("missing", "child")
                }
            }
        }
    }

    @TestCase
    public func cleanupDeleteArchivesTranscriptByRename(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-cleanup-delete-archive") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-cleanup-delete"
            store.appendTranscriptEntry(sessionKey, "assistant", "archive me")
            let originalTranscript = store.transcriptPath(sessionKey).toString()
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                requesterSessionKey: "cli:main",
                agentId: "reviewer",
                status: "running",
                cleanupMode: "delete",
                transcriptPath: originalTranscript
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            @Expect(gatewaySubagentMarkRunSucceeded(store.sessionsRoot(), runId, resultSummary: "done"), true)
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:main")) {
                toolset.debugDeliverTerminalNoticeForTest(sessionKey)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) =>
                        let archivedPath = gatewaySubagentRunRecordString(found, "archivedTranscriptPath")
                        @Expect(gatewaySubagentRunRecordString(found, "archiveStatus"), "archived")
                        @Expect(archivedPath.contains(".deleted."), true)
                        @Expect(exists(Path(originalTranscript)), false)
                        @Expect(exists(Path(archivedPath)), true)
                        @Expect(gatewaySubagentRunRecordString(found, "transcriptPath"), archivedPath)
                    case None => @Expect("missing", "record")
                }
            }
        }
    }

    @TestCase
    public func subagentsStatusDeniesDifferentRequesterSessionOnChannelSurface(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-toolset-scope-deny") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                "child-session-owned",
                requesterSessionKey: "telegram:chat:owner",
                agentId: "explorer",
                status: "running"
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", sessionKey: "telegram:chat:other")) {
                let denied = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(denied, "status"), "denied")
                @Expect(managedSubagentsString(denied, "action"), "status")
            }
        }
    }

    @TestCase
    public func subagentsCommandSpawnRejectsUnknownAgent(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-command-spawn-record") {
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", sessionKey: "telegram:chat:phase7")) {
                let spawned = managedSubagentsJson(gatewayHandleSubagentsCommandLine("/subagents spawn observer \"inspect unicode 任务\"").getOrThrow())
                @Expect(managedSubagentsString(spawned, "status"), "error")
                @Expect(managedSubagentsString(spawned, "agentId"), "observer")
                @Expect(managedSubagentsString(spawned, "error").contains("unknown subagent agent"), true)
            }
        }
    }

    @TestCase
    public func customSubagentResolverReadsAgentMarkdownMetadata(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-custom-resolver") {
            let agentDir = createManagedSubagentsCustomAgentFixture("phase9-custom", false)
            let spec = gatewaySubagentResolveAgent("phase9-custom")
            @Expect(spec.found, true)
            @Expect(spec.source, "custom")
            @Expect(spec.agentId, "phase9-custom")
            @Expect(spec.agentDir, agentDir.toString())
            @Expect(spec.model, "openai/gpt-test")
            @Expect(spec.tools.size, 2)
            @Expect(spec.background, false)
            @Expect(spec.isolation, "shared")
            @Expect(spec.maxTurns, 7)
        }
    }

    @TestCase
    public func sessionsSpawnCustomAgentRequiresPolicyAllow(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-custom-policy-deny") {
            createManagedSubagentsCustomAgentFixture("phase9-custom", false)
            let toolset = GatewayManagedSessionsToolset()
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", sessionKey: "telegram:chat:phase9")) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect unicode 任务",
                    Some("custom"),
                    Some("subagent"),
                    Some("phase9-custom"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    None<String>,
                    None<String>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "rejected")
                @Expect(managedSubagentsString(spawned, "reason"), "custom agents disabled")
                @Expect(managedSubagentsString(spawned, "agentId"), "phase9-custom")
            }
        }
    }

    @TestCase
    public func sessionsSpawnCustomAgentRecordsRunWhenPolicyAllows(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-custom-spawn-record") {
            createManagedSubagentsCustomAgentFixture("phase9-custom", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            settings.subagents.archiveAfterMinutes = 15
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", sessionKey: "telegram:chat:phase9")) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect unicode 任务",
                    Some("custom"),
                    Some("subagent"),
                    Some("phase9-custom"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    None<String>,
                    None<String>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                @Expect(managedSubagentsString(spawned, "agentId"), "phase9-custom")
                @Expect(managedSubagentsString(spawned, "agentSource"), "custom")
                @Expect(managedSubagentsString(spawned, "model"), "openai/gpt-test")
                @Expect(spawned.get("liveRunStarted").getOrThrow().asBool().getValue(), false)
                let runId = managedSubagentsString(spawned, "runId")
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(status, "status"), "ok")
                @Expect(managedSubagentsString(status, "runId"), runId)
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "status"), "queued")
                @Expect(managedSubagentsString(run, "requesterSessionKey"), "telegram:chat:phase9")
                @Expect(managedSubagentsString(run, "requesterChannel"), "telegram")
                @Expect(managedSubagentsInt(run, "archiveAfterMinutes"), 15)
                @Expect(managedSubagentsString(run, "archiveStatus"), "scheduled")
                @Expect(managedSubagentsString(run, "agentSource"), "custom")
                let metadata = run.get("metadata").getOrThrow().asObject()
                let agent = metadata.get("agent").getOrThrow().asObject()
                @Expect(managedSubagentsString(agent, "source"), "custom")
                @Expect(managedSubagentsString(agent, "model"), "openai/gpt-test")
            }
        }
    }

    @TestCase
    public func sessionsSpawnStoresRequestedContextModeAndParentThread(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-context-mode") {
            createManagedSubagentsCustomAgentFixture("phase10-custom", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            store.appendTranscriptEntry("telegram:chat:phase10:topic:42", "user", "parent context should be available")
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", sessionKey: "telegram:chat:phase10:topic:42")) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect with parent context",
                    Some("context"),
                    Some("subagent"),
                    Some("phase10-custom"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    Some("with-context"),
                    None<String>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                @Expect(managedSubagentsString(spawned, "contextMode"), "with_context")
                let runId = managedSubagentsString(spawned, "runId")
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "contextMode"), "with_context")
                @Expect(managedSubagentsString(run, "parentSessionKey"), "telegram:chat:phase10:topic:42")
                @Expect(managedSubagentsString(run, "requesterThreadId"), "42")
            }
        }
    }

    @TestCase
    public func telegramTopicSubagentSpawnPersistsRequesterBindingForCompletionNotice(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-topic-binding") {
            createManagedSubagentsCustomAgentFixture("phase10-telegram", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let requesterSessionKey = "telegram:group:group:-1001234567890:topic:42"
            appendManagedSubagentsBindingSnapshot(
                requesterSessionKey,
                "telegram",
                "group:-1001234567890:topic:42",
                "telegram:default",
                "group:-1001234567890:topic:42",
                "42",
                "777",
                "777",
                true
            )
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: requesterSessionKey)) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect telegram topic context",
                    Some("topic-binding"),
                    Some("subagent"),
                    Some("phase10-telegram"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    Some("thread"),
                    None<String>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                let runId = managedSubagentsString(spawned, "runId")
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "requesterSessionKey"), requesterSessionKey)
                @Expect(managedSubagentsString(run, "requesterChannel"), "telegram")
                @Expect(managedSubagentsString(run, "requesterAccountId"), "telegram:default")
                @Expect(managedSubagentsString(run, "requesterPeerId"), "group:-1001234567890:topic:42")
                @Expect(managedSubagentsString(run, "requesterThreadId"), "42")
                @Expect(managedSubagentsString(run, "requesterConversationId"), "group:-1001234567890:topic:42")
                @Expect(managedSubagentsString(run, "requesterReplyToMessageId"), "777")
                @Expect(run.get("requesterReplyInThread").getOrThrow().asBool().getValue(), true)
                let rowJson = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("list"), managedSubagentsSome("current"), None<String>, None<Int64>))
                let row = rowJson.get("sessions").getOrThrow().asArray()[0].asObject()
                @Expect(managedSubagentsString(row, "requesterPeerId"), "group:-1001234567890:topic:42")
                @Expect(managedSubagentsString(row, "requesterThreadId"), "42")
            }
        }
    }

    @TestCase
    public func telegramSubagentSpawnCreatesForumTopicAndThreadBindingWhenEnabled(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-create-topic") {
            createManagedSubagentsCustomAgentFixture("phase13-topic", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            settings.telegram.threadBindings.enabled = true
            settings.telegram.threadBindings.spawnSubagentSessions = true
            settings.telegram.actions.createForumTopic = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let requesterSessionKey = "telegram:group:group:-1001234567890:topic:42"
            appendManagedSubagentsBindingSnapshot(
                requesterSessionKey,
                "telegram",
                "group:-1001234567890:topic:42",
                "telegram:default",
                "group:-1001234567890:topic:42",
                "42",
                "777",
                "777",
                true
            )
            let toolset = GatewayManagedSessionsToolset()
            let marker = JsonObject()
            marker.put("sawTopicCreate", JsonBool(false))
            toolset.debugSetGatewayCallRunnerForTest(Some({ method: String, params: JsonObject =>
                @Expect(method, "channels.send")
                @Expect(params.get("peerId").getOrThrow().asString().getValue(), "group:-1001234567890")
                @Expect(params.get("text").getOrThrow().asString().getValue().startsWith("[topic-create]"), true)
                marker.put("sawTopicCreate", JsonBool(true))
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                out.put("messageThreadId", JsonString("88"))
                out
            }))
            try {
                let spawned = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: requesterSessionKey),
                    { => managedSubagentsJson(toolset.sessionsSpawnForCommand(
                        "inspect topic creation",
                        Some("topic-create"),
                        Some("subagent"),
                        Some("phase13-topic"),
                        None<String>,
                        None<String>,
                        None<String>,
                        None<String>,
                        None<Int64>,
                        None<Int64>,
                        Some("fresh"),
                        None<String>,
                        None<Bool>,
                        None<String>,
                        None<String>,
                        None<String>,
                        None<String>
                    )) }
                )
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                @Expect(marker.get("sawTopicCreate").getOrThrow().asBool().getValue(), true)
                let topic = spawned.get("telegramTopicBinding").getOrThrow().asObject()
                @Expect(managedSubagentsString(topic, "status"), "bound")
                let bindingPath = CliConfig.dotDir.join("gateway-telegram").join("thread-bindings.json")
                let rows = JsonValue.fromStr(String.fromUtf8(File.readFrom(bindingPath))).asArray()
                let binding = rows[0].asObject()
                @Expect(binding.get("conversationId").getOrThrow().asString().getValue(), "group:-1001234567890:topic:88")
                @Expect(binding.get("sessionKey").getOrThrow().asString().getValue(), managedSubagentsString(spawned, "sessionKey"))
            } finally {
                toolset.debugSetGatewayCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            }
        }
    }

    @TestCase
    public func sessionsSpawnRejectsChildToolsBeyondParentAgentPolicy(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-phase6-parent-boundary") {
            createManagedSubagentsCustomAgentFixture("phase6-child", false)
            writeManagedSubagentsAgentToolPolicy("agent-a", ["exec"])
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            settings.subagents.requireAgentId = true
            settings.subagents.allowAgents = ["phase6-child"]
            settings.subagents.childAllowedTools = ["shellExecute"]
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()

            let toolset = GatewayManagedSessionsToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                { => managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "attempt denied child shell",
                    Some("phase6-parent-boundary"),
                    Some("subagent"),
                    Some("phase6-child"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    Some("fresh"),
                    None<String>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                )) }
            )

            @Expect(managedSubagentsString(out, "status"), "rejected")
            @Expect(managedSubagentsString(out, "reason").contains("parent tool policy denied"), true)
        }
    }

    @TestCase
    public func telegramSubagentTopicCreateFailureReturnsWarningButKeepsRunRecord(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-create-topic-warning") {
            createManagedSubagentsCustomAgentFixture("phase13-topic-warning", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            settings.telegram.threadBindings.enabled = true
            settings.telegram.threadBindings.spawnSubagentSessions = true
            settings.telegram.actions.createForumTopic = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let requesterSessionKey = "telegram:group:group:-1002222222222:topic:42"
            appendManagedSubagentsBindingSnapshot(
                requesterSessionKey,
                "telegram",
                "group:-1002222222222:topic:42",
                "telegram:default",
                "group:-1002222222222:topic:42",
                "42",
                "777",
                "777",
                true
            )
            let toolset = GatewayManagedSessionsToolset()
            toolset.debugSetGatewayCallRunnerForTest(Some({ _method: String, _params: JsonObject =>
                let out = JsonObject()
                out.put("ok", JsonBool(false))
                out.put("reason", JsonString("forum topic create denied"))
                out
            }))
            try {
                let spawned = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("telegram", channelName: "telegram", sessionKey: requesterSessionKey),
                    { => managedSubagentsJson(toolset.sessionsSpawnForCommand(
                        "inspect topic warning",
                        Some("topic-warning"),
                        Some("subagent"),
                        Some("phase13-topic-warning"),
                        None<String>,
                        None<String>,
                        None<String>,
                        None<String>,
                        None<Int64>,
                        None<Int64>,
                        Some("fresh"),
                        None<String>,
                        None<Bool>,
                        None<String>,
                        None<String>,
                        None<String>,
                        None<String>
                    )) }
                )
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                let topic = spawned.get("telegramTopicBinding").getOrThrow().asObject()
                @Expect(managedSubagentsString(topic, "status"), "warning")
                let found = gatewaySubagentResolveRunRecord(store.sessionsRoot(), managedSubagentsString(spawned, "runId"))
                @Expect(found.isSome(), true)
            } finally {
                toolset.debugSetGatewayCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            }
        }
    }

    @TestCase
    public func telegramTopicSubagentTerminalNoticeUsesGatewayChannelHook(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-topic-notice") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-topic-notice"
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                parentSessionKey: "telegram:group:group:-1001234567890:topic:42",
                requesterSessionKey: "telegram:group:group:-1001234567890:topic:42",
                requesterChannel: "telegram",
                requesterThreadId: "42",
                requesterAccountId: "telegram:default",
                requesterPeerId: "group:-1001234567890:topic:42",
                requesterConversationId: "group:-1001234567890:topic:42",
                requesterReplyToMessageId: "777",
                requesterReplyInThread: true,
                agentId: "reviewer",
                runtime: "subagent",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            @Expect(gatewaySubagentMarkRunSucceeded(store.sessionsRoot(), runId, resultSummary: "topic review done"), true)
            let delivered = JsonObject()
            gatewayRegisterSubagentNoticeDeliveryHook({ channelName, accountId, peerId, notice, replyToMessageId, replyInThread =>
                delivered.put("value", JsonString("${channelName}|${accountId}|${peerId}|${replyToMessageId}|${replyInThread}|${notice.contains("topic review done")}"))
                "notice-message-1"
            })
            try {
                let toolset = GatewayManagedSessionsToolset()
                toolset.debugDeliverTerminalNoticeForTest(sessionKey)
                @Expect(managedSubagentsString(delivered, "value"), "telegram|telegram:default|group:-1001234567890:topic:42|777|true|true")
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) =>
                        @Expect(managedSubagentsString(found, "channelNoticeStatus"), "delivered")
                        @Expect(managedSubagentsString(found, "channelNoticeMessageId"), "notice-message-1")
                    case None => @Expect("missing", "record")
                }
            } finally {
                gatewayClearSubagentNoticeDeliveryHook()
            }
        }
    }

    @TestCase
    public func telegramSubagentTerminalNoticeFallsBackToGatewayRpcWhenHookUnavailable(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-notice-fallback") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-topic-notice-fallback"
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                parentSessionKey: "telegram:direct:user:1059872384",
                requesterSessionKey: "telegram:direct:user:1059872384",
                requesterChannel: "telegram",
                requesterAccountId: "telegram:default",
                requesterPeerId: "user:1059872384",
                requesterConversationId: "user:1059872384",
                requesterReplyToMessageId: "888",
                requesterReplyInThread: false,
                agentId: "explorer",
                runtime: "subagent",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            @Expect(gatewaySubagentMarkRunSucceeded(store.sessionsRoot(), runId, resultSummary: "fallback notice done"), true)
            gatewayClearSubagentNoticeDeliveryHook()

            let captured = JsonObject()
            let toolset = GatewayManagedSessionsToolset()
            toolset.debugSetGatewayCallRunnerForTest(Some<(String, JsonObject) -> JsonObject>({ method, params =>
                captured.put("method", JsonString(method))
                captured.put("channel", params.get("channel").getOrThrow())
                captured.put("accountId", params.get("accountId").getOrThrow())
                captured.put("peerId", params.get("peerId").getOrThrow())
                captured.put("text", params.get("text").getOrThrow())
                captured.put("replyToMessageId", params.get("replyToMessageId").getOrThrow())
                captured.put("replyInThread", params.get("replyInThread").getOrThrow())
                let out = JsonObject()
                out.put("ok", JsonBool(true))
                let result = JsonObject()
                result.put("ok", JsonBool(true))
                result.put("messageId", JsonString("gateway-rpc-message-1"))
                out.put("result", result)
                out
            }))
            try {
                toolset.debugDeliverTerminalNoticeForTest(sessionKey)
                @Expect(managedSubagentsString(captured, "method"), "channels.send")
                @Expect(managedSubagentsString(captured, "channel"), "telegram")
                @Expect(managedSubagentsString(captured, "accountId"), "telegram:default")
                @Expect(managedSubagentsString(captured, "peerId"), "user:1059872384")
                @Expect(managedSubagentsString(captured, "replyToMessageId"), "888")
                @Expect(captured.get("replyInThread").getOrThrow().asBool().getValue(), false)
                @Expect(managedSubagentsString(captured, "text").contains("fallback notice done"), true)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(found) =>
                        @Expect(managedSubagentsString(found, "channelNoticeStatus"), "delivered")
                        @Expect(managedSubagentsString(found, "channelNoticeMessageId"), "gateway-rpc-message-1")
                    case None => @Expect("missing", "record")
                }
            } finally {
                toolset.debugSetGatewayCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            }
        }
    }

    @TestCase
    public func telegramSubagentNoticeFailureStaysPendingAndRetriesToDelivered(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-telegram-notice-retry") {
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            let sessionKey = "child-topic-notice-retry"
            let record = gatewaySubagentCreateRunRecord(
                store.sessionsRoot(),
                sessionKey,
                parentSessionKey: "telegram:direct:user:1059872384",
                requesterSessionKey: "telegram:direct:user:1059872384",
                requesterChannel: "telegram",
                requesterAccountId: "telegram:default",
                requesterPeerId: "user:1059872384",
                requesterConversationId: "user:1059872384",
                requesterReplyToMessageId: "999",
                requesterReplyInThread: false,
                agentId: "explorer",
                runtime: "subagent",
                status: "running",
                transcriptPath: store.transcriptPath(sessionKey).toString()
            )
            let runId = gatewaySubagentRunRecordString(record, "runId")
            @Expect(gatewaySubagentMarkRunSucceeded(store.sessionsRoot(), runId, resultSummary: "retry notice done"), true)

            let attempts = JsonObject()
            attempts.put("count", JsonInt(0))
            gatewayRegisterSubagentNoticeDeliveryHook({ _channelName, _accountId, _peerId, _notice, _replyToMessageId, _replyInThread =>
                let count = managedSubagentsInt(attempts, "count") + 1
                attempts.put("count", JsonInt(count))
                if (count == 1) {
                    throw Exception("temporary delivery outage")
                }
                "notice-retry-message-1"
            })
            let toolset = GatewayManagedSessionsToolset()
            toolset.debugSetGatewayCallRunnerForTest(Some<(String, JsonObject) -> JsonObject>({ _method, _params =>
                let out = JsonObject()
                out.put("ok", JsonBool(false))
                out.put("error", JsonString("gateway queue unavailable"))
                out
            }))
            try {
                toolset.debugDeliverTerminalNoticeForTest(sessionKey)
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(pending) =>
                        @Expect(gatewaySubagentRunRecordString(pending, "channelNoticeStatus"), "pending")
                        @Expect(gatewaySubagentRunRecordString(pending, "lastChannelNoticeError").contains("temporary delivery outage"), true)
                    case None => @Expect("missing", "pending")
                }

                toolset.debugRetryPendingNoticesForTest()
                match (gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId)) {
                    case Some(delivered) =>
                        @Expect(gatewaySubagentRunRecordString(delivered, "channelNoticeStatus"), "delivered")
                        @Expect(gatewaySubagentRunRecordString(delivered, "channelNoticeMessageId"), "notice-retry-message-1")
                        @Expect(gatewaySubagentRunRecordString(delivered, "noticeStatus"), "delivered")
                    case None => @Expect("missing", "delivered")
                }
            } finally {
                gatewayClearSubagentNoticeDeliveryHook()
                toolset.debugSetGatewayCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            }
        }
    }

    @TestCase
    public func sessionsSpawnCwdIsolationRecordsSpecifiedWorkspace(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-cwd-isolation") {
            createManagedSubagentsCustomAgentFixture("phase11-cwd", false)
            let workspace = CliConfig.dotDir.join("phase11-workspace")
            Directory.create(workspace, recursive: true)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase11")) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect cwd workspace",
                    Some("cwd"),
                    Some("subagent"),
                    Some("phase11-cwd"),
                    None<String>,
                    None<String>,
                    None<String>,
                    Some(workspace.toString()),
                    None<Int64>,
                    None<Int64>,
                    None<String>,
                    Some("cwd"),
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                @Expect(managedSubagentsString(spawned, "isolationMode"), "cwd")
                @Expect(managedSubagentsString(spawned, "cwd"), workspace.toString())
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(managedSubagentsString(spawned, "runId")), None<String>, None<Int64>))
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "isolationMode"), "cwd")
                @Expect(managedSubagentsString(run, "cwd"), workspace.toString())
            }
        }
    }

    @TestCase
    public func sessionsSpawnWorktreeIsolationCreatesAndDeletesWorktreeWhenRequested(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-worktree-isolation") {
            createManagedSubagentsCustomAgentFixture("phase11-worktree", false)
            let repo = createManagedSubagentsGitRepo("phase11-source-repo")
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase11-worktree")) {
                let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                    "inspect isolated worktree",
                    Some("worktree"),
                    Some("subagent"),
                    Some("phase11-worktree"),
                    None<String>,
                    None<String>,
                    None<String>,
                    Some(repo.toString()),
                    None<Int64>,
                    None<Int64>,
                    None<String>,
                    Some("worktree"),
                    None<Bool>,
                    None<String>,
                    Some("delete"),
                    None<String>,
                    None<String>
                ))
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                @Expect(managedSubagentsString(spawned, "isolationMode"), "worktree")
                let worktreePath = managedSubagentsString(spawned, "worktreePath")
                @Expect(worktreePath.isEmpty(), false)
                @Expect(exists(Path(worktreePath)), false)
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(managedSubagentsString(spawned, "runId")), None<String>, None<Int64>))
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "worktreePath"), worktreePath)
                @Expect(managedSubagentsString(run, "cleanupMode"), "delete")
            }
        }
    }

    @TestCase
    public func subagentsCommandErrorsUseStructuredJson(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-command-error") {
            let failed = managedSubagentsJson(gatewayHandleSubagentsCommandLine("/subagents steer subrun_123").getOrThrow())
            @Expect(failed.get("ok").getOrThrow().asBool().getValue(), false)
            @Expect(managedSubagentsString(failed, "status"), "error")
            @Expect(managedSubagentsString(failed, "action"), "steer")
            @Expect(managedSubagentsString(failed, "usage").contains("/subagents spawn"), true)
        }
    }

    @TestCase
    public func subagentsCommandHelpReturnsSuccessfulUsageJson(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-command-help") {
            let help = managedSubagentsJson(gatewayHandleSubagentsCommandLine("/subagents help").getOrThrow())
            @Expect(help.get("ok").getOrThrow().asBool().getValue(), true)
            @Expect(managedSubagentsString(help, "status"), "ok")
            @Expect(managedSubagentsString(help, "action"), "help")
            @Expect(managedSubagentsString(help, "usage").contains("/subagents spawn"), true)
            @Expect(help.get("examples").getOrThrow().asArray().size() > 0, true)
        }
    }

    @TestCase
    public func sessionsBatchDelegateRecordsMultipleChildRuns(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-batch-success") {
            createManagedSubagentsCustomAgentFixture("phase13-batch", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase13")) {
                let batch = managedSubagentsJson(toolset.sessionsBatchDelegateForTest(
                    ["inspect first", "inspect second"],
                    Some("phase13-batch"),
                    Some("phase13"),
                    Some(2),
                    None<Int64>
                ))
                @Expect(managedSubagentsString(batch, "status"), "accepted")
                @Expect(managedSubagentsInt(batch, "total"), 2)
                @Expect(managedSubagentsInt(batch, "acceptedCount"), 2)
                @Expect(managedSubagentsString(batch, "summary"), "accepted=2 failed=0 timedOut=0 deferred=0")
                let children = batch.get("children").getOrThrow().asArray()
                @Expect(children.size(), 2)
                let first = children[0].asObject()
                let second = children[1].asObject()
                @Expect(managedSubagentsString(first, "status"), "accepted")
                @Expect(managedSubagentsString(second, "status"), "accepted")
                @Expect(managedSubagentsString(first, "runId").isEmpty(), false)
                @Expect(managedSubagentsString(second, "runId").isEmpty(), false)
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(managedSubagentsString(first, "runId")), None<String>, None<Int64>))
                @Expect(managedSubagentsString(status, "status"), "ok")
            }
        }
    }

    @TestCase
    public func sessionsBatchDelegateKeepsValidTasksWhenOneFailsValidation(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-batch-partial") {
            createManagedSubagentsCustomAgentFixture("phase13-partial", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase13-partial")) {
                let batch = managedSubagentsJson(toolset.sessionsBatchDelegateForTest(
                    ["inspect valid", "   "],
                    Some("phase13-partial"),
                    Some("phase13-partial"),
                    Some(2),
                    None<Int64>
                ))
                @Expect(managedSubagentsString(batch, "status"), "partial")
                @Expect(managedSubagentsInt(batch, "acceptedCount"), 1)
                @Expect(managedSubagentsInt(batch, "failedCount"), 1)
                @Expect(managedSubagentsString(batch, "summary"), "accepted=1 failed=1 timedOut=0 deferred=0")
                let children = batch.get("children").getOrThrow().asArray()
                @Expect(children.size(), 2)
                @Expect(managedSubagentsString(children[0].asObject(), "status"), "accepted")
                @Expect(managedSubagentsString(children[1].asObject(), "status"), "error")
            }
        }
    }

    @TestCase
    public func sessionsBatchDelegateCanMarkImmediatePerTaskTimeout(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-batch-timeout") {
            createManagedSubagentsCustomAgentFixture("phase13-timeout", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase13-timeout")) {
                let batch = managedSubagentsJson(toolset.sessionsBatchDelegateForTest(
                    ["inspect timeout"],
                    Some("phase13-timeout"),
                    Some("phase13-timeout"),
                    Some(1),
                    Some(0)
                ))
                @Expect(managedSubagentsString(batch, "status"), "partial")
                @Expect(managedSubagentsInt(batch, "timedOutCount"), 1)
                let child = batch.get("children").getOrThrow().asArray()[0].asObject()
                @Expect(managedSubagentsString(child, "status"), "timed_out")
                let status = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(managedSubagentsString(child, "runId")), None<String>, None<Int64>))
                let run = status.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "status"), "timed_out")
            }
        }
    }

    @TestCase
    public func sessionsBatchDelegateHonorsMaxWorkersWithDeferredRows(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-subagents-batch-max-workers") {
            createManagedSubagentsCustomAgentFixture("phase13-workers", false)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()

            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:phase13-workers")) {
                let batch = managedSubagentsJson(toolset.sessionsBatchDelegateForTest(
                    ["inspect one", "inspect two", "inspect three"],
                    Some("phase13-workers"),
                    Some("phase13-workers"),
                    Some(2),
                    None<Int64>
                ))
                @Expect(managedSubagentsString(batch, "status"), "partial")
                @Expect(managedSubagentsInt(batch, "maxWorkers"), 2)
                @Expect(managedSubagentsInt(batch, "acceptedCount"), 2)
                @Expect(managedSubagentsInt(batch, "deferredCount"), 1)
                let children = batch.get("children").getOrThrow().asArray()
                @Expect(children.size(), 3)
                @Expect(managedSubagentsString(children[0].asObject(), "status"), "accepted")
                @Expect(managedSubagentsString(children[1].asObject(), "status"), "accepted")
                @Expect(managedSubagentsString(children[2].asObject(), "status"), "deferred")
                @Expect(batch.get("runIds").getOrThrow().asArray().size(), 2)
            }
        }
    }

    @TestCase
    public func managedAcpBrokerPreservesUnicodeNoTailAndRedactsStderr(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-broker-unicode") {
            let toolset = GatewayManagedSessionsToolset()
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-unicode")) {
                let spawned = managedSubagentsSpawnFakeAcp(toolset, "managed-success")
                @Expect(managedSubagentsString(spawned, "status"), "accepted")
                let runId = managedSubagentsString(spawned, "runId")
                let terminal = managedSubagentsWaitForTerminal(toolset, runId)
                let run = terminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(run, "status"), "succeeded")
                @Expect(managedSubagentsBool(run, "hasLiveFuture"), false)
                let logs = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("logs"), managedSubagentsSome(runId), None<String>, None<Int64>))
                let text = managedSubagentsString(logs, "logs")
                @Expect(text.contains("仓颉输出🙂"), true)
                @Expect(text.contains("second-line-without-tail"), true)
                @Expect(text.contains("diagnostic 中文🙂"), true)
                @Expect(text.contains("test-secret-token-value"), false)

                let secret = managedSubagentsSpawnFakeAcp(toolset, "managed-secret")
                let secretRunId = managedSubagentsString(secret, "runId")
                let secretTerminal = managedSubagentsWaitForTerminal(toolset, secretRunId)
                @Expect(managedSubagentsString(secretTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                let secretLogs = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("logs"), managedSubagentsSome(secretRunId), None<String>, None<Int64>))
                let secretText = managedSubagentsString(secretLogs, "logs")
                @Expect(secretText.contains("[REDACTED]"), true)
                @Expect(secretText.contains("test-secret-token-value"), false)

                let privatePath = managedSubagentsSpawnFakeAcp(toolset, "managed-private-path")
                let privatePathRunId = managedSubagentsString(privatePath, "runId")
                let privatePathTerminal = managedSubagentsWaitForTerminal(toolset, privatePathRunId)
                @Expect(managedSubagentsString(privatePathTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                let privatePathLogs = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("logs"), managedSubagentsSome(privatePathRunId), None<String>, None<Int64>))
                let privatePathText = managedSubagentsString(privatePathLogs, "logs")
                @Expect(privatePathText.contains("[REDACTED_LOCAL_PATH]"), true)
                @Expect(privatePathText.contains("/Users/example/private-workspace"), false)

                let burst = managedSubagentsSpawnFakeAcp(toolset, "managed-stderr-burst")
                let burstRunId = managedSubagentsString(burst, "runId")
                let burstTerminal = managedSubagentsWaitForTerminal(toolset, burstRunId)
                @Expect(managedSubagentsString(burstTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                let burstLogs = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("logs"), managedSubagentsSome(burstRunId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(burstLogs, "logs").contains("...[TRUNCATED]"), true)
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            }
        }
    }

    @TestCase
    public func managedAcpBrokerEnforcesExactOutputBoundaryAndInvalidUtf8Isolation(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-broker-boundary") {
            let toolset = GatewayManagedSessionsToolset()
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-boundary")) {
                let below = managedSubagentsSpawnFakeAcp(toolset, "managed-below-limit")
                let belowTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(below, "runId"))
                let belowRun = belowTerminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(belowRun, "status"), "succeeded")
                @Expect(managedSubagentsString(belowRun, "resultSummary").size, 65535)

                let exact = managedSubagentsSpawnFakeAcp(toolset, "managed-exact-limit")
                let exactTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(exact, "runId"))
                let exactRun = exactTerminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(exactRun, "status"), "succeeded")
                @Expect(managedSubagentsString(exactRun, "resultSummary").size, 65536)

                let overflow = managedSubagentsSpawnFakeAcp(toolset, "managed-overflow")
                let overflowTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(overflow, "runId"))
                let overflowRun = overflowTerminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(overflowRun, "status"), "failed")
                @Expect(managedSubagentsString(overflowRun, "error").contains("output_limit_exceeded"), true)

                let invalid = managedSubagentsSpawnFakeAcp(toolset, "managed-invalid-utf8")
                let invalidTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(invalid, "runId"))
                let invalidRun = invalidTerminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(invalidRun, "status"), "failed")
                @Expect(managedSubagentsString(invalidRun, "error").contains("invalid_response_encoding"), true)

                let recovered = managedSubagentsSpawnFakeAcp(toolset, "managed-empty")
                let recoveredTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(recovered, "runId"))
                let recoveredRun = recoveredTerminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(recoveredRun, "status"), "succeeded")
                @Expect(managedSubagentsBool(recoveredRun, "hasLiveFuture"), false)
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            }
        }
    }

    @TestCase
    public func managedTestHomeWaitsForPostTerminalWorkerSettlementBeforeDelete(): Unit {
        let isolated = withManagedSessionsToolsetTestHome("/tmp/metis-managed-worker-settlement") {
            let toolset = GatewayManagedSessionsToolset()
            let currentDotDir = CliConfig.dotDir
            toolset.debugArmManagedWorkerSettleHoldForTest()
            let releaser = spawn {
                var helperWaiting = false
                try {
                    helperWaiting = toolset.debugWaitManagedWorkerDrainWaiterForTest(2000)
                } finally {
                    toolset.debugReleaseManagedWorkerSettleHoldForTest()
                }
                helperWaiting
            }
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-worker-settlement")) {
                let spawned = managedSubagentsSpawnFakeAcp(toolset, "managed-success")
                let terminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(spawned, "runId"))
                @Expect(managedSubagentsString(terminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                @Expect(toolset.debugWaitManagedWorkerSettleHoldForTest(2000), true)
                @Expect(toolset.debugManagedWorkerCountForTest(), 1)
                @Expect(exists(currentDotDir), true)
                (currentDotDir, releaser)
            }
        }
        @Expect(isolated[1].get(Duration.second * 2), true)
        @Expect(exists(isolated[0]), false)

        let toolset = GatewayManagedSessionsToolset()
        let priorDotDir = CliConfig.dotDir
        let retainedHome = "/tmp/metis-managed-worker-settlement-timeout-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        var failure = ""
        toolset.debugArmManagedWorkerSettleHoldForTest()
        try {
            withManagedSessionsToolsetResolvedTestHome(retainedHome, 25) {
                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-worker-settlement-timeout")) {
                    let spawned = managedSubagentsSpawnFakeAcp(toolset, "managed-success")
                    let terminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(spawned, "runId"))
                    @Expect(managedSubagentsString(terminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                    @Expect(toolset.debugWaitManagedWorkerSettleHoldForTest(2000), true)
                    @Expect(toolset.debugManagedWorkerCountForTest(), 1)
                }
            }
        } catch (e: Exception) {
            failure = e.message
        }
        try {
            @Expect(failure, "managed_test_workers_not_settled")
            @Expect(CliConfig.dotDir.toString(), priorDotDir.toString())
            @Expect(exists(Path(retainedHome)), true)
        } finally {
            toolset.debugReleaseManagedWorkerSettleHoldForTest()
            @Expect(toolset.debugWaitManagedWorkersSettledForTest(2000), true)
            try {
                remove(Path(retainedHome), recursive: true)
            } catch (_: Exception) {
                ()
            }
        }
    }

    @TestCase
    public func managedAcpBrokerTimeoutAndKillOnlyStopTargetOwner(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-broker-timeout-kill") {
            let toolset = GatewayManagedSessionsToolset()
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-timeout-kill")) {
                let hanging = managedSubagentsSpawnFakeAcp(toolset, "managed-hang", timeoutSeconds: 1)
                let success = managedSubagentsSpawnFakeAcp(toolset, "managed-success")
                let successTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(success, "runId"))
                @Expect(managedSubagentsString(successTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                let hangingTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(hanging, "runId"), timeoutMs: 5000)
                @Expect(managedSubagentsString(hangingTerminal.get("run").getOrThrow().asObject(), "status"), "timed_out")

                let killTarget = managedSubagentsSpawnFakeAcp(toolset, "managed-hang", timeoutSeconds: 20)
                let killRunId = managedSubagentsString(killTarget, "runId")
                let attachedDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
                var attached = JsonObject()
                while (DateTime.now().toUnixTimeStamp().toMilliseconds() < attachedDeadline) {
                    attached = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(killRunId), None<String>, None<Int64>))
                    if (managedSubagentsBool(attached, "hasLiveProcess")) { break }
                    sleep(Duration.millisecond * 20)
                }
                @Expect(managedSubagentsBool(attached, "hasLiveProcess"), true)
                let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(killRunId), None<String>, None<Int64>))
                @Expect(managedSubagentsString(killed, "status"), "cancelled")
                let killedTerminal = managedSubagentsWaitForTerminal(toolset, killRunId)
                @Expect(managedSubagentsString(killedTerminal.get("run").getOrThrow().asObject(), "status"), "cancelled")
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            }
        }
    }

    @TestCase
    public func managedSubagentBrokerRunsFakeChildAndCleansWorktreeOnSuccessAndCancel(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-broker-subagent") {
            createManagedSubagentsCustomAgentFixture("broker-subagent", true)
            let repo = createManagedSubagentsGitRepo("broker-subagent-repo")
            let worktreeHookMarker = installManagedSubagentsWorktreeStderrBurstHook(repo)
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()
            let fixture = CliConfig.cwd.join("scripts").join("gateway-stdio-p3b-fake-child.mjs").toString()
            let pidFile = CliConfig.dotDir.join("managed-subagent-hang.pids")
            toolset.debugSetManagedSubagentCommandSpecForTest(Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                { _sessionKey, _agentId, _task, cwdHint, _agentDir, _modelHint =>
                    ("node", [fixture, "managed-success-remove-worktree"], Path(cwdHint))
                }
            ))
            try {
                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-subagent")) {
                    let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                        "fixture-task",
                        Some("broker-subagent"),
                        Some("subagent"),
                        Some("broker-subagent"),
                        None<String>,
                        None<String>,
                        None<String>,
                        Some(repo.toString()),
                        Some(5),
                        None<Int64>,
                        None<String>,
                        Some("worktree"),
                        None<Bool>,
                        None<String>,
                        Some("delete"),
                        None<String>,
                        None<String>
                    ))
                    let worktreePath = managedSubagentsString(spawned, "worktreePath")
                    let terminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(spawned, "runId"))
                    let terminalRun = terminal.get("run").getOrThrow().asObject()
                    @Expect(managedSubagentsString(terminalRun, "status"), "succeeded")
                    @Expect(managedSubagentsBool(terminalRun, "hasLiveFuture"), false)
                    @Expect(exists(worktreeHookMarker), true)
                    @Expect(exists(Path(worktreePath)), false)
                    @Expect(managedSubagentsWorktreeRegistered(repo, worktreePath), false)
                    @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
                }

                toolset.debugSetManagedSubagentCommandSpecForTest(Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                    { _sessionKey, _agentId, _task, cwdHint, _agentDir, _modelHint =>
                        ("node", [fixture, "managed-hang", pidFile.toString()], Path(cwdHint))
                    }
                ))
                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-subagent-cancel")) {
                    let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                        "fixture-task",
                        Some("broker-subagent-cancel"),
                        Some("subagent"),
                        Some("broker-subagent"),
                        None<String>, None<String>, None<String>, Some(repo.toString()), Some(20), None<Int64>,
                        None<String>, Some("worktree"), None<Bool>, None<String>, Some("delete"), None<String>, None<String>
                    ))
                    let runId = managedSubagentsString(spawned, "runId")
                    let sessionKey = managedSubagentsString(spawned, "sessionKey")
                    let launchId = toolset.debugManagedLaunchIdForTest(sessionKey)
                    let cancelWorktreePath = managedSubagentsString(spawned, "worktreePath")
                    let pidDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
                    while (!exists(pidFile) && DateTime.now().toUnixTimeStamp().toMilliseconds() < pidDeadline) {
                        sleep(Duration.millisecond * 20)
                    }
                    @Expect(exists(pidFile), true)
                    toolset.debugSetManagedCancelTimeoutsForTest(Some<(Int64, Int64)>((1, 1)))
                    let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(runId), None<String>, None<Int64>))
                    @Expect(managedSubagentsString(killed, "status"), "cancelling")
                    @Expect(managedSubagentsBool(killed, "cleanupPending"), true)
                    let rejected = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("steer"), managedSubagentsSome(runId), managedSubagentsSome("must remain busy"), None<Int64>))
                    @Expect(managedSubagentsString(rejected, "status"), "busy")
                    @Expect(toolset.debugManagedLaunchIdForTest(sessionKey), launchId)
                    toolset.debugSetManagedCancelTimeoutsForTest(None<(Int64, Int64)>)
                    let terminal = managedSubagentsWaitForTerminal(toolset, runId)
                    let terminalRun = terminal.get("run").getOrThrow().asObject()
                    @Expect(managedSubagentsString(terminalRun, "status"), "cancelled")
                    @Expect(managedSubagentsBool(terminalRun, "hasLiveFuture"), false)
                    @Expect(exists(Path(cancelWorktreePath)), false)
                    @Expect(managedSubagentsWorktreeRegistered(repo, cancelWorktreePath), false)
                    for (pid in String.fromUtf8(File.readFrom(pidFile)).split("\n")) {
                        let value = pid.trimAscii()
                        if (!value.isEmpty()) {
                            @Expect(managedSubagentsWaitPidGone(value), true)
                        }
                    }
                    @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
                }
            } finally {
                toolset.debugSetManagedSubagentCommandSpecForTest(None<(String, String, String, String, String, String) -> (String, Array<String>, Path)>)
                toolset.debugSetManagedCancelTimeoutsForTest(None<(Int64, Int64)>)
                try { remove(pidFile) } catch (_: Exception) { () }
            }
        }
    }

    @TestCase
    public func managedRegistrationKillWinsBeforeStartAndStaleFinalizeCannotReplaceHandle(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-registration-race") {
            createManagedSubagentsCustomAgentFixture("registration-race", true)
            let repo = createManagedSubagentsGitRepo("registration-race-repo")
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()
            let fixture = CliConfig.cwd.join("scripts").join("gateway-stdio-p3b-fake-child.mjs").toString()
            toolset.debugSetManagedSubagentCommandSpecForTest(Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                { _sessionKey, _agentId, _task, cwdHint, _agentDir, _modelHint =>
                    ("node", [fixture, "managed-hang"], Path(cwdHint))
                }
            ))
            try {
                toolset.debugArmManagedRegistrationLatchForTest()
                let launchFuture = spawn {
                    gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-registration-race")) {
                        managedSubagentsJson(toolset.sessionsSpawnForCommand(
                            "fixture-task", Some("registration-race"), Some("subagent"), Some("registration-race"),
                            None<String>, None<String>, None<String>, Some(repo.toString()), Some(20), None<Int64>,
                            None<String>, Some("worktree"), None<Bool>, None<String>, Some("delete"), None<String>, None<String>
                        ))
                    }
                }
                @Expect(toolset.debugWaitManagedRegistrationLatchForTest(2000), true)
                let identity = toolset.debugManagedRegistrationIdentityForTest()
                @Expect(identity[0].isEmpty(), false)
                @Expect(identity[1].isEmpty(), false)
                let killFuture = spawn {
                    gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-registration-race")) {
                        managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(identity[1]), None<String>, None<Int64>))
                    }
                }
                sleep(Duration.millisecond * 20)
                toolset.debugReleaseManagedRegistrationLatchForTest()
                let spawned = launchFuture.get(Duration.second * 5)
                let _ = killFuture.get(Duration.second * 5)
                @Expect(managedSubagentsString(spawned, "runId"), identity[1])
                let terminal = managedSubagentsWaitForTerminal(toolset, identity[1])
                let terminalRun = terminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(terminalRun, "status"), "cancelled")
                @Expect(managedSubagentsBool(terminalRun, "hasLiveFuture"), false)
                let transcript = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings()).readTranscriptRaw(identity[0]) ?? ""
                @Expect(transcript.contains("subagent started:"), false)
                let raceWorktree = managedSubagentsString(spawned, "worktreePath")
                @Expect(exists(Path(raceWorktree)), false)
                @Expect(managedSubagentsWorktreeRegistered(repo, raceWorktree), false)

                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-stale-finalize")) {
                    let active = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                        "fixture-task", Some("stale-finalize"), Some("subagent"), Some("registration-race"),
                        None<String>, None<String>, None<String>, Some(repo.toString()), Some(20), None<Int64>,
                        None<String>, Some("shared"), None<Bool>, None<String>, Some("keep"), None<String>, None<String>
                    ))
                    let activeRunId = managedSubagentsString(active, "runId")
                    let activeSessionKey = managedSubagentsString(active, "sessionKey")
                    let runningDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
                    var activeStatus = JsonObject()
                    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < runningDeadline) {
                        activeStatus = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(activeRunId), None<String>, None<Int64>))
                        if (managedSubagentsString(activeStatus.get("run").getOrThrow().asObject(), "status") == "running") { break }
                        sleep(Duration.millisecond * 20)
                    }
                    let activeLaunchId = toolset.debugManagedLaunchIdForTest(activeSessionKey)
                    @Expect(activeLaunchId > 0, true)
                    @Expect(toolset.debugFinalizeStaleManagedRunForTest(activeSessionKey, activeRunId, activeLaunchId - 1), false)
                    @Expect(toolset.debugManagedLaunchIdForTest(activeSessionKey), activeLaunchId)
                    let afterStale = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(activeRunId), None<String>, None<Int64>))
                    @Expect(managedSubagentsString(afterStale.get("run").getOrThrow().asObject(), "status"), "running")
                    let _ = toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(activeRunId), None<String>, None<Int64>)
                    let staleTerminal = managedSubagentsWaitForTerminal(toolset, activeRunId)
                    @Expect(managedSubagentsString(staleTerminal.get("run").getOrThrow().asObject(), "status"), "cancelled")
                }
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            } finally {
                toolset.debugReleaseManagedRegistrationLatchForTest()
                toolset.debugSetManagedSubagentCommandSpecForTest(None<(String, String, String, String, String, String) -> (String, Array<String>, Path)>)
            }
        }
    }

    @TestCase
    public func managedWorkspaceCleanupFailureRetainsSuccessAndFailureUntilRetry(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-cleanup-pending") {
            createManagedSubagentsCustomAgentFixture("cleanup-pending", true)
            let repo = createManagedSubagentsGitRepo("cleanup-pending-repo")
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()
            let fixture = CliConfig.cwd.join("scripts").join("gateway-stdio-p3b-fake-child.mjs").toString()
            toolset.debugSetManagedSubagentCommandSpecForTest(Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                { sessionKey, _agentId, _task, cwdHint, _agentDir, _modelHint =>
                    ("node", [fixture, if (sessionKey.contains("cleanup-pending-failed")) { "managed-invalid-utf8" } else { "managed-success" }], Path(cwdHint))
                }
            ))
            toolset.debugSetManagedWorkspaceCleanupFailureForTest(true)
            try {
                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-cleanup-pending")) {
                    for (expectedOriginal in ["succeeded", "failed"]) {
                        let spawned = managedSubagentsJson(toolset.sessionsSpawnForCommand(
                            "fixture-task-${expectedOriginal}", Some("cleanup-pending-${expectedOriginal}"), Some("subagent"), Some("cleanup-pending"),
                            None<String>, None<String>, None<String>, Some(repo.toString()), Some(5), None<Int64>,
                            None<String>, Some("worktree"), None<Bool>, None<String>, Some("delete"), None<String>, None<String>
                        ))
                        let runId = managedSubagentsString(spawned, "runId")
                        let sessionKey = managedSubagentsString(spawned, "sessionKey")
                        let worktreePath = managedSubagentsString(spawned, "worktreePath")
                        let pendingDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 5000
                        var pending = JsonObject()
                        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < pendingDeadline) {
                            pending = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                            if (managedSubagentsString(pending, "state") == "cleanup_pending") { break }
                            sleep(Duration.millisecond * 20)
                        }
                        let pendingRun = pending.get("run").getOrThrow().asObject()
                        @Expect(managedSubagentsString(pending, "state"), "cleanup_pending")
                        @Expect(managedSubagentsString(pendingRun, "status"), "running")
                        @Expect(managedSubagentsString(pendingRun, "error").contains("workspace cleanup pending"), true)
                        if (expectedOriginal == "failed") {
                            @Expect(managedSubagentsString(pendingRun, "error").contains("invalid_response_encoding"), true)
                        } else {
                            @Expect(managedSubagentsString(pendingRun, "resultSummary").contains("仓颉输出🙂"), true)
                        }
                        @Expect(managedSubagentsBool(pending, "hasLiveFuture"), true)
                        @Expect(exists(Path(worktreePath)), true)
                        @Expect(managedSubagentsWorktreeRegistered(repo, worktreePath), true)
                        let launchId = toolset.debugManagedLaunchIdForTest(sessionKey)
                        let rejected = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("send"), managedSubagentsSome(runId), managedSubagentsSome("must remain busy"), None<Int64>))
                        @Expect(managedSubagentsString(rejected, "status"), "busy")
                        @Expect(toolset.debugManagedLaunchIdForTest(sessionKey), launchId)
                        toolset.debugSetManagedWorkspaceCleanupFailureForTest(false)
                        let killed = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("kill"), managedSubagentsSome(runId), None<String>, None<Int64>))
                        @Expect(managedSubagentsString(killed, "status"), "cancelled")
                        let terminal = managedSubagentsWaitForTerminal(toolset, runId)
                        @Expect(managedSubagentsString(terminal.get("run").getOrThrow().asObject(), "status"), "cancelled")
                        @Expect(managedSubagentsBool(terminal, "hasLiveFuture"), false)
                        @Expect(exists(Path(worktreePath)), false)
                        @Expect(managedSubagentsWorktreeRegistered(repo, worktreePath), false)
                        toolset.debugSetManagedWorkspaceCleanupFailureForTest(true)
                    }
                }
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            } finally {
                toolset.debugSetManagedWorkspaceCleanupFailureForTest(false)
                toolset.debugSetManagedSubagentCommandSpecForTest(None<(String, String, String, String, String, String) -> (String, Array<String>, Path)>)
            }
        }
    }

    @TestCase
    public func managedRunPersistenceFailureRetainsHandleAndRetriesUniqueTerminal(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-persistence-pending") {
            createManagedSubagentsCustomAgentFixture("persistence-pending", true)
            let repo = createManagedSubagentsGitRepo("persistence-pending-repo")
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.allowCustomAgents = true
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let toolset = GatewayManagedSessionsToolset()
            let fixture = CliConfig.cwd.join("scripts").join("gateway-stdio-p3b-fake-child.mjs").toString()
            toolset.debugSetManagedSubagentCommandSpecForTest(Some<(String, String, String, String, String, String) -> (String, Array<String>, Path)>(
                { _sessionKey, _agentId, _task, cwdHint, _agentDir, _modelHint =>
                    ("node", [fixture, "managed-success"], Path(cwdHint))
                }
            ))
            try {
                gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-persistence-pending")) {
                    toolset.debugArmManagedRegistrationLatchForTest()
                    let launchFuture = spawn {
                        gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-persistence-pending")) {
                            managedSubagentsJson(toolset.sessionsSpawnForCommand(
                                "persist-terminal", Some("persistence-terminal"), Some("subagent"), Some("persistence-pending"),
                                None<String>, None<String>, None<String>, Some(repo.toString()), Some(5), None<Int64>,
                                None<String>, Some("shared"), None<Bool>, None<String>, Some("keep"), None<String>, None<String>
                            ))
                        }
                    }
                    @Expect(toolset.debugWaitManagedRegistrationLatchForTest(2000), true)
                    toolset.debugSetManagedRunPersistenceFailureForTest(true)
                    toolset.debugReleaseManagedRegistrationLatchForTest()
                    let spawned = launchFuture.get(Duration.second * 5)
                    let runId = managedSubagentsString(spawned, "runId")
                    let sessionKey = managedSubagentsString(spawned, "sessionKey")
                    let launchId = toolset.debugManagedLaunchIdForTest(sessionKey)
                    let pendingDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 5000
                    var pending = JsonObject()
                    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < pendingDeadline) {
                        pending = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                        if (managedSubagentsString(pending, "state") == "persistence_pending") { break }
                        sleep(Duration.millisecond * 20)
                    }
                    let pendingRun = pending.get("run").getOrThrow().asObject()
                    @Expect(managedSubagentsString(pending, "state"), "persistence_pending")
                    @Expect(gatewaySubagentRunStatusIsTerminal(managedSubagentsString(pendingRun, "status")), false)
                    @Expect(managedSubagentsBool(pending, "hasLiveFuture"), true)
                    let busy = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("send"), managedSubagentsSome(runId), managedSubagentsSome("must remain busy"), None<Int64>))
                    @Expect(managedSubagentsString(busy, "status"), "busy")
                    @Expect(toolset.debugManagedLaunchIdForTest(sessionKey), launchId)
                    toolset.debugSetManagedRunPersistenceFailureForTest(false)
                    let terminal = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                    @Expect(managedSubagentsString(terminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                    @Expect(managedSubagentsString(terminal, "state"), "succeeded")
                    @Expect(managedSubagentsBool(terminal, "hasLiveFuture"), false)
                    let terminalAgain = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(runId), None<String>, None<Int64>))
                    @Expect(managedSubagentsString(terminalAgain.get("run").getOrThrow().asObject(), "status"), "succeeded")

                    toolset.debugSetManagedWorkspaceCleanupFailureForTest(true)
                    toolset.debugArmManagedRegistrationLatchForTest()
                    let cleanupLaunchFuture = spawn {
                        gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-persistence-pending")) {
                            managedSubagentsJson(toolset.sessionsSpawnForCommand(
                                "persist-cleanup", Some("persistence-cleanup"), Some("subagent"), Some("persistence-pending"),
                                None<String>, None<String>, None<String>, Some(repo.toString()), Some(5), None<Int64>,
                                None<String>, Some("worktree"), None<Bool>, None<String>, Some("delete"), None<String>, None<String>
                            ))
                        }
                    }
                    @Expect(toolset.debugWaitManagedRegistrationLatchForTest(2000), true)
                    toolset.debugSetManagedRunPersistenceFailureForTest(true)
                    toolset.debugReleaseManagedRegistrationLatchForTest()
                    let cleanupSpawned = cleanupLaunchFuture.get(Duration.second * 5)
                    let cleanupRunId = managedSubagentsString(cleanupSpawned, "runId")
                    let cleanupSessionKey = managedSubagentsString(cleanupSpawned, "sessionKey")
                    let worktreePath = managedSubagentsString(cleanupSpawned, "worktreePath")
                    let cleanupLaunchId = toolset.debugManagedLaunchIdForTest(cleanupSessionKey)
                    let cleanupPendingDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 5000
                    var cleanupPending = JsonObject()
                    while (DateTime.now().toUnixTimeStamp().toMilliseconds() < cleanupPendingDeadline) {
                        cleanupPending = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(cleanupRunId), None<String>, None<Int64>))
                        if (managedSubagentsString(cleanupPending, "state") == "persistence_pending") { break }
                        sleep(Duration.millisecond * 20)
                    }
                    @Expect(managedSubagentsString(cleanupPending, "state"), "persistence_pending")
                    @Expect(gatewaySubagentRunStatusIsTerminal(managedSubagentsString(cleanupPending.get("run").getOrThrow().asObject(), "status")), false)
                    @Expect(managedSubagentsBool(cleanupPending, "hasLiveFuture"), true)
                    @Expect(exists(Path(worktreePath)), true)
                    @Expect(managedSubagentsWorktreeRegistered(repo, worktreePath), true)
                    let cleanupBusy = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("steer"), managedSubagentsSome(cleanupRunId), managedSubagentsSome("must remain busy"), None<Int64>))
                    @Expect(managedSubagentsString(cleanupBusy, "status"), "busy")
                    @Expect(toolset.debugManagedLaunchIdForTest(cleanupSessionKey), cleanupLaunchId)
                    toolset.debugSetManagedWorkspaceCleanupFailureForTest(false)
                    toolset.debugSetManagedRunPersistenceFailureForTest(false)
                    let cleanupTerminal = managedSubagentsJson(toolset.subagentsForTest(managedSubagentsSome("status"), managedSubagentsSome(cleanupRunId), None<String>, None<Int64>))
                    @Expect(managedSubagentsString(cleanupTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                    @Expect(managedSubagentsBool(cleanupTerminal, "hasLiveFuture"), false)
                    @Expect(exists(Path(worktreePath)), false)
                    @Expect(managedSubagentsWorktreeRegistered(repo, worktreePath), false)
                }
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            } finally {
                toolset.debugReleaseManagedRegistrationLatchForTest()
                toolset.debugSetManagedWorkspaceCleanupFailureForTest(false)
                toolset.debugSetManagedRunPersistenceFailureForTest(false)
                toolset.debugSetManagedSubagentCommandSpecForTest(None<(String, String, String, String, String, String) -> (String, Array<String>, Path)>)
            }
        }
    }

    @TestCase
    public func managedAcpBrokerSigkillReapsOwnerTreeAndRecoversGeneration(): Unit {
        withManagedSessionsToolsetTestHome("/tmp/metis-managed-broker-sigkill") {
            let toolset = GatewayManagedSessionsToolset()
            let pidFile = CliConfig.dotDir.join("managed-broker-sigkill.pids")
            gatewayWithToolRuntimeContext(GatewayToolRuntimeContext("cli", sessionKey: "cli:managed-broker-sigkill")) {
                let hanging = managedSubagentsSpawnFakeAcp(toolset, "managed-hang ${pidFile.toString()}", timeoutSeconds: 20)
                let runId = managedSubagentsString(hanging, "runId")
                let pidDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 2000
                while (!exists(pidFile) && DateTime.now().toUnixTimeStamp().toMilliseconds() < pidDeadline) {
                    sleep(Duration.millisecond * 20)
                }
                @Expect(exists(pidFile), true)
                gatewayStdioBroker().debugKillBrokerForTest()
                let terminal = managedSubagentsWaitForTerminal(toolset, runId, timeoutMs: 7000)
                let failedRun = terminal.get("run").getOrThrow().asObject()
                @Expect(managedSubagentsString(failedRun, "status"), "failed")
                @Expect(managedSubagentsString(failedRun, "error").contains("broker_exited"), true)
                for (pid in String.fromUtf8(File.readFrom(pidFile)).split("\n")) {
                    let value = pid.trimAscii()
                    if (!value.isEmpty()) {
                        @Expect(managedSubagentsWaitPidGone(value), true)
                    }
                }

                let recovered = managedSubagentsSpawnFakeAcp(toolset, "managed-empty")
                let recoveredTerminal = managedSubagentsWaitForTerminal(toolset, managedSubagentsString(recovered, "runId"))
                @Expect(managedSubagentsString(recoveredTerminal.get("run").getOrThrow().asObject(), "status"), "succeeded")
                @Expect(gatewayStdioBroker().snapshot().ownerCount, 0)
            }
            try { remove(pidFile) } catch (_: Exception) { () }
        }
    }
}


@When[os == "macOS"]
private enum GwNoticeThinCaseSelection { Input0 | Input1 | Input2 | Input3 | Input4 }

@When[os == "macOS"]
private func gwNoticeThinSelections(): Array<GwNoticeThinCaseSelection> { [GwNoticeThinCaseSelection.Input0, GwNoticeThinCaseSelection.Input1, GwNoticeThinCaseSelection.Input2, GwNoticeThinCaseSelection.Input3, GwNoticeThinCaseSelection.Input4] }

@When[os == "macOS"]
private func gwNoticeThinKey(selected: GwNoticeThinCaseSelection): String {
    match (selected) {
        case GwNoticeThinCaseSelection.Input0 => "json"
        case GwNoticeThinCaseSelection.Input1 => "malformed"
        case GwNoticeThinCaseSelection.Input2 => "invalid"
        case GwNoticeThinCaseSelection.Input3 => "nonzero"
        case GwNoticeThinCaseSelection.Input4 => "invalid_error"
    }
}

@When[os == "macOS"]
private func gwNoticeThinSelect(raw: Option<String>): GwNoticeThinCaseSelection {
    match (raw) {
        case Some(value) => match (value) {
            case "json" => GwNoticeThinCaseSelection.Input0
            case "malformed" => GwNoticeThinCaseSelection.Input1
            case "invalid" => GwNoticeThinCaseSelection.Input2
            case "nonzero" => GwNoticeThinCaseSelection.Input3
            case "invalid_error" => GwNoticeThinCaseSelection.Input4
            case _ => throw Exception("thin_input_selector_invalid")
        }
        case None => throw Exception("thin_input_selector_invalid")
    }
}

// Scratch private-helper template. Instantiate once per package, not per test.
// Required imports are listed in manifest; no production/public test framework.


@When[os == "macOS"]
private func gwNoticeThinText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("thin_fixture_invalid_encoding") }
}

@When[os == "macOS"]
private func gwNoticeThinThreadSnapshot(): (Int64, Int64, Int64) {
    (getThreadCount(), getBlockingThreadCount(), gwNoticeThinCount(6))
}

@When[os == "macOS"]
private func gwNoticeThinThreadsWithin(baseline: (Int64, Int64, Int64)): Bool {
    getThreadCount() <= baseline[0] && getBlockingThreadCount() <= baseline[1]
}

@When[os == "macOS"]
private func gwNoticeThinCount(flavor: Int32): Int64 {
    var slots = VArray<UInt64, $4096>(repeat: 0)
    let count = unsafe { proc_pidinfo(Int32(getProcessId()), flavor, 0, inout slots, 32768) }
    if (count <= 0 || count >= 32768 || count % 8 != 0) { throw Exception("thin_observation_failed") }
    Int64(count) / 8
}

@When[os == "macOS"]
private func gwNoticeThinRead(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        for (index in 0..count) { bytes.add(buffer[index]) }
        if (bytes.size > 65536) { throw Exception("thin_diagnostic_oversize") }
    }
    bytes.toArray()
}

@When[os == "macOS"]
private func gwNoticeThinJoin(worker: Future<Array<Byte>>, deadline: MonoTime): Bool {
    let remaining = deadline - MonoTime.now()
    if (remaining <= Duration.Zero) { return false }
    try { let _ = worker.get(remaining); true }
    catch (_: TimeoutException) { false }
    catch (_: Exception) { true }
}

@When[os == "macOS"]
private class GwNoticeThinCase {
    let home: Path
    let actor: Path
    let journal: Path
    let parent: String
    let nonce: String
    let bound: Bool
    var failed = false
    var completed = false
    var auxiliaryJoined = true
    var selectedCase = ""
    var warmRounds: Int64 = 0
    var formalRounds: Int64 = 0
    var negativeRounds: Int64 = 0
    var roundDirectory = None<Path>
    let priorEnvironment = ArrayList<(String, Option<String>)>()
    init(home: Path, actor: Path, nonce: String, bound: Bool) {
        this.home = home; this.actor = actor; this.nonce = nonce; this.bound = bound
        this.journal = home.join("inventory")
        this.parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
            "METIS_THIN_ACTOR_DIRECTORY", "METIS_THIN_ACTOR_NONCE", "METIS_THIN_ACTOR_CASE", "METIS_CJPM_ROOT", "PATH"]) {
            priorEnvironment.add((key, getVariable(key)))
        }
        if (bound) { check(managedRecoveryInitialize(journal, parent, nonce)) }
        else { removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY"); removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
    }
    func check(value: Bool): Unit { failed = failed || !value; @Expect(value, true) }
    func begin(name: String, commands: Array<String>): Unit {
        let path = home.join(name); Directory.create(path); Directory.create(path.join("bin")); Directory.create(path.join("responses"))
        File.writeTo(path.join("binding"), nonce.toArray())
        for (command in commands) {
            copy(actor, to: path.join("bin").join(command))
            check(chmod(path.join("bin").join(command).toString(), 0o700u32) == 0)
        }
        roundDirectory = Some(path)
        setVariable("METIS_THIN_ACTOR_DIRECTORY", path.toString())
        setVariable("METIS_THIN_ACTOR_NONCE", nonce)
        setVariable("METIS_THIN_ACTOR_CASE", "raw_routes")
        // Only this controlled selfchild changes PATH; parent env is unchanged.
        setVariable("PATH", path.join("bin").toString())
    }
    func route(command: String, phase: String, stdout: Array<Byte>, stderr: Array<Byte>, code: Int64): Unit {
        let directory = roundDirectory.getOrThrow().join("responses")
        let prefix = command + "." + phase
        File.writeTo(directory.join(prefix + ".stdout.bin"), stdout)
        File.writeTo(directory.join(prefix + ".stderr.bin"), stderr)
        File.writeTo(directory.join(prefix + ".exit.txt"), code.toString().toArray())
    }
    func receipts(): Array<JsonObject> {
        let results = ArrayList<JsonObject>()
        for (entry in Directory.readFrom(roundDirectory.getOrThrow())) {
            if (entry.name.startsWith("receipt-") && entry.name.endsWith(".json")) {
                check(entry.isRegular() && !entry.isSymbolicLink())
                let receipt = JsonValue.fromStr(gwNoticeThinText(entry.path)).asObject()
                check(receipt.get("nonce").getOrThrow().asString().getValue() == nonce)
                check(receipt.get("pid").getOrThrow().asInt().getValue() > 1)
                results.add(receipt)
            }
        }
        results.toArray()
    }
    func sourceTerminal(): Bool {
        if (!bound) { return true }
        let source = managedRecoveryProbeRecords(journal, parent, nonce, MonoTime.now() + Duration.second * 2)
        source.ok && source.terminal
    }
    func terminal(): Bool { auxiliaryJoined && sourceTerminal() }
    func stable(fd: Int64, threadBaseline: (Int64, Int64, Int64)): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        while (MonoTime.now() < deadline && (!sourceTerminal() || gwNoticeThinCount(1) > fd || !gwNoticeThinThreadsWithin(threadBaseline))) {
            sleep(Duration.millisecond * 10)
        }
        check(sourceTerminal()); check(gwNoticeThinCount(1) == fd); check(gwNoticeThinThreadsWithin(threadBaseline))
        let currentThreads = gwNoticeThinThreadSnapshot()
        println("R-THREADS warmCjTasks=${threadBaseline[0]};finalCjTasks=${currentThreads[0]};warmCjBlocking=${threadBaseline[1]};finalCjBlocking=${currentThreads[1]};warmOsThreads=${threadBaseline[2]};finalOsThreads=${currentThreads[2]}")
    }
    func finish(): Unit { completed = !failed }
    func restore(): Unit {
        for ((key, prior) in priorEnvironment) {
            match (prior) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
        }
    }
}

@When[os == "macOS"]
private func gwNoticeThinCompileActor(home: Path,
    sourceFile!: String = "thin_process_output_fixture.cj", outputName!: String = "owned-thin-actor"): (Path, Bool) {
    if (!["thin_process_output_fixture.cj", "mcp_lifecycle_fixture.cj"].contains(sourceFile) ||
        !["owned-thin-actor", "owned-mcp-actor"].contains(outputName)) { throw Exception("thin_actor_source_invalid") }
    let source = canonicalize(Path("test/fixtures/service_plugin/stdio_protocol").join(sourceFile))
    let sdk = canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
    let compilerPath = sdk.join("bin/cjc")
    let magic = canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow()))
    let stdx = magic.join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx")
    let binary = home.join(outputName)
    let compiler = launchManagedRawChild(compilerPath.toString(), [source.toString(), "--import-path", stdx.toString(),
        "-L", stdx.toString(), "-lstdx.encoding.json", "--link-options", "-rpath ${stdx.toString()}", "-o", binary.toString()],
        newGeneration: true, stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    var output = None<Future<Array<Byte>>>; var error = None<Future<Array<Byte>>>
    var original = None<Exception>; var joined = false; var reaped = false
    let operationDeadline = MonoTime.now() + Duration.second * 60
    try {
        output = Some(spawn { gwNoticeThinRead(compiler.stdOutPipe) }); error = Some(spawn { gwNoticeThinRead(compiler.stdErrPipe) })
        let code = compiler.wait(timeout: Some(max(Duration.Zero, operationDeadline - MonoTime.now()))); reaped = true
        let outputRemaining = operationDeadline - MonoTime.now()
        if (outputRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = output.getOrThrow().get(outputRemaining)
        let errorRemaining = operationDeadline - MonoTime.now()
        if (errorRemaining <= Duration.Zero) { throw Exception("thin_actor_compile_timeout") }
        let _ = error.getOrThrow().get(errorRemaining)
        if (code != 0 || !exists(binary) || !FileInfo(binary).isRegular()) { throw Exception("thin_actor_compile_failed") }
    } catch (failure: Exception) { original = Some(failure) }
    finally {
        let cleanupDeadline = MonoTime.now() + Duration.second * 3
        try {
            if (compiler.isAlive()) { compiler.terminate(force: true) }
            let _ = compiler.wait(timeout: Some(max(Duration.Zero, cleanupDeadline - MonoTime.now()))); reaped = true
        } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
        finally {
            try { compiler.closeStreams() }
            catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let outputJoined = output.map({ worker => gwNoticeThinJoin(worker, cleanupDeadline) }) ?? true
                let errorJoined = error.map({ worker => gwNoticeThinJoin(worker, cleanupDeadline) }) ?? true
                joined = outputJoined && errorJoined && MonoTime.now() <= cleanupDeadline
                try { File.writeTo(home.join("compiler-proof"), "joined:${joined}\nreaped:${reaped}\n".toArray()) }
                catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
    }
    if (let Some(failure) <- original) { throw failure }
    if (!joined || !reaped || !compiler.streamsAreClosed()) { throw Exception("thin_actor_compile_pending") }
    (binary, true)
}

@When[os == "macOS"]
private func gwNoticeThinRun(filter: String, action: (GwNoticeThinCase) -> Unit, stdin!: Array<Byte> = []): Unit {
    if (let Some(outerText) <- getVariable("METIS_THIN_OUTER")) {
        let outer = canonicalize(Path(outerText))
        let nonce = getVariable("METIS_THIN_OUTER_NONCE").getOrThrow()
        if (!outer.toString().startsWith("/private/tmp/") || gwNoticeThinText(outer.join("owned.marker")) != nonce) {
            throw Exception("thin_outer_binding_invalid")
        }
        let home = canonicalize(Path(getVariable("METIS_HOME").getOrThrow()))
        let actor = canonicalize(Path(getVariable("METIS_THIN_ACTOR_BINARY").getOrThrow()))
        if (!home.toString().startsWith(outer.toString() + "/") || actor != outer.join("owned-thin-actor")) {
            throw Exception("thin_actor_binding_invalid")
        }
        let selected = gwNoticeThinSelect(getVariable("METIS_THIN_INPUT_CASE"))
        let fixture = GwNoticeThinCase(home, actor, nonce, getVariable("METIS_THIN_BOUND") == Some("true"))
        fixture.selectedCase = gwNoticeThinKey(selected)
        var original = None<Exception>
        try { action(fixture) }
        catch (failure: Exception) { original = Some(failure) }
        finally {
            try {
                let terminal = fixture.terminal()
                let childFormal = fixture.completed && !fixture.failed && original.isNone() && terminal
                File.writeTo(home.join("formal-before-fallback.json"),
                    ("{\"formal\":${childFormal},\"terminal\":${terminal},\"recorded\":true," +
                        "\"case\":\"${fixture.selectedCase}\",\"nonce\":\"${nonce}\",\"bound\":${fixture.bound}," +
                        "\"warmRounds\":${fixture.warmRounds},\"formalRounds\":${fixture.formalRounds},\"negativeRounds\":${fixture.negativeRounds}}").toArray())
                if (!childFormal && original.isNone()) { original = Some(Exception("thin_input_child_formal_failed")) }
            } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            finally {
                let cleanupDeadline = MonoTime.now() + Duration.second * 3
                try {
                    var terminal = fixture.auxiliaryJoined
                    if (fixture.bound) {
                        let stopped = managedRecoveryStopOwnedChildren((fixture.journal.toString(), fixture.parent), cleanupDeadline)
                        let source = managedRecoveryProbeRecords(fixture.journal, fixture.parent, fixture.nonce, cleanupDeadline)
                        terminal = terminal && stopped && source.ok && source.terminal
                    }
                    terminal = terminal && MonoTime.now() <= cleanupDeadline
                    if (terminal) { fixture.restore() }
                    else if (original.isNone()) { original = Some(Exception("thin_child_cleanup_pending_evidence_retained")) }
                } catch (failure: Exception) { if (original.isNone()) { original = Some(failure) } }
            }
        }
        if (let Some(failure) <- original) { throw failure }
        return
    }
    synchronized(MetisProcessEnvironmentLock) {
        let outer = Directory.createTemp("/private/tmp")
        let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        File.writeTo(outer.join("owned.marker"), nonce.toArray())
        println("R-WRAP fixture=${outer.fileName};nonce=${nonce};kind=${filter}")
        var formal = false
        var compilerReady = false
        let aggregateDeadline = MonoTime.now() + Duration.second * 713
        var aggregateFormal: Int64 = 0
        var aggregateWarm: Int64 = 0
        var aggregateNegative: Int64 = 0
        let completedCases = HashMap<String, Int64>()
        try {
            let artifact = gwNoticeThinCompileActor(outer); compilerReady = artifact[1]
            let (_, nodeBytes, _) = managedRecoveryExecuteWithOutput("which", ["node"])
            let node = try { String.fromUtf8(nodeBytes).trimAscii() }
                catch (_: Exception) { throw Exception("thin_node_resolution_failed") }
            if (node.isEmpty() || !Path(node).isAbsolute() || !FileInfo(node).isRegular()) {
                throw Exception("thin_node_resolution_failed")
            }
            var allCases = true
            var selectorRejections: Int64 = 0
            let invalidSelections: Array<Option<String>> = [None, Some("unknown")]
            for (raw in invalidSelections) {
                try { let _ = gwNoticeThinSelect(raw) }
                catch (failure: Exception) { if (failure.message == "thin_input_selector_invalid") { selectorRejections += 1 } }
            }
            if (selectorRejections != 2) { throw Exception("thin_input_selector_validation_failed") }
            let selections = gwNoticeThinSelections()
            if (selections.size != 5) { throw Exception("thin_input_matrix_incomplete") }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    let caseName = gwNoticeThinKey(selected)
                    let scheduleKey = mode + "-" + caseName
                    if (completedCases.contains(scheduleKey) || MonoTime.now() >= aggregateDeadline) { throw Exception("thin_input_schedule_invalid") }
                    let home = outer.join(scheduleKey); Directory.create(home)
                    File.writeTo(home.join("metis.json"), "{}".toArray())
                    File.writeTo(home.join("stdin"), stdin)
                    let environment = HashMap(getVariables())
                    let providerAliases = ArrayList<String>()
                    for (descriptor in cliModelProviderCatalogDescriptors()) {
                        for (alias in descriptor.apiKeyEnvAliases) { providerAliases.add(alias.toAsciiUpper()) }
                    }
                    for (name in environment.keys().toArray()) {
                        let upper = name.toAsciiUpper()
                        if (upper.contains("PROXY") || upper.endsWith("_TOKEN") || upper.endsWith("_API_KEY") ||
                            upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") ||
                            upper.endsWith("_ACCESS_KEY_ID") || providerAliases.contains(upper)) { environment.remove(name) }
                    }
                    environment["METIS_HOME"] = home.toString()
                    environment["CURL_HOME"] = home.toString(); environment["XDG_CONFIG_HOME"] = home.toString()
                    environment["METIS_LOG_FILE"] = home.join("child.log").toString()
                    environment["METIS_THIN_OUTER"] = outer.toString(); environment["METIS_THIN_OUTER_NONCE"] = nonce
                    environment["METIS_THIN_ACTOR_BINARY"] = artifact[0].toString()
                    environment["METIS_THIN_TEST_HOME"] = home.toString()
                    environment["METIS_THIN_BOUND"] = (mode == "bound").toString()
                    environment["METIS_THIN_INPUT_CASE"] = caseName
                    environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = ""; environment["METIS_PROCESS_RECOVERY_PARENT"] = ""
                    environment["METIS_STDIO_BROKER_NODE_COMMAND"] = node
                    environment["METIS_STDIO_BROKER_SCRIPT"] = canonicalize(Path("scripts/metis-stdio-broker.mjs")).toString()
                    let driver = outer.join(scheduleKey + "-driver-inventory")
                    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
                    let binding = "thin-driver-" + scheduleKey + nonce
                    let prior = ArrayList<(String, Option<String>)>()
                    for (key in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT", "METIS_STDIO_BROKER_SCRIPT",
                        "METIS_STDIO_BROKER_NODE_COMMAND"]) { prior.add((key, getVariable(key))) }
                    var child = None<ManagedOwnedChild>; var reaped = false; var terminal = false; var childFormal = false
                    var launchPending = false
                    var bodyFailure = None<Exception>
                    try {
                        setVariable("METIS_STDIO_BROKER_SCRIPT", environment["METIS_STDIO_BROKER_SCRIPT"])
                        setVariable("METIS_STDIO_BROKER_NODE_COMMAND", node)
                        if (!managedRecoveryInitialize(driver, parent, binding)) { throw Exception("thin_driver_inventory_failed") }
                        try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
                            launchPending = true
                            child = Some(managedRecoveryLaunchOwned(getCommand(), ["--filter=" + filter, "--parallel=1",
                                "--no-progress", "--no-color", "--no-capture-output"], environment: Some<Map<String, String>>(environment),
                                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error)))
                            launchPending = false
                        }
                        let remaining = aggregateDeadline - MonoTime.now()
                        if (remaining <= Duration.Zero) { throw Exception("thin_input_aggregate_deadline") }
                        let code = child.getOrThrow().wait(timeout: Some(min(Duration.second * 60, remaining))); reaped = true
                        child.getOrThrow().closeStreams()
                        let proof = JsonValue.fromStr(gwNoticeThinText(home.join("formal-before-fallback.json"))).asObject()
                        let source = managedRecoveryProbeRecords(driver, parent, binding, MonoTime.now() + Duration.second * 3)
                        terminal = source.ok && source.terminal
                        childFormal = code == 0 && terminal && proof.get("formal").getOrThrow().asBool().getValue() &&
                            proof.get("terminal").getOrThrow().asBool().getValue() && proof.get("recorded").getOrThrow().asBool().getValue() &&
                            proof.get("case").getOrThrow().asString().getValue() == caseName &&
                            proof.get("nonce").getOrThrow().asString().getValue() == nonce &&
                            proof.get("bound").getOrThrow().asBool().getValue() == (mode == "bound") &&
                            proof.get("warmRounds").getOrThrow().asInt().getValue() == 2 &&
                            proof.get("formalRounds").getOrThrow().asInt().getValue() == 32 &&
                            proof.get("negativeRounds").getOrThrow().asInt().getValue() == (if (caseName == "json") { 0 } else { 0 })
                        if (childFormal) {
                            completedCases[scheduleKey] = proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateFormal += proof.get("formalRounds").getOrThrow().asInt().getValue()
                            aggregateWarm += proof.get("warmRounds").getOrThrow().asInt().getValue()
                            aggregateNegative += proof.get("negativeRounds").getOrThrow().asInt().getValue()
                        }
                        allCases = allCases && childFormal
                        @Expect(childFormal, true)
                        if (!childFormal) { throw Exception("thin_input_child_formal_failed") }
                    } catch (failure: Exception) { bodyFailure = Some(failure) }
                    finally {
                        try {
                            File.writeTo(home.join("parent-formal-before-fallback"),
                                "formal:${childFormal}\nreaped:${reaped}\nterminal:${terminal}\ncase:${caseName}\n".toArray())
                        } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        finally {
                            let cleanupDeadline = MonoTime.now() + Duration.second * 3
                            if (let Some(handle) <- child) {
                                try {
                                    if (handle.isAlive()) { handle.terminate(force: true) }
                                    let left = max(Duration.Zero, cleanupDeadline - MonoTime.now())
                                    let _ = handle.wait(timeout: Some(left)); reaped = true
                                } catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                finally {
                                    try { handle.closeStreams() }
                                    catch (failure: Exception) { if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                                }
                            }
                            try {
                                let stopped = managedRecoveryStopOwnedChildren((driver.toString(), parent), cleanupDeadline)
                                let source = managedRecoveryProbeRecords(driver, parent, binding, cleanupDeadline)
                                terminal = !launchPending && stopped && source.ok && source.terminal && reaped &&
                                    child.isSome() && child.getOrThrow().streamsAreClosed() && MonoTime.now() <= cleanupDeadline
                                if (terminal) {
                                    for ((key, value) in prior) {
                                        match (value) { case Some(text) => setVariable(key, text) case None => removeVariable(key) }
                                    }
                                } else {
                                    allCases = false
                                    if (bodyFailure.isNone()) { bodyFailure = Some(Exception("thin_driver_cleanup_pending")) }
                                }
                            } catch (failure: Exception) { allCases = false; if (bodyFailure.isNone()) { bodyFailure = Some(failure) } }
                        }
                    }
                    if (let Some(failure) <- bodyFailure) { throw failure }
                }
            }
            for (mode in ["absent", "bound"]) {
                for (selected in selections) {
                    if (completedCases.get(mode + "-" + gwNoticeThinKey(selected)) != Some<Int64>(32)) { throw Exception("thin_input_matrix_incomplete") }
                }
            }
            if (completedCases.size != 10 || aggregateFormal != 320 || aggregateWarm != 20 || aggregateNegative != 0 ||
                MonoTime.now() > aggregateDeadline) { throw Exception("thin_input_matrix_incomplete") }
            File.writeTo(outer.join("aggregate-formal.json"),
                ("{\"children\":${completedCases.size},\"formalRounds\":${aggregateFormal},\"warmRounds\":${aggregateWarm}," +
                    "\"negativeRounds\":${aggregateNegative},\"selectorRejections\":${selectorRejections},\"parentScheduleSeconds\":713}").toArray())

            formal = allCases
        } finally {
            if (formal && compilerReady) { remove(outer, recursive: true) }
            else { eprintln("thin_interface_failure_evidence_retained") }
        }
    }
}

@When[os == "macOS"]
@Test
public class ThinGatewayNoticeResourceTest {
    @TestCase
    public func rWrapManagedNoticeUsesActualRpcCaptureAndPreservesBusiness(): Unit {
        gwNoticeThinRun("ThinGatewayNoticeResourceTest.rWrapManagedNoticeUsesActualRpcCaptureAndPreservesBusiness", { fixture =>
            let store = memorySessionStoreForGatewayUser(CliSettingManager.readGatewaySettings())
            gatewayClearSubagentNoticeDeliveryHook()
            let toolset = GatewayManagedSessionsToolset()
            toolset.debugSetGatewayCallRunnerForTest(None<(String, JsonObject) -> JsonObject>)
            let cases: Array<(String, Array<Byte>, Array<Byte>, Int64, String)> = [
                ("json", "{\"ok\":true,\"result\":{\"messageId\":\"owned-message-中文😀\"}}\n".toArray(), [], 0, "owned-message-中文😀"),
                ("malformed", "{malformed-中文😀\n".toArray(), [], 0, "gateway-rpc"),
                ("invalid", [255u8, 254u8, 128u8, 0u8], [], 0, "gateway-rpc"),
                ("nonzero", [], "发送失败中文😀\n".toArray(), 7, ""),
                ("invalid_error", [], [255u8, 254u8, 128u8, 0u8], 7, "")]
            var completed: Int64 = 0
            var fd: Int64 = 0; var threadBaseline: (Int64, Int64, Int64) = (0, 0, 0)
            for (index in 0..cases.size + 1) {
                if (index > 0 && cases[index - 1][0] != fixture.selectedCase) { continue }
                let item = if (index == 0) { cases[0] } else { cases[index - 1] }
                let rounds = if (index == 0) { 2 } else { 32 }
                for (round in 0..rounds) {
                    fixture.begin("notice-${index}-${round}", ["metis"])
                    fixture.route("metis", "main", item[1], item[2], item[3])
                    let sessionKey = "owned-notice-${index}-${round}"
                    let record = gatewaySubagentCreateRunRecord(store.sessionsRoot(), sessionKey,
                        parentSessionKey: "telegram:direct:user:123", requesterSessionKey: "telegram:direct:user:123",
                        requesterChannel: "telegram", requesterAccountId: "telegram:default", requesterPeerId: "user:123",
                        requesterConversationId: "user:123", requesterReplyToMessageId: "888", requesterReplyInThread: false,
                        agentId: "explorer", runtime: "subagent", status: "running", transcriptPath: store.transcriptPath(sessionKey).toString())
                    let runId = gatewaySubagentRunRecordString(record, "runId")
                    let summary = if (round == 31) { String(Array<Rune>(32768, repeat: r'中')) + "😀" } else { "完成中文😀" }
                    fixture.check(gatewaySubagentMarkRunSucceeded(store.sessionsRoot(), runId, resultSummary: summary))
                    toolset.debugDeliverTerminalNoticeForTest(sessionKey)
                    let found = gatewaySubagentResolveRunRecord(store.sessionsRoot(), runId).getOrThrow()
                    fixture.check(gatewaySubagentRunRecordString(found, "status") == "succeeded")
                    fixture.check(gatewaySubagentRunRecordString(found, "resultSummary") == summary)
                    fixture.check(gatewaySubagentRunRecordString(found, "channelNoticeStatus") == if (item[4].isEmpty()) { "pending" } else { "delivered" })
                    fixture.check(gatewaySubagentRunRecordString(found, "channelNoticeMessageId") == item[4])
                    let receipts = fixture.receipts(); fixture.check(receipts.size == 1)
                    if (receipts.size == 1) {
                        let args = receipts[0].get("args").getOrThrow().asArray().getItems()
                        fixture.check(args.size == 4)
                        if (args.size == 4) {
                            fixture.check(args[0].asString().getValue() == "gateway" && args[1].asString().getValue() == "call" && args[2].asString().getValue() == "channels.send")
                            let params = JsonValue.fromStr(args[3].asString().getValue()).asObject()
                            fixture.check(params.get("channel").getOrThrow().asString().getValue() == "telegram")
                            fixture.check(params.get("peerId").getOrThrow().asString().getValue() == "user:123")
                            fixture.check(params.get("accountId").getOrThrow().asString().getValue() == "telegram:default")
                            fixture.check(params.get("replyToMessageId").getOrThrow().asString().getValue() == "888")
                            fixture.check(!params.get("replyInThread").getOrThrow().asBool().getValue())
                            // Notices preview 1200 runes; the full summary remains in the run record.
                            let expectedBody = if (round == 31) {
                                String(Array<Rune>(1200, repeat: r'中')) + "\n... (truncated)"
                            } else { "完成中文😀" }
                            let expectedNotice = "[Subagent succeeded] explorer ${runId}\nStatus: succeeded\nSummary:\n${expectedBody}\nLogs: /subagents logs ${runId}"
                            let noticeText = params.get("text").getOrThrow().asString().getValue()
                            fixture.check(noticeText == expectedNotice)
                            fixture.check(params.get("message").getOrThrow().asString().getValue() == expectedNotice)
                        }
                    }
                    if (index > 0) { fixture.stable(fd, threadBaseline); completed += 1; fixture.formalRounds += 1 }
                    else { fixture.warmRounds += 1 }
                }
                if (index == 0) { fd = gwNoticeThinCount(1); threadBaseline = gwNoticeThinThreadSnapshot() }
            }
            fixture.check(completed == 32 && fixture.formalRounds == 32 && fixture.warmRounds == 2 &&
                fixture.negativeRounds == (if (fixture.selectedCase == "json") { 0 } else { 0 }))
            println("R-WRAP-GWNOTICE case=${fixture.selectedCase};actualRounds=${completed};bound=${fixture.bound};sourceTerminal=${fixture.terminal()};formal=${!fixture.failed}")
            fixture.finish()
        })
    }
}
