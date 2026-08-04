// Stage 3 guard tests (plan: metis-gateway-tools-feishu-tool-schema-backtick-and-duplicate-fix-plan-2026-08-04 §3).
//
// Two rules are frozen as test assets here:
//   (a) every gateway tool schema property key must match the Anthropic
//       validation pattern ^[a-zA-Z0-9_.-]{1,64}$ (including nested schemas),
//   (b) tool names must be unique across all gateway toolsets so that
//       SimpleToolManager never silently shadows one tool with another.
//
// The guard checks both the raw definition surface (18 toolsets instantiated
// directly, before ToolManager registration) and the effective runtime surface
// (gatewayDefaultChatToolNames / gatewayDefaultChatToolJsonValue, same-package
// APIs already exercised by agent_bridge_runtime_test.cj). All checks are pure
// in-memory operations: no network, no real ~/.metis configuration access.
package metis.gateway.core

import magic.core.tool.*
import metis.gateway.tools.{GatewayCanvasToolset, GatewayCronToolset, GatewayFeishuMediaToolset, GatewayFeishuOapiToolset, GatewayFSToolset, GatewayGatewayToolset, GatewayImageGenerationToolset, GatewayManagedSessionsToolset, GatewayMemoryToolset, GatewayMessageToolset, GatewayPlanToolset, GatewaySessionTranscriptToolset, GatewayShellToolset, GatewayTelegramMediaToolset, GatewayTtsToolset, GatewayVideoGenerationToolset, GatewayWeatherToolset, GatewayWebToolset}
import std.collection.{ArrayList, HashMap, HashSet}
import std.regex.Regex
import std.sort.*
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonArray, JsonObject, JsonString, JsonValue}

// ---------------------------------------------------------------------------
// ① Property-key validator: exact Anthropic rule ^[a-zA-Z0-9_.-]{1,64}$
// ---------------------------------------------------------------------------

private func isValidSchemaPropertyKey(key: String): Bool {
    Regex("^[a-zA-Z0-9_.-]{1,64}$").matches(key)
}

// ---------------------------------------------------------------------------
// ② Raw definition surface: instantiate the same 18 toolsets that
//    agent_bridge.cj:34-53 registers on GatewayP1ChatAgent.
// ---------------------------------------------------------------------------

private func guardAppendToolsetTools(out: ArrayList<(String, Tool)>, toolsetName: String, tools: Array<Tool>): Unit {
    for (tool in tools) {
        out.add((toolsetName, tool))
    }
}

private func collectAllRawTools(): ArrayList<(String, Tool)> {
    let out = ArrayList<(String, Tool)>()
    guardAppendToolsetTools(out, "GatewayFSToolset", GatewayFSToolset().tools)
    guardAppendToolsetTools(out, "GatewayMemoryToolset", GatewayMemoryToolset().tools)
    guardAppendToolsetTools(out, "GatewayWeatherToolset", GatewayWeatherToolset().tools)
    guardAppendToolsetTools(out, "GatewayWebToolset", GatewayWebToolset().tools)
    guardAppendToolsetTools(out, "GatewayShellToolset", GatewayShellToolset().tools)
    guardAppendToolsetTools(out, "GatewayPlanToolset", GatewayPlanToolset().tools)
    guardAppendToolsetTools(out, "GatewayCanvasToolset", GatewayCanvasToolset().tools)
    guardAppendToolsetTools(out, "GatewayCronToolset", GatewayCronToolset().tools)
    guardAppendToolsetTools(out, "GatewayGatewayToolset", GatewayGatewayToolset().tools)
    guardAppendToolsetTools(out, "GatewayMessageToolset", GatewayMessageToolset().tools)
    guardAppendToolsetTools(out, "GatewayTtsToolset", GatewayTtsToolset().tools)
    guardAppendToolsetTools(out, "GatewayVideoGenerationToolset", GatewayVideoGenerationToolset().tools)
    guardAppendToolsetTools(out, "GatewayImageGenerationToolset", GatewayImageGenerationToolset().tools)
    guardAppendToolsetTools(out, "GatewayTelegramMediaToolset", GatewayTelegramMediaToolset().tools)
    guardAppendToolsetTools(out, "GatewayFeishuMediaToolset", GatewayFeishuMediaToolset().tools)
    guardAppendToolsetTools(out, "GatewayFeishuOapiToolset", GatewayFeishuOapiToolset().tools)
    guardAppendToolsetTools(out, "GatewayManagedSessionsToolset", GatewayManagedSessionsToolset().tools)
    guardAppendToolsetTools(out, "GatewaySessionTranscriptToolset", GatewaySessionTranscriptToolset().tools)
    out
}

