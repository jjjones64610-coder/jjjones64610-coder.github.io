# Testing

This project was written in an environment **without Roblox Studio**. Anything
that depends on the engine (physics, replication, rendering, input devices,
DataStores) has **not been run yet** and must be checked in Studio with the plan
below. Everything that could be verified offline was verified, and is listed
first.

## 1. What has been verified (offline, automated)

Run everything with `scripts/check.sh` (see the header for tool versions).

| Check | Tool | Result |
|---|---|---|
| Formatting | StyLua 0.20 | clean |
| Lint | Selene 0.27 (Luau std + Roblox globals) | 0 errors, 0 warnings |
| Types against the **real Roblox API** (catches invented properties/methods) | luau-lsp 1.70 `analyze`, all files `--!strict`, current `globalTypes.d.luau` | 0 errors |
| Cross-module calls (`services.X.y`, `controllers.X.y`) exist | `scripts/audit_refs.py` | 0 missing |
| Unit + integration tests | Lune 0.9 (`lune run tests/run.luau`) | **71 passed** |
| Place builds and has the right structure | Rojo 7.4 + `tests/place_check.luau` | OK |

What the 71 tests cover:

* **Movement** — acceleration time, turn radius, plain vs. Momentum-Cancel
  reversal (~0.75 s vs < 0.25 s), restart mash lockout, Perfect snap cuts,
  zig-zag spam penalties, Fake Commit → Sold cut, burst cooldown/ceiling,
  precision landing timing and lockout, dive → slide → recovery chain, air
  redirect limits, holding (decelerate then pivot inside 3.2 studs), slide-hop
  speed ceiling, and a **fuzz test** (120,000 random frames with random
  techniques, walls and holding) proving the 34 studs/s cap, no NaN and
  exertion bounds.
* **Disc physics** — determinism, power→range monotonic, straight full-power
  backhand, backhand fades left / forehand right, bank curves both ways,
  hammer inverts, scoober flips short and breaks right, blade is fast,
  overcharge rolls more, crosswind drift, fixed-step consistency.
* **Throwing** — charge windows, forehand charge rate, sanitising hostile
  input, off-balance caps, release heights, left-handed mirroring, solver
  accuracy (static, leading, coarse) and an **integration test** that solved
  lead passes actually enter a moving receiver's catch zone.
