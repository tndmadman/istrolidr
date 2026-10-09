# Istrolid client systems: static code map

Source: the user's local, extracted `app.asar` with `js/istrolid.cat.js` (35,977 lines, 46 `//from` sections). The line numbers below refer to that **unmodified bundle**, not GitHub files or dynamically rebuilt versions. This is a research map, not a verified server implementation.

## Startup and runtime

1. `game.html` loads `css/style.css`, `js/istrolid.cat.js?r=0.3`, then renders UI through `canvas#webGL`.
2. `src/istrolid.js` defines `window.onload` (original bundle line ~35,914): initializes WebGL, actions, battle/galaxy/designer/fleet/menu modes, the game controller, simulation and interpolator.
3. On load it builds `new RootConnection(rootAddress)` (default `wss://root.istrolid.com`, line ~35,948) **before** launching the local sandbox. Offline gameplay thus still needs a network-isolation change or a failed/optional root connection handled gracefully.
4. `startInitialSandbox()` (~35,842) creates `new Sim()`, sets `serverType = "sandbox"`, `local = true`, starts it and assigns `new Local()`. This is the promising offline starting point.
5. `Control.simInterval()` (~35,785) sends a locally generated snapshot, calls `sim.simulate()` when active, forwards the packet to `Interpolator.recv`, and advances interpolation. This appears to be a 16-Hz simulation loop (confirm runtime timing).

## Mechanics investigation

| Area | Recovered source | Key findings |
| --- | --- | --- |
| Simulation | `src/sim.js` lines ~7,798–9,509 | `Sim.start`, `simulate`, `spacesRebuild`, `victoryConditions`, `send` |
| Ships | `src/unit.js` lines ~11,874–13,668 | `types.Unit.fromSpec` loads parts, accumulates cost / HP / thrust / mass / energy / shields; unit movement, orders and weapon handling |
| Damage | `src/unit.js` lines ~12,173–12,184 | `applyDamage(d)` subtracts shield first and spills excess into HP; `applyEnergyDamage(d)` subtracts energy |
| Parts and weapons | `src/parts.js` lines ~13,669–20,381 | 257 `parts.<name> = (function` class assignments counted in this release; some are cosmetic/armor/utility, not all weapons |
| Combat objects | `src/things.js` lines ~10,411–11,873 | Projectiles, particles, explosions and hit processing; many weapons are defined in `parts.js` |
| AI | `src/ai.js` lines ~20,382–22,063 | Rule evaluators: attack, kite, circle, ram, capture, keep range, movement and target selection |
| AI presets | `src/aidata.js` lines ~22,064–22,147 | Ship loadouts and AI rule presets |
| Spatial queries | `src/hspace.js` lines ~2,765–2,843 | Spatial indexing; `Sim.spacesRebuild` uses `HSpace` for units and bullets |
| Serialization | `src/zjson.js` and `src/protocol.js` | `zJson.dumpDv/loadDv`, protocol data exchanged with interpolator |
| Network | `src/network.js` lines ~22,148–22,408 | `Connection` (binary WebSocket game packets), `RootConnection` (JSON root control), `Local` (direct simulation dispatch) |
| Rendering | `src/engine.js`, `src/onecup.js` | WebGL canvas and UI framework |
| Build interface | `src/design.js`, `src/buildbar.js` | Ship design, validation and build slots |
| Battle interface | `src/battle.js`, `src/battleroom.js` | Battle interactions and room setup |

### Simulation step order

`Sim.simulate()` (near line 8,778) increases `step`, calls `startingSim`, checks AFK/host state, rebuilds spatial indexes, removes dead things, ticks all things, moves them, resolves unit collisions, ticks eligible players, then applies survival- or normal-mode victory logic.

`Sim.victoryConditions()` (near line 8,924) checks ownership of command points and, in non-local/non-AI-test sessions, whether people remain or the maximum match duration has elapsed.

### Two separate networking paths

- `Connection` constructs a game WebSocket (near ~22,153). It sends a join/player message and `gameKey`, receives `ArrayBuffer` data and decodes with `intp.zJson.loadDv`.
- `RootConnection` (near ~22,214) uses JSON and receives control/chat/server-list/auth messages. Root connectivity is **not** required by the local `Local.send` dispatch itself.
- `Local.send` (near ~22,383) calls a named `sim[args[0]]` method with local-player context. This is client-owned logic, so the sandbox is worth isolating for behavioral tests.

## Current verification status

- Confirmed: local ASAR contains these markers and classes; source module exporter/override builder has synthetic Windows smoke-test coverage.
- Not yet confirmed: launch of the modified app using the user's Windows Steam installation; independent simulation determinism; functioning root-server-free UI; any original authoritative multiplayer server source.
- Do **not** infer server implementation solely from the client `Sim` and local call path.

## Next test-first tasks

1. Verify a local Windows build starts, renders and enters sandbox with no modified modules.
2. Test sandbox with network disabled; identify code paths that presume `rootNet.websocket` exists.
3. Establish a repeatable local simulation test (fixed random seed, fixed fleet specs, step counts); compare ship costs, shields/HP, movement and collisions with baseline.
4. Verify AI build / move / fire / capture command flow with telemetry instead of arbitrary gameplay rewrites.
5. Isolate WebSocket and account side effects while keeping local battles functional.
6. Only then consider edits to ship stats, weapons or combat.

## Editable module workflow

Run `Export-Sources.cmd`: local sources go to `.build/sources/<original path>`, plus a source map. Copy **only** the module you intend to modify into `modules/<original path>`. For example `modules/src/ai.js` overrides only the AI section when you double-click `Run-Istrolid.cmd`.

Retain the `//from src/ai.js` first line unchanged. Never commit locally extracted original game code/assets to this public repository without permission to redistribute them. Keep notes and separately authored patches in Git.
