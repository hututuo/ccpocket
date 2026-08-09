import assert from "node:assert/strict";
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
