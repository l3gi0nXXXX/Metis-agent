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
