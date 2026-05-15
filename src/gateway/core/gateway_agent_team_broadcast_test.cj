package metis.gateway.core

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.model.ChatType
import metis.gateway.session.{GatewayIngressSource, GatewaySessionRequest}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonObject, JsonString}

private func broadcastStringArray(values: Array<String>): JsonArray {
    let out = JsonArray([])
    for (value in values) {
        out.add(JsonString(value))
    }
    out
}

private func broadcastAgentEntry(home: Path, id: String, modelRef: String, toolName: String, isDefault!: Bool = false): JsonObject {
    let entry = JsonObject()
    entry.put("id", JsonString(id))
    if (isDefault) {
        entry.put("default", JsonBool(true))
    }
    entry.put("workspace", JsonString(home.join("workspaces").join(id).toString()))
    entry.put("agentDir", JsonString(home.join("agents").join(id).join("agent").toString()))
    entry.put("sessionsDir", JsonString(home.join("sessions").join(id).toString()))
    let model = JsonObject()
    model.put("primary", JsonString(modelRef))
    entry.put("model", model)
    let tools = JsonObject()
    tools.put("allow", broadcastStringArray([toolName]))
    entry.put("tools", tools)
    return entry
}

private func broadcastBinding(agentId: String, channel: String, peerKind: String, peerId: String,
    accountId!: String = "*"): JsonObject {
    let binding = JsonObject()
    binding.put("type", JsonString("route"))
    binding.put("agentId", JsonString(agentId))
    let matchObj = JsonObject()
    matchObj.put("channel", JsonString(channel))
    matchObj.put("accountId", JsonString(accountId))
    let peer = JsonObject()
    peer.put("kind", JsonString(peerKind))
    peer.put("id", JsonString(peerId))
    matchObj.put("peer", peer)
    binding.put("match", matchObj)
    return binding
}

private func broadcastMember(agentId: String): JsonObject {
    let member = JsonObject()
    member.put("agentId", JsonString(agentId))
    return member
}

private func broadcastTeam(enabledValue: Option<JsonBool>, selectedMembers!: Array<String> = [],
    channelName!: String = "fake", peerKind!: String = "group", peerId!: String = "room-1",
    accountId!: String = "*"): JsonObject {
    let team = JsonObject()
    team.put("id", JsonString("content"))
    team.put("displayName", JsonString("Content Team"))
    team.put("defaultAgentId", JsonString("ops"))
    let members = JsonArray([])
    members.add(broadcastMember("ops"))
    members.add(broadcastMember("writer"))
    members.add(broadcastMember("reviewer"))
    team.put("members", members)
    let bindings = JsonArray([])
    bindings.add(broadcastBinding("ops", channelName, peerKind, peerId, accountId: accountId))
    team.put("bindings", bindings)
    let broadcast = JsonObject()
    match (enabledValue) {
        case Some(v) => broadcast.put("enabled", v)
        case None => ()
    }
    if (selectedMembers.size > 0) {
        broadcast.put("members", broadcastStringArray(selectedMembers))
    }
    team.put("broadcast", broadcast)
    return team
}

private func broadcastRoot(home: Path, team: JsonObject, channelName!: String = "fake",
    accountId!: String = "bot-a"): JsonObject {
    let root = JsonObject()
    let agents = JsonObject()
    let list = JsonArray([])
    list.add(broadcastAgentEntry(home, "main", "openai:gpt-main", "mainTool", isDefault: true))
    list.add(broadcastAgentEntry(home, "ops", "openai:gpt-ops", "opsTool"))
    list.add(broadcastAgentEntry(home, "writer", "openai:gpt-writer", "writerTool"))
    list.add(broadcastAgentEntry(home, "reviewer", "openai:gpt-reviewer", "reviewerTool"))
    agents.put("list", list)
    root.put("agents", agents)

    let channels = JsonObject()
    let fake = JsonObject()
    fake.put("defaultAccountId", JsonString(accountId))
    fake.put("accountIds", broadcastStringArray([accountId]))
    channels.put(channelName, fake)
    root.put("channels", channels)

    let bindings = JsonArray([])
    bindings.add(broadcastBinding("ops", channelName, "group", "room-1"))
    root.put("bindings", bindings)

    let agentTeams = JsonObject()
    agentTeams.put("list", JsonArray([team]))
    root.put("agentTeams", agentTeams)
    return root
}

