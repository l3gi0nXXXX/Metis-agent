package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.core.model.{CODEX_RUNTIME_APP_SERVER, CodexAppServerBinaryCheck}
import metis.gateway.model.ChatType
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

private func withCodexRuntimeCommandTempHome<T>(label: String, block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try {
            return block(home)
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            setGatewayCodexRuntimeBinaryCheckForTest(None<() -> CodexAppServerBinaryCheck>)
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func writeCodexRuntimeCommandAgentConfig(home: Path): Unit {
    let root = JsonObject()
    let agents = JsonObject()
    let defaults = JsonObject()
    defaults.put("workspace", JsonString(home.join("workspaces").toString()))
    agents.put("defaults", defaults)
    let list = JsonArray([])
    let entry = JsonObject()
    entry.put("id", JsonString("codex"))
    entry.put("workspace", JsonString(home.join("workspaces").join("codex").toString()))
    entry.put("agentDir", JsonString(home.join("agents").join("codex").join("agent").toString()))
    let model = JsonObject()
    model.put("primary", JsonString("openai-codex:gpt-5.5"))
    model.put("fallbacks", JsonArray([]))
    entry.put("model", model)
    list.add(entry)
    agents.put("list", list)
    root.put("agents", agents)
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func codexRuntimeCommandJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try { return value.asString().getValue().trimAscii() } catch (_: Exception) { () }
        case None => ()
    }
    ""
}

private func codexRuntimeCommandMediaContext(route: JsonObject): JsonObject {
    let context = JsonObject()
    context.put("imRoute", route)
    let media = JsonObject()
    media.put("context", context)
    media
}

private func codexRuntimeCommandRoute(adminId: String): JsonObject {
    let route = JsonObject()
    let runtimePolicy = JsonObject()
    runtimePolicy.put("allowAdminFrom", JsonArray([JsonString(adminId)]))
    route.put("runtimePolicy", runtimePolicy)
    route
}

private func codexRuntimeCommandSnakeCaseRoute(commandName: String): JsonObject {
    let route = JsonObject()
    let runtimePolicy = JsonObject()
    runtimePolicy.put("group_user_allowed_commands", JsonArray([JsonString(commandName)]))
    route.put("runtimePolicy", runtimePolicy)
    route
}

private func readCodexRuntimeCommandAgentRuntime(): String {
    let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(MetisConfigManager.configPath()))).asObject()
    let agents = root.get("agents").getOrThrow().asObject()
    let list = agents.get("list").getOrThrow().asArray()
    for (item in list.getItems()) {
        try {
            let entry = item.asObject()
            if (codexRuntimeCommandJsonString(entry, "id") == "codex") {
                let model = entry.get("model").getOrThrow().asObject()
                return codexRuntimeCommandJsonString(model, "openaiRuntime")
            }
        } catch (_: Exception) {
            ()
        }
    }
    ""
}

private func runCodexRuntimeCommandTurn(
    home: Path,
    text: String,
    senderId!: String = "",
    route!: JsonObject = JsonObject()
): GatewayResolvedSessionTurnResult {
    let store = GatewaySessionStore(home.join("sessions"), enabled: true, agentId: "codex")
    let bridge = AgentBridge(sessionStore: store)
    gatewayExecuteSessionRequestTurn(
        bridge,
        GatewaySessionRequest(
            GatewayIngressSource.Channel("telegram"),
            channelName: "telegram",
            sessionHint: "m4-codex-runtime",
            agentId: "codex",
            text: text,
            accountId: "bot-a",
            peerId: "chat-a",
            senderId: senderId,
            chatType: Some(ChatType.Direct),
            mediaContext: if (route.size() > 0) { codexRuntimeCommandMediaContext(route) } else { JsonObject() }
        ),
        text,
        streamingEnabled: false
    )
}

