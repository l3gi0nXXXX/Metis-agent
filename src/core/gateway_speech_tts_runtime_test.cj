package metis.core

import magic.jsonable.*

import std.collection.ArrayList
import std.convert.*
import std.env.{getVariable, setVariable}
import std.fs.{Directory, File, Path, exists}
import std.time.*
import std.unittest.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString}

private func ttsTestTempRoot(label: String): Path {
    let root = Path("/tmp/metis-speech-tts-runtime-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    root
}

private func ttsTestProvider(command: Array<String>, outputExtension!: String = "ogg", timeoutMs!: Int64 = 3000): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("command"))
    let commandJson = JsonArray()
    for (part in command) {
        commandJson.add(JsonString(part))
    }
    provider.put("command", commandJson)
    provider.put("outputExtension", JsonString(outputExtension))
    provider.put("timeoutMs", JsonInt(timeoutMs))
    provider
}

private func ttsTestOpenAICompatibleProvider(): JsonObject {
    let provider = JsonObject()
    provider.put("kind", JsonString("openai-compatible"))
    provider.put("apiKey", JsonString("test-api-key"))
    provider.put("baseUrl", JsonString("https://example.invalid/v1"))
    provider.put("model", JsonString("qwen3-tts-flash"))
    provider.put("voice", JsonString("Chelsie"))
    provider
}

private func ttsTestOpenAICompatibleBody(request: JsonObject): JsonObject {
    match (request.get("body")) {
        case Some(v) => try { v.asObject() } catch (_: Exception) { JsonObject() }
        case None => JsonObject()
    }
}

private func ttsTestConfig(providerId: String, provider: JsonObject): JsonObject {
    let config = JsonObject()
    let providers = JsonObject()
    providers.put(providerId, provider)
    config.put("enabled", JsonBool(true))
    config.put("provider", JsonString(providerId))
    config.put("providers", providers)
    config
}

private func ttsTestState(provider!: String = "", enabled!: Bool = true, limit!: Int64 = 4000): JsonObject {
    let state = JsonObject()
    state.put("enabled", JsonBool(enabled))
    state.put("provider", JsonString(provider))
    state.put("limit", JsonInt(limit))
    state
}

private func ttsTestPrefs(audioAsVoice: Bool): JsonObject {
    let prefs = JsonObject()
    prefs.put("audioAsVoice", JsonBool(audioAsVoice))
    return prefs
}

private func ttsTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func ttsTestBool(obj: JsonObject, key: String): Bool {
    match (obj.get(key)) {
        case Some(v) => try { v.asBool().getValue() } catch (_: Exception) { false }
        case None => false
    }
}

private func ttsTestAttempts(obj: JsonObject): JsonArray {
    match (obj.get("attempts")) {
        case Some(v) => try { v.asArray() } catch (_: Exception) { JsonArray([]) }
        case None => JsonArray([])
    }
}

private func ttsTestAttempt(obj: JsonObject, index: Int64): JsonObject {
    try { ttsTestAttempts(obj).getItems()[index].asObject() } catch (_: Exception) { JsonObject() }
}

@Test
public class GatewaySpeechTtsRuntimeTest {
    @TestCase
    public func fakeProviderCreatesVoicePayloadWhenAudioAsVoiceIsTrue(): Unit {
        let root = ttsTestTempRoot("fake-voice")
        let config = ttsTestConfig("fake", JsonObject())
        let result = gatewaySpeechTtsSynthesize(config, ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)

        @Expect(ttsTestBool(result, "ok"), true)
        @Expect(ttsTestString(result, "status"), "ok")
        @Expect(ttsTestString(result, "provider"), "fake")
        @Expect(ttsTestString(result, "payloadKind"), "voice")
        @Expect(ttsTestString(result, "payload").startsWith("[voice]"), true)
        @Expect(exists(Path(ttsTestString(result, "audioPath"))), true)
    }

    @TestCase
    public func fakeProviderCreatesAudioPayloadWhenAudioAsVoiceIsFalse(): Unit {
        let root = ttsTestTempRoot("fake-audio")
        let config = ttsTestConfig("fake", JsonObject())
        let result = gatewaySpeechTtsSynthesize(config, ttsTestPrefs(false), ttsTestState(), "hello", outputRoot: root)

        @Expect(ttsTestBool(result, "ok"), true)
        @Expect(ttsTestString(result, "payloadKind"), "audio")
        @Expect(ttsTestString(result, "payload").startsWith("[audio]"), true)
    }

