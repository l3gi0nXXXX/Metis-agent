package metis.gateway.core

import metis.core.model.{
    CodexAppServerClient,
    CodexAppServerSession,
    codexAppServerRedactDiagnostic
}
import metis.gateway.session.GatewayTurnContext

import std.convert.Parsable
import std.fs.Path
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

public class GatewayCodexAppServerTurnRequest {
    public let sessionKey: String
    public let workspaceDir: String
    public let channelName: String
    public let agentId: String
    public let modelName: String
    public let systemPrompt: String
    public let modelInput: String
    public let turnContext: Option<GatewayTurnContext>
    public let executionControl: Option<GatewayExecutionControl>

    public init(
        sessionKey: String,
        workspaceDir: String,
        channelName: String,
        agentId: String,
        modelName: String,
        systemPrompt: String,
        modelInput: String,
        turnContext!: Option<GatewayTurnContext> = None<GatewayTurnContext>,
        executionControl!: Option<GatewayExecutionControl> = None<GatewayExecutionControl>
    ) {
        this.sessionKey = sessionKey.trimAscii()
        this.workspaceDir = workspaceDir.trimAscii()
        this.channelName = channelName.trimAscii().toAsciiLower()
        this.agentId = agentId.trimAscii()
        this.modelName = modelName.trimAscii()
        this.systemPrompt = systemPrompt
        this.modelInput = modelInput
        this.turnContext = turnContext
        this.executionControl = executionControl
    }
}

public class GatewayCodexAppServerRuntimeResult {
    public let finalText: String
    public let threadId: String
    public let turnId: String
    public let completed: Bool
    public let interrupted: Bool
    public let toolIterations: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64
    public let usage: Option<JsonObject>
    public let metadata: JsonObject

    public init(
        finalText: String,
        threadId!: String = "",
        turnId!: String = "",
        completed!: Bool = false,
        interrupted!: Bool = false,
        toolIterations!: Int64 = 0,
        promptTokens!: Int64 = -1,
        completionTokens!: Int64 = -1,
        usage!: Option<JsonObject> = None<JsonObject>,
        metadata!: JsonObject = JsonObject()
    ) {
        this.finalText = finalText
        this.threadId = threadId.trimAscii()
        this.turnId = turnId.trimAscii()
        this.completed = completed
        this.interrupted = interrupted
        this.toolIterations = toolIterations
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
        this.usage = usage
        this.metadata = metadata
    }
}

private var gatewayCodexAppServerRunnerForTest: Option<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult> =
    None<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>

public func setGatewayCodexAppServerRunnerForTest(
    runner: Option<(GatewayCodexAppServerTurnRequest) -> GatewayCodexAppServerRuntimeResult>
): Unit {
    gatewayCodexAppServerRunnerForTest = runner
}

public func gatewayBuildCodexAppServerInput(systemPrompt: String, modelInput: String): String {
    let sb = StringBuilder()
    let system = systemPrompt.trimAscii()
    if (!system.isEmpty()) {
        sb.append("<system>\n")
        sb.append(system)
        sb.append("\n</system>\n\n")
    }
    sb.append("<input>\n")
    sb.append(modelInput.trimAscii())
    sb.append("\n</input>")
    sb.toString()
}

public func gatewayCodexAppServerRuntimeMetadata(
    modelName: String,
    channelName: String,
    sessionKey: String,
    threadId!: String = "",
    turnId!: String = "",
    completed!: Bool = false,
    interrupted!: Bool = false,
    toolIterations!: Int64 = 0,
    usage!: Option<JsonObject> = None<JsonObject>
): JsonObject {
    let meta = JsonObject()
    meta.put("runtime", JsonString("codex_app_server"))
    meta.put("model", JsonString(modelName.trimAscii()))
    meta.put("channel", JsonString(channelName.trimAscii().toAsciiLower()))
    meta.put("sessionKey", JsonString(sessionKey.trimAscii()))
    meta.put("threadId", JsonString(threadId.trimAscii()))
    meta.put("turnId", JsonString(turnId.trimAscii()))
    meta.put("completed", JsonBool(completed))
    meta.put("interrupted", JsonBool(interrupted))
    meta.put("toolIterations", JsonInt(toolIterations))
    match (usage) {
        case Some(value) => meta.put("usage", value)
        case None => ()
    }
    meta
}

public func gatewayCodexAppServerUsageInt(usage: Option<JsonObject>, key: String): Int64 {
    match (usage) {
        case Some(obj) =>
            match (obj.get(key)) {
                case Some(value) =>
                    try { return value.asInt().getValue() } catch (_: Exception) { () }
                    try { return Int64.parse(value.asString().getValue().trimAscii()) } catch (_: Exception) { () }
                case None => ()
            }
        case None => ()
    }
    -1
}

public func gatewayRunCodexAppServerTurn(request: GatewayCodexAppServerTurnRequest): GatewayCodexAppServerRuntimeResult {
    match (request.executionControl) {
        case Some(control) => control.throwIfCancelled()
        case None => ()
    }
    match (gatewayCodexAppServerRunnerForTest) {
        case Some(runner) => return runner(request)
        case None => ()
    }

    let workspace = if (request.workspaceDir.trimAscii().isEmpty()) {
        Path(".").toString()
    } else {
        request.workspaceDir.trimAscii()
    }
    let client = CodexAppServerClient(cwd: Some(workspace))
    let session = CodexAppServerSession(client)
    try {
        let timeoutMs = match (request.executionControl) {
            case Some(control) => control.remainingMs()
            case None => 600000
        }
        let turn = session.runTurn(
            workspace,
            gatewayBuildCodexAppServerInput(request.systemPrompt, request.modelInput),
            timeoutMs: timeoutMs
        )
        match (request.executionControl) {
            case Some(control) =>
                control.throwIfCancelled()
                control.heartbeat()
            case None => ()
        }
        if (!turn.error.isEmpty()) {
            throw Exception(turn.error)
        }
        if (!turn.completed && turn.finalText.trimAscii().isEmpty()) {
            throw Exception("codex app-server did not return a completed response")
        }
        let promptTokens = gatewayCodexAppServerUsageInt(turn.usage, "promptTokens")
        let completionTokens = gatewayCodexAppServerUsageInt(turn.usage, "outputTokens")
        let meta = gatewayCodexAppServerRuntimeMetadata(
            request.modelName,
            request.channelName,
            request.sessionKey,
            threadId: turn.threadId,
            turnId: turn.turnId,
            completed: turn.completed,
            interrupted: turn.interrupted,
            toolIterations: turn.toolIterations,
            usage: turn.usage
        )
        return GatewayCodexAppServerRuntimeResult(
            turn.finalText,
            threadId: turn.threadId,
            turnId: turn.turnId,
            completed: turn.completed,
            interrupted: turn.interrupted,
            toolIterations: turn.toolIterations,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            usage: turn.usage,
            metadata: meta
        )
    } catch (e: Exception) {
        throw Exception(codexAppServerRedactDiagnostic(e.message))
    } finally {
        try { client.close() } catch (_: Exception) { () }
    }
}
