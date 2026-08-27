package metis.core.prompting

import std.collection.ArrayList
import std.fs.{Path, File, Directory, FileInfo, exists, canonicalize, remove, rename}
import std.io.*
import std.sync.{Condition, Mutex}
import std.time.DateTime

private const AGENTS_FILENAME = "AGENTS.md"
private const SOUL_FILENAME = "SOUL.md"
private const TOOLS_FILENAME = "TOOLS.md"
private const IDENTITY_FILENAME = "IDENTITY.md"
private const USER_FILENAME = "USER.md"
private const HEARTBEAT_FILENAME = "HEARTBEAT.md"
private const BOOTSTRAP_FILENAME = "BOOTSTRAP.md"
private const MEMORY_FILENAME = "MEMORY.md"
private const MEMORY_ALT_FILENAME = "memory.md"
private const WORKSPACE_BOOTSTRAP_CACHE_MAX_ENTRIES: Int64 = 8
private const BOOTSTRAP_LOAD_FAILURE_WARNING_PREFIX = "workspace bootstrap load failed:"
private const INVALID_BOOTSTRAP_ENCODING = "invalid_bootstrap_encoding"
private const UNREADABLE_BOOTSTRAP_FILE = "unreadable_bootstrap_file"
private const BOOTSTRAP_LOAD_FAILED = "bootstrap_load_failed"

// BOOTSTRAP.md is an explicit, user-created setup-state file: load it in full prompt mode
// when present, but do not auto-create it as durable workspace memory for every agent.
public const METIS_WORKSPACE_BOOTSTRAP_AUTOCREATES_BOOTSTRAP_FILE: Bool = false

public class MetisAgentWorkspaceBootstrapFileState {
    public var name: String = ""
    public var path: String = ""
    public var created: Bool = false
    public var existed: Bool = false
    public init() {}
}

public class MetisAgentWorkspaceBootstrapResult {
    public var workspaceDir: String = ""
    public var createdCount: Int64 = 0
    public var files: Array<MetisAgentWorkspaceBootstrapFileState> = []
    public init() {}
}

public class MetisWorkspaceFileIoResult {
    public var ok: Bool = false
    public var reason: String = ""
    public var path: String = ""
    public var content: String = ""
    public init() {}
}

public class MetisAgentIdentity {
    public var name: String = ""
    public var emoji: String = ""
    public var theme: String = ""
    public var creature: String = ""
    public var vibe: String = ""
    public var avatar: String = ""
    public init() {}
}

public class MetisIdentityAvatarValidation {
    public var ok: Bool = false
    public var reason: String = ""
    public init() {}
}

private func canonicalPathString(path: Path): String {
    try {
        canonicalize(path).toString()
    } catch (_) {
        path.toString()
    }
}

private func readTextFile(path: Path): String {
    String.fromUtf8(File.readFrom(path))
}

private func metisEnsureDirectory(path: Path): Unit {
    if (!exists(path)) {
        Directory.create(path, recursive: true)
    }
}

private func metisPathIsSymlink(path: Path): Bool {
    try {
        FileInfo(path).isSymbolicLink()
    } catch (_e: Exception) {
        false
    }
}

private func metisWorkspaceTemplate(name: String): String {
    match (name) {
        case AGENTS_FILENAME =>
            "# Agents\n\n" +
            "This workspace belongs to a Metis agent. Keep durable operating rules, delegation notes, and handoff conventions here.\n"
        case SOUL_FILENAME =>
            "# Soul\n\n" +
            "Describe the agent's purpose, tone, boundaries, and decision preferences.\n"
        case TOOLS_FILENAME =>
            "# Tools\n\n" +
            "Record workspace-specific tool expectations, allowed workflows, and local caveats.\n"
        case IDENTITY_FILENAME =>
            "# Identity\n\n" +
            "Name: Metis Agent\n" +
            "Emoji: \n" +
            "Theme: practical and careful\n" +
            "Creature: \n" +
            "Vibe: focused engineering partner\n" +
            "Avatar: \n"
        case USER_FILENAME =>
            "# User\n\n" +
            "Store user preferences that are safe to share with this agent. Do not put credentials here.\n"
        case HEARTBEAT_FILENAME =>
            "# Heartbeat\n\n" +
            "Use this file for lightweight status, recurring checks, and continuity notes.\n"
        case MEMORY_FILENAME =>
            "# Memory\n\n" +
            "Add durable facts, goals, and decisions that should survive across sessions.\n"
        case _ => "# ${name}\n"
    }
}

