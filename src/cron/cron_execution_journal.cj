package metis.cron

import std.collection.ArrayList
import stdx.encoding.json.*

private func cronJournalReadStr(o: JsonObject, key: String, default!: String = ""): String {
    match (o.get(key)) {
        case Some(v) => match (v) {
            case s: JsonString => s.getValue()
            case _ => default
        }
        case None => default
    }
}

private func cronJournalReadI64(o: JsonObject, key: String, default!: Int64 = 0): Int64 {
    match (o.get(key)) {
        case Some(v) => match (v) {
            case n: JsonInt => n.getValue()
            case n: JsonFloat => Int64(n.getValue())
            case _ => default
        }
        case None => default
    }
}

public class CronSchedulerCursor {
    public var nextRunAtMs: Int64
    public var jobId: String

    public init(nextRunAtMs!: Int64 = 0, jobId!: String = "") {
        this.nextRunAtMs = nextRunAtMs
        this.jobId = jobId
    }
}

/** 与调度排序键 `(nextRunAtMs, jobId)` 使用同一比较规则。 */
public func cronCompareSchedulerCursor(left: CronSchedulerCursor, right: CronSchedulerCursor): Int64 {
    if (left.nextRunAtMs < right.nextRunAtMs) {
        return -1
    }
    if (left.nextRunAtMs > right.nextRunAtMs) {
        return 1
    }
    if (left.jobId < right.jobId) {
        return -1
    }
    if (left.jobId > right.jobId) {
        return 1
    }
    0
}

public class CronSchedulerMetadata {
    public var fairnessCursor: CronSchedulerCursor

    public init(fairnessCursor!: CronSchedulerCursor = CronSchedulerCursor()) {
        this.fairnessCursor = fairnessCursor
    }
}

public func cronNormalizeDeliveryReceiptStatus(raw: String): String {
    let status = raw.trimAscii().toAsciiLower()
    if (
        status == "not_started" ||
        status == "in_flight" ||
        status == "succeeded" ||
        status == "failed" ||
        status == "unknown"
    ) {
        return status
    }
    "not_started"
}

public class CronDeliveryReceipt {
    /** 不包含 channel 地址、消息正文或凭据，仅保存稳定的目标标识。 */
    public let targetId: String
    public var status: String
    public var updatedAtMs: Int64
    public var errorCode: String

    public init(
        targetId: String,
        status!: String = "not_started",
        updatedAtMs!: Int64 = 0,
        errorCode!: String = ""
    ) {
        this.targetId = targetId
        this.status = cronNormalizeDeliveryReceiptStatus(status)
        this.updatedAtMs = updatedAtMs
        this.errorCode = errorCode
    }
}

private func cronExecutionPhaseRank(phase: String): Int64 {
    match (phase) {
        case "reserved" => 0
        case "executing" => 1
        case "result_committed" => 2
        case "delivery_pending" => 3
        case "delivery_settled" => 4
        case "logged" => 5
        case _ => -1
    }
}

public class CronExecutionJournalEntry {
    public let executionId: String
    public let jobId: String
    public var phase: String
    public let reservedAtMs: Int64
    public var updatedAtMs: Int64
    /** 只允许保存摘要 hash/稳定标识，禁止保存 prompt、token、路径或 payload。 */
    public var businessOutcomeHash: String
    /** 可恢复的 run-log marker；true 表示该 execution 的终态行已确认写入。 */
    public var runLogRecorded: Bool
    public var deliveryReceipts: Array<CronDeliveryReceipt>

    public init(
        executionId: String,
        jobId: String,
        phase!: String = "reserved",
        reservedAtMs!: Int64 = 0,
        updatedAtMs!: Int64 = 0,
        businessOutcomeHash!: String = "",
        runLogRecorded!: Bool = false,
        deliveryReceipts!: Array<CronDeliveryReceipt> = []
    ) {
        if (executionId.trimAscii().isEmpty() || jobId.trimAscii().isEmpty()) {
            throw Exception("cron journal identity must not be empty")
        }
        if (cronExecutionPhaseRank(phase) < 0) {
            throw Exception("invalid cron execution journal phase")
        }
        this.executionId = executionId
        this.jobId = jobId
        this.phase = phase
        this.reservedAtMs = reservedAtMs
        this.updatedAtMs = updatedAtMs
        this.businessOutcomeHash = businessOutcomeHash
        this.runLogRecorded = runLogRecorded
        this.deliveryReceipts = deliveryReceipts
    }

    /**
     * 只允许 phase 单调前进；重复 transition 幂等。验证在赋值前完成，失败不改变旧值。
     */
    public func transition(nextPhase: String, atMs: Int64): Bool {
        let currentRank = cronExecutionPhaseRank(this.phase)
        let nextRank = cronExecutionPhaseRank(nextPhase)
        if (nextRank < 0 || nextRank < currentRank) {
            throw Exception("invalid cron execution journal transition")
        }
        if (nextRank == currentRank) {
            return false
        }
        this.phase = nextPhase
        this.updatedAtMs = atMs
        true
    }
}

