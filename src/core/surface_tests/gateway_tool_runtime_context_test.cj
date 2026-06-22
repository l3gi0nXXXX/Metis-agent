package metis.core.surface_tests

import metis.core.*

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject}

@Test
public class GatewayToolRuntimeContextTest {
    @TestCase
    public func runtimeContextPushPopAndCurrentWorkAsStack(): Unit {
        let outer = GatewayToolRuntimeContext("cli", channelName: "cli", sessionKey: "agent:main", prompt: "restart gateway")
        let inner = GatewayToolRuntimeContext("control-ui", channelName: "control-ui", sessionKey: "agent:ui", prompt: "apply config")
        @Expect(gatewayCurrentToolRuntimeContext().isNone(), true)
        gatewayPushToolRuntimeContext(outer)
        try {
            @Expect(gatewayCurrentToolRuntimeContext().isSome(), true)
            @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "cli")
            gatewayPushToolRuntimeContext(inner)
            try {
                @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "control-ui")
                @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().prompt.contains("apply config"), true)
            } finally {
                gatewayPopToolRuntimeContext()
            }
            @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "cli")
        } finally {
            gatewayPopToolRuntimeContext()
        }
        @Expect(gatewayCurrentToolRuntimeContext().isNone(), true)
    }

    @TestCase
    public func withRuntimeContextRestoresPreviousValue(): Unit {
        let outer = GatewayToolRuntimeContext("cli", prompt: "restart gateway")
        let inner = GatewayToolRuntimeContext("dashboard", prompt: "apply config")
        gatewayWithToolRuntimeContext(outer, { =>
            @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "cli")
            gatewayWithToolRuntimeContext(inner, { =>
                @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "dashboard")
            })
            @Expect(gatewayCurrentToolRuntimeContext().getOrThrow().sourceLabel, "cli")
        })
        @Expect(gatewayCurrentToolRuntimeContext().isNone(), true)
    }

    @TestCase
    public func runtimeContextCarriesMemorySearchPolicy(): Unit {
        let policy = JsonObject()
        policy.put("enabled", JsonBool(true))
        let context = GatewayToolRuntimeContext("telegram", agentId: "agent-a", memorySearchPolicy: policy)

        @Expect(context.agentId, "agent-a")
        @Expect(context.memorySearchPolicy.get("enabled").isSome(), true)
    }

    @TestCase
    public func runtimeContextCarriesCronToolExecPolicy(): Unit {
        let context = GatewayToolRuntimeContext(
            "cron",
            cronJobId: "job-a",
            toolExecMode: "ALLOWLIST",
            toolExecAllowlist: ["curl", "", "curl", "python3 -m"]
        )

        @Expect(context.sourceLabel, "cron")
        @Expect(context.cronJobId, "job-a")
        @Expect(context.toolExecMode, "allowlist")
        @Expect(context.toolExecAllowlist.size, 2)
        @Expect(context.toolExecAllowlist[0], "curl")
        @Expect(context.toolExecAllowlist[1], "python3 -m")
    }
}