private func metisWorkspaceSafeFailure(reason: String, path!: String = ""): MetisWorkspaceFileIoResult {
    let result = MetisWorkspaceFileIoResult()
    result.ok = false
    result.reason = reason
    result.path = path
    result
}

private func metisWorkspaceSafeSuccess(path: String, content!: String = ""): MetisWorkspaceFileIoResult {
    let result = MetisWorkspaceFileIoResult()
    result.ok = true
    result.path = path
    result.content = content
    result
}

private func metisWorkspaceRejectReason(relativePath: String): String {
    let trimmed = relativePath.trimAscii()
    if (trimmed.isEmpty()) {
        return "empty path"
    }
    let normalized = trimmed.replace("\\", "/")
    if (normalized.startsWith("/") || normalized.startsWith("~")) {
        return "path must be workspace-relative"
    }
    if (normalized.contains("://") || normalized.contains(":")) {
        return "path must not include a URI scheme"
    }
    for (part in normalized.split("/")) {
        let segment = part.trimAscii()
        if (segment == "..") {
            return "path traversal is not allowed"
        }
    }
    ""
}

private func metisCanonicalInside(root: Path, candidate: Path): Bool {
    try {
        let rootText = canonicalize(root).toString()
        let candidateText = canonicalize(candidate).toString()
        candidateText == rootText || candidateText.startsWith(rootText + "/")
    } catch (_e: Exception) {
        false
    }
}

private func metisIdentityCleanKey(raw: String): String {
    raw.replace("*", "").replace("_", "").trimAscii().toAsciiLower()
}

private func metisIdentityCleanValue(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed == "<unset>" || trimmed == "unset" || trimmed == "TODO" || trimmed == "todo") {
        return ""
    }
    trimmed
}

public func metisWorkspaceBootstrapFilenames(): Array<String> {
    [
        AGENTS_FILENAME,
        SOUL_FILENAME,
        TOOLS_FILENAME,
        IDENTITY_FILENAME,
        USER_FILENAME,
        HEARTBEAT_FILENAME,
        MEMORY_FILENAME
    ]
}

public func metisWorkspaceSupportedProfileFilenames(): Array<String> {
    [
        AGENTS_FILENAME,
        SOUL_FILENAME,
        TOOLS_FILENAME,
        IDENTITY_FILENAME,
        USER_FILENAME,
        HEARTBEAT_FILENAME,
        BOOTSTRAP_FILENAME,
        MEMORY_FILENAME
    ]
}

public func ensureMetisAgentWorkspace(workspaceDir: Path): MetisAgentWorkspaceBootstrapResult {
    metisEnsureDirectory(workspaceDir)
    let result = MetisAgentWorkspaceBootstrapResult()
    result.workspaceDir = canonicalPathString(workspaceDir)
    let states = ArrayList<MetisAgentWorkspaceBootstrapFileState>()
    var createdCount: Int64 = 0
    for (name in metisWorkspaceBootstrapFilenames()) {
        let path = workspaceDir.join(name)
        let state = MetisAgentWorkspaceBootstrapFileState()
        state.name = name
        state.path = path.toString()
        if (exists(path)) {
            state.existed = true
        } else {
            if (metisPathIsSymlink(path)) {
                state.existed = true
            } else {
                try (file = File.create(path)) {
                    file.write(metisWorkspaceTemplate(name).toArray())
                }
                state.created = true
                createdCount += 1
            }
        }
        states.add(state)
    }
    result.createdCount = createdCount
    result.files = states.toArray()
    result
}

public func metisWorkspaceSafeRead(workspaceDir: Path, relativePath: String): MetisWorkspaceFileIoResult {
    let reason = metisWorkspaceRejectReason(relativePath)
    if (!reason.isEmpty()) {
        return metisWorkspaceSafeFailure(reason)
    }
    if (!exists(workspaceDir)) {
        return metisWorkspaceSafeFailure("workspace does not exist")
    }
    let target = workspaceDir.join(relativePath.trimAscii())
    if (!exists(target)) {
        return metisWorkspaceSafeFailure("file does not exist", path: target.toString())
    }
    if (!metisCanonicalInside(workspaceDir, target)) {
        return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
    }
    metisWorkspaceSafeSuccess(canonicalPathString(target), content: readTextFile(target))
}

