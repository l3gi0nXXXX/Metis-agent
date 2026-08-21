package metis.gateway.openclaw_runtime

import metis.core.config.GatewayUserSettings
import metis.gateway.process.gatewayStdioBroker
import metis.process.{ManagedStdioBrokerClient, ManagedStdioOwnerSpec}
import magic.jsonable.*
import std.collection.ArrayList
import std.convert.Parsable
import std.core.Duration
import std.sync.{Condition, Mutex}
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

public class OpenClawCompatHostConfig {
    public var enabled: Bool = false
    public var nodeCommand: String = "node"
    public var hostScript: String = ""
    public var pluginRoots: Array<String> = []
    public var timeoutMs: Int64 = 10000
    public var restartPolicy: String = "on-failure"
    public var backoffMs: Int64 = 1000
    public var runtimeParams: JsonObject = JsonObject()

    public init() {}
}

public class OpenClawCompatHostLaunchSpec {
    public let nodeCommand: String
    public let hostScript: String
    public let pluginRoots: Array<String>
    public let timeoutMs: Int64

    public init(nodeCommand: String, hostScript: String, pluginRoots: Array<String>, timeoutMs: Int64) {
        this.nodeCommand = nodeCommand
        this.hostScript = hostScript
        this.pluginRoots = pluginRoots
        this.timeoutMs = timeoutMs
    }
}

public enum OpenClawCompatHostStartResult {
    | Started(OpenClawCompatHostTransport)
    | Failed(String)
}

public interface OpenClawCompatHostProcessRunner {
    func start(spec: OpenClawCompatHostLaunchSpec): OpenClawCompatHostStartResult
}

private let openClawCompatOwnerLock = Mutex()
private var openClawCompatOwnerSequence: Int64 = 0
private let OPENCLAW_COMPAT_RESPONSE_QUEUE_LIMIT: Int64 = 256
private let OPENCLAW_COMPAT_RESPONSE_BYTES_LIMIT: Int64 = 4 * 1024 * 1024

private func nextOpenClawCompatOwnerId(): String {
    synchronized(openClawCompatOwnerLock) {
        openClawCompatOwnerSequence += 1
        "openclaw-compat-${openClawCompatOwnerSequence}"
    }
}

private class OpenClawCompatStdioHostTransport <: OpenClawCompatHostTransport {
    private let broker: ManagedStdioBrokerClient
    private let ownerId: String
    private let stateLock = Mutex()
    private let requestLock = Mutex()
    private var condition: Condition
    private let stdoutLines = ArrayList<String>()
    private var stdoutQueuedBytes: Int64 = 0
    private var eventPump: Option<Future<Unit>> = None<Future<Unit>>
    private var closed: Bool = false
    private var lastReadStatus: String = ""

    public init(broker: ManagedStdioBrokerClient, ownerId: String) {
        this.broker = broker
        this.ownerId = ownerId
        synchronized(this.stateLock) {
            this.condition = this.stateLock.condition()
        }
        this.eventPump = Some(spawn { this.pumpOwnerEvents() })
    }

    private func compactJsonLine(raw: String): String {
        let out = StringBuilder()
        var inString = false
        var escaped = false
        for (ch in raw.toRuneArray()) {
            if (escaped) {
                out.append(ch)
                escaped = false
                continue
            }
            if (inString && ch == r'\\') {
                out.append(ch)
                escaped = true
                continue
            }
            if (ch == r'"') {
                out.append(ch)
                inString = !inString
                continue
            }
            if (!inString && (ch == r' ' || ch == r'\n' || ch == r'\r' || ch == r'\t')) {
                continue
            }
            out.append(ch)
        }
        out.toString()
    }

