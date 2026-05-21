import assert from "node:assert/strict";
import test from "node:test";

import {
  buildEventFrame,
  buildRuntimeConfig,
  parseArgs,
  startWsClientWithReadiness,
} from "./feishu-ws-sidecar.mjs";

test("parseArgs accepts explicit Feishu account id", () => {
  const args = parseArgs([
    "--account-id",
    "feishu-writer",
    "--app-id",
    "cli_writer_app",
    "positional",
  ]);

  assert.equal(args["account-id"], "feishu-writer");
  assert.equal(args["app-id"], "cli_writer_app");
  assert.deepEqual(args._, ["positional"]);
});

test("buildEventFrame injects Metis account id and preserves SDK event fields", () => {
  const sdkEvent = {
    tenant_key: "2d310bf3d74f575e",
    app_id: "cli_writer_app",
    message: { message_id: "om_1" },
  };

  const frame = buildEventFrame("im.message.receive_v1", sdkEvent, "feishu-writer");

  assert.equal(frame.type, "event");
  assert.equal(frame.payload.header.event_type, "im.message.receive_v1");
  assert.equal(frame.payload.header.account_id, "feishu-writer");
  assert.equal(frame.payload.event.tenant_key, "2d310bf3d74f575e");
  assert.equal(frame.payload.event.app_id, "cli_writer_app");
});

test("buildEventFrame keeps legacy envelope shape when account id is absent", () => {
  const frame = buildEventFrame("im.message.receive_v1", { app_id: "cli_app" }, "");

  assert.equal(Object.hasOwn(frame.payload.header, "account_id"), false);
  assert.equal(frame.payload.event.app_id, "cli_app");
});

test("runtime config requires sidecar secrets from stdin init frame instead of argv", () => {
  assert.throws(
    () =>
      buildRuntimeConfig(
        parseArgs([
          "--app-id",
          "cli_writer_app",
          "--app-secret",
          "argv-secret-never-allowed",
          "--verification-token",
          "argv-token-never-allowed",
          "--encrypt-key",
          "argv-key-never-allowed",
        ]),
        { type: "init", appSecret: "stdin-secret", verificationToken: "stdin-token", encryptKey: "stdin-key" },
      ),
    /secret argv flags are not supported/,
  );

  const config = buildRuntimeConfig(
    parseArgs(["--account-id", "feishu-writer", "--app-id", "cli_writer_app", "--domain", "feishu"]),
    { type: "init", appSecret: "stdin-secret", verificationToken: "stdin-token", encryptKey: "stdin-key" },
  );

  assert.equal(config.appId, "cli_writer_app");
  assert.equal(config.appSecret, "stdin-secret");
  assert.equal(config.verificationToken, "stdin-token");
  assert.equal(config.encryptKey, "stdin-key");
  assert.equal(config.accountId, "feishu-writer");
});

test("wsClient readiness resolves only after SDK start resolves", async () => {
  let started = false;
  const wsClient = {
    async start() {
      await new Promise((resolve) => setTimeout(resolve, 20));
      started = true;
    },
  };

  await startWsClientWithReadiness(wsClient, { eventDispatcher: {} }, { timeoutMs: 200 });

  assert.equal(started, true);
});

test("wsClient readiness reports start errors", async () => {
  const wsClient = {
    async start() {
      throw new Error("synthetic start failure");
    },
  };

  await assert.rejects(
    () => startWsClientWithReadiness(wsClient, { eventDispatcher: {} }, { timeoutMs: 200 }),
    /synthetic start failure/,
  );
});

test("wsClient readiness times out when SDK start never resolves", async () => {
  const wsClient = {
    start() {
      return new Promise(() => {});
    },
  };

  await assert.rejects(
    () => startWsClientWithReadiness(wsClient, { eventDispatcher: {} }, { timeoutMs: 30 }),
    /starting-timeout/,
  );
});
