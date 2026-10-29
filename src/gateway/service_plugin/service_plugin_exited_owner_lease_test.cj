package metis.gateway.service_plugin

import metis.utils.SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE
import std.collection.ArrayList
import std.env.getProcessId
import std.fs.{Directory, File, Path, exists, remove, rename}
import std.posix.chmod
import std.process.executeWithOutput
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func exitedLeaseTestIdentity(kind!: String = ""): ServicePluginExitedOwnerLeaseIdentity {
    ServicePluginExitedOwnerLeaseIdentity("sample-service", "sample-session", "sample-owner",
        Int64(getProcessId()) + 1000000, Int64(getProcessId()),
        if (kind == "generation") { 8 } else { 7 }, if (kind == "claim") { 10 } else { 9 },
        if (kind == "cleanup") { 12 } else { 11 })
}

private func exitedLeaseTestSnapshot(identity: ServicePluginExitedOwnerLeaseIdentity,
    kind!: String = ""): ServicePluginExitedOwnerLeaseSnapshot {
    let actual = ServicePluginExitedOwnerLeaseIdentity(
        if (kind == "service") { "foreign-service" } else { identity.serviceId },
        if (kind == "session") { "foreign-session" } else { identity.sessionId },
        if (kind == "owner") { "foreign-owner" } else { identity.ownerId },
        if (kind == "pid") { identity.pid + 1 } else { identity.pid },
        if (kind == "parent") { identity.parentPid + 1 } else { identity.parentPid },
        if (kind == "generation") { identity.generation + 1 } else { identity.generation },
        if (kind == "claim") { identity.claimToken + 1 } else { identity.claimToken },
        if (kind == "cleanup") { identity.cleanupToken + 1 } else { identity.cleanupToken })
    ServicePluginExitedOwnerLeaseSnapshot(actual,
        recordStatus: if (kind == "record_status") { "stopping" } else { "cleanup_pending" },
        recordSessionId: if (kind == "record_session") { "successor-session" } else { identity.sessionId },
        recordPid: if (kind == "record_pid") { identity.pid + 1 } else { identity.pid },
        finalStatus: if (kind == "manual") { "stopped" } else { "degraded" },
        finalReason: if (kind == "manual") { "manual_stop" } else if (kind == "unknown_reason") { "broker_unknown" } else { "process_exited" },
        activeSuccessor: kind == "successor", startClaim: kind == "start_claim",
        dispatchSettled: kind != "dispatch_active", dispatchFenced: kind != "dispatch_unfenced",
        shuttingDown: kind == "shutdown")
}

private func exitedLeaseTestJson(identity: ServicePluginExitedOwnerLeaseIdentity): String {
    let root = JsonObject()
    root.put("pluginId", JsonString(identity.serviceId)); root.put("sessionId", JsonString(identity.sessionId))
    root.put("state", JsonString("running")); root.put("status", JsonString("running"))
    root.put("pid", JsonInt(identity.pid)); root.put("parentPid", JsonInt(identity.parentPid))
    root.put("startedAtMs", JsonInt(1000)); root.put("lastHeartbeatMs", JsonInt(2000))
    root.put("port", JsonInt(20000 + DateTime.now().toUnixTimeStamp().toNanoseconds() % 30000))
    root.put("bindHost", JsonString("127.0.0.1"))
    root.put("stateFlushed", JsonBool(false)); root.put("businessProcessed", JsonBool(false))
    root.put("unknown中文", JsonString("保留🙂🚀"))
    root.toJsonString()
}

private func exitedLeaseTestPath(identity: ServicePluginExitedOwnerLeaseIdentity): Path {
    servicePluginRuntimeLeaseDir(identity.serviceId).join("${identity.sessionId}.lease.json")
}

private func exitedLeaseTestWrite(identity: ServicePluginExitedOwnerLeaseIdentity): String {
    let path = exitedLeaseTestPath(identity)
    if (!exists(path.parent)) { Directory.create(path.parent, recursive: true) }
    let original = exitedLeaseTestJson(identity)
    File.writeTo(path, original.toArray())
    original
}

private func exitedLeaseTestRead(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { "invalid_test_encoding" }
}

private func exitedLeaseTestProbes(): Unit {
    setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeout: Int64 => (Int64(1), "", "No such process") }))
    setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 => (Int64(1), "", "") }))
}

private func exitedLeaseTestCleanup(): Unit {
    setServicePluginExitedOwnerLeaseHookForTest(None<(String) -> Unit>)
    setServicePluginPidProbeCommandForTest(None<(Int64, Int64) -> (Int64, String, String)>)
    setServicePluginPortReleaseCommandForTest(None<(Int64, Int64, Int64) -> (Int64, String, String)>)
    setServicePluginMonotonicNowForTest(None<() -> Int64>)
}

