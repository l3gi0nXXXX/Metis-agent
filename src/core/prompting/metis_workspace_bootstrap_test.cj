package metis.core.prompting

import metis.utils.ShellUtils

import std.collection.ArrayList
import std.core.Duration
import std.fs.{Directory, File, OpenMode, Path, exists, remove}
import std.sync.{Condition, Mutex}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

private func repeatWorkspaceText(text: String, count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += text
    }
    out
}

private func cleanupWorkspaceBootstrapTestDir(root: Path): Unit {
    if (exists(root)) {
        remove(root, recursive: true)
    }
}

private func bootstrapHasFileWithSuffix(files: Array<MetisContextFile>, suffix: String): Bool {
    for (file in files) {
        if (file.path.endsWith(suffix)) {
            return true
        }
    }
    false
}

private func bootstrapStateHasName(files: Array<MetisAgentWorkspaceBootstrapFileState>, name: String): Bool {
    for (file in files) {
        if (file.name == name) {
            return true
        }
    }
    false
}

private func writeWorkspaceBootstrapCacheFixture(root: Path, memory: String): Unit {
    Directory.create(root, recursive: true)
    File.writeTo(root.join("AGENTS.md"), "# Agents 中文🙂\n".toArray())
    File.writeTo(root.join("SOUL.md"), "# Soul\n".toArray())
    File.writeTo(root.join("TOOLS.md"), "# Tools\n".toArray())
    File.writeTo(root.join("IDENTITY.md"), "# Identity\n".toArray())
    File.writeTo(root.join("USER.md"), "# User\n".toArray())
    File.writeTo(root.join("HEARTBEAT.md"), "# Heartbeat\n".toArray())
    File.writeTo(root.join("MEMORY.md"), memory.toArray())
}

private func workspaceBootstrapResultSignature(result: MetisBootstrapBudgetResult): String {
    let parts = ArrayList<String>()
    for (file in result.files) {
        parts.add("FILE=${file.path}\n${file.content}")
    }
    for (warning in result.warnings) {
        parts.add("WARNING=${warning}")
    }
    parts.add(
        "TOTAL=${result.totalChars}:${result.originalTotalChars}:${result.truncatedFiles}:${result.missingFiles}:${result.skippedFiles}"
    )
    String.join(parts.toArray(), delimiter: "\n--\n")
}

private func workspaceBootstrapPathOrder(result: MetisBootstrapBudgetResult): String {
    let paths = ArrayList<String>()
    for (file in result.files) {
        paths.add(file.path)
    }
    String.join(paths.toArray(), delimiter: "|")
}

private func workspaceBootstrapContains(result: MetisBootstrapBudgetResult, text: String): Bool {
    for (file in result.files) {
        if (file.content.contains(text)) {
            return true
        }
    }
    false
}

private func workspaceBootstrapMemoryContent(result: MetisBootstrapBudgetResult): String {
    for (file in result.files) {
        if (file.path.endsWith("MEMORY.md") || file.path.endsWith("memory.md")) {
            return file.content
        }
    }
    ""
}

private func workspaceBootstrapHasWarning(result: MetisBootstrapBudgetResult, text: String): Bool {
    for (warning in result.warnings) {
        if (warning.contains(text)) {
            return true
        }
    }
    false
}

private class WorkspaceBootstrapLoadGate {
    private let lock = Mutex()
    private var condition: Condition
    private var released: Bool = false

    init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    func waitForRelease(): Unit {
        synchronized(this.lock) {
            while (!this.released) {
                this.condition.wait()
            }
        }
    }

    func release(): Unit {
        synchronized(this.lock) {
            this.released = true
            this.condition.notifyAll()
        }
    }
}

private func waitForWorkspaceBootstrapWaiters(expected: Int64): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (MonoTime.now() < deadline) {
        if (metisWorkspaceBootstrapCacheStatsForTest().waits >= expected) {
            return true
        }
        sleep(Duration.millisecond * 5)
    }
    false
}

private func waitForWorkspaceBootstrapInFlight(expected: Int64): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (MonoTime.now() < deadline) {
        if (metisWorkspaceBootstrapCacheStatsForTest().inFlight == expected) {
            return true
        }
        sleep(Duration.millisecond * 5)
    }
    false
}

