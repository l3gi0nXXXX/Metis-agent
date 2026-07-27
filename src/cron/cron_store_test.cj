package metis.cron

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

private func withCronStoreTestPath<T>(block: (Path) -> T): T {
    let root = Path("/tmp/metis-cron-store-test-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    try {
        remove(root, recursive: true)
    } catch (_: Exception) {
        ()
    }
    Directory.create(root, recursive: true)
    try {
        return block(root.join("cron").join("jobs.json"))
    } finally {
        try {
            remove(root, recursive: true)
        } catch (_: Exception) {
            ()
        }
    }
}

private func cronStoreTestJob(id: String): CronJob {
    CronJob(
        id,
        "hello cron",
        CronSchedule.every(60000),
        state: CronJobState(nextRunAtMs: 1),
        sessionTarget: "main",
        agentId: "general"
    )
}

private func cronTestPathModeOctal(path: Path): String {
    try {
        let (exitCode, stdoutBytes, _) = executeWithOutput("stat", ["-f", "%Lp", path.toString()])
        if (exitCode == 0) {
            return String.fromUtf8(stdoutBytes).trimAscii()
        }
    } catch (_: Exception) {
        ()
    }
    ""
}

@Test
public class CronStoreToolExecPolicyTest {
    @TestCase
    public func cronSaveLoadPersistsToolExecPolicyAndNormalizesAllowlist(): Unit {
        withCronStoreTestPath({ storePath =>
            cronSave(storePath, [
                CronJob(
                    "tool-policy",
                    "hello cron",
                    CronSchedule.every(60000),
                    toolExecMode: "allowlist",
                    toolExecAllowlist: ["curl", "curl", ""]
                )
            ])

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].toolExecMode, "allowlist")
            @Expect(jobs[0].toolExecAllowlist.size, 1)
            @Expect(jobs[0].toolExecAllowlist[0], "curl")
        })
    }

    @TestCase
    public func cronLoadDefaultsAndSanitizesToolExecPolicy(): Unit {
        withCronStoreTestPath({ storePath =>
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(
                storePath,
                ("{\"version\":1,\"jobs\":[" +
                    "{\"id\":\"legacy\",\"prompt\":\"hello\",\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}}," +
                    "{\"id\":\"explicit-deny\",\"prompt\":\"hello\",\"toolExecMode\":\"deny\",\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}}," +
                    "{\"id\":\"bad-mode\",\"prompt\":\"hello\",\"toolExecMode\":\"approve\",\"toolExecAllowlist\":[\"curl\",42,\"\",\"curl\"],\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}}" +
                    "]}").toArray()
            )

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 3)
            @Expect(jobs[0].toolExecMode, "guarded")
            @Expect(jobs[0].toolExecAllowlist.size, 0)
            @Expect(jobs[1].toolExecMode, "deny")
            @Expect(jobs[2].toolExecMode, "guarded")
            @Expect(jobs[2].toolExecAllowlist.size, 1)
            @Expect(jobs[2].toolExecAllowlist[0], "curl")
        })
    }

    @TestCase
    public func cronSaveLoadPersistsScriptFieldsAndSanitizesMode(): Unit {
        withCronStoreTestPath({ storePath =>
            cronSave(storePath, [
                CronJob(
                    "scripted",
                    "hello cron",
                    CronSchedule.every(60000),
                    scriptPath: "daily/report.sh",
                    scriptMode: "noAgent"
                )
            ])

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 1)
            @Expect(jobs[0].scriptPath, "daily/report.sh")
            @Expect(jobs[0].scriptMode, "noAgent")
        })
    }

    @TestCase
    public func cronLoadDefaultsAndSanitizesScriptFields(): Unit {
        withCronStoreTestPath({ storePath =>
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(
                storePath,
                ("{\"version\":1,\"jobs\":[" +
                    "{\"id\":\"legacy\",\"prompt\":\"hello\",\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}}," +
                    "{\"id\":\"bad-script-mode\",\"prompt\":\"hello\",\"scriptPath\":\"report.sh\",\"scriptMode\":\"approve\",\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}}" +
                    "]}").toArray()
            )

            let jobs = cronLoadOrEmpty(storePath)
            @Expect(jobs.size, 2)
            @Expect(jobs[0].scriptPath, "")
            @Expect(jobs[0].scriptMode, "none")
            @Expect(jobs[1].scriptPath, "report.sh")
            @Expect(jobs[1].scriptMode, "none")
        })
    }
}

