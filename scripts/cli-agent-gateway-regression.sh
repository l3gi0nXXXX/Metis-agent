#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/build_lock.sh"

set +u
source /Users/l3gi0n/cangjie100/envsetup.sh
set -u

TMP_HOME="$(mktemp -d /tmp/metis-cli-agent-gw.XXXXXX)"
GATEWAY_LOG="$TMP_HOME/gateway.log"
GATEWAY_PID=""
BIN="$ROOT/target/release/bin/metis"
STDX_LIB_PATH="$ROOT/../CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx"
if [[ ! -d "$STDX_LIB_PATH" ]]; then
  STDX_LIB_PATH="$ROOT/../../../CangjieMagic/libs/cangjie-stdx-mac-aarch64-1.0.0.1/darwin_aarch64_llvm/dynamic/stdx"
fi
CLI_LIB_PATH="$ROOT/target/release/metis:$ROOT/ffi"
MAGIC_LIB_PATH="$ROOT/target/release/magic"
LIB_PATHS="$CLI_LIB_PATH:$MAGIC_LIB_PATH:$STDX_LIB_PATH"

append_if_dir() {
  local dir="$1"
  if [[ -n "$dir" && -d "$dir" ]]; then
    LIB_PATHS="$LIB_PATHS:$dir"
  fi
}

prepare_runtime_env() {
  append_if_dir "/opt/homebrew/opt/openssl@3/lib"
  append_if_dir "/opt/homebrew/opt/openssl@3.5/lib"
  append_if_dir "/usr/local/opt/openssl@3/lib"
  export DYLD_LIBRARY_PATH="$LIB_PATHS:${DYLD_LIBRARY_PATH:-}"
}

cleanup() {
  local exit_code=$?
  if [[ -n "${GATEWAY_PID}" ]]; then
    kill "${GATEWAY_PID}" >/dev/null 2>&1 || true
    wait "${GATEWAY_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_HOME}" >/dev/null 2>&1 || true
  return "${exit_code}"
}
trap cleanup EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s\n' "$haystack" | rg -F -- "$needle" >/dev/null; then
    echo "missing expected text: $needle" >&2
    exit 1
  fi
}

assert_matches() {
  local haystack="$1"
  local pattern="$2"
  if ! printf '%s\n' "$haystack" | rg --multiline "$pattern" >/dev/null; then
    echo "missing expected pattern: $pattern" >&2
    exit 1
  fi
}

run_cli() {
  prepare_runtime_env
  METIS_HOME="$TMP_HOME" METIS_CJPM_ROOT="$ROOT" \
    "$BIN" "$@"
}

mkdir -p "$TMP_HOME"
cat >"$TMP_HOME/metis.json" <<'EOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "qwen/qwen3.5-plus"
      }
    }
  },
  "models": {
    "providers": {
      "qwen": {
        "apiKey": "qwen-demo-key",
        "baseUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1"
      }
    }
  },
  "gateway": {
    "enabled": true,
    "port": 28890,
    "controlUi": {
      "enabled": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "auth": {
      "mode": "token",
      "token": "cli-agent-gateway-test-token"
    }
  }
}
EOF

echo "[cli-agent-gateway-regression] build"
mkdir -p target build-script-cache/release/metis/bin build-script-cache/release/magic/bin
with_metis_cjpm_build_lock rtk cjpm build -i >/dev/null

echo "[cli-agent-gateway-regression] start gateway"
prepare_runtime_env
METIS_HOME="$TMP_HOME" METIS_CJPM_ROOT="$ROOT" \
  "$BIN" gateway run \
  >"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID="$!"

for _ in $(seq 1 60); do
  if [[ -f "$TMP_HOME/gateway-serve.lock" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "$TMP_HOME/gateway-serve.lock" ]]; then
  echo "gateway did not start" >&2
  cat "$GATEWAY_LOG" >&2 || true
  exit 1
fi

