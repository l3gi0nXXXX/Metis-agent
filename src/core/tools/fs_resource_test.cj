package metis.core.tools

import magic.config.Config
import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class FsResourceTest {
    @TestCase
    public func resourceFileCreateClosesAndPreservesHumanResult(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-file-resource-create-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            Directory.create(root, recursive: true)
            let oldHome = getVariable("METIS_HOME") ?? ""
            let oldAuto = CliConfig.auto
            let oldLog = Config.logFile
            setVariable("METIS_HOME", root.toString())
            CliConfig.invalidatePathCache()
            CliConfig.auto = true
            Config.logFile = root.join("diagnostic.log").toString()
            try {
                let path = root.join("创建🧪.txt").toString()
                let result = fileCreate(path, "中文😀")
                @Expect(result.contains("created successfully!"), true)
                @Expect(String.fromUtf8(File.readFrom(path)), "中文😀")
                let failed = fileCreate(root.join("missing").join("child").toString(), "safe body")
                @Expect(failed.contains("Failed to create file:"), true)
                @Expect(failed.contains("safe body"), false)
                @Expect(fileCreate("relative-path", "body"), "File path must be absolute")
            } finally {
                CliConfig.auto = oldAuto
                Config.logFile = oldLog
                setVariable("METIS_HOME", oldHome)
                CliConfig.invalidatePathCache()
                remove(root, recursive: true)
            }
        }
    }
}
