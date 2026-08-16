#!/usr/bin/env node

import http from "node:http";
import net from "node:net";
import { createHash, timingSafeEqual } from "node:crypto";
import { networkInterfaces } from "node:os";
import { pathToFileURL } from "node:url";

const configuredListenHost =
  process.env.CCPOCKET_LAN_PROXY_HOST?.trim() || "auto";
const listenInterface =
  process.env.CCPOCKET_LAN_PROXY_INTERFACE?.trim() || "en0";
const listenPort = Number(process.env.CCPOCKET_LAN_PROXY_PORT ?? "8765");
const upstreamHost =
  process.env.CCPOCKET_LAN_PROXY_UPSTREAM_HOST ?? "127.0.0.1";
const upstreamPort = Number(
  process.env.CCPOCKET_LAN_PROXY_UPSTREAM_PORT ?? "8765",
);
const expectedTokenDigest = process.env.CCPOCKET_LAN_PROXY_TOKEN_SHA256
  ?.trim()
  .toLowerCase();
const rebindIntervalMs = Number(
  process.env.CCPOCKET_LAN_PROXY_REBIND_INTERVAL_MS ?? "5000",
);
const rebindConfirmationCount = Number(
  process.env.CCPOCKET_LAN_PROXY_REBIND_CONFIRMATIONS ?? "2",
);

if (
  !Number.isInteger(listenPort) ||
  listenPort < 1 ||
  listenPort > 65535 ||
  !Number.isInteger(upstreamPort) ||
  upstreamPort < 1 ||
  upstreamPort > 65535 ||
  !Number.isInteger(rebindIntervalMs) ||
  rebindIntervalMs < 1000 ||
  !Number.isInteger(rebindConfirmationCount) ||
  rebindConfirmationCount < 1
) {
  throw new Error(
    "LAN proxy ports, rebind interval, and confirmation count are invalid",
  );
}
if (expectedTokenDigest && !/^[a-f0-9]{64}$/.test(expectedTokenDigest)) {
  throw new Error("LAN proxy token digest must be a SHA-256 hex value");
}

export function isPrivateLanIpv4(address) {
  if (net.isIPv4(address) === 0) return false;
  const [a, b] = address.split(".").map(Number);
  return (
    a === 10 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 169 && b === 254)
  );
}

export function selectLanIpv4(
  interfaces,
  preferredInterface = "en0",
) {
  // A configured LAN interface is an authority boundary, not a preference.
  // Falling back to another private-looking interface can publish a VM,
  // container, hotspot or VPN address and repeatedly tear down the real Wi-Fi
  // listener while macOS refreshes its interface list. If the interface is
  // temporarily unavailable, wait for it to return instead.
  const candidates = interfaces[preferredInterface] ?? [];
  for (const entry of candidates) {
    const family = entry?.family;
    if (
      (family === "IPv4" || family === 4) &&
      entry.internal !== true &&
      typeof entry.address === "string" &&
      isPrivateLanIpv4(entry.address)
    ) {
      return entry.address;
    }
  }
  return undefined;
}

export function advanceLanRebindCandidate({
  boundHost,
  desiredHost,
  candidateHost,
  candidateObservations = 0,
  requiredObservations = 2,
}) {
  if (!desiredHost || desiredHost === boundHost) {
    return {
      candidateHost: undefined,
      candidateObservations: 0,
      confirmedHost: undefined,
    };
  }
  const nextObservations =
    candidateHost === desiredHost ? candidateObservations + 1 : 1;
  return {
    candidateHost: desiredHost,
    candidateObservations: nextObservations,
    confirmedHost:
      nextObservations >= requiredObservations ? desiredHost : undefined,
  };
}

export function destroyLanProxyTunnels(tunnels) {
  let destroyed = 0;
  for (const [id, tunnel] of [...tunnels]) {
    tunnels.delete(id);
    destroyed += 1;
    tunnel.clientSocket.destroy();
    tunnel.upstreamSocket.destroy();
  }
  return destroyed;
}

function logInfo(message) {
  console.log(`${new Date().toISOString()} ${message}`);
}

function logError(message) {
  console.error(`${new Date().toISOString()} ${message}`);
}

function desiredListenHost() {
  if (configuredListenHost !== "auto") {
    if (!isPrivateLanIpv4(configuredListenHost)) {
      throw new Error(
        "LAN proxy fixed host must be a private, non-loopback IPv4 address",
      );
    }
    return configuredListenHost;
  }
  return selectLanIpv4(networkInterfaces(), listenInterface);
}