// ---------------------------------------------------------------------------
// Recursive schema walker shared by the raw-surface, effective-surface and
// self-check tests. Appends one human-readable line per problem, always
// containing the schema path and the offending value.
// ---------------------------------------------------------------------------

private func guardAsObjectOpt(value: JsonValue): Option<JsonObject> {
    try { Some(value.asObject()) } catch (_: Exception) { None<JsonObject> }
}

private func guardAsArrayOpt(value: JsonValue): Option<JsonArray> {
    try { Some(value.asArray()) } catch (_: Exception) { None<JsonArray> }
}

// Walk one JSON-schema node: validate `properties` keys, cross-check the same
// level's `required` list, then recurse into nested object/array schemas.
private func collectSchemaObjectIssues(node: JsonObject, path: String, issues: ArrayList<String>): Unit {
    let propertyKeys = HashSet<String>()
    match (node.get("properties")) {
        case Some(propsValue) =>
            match (guardAsObjectOpt(propsValue)) {
                case Some(props) =>
                    for ((key, child) in props.getFields()) {
                        propertyKeys.add(key)
                        if (!isValidSchemaPropertyKey(key)) {
                            issues.add("illegal_property_key path=${path}.properties key=<${key}>")
                        }
                        // Nested object/array schemas carry their own properties/required/items.
                        match (guardAsObjectOpt(child)) {
                            case Some(childObj) => collectSchemaObjectIssues(childObj, "${path}.properties.${key}", issues)
                            case None => ()
                        }
                    }
                case None => issues.add("properties_not_object path=${path}.properties")
            }
        case None => ()
    }
    match (node.get("required")) {
        case Some(requiredValue) =>
            match (guardAsArrayOpt(requiredValue)) {
                case Some(requiredArr) =>
                    let seen = HashSet<String>()
                    for (item in requiredArr.getItems()) {
                        var entry = ""
                        var entryIsString = true
                        try { entry = item.asString().getValue() } catch (_: Exception) { entryIsString = false }
                        if (!entryIsString) {
                            issues.add("non_string_required_entry path=${path}.required")
                            continue
                        }
                        if (!isValidSchemaPropertyKey(entry)) {
                            issues.add("illegal_required_key path=${path}.required key=<${entry}>")
                        }
                        if (!propertyKeys.contains(entry)) {
                            issues.add("dangling_required path=${path}.required key=<${entry}> not in same-level properties")
                        }
                        if (seen.contains(entry)) {
                            issues.add("duplicate_required path=${path}.required key=<${entry}>")
                        } else {
                            seen.add(entry)
                        }
                    }
                case None => issues.add("required_not_array path=${path}.required")
            }
        case None => ()
    }
    // Array schemas: recurse into the element schema.
    match (node.get("items")) {
        case Some(itemsValue) =>
            match (guardAsObjectOpt(itemsValue)) {
                case Some(itemsObj) => collectSchemaObjectIssues(itemsObj, "${path}.items", issues)
                case None => ()
            }
        case None => ()
    }
}

// Validate one serialized tool schema; `label` prefixes every reported path
// (raw surface uses "toolsetName/toolName", effective surface uses "effective/toolName").
private func collectToolSchemaIssues(label: String, schema: JsonValue, issues: ArrayList<String>): Unit {
    match (guardAsObjectOpt(schema)) {
        case Some(obj) =>
            match (obj.get("parameters")) {
                case Some(paramsValue) =>
                    match (guardAsObjectOpt(paramsValue)) {
                        case Some(params) => collectSchemaObjectIssues(params, "${label}.parameters", issues)
                        case None => issues.add("parameters_not_object path=${label}.parameters")
                    }
                case None => issues.add("missing_parameters path=${label}")
            }
        case None => issues.add("tool_schema_not_object path=${label}")
    }
}

// Join issue lines into one string so a failing @Expect prints every problem.
private func guardJoinIssues(issues: ArrayList<String>): String {
    let arr = issues.toArray()
    sort(arr)
    String.join(arr, delimiter: " ;; ")
}

// The unittest framework truncates long expected/actual values, so dump the
// full issue list to stdout before a guard assertion fails.
private func guardDumpIssues(label: String, issues: ArrayList<String>): Unit {
    if (issues.size == 0) {
        return
    }
    println("[schema-guard] ${label}: ${issues.size} problem(s)")
    let arr = issues.toArray()
    sort(arr)
    for (line in arr) {
        println("[schema-guard]   ${line}")
    }
}

