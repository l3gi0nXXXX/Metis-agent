package metis.gateway.runtime

import magic.jsonable.*

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.gateway.logging.gatewayLoggingResetForTest
import magic.config.Config

import std.env.{getVariable, removeVariable, setVariable}
import std.fs.{Directory, File, FileInfo, Path, canonicalize, exists, remove}
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
        let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let home = Path("/tmp/metis-gateway-logs-ops-${stamp}")
        let parent = home.parent
        let identityOk = stamp > 0 && home.toString() == "/tmp/metis-gateway-logs-ops-${stamp}" &&
            parent.toString() == "/tmp" && canonicalize(parent).toString() == "/private/tmp" &&
            home.fileName == "metis-gateway-logs-ops-${stamp}"
        var existingIdentityOk = true
        let targetIsSymlink = try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false }
        if (exists(home)) {
            let info = FileInfo(home)
            existingIdentityOk = info.isDirectory() && !info.isSymbolicLink()
        }
        if (!identityOk || targetIsSymlink || !existingIdentityOk || exists(home)) {
            throw Exception("s3j_owned_home_identity_invalid")
        }
        let oldHome = getVariable("METIS_HOME")
        let oldLogFile = getVariable("METIS_LOG_FILE")
        let oldConfigLogFile = Config.logFile
        var homeCreated = false
        try {
            Directory.create(home, recursive: false)
            homeCreated = true
            setVariable("METIS_HOME", home.toString())
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            return block()
        } finally {
            var cleanupFailure = ""
            try {
                try {
                    match (oldHome) {
                        case Some(value) => setVariable("METIS_HOME", value)
                        case None => removeVariable("METIS_HOME")
                    }
                } catch (_: Exception) {
                    cleanupFailure = "s3j_env_restore_failed"
                }
                try {
                    match (oldLogFile) {
                        case Some(value) => setVariable("METIS_LOG_FILE", value)
                        case None => removeVariable("METIS_LOG_FILE")
                    }
                } catch (_: Exception) {
                    if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_env_restore_failed" }
                }
            } finally {
                try {
                    try {
                        CliConfig.invalidatePathCache()
                    } catch (_: Exception) {
                        if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_cache_restore_failed" }
                    }
                    try {
                        MetisConfigManager.invalidate()
                    } catch (_: Exception) {
                        if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_cache_restore_failed" }
                    }
                    try {
                        CliSettingManager.invalidate()
                    } catch (_: Exception) {
                        if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_cache_restore_failed" }
                    }
                } finally {
                    try {
                        try {
                            gatewayLoggingResetForTest()
                        } catch (_: Exception) {
                            if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_logging_reset_failed" }
                        }
                    } finally {
                        try {
                            try {
                                Config.logFile = oldConfigLogFile
                                @Expect(Config.logFile, oldConfigLogFile)
                                if (Config.logFile != oldConfigLogFile && cleanupFailure.isEmpty()) {
                                    cleanupFailure = "s3j_config_restore_failed"
                                }
                            } catch (_: Exception) {
                                if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_config_restore_failed" }
                            }
                        } finally {
                            try {
                                if (homeCreated && exists(home)) { remove(home, recursive: true) }
                            } catch (_: Exception) {
                                if (cleanupFailure.isEmpty()) { cleanupFailure = "s3j_owned_home_remove_failed" }
                            }
                            let remains = homeCreated && (exists(home) ||
                                try { FileInfo(home).isSymbolicLink() } catch (_: Exception) { false })
                            @Expect(remains, false)
                            if (remains && cleanupFailure.isEmpty()) {
                                cleanupFailure = "s3j_owned_home_cleanup_failed"
                            }
                            if (!cleanupFailure.isEmpty()) { throw Exception(cleanupFailure) }
                        }
                    }
                }
            }
        }
    }
}

@Test
public class GatewayServerMethodsOpsLogsTest {
    @TestCase
    public func s3jB1DynamicHomeRestoresMissingEnvironmentAndConfigSink(): Unit {
        let originalHome = getVariable("METIS_HOME")
        let originalEnvLogFile = getVariable("METIS_LOG_FILE")
        let originalConfigLogFile = Config.logFile
        try {
            setVariable("METIS_HOME", "/tmp")
            removeVariable("METIS_LOG_FILE")
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            let expectedDotDir = CliConfig.dotDir.toString()
            let expectedConfigPath = MetisConfigManager.configPath().toString()
            let expectedPort = CliSettingManager.readGatewaySettings().port
            let result = withLogsOpsTestHome<String>({ =>
                Config.logFile = CliConfig.logsDir.join("s3j-logs-inner.log").toString()
                "s3j-logs-ok"
            })
            @Expect(result, "s3j-logs-ok")
            @Expect(getVariable("METIS_HOME"), Some("/tmp"))
            @Expect(getVariable("METIS_LOG_FILE").isNone(), true)
            @Expect(CliConfig.dotDir.toString(), expectedDotDir)
            @Expect(MetisConfigManager.configPath().toString(), expectedConfigPath)
            @Expect(CliSettingManager.readGatewaySettings().port, expectedPort)
            @Expect(Config.logFile, originalConfigLogFile)
        } finally {
            match (originalHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => removeVariable("METIS_HOME")
            }
            match (originalEnvLogFile) {
                case Some(value) => setVariable("METIS_LOG_FILE", value)
                case None => removeVariable("METIS_LOG_FILE")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            Config.logFile = originalConfigLogFile
        }
    }

    @TestCase
    public func s3jN2DynamicHomeRethrowsAndCleansOwnedDirectory(): Unit {
        let originalHome = getVariable("METIS_HOME")
        let originalEnvLogFile = getVariable("METIS_LOG_FILE")
        let originalConfigLogFile = Config.logFile
        var observed = ""
        try {
            setVariable("METIS_HOME", "/tmp")
            removeVariable("METIS_LOG_FILE")
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            let expectedDotDir = CliConfig.dotDir.toString()
            let expectedConfigPath = MetisConfigManager.configPath().toString()
            let expectedPort = CliSettingManager.readGatewaySettings().port
            try {
                withLogsOpsTestHome<Unit>({ =>
                    throw Exception("s3j_dynamic_body_failure")
                })
            } catch (e: Exception) {
                observed = e.message
            }
            @Expect(observed, "s3j_dynamic_body_failure")
            @Expect(getVariable("METIS_HOME"), Some("/tmp"))
            @Expect(getVariable("METIS_LOG_FILE").isNone(), true)
            @Expect(CliConfig.dotDir.toString(), expectedDotDir)
            @Expect(MetisConfigManager.configPath().toString(), expectedConfigPath)
            @Expect(CliSettingManager.readGatewaySettings().port, expectedPort)
            @Expect(Config.logFile, originalConfigLogFile)
        } finally {
            match (originalHome) {
                case Some(value) => setVariable("METIS_HOME", value)
                case None => removeVariable("METIS_HOME")
            }
            match (originalEnvLogFile) {
                case Some(value) => setVariable("METIS_LOG_FILE", value)
                case None => removeVariable("METIS_LOG_FILE")
            }
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            gatewayLoggingResetForTest()
            Config.logFile = originalConfigLogFile
        }
    }

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