function websocketCredentialStatus(req) {
  let token;
  try {
    token = new URL(req.url ?? "/", "http://bridge.invalid").searchParams.get(
      "token",
    );
  } catch {
    return { status: "malformed", length: 0 };
  }
  if (!token) return { status: "missing", length: 0 };
  if (!expectedTokenDigest) {
    return { status: "unchecked", length: token.length };
  }
  const actual = createHash("sha256").update(token, "utf8").digest();
  const expected = Buffer.from(expectedTokenDigest, "hex");
  return {
    status: timingSafeEqual(actual, expected) ? "match" : "mismatch",
    length: token.length,
  };
}

function forwardedHeaders(req) {
  const headers = { ...req.headers };
  delete headers.forwarded;
  delete headers["x-forwarded-for"];
  delete headers["x-forwarded-host"];
  delete headers["x-forwarded-proto"];
  headers.host = `${upstreamHost}:${upstreamPort}`;
  headers["x-forwarded-for"] = req.socket.remoteAddress ?? "unknown";
  headers["x-forwarded-host"] = req.headers.host ?? "unknown";
  headers["x-forwarded-proto"] = "http";
  return headers;
}

const server = http.createServer((req, res) => {
  const requestPath = (() => {
    try {
      return new URL(req.url ?? "/", "http://bridge.invalid").pathname;
    } catch {
      return undefined;
    }
  })();
  const logsReadinessProbe =
    requestPath === "/health" || requestPath === "/readyz";
  const peer = req.socket.remoteAddress ?? "unknown";
  const upstream = http.request(
    {
      host: upstreamHost,
      port: upstreamPort,
      method: req.method,
      path: req.url,
      headers: forwardedHeaders(req),
    },
    (upstreamResponse) => {
      if (logsReadinessProbe) {
        logInfo(
          `[lan-proxy] HTTP ${requestPath} status=${upstreamResponse.statusCode ?? "unknown"} peer=${peer}`,
        );
      }
      res.writeHead(
        upstreamResponse.statusCode ?? 502,
        upstreamResponse.statusMessage,
        upstreamResponse.headers,
      );
      upstreamResponse.pipe(res);
    },
  );

  upstream.on("error", (error) => {
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json" });
    }
    res.end(JSON.stringify({ error: "Bridge unavailable" }));
    if (logsReadinessProbe) {
      logError(
        `[lan-proxy] HTTP ${requestPath} status=upstream_error peer=${peer}`,
      );
    }
    logError(`[lan-proxy] upstream HTTP error: ${error.message}`);
  });
  req.on("aborted", () => upstream.destroy());
  req.pipe(upstream);
});

let nextTunnelId = 0;
const activeTunnels = new Map();

server.on("upgrade", (req, clientSocket, head) => {
  const tunnelId = ++nextTunnelId;
  const credential = websocketCredentialStatus(req);
  logInfo(
    `[lan-proxy] tunnel=${tunnelId} WebSocket credential ${credential.status} length=${credential.length} peer=${req.socket.remoteAddress ?? "unknown"}`,
  );
  if (expectedTokenDigest && credential.status !== "match") {
    clientSocket.end(
      "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
    );
    return;
  }
  const upstreamSocket = net.createConnection(
    { host: upstreamHost, port: upstreamPort },
    () => {
      const headers = forwardedHeaders(req);
      const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
      for (const [name, value] of Object.entries(headers)) {
        if (value === undefined) continue;
        if (Array.isArray(value)) {
          for (const item of value) lines.push(`${name}: ${item}`);
        } else {
          lines.push(`${name}: ${value}`);
        }
      }
      upstreamSocket.write(`${lines.join("\r\n")}\r\n\r\n`);
      if (head.length > 0) upstreamSocket.write(head);
      clientSocket.pipe(upstreamSocket).pipe(clientSocket);
    },
  );

  activeTunnels.set(tunnelId, { clientSocket, upstreamSocket });

  const closeBoth = (error) => {
    if (!activeTunnels.delete(tunnelId)) return;
    if (error) {
      logError(
        `[lan-proxy] tunnel=${tunnelId} WebSocket tunnel error: ${error.code ?? error.message}`,
      );
    }
    clientSocket.destroy();
    upstreamSocket.destroy();
  };
  clientSocket.on("error", closeBoth);
  upstreamSocket.on("error", closeBoth);
  clientSocket.once("close", () => {
    logInfo(`[lan-proxy] tunnel=${tunnelId} client closed`);
    closeBoth();
  });
  upstreamSocket.once("close", () => {
    logInfo(`[lan-proxy] tunnel=${tunnelId} upstream closed`);
    closeBoth();
  });
});

server.on("clientError", (_error, socket) => {
  socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
});

let boundHost;
let binding = false;
let retryTimer;
let unavailableLogged = false;
let shuttingDown = false;
let pendingRebindHost;
let pendingRebindObservations = 0;
let forcedRebindCloseTimer;

function scheduleRetry() {
  if (shuttingDown || retryTimer !== undefined) return;
  retryTimer = setTimeout(() => {
    retryTimer = undefined;
    reconcileBinding();
  }, rebindIntervalMs);
}

