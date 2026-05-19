package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.config.CliConfig
import metis.core.memory.MemoryRuntimeRegistry

import std.fs.{Directory, File, exists, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonValue}

private func gatewayMemoryToolsetTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

@Test
public class GatewayMemoryToolsetTest {
    @TestCase
    public func memorySearchUsesRuntimeContextAgentWhenNoSessionKeyProvided(): Unit {
        MemoryRuntimeRegistry.activateBackend("local", startMaintenance: false)
        let memoryDir = CliConfig.cwd.join("memory")
        if (!exists(memoryDir)) {
            Directory.create(memoryDir, recursive: true)
        }
        let file = memoryDir.join("gateway-memory-toolset-agent-context-test.md")
        File.writeTo(
            file,
            "# Gateway memory\nremember gatewayagentcontexttoken for runtime context coverage\n".toArray()
        )
        try {
            let raw = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext("telegram", channelName: "telegram", agentId: "agent-a"),
                { =>
                    GatewayMemoryToolset().debugMemorySearchForTest(
                        "gatewayagentcontexttoken",
                        Some(3),
                        None<Float64>,
                        None<String>
                    )
                }
            )
            let result = JsonValue.fromStr(raw).asObject()
            let resolved = result.get("resolvedBackendConfig").getOrThrow().asObject()
            @Expect(gatewayMemoryToolsetTestString(resolved, "agentId"), "agent-a")
        } finally {
            if (exists(file)) {
                remove(file)
            }
        }
    }
}