echo "[cli-agent-gateway-regression] wait for gateway health"
gateway_ready="false"
for _ in $(seq 1 60); do
  gateway_health_out="$(run_cli gateway call health 2>&1 || true)"
  if { printf '%s\n' "$gateway_health_out" | rg '"ok"\s*:\s*true' >/dev/null && printf '%s\n' "$gateway_health_out" | rg '"method"\s*:\s*"health"' >/dev/null; } || printf '%s\n' "$gateway_health_out" | rg 'Gateway:\s*enabled=true\s*running=true' >/dev/null; then
    gateway_ready="true"
    break
  fi
  sleep 1
done

if [[ "$gateway_ready" != "true" ]]; then
  echo "gateway did not become reachable" >&2
  printf '%s\n' "$gateway_health_out" >&2 || true
  cat "$GATEWAY_LOG" >&2 || true
  exit 1
fi

echo "[cli-agent-gateway-regression] agent main session uses agent-scoped key"
agent_main_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer)"
printf '%s\n' "$agent_main_json"
assert_matches "$agent_main_json" '"agentId"\s*:\s*"reviewer"'
assert_matches "$agent_main_json" '"session"\s*:\s*"agent:reviewer:main"'

echo "[cli-agent-gateway-regression] --to resolves direct agent session key"
agent_to_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --to user123)"
printf '%s\n' "$agent_to_json"
assert_matches "$agent_to_json" '"session"\s*:\s*"agent:reviewer:direct:user123"'
assert_matches "$agent_to_json" '"to"\s*:\s*"user123"'

echo "[cli-agent-gateway-regression] --session-id resolves explicit agent session key"
agent_session_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --session-id workbench)"
printf '%s\n' "$agent_session_json"
assert_matches "$agent_session_json" '"session"\s*:\s*"agent:reviewer:explicit:workbench"'

echo "[cli-agent-gateway-regression] --lane namespaces the resolved session key"
agent_lane_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --session-id workbench --lane review)"
printf '%s\n' "$agent_lane_json"
assert_matches "$agent_lane_json" '"session"\s*:\s*"agent:reviewer:explicit:workbench:lane:review"'
assert_matches "$agent_lane_json" '"lane"\s*:\s*"review"'

echo "[cli-agent-gateway-regression] --run-id remains stable across process-local CLI invokes"
first_run_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --run-id idem-reviewer-1)"
printf '%s\n' "$first_run_json"
assert_matches "$first_run_json" '"runId"\s*:\s*"idem-reviewer-1"'
assert_matches "$first_run_json" '"idempotentReplay"\s*:\s*false'

second_run_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --run-id idem-reviewer-1)"
printf '%s\n' "$second_run_json"
assert_matches "$second_run_json" '"runId"\s*:\s*"idem-reviewer-1"'
assert_matches "$second_run_json" '"idempotentReplay"\s*:\s*false'

echo "[cli-agent-gateway-regression] agents list works against running gateway"
agents_list_json="$(run_cli agents list --json)"
printf '%s\n' "$agents_list_json"
assert_matches "$agents_list_json" '"method"\s*:\s*"agents.list"'
assert_matches "$agents_list_json" '"builtin"\s*:'

echo "[cli-agent-gateway-regression] agents summary works against running gateway"
agents_summary_json="$(run_cli agents summary --json)"
printf '%s\n' "$agents_summary_json"
assert_matches "$agents_summary_json" '"method"\s*:\s*"agents.summary"'
assert_matches "$agents_summary_json" '"totalCount"\s*:'

echo "[cli-agent-gateway-regression] agents health works against running gateway"
agents_health_json="$(run_cli agents health --json)"
printf '%s\n' "$agents_health_json"
assert_matches "$agents_health_json" '"method"\s*:\s*"agents.health"'
assert_matches "$agents_health_json" '"healthy"\s*:'

