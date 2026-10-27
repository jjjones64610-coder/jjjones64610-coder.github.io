# Testing

This project is written in an environment **without Roblox Studio**. Anything
that depends on the engine (Humanoid physics, replication, rendering, input
devices, DataStores, avatar loading) has **not been run yet** and must be
checked in Studio with the plan below. Everything that could be verified
offline was, and is listed first.

## 1. Verified offline (automated)

Run everything with `scripts/check.sh` (the header lists tool versions).

| Check | Tool | Result |
|---|---|---|
| Formatting | StyLua 0.20 | clean |
| Lint | Selene 0.27 (Luau std + Roblox globals) | 0 errors, 0 warnings |
| Types against the **real Roblox API** (catches invented properties and methods) | luau-lsp 1.70 `analyze`, every file `--!strict` | 0 errors |
| Cross-module calls (`services.X.y`, `controllers.X.y`) exist | `scripts/audit_refs.py` | 0 missing |
| Unit + integration tests | Lune 0.9 (`lune run tests/run.luau`) | **208 passed** |
| Place builds with the right structure and StarterPlayer settings | Rojo 7.4 + `tests/place_check.luau` | OK |

What the tests cover (`lune run tests/run.luau <spec>` runs one):

* **movement (48)**: acceleration, stopping and turning times; plain vs
  plant-restart reversal; auto-restart; Snap Cut judged against the pre-steer
  line; look-ahead fake commits; every press returns a reason; the input
  buffer; burst and layout can't reverse a sprint in one frame; precision
  landings and their timing; dives, pop-ups and their chain windows; the
  pivot step model (radius, swing time, fake step, hop, teleports); mark
  shuffle; **resets** (tip reset restores both air moves with a lift, two per
  jump, a cooldown, landing clears them; Charged moves; wall reset; landing
  reset refunds Burst and Layout; a ground layout needs a reset before an air
  layout); and a **120,000-frame fuzz** with random tip resets: never above
  the 36 studs/s cap, no NaN, exertion in range, root near the pivot.
* **disc (15)**: determinism, power → range, turn/fade shapes, bank, hammer,
  scoober, blade, wind, fixed-step consistency, field fit for both fields.
* **throw (22)**: charge windows, sanitising hostile input, release heights,
  releases from the pivot + step, the server's step check, left-handed
  mirroring, the lead-pass solver and an integration test that solved passes
  reach a moving receiver.
* **catch (26)**: catch quality at the closest approach, slack, client-root
  tolerance, contests, bobbles, block vs interception, the mark box and its
  counterplay table, the **fixed hitbox** (any stand height gives the
  standard zones), **prone zones** after a layout, and **tips** (closest pass,
  Perfect timing, tip-only overhead sphere, the pop lasting about as long as
  the tipper's lift).
* **rules (20)**: every RulesEngine outcome (completions, goals, the
  Greatest, out of bounds, drops, blocks, interceptions, Callahans,
  stall-outs, pulls, target score, universe point, time cap).
* **combo (9)**, **misc (10)**: chain scoring, settle/convert, ratings,
  levels, deterministic RNG.
* **modes (27)**: Mini / Normal rules and fields, eligibility for 0–16
  humans, ranked overrides, private rules, MatchPlan splits, bench rotation,
  exact bot fill, late joiners, leavers, ranked rosters.
* **tech (20)**, the tech-spec core (build step 1): acceleration and
  friction times, part-pushed stick, overspeed decay on the ground and in
  the air, the hard cap on flat and fall speed, the turn-rate curve, instant
  slow turns, rate-limited fast turns and drift loss, slow plain reversals,
  gravity and the fall multiplier, ballistic air, identical results at 20 /
  60 / 144 / 240 fps, the state machine and its transitions, holding and
  marking, the 100 ms input buffer, the timing readout, walls, frozen, and a
  60,000-step fuzz.
* **signatures (11)**: every signature move's recognition, priority (one
  per catch), timing windows, and a catch confirmed after its landing.

Regenerate the throw table in DESIGN §5.1 with `lune run tests/flight_table.luau`.

## 2. Studio test plan (not yet run)

