package gateway_historical_recovery_fixture

import std.convert.Parsable
import std.env.{getProcessId, getVariable}
import std.fs.{Directory, File, FileInfo, OpenMode, Path, canonicalize, exists, rename}
import std.io.StringReader
import std.net.*
import std.process.{ProcessRedirect, launch}
import std.sync.AtomicBool
import std.time.*
import stdx.encoding.json.*

// Standalone test executable. The runner must set METIS_HOME before launching.
// stdout is exclusively the Metis service-plugin JSON-frame channel.
func ownedPath(raw: String): Path {
    let home = getVariable("METIS_HOME").getOrDefault { "" }
    if (home.isEmpty() || raw.isEmpty()) { throw Exception("fixture_home_missing") }
    let root = canonicalize(Path(home)).toString()
    let path = Path(raw)
    if (!path.isAbsolute() || !canonicalize(path.parent).toString().startsWith(root)) {
        throw Exception("fixture_path_outside_home")
    }
    let parent = canonicalize(path.parent).toString()
    if (parent != root && !parent.startsWith(root + "/")) { throw Exception("fixture_path_outside_home") }
    if (exists(path) && FileInfo(path).isSymbolicLink()) { throw Exception("fixture_unsafe_path") }
    path
}

func readJson(path: Path): JsonObject {
    if (FileInfo(path).size > 65536) { throw Exception("fixture_input_too_large") }
    let text = try { String.fromUtf8(File.readFrom(path)) }
        catch (_: Exception) { throw Exception("invalid_response_encoding") }
    try { JsonValue.fromStr(text).asObject() }
        catch (_: Exception) { throw Exception("malformed_json") }
}

func atomicWrite(path: Path, text: String): Unit {
    let temporary = Path(path.toString() + ".tmp-${getProcessId()}")
    File.writeTo(temporary, text.toArray())
    rename(temporary, to: path, overwrite: true)
}

func field(root: JsonObject, key: String): String {
    root.get(key).getOrThrow().asString().getValue()
}

func number(root: JsonObject, key: String): Int64 {
    root.get(key).getOrThrow().asInt().getValue()
}

func envInt(key: String): Int64 {
    Int64.parse(getVariable(key).getOrDefault { "0" })
}

func waitFor(path: Path): Unit {
    let deadline = MonoTime.now() + Duration.second * 10
    while (!exists(path)) {
        if (MonoTime.now() >= deadline) { throw Exception("fixture_barrier_timeout") }
        sleep(Duration.millisecond * 10)
    }
}

class FixtureLease {
    let path: Path
    let plugin: String
    let session: String
    let pid: Int64
    let parent: Int64
    let started: Int64
    let port: Int64

    init(root: JsonObject) {
        this.path = ownedPath(field(root, "leasePath"))
        this.plugin = field(root, "pluginId")
        this.session = field(root, "sessionId")
        this.pid = number(root, "pid")
        this.parent = number(root, "parentPid")
        this.started = number(root, "startedAtMs")
        this.port = number(root, "port")
        if (this.plugin.isEmpty() || this.session.isEmpty() || this.pid <= 1 || this.parent <= 1 ||
            this.started <= 0 || this.port <= 0 || this.port > 65535) { throw Exception("fixture_identity_invalid") }
    }