function beginListen(host) {
  if (shuttingDown) return;
  binding = true;
  const onError = (error) => {
    server.off("listening", onListening);
    binding = false;
    boundHost = undefined;
    logError(
      `[lan-proxy] unable to listen on ${host}:${listenPort}: ${error.code ?? error.message}`,
    );
    scheduleRetry();
  };
  const onListening = () => {
    server.off("error", onError);
    binding = false;
    boundHost = host;
    unavailableLogged = false;
    logInfo(
      `[lan-proxy] listening on ${host}:${listenPort} -> ${upstreamHost}:${upstreamPort}`,
    );
  };
  server.once("error", onError);
  server.once("listening", onListening);
  server.listen(listenPort, host);
}

function reconcileBinding() {
  if (shuttingDown || binding) return;
  let desired;
  try {
    desired = desiredListenHost();
  } catch (error) {
    logError(`[lan-proxy] invalid listen configuration: ${error.message}`);
    return;
  }
  if (!desired) {
    pendingRebindHost = undefined;
    pendingRebindObservations = 0;
    if (!unavailableLogged) {
      logError(
        `[lan-proxy] no private IPv4 is available on ${listenInterface}; ` +
          (server.listening
            ? `retaining ${boundHost}:${listenPort} while waiting`
            : "waiting"),
      );
      unavailableLogged = true;
    }
    // networkInterfaces() can briefly omit en0 while macOS renews DHCP or
    // switches Wi-Fi state. Closing a healthy listener on one empty sample
    // turns that harmless observation into a guaranteed phone disconnect.
    // Keep the existing listener and its upgraded WebSocket tunnels alive;
    // only a repeatedly observed replacement address is allowed to rebind.
    if (!server.listening) scheduleRetry();
    return;
  }
  unavailableLogged = false;
  if (server.listening && boundHost === desired) {
    pendingRebindHost = undefined;
    pendingRebindObservations = 0;
    return;
  }
  if (server.listening) {
    const observation = advanceLanRebindCandidate({
      boundHost,
      desiredHost: desired,
      candidateHost: pendingRebindHost,
      candidateObservations: pendingRebindObservations,
      requiredObservations: rebindConfirmationCount,
    });
    pendingRebindHost = observation.candidateHost;
    pendingRebindObservations = observation.candidateObservations;
    if (!observation.confirmedHost) {
      logInfo(
        `[lan-proxy] observed candidate LAN address ${desired} ` +
          `(${pendingRebindObservations}/${rebindConfirmationCount}); ` +
          `retaining ${boundHost}:${listenPort}`,
      );
      return;
    }
    const previous = boundHost;
    binding = true;
    const destroyedTunnels = destroyLanProxyTunnels(activeTunnels);
    if (destroyedTunnels > 0) {
      logInfo(
        `[lan-proxy] closing ${destroyedTunnels} tunnel(s) for confirmed ` +
          `LAN address change ${previous} -> ${observation.confirmedHost}`,
      );
    }
    // Upgraded WebSockets are destroyed above. A short bound also prevents a
    // long-lived HTTP request from leaving the proxy closed-but-never-rebound.
    forcedRebindCloseTimer = setTimeout(() => {
      forcedRebindCloseTimer = undefined;
      logError(
        `[lan-proxy] forcing remaining HTTP connections closed during ` +
          `LAN rebind ${previous} -> ${observation.confirmedHost}`,
      );
      server.closeAllConnections?.();
    }, 1_000);
    forcedRebindCloseTimer.unref();
    server.close(() => {
      if (forcedRebindCloseTimer !== undefined) {
        clearTimeout(forcedRebindCloseTimer);
        forcedRebindCloseTimer = undefined;
      }
      binding = false;
      boundHost = undefined;
      pendingRebindHost = undefined;
      pendingRebindObservations = 0;
      logInfo(
        `[lan-proxy] LAN address changed ${previous} -> ${observation.confirmedHost}`,
      );
      beginListen(observation.confirmedHost);
    });
    return;
  }
  beginListen(desired);
}

let monitor;

function shutdown() {
  shuttingDown = true;
  if (monitor !== undefined) clearInterval(monitor);
  if (retryTimer !== undefined) clearTimeout(retryTimer);
  if (forcedRebindCloseTimer !== undefined) clearTimeout(forcedRebindCloseTimer);
  destroyLanProxyTunnels(activeTunnels);
  if (!server.listening) process.exit(0);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}

const isMain =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  monitor = setInterval(reconcileBinding, rebindIntervalMs);
  // Keep the helper alive while en0 temporarily has no usable address or the
  // server is between close() and listen(). If both timers are unref'ed, Node
  // can exit successfully in that gap; LaunchAgent's SuccessfulExit=false
  // then deliberately leaves the LAN route down until a manual restart.
  reconcileBinding();
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
