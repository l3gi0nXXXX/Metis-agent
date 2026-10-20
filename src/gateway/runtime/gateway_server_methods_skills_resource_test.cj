package metis.gateway.runtime

import magic.config.Config
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import metis.core.skills.SkillsPrompt
import std.env.{getProcessId, getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}

@When[os == "macOS"]
private func resourceRpcFdCount(): Int64 {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    @Expect(bytes > 0, true)
    Int64(bytes) / 8
}

@When[os != "macOS"]
private func resourceRpcFdCount(): Int64 { 0 }

@Test
public class GatewaySkillsResourceTest {
    @TestCase
    public func resourceSkillsRpcKeepsUnicodeAndInvalidFilesIsolated(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-file-resource-skills-rpc-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let dir = root.join("skills").join("fd-resource-rpc")
            Directory.create(dir, recursive: true)
            let oldHome = getVariable("METIS_HOME") ?? ""
            let oldWorkspace = CliConfig.workspaceDirOverride
            let oldLog = Config.logFile
            setVariable("METIS_HOME", root.toString())
            CliConfig.workspaceDirOverride = root.toString()
            CliConfig.invalidatePathCache()
            MetisConfigManager.invalidate()
            CliSettingManager.invalidate()
            Config.logFile = root.join("diagnostic.log").toString()
            try {
                let _ = MetisConfigManager.setSkillsEnabled(true)
                File.writeTo(dir.join("SKILL.md"), "---\nname: fd-resource-rpc\ndescription: 中文接口🧪\n---\n安全正文😀".toArray())
                SkillsPrompt.invalidate()
                @Expect(handleGatewaySkillsFamily("skills.status").getOrThrow().ok, true)
                let before = resourceRpcFdCount()
                for (_ in 0..32) {
                    SkillsPrompt.invalidate()
                    let response = handleGatewaySkillsFamily("skills.status").getOrThrow()
                    @Expect(response.ok, true)
                    @Expect(response.result.toJsonString().contains("中文接口🧪"), true)
                }
                @Expect(resourceRpcFdCount() <= before, true)
                File.writeTo(dir.join("SKILL.md"), [0xffu8, 0xfeu8])
                SkillsPrompt.invalidate()
                @Expect(handleGatewaySkillsFamily("skills.status").getOrThrow().ok, true)
            } finally {
                SkillsPrompt.invalidate()
                Config.logFile = oldLog
                setVariable("METIS_HOME", oldHome)
                CliConfig.workspaceDirOverride = oldWorkspace
                CliConfig.invalidatePathCache()
                MetisConfigManager.invalidate()
                CliSettingManager.invalidate()
                remove(root, recursive: true)
            }
        }
    }
}
