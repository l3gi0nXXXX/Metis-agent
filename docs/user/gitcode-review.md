# GitCode Review 配置说明

本文说明 Metis 在处理 GCM 发送的 GitCode issue、PR、评论 review 请求时使用的本地运行配置。GCM 负责 GitCode webhook、队列、作者过滤、team leader/CODEOWNERS 解析和 GitCode API 写回；Metis 负责源码上下文、CKB evidence、外部 PR review adapter 调用、LLM 草稿生成和结果回传。

## `gateway.gitcodeReview.sourceWorkspace`

`gateway.gitcodeReview.sourceWorkspace` 是 Metis 用来保存 GitCode 仓库源码的长期工作区配置。它不是一次性临时目录，也不是 GCM webhook queue。Metis 在需要源码上下文时，会在该目录下按仓库生成安全子目录，首次处理时 clone，后续处理时 pull 更新；如果 pull 失败，Metis 可以基于已存在的本地源码和事件信息降级生成回复。

默认配置如下：

```json
{
  "gateway": {
    "gitcodeReview": {
      "sourceWorkspace": {
        "root": "~/.metis/gitcode/repo-source-code",
        "allowedHosts": ["gitcode.com"],
        "gitTimeoutMs": 30000,
        "maxFilesPerRequest": 30,
        "maxFileBytes": 65536
      }
    }
  }
}
```

如果你接受默认值，可以不写 `gateway.gitcodeReview.sourceWorkspace`。需要把源码长期缓存放到其他位置时，只修改 `root`，不要把它指向 Metis 项目源码目录、GCM 项目源码目录、测试夹具目录或 `/tmp`。

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `gateway.gitcodeReview.sourceWorkspace.root` | `~/.metis/gitcode/repo-source-code` | 长期源码缓存根目录。必须能展开成绝对路径；不能为空；不能包含 `..`；不能指向当前 Metis 项目工作区内部。 |
| `gateway.gitcodeReview.sourceWorkspace.allowedHosts` | `["gitcode.com"]` | 允许 clone/pull 的 Git host 白名单。当前只允许 `gitcode.com`，不支持任意 host。 |
| `gateway.gitcodeReview.sourceWorkspace.gitTimeoutMs` | `30000` | git 操作超时时间，单位毫秒。合法范围是 `1000` 到 `120000`。 |
| `gateway.gitcodeReview.sourceWorkspace.maxFilesPerRequest` | `30` | 单次请求最多读取多少个源码文件用于上下文。合法范围是 `1` 到 `200`。 |
| `gateway.gitcodeReview.sourceWorkspace.maxFileBytes` | `65536` | 单个源码文件最多读取多少字节。合法范围是 `1024` 到 `1048576`。 |

推荐的自定义配置示例：

```json
{
  "gateway": {
    "gitcodeReview": {
      "sourceWorkspace": {
        "root": "/Users/l3gi0n/.metis/gitcode/repo-source-code",
        "allowedHosts": ["gitcode.com"],
        "gitTimeoutMs": 30000,
        "maxFilesPerRequest": 30,
        "maxFileBytes": 65536
      }
    }
  }
}
```

运行边界：

- `root` 下的源码可以长期保留，下一次相同仓库事件会复用并尝试更新。
- 删除 `root` 下的缓存会导致下次处理相关仓库时重新 clone。
- `allowedHosts` 当前只能配置为 `["gitcode.com"]`；如果写入其他 host，配置校验会失败。
- 当 repo URL 不是 `gitcode.com`、ref 不可信、路径包含 `..` 或文件路径越界时，Metis 应拒绝读取对应源码。
- 当 clone 失败时，本次源码上下文状态应为 `clone_failed`，业务可以基于 webhook/issue/PR/comment 已有信息降级处理。
- 当 pull 失败但本地已有源码时，本次源码上下文状态应为 `stale_available`，业务可以使用旧源码并在回复或诊断中标记降级。

排查方法：

1. 启动 Gateway 后触发一个 GitCode review 事件。
2. 查看 Metis 日志中是否出现 source workspace 相关状态，例如 `resolved`、`clone_failed`、`stale_available`、`invalid_workspace_root` 或 `invalid_clone_host`。
3. 查看 `root` 下是否出现按仓库 hash 生成的子目录。
4. 如果配置无效，先检查 `root` 是否包含 `..`、是否为绝对路径展开结果、是否误指向当前项目工作区内部；再检查 `allowedHosts` 是否只包含 `gitcode.com`。