    @TestCase
    public func commandProviderUsesArgvPlaceholdersAndWritesAudio(): Unit {
        let root = ttsTestTempRoot("command")
        let provider = ttsTestProvider([
            "sh",
            "-c",
            "printf '%s' \"$1\" > \"$2\"",
            "metis-tts",
            "{text}",
            "{output}"
        ])
        let result = gatewaySpeechTtsSynthesize(ttsTestConfig("local", provider), ttsTestPrefs(false), ttsTestState(), "hello-command", outputRoot: root)
        let audioPath = Path(ttsTestString(result, "audioPath"))

        @Expect(ttsTestBool(result, "ok"), true)
        @Expect(ttsTestString(result, "providerKind"), "command")
        @Expect(ttsTestString(result, "payloadKind"), "audio")
        @Expect(String.fromUtf8(File.readFrom(audioPath)), "hello-command")
    }

    @TestCase
    public func commandProviderNonZeroExitDoesNotExposeStderrSecrets(): Unit {
        let root = ttsTestTempRoot("nonzero")
        let provider = ttsTestProvider([
            "sh",
            "-c",
            "echo \"$METIS_TTS_SECRET\" >&2; exit 7"
        ])
        let result = gatewaySpeechTtsSynthesize(ttsTestConfig("local", provider), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)

        @Expect(ttsTestBool(result, "ok"), false)
        @Expect(ttsTestString(result, "status"), "provider_error")
        @Expect(ttsTestString(result, "message").contains("token-secret-value"), false)
        @Expect(ttsTestString(result, "stderr").contains("token-secret-value"), false)
    }

    @TestCase
    public func commandProviderMissingOutputReturnsProviderError(): Unit {
        let root = ttsTestTempRoot("missing-output")
        let provider = ttsTestProvider(["sh", "-c", "exit 0"])
        let result = gatewaySpeechTtsSynthesize(ttsTestConfig("local", provider), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)

        @Expect(ttsTestBool(result, "ok"), false)
        @Expect(ttsTestString(result, "status"), "provider_error")
        @Expect(ttsTestString(result, "message").contains("did not create"), true)
    }

    @TestCase
    public func commandProviderTimeoutReturnsTimeoutStatus(): Unit {
        let root = ttsTestTempRoot("timeout")
        let provider = ttsTestProvider(["sh", "-c", "sleep 2"], timeoutMs: 1)
        let result = gatewaySpeechTtsSynthesize(ttsTestConfig("local", provider), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)

        @Expect(ttsTestBool(result, "ok"), false)
        @Expect(ttsTestString(result, "status"), "timeout")
    }

    @TestCase
    public func statusReportsSharedProviderAndLegacyMigrationHint(): Unit {
        let config = ttsTestConfig("local", ttsTestProvider(["tts-bin", "{text}", "{output}"]))
        config.put("legacy", JsonBool(true))
        config.put("migrationHint", JsonString("Move gateway.channelsExtra.telegramTts to gateway.telegram.speech.tts or gateway.speech.tts."))
        let status = gatewaySpeechTtsStatus(config, ttsTestPrefs(false), ttsTestState())

        @Expect(ttsTestString(status, "status"), "ok")
        @Expect(ttsTestString(status, "provider"), "local")
        @Expect(ttsTestString(status, "providerKind"), "command")
        @Expect(ttsTestBool(status, "legacy"), true)
        @Expect(ttsTestString(status, "migrationHint").contains("gateway.channelsExtra.telegramTts"), true)
    }

    @TestCase
    public func statusAcceptsOpenAICompatibleProviderWithoutDroppingExistingProviders(): Unit {
        let config = ttsTestConfig("dashscope", ttsTestOpenAICompatibleProvider())
        let status = gatewaySpeechTtsStatus(config, ttsTestPrefs(true), ttsTestState())

        @Expect(ttsTestString(status, "status"), "ok")
        @Expect(ttsTestString(status, "provider"), "dashscope")
        @Expect(ttsTestString(status, "providerKind"), "openai-compatible")
        @Expect(ttsTestBool(status, "audioAsVoice"), true)
    }