* **Catching / defense** — secure, reach and dive zones, fingertip vs clean,
  server slack, contest resolution, bobble rules, mark stance zones, and an
  **integration test of mark counterplay** (mid release into a low mark is
  blocked; pivot + low step-out, hammers and breaks get by; a high mark stops
  hammers; jumping lifts the hands; you can't throw through a body).
* **Rules** — every outcome in `RulesEngine`: completions, goals only where
  you land, airborne resolution, the Greatest, out-of-bounds jump origins,
  incompletions, blocks, drops, OOB spots, interceptions, Callahan, stall-outs,
  pulls (in, out → brick, touched and dropped), target score, universe point,
  time cap during and between points.
* **Combos**, **rating/levels/team balance**, **deterministic RNG**.

Regenerate the throw table in DESIGN §4.1: `lune run tests/flight_table.luau`.

## 2. Studio test plan (not yet run)

### Setup
1. Open `build/UltimateBreakpoint.rbxlx` (or `rojo serve` + the Rojo plugin).
2. Game Settings → Avatar: **R15** (the place file also sets it).
3. Game Settings → Security: **Enable Studio Access to API Services** if you
   want saving and the leaderboard (otherwise you'll see a "not saved" toast).
4. View → Output open. Any `[Breakpoint] X.Init/Start failed` line is a bug.

### A. Solo smoke test (Play, F5)
- [ ] You spawn on the sideline of the Championship Stadium. Output shows `[Breakpoint] server ready`.
- [ ] HUD: scoreboard (WARMUP clock), exertion bar, pips, hint line. M opens the menu; mouse is free while it is open.
- [ ] Warm-up disc on the field: walk over it to pick it up, hold LMB and release to throw, the preview arc is visible.
- [ ] After ~20 s (or Play → *START MATCH NOW* as host) a Casual match starts with bots (3v3).
- [ ] Line-up: both teams on their goal lines, frozen, end zones glow in the attacking team's colour, banner "POINT 1".
- [ ] Pull: the puller (you or a bot) throws; everyone unfreezes on release; "PULL!".
- [ ] Bots cut, mark, chase throws, pick up grounded discs and throw passes.
- [ ] Catch by running into a disc. Reach (LMB) for wide ones. Layout (E) for far ones.
- [ ] With the disc: you decelerate then stand on a pivot (can't run); Q/E banks, 1–5 changes type, Ctrl = low, Space = hop, RMB = fake. A stall count appears when marked; it reaches 10 → "STALL" turnover.
- [ ] Throw out of bounds → turnover where it crossed; catch in the end zone → GOAL banner, confetti, crowd cheers, teams switch ends.
- [ ] Match ends at 5 or on the cap → summary panel (MVP, stats), back to warm-up.

### B. Movement feel (each with a visible label in the combo feed)
- [ ] Sprint turns are wide; Q while steering 45–90° snaps the line (dust + cyan streak).
- [ ] Q pointing backward plants (skid mark); Q again ~0.15 s later → "RESTART CUT PERFECT".
- [ ] Mashing Q twice instantly → "TOO EARLY" feedback.
- [ ] F bursts (orange ring, FOV kick), then shows a cooldown on the pip.
- [ ] Ctrl at speed slides (low pose); Q mid-slide → Slide Cut.
- [ ] Space, then Q in the air bends the path once; Ctrl just before landing → "PRECISION LANDING −xx ms".
- [ ] E dives horizontally; as the slide stops press Q → Recovery Chain.
- [ ] Rebound walls exist in the Combo Lab (pink): jump next to one in the air.
- [ ] Other players/bots show the matching poses (dive, slide, lean, reach, windups).

### C. Training (Menu → Training, or walk to a terminal and press G)
- [ ] Movement School advances through all 14 steps.
- [ ] Cutting Course: timer starts at the first green gate, splits and advice at the end, PB saved.
- [ ] Momentum Shuttle: reversal times graded.
- [ ] Aerial Catch: 10 launches; misses explain above/below/too far/early/late.
- [ ] Throwing Range: rings register hits (including the moving one); miss advice shows left/right/short/long.
- [ ] Interception Drill: two bots run 8 reps; INT/BLOCK/completed messages with lane distance.
- [ ] Combo Lab: checklist ticks as chains land.
- [ ] Free Launcher: set values in Menu → Training, press LAUNCH, catch.

### D. Multiplayer (Test → Clients and Servers, 2–4 players)
- [ ] Teams balance; bots top up to equal sizes; a joining player replaces a bot.
- [ ] Two players contest the same disc: earliest touch wins; near-ties go to the cleaner hand; fingertip contests bobble.
- [ ] Mark stance + hand blocks: a marker with low hands blocks a mid release thrown into them; a pivot + low step-out gets around.
- [ ] A player leaving while holding the disc → their team keeps it on the ground there.
- [ ] Poses, technique effects, disc flights and trails look identical on all clients.

### E. Latency (Studio Settings → Network → Incoming Replication Lag 0.1–0.2 s)
- [ ] Your own throws leave instantly and blend smoothly onto the server flight.
- [ ] Your catches snap to your hand immediately; contested ones correct cleanly.
- [ ] Catch claims are not rejected for normal play (watch for many "Denied" results; increase `Catch.BaseSlack` if so).
- [ ] No false speed resets while moving with techniques (raise `HardCap * 1.25 + 6` slack in MovementService if needed).

### F. Devices
- [ ] Device emulator (phone): thumbstick, buttons, camera drag, disc buttons appear when holding; menu button.
- [ ] Gamepad: every binding in Menu → Controls; menu navigable with the D-pad.
- [ ] Rebinding a key in Menu → Controls takes effect immediately and persists after rejoin (with API access).

### G. Data
- [ ] With API access: XP, level, stats, mastery, PBs, cosmetics and settings persist across sessions.
- [ ] Ranked (4+ humans, no bots): ratings change and the leaderboard lists them after ~90 s.

### H. Performance (MicroProfiler, Ctrl+F6)
- [ ] Client frame < 8 ms on a mid PC with 14 players/bots in a stadium arena.
- [ ] Server Heartbeat stays well under 16 ms with 8 bots.

## 3. Assumptions to confirm in Studio

These are the places where engine behaviour was reasoned about but not observed:

1. **Humanoid + `LinearVelocity` (Plane mode)** controls horizontal motion
   cleanly with `WalkSpeed = 0`. If movement jitters, raise the force in
   `MovementController` (`AssemblyMass * 900`) or set `RigidityEnabled`.
2. **Jumping** via `ChangeState(Jumping)` + direct vertical velocity behaves
   the same on ground and in the air (wall rebound uses it mid-air).
3. **Limb collision group** (`UBLimbs` collides with nothing) keeps the
   procedural layout/slide poses from snagging the ground.
4. **Default R15 animation IDs** in `Shared/Animation/Locomotion.luau` load in
   your experience (they are Roblox's own).
5. **Built-in sound paths** (`rbxasset://sounds/...`) in `Config/Audio.luau`
   exist on all platforms; missing ones are silent. Crowd loops need your own
   uploaded audio.
6. **`Players:CreateHumanoidModelFromDescription`** builds bots in Studio and
   live servers.
7. **Motor6D C0 posing** looks right on avatars with unusual proportions
   (Rthro, very small/large scales).

## 4. Tuning

All feel numbers live in `src/shared/Config`: `Movement.luau` (speeds, windows,
costs), `Disc.luau` (flight, throw, catch, mark), `Modes.luau` (rules),
`Arenas.luau` (wind, look). Re-run `lune run tests/run.luau` after changes:
the tests encode the intended *relationships* (e.g. spam must score lower than
variety, a plant-restart must beat a plain reversal), not exact values.