echo "[cli-agent-gateway-regression] agents capabilities works against running gateway"
agents_capabilities_json="$(run_cli agents capabilities --json)"
printf '%s\n' "$agents_capabilities_json"
assert_matches "$agents_capabilities_json" '"method"\s*:\s*"agents.capabilities"'
assert_matches "$agents_capabilities_json" '"capabilities"\s*:'

echo "[cli-agent-gateway-regression] agents add creates a managed custom agent"
agents_add_json="$(run_cli agents add --agent reviewer-local --name ReviewerLocal --json)"
printf '%s\n' "$agents_add_json"
assert_matches "$agents_add_json" '"method"\s*:\s*"agents.add"'
assert_matches "$agents_add_json" '"agentId"\s*:\s*"reviewer-local"'

echo "[cli-agent-gateway-regression] agents set-identity updates managed agent identity"
agents_identity_json="$(run_cli agents set-identity --agent reviewer-local --name ReviewerLocal --emoji R --json)"
printf '%s\n' "$agents_identity_json"
assert_matches "$agents_identity_json" '"method"\s*:\s*"agents.set-identity"'
assert_matches "$agents_identity_json" '"name"\s*:\s*"ReviewerLocal"'

echo "[cli-agent-gateway-regression] agents bind adds a routing binding"
agents_bind_json="$(run_cli agents bind --agent reviewer-local --bind qq:default --json)"
printf '%s\n' "$agents_bind_json"
assert_matches "$agents_bind_json" '"method"\s*:\s*"agents.bind"'
assert_matches "$agents_bind_json" '"added"\s*:'

echo "[cli-agent-gateway-regression] agents bindings lists the route"
agents_bindings_json="$(run_cli agents bindings --agent reviewer-local --json)"
printf '%s\n' "$agents_bindings_json"
assert_matches "$agents_bindings_json" '"method"\s*:\s*"agents.bindings"'
assert_matches "$agents_bindings_json" '"description"\s*:\s*"qq:default"'

echo "[cli-agent-gateway-regression] agents unbind removes the route"
agents_unbind_json="$(run_cli agents unbind --agent reviewer-local --bind qq:default --json)"
printf '%s\n' "$agents_unbind_json"
assert_matches "$agents_unbind_json" '"method"\s*:\s*"agents.unbind"'
assert_matches "$agents_unbind_json" '"removed"\s*:'

echo "[cli-agent-gateway-regression] agents team create applies fake Telegram route binding"
telegram_team_binding='{"type":"route","agentId":"e2e-writer","match":{"channel":"telegram","accountId":"bot-a","peer":{"kind":"group","id":"-100_e2e"}}}'
agents_team_create_json="$(run_cli agents team create --team e2e --name "Fake E2E Team" --template pm-writer-reviewer --alias "/agent writer=e2e-writer" --binding-json "$telegram_team_binding" --json)"
printf '%s\n' "$agents_team_create_json"
assert_matches "$agents_team_create_json" '"method"\s*:\s*"agents.teams.create"'
assert_matches "$agents_team_create_json" '"id"\s*:\s*"e2e"'
assert_matches "$agents_team_create_json" '"bindingApply"\s*:'
assert_contains "$agents_team_create_json" '"e2e-writer"'

echo "[cli-agent-gateway-regression] agents bindings exposes fake Telegram route"
agents_team_writer_bindings_json="$(run_cli agents bindings --agent e2e-writer --json)"
printf '%s\n' "$agents_team_writer_bindings_json"
assert_matches "$agents_team_writer_bindings_json" '"method"\s*:\s*"agents.bindings"'
assert_contains "$agents_team_writer_bindings_json" '"description": "telegram:bot-a peer=group:-100_e2e"'

