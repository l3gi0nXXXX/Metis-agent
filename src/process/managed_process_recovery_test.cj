package metis.process

import std.env.{getVariable, setVariable, removeVariable}
import std.env.getVariables
import std.collection.{ArrayList, HashMap}
import std.fs.{Directory, File, Path, exists, remove}
import std.process.{SubProcess, ProcessRedirect, launch}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

private func recoveryTestHome(action: (Path, String) -> Unit): Unit {
    let home = Path("/private/tmp/metis-recovery-process-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    try {
        @Expect(managedRecoveryInitialize(home, parent, "fixture-parent"), true)
        action(home, parent)
    } finally {
        match (oldDirectory) {
            case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value)
            case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        }
        match (oldParent) {
            case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value)
            case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT")
        }
        // A returned callback does not prove every soft assertion or child cleanup.
        // Retain the owned journal for formal verification and root-owned cleanup.
    }
}

private func recoveryLaunchAttachedFixture(home: Path, parent: String, key: String, command: String, args: Array<String>): SubProcess {
    let environment = HashMap<String, String>()
    for ((name, value) in getVariables()) { environment[name] = value }
    environment["METIS_PROCESS_RECOVERY_DIRECTORY"] = home.toString()
    environment["METIS_PROCESS_RECOVERY_PARENT"] = parent
    environment["METIS_PROCESS_RECOVERY_BROKER_KEY"] = key
    let wrapped = ArrayList<String>()
    wrapped.add(managedStdioResolveBrokerScriptPath()); wrapped.add("--attached"); wrapped.add(command)
    for (arg in args) { wrapped.add(arg) }
    launch("node", wrapped.toArray(), environment: environment, stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Discard, stdErr: ProcessRedirect.Discard)
}

