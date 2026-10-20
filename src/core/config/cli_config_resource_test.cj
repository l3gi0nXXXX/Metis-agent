package metis.core.config

import magic.config.Config
import std.env.{getProcessId, getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}

@When[os == "macOS"]
private func resourceConfigFdCount(): Int64 {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    @Expect(bytes > 0, true)
    Int64(bytes) / 8
}

@When[os != "macOS"]
private func resourceConfigFdCount(): Int64 { 0 }

private func withResourceConfigHome(block: (Path) -> Unit): Unit {
    synchronized(MetisProcessEnvironmentLock) {
        let root = Path("/tmp/metis-file-resource-config-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(root, recursive: true)
        let oldHome = getVariable("METIS_HOME") ?? ""
        let oldWorkspace = CliConfig.workspaceDirOverride
        let oldLog = Config.logFile
        setVariable("METIS_HOME", root.toString())
        CliConfig.workspaceDirOverride = root.toString()
        CliConfig.invalidatePathCache()
        Config.logFile = root.join("diagnostic.log").toString()
        try {
            block(root)
        } finally {
            Config.logFile = oldLog
            setVariable("METIS_HOME", oldHome)
            CliConfig.workspaceDirOverride = oldWorkspace
            CliConfig.invalidatePathCache()
            remove(root, recursive: true)
        }
    }
}

@Test
public class CliConfigResourceTest {
    @TestCase
    public func resourceRulesUnicodeAndLongReadsCloseBeforeReturning(): Unit {
        withResourceConfigHome({ root =>
            let content = StringBuilder()
            for (_ in 0..4096) { content.append("中文规则🧪\n") }
            let expected = content.toString()
            File.writeTo(root.join("AGENTS.md"), expected.toArray())
            @Expect(CliConfig.userRules, expected)
            let before = resourceConfigFdCount()
            for (_ in 0..32) { @Expect(CliConfig.userRules, expected) }
            @Expect(resourceConfigFdCount() <= before, true)
        })
    }

    @TestCase
    public func resourceRulesMissingEmptyAndInvalidEncodingStayIsolated(): Unit {
        withResourceConfigHome({ root =>
            @Expect(CliConfig.userRules, "")
            let path = root.join("AGENTS.md")
            File.writeTo(path, [])
            @Expect(CliConfig.userRules, "")
            File.writeTo(path, [0xffu8, 0xfeu8, 0x00u8])
            @Expect(CliConfig.userRules, "")
            let before = resourceConfigFdCount()
            for (_ in 0..32) { @Expect(CliConfig.userRules, "") }
            @Expect(resourceConfigFdCount() <= before, true)
            File.writeTo(path, "{ malformed JSON / 用户规则😀".toArray())
            @Expect(CliConfig.userRules, "{ malformed JSON / 用户规则😀")
        })
    }
}
