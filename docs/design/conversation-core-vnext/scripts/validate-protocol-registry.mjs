#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const registry = JSON.parse(
  readFileSync(resolve(root, "protocol-registry.v1.json"), "utf8"),
);
const readme = readFileSync(resolve(root, "README.md"), "utf8");
const protocolDoc = readFileSync(resolve(root, "05-protocol-registry.md"), "utf8");

const failures = [];
const fail = (message) => failures.push(message);
const messages = Array.isArray(registry.messages) ? registry.messages : [];
const byType = new Map();
const typePattern = /^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$/;

if (registry.status !== "draft_architecture_baseline" &&
    registry.status !== "implementation_ready") {
  fail(`invalid registry status: ${registry.status}`);
}

for (const message of messages) {
  if (!typePattern.test(message.type ?? "")) {
    fail(`invalid message type: ${message.type}`);
  }
  if (byType.has(message.type)) {
    fail(`duplicate message type: ${message.type}`);
  }
  byType.set(message.type, message);

  if (!Number.isInteger(message.featureMajor) || message.featureMajor < 1) {
    fail(`${message.type}: invalid featureMajor`);
  }
  if (!Number.isInteger(message.featureMinor) || message.featureMinor < 0) {
    fail(`${message.type}: invalid featureMinor`);
  }
  if (!Array.isArray(message.requiredPayload) ||
      new Set(message.requiredPayload).size !== message.requiredPayload.length) {
    fail(`${message.type}: invalid or duplicate requiredPayload`);
  }
  if ((message.kind === "request" || message.kind === "handshake") &&
      !Array.isArray(message.responseTypes)) {
    fail(`${message.type}: request/handshake lacks responseTypes`);
  }
  if (message.kind === "mutation") {
    if (!message.requiredPayload?.includes("header")) {
      fail(`${message.type}: mutation lacks OperationHeader`);
    }
    if (message.operationPolicy !== message.delivery) {
      fail(`${message.type}: operationPolicy differs from delivery`);
    }
    if (!Array.isArray(message.responseTypes) || message.responseTypes.length === 0) {
      fail(`${message.type}: mutation lacks correlated terminal response`);
    }
  }
  if (message.kind === "request" && message.responseTypes?.includes("operation.result")) {
    fail(`${message.type}: non-mutation request reuses operation.result`);
  }
}

for (const message of messages) {
  for (const responseType of message.responseTypes ?? []) {
    const response = byType.get(responseType);
    if (!response) {
      fail(`${message.type}: missing response type ${responseType}`);
    } else if (response.direction !== "server_to_client") {
      fail(`${message.type}: response ${responseType} has wrong direction`);
    }
  }
}

const subscriptions = new Map([
  ["catalog.subscribe", "sync.unsubscribe"],
  ["timeline.subscribe", "sync.unsubscribe"],
  ["interaction.watch", "interaction.unwatch"],
  ["subagents.watch", "subagents.unwatch"],
  ["mirror.subscribe", "mirror.unsubscribe"],
]);
for (const [start, stop] of subscriptions) {
  if (byType.get(start)?.delivery !== "subscription") {
    fail(`${start}: missing subscription declaration`);
  }
  if (!byType.has(stop)) {
    fail(`${start}: missing cleanup request ${stop}`);
  }
}

for (const type of ["catalog.subscribe", "timeline.subscribe"]) {
  const responses = new Set(byType.get(type)?.responseTypes ?? []);
  if (!responses.has("sync.begin") || !responses.has("sync.complete")) {
    fail(`${type}: lacks sync.begin/sync.complete batch boundaries`);
  }
}
for (const type of ["sync.begin", "sync.complete", "sync.resync_required", "sync.ack", "flow.ack"]) {
  if (byType.get(type)?.targetScope !== "sync_scope") {
    fail(`${type}: must accept source-or-thread SyncScope`);
  }
}
for (const [type, fields] of new Map([
  ["timeline.gap", ["meta", "reason", "gap", "repairCursor", "retryClass"]],
  ["sync.complete", ["meta", "windowComplete", "latestTurnComplete", "latestTurnGap", "checkpoint"]],
  ["sync.resync_required", ["subscriptionId", "scope", "reason", "expectedRevision"]],
  ["content.cancelled", ["offerId", "releasedBytes", "leaseState"]],
  ["input_payload.release", ["uploadId", "payloadId"]],
  ["input_payload.released", ["uploadId", "payloadId", "outcome"]],
])) {
  const actual = new Set(byType.get(type)?.requiredPayload ?? []);
  for (const field of fields) {
    if (!actual.has(field)) fail(`${type}: missing required payload field ${field}`);
  }
}
const mirrorResponses = new Set(byType.get("mirror.subscribe")?.responseTypes ?? []);
for (const type of ["mirror.begin", "mirror.snapshot", "mirror.patch", "mirror.complete", "mirror.status"]) {
  if (!mirrorResponses.has(type)) fail(`mirror.subscribe: lacks response ${type}`);
}
for (const type of ["mirror.begin", "mirror.snapshot", "mirror.patch", "mirror.complete"]) {
  if (!byType.get(type)?.requiredPayload?.includes("meta")) {
    fail(`${type}: durable Mirror frame lacks MirrorFrameMeta`);
  }
}
if (!byType.has("mirror.ack") || byType.get("mirror.ack")?.kind !== "ack") {
  fail("mirror.subscribe: lacks dedicated durable ACK");
}
for (const type of ["turn.input.admitted", "turn.input.state"]) {
  if (byType.get(type)?.targetScope !== "input_intent") {
    fail(`${type}: direct/queued receipt must use input_intent scope`);
  }
}

const countMatch = readme.match(/([0-9]+) 个消息类型/);
if (!countMatch || Number(countMatch[1]) !== messages.length) {
  fail(`README message count does not match registry (${messages.length})`);
}

const proseTypes = new Set(
  [...protocolDoc.matchAll(/`([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+)`/g)]
    .map((match) => match[1])
    .filter((value) =>
      !value.startsWith("ccpocket.") &&
      !value.endsWith(".*") &&
      !value.endsWith(".ts") &&
      !value.includes("_v1") &&
      !value.includes("_v2") &&
      value !== "interaction.respond.response.kind" &&
      value !== "plan.toggle"),
);
for (const type of proseTypes) {
  if (!byType.has(type)) {
    fail(`protocol prose references unregistered message: ${type}`);
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure);
  process.exitCode = 1;
} else {
  console.log(
    `protocol registry ok: ${messages.length} messages, ` +
      `${new Set(messages.map((message) => message.featureId)).size} features`,
  );
}
