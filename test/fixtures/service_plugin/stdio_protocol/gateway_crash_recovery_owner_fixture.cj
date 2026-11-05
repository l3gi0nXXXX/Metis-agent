package gateway_crash_recovery_owner_fixture

import std.convert.Parsable
import std.core.Duration
import std.env.{getCommand, getProcessId, getVariable}
import std.fs.{File, OpenMode, Path, canonicalize, exists, remove}
import std.io.StringReader
import std.net.*
import std.process.{launch, ProcessRedirect, SubProcess}
import std.sync.AtomicBool
import std.time.*
import stdx.encoding.json.*

private let ownerStartedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()

foreign {
    func signal(number: Int32, handler: UIntNative): UIntNative
    func getpgrp(): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

private func owned(raw: String): Path {
    let root = canonicalize(Path(getVariable("METIS_HOME").getOrThrow())).toString()
    let path = Path(raw)
    let parent = canonicalize(path.parent).toString()
    if (!path.isAbsolute() || (parent != root && !parent.startsWith(root + "/"))) {
        throw Exception("fixture_path_outside_home")
    }
    path
}

private func append(path: Path, text: String): Unit {
    try (file = File(path, OpenMode.Append)) { file.write((text + "\n").toArray()) }
}

private func lease(port: Int64, state: String): Unit {
    let root = JsonObject()
    root.put("pluginId", JsonString(getVariable("METIS_SERVICE_PLUGIN_ID").getOrThrow()))
    root.put("sessionId", JsonString(getVariable("METIS_SERVICE_PLUGIN_SESSION_ID").getOrThrow()))
    root.put("pid", JsonInt(getProcessId()))
    root.put("parentPid", JsonInt(Int64.parse(getVariable("METIS_SERVICE_PLUGIN_PARENT_PID").getOrThrow())))
    root.put("startedAtMs", JsonInt(ownerStartedAt))
    root.put("lastHeartbeatMs", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
    root.put("bindHost", JsonString("127.0.0.1"))
    root.put("port", JsonInt(port))
    root.put("state", JsonString(state))
    File.writeTo(owned(getVariable("METIS_SERVICE_PLUGIN_LEASE_PATH").getOrThrow()), root.toJsonString().toArray())
}

private func readStop(stop: AtomicBool, stopPath: Path): Unit {
    try (input = File("/dev/stdin", OpenMode.Read)) {
        let reader = StringReader(input)
        while (true) {
            let line = match (reader.readln()) { case Some(value) => value case None => break }
            let frame = try { JsonValue.fromStr(line).asObject() }
                catch (_: Exception) { throw Exception("malformed_json") }
            let method = try { frame.get("method").getOrThrow().asString().getValue() }
                catch (_: Exception) { "" }
            if (method == "stop") { File.writeTo(stopPath, "stop".toArray()); break }
        }
    } catch (_: Exception) { eprintln("fixture_input_closed") }
    finally { stop.store(true) }
}

private func servePeer(listener: TcpServerSocket): Unit {
    try (peer = listener.accept(timeout: Some(Duration.millisecond * 25))) {
        peer.readTimeout = Some(Duration.second)
        let bytes = Array<Byte>(4096, repeat: 0)
        let n = peer.read(bytes)
        if (n <= 0) { return }
        let _ = try { String.fromUtf8(bytes[..n]) }
            catch (_: Exception) { throw Exception("invalid_response_encoding") }
        let body = "{\"ok\":true}"
        peer.write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n${body}".toArray())
    } catch (_: SocketTimeoutException) { () }
}

private func grandchild(args: Array<String>): Int64 {
    let release = owned(args[1])
    let marker = owned(args[2])
    if (unsafe { signal(15, 1) } == UIntNative.Max) { return 70 }
    File.writeTo(marker, "${getProcessId()}".toArray())
    while (!exists(release)) { sleep(Duration.millisecond * 10) }
    0
}

private func service(args: Array<String>): Int64 {
    let pending = owned(args[1])
    let initialized = owned(args[2])
    let release = owned(args[3])
    let stopSeen = owned(args[4])
    let childRelease = owned(args[5])
    let childMarker = owned(args[6])
    let oldGroup = owned(Path(getVariable("METIS_HOME").getOrThrow()).join("old.pgid").toString())
    if (exists(oldGroup)) {
        let text = try { String.fromUtf8(File.readFrom(oldGroup)) }
            catch (_: Exception) { throw Exception("invalid_response_encoding") }
        let pgid = Int32.parse(text.trimAscii())
        if (pgid <= 1) { throw Exception("fixture_old_group_invalid") }
        let result = unsafe { kill(-pgid, 0) }
        if (result == 0 || unsafe { __error().read() } != 3) {
            File.writeTo(owned(Path(getVariable("METIS_HOME").getOrThrow()).join("owner.overlap").toString()),
                "old_group_active_or_unknown_at_new_owner_start".toArray())
        }
    }
    var child: Option<SubProcess> = None
    if (args[7] == "grandchild") {
        if (exists(childRelease)) { remove(childRelease) }
        if (exists(childMarker)) { remove(childMarker) }
        try (input = File("/dev/null", OpenMode.Read), output = File("/dev/null", OpenMode.Write)) {
            child = Some(launch(getCommand(), ["grandchild", childRelease.toString(), childMarker.toString()],
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(output)))
        }
        let deadline = MonoTime.now() + Duration.second * 3
        while (!exists(childMarker) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!exists(childMarker)) { throw Exception("fixture_grandchild_not_ready") }
    }
    let stop = AtomicBool(false)
    try (listener = TcpServerSocket(bindAt: 0u16), output = File("/dev/stdout", OpenMode.Write)) {
        listener.bind()
        let port = Int64((listener.localAddress as IPSocketAddress)?.port ?? 0u16)
        lease(port, "running")
        let fact = JsonObject()
        fact.put("pid", JsonInt(getProcessId()))
        fact.put("pgid", JsonInt(Int64(unsafe { getpgrp() })))
        fact.put("port", JsonInt(port))
        fact.put("grandchildPid", JsonInt(match (child) { case Some(value) => value.pid case None => 0 }))
        File.writeTo(pending, fact.toJsonString().toArray())
        let reader = spawn { readStop(stop, stopSeen) }
        while (!exists(release) && !stop.load()) { servePeer(listener) }
        if (!stop.load()) {
            append(initialized, fact.toString())
            let frame = JsonObject()
            frame.put("type", JsonString("response"))
            frame.put("frameId", JsonString("init-1"))
            frame.put("serviceId", JsonString(getVariable("METIS_SERVICE_PLUGIN_ID").getOrThrow()))
            frame.put("method", JsonString("initialize"))
            let payload = JsonObject()
            payload.put("ok", JsonBool(true)); payload.put("status", JsonString("ready"))
            frame.put("payload", payload)
            output.write((frame.toString() + "\n").toArray())
            output.flush()
            while (!stop.load()) { servePeer(listener) }
        }
        listener.close()
        lease(port, "stopped")
        File.writeTo(childRelease, "release".toArray())
        if (let Some(value) <- child) { let _ = value.wait(timeout: Some(Duration.second * 3)) }
        reader.get(Duration.second * 3)
    }
    0
}

main(args: Array<String>): Int64 {
    try {
        if (args.size == 3 && args[0] == "grandchild") { return grandchild(args) }
        if (args.size == 8 && args[0] == "service") { return service(args) }
        64
    } catch (_: Exception) {
        eprintln("fixture_failed")
        70
    }
}
