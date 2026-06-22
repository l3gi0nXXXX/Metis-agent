package metis.core

public class CronShellExecutionDecision {
    public let applies: Bool
    public let approved: Bool
    public let status: String
    public let reason: String
    public let message: String

    public init(
        applies: Bool,
        approved: Bool,
        status: String,
        reason: String,
        message!: String = ""
    ) {
        this.applies = applies
        this.approved = approved
        this.status = status
        this.reason = reason
        this.message = message
    }
}

private func normalizeCronShellExecMode(raw: String): String {
    let mode = raw.trimAscii().toAsciiLower()
    if (mode == "allowlist" || mode == "yolo") {
        return mode
    }
    "deny"
}

private func cronShellCommandHasAllowedPrefix(command: String, prefix: String): Bool {
    let cmd = command.trimAscii()
    let pat = prefix.trimAscii()
    if (cmd.isEmpty() || pat.isEmpty()) {
        return false
    }
    if (cmd == pat) {
        return true
    }
    cmd.startsWith(pat + " ") ||
        cmd.startsWith(pat + "\t") ||
        cmd.startsWith(pat + "\n") ||
        cmd.startsWith(pat + ";") ||
        cmd.startsWith(pat + "&") ||
        cmd.startsWith(pat + "|")
}

public func cronShellCommandMatchesAllowlist(command: String, allowlist: Array<String>): Bool {
    for (entry in allowlist) {
        if (cronShellCommandHasAllowedPrefix(command, entry)) {
            return true
        }
    }
    false
}

private func renderCronShellBlockedMessage(reason: String, cronJobId: String, command: String): String {
    let id = cronJobId.trimAscii()
    let idPart = if (id.isEmpty()) { "" } else { " for cron job '${metisSafeRuneEllipsis(id, 48)}'" }
    let commandPart = if (command.trimAscii().isEmpty()) {
        ""
    } else {
        " Command preview: ${metisSafeRuneEllipsis(command.trimAscii(), 80)}."
    }
    if (reason == "cron_tool_exec_allowlist_miss") {
        return "Cron/headless shell execution blocked${idPart}: command is not covered by toolExecAllowlist.${commandPart} Configure --tool-exec-mode allowlist with a matching --tool-exec-allow prefix, or use --tool-exec-mode yolo for this cron job only."
    }
    if (reason == "cron_tool_exec_empty_command") {
        return "Cron/headless shell execution blocked${idPart}: shell command is empty. Configure a non-empty command and explicit cron tool authorization."
    }
    "Cron/headless shell execution blocked${idPart}: cron cannot wait for interactive approval.${commandPart} Configure --tool-exec-mode allowlist with --tool-exec-allow <prefix>, or --tool-exec-mode yolo for this cron job only."
}

public func resolveCronShellExecutionDecision(
    context: Option<GatewayToolRuntimeContext>,
    command: String
): CronShellExecutionDecision {
    match (context) {
        case Some(ctx) =>
            if (ctx.sourceLabel != "cron") {
                return CronShellExecutionDecision(false, false, "interactive", "not_cron_context")
            }
            let mode = normalizeCronShellExecMode(ctx.toolExecMode)
            let trimmedCommand = command.trimAscii()
            if (trimmedCommand.isEmpty()) {
                let reason = "cron_tool_exec_empty_command"
                return CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command))
            }
            if (mode == "yolo") {
                return CronShellExecutionDecision(true, true, "yolo", "cron_tool_exec_yolo")
            }
            if (mode == "allowlist") {
                if (cronShellCommandMatchesAllowlist(trimmedCommand, ctx.toolExecAllowlist)) {
                    return CronShellExecutionDecision(true, true, "allowlist-hit", "cron_tool_exec_allowlist_hit")
                }
                let reason = "cron_tool_exec_allowlist_miss"
                return CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command))
            }
            let reason = "cron_headless_approval_required"
            CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command))
        case None => CronShellExecutionDecision(false, false, "interactive", "no_runtime_context")
    }
}

public func resolveCurrentCronShellExecutionDecision(command: String): CronShellExecutionDecision {
    resolveCronShellExecutionDecision(gatewayCurrentToolRuntimeContext(), command)
}