## `gateway.gitcodeReview.promptTemplates`

`gateway.gitcodeReview.promptTemplates` 用于配置 GitCode review 六类提示词模板的用户覆盖目录。它只影响 Metis 生成回复草稿时的 prompt 内容，不影响 GCM 的 webhook 鉴权、作者过滤、team leader/CODEOWNERS 解析、GitCode API 写回或维护者提及句追加。

默认配置如下：

```json
{
  "gateway": {
    "gitcodeReview": {
      "promptTemplates": {
        "dir": "~/.metis/gitcodemonitor/prompt",
        "allowUserOverride": true,
        "reloadPolicy": "on_plugin_load",
        "maxTemplateBytes": 32768,
        "strictValidation": true
      }
    }
  }
}
```

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `gateway.gitcodeReview.promptTemplates.dir` | `~/.metis/gitcodemonitor/prompt` | 用户自定义模板目录。目录缺失或某个模板文件缺失时，Metis 对缺失模板使用内置默认模板。 |
| `gateway.gitcodeReview.promptTemplates.allowUserOverride` | `true` | 是否允许读取用户覆盖模板。设为 `false` 时只使用内置模板。 |
| `gateway.gitcodeReview.promptTemplates.reloadPolicy` | `on_plugin_load` | 当前只支持 `on_plugin_load`，即 Gateway/GCM service plugin 加载时读取模板；修改模板后需要重启 Gateway 或重新加载插件。 |
| `gateway.gitcodeReview.promptTemplates.maxTemplateBytes` | `32768` | 单个模板最大字节数。合法范围是 `4096` 到 `131072`。超限模板会 fallback 到内置模板。 |
| `gateway.gitcodeReview.promptTemplates.strictValidation` | `true` | 当前必须保持 `true`。模板 metadata、契约版本、正文安全检查不通过时，单个模板 fallback 到内置模板。 |

用户覆盖目录下支持六个文件：

| 文件名 | `templateId` | 适用事件 |
| --- | --- | --- |
| `issue-bug.md` | `issue_bug` | bug issue。 |
| `issue-feature-request.md` | `issue_feature_request` | feature request issue。 |
| `issue-question.md` | `issue_question` | question issue。 |
| `pr-english.md` | `pr_english` | 英文 PR 模板。 |
| `pr-chinese.md` | `pr_chinese` | 中文 PR 模板。 |
| `comment.md` | `comment_reply` | issue 或 PR 下的新评论。 |

每个模板文件必须包含 frontmatter，格式如下：

```markdown
---
templateId: issue_bug
contractVersion: gcm-metis-gitcode-review-v1
templateVersion: 2
inputSchema: PromptInputV1
outputSchema: GitCodeGeneratedReplyModelOutputV1
language: zh-CN
---

# Role
你是仓颉社区技术专家。

# Task
基于 issue、源码上下文、CKB evidence 和诊断信息生成回复草稿。

# Evidence Policy
只使用输入中已有的事实和证据；证据不足时说明限制，不能编造。

# Style
自然、具体、平等，不要像流程通知。
```

模板边界：

- 模板正文不得要求模型生成 `@team leader`、`@codeowner` 或维护者 footer；这些提及句由 GCM 在写回前追加。
- 模板正文不得包含真实 token、Cookie、Authorization header、本机绝对路径、`auto-reply`、`gitcodemonitor` 或其他机器来源说明。
- `system-prompt.md` 只是提示词研究素材，不是运行时模板目录；不要把 `07-AI-Research/system-prompt.md` 配到 `promptTemplates.dir`。
- 单个用户模板校验失败时，只有该模板 fallback 到内置模板，其他合法模板继续生效。
- 修改模板后需要重启 Gateway 或重新加载 GCM service plugin，才能让 `on_plugin_load` 重新读取模板。

## 相关配置入口

同一组 GitCode review 运行配置还包括：

- `gateway.gitcodeReview.prReviewAdapter`：外部 PR review engine adapter 配置。测试阶段通过 mock 注入，不应在生产配置中启用 mock。
- `gateway.gitcodeReview.promptTemplates`：GitCode review prompt 模板目录配置，默认 `~/.metis/gitcodemonitor/prompt`，在插件加载时读取。