private func broadcastMediaContext(channelName!: String = "fake", accountId!: String = "bot-a",
    peerKind!: String = "group", peerId!: String = "room-1", parentPeerKind!: String = "",
    parentPeerId!: String = ""): JsonObject {
    let media = JsonObject()
    let context = JsonObject()
    let route = JsonObject()
    route.put("channel", JsonString(channelName))
    route.put("accountId", JsonString(accountId))
    route.put("defaultAccountId", JsonString(accountId))
    route.put("peerKind", JsonString(peerKind))
    route.put("peerId", JsonString(peerId))
    if (!parentPeerKind.isEmpty()) {
        route.put("parentPeerKind", JsonString(parentPeerKind))
    }
    if (!parentPeerId.isEmpty()) {
        route.put("parentPeerId", JsonString(parentPeerId))
    }
    context.put("imRoute", route)
    media.put("context", context)
    return media
}

private func broadcastRequest(root: JsonObject, channelName!: String = "fake", accountId!: String = "bot-a",
    peerKind!: String = "group", peerId!: String = "room-1", parentPeerKind!: String = "",
    parentPeerId!: String = ""): GatewaySessionRequest {
    GatewaySessionRequest(
        GatewayIngressSource.Channel(channelName),
        channelName: channelName,
        sessionHint: "${channelName}:${peerKind}:${peerId}",
        text: "hello team",
        accountId: accountId,
        peerId: peerId,
        senderId: "user-1",
        conversationId: peerId,
        threadId: if (peerKind == "topic") { peerId } else { "" },
        sourceMessageId: "msg-1",
        chatType: Some(ChatType.Group),
        dmScope: "per-chat",
        replyToMessageId: "msg-1",
        replyInThread: peerKind == "topic",
        deliver: true,
        mediaContext: broadcastMediaContext(channelName: channelName, accountId: accountId, peerKind: peerKind,
            peerId: peerId, parentPeerKind: parentPeerKind, parentPeerId: parentPeerId),
        routeRoot: root,
        routeAccountId: accountId,
        routeDefaultAccountId: accountId,
        routePeerKind: peerKind,
        routePeerId: peerId,
        routeParentPeerKind: parentPeerKind,
        routeParentPeerId: parentPeerId
    )
}

