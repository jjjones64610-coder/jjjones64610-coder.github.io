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
| Unit + integration tests | Lune 0.9 (`lune run tests/run.luau`) | **238 passed** |
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
* **tech (42)**: every tech in TechCore (Burst and Burst Kick, Perfect /
  late / buffered / capped cuts, Juke, Plant Stop, Slide, Carve, Landing
  Slide, Fast Fall, Slide Hop chains, Jump heights, Air Dodge and its hang,
  Disc Reset, Wavedash, Reverse Snap and its stumble, Burst Dive, Layout,
  air Layout, Tech Roll, Sky, Mirror Step, the abilities' effects, a
  40,000-step tech fuzz) and the core (build step 1): acceleration and
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

### STAGE 3 — The disc and throwing (docs/CORE_DESIGN.md) ← test this now
**TEST FIELD (MOVEMENT)** now has a disc lying in front of you. Walk to it and press LMB to pick it up.
After every throw the panel reports the throw, the release quality, the distance and how far it curved;
the disc comes back in front of you a few seconds after it lands. Tune in `Config/Tuning.luau`, section
"THE DISC, THROWING AND CATCHING" → `Throw`.

- [ ] **Charge and release:** hold LMB, the meter fills; release to throw exactly at the crosshair. A tap is a short dump, a full hold is a long throw.
- [ ] **Perfect release:** release on the gold line: "SNAP RELEASE", a faster, cleaner flight. Hold past the zone: "OVERCHARGED", it wobbles and fades early. The rhythm is the same for every throw.
- [ ] **Bend it:** hold **A** at the release: a backhand that curves left (the panel says BENDS LEFT). Hold **D**: a forehand from your other side, curving right. Nothing held: a flat backhand. Expect roughly 30 studs of curve on a 130-stud throw (BendBank).
- [ ] **Hammer:** aim well above the horizon (about 28°+) with at least a 60 % charge: the panel switches to HAMMER and the disc goes up and over. Aim high with a weak charge and it is just a floaty backhand.
- [ ] **Flight:** throws float, bank and fade like a disc, not a ball: the flat backhand drifts late, bends hold their curve, the hammer drops steeply.
- [ ] **Aim:** hold RMB with the disc: the view tightens and the mouse slows for precise aiming.
- [ ] **Fake:** while charging, press RMB: the throw is cancelled (a pump fake); you can charge again after a moment.
- [ ] **No running with it:** pick it up or catch it at speed: you skid to a stop, then WASD only steps your free foot around the pivot (double-tap lunges). The bend keys and the step keys are the same on purpose: step out and bend round.
- [ ] **Air throw:** throw it high to yourself (a hammer works), run under it, jump, catch it in the air and release before you land. Full power, aims true, a little less spin. Same out of a dive.
- [ ] **On the run:** a release during the catch skid goes exactly where you aim (there is no random spread any more).
- [ ] **Nothing else throws:** 1-5, T, the mouse wheel, Q, E, Z, X, F, C, R do nothing.

What to tell me: is the charge too slow or too fast (ChargeTime)? Is the Perfect window findable (SnapPerfect)? Is the
bend too much or too little (BendBank)? Does the hammer trigger when you don't want it (HammerPitch, HammerFill)?
Does the skid after a catch feel right (CATCH_RUNOUT_FRICTION)?

Known for this stage: the pump-fake sound is a stock placeholder (ForgeGUI is disconnected; it needs
re-authorizing before I can make the real one). Catching and blocking are still the old rules until stage 4
(RMB without the disc still marks). Bots still throw their own five throw types.

### STAGE 2 — Jump, dive, landing recovery (docs/CORE_DESIGN.md)
Same place: **TEST FIELD (MOVEMENT)**. The debug panel's **AIR** line shows whether your air action is
READY or SPENT; **LAST** shows the timing of the last Tech Roll / Wavedash. Tune in `Config/Tuning.luau`
(sections JUMP, THE AIR ACTION, LANDING OUT OF A DIVE).

