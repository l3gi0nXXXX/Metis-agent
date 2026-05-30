package metis.gateway.service_plugin

import std.fs.{File, Path}
import std.unittest.testmacro.*

@Test
public class ServicePluginJobContractTest {
    private func fixture(name: String): String {
        String.fromUtf8(File.readFrom(Path("test").join("fixtures").join("service_plugin").join("job_protocol").join(name))).trimAscii()
    }

    @TestCase
    public func jobProtocolFixturesDecodeAndValidateAsyncScanLifecycle(): Unit {
        let doc = String.fromUtf8(File.readFrom(Path("docs").join("service-plugin-job-protocol.md")))
        @Expect(doc.contains("accepted -> running -> progress* -> completed|failed|cancelled|expired"), true)
        @Expect(doc.contains("raw JSON"), true)

        let startFrame = decodeServiceFrame(this.fixture("scan_start_async_request.jsonl"))
        @Expect(startFrame.ok, true)
        let start = parseServicePluginJobStartPayload(startFrame.frame.payload)
        @Expect(start.ok, true)
        @Expect(start.payload.mode, "async")
        @Expect(start.payload.jobId, "gcm-scan-20260530-095017-0001")
        @Expect(start.payload.deliveryTarget.channel, "telegram")
        @Expect(start.payload.deliveryTarget.peerId, "internal-peer-24")
        @Expect(start.payload.limits.maxRepos, 0)
        @Expect(start.payload.limits.maxItems, 0)
        @Expect(start.payload.limits.maxDurationMillis, 0)

        let acceptedFrame = decodeServiceFrame(this.fixture("scan_accepted_response.jsonl"))
        @Expect(acceptedFrame.ok, true)
        let accepted = parseServicePluginJobAcceptedPayload(acceptedFrame.frame.payload, expectedJobId: start.payload.jobId)
        @Expect(accepted.ok, true)
        @Expect(accepted.payload.status, "accepted")
        @Expect(accepted.payload.jobId, start.payload.jobId)

        let completedFrame = decodeServiceFrame(this.fixture("scan_completed_event.jsonl"))
        @Expect(completedFrame.ok, true)
        let completed = parseServicePluginJobEventPayload(completedFrame.frame.capabilityId, completedFrame.frame.payload)
        @Expect(completed.ok, true)
        @Expect(completed.payload.status, "completed")
        @Expect(completed.payload.accepted, 12)

        let failedFrame = decodeServiceFrame(this.fixture("scan_failed_event.jsonl"))
        @Expect(failedFrame.ok, true)
        let failed = parseServicePluginJobEventPayload(failedFrame.frame.capabilityId, failedFrame.frame.payload)
        @Expect(failed.ok, true)
        @Expect(failed.payload.status, "failed")
        @Expect(failed.payload.errorKind, "gitcode_timeout")
    }

    @TestCase
    public func jobPayloadValidationRejectsInvalidFieldsAndMismatchedCapability(): Unit {
        let missingJob = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"\",\"idempotencyKey\":\"k\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":\"p\"}}")
        @Expect(missingJob.ok, false)
        @Expect(missingJob.status, "job_payload_invalid")