### Setup
1. Open `build/UltimateBreakpoint.rbxlx` (or `rojo serve` + the Rojo plugin).
2. Game Settings → Avatar: **R15** (also set in the place).
3. Game Settings → Security: **Enable Studio Access to API Services** for
   saving and the leaderboard (otherwise a "not saved" toast appears).
4. View → Output open. `[Breakpoint] X.Init/Start failed` or
   `MOVEMENT ERROR` is a bug: copy it.

### 0. Tech core (build steps 1–2, the default engine)
The debug HUD sits top right (always in Studio; Settings → Tech debug HUD
elsewhere).
- [ ] Hold W: SPEED climbs to 22 in about 0.37 s and stays there. Let go: you stop in about 0.28 s.
- [ ] Below 12 you turn on the spot. At full speed a hard turn shows **DRIFT** and SPEED drops; a full reversal is slow (that is what cuts will be for).
- [ ] You stand at the right height on flat ground, ramps and small steps, with no bobbing, sinking or sliding while standing still.
- [ ] Walk off a ledge: STATE goes Airborne, you fall faster on the way down, and land cleanly (no bounce, no sinking). The fall animation plays.
- [ ] Run into a wall at an angle: you slide along it, no sticking or jitter.
- [ ] Catch a pass at speed: you skid to a stop (STATE HoldingDisc), turn to the camera, and can throw. No travel snap-backs.
- [ ] Press Space / Q / E / C: nothing moves yet, but BUFFER shows the press for 100 ms.
- [ ] Settings → **New movement core** off: the classic movement comes back at once; on again: the tech core.
- [ ] No key hints under the crosshair and no air-move line.

### A. Running and feel (classic engine, solo, F5)
- [ ] Hold W: you start running at once and **sprint by yourself** after ~0.3 s (Shift sprints instantly). Top speed feels fast; stopping takes a fraction of a second; turns at jog are tight.
- [ ] Feet don't skate at any speed; walk/run blend smoothly; no limbs pop.
- [ ] The camera doesn't jitter, clip into the floor when you look up, or pulse its FOV on every cut.
- [ ] Settings → **Show hitboxes**: every player has the same capsule. A tall or Rthro avatar is rescaled to the standard body when it spawns.

### B. Techniques and combos (each press does something)
- [ ] Hold D, then Q while sprinting → **Snap Cut** (Clean or Perfect, never a weak cut).
- [ ] Q with nothing held at speed → **Plant**; keep a direction held → auto-restart; Q/F/Space in the window → faster restart.
- [ ] F → **Burst**; F holding S at a sprint bends your line (no instant reversal).
- [ ] C at speed → Slide; Q mid-slide → Slide Cut. Jump, C just before landing → "PRECISION LANDING −xx ms".
- [ ] E → Layout; Space as the slide stops → pop-up. A refused press shows why ("NEED SPEED", "ONE PER JUMP", cooldowns flash the key pip).
- [ ] The **chain widget** appears from the first technique and counts up; a card shows when it ends; a catch soon after converts it (×2).

### C. Resets and signature moves (Training → Reset Lab)
- [ ] Jump at an incoming floater and press **RMB** as it reaches your hands: the disc pops up, a cyan flash plays, the HUD shows `Q AIR CUT · E AIR LAYOUT` lit again (CHARGED).
- [ ] Use the reset (Q with a direction, or E) and catch the popped disc before landing → **RESET GRAB** banner, +points in the chain.
- [ ] Two tips in one jump then the catch → **DOUBLE TIP**; a third tip is refused.
- [ ] Next to a Rebound wall: wall rebound + tip + catch → **WALL TIP**.
- [ ] Layout → Perfect pop-up → air layout catch → **DOUBLE LAYOUT**.
- [ ] A Perfect precision landing shows "LANDING RESET" and Burst is ready at once.
- [ ] RMB in the air with no disc near → "NO DISC TO TIP".
- [ ] In a match, other players see your signature banner; in Training only you do.

