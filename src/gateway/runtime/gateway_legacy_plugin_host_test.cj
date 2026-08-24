package metis.gateway.runtime

import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonObject

private func p3ShellLegacyString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(value) => try {
            value.asString().getValue()
        } catch (_: Exception) {
            ""
        }
        case None => ""
    }
}

private func p3ShellLegacyRestoreEnvironment(key: String, previous: Option<String>): Unit {
    match (previous) {
        case Some(value) => setVariable(key, value)
        case None => setVariable(key, "")
    }
}

@Test
public class GatewayLegacyPluginHostTest {
    @TestCase
    public func p3P5LegacyHostInspectUsesFormalTimedShellPathInTemporaryHome(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-p3-shell-legacy-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let home = root.join("home")
            let project = root.join("project")
            let plugin = home.join("gateway-plugins").join("p3-shell-legacy")
            let oldHome = getVariable("METIS_HOME")
            let oldRoot = getVariable("METIS_CJPM_ROOT")
            try {
                Directory.create(plugin, recursive: true)
                Directory.create(project.join("scripts"), recursive: true)
                File.writeTo(
                    plugin.join("metis.plugin.json"),
                    "{\"id\":\"p3-shell-legacy\",\"gatewayRuntime\":{\"kind\":\"legacy-node-plugin\"}}".toArray()
                )
                File.writeTo(
                    project.join("scripts").join("legacy-channel-host.mjs"),
                    "process.stdout.write(JSON.stringify({ok:true,status:'ready',text:'中文🙂legacy'}));".toArray()
                )
                setVariable("METIS_HOME", home.toString())
                setVariable("METIS_CJPM_ROOT", project.toString())
                CliConfig.invalidatePathCache()

                let result = gatewayLegacyPluginHostInspect("p3-shell-legacy", timeoutMs: 2000)

                @Expect(p3ShellLegacyString(result, "status"), "ready")
                @Expect(p3ShellLegacyString(result, "text"), "中文🙂legacy")
                @Expect(p3ShellLegacyString(result, "hostOperation"), "inspect")
                @Expect(p3ShellLegacyString(result, "compatibilityMode"), "legacy-plugin-host")
            } finally {
                p3ShellLegacyRestoreEnvironment("METIS_HOME", oldHome)
                p3ShellLegacyRestoreEnvironment("METIS_CJPM_ROOT", oldRoot)
                CliConfig.invalidatePathCache()
                try {
                    remove(root, recursive: true)
                } catch (_: Exception) {
                    ()
                }
            }
        }
    }
}
