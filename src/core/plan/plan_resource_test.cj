package metis.core.plan

import magic.config.Config
import metis.core.config.{CliConfig, MetisProcessEnvironmentLock}
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class PlanResourceTest {
    @TestCase
    public func resourcePlanSavesAndLoadsOnlyInsideTemporaryHome(): Unit {
        synchronized(MetisProcessEnvironmentLock) {
            let root = Path("/tmp/metis-file-resource-plan-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
            Directory.create(root, recursive: true)
            let oldHome = getVariable("METIS_HOME") ?? ""
            let oldLog = Config.logFile
            setVariable("METIS_HOME", root.toString())
            CliConfig.invalidatePathCache()
            Config.logFile = root.join("diagnostic.log").toString()
            try {
                let plan = Plan(["检查资源🧪", "中文任务😀"])
                for (_ in 0..32) { plan.save() }
                @Expect(String.fromUtf8(File.readFrom(root.join("todo.md"))), plan.toString())
                @Expect(Plan.load().toString(), plan.toString())
                remove(root.join("todo.md"))
                Directory.create(root.join("todo.md"))
                // Opening a directory as the target must remain an isolated save failure.
                plan.save()
                @Expect(Plan.load().topLevelTasks.isEmpty(), true)
            } finally {
                Config.logFile = oldLog
                setVariable("METIS_HOME", oldHome)
                CliConfig.invalidatePathCache()
                remove(root, recursive: true)
            }
        }
    }
}