private func withBroadcastTempHome<T>(label: String, block: (Path) -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-agent-team-broadcast-${label}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
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
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

private func writeBroadcastRoot(root: JsonObject): Unit {
    File.writeTo(MetisConfigManager.configPath(), root.toJsonString().toArray())
    CliConfig.invalidatePathCache()
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
}

private func broadcastRouteString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayAgentTeamBroadcastTest {
    @TestCase
    public func disabledBroadcastFallsBackToCurrentSingleAgentRouting(): Unit {
        withBroadcastTempHome("disabled", { home: Path =>
            let root = broadcastRoot(home, broadcastTeam(Some(JsonBool(false)), selectedMembers: ["writer", "reviewer"]))
            writeBroadcastRoot(root)
            let request = broadcastRequest(root)

            let direct = gatewayResolveSessionContextWithAgentRoute(request)
            let plan = gatewayResolveAgentTeamBroadcastPlan(request)

            @Expect(plan.enabled, false)
            @Expect(plan.turns.size, 1)
            @Expect(plan.turns[0].context.agentId, direct.agentId)
            @Expect(plan.turns[0].context.sessionKey, direct.sessionKey)
            @Expect(plan.turns[0].context.matchedBy, "binding.peer.exact")
        })
    }

    @TestCase
    public func enabledBroadcastFansOutOnlySelectedMembersWithIsolatedRuntimeScope(): Unit {
        withBroadcastTempHome("enabled", { home: Path =>
            let root = broadcastRoot(home, broadcastTeam(Some(JsonBool(true)), selectedMembers: ["writer", "reviewer"]))
            writeBroadcastRoot(root)
            let plan = gatewayResolveAgentTeamBroadcastPlan(broadcastRequest(root))

            @Expect(plan.enabled, true)
            @Expect(plan.teamId, "content")
            @Expect(plan.selectedAgentIds.size, 2)
            @Expect(plan.selectedAgentIds.contains("writer"), true)
            @Expect(plan.selectedAgentIds.contains("reviewer"), true)
            @Expect(plan.turns.size, 2)
            @Expect(plan.turns[0].context.agentId, "writer")
            @Expect(plan.turns[1].context.agentId, "reviewer")
            @Expect(plan.turns[0].context.sessionKey, "agent:writer:fake:group:room-1")
            @Expect(plan.turns[1].context.sessionKey, "agent:reviewer:fake:group:room-1")
            @Expect(plan.turns[0].context.sessionKey == plan.turns[1].context.sessionKey, false)
            @Expect(plan.turns[0].request.sessionHint == plan.turns[1].request.sessionHint, false)
            @Expect(plan.turns[0].context.turnContext.workspaceDir, home.join("workspaces").join("writer").toString())
            @Expect(plan.turns[1].context.turnContext.workspaceDir, home.join("workspaces").join("reviewer").toString())
            @Expect(plan.turns[0].context.turnContext.modelRef, "openai:gpt-writer")
            @Expect(plan.turns[1].context.turnContext.modelRef, "openai:gpt-reviewer")
            @Expect(plan.turns[0].context.turnContext.agentScope.toJsonString().contains("writerTool"), true)
            @Expect(plan.turns[1].context.turnContext.agentScope.toJsonString().contains("reviewerTool"), true)

            let executableWriterContext = gatewayResolveSessionContextWithAgentRoute(plan.turns[0].request)
            @Expect(executableWriterContext.agentId, "writer")
            @Expect(executableWriterContext.sessionKey, "agent:writer:fake:group:room-1")
            @Expect(broadcastRouteString(executableWriterContext.turnContext.route, "matchedBy"), "broadcast.team")
            @Expect(broadcastRouteString(executableWriterContext.turnContext.route, "broadcastTeamId"), "content")
        })
    }

    @TestCase
    public func broadcastSkipsInvalidSelectedMembersButKeepsValidFanout(): Unit {
        withBroadcastTempHome("invalid-selected", { home: Path =>
            let team = broadcastTeam(Some(JsonBool(true)), selectedMembers: ["writer", "ghost", "outsider"])
            let members = team.get("members").getOrThrow().asArray()
            members.add(broadcastMember("ghost"))
            let root = broadcastRoot(home, team)
            writeBroadcastRoot(root)
            let plan = gatewayResolveAgentTeamBroadcastPlan(broadcastRequest(root))

            @Expect(plan.enabled, true)
            @Expect(plan.selectedAgentIds.size, 1)
            @Expect(plan.selectedAgentIds[0], "writer")
            @Expect(plan.turns.size, 1)
            @Expect(plan.turns[0].context.agentId, "writer")
            @Expect(plan.diagnostics.contains("broadcast-member-unknown-agent:content:ghost"), true)
            @Expect(plan.diagnostics.contains("broadcast-member-not-in-team:content:outsider"), true)
        })
    }

    @TestCase
    public func broadcastPreservesIngressAccountThreadAndMediaRouteForTelegramFanout(): Unit {
        withBroadcastTempHome("telegram-route-preserve", { home: Path =>
            let root = broadcastRoot(
                home,
                broadcastTeam(
                    Some(JsonBool(true)),
                    selectedMembers: ["writer"],
                    channelName: "telegram",
                    peerKind: "topic",
                    peerId: "42",
                    accountId: "*"
                ),
                channelName: "telegram",
                accountId: "bot-a"
            )
            writeBroadcastRoot(root)
            let plan = gatewayResolveAgentTeamBroadcastPlan(
                broadcastRequest(
                    root,
                    channelName: "telegram",
                    accountId: "bot-b",
                    peerKind: "topic",
                    peerId: "42",
                    parentPeerKind: "group",
                    parentPeerId: "-100_acceptance"
                )
            )

            @Expect(plan.enabled, true)
            @Expect(plan.turns.size, 1)
            let turn = plan.turns[0]
            @Expect(turn.request.accountId, "bot-b")
            @Expect(turn.request.replyAccountId, "bot-b")
            @Expect(turn.request.threadId, "42")
            @Expect(turn.request.replyInThread, true)
            match (turn.context.deliveryTarget) {
                case Some(target) =>
                    @Expect(target.accountId, "bot-b")
                    @Expect(target.peerId, "42")
                    @Expect(target.threadId, "42")
                    @Expect(target.replyInThread, true)
                case None => @Expect("missing", "delivery-target")
            }
            let imRoute = turn.request.mediaContext.get("context").getOrThrow().asObject()
                .get("imRoute").getOrThrow().asObject()
            @Expect(broadcastRouteString(imRoute, "accountId"), "bot-b")
            @Expect(broadcastRouteString(imRoute, "peerKind"), "topic")
            @Expect(broadcastRouteString(imRoute, "peerId"), "42")
            @Expect(broadcastRouteString(imRoute, "parentPeerKind"), "group")
            @Expect(broadcastRouteString(imRoute, "parentPeerId"), "-100_acceptance")
        })
    }

    @TestCase
    public func broadcastRequiresBooleanEnabledTrueAndASelectedMemberList(): Unit {
        withBroadcastTempHome("explicit-enabled", { home: Path =>
            let stringEnabledTeam = broadcastTeam(None, selectedMembers: ["writer", "reviewer"])
            stringEnabledTeam.get("broadcast").getOrThrow().asObject().put("enabled", JsonString("true"))
            let stringEnabledRoot = broadcastRoot(home, stringEnabledTeam)
            writeBroadcastRoot(stringEnabledRoot)
            let stringPlan = gatewayResolveAgentTeamBroadcastPlan(broadcastRequest(stringEnabledRoot))
            @Expect(stringPlan.enabled, false)
            @Expect(stringPlan.turns.size, 1)
            @Expect(stringPlan.turns[0].context.agentId, "ops")

            let noMembersRoot = broadcastRoot(home, broadcastTeam(Some(JsonBool(true))))
            writeBroadcastRoot(noMembersRoot)
            let noMembersPlan = gatewayResolveAgentTeamBroadcastPlan(broadcastRequest(noMembersRoot))
            @Expect(noMembersPlan.enabled, false)
            @Expect(noMembersPlan.turns.size, 1)
            @Expect(noMembersPlan.diagnostics.contains("broadcast-members-empty:content"), true)
        })
    }

    @TestCase
    public func broadcastAggregateIsDeterministicAndCarriesPerAgentStatus(): Unit {
        withBroadcastTempHome("aggregate", { home: Path =>
            let root = broadcastRoot(home, broadcastTeam(Some(JsonBool(true)), selectedMembers: ["writer", "reviewer"]))
            writeBroadcastRoot(root)
            let plan = gatewayResolveAgentTeamBroadcastPlan(broadcastRequest(root))
            let writer = GatewayResolvedSessionTurnResult(
                plan.turns[0].context,
                GatewaySessionExecutionResult("writer answer", delivered: true, deliveryStatus: "delivered", deliveryMessageId: "m-writer")
            )
            let reviewer = GatewayResolvedSessionTurnResult(
                plan.turns[1].context,
                GatewaySessionExecutionResult("reviewer answer", delivered: false, deliveryStatus: "not-requested")
            )

            let aggregate = gatewayAgentTeamBroadcastAggregateJson(plan, [reviewer, writer])
            @Expect(aggregate.get("kind").getOrThrow().asString().getValue(), "agent-team-broadcast-aggregate")
            @Expect(aggregate.get("teamId").getOrThrow().asString().getValue(), "content")
            @Expect(aggregate.get("status").getOrThrow().asString().getValue(), "partial")
            @Expect(aggregate.get("delivered").getOrThrow().asBool().getValue(), true)
            let agents = aggregate.get("agents").getOrThrow().asArray()
            @Expect(agents.size(), 2)
            @Expect(agents[0].asObject().get("agentId").getOrThrow().asString().getValue(), "writer")
            @Expect(agents[0].asObject().get("deliveryStatus").getOrThrow().asString().getValue(), "delivered")
            @Expect(agents[0].asObject().get("detail").getOrThrow().asString().getValue(), "delivered")
            @Expect(agents[1].asObject().get("agentId").getOrThrow().asString().getValue(), "reviewer")
            @Expect(agents[1].asObject().get("status").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(agents[1].asObject().get("detail").getOrThrow().asString().getValue(), "not-requested")
            @Expect(aggregate.get("answer").getOrThrow().asString().getValue(), "[writer] writer answer\n[reviewer] reviewer answer")
        })
    }

    @TestCase
    public func telegramBroadcastAggregateCarriesPerMemberRouteAndSessionEvidence(): Unit {
        withBroadcastTempHome("telegram-aggregate", { home: Path =>
            let root = broadcastRoot(
                home,
                broadcastTeam(
                    Some(JsonBool(true)),
                    selectedMembers: ["writer", "reviewer"],
                    channelName: "telegram",
                    peerKind: "group",
                    peerId: "-100_acceptance",
                    accountId: "bot-a"
                ),
                channelName: "telegram",
                accountId: "bot-a"
            )
            writeBroadcastRoot(root)
            let plan = gatewayResolveAgentTeamBroadcastPlan(
                broadcastRequest(root, channelName: "telegram", accountId: "bot-a",
                    peerKind: "group", peerId: "-100_acceptance")
            )

            @Expect(plan.enabled, true)
            @Expect(plan.turns.size, 2)
            @Expect(plan.turns[0].context.agentId, "writer")
            @Expect(plan.turns[1].context.agentId, "reviewer")
            @Expect(plan.turns[0].context.channelName, "telegram")
            @Expect(plan.turns[0].context.accountId, "bot-a")
            @Expect(plan.turns[0].context.sessionKey, "agent:writer:telegram:group:-100_acceptance")
            @Expect(plan.turns[1].context.sessionKey, "agent:reviewer:telegram:group:-100_acceptance")
            @Expect(plan.turns[0].request.sessionHint, "agent:writer:telegram:group:-100_acceptance")
            @Expect(plan.turns[1].request.sessionHint, "agent:reviewer:telegram:group:-100_acceptance")

            let writer = GatewayResolvedSessionTurnResult(
                plan.turns[0].context,
                GatewaySessionExecutionResult("writer telegram answer", delivered: true,
                    deliveryStatus: "delivered", deliveryMessageId: "tg-writer")
            )
            let reviewer = GatewayResolvedSessionTurnResult(
                plan.turns[1].context,
                GatewaySessionExecutionResult("reviewer telegram answer", delivered: true,
                    deliveryStatus: "delivered", deliveryMessageId: "tg-reviewer")
            )
            let aggregate = gatewayAgentTeamBroadcastAggregateJson(plan, [reviewer, writer])
            let agents = aggregate.get("agents").getOrThrow().asArray()
            @Expect(aggregate.get("status").getOrThrow().asString().getValue(), "ok")
            @Expect(agents[0].asObject().get("sessionKey").getOrThrow().asString().getValue(),
                "agent:writer:telegram:group:-100_acceptance")
            @Expect(agents[1].asObject().get("sessionKey").getOrThrow().asString().getValue(),
                "agent:reviewer:telegram:group:-100_acceptance")
            @Expect(aggregate.get("answer").getOrThrow().asString().getValue(),
                "[writer] writer telegram answer\n[reviewer] reviewer telegram answer")
        })
    }
}
