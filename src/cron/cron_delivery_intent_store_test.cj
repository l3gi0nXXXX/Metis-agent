package metis.cron

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func withCronDeliveryIntentRoot<T>(block: (Path) -> T): T {
    let root = Path("/tmp/metis-cron-intent-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root.join("cron"), recursive: true)
    let store = root.join("cron").join("jobs.json")
    try {
        block(store)
    } finally {
        try { remove(root, recursive: true) } catch (_: Exception) { () }
    }
}

private func cronIntentArtifact(answer!: String = "完成：中文🙂"): CronDeliveryIntentArtifact {
    CronDeliveryIntentArtifact(
        "job:1:2",
        "job",
        answer,
        "announce",
        "feishu",
        "peer-id",
        "account",
        2,
        false
    )
}

@Test
public class CronDeliveryIntentStoreTest {
    @TestCase
    public func m3B2ArtifactRoundTripIsAtomicUtf8AndPathSafe(): Unit {
        withCronDeliveryIntentRoot({ store =>
            let ref = saveCronDeliveryIntentArtifact(store, cronIntentArtifact())
            @Expect(ref.contains("/"), false)
            @Expect(ref.contains("job:1:2"), false)
            let loaded = loadCronDeliveryIntentArtifact(store, ref, expectedExecutionId: "job:1:2")
            @Expect(loaded.ok, true)
            @Expect(loaded.artifact.getOrThrow().answer, "完成：中文🙂")
            @Expect(exists(cronDeliveryIntentPath(store, ref)), true)
            @Expect(deleteCronDeliveryIntentArtifact(store, ref), true)
            @Expect(exists(cronDeliveryIntentPath(store, ref)), false)
        })
    }

    @TestCase
    public func m3N3MalformedJsonInvalidUtf8IdentityAndSensitivePayloadAreIsolated(): Unit {
        withCronDeliveryIntentRoot({ store =>
            let ref = saveCronDeliveryIntentArtifact(store, cronIntentArtifact())
            @Expect(loadCronDeliveryIntentArtifact(store, ref, expectedExecutionId: "other").status, "identity_mismatch")
            File.writeTo(cronDeliveryIntentPath(store, ref), "{bad-json".toArray())
            @Expect(loadCronDeliveryIntentArtifact(store, ref).status, "malformed_json")
            File.writeTo(cronDeliveryIntentPath(store, ref), Array<Byte>(2, { i => if (i == 0) { 195 } else { 40 } }))
            @Expect(loadCronDeliveryIntentArtifact(store, ref).status, "invalid_response_encoding")
            @Expect(loadCronDeliveryIntentArtifact(store, "../secret").status, "invalid_artifact_ref")
            var rejected = false
            try {
                let _ = saveCronDeliveryIntentArtifact(store, cronIntentArtifact(answer: "Authorization: Bearer secret-token"))
            } catch (_: Exception) {
                rejected = true
            }
            @Expect(rejected, true)
        })
    }
}
