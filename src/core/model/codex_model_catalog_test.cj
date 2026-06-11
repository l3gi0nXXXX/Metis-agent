package metis.core.model

import std.unittest.testmacro.*

@Test
public class CodexModelCatalogTest {
    @TestCase
    public func modelResolutionUsesLiveConfigCacheStaticOrderAndNormalizesProviderPrefix(): Unit {
        let live = codexResolveModelIdsFromSources(liveIds: ["openai/gpt-5.4"])
        @Expect(live.source, "live")
        @Expect(live.modelIds.contains("gpt-5.4"), true)

        let config = codexResolveModelIdsFromSources(configText: "model = \"openai/gpt-5.4\"\n")
        @Expect(config.source, "config.toml")
        @Expect(config.modelIds.contains("gpt-5.4"), true)

        let cache = codexResolveModelIdsFromSources(cacheText: "{\"models\":[{\"id\":\"openai-codex/gpt-5.4\"}]}")
        @Expect(cache.source, "models_cache.json")
        @Expect(cache.modelIds.contains("gpt-5.4"), true)

        let fallback = codexResolveModelIdsFromSources()
        @Expect(fallback.source, "static")
        @Expect(fallback.modelIds[0], "gpt-5.5")
    }

    @TestCase
    public func catalogFilteringKeepsSparkButFiltersHiddenAndDeprecatedSlugs(): Unit {
        let entries = [
            CodexModelCatalogEntry("gpt-5.3-codex-spark", "", false),
            CodexModelCatalogEntry("gpt-5.6-hidden", "hidden", true),
            CodexModelCatalogEntry("gpt-5.6-hide", "hide", true),
            CodexModelCatalogEntry("gpt-5.2-codex", "", true)
        ]
        let ids = codexModelIdsFromEntries(entries)
        @Expect(ids.contains("gpt-5.3-codex-spark"), true)
        @Expect(ids.contains("gpt-5.6-hidden"), false)
        @Expect(ids.contains("gpt-5.6-hide"), false)
        @Expect(ids.contains("gpt-5.2-codex"), false)
        @Expect(codexStaticModelCatalog().contains("gpt-5.2-codex"), false)

        let compat = codexForwardCompatModelCatalog(["gpt-5.3-codex"])
        @Expect(compat[0], "gpt-5.5")
        @Expect(compat[1], "gpt-5.4-mini")
        @Expect(compat[2], "gpt-5.4")
        @Expect(compat.contains("gpt-5.3-codex-spark"), true)
    }

    @TestCase
    public func codexContextWindowInvalidatesOpenAIStyleStaleCacheAndUsesCodexFallbacks(): Unit {
        let stale = [CodexContextCacheEntry("gpt-5.5", 1050000)]
        @Expect(codexResolveContextWindow("gpt-5.5", cache: stale), 272000)
        @Expect(codexContextFallback("gpt-5.3-codex-spark"), 128000)
        @Expect(codexResolveDisplayContextLength("openai-codex", "openai-codex:gpt-5.5"), 272000)
        @Expect(codexResolveDisplayContextLength("openai", "openai:gpt-5.5"), 0)
    }

    @TestCase
    public func modelValidationTrustsExplicitModelsAndDefaultsFromCatalog(): Unit {
        let catalog = ["gpt-5.5", "gpt-5.4"]
        let exact = codexValidateModelChoice("gpt-5.5", catalog)
        @Expect(exact.status, "accepted")
        @Expect(exact.modelId, "gpt-5.5")

        let corrected = codexValidateModelChoice("gpt_5.4", catalog)
        @Expect(corrected.status, "corrected")
        @Expect(corrected.modelId, "gpt-5.4")

        let unknown = codexValidateModelChoice("anthropic/claude-opus-4.6", catalog)
        @Expect(unknown.status, "acceptedWithWarning")
        @Expect(unknown.modelId, "claude-opus-4.6")

        @Expect(codexNormalizeExplicitModelForOpenAICodex("openai/gpt-5.4"), "gpt-5.4")
        @Expect(codexNormalizeExplicitModelForOpenAICodex("anthropic/claude-opus-4.6"), "claude-opus-4.6")
        @Expect(codexNormalizeExplicitModelForOpenAICodex("gpt-5.4"), "gpt-5.4")
        @Expect(codexDefaultModelForUntouchedDefault(catalog), "gpt-5.5")
        @Expect(codexDefaultModelForUntouchedDefault(Array<String>()), "gpt-5.3-codex")
    }

    @TestCase
    public func emptyRuntimeModelDefaultOnlyAppliesToOpenAICodexProvider(): Unit {
        @Expect(codexDefaultModelForEmptyRuntimeModel("openai-codex", "", ["gpt-5.5"]), "gpt-5.5")
        @Expect(codexDefaultModelForEmptyRuntimeModel("openai-codex", "gpt-5.4", ["gpt-5.5"]), "gpt-5.4")
        @Expect(codexDefaultModelForEmptyRuntimeModel("openai", "", ["gpt-5.5"]), "")
    }
}