@Test
public class CronRunLogDeliveryErrorTest {
    @TestCase
    public func runLogAppendReadIncludesDeliveryError(): Unit {
        withCronStoreTestPath({ storePath =>
            appendCronRunLog(
                storePath,
                "delivery-error",
                "success",
                1000,
                1010,
                summary: "agent ok",
                deliveryStatus: "not-delivered",
                deliveryError: "telegram send failed",
                diagnosticCode: "cron_tool_exec_blocked",
                diagnosticMessage: "code=cron_tool_exec_blocked reason=cron_headless_approval_required mode=deny allowlistCount=0"
            )

            let rows = readCronRunLogEntriesForJob(storePath, "delivery-error", limit: 10)
            @Expect(rows.get("total").getOrThrow().asInt().getValue(), 1)
            let row = rows.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(row.get("deliveryError").getOrThrow().asString().getValue(), "telegram send failed")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "cron_tool_exec_blocked")
            @Expect(row.get("diagnosticMessage").getOrThrow().asString().getValue().contains("mode=deny"), true)

            let merged = readCronRunLogMergedFromStore(storePath, ["delivery-error"], resultLimit: 10)
            let mergedRow = merged.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(mergedRow.get("deliveryError").getOrThrow().asString().getValue(), "telegram send failed")
            @Expect(mergedRow.get("diagnosticCode").getOrThrow().asString().getValue(), "cron_tool_exec_blocked")
        })
    }

    @TestCase
    public func runLogReadLegacyEntryDefaultsDeliveryErrorEmpty(): Unit {
        withCronStoreTestPath({ storePath =>
            let runsDir = cronRunsDirFromStore(storePath)
            Directory.create(runsDir, recursive: true)
            File.writeTo(
                runsDir.join("legacy-delivery.jsonl"),
                ("{\"ts\":1010,\"jobId\":\"legacy-delivery\",\"action\":\"finished\",\"status\":\"success\"," +
                    "\"summary\":\"old row\",\"runAtMs\":1000,\"startedAtMs\":1000,\"endedAtMs\":1010," +
                    "\"durationMs\":10,\"nextRunAtMs\":0,\"deliveryStatus\":\"not-delivered\"," +
                    "\"sessionTarget\":\"main\",\"error\":\"\"}\n").toArray()
            )

            let rows = readCronRunLogEntriesForJob(storePath, "legacy-delivery", limit: 10)
            @Expect(rows.get("total").getOrThrow().asInt().getValue(), 1)
            let row = rows.get("entries").getOrThrow().asArray()[0].asObject()
            @Expect(row.get("deliveryStatus").getOrThrow().asString().getValue(), "not-delivered")
            @Expect(row.get("deliveryError").getOrThrow().asString().getValue(), "")
            @Expect(row.get("diagnosticCode").getOrThrow().asString().getValue(), "")
            @Expect(row.get("diagnosticMessage").getOrThrow().asString().getValue(), "")
        })
    }
}

@Test
public class CronRunLogPathGuardTest {
    @TestCase
    public func runLogRejectsTraversalJobId(): Unit {
        withCronStoreTestPath({ storePath =>
            var threw = false
            try {
                appendCronRunLog(storePath, "../x", "success", 1000, 1001)
            } catch (e: Exception) {
                threw = e.message.contains("invalid cron run log job id")
            }
            @Expect(threw, true)
            @Expect(exists(storePath.parent.parent.join("x.jsonl")), false)
        })
    }
}

