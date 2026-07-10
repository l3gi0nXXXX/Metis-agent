package metis.core.surface_tests

import metis.core.*

import std.collection.ArrayList
import std.time.*
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

    @TestCase
    public func runtimeContextStacksStayIsolatedAcrossConcurrentThreads(): Unit {
        let futures = ArrayList<Future<String>>()
        var worker: Int64 = 0
        while (worker < 8) {
            let workerId = worker
            futures.add(spawn {
                gatewayWithToolRuntimeContext(
                    GatewayToolRuntimeContext(
                        "cron",
                        cronJobId: "ctx-${workerId}",
                        toolExecMode: "allowlist",
                        toolExecAllowlist: ["cmd-${workerId}"]
                    ),
                    { =>
                        var ok = true
                        var observed = ""
                        var i: Int64 = 0
                        while (i < 20) {
                            let current = gatewayCurrentToolRuntimeContext().getOrThrow()
                            observed = current.cronJobId + "/" + if (current.toolExecAllowlist.isEmpty()) { "" } else { current.toolExecAllowlist[0] }
                            if (current.cronJobId != "ctx-${workerId}" || current.toolExecAllowlist.size != 1 || current.toolExecAllowlist[0] != "cmd-${workerId}") {
                                ok = false
                                break
                            }
                            sleep(Duration.millisecond * 1)
                            i += 1
                        }
                        if (ok) { "ok-${workerId}" } else { "bad-${workerId}:${observed}" }
                    }
                )
            })
            worker += 1
        }

        for (future in futures) {
            @Expect(future.get().startsWith("ok-"), true)
        }
        @Expect(gatewayCurrentToolRuntimeContext().isNone(), true)
    }
}
