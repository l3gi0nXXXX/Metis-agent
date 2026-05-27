package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.logging.gatewayLoggingResetForTest

import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonString}

private func logsOpsTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func logsOpsTestInt(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) => try { v.asInt().getValue() } catch (_: Exception) { -1 }
        case None => -1
    }
}

private func withLogsOpsTestHome<T>(block: () -> T): T {
    synchronized(MetisProcessEnvironmentLock) {
        let home = Path("/tmp/metis-gateway-logs-ops-${DateTime.now().toUnixTimeStamp().toMilliseconds()}")
        try { remove(home, recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        let oldHome = getVariable("METIS_HOME")
        let oldLogFile = getVariable("METIS_LOG_FILE")
        setVariable("METIS_HOME", home.toString())
        CliConfig.invalidatePathCache()
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        gatewayLoggingResetForTest()
        try {
            return block()
        } finally {
            match (oldHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => setVariable("METIS_HOME", "")
            }
            match (oldLogFile) {
                case Some(value) => setVariable("METIS_LOG_FILE", value)
                case None => setVariable("METIS_LOG_FILE", "")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            try { remove(home, recursive: true) } catch (_: Exception) { () }
        }
    }
}

@Test
public class GatewayServerMethodsOpsLogsTest {
    @TestCase
    public func logsStatusAndTailUseResolvedCurrentLogFile(): Unit {
        withLogsOpsTestHome {
            let logPath = CliConfig.logsDir.join("current-gateway.log")
            let first = "{\"time\":\"2026-05-18T10:00:00.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"one\",\"message\":\"one\"}\n"
            let second = "{\"time\":\"2026-05-18T10:00:01.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"two\",\"message\":\"two\"}\n"
            File.writeTo(logPath, "${first}${second}".toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let status = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.status"))
            @Expect(status.ok, true)
            let statusRoot = status.result.asObject()
            @Expect(logsOpsTestString(statusRoot, "currentLogFile"), logPath.toString())
            @Expect(statusRoot.get("currentLogFileExists").getOrThrow().asBool().getValue(), true)
            @Expect(logsOpsTestInt(statusRoot, "currentSize"), FileInfo(logPath).size)

            let params = JsonObject()
            params.put("limit", 1.toJsonValue())
            let tail = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: params))
            @Expect(tail.ok, true)
            let tailRoot = tail.result.asObject()
            @Expect(logsOpsTestString(tailRoot, "file"), logPath.toString())
            @Expect(tailRoot.get("cursor").isSome(), true)
            @Expect(tailRoot.get("size").isSome(), true)
            @Expect(tailRoot.get("truncated").isSome(), true)
            @Expect(tailRoot.get("reset").isSome(), true)
            let lines = tailRoot.get("lines").getOrThrow().asArray()
            @Expect(lines.size(), 1)
            @Expect(lines[0].asString().getValue().contains("\"event\":\"two\""), true)
        }
    }

    @TestCase
    public func logsTailKeepsUtf8WhenMaxBytesUsesByteCursor(): Unit {
        withLogsOpsTestHome {
            let logPath = CliConfig.logsDir.join("utf8-gateway.log")
            let first = "{\"time\":\"2026-05-18T10:00:00.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"first\",\"message\":\"前置日志\"}\n"
            let second = "{\"time\":\"2026-05-18T10:00:01.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"second\",\"message\":\"尾部中文\"}\n"
            File.writeTo(logPath, "${first}${second}".toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let params = JsonObject()
            params.put("limit", 5.toJsonValue())
            params.put("maxBytes", Int64(second.toArray().size).toJsonValue())
            let tail = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: params))
            @Expect(tail.ok, true)
            let rendered = tail.result.toJsonString()
            @Expect(rendered.contains("尾部中文"), true)
            @Expect(rendered.contains("前置日志"), false)
        }
    }

    @TestCase
    public func logsTailReadsBoundedWindowAndResetsOldCursors(): Unit {
        withLogsOpsTestHome {
            let logPath = CliConfig.logsDir.join("large-gateway.log")
            let builder = StringBuilder()
            for (idx in 0..12000) {
                builder.append("{\"time\":\"2026-05-18T10:00:00.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"old-${idx}\",\"message\":\"padding padding padding padding padding\"}\n")
            }
            let finalLine = "{\"time\":\"2026-05-18T10:00:01.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"final-large-window\",\"message\":\"tail survives\"}\n"
            builder.append(finalLine)
            File.writeTo(logPath, builder.toString().toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let params = JsonObject()
            params.put("limit", 5.toJsonValue())
            params.put("maxBytes", Int64(finalLine.toArray().size + 8).toJsonValue())
            let tail = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: params))
            @Expect(tail.ok, true)
            let root = tail.result.asObject()
            @Expect(logsOpsTestInt(root, "cursor"), FileInfo(logPath).size)
            @Expect(logsOpsTestInt(root, "size"), FileInfo(logPath).size)
            @Expect(root.get("truncated").getOrThrow().asBool().getValue(), true)
            let rendered = root.toJsonString()
            @Expect(rendered.contains("final-large-window"), true)
            @Expect(rendered.contains("old-0"), false)

            let staleParams = JsonObject()
            staleParams.put("cursor", 0.toJsonValue())
            staleParams.put("limit", 5.toJsonValue())
            staleParams.put("maxBytes", Int64(finalLine.toArray().size + 8).toJsonValue())
            let stale = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: staleParams))
            @Expect(stale.ok, true)
            let staleRoot = stale.result.asObject()
            @Expect(staleRoot.get("reset").getOrThrow().asBool().getValue(), true)
            @Expect(staleRoot.get("truncated").getOrThrow().asBool().getValue(), true)

            let movedParams = JsonObject()
            movedParams.put("cursor", (FileInfo(logPath).size + 100).toJsonValue())
            movedParams.put("limit", 5.toJsonValue())
            movedParams.put("maxBytes", Int64(finalLine.toArray().size + 8).toJsonValue())
            let moved = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: movedParams))
            @Expect(moved.ok, true)
            let movedRoot = moved.result.asObject()
            @Expect(movedRoot.get("reset").getOrThrow().asBool().getValue(), true)
            @Expect(logsOpsTestInt(movedRoot, "cursor"), FileInfo(logPath).size)
        }
    }

    @TestCase
    public func logsGetReturnsLastFortyLinesNewestFirst(): Unit {
        withLogsOpsTestHome {
            let logPath = CliConfig.logsDir.join("get-gateway.log")
            let builder = StringBuilder()
            for (idx in 0..50) {
                builder.append("{\"time\":\"2026-05-18T10:00:00.000+08:00\",\"level\":\"info\",\"subsystem\":\"gateway\",\"event\":\"line-${idx}\",\"message\":\"row\"}\n")
            }
            File.writeTo(logPath, builder.toString().toArray())
            setVariable("METIS_LOG_FILE", logPath.toString())
            gatewayLoggingResetForTest()

            let get = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.get"))
            @Expect(get.ok, true)
            let lines = get.result.asObject().get("tail").getOrThrow().asArray()
            @Expect(lines.size(), 40)
            @Expect(lines[0].asString().getValue().contains("\"event\":\"line-49\""), true)
            @Expect(lines[39].asString().getValue().contains("\"event\":\"line-10\""), true)
        }
    }

    @TestCase
    public func logsRejectUnsafeRequestedFileNames(): Unit {
        withLogsOpsTestHome {
            let attempts = ["/tmp/metis-secret-never-visible.log", "../secret.log", "sub/../secret.log", "nested/secret.log", "nested\\secret.log"]
            for (attempt in attempts) {
                let params = JsonObject()
                params.put("file", JsonString(attempt))
                let tail = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.tail", params: params))
                @Expect(tail.ok, false)
                @Expect(tail.errorCode, "INVALID_REQUEST")
                @Expect(tail.toJson().toJsonString().contains("secret-never-visible"), false)

                let get = gatewayDispatchLocalMethod(GatewayRpcRequest("logs.get", params: params))
                @Expect(get.ok, false)
                @Expect(get.errorCode, "INVALID_REQUEST")
            }
        }
    }
}