@Test
public class CronRunLogCorruptionTest {
    @TestCase
    public func runLogReadSkipsInvalidUtf8WithoutThrowing(): Unit {
        withCronStoreTestPath({ storePath =>
            let runsDir = cronRunsDirFromStore(storePath)
            Directory.create(runsDir, recursive: true)
            File.writeTo(runsDir.join("broken.jsonl"), Array<Byte>(3, { i => if (i == 1) { 40 } else { 195 } }))

            let rows = readCronRunLogEntriesForJob(storePath, "broken", limit: 10)
            @Expect(rows.get("total").getOrThrow().asInt().getValue(), 0)
            @Expect(rows.get("entries").getOrThrow().asArray().size(), 0)
        })
    }
}

@Test
public class CronRunLogPruneTest {
    @TestCase
    public func runLogAppendPrunesOldEntries(): Unit {
        withCronStoreTestPath({ storePath =>
            var i: Int64 = 0
            while (i < 3000) {
                appendCronRunLog(storePath, "pruned", "success", i, i + 1, summary: "row-${i}")
                i += 1
            }

            let rows = readCronRunLogEntriesForJob(storePath, "pruned", limit: 5000)
            @Expect(rows.get("total").getOrThrow().asInt().getValue(), 2000)
            let entries = rows.get("entries").getOrThrow().asArray()
            @Expect(entries.size(), 2000)
            @Expect(entries[0].asObject().get("summary").getOrThrow().asString().getValue(), "row-2999")
            @Expect(entries[1999].asObject().get("summary").getOrThrow().asString().getValue(), "row-1000")
        })
    }
}

@Test
public class CronRunLogConcurrencyTest {
    @TestCase
    public func runLogConcurrentAppendKeepsJsonLinesReadable(): Unit {
        withCronStoreTestPath({ storePath =>
            let futures = ArrayList<Future<Unit>>()
            var worker: Int64 = 0
            while (worker < 6) {
                let workerId = worker
                futures.add(spawn {
                    var i: Int64 = 0
                    while (i < 40) {
                        appendCronRunLog(
                            storePath,
                            "concurrent",
                            "success",
                            workerId * 1000 + i,
                            workerId * 1000 + i + 1,
                            summary: "w${workerId}-${i}"
                        )
                        i += 1
                    }
                })
                worker += 1
            }
            for (future in futures) {
                future.get()
            }

            let text = String.fromUtf8(File.readFrom(cronRunLogPathFromStore(storePath, "concurrent")))
            var lines: Int64 = 0
            for (line in text.split("\n")) {
                let trimmed = line.trimAscii()
                if (trimmed.isEmpty()) {
                    continue
                }
                let obj = JsonValue.fromStr(trimmed).asObject()
                @Expect(obj.get("jobId").getOrThrow().asString().getValue(), "concurrent")
                lines += 1
            }
            @Expect(lines, 240)
        })
    }
}

@Test
public class CronStorePermissionAndCorruptionTest {
    @TestCase
    public func cronStoreSaveUsesPrivateModesAndLoadDegradesCorruption(): Unit {
        withCronStoreTestPath({ storePath =>
            cronSave(storePath, [cronStoreTestJob("secure-store")])
            @Expect(cronTestPathModeOctal(storePath.parent), "700")
            @Expect(cronTestPathModeOctal(storePath), "600")
            @Expect(cronLoadOrEmpty(storePath).size, 1)

            File.writeTo(storePath, Array<Byte>(2, { i => if (i == 0) { 195 } else { 40 } }))
            @Expect(cronLoadOrEmpty(storePath).size, 0)

            File.writeTo(storePath, "{not-json".toArray())
            @Expect(cronLoadOrEmpty(storePath).size, 0)
        })
    }
}

