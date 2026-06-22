package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.config.CliConfig

import std.unittest.testmacro.*

@Test
public class GatewayShellToolsetCronPolicyTest {
    @TestCase
    public func cronDenyShellToolReturnsBlockedTextWithoutPrompting(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("cron", cronJobId: "deny-job", toolExecMode: "deny"),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "printf denied", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Cron/headless shell execution blocked"), true)
        @Expect(out.contains("cron cannot wait for interactive approval"), true)
        @Expect(out.contains("Diagnostic: code=cron_tool_exec_blocked reason=cron_headless_approval_required mode=deny allowlistCount=0."), true)
        @Expect(out.contains("deny-job"), true)
    }

    @TestCase
    public func cronYoloShellToolExecutesWithoutInteractiveConfirmation(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("cron", cronJobId: "yolo-job", toolExecMode: "yolo"),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "printf metis-p2-yolo", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Command executed successfully"), true)
        @Expect(out.contains("metis-p2-yolo"), true)
    }

    @TestCase
    public func cronGuardedShellToolExecutesSafeCommandWithoutInteractiveConfirmation(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("cron", cronJobId: "guarded-job", toolExecMode: "guarded"),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "printf metis-m6-guarded", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Command executed successfully"), true)
        @Expect(out.contains("metis-m6-guarded"), true)
    }

    @TestCase
    public func cronAllowlistShellToolExecutesMatchingCommandWithoutPrompting(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext(
                "cron",
                cronJobId: "allow-job",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["printf"]
            ),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "printf metis-p2-allow", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Command executed successfully"), true)
        @Expect(out.contains("metis-p2-allow"), true)
    }
}