public func metisWorkspaceSafeWrite(workspaceDir: Path, relativePath: String, content: String): MetisWorkspaceFileIoResult {
    let reason = metisWorkspaceRejectReason(relativePath)
    if (!reason.isEmpty()) {
        return metisWorkspaceSafeFailure(reason)
    }
    metisEnsureDirectory(workspaceDir)
    let target = workspaceDir.join(relativePath.trimAscii())
    let parent = target.parent
    metisEnsureDirectory(parent)
    if (!metisCanonicalInside(workspaceDir, parent)) {
        return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
    }
    if (metisPathIsSymlink(target)) {
        return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
    }
    if (exists(target) && !metisCanonicalInside(workspaceDir, target)) {
        return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
    }
    let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let tmp = parent.join(".${target.fileName}.metis-${stamp}.tmp")
    try {
        try (file = File.create(tmp)) {
            file.write(content.toArray())
        }
        if (metisPathIsSymlink(target)) {
            try { remove(tmp) } catch (_: Exception) { () }
            return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
        }
        if (exists(target) && !metisCanonicalInside(workspaceDir, target)) {
            try { remove(tmp) } catch (_: Exception) { () }
            return metisWorkspaceSafeFailure("path escapes workspace", path: target.toString())
        }
        rename(tmp, to: target, overwrite: true)
    } catch (e: Exception) {
        try { remove(tmp) } catch (_: Exception) { () }
        return metisWorkspaceSafeFailure("write failed: ${e.message}", path: target.toString())
    }
    metisWorkspaceSafeSuccess(canonicalPathString(target), content: content)
}

public func parseMetisIdentityMarkdown(content: String): MetisAgentIdentity {
    let identity = MetisAgentIdentity()
    for (line in content.split("\n")) {
        var trimmed = line.trimAscii()
        if (trimmed.startsWith("-")) {
            trimmed = trimmed[1..].trimAscii()
        }
        if (trimmed.startsWith("*")) {
            trimmed = trimmed[1..].trimAscii()
        }
        if (!trimmed.contains(":")) {
            continue
        }
        let parts = trimmed.split(":")
        if (parts.size < 2) {
            continue
        }
        let key = metisIdentityCleanKey(parts[0])
        let value = metisIdentityCleanValue(String.join(parts[1..parts.size], delimiter: ":"))
        if (key == "name") {
            identity.name = value
        } else if (key == "emoji") {
            identity.emoji = value
        } else if (key == "theme") {
            identity.theme = value
        } else if (key == "creature") {
            identity.creature = value
        } else if (key == "vibe") {
            identity.vibe = value
        } else if (key == "avatar") {
            identity.avatar = value
        }
    }
    identity
}

public func validateMetisIdentityAvatar(workspaceDir: Path, avatar: String): MetisIdentityAvatarValidation {
    let result = MetisIdentityAvatarValidation()
    let trimmed = avatar.trimAscii()
    let low = trimmed.toAsciiLower()
    if (trimmed.isEmpty() || low.startsWith("http://") || low.startsWith("https://") || low.startsWith("data:")) {
        result.ok = true
        return result
    }
    if (trimmed.startsWith("~")) {
        result.reason = "avatar must not use home-relative paths"
        return result
    }
    if (trimmed.contains("://") || trimmed.contains(":")) {
        result.reason = "avatar URI scheme is not allowed"
        return result
    }
    let reason = metisWorkspaceRejectReason(trimmed)
    if (!reason.isEmpty()) {
        result.reason = reason
        return result
    }
    if (!exists(workspaceDir)) {
        result.reason = "workspace does not exist"
        return result
    }
    let target = workspaceDir.join(trimmed)
    let parent = target.parent
    if (exists(parent) && !metisCanonicalInside(workspaceDir, parent)) {
        result.reason = "avatar path escapes workspace"
        return result
    }
    if (exists(target) && !metisCanonicalInside(workspaceDir, target)) {
        result.reason = "avatar path escapes workspace"
        return result
    }
    result.ok = true
    result
}

