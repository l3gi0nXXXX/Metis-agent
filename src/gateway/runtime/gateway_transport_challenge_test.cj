package metis.gateway.runtime

import metis.core.config.{CliConfig, CliSettingManager, GatewayUserSettings, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.protocol.{GatewayClientInfo, GatewayConnectParams, GatewayProtocolRequest}

import std.env.{getVariable, setVariable}
import std.convert.Parsable
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private let gatewayTransportChallengeTestHome = "/tmp/metis-gateway-transport-challenge-test-home"
private let gatewayTransportChallengeEndpoint = "http://127.0.0.1:19998"

private func gatewayTransportChallengeTestUser(): GatewayUserSettings {
    var user = GatewayUserSettings()
    user.port = 19998
    user.auth.mode = "none"
    user.remote.enabled = true
    user.remote.transport = "http"
    user.remote.url = gatewayTransportChallengeEndpoint
    user.cronEnabled = false
    return user
}

private func withGatewayTransportChallengeSettings<T>(block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        try {
            remove(Path(gatewayTransportChallengeTestHome), recursive: true)
        } catch (_: Exception) {
            ()
        }
        Directory.create(gatewayTransportChallengeTestHome, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", gatewayTransportChallengeTestHome)
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        let user = gatewayTransportChallengeTestUser()
        let _ = MetisConfigManager.setGatewaySettings(user)
        CliSettingManager.invalidate()
        try {
            block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
        }
    }
}

private func gatewayTransportChallengeConnect(): GatewayConnectParams {
    GatewayConnectParams(
        GatewayClientInfo("remote-challenge-cli", name: "remote-challenge-cli", mode: "local-cli"),
        transport: "remote",
        transportKind: "remote",
        gatewayUrl: gatewayTransportChallengeEndpoint,
        timeoutMs: 50,
        connectionId: "remote-challenge-connection"
    )
}

private func gatewayTransportChallengeBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func gatewayTransportChallengeString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func gatewayTransportChallengeInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { Int64.parse(v.toString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

@Test
public class GatewayTransportChallengeTest {
    @TestCase
    public func connectAckDoesNotTriggerRemoteReconnectBeforeAckRequest(): Unit {
        withGatewayTransportChallengeSettings<Unit>({ =>
            let adapter = RemoteGatewayTransportAdapter(gatewayTransportChallengeEndpoint, timeoutMs: 50)
            let params = JsonObject()
            params.put("challengeToken", JsonString("challenge-token-from-previous-response"))
            let response = adapter.request(
                GatewayProtocolRequest(
                    "connect.ack",
                    gatewayTransportChallengeConnect(),
                    params: params,
                    requestId: "remote-connect-ack-test"
                )
            )
            @Expect(response.ok, false)

            let transport = gatewayTransportRuntimeSnapshotFor("remote", gatewayTransportChallengeEndpoint)
            let remote = transport.get("remote").getOrThrow().asObject()
            @Expect(gatewayTransportChallengeInt(remote, "connectCount"), 0)
            @Expect(gatewayTransportChallengeInt(remote, "requestCount") > 0, true)
            @Expect(gatewayTransportChallengeString(remote, "lastError").isEmpty(), false)
            @Expect(gatewayTransportChallengeBool(remote, "connected"), false)
        })
    }
}
