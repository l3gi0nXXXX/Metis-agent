package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.core.GatewayStopResult
import metis.gateway.logging.{gatewayLoggingResetForTest, gatewayLoggingCaptureConsoleForTest, gatewayLoggingCapturedConsoleForTest, MetisLogEvent}
import stdx.encoding.json.JsonValue
import metis.gateway.service_plugin.{setServicePluginPidProbeCommandForTest, setServicePluginPortReleaseCommandForTest}
import metis.process.{ProcessInstanceIdentity, currentProcessInstanceIdentity, resetManagedStdioBrokerForTest}
import std.core.Duration
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, exists, remove}
import std.net.{IPSocketAddress, TcpServerSocket}
import std.process.executeWithOutput
import std.sync.AtomicInt64
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

// This is the historical snapshot shape left by an interrupted plugin shutdown.
private func hr30WritePendingMarker(home: Path, identity: GatewayServeIdentity): String {
    let original = hrRuntimeWriteMarker(identity, legacy: false, broker: "stopped")
        .replace("servicePluginIngressStatus:sent", "servicePluginIngressStatus:cleanup_pending")
        .replace("servicePluginOwnerStatus:terminated", "servicePluginOwnerStatus:cleanup_pending")
        .replace("canvasStatus:stopped", "canvasStatus:already_stopped")
    File.writeTo(home.join("gateway-serve.stop-complete"), original.toArray())
    original
}