private func buildMissingContextFile(path: Path): MetisContextFile {
    let displayPath = canonicalPathString(path)
    MetisContextFile(displayPath, "[MISSING] Expected at: ${displayPath}")
}

private func loadContextFile(path: Path): MetisContextFile {
    let bytes = try {
        File.readFrom(path)
    } catch (_: Exception) {
        return MetisContextFile(
            canonicalPathString(path),
            "[INVALID] Workspace context file ${path.fileName}: ${UNREADABLE_BOOTSTRAP_FILE}"
        )
    }
    let content = try {
        String.fromUtf8(bytes)
    } catch (_: Exception) {
        return MetisContextFile(
            canonicalPathString(path),
            "[INVALID] Workspace context file ${path.fileName}: ${INVALID_BOOTSTRAP_ENCODING}"
        )
    }
    MetisContextFile(canonicalPathString(path), content)
}

private func bootstrapContextFileLoadFailure(file: MetisContextFile): String {
    if (file.content.contains(INVALID_BOOTSTRAP_ENCODING)) {
        return INVALID_BOOTSTRAP_ENCODING
    }
    if (file.content.contains(UNREADABLE_BOOTSTRAP_FILE)) {
        return UNREADABLE_BOOTSTRAP_FILE
    }
    ""
}

private func shouldIncludeInMinimalMode(fileName: String): Bool {
    fileName == AGENTS_FILENAME || fileName == TOOLS_FILENAME
}

private func shouldUseCompactImBootstrap(runtimeChannel: String): Bool {
    let normalized = runtimeChannel.trimAscii().toAsciiLower()
    normalized == "telegram" || normalized == "qq" || normalized == "feishu"
}

private func shouldSkipInCompactImMode(fileName: String): Bool {
    fileName == USER_FILENAME || fileName == HEARTBEAT_FILENAME || fileName == BOOTSTRAP_FILENAME
}

private func workspaceBootstrapFileIdentity(path: Path): String {
    if (!exists(path)) {
        return "${path.fileName}:missing"
    }
    try {
        let info = FileInfo(path)
        let modified = info.lastModificationTime.toUnixTimeStamp().toNanoseconds()
        "${path.fileName}:present:${info.size}:${modified}"
    } catch (_: Exception) {
        "${path.fileName}:present:identity_unavailable"
    }
}

private func workspaceBootstrapCacheKey(
    workspaceDir: Path,
    promptMode: PromptMode,
    runtimeChannel: String
): String {
    let normalizedChannel = runtimeChannel.trimAscii().toAsciiLower()
    let minimalMode = match (promptMode) {
        case PromptMode.MinimalMode => true
        case _ => false
    }
    let compactImMode = shouldUseCompactImBootstrap(normalizedChannel)
    let identities = ArrayList<String>()
    let baseNames = [
        AGENTS_FILENAME,
        SOUL_FILENAME,
        TOOLS_FILENAME,
        IDENTITY_FILENAME,
        USER_FILENAME,
        HEARTBEAT_FILENAME
    ]
    for (name in baseNames) {
        if (minimalMode && !shouldIncludeInMinimalMode(name)) {
            continue
        }
        if (!minimalMode && compactImMode && shouldSkipInCompactImMode(name)) {
            continue
        }
        identities.add(workspaceBootstrapFileIdentity(workspaceDir.join(name)))
    }
    if (!minimalMode) {
        if (!compactImMode) {
            identities.add(workspaceBootstrapFileIdentity(workspaceDir.join(BOOTSTRAP_FILENAME)))
        }
        // Both spellings affect which memory file wins and therefore both belong to the identity.
        identities.add(workspaceBootstrapFileIdentity(workspaceDir.join(MEMORY_FILENAME)))
        identities.add(workspaceBootstrapFileIdentity(workspaceDir.join(MEMORY_ALT_FILENAME)))
    }
    let modeKey = match (promptMode) {
        case PromptMode.FullMode => "full"
        case PromptMode.MinimalMode => "minimal"
        case PromptMode.NoneMode => "none"
    }
    let parts = ArrayList<String>()
    parts.add(canonicalPathString(workspaceDir))
    parts.add(modeKey)
    parts.add(normalizedChannel)
    for (identity in identities) {
        parts.add(identity)
    }
    let encoded = ArrayList<String>()
    for (part in parts) {
        encoded.add("${part.size}:${part}")
    }
    String.join(encoded.toArray(), delimiter: "|")
}

