# IstrolidR Server Security Lab

A local test server for developing custom server-side security checks against **servers you control**. This is not a playable Istrolid dedicated server: the lab currently speaks its own JSON protocol (lab-v1), **not** the original game's zJson binary protocol. The original game client will not connect to this server unchanged.

## Quick start (Windows)

1. Install Node.js 20+.
2. Double-click **Run-Security-Lab.cmd** in the repository root. It installs the pinned WebSocket dependency on first launch.
3. By default, the server binds to 127.0.0.1:8765 and prints a random player token in your local console.
4. Double-click **Run-Security-Tests.cmd** to run the input-validation and abuse-regression tests.
5. Logs appear under security-lab/.build/audit.jsonl (Git-ignored).

## Write custom server code

Create security-lab/plugins/my-check.mjs exporting a function named onCommand(event). Enable it explicitly:

    Run-Security-Lab.cmd --plugin my-check.mjs

The example plugin, security-lab/plugins/deny-unit-13.mjs, denies the fire command from test unit 13.

The plugin receives a copied event containing session role, session ID and validated command details. It can return an object with reject:true and a reason string, or tags: an array of short labels for accepted commands. A plugin exception, invalid response, or timeout rejects the command. An operator can load multiple plugins with repeated --plugin flags.

**Security boundary:** plugins are trusted server code installed by the operator, never supplied by clients. Worker threads prevent an accidental infinite loop from freezing the primary server, but are NOT a secure isolation boundary against malicious Node.js plugins. Do not run untrusted plugins outside a restricted VM/container.

## Test protocol

Connect to ws://127.0.0.1:8765/lab and send these individual JSON WebSocket frames:

1. Authenticate: {"type":"hello","version":"lab-v1","token":"TOKEN_FROM_CONSOLE"}
2. Join: {"type":"join","room":"sandbox"}
3. Issue a command: {"type":"command","seq":1,"name":"move","args":{"unitId":1,"x":0,"y":10}}

Other commands: fire (unitId, targetId); setMatchFlags (friendlyFire:boolean, requires tester role). Enable tester role using a distinct environment variable ISTROLIDR_TEST_ADMIN_TOKEN of at least 24 characters. The default player token can be supplied as ISTROLIDR_TEST_TOKEN.

Acknowledgments contain simulated:false. **No combat simulation has been wired in yet.** This is a protocol/security harness, not a game server.

## Defenses and diagnostics

- Binds to localhost by default, and refuses LAN/public binding without --allow-lan. LAN requires an operator-configured token. Do not expose this lab to the public internet.
- Strong separate player/tester tokens; timing-safe token comparisons. Plain ws:// is unencrypted: use a VPN/TLS proxy for any remote lab network.
- Authentication before commands; player/tester role checks; join requirement; strict command envelope/argument schemas; sequence/replay checks.
- 16 KiB message limit, ~30 messages per second, 16 active connections, four connections per IP, bounded message-processing queue, 5-second authentication timeout.
- Separate worker per opted-in test plugin with 250-ms command deadline; failing checks reject the request.
- JSONL audit log contains timestamps, event types and sanitized session IDs/roles/codes. Tokens, full payloads and IPs are never written to the audit log.
- Automated Windows and Linux tests validate malformed frames, oversized data, role checks, replay, plugin policy and rejected invalid input.

## Roadmap

1. Fuzz the lab's envelope and command validation with seeded test cases and regression fixtures.
2. Implement and test an original zJson decoder in a separate adapter with strict resource bounds; never target original production servers.
3. Adapt the recovered local Sim implementation to authoritative server state, with per-player ownership checks.
4. Add two-client synchronization tests, audit trails, and isolated LAN deployment.
5. Only once compatibility is demonstrated, optionally add original-client packet handling against test servers we operate.

This module intentionally performs no requests to root.istrolid.com or production battle servers.