@When[os == "macOS"]
@Test
public class ManagedProcessRecoveryTest {
    @TestCase
    public func rS1U1TerminalFactsAreImmutableAndIdempotent(): Unit {
        recoveryTestHome({ home, parent =>
            @Expect(managedRecoveryPublishFact(home, "b-1-o-1", "intent", parent), true)
            @Expect(managedRecoveryPublishFact(home, "b-1-o-1", "spawned", parent, pid: 987654, pgid: 987654), true)
            @Expect(managedRecoveryPublishFact(home, "b-1-o-1", "terminal", parent, pid: 987654, pgid: 987654), true)
            @Expect(managedRecoveryPublishFact(home, "b-1-o-1", "terminal", parent, pid: 987654, pgid: 987654), true)
            @Expect(managedRecoveryPublishFact(home, "b-1-o-1", "terminal", parent, pid: 987655, pgid: 987655), false)
            let observed = managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second)
            @Expect(observed.terminal, true)
            @Expect(observed.count, 1)
            @Expect(observed.original.contains("payload"), false)
        })
    }

    @TestCase
    public func rS1B1IntentWithoutSpawnNeverMeansTerminal(): Unit {
        recoveryTestHome({ home, parent =>
            @Expect(managedRecoveryPublishFact(home, "before-spawn", "intent", parent), true)
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).status,
                "resource_intent_incomplete")
            let publishing = home.join("before-spawn.spawned")
            File.writeTo(publishing, Array<UInt8>(0, repeat: 0))
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).status, "inventory_changing")
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now()).terminal, false)
            File.writeTo(publishing, "managed-recovery-v1\nkey:before-spawn\nphase:spawned\nparent:${parent}\npid:987654\npgid:987654\nbirth:\n".toArray())
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).status,
                "resource_identity_unknown")
        })
    }

    @TestCase
    public func rS1N1StrictTextRejectsUnicodeCorruptionAndOversize(): Unit {
        recoveryTestHome({ home, parent =>
            @Expect(managedRecoveryParseFields("managed-recovery-v1\n中文😀:value\n").isNone(), true)
            @Expect(managedRecoveryParseFields("managed-recovery-v1\nkey:a\nkey:b\n").isNone(), true)
            @Expect(managedRecoverySafeKey("中文😀"), false)
            @Expect(managedRecoverySafeKey("../escape"), false)
            let binary = home.join("bad.intent")
            File.writeTo(binary, [0xffu8, 0xfeu8])
            @Expect(managedRecoveryReadText(binary).isNone(), true)
            remove(binary)
            File.writeTo(home.join("unknown-name"), Array<UInt8>(0, repeat: 0))
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).status, "inventory_invalid")
            remove(home.join("unknown-name"))
            Directory.create(home.join("wrong-type.intent"))
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).status, "inventory_invalid")
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).terminal, false)
            File.writeTo(binary, Array<UInt8>(1048576, repeat: 65))
            @Expect(managedRecoveryReadText(binary).isNone(), true)
        })
    }

    @TestCase
    public func rS0N1NoPortAliveResourceCannotBeTerminal(): Unit {
        recoveryTestHome({ home, parent =>
            let pid = currentProcessInstanceIdentity().getOrThrow().pid
            let birth = observeProcessBirthIdentity(pid).getOrThrow()
            @Expect(managedRecoveryPublishFact(home, "alive-no-port", "intent", parent), true)
            @Expect(managedRecoveryPublishFact(home, "alive-no-port", "spawned", parent, pid: pid), true)
            @Expect(managedRecoveryPublishFact(home, "alive-no-port", "birth", parent, pid: pid, birth: birth.serialize()), true)
            let observed = managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second)
            @Expect(observed.terminal, false)
            @Expect(observed.status, "resource_alive")
        })
    }

    @TestCase
    public func rS2B1ClaimSerializesAndReleasesWithoutDeletingInode(): Unit {
        recoveryTestHome({ home, _ =>
            let path = home.join("mutation-claim")
            let first = acquireProcessFileClaim(path, MonoTime.now() + Duration.second)
            @Expect(first.ok, true)
            try {
                let blocked = acquireProcessFileClaim(path, MonoTime.now() + Duration.millisecond * 30)
                @Expect(blocked.ok, false)
                blocked.release()
            } finally { first.release() }
            @Expect(exists(path), true)
            let next = acquireProcessFileClaim(path, MonoTime.now() + Duration.second)
            @Expect(next.ok, true)
            next.release()
            remove(path)
        })
    }

    @TestCase
    public func rS0B1LegacyInventoryMissingIsExplicit(): Unit {
        let missing = Path("/tmp/metis-recovery-missing-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        @Expect(managedRecoveryProbeRecords(missing, "parent", "nonce", MonoTime.now() + Duration.second).status,
            "legacy_inventory_missing")
        @Expect(parseProcessBirthIdentity("123:1:1000000").isNone(), true)
        @Expect(parseProcessBirthIdentity("123:0:0").isNone(), true)
        @Expect(parseProcessBirthIdentity("中文😀").isNone(), true)
    }

    @TestCase
    public func rS1C2ThousandActualHelpersKeepOneActiveRootAndBoundedHistory(): Unit {
        recoveryTestHome({ home, parent =>
            let context = (home.toString(), parent)
            let heldKey = managedRecoveryNativeIntent(context: context)
            let held = recoveryLaunchAttachedFixture(home, parent, heldKey, "/bin/sleep", ["300"])
            var heldReaped = false
            try {
                @Expect(managedRecoveryCommitAttachedLaunch(home, heldKey, parent), true)
                for (index in 1..=1000) {
                    let key = managedRecoveryNativeIntent(context: context)
                    let child = recoveryLaunchAttachedFixture(home, parent, key, "/usr/bin/true", [])
                    var reaped = false
                    try {
                        @Expect(managedRecoveryCommitAttachedLaunch(home, key, parent), true)
                        @Expect(child.wait(timeout: Some(Duration.second * 5)), 0)
                        reaped = true
                        @Expect(managedRecoveryRetireObservedHelper(key, context), true)
                        @Expect(Directory.readFrom(home).size <= 12, true)
                        @Expect(held.isAlive(), true)
                    } finally {
                        if (!reaped) {
                            try { child.terminate(force: false); let _ = child.wait(timeout: Some(Duration.second * 5)) } catch (_: Exception) { () }
                        }
                    }
                    if (index % 100 == 0) { println("R-S1-C2 completed=${index}; activeRoot=1; retainedFacts<=12") }
                }
                let checkpoint = managedRecoveryReadText(home.join("roots.closed")).getOrThrow()
                @Expect(checkpoint.contains("ranges:2-1001\n"), true)
                let active = managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second * 2)
                @Expect(active.terminal, false)
                held.terminate(force: false)
                let _ = held.wait(timeout: Some(Duration.second * 5))
                heldReaped = true
                @Expect(managedRecoveryRetireObservedHelper(heldKey, context), true)
                @Expect(Directory.readFrom(home).size <= 4, true)
                let final = managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second * 2)
                @Expect(final.terminal, true)
                @Expect(managedRecoveryReadText(home.join("roots.closed")).getOrThrow().contains("ranges:1-1001\n"), true)
            } finally {
                if (!heldReaped) {
                    try { held.terminate(force: false); let _ = held.wait(timeout: Some(Duration.second * 5)) } catch (_: Exception) { () }
                }
            }
        })
    }

    @TestCase
    public func rS1C2CorruptFutureCheckpointAndNoSpawnCannotReuseRoot(): Unit {
        recoveryTestHome({ home, parent =>
            let context = (home.toString(), parent)
            let first = managedRecoveryNativeIntent(context: context)
            @Expect(first, "r-1")
            @Expect(exists(home.join(".issued")), true)
            let rawIssued = String.fromUtf8(File.readFrom(home.join(".issued")))
            @Expect(rawIssued, "managed-recovery-v1\nparent:${parent}\nissued:1\n")
            let readIssued = managedRecoveryReadText(home.join(".issued"))
            @Expect(readIssued.isSome(), true)
            let parsedIssued = managedRecoveryParseFields(rawIssued)
            @Expect(parsedIssued.isSome(), true)
            let issuedFields = parsedIssued.getOrThrow()
            @Expect(issuedFields.size, 2)
            @Expect(issuedFields["issued"], "1")
            @Expect(issuedFields["parent"], parent)
            @Expect(managedRecoveryReadIssued(home, parent), 1)
            managedRecoveryNativeTerminal(first, 0, 0, false, true, context: context)
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).terminal, true)
            let second = managedRecoveryNativeIntent(context: context)
            @Expect(second, "r-2")
            let invalid = "managed-recovery-v1\nparent:${parent}\nbroker:roots\nissued:100\nranges:1-100\n"
            File.writeTo(home.join("roots.closed"), invalid.toArray())
            var refused = false
            try { let _ = managedRecoveryNativeIntent(context: context) } catch (_: Exception) { refused = true }
            @Expect(refused, true)
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).terminal, false)
        })
    }

    @TestCase
    public func rS1C1StrictClosedRangesRejectMalformedOverlappingAndOversize(): Unit {
        recoveryTestHome({ _, parent =>
            let prefix = "managed-recovery-v1\nparent:${parent}\nbroker:roots\nissued:10000\nranges:"
            for (ranges in ["1-5,4-10", "6-10,1-3", "0-1", "1-10001", "1-9007199254740992", "01-2", "中文😀", "1-2,1-2"]) {
                @Expect(managedRecoveryParseClosedCheckpoint(prefix + ranges + "\n", "roots.closed", parent).isNone(), true)
            }
            let valid = managedRecoveryParseClosedCheckpoint(prefix + "1-3,5-10000\n", "roots.closed", parent).getOrThrow()
            @Expect(valid.covers(""), false)
            @Expect(valid.covers("r-4"), false)
            @Expect(valid.covers("r-5-o-123"), true)
            @Expect(valid.covers("r-10001"), false)
        })
    }

    @TestCase
    public func rS1C2OverflowRangesRetainSourcesAndClosedGapsPermitRecompression(): Unit {
        recoveryTestHome({ home, parent =>
            let context = (home.toString(), parent)
            let keys = ArrayList<String>()
            for (_ in 0..516) { keys.add(managedRecoveryNativeIntent(context: context)) }
            for (index in 1..516: 2) { managedRecoveryNativeTerminal(keys[index], 0, 0, false, true, context: context) }
            let before = managedRecoveryReadRootCheckpoint(home, parent).getOrThrow()
            @Expect(before.ranges.size, 257)
            @Expect(before.covers("r-516"), false)
            @Expect(exists(home.join("r-516.not_spawned")), true)
            @Expect(exists(home.join("r-515.intent")), true)
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).terminal, false)
            for (index in 0..516: 2) { managedRecoveryNativeTerminal(keys[index], 0, 0, false, true, context: context) }
            let after = managedRecoveryReadRootCheckpoint(home, parent).getOrThrow()
            @Expect(after.ranges.size, 1)
            @Expect(after.covers("r-516"), true)
            @Expect(Directory.readFrom(home).size <= 4, true)
            @Expect(managedRecoveryProbeRecords(home, parent, "fixture-parent", MonoTime.now() + Duration.second).terminal, true)
            @Expect(managedRecoveryNativeIntent(context: context), "r-517")
        })
    }
}
