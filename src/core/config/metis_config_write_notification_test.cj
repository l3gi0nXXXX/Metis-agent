package metis.core.config

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private class ConfigWriteNotificationCapture <: MetisConfigWriteNotificationListener {
    private let capturePath: Path

    public init(capturePath: Path) {
        this.capturePath = capturePath
    }

    public func onConfigWritten(event: MetisConfigWriteNotification): Unit {
        File.writeTo(this.capturePath, "${event.configPath}\n${event.persistedHash}".toArray())
    }
}

@Test
public class MetisConfigWriteNotificationTest {
    @TestCase
    public func writeRootEmitsInProcessNotificationWithoutReadingRealHome(): Unit {
        let testHome = Path("/tmp/metis-config-write-notification-${DateTime.now().toUnixTimeStamp().toMilliseconds()}").toString()
        try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
        Directory.create(testHome, recursive: true)

        let oldHome = getVariable("METIS_HOME")
        setVariable("METIS_HOME", testHome)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()

        let capturePath = Path(testHome).join("notification.txt")
        MetisConfigManager.setWriteRootNotificationHook(Some<MetisConfigWriteNotificationListener>(
            ConfigWriteNotificationCapture(capturePath)
        ))

        let root = JsonObject()
        let gateway = JsonObject()
        gateway.put("mode", JsonString("local"))
        root.put("gateway", gateway)
        MetisConfigManager.writeRoot(root)

        @Expect(exists(capturePath), true)
        let captured = if (exists(capturePath)) {
            String.fromUtf8(File.readFrom(capturePath)).split("\n")
        } else {
            Array<String>()
        }
        @Expect(captured.size >= 2, true)
        @Expect(if (captured.size >= 1) { captured[0] } else { "" }, MetisConfigManager.configPath().toString())
        @Expect(if (captured.size >= 2) { captured[1].isEmpty() } else { true }, false)

        MetisConfigManager.setWriteRootNotificationHook(None<MetisConfigWriteNotificationListener>)
        match (oldHome) {
            case Some(value) => setVariable("METIS_HOME", value)
            case None => setVariable("METIS_HOME", "")
        }
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        try { remove(Path(testHome), recursive: true) } catch (_e: Exception) { () }
    }
}
