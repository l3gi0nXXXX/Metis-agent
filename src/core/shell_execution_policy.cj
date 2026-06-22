package metis.core

import std.convert.Parsable

public let CRON_SHELL_BLOCKED_MARKER: String = "Cron/headless shell execution blocked"

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

public class CronShellExecutionDiagnostic {
    public let code: String
    public let reason: String
    public let mode: String
    public let allowlistCount: Int64
    public let commandPreview: String
    public let message: String

    public init(
        code: String,
        reason: String,
        mode: String,
        allowlistCount: Int64,
        commandPreview: String,
        message: String
    ) {
        this.code = code
        this.reason = reason
        this.mode = mode
        this.allowlistCount = allowlistCount
        this.commandPreview = commandPreview
        this.message = message
    }
}

private func normalizeCronShellExecMode(raw: String): String {
    let mode = raw.trimAscii().toAsciiLower()
    if (mode == "guarded" || mode == "deny" || mode == "allowlist" || mode == "yolo") {
        return mode
    }
    "guarded"
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

private func cronShellRedactAfterMarker(raw: String, marker: String): String {
    let parts = raw.split(marker, 2)
    if (parts.size < 2) {
        return raw
    }
    parts[0] + marker + "[redacted]"
}

private func cronShellRedactUrlUserInfo(raw: String): String {
    let schemeParts = raw.split("://", 2)
    if (schemeParts.size < 2) {
        return raw
    }
    let restParts = schemeParts[1].split("@", 2)
    if (restParts.size < 2) {
        return raw
    }
    schemeParts[0] + "://[redacted]@" + restParts[1]
}

private func cronShellRedactDiagnosticText(raw: String): String {
    var out = raw
    out = cronShellRedactUrlUserInfo(out)
    out = cronShellRedactAfterMarker(out, "Authorization: Bearer ")
    out = cronShellRedactAfterMarker(out, "authorization: bearer ")
    out = cronShellRedactAfterMarker(out, "Authorization=")
    out = cronShellRedactAfterMarker(out, "authorization=")
    out = cronShellRedactAfterMarker(out, "Bearer ")
    out = cronShellRedactAfterMarker(out, "bearer ")
    out = cronShellRedactAfterMarker(out, "api_key=")
    out = cronShellRedactAfterMarker(out, "apiKey=")
    out = cronShellRedactAfterMarker(out, "token=")
    out = cronShellRedactAfterMarker(out, "access_token=")
    out = cronShellRedactAfterMarker(out, "auth_token=")
    out = cronShellRedactAfterMarker(out, "password=")
    out = cronShellRedactAfterMarker(out, "passwd=")
    out = cronShellRedactAfterMarker(out, "proxy=")
    out
}

private func cronShellCommandPreview(command: String, maxRunes: Int64): String {
    metisSafeRuneEllipsis(cronShellRedactDiagnosticText(command.trimAscii()), maxRunes)
}

private func renderCronShellBlockedDiagnostic(reason: String, mode: String, allowlistCount: Int64): String {
    "Diagnostic: code=cron_tool_exec_blocked reason=${reason} mode=${mode} allowlistCount=${allowlistCount}."
}

private func renderCronShellBlockedMessage(reason: String, cronJobId: String, command: String, mode: String, allowlistCount: Int64): String {
    let id = cronJobId.trimAscii()
    let idPart = if (id.isEmpty()) { "" } else { " for cron job '${metisSafeRuneEllipsis(id, 48)}'" }
    let commandPart = if (command.trimAscii().isEmpty()) {
        ""
    } else {
        " Command preview: ${cronShellCommandPreview(command, 80)}."
    }
    let diagnosticPart = " " + renderCronShellBlockedDiagnostic(reason, mode, allowlistCount)
    if (reason == "cron_tool_exec_allowlist_miss") {
        return "${CRON_SHELL_BLOCKED_MARKER}${idPart}: command is not covered by toolExecAllowlist.${commandPart} Configure --tool-exec-mode allowlist with a matching --tool-exec-allow prefix, or use --tool-exec-mode yolo for this cron job only.${diagnosticPart}"
    }
    if (reason == "cron_tool_exec_empty_command") {
        return "${CRON_SHELL_BLOCKED_MARKER}${idPart}: shell command is empty. Configure a non-empty command and explicit cron tool authorization.${diagnosticPart}"
    }
    if (reason == "cron_tool_exec_guarded_hardline" || reason == "cron_tool_exec_guarded_dangerous") {
        return "${CRON_SHELL_BLOCKED_MARKER}${idPart}: guarded cron policy blocked a dangerous shell command.${commandPart} Use a safer command, or configure an explicit allowlist/yolo only for this cron job after review.${diagnosticPart}"
    }
    "${CRON_SHELL_BLOCKED_MARKER}${idPart}: cron cannot wait for interactive approval.${commandPart} Configure --tool-exec-mode allowlist with --tool-exec-allow <prefix>, or --tool-exec-mode yolo for this cron job only.${diagnosticPart}"
}

private func cronShellContainsRootDestroyCommand(command: String): Bool {
    command.contains("rm -rf /") ||
        command.contains("rm -fr /") ||
        command.contains("rm -rf -- /") ||
        command.contains("rm -fr -- /")
}

private func cronShellContainsMkfsCommand(command: String): Bool {
    command == "mkfs" ||
        command.startsWith("mkfs ") ||
        command.contains(" mkfs ") ||
        command.contains(";mkfs ") ||
        command.contains("&&mkfs ") ||
        command.contains("|mkfs ") ||
        command.contains("mkfs.")
}

private func cronShellContainsPowerCommand(command: String): Bool {
    command == "shutdown" ||
        command == "reboot" ||
        command == "halt" ||
        command == "poweroff" ||
        command.startsWith("shutdown ") ||
        command.startsWith("reboot ") ||
        command.startsWith("halt ") ||
        command.startsWith("poweroff ") ||
        command.contains(" shutdown ") ||
        command.contains(" reboot ") ||
        command.contains(" halt ") ||
        command.contains(" poweroff ")
}

private func cronShellGuardedBlockReason(command: String): String {
    if (cronShellContainsRootDestroyCommand(command) ||
        cronShellContainsMkfsCommand(command) ||
        (command.contains("dd ") && command.contains("of=/dev/")) ||
        command.contains(":(){:|:&};:") ||
        command.contains("kill -1") ||
        command.contains("kill -9 -1") ||
        command.contains("sudo -s")) {
        return "cron_tool_exec_guarded_hardline"
    }
    if (cronShellContainsPowerCommand(command)) {
        return "cron_tool_exec_guarded_dangerous"
    }
    ""
}

public func cronShellCommandGuardDecision(command: String, cronJobId: String, allowlistCount: Int64): CronShellExecutionDecision {
    let trimmedCommand = command.trimAscii()
    if (trimmedCommand.isEmpty()) {
        let reason = "cron_tool_exec_empty_command"
        return CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, cronJobId, command, "guarded", allowlistCount))
    }
    let lowered = trimmedCommand.toAsciiLower()
    let blockReason = cronShellGuardedBlockReason(lowered)
    if (!blockReason.isEmpty()) {
        return CronShellExecutionDecision(true, false, "blocked", blockReason, message: renderCronShellBlockedMessage(blockReason, cronJobId, command, "guarded", allowlistCount))
    }
    CronShellExecutionDecision(true, true, "guarded", "cron_tool_exec_guarded_safe")
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
            let allowlistCount = ctx.toolExecAllowlist.size
            if (trimmedCommand.isEmpty()) {
                let reason = "cron_tool_exec_empty_command"
                return CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command, mode, allowlistCount))
            }
            if (mode == "yolo") {
                return CronShellExecutionDecision(true, true, "yolo", "cron_tool_exec_yolo")
            }
            if (mode == "guarded") {
                return cronShellCommandGuardDecision(trimmedCommand, ctx.cronJobId, allowlistCount)
            }
            if (mode == "allowlist") {
                if (cronShellCommandMatchesAllowlist(trimmedCommand, ctx.toolExecAllowlist)) {
                    return CronShellExecutionDecision(true, true, "allowlist-hit", "cron_tool_exec_allowlist_hit")
                }
                let reason = "cron_tool_exec_allowlist_miss"
                return CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command, mode, allowlistCount))
            }
            let reason = "cron_headless_approval_required"
            CronShellExecutionDecision(true, false, "blocked", reason, message: renderCronShellBlockedMessage(reason, ctx.cronJobId, command, mode, allowlistCount))
        case None => CronShellExecutionDecision(false, false, "interactive", "no_runtime_context")
    }
}