@Test
public class GatewayHistoricalPendingRecoveryTest {
    @TestCase
    public func hr30U1PendingSnapshotAndRunningLeaseAreRecoverable(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hr30WritePendingMarker(home, identity)
            let lease = hrRuntimeWriteLease(home, identity, state: "running")
            let leaseBytes = File.readFrom(lease)
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            @Expect(evidence.parsed.ok, true)
            @Expect(evidence.status, "recoverable")
            @Expect(evidence.parsed.completion.status, "cleanup_pending")
            @Expect(File.readFrom(lease), leaseBytes)
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
        })
    }

    @TestCase
    public func hr30P1ArchivePreservesPendingHistoryAndRunningLease(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hr30WritePendingMarker(home, identity)
            let lease = hrRuntimeWriteLease(home, identity, state: "running")
            let leaseBytes = File.readFrom(lease)
            let business = home.join("pending-business.json")
            File.writeTo(business, "待处理中文🧪".toArray())
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            @Expect(evidence.status, "recoverable")
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "reconciled")
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(File.readFrom(lease), leaseBytes)
            @Expect(String.fromUtf8(File.readFrom(business)), "待处理中文🧪")
            var originals: Int64 = 0
            var summaries: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                let text = String.fromUtf8(File.readFrom(entry.path))
                if (entry.name.endsWith(".completion")) {
                    originals += 1
                    @Expect(text, original)
                } else if (entry.name.endsWith(".evidence")) {
                    summaries += 1
                    @Expect(text.contains("resourceStatus:terminal"), true)
                    @Expect(text.contains("lease:987654322:${identity.pid}:2000:0:running\n"), true)
                    @Expect(text.contains("lease:987654322:${identity.pid}:2000:0:stopped\n"), false)
                    @Expect(text.contains(home.toString()), false)
                    @Expect(text.contains(identity.nonce), false)
                }
            }
            @Expect(originals, 1)
            @Expect(summaries, 1)
        })
    }

    @TestCase
    public func hr30B1PendingSurfaceCannotSkipLeaseEvidence(): Unit {
        hrRuntimeHome({ home, identity =>
            let pending = hr30WritePendingMarker(home, identity)
            let aggregate = pending.replace("servicePluginLeaseStatus:cleanup_pending", "servicePluginLeaseStatus:terminal")
                .replace("servicePluginPortStatus:cleanup_pending", "servicePluginPortStatus:terminal")
            File.writeTo(home.join("gateway-serve.stop-complete"), aggregate.toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            let _ = hrRuntimeWriteLease(home, identity, state: "running")
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (0, "", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "pid_alive")
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            @Expect(gatewayCollectHistoricalRecoveryEvidence(MonoTime.now()).status, "deadline_exceeded")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), aggregate)
        })
    }

    @TestCase
    public func hr30N1ActiveOrUnknownResourcesKeepRestartBlocked(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hr30WritePendingMarker(home, identity)
            let lease = hrRuntimeWriteLease(home, identity, state: "running")
            let leaseText = String.fromUtf8(File.readFrom(lease))
            let launches = AtomicInt64(0)
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (0, "", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "pid_alive")
            @Expect(gatewayExecuteRestartServe(launchServe: { => launches.fetchAdd(1); true }), 1)
            @Expect(launches.load(), 0)
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "Operation not permitted") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "pid_probe_permission_denied")
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
            File.writeTo(lease, leaseText.replace("\"port\":0", "\"port\":${gatewayConfiguredServePort()}").toArray())
            setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (0, "p123", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "port_active")
            setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
            File.writeTo(lease, leaseText.toArray())
            setGatewayServePortProbeForTest(Some({ _, _ => (0, "123", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "port_release_timeout")
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "partial output", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "port_probe_failed")
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            for (field in ["servicePluginIngressStatus:cleanup_pending", "servicePluginOwnerStatus:cleanup_pending"]) {
                for (invalid in ["close_failed", "timeout", "unknown"]) {
                    File.writeTo(home.join("gateway-serve.stop-complete"), original.replace(field, "${field.split(":")[0]}:${invalid}").toArray())
                    @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
                }
            }
            File.writeTo(home.join("gateway-serve.stop-complete"), original.toArray())
            let current = currentProcessInstanceIdentity().getOrThrow()
            let alive = GatewayServeIdentity(current.pid, 1000, "活跃父实例🧪", processIdentity: Some(current))
            let _ = hr30WritePendingMarker(home, alive)
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "identity_alive")
        })
    }

    @TestCase
    public func hr30N2PendingCommitRejectsReplacedLeaseAfterArchive(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hr30WritePendingMarker(home, identity)
            let lease = hrRuntimeWriteLease(home, identity, state: "running")
            let before = String.fromUtf8(File.readFrom(lease))
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            @Expect(evidence.status, "recoverable")
            let replacement = before.replace("2000", "2001")
            let result = gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3,
                afterArchive: { => File.writeTo(lease, replacement.toArray()) })
            @Expect(result.status, "identity_changed")
            @Expect(result.ok, false)
            @Expect(String.fromUtf8(File.readFrom(lease)), replacement)
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
        })
    }

    @TestCase
    public func hr30E2eRestartReconcilesPendingSnapshotBeforeLaunch(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hr30WritePendingMarker(home, identity)
            let lease = hrRuntimeWriteLease(home, identity, state: "running")
            let leaseBytes = File.readFrom(lease)
            @Expect(gatewayExecuteStopServe(), 0)
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            @Expect(exists(home.join("gateway-serve.recovery-history")), false)
            let launches = AtomicInt64(0)
            @Expect(gatewayExecuteRestartServe(launchServe: { =>
                launches.fetchAdd(1)
                gatewayAcquireServeLockForRunningProcess()
            }), 0)
            @Expect(launches.load(), 1)
            @Expect(gatewayOwnsCurrentServeLock(), true)
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(File.readFrom(lease), leaseBytes)
            gatewayReleaseServeLockQuiet()
            @Expect(gatewayPendingServeCompletionStatus(), "missing")
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            var archived: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".completion")) {
                    archived += 1
                    @Expect(String.fromUtf8(File.readFrom(entry.path)), original)
                }
            }
            @Expect(archived, 1)
        })
    }
}

