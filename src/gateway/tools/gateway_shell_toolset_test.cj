package metis.gateway.tools

import metis.core.{CRON_SHELL_BLOCKED_MARKER, GatewayToolRuntimeContext, gatewayWithToolRuntimeContext, resolveCurrentCronShellExecutionDecision}
import metis.core.config.CliConfig
import metis.utils.{SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC, SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC, ShellUtils}

import std.fs.{File, Path, exists, remove}
import std.time.DateTime
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

    @TestCase
    public func deadlineShellPreservesChineseAndEmojiUtf8Output(): Unit {
        let result = ShellUtils.executeWithDeadline("printf '中文🙂'", 1000)
        @Expect(result[0], 0)
        @Expect(result[1], "中文🙂")
        @Expect(result[2], "")
    }

    @TestCase
    public func deadlineShellRejectsBinaryStdoutWithStableNonSensitiveDiagnostic(): Unit {
        let result = ShellUtils.executeWithDeadline("printf '\\377secret-never-visible'", 1000)
        @Expect(result[0], SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE)
        @Expect(result[1], "")
        @Expect(result[2], SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC)
        @Expect(result[2].contains("secret-never-visible"), false)

        let visible = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext("cron", cronJobId: "binary-job", toolExecMode: "yolo"),
            { =>
                debugGatewayShellExecuteForTest(
                    CliConfig.cwd.toString(),
                    "printf '\\377secret-never-visible'",
                    None<String>,
                    Some(false)
                )
            }
        )
        @Expect(visible.contains(SHELL_INVALID_RESPONSE_ENCODING_DIAGNOSTIC), true)
        @Expect(visible.contains("secret-never-visible"), false)
        @Expect(visible.contains("successfully"), false)
    }

    @TestCase
    public func deadlineShellReportsDegradedTreeTerminationWhenPgrepUnavailable(): Unit {
        let result = ShellUtils.executeWithDeadline(
            "printf ok",
            1000,
            pgrepPath: "/path-that-does-not-exist/pgrep"
        )
        @Expect(result[0], 0)
        @Expect(result[1], "ok")
        @Expect(result[2].contains(SHELL_PROCESS_TREE_DEGRADED_DIAGNOSTIC), true)
        @Expect(result[2].contains("/path-that-does-not-exist"), false)
    }

    @TestCase
    public func cronAllowlistCurlShellToolExecutesWithoutInteractiveConfirmation(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext(
                "cron",
                cronJobId: "curl-allow-job",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["curl"]
            ),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "curl --version", None<String>, Some(false))
            }
        )

        @Expect(out.contains("Command executed successfully"), true)
        @Expect(out.contains("curl"), true)
    }

    @TestCase
    public func cronAllowlistCurlDoesNotMatchCurlxPrefix(): Unit {
        let out = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext(
                "cron",
                cronJobId: "curlx-deny-job",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["curl"]
            ),
            { =>
                debugGatewayShellExecuteForTest(CliConfig.cwd.toString(), "curlx --version", None<String>, Some(false))
            }
        )

        @Expect(out.contains(CRON_SHELL_BLOCKED_MARKER), true)
        @Expect(out.contains("cron_tool_exec_allowlist_miss"), true)
        @Expect(out.contains("curlx --version"), true)
    }

    @TestCase
    public func m3N1CronToolChildUsesRemainingDeadlineAndCannotProduceLateSuccess(): Unit {
        let marker = Path(
            "/tmp/metis-cron-tool-deadline-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        )
        let pidFile = Path("${marker}.pid")
        try {
            let startedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let out = gatewayWithToolRuntimeContext(
                GatewayToolRuntimeContext(
                    "cron",
                    cronJobId: "deadline-tool-job",
                    toolExecMode: "yolo",
                    remainingMsHook: Some({ => 20 })
                ),
                { =>
                    debugGatewayShellExecuteForTest(
                        CliConfig.cwd.toString(),
                        "echo $$ > ${pidFile}; sleep 2; printf late-success > ${marker}",
                        None<String>,
                        Some(false)
                    )
                }
            )
            let elapsedMs = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAtMs
            @Expect(out.contains("timeout"), true)
            @Expect(out.contains("late-success"), false)
            @Expect(elapsedMs < 500, true)
            @Expect(exists(pidFile), true)
            let pid = String.fromUtf8(File.readFrom(pidFile)).trimAscii()
            let (pidCheck, _, _) = ShellUtils.execute(
                ["/bin/kill", "-0", pid],
                withWrap: false
            )
            @Expect(pidCheck != 0, true)
            @Expect(exists(marker), false)
        } finally {
            try { remove(marker) } catch (_: Exception) { () }
            try { remove(pidFile) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func nonCronImShellContextKeepsInteractivePolicyPath(): Unit {
        let decision = gatewayWithToolRuntimeContext(
            GatewayToolRuntimeContext(
                "telegram",
                channelName: "telegram",
                sessionKey: "telegram:chat:42",
                toolExecMode: "allowlist",
                toolExecAllowlist: ["curl"]
            ),
            { => resolveCurrentCronShellExecutionDecision("curl --version") }
        )

        @Expect(decision.applies, false)
        @Expect(decision.status, "interactive")
        @Expect(decision.reason, "not_cron_context")
    }
}