public func resolveCurrentCronShellExecutionDecision(command: String): CronShellExecutionDecision {
    resolveCronShellExecutionDecision(gatewayCurrentToolRuntimeContext(), command)
}

private func cronShellDiagnosticTokenValue(raw: String, key: String): String {
    for (part in raw.split(" ")) {
        let token = part.trimAscii()
        let pieces = token.split("=", 2)
        if (pieces.size == 2 && pieces[0] == key) {
            return pieces[1].replace(".", "").trimAscii()
        }
    }
    ""
}

private func cronShellDiagnosticCount(raw: String): Int64 {
    let value = cronShellDiagnosticTokenValue(raw, "allowlistCount")
    if (value.isEmpty()) {
        return 0
    }
    try {
        return Int64.parse(value)
    } catch (_: Exception) {
        return 0
    }
}

private func cronShellDiagnosticCommandPreview(raw: String): String {
    var preview = ""
    let commandParts = raw.split("Command preview:", 2)
    if (commandParts.size >= 2) {
        preview = commandParts[1].split(" Diagnostic:", 2)[0].split(" Configure ", 2)[0].trimAscii()
    }
    if (preview.isEmpty()) {
        preview = raw
    }
    cronShellCommandPreview(preview, 120)
}

private func cronShellDiagnosticMessage(code: String, reason: String, mode: String, allowlistCount: Int64, commandPreview: String): String {
    let previewPart = if (commandPreview.isEmpty()) { "" } else { " commandPreview=${commandPreview}" }
    metisSafeRuneEllipsis("code=${code} reason=${reason} mode=${mode} allowlistCount=${allowlistCount}${previewPart}", 180)
}

public func cronShellExecutionBlockedDiagnosticFromText(text: String): Option<CronShellExecutionDiagnostic> {
    if (!text.contains(CRON_SHELL_BLOCKED_MARKER)) {
        return None<CronShellExecutionDiagnostic>
    }
    let diagnosticParts = text.split("Diagnostic: code=cron_tool_exec_blocked", 2)
    var reason = "cron_headless_approval_required"
    var mode = ""
    var allowlistCount: Int64 = 0
    if (diagnosticParts.size >= 2) {
        let diagnosticTail = diagnosticParts[1]
        let parsedReason = cronShellDiagnosticTokenValue(diagnosticTail, "reason")
        let parsedMode = cronShellDiagnosticTokenValue(diagnosticTail, "mode")
        if (!parsedReason.isEmpty()) {
            reason = parsedReason
        }
        mode = parsedMode
        allowlistCount = cronShellDiagnosticCount(diagnosticTail)
    }
    let commandPreview = cronShellDiagnosticCommandPreview(text)
    let code = "cron_tool_exec_blocked"
    let message = cronShellDiagnosticMessage(code, reason, mode, allowlistCount, commandPreview)
    Some(CronShellExecutionDiagnostic(code, reason, mode, allowlistCount, commandPreview, message))
}
