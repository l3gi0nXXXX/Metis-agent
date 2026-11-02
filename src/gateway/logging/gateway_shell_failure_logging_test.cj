package metis.gateway.logging

import magic.config.Config
import metis.core.config.{CliConfig, CliSettingManager}
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Directory, File, remove}
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class GatewayShellFailureLoggingTest {
    @TestCase
    public func fdS2N4FileSinkRecoversOnceWithoutQueuedPayloads(): Unit {
        let home = Directory.createTemp("/tmp")
        let names = ["METIS_HOME", "METIS_LOG_FILE", "METIS_LOG_LEVEL", "METIS_CONSOLE_LEVEL"]
        let before = names.map({ name => getVariable(name) })
        let blocker = home.join("blocker")
        let file = blocker.join("owned.jsonl")
        try {
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_LOG_FILE", file.toString())
            setVariable("METIS_LOG_LEVEL", "debug")
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            File.writeTo(blocker, "owned".toArray())
            let report = gatewayCreateShellFailureReporter()
            for (_ in 0..1000) { report(7, "中文😀synthetic-secret") }
            remove(blocker)
            report(8, "captured")
            report(9, "timed")
            let text = try { String.fromUtf8(File.readFrom(file)) }
                catch (_: Exception) { throw Exception("owned_log_encoding_failed") }
            let lines = text.trimAscii().split("\n")
            @Expect(lines.size, 3)
            let recovery = JsonValue.fromStr(lines[0]).asObject()
            @Expect(recovery.get("event").getOrThrow().asString().getValue(), "logging.file.recovered")
            @Expect(recovery.get("failedRecords").getOrThrow().asInt().getValue(), 1000)
            @Expect(JsonValue.fromStr(lines[1]).asObject().get("exitCode").getOrThrow().asInt().getValue(), 8)
            @Expect(JsonValue.fromStr(lines[2]).asObject().get("exitCode").getOrThrow().asInt().getValue(), 9)
            @Expect(text.contains("synthetic-secret"), false)
        } finally {
            for (index in 0..names.size) {
                match (before[index]) {
                    case Some(value) => setVariable(names[index], value)
                    case None => removeVariable(names[index])
                }
            }
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            remove(home, recursive: true)
        }
    }

    @TestCase
    public func fdS2P1ShellFailuresAppendStructuredRedactedEvidence(): Unit {
        let home = Directory.createTemp("/tmp")
        let names = ["METIS_HOME", "METIS_LOG_FILE", "METIS_LOG_LEVEL", "METIS_CONSOLE_LEVEL"]
        let before = names.map({ name => getVariable(name) })
        let oldFile = Config.logFile
        let file = home.join("owned.jsonl")
        try {
            setVariable("METIS_HOME", home.toString())
            setVariable("METIS_LOG_FILE", file.toString())
            setVariable("METIS_LOG_LEVEL", "debug")
            setVariable("METIS_CONSOLE_LEVEL", "silent")
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            File.writeTo(file, "{\"sentinel\":\"中文😀\"}\n".toArray())
            let report = gatewayCreateShellFailureReporter()
            report(7, "中文😀synthetic-secret")
            let bytes = try { String.fromUtf8(File.readFrom(file)) }
                catch (_: Exception) { throw Exception("owned_log_encoding_failed") }
            @Expect(bytes.startsWith("{\"sentinel\":\"中文😀\"}\n"), true)
            @Expect(bytes.contains("synthetic-secret"), false)
            let row = JsonValue.fromStr(bytes.split("\n")[1]).asObject()
            @Expect(row.get("event").getOrThrow().asString().getValue(), "shell.command.failed")
            @Expect(row.get("commandKind").getOrThrow().asString().getValue(), "unknown")
            @Expect(row.get("exitCode").getOrThrow().asInt().getValue(), 7)
        } finally {
            for (index in 0..names.size) {
                match (before[index]) {
                    case Some(value) => setVariable(names[index], value)
                    case None => removeVariable(names[index])
                }
            }
            Config.logFile = oldFile
            CliConfig.invalidatePathCache()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            remove(home, recursive: true)
        }
    }
}