@Test
public class CronExecutionJournalSchemaTest {
    /** M1-B2: scheduler cursor uses the same stable `(nextRunAtMs, jobId)` ordering as due-job selection. */
    @TestCase
    public func schedulerCursorIsDeterministicallyComparable(): Unit {
        @Expect(
            cronCompareSchedulerCursor(
                CronSchedulerCursor(nextRunAtMs: 100, jobId: "z"),
                CronSchedulerCursor(nextRunAtMs: 101, jobId: "a")
            ),
            -1
        )
        @Expect(
            cronCompareSchedulerCursor(
                CronSchedulerCursor(nextRunAtMs: 100, jobId: "a"),
                CronSchedulerCursor(nextRunAtMs: 100, jobId: "b")
            ),
            -1
        )
        @Expect(
            cronCompareSchedulerCursor(
                CronSchedulerCursor(nextRunAtMs: 100, jobId: "a"),
                CronSchedulerCursor(nextRunAtMs: 100, jobId: "a")
            ),
            0
        )
    }

    /** M1-N2/M2-B2: rejected and repeated journal transitions never partially mutate durable state. */
    @TestCase
    public func journalTransitionIsMonotonicAtomicAndIdempotent(): Unit {
        let entry = CronExecutionJournalEntry(
            "exec-1",
            "job-1",
            phase: "executing",
            reservedAtMs: 10,
            updatedAtMs: 20
        )
        @Expect(entry.transition("executing", 30), false)
        @Expect(entry.phase, "executing")
        @Expect(entry.updatedAtMs, 20)

        var rejected = false
        try {
            entry.transition("reserved", 40)
        } catch (_: Exception) {
            rejected = true
        }
        @Expect(rejected, true)
        @Expect(entry.phase, "executing")
        @Expect(entry.updatedAtMs, 20)

        @Expect(entry.transition("result_committed", 50), true)
        @Expect(entry.phase, "result_committed")
        @Expect(entry.updatedAtMs, 50)
    }

    /** M2-B2: legacy schema defaults reservation/journal fields without losing the old job. */
    @TestCase
    public func legacyStoreDefaultsExecutionFieldsAndEmptyJournal(): Unit {
        withCronStoreTestPath({ storePath =>
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(
                storePath,
                ("{\"version\":1,\"jobs\":[{\"id\":\"legacy\",\"prompt\":\"hello\"," +
                    "\"schedule\":{\"kind\":\"every\",\"everyMs\":60000}," +
                    "\"state\":{\"nextRunAtMs\":123}}]}").toArray()
            )

            let store = cronLoadStoreOrEmpty(storePath)
            @Expect(store.jobs.size, 1)
            @Expect(store.jobs[0].state.executionId, "")
            @Expect(store.jobs[0].state.executionStartedAtMs, 0)
            @Expect(store.jobs[0].state.executionHeartbeatAtMs, 0)
            @Expect(store.scheduler.fairnessCursor.jobId, "")
            @Expect(store.journal.size, 0)
        })
    }

