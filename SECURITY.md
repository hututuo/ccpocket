# Security Policy

## Supported versions

| Component | Version | Supported |
|-----------|---------|-----------|
| Bridge Server (`@ccpocket/bridge`) | latest | Yes |
| Mobile App | latest | Yes |

## Reporting a vulnerability

If you discover a security vulnerability, **please do not open a public issue**.

Instead, report it privately via [GitHub Security Advisories](https://github.com/K9i-0/ccpocket/security/advisories/new).

Please include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Security considerations

CC Pocket's Bridge Server exposes filesystem operations over WebSocket. Key security measures include:

- **`BRIDGE_ALLOWED_DIRS`**: Restricts which directories can be accessed; defaults to `$HOME` and accepts the exact value `*` only for intentional unrestricted access
- **`BRIDGE_API_KEY`**: Stores the Bridge connection key
- **`BRIDGE_REQUIRE_API_KEY`**: Explicitly enables (`1`) or disables (`0`) connection-key authentication; when unset, legacy installs infer it from whether a key exists. Disabling it on a non-loopback listener intentionally exposes the Bridge to the trusted LAN and also disables owner full-disk read surfaces that require an authenticated phone.
- **Development diagnostics**: `BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS=1` is honored only together with an explicit `BRIDGE_AUTH_MODE=open`. It narrowly permits a user-triggered, sanitized session report and does not authorize ordinary phone-to-Mac uploads. Do not set it on formal, external, or untrusted-network deployments.
- **Path validation**: Unless explicitly unrestricted, all paths are resolved and checked against allowed directories before any operation
- **Network security**: Tailscale or local network recommended for remote access; no data is sent to external servers
- **Credential storage**: API keys and SSH keys are stored using platform-native encrypted storage (iOS Keychain / Android Keystore)
