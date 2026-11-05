package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.process.{ProcessInstanceIdentity, currentProcessInstanceIdentity, managedRecoveryInitialize, managedRecoveryPublishFact,
    resetManagedStdioBrokerForTest, managedStdioBroker}
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import magic.utils.http.{HttpProcessLaunchProvider, HttpProcessLaunchSpec, setHttpProcessLaunchProvider}
import std.collection.HashMap
import std.posix.chmod
import metis.gateway.logging.gatewayLoggingResetForTest

private class CrashRecoveryPreviousProcessProvider <: ProcessLaunchProvider {
    public func launch(_command: String, _args: Array<String>, _env: Array<(String, String)>, _error: Bool): ProcessHandle {
        throw Exception("crash_fixture_previous_process_provider")
    }
}

private class CrashRecoveryPreviousHttpProvider <: HttpProcessLaunchProvider {
    public func prepare(command: String, args: Array<String>): HttpProcessLaunchSpec {
        HttpProcessLaunchSpec("previous-provider", args, environment: HashMap<String, String>(),
            onSpawned: { _ => true }, requestStop: { _, _ => }, onTerminal: { _, _, _ => })
    }
}

private func crashRecoveryRestoreVariable(name: String, value: ?String): Unit {
    match (value) { case Some(text) => setVariable(name, text) case None => removeVariable(name) }
}

