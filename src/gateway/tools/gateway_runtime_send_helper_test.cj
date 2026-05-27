package metis.gateway.tools

import metis.core.{GatewayToolRuntimeContext, gatewayWithToolRuntimeContext}

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

@Test
public class GatewayRuntimeSendHelperTest {
    private func samplePayload(): JsonObject {
        let payload = JsonObject()
        payload.put("channel", JsonString("telegram"))
        payload.put("peerId", JsonString("user:1"))
        payload.put("text", JsonString("hello"))
        payload.put("replyToMessageId", JsonString("42"))
        payload
    }

    private func okResult(source: String): JsonObject {
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("source", JsonString(source))
        out
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendUsesTestRunnerFirst(): Unit {
        let methods = ArrayList<String>()
        let payloads = ArrayList<JsonObject>()
        let payload = this.samplePayload()
        let out = gatewayToolInvokeChannelsSend(
            "runtime_send_helper_test",
            payload,
            callRunnerForTest: Some({ method: String, params: JsonObject =>
                methods.add(method)
                payloads.add(params)
                this.okResult("runner")
            })
        )

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(out.get("source").getOrThrow().asString().getValue(), "runner")
        @Expect(methods.size, 1)
        @Expect(methods[0], "channels.send")
        @Expect(payloads[0].get("replyToMessageId").getOrThrow().asString().getValue(), "42")
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendUsesRuntimeHookInsideContext(): Unit {
        let methods = ArrayList<String>()
        let cliCalls = ArrayList<String>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            gatewayCallHook: Some({ method: String, _params: JsonObject =>
                methods.add(method)
                this.okResult("hook")
            })
        )

        let out = gatewayWithToolRuntimeContext(context, { =>
            gatewayToolInvokeChannelsSend(
                "runtime_send_helper_test",
                this.samplePayload(),
                cliFallback: Some({ =>
                    cliCalls.add("called")
                    this.okResult("cli")
                })
            )
        })

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(out.get("source").getOrThrow().asString().getValue(), "hook")
        @Expect(methods.size, 1)
        @Expect(methods[0], "channels.send")
        @Expect(cliCalls.size, 0)
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendFailsFastWhenRuntimeHookMissing(): Unit {
        let cliCalls = ArrayList<String>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1"
        )

        let out = gatewayWithToolRuntimeContext(context, { =>
            gatewayToolInvokeChannelsSend(
                "runtime_send_helper_test",
                this.samplePayload(),
                cliFallback: Some({ =>
                    cliCalls.add("called")
                    this.okResult("cli")
                })
            )
        })

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(out.get("status").getOrThrow().asString().getValue(), "error")
        @Expect(out.get("code").getOrThrow().asString().getValue(), "send_hook_missing")
        @Expect(out.get("method").getOrThrow().asString().getValue(), "channels.send")
        @Expect(out.get("toolName").getOrThrow().asString().getValue(), "runtime_send_helper_test")
        @Expect(out.get("selfCallPrevented").getOrThrow().asBool().getValue(), true)
        @Expect(cliCalls.size, 0)
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendUsesCliFallbackOnlyOutsideRuntime(): Unit {
        let cliCalls = ArrayList<String>()
        let out = gatewayToolInvokeChannelsSend(
            "runtime_send_helper_test",
            this.samplePayload(),
            cliFallback: Some({ =>
                cliCalls.add("called")
                this.okResult("cli")
            })
        )

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), true)
        @Expect(out.get("source").getOrThrow().asString().getValue(), "cli")
        @Expect(cliCalls.size, 1)
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendReturnsUnavailableOutsideRuntimeWithoutFallback(): Unit {
        let out = gatewayToolInvokeChannelsSend("runtime_send_helper_test", this.samplePayload())

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(out.get("status").getOrThrow().asString().getValue(), "gateway_call_unavailable")
        @Expect(out.get("method").getOrThrow().asString().getValue(), "channels.send")
        @Expect(out.get("toolName").getOrThrow().asString().getValue(), "runtime_send_helper_test")
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendPreservesPayloadObject(): Unit {
        let payload = this.samplePayload()
        let captured = ArrayList<JsonObject>()
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            gatewayCallHook: Some({ _method: String, params: JsonObject =>
                captured.add(params)
                this.okResult("hook")
            })
        )

        gatewayWithToolRuntimeContext(context, { =>
            gatewayToolInvokeChannelsSend("runtime_send_helper_test", payload)
        })

        @Expect(captured.size, 1)
        @Expect(captured[0].get("channel").getOrThrow().asString().getValue(), "telegram")
        @Expect(captured[0].get("peerId").getOrThrow().asString().getValue(), "user:1")
        @Expect(captured[0].get("text").getOrThrow().asString().getValue(), "hello")
        @Expect(captured[0].get("replyToMessageId").getOrThrow().asString().getValue(), "42")
    }

    @TestCase
    public func gatewayToolInvokeChannelsSendConvertsHookExceptionToError(): Unit {
        let context = GatewayToolRuntimeContext(
            "telegram",
            channelName: "telegram",
            sessionKey: "telegram:direct:user:1",
            gatewayCallHook: Some({ _method: String, _params: JsonObject =>
                throw Exception("hook failed")
            })
        )

        let out = gatewayWithToolRuntimeContext(context, { =>
            gatewayToolInvokeChannelsSend("runtime_send_helper_test", this.samplePayload())
        })

        @Expect(out.get("ok").getOrThrow().asBool().getValue(), false)
        @Expect(out.get("status").getOrThrow().asString().getValue(), "error")
        @Expect(out.get("method").getOrThrow().asString().getValue(), "channels.send")
        @Expect(out.get("error").getOrThrow().asString().getValue().contains("hook failed"), true)
    }
}
