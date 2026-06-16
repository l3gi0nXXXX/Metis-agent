package metis.gateway.tools

import metis.gateway.model.GatewayCkbAdminConfig

import std.collection.ArrayList
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

private func ckbAdminTestString(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

private func ckbAdminTestTokenFile(): String {
    let root = Path("/tmp/metis-ckb-admin-client-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    Directory.create(root, recursive: true)
    let path = root.join("admin-token")
    File.writeTo(path, "admin-test-token\n".toArray())
    path.toString()
}

@Test
public class GatewayCkbAdminClientTest {
    @TestCase
    public func metis3RefreshModeMapsOnlyAllowlistTasks(): Unit {
        // METIS3-UT-002, METIS3-UT-004
        let cases: Array<(String, Array<String>, Bool)> = [
            ("repo-catalog", ["community_repo_discovery_30d"], false),
            ("docs", ["docs_probe_30d"], false),
            ("website-probe", ["website_probe_weekly"], false),
            ("website-full", ["website_full_weekly"], false),
            ("web-candidates", ["web_candidate_weekly"], false),
            ("web-candidates-recrawl", ["web_candidate_recrawl_30d"], false),
            ("rebuild", ["weekly_full_rebuild"], false),
            ("both", ["community_repo_discovery_30d", "docs_probe_30d"], false),
            ("status", [], true)
        ]
        for ((mode, tasks, statusOnly) in cases) {
            let mapped = gatewayCkbRefreshModeToTaskNames(mode)
            @Expect(mapped.ok, true)
            @Expect(mapped.taskNames, tasks)
            @Expect(mapped.statusOnly, statusOnly)
        }
        for (mode in ["active-item", "active-repo", "repo-list", "active_item_sync_on_merge", "active_repo_fetch_on_merge", "repo_list_refresh_on_merge", "weekly_full_rebuild"]) {
            let mapped = gatewayCkbRefreshModeToTaskNames(mode)
            @Expect(mapped.ok, false)
            @Expect(mapped.taskNames.isEmpty(), true)
            @Expect(mapped.statusOnly, false)
        }
    }

    @TestCase
    public func metis3RunSchedulerUsesAdminPathTaskNamesAndForce(): Unit {
        // METIS3-UT-003
        let tokenFile = ckbAdminTestTokenFile()
        let requests = ArrayList<GatewayCkbAdminHttpRequest>()
        setGatewayCkbAdminHttpRunnerForTest(Some({ request: GatewayCkbAdminHttpRequest =>
            requests.add(request)
            let result = JsonObject()
            result.put("status", JsonString("succeeded"))
            result.put("taskNames", JsonArray([JsonString("community_repo_discovery_30d")]))
            result.put("ran", JsonInt(1))
            result.put("succeeded", JsonInt(1))
            result.put("repoCount", JsonInt(42))
            result.put("knowledgeVersion", JsonString("ckb-v1"))
            let envelope = JsonObject()
            envelope.put("ok", JsonBool(true))
            envelope.put("data", result)
            GatewayCkbAdminHttpResponse(200, body: envelope.toJsonString())
        }))
        try {
            let cfg = GatewayCkbAdminConfig(
                enabled: true,
                endpoint: "http://127.0.0.1:18890",
                adminTokenFile: tokenFile
            )
            let result = gatewayCkbAdminRunSchedulerTasks(cfg, ["community_repo_discovery_30d"], "telegram_native_command", "tg:sender:abc")
            @Expect(result.ok, true)
            @Expect(requests.size, 1)
            @Expect(requests[0].method, "POST")
            @Expect(requests[0].path, "/v1/admin/scheduler/run")
            @Expect(requests[0].url, "http://127.0.0.1:18890/v1/admin/scheduler/run")
            @Expect(requests[0].authorizationHeader.contains("admin-test-token"), true)
            let body = JsonValue.fromStr(requests[0].body).asObject()
            @Expect(body.get("force").getOrThrow().asBool().getValue(), true)
            @Expect(body.get("source").getOrThrow().asString().getValue(), "telegram_native_command")
            @Expect(body.get("requestedBy").getOrThrow().asString().getValue(), "tg:sender:abc")
            let taskNames = body.get("taskNames").getOrThrow().asArray()
            @Expect(taskNames.size(), 1)
            @Expect(taskNames[0].asString().getValue(), "community_repo_discovery_30d")
        } finally {
            setGatewayCkbAdminHttpRunnerForTest(None<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse>)
            try { remove(Path(tokenFile).parent, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func metis3BoundariesDoNotCallHttpForDisabledUnknownOrForbiddenTargets(): Unit {
        // METIS3-BND-001, METIS3-BND-002, METIS3-BND-003
        let tokenFile = ckbAdminTestTokenFile()
        let requests = ArrayList<GatewayCkbAdminHttpRequest>()
        setGatewayCkbAdminHttpRunnerForTest(Some({ request: GatewayCkbAdminHttpRequest =>
            requests.add(request)
            GatewayCkbAdminHttpResponse(500, body: "{\"ok\":false}")
        }))
        try {
            let disabled = gatewayCkbAdminRunSchedulerTasks(GatewayCkbAdminConfig(), ["community_repo_discovery_30d"], "telegram_native_command", "tg")
            @Expect(disabled.ok, false)
            @Expect(gatewayRenderCkbAdminCommandResult(disabled).contains("disabled"), true)

            let cfg = GatewayCkbAdminConfig(enabled: true, endpoint: "http://127.0.0.1:18890", adminTokenFile: tokenFile)
            let unknown = gatewayCkbAdminCommand(cfg, "/ckb-refresh", "telegram_native_command", "tg")
            @Expect(unknown.ok, false)
            @Expect(gatewayRenderCkbAdminCommandResult(unknown).contains("Usage: /ckb-refresh"), true)
            let forbidden = gatewayCkbAdminCommand(cfg, "/ckb-refresh active-repo Cangjie/cangjie_tools", "telegram_native_command", "tg")
            @Expect(forbidden.ok, false)
            @Expect(gatewayRenderCkbAdminCommandResult(forbidden).contains("unsupported"), true)
            @Expect(requests.size, 0)
        } finally {
            setGatewayCkbAdminHttpRunnerForTest(None<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse>)
            try { remove(Path(tokenFile).parent, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func metis3StatusUsesReadOnlyStatusPathsAndRendererIsHumanReadable(): Unit {
        // METIS3-POS-003, METIS3-NEG-003
        let tokenFile = ckbAdminTestTokenFile()
        let requests = ArrayList<GatewayCkbAdminHttpRequest>()
        setGatewayCkbAdminHttpRunnerForTest(Some({ request: GatewayCkbAdminHttpRequest =>
            requests.add(request)
            if (request.path == "/v1/status") {
                let result = JsonObject()
                result.put("repoCatalogVersion", JsonString("repo-v1"))
                result.put("repoCount", JsonInt(88))
                let envelope = JsonObject()
                envelope.put("ok", JsonBool(true))
                envelope.put("data", result)
                return GatewayCkbAdminHttpResponse(200, body: envelope.toJsonString())
            }
            if (request.path == "/v1/schedules") {
                let docs = JsonObject()
                docs.put("name", JsonString("docs_probe_30d"))
                docs.put("lastSuccessAt", JsonString("2026-06-16T01:00:00Z"))
                let repos = JsonObject()
                repos.put("name", JsonString("community_repo_discovery_30d"))
                repos.put("lastSuccessAt", JsonString("2026-06-16T02:00:00Z"))
                let entries = JsonArray([])
                entries.add(docs)
                entries.add(repos)
                let schedules = JsonObject()
                schedules.put("entries", entries)
                let envelope = JsonObject()
                envelope.put("ok", JsonBool(true))
                envelope.put("data", schedules)
                return GatewayCkbAdminHttpResponse(200, body: envelope.toJsonString())
            }
            GatewayCkbAdminHttpResponse(500, body: "{\"ok\":false}")
        }))
        try {
            let cfg = GatewayCkbAdminConfig(enabled: true, endpoint: "http://localhost:18890", adminTokenFile: tokenFile)
            let status = gatewayCkbAdminStatus(cfg)
            let rendered = gatewayRenderCkbAdminCommandResult(status)
            @Expect(status.ok, true)
            @Expect(requests.size, 2)
            @Expect(requests[0].path, "/v1/status")
            @Expect(requests[1].path, "/v1/schedules")
            @Expect(rendered.contains("repoCatalogVersion: repo-v1"), true)
            @Expect(rendered.contains("repoCount: 88"), true)
            @Expect(rendered.contains("docs_probe_30d.lastSuccessAt: 2026-06-16T01:00:00Z"), true)
            @Expect(rendered.contains("community_repo_discovery_30d.lastSuccessAt: 2026-06-16T02:00:00Z"), true)
            @Expect(rendered.contains("\"ok\""), false)
            @Expect(rendered.contains("Authorization"), false)
            @Expect(rendered.contains("admin-test-token"), false)

            setGatewayCkbAdminHttpRunnerForTest(Some({ _request: GatewayCkbAdminHttpRequest =>
                GatewayCkbAdminHttpResponse(401, body: "{\"ok\":false,\"error\":{\"message\":\"Authorization: Bearer secret\"}}")
            }))
            let unauthorized = gatewayRenderCkbAdminCommandResult(gatewayCkbAdminStatus(cfg))
            @Expect(unauthorized.contains("401"), true)
            @Expect(unauthorized.contains("Bearer secret"), false)
            @Expect(unauthorized.contains("\"ok\""), false)
        } finally {
            setGatewayCkbAdminHttpRunnerForTest(None<(GatewayCkbAdminHttpRequest) -> GatewayCkbAdminHttpResponse>)
            try { remove(Path(tokenFile).parent, recursive: true) } catch (_: Exception) { () }
        }
    }
}
