package metis.gateway.service_plugin

import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import metis.utils.SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE
import std.core.Duration
import std.collection.ArrayList
import std.sync.AtomicInt64
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.process.executeWithOutput
import std.posix.chmod
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

private func hrHostHome(block: (Path) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-hr-host-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let before = getVariable("METIS_HOME")
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
        setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
        try { block(home) } finally {
            setServicePluginPidProbeCommandForTest(None)
            setServicePluginPortReleaseCommandForTest(None)
            setServicePluginPortOwnerProbeForTest(None)
            setVariable("METIS_HOME", before.getOrDefault({ => "" }))
            CliConfig.invalidatePathCache()
            remove(home, recursive: true)
            @Expect(exists(home), false)
        }
    }
}

private func hrHostLease(home: Path, session: String, parent!: Int64 = 987654321,
    state!: String = "stopped", started!: Int64 = 2000, port!: Int64 = 0): Path {
    let dir = home.join("service-plugin").join("runtime").join("test-plugin")
    if (!exists(dir)) { Directory.create(dir, recursive: true) }
    let path = dir.join("${session}.lease.json")
    File.writeTo(path, ("{\"pluginId\":\"test-plugin\",\"sessionId\":\"${session}\",\"state\":\"${state}\"," +
        "\"pid\":987654322,\"parentPid\":${parent},\"startedAtMs\":${started},\"port\":${port},\"note\":\"历史恢复-测试🧪\"}").toArray())
    path
}

