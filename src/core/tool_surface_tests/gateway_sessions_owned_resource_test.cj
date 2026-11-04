package metis.core.tool_surface_tests

import metis.core.tools.GatewaySessionsToolset
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.process.{observeProcessBirthIdentity}
import std.convert.Parsable
import stdx.encoding.json.{JsonValue, JsonString}
import std.collection.HashMap
import metis.process.{currentProcessInstanceIdentity, managedRecoveryInitialize, managedRecoveryStopOwnedChildren, managedRecoveryProbeRecords}
import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Path, File, Directory, exists, remove}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32 }

@When[os == "macOS"]
private func ownedFixtureFds(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("owned_fixture_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedFixtureRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("acp_fixture_contract_failed") }
}


@When[os == "macOS"]
@Test
public class GatewaySessionsOwnedResourceTest {
    @TestCase
    public func lN3ActualAcpCancelKeepsOwnerUntilReadersJoin(): Unit {
        let home = Path("/private/tmp/metis-acp-cancel-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let oldHome = getVariable("METIS_HOME")
        let oldDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        let oldParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let directory = home.join("owned")
        Directory.create(home)
        var terminal = false
        var formal = false
        var cancelCompleted = 0
        var fastCompleted = 0
        var firstError = None<Exception>
        try {
            setVariable("METIS_HOME", home.toString())
            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
            ownedFixtureRequire(managedRecoveryInitialize(directory, parent, "acp-cancel"))
            var settings = CliSettingManager.readGatewaySettings()
            settings.subagents.requireAgentId = false
            settings.subagents.allowAgents = ["*"]
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()
            let script = home.join("fake-acp.sh")
            File.writeTo(script, "trap '' TERM\nprintf '中文😀'; printf '错误😀' >&2\necho $$ > \"$1\"\nwhile :; do /bin/sleep 1; done\n".toArray())
            let toolset = GatewaySessionsToolset()
            let baseline = ownedFixtureFds()
            for (target in ["one", "all"]) {
                let ready = home.join("ready-${target}")
                let harness = "cmd:/bin/sh '${script.toString()}' '${ready.toString()}'"
                let response = toolset.sessionsSpawnForCommand("synthetic-cancel", Some("owned-cancel"), Some("acp"), Some(harness),
                    None, None, None, Some(home.toString()), Some<Int64>(30), None, None, None, Some("keep"), None, None)
                let parsed = JsonValue.fromStr(response).asObject()
                ownedFixtureRequire(parsed.get("liveRunStarted").getOrThrow().asBool().getValue())
                let session = parsed.get("sessionKey").getOrThrow().asString().getValue()
                let readyDeadline = MonoTime.now() + Duration.second * 5
                while (!exists(ready) && MonoTime.now() < readyDeadline) { sleep(Duration.millisecond * 5) }
                ownedFixtureRequire(exists(ready))
                let pidText = try { String.fromUtf8(File.readFrom(ready)).trimAscii() } catch (_: Exception) { throw Exception("acp_fixture_invalid_encoding") }
                let pid = Int64.parse(pidText)
                let birth = observeProcessBirthIdentity(pid).getOrThrow()
                let counts = toolset.debugManagedSubagentOwnerCountsForTest()
                ownedFixtureRequire(counts[0] == 1); ownedFixtureRequire(counts[1] == 1)
                let _ = toolset.subagents.invoke(HashMap<String, JsonValue>([
                    ("action", JsonString("kill")),
                    ("target", JsonString(if (target == "all") { "all" } else { session }))
                ]))
                let cleanupDeadline = MonoTime.now() + Duration.second * 10
                while (toolset.debugManagedSubagentOwnerCountsForTest() != (0, 0) && MonoTime.now() < cleanupDeadline) { sleep(Duration.millisecond * 5) }
                ownedFixtureRequire(toolset.debugManagedSubagentOwnerCountsForTest() == (0, 0))
                ownedFixtureRequire(observeProcessBirthIdentity(birth.pid).isNone())
                let source = managedRecoveryProbeRecords(directory, parent, "acp-cancel", cleanupDeadline)
                ownedFixtureRequire(source.ok && source.terminal)
                ownedFixtureRequire(ownedFixtureFds() == baseline)
                cancelCompleted++
            }
            for (_ in 0..32) {
                let response = toolset.sessionsSpawnForCommand("synthetic-fast", Some("owned-fast"), Some("acp"),
                    Some("cmd:/bin/sh -c 'printf 快完成😀; exit 0'"), None, None, None, Some(home.toString()),
                    Some<Int64>(30), None, None, None, Some("keep"), None, None)
                let parsed = JsonValue.fromStr(response).asObject()
                ownedFixtureRequire(parsed.get("liveRunStarted").getOrThrow().asBool().getValue())
                let deadline = MonoTime.now() + Duration.second * 5
                while (toolset.debugManagedSubagentOwnerCountsForTest() != (0, 0) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                ownedFixtureRequire(toolset.debugManagedSubagentOwnerCountsForTest() == (0, 0))
                ownedFixtureRequire(ownedFixtureFds() == baseline)
                let source = managedRecoveryProbeRecords(directory, parent, "acp-cancel", deadline)
                ownedFixtureRequire(source.ok && source.terminal)
                fastCompleted++
            }
            formal = cancelCompleted == 2 && fastCompleted == 32
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var proofSaved = false
            var restored = true
            try {
                File.writeTo(home.join("formal-before-fallback"),
                    "formal:${formal};cancelCompleted:${cancelCompleted};fastCompleted:${fastCompleted};bodyFailed:${firstError.isSome()}\n".toArray())
                proofSaved = true
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try {
                    terminal = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
                    if (!terminal) { throw Exception("acp_fixture_cleanup_pending") }
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    for ((key, previous) in [("METIS_HOME", oldHome), ("METIS_PROCESS_RECOVERY_DIRECTORY", oldDirectory), ("METIS_PROCESS_RECOVERY_PARENT", oldParent)]) {
                        try { match (previous) { case Some(value) => setVariable(key, value) case None => removeVariable(key) } }
                        catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                    }
                    try { CliConfig.invalidatePathCache() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                    try { MetisConfigManager.invalidate() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                    try { CliSettingManager.invalidate() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                }
            }
            if (formal && proofSaved && terminal && restored && firstError.isNone()) { remove(home, recursive: true) }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}