@Test
public class GatewayCodexRuntimeCommandIntegrationTest {
    @TestCase
    public func enablesAppServerForCurrentAgentFromImTurn(): Unit {
        withCodexRuntimeCommandTempHome("metis-m4-codex-runtime-enable", { home: Path =>
            writeCodexRuntimeCommandAgentConfig(home)
            setGatewayCodexRuntimeBinaryCheckForTest(Some({ => CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0") }))

            let turn = runCodexRuntimeCommandTurn(
                home,
                "/codex-runtime on",
                senderId: "admin-1",
                route: codexRuntimeCommandRoute("admin-1")
            )

            @Expect(turn.execution.answer.contains("Codex runtime changed from auto to codex_app_server"), true)
            @Expect(turn.execution.answer.contains("Runtime caches were refreshed."), true)
            @Expect(turn.execution.answer.contains("\"ok\""), false)
            @Expect(turn.execution.answer.contains("\"result\""), false)
            @Expect(readCodexRuntimeCommandAgentRuntime(), CODEX_RUNTIME_APP_SERVER)
            @Expect(turn.context.turnContext.senderId, "admin-1")
            @Expect(turn.context.turnContext.chatType.isSome(), true)
        })
    }

    @TestCase
    public func rejectsNonAdminSenderWithoutPersisting(): Unit {
        withCodexRuntimeCommandTempHome("metis-m4-codex-runtime-denied", { home: Path =>
            writeCodexRuntimeCommandAgentConfig(home)
            setGatewayCodexRuntimeBinaryCheckForTest(Some({ => CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0") }))

            let turn = runCodexRuntimeCommandTurn(
                home,
                "/codex-runtime on",
                senderId: "user-1",
                route: codexRuntimeCommandRoute("admin-1")
            )

            @Expect(turn.execution.answer.contains("sender is not allowed"), true)
            @Expect(turn.execution.answer.contains("\"ok\""), false)
            @Expect(readCodexRuntimeCommandAgentRuntime(), "")
        })
    }

    @TestCase
    public func acceptsSnakeCaseUserCommandPolicyWithDirectFallback(): Unit {
        withCodexRuntimeCommandTempHome("metis-m4-codex-runtime-snake-policy", { home: Path =>
            writeCodexRuntimeCommandAgentConfig(home)
            setGatewayCodexRuntimeBinaryCheckForTest(Some({ => CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0") }))

            let turn = runCodexRuntimeCommandTurn(
                home,
                "/codex_runtime on",
                senderId: "user-1",
                route: codexRuntimeCommandSnakeCaseRoute("codex_runtime")
            )

            @Expect(turn.execution.answer.contains("Codex runtime changed from auto to codex_app_server"), true)
            @Expect(readCodexRuntimeCommandAgentRuntime(), CODEX_RUNTIME_APP_SERVER)
        })
    }

    @TestCase
    public func requiresSenderIdentityForMutation(): Unit {
        withCodexRuntimeCommandTempHome("metis-m4-codex-runtime-missing-sender", { home: Path =>
            writeCodexRuntimeCommandAgentConfig(home)
            setGatewayCodexRuntimeBinaryCheckForTest(Some({ => CodexAppServerBinaryCheck(true, status: "ok", version: "0.130.0") }))

            let turn = runCodexRuntimeCommandTurn(home, "/codex-runtime on")

            @Expect(turn.execution.answer.contains("without sender identity"), true)
            @Expect(readCodexRuntimeCommandAgentRuntime(), "")
        })
    }

    @TestCase
    public func rejectsUnavailableCodexCliWithoutPersisting(): Unit {
        withCodexRuntimeCommandTempHome("metis-m4-codex-runtime-binary-missing", { home: Path =>
            writeCodexRuntimeCommandAgentConfig(home)
            setGatewayCodexRuntimeBinaryCheckForTest(Some({ =>
                CodexAppServerBinaryCheck(false, status: "not-found", message: "Codex CLI was not found.")
            }))

            let turn = runCodexRuntimeCommandTurn(
                home,
                "/codex-runtime on",
                senderId: "admin-1",
                route: codexRuntimeCommandRoute("admin-1")
            )

            @Expect(turn.execution.answer.contains("Cannot enable codex_app_server"), true)
            @Expect(turn.execution.answer.contains("Codex CLI was not found."), true)
            @Expect(readCodexRuntimeCommandAgentRuntime(), "")
        })
    }
}