    @TestCase
    public func openAICompatibleProviderWithoutApiKeyIsNotConfigured(): Unit {
        let provider = JsonObject()
        provider.put("kind", JsonString("openai-compatible"))
        provider.put("baseUrl", JsonString("https://example.invalid/v1"))
        provider.put("model", JsonString("qwen3-tts-flash"))
        provider.put("voice", JsonString("Chelsie"))
        let status = gatewaySpeechTtsStatus(ttsTestConfig("dashscope", provider), ttsTestPrefs(true), ttsTestState())

        @Expect(ttsTestBool(status, "ok"), false)
        @Expect(ttsTestString(status, "status"), "not_configured")
        @Expect(ttsTestString(status, "providerKind"), "openai-compatible")
    }

    @TestCase
    public func openAICompatibleProviderPostsSpeechRequestAndWritesVoiceAudio(): Unit {
        let root = ttsTestTempRoot("openai-compatible")
        let sawRequests = ArrayList<String>()
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ request: JsonObject =>
            sawRequests.add("yes")
            let body = ttsTestOpenAICompatibleBody(request)
            @Expect(ttsTestString(request, "url"), "https://example.invalid/v1/audio/speech")
            @Expect(ttsTestString(request, "authorization"), "Bearer test-api-key")
            @Expect(ttsTestString(body, "model"), "qwen3-tts-flash")
            @Expect(ttsTestString(body, "input"), "hello-openai")
            @Expect(ttsTestString(body, "voice"), "Chelsie")
            @Expect(ttsTestString(body, "response_format"), "opus")
            GatewaySpeechTtsOpenAICompatibleHttpResult(200, bodyBytes: "OPENAI-COMPATIBLE-AUDIO".toArray())
        }))
        try {
            let result = gatewaySpeechTtsSynthesize(ttsTestConfig("dashscope", ttsTestOpenAICompatibleProvider()), ttsTestPrefs(true), ttsTestState(), "hello-openai", outputRoot: root)
            let audioPath = Path(ttsTestString(result, "audioPath"))

            @Expect(sawRequests.size, 1)
            @Expect(ttsTestBool(result, "ok"), true)
            @Expect(ttsTestString(result, "provider"), "dashscope")
            @Expect(ttsTestString(result, "providerKind"), "openai-compatible")
            @Expect(ttsTestString(result, "payloadKind"), "voice")
            @Expect(ttsTestString(result, "audioPath").endsWith(".opus"), true)
            @Expect(String.fromUtf8(File.readFrom(audioPath)), "OPENAI-COMPATIBLE-AUDIO")
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }
    }

    @TestCase
    public func openAICompatibleProviderMapsAuthFailureWithoutLeakingApiKey(): Unit {
        let root = ttsTestTempRoot("openai-auth")
        let provider = ttsTestOpenAICompatibleProvider()
        provider.put("apiKey", JsonString("secret-key-never-print"))
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ _request: JsonObject =>
            GatewaySpeechTtsOpenAICompatibleHttpResult(401, bodyBytes: "{\"error\":{\"message\":\"bad key\"}}".toArray())
        }))
        try {
            let result = gatewaySpeechTtsSynthesize(ttsTestConfig("dashscope", provider), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)

            @Expect(ttsTestBool(result, "ok"), false)
            @Expect(ttsTestString(result, "status"), "auth_error")
            @Expect(ttsTestString(result, "message").contains("secret-key-never-print"), false)
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }
    }

    @TestCase
    public func openAICompatibleProviderMapsServerFailureAndTimeout(): Unit {
        let root = ttsTestTempRoot("openai-errors")
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ _request: JsonObject =>
            GatewaySpeechTtsOpenAICompatibleHttpResult(500, bodyBytes: "server failed".toArray())
        }))
        try {
            let providerError = gatewaySpeechTtsSynthesize(ttsTestConfig("dashscope", ttsTestOpenAICompatibleProvider()), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)
            @Expect(ttsTestBool(providerError, "ok"), false)
            @Expect(ttsTestString(providerError, "status"), "provider_error")
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }

        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ _request: JsonObject =>
            GatewaySpeechTtsOpenAICompatibleHttpResult(408, error: "timeout")
        }))
        try {
            let timeout = gatewaySpeechTtsSynthesize(ttsTestConfig("dashscope", ttsTestOpenAICompatibleProvider()), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)
            @Expect(ttsTestBool(timeout, "ok"), false)
            @Expect(ttsTestString(timeout, "status"), "timeout")
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }
    }

    @TestCase
    public func openAICompatibleProviderResolvesApiKeyFromEnvironmentReference(): Unit {
        let root = ttsTestTempRoot("openai-env")
        let envKey = "METIS_TTS_TEST_API_KEY_${DateTime.now().toUnixTimeStamp().toNanoseconds()}"
        let old = getVariable(envKey)
        setVariable(envKey, "env-test-api-key")
        let provider = ttsTestOpenAICompatibleProvider()
        provider.put("apiKey", JsonString("$" + "{" + envKey + "}"))
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ request: JsonObject =>
            @Expect(ttsTestString(request, "authorization"), "Bearer env-test-api-key")
            GatewaySpeechTtsOpenAICompatibleHttpResult(200, bodyBytes: "ENV-AUDIO".toArray())
        }))
        try {
            let status = gatewaySpeechTtsStatus(ttsTestConfig("dashscope", provider), ttsTestPrefs(true), ttsTestState())
            @Expect(ttsTestBool(status, "ok"), true)
            let result = gatewaySpeechTtsSynthesize(ttsTestConfig("dashscope", provider), ttsTestPrefs(true), ttsTestState(), "hello", outputRoot: root)
            @Expect(ttsTestBool(result, "ok"), true)
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
            match (old) {
                case Some(value) => setVariable(envKey, value)
                case None => setVariable(envKey, "")
            }
        }
    }

    @TestCase
    public func ttsFallsBackToSecondaryProviderAndRecordsAttempts(): Unit {
        let root = ttsTestTempRoot("fallback")
        let config = ttsTestConfig("primary", ttsTestOpenAICompatibleProvider())
        let providers = config.get("providers").getOrThrow().asObject()
        let fallback = JsonObject()
        fallback.put("kind", JsonString("fake"))
        providers.put("fallback", fallback)
        config.put("fallbackProviders", JsonArray([JsonString("fallback")]))
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ _request: JsonObject =>
            GatewaySpeechTtsOpenAICompatibleHttpResult(500, bodyBytes: "primary failed".toArray())
        }))
        try {
            let result = gatewaySpeechTtsSynthesize(config, ttsTestPrefs(true), ttsTestState(), "hello fallback", outputRoot: root)
            let attempts = ttsTestAttempts(result)
            let first = ttsTestAttempt(result, 0)
            let second = ttsTestAttempt(result, 1)

            @Expect(ttsTestBool(result, "ok"), true)
            @Expect(ttsTestString(result, "provider"), "fallback")
            @Expect(ttsTestString(result, "payloadKind"), "voice")
            @Expect(attempts.size(), 2)
            @Expect(ttsTestString(first, "provider"), "primary")
            @Expect(ttsTestString(first, "outcome"), "failed")
            @Expect(ttsTestString(first, "reasonCode"), "provider_error")
            @Expect(ttsTestString(second, "provider"), "fallback")
            @Expect(ttsTestString(second, "outcome"), "ok")
            @Expect(result.toJsonString().contains("test-api-key"), false)
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }
    }

    @TestCase
    public func ttsUsesDegradeMessageWhenAllProvidersFail(): Unit {
        let root = ttsTestTempRoot("degrade")
        let config = ttsTestConfig("primary", ttsTestOpenAICompatibleProvider())
        config.put("degradeMessage", JsonString("语音暂时发送失败，我先打字陪你。"))
        let providers = config.get("providers").getOrThrow().asObject()
        providers.put("fallback", ttsTestProvider(["sh", "-c", "exit 9"]))
        config.put("fallbackProviders", JsonArray([JsonString("fallback")]))
        setGatewaySpeechTtsOpenAICompatibleRunnerForTest(Some({ _request: JsonObject =>
            GatewaySpeechTtsOpenAICompatibleHttpResult(500, bodyBytes: "primary failed".toArray())
        }))
        try {
            let result = gatewaySpeechTtsSynthesize(config, ttsTestPrefs(true), ttsTestState(), "hello degrade", outputRoot: root)

            @Expect(ttsTestBool(result, "ok"), true)
            @Expect(ttsTestString(result, "status"), "degraded")
            @Expect(ttsTestString(result, "payloadKind"), "text")
            @Expect(ttsTestString(result, "payload"), "语音暂时发送失败，我先打字陪你。")
            @Expect(ttsTestAttempts(result).size(), 2)
            @Expect(result.toJsonString().contains("test-api-key"), false)
        } finally {
            setGatewaySpeechTtsOpenAICompatibleRunnerForTest(None<(JsonObject) -> GatewaySpeechTtsOpenAICompatibleHttpResult>)
        }
    }
}
