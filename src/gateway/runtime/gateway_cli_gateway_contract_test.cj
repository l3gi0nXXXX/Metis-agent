package metis.gateway.runtime

import metis.core.config.{CliSettingManager, MetisConfigManager}

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*

private func gatewayCliContractRestoreEnv(name: String, oldValue: Option<String>): Unit {
    match (oldValue) {
        case Some(value) => setVariable(name, value)
        case None => setVariable(name, "")
    }
}

private func withGatewayCliContractTestHome<T>(label: String, block: () -> T): T {
    let testHome = "/tmp/${label}"
    try {
        remove(Path(testHome), recursive: true)
    } catch (_: Exception) {
        ()
    }
    Directory.create(testHome, recursive: true)
    let oldHome = getVariable("METIS_HOME")
    let oldMode = getVariable("METIS_GATEWAY_CLI_MODE")
    setVariable("METIS_HOME", testHome)
    setVariable("METIS_GATEWAY_CLI_MODE", "")
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    try {
        return block()
    } finally {
        gatewayCliContractRestoreEnv("METIS_HOME", oldHome)
        gatewayCliContractRestoreEnv("METIS_GATEWAY_CLI_MODE", oldMode)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
    }
}

@Test
public class GatewayCliGatewayContractTest {
    @TestCase
    public func defaultCliClientUsesGatewayServeTransportWithoutRemoteUrl(): Unit {
        withGatewayCliContractTestHome<Unit>("metis-gateway-cli-contract-default-serve", { =>
            var settings = CliSettingManager.readGatewaySettings()
            settings.port = 28788
            settings.remote.enabled = false
            settings.remote.url = ""
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()

            let client = gatewayCliClient()
            @Expect(client.transport, "remote")
            @Expect(client.gatewayUrl, "http://127.0.0.1:28788")
            @Expect(client.gatewayUrl == "local://gateway", false)
        })
    }

    @TestCase
    public func explicitCliLocalModeIsRequiredForEmbeddedLocalClient(): Unit {
        withGatewayCliContractTestHome<Unit>("metis-gateway-cli-contract-explicit-local", { =>
            var settings = CliSettingManager.readGatewaySettings()
            settings.port = 28789
            settings.remote.enabled = false
            settings.remote.url = ""
            let _ = MetisConfigManager.setGatewaySettings(settings)
            setVariable("METIS_GATEWAY_CLI_MODE", "local")
            CliSettingManager.invalidate()

            let client = gatewayCliClient()
            @Expect(client.transport, "local")
            @Expect(client.gatewayUrl, "local://gateway")
        })
    }

    @TestCase
    public func explicitRemoteUrlStillWinsForCliClient(): Unit {
        withGatewayCliContractTestHome<Unit>("metis-gateway-cli-contract-remote-url", { =>
            var settings = CliSettingManager.readGatewaySettings()
            settings.port = 28790
            settings.remote.enabled = true
            settings.remote.transport = "remote"
            settings.remote.url = "https://gateway.example.test"
            let _ = MetisConfigManager.setGatewaySettings(settings)
            CliSettingManager.invalidate()

            let client = gatewayCliClient()
            @Expect(client.transport, "remote")
            @Expect(client.gatewayUrl, "https://gateway.example.test")
        })
    }
}