private func cloneMetisBootstrapBudgetResult(source: MetisBootstrapBudgetResult): MetisBootstrapBudgetResult {
    let result = MetisBootstrapBudgetResult()
    let files = ArrayList<MetisContextFile>()
    for (file in source.files) {
        files.add(MetisContextFile(file.path, file.content))
    }
    let warnings = ArrayList<String>()
    for (warning in source.warnings) {
        warnings.add(warning)
    }
    result.files = files.toArray()
    result.warnings = warnings.toArray()
    result.totalChars = source.totalChars
    result.originalTotalChars = source.originalTotalChars
    result.truncatedFiles = source.truncatedFiles
    result.missingFiles = source.missingFiles
    result.skippedFiles = source.skippedFiles
    result
}

private func workspaceBootstrapResultIsCacheable(result: MetisBootstrapBudgetResult): Bool {
    for (warning in result.warnings) {
        if (warning.startsWith(BOOTSTRAP_LOAD_FAILURE_WARNING_PREFIX)) {
            return false
        }
    }
    true
}

private func workspaceBootstrapLoadFailureResult(reason: String): MetisBootstrapBudgetResult {
    let content = "[INVALID] Workspace bootstrap unavailable: ${reason}"
    let result = MetisBootstrapBudgetResult()
    result.files = [MetisContextFile("workspace-bootstrap", content)]
    result.warnings = ["${BOOTSTRAP_LOAD_FAILURE_WARNING_PREFIX} ${reason}"]
    result.totalChars = content.size
    result.originalTotalChars = content.size
    result
}

private class MetisWorkspaceBootstrapCacheEntry {
    let key: String
    let result: MetisBootstrapBudgetResult
    var lastUsed: Int64

    init(key: String, result: MetisBootstrapBudgetResult, lastUsed: Int64) {
        this.key = key
        this.result = result
        this.lastUsed = lastUsed
    }
}

private class MetisWorkspaceBootstrapFlight {
    let key: String
    let epoch: Int64
    let token: Int64
    var loading: Bool = true
    var result: Option<MetisBootstrapBudgetResult> = None

    init(key: String, epoch: Int64, token: Int64) {
        this.key = key
        this.epoch = epoch
        this.token = token
    }
}

public class MetisWorkspaceBootstrapCacheStats {
    public var loads: Int64 = 0
    public var hits: Int64 = 0
    public var waits: Int64 = 0
    public var evictions: Int64 = 0
    public var completedEntries: Int64 = 0
    public var inFlight: Int64 = 0
    public init() {}
}

private class MetisWorkspaceBootstrapCache {
    private let lock = Mutex()
    private var condition: Condition
    private let entries = ArrayList<MetisWorkspaceBootstrapCacheEntry>()
    private let flights = ArrayList<MetisWorkspaceBootstrapFlight>()
    private var sequence: Int64 = 0
    private var epoch: Int64 = 0
    private var flightSequence: Int64 = 0
    private var loads: Int64 = 0
    private var hits: Int64 = 0
    private var waits: Int64 = 0
    private var evictions: Int64 = 0
    private var beforeLoadHook: Option<(String) -> Unit> = None

    init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    private func nextSequenceLocked(): Int64 {
        this.sequence += 1
        this.sequence
    }

    private func removeFlightLocked(flight: MetisWorkspaceBootstrapFlight): Unit {
        for (i in 0..this.flights.size) {
            if (this.flights[i].token == flight.token) {
                let _ = this.flights.remove(at: i)
                return
            }
        }
    }

    private func ownsFlightLocked(flight: MetisWorkspaceBootstrapFlight): Bool {
        if (flight.epoch != this.epoch) {
            return false
        }
        for (current in this.flights) {
            if (current.token == flight.token) {
                return true
            }
        }
        false
    }