func hrRuntimeHome(block: (Path, GatewayServeIdentity) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-hr-runtime-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let before = getVariable("METIS_HOME")
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        var port: Int64 = 0
        try (socket = TcpServerSocket(bindAt: 0u16)) {
            socket.bind()
            port = Int64((socket.localAddress as IPSocketAddress)?.port ?? 0u16)
        }
        var settings = CliSettingManager.readGatewaySettings()
        settings.port = port
        let _ = MetisConfigManager.setGatewaySettings(settings)
        CliSettingManager.invalidate()
        setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
        setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
        setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
        let current = currentProcessInstanceIdentity().getOrThrow()
        let identity = GatewayServeIdentity(987654321, 1000, "历史恢复-测试🧪",
            processIdentity: Some(ProcessInstanceIdentity(current.platform, 987654321)))
        try { block(home, identity) } finally {
            gatewayReleaseServeLockQuiet()
            let _ = resetManagedStdioBrokerForTest(timeoutMs: 3000)
            setGatewayServePortProbeForTest(None)
            setServicePluginPidProbeCommandForTest(None)
            setServicePluginPortReleaseCommandForTest(None)
            setGatewayStopOutputForTest(None)
            setVariable("METIS_HOME", before.getOrDefault({ => "" }))
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            remove(home, recursive: true)
            @Expect(exists(home), false)
        }
    }
}

func hrRuntimeWriteMarker(identity: GatewayServeIdentity, legacy!: Bool = true,
    broker!: String = "broker_close_exit_nonzero", terminal!: Bool = true): String {
    let stop = GatewayStopResult(false, "cleanup_pending", inboundStatus: "stopped", compatStatus: "stopped",
        sidecarStatus: "disabled", servicePluginIngressStatus: "sent", servicePluginDispatchStatus: "cleanup_pending",
        servicePluginOwnerStatus: "terminated", servicePluginLeaseStatus: "cleanup_pending", servicePluginPortStatus: "cleanup_pending",
        servicePluginPendingCount: 1, channelsStatus: "stopped", brokerStatus: broker,
        brokerExternalTerminal: terminal, brokerTerminalBasis: if (terminal) { "closed_ack_exit_observed" } else { "unknown" })
    let written = gatewayWriteServeCompletionMarker(identity, stop, httpStatus: "stopped", canvasStatus: "stopped", gatewayServerStatus: "stopped")
    @Expect(written, true)
    let path = CliConfig.dotDir.join("gateway-serve.stop-complete")
    var text = String.fromUtf8(File.readFrom(path))
    if (legacy) {
        text = text.replace("recoveryEvidenceVersion:1\n", "")
            .replace("brokerExternalTerminal:${if (terminal) { 1 } else { 0 }}\n", "")
            .replace("brokerTerminalBasis:${if (terminal) { "closed_ack_exit_observed" } else { "unknown" }}\n", "")
        File.writeTo(path, text.toArray())
    }
    text
}

func hrRuntimeWriteLease(home: Path, identity: GatewayServeIdentity, state!: String = "stopped"): Path {
    let dir = home.join("service-plugin").join("runtime").join("test-plugin")
    if (!exists(dir)) { Directory.create(dir, recursive: true) }
    let path = dir.join("test-plugin-1.lease.json")
    File.writeTo(path, ("{\"pluginId\":\"test-plugin\",\"sessionId\":\"test-plugin-1\",\"state\":\"${state}\"," +
        "\"pid\":987654322,\"parentPid\":${identity.pid},\"startedAtMs\":2000,\"port\":0}").toArray())
    path
}