@Test
public class MetisWorkspaceBootstrapTest {
    @TestCase
    public func s4U1BootstrapCacheReturnsDefensiveByteIdenticalResult(): Unit {
        let root = Path("/tmp/metis-bootstrap-cache-s4-u1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try {
            resetMetisWorkspaceBootstrapCacheForTest()
            writeWorkspaceBootstrapCacheFixture(root, "# Memory\n中文记忆🙂\n")

            let first = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let expected = workspaceBootstrapResultSignature(first)
            first.files[0].content = "caller mutation"
            first.warnings = ["caller mutation"]
            let second = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let stats = metisWorkspaceBootstrapCacheStatsForTest()

            @Expect(workspaceBootstrapResultSignature(second), expected)
            @Expect(stats.loads, 1)
            @Expect(stats.hits, 1)
            @Expect(stats.completedEntries, 1)
        } finally {
            resetMetisWorkspaceBootstrapCacheForTest()
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func s4B1ConcurrentLoadsSingleFlightAndLruIsBounded(): Unit {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds()
        let root = Path("/tmp/metis-bootstrap-cache-s4-b1-${stamp}")
        let extraRoots = ArrayList<Path>()
        let gate = WorkspaceBootstrapLoadGate()
        try {
            resetMetisWorkspaceBootstrapCacheForTest()
            writeWorkspaceBootstrapCacheFixture(root, repeatWorkspaceText("# 记忆-index🙂\n正文🙂\n", 24000))
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(Some({key: String =>
                if (key.contains("metis-bootstrap-cache-s4-b1-${stamp}")) {
                    gate.waitForRelease()
                }
            }))
            let futures = ArrayList<Future<MetisBootstrapBudgetResult>>()
            for (_ in 0..16) {
                futures.add(spawn { MetisWorkspaceBootstrap.resolveContextFilesDetailed(root) })
            }
            @Expect(waitForWorkspaceBootstrapWaiters(15), true)
            gate.release()
            var expected = ""
            for (i in 0..futures.size) {
                let result = futures[i].get(Duration.second * 5)
                @Expect(result.totalChars <= DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS, true)
                let memory = workspaceBootstrapMemoryContent(result)
                @Expect(memory.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
                @Expect(String.fromUtf8(memory.toArray()), memory)
                if (i == 0) {
                    expected = workspaceBootstrapResultSignature(result)
                } else {
                    @Expect(workspaceBootstrapResultSignature(result), expected)
                }
            }
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(None)
            let singleFlightStats = metisWorkspaceBootstrapCacheStatsForTest()
            @Expect(singleFlightStats.loads, 1)
            @Expect(singleFlightStats.waits, 15)
            @Expect(singleFlightStats.completedEntries, 1)

            for (i in 0..8) {
                let extra = Path("/tmp/metis-bootstrap-cache-s4-b1-extra-${stamp}-${i}")
                extraRoots.add(extra)
                writeWorkspaceBootstrapCacheFixture(extra, "# Memory ${i}\n")
                let result = MetisWorkspaceBootstrap.resolveContextFilesDetailed(extra)
                @Expect(result.totalChars <= DEFAULT_BOOTSTRAP_TOTAL_MAX_CHARS, true)
            }
            let boundedStats = metisWorkspaceBootstrapCacheStatsForTest()
            @Expect(boundedStats.loads, 9)
            @Expect(boundedStats.completedEntries, 8)
            @Expect(boundedStats.evictions, 1)
            @Expect(boundedStats.inFlight, 0)
        } finally {
            gate.release()
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(None)
            resetMetisWorkspaceBootstrapCacheForTest()
            cleanupWorkspaceBootstrapTestDir(root)
            for (extra in extraRoots) {
                cleanupWorkspaceBootstrapTestDir(extra)
            }
        }
    }

    @TestCase
    public func s4P1FileIdentityChangeInvalidatesCache(): Unit {
        let root = Path("/tmp/metis-bootstrap-cache-s4-p1-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        try {
            resetMetisWorkspaceBootstrapCacheForTest()
            writeWorkspaceBootstrapCacheFixture(root, "# Memory\nold-cache-marker\n")
            let first = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let firstOrder = workspaceBootstrapPathOrder(first)

            File.writeTo(root.join("MEMORY.md"), "# Memory\nnew-cache-marker-with-different-size🙂\n".toArray())
            let second = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let stats = metisWorkspaceBootstrapCacheStatsForTest()

            @Expect(workspaceBootstrapContains(second, "new-cache-marker-with-different-size🙂"), true)
            @Expect(workspaceBootstrapContains(second, "old-cache-marker"), false)
            @Expect(workspaceBootstrapPathOrder(second), firstOrder)
            @Expect(stats.loads, 2)
            @Expect(stats.hits, 0)

            let collisionPrefix = "/tmp/metis-bootstrap-key-collision-${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
            let keyA = metisWorkspaceBootstrapCacheKeyForTest(
                Path("${collisionPrefix}|full|b"),
                runtimeChannel: "c"
            )
            let keyB = metisWorkspaceBootstrapCacheKeyForTest(
                Path(collisionPrefix),
                runtimeChannel: "b|full|c"
            )
            @Expect(keyA == keyB, false)
        } finally {
            resetMetisWorkspaceBootstrapCacheForTest()
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func s4N1InvalidUtf8AndLoaderFailureSettleWithoutCaching(): Unit {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds()
        let root = Path("/tmp/metis-bootstrap-cache-s4-n1-${stamp}")
        let failureGate = WorkspaceBootstrapLoadGate()
        let oldGate = WorkspaceBootstrapLoadGate()
        let newGate = WorkspaceBootstrapLoadGate()
        try {
            resetMetisWorkspaceBootstrapCacheForTest()
            writeWorkspaceBootstrapCacheFixture(root, "# Memory\nvalid\n")
            File.writeTo(root.join("MEMORY.md"), Array<Byte>(2, {i => if (i == 0) { 195 } else { 40 }}))
            let invalid = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let invalidStats = metisWorkspaceBootstrapCacheStatsForTest()
            @Expect(workspaceBootstrapContains(invalid, "invalid_bootstrap_encoding"), true)
            @Expect(workspaceBootstrapHasWarning(invalid, "invalid_bootstrap_encoding"), true)
            @Expect(invalidStats.completedEntries, 0)

            remove(root.join("MEMORY.md"))
            Directory.create(root.join("MEMORY.md"))
            let unreadable = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            @Expect(workspaceBootstrapContains(unreadable, "unreadable_bootstrap_file"), true)
            @Expect(workspaceBootstrapHasWarning(unreadable, "unreadable_bootstrap_file"), true)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().completedEntries, 0)

            remove(root.join("MEMORY.md"), recursive: true)
            File.writeTo(root.join("MEMORY.md"), "# Memory\nrepaired中文🙂\n".toArray())
            let repaired = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            @Expect(workspaceBootstrapContains(repaired, "repaired中文🙂"), true)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().completedEntries, 1)

            resetMetisWorkspaceBootstrapCacheForTest()
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(Some({key: String =>
                if (key.contains("metis-bootstrap-cache-s4-n1-${stamp}")) {
                    failureGate.waitForRelease()
                    throw Exception("forced loader failure")
                }
            }))
            let futures = ArrayList<Future<MetisBootstrapBudgetResult>>()
            for (_ in 0..9) {
                futures.add(spawn { MetisWorkspaceBootstrap.resolveContextFilesDetailed(root) })
            }
            @Expect(waitForWorkspaceBootstrapWaiters(8), true)
            failureGate.release()
            for (future in futures) {
                let failed = future.get(Duration.second * 5)
                @Expect(workspaceBootstrapContains(failed, "bootstrap_load_failed"), true)
                @Expect(workspaceBootstrapHasWarning(failed, "bootstrap_load_failed"), true)
            }
            let failedStats = metisWorkspaceBootstrapCacheStatsForTest()
            @Expect(failedStats.loads, 1)
            @Expect(failedStats.waits, 8)
            @Expect(failedStats.completedEntries, 0)
            @Expect(failedStats.inFlight, 0)

            setMetisWorkspaceBootstrapBeforeLoadHookForTest(None)
            let recovered = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            @Expect(workspaceBootstrapContains(recovered, "repaired中文🙂"), true)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().completedEntries, 1)

            resetMetisWorkspaceBootstrapCacheForTest()
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(Some({key: String =>
                if (key.contains("metis-bootstrap-cache-s4-n1-${stamp}")) {
                    oldGate.waitForRelease()
                }
            }))
            let oldOwner = spawn { MetisWorkspaceBootstrap.resolveContextFilesDetailed(root) }
            @Expect(waitForWorkspaceBootstrapInFlight(1), true)
            let oldWaiter = spawn { MetisWorkspaceBootstrap.resolveContextFilesDetailed(root) }
            @Expect(waitForWorkspaceBootstrapWaiters(1), true)

            resetMetisWorkspaceBootstrapCacheForTest()
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(Some({key: String =>
                if (key.contains("metis-bootstrap-cache-s4-n1-${stamp}")) {
                    newGate.waitForRelease()
                }
            }))
            let newOwner = spawn { MetisWorkspaceBootstrap.resolveContextFilesDetailed(root) }
            @Expect(waitForWorkspaceBootstrapInFlight(1), true)
            oldGate.release()
            let _ = oldOwner.get(Duration.second * 5)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().inFlight, 1)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().completedEntries, 0)

            let resetWaiter = oldWaiter.get(Duration.second * 5)
            @Expect(workspaceBootstrapContains(resetWaiter, "bootstrap_load_failed"), true)
            newGate.release()
            let afterReset = newOwner.get(Duration.second * 5)
            @Expect(workspaceBootstrapContains(afterReset, "repaired中文🙂"), true)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().completedEntries, 1)
            @Expect(metisWorkspaceBootstrapCacheStatsForTest().inFlight, 0)
        } finally {
            failureGate.release()
            oldGate.release()
            newGate.release()
            setMetisWorkspaceBootstrapBeforeLoadHookForTest(None)
            resetMetisWorkspaceBootstrapCacheForTest()
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func resolveContextFilesTruncatesLargeMemoryFileUsingBootstrapBudget(): Unit {
        let root = Path("/tmp/metis-workspace-bootstrap-large-memory")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("AGENTS.md"), "# Agents\n".toArray())
            File.writeTo(root.join("SOUL.md"), "# Soul\n".toArray())
            File.writeTo(root.join("TOOLS.md"), "# Tools\n".toArray())
            File.writeTo(root.join("IDENTITY.md"), "# Identity\n".toArray())
            File.writeTo(root.join("USER.md"), "# User\n".toArray())
            File.writeTo(root.join("HEARTBEAT.md"), "# Heartbeat\n".toArray())
            File.writeTo(root.join("BOOTSTRAP.md"), "# Bootstrap\n".toArray())
            let largeMemory = repeatWorkspaceText("memory-line-", 40000)
            File.writeTo(root.join("MEMORY.md"), largeMemory.toArray())

            let bootstrap = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let files = bootstrap.files
            var foundMemory = false
            for (file in files) {
                if (file.path.endsWith("/MEMORY.md") || file.path.endsWith("\\MEMORY.md") || file.path.endsWith("MEMORY.md")) {
                    foundMemory = true
                    @Expect(file.content.contains("memory bootstrap compressed"), true)
                    @Expect(file.content.size <= DEFAULT_BOOTSTRAP_MAX_CHARS, true)
                }
            }
            @Expect(foundMemory, true)
            @Expect(bootstrap.truncatedFiles >= 1, true)
            @Expect(bootstrap.totalChars < bootstrap.originalTotalChars, true)
            @Expect(bootstrap.warnings.size >= 1, true)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func resolveContextFilesPreservesMissingPlaceholderForAbsentMemory(): Unit {
        let root = Path("/tmp/metis-workspace-bootstrap-missing-memory")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("AGENTS.md"), "# Agents\n".toArray())
            File.writeTo(root.join("SOUL.md"), "# Soul\n".toArray())
            File.writeTo(root.join("TOOLS.md"), "# Tools\n".toArray())
            File.writeTo(root.join("IDENTITY.md"), "# Identity\n".toArray())
            File.writeTo(root.join("USER.md"), "# User\n".toArray())
            File.writeTo(root.join("HEARTBEAT.md"), "# Heartbeat\n".toArray())

            let bootstrap = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            let files = bootstrap.files
            var foundMissingMemory = false
            for (file in files) {
                if (file.content.startsWith("[MISSING] Expected at:") && (file.path.endsWith("/MEMORY.md") || file.path.endsWith("\\MEMORY.md") || file.path.endsWith("MEMORY.md"))) {
                    foundMissingMemory = true
                }
            }
            @Expect(foundMissingMemory, true)
            @Expect(bootstrap.missingFiles >= 1, true)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func resolveContextFilesMinimalModeStillOnlyReturnsAgentsAndTools(): Unit {
        let root = Path("/tmp/metis-workspace-bootstrap-minimal")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("AGENTS.md"), "# Agents\n".toArray())
            File.writeTo(root.join("TOOLS.md"), "# Tools\n".toArray())
            File.writeTo(root.join("MEMORY.md"), repeatWorkspaceText("memory-line-", 5000).toArray())

            let files = MetisWorkspaceBootstrap.resolveContextFiles(root, promptMode: PromptMode.MinimalMode)
            @Expect(files.size, 2)
            @Expect(files[0].path.endsWith("AGENTS.md"), true)
            @Expect(files[1].path.endsWith("TOOLS.md"), true)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func bootstrapPolicyDoesNotAutoCreateBootstrapButLoadsExistingInFullMode(): Unit {
        let root = Path("/tmp/metis-workspace-bootstrap-policy")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("BOOTSTRAP.md"), "# Setup State\n".toArray())

            @Expect(METIS_WORKSPACE_BOOTSTRAP_AUTOCREATES_BOOTSTRAP_FILE, false)
            @Expect(metisWorkspaceBootstrapFilenames().contains("BOOTSTRAP.md"), false)
            let ensure = ensureMetisAgentWorkspace(root)
            @Expect(ensure.createdCount >= 6, true)
            @Expect(bootstrapStateHasName(ensure.files, "BOOTSTRAP.md"), false)

            let bootstrap = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "BOOTSTRAP.md"), true)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func resolveContextFilesSkipsLowValueFilesForTelegramBootstrap(): Unit {
        let root = Path("/tmp/metis-workspace-bootstrap-telegram-compact")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("AGENTS.md"), "# Agents\n".toArray())
            File.writeTo(root.join("SOUL.md"), "# Soul\n".toArray())
            File.writeTo(root.join("TOOLS.md"), "# Tools\n".toArray())
            File.writeTo(root.join("IDENTITY.md"), "# Identity\n".toArray())
            File.writeTo(root.join("USER.md"), "# User\n".toArray())
            File.writeTo(root.join("HEARTBEAT.md"), "# Heartbeat\n".toArray())
            File.writeTo(root.join("BOOTSTRAP.md"), "# Bootstrap\n".toArray())
            File.writeTo(root.join("MEMORY.md"), "# Goals\n- keep this\n".toArray())

            let bootstrap = MetisWorkspaceBootstrap.resolveContextFilesDetailed(root, runtimeChannel: "telegram")
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "AGENTS.md"), true)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "TOOLS.md"), true)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "SOUL.md"), true)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "IDENTITY.md"), true)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "MEMORY.md"), true)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "USER.md"), false)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "HEARTBEAT.md"), false)
            @Expect(bootstrapHasFileWithSuffix(bootstrap.files, "BOOTSTRAP.md"), false)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func ensureAgentWorkspaceCreatesMissingBootstrapFilesWithoutOverwriting(): Unit {
        let root = Path("/tmp/metis-agent-workspace-bootstrap-ensure")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root, recursive: true)
            File.writeTo(root.join("SOUL.md"), "# Custom Soul\n".toArray())

            let bootstrap = ensureMetisAgentWorkspace(root)

            @Expect(bootstrap.workspaceDir.endsWith("metis-agent-workspace-bootstrap-ensure"), true)
            @Expect(bootstrap.createdCount >= 6, true)
            @Expect(String.fromUtf8(File.readFrom(root.join("SOUL.md"))), "# Custom Soul\n")
            for (name in metisWorkspaceBootstrapFilenames()) {
                @Expect(exists(root.join(name)), true)
            }
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }

    @TestCase
    public func safeWorkspaceReadWriteRejectsEscapesAndAllowsRelativeFiles(): Unit {
        let root = Path("/tmp/metis-agent-workspace-safe-io")
        let outside = Path("/tmp/metis-agent-workspace-safe-io-outside")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            cleanupWorkspaceBootstrapTestDir(outside)
            Directory.create(root, recursive: true)
            Directory.create(outside, recursive: true)
            File.writeTo(outside.join("secret.txt"), "secret".toArray())

            let writeResult = metisWorkspaceSafeWrite(root, "notes/today.md", "hello")
            @Expect(writeResult.ok, true)
            let readResult = metisWorkspaceSafeRead(root, "notes/today.md")
            @Expect(readResult.ok, true)
            @Expect(readResult.content, "hello")

            @Expect(metisWorkspaceSafeRead(root, "../secret.txt").ok, false)
            @Expect(metisWorkspaceSafeWrite(root, "/tmp/escape.txt", "bad").ok, false)

            let (code, _, _) = ShellUtils.execute(
                ["ln", "-s", outside.toString(), root.join("escape").toString()],
                withWrap: false
            )
            @Expect(code, 0)
            @Expect(metisWorkspaceSafeRead(root, "escape/secret.txt").ok, false)

            File.writeTo(outside.join("target.txt"), "keep".toArray())
            let (linkCode, _, _) = ShellUtils.execute(
                ["ln", "-s", outside.join("target.txt").toString(), root.join("link.txt").toString()],
                withWrap: false
            )
            @Expect(linkCode, 0)
            let symlinkWrite = metisWorkspaceSafeWrite(root, "link.txt", "bad")
            @Expect(symlinkWrite.ok, false)
            @Expect(String.fromUtf8(File.readFrom(outside.join("target.txt"))), "keep")
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
            cleanupWorkspaceBootstrapTestDir(outside)
        }
    }

    @TestCase
    public func identityMarkdownParsesFieldsAndValidatesAvatarBoundary(): Unit {
        let root = Path("/tmp/metis-agent-workspace-identity")
        try {
            cleanupWorkspaceBootstrapTestDir(root)
            Directory.create(root.join("assets"), recursive: true)
            File.writeTo(root.join("assets").join("avatar.png"), "png".toArray())

            let identity = parseMetisIdentityMarkdown(
                "# Identity\n\n" +
                "Name: Planner\n" +
                "Emoji: P\n" +
                "Theme: slate\n" +
                "Creature: \n" +
                "Vibe: calm\n" +
                "Avatar: assets/avatar.png\n"
            )
            @Expect(identity.name, "Planner")
            @Expect(identity.emoji, "P")
            @Expect(identity.theme, "slate")
            @Expect(identity.vibe, "calm")
            @Expect(identity.avatar, "assets/avatar.png")

            @Expect(validateMetisIdentityAvatar(root, "assets/avatar.png").ok, true)
            @Expect(validateMetisIdentityAvatar(root, "https://example.test/avatar.png").ok, true)
            @Expect(validateMetisIdentityAvatar(root, "HTTPS://example.test/avatar.png").ok, true)
            @Expect(validateMetisIdentityAvatar(root, "data:image/png;base64,AAAA").ok, true)
            @Expect(validateMetisIdentityAvatar(root, "DATA:image/png;base64,AAAA").ok, true)
            @Expect(validateMetisIdentityAvatar(root, "~/avatar.png").ok, false)
            @Expect(validateMetisIdentityAvatar(root, "file:///tmp/avatar.png").ok, false)
            @Expect(validateMetisIdentityAvatar(root, "../avatar.png").ok, false)
        } finally {
            cleanupWorkspaceBootstrapTestDir(root)
        }
    }
}