    /** M2-B2/REV-03/REV-04: jobs, cursor, journal marker and all receipt states share one snapshot. */
    @TestCase
    public func envelopeRoundTripPersistsJournalCursorAndDeliveryReceipts(): Unit {
        withCronStoreTestPath({ storePath =>
            let job = cronStoreTestJob("durable")
            job.state.executionId = "exec-durable"
            job.state.executionStartedAtMs = 100
            job.state.executionHeartbeatAtMs = 110
            let statuses = ["not_started", "in_flight", "succeeded", "failed", "unknown"]
            let receipts = ArrayList<CronDeliveryReceipt>()
            var index: Int64 = 0
            for (status in statuses) {
                receipts.add(
                    CronDeliveryReceipt(
                        "target-${index}",
                        status: status,
                        updatedAtMs: 200 + index,
                        errorCode: if (status == "failed") { "send_failed" } else { "" }
                    )
                )
                index += 1
            }
            let journal = CronExecutionJournalEntry(
                "exec-durable",
                "durable",
                phase: "result_committed",
                reservedAtMs: 100,
                updatedAtMs: 200,
                businessOutcomeHash: "sha256:result",
                runLogRecorded: true,
                deliveryReceipts: receipts.toArray()
            )
            cronSaveStoreAtomic(
                storePath,
                CronStoreEnvelope(
                    jobs: [job],
                    scheduler: CronSchedulerMetadata(
                        fairnessCursor: CronSchedulerCursor(nextRunAtMs: 123, jobId: "durable")
                    ),
                    journal: [journal]
                )
            )

            let loaded = cronLoadStoreOrEmpty(storePath)
            @Expect(loaded.jobs[0].state.executionId, "exec-durable")
            @Expect(loaded.jobs[0].state.executionStartedAtMs, 100)
            @Expect(loaded.jobs[0].state.executionHeartbeatAtMs, 110)
            @Expect(loaded.scheduler.fairnessCursor.nextRunAtMs, 123)
            @Expect(loaded.scheduler.fairnessCursor.jobId, "durable")
            @Expect(loaded.journal.size, 1)
            @Expect(loaded.journal[0].phase, "result_committed")
            @Expect(loaded.journal[0].businessOutcomeHash, "sha256:result")
            @Expect(loaded.journal[0].runLogRecorded, true)
            @Expect(loaded.journal[0].deliveryReceipts.size, 5)
            index = 0
            for (status in statuses) {
                @Expect(loaded.journal[0].deliveryReceipts[index].status, status)
                index += 1
            }

            let journalJson = JsonValue.fromStr(String.fromUtf8(File.readFrom(storePath)))
                .asObject()
                .get("executionJournal")
                .getOrThrow()
                .toJsonString()
            @Expect(journalJson.contains("hello cron"), false)
            @Expect(journalJson.contains("token"), false)
            @Expect(journalJson.contains("payload"), false)
        })
    }

    /** M2-B2: legacy cronSave callers preserve scheduler/journal and unknown root metadata. */
    @TestCase
    public func ordinaryCronSavePreservesEnvelopeMetadataAndUnknownFields(): Unit {
        withCronStoreTestPath({ storePath =>
            Directory.create(storePath.parent, recursive: true)
            File.writeTo(
                storePath,
                ("{\"version\":1,\"futureMetadata\":{\"owner\":\"future\"}," +
                    "\"scheduler\":{\"fairnessCursor\":{\"nextRunAtMs\":9,\"jobId\":\"old\"}," +
                    "\"futureSchedulerField\":\"keep\"}," +
                    "\"executionJournal\":[{\"executionId\":\"exec-old\",\"jobId\":\"old\"," +
                    "\"phase\":\"reserved\",\"reservedAtMs\":1,\"updatedAtMs\":1," +
                    "\"businessOutcomeHash\":\"\",\"runLogRecorded\":false,\"deliveryReceipts\":[]}]," +
                    "\"jobs\":[]}").toArray()
            )

            cronSave(storePath, [cronStoreTestJob("new-job")])

            let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(storePath))).asObject()
            @Expect(
                root.get("futureMetadata").getOrThrow().asObject()
                    .get("owner").getOrThrow().asString().getValue(),
                "future"
            )
            let loaded = cronLoadStoreOrEmpty(storePath)
            @Expect(loaded.jobs.size, 1)
            @Expect(loaded.scheduler.fairnessCursor.jobId, "old")
            @Expect(loaded.journal.size, 1)
            @Expect(loaded.journal[0].executionId, "exec-old")

            cronSaveStoreAtomic(storePath, loaded)
            let afterEnvelopeSave = JsonValue.fromStr(String.fromUtf8(File.readFrom(storePath))).asObject()
            @Expect(
                afterEnvelopeSave.get("scheduler").getOrThrow().asObject()
                    .get("futureSchedulerField").getOrThrow().asString().getValue(),
                "keep"
            )
        })
    }
}
