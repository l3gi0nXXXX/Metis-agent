package metis.core.tool_surface_tests

import metis.core.{GatewayToolRuntimeContext, resolveCronShellExecutionDecision}

import std.unittest.testmacro.*

@Test
public class CronShellExecutionPolicyTest {
    @TestCase
    public func cronDenyReturnsHeadlessBlockedDecision(): Unit {
        let ctx = GatewayToolRuntimeContext("cron", cronJobId: "news-job", toolExecMode: "deny")
        let decision = resolveCronShellExecutionDecision(Some(ctx), "curl https://example.com")

        @Expect(decision.applies, true)
        @Expect(decision.approved, false)
        @Expect(decision.status, "blocked")
        @Expect(decision.reason, "cron_headless_approval_required")
        @Expect(decision.message.contains("cron cannot wait for interactive approval"), true)
        @Expect(decision.message.contains("news-job"), true)
    }

    @TestCase
    public func cronAllowlistHitApprovesWithoutInteractiveConfirmation(): Unit {
        let ctx = GatewayToolRuntimeContext(
            "cron",
            cronJobId: "news-job",
            toolExecMode: "allowlist",
            toolExecAllowlist: ["curl", "python3 -m"]
        )
        let decision = resolveCronShellExecutionDecision(Some(ctx), "curl -fsSL https://example.com")

        @Expect(decision.applies, true)
        @Expect(decision.approved, true)
        @Expect(decision.status, "allowlist-hit")
        @Expect(decision.reason, "cron_tool_exec_allowlist_hit")
    }

    @TestCase
    public func cronAllowlistBoundaryRejectsEmptyAndSimilarPrefixes(): Unit {
        let ctx = GatewayToolRuntimeContext(
            "cron",
            cronJobId: "news-job",
            toolExecMode: "allowlist",
            toolExecAllowlist: ["curl"]
        )
        let empty = resolveCronShellExecutionDecision(Some(ctx), "")
        let miss = resolveCronShellExecutionDecision(Some(ctx), "curlx https://example.com")
        let noAllow = resolveCronShellExecutionDecision(
            Some(GatewayToolRuntimeContext("cron", cronJobId: "news-job", toolExecMode: "allowlist")),
            "curl https://example.com"
        )

        @Expect(empty.approved, false)
        @Expect(empty.reason, "cron_tool_exec_empty_command")
        @Expect(miss.approved, false)
        @Expect(miss.reason, "cron_tool_exec_allowlist_miss")
        @Expect(noAllow.approved, false)
        @Expect(noAllow.reason, "cron_tool_exec_allowlist_miss")
    }

    @TestCase
    public func nonCronContextKeepsInteractiveShellConfirmationPath(): Unit {
        let ctx = GatewayToolRuntimeContext("feishu", toolExecMode: "yolo")
        let decision = resolveCronShellExecutionDecision(Some(ctx), "printf ok")

        @Expect(decision.applies, false)
        @Expect(decision.approved, false)
        @Expect(decision.status, "interactive")
        @Expect(decision.reason, "not_cron_context")
    }
}