- [ ] **Jump:** Space jumps at once (no delay, even sprinting); hold Space for a higher jump. In the air you can steer, but only a little — you commit.
- [ ] **Dive:** jump, then Space again with W/A/S/D held: you lay out that way (DIVE line: speed + boost). Straight ahead keeps all your speed; sideways or backwards keeps less. Only one per jump.
- [ ] **No ground dive:** there is no dive key; Space on the ground is always a jump.
- [ ] **Sky Reach:** jump, then Space again with no direction: you hang a beat with your hands up.
- [ ] **Belly slide:** a dive lands you chest-down sliding along the grass, then you get up. Feels like a commitment, not a stun.
- [ ] **Tech Roll:** press Space right as the dive lands (a hair early is fine): you roll up fast and keep a good share of your speed. LAST says PERFECT within ±40 ms.
- [ ] **Scramble:** miss the roll and press Space while face down: you get up sooner, but slower than a roll.
- [ ] **Wavedash:** jump, and press Space + a direction just before you land: no layout, you hit the ground in a fast slide that way. Space out of the slide hops; Shift carves it.
- [ ] **The chain:** cut (let go, snap) → jump → dive → tech roll → cut again, without the body ever stalling or snapping. Also: cut → jump → wavedash → slide hop.
- [ ] **Sounds (ForgeGUI):** jump, dive launch, chest landing, tech roll, wavedash slide each have their own sound.
- [ ] **Look:** the dive is flat and stretched, the belly slide stays on the ground, the skid now leans back with the feet dug in.

Rules tightened in the audit pass (worth a specific look):
- [ ] A dive from a standstill still travels (DIVE_MIN_SPEED); you can't dive or Sky Reach while holding the disc.
- [ ] A wavedash sideways or backwards keeps less speed than one straight ahead (WAVEDASH_TURN_KEEP).
- [ ] One mistake gives one skid (no skid-into-skid), and hopping out of a skid gives no speed.
- [ ] Letting go during the short cooldown after a cut just slows you; it never turns into a late cut.
- [ ] Menu → Controls lists only Jump, Sprint, Throw, Aim/Fake, Menu, and the guide under it teaches the current moves.
- Known: Sky Reach shows the hang and the hands-up pose, but its extra catch reach is only connected in stage 4 (catching).

What to tell me: is the dive too long or too short (DIVE_BOOST, DIVE_UP)? Is the face-down time punishing enough
but not boring (LAYOUT_DOWN_TIME, GETUP_TIME)? Is the Tech Roll timing findable (TECH_ROLL_WINDOW / _PERFECT)?
Is the jump too floaty or too heavy (JUMP_TAP, PLAYER_GRAVITY)?

Gone (no keys left for them): the separate air dodge, fast fall, the crouch "Sky" jump, Stall, Reverse Snap,
Burst Dive, ground layouts.

### STAGE 1 — Movement and turning (docs/CORE_DESIGN.md)
Start the place (F5), choose **TEST FIELD (MOVEMENT)** on the title screen. The debug panel
(top right) shows SPEED, STATE, BURST and a **CUT** line for every cut. Tune anything in
`src/shared/Config/Tuning.luau`.

