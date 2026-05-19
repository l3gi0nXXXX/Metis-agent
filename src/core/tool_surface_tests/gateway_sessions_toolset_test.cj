package metis.core.tool_surface_tests

import metis.core.tools.*

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.gateway.core.gatewaySessionStoreForUser
import magic.jsonable.*

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

private func withGatewaySessionsToolsetTestHome<T>(home: String, block: () -> T): T {
    let actualHome = "${home}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
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
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            remove(Path(actualHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
    }
}

private func writeGatewaySessionsAgentToolDeny(agentId: String, deny: Array<String>): Unit {
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

private func writeGatewaySessionsAgentToAgentPolicy(enabled: Bool, allow: Array<String>, visibility: String): Unit {
    let root = JsonObject()
    let tools = JsonObject()
    let agentToAgent = JsonObject()
    agentToAgent.put("enabled", enabled.toJsonValue())
    let allowed = JsonArray([])
    for (name in allow) {
        allowed.add(JsonString(name))
    }
    agentToAgent.put("allow", allowed)
    if (!visibility.trimAscii().isEmpty()) {
        agentToAgent.put("visibility", JsonString(visibility.trimAscii()))
    }
    tools.put("agentToAgent", agentToAgent)
    root.put("tools", tools)
    let configDir = MetisConfigManager.configPath().parent
    if (!exists(configDir)) {
        Directory.create(configDir, recursive: true)
    }
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func gatewaySessionsJson(raw: String): JsonObject {
    JsonValue.fromStr(raw).asObject()
}

private func gatewaySessionsString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewaySessionsToolsetTest {
    @TestCase
    public func sessionsSendKeepsRawTranscriptAppendCompatibility(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-send-raw-append") {
            let store = gatewaySessionStoreForUser(CliSettingManager.readGatewaySettings())
            store.appendTranscriptEntry("agent:agent-a:main", "system", "existing")
            let toolset = GatewaySessionsToolset()

            let out = gatewaySessionsJson(toolset.sessionsSendForTest("agent:agent-a:main", "append-only note", Some<String>("assistant")))

            @Expect(gatewaySessionsString(out, "status"), "ok")
            @Expect(gatewaySessionsString(out, "role"), "assistant")
            @Expect(store.formatHistoryAsText("agent:agent-a:main", 10).contains("[assistant] append-only note"), true)
        }
    }

    @TestCase
    public func sessionsSendRejectsCrossAgentRuntimeSendByDefault(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-send-a2a-default-deny") {
            let store = gatewaySessionStoreForUser(CliSettingManager.readGatewaySettings())
            store.appendTranscriptEntry("agent:agent-b:main", "system", "target ready")
            let toolset = GatewaySessionsToolset()

            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                { => gatewaySessionsJson(toolset.sessionsSendA2AForTest(
                    Some<String>("agent:agent-b:main"),
                    None<String>,
                    None<String>,
                    "hello target",
                    Some<Int64>(0)
                )) }
            )

            @Expect(gatewaySessionsString(out, "status"), "forbidden")
            @Expect(gatewaySessionsString(out, "error").contains("Agent-to-agent messaging is disabled"), true)
            @Expect(store.formatHistoryAsText("agent:agent-b:main", 10).contains("[user] hello target"), false)
        }
    }

    @TestCase
    public func sessionsSendAgentToAgentTimeoutZeroReturnsAcceptedAndStartsRun(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-send-a2a-accepted") {
            writeGatewaySessionsAgentToAgentPolicy(true, ["*"], "all")
            let store = gatewaySessionStoreForUser(CliSettingManager.readGatewaySettings())
            let target = "agent:agent-b:a2a-accepted"
            store.appendTranscriptEntry(target, "system", "sessions_spawn metadata: runtime=acp, agentId=fake-runner")
            let toolset = GatewaySessionsToolset()
            toolset.debugSetSessionsSendRuntimeRunnerForTest(Some({ _sessionKey: String, _task: String => "accepted-reply" }))
            try {

                let out = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                    { => gatewaySessionsJson(toolset.sessionsSendA2AForTest(
                        Some<String>(target),
                        None<String>,
                        None<String>,
                        "ping accepted",
                        Some<Int64>(0)
                    )) }
                )

                @Expect(gatewaySessionsString(out, "status"), "accepted")
                @Expect(gatewaySessionsString(out, "sessionKey"), target)
                @Expect(out.get("liveRunStarted").getOrThrow().asBool().getValue(), true)
                @Expect(store.formatHistoryAsText(target, 10).contains("[user] ping accepted"), true)
            } finally {
                toolset.debugSetSessionsSendRuntimeRunnerForTest(None<(String, String) -> String>)
            }
        }
    }

    @TestCase
    public func sessionsSendAgentToAgentWaitsForTargetReply(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-send-a2a-reply") {
            writeGatewaySessionsAgentToAgentPolicy(true, ["agent-*"], "all")
            let store = gatewaySessionStoreForUser(CliSettingManager.readGatewaySettings())
            let target = "agent:agent-b:a2a-reply"
            store.appendTranscriptEntry(target, "system", "sessions_spawn metadata: runtime=acp, agentId=fake-runner")
            let toolset = GatewaySessionsToolset()
            toolset.debugSetSessionsSendRuntimeRunnerForTest(Some({ sessionKey: String, task: String =>
                if (sessionKey == target && task == "ping reply") { "a2a-reply" } else { "" }
            }))
            try {

                let out = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                    { => gatewaySessionsJson(toolset.sessionsSendA2AForTest(
                        Some<String>(target),
                        None<String>,
                        None<String>,
                        "ping reply",
                        Some<Int64>(5)
                    )) }
                )

                @Expect(gatewaySessionsString(out, "status"), "ok")
                @Expect(gatewaySessionsString(out, "reply").contains("a2a-reply"), true)
                @Expect(store.formatHistoryAsText(target, 10).contains("[assistant] a2a-reply"), true)
            } finally {
                toolset.debugSetSessionsSendRuntimeRunnerForTest(None<(String, String) -> String>)
            }
        }
    }

    @TestCase
    public func sessionsSendAgentToAgentReturnsTimeoutDiagnosticWhenNoReplyArrives(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-send-a2a-timeout") {
            writeGatewaySessionsAgentToAgentPolicy(true, ["*"], "all")
            let store = gatewaySessionStoreForUser(CliSettingManager.readGatewaySettings())
            let target = "agent:agent-b:a2a-timeout"
            store.appendTranscriptEntry(target, "system", "sessions_spawn metadata: runtime=acp, agentId=fake-runner")
            let toolset = GatewaySessionsToolset()
            toolset.debugSetSessionsSendRuntimeRunnerForTest(Some({ _sessionKey: String, _task: String => "" }))
            try {
                let out = gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                    { => gatewaySessionsJson(toolset.sessionsSendA2AForTest(
                        Some<String>(target),
                        None<String>,
                        None<String>,
                        "ping timeout",
                        Some<Int64>(1)
                    )) }
                )

                @Expect(gatewaySessionsString(out, "status"), "timeout")
                @Expect(gatewaySessionsString(out, "error").contains("Timed out waiting for target assistant reply"), true)
                @Expect(store.formatHistoryAsText(target, 10).contains("[user] ping timeout"), true)
            } finally {
                toolset.debugSetSessionsSendRuntimeRunnerForTest(None<(String, String) -> String>)
            }
        }
    }

    @TestCase
    public func sessionsSpawnRejectsChildToolsBeyondParentAgentPolicy(): Unit {
        withGatewaySessionsToolsetTestHome("/tmp/metis-gateway-sessions-phase6-parent-boundary") {
            writeGatewaySessionsAgentToolDeny("agent-a", ["exec"])
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.requireAgentId = true
            settings.subagents.allowAgents = ["reviewer"]
            settings.subagents.childAllowedTools = ["shellExecute"]
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()

            let toolset = GatewaySessionsToolset()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:agent-a:main", agentId: "agent-a"),
                { => gatewaySessionsJson(toolset.sessionsSpawnForCommand(
                    "attempt denied child shell",
                    Some<String>("phase6-parent-boundary"),
                    Some<String>("subagent"),
                    Some<String>("reviewer"),
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<Int64>,
                    None<Int64>,
                    None<Bool>,
                    None<String>,
                    None<String>,
                    None<String>,
                    None<String>
                )) }
            )

            @Expect(gatewaySessionsString(out, "status"), "rejected")
            @Expect(gatewaySessionsString(out, "reason").contains("parent tool policy denied"), true)
        }
    }
}
