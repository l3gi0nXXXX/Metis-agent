package metis.core.skills

import magic.config.Config
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager, MetisProcessEnvironmentLock}
import std.env.{getProcessId, getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign {
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, size: Int32): Int32
}

@When[os == "macOS"]
private func resourceSkillsFdCount(): Int64 {
    var descriptors = VArray<UInt64, $4096>(repeat: 0)
    let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, inout descriptors, 32768) }
    @Expect(bytes > 0, true)
    Int64(bytes) / 8
}

@When[os != "macOS"]
private func resourceSkillsFdCount(): Int64 { 0 }

@Test
public class SkillsResourceTest {
    @TestCase
    public func resourceSkillRuntimeAndInfoReadUnicodeWithoutRetainingFiles(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-file-resource-skills-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            let dir = root.join("skills").join("fd-resource-skill")
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
                let body = StringBuilder()
                for (_ in 0..1024) { body.append("长正文😀\n") }
                File.writeTo(dir.join("SKILL.md"), ("---\nname: fd-resource-skill\ndescription: 中文资源🧪\nhomepage: https://example.invalid/fd\n---\n" + body.toString()).toArray())
                SkillsPrompt.invalidate()
                var found = false
                for (descriptor in SkillsPrompt.listSkillDescriptors()) {
                    if (descriptor.name == "fd-resource-skill") {
                        found = true
                        @Expect(descriptor.description, "中文资源🧪")
                    }
                }
                @Expect(found, true)
                let first = tryHandleSkillsCommand("/skills info fd-resource-skill").getOrThrow()
                @Expect(first.contains("中文资源🧪"), true)
                @Expect(first.contains("https://example.invalid/fd"), true)
                let before = resourceSkillsFdCount()
                for (_ in 0..32) {
                    SkillsPrompt.invalidate()
                    let info = tryHandleSkillsCommand("/skills info fd-resource-skill").getOrThrow()
                    @Expect(info.contains("中文资源🧪"), true)
                }
                @Expect(resourceSkillsFdCount() <= before, true)
                let invalidFiles: Array<Array<Byte>> = [[], [0xffu8, 0xfeu8], "---\nname: fd-resource-skill\n{ malformed JSON 😀".toArray()]
                for (bad in invalidFiles) {
                    File.writeTo(dir.join("SKILL.md"), bad)
                    SkillsPrompt.invalidate()
                    let _ = SkillsPrompt.listSkillDescriptors()
                    let reply = tryHandleSkillsCommand("/skills info fd-resource-skill")
                    @Expect(reply.isSome(), true)
                }
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
