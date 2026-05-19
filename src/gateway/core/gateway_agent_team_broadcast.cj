package metis.gateway.core

import metis.core.config.{MetisAgentScope, MetisPaths}
import metis.gateway.session.{GatewaySessionContext, GatewaySessionRequest, GatewayTurnContext, gatewayIngressSourceLabel, gatewayResolveDeliveryTarget, gatewayRuntimeRouteContextFromMediaContext}
import std.collection.ArrayList
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public class GatewayAgentTeamBroadcastTurn {
    public let teamId: String
    public let agentId: String
    public let request: GatewaySessionRequest
    public let context: GatewaySessionContext

    public init(teamId: String, agentId: String, request: GatewaySessionRequest, context: GatewaySessionContext) {
        this.teamId = teamId.trimAscii()
        this.agentId = agentId.trimAscii()
        this.request = request
        this.context = context
    }
}

public class GatewayAgentTeamBroadcastPlan {
    public let enabled: Bool
    public let teamId: String
    public let strategy: String
    public let selectedAgentIds: Array<String>
    public let turns: Array<GatewayAgentTeamBroadcastTurn>
    public let diagnostics: Array<String>

    public init(
        enabled: Bool,
        teamId: String,
        strategy: String,
        selectedAgentIds: Array<String>,
        turns: Array<GatewayAgentTeamBroadcastTurn>,
        diagnostics: Array<String>
    ) {
        this.enabled = enabled
        this.teamId = teamId.trimAscii()
        this.strategy = strategy.trimAscii().toAsciiLower()
        this.selectedAgentIds = selectedAgentIds
        this.turns = turns
        this.diagnostics = diagnostics
    }
}