// Sorted comma-joined top-level parameters.properties keys of a tool schema.
private func guardTopLevelPropertyKeysJoined(schema: JsonValue): String {
    let keys = ArrayList<String>()
    try {
        let params = schema.asObject().get("parameters").getOrThrow().asObject()
        let props = params.get("properties").getOrThrow().asObject()
        for ((key, _) in props.getFields()) {
            keys.add(key)
        }
    } catch (_: Exception) {
        return "<unreadable schema>"
    }
    let arr = keys.toArray()
    sort(arr)
    String.join(arr, delimiter: ",")
}

// Build "a...a" of the requested length for validator boundary cases.
private func guardRepeatedKey(count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += "a"
    }
    out
}

@Test
public class GatewayToolsetSchemaGuardTest {

    // ③ T3-U1: every raw tool schema property key (including nested levels)
    // must be legal, and every `required` list must be consistent with the
    // same-level `properties`.
    @TestCase
    public func rawToolSchemaPropertyKeysAreLegal(): Unit {
        let issues = ArrayList<String>()
        for ((toolsetName, tool) in collectAllRawTools()) {
            collectToolSchemaIssues("${toolsetName}/${tool.name}", tool.toJsonValue(), issues)
        }
        guardDumpIssues("rawToolSchemaPropertyKeysAreLegal", issues)
        @Expect(guardJoinIssues(issues), "")
    }

    // ④ T3-U2: tool names must be unique across all raw toolsets so no tool
    // is silently shadowed inside SimpleToolManager's name-keyed HashMap.
    @TestCase
    public func allRawToolNamesAreUniqueAcrossToolsets(): Unit {
        let owners = HashMap<String, ArrayList<String>>()
        for ((toolsetName, tool) in collectAllRawTools()) {
            if (!owners.contains(tool.name)) {
                owners.add(tool.name, ArrayList<String>())
            }
            owners[tool.name].add(toolsetName)
        }
        let duplicates = ArrayList<String>()
        for ((name, sets) in owners) {
            if (sets.size > 1) {
                let setsArr = sets.toArray()
                sort(setsArr)
                duplicates.add("duplicate_tool_name name=${name} toolsets=[${String.join(setsArr, delimiter: ", ")}]")
            }
        }
        guardDumpIssues("allRawToolNamesAreUniqueAcrossToolsets", duplicates)
        @Expect(guardJoinIssues(duplicates), "")
    }

    // ⑤ T3-U3: the guard's own raw-toolset manifest must stay in sync with the
    // real runtime inventory. If agent_bridge.cj adds/removes a toolset and
    // collectAllRawTools() is not updated (or vice versa), this fails.
    @TestCase
    public func guardManifestMatchesGatewayRuntimeInventory(): Unit {
        let rawNames = HashSet<String>()
        for ((_, tool) in collectAllRawTools()) {
            rawNames.add(tool.name)
        }
        let runtimeNames = HashSet<String>()
        for (name in gatewayDefaultChatToolNames()) {
            runtimeNames.add(name)
        }
        let problems = ArrayList<String>()
        for (name in rawNames) {
            if (!runtimeNames.contains(name)) {
                problems.add("missing_in_runtime name=${name} (raw toolset tool absent from gatewayDefaultChatToolNames)")
            }
        }
        for (name in runtimeNames) {
            if (!rawNames.contains(name)) {
                problems.add("extra_in_runtime name=${name} (runtime tool not covered by guard manifest)")
            }
        }
        guardDumpIssues("guardManifestMatchesGatewayRuntimeInventory", problems)
        @Expect(guardJoinIssues(problems), "")
    }

    // ⑥ T3-U4: the effective surface actually sent to the model (after
    // SimpleToolManager registration) must be legal, and the two Feishu tools
    // fixed by Stage 1/2 must expose exactly the expected parameter sets.
    @TestCase
    public func effectiveGatewayToolSchemasAreLegalAndStable(): Unit {
        let issues = ArrayList<String>()
        for (name in gatewayDefaultChatToolNames()) {
            match (gatewayDefaultChatToolJsonValue(name)) {
                case Some(schema) => collectToolSchemaIssues("effective/${name}", schema, issues)
                case None => issues.add("effective_schema_unreadable name=${name}")
            }
        }
        guardDumpIssues("effectiveGatewayToolSchemasAreLegalAndStable", issues)
        @Expect(guardJoinIssues(issues), "")

        // Pin the exact final parameter sets of the two tools involved in the fix.
        let fetchResource = gatewayDefaultChatToolJsonValue("feishu_im_user_fetch_resource").getOrThrow()
        @Expect(guardTopLevelPropertyKeysJoined(fetchResource), "file_key,message_id,resource_type")
        let botImage = gatewayDefaultChatToolJsonValue("feishu_im_bot_image").getOrThrow()
        @Expect(guardTopLevelPropertyKeysJoined(botImage), "account_id,action,params_json")
    }

