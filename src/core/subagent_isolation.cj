package metis.core

public func gatewaySubagentNormalizeIsolationMode(isolation: String): String {
    match (isolation.trimAscii().toAsciiLower().replace("-", "_")) {
        case "cwd" | "directory" | "dir" => "cwd"
        case "worktree" | "git_worktree" => "worktree"
        case _ => "shared"
    }
}

public func gatewaySubagentNormalizeCleanupMode(cleanup: String): String {
    match (cleanup.trimAscii().toAsciiLower()) {
        case "delete" | "remove" | "cleanup" => "delete"
        case _ => "keep"
    }
}

public func gatewaySubagentNormalizeSandboxMode(sandbox: String): String {
    match (sandbox.trimAscii().toAsciiLower()) {
        case "require" | "required" | "sandbox" => "require"
        case _ => "inherit"
    }
}