echo "[cli-agent-gateway-regression] gateway RPC updates fake Feishu route and deterministic broadcast"
agents_team_update_json="$(run_cli gateway call agents.teams.update '{"id":"e2e","bindings":[{"type":"route","agentId":"e2e-reviewer","match":{"channel":"feishu","accountId":"tenant-a","peer":{"kind":"thread","id":"thread-e2e"}}}],"broadcast":{"enabled":true,"members":["e2e-writer","e2e-reviewer"]}}')"
printf '%s\n' "$agents_team_update_json"
assert_matches "$agents_team_update_json" '"method"\s*:\s*"agents.teams.update"'
assert_matches "$agents_team_update_json" '"id"\s*:\s*"e2e"'
assert_contains "$agents_team_update_json" '"channel": "feishu"'
assert_contains "$agents_team_update_json" '"id": "thread-e2e"'
assert_contains "$agents_team_update_json" '"enabled": true'
assert_contains "$agents_team_update_json" '"e2e-reviewer"'

echo "[cli-agent-gateway-regression] agents bindings exposes fake Feishu thread route"
agents_team_reviewer_bindings_json="$(run_cli agents bindings --agent e2e-reviewer --json)"
printf '%s\n' "$agents_team_reviewer_bindings_json"
assert_matches "$agents_team_reviewer_bindings_json" '"method"\s*:\s*"agents.bindings"'
assert_contains "$agents_team_reviewer_bindings_json" '"description": "feishu:tenant-a peer=thread:thread-e2e"'

echo "[cli-agent-gateway-regression] agents team get returns persisted broadcast members"
agents_team_get_json="$(run_cli agents team get --team e2e --json)"
printf '%s\n' "$agents_team_get_json"
assert_matches "$agents_team_get_json" '"method"\s*:\s*"agents.teams.get"'
assert_contains "$agents_team_get_json" '"enabled": true'
assert_contains "$agents_team_get_json" '"e2e-writer"'
assert_contains "$agents_team_get_json" '"e2e-reviewer"'

echo "[cli-agent-gateway-regression] agents delete removes the managed custom agent"
agents_delete_json="$(run_cli agents delete --agent reviewer-local --json)"
printf '%s\n' "$agents_delete_json"
assert_matches "$agents_delete_json" '"method"\s*:\s*"agents.delete"'
assert_matches "$agents_delete_json" '"agentId"\s*:\s*"reviewer-local"'

echo "[cli-agent-gateway-regression] --best-effort-deliver keeps invoke success on missing target"
agent_best_effort_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --deliver --best-effort-deliver)"
printf '%s\n' "$agent_best_effort_json"
assert_matches "$agent_best_effort_json" '"deliveryStatus"\s*:\s*"best-effort-missing-target"'
assert_matches "$agent_best_effort_json" '"bestEffortDeliver"\s*:\s*true'

echo "[cli-agent-gateway-regression] non-best-effort delivery failure exits non-zero"
set +e
agent_delivery_fail_out="$(run_cli agent --message /definitely-unknown --json --agent reviewer --deliver 2>&1)"
agent_delivery_fail_code=$?
set -e
printf '%s\n' "$agent_delivery_fail_out"
assert_contains "$agent_delivery_fail_out" "reply target could not be resolved"
assert_contains "$agent_delivery_fail_out" "Gateway agent failed"

echo "[cli-agent-gateway-regression] --verbose full enriches plain-text output"
agent_verbose_out="$(run_cli agent --message /definitely-unknown --agent reviewer --verbose full)"
printf '%s\n' "$agent_verbose_out"
assert_contains "$agent_verbose_out" "[routing]"
assert_contains "$agent_verbose_out" "[delivery]"
assert_contains "$agent_verbose_out" "[invoke]"

echo "[cli-agent-gateway-regression] --timeout is preserved in invoke payload"
agent_timeout_json="$(run_cli agent --message /definitely-unknown --json --agent reviewer --timeout 1)"
printf '%s\n' "$agent_timeout_json"
assert_matches "$agent_timeout_json" '"timeout"\s*:\s*1'

echo "[cli-agent-gateway-regression] ok"
