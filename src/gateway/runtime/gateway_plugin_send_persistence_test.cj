package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisProcessEnvironmentLock}
import metis.gateway.core.{gatewayChannelRuntimeStatePath, resetGatewayChannelRuntimeObservationForTest}
import metis.process.ManagedStdioBrokerClient
import metis.utils.debugSetShellBrokerProviderForTest
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, Path, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

@Test
public class GatewayPluginSendPersistenceTest {
    @TestCase
    public func fdS2P2SuccessfulOrFailedSendSurvivesUnreadableObservation(): Unit {
        for (success in [true, false]) { pluginSendPersistenceFixture(success, true) }
    }

    @TestCase
    public func fdS2N3SuccessfulOrFailedSendSurvivesWriterFailure(): Unit {
        for (success in [true, false]) { pluginSendPersistenceFixture(success, false) }
    }
}

private func pluginSendPersistenceFixture(success: Bool, corrupt: Bool): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let root = Directory.createTemp("/tmp")
        let home = root.join("home")
        let project = root.join("project")
        let plugin = home.join("gateway-plugins").join("owned-send")
        let previousHome = getVariable("METIS_HOME")
        let previousRoot = getVariable("METIS_CJPM_ROOT")
        let previousConsole = getVariable("METIS_CONSOLE_LEVEL")
        let client = ManagedStdioBrokerClient()
        try {
            Directory.create(plugin, recursive: true)
            Directory.create(project.join("scripts"), recursive: true)
            File.writeTo(plugin.join("metis.plugin.json"),
                "{\"id\":\"owned-send\",\"gatewayRuntime\":{\"kind\":\"legacy-node-plugin\"}}".toArray())
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_CJPM_ROOT", project.toString())
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            let state = Path(gatewayChannelRuntimeStatePath())
            File.writeTo(state, "{}".toArray())
            let marker = root.join("sent.txt")
            let beforeState = root.join("before-state.bin")
            let damage = if (corrupt) {
                "fs.writeFileSync(${JsonString(state.toString()).toJsonString()},Buffer.from([255]));"
            } else { "fs.chmodSync(${JsonString(state.toString()).toJsonString()},0o444);" }
            File.writeTo(project.join("scripts").join("legacy-channel-host.mjs"),
                ("import fs from 'node:fs';if(process.argv[2]==='send'){" +
                "fs.copyFileSync(${JsonString(state.toString()).toJsonString()},${JsonString(beforeState.toString()).toJsonString()});" +
                "fs.appendFileSync(${JsonString(marker.toString()).toJsonString()},'1');" + damage +
                "process.stdout.write(JSON.stringify({ok:${success},text:'中文😀',reason:'owned-failure'}));}" +
                "else{process.stdout.write(JSON.stringify({ok:true}));}").toArray())
            debugSetShellBrokerProviderForTest(Some({ => client }))
            let params = JsonObject()
            params.put("pluginId", JsonString("owned-send"))
            params.put("accountId", JsonString("owned"))
            params.put("peerId", JsonString("owned-peer"))
            params.put("text", JsonString("中文😀"))
            let response = handleGatewayChannelsFamily("plugins.send", GatewayUserSettings(),
                request: Some(GatewayRpcRequest("plugins.send", params: params))).getOrThrow().result.asObject()
            @Expect(response.get("ok").getOrThrow().asBool().getValue(), success)
            @Expect(response.get("host").getOrThrow().asObject().get("text").getOrThrow().asString().getValue(), "中文😀")
            let runtime = response.get("runtime").getOrThrow().asObject()
            @Expect(runtime.get("persisted").getOrThrow().asBool().getValue(), false)
            @Expect(runtime.get("persistenceStatus").getOrThrow().asString().getValue(),
                if (corrupt) { "invalid_response_encoding" } else { "state_write_failed" })
            @Expect(File.readFrom(marker), "1".toArray())
            @Expect(File.readFrom(state), if (corrupt) { [0xffu8] } else { File.readFrom(beforeState) })
        } finally {
            client.close()
            debugSetShellBrokerProviderForTest(None)
            resetGatewayChannelRuntimeObservationForTest()
            for ((key, old) in [("METIS_HOME", previousHome), ("METIS_CJPM_ROOT", previousRoot),
                ("METIS_CONSOLE_LEVEL", previousConsole)]) {
                match (old) { case Some(value) => setVariable(key, value) case None => removeVariable(key) }
            }
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            remove(root, recursive: true)
        }
    }
}