    func write(state: String): Unit {
        let root = JsonObject()
        root.put("pluginId", JsonString(this.plugin))
        root.put("sessionId", JsonString(this.session))
        root.put("state", JsonString(state))
        root.put("status", JsonString(state))
        root.put("pid", JsonInt(this.pid))
        root.put("parentPid", JsonInt(this.parent))
        root.put("startedAtMs", JsonInt(this.started))
        root.put("lastHeartbeatMs", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        root.put("bindHost", JsonString("127.0.0.1"))
        root.put("port", JsonInt(this.port))
        atomicWrite(this.path, root.toJsonString())
    }
}

func registration(port: Int64): JsonObject {
    let root = JsonObject()
    root.put("leasePath", JsonString(getVariable("METIS_SERVICE_PLUGIN_LEASE_PATH").getOrDefault { "" }))
    root.put("pluginId", JsonString(getVariable("METIS_SERVICE_PLUGIN_ID").getOrDefault { "" }))
    root.put("sessionId", JsonString(getVariable("METIS_SERVICE_PLUGIN_SESSION_ID").getOrDefault { "" }))
    root.put("pid", JsonInt(getProcessId()))
    root.put("parentPid", JsonInt(envInt("METIS_SERVICE_PLUGIN_PARENT_PID")))
    root.put("startedAtMs", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
    root.put("port", JsonInt(port))
    root
}

func ready(path: Path, port: Int64): Unit {
    let root = JsonObject()
    root.put("pid", JsonInt(getProcessId()))
    root.put("port", JsonInt(port))
    atomicWrite(path, root.toJsonString())
}

func journalProcess(path: Path, event: String, service: String): Unit {
    let entry = JsonObject()
    entry.put("event", JsonString(event))
    entry.put("pid", JsonInt(getProcessId()))
    entry.put("serviceId", JsonString(service))
    try (record = File(path, OpenMode.Append)) {
        record.write((entry.toJsonString().replace("\n", "").replace("\r", "") + "\n").toArray())
        record.flush()
    }
}

func emitInitialized(output: File, service: String, journal: Path): Unit {
    let root = JsonObject()
    root.put("type", JsonString("response"))
    root.put("frameId", JsonString("init-1"))
    root.put("serviceId", JsonString(service))
    root.put("method", JsonString("initialize"))
    let payload = JsonObject()
    payload.put("ok", JsonBool(true))
    payload.put("status", JsonString("ready"))
    root.put("payload", payload)
    output.write((root.toJsonString().replace("\n", "").replace("\r", "") + "\n").toArray())
    output.flush()
    journalProcess(journal, "initialized", service)
}

func readStop(stop: AtomicBool, stopSeen: Path): Unit {
    try (input = File("/dev/stdin", OpenMode.Read)) {
        let reader = StringReader(input)
        while (true) {
            let text = match (reader.readln()) { case Some(value) => value case None => break }
            if (text.size > 65536) { throw Exception("fixture_input_too_large") }
            let request = try { JsonValue.fromStr(text).asObject() }
                catch (_: Exception) { throw Exception("malformed_json") }
            let method = try { field(request, "method") } catch (_: Exception) { "" }
            if (method == "stop") {
                atomicWrite(stopSeen, "stop\n")
                break
            }
        }
    } catch (_: Exception) {
        try { eprintln("historical service fixture input failed") } catch (_: Exception) { () }
    } finally { stop.store(true) }
}

func serveHttp(listener: TcpServerSocket): Unit {
    try (peer = listener.accept(timeout: Some(Duration.millisecond * 100))) {
        peer.readTimeout = Some(Duration.second)
        peer.writeTimeout = Some(Duration.second)
        let request = Array<Byte>(4096, repeat: 0)
        let count = peer.read(request)
        if (count <= 0) { return }
        // External request bytes are decoded only for validation, never echoed.
        let _ = try { String.fromUtf8(request[..count]) }
            catch (_: Exception) { throw Exception("invalid_response_encoding") }
        let body = "{\"ok\":true,\"fixture\":\"busy-until-release\"}"
        peer.write(("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n" + body).toArray())
    } catch (_: SocketTimeoutException) { () }
}

func recoverBusiness(pending: Path, receipt: Path, effects: Path): Unit {
    let job = readJson(pending)
    let id = field(job, "id")
    if (exists(receipt)) {
        if (field(readJson(receipt), "id") != id) { throw Exception("fixture_receipt_identity_mismatch") }
        return
    }
    let effect = JsonObject()
    effect.put("id", JsonString(id))
    effect.put("status", JsonString("recovered"))
    try (output = File(effects, OpenMode.Append)) {
        output.write((effect.toJsonString().replace("\n", "").replace("\r", "") + "\n").toArray())
        output.flush()
    }
    atomicWrite(receipt, effect.toJsonString())
}

func runService(args: Array<String>): Int64 {
    // service READY RELEASE STOP_SEEN [PENDING RECEIPT EFFECTS]. The optional
    // fake business recovery is performed by the service, never by the test driver.
    if (args.size != 4 && args.size != 7) { return 64 }
    let readyPath = ownedPath(args[1])
    let release = ownedPath(args[2])
    let stopSeen = ownedPath(args[3])
    let stop = AtomicBool(false)
    try (listener = TcpServerSocket(bindAt: 0u16)) {
        listener.bind()
        let port = Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16)
        let lease = FixtureLease(registration(port))
        journalProcess(ownedPath(readyPath.toString() + ".initializations.jsonl"), "started", lease.plugin)
        lease.write("running")
        if (args.size == 7) {
            recoverBusiness(ownedPath(args[4]), ownedPath(args[5]), ownedPath(args[6]))
        }
        ready(readyPath, port)
        try (output = File("/dev/stdout", OpenMode.Write)) {
            emitInitialized(output, lease.plugin, ownedPath(readyPath.toString() + ".initializations.jsonl"))
            let reader = spawn { readStop(stop, stopSeen) }
            while (!stop.load() && !exists(release)) { serveHttp(listener) }
            listener.close()
            lease.write("stopped")
            if (stop.load()) { reader.get(Duration.second) }
        }
    }
    0
}

func runWorker(args: Array<String>): Int64 {
    // worker READY RELEASE REGISTRATION REGISTERED: independently owned HTTP
    // component, which alone writes the delegated lease and terminal transition.
    if (args.size != 5) { return 64 }
    let readyPath = ownedPath(args[1])
    let release = ownedPath(args[2])
    let request = ownedPath(args[3])
    let registered = ownedPath(args[4])
    var lease = None<FixtureLease>
    try (listener = TcpServerSocket(bindAt: 0u16)) {
        listener.bind()
        let port = Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16)
        ready(readyPath, port)
        while (!exists(release)) {
            if (lease.isNone() && exists(request)) {
                let candidate = FixtureLease(readJson(request))
                if (candidate.port != port) { throw Exception("fixture_port_mismatch") }
                candidate.write("running")
                lease = Some(candidate)
                atomicWrite(registered, "registered\n")
            }
            serveHttp(listener)
        }
        listener.close()
        if (let Some(value) <- lease) { value.write("stopped") }
    }
    0
}

