// Standalone fake raw business CLI for sandbox caller tests. Not a Metis
// service-plugin/GCM frame actor. It never executes Docker, a shell or Metis.
package sandbox_caller_actor

import std.collection.ArrayList
import std.convert.Parsable
import std.env.{getCommand, getProcessId, getVariable, getStdOut, getStdErr}
import std.fs.{File, FileInfo, OpenMode, Path, canonicalize, exists, rename}
import std.time.MonoTime
import stdx.encoding.json.*

foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
    func getpgrp(): Int32
    func getppid(): Int32
}

private func text(path: Path): String {
    if (!FileInfo(path).isRegular() || FileInfo(path).size > 1048576) { throw Exception("sandbox_actor_input_invalid") }
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { throw Exception("sandbox_actor_encoding_invalid") }
}
private func publish(path: Path, bytes: Array<Byte>): Unit {
    let pending = Path(path.toString() + ".pending")
    File.writeTo(pending, bytes); rename(pending, to: path, overwrite: true)
}
private func birth(): String {
    var info = VArray<UInt64, $17>(repeat: 0)
    if (unsafe { proc_pidinfo(Int32(getProcessId()), 3, 0, inout info, 136) } != 136 || info[15] == 0) {
        throw Exception("sandbox_actor_identity_unknown")
    }
    "${getProcessId()}:${info[15]}:${info[16]}"
}
private func payload(nonce: String, ordinal: Int64, error: Bool): Array<Byte> {
    let bytes = ArrayList<Byte>(if (error) { [0xfeu8, 0u8, 0xffu8] } else { [0xffu8, 0u8, 0xfeu8] })
    bytes.add(all: ("SC-RAW-${ordinal}-${nonce}-" + if (error) { "错误😀\n" } else { "输出中文😀\n" }).toArray())
    bytes.add(all: String(Array<Rune>(16384, repeat: r'中')).toArray())
    bytes.add(all: [0u8, 0xffu8, 0xc3u8, 0x28u8, 0xf0u8, 0x9fu8, 0x98u8])
    bytes.add(all: "😀SC-RAW-END\n".toArray()); bytes.toArray()
}

main(args: Array<String>): Int64 {
    try {
        let directory = canonicalize(Path(getVariable("SC_CALL_DIR").getOrThrow()))
        let nonce = getVariable("SC_CALL_NONCE").getOrThrow()
        if (!directory.toString().startsWith("/private/tmp/") || text(directory.join("owner")) != nonce) {
            throw Exception("sandbox_actor_owner_invalid")
        }
        let home = canonicalize(Path(getVariable("SC_CALL_HOME").getOrThrow()))
        let invocation = getCommand()
        if (getVariable("PATH") != Some(home.join("bin").toString()) ||
            (!Path(invocation).isAbsolute() && invocation != "id")) {
            throw Exception("sandbox_actor_command_invalid")
        }
        let command = canonicalize(if (Path(invocation).isAbsolute()) { Path(invocation) } else { home.join("bin").join(invocation) })
        if (!command.toString().startsWith(home.join("bin").toString() + "/")) { throw Exception("sandbox_actor_command_invalid") }
        let stage = if (command.fileName == "id") {
            if (args != ["-u"] && args != ["-g"]) { throw Exception("sandbox_actor_id_invalid") }
            if (args[0] == "-u") { "id-u" } else { "id-g" }
        } else {
            if (args.isEmpty()) { throw Exception("sandbox_actor_args_missing") }
            match (args[0]) {
                case "images" => "images"
                case "ps" => "ps"
                case "pull" => "pull"
                case "run" | "-D" => "run"
                case _ => throw Exception("sandbox_actor_args_invalid")
            }
        }
        let sequence = directory.join("sequence")
        let ordinal = if (exists(sequence)) { Int64.parse(text(sequence)) + 1 } else { 1 }
        publish(sequence, ordinal.toString().toArray())
        let before = birth()
        let parent = Int64(unsafe { getppid() })
        if (parent <= 1) { throw Exception("sandbox_actor_parent_missing") }
        let record = JsonObject(); record.put("nonce", JsonString(nonce)); record.put("stage", JsonString(stage))
        record.put("ordinal", JsonInt(ordinal)); record.put("pid", JsonInt(getProcessId()))
        record.put("pgid", JsonInt(Int64(unsafe { getpgrp() }))); record.put("parentPid", JsonInt(parent))
        record.put("birth", JsonString(before)); record.put("command", JsonString(command.toString()))
        record.put("cwd", JsonString(canonicalize(Path(".")).toString()))
        let arguments = JsonArray(); for (arg in args) { arguments.add(JsonString(arg)) }; record.put("args", arguments)
        let behavior = getVariable("SC_CALL_BEHAVIOR").getOrDefault({ => "normal" })
        var code: Int64 = 0
        if (stage == "run") {
            record.put("phase", JsonString("ready")); publish(directory.join("ready"), record.toString().toArray())
            let limit = MonoTime.now() + Duration.second * 60
            while (!exists(directory.join("release"))) {
                // This actor has no descendants. Parent death cannot strand its
                // owned release wait even for the SDK/no-context launch path.
                if (Int64(unsafe { getppid() }) != parent || MonoTime.now() >= limit) { return 70 }
                sleep(Duration.millisecond)
            }
            if (text(directory.join("release")) != nonce) { throw Exception("sandbox_actor_release_invalid") }
            let out = getStdOut(); out.write(payload(nonce, ordinal, false)); out.flush()
            let err = getStdErr(); err.write(payload(nonce, ordinal, true)); err.flush()
            code = Int64.parse(getVariable("SC_CALL_EXIT").getOrThrow())
            if (code < 0 || code > 255) { throw Exception("sandbox_actor_exit_invalid") }
        } else {
            let out = getStdOut()
            if (stage == "images") { if (behavior != "missing_image") { out.write("owned-image\n".toArray()) } }
            else if (stage == "ps") {
                out.write(if (behavior == "invalid_ps") { [0xffu8, 0xfeu8, 0x80u8, 0u8] } else { "another-container\n".toArray() })
            } else if (stage == "id-u") { out.write("501\n".toArray()) }
            else if (stage == "id-g") { out.write("20\n".toArray()) }
            else if (stage == "pull") { code = 7 }
            out.flush()
        }
        let after = birth(); if (before != after) { throw Exception("sandbox_actor_identity_changed") }
        record.put("secondBirth", JsonString(after)); record.put("phase", JsonString("complete")); record.put("code", JsonInt(code))
        publish(directory.join("call-${ordinal}.json"), record.toString().toArray())
        code
    } catch (_: Exception) { eprintln("sandbox_actor_failed"); 70 }
}
