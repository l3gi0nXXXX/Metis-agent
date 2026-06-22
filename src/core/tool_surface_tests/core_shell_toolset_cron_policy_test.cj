package metis.core.tool_surface_tests

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}
import metis.core.tools.debugCoreShellExecuteForTest

import std.unittest.testmacro.*

@Test
public class CoreShellToolsetCronPolicyTest {
    @TestCase
    public func coreShellCronDenyReturnsBlockedTextWithoutPrompting(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("cron", cronJobId: "core-deny", toolExecMode: "deny"),
            { =>
                debugCoreShellExecuteForTest("/tmp", "printf denied", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Cron/headless shell execution blocked"), true)
        @Expect(out.contains("core-deny"), true)
    }
}