    private func pumpOwnerEvents(): Unit {
        while (true) {
            if (synchronized(this.stateLock) { this.closed }) {
                return
            }
            match (this.broker.readOwnerLine(this.ownerId, timeoutMs: 250)) {
                case Some(event) =>
                    if (event.eventType == "owner.stdout") {
                        let overflow = synchronized(this.stateLock) {
                            let bytes = event.text.toArray().size
                            if (this.stdoutLines.size >= OPENCLAW_COMPAT_RESPONSE_QUEUE_LIMIT || this.stdoutQueuedBytes + bytes > OPENCLAW_COMPAT_RESPONSE_BYTES_LIMIT) {
                                this.closed = true
                                this.lastReadStatus = "buffer_capacity_exceeded"
                                this.condition.notifyAll()
                                true
                            } else {
                                this.stdoutLines.add(event.text)
                                this.stdoutQueuedBytes += bytes
                                this.condition.notifyAll()
                                false
                            }
                        }
                        if (overflow) {
                            let _ = this.broker.stopOwner(this.ownerId, timeoutMs: 1000)
                            return
                        }
                    } else if (event.eventType == "owner.exit" || event.eventType == "owner.error" || event.eventType == "owner.timeout") {
                        synchronized(this.stateLock) {
                            this.closed = true
                            this.lastReadStatus = if (!event.status.isEmpty()) { event.status } else if (event.eventType == "owner.timeout") { "timed_out" } else { "owner_exited" }
                            this.condition.notifyAll()
                        }
                        return
                    }
                    // stderr is continuously drained and intentionally excluded from protocol replies.
                case None =>
                    let snapshot = this.broker.snapshot()
                    if (!snapshot.running || !snapshot.responsive) {
                        synchronized(this.stateLock) {
                            this.closed = true
                            this.lastReadStatus = snapshot.status
                            this.condition.notifyAll()
                        }
                        return
                    }
            }
        }
    }

    private func readLine(timeoutMs: Int64): Option<String> {
        let effectiveTimeoutMs = if (timeoutMs > 0) { timeoutMs } else { 10000 }
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + effectiveTimeoutMs
        synchronized(this.stateLock) {
            while (this.stdoutLines.isEmpty() && !this.closed) {
                let remaining = deadline - DateTime.now().toUnixTimeStamp().toMilliseconds()
                if (remaining <= 0) {
                    return None<String>
                }
                let _ = this.condition.wait(timeout: Duration.millisecond * remaining)
            }
            if (!this.stdoutLines.isEmpty()) {
                let value = this.stdoutLines.remove(at: 0)
                this.stdoutQueuedBytes -= value.toArray().size
                return Some(value)
            }
            None<String>
        }
    }

    public func send(frame: JsonObject, timeoutMs!: Int64): OpenClawCompatHostTransportResult {
        synchronized(this.requestLock) {
            if (synchronized(this.stateLock) { this.closed }) {
                return OpenClawCompatHostTransportResult.Failure("OpenClaw compatibility host transport is closed")
            }
            let written = this.broker.writeOwnerLine(this.ownerId, this.compactJsonLine(frame.toJsonString()))
            if (!written.ok) {
                synchronized(this.stateLock) { this.closed = true }
                let _ = this.broker.stopOwner(this.ownerId, timeoutMs: 1000)
                return OpenClawCompatHostTransportResult.Failure("OpenClaw compatibility host write failed: ${written.status}")
            }
            match (this.readLine(timeoutMs)) {
                case Some(line) =>
                    let trimmed = line.trimAscii()
                    if (trimmed.isEmpty()) {
                        return OpenClawCompatHostTransportResult.Failure("OpenClaw compatibility host returned an empty frame")
                    }
                    try {
                        return OpenClawCompatHostTransportResult.Response(JsonValue.fromStr(trimmed).asObject())
                    } catch (_: Exception) {
                        return OpenClawCompatHostTransportResult.Failure("OpenClaw compatibility host returned invalid json: malformed_json")
                    }
                case None =>
                    let terminalStatus = synchronized(this.stateLock) { this.lastReadStatus }
                    synchronized(this.stateLock) { this.closed = true }
                    let _ = this.broker.stopOwner(this.ownerId, timeoutMs: 1000)
                    if (!terminalStatus.isEmpty() && terminalStatus != "timed_out") {
                        OpenClawCompatHostTransportResult.Failure("OpenClaw compatibility host read failed: ${terminalStatus}")
                    } else {
                        OpenClawCompatHostTransportResult.Timeout
                    }
                }
        }
    }

