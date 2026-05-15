# Metis AgentTeam Series 14 Manual Acceptance Runbook

Date: 2026-05-15
Scope: Phase 1 real-environment evidence package and Phase 9 release validation closeout template.

This file is a redacted evidence template. Do not paste Telegram bot tokens, Feishu app secrets, access tokens, refresh tokens, device codes, authorization headers, or real user files from `~/.metis`.

## 1. Evidence Rules

- Use an isolated `METIS_HOME`, for example `/tmp/metis-agentteam-manual-acceptance-series14`.
- Do not use production Telegram bots, Feishu tenants, Feishu groups, or provider keys unless a release owner explicitly records that decision.
- Live Telegram and Feishu checks are opt-in. If credentials are unavailable, record `skipped` with the exact reason.
- Redact identifiers that are not needed for replay. Use stable labels such as `telegram-test-bot-a`, `feishu-test-tenant-a`, and `feishu-test-group-a`.
- Preserve source-backed references in `develop_steps/metis-agent-team-series-14-current-source-recheck-gap-quantification-manual-acceptance-2026-05-15.md`.

## 2. Environment

| Field | Value |
| --- | --- |
| Operator | `<name or handle>` |
| Run date/time | `<YYYY-MM-DD HH:MM timezone>` |
| Metis commit | `<git rev-parse HEAD>` |
| Worktree | `/Users/l3gi0n/work/workspace_cangjie/Metis/.worktrees/agentteam-s14-phase9-20260515` |
| METIS_HOME | `/tmp/metis-agentteam-manual-acceptance-series14` |
| DYLD_LIBRARY_PATH openssl entry | `/opt/homebrew/opt/openssl@3/lib` |
| Control UI URL | `<skipped or http://127.0.0.1:.../>` |
| Live Telegram opt-in | `0` or `1` |
| Live Feishu opt-in | `0` or `1` |

Setup commands:

```bash
source /Users/l3gi0n/cangjie100/envsetup.sh
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$DYLD_LIBRARY_PATH"
export METIS_HOME="/tmp/metis-agentteam-manual-acceptance-series14"
```

## 3. Frozen Source Evidence

| Artifact | Expected evidence | Result |
| --- | --- | --- |
| Series14 source recheck | Current Feishu token provider support is recorded as user/TAT/bot/app token support. | `<pass/fail>` |
| OAPI parity report | 108 action rows, 108 aligned, 0 partial, 0 missing, 0 not-applicable. | `<pass/fail>` |
| AgentTeam user guide | References series14 and this runbook; no stale TAT/app-token provider release-gate wording. | `<pass/fail>` |

## 4. Test Accounts

| Resource | Redacted identifier | Notes |
| --- | --- | --- |
| Telegram test bot | `<telegram-test-bot-a>` | Token stored only in isolated test config. |
| Telegram test chat/topic | `<telegram-test-chat-a/topic-a>` | Record only redacted chat/topic ids if needed. |
| Feishu test app | `<feishu-test-app-a>` | Do not record appSecret. |
| Feishu test tenant | `<feishu-test-tenant-a>` | Test tenant only. |
| Feishu test user | `<feishu-test-user-a>` | User can authorize OAuth. |
| Feishu test group/thread | `<feishu-test-group-a/thread-a>` | Bot installed in the test group. |
| Feishu scopes enabled | `<redacted scope list or skipped>` | Record scope names, never tokens. |

## 5. Gate Commands

| Command | Expected | Result |
| --- | --- | --- |
| `METIS_HOME=/tmp/metis-agentteam-manual-acceptance-series14 scripts/agentteam-manual-acceptance-gate.sh` | Passes with live Telegram/Feishu skipped unless opt-in env vars are set. | `<pass/fail/skipped>` |
| `git diff --check` | No whitespace errors. | `<pass/fail>` |

Paste only non-secret command summaries:

```text
<agentteam-gate summary lines>
```

## 6. Telegram Manual Checks