private func crashRecoveryTestHome(action: (Path, GatewayServeIdentity) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/private/tmp/metis-crash-recovery-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let oldHome = getVariable("METIS_HOME")
        let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
        let oldLogFile = getVariable("METIS_LOG_FILE")
        let oldConsole = getVariable("METIS_CONSOLE_LEVEL")
        let oldProcessProvider = setProcessLaunchProvider(None)
        let _ = setProcessLaunchProvider(oldProcessProvider)
        let oldHttpProvider = setHttpProcessLaunchProvider(None)
        let _ = setHttpProcessLaunchProvider(oldHttpProvider)
        Directory.create(home, recursive: true)
        var firstError = None<Exception>
        try {
            File.writeTo(home.join("test-owned"), "crash-recovery-fixture-v1\n".toArray())
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", "")
            setVariable("METIS_PROCESS_RECOVERY_PARENT", "")
            setVariable("METIS_LOG_FILE", home.join("fixture-logging.jsonl").toString())
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            let process = currentProcessInstanceIdentity().getOrThrow()
            let identity = GatewayServeIdentity(987654321, 1000, "crash-fixture-中文😀",
                processIdentity: Some(ProcessInstanceIdentity(process.platform, 987654321)))
            let text = "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\n" +
                "processIdentity:${identity.processIdentity.getOrThrow().serialize()}\ngracefulShutdownTimeoutMs:60000\n"
            File.writeTo(home.join("gateway-serve.lock"), text.toArray())
            action(home, identity)
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var physicalTerminal = false
            try {
                let result = resetManagedStdioBrokerForTest(timeoutMs: 3000)
                let broker = managedStdioBroker().snapshot()
                physicalTerminal = result.ok && !broker.running && broker.brokerPid == 0 &&
                    broker.ownerCount == 0 && broker.readerCount == 0 && broker.dispatcherCount == 0
                if (!physicalTerminal) { throw Exception("crash_fixture_broker_cleanup_pending") }
            }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                // These unit actions never launch a business child; synthetic pending evidence remains pending.
                // Restore test globals only after the real probe broker has physically settled.
                if (physicalTerminal) {
                    try { let _ = setProcessLaunchProvider(oldProcessProvider) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                    try { let _ = setHttpProcessLaunchProvider(oldHttpProvider) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
                try { let _ = setGatewayServePortProbeForTest(None) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { let _ = setGatewayStopOutputForTest(None) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                for ((key, value) in [("METIS_HOME", oldHome), ("METIS_PROCESS_RECOVERY_DIRECTORY", oldDirectory),
                    ("METIS_PROCESS_RECOVERY_PARENT", oldParent), ("METIS_LOG_FILE", oldLogFile), ("METIS_CONSOLE_LEVEL", oldConsole)]) {
                    try { crashRecoveryRestoreVariable(key, value) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
                try { CliConfig.invalidatePathCache() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { MetisConfigManager.invalidate() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { CliSettingManager.invalidate() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { gatewayLoggingResetForTest() } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
            // Original @Expect calls are nonthrowing: retain all inputs rather than infer success.
            try { println("R-CRASH-UNIT ownedFixture=${home.fileName};retained=true") }
            catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}

private func crashRecoveryTestInventory(identity: GatewayServeIdentity): Unit {
    @Expect(managedRecoveryInitialize(gatewayRecoveryInventoryPath(identity), identity.processIdentity.getOrThrow().serialize(), identity.nonce), true)
    // The test process is a collector, not the crashed owner; do not attach its probe broker to old facts.
    setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", "")
    setVariable("METIS_PROCESS_RECOVERY_PARENT", "")
}

@When[os == "macOS"]
@Test
public class GatewayCrashRecoveryTest {
    @TestCase
    public func rS1U2CleanTerminalRestoresPreviousProviderAndEnvironment(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let old = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(CrashRecoveryPreviousHttpProvider()))
            try {
                let context = (gatewayRecoveryInventoryPath(identity).toString(), identity.processIdentity.getOrThrow().serialize())
                let scope = GatewayRecoveryLaunchScope(context, identity.nonce, Some("old-directory"), Some("old-parent"))
                scope.closeAdmission()
                let fenced = setHttpProcessLaunchProvider(None)
                let _ = setHttpProcessLaunchProvider(fenced)
                var refused = false
                try { let _ = fenced.getOrThrow().prepare("/usr/bin/true", []) } catch (_: Exception) { refused = true }
                @Expect(refused, true)
                @Expect(exists(gatewayRecoveryInventoryPath(identity).join(".issued")), false)
                @Expect(scope.restoreAfterTerminal(MonoTime.now() + Duration.second), true)
                let restored = setHttpProcessLaunchProvider(None)
                let _ = setHttpProcessLaunchProvider(restored)
                @Expect(restored.getOrThrow().prepare("/usr/bin/true", []).command, "previous-provider")
                @Expect(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").getOrDefault({ => "" }), "old-directory")
                @Expect(getVariable("METIS_PROCESS_RECOVERY_PARENT").getOrDefault({ => "" }), "old-parent")
            } finally { let _ = setHttpProcessLaunchProvider(old) }
        })
    }

    @TestCase
    public func rS2InitTerminalRestoresAbsentEnvironment(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let old = setHttpProcessLaunchProvider(Some<HttpProcessLaunchProvider>(CrashRecoveryPreviousHttpProvider()))
            try {
                let context = (gatewayRecoveryInventoryPath(identity).toString(), identity.processIdentity.getOrThrow().serialize())
                let scope = GatewayRecoveryLaunchScope(context, identity.nonce, None, None)
                // Exercise the same scoped finally used when service initialization throws.
                var failed = false
                try { throw Exception("owned_initialization_failed") }
                catch (_: Exception) { failed = true }
                finally {
                    scope.closeAdmission()
                    @Expect(scope.stopOwnedChildren(MonoTime.now() + Duration.second), true)
                    @Expect(scope.restoreAfterTerminal(MonoTime.now() + Duration.second), true)
                }
                @Expect(failed, true)
                @Expect(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").isNone(), true)
                @Expect(getVariable("METIS_PROCESS_RECOVERY_PARENT").isNone(), true)
                let restored = setHttpProcessLaunchProvider(None)
                let _ = setHttpProcessLaunchProvider(restored)
                @Expect(restored.getOrThrow().prepare("/usr/bin/true", []).command, "previous-provider")
            } finally { let _ = setHttpProcessLaunchProvider(old) }
        })
    }

    @TestCase
    public func rS1U2PendingEvidenceKeepsProviderFenced(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let old = setHttpProcessLaunchProvider(None)
            try {
                let context = (gatewayRecoveryInventoryPath(identity).toString(), identity.processIdentity.getOrThrow().serialize())
                let scope = GatewayRecoveryLaunchScope(context, identity.nonce, Some("old-directory"), Some("old-parent"))
                @Expect(managedRecoveryPublishFact(gatewayRecoveryInventoryPath(identity), "pending", "intent", context[1]), true)
                @Expect(scope.restoreAfterTerminal(MonoTime.now() + Duration.second), false)
                let fenced = setHttpProcessLaunchProvider(None)
                var refused = false
                try { let _ = fenced.getOrThrow().prepare("/usr/bin/true", []) } catch (_: Exception) { refused = true }
                @Expect(refused, true)
                @Expect(exists(gatewayRecoveryInventoryPath(identity).join(".issued")), false)
                @Expect(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY").getOrDefault({ => "" }) == "old-directory", false)
            } finally { let _ = setHttpProcessLaunchProvider(old) }
        })
    }

    @TestCase
    public func rS2N3FailedCompletionPersistencePreservesCrashIdentity(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            @Expect(gatewayServeExitHasDurableEvidence(identity), false)
            @Expect(gatewayReleaseServeLockForIdentity(identity), false)
            @Expect(exists(gatewayServeLockPath()), true)
            @Expect(gatewayWriteServeCompletionMarker(identity, "cleanup_pending"), true)
            @Expect(gatewayServeExitHasDurableEvidence(identity), false)
        })
    }

    @TestCase
    public func rS2N6PresentInventoryWithoutReadableHeaderKeepsExactLock(): Unit {
        crashRecoveryTestHome({ home, fixtureIdentity =>
            let process = currentProcessInstanceIdentity().getOrThrow()
            let identity = GatewayServeIdentity(process.pid, fixtureIdentity.startedAtMs, fixtureIdentity.nonce,
                processIdentity: Some(process))
            let lock = "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\n" +
                "processIdentity:${process.serialize()}\ngracefulShutdownTimeoutMs:60000\n"
            let request = lock + "requestedAtMs:1\n"
            let requestPath = home.join("gateway-serve.stop-request")
            File.writeTo(gatewayServeLockPath(), lock.toArray())
            File.writeTo(requestPath, request.toArray())
            File.writeTo(gatewayServeCompletionPath(),
                (lock + "status:graceful\nfullTerminal:1\nservicePluginPendingCount:0\n").toArray())
            @Expect(gatewayParseServeCompletion(String.fromUtf8(File.readFrom(gatewayServeCompletionPath())), identity).fullTerminal, true)
            let directory = gatewayRecoveryInventoryPath(identity)
            Directory.create(directory, recursive: true)
            let header = directory.join("inventory")
            @Expect(gatewayServeExitHasDurableEvidence(identity), false)
            @Expect(gatewayReleaseServeLockForIdentity(identity), false)
            for (bytes in ["malformed 中文😀\n".toArray(), [0xffu8, 0xfeu8]]) {
                File.writeTo(header, bytes)
                @Expect(gatewayServeExitHasDurableEvidence(identity), false)
                @Expect(gatewayReleaseServeLockForIdentity(identity), false)
                @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), lock)
                @Expect(String.fromUtf8(File.readFrom(requestPath)), request)
            }
            remove(header)
            Directory.create(header)
            @Expect(gatewayReleaseServeLockForIdentity(identity), false)
            @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), lock)
            @Expect(String.fromUtf8(File.readFrom(requestPath)), request)
        })
    }

    @TestCase
    public func rS2H3AbsentInventoryDirectoryKeepsLegacyRelease(): Unit {
        crashRecoveryTestHome({ home, fixtureIdentity =>
            let process = currentProcessInstanceIdentity().getOrThrow()
            let identity = GatewayServeIdentity(process.pid, fixtureIdentity.startedAtMs, fixtureIdentity.nonce,
                processIdentity: Some(process))
            let lock = "gateway-serve-active-v4\npid:${identity.pid}\nstartedAtMs:${identity.startedAtMs}\nnonce:${identity.nonce}\n" +
                "processIdentity:${process.serialize()}\ngracefulShutdownTimeoutMs:60000\n"
            let requestPath = home.join("gateway-serve.stop-request")
            File.writeTo(gatewayServeLockPath(), lock.toArray())
            File.writeTo(requestPath, (lock + "requestedAtMs:1\n").toArray())
            @Expect(exists(gatewayRecoveryInventoryPath(identity)), false)
            @Expect(gatewayServeExitHasDurableEvidence(identity), true)
            @Expect(gatewayReleaseServeLockForIdentity(identity), true)
            @Expect(exists(gatewayServeLockPath()), false)
            @Expect(exists(requestPath), false)
        })
    }

    @TestCase
    public func rS2N1StopRequestMustRemainStrictlyBoundAcrossRetirement(): Unit {
        crashRecoveryTestHome({ home, identity =>
            crashRecoveryTestInventory(identity)
            let lock = String.fromUtf8(File.readFrom(gatewayServeLockPath()))
            let request = lock + "requestedAtMs:1\n"
            let path = home.join("gateway-serve.stop-request")
            for (bad in [request.replace(identity.nonce, "new-generation"), request + "requestedAtMs:2\n",
                lock + "requestedAtMs:\nrequestedAtMs:1\n", lock + "requestedAtMs:01\n", lock + "requestedAtMs:0\n", request + "中文😀:bad\n"]) {
                File.writeTo(path, bad.toArray())
                let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
                @Expect(evidence.status == "recoverable", false)
                @Expect(gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second).ok, false)
                @Expect(gatewayAcquireServeLockForRunningProcess(), false)
                let history = home.join("gateway-serve.recovery-history")
                let admissionArchives = if (exists(history)) { Directory.readFrom(history).size } else { 0 }
                @Expect(admissionArchives, 0)
                @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), lock)
                @Expect(String.fromUtf8(File.readFrom(path)), bad)
            }
            File.writeTo(path, [0xffu8, 0xfeu8])
            @Expect(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second).status, "stop_request_invalid")
            File.writeTo(path, request.toArray())
            let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
            let replacement = request.replace(identity.nonce, "new-generation")
            let replaced = gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second * 3,
                afterArchive: { => File.writeTo(path, replacement.toArray()) })
            @Expect(replaced.ok, false)
            @Expect(String.fromUtf8(File.readFrom(path)), replacement)
            @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), lock)
            File.writeTo(path, request.toArray())
            let blocked = gatewayCommitCrashRecovery(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second),
                MonoTime.now() + Duration.second * 3, afterArchive: { => chmod(home.toString(), UInt32(0o500)) })
            chmod(home.toString(), UInt32(0o700))
            @Expect(blocked.status, "stop_request_retirement_failed")
            @Expect(String.fromUtf8(File.readFrom(path)), request)
            @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), lock)
            let final = gatewayCommitCrashRecovery(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second), MonoTime.now() + Duration.second * 3)
            @Expect(final.ok, true)
            @Expect(exists(path), false)
            @Expect(exists(gatewayServeLockPath()), false)
            var archived = false
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".crash-stop-request") && String.fromUtf8(File.readFrom(entry.path)) == request) { archived = true }
            }
            @Expect(archived, true)
        })
    }

    @TestCase
    public func rS2U2CrashDiagnosticsAreRedactedAndSinkFailureCannotUndoCommit(): Unit {
        crashRecoveryTestHome({ home, identity =>
            crashRecoveryTestInventory(identity)
            let oldFile = getVariable("METIS_LOG_FILE").getOrDefault({ => "" })
            let oldLevel = getVariable("METIS_LOG_LEVEL")
            let oldConsole = getVariable("METIS_CONSOLE_LEVEL").getOrDefault({ => "" })
            var diagnosticError = None<Exception>
            try {
                let output = home.join("recovery-diagnostic.jsonl")
                setVariable("METIS_LOG_FILE", output.toString()); setVariable("METIS_LOG_LEVEL", "debug")
                setVariable("METIS_CONSOLE_LEVEL", "silent"); gatewayLoggingResetForTest()
                let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
                @Expect(gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second * 3).ok, true)
                let text = String.fromUtf8(File.readFrom(output))
                @Expect(text.contains("gateway.recovery.checked"), true)
                @Expect(text.contains("gateway.recovery.reconciled"), true)
                @Expect(text.contains("crash_recovery"), true)
                @Expect(text.contains(identity.nonce), false)
                @Expect(text.contains(home.toString()), false)
                File.writeTo(gatewayServeLockPath(), evidence.originalLock.toArray())
                let blockedSink = home.join("blocked-log-sink")
                Directory.create(blockedSink)
                setVariable("METIS_LOG_FILE", blockedSink.toString()); gatewayLoggingResetForTest()
                @Expect(gatewayCommitCrashRecovery(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second),
                    MonoTime.now() + Duration.second * 3).ok, true)
                @Expect(exists(gatewayServeLockPath()), false)
            } catch (error: Exception) { diagnosticError = Some(error) }
            finally {
                for ((key, value) in [("METIS_LOG_FILE", Some(oldFile)), ("METIS_LOG_LEVEL", oldLevel),
                    ("METIS_CONSOLE_LEVEL", Some(oldConsole))]) {
                    try { crashRecoveryRestoreVariable(key, value) }
                    catch (error: Exception) { if (diagnosticError.isNone()) { diagnosticError = Some(error) } }
                }
                try { gatewayLoggingResetForTest() }
                catch (error: Exception) { if (diagnosticError.isNone()) { diagnosticError = Some(error) } }
            }
            if (let Some(error) <- diagnosticError) { throw error }
        })
    }

    @TestCase
    public func rS2U1MissingCompletionCollectsIndependentCrashFacts(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
            @Expect(evidence.status, "recoverable")
            @Expect(evidence.originalLock.contains("status:graceful"), false)
            @Expect(exists(gatewayServeCompletionPath()), false)
        })
    }

    @TestCase
    public func rS2P1ArchiveKeepsMissingFactAndRetiresOnlyOldLock(): Unit {
        crashRecoveryTestHome({ home, identity =>
            crashRecoveryTestInventory(identity)
            let business = home.join("pending-business")
            File.writeTo(business, "未完成业务中文😀".toArray())
            let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
            let result = gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second * 3)
            @Expect(result.status, "recovered_after_crash")
            @Expect(exists(gatewayServeLockPath()), false)
            @Expect(exists(gatewayServeCompletionPath()), false)
            @Expect(String.fromUtf8(File.readFrom(business)), "未完成业务中文😀")
            var summaries: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".crash-evidence")) {
                    summaries += 1
                    let text = String.fromUtf8(File.readFrom(entry.path))
                    @Expect(text.contains("completion:missing"), true)
                    @Expect(text.contains("status:graceful"), false)
                }
            }
            @Expect(summaries, 1)
        })
    }

    @TestCase
    public func rS2N1ReplacedLockAfterArchiveIsNeverRemoved(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
            let replacement = evidence.originalLock.replace(identity.nonce, "new-generation")
            let result = gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second * 3,
                afterArchive: { => File.writeTo(gatewayServeLockPath(), replacement.toArray()) })
            @Expect(result.ok, false)
            @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), replacement)
        })
    }

    @TestCase
    public func rS2N2ArchiveFailurePreservesOriginalEvidence(): Unit {
        crashRecoveryTestHome({ home, identity =>
            crashRecoveryTestInventory(identity)
            let evidence = gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second)
            File.writeTo(home.join("gateway-serve.recovery-history"), "blocked".toArray())
            @Expect(gatewayCommitCrashRecovery(evidence, MonoTime.now() + Duration.second).ok, false)
            @Expect(String.fromUtf8(File.readFrom(gatewayServeLockPath())), evidence.originalLock)
        })
    }

    @TestCase
    public func rS0B1LegacyMissingInventoryRemainsExplicitlyUnknown(): Unit {
        crashRecoveryTestHome({ _, _ =>
            @Expect(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second).status, "legacy_inventory_missing")
            @Expect(gatewayAnotherServeInstanceSeemsRunning(), true)
            @Expect(exists(gatewayServeLockPath()), true)
        })
    }

    @TestCase
    public func rS2B1IncompleteSpawnAndDeadlineCannotRecover(): Unit {
        crashRecoveryTestHome({ _, identity =>
            crashRecoveryTestInventory(identity)
            let parent = identity.processIdentity.getOrThrow().serialize()
            @Expect(managedRecoveryPublishFact(gatewayRecoveryInventoryPath(identity), "uncommitted", "intent", parent), true)
            @Expect(gatewayCollectCrashRecoveryEvidence(MonoTime.now() + Duration.second).status, "resource_intent_incomplete")
            @Expect(gatewayCollectCrashRecoveryEvidence(MonoTime.now()).status, "deadline_exceeded")
        })
    }

    @TestCase
    public func rS3N1DefaultHumanOutputDescribesEvidenceInsteadOfClaimingLiveChildren(): Unit {
        for (status in ["legacy_inventory_missing", "resource_identity_unknown", "recovered_after_crash", "cleanup_pending"]) {
            let text = gatewayStopOutcomeHumanText(status)
            @Expect(text.contains("主进程已退出但子进程清理未完成"), false)
            @Expect(text.contains("\"ok\""), false)
            @Expect(text.contains("\"result\""), false)
        }
    }

    @TestCase
    public func rS1U2TestFixtureRestoresExactProvidersAndEnvironmentAfterReturnAndThrow(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let oldProcess = setProcessLaunchProvider(None)
            let _ = setProcessLaunchProvider(oldProcess)
            let oldHttp = setHttpProcessLaunchProvider(None)
            let _ = setHttpProcessLaunchProvider(oldHttp)
            let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
            let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
            let home = Directory.createTemp("/private/tmp")
            let previousProcess = CrashRecoveryPreviousProcessProvider()
            let previousHttp = CrashRecoveryPreviousHttpProvider()
            var firstError = None<Exception>
            var completed: Int64 = 0
            try {
                File.writeTo(home.join("test-owned"), "crash-provider-isolation-v1\n".toArray())
                for (bound in [false, true]) {
                    let expectedProcess = if (bound) { Some<ProcessLaunchProvider>(previousProcess) } else { None<ProcessLaunchProvider> }
                    let expectedHttp = if (bound) { Some<HttpProcessLaunchProvider>(previousHttp) } else { None<HttpProcessLaunchProvider> }
                    if (bound) {
                        let initialized = managedRecoveryInitialize(home.join("prior-context"),
                            currentProcessInstanceIdentity().getOrThrow().serialize(), "unit-provider-prior")
                        @Expect(initialized, true)
                        if (!initialized) { throw Exception("crash_fixture_prior_context_invalid") }
                    } else {
                        removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
                        removeVariable("METIS_PROCESS_RECOVERY_PARENT")
                    }
                    let expectedDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
                    let expectedParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
                    let _ = setProcessLaunchProvider(expectedProcess)
                    let _ = setHttpProcessLaunchProvider(expectedHttp)
                    for (throwsBody in [false, true]) {
                        var bodyFailure = None<String>
                        try {
                            crashRecoveryTestHome({ _, identity =>
                                crashRecoveryTestInventory(identity)
                                let context = (gatewayRecoveryInventoryPath(identity).toString(), identity.processIdentity.getOrThrow().serialize())
                                let scope = GatewayRecoveryLaunchScope(context, identity.nonce, expectedDirectory, expectedParent)
                                @Expect(managedRecoveryPublishFact(gatewayRecoveryInventoryPath(identity), "pending", "intent", context[1]), true)
                                @Expect(scope.restoreAfterTerminal(MonoTime.now() + Duration.second), false)
                                let activeHttp = setHttpProcessLaunchProvider(None)
                                let _ = setHttpProcessLaunchProvider(activeHttp)
                                let refused = try { let _ = activeHttp.getOrThrow().prepare("/usr/bin/true", []); false }
                                    catch (error: Exception) { error.message == "process_recovery_generation_closing" }
                                @Expect(refused, true)
                                @Expect(exists(gatewayRecoveryInventoryPath(identity).join(".issued")), false)
                                let activeProcess = setProcessLaunchProvider(None)
                                let _ = setProcessLaunchProvider(activeProcess)
                                @Expect(activeProcess.isSome(), true)
                                if (bound) {
                                    @Expect(refEq((activeProcess.getOrThrow() as Object).getOrThrow(), (previousProcess as Object).getOrThrow()), false)
                                }
                                if (throwsBody) { throw Exception("crash_fixture_original_body_error") }
                            })
                        } catch (error: Exception) { bodyFailure = Some(error.message) }
                        @Expect(bodyFailure.isSome(), throwsBody)
                        if (let Some(label) <- bodyFailure) { @Expect(label, "crash_fixture_original_body_error") }
                        let actualProcess = setProcessLaunchProvider(None)
                        let _ = setProcessLaunchProvider(actualProcess)
                        let actualHttp = setHttpProcessLaunchProvider(None)
                        let _ = setHttpProcessLaunchProvider(actualHttp)
                        @Expect(actualProcess.isSome(), expectedProcess.isSome())
                        @Expect(actualHttp.isSome(), expectedHttp.isSome())
                        if (bound) {
                            @Expect(refEq((actualProcess.getOrThrow() as Object).getOrThrow(), (previousProcess as Object).getOrThrow()), true)
                            @Expect(refEq((actualHttp.getOrThrow() as Object).getOrThrow(), (previousHttp as Object).getOrThrow()), true)
                        }
                        @Expect(getVariable("METIS_PROCESS_RECOVERY_DIRECTORY") == expectedDirectory, true)
                        @Expect(getVariable("METIS_PROCESS_RECOVERY_PARENT") == expectedParent, true)
                        completed += 1
                    }
                }
                @Expect(completed, 4)
            } catch (error: Exception) { firstError = Some(error) }
            finally {
                try { let _ = setProcessLaunchProvider(oldProcess) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                try { let _ = setHttpProcessLaunchProvider(oldHttp) }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                for ((key, value) in [("METIS_PROCESS_RECOVERY_DIRECTORY", oldDirectory), ("METIS_PROCESS_RECOVERY_PARENT", oldParent)]) {
                    try { crashRecoveryRestoreVariable(key, value) }
                    catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                }
                try { println("R-CRASH-PROVIDER ownedFixture=${home.fileName};retained=true;completed=${completed}") }
                catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            }
            if (let Some(error) <- firstError) { throw error }
        }
    }
}