Controls are only: WASD, mouse, Space, Shift, LMB, RMB (+ Space+Shift together = ability, M = menu).
- [ ] **Nothing else is bound.** Q, E, C, F, G, Z, X, T, 1-5, R, B do nothing.
- [ ] **Momentum:** from a standstill you build up to ~30 (SPEED line), hold Shift to build to ~40. Letting go of WASD slides you to a stop instead of halting instantly.
- [ ] **Turning by speed:** walking you can turn on the spot; at full sprint, sweeping turns (holding W and adding A) keep your speed, while sharp ones show DRIFT and cost speed.
- [ ] **The planted cut:** running, *let go of W*, then press D. The CUT line says PERFECT when the let-go was 40-120 ms (kept 100 %+), CLEAN otherwise (kept 80 %). Try it on the cone slalom; a good run keeps the SPEED line high.
- [ ] **The sloppy cut:** at sprint, swap W for S (or S+D) in the same instant with no gap at all. Yanking the direction round more than 110° with no plant gives **SKID**: you slide on, lose speed, then run again. (Note: holding W and pressing S cancels to "no input", so that counts as letting go — a cut, graded by how long both were down.)
- [ ] **Juke:** cut right, then within ~0.1 s go straight back to W. CUT stays PERFECT/CLEAN and you're back on your old line at 90 %.
- [ ] **Spam is capped:** cutting again within 0.6 s keeps at most 85 %.
- [ ] **Look:** the body leans into turns and acceleration, pitches low at sprint, and the feet match the ground speed (no ice skating), including at full Burst.
- [ ] **Chord:** Space and Shift pressed together fire the ability (and you still jump). A normal "hold Shift, then jump" never fires it.
- [ ] **Bots** (play a 3v3) cut the same way: short stops before they change direction.

What to tell me: does running feel heavy or floaty (RUN_ACCEL, GROUND_FRICTION)? Are turns too wide or too
tight (TURN_RATE)? Is the Perfect let-go window findable (CUT_RELEASE_PERFECT)? Does the skid trigger when
you don't want it (SKID_ANGLE, SKID_MIN_SPEED)?

Not stage 1 (still on the old design until their stage): jumping/air dodge, dives, the disc, throwing and
the pivot (throw type is stuck on Backhand), catching and marking (RMB still marks), the Training hall
tutorial (it still teaches Q/E), and abilities (still FLOW-meter based).

### 0. Tech engine (the default)
The debug HUD sits top right (always in Studio): speed, state, Burst, and
the last timed press in ms ("Cut: 34 ms early").
- [ ] Running: SPEED reaches 22 in ~0.37 s; hold Shift for 30 while the bar drains; tap Shift for a Burst Kick. A hard turn at speed shows DRIFT.
- [ ] Standing height is right on flat ground, ramps and steps; no bobbing or sinking.
- [ ] Q with a new direction cuts (a Perfect pops gold with an impact frame); Q then back to your line jukes; Q with no direction stops dead.
- [ ] C at speed slides (60°/s), Shift in a slide carves; Space 0.15–0.30 s into a slide hops; hold C through a landing for a Perfect landing slide.
- [ ] Space taps vs holds give different heights; Space in the air dodges (with a hang); a dodge just before landing wavedashes; standing, hold Space for a Sky.
- [ ] Backward dodge then Q reverse-snaps; standing tap-jump, diagonal dodge, Q burst-dives.
- [ ] E at speed lays out toward the camera; Space as you land tech-rolls.
- [ ] Catching: press LMB as the ring closes (gold = Perfect). No press: it bobbles; press again to save it. A Perfect Catch then LMB throws at once (Hot Hands).
- [ ] As a defender, Q right after your matchup's plant: "Perfect Cut" (Mirror); if they juked you lose speed.
- [ ] Running through a player slows you.
- [ ] Ability: set it in Settings, fill FLOW (bar above Burst), press G. Flash Step blinks (not through walls); The Zone / Sky Walk / Overdrive glow on your character for everyone.
- [ ] Anime effects: speed lines above run speed, afterimages on dashes and cuts, slash arcs; Settings → Anime effects turns them off.
- [ ] Bots: cut, dodge, slide, lay out and tech-roll on the new engine; they still pivot and throw as before.
- [ ] Throwing: LMB backhand / RMB forehand, F + either for overheads; the meter's pale zone and gold Snap line; C mid-charge fakes; the other throw within 150 ms is a Fake Switch.
- [ ] Holding the disc: WASD steps the free foot (1.2 studs), a double-tap lunges; no travel snap-backs.
- [ ] Marking: LMB swings a hand block (a Point Block right on the release). A defender's untimed dive at the disc knocks it down; overlapping the receiver gives it back (foul).
- [ ] World-class: land your feet on a disc in flight (Flip Reset, stored dodge); a throw on the landing frame (Pinch, much faster); Dive right after a dodge (Stall); Cut right after a wavedash (Zap Dash); jump just as you touch a wall in the air (Wall Kick). Each shows on the timing bar in Training.
- [ ] Throw shaping: while charging the camera holds still; mouse left/right tilts the edge (bank pip), up/down the launch angle (the preview arc shows both); a hard edge leaves as a Blade. A throw on the move before your pivot plants is a little less accurate the faster you go.
- [ ] Training → TECH DRILLS: pick one, the panel counts reps to three Perfects.
- [ ] Music: main theme in warm-up, the chill track in Training, the match track in a point, the fanfare at match end; Settings → Music volume.
- [ ] Settings → New movement core off brings back the classic engine at once.