        let badPeerType = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"j\",\"idempotencyKey\":\"k\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":42}}")
        @Expect(badPeerType.ok, false)
        @Expect(badPeerType.diagnostic.contains("peerId"), true)

        var longJob = ""
        for (_ in 0..129) { longJob += "x" }
        let tooLong = parseServicePluginJobAcceptedPayload("{\"ok\":true,\"status\":\"accepted\",\"jobId\":\"${longJob}\"}")
        @Expect(tooLong.ok, false)
        @Expect(tooLong.status, "job_payload_invalid")

        let mismatch = parseServicePluginJobEventPayload("gitcode.monitor.scan_failed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"j\"}")
        @Expect(mismatch.ok, false)
        @Expect(mismatch.status, "event_payload_invalid")

        let diagnostic = parseServicePluginJobEventPayload("gitcode.monitor.scan_failed", "{\"ok\":false,\"status\":\"failed\",\"jobId\":\"j\",\"diagnostic\":\"/Users/name/private token=secret\"}")
        @Expect(diagnostic.ok, true)
        let message = renderServicePluginJobEventMessage(diagnostic.payload)
        @Expect(message.contains("secret"), false)
        @Expect(message.contains("/Users/"), false)

        let missingLimits = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"j\",\"idempotencyKey\":\"k\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":\"p\"}}")
        @Expect(missingLimits.ok, true)
        @Expect(missingLimits.payload.limits.maxRepos, 0)
        @Expect(missingLimits.payload.limits.maxItems, 0)
        @Expect(missingLimits.payload.limits.maxDurationMillis, 0)

        let missingDuration = parseServicePluginJobStartPayload("{\"ok\":true,\"mode\":\"async\",\"jobId\":\"j2\",\"idempotencyKey\":\"k2\",\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"a\",\"peerId\":\"p\"},\"limits\":{\"maxRepos\":0,\"maxItems\":0}}")
        @Expect(missingDuration.ok, true)
        @Expect(missingDuration.payload.limits.maxDurationMillis, 0)
    }

    @TestCase
    public func completedScanReportRendersDuplicateSamplesDryRunAndNoRawJson(): Unit {
        let payload = "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-1\",\"accepted\":0,\"ignored\":0,\"emitted\":0,\"durationMs\":28800,\"stateSaved\":true,\"report\":{\"orgs\":[\"cangjie\",\"cangjie-sig\"],\"stopReason\":\"completed\",\"limits\":{\"maxRepos\":1,\"maxItems\":30,\"timeoutMillis\":60000},\"scannedRepos\":1,\"checkedItems\":31,\"newEvents\":0,\"duplicateEvents\":31,\"filteredEvents\":0,\"failedEvents\":0,\"draftsGenerated\":0,\"draftsFailed\":0,\"notificationsSent\":0,\"writes\":0,\"writeMode\":\"dry_run\",\"samples\":{\"duplicate\":[{\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":70,\"reason\":\"seen\"},{\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":69,\"reason\":\"seen\"}]}}}"
        let parsed = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", payload)
        @Expect(parsed.ok, true)
        let text = renderServicePluginJobEventMessage(parsed.payload)
        @Expect(text.contains("GitCode 扫描完成"), true)
        @Expect(text.contains("范围: orgs=cangjie,cangjie-sig maxRepos=1 maxItems=30"), true)
        @Expect(text.contains("timeout=60s"), false)
        @Expect(text.contains("停止原因"), false)
        @Expect(text.contains("扫描: 仓库 1 个，候选 PR/Issue/comment 31 条"), true)
        @Expect(text.contains("结果: 新增 0 条，重复 31 条，过滤 0 条，失败 0 条"), true)
        @Expect(text.contains("本次没有新增未处理事件，因此未生成新回复"), true)
        @Expect(text.contains("写回: dryRun=true，未写回 GitCode。"), true)
        @Expect(text.contains("最近重复事件:"), true)
        @Expect(text.contains("cangjie/community PR #70 - seen"), true)
        @Expect(text.contains("还有 29 条重复事件未展示"), true)
        @Expect(text.contains("\"ok\""), false)
        @Expect(text.contains("\"result\""), false)
        @Expect(text.contains("\"payload\""), false)
    }

    @TestCase
    public func completedScanReportRendersOnlyExplicitStopReasons(): Unit {
        let completed = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-stop-0\",\"report\":{\"orgs\":[\"cangjie\"],\"stopReason\":\"completed\",\"limits\":{\"maxRepos\":0,\"maxItems\":0,\"timeoutMillis\":30000},\"scannedRepos\":6,\"checkedItems\":36,\"newEvents\":0,\"writeMode\":\"dry_run\"}}")
        @Expect(completed.ok, true)
        let completedText = renderServicePluginJobEventMessage(completed.payload)
        @Expect(completedText.contains("范围: orgs=cangjie"), true)
        @Expect(completedText.contains("maxRepos=5"), false)
        @Expect(completedText.contains("maxItems=30"), false)
        @Expect(completedText.contains("timeout="), false)
        @Expect(completedText.contains("停止原因"), false)

        let maxRepos = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-stop-1\",\"report\":{\"orgs\":[\"cangjie\"],\"stopReason\":\"max_repos_reached\",\"limits\":{\"maxRepos\":2,\"maxItems\":0},\"scannedRepos\":2,\"checkedItems\":12,\"newEvents\":0,\"writeMode\":\"dry_run\"}}")
        @Expect(maxRepos.ok, true)
        let maxReposText = renderServicePluginJobEventMessage(maxRepos.payload)
        @Expect(maxReposText.contains("停止原因: 达到用户设置的 maxRepos=2"), true)
        @Expect(maxReposText.contains("\"stopReason\""), false)

        let maxItems = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-stop-2\",\"report\":{\"orgs\":[\"cangjie\"],\"stopReason\":\"max_items_reached\",\"limits\":{\"maxRepos\":0,\"maxItems\":30},\"scannedRepos\":2,\"checkedItems\":30,\"newEvents\":0,\"writeMode\":\"dry_run\"}}")
        @Expect(maxItems.ok, true)
        let maxItemsText = renderServicePluginJobEventMessage(maxItems.payload)
        @Expect(maxItemsText.contains("停止原因: 达到用户设置的 maxItems=30"), true)
        @Expect(maxItemsText.contains("timeout"), false)

        let unknown = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-stop-3\",\"report\":{\"stopReason\":\"future_reason\",\"scannedRepos\":1,\"checkedItems\":1,\"newEvents\":0,\"writeMode\":\"dry_run\"}}")
        @Expect(unknown.ok, true)
        let unknownText = renderServicePluginJobEventMessage(unknown.payload)
        @Expect(unknownText.contains("停止原因: future_reason"), true)
        @Expect(unknownText.contains("{"), false)
    }

    @TestCase
    public func completedScanReportRendersNewPrSourceUrlDraftStatusAndTruncates(): Unit {
        let payload = "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-2\",\"durationMs\":31200,\"report\":{\"orgs\":[\"cangjie\"],\"scannedRepos\":3,\"checkedItems\":42,\"newEvents\":6,\"duplicateEvents\":38,\"filteredEvents\":2,\"failedEvents\":0,\"draftsGenerated\":1,\"draftsFailed\":1,\"notificationsSent\":1,\"writes\":0,\"writeMode\":\"dry_run\",\"samples\":{\"new\":[{\"eventId\":\"e1\",\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":71,\"title\":\"修复 xxx\",\"url\":\"https://gitcode.com/cangjie/community/pulls/71\",\"status\":\"draft_generated\",\"notification\":\"telegram:sent\",\"writeback\":\"dry_run\"},{\"eventId\":\"e2\",\"repo\":\"cangjie/community\",\"kind\":\"issue\",\"number\":102,\"title\":\"讨论 yyy\",\"url\":\"\",\"status\":\"needsHumanReview\",\"reason\":\"CKB unavailable\",\"notification\":\"notification_failed\",\"writeback\":\"write_skipped_dry_run\"},{\"repo\":\"r\",\"kind\":\"pr\",\"number\":3,\"title\":\"t\",\"url\":\"u\"},{\"repo\":\"r\",\"kind\":\"pr\",\"number\":4,\"title\":\"t\",\"url\":\"u\"},{\"repo\":\"r\",\"kind\":\"pr\",\"number\":5,\"title\":\"t\",\"url\":\"u\"},{\"repo\":\"r\",\"kind\":\"pr\",\"number\":6,\"title\":\"t\",\"url\":\"u\"}]}}}"
        let parsed = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", payload)
        @Expect(parsed.ok, true)
        let text = renderServicePluginJobEventMessage(parsed.payload)
        @Expect(text.contains("回复: 已生成草稿 1 条，需人工确认 1 条，生成失败 1 条"), true)
        @Expect(text.contains("通知: 已发送 1 条"), true)
        @Expect(text.contains("来源: cangjie/community PR #71 https://gitcode.com/cangjie/community/pulls/71"), true)
        @Expect(text.contains("标题: 修复 xxx"), true)
        @Expect(text.contains("状态: 已生成回复草稿"), true)
        @Expect(text.contains("来源: cangjie/community Issue #102 链接: unavailable"), true)
        @Expect(text.contains("状态: needsHumanReview"), true)
        @Expect(text.contains("原因: CKB unavailable"), true)
        @Expect(text.contains("还有 1 条新增事件未展示"), true)
    }

    @TestCase
    public func malformedReportFallsBackAndSecretsAreRedacted(): Unit {
        let malformed = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-3\",\"accepted\":0,\"ignored\":0,\"emitted\":0,\"report\":\"bad\"}")
        @Expect(malformed.ok, true)
        let fallback = renderServicePluginJobEventMessage(malformed.payload)
        @Expect(fallback.contains("当前 GCM 未返回扫描明细"), true)
        @Expect(fallback.contains("accepted=0 ignored=0 emitted=0"), true)

        let secret = parseServicePluginJobEventPayload("gitcode.monitor.scan_completed", "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-4\",\"report\":{\"scannedRepos\":1,\"checkedItems\":1,\"newEvents\":1,\"samples\":{\"new\":[{\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":1,\"title\":\"token=should-not-leak\",\"url\":\"https://gitcode.com/cangjie/community/pulls/1?cookie=bad\",\"status\":\"draft_generated\"}]}}}")
        @Expect(secret.ok, true)
        let text = renderServicePluginJobEventMessage(secret.payload)
        @Expect(text.contains("should-not-leak"), false)
        @Expect(text.contains("cookie=bad"), false)
        @Expect(text.contains("[REDACTED]"), true)
    }

    @TestCase
    public func jobStatusSnapshotUsesSameReportRenderer(): Unit {
        let payload = "{\"ok\":true,\"status\":\"completed\",\"jobId\":\"gcm-scan-5\",\"report\":{\"orgs\":[\"cangjie\"],\"scannedRepos\":1,\"checkedItems\":31,\"newEvents\":0,\"duplicateEvents\":31,\"writeMode\":\"dry_run\",\"samples\":{\"duplicate\":[{\"repo\":\"cangjie/community\",\"kind\":\"pr\",\"number\":70,\"reason\":\"seen\"}]}}}"
        let text = renderServicePluginJobSnapshotMessage(payload, fallbackJobId: "fallback")
        @Expect(text.contains("GitCode 扫描完成"), true)
        @Expect(text.contains("scanId: gcm-scan-5"), true)
        @Expect(text.contains("重复 31 条"), true)

        let running = renderServicePluginJobSnapshotMessage("{\"ok\":true,\"status\":\"running\",\"jobId\":\"gcm-scan-6\",\"stage\":\"scan_repo\",\"report\":{\"scannedRepos\":2,\"checkedItems\":9}}", fallbackJobId: "fallback")
        @Expect(running.contains("GitCode 扫描状态"), true)
        @Expect(running.contains("scanId=gcm-scan-6"), true)
        @Expect(running.contains("已扫描仓库 2 个"), true)
        @Expect(running.contains("候选事件 9 条"), true)
    }
}