@Test
public class GatewayHistoricalRecoveryTest {
    @TestCase
    public func hrS2U1ClassifiesV4AndExplicitEvidenceWithoutRewritingHistory(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteLease(home, identity)
            for (legacy in [true, false]) {
                let original = hrRuntimeWriteMarker(identity, legacy: legacy)
                let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
                @Expect(evidence.parsed.ok, true)
                @Expect(evidence.parsed.completion.status, "cleanup_pending")
                @Expect(gatewayEvaluateHistoricalRecoveryEvidence(evidence).status, "recoverable")
                @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            }
            let aggregate = hrRuntimeWriteMarker(identity).replace("servicePluginIngressStatus:sent", "servicePluginIngressStatus:terminal")
                .replace("servicePluginDispatchStatus:cleanup_pending", "servicePluginDispatchStatus:cancelled")
                .replace("servicePluginOwnerStatus:terminated", "servicePluginOwnerStatus:graceful_exited")
                .replace("servicePluginLeaseStatus:cleanup_pending", "servicePluginLeaseStatus:terminal")
                .replace("servicePluginPortStatus:cleanup_pending", "servicePluginPortStatus:terminal")
            File.writeTo(home.join("gateway-serve.stop-complete"), aggregate.toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            File.writeTo(home.join("gateway-serve.stop-complete"), aggregate.replace("sidecarStatus:disabled", "sidecarStatus:terminal").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            let explicit = hrRuntimeWriteMarker(identity, legacy: false)
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("recoveryEvidenceVersion:1", "recoveryEvidenceVersion:2")).status, "evidence_version_unsupported")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("brokerExternalTerminal:1", "brokerExternalTerminal:0")).status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("brokerTerminalBasis:closed_ack_exit_observed", "brokerTerminalBasis:unknown")).status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("brokerTerminalBasis:closed_ack_exit_observed", "brokerTerminalBasis:untrusted")).status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit + "pid:${identity.pid}\n").status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict(explicit.replace("servicePluginLeaseStatus:cleanup_pending\n", "")).status, "malformed")
            File.writeTo(home.join("gateway-serve.stop-complete"), explicit.replace("servicePluginLeaseStatus:cleanup_pending", "servicePluginLeaseStatus:not_checked").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
        })
    }

    @TestCase
    public func s2N1NewShutdownFactsStayCompatibleAndFailClosed(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteLease(home, identity)
            let written = hrRuntimeWriteMarker(identity, legacy: false)
            @Expect(gatewayParseHistoricalCompletionStrict(written).ok, true)
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            let legacy = written.replace("channelPendingCount:0\n", "").replace("shutdownPhase:complete\n", "")
                .replace("shutdownPendingCount:0\n", "").replace("cronStatus:not_applicable\n", "")
                .replace("memoryStatus:not_applicable\n", "")
            @Expect(gatewayParseHistoricalCompletionStrict(legacy).ok, true)
            File.writeTo(home.join("gateway-serve.stop-complete"), legacy.toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            for (key in ["channelPendingCount", "shutdownPendingCount"]) {
                for (invalid in ["", "-1", "bad"]) {
                    let malformed = written.replace("${key}:0", "${key}:${invalid}")
                    @Expect(gatewayParseHistoricalCompletionStrict(malformed).status, "malformed")
                }
                @Expect(gatewayParseHistoricalCompletionStrict(written + "${key}:0\n").status, "malformed")
                let pending = written.replace("${key}:0", "${key}:1")
                File.writeTo(home.join("gateway-serve.stop-complete"), pending.toArray())
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
                let contradictory = pending.replace("fullTerminal:0", "fullTerminal:1").replace("status:cleanup_pending", "status:graceful")
                    .replace("servicePluginPendingCount:1", "servicePluginPendingCount:0")
                @Expect(gatewayParseServeCompletion(contradictory, identity).fullTerminal, false)
            }
            for (key in ["cronStatus", "memoryStatus"]) {
                for (status in ["cleanup_pending", "stop_failed", "unknown", ""]) {
                    let pending = written.replace("${key}:not_applicable", "${key}:${status}")
                    File.writeTo(home.join("gateway-serve.stop-complete"), pending.toArray())
                    @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
                    let contradictory = pending.replace("fullTerminal:0", "fullTerminal:1").replace("status:cleanup_pending", "status:graceful")
                        .replace("servicePluginPendingCount:1", "servicePluginPendingCount:0")
                    @Expect(gatewayParseServeCompletion(contradictory, identity).fullTerminal, false)
                }
            }
            let diagnosticOnly = written.replace("shutdownPhase:complete", "shutdownPhase:未知🧪")
            File.writeTo(home.join("gateway-serve.stop-complete"), diagnosticOnly.toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
            @Expect(gatewayParseHistoricalCompletionStrict(written + "unknownShutdownFact:0\n").status, "malformed")
        })
    }

    @TestCase
    public func hrS2B1StrictMarkerUnicodeEncodingAndIdentityLimits(): Unit {
        hrRuntimeHome({ home, identity =>
            let original = hrRuntimeWriteMarker(identity)
            @Expect(gatewayParseHistoricalCompletionStrict(original).identity.getOrThrow().nonce, "历史恢复-测试🧪")
            @Expect(gatewayParseHistoricalCompletionStrict(original.replace(identity.nonce, String(Array<Rune>(4097, repeat: r'中')))).status, "evidence_limit_exceeded")
            @Expect(gatewayParseHistoricalCompletionStrict(original.replace("pid:${identity.pid}\n", "pid:7\n")).status, "identity_mismatch")
            let nonce4096 = String(Array<Rune>(1365, repeat: r'中')) + "x"
            @Expect(nonce4096.size, 4096)
            @Expect(gatewayParseHistoricalCompletionStrict(original.replace(identity.nonce, nonce4096)).ok, true)
            let full = original + String(Array<Rune>(65536 - original.size, repeat: r'\n'))
            @Expect(gatewayParseHistoricalCompletionStrict(full).ok, true)
            @Expect(gatewayParseHistoricalCompletionStrict(full + "\n").status, "evidence_limit_exceeded")
            @Expect(gatewayParseHistoricalCompletionStrict(original + "\u{0}").status, "malformed")
            @Expect(gatewayParseHistoricalCompletionStrict("{").ok, false)
            File.writeTo(home.join("gateway-serve.stop-complete"), [0xffu8, 0xfeu8, 0x00u8])
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "invalid_response_encoding")
        })
    }

    @TestCase
    public func hrS2P1ArchivesAndReconcilesOnlyOwnedHistoricalMarker(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let pending = home.join("pending-business.json")
            File.writeTo(pending, "待处理🧪".toArray())
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            let result = gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3)
            @Expect(result.status, "reconciled")
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(String.fromUtf8(File.readFrom(pending)), "待处理🧪")
            var originals: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".completion")) {
                    originals += 1
                    @Expect(String.fromUtf8(File.readFrom(entry.path)), original)
                    let permissions = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", entry.path.toString()])
                    @Expect(try { String.fromUtf8(permissions[1]).trimAscii() } catch (_: Exception) { "invalid_response_encoding" }, "600")
                } else if (entry.name.endsWith(".evidence")) {
                    let summary = String.fromUtf8(File.readFrom(entry.path))
                    @Expect(summary.contains("leaseCount:1"), true)
                    @Expect(summary.contains("rawPortProbe:released"), true)
                    @Expect(summary.contains("brokerBasis:legacy_v4_broker_close_exit_nonzero"), true)
                    @Expect(summary.contains(home.toString()), false)
                    @Expect(summary.contains(identity.nonce), false)
                }
            }
            @Expect(originals, 1)
            @Expect(gatewayReconcileHistoricalServeCompletion().status, "missing")
        })
    }

    @TestCase
    public func hrS2N1CommitFailureAndChangedEvidenceKeepReplacementSafe(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            File.writeTo(home.join("gateway-serve.recovery-history"), "blocked".toArray())
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "archive_write_failed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            remove(home.join("gateway-serve.recovery-history"))
            File.writeTo(home.join("gateway-serve.stop-complete"), original.replace(identity.nonce, "replacement🧪").toArray())
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "identity_changed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))).contains("replacement🧪"), true)
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "partial output", "") }))
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().ok, false)
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            File.writeTo(home.join("gateway-serve.stop-complete"), original.toArray())
            let calls = AtomicInt64(0)
            let lease = home.join("service-plugin/runtime/test-plugin/test-plugin-1.lease.json")
            let leaseText = String.fromUtf8(File.readFrom(lease))
            setGatewayServePortProbeForTest(Some({ _, _ =>
                if (calls.fetchAdd(1) == 0) { File.writeTo(lease, leaseText.replace("2000", "2001").toArray()) }
                (1, "", "")
            }))
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "identity_changed")
            @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
            File.writeTo(lease, leaseText.toArray())
            setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
            // A symlink to identical content is no longer the exclusively published lock.
            let lock = home.join("gateway-serve.lock")
            let ownedText = String.fromUtf8(File.readFrom(lock))
            let replacement = home.join("replacement-lock")
            File.writeTo(replacement, ownedText.toArray())
            remove(lock)
            @Expect(executeWithOutput("/bin/ln", ["-s", replacement.toString(), lock.toString()])[0], 0)
            @Expect(gatewayOwnsCurrentServeLock(), false)
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second).status, "lock_not_owned")
            remove(lock)
            File.writeTo(lock, ownedText.toArray())
            gatewayReleaseServeLockQuiet()
            @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second).status, "lock_not_owned")
        })
    }

    @TestCase
    public func hrS2N2UnknownBrokerAndSurfaceFailuresRemainBlocked(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteLease(home, identity)
            for (broker in ["broker_close_write_failed", "broker_close_eof_before_ack", "broker_close_ack_timeout", "broker_close_exit_timeout"]) {
                let _ = hrRuntimeWriteMarker(identity, broker: broker, terminal: false)
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            }
            let _ = hrRuntimeWriteMarker(identity, legacy: false, terminal: false)
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().ok, false)
            let original = hrRuntimeWriteMarker(identity)
            File.writeTo(home.join("gateway-serve.stop-complete"), original.replace("httpStatus:stopped", "httpStatus:close_failed").toArray())
            @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
            for (field in ["inboundStatus:stopped", "compatStatus:stopped", "sidecarStatus:disabled", "servicePluginIngressStatus:sent", "servicePluginDispatchStatus:cleanup_pending", "servicePluginOwnerStatus:terminated", "channelsStatus:stopped", "httpStatus:stopped", "canvasStatus:stopped", "gatewayServerStatus:stopped"]) {
                for (failure in ["close_failed", "timeout"]) {
                    let key = field.split(":")[0]
                    File.writeTo(home.join("gateway-serve.stop-complete"), original.replace(field, "${key}:${failure}").toArray())
                    @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "resources_not_terminal")
                }
            }
        })
    }

    @TestCase
    public func hrS2B2ConcurrentStartersHaveOneRecoveryCommitOwner(): Unit {
        hrRuntimeHome({ home, identity =>
            let _ = hrRuntimeWriteMarker(identity)
            let _ = hrRuntimeWriteLease(home, identity)
            let ready = AtomicInt64(0)
            let starters = Array(2, { _ => spawn {
                ready.fetchAdd(1)
                while (ready.load() != 2) { sleep(Duration.millisecond) }
                gatewayAcquireServeLockForRunningProcess()
            } })
            var successful: Int64 = 0
            for (future in starters) { if (future.get(Duration.second * 10)) { successful += 1 } }
            @Expect(successful, 1)
            @Expect(exists(home.join("gateway-serve.stop-complete")), false)
            @Expect(gatewayOwnsCurrentServeLock(), true)
            var committed: Int64 = 0
            for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                if (entry.name.endsWith(".completion")) { committed += 1 }
            }
            @Expect(committed, 1)
        })
    }
    @TestCase
    public func hrS2ArchiveBarrierRejectsAllChangedInputs(): Unit {
        for (fault in ["marker", "lock", "session", "encoding", "deadline", "exception"]) {
            hrRuntimeHome({ home, identity =>
                @Expect(gatewayAcquireServeLockForRunningProcess(), true)
                let original = hrRuntimeWriteMarker(identity)
                let lease = hrRuntimeWriteLease(home, identity)
                let leaseText = String.fromUtf8(File.readFrom(lease))
                let marker = home.join("gateway-serve.stop-complete")
                let lock = home.join("gateway-serve.lock")
                let lockText = String.fromUtf8(File.readFrom(lock))
                let business = home.join("pending-business.json")
                File.writeTo(business, "待处理🧪".toArray())
                let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
                let deadline = MonoTime.now() + Duration.second * 2
                let result = gatewayCommitHistoricalRecovery(evidence, deadline, afterArchive: { =>
                    match (fault) {
                        case "marker" => File.writeTo(marker, original.replace(identity.nonce, "新实例🧪").toArray())
                        case "lock" => File.writeTo(lock, lockText.replace("nonce:", "nonce:replacement-").toArray())
                        case "session" =>
                            remove(lease)
                            File.writeTo(lease.parent.join("replacement-session.lease.json"),
                                leaseText.replace("test-plugin-1", "replacement-session").toArray())
                        case "encoding" => File.writeTo(marker, [0xffu8, 0xfeu8])
                        case "deadline" => while (MonoTime.now() <= deadline) { sleep(Duration.millisecond * 5) }
                        case _ => throw Exception("controlled recovery barrier failure")
                    }
                })
                let expected = match (fault) {
                    case "marker" | "session" => "identity_changed"
                    case "lock" => "lock_not_owned"
                    case "encoding" => "invalid_response_encoding"
                    case "deadline" => "deadline_exceeded"
                    case _ => "recovery_revalidation_failed"
                }
                @Expect(result.status, expected)
                @Expect(result.ok, false)
                @Expect(exists(marker), true)
                @Expect(String.fromUtf8(File.readFrom(business)), "待处理🧪")
                if (fault == "marker") { @Expect(String.fromUtf8(File.readFrom(marker)).contains("新实例🧪"), true) }
                if (fault == "session") { @Expect(exists(lease.parent.join("replacement-session.lease.json")), true) }
                if (fault != "marker" && fault != "encoding") { @Expect(String.fromUtf8(File.readFrom(marker)), original) }
                var archived: Int64 = 0
                for (entry in Directory.readFrom(home.join("gateway-serve.recovery-history"))) {
                    if (entry.name.endsWith(".completion")) {
                        archived += 1
                        @Expect(String.fromUtf8(File.readFrom(entry.path)), original)
                    }
                }
                @Expect(archived, 1)
                if (fault == "lock") { File.writeTo(lock, lockText.toArray()) }
            })
        }
    }

    @TestCase
    public func hrS2ForeignListenerAppearingAfterArchiveStaysAlive(): Unit {
        hrRuntimeHome({ home, identity =>
            @Expect(gatewayAcquireServeLockForRunningProcess(), true)
            let original = hrRuntimeWriteMarker(identity)
            let lease = hrRuntimeWriteLease(home, identity)
            let leaseText = String.fromUtf8(File.readFrom(lease))
            let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
            try (listener = TcpServerSocket(bindAt: UInt16(gatewayConfiguredServePort()))) {
                let result = gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second,
                    afterArchive: { =>
                        listener.bind()
                        File.writeTo(lease, leaseText.replace("\"port\":0", "\"port\":${gatewayConfiguredServePort()}").toArray())
                        setServicePluginPortReleaseCommandForTest(None)
                    })
                @Expect(result.ok, false)
                @Expect(result.status, "port_active")
                @Expect(String.fromUtf8(File.readFrom(home.join("gateway-serve.stop-complete"))), original)
                // The foreign listener is still listening before test-owned cleanup closes it.
                @Expect(Int64((listener.localAddress as IPSocketAddress).getOrThrow().port), gatewayConfiguredServePort())
                let live = executeWithOutput("/usr/sbin/lsof", ["-nP", "-iTCP:${gatewayConfiguredServePort()}", "-sTCP:LISTEN", "-t"])
                @Expect(live[0], 0)
                @Expect(try { !String.fromUtf8(live[1]).trimAscii().isEmpty() } catch (_: Exception) { false }, true)
            }
        })
    }

    @TestCase
    public func hrS2RealCollectorLogsSchemaClassesAndSingleReconciliation(): Unit {
        hrRuntimeHome({ home, identity =>
            let oldFile = getVariable("METIS_LOG_FILE")
            let oldLevel = getVariable("METIS_LOG_LEVEL")
            let oldConsole = getVariable("METIS_CONSOLE_LEVEL")
            let file = home.join("recovery.jsonl")
            try {
                setVariable("METIS_LOG_FILE", file.toString())
                setVariable("METIS_LOG_LEVEL", "debug")
                setVariable("METIS_CONSOLE_LEVEL", "silent")
                gatewayLoggingResetForTest()
                gatewayLoggingCaptureConsoleForTest()
                @Expect(gatewayAcquireServeLockForRunningProcess(), true)
                let _ = hrRuntimeWriteMarker(identity)
                let _ = hrRuntimeWriteLease(home, identity)
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "recoverable")
                setServicePluginPidProbeCommandForTest(Some({ _, _ => (0, "", "") }))
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "pid_alive")
                setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
                setGatewayServePortProbeForTest(Some({ _, _ => (1, "partial", "") }))
                @Expect(gatewayHistoricalServeCompletionRecoveryStatus().status, "port_probe_failed")
                setGatewayServePortProbeForTest(Some({ _, _ => (1, "", "") }))
                let evidence = gatewayCollectHistoricalRecoveryEvidence(MonoTime.now() + Duration.second)
                @Expect(gatewayCommitHistoricalRecovery(evidence, MonoTime.now() + Duration.second * 3).status, "reconciled")
                let raw = String.fromUtf8(File.readFrom(file))
                @Expect(raw.contains(home.toString()), false)
                @Expect(raw.contains(identity.nonce), false)
                var reconciled: Int64 = 0
                var active: Int64 = 0
                var unknown: Int64 = 0
                var terminal: Int64 = 0
                for (line in raw.split("\n")) {
                    if (line.isEmpty()) { continue }
                    let row = JsonValue.fromStr(line).asObject()
                    let event = row.get("event").getOrThrow().asString().getValue()
                    if (![MetisLogEvent.gatewayRecoveryChecked, MetisLogEvent.gatewayRecoveryBlocked, MetisLogEvent.gatewayRecoveryReconciled].contains(event)) { continue }
                    @Expect(row.get("oldPid").getOrThrow().asInt().getValue(), identity.pid)
                    @Expect(row.get("identityHash").getOrThrow().asString().getValue().isEmpty(), false)
                    @Expect(row.get("historicalStatus").getOrThrow().asString().getValue(), "cleanup_pending")
                    @Expect(row.get("phase").getOrThrow().asString().getValue(), "historical_recovery")
                    @Expect(row.get("reason").getOrThrow().asString().getValue().isEmpty(), false)
                    @Expect(row.get("count").getOrThrow().asInt().getValue(), 1)
                    @Expect(row.get("durationMs").getOrThrow().asInt().getValue() >= 0, true)
                    match (row.get("resourceStatus").getOrThrow().asString().getValue()) {
                        case "terminal" => terminal += 1
                        case "active" => active += 1
                        case "unknown" => unknown += 1
                        case _ => @Expect(false, true)
                    }
                    if (event == MetisLogEvent.gatewayRecoveryReconciled) { reconciled += 1 }
                }
                @Expect(reconciled, 1)
                @Expect(active > 0 && unknown > 0 && terminal > 0, true)
                @Expect(gatewayLoggingCapturedConsoleForTest().size, 0)
                let archive = home.join("gateway-serve.recovery-history")
                let dirMode = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", archive.toString()])
                @Expect(try { String.fromUtf8(dirMode[1]).trimAscii() } catch (_: Exception) { "invalid" }, "700")
                for (entry in Directory.readFrom(archive)) {
                    let mode = executeWithOutput("/usr/bin/stat", ["-f", "%Lp", entry.path.toString()])
                    @Expect(try { String.fromUtf8(mode[1]).trimAscii() } catch (_: Exception) { "invalid" }, "600")
                }
            } finally {
                setVariable("METIS_LOG_FILE", oldFile.getOrDefault({ => "" }))
                setVariable("METIS_LOG_LEVEL", oldLevel.getOrDefault({ => "" }))
                setVariable("METIS_CONSOLE_LEVEL", oldConsole.getOrDefault({ => "" }))
                gatewayLoggingResetForTest()
            }
        })
    }

}
