# Metis Service Plugin Stdio Protocol

This document defines the stdio contract between Metis and service plugin
processes. The host treats every plugin as untrusted input, including plugins
that are normally shipped by a known project.

## Streams

`stdin` is written by Metis. Each line is one UTF-8 JSON object service frame
terminated by `\n`. A frame payload can contain escaped newlines inside JSON
strings, but a single frame must not span multiple stdout or stdin lines.

`stdout` is written by the plugin and must be frame-only while Metis manages the
process. Logs, warnings, wrapper output, command output, and diagnostics are not
service frames. The host isolates bounded stdout noise and never echoes raw
plugin stdout to CLI or IM users.

`stderr` is for plugin logs and diagnostics. Metis may store redacted stderr
summaries in runtime diagnostics, but default user-facing command output must be
human-readable and must not display raw JSON, credentials, or local paths.

## Frame Schema

Current schema: `metis.servicePlugin.v1`

Current protocol version: `1.0`

Allowed frame types:

- `request`
- `response`
- `event`
- `audit`
- `heartbeat`

Allowed methods:

- `initialize`
- `registerCapabilities`
- `invokeCapability`
- `emitCapabilityEvent`
- `requestHostApi`
- `status`
- `stop`
- `heartbeat`
- `audit`

Required fields for every frame:

- `type`: string, one of the allowed frame types.
- `frameId`: non-empty string.
- `serviceId`: non-empty string matching the manifest `pluginId`.

Required fields for an invoke response:

- `type`: `response`
- `method`: `invokeCapability`
- `serviceId`: the expected service id.
- `capabilityId`: the requested capability id.
- `correlationId`: the request correlation id.
- `payload`: a JSON object.

Example initialize response:

```json
{"type":"response","frameId":"initialize","serviceId":"gitcode-monitor","method":"initialize","payload":{"ok":true,"status":"ok","capabilities":8}}
```

Example invoke response:

```json
{"type":"response","frameId":"response-scan-1","serviceId":"gitcode-monitor","method":"invokeCapability","capabilityId":"gitcode.monitor.scan_once","correlationId":"corr-scan-1","payload":{"ok":true,"status":"ok","accepted":0,"ignored":0,"emitted":0,"stateSaved":true}}
```

## Sync RPC Boundary

Synchronous `invokeCapability` is only for short control actions whose response
is the final result. It must not be used to hold an IM request open while a
long-running external scan, polling loop, or writeback workflow completes.

Long-running work must use the service plugin job protocol:

1. Metis invokes the capability with an async job start payload.
2. The plugin responds quickly with `status: "accepted"` and a `jobId`.
3. Later lifecycle updates are emitted as `event` frames and delivered by Metis
   through the recorded delivery target.

For GitCodeMonitor, `gitcode.monitor.scan_once` is an async job start. The
accepted response confirms only that GCM accepted the job; it is not a completed
scan result.

## Payload Status

New response payloads must be JSON objects. They must include:

- `ok`: boolean.
- `status`: string.

Failure payloads may include `diagnostic`, which must be a string no larger than
4096 bytes before redaction. Unknown fields are allowed when total payload size
is within the host limit.

## Defensive Host Reading

The host reads stdout with a bounded expected-frame policy. It may skip a small
amount of non-frame stdout before the expected response, but events, audit
frames, heartbeat frames, malformed frames, or responses for another request
cannot satisfy a request.

Default statuses:

- `stdout_protocol_noise`: stdout noise was isolated but a matching response was
  eventually found.
- `stdout_protocol_violation`: stdout noise exceeded the host budget or the
  stream contained unrecoverable protocol contamination.
- `unexpected_frame`: a valid service frame was received but it was not allowed
  for the current request.
- `frame_decode_failed`: a JSON-looking frame could not be decoded.
- `payload_invalid`: a response payload failed schema validation.

## Redaction

Before diagnostics are stored or displayed, Metis redacts secrets and local
paths. Redaction must cover authorization headers, bearer values, cookies,
tokens, passwords, and local filesystem paths. Diagnostic records should include
a stable hash or size summary instead of raw hostile stdout when possible.

Default CLI and IM command outputs must be human-readable and must not display
raw JSON object keys such as `"ok"`, `"status"`, `"image"`, `"schedule"`, or
`"sessions"` unless an explicit machine-output mode requested JSON.
