import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  isPrivateLanIpv4,
  selectLanIpv4,
} from "./ccpocket-bridge-lan-proxy.mjs";

test("accepts private LAN IPv4 ranges but rejects loopback and public IPs", () => {
  for (const address of ["10.1.2.3", "172.16.0.1", "172.31.9.9", "192.168.1.8", "169.254.2.3"]) {
    assert.equal(isPrivateLanIpv4(address), true, address);
  }
  for (const address of ["127.0.0.1", "0.0.0.0", "172.32.0.1", "8.8.8.8", "::1"]) {
    assert.equal(isPrivateLanIpv4(address), false, address);
  }
});

test("prefers the configured interface and ignores internal or public entries", () => {
  const interfaces = {
    en1: [
      { address: "192.168.50.7", family: "IPv4", internal: false },
    ],
    en0: [
      { address: "127.0.0.1", family: "IPv4", internal: true },
      { address: "192.168.124.219", family: "IPv4", internal: false },
    ],
  };
  assert.equal(selectLanIpv4(interfaces, "en0"), "192.168.124.219");
  assert.equal(selectLanIpv4(interfaces, "en1"), "192.168.50.7");
});

test("returns undefined when no private external IPv4 is available", () => {
  assert.equal(
    selectLanIpv4({
      en0: [{ address: "8.8.8.8", family: 4, internal: false }],
      lo0: [{ address: "127.0.0.1", family: 4, internal: true }],
    }),
    undefined,
  );
});

test("does not fall back from the configured LAN interface to a virtual interface", () => {
  const interfaces = {
    en0: [],
    feth4921: [
      { address: "192.168.192.243", family: "IPv4", internal: false },
    ],
    utun0: [
      { address: "10.0.0.8", family: "IPv4", internal: false },
    ],
  };

  assert.equal(selectLanIpv4(interfaces, "en0"), undefined);
});

test(
  "stays alive while the configured interface is temporarily unavailable",
  async () => {
    const helper = new URL("./ccpocket-bridge-lan-proxy.mjs", import.meta.url);
    const child = spawn(process.execPath, [fileURLToPath(helper)], {
      env: {
        ...process.env,
        CCPOCKET_LAN_PROXY_HOST: "auto",
        CCPOCKET_LAN_PROXY_INTERFACE: "ccpocket-test-missing-interface",
        CCPOCKET_LAN_PROXY_PORT: "18771",
        CCPOCKET_LAN_PROXY_UPSTREAM_PORT: "18772",
        CCPOCKET_LAN_PROXY_REBIND_INTERVAL_MS: "1000",
      },
      stdio: ["ignore", "ignore", "pipe"],
    });
    const stderr = [];
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => stderr.push(chunk));

    try {
      await new Promise((resolve) => setTimeout(resolve, 250));
      assert.equal(
        child.exitCode,
        null,
        `helper exited while waiting for en0: ${stderr.join("")}`,
      );
    } finally {
      if (child.exitCode === null) child.kill("SIGTERM");
      if (child.exitCode === null) await once(child, "exit");
    }
  },
);
