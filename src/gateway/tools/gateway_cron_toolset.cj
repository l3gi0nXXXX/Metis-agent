package metis.gateway.tools

import magic.dsl.{tool, toolset}
import magic.prelude.*

import metis.cron.{CronPromptScanResult, executeGatewayCronCommand, scanCronPromptStrict}
import metis.io.PrintUtils

import std.collection.ArrayList
import stdx.encoding.json.{JsonObject, JsonString}

@toolset
public class GatewayCronToolset {
    private func addStringFlag(args: ArrayList<String>, flag: String, value: Option<String>): Unit {
        match (value) {
            case Some(v) =>
                let t = v.trimAscii()
                if (!t.isEmpty()) {
                    args.add(flag)
                    args.add(t)
                }
            case None => ()
        }
    }

    private func addIntFlag(args: ArrayList<String>, flag: String, value: Option<Int64>): Unit {
        match (value) {
            case Some(v) =>
                args.add(flag)
                args.add(v.toString())
            case None => ()
        }
    }

    private func addBoolFlag(args: ArrayList<String>, flag: String, value: Option<Bool>): Unit {
        match (value) {
            case Some(v) =>
                if (v) {
                    args.add(flag)
                }
            case None => ()
        }
    }

    private func addBoolChoiceFlag(args: ArrayList<String>, trueFlag: String, falseFlag: String, value: Option<Bool>): Unit {
        match (value) {
            case Some(v) => args.add(if (v) { trueFlag } else { falseFlag })
            case None => ()
        }
    }

    private func normalizeAction(action: String): String {
        let normalized = action.trimAscii().toAsciiLower()
        if (
            normalized == "help" ||
            normalized == "path" ||
            normalized == "status" ||
            normalized == "list" ||
            normalized == "add" ||
            normalized == "update" ||
            normalized == "remove" ||
            normalized == "enable" ||
            normalized == "disable" ||
            normalized == "run" ||
            normalized == "runs" ||
            normalized == "wake"
        ) {
            return normalized
        }
        ""
    }

    private func promptBlockedResult(action: String, scan: CronPromptScanResult): String {
        let err = JsonObject()
        err.put("ok", false.toJsonValue())
        err.put("action", JsonString(action))
        err.put("status", JsonString("error"))
        err.put("errorCode", JsonString("cron_prompt_blocked"))
        err.put("threatId", JsonString(scan.threatId))
        err.put("message", JsonString(scan.message))
        let out = err.toJsonString()
        PrintUtils.printToolResult(out)
        out
    }