    // ⑦ T3-B1: validator positive boundary cases.
    @TestCase
    public func schemaKeyValidatorAcceptsLegalBoundaryKeys(): Unit {
        @Expect(isValidSchemaPropertyKey(guardRepeatedKey(64)), true) // max length 64
        @Expect(isValidSchemaPropertyKey("a"), true) // min length 1
        @Expect(isValidSchemaPropertyKey("resource_type"), true)
        @Expect(isValidSchemaPropertyKey("a.b-c_d"), true) // '.', '-', '_' all legal
        @Expect(isValidSchemaPropertyKey("A9"), true)
    }

    // ⑦ T3-N1: validator negative self-check — proves the guard is not
    // vacuously true.
    @TestCase
    public func schemaKeyValidatorRejectsIllegalKeys(): Unit {
        @Expect(isValidSchemaPropertyKey("`type`"), false) // the exact P1 defect shape
        @Expect(isValidSchemaPropertyKey("类型"), false) // non-ASCII
        @Expect(isValidSchemaPropertyKey("has space"), false)
        @Expect(isValidSchemaPropertyKey(guardRepeatedKey(65)), false) // over max length
        @Expect(isValidSchemaPropertyKey(""), false) // empty
    }

    // ⑦ T3-N2: feed a hand-built nested schema containing an illegal key,
    // a dangling required entry and a duplicated required entry to the
    // recursive walker, and assert each problem is reported with its path.
    @TestCase
    public func schemaWalkerSelfCheckFindsInjectedProblems(): Unit {
        // fixture.parameters:
        //   properties:
        //     ok_key: string
        //     `type`: string                          <- illegal key at top level
        //     nested: object
        //       properties: { child_ok: string }
        //       required: [missing_child, missing_child]  <- dangling + duplicate
        //     list: array
        //       items: object
        //         properties: { "bad key": string }   <- illegal key inside items
        //   required: [ok_key, ghost, ok_key]         <- dangling + duplicate
        let stringSchema = JsonObject()
        stringSchema.put("type", JsonString("string"))

        let nestedProps = JsonObject()
        nestedProps.put("child_ok", stringSchema)
        let nestedRequired = JsonArray([])
        nestedRequired.add(JsonString("missing_child"))
        nestedRequired.add(JsonString("missing_child"))
        let nested = JsonObject()
        nested.put("type", JsonString("object"))
        nested.put("properties", nestedProps)
        nested.put("required", nestedRequired)

        let itemsProps = JsonObject()
        itemsProps.put("bad key", stringSchema)
        let itemsObj = JsonObject()
        itemsObj.put("type", JsonString("object"))
        itemsObj.put("properties", itemsProps)
        let listSchema = JsonObject()
        listSchema.put("type", JsonString("array"))
        listSchema.put("items", itemsObj)

        let props = JsonObject()
        props.put("ok_key", stringSchema)
        props.put("`type`", stringSchema)
        props.put("nested", nested)
        props.put("list", listSchema)
        let required = JsonArray([])
        required.add(JsonString("ok_key"))
        required.add(JsonString("ghost"))
        required.add(JsonString("ok_key"))
        let root = JsonObject()
        root.put("type", JsonString("object"))
        root.put("properties", props)
        root.put("required", required)

        let issues = ArrayList<String>()
        collectSchemaObjectIssues(root, "fixture.parameters", issues)
        let joined = guardJoinIssues(issues)
        // Top-level illegal key with its path.
        @Expect(joined.contains("illegal_property_key path=fixture.parameters.properties key=<`type`>"), true)
        // Nested illegal key found inside array items.
        @Expect(joined.contains("illegal_property_key path=fixture.parameters.properties.list.items.properties key=<bad key>"), true)
        // Top-level dangling and duplicated required entries.
        @Expect(joined.contains("dangling_required path=fixture.parameters.required key=<ghost>"), true)
        @Expect(joined.contains("duplicate_required path=fixture.parameters.required key=<ok_key>"), true)
        // Nested dangling and duplicated required entries with the nested path.
        @Expect(joined.contains("dangling_required path=fixture.parameters.properties.nested.required key=<missing_child>"), true)
        @Expect(joined.contains("duplicate_required path=fixture.parameters.properties.nested.required key=<missing_child>"), true)
        // Exactly the injected problems, nothing else: 2 illegal keys +
        // ghost(dangling+illegal-free) + ok_key duplicate + missing_child dangling(x2 -> 1 dangling is
        // reported per occurrence) + missing_child duplicate.
        // Occurrences: illegal `type`(1), illegal bad key(1), ghost dangling(1),
        // ok_key duplicate(1), missing_child dangling(2), missing_child duplicate(1) = 7
        @Expect(issues.size, 7)
    }
}