func runDelegate(args: Array<String>): Int64 {
    // delegate WORKER_READY REGISTRATION REGISTERED STOP_SEEN. Its lease keeps
    // this protocol owner's PID while HTTP work survives until worker RELEASE.
    if (args.size != 5) { return 64 }
    let workerReady = ownedPath(args[1])
    let request = ownedPath(args[2])
    let registered = ownedPath(args[3])
    let stopSeen = ownedPath(args[4])
    waitFor(workerReady)
    let port = number(readJson(workerReady), "port")
    let record = registration(port)
    journalProcess(ownedPath(request.toString() + ".initializations.jsonl"), "started", field(record, "pluginId"))
    atomicWrite(request, record.toJsonString())
    waitFor(registered)
    let stop = AtomicBool(false)
    try (output = File("/dev/stdout", OpenMode.Write)) {
        emitInitialized(output, field(record, "pluginId"), ownedPath(request.toString() + ".initializations.jsonl"))
        readStop(stop, stopSeen)
    }
    0
}

// The task-owned bin/lsof link uses this native mode. It never manufactures a
// probe result: after the controlled archive window it runs the system lsof.
func runLsofForwarder(args: Array<String>): Int64 {
    let home = Path(getVariable("METIS_HOME").getOrDefault { "" })
    let target = ownedPath(home.join("lsof-gateway-port").toString())
    let port = Int64.parse(try { String.fromUtf8(File.readFrom(target)).trimAscii() }
        catch (_: Exception) { throw Exception("invalid_response_encoding") })
    let history = home.join("gateway-serve.recovery-history")
    var completions: Int64 = 0
    var evidence: Int64 = 0
    if (exists(history)) {
        for (entry in Directory.readFrom(history)) {
            if (entry.isRegular() && entry.name.endsWith(".completion")) { completions++ }
            if (entry.isRegular() && entry.name.endsWith(".evidence")) { evidence++ }
        }
    }
    let entered = home.join("lsof-archive-entered")
    if (args.contains("-iTCP:${port}") && completions == 1 && evidence == 1 &&
        exists(home.join("gateway-serve.stop-complete")) && !exists(entered)) {
        let proof = JsonObject()
        proof.put("pid", JsonInt(getProcessId()))
        proof.put("enteredAtMs", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        atomicWrite(entered, proof.toJsonString())
        waitFor(home.join("lsof-archive-release"))
    }
    let child = launch("/usr/sbin/lsof", args, stdIn: ProcessRedirect.Inherit,
        stdOut: ProcessRedirect.Inherit, stdErr: ProcessRedirect.Inherit)
    child.wait()
}

main(args: Array<String>): Int64 {
    try {
        if (args.size < 1) { return 64 }
        match (args[0]) {
            case "-nP" => runLsofForwarder(args)
            case "service" => runService(args)
            case "worker" => runWorker(args)
            case "delegate" => runDelegate(args)
            case _ => 64
        }
    } catch (_: Exception) {
        try { eprintln("historical service fixture failed") } catch (_: Exception) { () }
        70
    }
}
