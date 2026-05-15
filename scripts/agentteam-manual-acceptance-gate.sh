#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

if [[ "${METIS_AGENTTEAM_SKIP_ENVSETUP:-0}" != "1" && -f /Users/l3gi0n/cangjie100/envsetup.sh ]]; then
  set +u
  source /Users/l3gi0n/cangjie100/envsetup.sh
  set -u
fi

fail() {
  echo "[agentteam-gate] ERROR: $*" >&2
  exit 1
}

info() {
  echo "[agentteam-gate] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

redacted_flag() {
  if [[ -n "${1:-}" ]]; then
    printf "provided-redacted"
  else
    printf "not-provided"
  fi
}

resource_status() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    printf "provided-redacted"
  else
    printf "missing"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

agentteam_acceptance_json() {
  cat <<'JSON'
{
  "source": "develop_steps/metis-agent-team-series-19-feishu-openclaw-source-recheck-gap-quantification-manual-acceptance-2026-05-16.md",
  "scope": "phase0-9-gap-index",
  "statuses": {
    "localPass": "local-pass",
    "externalResourceRequired": "external-resource-required",
    "operatorRecordRequired": "operator-record-required"
  },
  "phases": [
    {
      "id": "phase0",
      "title": "Freeze source-backed GAP matrix",
      "status": "local-pass",
      "gaps": ["G01", "G02", "G03", "G04", "G05", "G06", "G07", "G08", "G09", "G10", "G24", "G25"],
      "checklist": [
        {"id": "M01", "status": "local-pass", "evidence": "isolated METIS_HOME and redacted report directory were enforced"},
        {"id": "M28", "status": "local-pass", "evidence": "report.json and manual-acceptance-template.md were generated"}
      ],
      "evidence": [
        {"id": "series14-source-doc", "status": "local-pass", "path": "develop_steps/metis-agent-team-series-14-current-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md"},
        {"id": "oapi-parity-report", "status": "local-pass", "path": "develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md"}
      ]
    },
    {
      "id": "phase1",
      "title": "Management entry points and operation paths",
      "status": "local-pass",
      "gaps": ["G08", "G09", "G23", "G24"],
      "checklist": [
        {"id": "M03", "status": "local-pass", "evidence": "CLI team create is mapped to agents.teams.create"},
        {"id": "M04", "status": "local-pass", "evidence": "CLI team list/get support --json Gateway RPC output"},
        {"id": "M05", "status": "local-pass", "evidence": "CLI team update/delete are mapped to Gateway RPC"},
        {"id": "M06", "status": "local-pass", "evidence": "team create returns generated member agents in Gateway RPC"}
      ],
      "evidence": [
        {"id": "cli-help-boundary", "status": "local-pass", "path": "src/program/cli_local_flows.cj"},
        {"id": "team-rpc-methods", "status": "local-pass", "path": "src/gateway/runtime/gateway_server_methods_agents.cj"}
      ]
    },
    {
      "id": "phase2",
      "title": "Agent isolation acceptance",
      "status": "local-pass",
      "gaps": ["G02", "G03", "G04", "G05", "G09", "G25"],
      "checklist": [
        {"id": "M06", "status": "local-pass", "evidence": "team create auto-creates member agent workspace/agentDir/sessionsDir"},
        {"id": "M07", "status": "local-pass", "evidence": "profile file reads and writes are scoped to the selected agent workspace"},
        {"id": "M08", "status": "local-pass", "evidence": "per-agent models.json paths and model refs remain separate"},
        {"id": "M09", "status": "local-pass", "evidence": "agent auth-profiles are not copied or read across agents unless explicitly requested"},
        {"id": "M27", "status": "local-pass", "evidence": "local evidence is redaction-scanned before the gate exits"}
      ],
      "evidence": [
        {"id": "profile-isolation-test", "status": "local-pass", "path": "src/gateway/runtime/gateway_server_methods_agents_test.cj"},
        {"id": "model-auth-isolation-test", "status": "local-pass", "path": "src/gateway/runtime/gateway_server_methods_agents_test.cj"}
      ]
    },
    {
      "id": "phase3",
      "title": "binding/accountId/teamId route acceptance",
      "status": "local-pass",
      "gaps": ["G07", "G10", "G12", "G22"],
      "checklist": [
        {"id": "M10", "status": "local-pass", "evidence": "local conflict tests reject duplicate routes without partial team writes"},
        {"id": "M14", "status": "external-resource-required", "evidence": "real multi-account Feishu bot validation needs operator resources"}
      ],
      "evidence": [
        {"id": "route-resolver-tests", "status": "local-pass", "path": "src/gateway/runtime/gateway_server_methods_agents_test.cj"}
      ]
    },
    {
      "id": "phase4",
      "title": "Telegram live route acceptance",
      "status": "external-resource-required",
      "gaps": ["G11"],
      "checklist": [
        {"id": "M11", "status": "external-resource-required", "evidence": "requires real test bot and private chat"},
        {"id": "M12", "status": "external-resource-required", "evidence": "requires real test group/topic"},
        {"id": "M13", "status": "external-resource-required", "evidence": "requires real message delivery and aggregate reply evidence"}
      ],
      "evidence": []
    },
    {
      "id": "phase5",
      "title": "Feishu account/routing/threadSession live acceptance",
      "status": "external-resource-required",
      "gaps": ["G12", "G13", "G22"],
      "checklist": [
        {"id": "M14", "status": "external-resource-required", "evidence": "requires two test Feishu accounts/bots"},
        {"id": "M15", "status": "external-resource-required", "evidence": "requires real Feishu group mention and allowlist checks"},
        {"id": "M16", "status": "external-resource-required", "evidence": "requires real Feishu thread/topic checks"}
      ],
      "evidence": []
    },
    {
      "id": "phase6",
      "title": "Feishu OAuth/UAT/TAT live acceptance",
      "status": "external-resource-required",
      "gaps": ["G14", "G15", "G17"],
      "checklist": [
        {"id": "M17", "status": "external-resource-required", "evidence": "requires test app credentials, offline_access, and user authorization"}
      ],
      "evidence": []
    },
    {
      "id": "phase7",
      "title": "Feishu OAPI parity live acceptance",
      "status": "external-resource-required",
      "gaps": ["G16", "G17"],
      "checklist": [
        {"id": "M18", "status": "external-resource-required", "evidence": "requires low-risk test doc/wiki/calendar/task/bitable/sheet/im resources"},
        {"id": "M19", "status": "external-resource-required", "evidence": "requires writeable test-only Feishu resources"}
      ],
      "evidence": []
    },
    {
      "id": "phase8",
      "title": "Feishu CardKit and rich events live acceptance",
      "status": "external-resource-required",
      "gaps": ["G18", "G19", "G20"],
      "checklist": [
        {"id": "M20", "status": "external-resource-required", "evidence": "requires real CardKit-capable test chat"},
        {"id": "M21", "status": "external-resource-required", "evidence": "requires test media/file resources"},
        {"id": "M22", "status": "external-resource-required", "evidence": "requires reaction, quote, and merged-forward test events"}
      ],
      "evidence": []
    },
    {
      "id": "phase9",
      "title": "Control UI product acceptance",
      "status": "operator-record-required",
      "gaps": ["G23", "G24"],
      "checklist": [
        {"id": "M23", "status": "operator-record-required", "evidence": "set METIS_AGENTTEAM_CONTROL_UI_URL to run browser smoke"},
        {"id": "M24", "status": "operator-record-required", "evidence": "requires local Gateway/Control UI runtime"},
        {"id": "M25", "status": "operator-record-required", "evidence": "requires local Gateway/Control UI runtime"},
        {"id": "M26", "status": "operator-record-required", "evidence": "requires local Gateway/Control UI runtime"}
      ],
      "evidence": []
    }
  ],
  "gaps": [
    {"id": "G01", "status": "local-pass", "phase": "phase0", "title": "multi-agent config/default agent"},
    {"id": "G02", "status": "local-pass", "phase": "phase2", "title": "per-agent workspace and agentDir isolation"},
    {"id": "G03", "status": "local-pass", "phase": "phase2", "title": "profile files"},
    {"id": "G04", "status": "local-pass", "phase": "phase2", "title": "per-agent model"},
    {"id": "G05", "status": "local-pass", "phase": "phase2", "title": "per-agent auth profile and credential source"},
    {"id": "G06", "status": "local-pass", "phase": "phase0", "title": "skill/tool filtering"},
    {"id": "G07", "status": "local-pass", "phase": "phase3", "title": "binding match dimensions"},
    {"id": "G08", "status": "local-pass", "phase": "phase1", "title": "CLI/UI/Gateway RPC management surface"},
    {"id": "G09", "status": "local-pass", "phase": "phase1", "title": "team CRUD auto-creates member agents"},
    {"id": "G10", "status": "local-pass", "phase": "phase3", "title": "team broadcast/fan-out local plan"},
    {"id": "G11", "status": "external-resource-required", "phase": "phase4", "title": "Telegram live route and broadcast"},
    {"id": "G12", "status": "external-resource-required", "phase": "phase5", "title": "Feishu multi-account live route"},
    {"id": "G13", "status": "external-resource-required", "phase": "phase5", "title": "Feishu inbound group/thread policy live route"},
    {"id": "G14", "status": "external-resource-required", "phase": "phase6", "title": "Feishu OAuth/UAT live authorization"},
    {"id": "G15", "status": "external-resource-required", "phase": "phase6", "title": "Feishu TAT/app-token live validation"},
    {"id": "G16", "status": "external-resource-required", "phase": "phase7", "title": "Feishu OAPI live tool matrix"},
    {"id": "G17", "status": "external-resource-required", "phase": "phase7", "title": "Feishu scope diagnostics and repair live validation"},
    {"id": "G18", "status": "external-resource-required", "phase": "phase8", "title": "Feishu CardKit streaming live validation"},
    {"id": "G19", "status": "external-resource-required", "phase": "phase8", "title": "Feishu rich event/resource live validation"},
    {"id": "G20", "status": "external-resource-required", "phase": "phase8", "title": "Feishu native start/doctor/auth command parity"},
    {"id": "G21", "status": "external-resource-required", "phase": "phase8", "title": "automatic Feishu bot/app creation platform boundary"},
    {"id": "G22", "status": "external-resource-required", "phase": "phase5", "title": "multi-bot mapping to agent/team live validation"},
    {"id": "G23", "status": "operator-record-required", "phase": "phase9", "title": "Miaoda-like Control UI product experience"},
    {"id": "G24", "status": "local-pass", "phase": "phase0", "title": "manual acceptance and evidence pack"},
    {"id": "G25", "status": "local-pass", "phase": "phase2", "title": "security and redaction"}
  ]
}
JSON
}

write_evidence_pack() {
  local report_dir="$1"
  local report_json="$report_dir/report.json"
  local template_md="$report_dir/manual-acceptance-template.md"
  local created_at
  local head
  local telegram_status
  local telegram_reason
  local telegram_check_status
  local telegram_check_reason
  local telegram_opt_in
  local feishu_status
  local control_ui_status

  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  head="$(git rev-parse HEAD)"
  telegram_status="skipped"
  telegram_reason="opt-in-disabled"
  telegram_check_status="skipped"
  telegram_check_reason="opt-in-disabled"
  telegram_opt_in="false"
  feishu_status="skipped"
  control_ui_status="skipped"
  if [[ "${METIS_AGENTTEAM_LIVE_TELEGRAM:-0}" == "1" ]]; then
    telegram_opt_in="true"
    if [[ -z "${METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID:-}" || -z "${METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID:-}" ]]; then
      telegram_status="skipped"
      telegram_reason="external-resource-required"
      telegram_check_status="skipped"
      telegram_check_reason="external-resource-required"
    else
      telegram_status="manual-opt-in-record-required"
      telegram_reason="operator-record-required"
      telegram_check_status="manual-opt-in-record-required"
      telegram_check_reason="operator-record-required"
    fi
  fi
  if [[ "${METIS_AGENTTEAM_LIVE_FEISHU:-0}" == "1" ]]; then
    feishu_status="manual-opt-in-record-required"
  fi
  if [[ -n "${METIS_AGENTTEAM_CONTROL_UI_URL:-}" ]]; then
    control_ui_status="enabled"
  fi

  {
    cat <<JSON
{
  "kind": "metis-agentteam-manual-acceptance-evidence",
  "series": "19",
  "phases": "0-9",
  "createdAt": "$created_at",
  "gitHead": "$head",
  "metisHome": "$(json_escape "$METIS_HOME_CANONICAL")",
  "reportDir": "$(json_escape "$report_dir")",
  "acceptance":
JSON
    agentteam_acceptance_json
    cat <<JSON
  ,
  "controlUi": {
    "status": "$control_ui_status",
    "url": "$(redacted_flag "${METIS_AGENTTEAM_CONTROL_UI_URL:-}")"
  },
  "liveGates": {
    "telegram": {
      "status": "$telegram_status",
      "reason": "$telegram_reason",
      "optIn": $telegram_opt_in,
      "accountId": "$(redacted_flag "${METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID:-}")",
      "chatOrTopic": "$(redacted_flag "${METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID:-}")",
      "requiredResources": [
        {
          "name": "METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID",
          "status": "$(resource_status METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID)"
        },
        {
          "name": "METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID",
          "status": "$(resource_status METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID)"
        }
      ],
      "manualChecks": [
        {
          "id": "account-route",
          "status": "$telegram_check_status",
          "reason": "$telegram_check_reason"
        },
        {
          "id": "group-topic-session-isolation",
          "status": "$telegram_check_status",
          "reason": "$telegram_check_reason"
        },
        {
          "id": "alias-route",
          "status": "$telegram_check_status",
          "reason": "$telegram_check_reason"
        },
        {
          "id": "broadcast-aggregate",
          "status": "$telegram_check_status",
          "reason": "$telegram_check_reason"
        }
      ]
    },
    "feishu": {
      "status": "$feishu_status",
      "accountId": "$(redacted_flag "${METIS_AGENTTEAM_FEISHU_ACCOUNT_ID:-}")",
      "tenant": "$(redacted_flag "${METIS_AGENTTEAM_FEISHU_TENANT_ID:-}")",
      "chatOrThread": "$(redacted_flag "${METIS_AGENTTEAM_FEISHU_CHAT_ID:-}")"
    }
  },
  "redaction": {
    "storesRealMetisHome": false,
    "containsTelegramBotToken": false,
    "containsFeishuAppSecret": false,
    "containsAccessToken": false,
    "containsRefreshToken": false,
    "containsAuthorizationHeader": false
  }
}
JSON
  } >"$report_json"

  cat >"$template_md" <<MD
# Metis AgentTeam Manual Acceptance Evidence

- Date: $created_at
- Git head: $head
- METIS_HOME: $METIS_HOME_CANONICAL
- Report dir: $report_dir
- Operator: TODO
- Gateway URL: TODO redacted or local-only
- Control UI URL: ${control_ui_status}

## Phase 0 Evidence Freeze

| Check | Result | Evidence |
| --- | --- | --- |
| Series 19 source-backed GAP matrix is current | local-pass | See report.json acceptance.source |
| Series 14 OAPI parity is 108 aligned / 0 partial / 0 missing / 0 not-applicable | TODO pass/fail | TODO |
| Live Telegram/Feishu gates are opt-in only | TODO pass/fail | See report.json liveGates |

## Phase 0-9 Structured Acceptance Index

| Phase | Gate status | GAPs | Evidence |
| --- | --- | --- | --- |
| phase0 | local-pass | G01 G02 G03 G04 G05 G06 G07 G08 G09 G10 G24 G25 | Source-backed docs and redacted evidence pack checks |
| phase1 | local-pass | G08 G09 G23 G24 | CLI/UI/Gateway RPC management boundary |
| phase2 | local-pass | G02 G03 G04 G05 G09 G25 | Local agent isolation tests and redaction checks |
| phase3 | local-pass | G07 G10 G12 G22 | Local binding/account route checks; live multi-account remains external |
| phase4 | external-resource-required | G11 | Real Telegram bot/group/topic required |
| phase5 | external-resource-required | G12 G13 G22 | Real Feishu accounts/bots/groups/topics required |
| phase6 | external-resource-required | G14 G15 G17 | Real Feishu app credentials and OAuth user required |
| phase7 | external-resource-required | G16 G17 | Real Feishu OAPI test resources required |
| phase8 | external-resource-required | G18 G19 G20 G21 | Real CardKit/rich event resources and platform permission confirmation required |
| phase9 | operator-record-required | G23 G24 | Local Control UI/Gateway runtime smoke record required |

## GAP Acceptance State Index

| GAP | Gate status | Evidence |
| --- | --- | --- |
| G01 | local-pass | Multi-agent/default source-backed matrix row |
| G02 | local-pass | Workspace/agentDir/sessionsDir isolation tests |
| G03 | local-pass | Profile file scoped read/write tests |
| G04 | local-pass | Per-agent models.json tests |
| G05 | local-pass | Per-agent auth profile source tests |
| G06 | local-pass | Skill/tool filter source-backed row |
| G07 | local-pass | Binding route resolver tests |
| G08 | local-pass | CLI/UI/Gateway RPC management boundary |
| G09 | local-pass | Team create auto-creates member agents |
| G10 | local-pass | Local broadcast plan/aggregate tests |
| G11 | external-resource-required | Telegram live route/broadcast requires test bot/group/topic |
| G12 | external-resource-required | Feishu multi-account route requires real accounts |
| G13 | external-resource-required | Feishu group/thread policy requires real group/thread |
| G14 | external-resource-required | Feishu OAuth/UAT requires real app/user authorization |
| G15 | external-resource-required | Feishu TAT/app token requires real app credentials |
| G16 | external-resource-required | Feishu OAPI parity requires real test resources |
| G17 | external-resource-required | Feishu scope diagnostic requires real missing-scope scenario |
| G18 | external-resource-required | Feishu CardKit streaming requires real CardKit chat |
| G19 | external-resource-required | Feishu rich events/resources require real media/events |
| G20 | external-resource-required | Feishu native command parity requires real IM command smoke |
| G21 | external-resource-required | Automatic Feishu bot/app creation needs platform permission confirmation |
| G22 | external-resource-required | Multi-bot team mapping needs real accounts |
| G23 | operator-record-required | Control UI product acceptance needs local browser smoke record |
| G24 | local-pass | This gate emits redacted evidence pack and checklist |
| G25 | local-pass | Secret-pattern scan and redaction flags |

## Phase 1 Redacted Live Resource Pack

| Resource | Result | Redacted Evidence |
| --- | --- | --- |
| Isolated METIS_HOME | TODO pass/fail | $METIS_HOME_CANONICAL |
| Telegram test bot/account | TODO skipped/pass/fail | redacted id only |
| Telegram test group/topic | TODO skipped/pass/fail | redacted id only |
| Feishu test app/account | TODO skipped/pass/fail | redacted id only |
| Feishu tenant/user/group/thread | TODO skipped/pass/fail | redacted id only |
| Provider key for per-agent model smoke | TODO skipped/pass/fail | source summary only |

## Phase 1 Core AgentTeam CLI/RPC Acceptance

| Check | Result | Evidence |
| --- | --- | --- |
| CLI team create/list/get/update/delete | TODO pass/fail | TODO |
| CLI custom members and aliases | TODO pass/fail | TODO |
| RPC agents.teams create/list/get/update/delete | TODO pass/fail | TODO |
| Profile files list/get/set including BOOTSTRAP.md creation | TODO pass/fail | TODO |
| Per-agent models and credential source redaction | TODO pass/fail | TODO |
| Binding conflict rejects same route/different agent without partial write | TODO pass/fail | TODO |
| Broadcast aggregate includes per-agent status/detail/answer/sessionKey | TODO pass/fail | TODO |

## Phase 2 Agent Isolation Acceptance

| GAP | Gate status | Acceptance item | Evidence |
| --- | --- | --- | --- |
| G02 | local-pass | member workspace/agentDir/sessionsDir are distinct | GatewayServerMethodsAgentsTest.agentRuntimeScopeKeepsPerAgentModelAuthWorkspaceAndSessionPathsSeparate |
| G03 | local-pass | profile file reads/writes are scoped to the selected agent | GatewayServerMethodsAgentsTest.agentFilesRpcUsesWorkspaceSafeBootstrapFiles |
| G04 | local-pass | agent A/B model state does not cross-write | GatewayServerMethodsAgentsTest.agentAAgentBModelsRpcKeepsModelsJsonPathAndModelRefSeparate |
| G05 | local-pass | auth profile source does not cross-read main or sibling credentials | GatewayServerMethodsAgentsTest.agentBWithoutExplicitAuthCopyDoesNotReadAgentAOrMainCredentialsAndRedactsOutput |
| G09 | local-pass | team create auto-creates member agents and delete preserves agent dirs | GatewayServerMethodsAgentsTest.agentTeamsCreateUpdateListAndDeleteRoundTripConfig |
| G25 | local-pass | evidence pack is redaction-scanned | scripts/agentteam-manual-acceptance-gate.sh |

## Phase 3 Telegram Live Route Gate

| Check | Gate Result | Evidence |
| --- | --- | --- |
| Account route | $telegram_check_status | $telegram_check_reason; redacted account only |
| Group/topic session isolation | $telegram_check_status | $telegram_check_reason; redacted chat/topic only |
| Alias route | $telegram_check_status | $telegram_check_reason; @writer or /agent writer manual smoke |
| Broadcast aggregate | $telegram_check_status | $telegram_check_reason; aggregate rows must include agentId/status/sessionKey |

## Redaction Checklist

- No real ~/.metis path was used.
- No Telegram bot token was recorded.
- No Feishu app secret was recorded.
- No access or refresh token was recorded.
- No auth header was recorded.
- No proxy credentials or provider keys were recorded.
MD

  if rg -n -i 'bot[ _-]?token[=:][^ ]+|app[ _-]?secret[=:][^ ]+|access[ _-]?token[=:][^ ]+|refresh[ _-]?token[=:][^ ]+|authorization:[[:space:]]*bearer[[:space:]]+[^ ]+|sk-[A-Za-z0-9_-]{16,}' "$report_dir" >/tmp/metis-agentteam-gate-redaction.txt; then
    cat /tmp/metis-agentteam-gate-redaction.txt >&2
    rm -f /tmp/metis-agentteam-gate-redaction.txt
    fail "redaction scan found secret-like evidence in $report_dir"
  fi
  rm -f /tmp/metis-agentteam-gate-redaction.txt
}

require_command git
require_command rg

PARITY_REPORT="develop_steps/metis-agent-team-series-14-oapi-action-parity-report-2026-05-15.md"
SERIES14_DOC="develop_steps/metis-agent-team-series-14-current-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md"

METIS_HOME_VALUE="${METIS_HOME:-}"
[[ -n "$METIS_HOME_VALUE" ]] || fail "set METIS_HOME to an isolated test directory, for example /tmp/metis-agentteam-manual-acceptance"

REAL_HOME="$(cd "$HOME" && pwd -P)/.metis"
METIS_HOME_CANONICAL="$(mkdir -p "$METIS_HOME_VALUE" && cd "$METIS_HOME_VALUE" && pwd -P)"
if [[ "$METIS_HOME_CANONICAL" == "$REAL_HOME" ]]; then
  fail "METIS_HOME points at the real home ($REAL_HOME). Use an isolated test home."
fi
info "METIS_HOME=$METIS_HOME_CANONICAL"

REPORT_DIR_VALUE="${METIS_AGENTTEAM_REPORT_DIR:-$METIS_HOME_CANONICAL/agentteam-manual-acceptance-report}"
mkdir -p "$REPORT_DIR_VALUE"
REPORT_DIR_CANONICAL="$(cd "$REPORT_DIR_VALUE" && pwd -P)"
if [[ "$REPORT_DIR_CANONICAL" == "$REAL_HOME"* ]]; then
  fail "report dir points inside the real home ($REAL_HOME). Use METIS_AGENTTEAM_REPORT_DIR outside the real home."
fi
write_evidence_pack "$REPORT_DIR_CANONICAL"
info "redacted evidence pack written to $REPORT_DIR_CANONICAL"

stale_patterns=(
  "Auth status RPC missing"
  "只 start"
  "4 个文件"
  "自动创建 Feishu"
  "TAT/app-token provider parity"
  "series13 is the current source-recheck"
)
for pattern in "${stale_patterns[@]}"; do
  if rg -n "$pattern" docs/user/agent-team.md >/tmp/metis-agentteam-gate-rg.txt; then
    cat /tmp/metis-agentteam-gate-rg.txt >&2
    fail "stale AgentTeam/Feishu wording found in docs/user/agent-team.md: $pattern"
  fi
done
rm -f /tmp/metis-agentteam-gate-rg.txt
info "docs stale-wording check passed"

[[ -f "$SERIES14_DOC" ]] || fail "missing series14 evidence document: $SERIES14_DOC"
rg -n "tenant_access_token.*bot_access_token.*app_access_token|user/TAT/bot/app token provider" "$SERIES14_DOC" >/dev/null \
  || fail "series14 evidence document must record current Feishu token provider support"
info "series14 evidence document check passed"

[[ -f "$PARITY_REPORT" ]] || fail "missing OAPI parity report: $PARITY_REPORT"
rg -n "OpenClaw-Lark source currently enumerates 108" "$PARITY_REPORT" >/dev/null \
  || fail "OAPI parity report must identify the 108 action source baseline"
rg -n "^-? ?aligned: 108$" "$PARITY_REPORT" >/dev/null \
  || fail "OAPI parity report aligned count changed; regenerate and review the report"
rg -n "^-? ?partial: 0$" "$PARITY_REPORT" >/dev/null \
  || fail "OAPI parity report partial count changed; regenerate and review the report"
rg -n "^-? ?missing: 0$" "$PARITY_REPORT" >/dev/null \
  || fail "OAPI parity report missing count is not the reviewed baseline"
rg -n "^-? ?not-applicable: 0$" "$PARITY_REPORT" >/dev/null \
  || fail "OAPI parity report not-applicable count changed; regenerate and review the report"
INVALID_STATUS="$(awk -F'|' '/^\| feishu_/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 != "aligned" && $3 != "partial" && $3 != "missing" && $3 != "not-applicable") print $0 }' "$PARITY_REPORT")"
[[ -z "$INVALID_STATUS" ]] || fail "OAPI parity report contains an invalid status: $INVALID_STATUS"
ACTION_ROWS="$(awk '/^\| feishu_/ { count += 1 } END { print count + 0 }' "$PARITY_REPORT")"
[[ "$ACTION_ROWS" == "108" ]] || fail "OAPI parity report must contain 108 action rows, found $ACTION_ROWS"
info "OAPI parity report check passed"

git diff --check
info "git diff --check passed"

if [[ -z "${METIS_AGENTTEAM_CONTROL_UI_URL:-}" ]]; then
  info "browser smoke skipped; set METIS_AGENTTEAM_CONTROL_UI_URL to a built Control UI or live Gateway URL to enable it"
else
  require_command node
  [[ -d "$ROOT/ui/node_modules" ]] || fail "ui/node_modules is missing; run npm --prefix ui install before browser smoke"
  SMOKE_BASE="$(mktemp "$ROOT/ui/.agentteam-browser-smoke.XXXXXX")"
  SMOKE_SCRIPT="${SMOKE_BASE}.mjs"
  mv "$SMOKE_BASE" "$SMOKE_SCRIPT"
  cleanup() {
    rm -f "$SMOKE_SCRIPT"
  }
  trap cleanup EXIT
  cat >"$SMOKE_SCRIPT" <<'NODE'
import fs from "node:fs";
import { chromium } from "playwright";

const url = process.argv[2];
if (!url) {
  throw new Error("missing Control UI URL");
}

const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const launchOptions = fs.existsSync(chromePath)
  ? { headless: true, executablePath: chromePath }
  : { headless: true };

const browser = await chromium.launch(launchOptions);
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = [];
page.on("pageerror", (err) => errors.push(`pageerror: ${err.message}`));
page.on("requestfailed", (req) => {
  const type = req.resourceType();
  if (type === "document" || type === "script" || type === "stylesheet") {
    errors.push(`requestfailed: ${type} ${req.url()} ${req.failure()?.errorText ?? ""}`);
  }
});

try {
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => Boolean(customElements.get("metis-app")), null, { timeout: 15000 });
  await page.waitForTimeout(500);
  const initial = await page.evaluate(() => ({
    defined: Boolean(customElements.get("metis-app")),
    visibleText: document.body.innerText,
  }));
  if (!initial.defined) {
    throw new Error("customElements.get(\"metis-app\") is not registered");
  }
  if (!initial.visibleText.includes("Metis")) {
    throw new Error("visible Metis UI content was not rendered");
  }

  const agentsLink = page.locator('a[href="/agents"]').first();
  const hasAgentsLink = await agentsLink.count();
  if (hasAgentsLink > 0) {
    await agentsLink.click();
    await page.waitForURL(/\/agents(?:$|[?#])/, { timeout: 10000 });
    await page.waitForFunction(
      () => document.body.innerText.includes("Teams") || document.body.innerText.includes("Agent Teams"),
      null,
      { timeout: 10000 },
    );
  }
  const finalText = await page.evaluate(() => document.body.innerText);
  if (!finalText.includes("Teams") && !finalText.includes("Agent Teams")) {
    throw new Error("Agents -> Teams content is not visible after navigation");
  }
  if (errors.length > 0) {
    throw new Error(errors.join("\n"));
  }
} finally {
  await browser.close();
}
NODE
  (cd "$ROOT/ui" && node "$SMOKE_SCRIPT" "$METIS_AGENTTEAM_CONTROL_UI_URL")
  info "browser smoke passed"
fi

if [[ "${METIS_AGENTTEAM_LIVE_TELEGRAM:-0}" == "1" ]]; then
  if [[ -z "${METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID:-}" || -z "${METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID:-}" ]]; then
    info "live Telegram gate skipped: external-resource-required; provide METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID and METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID to enable manual smoke"
  else
    info "live Telegram gate opted in for account=${METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID}; test chat/topic ids are operator-provided and must be redacted in reports"
    info "live Telegram route checks remain manual: account route, group/topic session isolation, alias routing, and team broadcast aggregate"
  fi
else
  info "live Telegram gate skipped; set METIS_AGENTTEAM_LIVE_TELEGRAM=1 with METIS_AGENTTEAM_TELEGRAM_ACCOUNT_ID and METIS_AGENTTEAM_TELEGRAM_TEST_CHAT_ID to enable manual smoke"
fi

if [[ "${METIS_AGENTTEAM_LIVE_FEISHU:-0}" == "1" ]]; then
  info "live Feishu gate is opt-in; record app/account/tenant/scopes, pass/fail, and log redaction result in the runbook"
else
  info "live Feishu gate skipped"
fi

info "manual acceptance preflight passed"
