package metis.cron

import std.collection.ArrayList

/** `cron list/status` 使用的只读调度冲突诊断窗口。 */
public let CRON_SCHEDULE_CONFLICT_WINDOW_MS: Int64 = 60_000

public class CronScheduleConflict {
    public let jobIds: Array<String>
    public let reason: String
    public let nextRunAtMs: Int64
    public let windowMs: Int64

    public init(jobIds: Array<String>, reason: String, nextRunAtMs: Int64, windowMs: Int64) {
        this.jobIds = jobIds
        this.reason = reason
        this.nextRunAtMs = nextRunAtMs
        this.windowMs = windowMs
    }
}

/**
 * 返回与 CronRunner reservation 一致的串行键；空键表示没有可比较的会话资源。
 */
public func cronConflictSerialKey(job: CronJob): String {
    let explicit = job.sessionKey.trimAscii()
    if (!explicit.isEmpty()) {
        return explicit
    }
    conversationKeyForCronTarget(job.id, job.sessionTarget)
}

private func cronConflictNextRunAtMs(job: CronJob, nowMs: Int64): Option<Int64> {
    if (job.state.nextRunAtMs > nowMs) {
        return Some(job.state.nextRunAtMs)
    }
    computeJobNextRun(job, nowMs)
}

private func cronConflictDeliveryKey(job: CronJob): String {
    let channel = job.deliveryChannel.trimAscii().toAsciiLower()
    let target = job.deliveryTo.trimAscii()
    if (channel.isEmpty() && target.isEmpty()) {
        return ""
    }
    "${channel}\u{001f}${job.deliveryAccountId.trimAscii()}\u{001f}${target}"
}

private func cronConflictIsAgentWork(job: CronJob): Bool {
    job.payloadKind.trimAscii().toAsciiLower() == "agentturn" &&
        cronNormalizeScriptMode(job.scriptMode) != "noAgent"
}

/**
 * 对 enabled agent jobs 的下一触发做只读 pairwise 诊断。
 *
 * 同一窗口内，如果 delivery target 或 CronRunner serial key 相同，则返回 warning。
 * 本函数不持有 store、不修改 job，也不自动改变 schedule/stagger。
 */
public func detectCronScheduleConflicts(
    jobs: Array<CronJob>,
    nowMs: Int64,
    windowMs!: Int64 = CRON_SCHEDULE_CONFLICT_WINDOW_MS
): Array<CronScheduleConflict> {
    let boundedWindow = max(0, windowMs)
    let out = ArrayList<CronScheduleConflict>()
    var left: Int64 = 0
    while (left < jobs.size) {
        let a = jobs[left]
        if (!a.enabled || !cronConflictIsAgentWork(a)) {
            left += 1
            continue
        }
        let aNext = cronConflictNextRunAtMs(a, nowMs)
        var right = left + 1
        while (right < jobs.size) {
            let b = jobs[right]
            if (!b.enabled || !cronConflictIsAgentWork(b)) {
                right += 1
                continue
            }
            match ((aNext, cronConflictNextRunAtMs(b, nowMs))) {
                case (Some(aAt), Some(bAt)) =>
                    let distance = if (aAt >= bAt) { aAt - bAt } else { bAt - aAt }
                    if (distance <= boundedWindow) {
                        let aDelivery = cronConflictDeliveryKey(a)
                        let bDelivery = cronConflictDeliveryKey(b)
                        let aSerial = cronConflictSerialKey(a)
                        let bSerial = cronConflictSerialKey(b)
                        let sameDelivery = !aDelivery.isEmpty() && aDelivery == bDelivery
                        let sameSerial = !aSerial.isEmpty() && aSerial == bSerial
                        if (sameDelivery || sameSerial) {
                            let reason = if (sameDelivery && sameSerial) {
                                "same_delivery_target_and_serial_key"
                            } else if (sameDelivery) {
                                "same_delivery_target"
                            } else {
                                "same_serial_key"
                            }
                            out.add(CronScheduleConflict(
                                [a.id, b.id],
                                reason,
                                min(aAt, bAt),
                                boundedWindow
                            ))
                        }
                    }
                case _ => ()
            }
            right += 1
        }
        left += 1
    }
    out.toArray()
}