    private func addCompletedLocked(key: String, result: MetisBootstrapBudgetResult): Unit {
        if (Int64(this.entries.size) >= WORKSPACE_BOOTSTRAP_CACHE_MAX_ENTRIES) {
            var oldestIndex: Int64 = 0
            var oldestSequence = this.entries[0].lastUsed
            for (i in 1..this.entries.size) {
                if (this.entries[i].lastUsed < oldestSequence) {
                    oldestIndex = Int64(i)
                    oldestSequence = this.entries[i].lastUsed
                }
            }
            let _ = this.entries.remove(at: oldestIndex)
            this.evictions += 1
        }
        this.entries.add(
            MetisWorkspaceBootstrapCacheEntry(
                key,
                cloneMetisBootstrapBudgetResult(result),
                this.nextSequenceLocked()
            )
        )
    }

    func getOrLoad(key: String, load: () -> MetisBootstrapBudgetResult): MetisBootstrapBudgetResult {
        var ownedFlight = None<MetisWorkspaceBootstrapFlight>
        var hook = None<(String) -> Unit>
        synchronized(this.lock) {
            for (entry in this.entries) {
                if (entry.key == key) {
                    entry.lastUsed = this.nextSequenceLocked()
                    this.hits += 1
                    return cloneMetisBootstrapBudgetResult(entry.result)
                }
            }
            for (flight in this.flights) {
                if (flight.key == key) {
                    this.waits += 1
                    while (flight.loading) {
                        this.condition.wait()
                    }
                    return match (flight.result) {
                        case Some(result) => cloneMetisBootstrapBudgetResult(result)
                        case None => workspaceBootstrapLoadFailureResult(BOOTSTRAP_LOAD_FAILED)
                    }
                }
            }
            this.flightSequence += 1
            let flight = MetisWorkspaceBootstrapFlight(key, this.epoch, this.flightSequence)
            this.flights.add(flight)
            this.loads += 1
            ownedFlight = Some(flight)
            hook = this.beforeLoadHook
        }

        let loaded = try {
            match (hook) {
                case Some(callback) => callback(key)
                case None => ()
            }
            load()
        } catch (_: Exception) {
            workspaceBootstrapLoadFailureResult(BOOTSTRAP_LOAD_FAILED)
        }
        synchronized(this.lock) {
            match (ownedFlight) {
                case Some(flight) =>
                    if (this.ownsFlightLocked(flight)) {
                        flight.result = Some(cloneMetisBootstrapBudgetResult(loaded))
                        flight.loading = false
                        this.removeFlightLocked(flight)
                        if (workspaceBootstrapResultIsCacheable(loaded)) {
                            this.addCompletedLocked(key, loaded)
                        }
                    }
                case None => ()
            }
            this.condition.notifyAll()
        }
        cloneMetisBootstrapBudgetResult(loaded)
    }

    func reset(): Unit {
        synchronized(this.lock) {
            this.epoch += 1
            this.entries.clear()
            for (flight in this.flights) {
                flight.result = Some(workspaceBootstrapLoadFailureResult(BOOTSTRAP_LOAD_FAILED))
                flight.loading = false
            }
            this.flights.clear()
            this.sequence = 0
            this.loads = 0
            this.hits = 0
            this.waits = 0
            this.evictions = 0
            this.beforeLoadHook = None
            this.condition.notifyAll()
        }
    }

    func setBeforeLoadHook(hook: Option<(String) -> Unit>): Unit {
        synchronized(this.lock) {
            this.beforeLoadHook = hook
        }
    }

    func stats(): MetisWorkspaceBootstrapCacheStats {
        synchronized(this.lock) {
            let result = MetisWorkspaceBootstrapCacheStats()
            result.loads = this.loads
            result.hits = this.hits
            result.waits = this.waits
            result.evictions = this.evictions
            result.completedEntries = Int64(this.entries.size)
            result.inFlight = Int64(this.flights.size)
            result
        }
    }
}

private let metisWorkspaceBootstrapCache = MetisWorkspaceBootstrapCache()

public func resetMetisWorkspaceBootstrapCacheForTest(): Unit {
    metisWorkspaceBootstrapCache.reset()
}

public func setMetisWorkspaceBootstrapBeforeLoadHookForTest(hook: Option<(String) -> Unit>): Unit {
    metisWorkspaceBootstrapCache.setBeforeLoadHook(hook)
}

