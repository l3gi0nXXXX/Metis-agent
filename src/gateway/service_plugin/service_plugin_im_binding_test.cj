package metis.gateway.service_plugin

import metis.core.config.{GatewayServicePluginUserSettings, GatewayUserSettings}

import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString}

private func servicePluginImTestUser(
    pluginId: String,
    channel: String,
    accountId: String,
    commandPrefix: String,
    enabled!: Bool = true,
    scopes!: Array<String> = ["direct"]
): GatewayUserSettings {
    var user = GatewayUserSettings()
    var plugin = GatewayServicePluginUserSettings()
    plugin.pluginId = pluginId
    plugin.enabled = enabled
    let binding = JsonObject()
    binding.put("accountId", JsonString(accountId))
    binding.put("commandPrefix", JsonString(commandPrefix))
    let scopeValues = JsonArray([])
    for (scope in scopes) {
        scopeValues.add(JsonString(scope))
    }
    binding.put("scopes", scopeValues)
    plugin.imBindings.put(channel, binding)
    user.servicePlugins = [plugin]
    user
}

private func servicePluginImTestMatch(
    user: GatewayUserSettings,
    channel: String,
    accountId: String,
    text: String
): ServicePluginImDispatchMatch {
    matchServicePluginImBinding(buildServicePluginImBindingRules(user), channel, accountId, text)
}

@Test
public class ServicePluginImBindingTest {
    @TestCase
    public func telegramGitcodeBindingMatchesPrefix(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode status")

        @Expect(result.matched, true)
        @Expect(result.pluginId, "gitcode-monitor")
        @Expect(result.channel, "telegram")
        @Expect(result.accountId, "tg-gitcode-monitor")
        @Expect(result.commandPrefix, "/gitcode")
        @Expect(result.commandText, "/gitcode status")
        @Expect(result.reason, "matched")
    }

    @TestCase
    public func telegramDefaultAccountDoesNotMatchGitcodeBinding(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "telegram", "default", "/gitcode status")

        @Expect(result.matched, false)
        @Expect(result.reason, "binding_not_found")
    }

    @TestCase
    public func feishuGitcodeBindingMatchesPrefix(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "feishu", "feishu-gitcode-monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "feishu", "feishu-gitcode-monitor", "/gitcode")

        @Expect(result.matched, true)
        @Expect(result.pluginId, "gitcode-monitor")
        @Expect(result.accountId, "feishu-gitcode-monitor")
    }

    @TestCase
    public func plainTextDoesNotMatchCommandPrefix(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "hello")

        @Expect(result.matched, false)
        @Expect(result.reason, "prefix_not_matched")
        @Expect(result.prefixMatched, false)
    }

    @TestCase
    public func similarPrefixDoesNotMatch(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode2 status")

        @Expect(result.matched, false)
        @Expect(result.reason, "prefix_not_matched")
    }

    @TestCase
    public func disabledServicePluginBindingDoesNotMatch(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "/gitcode", enabled: false)
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode status")

        @Expect(result.matched, false)
        @Expect(result.reason, "plugin_disabled")
        @Expect(result.prefixMatched, true)
    }

    @TestCase
    public func emptyCommandPrefixIsSkipped(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "tg-gitcode-monitor", "")
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode status")

        @Expect(result.matched, false)
        @Expect(result.reason, "prefix_not_matched")
    }

    @TestCase
    public func prefixedAccountIdsAreNormalizedForMatching(): Unit {
        let user = servicePluginImTestUser("gitcode-monitor", "telegram", "telegram:TG-GitCode-Monitor", "/gitcode")
        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode status")

        @Expect(result.matched, true)
        @Expect(result.accountId, "tg-gitcode-monitor")
    }

    @TestCase
    public func duplicateBindingsReturnConflictInsteadOfRandomSelection(): Unit {
        var user = GatewayUserSettings()
        var first = GatewayServicePluginUserSettings()
        first.pluginId = "gitcode-monitor"
        let firstBinding = JsonObject()
        firstBinding.put("accountId", JsonString("tg-gitcode-monitor"))
        firstBinding.put("commandPrefix", JsonString("/gitcode"))
        first.imBindings.put("telegram", firstBinding)
        var second = GatewayServicePluginUserSettings()
        second.pluginId = "gitcode-monitor-copy"
        let secondBinding = JsonObject()
        secondBinding.put("accountId", JsonString("tg-gitcode-monitor"))
        secondBinding.put("commandPrefix", JsonString("/gitcode"))
        second.imBindings.put("telegram", secondBinding)
        user.servicePlugins = [first, second]

        let result = servicePluginImTestMatch(user, "telegram", "tg-gitcode-monitor", "/gitcode status")

        @Expect(result.matched, false)
        @Expect(result.reason, "binding_conflict")
        @Expect(result.prefixMatched, true)
    }
}
