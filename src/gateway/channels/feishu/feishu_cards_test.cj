package metis.gateway.channels.feishu

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonBool, JsonObject, JsonString}

private class FeishuCardKitExecutorFakeOapi <: FeishuCardKitOapiClient {
    let stages = ArrayList<String>()
    let bodies = ArrayList<String>()
    let scopes = ArrayList<String>()
    var failStage = ""

    public init() {}

    public func execute(request: FeishuCardKitExecutableRequest): FeishuCardKitOapiResult {
        this.stages.add(request.stage)
        this.bodies.add(request.body.toJsonString())
        for (scope in request.requiredScopes) {
            if (!this.scopes.contains(scope)) {
                this.scopes.add(scope)
            }
        }
        if (request.stage == this.failStage) {
            return FeishuCardKitOapiResult(status: "message_unavailable", error: "message recalled")
        }
        if (request.stage == "create_entity") {
            return FeishuCardKitOapiResult(ok: true, status: "ok", cardId: "card_entity_1")
        }
        if (request.stage == "send_card_message") {
            @Expect(request.cardId, "card_entity_1")
            return FeishuCardKitOapiResult(ok: true, status: "ok", messageId: "om_card_1")
        }
        return FeishuCardKitOapiResult(ok: true, status: "ok")
    }
}

@Test
public class FeishuCardKitExecutorTest {
    private func plan(): FeishuCardKitStreamingPlan {
        FeishuCardKitStreamingPlan.build(
            accountId: "tenant-a",
            receiveId: "oc_stream",
            receiveIdType: "chat_id",
            card: FeishuInteractiveCard(title: "Metis", text: "initial answer"),
            cardId: "",
            messageId: "",
            elementId: "metis_stream_body",
            patchContent: "partial answer",
            finalCard: FeishuInteractiveCard(title: "Metis", text: "final answer"),
            abortReason: "operator stopped"
        )
    }

    @TestCase
    public func executorRunsCreateSendPatchSettingsFinalAbortAgainstFakeBoundary(): Unit {
        let fake = FeishuCardKitExecutorFakeOapi()
        let result = FeishuCardKitExecutor(fake).execute(this.plan())
        @Expect(result.status, "success")
        @Expect(result.networkAttempted, true)
        @Expect(result.cardId, "card_entity_1")
        @Expect(result.messageId, "om_card_1")
        @Expect(fake.stages.toArray(), [
            "create_entity",
            "send_card_message",
            "stream_patch",
            "settings_close",
            "final_update",
            "abort_update"
        ])
        @Expect(fake.bodies[1].contains("card_entity_1"), true)
        @Expect(fake.bodies[2].contains("partial answer"), true)
        @Expect(fake.bodies[3].contains("streaming_mode"), true)
        @Expect(fake.bodies[4].contains("final answer"), true)
        @Expect(fake.bodies[5].contains("operator stopped"), true)
        @Expect(fake.scopes.contains("cardkit:card:create"), true)
        @Expect(fake.scopes.contains("cardkit:card:update"), true)
        @Expect(fake.scopes.contains("im:message:send_as_bot"), true)
        @Expect(result.toJson().toJsonString().contains("Authorization"), false)
    }

    @TestCase
    public func executorSendsFallbackTextWhenCardMessageBecomesUnavailable(): Unit {
        let fake = FeishuCardKitExecutorFakeOapi()
        fake.failStage = "final_update"
        let result = FeishuCardKitExecutor(fake).execute(this.plan())
        @Expect(result.status, "fallback_sent")
        @Expect(result.fallbackSent, true)
        @Expect(fake.stages.toArray(), [
            "create_entity",
            "send_card_message",
            "stream_patch",
            "settings_close",
            "final_update",
            "fallback_text"
        ])
        @Expect(fake.bodies[fake.bodies.size - 1].contains("final answer"), true)
        @Expect(fake.bodies[fake.bodies.size - 1].contains("om_card_1"), true)
    }
}
