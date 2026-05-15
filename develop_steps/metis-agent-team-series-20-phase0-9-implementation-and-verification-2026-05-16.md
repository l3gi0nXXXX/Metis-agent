# Metis Agent Team Series 20 Phase 0-9 Implementation And Verification

日期：2026-05-16

## 1. 范围

本次基于 `metis-agent-team-series-19-feishu-openclaw-source-recheck-gap-quantification-manual-acceptance-2026-05-16.md` 执行 phase 0 至 phase 9 的补齐工作，目标是在不突破 Metis 现有 Gateway、ChannelManager、agent scope、Control UI 架构边界的前提下，尽可能一次性关闭可本地实现和可本地验收的 Agent Team GAP。

## 2. 实施摘要

- Phase 0-2：补强 Agent Team 手工验收 gate、CLI/RPC 参数构造、team 创建/更新/删除、绑定冲突、agent workspace 与模型/认证隔离测试。
- Phase 3-4：补强 Telegram 私聊、群、topic、mention alias、broadcast 路由与 fake IM 端到端验收。
- Phase 5-6：补强 Feishu accountId、账号级凭据来源、OAuth/UAT 生命周期、渠道状态诊断与 OAPI token mode 诊断。
- Phase 7-8：补强 Feishu OAPI action parity、scope exactness、live smoke opt-in、repair action、脱敏诊断与 no-network 默认路径。
- Phase 9：补齐 Control UI 的 Agent Teams 一级入口、管理控制台空态、Feishu 配置边界说明、导航/浏览器烟测和构建产物。

## 3. 额外修复

验证阶段发现两个真实问题并已修复：

- Feishu OAPI token lookup 错误文案没有统一经过敏感信息脱敏，已在 OAPI result 与 scope diagnostic 输出边界统一处理，同时避免把普通诊断 `token endpoint unavailable` 误判为密钥。
- Telegram AgentTeam fake inbound 测试缺少 `adapter.start()` 前置条件，导致队列为空，已与同文件其他 fake inbound 用例保持一致。

## 4. 验收结果

已通过：

- `bash -n scripts/agentteam-manual-acceptance-gate.sh scripts/agentteam-manual-acceptance-gate-test.sh`
- `bash scripts/agentteam-manual-acceptance-gate-test.sh`
- `node --test scripts/agentteam-manual-acceptance-gate.test.mjs`
- `METIS_AGENTTEAM_SKIP_ENVSETUP=1 METIS_HOME=/tmp/metis-agentteam-s19-main-gate METIS_AGENTTEAM_REPORT_DIR=/tmp/metis-agentteam-s19-main-report scripts/agentteam-manual-acceptance-gate.sh`
- `npm --prefix ui run build`
- `npm --prefix ui test -- src/ui/controllers/agent-teams.metis.test.ts src/ui/views/agents-panel-teams.metis.test.ts src/ui/views/agents.metis.test.ts src/ui/navigation.test.ts src/ui/navigation.browser.test.ts src/ui/metis-control-ui-contract.metis.test.ts src/ui/metis-control-ui-browser-smoke.metis.test.ts --reporter verbose`
- `cjpm test src/gateway/tools --no-color --parallel 1`
- `cjpm test src/gateway/channels/telegram --no-color --parallel 1`
- `cjpm test src/core/tools/fs_utils --no-color --show-all-output --parallel 1`
- `cjpm test src/program --no-color --show-all-output --parallel 1`
- `cjpm clean && cjpm build -i && cjpm test`

最终完整 Cangjie 验证结果：1423 passed, 0 skipped, 0 error, 0 failed。

## 5. 仍需外部资源验收的项目

以下项目已在 gate 中明确标记为 external-resource-required，不在本地测试中伪装为已通过：

- 真实 Telegram bot、真实 chat/topic、真实回调或 polling 链路。
- 真实 Feishu app、tenant、OAuth/UAT 授权、OAPI scope 与回调域名。
- 自动创建 Feishu bot/app 仍受飞书开放平台能力、租户权限和人工审核约束，当前实现保持为明确诊断、配置向导、OAuth/OAPI 边界与手工验收 gate。