| ID | Check | Expected | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | Test bot configured under isolated `METIS_HOME` | No production token or real `~/.metis` use. | `<pass/fail/skipped>` | `<redacted note>` |
| T2 | `telegram:<accountId>` route binding | Gateway inbound shows `channel=telegram`; route selects expected agent. | `<pass/fail/skipped>` | `<redacted log summary>` |
| T3 | Group/topic session isolation | Different topics produce distinct session keys. | `<pass/fail/skipped>` | `<redacted session key suffixes>` |
| T4 | Alias route | `@writer` or `/agent writer` routes to writer member; default fallback works. | `<pass/fail/skipped>` | `<redacted transcript summary>` |

## 7. Feishu Manual Checks

| ID | Check | Expected | Result | Evidence |
| --- | --- | --- | --- | --- |
| F1 | Feishu app configured | Gateway status reports configured account with redacted fields. | `<pass/fail/skipped>` | `<redacted status summary>` |
| F2 | OAuth missing credentials | Missing app secret returns `missing_app_credentials`, redacted. | `<pass/fail/skipped>` | `<redacted JSON status>` |
| F3 | OAuth live smoke skipped | Without opt-in, live smoke reports `skipped` and performs no real network call. | `<pass/fail/skipped>` | `<redacted command summary>` |
| F4 | OAuth live flow | With opt-in test app, start/status/poll/complete/revoke succeeds or fails with clear redacted reason. | `<pass/fail/skipped>` | `<redacted result>` |
| F5 | OAPI UAT action | Authorized user action succeeds; unauthorized path returns `auth_required` or `scope_missing`. | `<pass/fail/skipped>` | `<redacted action/result>` |
| F6 | OAPI TAT/app token action | Tenant/app-token action does not return `token_mode_unsupported`; missing credential is structured. | `<pass/fail/skipped>` | `<redacted action/result>` |
| F7 | App scope missing | Missing app permission returns `app_scope_missing` with missing scope names only. | `<pass/fail/skipped>` | `<redacted scope list>` |
| F8 | Rich event replay/live event | Message/reaction/card/drive/membership fixtures route or ignore with expected reason. | `<pass/fail/skipped>` | `<redacted event ids>` |
| F9 | Streaming card | Create/patch/finalize/abort path works or returns explicit fallback. | `<pass/fail/skipped>` | `<redacted card id suffix>` |

## 8. Phase 9 Validation Closeout

This worker should not run repository-wide `cjpm clean`, `cjpm build -i`, or `cjpm test`; those remain for the main workspace release gate.

| Validation | Owner | Result | Notes |
| --- | --- | --- | --- |
| Worker manual gate | Phase 0/1/9 worker | `<pass/fail>` | Isolated `METIS_HOME`; no live network unless opt-in. |
| Worker `git diff --check` | Phase 0/1/9 worker | `<pass/fail>` | Required before commit. |
| Full Cangjie clean/build/test | Main workspace release owner | `<pending/pass/fail>` | `cjpm clean && cjpm build -i && cjpm test`. |
| UI test/build | Main workspace release owner | `<pending/pass/fail>` | `npm --prefix ui test && npm --prefix ui run build`. |
| Control UI browser smoke | Main workspace release owner if UI touched | `<pending/pass/fail/skipped>` | Required for UI/browser runtime changes. |

## 9. Secret Redaction Checklist

- [ ] No Telegram bot token in this file.
- [ ] No Feishu appSecret in this file.
- [ ] No Feishu access token, refresh token, device code, or authorization header in this file.
- [ ] No production tenant, group, or user identifiers unless explicitly approved and redacted.
- [ ] No real `~/.metis` files were read into evidence or modified during the run.

## 10. Final Signoff

| Field | Value |
| --- | --- |
| Overall result | `<pass/fail/blocked>` |
| Blocking issues | `<none or issue links>` |
| Residual risks | `<remaining live gaps or skipped tests>` |
| Commit SHA | `<local commit after changes>` |
