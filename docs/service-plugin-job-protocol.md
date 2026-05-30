# Metis Service Plugin Job Protocol

This document defines the async job contract used when a service plugin action
outlives a single synchronous request/response window.

## Lifecycle

The lifecycle is:

```text
accepted -> running -> progress* -> completed|failed|cancelled|expired
```

Metis waits only for `accepted`. Completion, failure, cancellation, and progress
arrive as `event` frames.

## Job Start Payload

The request payload is a JSON object with:

- `mode`: must be `async` for production long-running work.
- `jobId`: Metis-generated, unique, non-secret, at most 128 bytes.
- `idempotencyKey`: stable key for duplicate IM deliveries.
- `requestedBy`: redacted requester summary.
- `deliveryTarget`: internal target used by Metis to notify the original IM
  conversation. `peerId` is internal-only and must not be logged or shown to
  users.
- `limits`: bounded scan controls. Zero means no explicit limit.
- `options`: plugin-specific booleans such as `dryRun` and `offlineFixture`.

Unknown fields are allowed, but required fields must have the documented type.

## Accepted Response

The plugin must return quickly:

```json
{"ok":true,"status":"accepted","mode":"async","jobId":"gcm-scan-20260530-095017-0001","alreadyRunning":false}
```

`accepted` means the plugin accepted the job start request. It does not mean the
scan has completed.

## Event Payloads

Event payloads are JSON objects with `ok`, `status`, and `jobId`. Status must be
one of `progress`, `completed`, `failed`, `cancelled`, or `expired`.

Capability and status must agree:

- `gitcode.monitor.scan_progress` uses `status: "progress"`.
- `gitcode.monitor.scan_completed` uses `status: "completed"`.
- `gitcode.monitor.scan_failed` uses `status: "failed"`.
- `gitcode.monitor.scan_cancelled` uses `status: "cancelled"`.

Metis rejects events for unknown jobs, mismatched capabilities, invalid payloads,
or oversized diagnostics. Duplicate terminal events for a delivered job are
idempotent and must not deliver a second IM message.

## Error Codes

- `job_payload_invalid`: payload is not an object, has wrong field types, or
  contains oversized fields.
- `job_already_running`: the same idempotency key or job id is already active.
- `job_rejected`: plugin policy rejected the job.
- `job_not_found`: status/cancel referenced an unknown job.
- `job_cancelled`: job was cancelled.
- `job_timeout`: job exceeded its runtime budget.
- `job_failed`: plugin execution failed.
- `event_delivery_failed`: Metis could not deliver a terminal notification.

Default user-facing output must be human-readable and must not echo raw JSON.

## Redaction And Recovery

Metis stores enough delivery target state to deliver terminal events, but logs
and user output must use hashes or length summaries for `peerId`, `senderId`,
credentials, and local filesystem paths.

If Metis restarts, unfinished jobs may be loaded from a controlled Metis state
file and marked `recovering`. Metis should query `gitcode.monitor.job_status` to
resolve each recovering job. Tests must use temporary paths and must not access
real `~/.metis`, Telegram, Feishu, GitCode, or GCM credentials.
