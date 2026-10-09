# IstrolidR: native private server and security lab

**Native Istrolid root and ZJson battle transport are implemented.** The recovered 2023 client and native test server now agree on the binary encoding, packet dictionary, root JSON message shapes, gameKey exchange and lobby snapshots.

**Important:** gameplay is still incomplete: this is a real native-protocol **lobby**, not yet a fully playable, authoritative combat server. Commands that require ship simulation are not applied. Do not mistake a successful connection for complete multiplayer support.

## Start a native Istrolid private test server

1. Install the official Istrolid client and Node.js 20+.
2. Double-click **Run-Security-Lab.cmd** from the repository root. It uses Build-Only.cmd to extract the locally installed client's exact ZJson word table and launches the native test server on 127.0.0.1:8765.
3. Double-click **Run-Private-Client.cmd** to start an isolated client with rootAddress set to ws://127.0.0.1:8765/root and the room set to IstrolidR Test Room.
4. Custom local plugin: Run-Security-Lab.cmd --plugin deny-move-orders.mjs
5. Run-Security-Tests.cmd to exercise golden client wire packets, fake game keys, malformed inputs and existing security harness regressions.

The client saves to a separate private development profile, with production HTTP and WebSocket requests blocked. **Start the test server before launching the private client.** Keep the test service bound to localhost.

The original JSON-only test harness remains available with **Run-JSON-Test-Lab.cmd** and uses the separate lab-v1 protocol described below.

## Protocol status

| Feature | Status |
|---|---|
| Binary ZJson encode/decode, common strings and END framing | Implemented, tested against original client bytes |
| Original client RootConnection JSON message names | Implemented for room discovery, gameKey and local guest login |
| Original client Connection playerJoin and gameKey | Implemented with session/key validation |
| Binary snapshot format and team selection | Implemented |
| Separate local session and guest profile | Implemented |
| Original server's authoritative Sim / ship build / combat | Not yet implemented |
| Original game's full account services and public matchmaking | Not implemented |
| TLS, hardened public dedicated server | Not implemented (localhost-only) |

Every word-table string is loaded **locally** from your own app archive. No proprietary game code or assets are uploaded to the repository.

## Security testing

The native service rejects malformed ZJson packets, invalid game keys, unauthenticated battle commands, excessive message rates and unauthorized room configuration. It supports operator-installed trusted JavaScript plugins that can inspect/reject allowed game commands. Plugin workers are **not** an OS sandbox; never execute unknown/untrusted plugins. No remotely submitted JavaScript is executed.

See [the repository research roadmap](../docs/SYSTEMS.md) and [issue #5](https://github.com/tndmadman/istrolidr/issues/5) for work toward a complete authoritative battle simulation.

---

## Legacy JSON-only protocol test harness


## Quick start (Windows)

1. Install Node.js 20+.
2. Double-click **Run-JSON-Test-Lab.cmd** in the repository root. It installs the pinned WebSocket dependency on first launch.
3. By default, the server binds to 127.0.0.1:8765 and prints a random player token in your local console.
4. Double-click **Run-Security-Tests.cmd** to run the input-validation and abuse-regression tests.
5. Logs appear under security-lab/.build/audit.jsonl (Git-ignored).

## Write custom server code

Create security-lab/plugins/my-check.mjs exporting a function named onCommand(event). Enable it explicitly:

    Run-JSON-Test-Lab.cmd --plugin my-check.mjs

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
