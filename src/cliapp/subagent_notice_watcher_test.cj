package metis.cliapp

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

@Test
public class CliSubagentNoticeWatcherTest {
    private func noticeEvent(sessionKey: String, notice: String, kind!: String = "session.subagent.notice"): JsonObject {
        let payload = JsonObject()
        payload.put("sessionKey", JsonString(sessionKey))
        payload.put("notice", JsonString(notice))
        let event = JsonObject()
        event.put("kind", JsonString(kind))
        event.put("payload", payload)
        event
    }

    @TestCase
    public func parsesOnlyGatewaySubagentNoticeEvents(): Unit {
        let event = noticeEvent("main", "[Subagent succeeded] reviewer subrun_1 summary done")
        match (cliSubagentNoticeFromGatewayEvent(event)) {
            case Some(notice) =>
                @Expect(notice.contains("[Subagent succeeded] reviewer subrun_1"), true)
                @Expect(notice.contains("summary done"), true)
            case None => @Expect("missing", "notice")
        }

        @Expect(cliSubagentNoticeFromGatewayEvent(noticeEvent("main", "ignored", kind: "session.transcript.updated")).isNone(), true)
        @Expect(cliSubagentNoticeFromGatewayEvent(JsonObject()).isNone(), true)
    }

    @TestCase
    public func matchesCanonicalCliSessionAlias(): Unit {
        @Expect(cliSubagentNoticeEventMatchesSession(noticeEvent("agent:general:main", "notice"), "main"), true)
        @Expect(cliSubagentNoticeEventMatchesSession(noticeEvent("telegram:chat:owner", "notice"), "main"), false)
    }

    @TestCase
    public func extractsNoticesFromGatewayStreamResult(): Unit {
        let events = JsonArray([])
        events.add(noticeEvent("agent:general:main", "[Subagent succeeded] old subrun_old"))
        events.add(noticeEvent("telegram:chat:owner", "[Subagent failed] other subrun_other"))
        events.add(noticeEvent("main", "[Subagent failed] reviewer subrun_new"))
        let pull = JsonObject()
        pull.put("events", events)
        let result = JsonObject()
        result.put("pull", pull)

        let notices = cliSubagentNoticesFromGatewayStreamResult(result, "main")
        @Expect(notices.size, 2)
        @Expect(notices[0], "[Subagent succeeded] old subrun_old")
        @Expect(notices[1], "[Subagent failed] reviewer subrun_new")
    }
}
