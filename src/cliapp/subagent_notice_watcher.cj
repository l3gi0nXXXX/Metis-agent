package metis.cliapp

import magic.log.LogUtils

import metis.gateway.runtime.{gatewayCliClient, gatewayEnsureSubagentNoticeEventPublisherRegistered}
import metis.io.PrintUtils

import std.collection.ArrayList
import std.sync.AtomicBool
import stdx.encoding.json.{JsonArray, JsonObject, JsonValue}

private let CLI_SUBAGENT_NOTICE_EVENT_KIND = "session.subagent.notice"

private func cliNoticeJsonString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_e: Exception) { "" }
        case None => ""
    }
}

private func cliSubagentNoticeEventPayload(event: JsonObject): Option<JsonObject> {
    match (event.get("payload")) {
        case Some(v) =>
            try { Some(v.asObject()) } catch (_e: Exception) { None<JsonObject> }
        case None => None<JsonObject>
    }
}

public func cliSubagentNoticeFromGatewayEvent(event: JsonObject): Option<String> {
    if (cliNoticeJsonString(event, "kind") != CLI_SUBAGENT_NOTICE_EVENT_KIND) {
        return None<String>
    }
    let payload = match (cliSubagentNoticeEventPayload(event)) {
        case Some(v) => v
        case None => return None<String>
    }
    let notice = cliNoticeJsonString(payload, "notice")
    if (!notice.trimAscii().isEmpty()) {
        return Some(notice)
    }
    let text = cliNoticeJsonString(payload, "text")
    if (!text.trimAscii().isEmpty()) {
        return Some(text)
    }
    None<String>
}

public func cliSubagentNoticeGatewayEventSessionKey(event: JsonObject): String {
    let payload = match (cliSubagentNoticeEventPayload(event)) {
        case Some(v) => v
        case None => return ""
    }
    cliNoticeJsonString(payload, "sessionKey").trimAscii()
}

public func cliSubagentNoticeEventMatchesSession(event: JsonObject, sessionKey: String): Bool {
    let eventSessionKey = cliSubagentNoticeGatewayEventSessionKey(event)
    let expected = sessionKey.trimAscii()
    eventSessionKey == expected || (expected == "main" && eventSessionKey == "agent:general:main")
}

public func cliSubagentNoticesFromGatewayStreamResult(result: JsonValue, sessionKey: String): Array<String> {
    let notices = ArrayList<String>()
    try {
        let root = result.asObject()
        let pull = match (root.get("pull")) {
            case Some(v) => try { v.asObject() } catch (_inner: Exception) { JsonObject() }
            case None => JsonObject()
        }
        let events = match (pull.get("events")) {
            case Some(v) => try { v.asArray() } catch (_inner: Exception) { JsonArray([]) }
            case None => JsonArray([])
        }
        var i: Int64 = 0
        while (i < Int64(events.size())) {
            try {
                let event = events[i].asObject()
                if (cliSubagentNoticeEventMatchesSession(event, sessionKey)) {
                    match (cliSubagentNoticeFromGatewayEvent(event)) {
                        case Some(notice) => notices.add(notice)
                        case None => ()
                    }
                }
            } catch (_inner: Exception) {
                ()
            }
            i += 1
        }
    } catch (_e: Exception) {
        ()
    }
    notices.toArray()
}

protected class CliSubagentNoticeWatcher {
    private let sessionKey: String
    private let stopRequested = AtomicBool(false)
    private var future: Option<Future<Unit>> = None

    init(sessionKey: String) {
        this.sessionKey = sessionKey.trimAscii()
        gatewayEnsureSubagentNoticeEventPublisherRegistered()
    }

    func start(): Unit {
        if (this.future.isSome()) {
            return
        }
        this.future = spawn {
            while (!this.stopRequested.load() && !Thread.currentThread.hasPendingCancellation) {
                this.pollOnce()
                sleep(Duration.millisecond * 700)
            }
        }
    }

    func stop(): Unit {
        this.stopRequested.store(true)
        if (let Some(f) <- this.future) {
            f.cancel()
        }
    }

    private func pollOnce(): Unit {
        try {
            let response = gatewayCliClient().streamEvents(
                limit: 8,
                waitMs: 700,
                eventKinds: [CLI_SUBAGENT_NOTICE_EVENT_KIND]
            )
            if (!response.ok) {
                LogUtils.debug("CLI subagent notice gateway stream failed: ${response.error}")
                return
            }
            let notices = cliSubagentNoticesFromGatewayStreamResult(response.result, this.sessionKey)
            for (notice in notices) {
                this.printNotice(notice)
            }
        } catch (e: Exception) {
            LogUtils.debug("CLI subagent notice gateway stream poll failed: ${e.message}")
        }
    }

    private func printNotice(notice: String): Unit {
        PrintUtils.printLine("")
        PrintUtils.printLine(PrintUtils.renderAssistantResponseBox(notice))
        PrintUtils.printLine("")
    }
}

protected func startCliSubagentNoticeWatcher(): CliSubagentNoticeWatcher {
    let watcher = CliSubagentNoticeWatcher("main")
    watcher.start()
    watcher
}