public func metisWorkspaceBootstrapCacheStatsForTest(): MetisWorkspaceBootstrapCacheStats {
    metisWorkspaceBootstrapCache.stats()
}

public func metisWorkspaceBootstrapCacheKeyForTest(
    workspaceDir: Path,
    promptMode!: PromptMode = PromptMode.FullMode,
    runtimeChannel!: String = ""
): String {
    workspaceBootstrapCacheKey(workspaceDir, promptMode, runtimeChannel)
}

private func addLoadedContextFile(
    files: ArrayList<MetisContextFile>,
    loadFailures: ArrayList<String>,
    path: Path
): Unit {
    let file = loadContextFile(path)
    let failure = bootstrapContextFileLoadFailure(file)
    if (!failure.isEmpty()) {
        loadFailures.add(failure)
    }
    files.add(file)
}

private func resolveContextFilesDetailedUncached(
    workspaceDir: Path,
    promptMode: PromptMode,
    runtimeChannel: String
): MetisBootstrapBudgetResult {
    let files = ArrayList<MetisContextFile>()
    let loadFailures = ArrayList<String>()
    let minimalMode = match (promptMode) {
        case PromptMode.MinimalMode => true
        case _ => false
    }
    let compactImMode = shouldUseCompactImBootstrap(runtimeChannel)
    let baseNames = [
        AGENTS_FILENAME,
        SOUL_FILENAME,
        TOOLS_FILENAME,
        IDENTITY_FILENAME,
        USER_FILENAME,
        HEARTBEAT_FILENAME
    ]

    for (name in baseNames) {
        if (minimalMode && !shouldIncludeInMinimalMode(name)) {
            continue
        }
        if (!minimalMode && compactImMode && shouldSkipInCompactImMode(name)) {
            continue
        }
        let path = workspaceDir.join(name)
        if (exists(path)) {
            addLoadedContextFile(files, loadFailures, path)
        } else {
            files.add(buildMissingContextFile(path))
        }
    }

    if (!minimalMode) {
        let bootstrapPath = workspaceDir.join(BOOTSTRAP_FILENAME)
        if (!compactImMode && exists(bootstrapPath)) {
            addLoadedContextFile(files, loadFailures, bootstrapPath)
        }

        let memoryPath = workspaceDir.join(MEMORY_FILENAME)
        let memoryAltPath = workspaceDir.join(MEMORY_ALT_FILENAME)
        if (exists(memoryPath)) {
            addLoadedContextFile(files, loadFailures, memoryPath)
        } else if (exists(memoryAltPath)) {
            addLoadedContextFile(files, loadFailures, memoryAltPath)
        } else {
            files.add(buildMissingContextFile(memoryPath))
        }
    }

    let result = MetisBootstrapBudget.buildContextFiles(files.toArray())
    if (!loadFailures.isEmpty()) {
        let warnings = ArrayList<String>()
        for (warning in result.warnings) {
            warnings.add(warning)
        }
        for (failure in loadFailures) {
            warnings.add("${BOOTSTRAP_LOAD_FAILURE_WARNING_PREFIX} ${failure}")
        }
        result.warnings = warnings.toArray()
    }
    result
}

public class MetisWorkspaceBootstrap {
    public static func resolveContextFilesDetailed(
        workspaceDir: Path,
        promptMode!: PromptMode = PromptMode.FullMode,
        runtimeChannel!: String = ""
    ): MetisBootstrapBudgetResult {
        let key = workspaceBootstrapCacheKey(workspaceDir, promptMode, runtimeChannel)
        metisWorkspaceBootstrapCache.getOrLoad(key, { =>
            resolveContextFilesDetailedUncached(workspaceDir, promptMode, runtimeChannel)
        })
    }

    public static func resolveContextFiles(
        workspaceDir: Path,
        promptMode!: PromptMode = PromptMode.FullMode,
        runtimeChannel!: String = ""
    ): Array<MetisContextFile> {
        MetisWorkspaceBootstrap.resolveContextFilesDetailed(
            workspaceDir,
            promptMode: promptMode,
            runtimeChannel: runtimeChannel
        ).files
    }
}