@Test
public class ServicePluginHistoricalRecoveryTest {
    @TestCase
    public func hr30U1KnownActiveLeaseRequiresLiveTerminalEvidence(): Unit {
        for (state in ["running", "starting", "stopping"]) {
            hrHostHome({ home =>
                let path = hrHostLease(home, "历史恢复-测试🧪", state: state, port: 12345)
                let original = File.readFrom(path)
                let business = home.join("pending-business.json")
                File.writeTo(business, "待处理中文🧪".toArray())
                let businessBytes = File.readFrom(business)
                let result = probeServicePluginHistoricalResources(987654321, 1000,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(result.conclusive, true)
                @Expect(result.terminal, true)
                @Expect(result.status, "terminal")
                @Expect(result.matchedCount, 1)
                @Expect(File.readFrom(path), original)
                @Expect(File.readFrom(business), businessBytes)
            })
        }
    }

    @TestCase
    public func hr30P1MixedLeaseSnapshotIsReadOnlyAndRevalidated(): Unit {
        hrHostHome({ home =>
            let before = listServicePlugins().toArray()
            let paths = [hrHostLease(home, "terminal"), hrHostLease(home, "running", state: "running"),
                hrHostLease(home, "starting", state: "starting"), hrHostLease(home, "stopping", state: "stopping")]
            let originals = ArrayList<Array<UInt8>>()
            for (path in paths) { originals.add(File.readFrom(path)) }
            let business = home.join("pending-business.json")
            File.writeTo(business, "待处理中文🧪".toArray())
            let businessBytes = File.readFrom(business)
            let probedPids = ArrayList<Int64>()
            let healthCalls = AtomicInt64(0)
            setServicePluginPidProbeCommandForTest(Some({ pid, _ =>
                probedPids.add(pid)
                (1, "", "No such process")
            }))
            setServicePluginHealthzProbeForTest(Some({ _, _ =>
                healthCalls.fetchAdd(1)
                ServicePluginHealthzProbeResult(false, diagnostic: "unexpected_historical_http_probe")
            }))
            try {
                let found = probeServicePluginHistoricalResources(987654321, 1000,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(found.conclusive, true)
                @Expect(found.terminal, true)
                @Expect(found.status, "terminal")
                @Expect(found.matchedCount, 4)
                let again = revalidateServicePluginHistoricalEvidence(found,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(again.conclusive, true)
                @Expect(again.terminal, true)
                @Expect(again.status, "terminal")
                @Expect(again.matchedCount, 4)
                @Expect(probedPids.size, 8)
                for (pid in probedPids) { @Expect(pid, 987654322) }
                @Expect(healthCalls.load(), 0)
                for (i in 0..paths.size) { @Expect(File.readFrom(paths[i]), originals[i]) }
                @Expect(File.readFrom(business), businessBytes)
                @Expect(listServicePlugins().size, before.size)
                for (entry in before) {
                    let after = getServicePluginSnapshot(entry.serviceId).getOrThrow()
                    @Expect(after.instanceId, entry.instanceId)
                    @Expect(after.pid, entry.pid)
                    @Expect(after.status, entry.status)
                    @Expect(after.enabled, entry.enabled)
                    @Expect(after.configSummary, entry.configSummary)
                    @Expect(after.capabilityIds, entry.capabilityIds)
                    @Expect(after.lastHeartbeatAtMillis, entry.lastHeartbeatAtMillis)
                    @Expect(after.lastError, entry.lastError)
                    @Expect(after.supervisorRestartCount, entry.supervisorRestartCount)
                }
            } finally { setServicePluginHealthzProbeForTest(None) }
        })
    }

    @TestCase
    public func hr30B1ActiveLeaseKeepsDeadlineIdentityAndStrictReaderBounds(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "历史恢复-测试🧪", state: "running")
            let original = String.fromUtf8(File.readFrom(path))
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now(),
                allowStaleActiveLease: true).status, "probe_timeout")
            @Expect(probeServicePluginHistoricalResources(987654320, 1000, MonoTime.now() + Duration.second,
                allowStaleActiveLease: true).status, "lease_evidence_missing")
            @Expect(probeServicePluginHistoricalResources(987654321, 2001, MonoTime.now() + Duration.second,
                allowStaleActiveLease: true).status, "identity_mismatch")
            let padded = original + String(Array<Rune>(65536 - original.size, repeat: r' '))
            File.writeTo(path, padded.toArray())
            let bound = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second,
                allowStaleActiveLease: true)
            @Expect(bound.status, "terminal")
            @Expect(bound.terminal, true)
            for ((bytes, status) in [((padded + " ").toArray(), "evidence_limit_exceeded"),
                ("{坏JSON🧪".toArray(), "malformed_json"),
                ([0xffu8, 0xfeu8, 0x00u8], "invalid_response_encoding")]) {
                File.writeTo(path, bytes)
                let result = probeServicePluginHistoricalResources(987654321, 1000,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(result.status, status)
                @Expect(result.conclusive, false)
                @Expect(result.terminal, false)
                @Expect(File.readFrom(path), bytes)
            }
        })
    }

    @TestCase
    public func hr30N1ActiveLeaseCannotBypassPidPortOrUnknownStateFailures(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "one", state: "running", port: 12345)
            let original = File.readFrom(path)
            for ((exit, error, expected, conclusive) in [
                (Int64(0), "", "pid_alive", true),
                (Int64(1), "Operation not permitted", "pid_probe_permission_denied", false),
                (Int64(124), "", "pid_probe_timeout", false),
                (Int64(126), "", "pid_probe_unavailable", false),
                (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "invalid_response_encoding", false)]) {
                setServicePluginPidProbeCommandForTest(Some({ _, _ => (exit, "", error) }))
                let result = probeServicePluginHistoricalResources(987654321, 1000,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(result.status, expected)
                @Expect(result.conclusive, conclusive)
                @Expect(result.terminal, false)
                @Expect(File.readFrom(path), original)
            }
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
            for ((exit, output, error, expected, conclusive) in [
                (Int64(0), "p4321", "", "port_active", true),
                (Int64(1), "p4321", "", "port_probe_unavailable", false),
                (Int64(124), "", "", "port_probe_timeout", false),
                (Int64(0), "", "", "port_probe_invalid", false),
                (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "", "invalid_response_encoding", false),
                (Int64(1), "", "Operation not permitted", "port_probe_unavailable", false)]) {
                setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (exit, output, error) }))
                let result = probeServicePluginHistoricalResources(987654321, 1000,
                    MonoTime.now() + Duration.second, allowStaleActiveLease: true)
                @Expect(result.status, expected)
                @Expect(result.conclusive, conclusive)
                @Expect(result.terminal, false)
                @Expect(File.readFrom(path), original)
            }
            setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
            let _ = hrHostLease(home, "one", state: "unknown-external-state")
            let unknownBytes = File.readFrom(path)
            let unknown = probeServicePluginHistoricalResources(987654321, 1000,
                MonoTime.now() + Duration.second, allowStaleActiveLease: true)
            @Expect(unknown.status, "lease_state_unknown")
            @Expect(unknown.conclusive, false)
            @Expect(unknown.terminal, false)
            @Expect(File.readFrom(path), unknownBytes)
        })
    }

    @TestCase
    public func hr30N2ActiveLeaseReplacementInvalidatesSnapshot(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "one", state: "running")
            let result = probeServicePluginHistoricalResources(987654321, 1000,
                MonoTime.now() + Duration.second, allowStaleActiveLease: true)
            @Expect(result.terminal, true)
            let changed = String.fromUtf8(File.readFrom(path)).replace("2000", "2001")
            File.writeTo(path, changed.toArray())
            let after = revalidateServicePluginHistoricalEvidence(result, MonoTime.now() + Duration.second,
                allowStaleActiveLease: true)
            @Expect(after.status, "identity_changed")
            @Expect(after.conclusive, false)
            @Expect(after.terminal, false)
            @Expect(String.fromUtf8(File.readFrom(path)), changed)
            remove(path)
            let replacement = hrHostLease(home, "new-session", state: "running")
            let bytes = File.readFrom(replacement)
            let sessionChanged = revalidateServicePluginHistoricalEvidence(result,
                MonoTime.now() + Duration.second, allowStaleActiveLease: true)
            @Expect(sessionChanged.status, "identity_changed")
            @Expect(sessionChanged.conclusive, false)
            @Expect(sessionChanged.terminal, false)
            @Expect(File.readFrom(replacement), bytes)
        })
    }

    @TestCase
    public func hrS1U2CollectsAllOldParentLeaseEvidence(): Unit {
        hrHostHome({ home =>
            let first = hrHostLease(home, "one")
            let second = hrHostLease(home, "two")
            File.writeTo(first.parent.join("listener-diagnostics.log"), [0xffu8])
            File.writeTo(first.parent.join("lease-diagnostics.log"), [0xfeu8])
            let result = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(result.conclusive, true)
            @Expect(result.terminal, true)
            @Expect(result.matchedCount, 2)
            @Expect(result.status, "terminal")
            @Expect(servicePluginReadHistoricalLeaseStrict(second).status, "ok")
        })
    }

    @TestCase
    public func hrS1B1StrictLeaseScanBoundsEncodingAndPaths(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "one")
            let valid = String.fromUtf8(File.readFrom(path))
            let padded = valid + String(Array<Rune>(65536 - valid.size, repeat: r' '))
            File.writeTo(path, padded.toArray())
            @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "ok")
            File.writeTo(path, (padded + " ").toArray())
            @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "evidence_limit_exceeded")
            File.writeTo(path, [0xffu8, 0xfeu8, 0x00u8])
            @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "invalid_response_encoding")
            for (invalid in ["{", "{\"state\":\"stopped\",\"state\":\"running\"}",
                "{\"state\":\"stopped\",\"sta\\u0074e\":\"running\"}"]) {
                File.writeTo(path, invalid.toArray())
                @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "malformed_json")
            }
            File.writeTo(path, valid.replace("\"one\"", "\"../escape\"").toArray())
            @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "identity_mismatch")
            File.writeTo(path, valid.toArray())
            let outside = home.join("outside-lease.json")
            File.writeTo(outside, valid.toArray())
            remove(path)
            @Expect(executeWithOutput("/bin/ln", ["-s", outside.toString(), path.toString()])[0], 0)
            @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "unsafe_path")
            remove(path)
            File.writeTo(path, valid.toArray())
            // One plugin directory plus 4095 lease entries is exactly the scan-item bound.
            for (i in 1..4095) { let _ = hrHostLease(home, "entry-${i}") }
            let atBound = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second * 30)
            @Expect(atBound.status, "terminal")
            @Expect(atBound.matchedCount, 4095)
            let _ = hrHostLease(home, "over-bound")
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second * 30).status, "evidence_limit_exceeded")
        })
        hrHostHome({ home =>
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).status, "lease_evidence_missing")
            Directory.create(home.join("service-plugin/runtime"), recursive: true)
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).status, "lease_evidence_missing")
        })
    }

    @TestCase
    public func hrS1P1OldParentProbeIsReadOnlyAndKeepsPendingData(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "历史恢复-测试🧪")
            let original = File.readFrom(path)
            let pending = home.join("business-pending.json")
            File.writeTo(pending, "{\"pending\":\"中文🧪\"}".toArray())
            let business = File.readFrom(pending)
            let result = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(result.terminal, true)
            @Expect(revalidateServicePluginHistoricalEvidence(result, MonoTime.now() + Duration.second).terminal, true)
            @Expect(File.readFrom(path), original)
            @Expect(File.readFrom(pending), business)
            @Expect(probeServicePluginHistoricalResources(987654320, 1000, MonoTime.now() + Duration.second).status, "lease_evidence_missing")
        })
    }

    @TestCase
    public func hrS1N1LeasePidAndPortFailuresNeverBecomeTerminal(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "one", state: "running")
            let active = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(active.status, "lease_active")
            @Expect(active.terminal, false)
            let _ = hrHostLease(home, "one", port: 12345)
            for (input in [(0, "", ""), (1, "", "Operation not permitted"), (124, "", ""), (125, "", "")]) {
                setServicePluginPidProbeCommandForTest(Some({ _, _ => input }))
                @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).terminal, false)
            }
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
            for (input in [(0, "p1234", ""), (1, "p1234", ""), (124, "", ""), (125, "", ""), (1, "", "denied")]) {
                setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => input }))
                @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).terminal, false)
            }
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "") }))
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).status, "invalid_response_encoding")
            @Expect(exists(path), true)
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now()).status, "probe_timeout")
        })
    }

    @TestCase
    public func hrS1N2ReplacedLeaseInvalidatesCollectedEvidence(): Unit {
        hrHostHome({ home =>
            let path = hrHostLease(home, "one")
            let result = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(result.terminal, true)
            let changed = String.fromUtf8(File.readFrom(path)).replace("2000", "2001")
            File.writeTo(path, changed.toArray())
            let after = revalidateServicePluginHistoricalEvidence(result, MonoTime.now() + Duration.second)
            @Expect(after.terminal, false)
            @Expect(after.status, "identity_changed")
            @Expect(String.fromUtf8(File.readFrom(path)), changed)
        })
    }
    @TestCase
    public func hrS1ContractBranchesHavePreciseReasonsAndRegistryIsolation(): Unit {
        hrHostHome({ home =>
            let before = listServicePlugins().toArray()
            let path = hrHostLease(home, "one", port: 12345)
            for ((exit, error, expected, conclusive) in [
                (Int64(0), "", "pid_alive", true), (Int64(1), "Operation not permitted", "pid_probe_permission_denied", false),
                (Int64(124), "", "pid_probe_timeout", false), (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "invalid_response_encoding", false)]) {
                setServicePluginPidProbeCommandForTest(Some({ _, _ => (exit, "", error) }))
                let result = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
                @Expect(result.status, expected)
                @Expect(result.conclusive, conclusive)
                @Expect(result.terminal, false)
            }
            setServicePluginPidProbeCommandForTest(Some({ _, _ => (1, "", "No such process") }))
            for ((exit, output, error, expected, conclusive) in [
                (Int64(0), "p4321", "", "port_active", true), (Int64(1), "p4321", "", "port_probe_unavailable", false),
                (Int64(124), "", "", "port_probe_timeout", false),
                (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "", "invalid_response_encoding", false),
                (Int64(1), "", "Operation not permitted", "port_probe_unavailable", false)]) {
                setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (exit, output, error) }))
                let result = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
                @Expect(result.status, expected)
                @Expect(result.conclusive, conclusive)
                @Expect(result.terminal, false)
            }
            setServicePluginPortReleaseCommandForTest(Some({ _, _, _ => (1, "", "") }))
            chmod(path.toString(), UInt32(0o000))
            try { @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "read_failed") }
            finally { chmod(path.toString(), UInt32(0o600)) }
            chmod(path.parent.toString(), UInt32(0o000))
            try {
                let denied = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
                @Expect(denied.terminal, false)
                @Expect(denied.conclusive, false)
                @Expect(denied.status, "scan_failed")
            } finally { chmod(path.parent.toString(), UInt32(0o700)) }
            let _ = hrHostLease(home, "one", state: "unknown-external-state")
            let unknown = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(unknown.status, "lease_state_unknown")
            @Expect(unknown.conclusive, false)
            @Expect(unknown.terminal, false)
            remove(path)
            @Expect(probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second).status, "lease_evidence_missing")
            @Expect(listServicePlugins().size, before.size)
            for (entry in before) {
                let after = getServicePluginSnapshot(entry.serviceId).getOrThrow()
                @Expect(after.instanceId, entry.instanceId)
                @Expect(after.pid, entry.pid)
                @Expect(after.status, entry.status)
            }
        })
    }

    @TestCase
    public func hrS1N2SessionReplacementInvalidatesCompleteSnapshot(): Unit {
        hrHostHome({ home =>
            let old = hrHostLease(home, "old-session")
            let evidence = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
            @Expect(evidence.terminal, true)
            remove(old)
            let replacement = hrHostLease(home, "new-session")
            let bytes = File.readFrom(replacement)
            let result = revalidateServicePluginHistoricalEvidence(evidence, MonoTime.now() + Duration.second)
            @Expect(result.status, "identity_changed")
            @Expect(result.conclusive, false)
            @Expect(result.terminal, false)
            @Expect(File.readFrom(replacement), bytes)
        })
    }

    @TestCase
    public func hrS1PositiveHistoricalProbeNeverTouchesHttpOrRegistry(): Unit {
        hrHostHome({ home =>
            let before = listServicePlugins().toArray()
            let first = hrHostLease(home, "positive-one")
            let second = hrHostLease(home, "positive-two")
            let firstBytes = File.readFrom(first)
            let secondBytes = File.readFrom(second)
            let business = home.join("pending-business.json")
            File.writeTo(business, "待处理中文🧪".toArray())
            let businessBytes = File.readFrom(business)
            let healthCalls = AtomicInt64(0)
            let probedPids = ArrayList<Int64>()
            setServicePluginHealthzProbeForTest(Some({ _, _ =>
                healthCalls.fetchAdd(1)
                ServicePluginHealthzProbeResult(false, diagnostic: "unexpected_historical_http_probe")
            }))
            setServicePluginPidProbeCommandForTest(Some({ pid, _ =>
                probedPids.add(pid)
                (1, "", "No such process")
            }))
            try {
                let found = probeServicePluginHistoricalResources(987654321, 1000, MonoTime.now() + Duration.second)
                @Expect(found.conclusive, true)
                @Expect(found.terminal, true)
                @Expect(found.matchedCount, 2)
                let again = revalidateServicePluginHistoricalEvidence(found, MonoTime.now() + Duration.second)
                @Expect(again.conclusive, true)
                @Expect(again.terminal, true)
                @Expect(again.matchedCount, 2)
                @Expect(probedPids.size, 4)
                for (pid in probedPids) { @Expect(pid, 987654322) }
                @Expect(healthCalls.load(), 0)
                @Expect(listServicePlugins().size, before.size)
                for (entry in before) {
                    let after = getServicePluginSnapshot(entry.serviceId).getOrThrow()
                    @Expect(after.instanceId, entry.instanceId)
                    @Expect(after.pid, entry.pid)
                    @Expect(after.status, entry.status)
                    @Expect(after.enabled, entry.enabled)
                    @Expect(after.configSummary, entry.configSummary)
                    @Expect(after.capabilityIds, entry.capabilityIds)
                    @Expect(after.lastHeartbeatAtMillis, entry.lastHeartbeatAtMillis)
                    @Expect(after.lastError, entry.lastError)
                    @Expect(after.supervisorRestartCount, entry.supervisorRestartCount)
                }
                @Expect(File.readFrom(first), firstBytes)
                @Expect(File.readFrom(second), secondBytes)
                @Expect(File.readFrom(business), businessBytes)
            } finally { setServicePluginHealthzProbeForTest(None) }
        })
    }

}
