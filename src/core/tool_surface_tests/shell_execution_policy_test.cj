package metis.core.tool_surface_tests

import metis.core.{
    GatewayToolRuntimeContext,
    cronShellCommandGuardDecision,
    cronShellExecutionBlockedDiagnosticFromText,
    resolveCronShellExecutionDecision
}
import metis.cron.cronNormalizeToolExecMode

import std.unittest.testmacro.*

@Test
public class CronShellExecutionPolicyTest {
    @TestCase
    public func cronGuardedDefaultApprovesSafeCommand(): Unit {
        @Expect(cronNormalizeToolExecMode(""), "guarded")
        @Expect(cronNormalizeToolExecMode("GUARDED"), "guarded")
        @Expect(cronNormalizeToolExecMode("deny"), "deny")
        @Expect(cronNormalizeToolExecMode("allowlist"), "allowlist")
        @Expect(cronNormalizeToolExecMode("yolo"), "yolo")

        let ctx = GatewayToolRuntimeContext("cron", cronJobId: "news-job", toolExecMode: "GUARDED")
        let decision = resolveCronShellExecutionDecision(Some(ctx), "echo hello")

        @Expect(decision.applies, true)
        @Expect(decision.approved, true)
        @Expect(decision.status, "guarded")
        @Expect(decision.reason, "cron_tool_exec_guarded_safe")
    }

    @TestCase
    public func cronDenyReturnsHeadlessBlockedDecision(): Unit {
        let ctx = GatewayToolRuntimeContext("cron", cronJobId: "news-job", toolExecMode: "deny")
        let decision = resolveCronShellExecutionDecision(Some(ctx), "curl https://example.com")

        @Expect(decision.applies, true)
        @Expect(decision.approved, false)
        @Expect(decision.status, "blocked")
        @Expect(decision.reason, "cron_headless_approval_required")
        @Expect(decision.message.contains("cron cannot wait for interactive approval"), true)
        @Expect(decision.message.contains("Diagnostic: code=cron_tool_exec_blocked reason=cron_headless_approval_required mode=deny allowlistCount=0."), true)
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
        @Expect(noAllow.message.contains("mode=allowlist allowlistCount=0"), true)
    }

    @TestCase
    public func cronGuardedBlocksEmptyAndDangerousCommands(): Unit {
        let empty = cronShellCommandGuardDecision("", "guard-job", 0)
        let rmRoot = cronShellCommandGuardDecision("rm -rf /", "guard-job", 0)
        let mkfs = cronShellCommandGuardDecision("mkfs.ext4 /dev/disk1", "guard-job", 0)
        let sudo = cronShellCommandGuardDecision("sudo -S", "guard-job", 0)
        let power = cronShellCommandGuardDecision("shutdown now", "guard-job", 0)

        @Expect(empty.approved, false)
        @Expect(empty.reason, "cron_tool_exec_empty_command")
        @Expect(rmRoot.approved, false)
        @Expect(rmRoot.reason, "cron_tool_exec_guarded_hardline")
        @Expect(mkfs.approved, false)
        @Expect(mkfs.reason, "cron_tool_exec_guarded_hardline")
        @Expect(sudo.approved, false)
        @Expect(sudo.reason, "cron_tool_exec_guarded_hardline")
        @Expect(power.approved, false)
        @Expect(power.reason, "cron_tool_exec_guarded_dangerous")
    }

    @TestCase
    public func cronBlockedDiagnosticParserHandlesNewLegacyAndNormalText(): Unit {
        let deny = resolveCronShellExecutionDecision(
            Some(GatewayToolRuntimeContext("cron", cronJobId: "diag-job", toolExecMode: "deny")),
            "curl https://example.com"
        )
        let allowMiss = resolveCronShellExecutionDecision(
            Some(GatewayToolRuntimeContext("cron", cronJobId: "diag-job", toolExecMode: "allowlist", toolExecAllowlist: ["printf"])),
            "curl https://example.com"
        )
        let legacy = "Cron/headless shell execution blocked for cron job 'old': cron cannot wait for interactive approval."

        let denyDiag = cronShellExecutionBlockedDiagnosticFromText(deny.message).getOrThrow()
        let allowDiag = cronShellExecutionBlockedDiagnosticFromText(allowMiss.message).getOrThrow()
        let legacyDiag = cronShellExecutionBlockedDiagnosticFromText(legacy).getOrThrow()

        @Expect(denyDiag.code, "cron_tool_exec_blocked")
        @Expect(denyDiag.reason, "cron_headless_approval_required")
        @Expect(denyDiag.mode, "deny")
        @Expect(allowDiag.reason, "cron_tool_exec_allowlist_miss")
        @Expect(allowDiag.mode, "allowlist")
        @Expect(allowDiag.allowlistCount, 1)
        @Expect(legacyDiag.reason, "cron_headless_approval_required")
        @Expect(legacyDiag.mode, "")
        @Expect(cronShellExecutionBlockedDiagnosticFromText("normal answer").isNone(), true)
    }

    @TestCase
    public func cronBlockedDiagnosticRedactsAndTruncatesUtf8CommandPreview(): Unit {
        let longTail = "中文🙂Authorization: Bearer secret-token-never-visible token=raw-lower-secret https://user:pass@example.com/hook "
        let decision = resolveCronShellExecutionDecision(
            Some(GatewayToolRuntimeContext("cron", cronJobId: "diag-secret", toolExecMode: "guarded")),
            "rm -rf / ${longTail}${longTail}${longTail}"
        )
        let diagnostic = cronShellExecutionBlockedDiagnosticFromText(decision.message).getOrThrow()

        @Expect(diagnostic.code, "cron_tool_exec_blocked")
        @Expect(diagnostic.commandPreview.contains("中文🙂"), true)
        @Expect(diagnostic.message.contains("secret-token-never-visible"), false)
        @Expect(diagnostic.message.contains("raw-lower-secret"), false)
        @Expect(diagnostic.message.contains("user:pass"), false)
        @Expect(diagnostic.message.size < 220, true)
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