private func exitedLeaseTestTempCount(path: Path): Int64 {
    var count: Int64 = 0
    for (entry in Directory.readFrom(path.parent)) { if (entry.name.startsWith(".owner-reconcile-")) { count++ } }
    count
}

@Test
public class ServicePluginExitedOwnerLeaseTest {
    @TestCase
    public func bpS3N1RetirementPositive(): Unit {
        withServicePluginHostTestHome("exited-r-p", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            exitedLeaseTestProbes()
            try {
                let snapshot = exitedLeaseTestSnapshot(identity)
                let guard = { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }
                @Expect(guard(), true)
                @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), guard), "retired")
                let read = servicePluginReadHistoricalLeaseStrict(path)
                @Expect(read.status, "ok"); @Expect(read.evidence.getOrThrow().state, "stopped")
                let result = JsonValue.fromStr(exitedLeaseTestRead(path)).asObject()
                let before = JsonValue.fromStr(original).asObject()
                for (key in ["pluginId", "sessionId", "pid", "parentPid", "port", "startedAtMs", "lastHeartbeatMs", "unknown中文", "stateFlushed", "businessProcessed"]) {
                    @Expect(result.get(key).getOrThrow().toJsonString(), before.get(key).getOrThrow().toJsonString())
                }
                @Expect(result.get("status").getOrThrow().asString().getValue(), "stopped")
                @Expect(result.get("hostReconciledBasis").getOrThrow().asString().getValue(), "owner_exit_pid_gone_port_released")
                let saved = exitedLeaseTestRead(path)
                @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), guard), "already_stopped")
                @Expect(exitedLeaseTestRead(path), saved)
                @Expect(exitedLeaseTestTempCount(path), 0)
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1RetirementUnicodeAndEvidenceLimit(): Unit {
        withServicePluginHostTestHome("exited-r-u-size", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            let snapshot = exitedLeaseTestSnapshot(identity)
            let guard = { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }
            let run = { => servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), guard) }
            exitedLeaseTestProbes()
            setServicePluginMonotonicNowForTest(Some({ => Int64(0) }))
            try {
                let longUnicode = StringBuilder()
                for (_ in 0..2000) { longUnicode.append("长🙂") }
                let unicodeRoot = JsonValue.fromStr(original).asObject()
                unicodeRoot.put("unknown中文", JsonString(longUnicode.toString()))
                let unicodeInput = unicodeRoot.toJsonString()
                @Expect(unicodeInput.toArray().size < 65536, true)
                File.writeTo(path, unicodeInput.toArray())
                @Expect(run(), "retired")
                @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "ok")
                @Expect(JsonValue.fromStr(exitedLeaseTestRead(path)).asObject().get("unknown中文").getOrThrow().asString().getValue(), longUnicode.toString())

                let overInput = StringBuilder()
                for (_ in 0..12000) { overInput.append("长🙂") }
                let oversizedRoot = JsonValue.fromStr(original).asObject()
                oversizedRoot.put("unknown中文", JsonString(overInput.toString()))
                let oversized = oversizedRoot.toJsonString().toArray()
                @Expect(oversized.size > 65536, true)
                File.writeTo(path, oversized)
                @Expect(run(), "evidence_limit_exceeded")
                @Expect(File.readFrom(path), oversized)

                let edge = JsonValue.fromStr(original).asObject()
                edge.put("unknown中文", JsonString(""))
                let fixedSize = edge.toJsonString().toArray().size
                let padding = StringBuilder()
                for (_ in 0..(65520 - fixedSize)) { padding.append("x") }
                edge.put("unknown中文", JsonString(padding.toString()))
                let nearLimit = edge.toJsonString().toArray()
                @Expect(nearLimit.size, 65520)
                File.writeTo(path, nearLimit)
                @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "ok")
                @Expect(run(), "evidence_limit_exceeded")
                @Expect(File.readFrom(path), nearLimit)
                @Expect(servicePluginReadHistoricalLeaseStrict(path).status, "ok")
                @Expect(exitedLeaseTestTempCount(path), 0)
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1RetirementIdentityNegative(): Unit {
        withServicePluginHostTestHome("exited-r-i", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            exitedLeaseTestProbes()
            try {
                // Exercise the production snapshot guard for each independent
                // ownership dimension; a fixed false callback is insufficient.
                for (kind in ["service", "session", "owner", "pid", "parent", "generation", "claim", "cleanup", "record_status", "record_session", "record_pid", "successor", "start_claim"]) {
                    let snapshot = exitedLeaseTestSnapshot(identity, kind: kind)
                    let guard = { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }
                    @Expect(guard(), false)
                    @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), guard), "cleanup_identity_changed")
                    @Expect(exitedLeaseTestRead(path), original)
                }
                for (key in ["pluginId", "sessionId", "pid", "parentPid"]) {
                    let json = JsonValue.fromStr(original).asObject()
                    if (key == "pid" || key == "parentPid") { json.put(key, JsonInt(identity.pid + 1)) }
                    else { json.put(key, JsonString("foreign-value")) }
                    let changed = json.toJsonString()
                    File.writeTo(path, changed.toArray())
                    let snapshot = exitedLeaseTestSnapshot(identity)
                    let status = servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000),
                        { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) })
                    @Expect(status == "identity_mismatch" || status == "lease_identity_mismatch", true)
                    @Expect(exitedLeaseTestRead(path), changed)
                }
                @Expect(exitedLeaseTestTempCount(path), 0)
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1RetirementResourceNegative(): Unit {
        withServicePluginHostTestHome("exited-r-r", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            try {
                for ((kind, expected) in [("alive", "pid_alive"), ("reused_pid", "pid_alive"),
                    ("permission", "pid_probe_permission_denied"), ("pid_timeout", "pid_probe_timeout"),
                    ("pid_encoding", "invalid_response_encoding"), ("pid_unknown", "pid_probe_unavailable"),
                    ("foreign_port", "port_release_timeout"), ("port_unknown", "port_probe_unavailable"),
                    ("port_timeout", "port_probe_timeout"), ("port_encoding", "invalid_response_encoding"),
                    ("dispatch_active", "cleanup_identity_changed"), ("dispatch_unfenced", "cleanup_identity_changed")]) {
                    exitedLeaseTestProbes()
                    setServicePluginPidProbeCommandForTest(Some({ _pid: Int64, _timeout: Int64 =>
                        match (kind) {
                            case "alive" | "reused_pid" => (Int64(0), "", "")
                            case "permission" => (Int64(1), "", "Operation not permitted")
                            case "pid_timeout" => (Int64(124), "", "")
                            case "pid_encoding" => (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "")
                            case "pid_unknown" => (Int64(42), "", "")
                            case _ => (Int64(1), "", "No such process")
                        }
                    }))
                    setServicePluginPortReleaseCommandForTest(Some({ _port: Int64, _pid: Int64, _timeout: Int64 =>
                        match (kind) {
                            case "foreign_port" => (Int64(0), "p999999", "")
                            case "port_unknown" => (Int64(1), "p999999", "")
                            case "port_timeout" => (Int64(124), "", "")
                            case "port_encoding" => (SHELL_INVALID_RESPONSE_ENCODING_EXIT_CODE, "", "")
                            case _ => (Int64(1), "", "")
                        }
                    }))
                    let snapshot = exitedLeaseTestSnapshot(identity, kind: kind)
                    @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000),
                        { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }), expected)
                    @Expect(exitedLeaseTestRead(path), original)
                    @Expect(exitedLeaseTestTempCount(path), 0)
                }
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1RetirementInputNegative(): Unit {
        withServicePluginHostTestHome("exited-r-u", { home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            let snapshot = exitedLeaseTestSnapshot(identity)
            let guard = { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }
            let run = { => servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), guard) }
            exitedLeaseTestProbes()
            try {
                for ((body, expected) in [("{malformed", "malformed_json"),
                    (original.replace("{", "{\"state\":\"running\","), "malformed_json"),
                    (original.replace("running", "future"), "lease_state_unknown")]) {
                    File.writeTo(path, body.toArray())
                    @Expect(run(), expected); @Expect(exitedLeaseTestRead(path), body)
                }
                let binary = [UInt8(0xff), UInt8(0xfe), UInt8(0), UInt8(1)]
                File.writeTo(path, binary)
                @Expect(run(), "invalid_response_encoding"); @Expect(File.readFrom(path), binary)
                File.writeTo(path, original.toArray())
                chmod(path.toString(), UInt32(0o000))
                try { @Expect(run(), "read_failed") } finally { chmod(path.toString(), UInt32(0o600)) }
                @Expect(exitedLeaseTestRead(path), original)
                let realFile = path.parent.join("original.json")
                rename(path, to: realFile)
                try {
                    @Expect(executeWithOutput("/bin/ln", ["-s", realFile.toString(), path.toString()])[0], 0)
                    @Expect(run(), "unsafe_path"); @Expect(exitedLeaseTestRead(realFile), original)
                } finally { if (exists(path)) { remove(path) }; rename(realFile, to: path) }
                let realDirectory = path.parent.parent.join("unlinked-directory")
                rename(path.parent, to: realDirectory)
                try {
                    @Expect(executeWithOutput("/bin/ln", ["-s", realDirectory.toString(), path.parent.toString()])[0], 0)
                    @Expect(run(), "unsafe_path")
                } finally { if (exists(path.parent)) { remove(path.parent) }; rename(realDirectory, to: path.parent) }
                let outside = ServicePluginExitedOwnerLeaseIdentity("../outside", identity.sessionId, identity.ownerId, identity.pid,
                    identity.parentPid, identity.generation, identity.claimToken, identity.cleanupToken)
                @Expect(servicePluginRetireExitedOwnerLease(outside, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000), { => true }), "identity_mismatch")
                @Expect(exitedLeaseTestRead(path), original)
                @Expect(exitedLeaseTestTempCount(path), 0)
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1RetirementRaceAndPersistence(): Unit {
        withServicePluginHostTestHome("exited-r-x", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let path = exitedLeaseTestPath(identity)
            try {
                for (kind in ["replace_file", "replace_at_rename", "owner_race", "owner_at_rename", "temp_fail", "write_fail", "rename_fail", "deadline"]) {
                    let original = exitedLeaseTestWrite(identity)
                    let replacement = original.replace("保留", "外部变更")
                    let observations = ArrayList<ServicePluginExitedOwnerLeaseSnapshot>()
                    observations.add(exitedLeaseTestSnapshot(identity))
                    exitedLeaseTestProbes()
                    setServicePluginExitedOwnerLeaseHookForTest(Some({ phase: String =>
                        if ((kind == "replace_file" && phase == "after_read") || (kind == "replace_at_rename" && phase == "before_rename")) { File.writeTo(path, replacement.toArray()) }
                        if ((kind == "owner_race" && phase == "before_commit") || (kind == "owner_at_rename" && phase == "before_rename")) { observations[0] = exitedLeaseTestSnapshot(identity, kind: "generation") }
                        if ((kind == "temp_fail" && phase == "before_temp") || (kind == "write_fail" && phase == "before_write") ||
                            (kind == "rename_fail" && phase == "before_rename")) { throw Exception("synthetic_persist_failure") }
                        if (kind == "deadline" && phase == "before_commit") {
                            let futureTime = servicePluginDeadlineNowMs() + 100000
                            setServicePluginMonotonicNowForTest(Some({ => futureTime }))
                        }
                    }))
                    let result = servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000),
                        { => servicePluginExitedOwnerLeaseGuardMatches(identity, observations[0]) })
                    let expected = match (kind) {
                        case "replace_file" | "replace_at_rename" => "lease_identity_changed"
                        case "owner_race" | "owner_at_rename" => "cleanup_identity_changed"
                        case "deadline" => "pid_probe_timeout"
                        case _ => "lease_reconcile_write_failed"
                    }
                    @Expect(result, expected)
                    @Expect(exitedLeaseTestRead(path), if (kind == "replace_file" || kind == "replace_at_rename") { replacement } else { original })
                    @Expect(exitedLeaseTestTempCount(path), 0)
                    exitedLeaseTestCleanup()
                    exitedLeaseTestProbes()
                    @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000),
                        { => servicePluginExitedOwnerLeaseGuardMatches(identity, exitedLeaseTestSnapshot(identity)) }), "retired")
                }
            } finally { exitedLeaseTestCleanup() }
        })
    }

    @TestCase
    public func bpS3N1SupervisorRetryEligibilityRejectsManualShutdownAndUnknownReason(): Unit {
        withServicePluginHostTestHome("exited-r-s-eligibility", { _home: Path =>
            let identity = exitedLeaseTestIdentity()
            let original = exitedLeaseTestWrite(identity)
            let path = exitedLeaseTestPath(identity)
            try {
                exitedLeaseTestProbes()
                for (kind in ["manual", "shutdown", "unknown_reason"]) {
                    let snapshot = exitedLeaseTestSnapshot(identity, kind: kind)
                    @Expect(servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot), false)
                    @Expect(servicePluginRetireExitedOwnerLease(identity, ServicePluginProbeDeadline(servicePluginDeadlineNowMs() + 1000),
                        { => servicePluginExitedOwnerLeaseGuardMatches(identity, snapshot) }), "cleanup_identity_changed")
                    @Expect(exitedLeaseTestRead(path), original)
                }
            } finally { exitedLeaseTestCleanup() }
        })
    }
}
