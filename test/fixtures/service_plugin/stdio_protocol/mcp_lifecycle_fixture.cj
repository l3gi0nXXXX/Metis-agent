// Standalone MCP JSON-RPC test actor. This is not a Metis service-plugin
// or GCM protocol fixture; its placement reuses the existing stdio fixture tree.
package owned_mcp_lifecycle

import std.env.{getProcessId, getVariable}
import std.fs.{Directory, File, OpenMode, Path, exists}
import std.io.StringReader
import stdx.encoding.json.*

private func answer(output: File, request: JsonObject, result: JsonObject): Unit {
    let frame = JsonObject()
    frame.put("jsonrpc", JsonString("2.0")); frame.put("id", request.get("id").getOrThrow())
    frame.put("result", result)
    output.write((frame.toString() + "\n").toArray()); output.flush()
}

private func record(path: Path, nonce: String, phase: String): Unit {
    let receipt = JsonObject()
    receipt.put("nonce", JsonString(nonce)); receipt.put("pid", JsonInt(getProcessId())); receipt.put("phase", JsonString(phase))
    let facts = JsonArray()
    if (let Some(directory) <- getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")) {
        if (!directory.isEmpty() && exists(Path(directory))) {
            for (entry in Directory.readFrom(Path(directory))) {
                if (entry.isRegular() && !entry.isSymbolicLink() && entry.name.endsWith(".birth")) {
                    let text = try { String.fromUtf8(File.readFrom(entry.path)) }
                        catch (_: Exception) { throw Exception("owned_fixture_birth_encoding_invalid") }
                    facts.add(JsonString(text))
                }
            }
        }
    }
    receipt.put("birthFacts", facts)
    File.writeTo(path, receipt.toString().toArray())
}

main(args: Array<String>): Int64 {
    if (args.size != 3) { return 64 }
    let mode = args[0]
    let receipt = Path(args[1])
    let nonce = args[2]
    try (input = File("/dev/stdin", OpenMode.Read), output = File("/dev/stdout", OpenMode.Write)) {
        let reader = StringReader(input)
        while (let Some(line) <- reader.readln()) {
            let request = JsonValue.fromStr(line).asObject()
            let method = request.get("method").getOrThrow().asString().getValue()
            if (method == "initialize") {
                let result = JsonObject()
                result.put("protocolVersion", request.get("params").getOrThrow().asObject().get("protocolVersion").getOrThrow())
                let capabilities = JsonObject()
                let prompts = JsonObject(); prompts.put("listChanged", JsonBool(false)); capabilities.put("prompts", prompts)
                let resources = JsonObject(); resources.put("subscribe", JsonBool(false)); resources.put("listChanged", JsonBool(false))
                capabilities.put("resources", resources)
                let tools = JsonObject(); tools.put("listChanged", JsonBool(false)); capabilities.put("tools", tools)
                result.put("capabilities", capabilities); result.put("instructions", JsonNull())
                let info = JsonObject(); info.put("name", JsonString("owned-lifecycle")); info.put("version", JsonString("1"))
                result.put("serverInfo", info)
                record(receipt, nonce, "initialized")
                answer(output, request, result)
            } else if (method == "tools/list") {
                record(receipt, nonce, "tools")
                if (mode == "invalid_utf8") { output.write([255u8, 254u8, 10u8]); output.flush(); continue }
                if (mode == "malformed_json") {
                    output.write(("{malformed-" + String(Array<Rune>(32768, repeat: r'中')) + "😀syntheticsecret\n").toArray())
                    output.flush(); continue
                }
                if (mode == "early_eof") { return 0 }
                let result = JsonObject(); let tools = JsonArray(); let tool = JsonObject()
                tool.put("name", JsonString("owned_echo")); tool.put("description", JsonString("中文😀 owned echo"))
                let schema = JsonObject(); schema.put("type", JsonString("object"))
                let properties = JsonObject(); let text = JsonObject(); text.put("type", JsonString("string"))
                properties.put("text", text); schema.put("properties", properties)
                schema.put("required", JsonArray([JsonString("text")]))
                tool.put("inputSchema", schema); tools.add(tool); result.put("tools", tools); result.put("nextCursor", JsonNull())
                answer(output, request, result)
            } else if (method == "tools/call") {
                let text = request.get("params").getOrThrow().asObject().get("arguments").getOrThrow().asObject().get("text").getOrThrow().asString().getValue()
                let result = JsonObject(); let content = JsonArray(); let item = JsonObject()
                item.put("type", JsonString("text")); item.put("text", JsonString(text)); item.put("annotations", JsonNull()); content.add(item)
                result.put("content", content); result.put("isError", JsonBool(false)); answer(output, request, result)
            }
        }
    } catch (_: Exception) { eprintln("owned_mcp_lifecycle_failed"); return 70 }
    0
}