    public func close(): Unit {
        let shouldStop = synchronized(this.stateLock) {
            if (this.closed) {
                false
            } else {
                this.closed = true
                true
            }
        }
        if (shouldStop) {
            let _ = this.broker.stopOwner(this.ownerId, timeoutMs: 1000)
        }
        let pump = synchronized(this.stateLock) {
            let value = this.eventPump
            this.eventPump = None<Future<Unit>>
            value
        }
        match (pump) {
            case Some(future) =>
                try { let _ = future.get(Duration.second) } catch (_: Exception) { try { future.cancel() } catch (_: Exception) { () } }
            case None => ()
        }
    }

    public func isAlive(): Bool {
        if (synchronized(this.stateLock) { this.closed }) {
            return false
        }
        let snapshot = this.broker.snapshot()
        snapshot.running && snapshot.responsive
    }
}

public class OpenClawCompatStdioProcessRunner <: OpenClawCompatHostProcessRunner {
    public init() {}

    public func start(spec: OpenClawCompatHostLaunchSpec): OpenClawCompatHostStartResult {
        let command = spec.nodeCommand.trimAscii()
        let script = spec.hostScript.trimAscii()
        if (command.isEmpty() || script.isEmpty()) {
            return OpenClawCompatHostStartResult.Failed("nodeCommand and hostScript are required")
        }
        let broker = gatewayStdioBroker()
        let ownerId = nextOpenClawCompatOwnerId()
        let started = broker.startOwner(ManagedStdioOwnerSpec(
            ownerId,
            command,
            args: [script],
            stdinMode: "line",
            outputMode: "line",
            maxLineBytes: 1024 * 1024,
            maxBufferedBytes: 4 * 1024 * 1024,
            maxTotalOutputBytes: 0
        ))
        if (!started.ok) {
            return OpenClawCompatHostStartResult.Failed(started.status)
        }
        OpenClawCompatHostStartResult.Started(OpenClawCompatStdioHostTransport(broker, ownerId))
    }
}

public class OpenClawCompatHostManagerStatus {
    public let ok: Bool
    public let state: String
    public let diagnostic: JsonObject
    public let raw: JsonObject

    public init(
        ok: Bool,
        state: String,
        diagnostic!: JsonObject = JsonObject(),
        raw!: JsonObject = JsonObject()
    ) {
        this.ok = ok
        this.state = state
        this.diagnostic = diagnostic
        this.raw = raw
    }
}

private func ocManagerDiagnostic(kind: String, message!: String = ""): JsonObject {
    let out = JsonObject()
    out.put("kind", JsonString(kind))
    if (!message.trimAscii().isEmpty()) {
        out.put("message", JsonString(message.trimAscii()))
    }
    out
}

private func ocManagerString(obj: JsonObject, key: String, fallback: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                let value = v.asString().getValue().trimAscii()
                if (value.isEmpty()) { fallback } else { value }
            } catch (_: Exception) {
                fallback
            }
        case None => fallback
    }
}