public class CronStoreEnvelope {
    public var jobs: Array<CronJob>
    public var scheduler: CronSchedulerMetadata
    public var journal: Array<CronExecutionJournalEntry>

    public init(
        jobs!: Array<CronJob> = [],
        scheduler!: CronSchedulerMetadata = CronSchedulerMetadata(),
        journal!: Array<CronExecutionJournalEntry> = []
    ) {
        this.jobs = jobs
        this.scheduler = scheduler
        this.journal = journal
    }
}

public func cronSchedulerMetadataFromJson(obj: JsonObject): CronSchedulerMetadata {
    let cursor = match (obj.get("fairnessCursor")) {
        case Some(value) => try {
            let cursorObj = value.asObject()
            CronSchedulerCursor(
                nextRunAtMs: cronJournalReadI64(cursorObj, "nextRunAtMs", default: 0),
                jobId: cronJournalReadStr(cursorObj, "jobId", default: "")
            )
        } catch (_: Exception) {
            CronSchedulerCursor()
        }
        case None => CronSchedulerCursor()
    }
    CronSchedulerMetadata(fairnessCursor: cursor)
}

public func cronSchedulerMetadataToJson(metadata: CronSchedulerMetadata): JsonObject {
    let cursor = JsonObject()
    cursor.put("nextRunAtMs", JsonInt(metadata.fairnessCursor.nextRunAtMs))
    cursor.put("jobId", JsonString(metadata.fairnessCursor.jobId))
    let out = JsonObject()
    out.put("fairnessCursor", cursor)
    out
}

public func cronExecutionJournalFromJson(value: JsonValue): Array<CronExecutionJournalEntry> {
    let out = ArrayList<CronExecutionJournalEntry>()
    try {
        for (item in value.asArray().getItems()) {
            try {
                let obj = item.asObject()
                let receipts = ArrayList<CronDeliveryReceipt>()
                match (obj.get("deliveryReceipts")) {
                    case Some(receiptValue) =>
                        try {
                            for (receiptItem in receiptValue.asArray().getItems()) {
                                let receipt = receiptItem.asObject()
                                receipts.add(
                                    CronDeliveryReceipt(
                                        cronJournalReadStr(receipt, "targetId"),
                                        status: cronJournalReadStr(receipt, "status", default: "not_started"),
                                        updatedAtMs: cronJournalReadI64(receipt, "updatedAtMs"),
                                        errorCode: cronJournalReadStr(receipt, "errorCode")
                                    )
                                )
                            }
                        } catch (_: Exception) {
                            ()
                        }
                    case None => ()
                }
                out.add(
                    CronExecutionJournalEntry(
                        cronJournalReadStr(obj, "executionId"),
                        cronJournalReadStr(obj, "jobId"),
                        phase: cronJournalReadStr(obj, "phase", default: "reserved"),
                        reservedAtMs: cronJournalReadI64(obj, "reservedAtMs"),
                        updatedAtMs: cronJournalReadI64(obj, "updatedAtMs"),
                        businessOutcomeHash: cronJournalReadStr(obj, "businessOutcomeHash"),
                        runLogRecorded: match (obj.get("runLogRecorded")) {
                            case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
                            case None => false
                        },
                        deliveryReceipts: receipts.toArray()
                    )
                )
            } catch (_: Exception) {
                ()
            }
        }
    } catch (_: Exception) {
        ()
    }
    out.toArray()
}

public func cronExecutionJournalToJson(entries: Array<CronExecutionJournalEntry>): JsonArray {
    let rows = ArrayList<JsonValue>()
    for (entry in entries) {
        let row = JsonObject()
        row.put("executionId", JsonString(entry.executionId))
        row.put("jobId", JsonString(entry.jobId))
        row.put("phase", JsonString(entry.phase))
        row.put("reservedAtMs", JsonInt(entry.reservedAtMs))
        row.put("updatedAtMs", JsonInt(entry.updatedAtMs))
        row.put("businessOutcomeHash", JsonString(entry.businessOutcomeHash))
        row.put("runLogRecorded", JsonBool(entry.runLogRecorded))
        let receipts = ArrayList<JsonValue>()
        for (receipt in entry.deliveryReceipts) {
            let receiptRow = JsonObject()
            receiptRow.put("targetId", JsonString(receipt.targetId))
            receiptRow.put("status", JsonString(cronNormalizeDeliveryReceiptStatus(receipt.status)))
            receiptRow.put("updatedAtMs", JsonInt(receipt.updatedAtMs))
            receiptRow.put("errorCode", JsonString(receipt.errorCode))
            receipts.add(receiptRow)
        }
        row.put("deliveryReceipts", JsonArray(receipts))
        rows.add(row)
    }
    JsonArray(rows)
}
