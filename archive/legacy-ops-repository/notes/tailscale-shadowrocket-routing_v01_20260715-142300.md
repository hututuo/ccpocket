# ccPocket via Shadowrocket Tailscale routing

Status: `root-cause-confirmed; client fix pending validation`

## Confirmed live evidence

- ccPocket Bridge 1.65.0 is listening on `*:8765`.
- The Mac Tailscale address is `100.105.41.82`.
- A real WebSocket handshake to `ws://100.105.41.82:8765` returned `101 Switching Protocols` and the Bridge returned its session list.
- The currently established ccPocket connection reached the Bridge from `100.78.215.62`, the iPhone's official Tailscale App node.
- Shadowrocket's embedded Tailscale node is `100.104.72.123`; Mac-to-node Tailscale ping and ordinary ICMP ping both succeeded.
- Shadowrocket showed the Mac peer with RTT, proving its embedded module control/data probe could reach the Mac, but no ccPocket WebSocket connection from `100.104.72.123` was observed.
- The user's active Shadowrocket configuration explicitly placed `100.64.0.0/10` in both `bypass-tun` and `skip-proxy`, while later rules attempted to send the same range to `TAILSCALE`.

## Interpretation

- Safari cannot be used by navigating directly to a `ws://` URL; the displayed iOS device-access restriction is a URL-scheme/navigation issue, not proof that the Tailnet path is blocked.
- `http://100.105.41.82:8765/` is only a transport probe and intentionally returns `404 Not Found`; ccPocket itself must use the WebSocket endpoint.
- For Shadowrocket, a peer RTT does not prove arbitrary app TCP/WebSocket traffic is assigned to the Tailscale policy. In the supplied configuration, `bypass-tun` excluded the Tailscale CGNAT range before the rule engine could match it; this directly explains why no request appeared in Shadowrocket's logs.
- Do not substitute `DIRECT` for `TAILSCALE` in this ccPocket test. The earlier `DIRECT` suggestion came from a third-party guide and did not match the observed policy boundary.

## Candidate client rule pending user validation

Remove `100.64.0.0/10` from both `bypass-tun` and `skip-proxy`. Place these above LAN/proxy/final catch-all rules, remove any conflicting or duplicate rule for the same range, reload the Shadowrocket tunnel, then reconnect ccPocket:

```text
IP-CIDR,100.64.0.0/10,TAILSCALE,no-resolve
DOMAIN-SUFFIX,ts.net,TAILSCALE
```

Also ensure Shadowrocket's excluded routes do not contain `100.64.0.0/10`.

The line `DOMAIN,100.105.41.82,TAILSCALE` is invalid for an IP literal and should be removed; the IPv4 CIDR rule already covers the Mac address.
