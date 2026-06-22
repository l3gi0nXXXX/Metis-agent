package metis.cron

import std.unittest.testmacro.*

@Test
public class CronExpressionTimeZoneTest {
    @TestCase
    public func utcCronTenRunsAtBeijingEighteen(): Unit {
        let before = 1_782_122_340_000
        let expectedUtc = 1_782_122_400_000
        let nextUtc = computeNextRunAtMs(CronSchedule.cron("0 10 * * *", "UTC"), before, 0).getOrThrow()
        @Expect(nextUtc, expectedUtc)

        let nextShanghai = computeNextRunAtMs(CronSchedule.cron("0 18 * * *", "Asia/Shanghai"), before, 0).getOrThrow()
        @Expect(nextShanghai, expectedUtc)
    }

    @TestCase
    public func cronTimezoneRejectsUnknownName(): Unit {
        @Expect(cronResolveTimeZoneOffsetMinutes("Mars/Base").isNone(), true)
    }
}
