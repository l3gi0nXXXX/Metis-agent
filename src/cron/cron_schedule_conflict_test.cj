package metis.cron

import std.unittest.*
import std.unittest.testmacro.*

private func cronConflictTestJob(
    id: String,
    atMs: Int64,
    enabled!: Bool = true,
    sessionKey!: String = "",
    sessionTarget!: String = "isolated",
    channel!: String = "feishu",
    target!: String = "chat-a",
    payloadKind!: String = "agentTurn"
): CronJob {
    CronJob(
        id,
        "重任务 ${id}",
        CronSchedule.at(atMs),
        enabled: enabled,
        sessionTarget: sessionTarget,
        deliveryChannel: channel,
        deliveryTo: target,
        payloadKind: payloadKind,
        sessionKey: sessionKey
    )
}

@Test
public class CronScheduleConflictTest {
    @TestCase
    public func c2U01SameDeliveryTargetProducesOneReadonlyWarning(): Unit {
        let first = cronConflictTestJob("体育-中文-😀", 10_000, sessionKey: "session-a")
        let second = cronConflictTestJob("sports-b", 10_000, sessionKey: "session-b")
        let beforeFirst = first.schedule.atMs
        let beforeSecond = second.schedule.atMs

        let rows = detectCronScheduleConflicts([first, second], 1_000)

        @Expect(rows.size, 1)
        @Expect(rows[0].jobIds, ["体育-中文-😀", "sports-b"])
        @Expect(rows[0].reason, "same_delivery_target")
        @Expect(rows[0].nextRunAtMs, 10_000)
        @Expect(first.schedule.atMs, beforeFirst)
        @Expect(second.schedule.atMs, beforeSecond)
    }

    @TestCase
    public func c2B01WindowDisabledResourceAndSerialKeyBoundariesAreExact(): Unit {
        let base = cronConflictTestJob(
            "base", 10_000, sessionKey: "shared", channel: "feishu", target: "chat-a"
        )
        let outside = cronConflictTestJob(
            "outside", 70_001, sessionKey: "shared", channel: "telegram", target: "chat-b"
        )
        @Expect(detectCronScheduleConflicts([base, outside], 1_000, windowMs: 60_000).size, 0)

        let sameSerial = cronConflictTestJob(
            "same-serial", 70_000, sessionKey: "shared", channel: "telegram", target: "chat-b"
        )
        let serialRows = detectCronScheduleConflicts([base, sameSerial], 1_000, windowMs: 60_000)
        @Expect(serialRows.size, 1)
        @Expect(serialRows[0].reason, "same_serial_key")

        let disabled = cronConflictTestJob("disabled", 10_000, enabled: false)
        let systemEvent = cronConflictTestJob("system", 10_000, payloadKind: "systemEvent")
        @Expect(detectCronScheduleConflicts([base, disabled, systemEvent], 1_000).size, 0)

        let different = cronConflictTestJob(
            "different", 10_000, sessionKey: "different", channel: "telegram", target: "chat-c"
        )
        @Expect(detectCronScheduleConflicts([base, different], 1_000).size, 0)

        let isolatedA = cronConflictTestJob(
            "isolated-a", 10_000, channel: "feishu", target: "chat-a"
        )
        let isolatedB = cronConflictTestJob(
            "isolated-b", 10_000, channel: "telegram", target: "chat-b"
        )
        @Expect(cronConflictSerialKey(isolatedA), "gateway:cron:isolated:isolated-a")
        @Expect(cronConflictSerialKey(isolatedB), "gateway:cron:isolated:isolated-b")
        @Expect(detectCronScheduleConflicts([isolatedA, isolatedB], 1_000).size, 0)
    }
}