    @tool[
        description: "Operate gateway cron jobs through the unified Gateway cron backend. Supported actions: help, path, status, list, add, update, remove, enable, disable, run, runs, wake.",
        parameters: {
            action: "Cron action.",
            id: "Optional cron job id.",
            name: "Optional cron job name for add/update.",
            message: "Optional message/prompt text for add/update/wake.",
            every: "Optional interval schedule for add, e.g. 10m.",
            at: "Optional absolute timestamp for add.",
            cronExpr: "Optional cron expression for add/update.",
            enabled: "Optional enabled flag for update.",
            session: "Optional session target for add/update: main, isolated, current, or session:<key>.",
            deliveryChannel: "Optional delivery channel for add/update.",
            deliveryMode: "Optional delivery mode for add/update: none, announce, or webhook.",
            deliveryTo: "Optional delivery peer/chat target for add/update.",
            deliveryAccountId: "Optional delivery account id for add/update.",
            bestEffortDeliver: "Optional best-effort delivery flag for add/update.",
            timeoutMs: "Optional execution timeout in milliseconds for add/update.",
            maxRetries: "Optional max retry count for add/update.",
            retryBackoffMs: "Optional retry backoff milliseconds for add/update.",
            failureChannel: "Optional failure alert channel for add/update.",
            failureDestMode: "Optional failure delivery mode for add/update: none, announce, or webhook.",
            failureTo: "Optional failure alert target for add/update.",
            failureAccountId: "Optional failure alert account id for add/update.",
            failureAlertAfter: "Optional consecutive failure threshold for alerts.",
            failureAlertCooldownMs: "Optional failure alert cooldown milliseconds.",
            model: "Optional model override for add/update.",
            thinkingLevel: "Optional thinking level for add/update.",
            lightContext: "Optional light context flag for add/update.",
            dueOnly: "Optional due_only flag for run.",
            mode: "Optional wake mode.",
            text: "Optional wake text."
        }
    ]
    public func cron(
        action: String,
        id: Option<String>,
        name: Option<String>,
        message: Option<String>,
        every: Option<String>,
        at: Option<String>,
        cronExpr: Option<String>,
        enabled: Option<Bool>,
        session: Option<String>,
        deliveryChannel: Option<String>,
        deliveryMode: Option<String>,
        deliveryTo: Option<String>,
        deliveryAccountId: Option<String>,
        bestEffortDeliver: Option<Bool>,
        timeoutMs: Option<Int64>,
        maxRetries: Option<Int64>,
        retryBackoffMs: Option<Int64>,
        failureChannel: Option<String>,
        failureDestMode: Option<String>,
        failureTo: Option<String>,
        failureAccountId: Option<String>,
        failureAlertAfter: Option<Int64>,
        failureAlertCooldownMs: Option<Int64>,
        model: Option<String>,
        thinkingLevel: Option<String>,
        lightContext: Option<Bool>,
        dueOnly: Option<Bool>,
        mode: Option<String>,
        text: Option<String>
    ): String {
        let act = this.normalizeAction(action)
        PrintUtils.printTool("cron", shortMessage: if (act.isEmpty()) { "help" } else { act })

        let args = ArrayList<String>(["cron"])
        if (act.isEmpty() || act == "help") {
            args.add("help")
        } else if (act == "path" || act == "list" || act == "status") {
            args.add(act)
        } else if (act == "add") {
            let jobName = match (name) { case Some(v) => v.trimAscii() case None => "" }
            let msg = match (message) { case Some(v) => v.trimAscii() case None => "" }
            if (jobName.isEmpty() || msg.isEmpty()) {
                let err = JsonObject()
                err.put("ok", false.toJsonValue())
                err.put("action", JsonString("add"))
                err.put("status", JsonString("error"))
                err.put("error", JsonString("add requires name and message"))
                let out = err.toJsonString()
                PrintUtils.printToolResult(out)
                return out
            }
            let promptScan = scanCronPromptStrict(msg)
            if (!promptScan.ok) {
                return this.promptBlockedResult("add", promptScan)
            }
            args.add("add")
            args.add("--name")
            args.add(jobName)
            match (every) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--every")
                        args.add(t)
                    }
                case None => ()
            }
            match (at) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--at")
                        args.add(t)
                    }
                case None => ()
            }
            match (cronExpr) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--cron")
                        args.add(t)
                    }
                case None => ()
            }
            this.addStringFlag(args, "--session", session)
            this.addStringFlag(args, "--delivery-mode", deliveryMode)
            this.addStringFlag(args, "--channel", deliveryChannel)
            this.addStringFlag(args, "--to", deliveryTo)
            this.addStringFlag(args, "--delivery-account-id", deliveryAccountId)
            this.addBoolChoiceFlag(args, "--best-effort-deliver", "--no-best-effort-deliver", bestEffortDeliver)
            this.addIntFlag(args, "--timeout-ms", timeoutMs)
            this.addIntFlag(args, "--max-retries", maxRetries)
            this.addIntFlag(args, "--retry-backoff-ms", retryBackoffMs)
            this.addStringFlag(args, "--failure-dest-mode", failureDestMode)
            this.addStringFlag(args, "--failure-channel", failureChannel)
            this.addStringFlag(args, "--failure-to", failureTo)
            this.addStringFlag(args, "--failure-account-id", failureAccountId)
            this.addIntFlag(args, "--failure-alert-after", failureAlertAfter)
            this.addIntFlag(args, "--failure-alert-cooldown-ms", failureAlertCooldownMs)
            this.addStringFlag(args, "--model", model)
            this.addStringFlag(args, "--thinking-level", thinkingLevel)
            this.addBoolChoiceFlag(args, "--light-context", "--no-light-context", lightContext)
            args.add("--message")
            args.add(msg)
        } else if (act == "update") {
            let resolvedId = match (id) { case Some(v) => v.trimAscii() case None => "" }
            if (resolvedId.isEmpty()) {
                let err = JsonObject()
                err.put("ok", false.toJsonValue())
                err.put("action", JsonString("update"))
                err.put("status", JsonString("error"))
                err.put("error", JsonString("update requires id"))
                let out = err.toJsonString()
                PrintUtils.printToolResult(out)
                return out
            }
            match (message) {
                case Some(rawPrompt) =>
                    let prompt = rawPrompt.trimAscii()
                    if (!prompt.isEmpty()) {
                        let promptScan = scanCronPromptStrict(rawPrompt)
                        if (!promptScan.ok) {
                            return this.promptBlockedResult("update", promptScan)
                        }
                    }
                case None => ()
            }
            args.add("update")
            args.add("--job-id")
            args.add(resolvedId)
            match (name) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--name")
                        args.add(t)
                    }
                case None => ()
            }
            match (every) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--every")
                        args.add(t)
                    }
                case None => ()
            }
            match (at) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--at")
                        args.add(t)
                    }
                case None => ()
            }
            match (cronExpr) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--cron")
                        args.add(t)
                    }
                case None => ()
            }
            match (enabled) {
                case Some(v) => args.add(if (v) { "--enable" } else { "--disable" })
                case None => ()
            }
            this.addStringFlag(args, "--session", session)
            this.addStringFlag(args, "--delivery-mode", deliveryMode)
            this.addStringFlag(args, "--channel", deliveryChannel)
            this.addStringFlag(args, "--to", deliveryTo)
            this.addStringFlag(args, "--delivery-account-id", deliveryAccountId)
            this.addBoolChoiceFlag(args, "--best-effort-deliver", "--no-best-effort-deliver", bestEffortDeliver)
            this.addIntFlag(args, "--timeout-ms", timeoutMs)
            this.addIntFlag(args, "--max-retries", maxRetries)
            this.addIntFlag(args, "--retry-backoff-ms", retryBackoffMs)
            this.addStringFlag(args, "--failure-dest-mode", failureDestMode)
            this.addStringFlag(args, "--failure-channel", failureChannel)
            this.addStringFlag(args, "--failure-to", failureTo)
            this.addStringFlag(args, "--failure-account-id", failureAccountId)
            this.addIntFlag(args, "--failure-alert-after", failureAlertAfter)
            this.addIntFlag(args, "--failure-alert-cooldown-ms", failureAlertCooldownMs)
            this.addStringFlag(args, "--model", model)
            this.addStringFlag(args, "--thinking-level", thinkingLevel)
            this.addBoolChoiceFlag(args, "--light-context", "--no-light-context", lightContext)
            match (message) {
                case Some(v) =>
                    let t = v.trimAscii()
                    if (!t.isEmpty()) {
                        args.add("--message")
                        args.add(t)
                    }
                case None => ()
            }
        } else if (act == "remove" || act == "enable" || act == "disable" || act == "run" || act == "runs" || act == "wake") {
            let resolvedId = match (id) { case Some(v) => v.trimAscii() case None => "" }
            if ((act == "remove" || act == "enable" || act == "disable" || act == "run" || act == "runs" || act == "wake") && resolvedId.isEmpty()) {
                let err = JsonObject()
                err.put("ok", false.toJsonValue())
                err.put("action", JsonString(act))
                err.put("status", JsonString("error"))
                err.put("error", JsonString("${act} requires id"))
                let out = err.toJsonString()
                PrintUtils.printToolResult(out)
                return out
            }
            args.add(act)
            args.add("--job-id")
            args.add(resolvedId)
            if (act == "run") {
                if (dueOnly ?? false) {
                    args.add("--due")
                }
            }
            if (act == "wake") {
                match (mode) {
                    case Some(v) =>
                        let t = v.trimAscii()
                        if (!t.isEmpty()) {
                            args.add("--mode")
                            args.add(t)
                        }
                    case None => ()
                }
                match (text) {
                    case Some(v) =>
                        let t = v.trimAscii()
                        if (!t.isEmpty()) {
                            args.add("--text")
                            args.add(t)
                        }
                    case None => ()
                }
            }
        }

        // The unified gateway runtime registers the cron run hook during service setup,
        // so the tool only needs the shared cron command entrypoint here.
        let (msg, code) = executeGatewayCronCommand(args.toArray())
        let result = JsonObject()
        result.put("ok", (code == 0).toJsonValue())
        result.put("action", JsonString(if (act.isEmpty()) { "help" } else { act }))
        result.put("status", JsonString(if (code == 0) { "ok" } else { "error" }))
        result.put("exitCode", code.toJsonValue())
        result.put("output", JsonString(msg))
        let out = result.toJsonString()
        PrintUtils.printToolResult(out)
        return out
    }

    public func cronForTest(
        action: String,
        id: Option<String>,
        name: Option<String>,
        message: Option<String>,
        every: Option<String>,
        at: Option<String>,
        cronExpr: Option<String>,
        enabled: Option<Bool>,
        session: Option<String>,
        deliveryChannel: Option<String>,
        deliveryMode: Option<String>,
        deliveryTo: Option<String>,
        deliveryAccountId: Option<String>,
        bestEffortDeliver: Option<Bool>,
        timeoutMs: Option<Int64>,
        maxRetries: Option<Int64>,
        retryBackoffMs: Option<Int64>,
        failureChannel: Option<String>,
        failureDestMode: Option<String>,
        failureTo: Option<String>,
        failureAccountId: Option<String>,
        failureAlertAfter: Option<Int64>,
        failureAlertCooldownMs: Option<Int64>,
        model: Option<String>,
        thinkingLevel: Option<String>,
        lightContext: Option<Bool>,
        dueOnly: Option<Bool>,
        mode: Option<String>,
        text: Option<String>
    ): String {
        this.__tool_impl_of_cron(
            action,
            id,
            name,
            message,
            every,
            at,
            cronExpr,
            enabled,
            session,
            deliveryChannel,
            deliveryMode,
            deliveryTo,
            deliveryAccountId,
            bestEffortDeliver,
            timeoutMs,
            maxRetries,
            retryBackoffMs,
            failureChannel,
            failureDestMode,
            failureTo,
            failureAccountId,
            failureAlertAfter,
            failureAlertCooldownMs,
            model,
            thinkingLevel,
            lightContext,
            dueOnly,
            mode,
            text
        )
    }
}