// Fanout turns carry their resolved route in mediaContext and clear routeRoot on the executable
// request, so the existing turn runner cannot route every broadcast member back to the same binding.
private func gatewayBroadcastJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayBroadcastJsonBoolStrict(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func gatewayBroadcastJsonObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func gatewayBroadcastJsonArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func gatewayBroadcastNormalizeStrategy(raw: String, owner: String, defaultStrategy: String,
    diagnostics: ArrayList<String>): String {
    let normalized = raw.trimAscii().toAsciiLower()
    if (normalized.isEmpty()) {
        return defaultStrategy
    }
    if (normalized == "parallel" || normalized == "sequential") {
        return normalized
    }
    diagnostics.add("broadcast-strategy-invalid:${owner}:${normalized}")
    defaultStrategy
}

private func gatewayBroadcastCloneObject(obj: JsonObject): JsonObject {
    try {
        JsonValue.fromStr(obj.toJsonString()).asObject()
    } catch (_: Exception) {
        JsonObject()
    }
}

private func gatewayBroadcastAgentIdFromValue(value: JsonValue): String {
    try {
        return MetisAgentScope.normalizeAgentId(value.asString().getValue())
    } catch (_: Exception) {
        ()
    }
    try {
        let obj = value.asObject()
        let agentId = if (!gatewayBroadcastJsonString(obj, "agentId").isEmpty()) {
            gatewayBroadcastJsonString(obj, "agentId")
        } else {
            gatewayBroadcastJsonString(obj, "id")
        }
        return MetisAgentScope.normalizeAgentId(agentId)
    } catch (_: Exception) {
        ()
    }
    ""
}

private func gatewayBroadcastTeamId(team: JsonObject): String {
    MetisAgentScope.normalizeAgentId(gatewayBroadcastJsonString(team, "id"))
}

private func gatewayBroadcastTeamDefaultAgentId(team: JsonObject): String {
    let configured = MetisAgentScope.normalizeAgentId(gatewayBroadcastJsonString(team, "defaultAgentId"))
    if (!configured.isEmpty()) {
        return configured
    }
    let members = gatewayBroadcastJsonArray(team, "members")
    if (members.size() > 0) {
        return gatewayBroadcastAgentIdFromValue(members[0])
    }
    "main"
}

private func gatewayBroadcastAddTeam(out: ArrayList<JsonObject>, seen: ArrayList<String>, team: JsonObject): Unit {
    let teamId = gatewayBroadcastTeamId(team)
    let key = if (teamId.isEmpty()) { "idx:${out.size}" } else { teamId }
    if (!seen.contains(key)) {
        out.add(team)
        seen.add(key)
    }
}

private func gatewayBroadcastAddTeamArray(out: ArrayList<JsonObject>, seen: ArrayList<String>, teams: JsonArray): Unit {
    for (i in 0..teams.size()) {
        let team = try { teams[i].asObject() } catch (_: Exception) { JsonObject() }
        if (team.size() > 0) {
            gatewayBroadcastAddTeam(out, seen, team)
        }
    }
}

private func gatewayBroadcastTeams(root: JsonObject): Array<JsonObject> {
    let out = ArrayList<JsonObject>()
    let seen = ArrayList<String>()
    gatewayBroadcastAddTeamArray(out, seen, gatewayBroadcastJsonArray(gatewayBroadcastJsonObject(root, "agentTeams"), "list"))
    match (root.get("teams")) {
        case Some(v) =>
            try {
                gatewayBroadcastAddTeamArray(out, seen, v.asArray())
            } catch (_: Exception) {
                try {
                    gatewayBroadcastAddTeamArray(out, seen, gatewayBroadcastJsonArray(v.asObject(), "list"))
                } catch (_2: Exception) {
                    ()
                }
            }
        case None => ()
    }
    out.toArray()
}

private func gatewayBroadcastSelectedAgentIds(broadcast: JsonObject): Array<String> {
    for (key in ["members", "agentIds", "selectedMembers", "selected"]) {
        let arr = gatewayBroadcastJsonArray(broadcast, key)
        if (arr.size() == 0) {
            continue
        }
        let out = ArrayList<String>()
        for (i in 0..arr.size()) {
            let agentId = gatewayBroadcastAgentIdFromValue(arr[i])
            if (!agentId.isEmpty() && !out.contains(agentId)) {
                out.add(agentId)
            }
        }
        return out.toArray()
    }
    []
}

private func gatewayBroadcastSelectedAgentIdsFromArray(arr: JsonArray): Array<String> {
    let out = ArrayList<String>()
    for (i in 0..arr.size()) {
        let agentId = gatewayBroadcastAgentIdFromValue(arr[i])
        if (!agentId.isEmpty() && !out.contains(agentId)) {
            out.add(agentId)
        }
    }
    out.toArray()
}

private func gatewayBroadcastTeamMemberIds(team: JsonObject): ArrayList<String> {
    let out = ArrayList<String>()
    let members = gatewayBroadcastJsonArray(team, "members")
    for (i in 0..members.size()) {
        let agentId = gatewayBroadcastAgentIdFromValue(members[i])
        if (!agentId.isEmpty() && !out.contains(agentId)) {
            out.add(agentId)
        }
    }
    out
}

private func gatewayBroadcastAgentExists(root: JsonObject, agentId: String): Bool {
    let list = gatewayBroadcastJsonArray(gatewayBroadcastJsonObject(root, "agents"), "list")
    if (list.size() == 0) {
        return agentId == "main"
    }
    for (i in 0..list.size()) {
        let row = try { list[i].asObject() } catch (_: Exception) { JsonObject() }
        if (MetisAgentScope.normalizeAgentId(gatewayBroadcastJsonString(row, "id")) == agentId) {
            return true
        }
    }
    false
}

private func gatewayBroadcastChannelName(request: GatewaySessionRequest): String {
    let channel = request.channelName.trimAscii().toAsciiLower()
    if (!channel.isEmpty()) {
        return channel
    }
    gatewayIngressSourceLabel(request.source)
}

private func gatewayBroadcastRouteAccountId(request: GatewaySessionRequest): String {
    if (!request.routeAccountId.trimAscii().isEmpty()) {
        return request.routeAccountId
    }
    request.accountId
}

private func gatewayBroadcastBindingMatches(root: JsonObject, request: GatewaySessionRequest, binding: JsonObject): Bool {
    if (request.routeRoot.size() == 0 || request.routePeerKind.isEmpty() || request.routePeerId.isEmpty()) {
        return false
    }
    let tempRoot = gatewayBroadcastCloneObject(root)
    let bindings = JsonArray([])
    bindings.add(gatewayBroadcastCloneObject(binding))
    tempRoot.put("bindings", bindings)
    let route = gatewayResolveAgentRoute(
        GatewayAgentRouteInput(
            tempRoot,
            gatewayBroadcastChannelName(request),
            accountId: gatewayBroadcastRouteAccountId(request),
            defaultAccountId: request.routeDefaultAccountId,
            peerKind: request.routePeerKind,
            peerId: request.routePeerId,
            parentPeerKind: request.routeParentPeerKind,
            parentPeerId: request.routeParentPeerId,
            senderId: request.senderId,
            dmScope: request.dmScope
        )
    )
    route.matchedBy.startsWith("binding.")
}

private func gatewayBroadcastMatchBindingFromMatch(team: JsonObject, routeMatch: JsonObject): JsonObject {
    let binding = JsonObject()
    binding.put("type", JsonString("route"))
    binding.put("agentId", JsonString(gatewayBroadcastTeamDefaultAgentId(team)))
    binding.put("match", gatewayBroadcastCloneObject(routeMatch))
    binding
}

private func gatewayBroadcastAnyBindingMatches(root: JsonObject, request: GatewaySessionRequest, bindings: JsonArray): Bool {
    for (i in 0..bindings.size()) {
        let binding = try { bindings[i].asObject() } catch (_: Exception) { JsonObject() }
        if (binding.size() > 0 && gatewayBroadcastBindingMatches(root, request, binding)) {
            return true
        }
    }
    false
}

private func gatewayBroadcastTeamMatches(root: JsonObject, request: GatewaySessionRequest, team: JsonObject,
    broadcast: JsonObject): Bool {
    let broadcastBindings = gatewayBroadcastJsonArray(broadcast, "bindings")
    if (broadcastBindings.size() > 0) {
        return gatewayBroadcastAnyBindingMatches(root, request, broadcastBindings)
    }
    let routeMatch = gatewayBroadcastJsonObject(broadcast, "match")
    if (routeMatch.size() > 0) {
        let bindings = JsonArray([])
        bindings.add(gatewayBroadcastMatchBindingFromMatch(team, routeMatch))
        return gatewayBroadcastAnyBindingMatches(root, request, bindings)
    }
    gatewayBroadcastAnyBindingMatches(root, request, gatewayBroadcastJsonArray(team, "bindings"))
}

private func gatewayBroadcastMergePolicyFields(target: JsonObject, raw: JsonObject): Unit {
    for (key in ["systemPrompt", "skills", "tools", "groupPolicy", "policy", "runtimePolicy", "disableAudioPreflight"]) {
        if (target.get(key).isNone()) {
            match (raw.get(key)) {
                case Some(value) => target.put(key, value)
                case None => ()
            }
        }
    }
}

private func gatewayBroadcastTurnRoute(route: GatewayAgentRoute, rawRoute: JsonObject, teamId: String,
    selectedAgentIds: Array<String>, strategy: String, role: String, deliver: Bool, observerReason: String): JsonObject {
    let out = JsonObject()
    out.put("agentId", JsonString(route.agentId))
    out.put("channel", JsonString(route.channel))
    out.put("accountId", JsonString(route.accountId))
    out.put("preferredAccountId", JsonString(route.preferredAccountId))
    out.put("peerKind", JsonString(route.peerKind))
    out.put("peerId", JsonString(route.peerId))
    let parentPeerKind = gatewayBroadcastJsonString(rawRoute, "parentPeerKind")
    let parentPeerId = gatewayBroadcastJsonString(rawRoute, "parentPeerId")
    let threadId = gatewayBroadcastJsonString(rawRoute, "threadId")
    if (!parentPeerKind.isEmpty()) {
        out.put("parentPeerKind", JsonString(parentPeerKind))
    }
    if (!parentPeerId.isEmpty()) {
        out.put("parentPeerId", JsonString(parentPeerId))
    }
    if (!threadId.isEmpty()) {
        out.put("threadId", JsonString(threadId))
    }
    out.put("sessionKey", JsonString(route.sessionKey))
    out.put("mainSessionKey", JsonString(route.mainSessionKey))
    out.put("matchedBy", JsonString(route.matchedBy))
    out.put("broadcastTeamId", JsonString(teamId))
    out.put("broadcastEnabled", JsonBool(true))
    out.put("broadcastStrategy", JsonString(strategy))
    out.put("broadcastRole", JsonString(role))
    out.put("broadcastDeliver", JsonBool(deliver))
    if (!observerReason.isEmpty()) {
        out.put("broadcastObserverReason", JsonString(observerReason))
    }
    let selected = JsonArray([])
    for (agentId in selectedAgentIds) {
        selected.add(JsonString(agentId))
    }
    out.put("broadcastSelectedAgentIds", selected)
    if (!route.lastRoutePolicy.trimAscii().isEmpty()) {
        out.put("lastRoutePolicy", JsonString(route.lastRoutePolicy))
    }
    gatewayBroadcastMergePolicyFields(out, rawRoute)
    out
}

private func gatewayBroadcastScopeString(scope: JsonObject, key: String): String {
    match (scope.get(key)) {
        case Some(v) => try { v.asString().getValue().trimAscii() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayBroadcastContextForRoute(request: GatewaySessionRequest, route: GatewayAgentRoute,
    turnRoute: JsonObject): GatewaySessionContext {
    let scope = MetisAgentScope.resolve(
        request.routeRoot,
        agentId: route.agentId,
        homeRoot: MetisPaths.homeRootReadOnly(),
        defaultWorkspace: MetisPaths.workspaceRootReadOnly()
    )
    let turnContext = GatewayTurnContext(
        route.agentId,
        workspaceDir: gatewayBroadcastScopeString(scope, "workspaceDir"),
        agentDir: gatewayBroadcastScopeString(scope, "agentDir"),
        modelsJsonPath: gatewayBroadcastScopeString(scope, "modelsJsonPath"),
        authProfilesPath: gatewayBroadcastScopeString(scope, "authProfilesPath"),
        legacyAuthPath: gatewayBroadcastScopeString(scope, "legacyAuthPath"),
        sessionsDir: gatewayBroadcastScopeString(scope, "sessionsDir"),
        sessionKey: route.sessionKey,
        mainSessionKey: route.mainSessionKey,
        matchedBy: route.matchedBy,
        lastRoutePolicy: route.lastRoutePolicy,
        modelRef: gatewayBroadcastScopeString(scope, "modelRef"),
        channelName: gatewayBroadcastChannelName(request),
        accountId: route.accountId,
        peerId: request.peerId,
        threadId: request.threadId,
        route: turnRoute,
        agentScope: scope
    )
    GatewaySessionContext(
        request.source,
        gatewayIngressSourceLabel(request.source),
        gatewayBroadcastChannelName(request),
        route.sessionKey,
        route.agentId,
        accountId: route.accountId,
        preferredAccountId: route.preferredAccountId,
        matchedBy: route.matchedBy,
        lastRoutePolicy: route.lastRoutePolicy,
        routeDiagnostics: route.diagnostics,
        lane: request.lane,
        deliveryTarget: gatewayResolveDeliveryTarget(request, route.sessionKey, preferredAccountId: route.preferredAccountId),
        turnContext: Some(turnContext)
    )
}

private func gatewayBroadcastInboundSnapshot(request: GatewaySessionRequest): JsonObject {
    let snapshot = JsonObject()
    snapshot.put("channel", JsonString(gatewayBroadcastChannelName(request)))
    snapshot.put("accountId", JsonString(gatewayBroadcastRouteAccountId(request)))
    snapshot.put("peerKind", JsonString(request.routePeerKind))
    snapshot.put("peerId", JsonString(request.routePeerId))
    snapshot.put("parentPeerKind", JsonString(request.routeParentPeerKind))
    snapshot.put("parentPeerId", JsonString(request.routeParentPeerId))
    snapshot.put("senderId", JsonString(request.senderId))
    snapshot.put("conversationId", JsonString(request.conversationId))
    snapshot.put("threadId", JsonString(request.threadId))
    snapshot.put("sourceMessageId", JsonString(request.sourceMessageId))
    snapshot.put("text", JsonString(request.text))
    return snapshot
}

private func gatewayBroadcastMediaContextForRoute(mediaContext: JsonObject, turnRoute: JsonObject,
    inboundSnapshot: JsonObject): JsonObject {
    let media = gatewayBroadcastCloneObject(mediaContext)
    let context = match (media.get("context")) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
    context.put("imRoute", gatewayBroadcastCloneObject(turnRoute))
    context.put("broadcastInboundSnapshot", gatewayBroadcastCloneObject(inboundSnapshot))
    media.put("context", context)
    media
}

private func gatewayBroadcastExecutableRequest(request: GatewaySessionRequest, route: GatewayAgentRoute,
    turnRoute: JsonObject, inboundSnapshot: JsonObject, deliver: Bool): GatewaySessionRequest {
    GatewaySessionRequest(
        request.source,
        channelName: request.channelName,
        sessionHint: route.sessionKey,
        agentId: route.agentId,
        text: request.text,
        accountId: route.accountId,
        peerId: request.peerId,
        senderId: request.senderId,
        declaredUser: request.declaredUser,
        operatorScopes: request.operatorScopes,
        conversationId: request.conversationId,
        threadId: request.threadId,
        sourceMessageId: request.sourceMessageId,
        chatType: request.chatType,
        dmScope: request.dmScope,
        to: request.to,
        lane: request.lane,
        replyChannel: request.replyChannel,
        replyTo: request.replyTo,
        replyAccountId: if (!request.replyAccountId.isEmpty()) { request.replyAccountId } else if (!route.preferredAccountId.isEmpty()) { route.preferredAccountId } else { route.accountId },
        replyToMessageId: request.replyToMessageId,
        replyInThread: request.replyInThread,
        deliver: request.deliver && deliver,
        mediaContext: gatewayBroadcastMediaContextForRoute(request.mediaContext, turnRoute, inboundSnapshot)
    )
}

private func gatewayBroadcastRouteForAgent(request: GatewaySessionRequest, agentId: String,
    diagnostics: Array<String>): GatewayAgentRoute {
    gatewayResolveAgentRoute(
        GatewayAgentRouteInput(
            request.routeRoot,
            gatewayBroadcastChannelName(request),
            accountId: gatewayBroadcastRouteAccountId(request),
            defaultAccountId: request.routeDefaultAccountId,
            peerKind: request.routePeerKind,
            peerId: request.routePeerId,
            parentPeerKind: request.routeParentPeerKind,
            parentPeerId: request.routeParentPeerId,
            senderId: request.senderId,
            dmScope: request.dmScope,
            explicitAgentId: agentId,
            explicitMatchedBy: "broadcast.team",
            diagnostics: diagnostics
        )
    )
}

private func gatewayBroadcastSinglePlan(request: GatewaySessionRequest, diagnostics: Array<String>): GatewayAgentTeamBroadcastPlan {
    let context = gatewayResolveSessionContextWithAgentRoute(request)
    let turn = GatewayAgentTeamBroadcastTurn("", context.agentId, request, context)
    GatewayAgentTeamBroadcastPlan(false, "", "sequential", [], [turn], diagnostics)
}

private func gatewayBroadcastValidatedSelectedIds(root: JsonObject, team: JsonObject, selected: Array<String>,
    diagnostics: ArrayList<String>): Array<String> {
    let teamId = gatewayBroadcastTeamId(team)
    let members = gatewayBroadcastTeamMemberIds(team)
    let out = ArrayList<String>()
    for (agentId in selected) {
        if (!members.contains(agentId)) {
            diagnostics.add("broadcast-member-not-in-team:${teamId}:${agentId}")
            continue
        }
        if (!gatewayBroadcastAgentExists(root, agentId)) {
            diagnostics.add("broadcast-member-unknown-agent:${teamId}:${agentId}")
            continue
        }
        if (!out.contains(agentId)) {
            out.add(agentId)
        }
    }
    out.toArray()
}

private func gatewayBroadcastValidatedTopLevelSelectedIds(root: JsonObject, peerKey: String, selected: Array<String>,
    diagnostics: ArrayList<String>): Array<String> {
    let out = ArrayList<String>()
    for (agentId in selected) {
        if (!gatewayBroadcastAgentExists(root, agentId)) {
            diagnostics.add("broadcast-member-unknown-agent:top-level:${peerKey}:${agentId}")
            continue
        }
        if (!out.contains(agentId)) {
            out.add(agentId)
        }
    }
    out.toArray()
}

private func gatewayBroadcastUsesSingleActiveFeishuReply(request: GatewaySessionRequest): Bool {
    if (gatewayBroadcastChannelName(request) != "feishu") {
        return false
    }
    let peerKind = request.routePeerKind.trimAscii().toAsciiLower()
    peerKind == "group" || peerKind == "thread" || peerKind == "topic"
}

private func gatewayBroadcastActiveAgentId(request: GatewaySessionRequest, selected: Array<String>): String {
    if (selected.size == 0) {
        return ""
    }
    let direct = try {
        gatewayResolveSessionContextWithAgentRoute(request).agentId
    } catch (_: Exception) {
        ""
    }
    if (!direct.isEmpty() && selected.contains(direct)) {
        return direct
    }
    selected[0]
}

private func gatewayBroadcastBuildTurns(
    request: GatewaySessionRequest,
    teamId: String,
    selected: Array<String>,
    strategy: String,
    diagnostics: ArrayList<String>
): Array<GatewayAgentTeamBroadcastTurn> {
    let rawRoute = gatewayRuntimeRouteContextFromMediaContext(request.mediaContext)
    let inboundSnapshot = gatewayBroadcastInboundSnapshot(request)
    let turns = ArrayList<GatewayAgentTeamBroadcastTurn>()
    let singleActiveFeishuReply = gatewayBroadcastUsesSingleActiveFeishuReply(request)
    let activeAgentId = if (singleActiveFeishuReply) {
        gatewayBroadcastActiveAgentId(request, selected)
    } else {
        ""
    }
    for (agentId in selected) {
        let route = gatewayBroadcastRouteForAgent(request, agentId, diagnostics.toArray())
        if (route.agentId != agentId) {
            diagnostics.add("broadcast-route-agent-fallback:${teamId}:${agentId}:${route.agentId}")
            continue
        }
        let deliver = !singleActiveFeishuReply || agentId == activeAgentId
        let role = if (deliver) { "active" } else { "observer" }
        let observerReason = if (deliver) { "" } else { "feishu-group-single-active-reply" }
        let turnRoute = gatewayBroadcastTurnRoute(route, rawRoute, teamId, selected, strategy, role, deliver,
            observerReason)
        let executableRequest = gatewayBroadcastExecutableRequest(request, route, turnRoute, inboundSnapshot, deliver)
        let context = gatewayBroadcastContextForRoute(request, route, turnRoute)
        turns.add(GatewayAgentTeamBroadcastTurn(teamId, agentId, executableRequest, context))
    }
    turns.toArray()
}

private func gatewayBroadcastBuildPlanForTeam(request: GatewaySessionRequest, team: JsonObject,
    diagnostics: ArrayList<String>): GatewayAgentTeamBroadcastPlan {
    let teamId = gatewayBroadcastTeamId(team)
    let broadcast = gatewayBroadcastJsonObject(team, "broadcast")
    let strategy = gatewayBroadcastNormalizeStrategy(gatewayBroadcastJsonString(broadcast, "strategy"), teamId,
        "sequential", diagnostics)
    let selectedRaw = gatewayBroadcastSelectedAgentIds(broadcast)
    if (selectedRaw.size == 0) {
        diagnostics.add("broadcast-members-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    let selected = gatewayBroadcastValidatedSelectedIds(request.routeRoot, team, selectedRaw, diagnostics)
    if (selected.size == 0) {
        diagnostics.add("broadcast-members-valid-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }

    let turns = gatewayBroadcastBuildTurns(request, teamId, selected, strategy, diagnostics)
    if (turns.size == 0) {
        diagnostics.add("broadcast-turns-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    GatewayAgentTeamBroadcastPlan(true, teamId, strategy, selected, turns, diagnostics.toArray())
}

private func gatewayBroadcastRequestPeerKeys(request: GatewaySessionRequest): Array<String> {
    let out = ArrayList<String>()
    for (value in [request.routePeerId, request.peerId, request.conversationId]) {
        let normalized = value.trimAscii()
        if (!normalized.isEmpty() && !out.contains(normalized)) {
            out.add(normalized)
        }
    }
    out.toArray()
}

private func gatewayBroadcastTopLevelPeerKey(request: GatewaySessionRequest, broadcast: JsonObject): String {
    for (peerKey in gatewayBroadcastRequestPeerKeys(request)) {
        match (broadcast.get(peerKey)) {
            case Some(value) =>
                try {
                    let arr = value.asArray()
                    if (arr.size() > 0) {
                        return peerKey
                    }
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
    }
    ""
}

private func gatewayBroadcastBuildPlanForTopLevelPeerMap(request: GatewaySessionRequest,
    diagnostics: ArrayList<String>): GatewayAgentTeamBroadcastPlan {
    let broadcast = gatewayBroadcastJsonObject(request.routeRoot, "broadcast")
    if (broadcast.size() == 0) {
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    let peerKey = gatewayBroadcastTopLevelPeerKey(request, broadcast)
    if (peerKey.isEmpty()) {
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    diagnostics.add("broadcast-compat-top-level-peer-map:${peerKey}")
    let teamId = "top-level:${peerKey}"
    let strategy = gatewayBroadcastNormalizeStrategy(gatewayBroadcastJsonString(broadcast, "strategy"), teamId,
        "parallel", diagnostics)
    let selectedRaw = gatewayBroadcastSelectedAgentIdsFromArray(gatewayBroadcastJsonArray(broadcast, peerKey))
    if (selectedRaw.size == 0) {
        diagnostics.add("broadcast-members-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    let selected = gatewayBroadcastValidatedTopLevelSelectedIds(request.routeRoot, peerKey, selectedRaw, diagnostics)
    if (selected.size == 0) {
        diagnostics.add("broadcast-members-valid-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    let turns = gatewayBroadcastBuildTurns(request, teamId, selected, strategy, diagnostics)
    if (turns.size == 0) {
        diagnostics.add("broadcast-turns-empty:${teamId}")
        return gatewayBroadcastSinglePlan(request, diagnostics.toArray())
    }
    GatewayAgentTeamBroadcastPlan(true, teamId, strategy, selected, turns, diagnostics.toArray())
}

public func gatewayResolveAgentTeamBroadcastPlan(request: GatewaySessionRequest): GatewayAgentTeamBroadcastPlan {
    if (request.routeRoot.size() == 0 || request.routePeerKind.isEmpty() || request.routePeerId.isEmpty()) {
        return gatewayBroadcastSinglePlan(request, [])
    }
    let diagnostics = ArrayList<String>()
    for (team in gatewayBroadcastTeams(request.routeRoot)) {
        let broadcast = gatewayBroadcastJsonObject(team, "broadcast")
        if (!gatewayBroadcastJsonBoolStrict(broadcast, "enabled")) {
            continue
        }
        if (!gatewayBroadcastTeamMatches(request.routeRoot, request, team, broadcast)) {
            continue
        }
        return gatewayBroadcastBuildPlanForTeam(request, team, diagnostics)
    }
    gatewayBroadcastBuildPlanForTopLevelPeerMap(request, diagnostics)
}

private func gatewayBroadcastFailureResult(turn: GatewayAgentTeamBroadcastTurn, error: String): GatewayResolvedSessionTurnResult {
    GatewayResolvedSessionTurnResult(
        turn.context,
        GatewaySessionExecutionResult("", delivered: false, deliveryStatus: "exception", deliveryError: error)
    )
}

private func gatewayBroadcastExecuteOne(
    turn: GatewayAgentTeamBroadcastTurn,
    execute: (GatewayAgentTeamBroadcastTurn) -> GatewayResolvedSessionTurnResult
): GatewayResolvedSessionTurnResult {
    try {
        execute(turn)
    } catch (e: Exception) {
        gatewayBroadcastFailureResult(turn, e.message)
    }
}

public func gatewayRunAgentTeamBroadcastPlan(
    plan: GatewayAgentTeamBroadcastPlan,
    execute: (GatewayAgentTeamBroadcastTurn) -> GatewayResolvedSessionTurnResult
): Array<GatewayResolvedSessionTurnResult> {
    let out = ArrayList<GatewayResolvedSessionTurnResult>()
    if (plan.strategy == "parallel") {
        let futures = ArrayList<Future<GatewayResolvedSessionTurnResult>>()
        for (turn in plan.turns) {
            let captured = turn
            futures.add(spawn {
                gatewayBroadcastExecuteOne(captured, execute)
            })
        }
        for (i in 0..futures.size) {
            try {
                out.add(futures[i].get())
            } catch (e: Exception) {
                out.add(gatewayBroadcastFailureResult(plan.turns[i], e.message))
            }
        }
        return out.toArray()
    }
    for (turn in plan.turns) {
        out.add(gatewayBroadcastExecuteOne(turn, execute))
    }
    out.toArray()
}

private func gatewayBroadcastFindTurnResult(
    turn: GatewayAgentTeamBroadcastTurn,
    results: Array<GatewayResolvedSessionTurnResult>
): Option<GatewayResolvedSessionTurnResult> {
    for (result in results) {
        if (result.context.agentId == turn.agentId && result.context.sessionKey == turn.context.sessionKey) {
            return Some(result)
        }
    }
    None<GatewayResolvedSessionTurnResult>
}

private func gatewayBroadcastAggregateDetail(delivered: Bool, deliveryStatus: String, deliveryError: String): String {
    let status = deliveryStatus.trimAscii()
    let err = deliveryError.trimAscii()
    if (!err.isEmpty()) {
        if (!status.isEmpty()) {
            return "${status}: ${err}"
        }
        return err
    }
    if (!status.isEmpty()) {
        return status
    }
    if (delivered) {
        return "delivered"
    }
    "not-delivered"
}

public func gatewayAgentTeamBroadcastAggregateJson(
    plan: GatewayAgentTeamBroadcastPlan,
    results: Array<GatewayResolvedSessionTurnResult>
): JsonObject {
    let agents = JsonArray([])
    let answerLines = ArrayList<String>()
    var deliveredCount: Int64 = 0
    var allDelivered = plan.turns.size > 0
    for (turn in plan.turns) {
        let row = JsonObject()
        row.put("teamId", JsonString(turn.teamId))
        row.put("agentId", JsonString(turn.agentId))
        row.put("sessionKey", JsonString(turn.context.sessionKey))
        match (gatewayBroadcastFindTurnResult(turn, results)) {
            case Some(result) =>
                let execution = result.execution
                let status = if (execution.delivered) { "delivered" } else { "not-delivered" }
                if (execution.delivered) {
                    deliveredCount += 1
                } else {
                    allDelivered = false
                }
                row.put("status", JsonString(status))
                row.put("delivered", JsonBool(execution.delivered))
                row.put("deliveryStatus", JsonString(execution.deliveryStatus))
                row.put("deliveryError", JsonString(execution.deliveryError))
                row.put("error", JsonString(execution.deliveryError))
                row.put("detail", JsonString(gatewayBroadcastAggregateDetail(execution.delivered,
                    execution.deliveryStatus, execution.deliveryError)))
                row.put("elapsedMs", JsonInt(0))
                row.put("deliveryMessageId", JsonString(execution.deliveryMessageId))
                row.put("answer", JsonString(execution.answer))
                if (!execution.answer.trimAscii().isEmpty()) {
                    answerLines.add("[${turn.agentId}] ${execution.answer}")
                }
            case None =>
                allDelivered = false
                row.put("status", JsonString("missing-result"))
                row.put("delivered", JsonBool(false))
                row.put("deliveryStatus", JsonString("missing-result"))
                row.put("deliveryError", JsonString(""))
                row.put("error", JsonString(""))
                row.put("detail", JsonString("missing-result: no execution result for broadcast member"))
                row.put("elapsedMs", JsonInt(0))
                row.put("deliveryMessageId", JsonString(""))
                row.put("answer", JsonString(""))
        }
        agents.add(row)
    }

    let status = if (!plan.enabled) {
        "disabled"
    } else if (allDelivered) {
        "ok"
    } else if (deliveredCount > 0) {
        "partial"
    } else {
        "failed"
    }
    let out = JsonObject()
    out.put("kind", JsonString("agent-team-broadcast-aggregate"))
    out.put("enabled", JsonBool(plan.enabled))
    out.put("teamId", JsonString(plan.teamId))
    out.put("strategy", JsonString(plan.strategy))
    out.put("status", JsonString(status))
    out.put("delivered", JsonBool(deliveredCount > 0))
    out.put("total", JsonInt(plan.turns.size))
    out.put("deliveredCount", JsonInt(deliveredCount))
    out.put("agents", agents)
    out.put("answer", JsonString(String.join(answerLines.toArray(), delimiter: "\n")))
    out
}
