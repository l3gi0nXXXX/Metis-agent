package metis.gateway.tools

import std.unittest.testmacro.*

private func expectFeishuOapiScopes(actionKey: String, expected: Array<String>): Unit {
    let actual = feishuOapiRequiredScopesForActionKeyForTest(actionKey)
    @Expect(actual.size, expected.size)
    for (i in 0..expected.size) {
        @Expect(actual[i], expected[i])
    }
}

@Test
public class GatewayFeishuOapiScopeExactTest {
    @TestCase
    public func partialOpenClawActionsUseExactRequiredScopes(): Unit {
        expectFeishuOapiScopes("feishu_bitable_app.copy", ["base:app:copy"])
        expectFeishuOapiScopes("feishu_bitable_app_table.batch_create", ["base:table:create"])
        expectFeishuOapiScopes("feishu_bitable_app_table.create", ["base:table:create"])
        expectFeishuOapiScopes("feishu_bitable_app_table.list", ["base:table:read"])
        expectFeishuOapiScopes("feishu_bitable_app_table.patch", ["base:table:update"])
        expectFeishuOapiScopes("feishu_bitable_app_table_record.batch_create", ["base:record:create"])
        expectFeishuOapiScopes("feishu_bitable_app_table_record.batch_update", ["base:record:update"])
        expectFeishuOapiScopes("feishu_bitable_app_table_record.create", ["base:record:create"])
        expectFeishuOapiScopes("feishu_bitable_app_table_record.list", ["base:record:retrieve"])
        expectFeishuOapiScopes("feishu_bitable_app_table_record.update", ["base:record:update"])
        expectFeishuOapiScopes("feishu_bitable_app_table_view.create", ["base:view:write_only"])
        expectFeishuOapiScopes("feishu_bitable_app_table_view.get", ["base:view:read"])
        expectFeishuOapiScopes("feishu_bitable_app_table_view.list", ["base:view:read"])
        expectFeishuOapiScopes("feishu_bitable_app_table_view.patch", ["base:view:write_only"])
        expectFeishuOapiScopes("feishu_calendar_event_attendee.create", ["calendar:calendar.event:update"])
        expectFeishuOapiScopes("feishu_calendar_event_attendee.list", ["calendar:calendar.event:read"])
        expectFeishuOapiScopes("feishu_task_attachment.upload", ["task:attachment:write"])
        expectFeishuOapiScopes("feishu_task_comment.create", ["task:comment:write"])
        expectFeishuOapiScopes("feishu_task_comment.get", ["task:comment:read", "task:comment:write"])
        expectFeishuOapiScopes("feishu_task_comment.list", ["task:comment:read", "task:comment:write"])
        expectFeishuOapiScopes("feishu_task_section.create", ["task:task"])
        expectFeishuOapiScopes("feishu_task_section.get", ["task:task"])
        expectFeishuOapiScopes("feishu_task_section.list", ["task:task"])
        expectFeishuOapiScopes("feishu_task_section.patch", ["task:task"])
        expectFeishuOapiScopes("feishu_task_section.tasks", ["task:task"])
        expectFeishuOapiScopes("feishu_task_task.create", ["task:task:write", "task:task:writeonly"])
        expectFeishuOapiScopes("feishu_task_task.patch", ["task:task:write", "task:task:writeonly"])
        expectFeishuOapiScopes("feishu_task_task.add_members", ["task:task:write", "task:task:writeonly"])
        expectFeishuOapiScopes("feishu_task_task.append_steps", ["task:task:write", "task:task:writeonly"])
        expectFeishuOapiScopes("feishu_task_tasklist.add_members", ["task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_tasklist.create", ["task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_tasklist.get", ["task:tasklist:read", "task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_tasklist.list", ["task:tasklist:read", "task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_tasklist.patch", ["task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_tasklist.tasks", ["task:tasklist:read", "task:tasklist:write"])
        expectFeishuOapiScopes("feishu_task_agent.update_profile", ["task:task:write", "task:task:writeonly"])
    }
}
