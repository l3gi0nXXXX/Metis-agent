// Standalone raw-output fake cjpm; this is not a service-plugin/GCM protocol actor.
package owned_internal_subagent_process

import std.collection.ArrayList
import std.env.{getCommand, getProcessId, getVariable, getStdOut, getStdErr}
import std.fs.{File, OpenMode, Path, canonicalize, exists, rename}
import std.runtime.getMaxHeapSize
import stdx.crypto.digest.SHA256
import stdx.encoding.json.*

foreign { func getpgid(pid: Int32): Int32; func getppid(): Int32 }

private func text(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("internal_actor_invalid_encoding") }
}
private func publish(path: Path, bytes: Array<Byte>): Unit {
    let pending = path.parent.join(path.fileName + ".pending")
    File.writeTo(pending, bytes)
    rename(pending, to: path)
}
private func hex(bytes: Array<Byte>): String {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    let output = StringBuilder()
    for (value in bytes) { output.append(digits[Int64(value >> 4)]); output.append(digits[Int64(value & 15)]) }
    output.toString()
}
private func sha(bytes: Array<Byte>): String {
    let hash = SHA256(); hash.write(bytes); hex(hash.finish())
}
private func fileSha(path: Path): String {
    let hash = SHA256(); let buffer = Array<Byte>(8192, repeat: 0)
    try (file = File(path, OpenMode.Read)) {
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            hash.write(buffer[0..count])
        }
    }
    hex(hash.finish())
}
private func check(ok: Bool): Unit { if (!ok) { throw Exception("internal_actor_contract_failed") } }

main(args: Array<String>): Int64 {
    try {
        let home = canonicalize(Path(getVariable("METIS_INTERNAL_SUBAGENT_HOME").getOrThrow()))
        let directory = canonicalize(Path(getVariable("METIS_INTERNAL_SUBAGENT_CASE").getOrThrow()))
        let nonce = getVariable("METIS_INTERNAL_SUBAGENT_NONCE").getOrThrow()
        let originalParent = unsafe { getppid() }
        check(home.toString().startsWith("/private/tmp/") && directory.toString().startsWith(home.toString() + "/"))
        check(!nonce.isEmpty() && text(home.join("owner")) == nonce && text(directory.join("owner")) == nonce)
        check(getMaxHeapSize() == 67108864)
        let argv0 = getCommand()
        check(getVariable("PATH") == Some(home.join("bin").toString()))
        let command = if (Path(argv0).isAbsolute()) { canonicalize(Path(argv0)) } else {
            check(argv0 == "cjpm")
            canonicalize(home.join("bin/cjpm"))
        }
        check(command == canonicalize(home.join("bin/cjpm")))
        let commandSha = fileSha(command)
        check(commandSha == text(home.parent.join("actor.sha")))
        check(args.size == 6 && args[0] == "run" && args[1] == "--skip-build" && args[2] == "--name" &&
            args[3] == "metis" && args[4] == "--run-args")
        let nested = args[5].split(" ", removeEmpty: true)
        check(nested.size == 10 && nested[0] == "--internal-subagent" && nested[1] == "explorer" &&
            nested[2] == "--prompt-file" && nested[4] == "--output-format" && nested[5] == "plain" &&
            nested[6] == "--language" && nested[7] == "zh" && nested[8] == "--model" && nested[9] == "openai:fixture")
        let prompt = canonicalize(Path(nested[3]))
        let promptRoot = canonicalize(Path(getVariable("METIS_INTERNAL_SUBAGENT_PROMPT_ROOT").getOrThrow()))
        check(promptRoot.toString().startsWith(home.toString() + "/") && prompt.parent == promptRoot)
        let promptBytes = File.readFrom(prompt)
        let promptText = try { String.fromUtf8(promptBytes) }
            catch (_: Exception) { throw Exception("internal_actor_prompt_invalid_encoding") }
        check(promptText.endsWith("Task:\n" + text(directory.join("task.bin"))))
        File.writeTo(directory.join("observed-prompt.bin"), promptBytes)
        let mode = text(directory.join("mode"))
        let response = if (mode == "large") {
            let builder = StringBuilder()
            for (_ in 0..4096) { builder.append("中文😀abcd \n") }
            builder.toString().toArray()
        } else { "owned internal subagent 中文😀\n".toArray() }
        let errorBytes = ArrayList<Byte>(response)
        if (mode == "large") { errorBytes.add(0); errorBytes.add(255); errorBytes.add(195); errorBytes.add(40) }
        File.writeTo(directory.join("actor.stdout.bin"), response)
        File.writeTo(directory.join("actor.stderr.bin"), errorBytes.toArray())
        let receipt = JsonObject()
        receipt.put("nonce", JsonString(nonce)); receipt.put("pid", JsonInt(getProcessId()))
        receipt.put("pgid", JsonInt(Int64(unsafe { getpgid(0) })))
        receipt.put("parentPid", JsonInt(Int64(originalParent)))
        receipt.put("heapBytes", JsonInt(getMaxHeapSize())); receipt.put("command", JsonString(command.toString()))
        receipt.put("argv0", JsonString(argv0)); receipt.put("commandSha", JsonString(commandSha))
        receipt.put("commandResolution", JsonString("unique_owned_PATH"))
        let argv = JsonArray(); for (arg in args) { argv.add(JsonString(arg)) }; receipt.put("args", argv)
        receipt.put("promptPath", JsonString(prompt.toString())); receipt.put("promptSha", JsonString(sha(promptBytes)))
        receipt.put("stdoutSha", JsonString(sha(response))); receipt.put("stderrSha", JsonString(sha(errorBytes.toArray())))
        receipt.put("recoveryDirectory", JsonString(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").getOrDefault({ => "" })))
        receipt.put("recoveryParent", JsonString(getVariable("METIS_PROCESS_RECOVERY_PARENT").getOrDefault({ => "" })))
        publish(directory.join("receipt.json"), receipt.toJsonString().toArray())
        if (mode == "hold") {
            while (!exists(directory.join("release"))) {
                if (unsafe { getppid() } != originalParent) { return 0 }
                sleep(Duration.millisecond * 5)
            }
        }
        let out = spawn { let stream = getStdOut(); stream.write(response); stream.flush() }
        let err = spawn { let stream = getStdErr(); stream.write(errorBytes.toArray()); stream.flush() }
        out.get(Duration.second * 5); err.get(Duration.second * 5)
        publish(directory.join("writers-joined"), nonce.toArray())
        return 0
    } catch (_: Exception) {
        try { let error = getStdErr(); error.write("internal_actor_failed\n".toArray()); error.flush() }
        catch (_: Exception) { () }
        return 70
    }
}
