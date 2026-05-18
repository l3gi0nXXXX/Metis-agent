package metis.core.agents

import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import metis.core.prompting.MetisSystemPromptBuilder

import std.env.{getVariable, setVariable}
import std.fs.{Directory, Path, remove}
import std.unittest.testmacro.*

private func agentPdfRegistryResetEnv(oldHome: Option<String>, home: String): Unit {
    match (oldHome) {
        case Some(value) => setVariable("METIS_HOME", value)
        case None => setVariable("METIS_HOME", "")
    }
    MetisConfigManager.invalidate()
    CliSettingManager.invalidate()
    CliConfig.invalidatePathCache()
    try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
}

private func agentPdfRegistryContains(values: Array<String>, name: String): Bool {
    for (value in values) {
        if (value == name) {
            return true
        }
    }
    false
}

@Test
public class AgentPdfToolRegistryTest {
    @TestCase
    public func generalAgentToolNamesIncludePdf(): Unit {
        let home = "/tmp/metis-agent-pdf-registry-general"
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        try {
            CliConfig.model = "fake:agent-pdf-registry"
            let agent = GeneralCodeAgent()
            let names = MetisSystemPromptBuilder.collectToolNames(agent.toolManager.tools)
            @Expect(agentPdfRegistryContains(names, "pdf"), true)
        } finally {
            agentPdfRegistryResetEnv(oldHome, home)
        }
    }

    @TestCase
    public func cangjieAgentToolNamesIncludePdf(): Unit {
        let home = "/tmp/metis-agent-pdf-registry-cangjie"
        let oldHome = getVariable("METIS_HOME")
        try { remove(Path(home), recursive: true) } catch (_: Exception) { () }
        Directory.create(home, recursive: true)
        setVariable("METIS_HOME", home)
        MetisConfigManager.invalidate()
        CliSettingManager.invalidate()
        CliConfig.invalidatePathCache()
        let oldLsp = CliConfig.enableLSPTool
        CliConfig.enableLSPTool = false
        try {
            CliConfig.model = "fake:agent-pdf-registry"
            let agent = CangjieCodeAgent()
            let names = MetisSystemPromptBuilder.collectToolNames(agent.toolManager.tools)
            @Expect(agentPdfRegistryContains(names, "pdf"), true)
        } finally {
            CliConfig.enableLSPTool = oldLsp
            agentPdfRegistryResetEnv(oldHome, home)
        }
    }
}
