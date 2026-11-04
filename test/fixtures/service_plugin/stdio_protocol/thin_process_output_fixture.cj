// DRAFT ONLY: standalone raw-output actor, not a service-plugin/GCM protocol
// fixture. Its future placement reuses an explicitly unignored test directory.
package owned_thin_process_output

import std.env.{getCommand, getProcessId, getVariable}
import std.convert.Parsable
import std.collection.ArrayList
import std.fs.{File, OpenMode, Path, canonicalize, exists}
import std.time.DateTime
import stdx.encoding.json.*

private func variable(name: String): String {
    getVariable(name).getOrThrow()
}

private func ownedPayload(path: String, home: String): Array<Byte> {
    let input = canonicalize(Path(path))
    if (!input.toString().startsWith(home + "/")) { throw Exception("owned_actor_payload_outside_home") }
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    try (stream = File(input, OpenMode.Read)) {
        while (true) {
            let count = stream.read(buffer)
            if (count == 0) { break }
            if (result.size + count > 1048576) { throw Exception("owned_actor_payload_oversize") }
            for (index in 0..count) { result.add(buffer[index]) }
        }
    }
    result.toArray()
}

private func record(args: Array<String>): Unit {
    let directory = Path(variable("METIS_THIN_ACTOR_DIRECTORY"))
    let nonce = variable("METIS_THIN_ACTOR_NONCE")
    if (nonce.isEmpty() || !exists(directory.join("binding"))) {
        throw Exception("owned_actor_binding_missing")
    }
    let binding = try { String.fromUtf8(File.readFrom(directory.join("binding"))) }
        catch (_: Exception) { throw Exception("owned_actor_binding_invalid") }
    if (binding != nonce) { throw Exception("owned_actor_binding_mismatch") }
    let receipt = JsonObject()
    receipt.put("nonce", JsonString(nonce))
    receipt.put("pid", JsonInt(getProcessId()))
    receipt.put("recordedAtNs", JsonInt(DateTime.now().toUnixTimeStamp().toNanoseconds()))
    receipt.put("command", JsonString(getCommand()))
    receipt.put("commandName", JsonString(Path(getCommand()).fileName))
    receipt.put("phase", JsonString(if (args.size > 0 && args[0] == "--version") { "version" } else { "main" }))
    receipt.put("cwd", JsonString(canonicalize(Path(".")).toString()))
    let arguments = JsonArray()
    for (arg in args) { arguments.add(JsonString(arg)) }
    receipt.put("args", arguments)
    let commandName = Path(getCommand()).fileName
    if (args.size >= 2 && (commandName == "diff" || (commandName == "git" && args[0] == "diff"))) {
        let home = canonicalize(Path(variable("METIS_THIN_TEST_HOME"))).toString()
        if (!home.startsWith("/private/tmp/") || !directory.toString().startsWith(home + "/")) {
            throw Exception("owned_actor_payload_home_invalid")
        }
        for (offset in 0..2) {
            let bytes = ownedPayload(args[args.size - 2 + offset], home)
            File.writeTo(directory.join("payload-${getProcessId()}-${offset}.bin"), bytes)
        }
        receipt.put("payloadRecorded", JsonBool(true))
    }
    // Unique actual PID keeps fallback invocations distinct; no shared append FD.
    File.writeTo(directory.join("receipt-${getProcessId()}.json"), receipt.toString().toArray())
}

private func emit(path: String, bytes: Array<Byte>): Unit {
    try (stream = File(path, OpenMode.Write)) { stream.write(bytes); stream.flush() }
}

private func out(text: String): Unit { emit("/dev/stdout", text.toArray()) }
private func err(text: String): Unit { emit("/dev/stderr", text.toArray()) }

private func routed(args: Array<String>): Int64 {
    let command = Path(getCommand()).fileName
    let phase = if (args.size > 0 && args[0] == "--version") { "version" } else { "main" }
    let directory = Path(variable("METIS_THIN_ACTOR_DIRECTORY")).join("responses")
    let prefix = "${command}.${phase}"
    let codeText = try { String.fromUtf8(File.readFrom(directory.join(prefix + ".exit.txt"))) }
        catch (_: Exception) { throw Exception("owned_actor_route_invalid") }
    let code = Int64.parse(codeText.trimAscii())
    if (code < 0 || code > 255) { throw Exception("owned_actor_route_invalid") }
    emit("/dev/stdout", File.readFrom(directory.join(prefix + ".stdout.bin")))
    emit("/dev/stderr", File.readFrom(directory.join(prefix + ".stderr.bin")))
    code
}

main(args: Array<String>): Int64 {
    try {
        record(args)
        let mode = variable("METIS_THIN_ACTOR_CASE")
        match (mode) {
            case "raw_routes" => return routed(args)
            case "unicode_stdout" => out("\u{1b}[31m中文😀" + String(Array<Rune>(32768, repeat: r'中')) + "\u{1b}[0m\n")
            case "empty_stdout" => ()
            case "unicode_stderr" => err("\u{1b}[31m构建失败😀\u{1b}[0m\n"); return 7
            case "exit_127" => err("业务退出😀\n"); return 127
            case "invalid_stdout" => emit("/dev/stdout", [255u8, 254u8, 128u8, 0u8, 10u8])
            case "invalid_stderr" => emit("/dev/stderr", [255u8, 254u8, 128u8, 0u8, 10u8]); return 7
            case "proxy_https" => out("<dictionary> {\n HTTPEnable : 1\n HTTPProxy : 127.0.0.1\n HTTPPort : 8080\n HTTPSEnable : 1\n HTTPSProxy : 127.0.0.1\n HTTPSPort : 7897\n}\n")
            case "proxy_http" => out("<dictionary> {\n HTTPEnable : 1\n HTTPProxy : 127.0.0.1\n HTTPPort : 8080\n}\n")
            case "proxy_socks" => out("<dictionary> {\n SOCKSEnable : 1\n SOCKSProxy : 127.0.0.1\n SOCKSPort : 1080\n}\n")
            case "malformed" => out("{invalid-中文😀\n")
            case "pdf_resolved" => out("owned-module/中文😀/index.js\n")
            case "version_ok" => out("codex-cli 0.130.0\n")
            case "version_old" => out("codex-cli 0.124.9\n")
            case "version_malformed" => out("codex-cli 中文😀\n")
            case "ignored" => return 0
            case "not_ignored" => return 1
            case "diff_changed" =>
                out("--- a/owned\n+++ b/owned\n@@ -1 +1 @@\n-旧中文😀\n+新中文😀\n")
                return 1
            case "mtime" => out("1234567890\n")
            case "mtime_darwin_failure" =>
                if (args.size == 3 && args[0] == "-f") { return 7 }
                if (args.size != 3 || args[0] != "-c") { return 64 }
                out("1234567891\n")
            case "gateway_json" => out("{\"ok\":true,\"messageId\":\"owned-message-中文😀\"}\n")
            case _ => err("owned_actor_case_unsupported\n"); return 64
        }
        0
    } catch (_: Exception) {
        eprintln("owned_actor_failed")
        70
    }
}
