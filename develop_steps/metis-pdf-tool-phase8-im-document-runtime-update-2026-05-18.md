# Metis PDF Tool Phase 8 IM Document Runtime Update

日期：2026-05-18

## 实施结论

Phase 8 的实际接入点保持在 `src/core/gateway_media_understanding_runtime.cj`，没有把 PDF 解析逻辑复制到 Telegram adapter/toolset。Telegram `document_extract` 仍调用 `gatewayMediaUnderstandingForRecord(... capability:"document")`，PDF 命中后由 shared gateway PDF runtime hook 接管。

本阶段只落窄接口，不实现 PDF loader/model runner internals：

- PDF 判定：`mimeType` 包含/等于 PDF、`fileName` 以 `.pdf` 结尾、或本地文件 magic bytes 为 `%PDF-`。
- Runtime hook：`setGatewayMediaPdfRuntimeForTest` 覆盖 `gatewayMediaAnalyzePdfPathForRuntime`。默认返回 `not_configured`，提示配置 `agents.defaults.pdfModel` 或 image model。
- 错误传播：PDF runtime 的 `provider_error`、`timeout`、`too_large`、`unsupported` 会直接成为 document understanding status，不再落到 `metadata_only`。
- 兼容性差异：当 PDF runtime 只是 `not_configured` 时，保留既有 native document extractor 和 `.extract.txt` companion fallback；只有无 fallback 时才返回 PDF-specific `not_configured`。这样既满足 PDF 未配置不静默 metadata_only，也不破坏已有手工抽取文件路径。

## Feishu / QQ 复用点

当前 Feishu media toolset 只提供资源 fetch/staging，未发现同构的 document_extract tool；QQ 当前没有独立 media toolset。后续 Feishu/QQ 若新增 document extract，只应把 staged media record 交给 `gatewayMediaUnderstandingForRecord(... capability:"document")`，复用同一个 PDF runtime hook。

## 手工验收更新

| 编号 | 验收条目 | 操作方法 | 验收标准 |
| --- | --- | --- | --- |
| P8-01 | Telegram PDF runtime 成功 | 使用 fake/local PDF runtime 或已配置 PDF model；发送 PDF 后调用 `telegram_document_extract`。 | 返回 `status=ok`、`readable=true`，`outputs[].source=gateway_pdf_runtime`，内容为 PDF 分析文本。 |
| P8-02 | PDF provider error | 使用 fake provider 返回 401/密钥相关错误。 | 返回 `status=provider_error`、`documentExtractStatus=provider_error`；输出中不包含 Bearer token、api_key、token 等秘密；不返回 `metadata_only`。 |
| P8-03 | PDF runtime 未配置 | 无 PDF/image model，发送无 companion 的 PDF。 | 返回 `status=not_configured`、`readable=false`，reason 指向 `agents.defaults.pdfModel` 或 image model 配置；不返回 `metadata_only`。 |
| P8-04 | 旧 companion 兼容 | PDF 旁边存在 `.extract.txt`，PDF runtime 未配置。 | 仍返回 `status=ok` 和 companion 文本，避免破坏已有离线抽取工作流。 |
| P8-05 | Feishu/QQ 预留 | 检查 Feishu/QQ 后续 document extract 设计。 | 不在 channel adapter/toolset 复制 PDF 解析；统一复用 gateway media understanding runtime。 |

