#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/metis-agentteam-gate-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "[agentteam-gate-test] ERROR: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  rg -n "$pattern" "$file" >/dev/null || fail "$file does not contain expected pattern: $pattern"
}

assert_tree_not_contains_secret() {
  local dir="$1"
  if rg -n -i 'bot[ _-]?token[=:][^ ]+|app[ _-]?secret[=:][^ ]+|access[ _-]?token[=:][^ ]+|refresh[ _-]?token[=:][^ ]+|authorization:[[:space:]]*bearer[[:space:]]+[^ ]+|sk-[A-Za-z0-9_-]{16,}' "$dir" >/dev/null; then
    fail "secret-like evidence found under $dir"
  fi
}

run_gate() {
  local home="$1"
  local metis_home="$2"
  local report_dir="$3"
  local log_file="$4"
  env -i \
    PATH="$PATH" \
    HOME="$home" \
    METIS_AGENTTEAM_SKIP_ENVSETUP=1 \
    METIS_HOME="$metis_home" \
    METIS_AGENTTEAM_REPORT_DIR="$report_dir" \
    "$ROOT/scripts/agentteam-manual-acceptance-gate.sh" >"$log_file" 2>&1
}

fake_home="$TMP_ROOT/operator-home"
metis_home="$TMP_ROOT/metis-home"
report_dir="$TMP_ROOT/evidence"
mkdir -p "$fake_home"

run_gate "$fake_home" "$metis_home" "$report_dir" "$TMP_ROOT/success.log"

[[ -f "$report_dir/report.json" ]] || fail "report.json was not written"
[[ -f "$report_dir/manual-acceptance-template.md" ]] || fail "manual-acceptance-template.md was not written"
assert_file_contains "$report_dir/report.json" '"series": "19"'
assert_file_contains "$report_dir/report.json" '"phases": "0-9"'
assert_file_contains "$report_dir/report.json" '"acceptance"'
assert_file_contains "$report_dir/report.json" '"id": "phase2"'
assert_file_contains "$report_dir/report.json" '"id": "G02"'
assert_file_contains "$report_dir/report.json" '"id": "G11"'
assert_file_contains "$report_dir/report.json" '"status": "local-pass"'
assert_file_contains "$report_dir/report.json" '"status": "external-resource-required"'
assert_file_contains "$report_dir/report.json" '"storesRealMetisHome": false'
assert_file_contains "$report_dir/manual-acceptance-template.md" '## Phase 0 Evidence Freeze'
assert_file_contains "$report_dir/manual-acceptance-template.md" '## Phase 2 Agent Isolation Acceptance'
assert_file_contains "$report_dir/manual-acceptance-template.md" '\| G02 \|'
assert_file_contains "$report_dir/manual-acceptance-template.md" '\| G11 \| external-resource-required \|'
assert_file_contains "$report_dir/manual-acceptance-template.md" '## Phase 1 Core AgentTeam CLI/RPC Acceptance'
assert_file_contains "$report_dir/manual-acceptance-template.md" 'CLI team create/list/get/update/delete'
assert_file_contains "$report_dir/manual-acceptance-template.md" 'RPC agents.teams create/list/get/update/delete'
assert_file_contains "$report_dir/manual-acceptance-template.md" 'Binding conflict rejects same route/different agent without partial write'
assert_tree_not_contains_secret "$report_dir"

real_home="$TMP_ROOT/real-home"
mkdir -p "$real_home"
if env -i \
  PATH="$PATH" \
  HOME="$real_home" \
  METIS_AGENTTEAM_SKIP_ENVSETUP=1 \
  METIS_AGENTTEAM_ALLOW_REAL_HOME=1 \
  METIS_HOME="$real_home/.metis" \
  "$ROOT/scripts/agentteam-manual-acceptance-gate.sh" >"$TMP_ROOT/real-home.log" 2>&1; then
  fail "gate accepted HOME/.metis even though Phase 0 requires isolated METIS_HOME"
fi
assert_file_contains "$TMP_ROOT/real-home.log" 'real home'

echo "[agentteam-gate-test] passed"
