package metis.gateway.logging

import stdx.encoding.json.{JsonInt, JsonObject, JsonString}

/** Composition adapter: never passes command arguments or output into logs. */
public func gatewayCreateShellFailureReporter(): (Int64, String) -> Unit {
    let logger = metisCreateSubsystemLogger("process/shell")
    { exitCode, kind =>
        let meta = JsonObject()
        meta.put("exitCode", JsonInt(exitCode))
        meta.put("commandKind", JsonString(if (kind == "captured" || kind == "timed") { kind } else { "unknown" }))
        logger.error(MetisLogEvent.shellCommandFailed, "shell command failed", meta: meta)
    }
}