### 0a. Round 5 (after the first playtest)
- [ ] Join: the title screen shows (art, logo, level + coins); PLAY drops you in; SHOP / LOCKER / SETTINGS open those tabs. Main theme plays.
- [ ] The only cursor is a white circle (no arrow), centred in play, following the mouse in menus.
- [ ] Every avatar is the same standard body (Rthro / bundle bodies become the standard R15 shape; clothes and accessories stay).
- [ ] Pivot: catch on the run, stop, step around: no pull-back, no spinning, the disc leaves from where your hand is.
- [ ] Running feels quicker; Space always jumps at once; crouch (C) then Space is a Sky.
- [ ] Touching the disc catches it; LMB on the gold ring is a Perfect Catch.
- [ ] Throws: 0.7 s charge, Q / E curve, the camera keeps following the mouse.
- [ ] Bots: with the disc in your hands they cut into the lanes in front of you; open, you get passes.
- [ ] Shop: buy an emote / aura / trail / ability with coins; equip it; B plays the emote in warm-up; Perfects flare your aura. Robux buttons read "after publishing".

### 0a+. Round 6
- [ ] Every menu button shows its label (the art no longer covers the text).
- [ ] Title screen: PLAY 3v3 or PLAY 7v7; alone, the match starts against bots at once on that field.
- [ ] Walk up to an opposing thrower: you mark automatically (no RMB needed), shuffle fast with instant turns, and the stall count runs.
- [ ] Throwing past bots: stepping out beats the mark more often; bot defenders don't pick off every throw. The preview arc shows most of the flight.
- [ ] Catching: near-misses on your screen still count.

### 0a++. Round 7 (speed, abilities, combos, anime)
- [ ] The whole game is quicker: run 30, Burst 40, faster accel and snappier jumps. Nothing feels floaty.
- [ ] Abilities last: Zone / Sky Walk 8 s, Overdrive 7 s (+6 top speed, Burst never drains), Flash Step blinks 18 studs and surges you forward.
- [ ] Sky Walk floats (lower gravity) and gives three extra Air Dodges per jump.
- [ ] Shop sells Magnet Hands (catch reach +2.5 for 8 s) and Tempest Throw (next throw in 10 s is 35 % faster, shows "TEMPEST"). Both have icons.
- [ ] Every cast plays the power-up: crouch and tremble, then arms flung wide, rings of light, impact frame and a camera punch. Others see the pose and rings too.
- [ ] Saves: a low layout catch says DIVING SAVE, a catch at the laces says SHOESTRING. Catch in the air and throw before landing: ALLEY-OOP.
- [ ] Quick passes (released within 2 s of the catch) build a PASS CHAIN xN on the HUD and fill FLOW for both players.
- [ ] Anime sprint: past run speed the body pitches low with the arms straight back. Catches snap the disc into the chest; throws snap through the follow-through.

### 0b. Art (Config/Art, ForgeGUI images on Roblox)
- [ ] The scoreboard bar and the menu buttons show the new art (not stretched badly, text readable on top).
- [ ] A selected tab, a toggle that is on and the gold Play button still show their colour (the art steps aside for state colours).
- [ ] Empty an id in `Config/Art.luau`: that element falls back to the drawn look.

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