private func ocManagerBool(obj: JsonObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            try { v.asBool().getValue() } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func ocManagerInt(obj: JsonObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            try { Int64.parse(v.toJsonString()) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

private func ocManagerArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func ocManagerObject(obj: JsonObject, key: String): JsonObject {
    match (obj.get(key)) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func ocManagerConfigObject(user: GatewayUserSettings): JsonObject {
    match (user.channelsExtra) {
        case Some(extra) =>
            for (key in ["openclawRuntime", "openclawCompatHost", "openclawCompatibilityHost"]) {
                match (extra.get(key)) {
                    case Some(v) => try { return v.asObject() } catch (_: Exception) { () }
                    case None => ()
                }
            }
        case None => ()
    }
    JsonObject()
}

public func openClawCompatHostConfigFromGatewaySettings(user: GatewayUserSettings): OpenClawCompatHostConfig {
    let raw = ocManagerConfigObject(user)
    let config = OpenClawCompatHostConfig()
    config.runtimeParams = raw
    config.enabled = ocManagerBool(raw, "enabled", false)
    config.nodeCommand = ocManagerString(raw, "nodeCommand", "node")
    config.hostScript = ocManagerString(raw, "hostScript", "")
    let roots = ArrayList<String>()
    let arr = ocManagerArray(raw, "pluginRoots")
    for (i in 0..arr.size()) {
        let root = try { arr[i].asString().getValue().trimAscii() } catch (_: Exception) { "" }
        if (!root.isEmpty()) {
            roots.add(root)
        }
    }
    config.pluginRoots = roots.toArray()
    let timeoutMs = ocManagerInt(raw, "timeoutMs", 10000)
    config.timeoutMs = if (timeoutMs > 0) { timeoutMs } else { 10000 }
    config.restartPolicy = ocManagerString(raw, "restartPolicy", "on-failure")
    let backoffMs = ocManagerInt(raw, "backoffMs", 1000)
    config.backoffMs = if (backoffMs > 0) { backoffMs } else { 1000 }
    config
}

private func ocManagerRegistryArray(obj: JsonObject, key: String): JsonArray {
    match (obj.get(key)) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

public class OpenClawCompatGatewayRegistryBridge {
    public let raw: JsonObject
    public let channels: JsonArray
    public let httpRoutes: JsonArray
    public let tools: JsonArray
    public let providers: JsonArray
    public let hooks: JsonArray

    public init(raw!: JsonObject = JsonObject()) {
        this.raw = raw
        this.channels = ocManagerRegistryArray(raw, "channels")
        this.httpRoutes = ocManagerRegistryArray(raw, "httpRoutes")
        this.tools = ocManagerRegistryArray(raw, "tools")
        this.providers = ocManagerRegistryArray(raw, "providers")
        this.hooks = ocManagerRegistryArray(raw, "hooks")
    }

    public func channelCount(): Int64 { this.channels.size() }
    public func httpRouteCount(): Int64 { this.httpRoutes.size() }
    public func toolCount(): Int64 { this.tools.size() }
    public func providerCount(): Int64 { this.providers.size() }
    public func hookCount(): Int64 { this.hooks.size() }
}

public class OpenClawCompatRegistrySyncSummary {
    public let channels: Int64
    public let httpRoutes: Int64
    public let tools: Int64
    public let providers: Int64
    public let hooks: Int64

    public init(
        channels!: Int64 = 0,
        httpRoutes!: Int64 = 0,
        tools!: Int64 = 0,
        providers!: Int64 = 0,
        hooks!: Int64 = 0
    ) {
        this.channels = channels
        this.httpRoutes = httpRoutes
        this.tools = tools
        this.providers = providers
        this.hooks = hooks
    }

    public func toJson(): JsonObject {
        let out = JsonObject()
        out.put("channels", this.channels.toJsonValue())
        out.put("httpRoutes", this.httpRoutes.toJsonValue())
        out.put("tools", this.tools.toJsonValue())
        out.put("providers", this.providers.toJsonValue())
        out.put("hooks", this.hooks.toJsonValue())
        return out
    }
}

public class OpenClawCompatHostManager {
    private let config: OpenClawCompatHostConfig
    private let runner: OpenClawCompatHostProcessRunner
    private var client: Option<OpenClawCompatHostClient> = None<OpenClawCompatHostClient>
    private var state: String = "stopped"
    private var restartBackoffActive: Bool = false
    private var lastDiagnostic: JsonObject = JsonObject()
    private var lastRaw: JsonObject = JsonObject()
    private var registryBridge: OpenClawCompatGatewayRegistryBridge = OpenClawCompatGatewayRegistryBridge()
    private var registrySync: OpenClawCompatRegistrySyncSummary = OpenClawCompatRegistrySyncSummary()

    public init(
        config: OpenClawCompatHostConfig,
        runner!: OpenClawCompatHostProcessRunner = OpenClawCompatStdioProcessRunner()
    ) {
        this.config = config
        this.runner = runner
    }

    private func pluginLoadParams(): JsonObject {
        let params = JsonObject()
        let roots = JsonArray([])
        for (root in this.config.pluginRoots) {
            roots.add(JsonString(root))
        }
        params.put("roots", roots)
        let runtime = JsonObject()
        runtime.put("version", JsonString("metis-openclaw-compat"))
        params.put("runtime", runtime)
        for (key in ["config", "secrets", "permissions", "fetchPolicy"]) {
            match (this.config.runtimeParams.get(key)) {
                case Some(v) => params.put(key, v)
                case None => ()
            }
        }
        params
    }

    private func syncRegisteredCapabilities(client: OpenClawCompatHostClient): OpenClawCompatHostClientResult {
        let registered = client.request("plugin.registeredCapabilities")
        if (registered.ok) {
            this.registryBridge = OpenClawCompatGatewayRegistryBridge(raw: ocManagerObject(registered.result, "gatewayRegistries"))
            this.registrySync = OpenClawCompatRegistrySyncSummary(
                channels: this.registryBridge.channelCount(),
                httpRoutes: this.registryBridge.httpRouteCount(),
                tools: this.registryBridge.toolCount(),
                providers: this.registryBridge.providerCount(),
                hooks: this.registryBridge.hookCount()
            )
        }
        registered
    }

    private func status(ok: Bool, state: String, diagnostic!: JsonObject = JsonObject(), raw!: JsonObject = JsonObject()): OpenClawCompatHostManagerStatus {
        this.state = state
        this.lastDiagnostic = diagnostic
        this.lastRaw = raw
        OpenClawCompatHostManagerStatus(ok, state, diagnostic: diagnostic, raw: raw)
    }

    public func start(): OpenClawCompatHostManagerStatus {
        if (!this.config.enabled) {
            return this.status(true, "disabled")
        }
        match (this.client) {
            case Some(existing) =>
                if (existing.isAlive()) {
                    return this.status(true, "running")
                }
            case None => ()
        }
        if (this.restartBackoffActive) {
            return this.status(false, "backoff", diagnostic: ocManagerDiagnostic("restart_backoff"))
        }
        let spec = OpenClawCompatHostLaunchSpec(
            this.config.nodeCommand,
            this.config.hostScript,
            this.config.pluginRoots,
            this.config.timeoutMs
        )
        match (this.runner.start(spec)) {
            case Started(transport) =>
                let client = OpenClawCompatHostClient(transport, defaultTimeoutMs: this.config.timeoutMs)
                this.client = Some(client)
                let loaded = client.request("plugin.load", params: this.pluginLoadParams())
                if (loaded.ok) {
                    let registered = this.syncRegisteredCapabilities(client)
                    if (!registered.ok) {
                        let _ = client.stop()
                        this.client = None<OpenClawCompatHostClient>
                        return this.status(false, registered.status, diagnostic: registered.diagnostic, raw: registered.raw)
                    }
                    return this.status(true, "running", raw: loaded.raw)
                }
                let _ = client.stop()
                this.client = None<OpenClawCompatHostClient>
                return this.status(false, loaded.status, diagnostic: loaded.diagnostic, raw: loaded.raw)
            case Failed(reason) =>
                this.client = None<OpenClawCompatHostClient>
                return this.status(false, "error", diagnostic: ocManagerDiagnostic("launch_failed", message: reason))
        }
    }

    public func stop(): OpenClawCompatHostManagerStatus {
        match (this.client) {
            case Some(existing) =>
                let stopped = existing.stop()
                this.client = None<OpenClawCompatHostClient>
                this.restartBackoffActive = false
                this.registryBridge = OpenClawCompatGatewayRegistryBridge()
                this.registrySync = OpenClawCompatRegistrySyncSummary()
                return this.status(stopped.ok, "stopped", diagnostic: stopped.diagnostic, raw: stopped.raw)
            case None =>
                this.restartBackoffActive = false
                this.registryBridge = OpenClawCompatGatewayRegistryBridge()
                this.registrySync = OpenClawCompatRegistrySyncSummary()
                return this.status(true, "stopped")
        }
    }

    public func health(): OpenClawCompatHostManagerStatus {
        if (!this.config.enabled) {
            return this.status(true, "disabled")
        }
        match (this.client) {
            case Some(existing) =>
                if (!existing.isAlive()) {
                    this.restartBackoffActive = true
                    return this.status(false, "crashed", diagnostic: ocManagerDiagnostic("host_crashed"))
                }
                let healthy = existing.health()
                if (healthy.ok) {
                    return this.status(true, "running", raw: healthy.raw)
                }
                return this.status(false, healthy.status, diagnostic: healthy.diagnostic, raw: healthy.raw)
            case None =>
                return this.status(false, "stopped", diagnostic: ocManagerDiagnostic("host_not_started"))
        }
    }

    public func restart(): OpenClawCompatHostManagerStatus {
        if (this.config.restartPolicy.trimAscii().toAsciiLower() == "never") {
            return this.status(false, "disabled", diagnostic: ocManagerDiagnostic("restart_disabled"))
        }
        if (this.restartBackoffActive) {
            return this.status(false, "backoff", diagnostic: ocManagerDiagnostic("restart_backoff"))
        }
        let _ = this.stop()
        this.start()
    }

    public func snapshot(): OpenClawCompatHostManagerStatus {
        OpenClawCompatHostManagerStatus(
            this.state == "running" || this.state == "disabled" || this.state == "stopped",
            this.state,
            diagnostic: this.lastDiagnostic
        )
    }

    public func gatewayRegistryBridge(): OpenClawCompatGatewayRegistryBridge {
        this.registryBridge
    }

    public func registrySyncSummary(): OpenClawCompatRegistrySyncSummary {
        this.registrySync
    }

    public func setRegistrySyncSummary(summary: OpenClawCompatRegistrySyncSummary): Unit {
        this.registrySync = summary
    }

    public func invoke(method: String, payload: JsonObject): JsonObject {
        match (this.client) {
            case Some(existing) =>
                if (!existing.isAlive()) {
                    let out = JsonObject()
                    out.put("ok", false.toJsonValue())
                    out.put("status", JsonString("crashed"))
                    out.put("diagnostic", ocManagerDiagnostic("host_crashed"))
                    return out
                }
                let result = existing.request(method.trimAscii(), params: payload)
                if (result.ok) {
                    return result.result
                }
                let out = JsonObject()
                out.put("ok", false.toJsonValue())
                out.put("status", JsonString(result.status))
                out.put("diagnostic", result.diagnostic)
                out.put("raw", result.raw)
                return out
            case None =>
                let out = JsonObject()
                out.put("ok", false.toJsonValue())
                out.put("status", JsonString("stopped"))
                out.put("diagnostic", ocManagerDiagnostic("host_not_started"))
                return out
        }
    }

    public func snapshotJson(): JsonObject {
        let out = JsonObject()
        out.put("enabled", this.config.enabled.toJsonValue())
        out.put("ok", (this.state == "running" || this.state == "disabled" || this.state == "stopped").toJsonValue())
        out.put("state", JsonString(this.state))
        out.put("diagnostic", this.lastDiagnostic)
        out.put("raw", this.lastRaw)
        let capture = JsonObject()
        capture.put("channels", this.registryBridge.channelCount().toJsonValue())
        capture.put("httpRoutes", this.registryBridge.httpRouteCount().toJsonValue())
        capture.put("tools", this.registryBridge.toolCount().toJsonValue())
        capture.put("providers", this.registryBridge.providerCount().toJsonValue())
        capture.put("hooks", this.registryBridge.hookCount().toJsonValue())
        out.put("capturedCapabilities", capture)
        out.put("registrySync", this.registrySync.toJson())
        return out
    }
}