### D. The pivot and the mark
- [ ] Catch at a sprint: you slide a little, keep facing your run, then turn to the camera and plant (pivot disc under your foot).
- [ ] WASD steps around the pivot; the planted foot never moves; Q / E swing fast; the throw comes from where your hand is and goes **where the crosshair points**.
- [ ] Training → **Break the Mark**: a step-out to the open side gets past; a Sold swing (fake, then swing) beats the bot.
- [ ] As a defender: hold RMB near the holder to mark-shuffle (no skating); C toggles Low / High; the stall counts.

### E. Matches and modes
- [ ] Alone: the lobby says practice vs bots; a **Mini 3v3** starts with bots on the Mini field.
- [ ] Test → Clients and Servers with 2–6 players: Mini, teams balanced, bots fill the rest; a joining player replaces a bot at the next point.
- [ ] With 7–9 players the vote offers Mini or Normal; Normal is 7v7 on the big field. Extras sit on the bench and rotate in.
- [ ] Line-ups freeze only briefly, then you can move behind your goal line; the pull releases everyone.
- [ ] Goals, turnovers, stall-outs, the end-of-match summary.

### F. Latency (Studio Settings → Network → Incoming Replication Lag 0.1–0.2 s)
- [ ] No snapping or rubber-banding while running with techniques (speed check).
- [ ] Catches snap to your hand at once; a lost contest eases back cleanly; observers see the disc go into the catcher's hand, not teleport.
- [ ] Tips: the disc pops for you at once and the server's version blends in.
- [ ] Pivot: no travel resets while legally stepping or swinging.

### G. Devices
- [ ] Phone emulator: stick, buttons, TIP label in the air, swing buttons while holding.
- [ ] Gamepad: all bindings; X swings to the other side while holding; L2 tips in the air.
- [ ] Rebinding takes effect at once and persists (with API access).

### H. Performance (MicroProfiler, Ctrl+F6)
- [ ] Client frame < 8 ms with 14 players/bots on Normal (hitbox overlay off).
- [ ] Server Heartbeat well under 16 ms with 13 bots.

## 3. Engine assumptions to confirm in Studio

These were reasoned about from the API, not observed:

0. **Tech engine**: with `Humanoid.EvaluateStateMachine = false`, a
   VectorForce of `AssemblyMass × workspace.Gravity` on the root, and the
   root's velocity written every frame, the character stays upright (the
   AlignOrientation holds it), only the root collides (limbs are in
   UBLimbs), and the Animate script reads `UB_Air` for air poses.
1. **Humanoid-driven movement (classic engine)**: `WalkSpeed = |v|` + `Move(v.Unit)` each
   frame tracks the sim's velocity closely on the ground and in the air, and
   direct `AssemblyLinearVelocity` writes on impulse frames stick.
2. **Jumps** via `JumpPower` + `ChangeState(Jumping)` (also mid-air for wall
   rebounds and tip lifts).
3. **Avatar normalisation**: `Humanoid:GetAppliedDescription()` +
   `ApplyDescriptionAsync` rescales spawned players without breaking the
   movement or poses (PoseController re-captures rest joints).
4. **Leg IK** in PoseController plants the pivot foot and stance feet on the
   ground for standard bodies.
5. **Camera** `workspace:Spherecast` distance semantics for wall pull-in.
6. **Bots** from `Players:CreateHumanoidModelFromDescription`, server-owned,
   driven by the same sim.
7. **Adornments** (`CylinderHandleAdornment` / `SphereHandleAdornment` under
   a workspace folder) render the hitbox overlay.
8. Built-in sound paths in `Config/Audio.luau` exist on all platforms
   (missing ones are silent; crowd loops need your own audio).

## 4. Tuning

All feel numbers live in `src/shared/Config`: `Movement.luau` (speeds,
windows, costs, resets), `Disc.luau` (flight, tempo, throw, catch, tip,
mark), `Hitbox.luau`, `Signatures.luau` (points, windows), `Modes.luau`
(fields, rules), `Arenas.luau` (wind, look). Re-run `lune run tests/run.luau`
after changes: the tests encode relationships (spam scores less than variety,
a plant-restart beats a plain reversal, a tip's pop lasts about as long as
the tipper's lift), not exact values.
