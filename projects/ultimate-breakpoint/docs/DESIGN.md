# ULTIMATE: BREAKPOINT — Design

> Ultimate frisbee turned into a competitive movement-skill sport.
> A beginner runs to the disc, catches it and throws it. An expert plants,
> restarts, bursts into a lane, tips a disc out of the air to reset their air
> moves, and pivots around a marker to break the mark.

**Why "Breakpoint".** In ultimate a *break* is a throw around the marker to
the side they are denying, and *breaking* a defender is what good cutting
does. The game is built around both moments.

All numbers come from `src/shared/Config/*.luau`; change them there. The
offline tests (`tests/`) encode the intended *relationships* (speed caps,
flight shapes, rule outcomes, reset limits) and fail if a change breaks one.

**Status.** Written and checked offline only (types against the real Roblox
API, lint, 188 Lune tests, place build). It has not been run in Roblox
Studio; see `docs/TESTING.md`.

---

## 1. Pillars

| Pillar | How it shows up |
|---|---|
| Feels good first | The Humanoid moves the body every frame from the sim's velocity (§3.1). Running is the default (auto-sprint); stops and turns are quick; every press does something visible. |
| Skill over randomness | No hidden rolls. Throws, catches, tips, bobbles, blocks and bot noise are deterministic functions of inputs and positions. |
| Hard to master | Timing only changes the *bonus*. The ceiling is in chains, resets and signature moves (§4), break throws from the pivot (§6), and reading the mark (§7). |
| Fair bodies | Everyone has the same fixed hitbox (§2). |
| PvP | Exactly two modes, Mini 3v3 and Normal 7v7; bots only fill empty spots (§10). |
| Integrity | Every technique has a cost, cooldown or commitment; the server validates every technique, reset, tip, catch and throw (§12). |
| No pay-to-win | Progression is cosmetic only. There are no purchases in the code. |

---

## 2. Scale, fields and the fixed hitbox

* 1 metre ≈ 3 studs. Characters: jog 18 studs/s, sprint 28, hard cap 36.
  Gravity 160 studs/s², jump 46 studs/s (+4 at full sprint): ~6.6 studs of
  air in ~0.58 s.
* **Fields** (`Config/Modes.Fields`; `length` is the playing field proper):

  | Field | Width | Playing field | End zones | Brick | Total | Sprint across |
  |---|---|---|---|---|---|---|
  | Mini (3v3) | 90 | 160 | 2 × 40 | 44 | 240 × 90 | ~6 s |
  | Normal (7v7) | 136 | 240 | 2 × 60 | 64 | 360 × 136 | ~9 s (real ultimate ≈ 8.5–9 s) |

* **Fixed hitbox** (`Config/Hitbox`). Every player's avatar is rescaled to
  standard proportions when it spawns (HumanoidDescription scales: height,
  width, depth and head 1, body type and proportions 0; clothes, colours and
  accessories are kept). Bots spawn with the same scales. Gameplay never
  reads the avatar's parts: catch zones are built from a fixed capsule
  measured from the feet (`Hitbox.root`: the root moved so it stands 3 studs
  above the same ground), mark boxes are measured from the ground, and only
  the 2 × 2 × 1 HumanoidRootPart collides (limbs and accessories collide with
  nothing; players never collide with each other). **Settings → Show
  hitboxes** draws everyone's capsule (radius 1.2, height 5.4).

---

## 3. Movement (`Movement/MovementSim.luau`)

### 3.1 How the body moves

The pure sim decides the velocity; the client's Humanoid moves the body:
every frame `WalkSpeed = |v|` and `Move(v.Unit)`. On *impulse* frames
(technique starts, jumps, any jump in the output of more than 4 studs/s) it
also writes `AssemblyLinearVelocity` directly. Jumps set `JumpPower` and
`ChangeState(Jumping)`. Facing is an AlignOrientation (AutoRotate off). The
sim only adopts the body's real velocity when a ray says something solid is
in the way (`env.blocked`) and the body has lagged for 0.08 s. If the frame
ever errors, the body is stopped rather than left running.

Bots run the same sim on the server and drive their Humanoids the same way.

### 3.2 Locomotion

| | |
|---|---|
| Acceleration | 95 % of sprint in ~0.32 s (Accel 70, from rest 140) |
| Stopping | from sprint in ~0.28 s (Coast 100, Brake 130) |
| Turning | sideways accel 260 at jog → 130 at sprint: ~1.2-stud turn radius at jog, ~6 at sprint |
| Plain reversal at sprint | ~0.45 s (a Perfect plant-restart: < 0.2 s) |
| Air | AirAccel 30; air control can add at most 4 over takeoff speed |
| Landing | keeps 96 % of speed, 0.08 s recovery |
| Sprint | **AutoSprint** (default): sprint after holding one direction for 0.3 s; Shift sprints at once; ToggleSprint optional |
| Exertion | 100. Sprinting is effectively free (drain 2/s, regen 8/s); techniques spend it. *Gassed* only below half a technique's cost |

### 3.3 Techniques: every press does something

`MovementSim.press` returns `(ok, reason)`. Presses that are a little early,
in a short cooldown or about to become valid are **buffered for 0.15 s** and
retried every step; there are no lockouts. A refused press says why on the
HUD ("NEED SPEED", "ONE PER JUMP", "BURST READY IN 0.8s"). The HUD's context
line shows what each key does right now.

| Key (KBM) | Context | Technique |
|---|---|---|
| Q | ground, input 25–120° off your line | **Snap Cut**: instant redirect. Judged against the line from *before* the steer started (0.2 s memory), so holding D then Q is still a Perfect cut. Exit ≥ 0.7 × sprint |
| Q | ground, input along your line | 0.1 s look-ahead: a steer inside it makes a Snap Cut, otherwise a **Fake Commit** (jab, then a Sold cut within 0.6 s) |
| Q | ground, no input / > 120° back, at speed | **Plant** (Momentum Cancel): stop in 0.12 s; hold a direction to auto-restart at 0.8 × sprint, or Q/F/Space in the window for 0.95 × (Perfect) |
| Q | below 5.4 studs/s | quick **side step** |
| Q | air | **Air Redirect** (bend up to 80°; no-op and not used up if you already go that way) |
| Q | slide | **Slide Cut** (up to 160°) |
| F | ground / slide | **Burst Step**: +20 % for 0.2 s (1.2 s cooldown; free out of a plant). Above jog it bends your line at most 45° |
| C (or Ctrl) | ground, fast | **Slide** |
| C | air, ≤ 0.35 s before touchdown | **Precision Landing** (Perfect ≤ 0.08 s keeps all speed) / **Roll-out** after a dive |
| E | ground or air | **Layout** dive (above jog it leaves at most 40° off your line) |
| Space / Q / F | as the dive slide stops | **Recovery Chain** pop-up (Perfect within 0.1 s of the slide stopping) |
| Space | air, next to a Rebound wall | **Wall Rebound** (2 per jump, different walls) |
| RMB | air, disc at your hands | **Tip Reset** (§4) |

### 3.4 Resets (the flip-reset family)

Each jump gives **one Air Redirect and one air Layout** (a ground layout
uses the air layout too). A **reset** gives them back mid-air:

* **Tip Reset**: in the air, press **RMB** (gamepad L2, mobile TIP) as the
  disc reaches your hands. Judged on the disc's *closest pass* within
  ±0.12 s of the press against your catch zones plus a hands-up sphere over
  your head; Perfect within ±0.05 s. The disc pops up ~1.5 studs and comes
  back down in ~0.4 s; you get your air moves back, the Layout cooldown is
  refunded, and you get a lift (22, Perfect 28 studs/s up) so you have the
  ~0.4 s you need to use them. Two tips per jump at most, 0.25 s apart. You
  can catch the tipped disc yourself after a 0.25 s touch lock.
* **Wall Reset**: a Wall Rebound also gives both air moves back.
* **Charged**: the first air move after any reset is Charged: an Air
  Redirect keeps all of its speed; an air Layout leaves 4 studs/s faster.
* **Landing Reset**: a Perfect Precision Landing refunds Burst and Layout at
  once (a Perfect Roll-out refunds the Layout).
* **Recovery Reset**: a Perfect pop-up refunds the Layout (→ Double Layout).

The HUD shows your air moves while airborne: `Q AIR CUT · E AIR LAYOUT`, dim
when used, cyan when Charged, plus tips used. A reset flashes cyan round the
body for everyone.

### 3.5 Invariants (tested)

The 120,000-frame fuzz test (random inputs, presses, swings, marking,
holding, walls, blocked bodies and random tip resets) proves: never above
the 36 studs/s cap, no NaN, exertion in range, no vertical impulse above 60,
and the root never strays from the pivot.

---

## 4. Combos and signature moves

### 4.1 Chains (`Rules/ComboEvaluator.luau`)

event = base × quality (Perfect 1.5, Clean 1, Sloppy 0.5, Gassed 0.3) ×
variety (repeat 0.25, in last three 0.6). Chain = sum × length bonus (up to
×3) × unique bonus (up to ×1.4). A chain ends 1.5 s after its last
technique. **Converted** into a catch, interception or block within 2 s:
×2 score, XP and a highlight; unconverted chains pay 25 % as XP. The HUD
shows the chain from the first technique (count, points, tier word, a
draining bar) and a card when it ends.

### 4.2 Signature moves (`Rules/Signatures.luau`, `Config/Signatures.luau`)

Hard, named plays built from the resets. Recognised from validated events on
the server (the client recognises them too, for an instant banner); points
go into the chain, so a catch doubles them. Announced to everyone (practice
in Training stays private), XP by tier, counted per move.

| Move | What | Points |
|---|---|---|
| **Double Tip** | two tips in one jump, then catch it before you land | 3000 |
| **Wall Tip** | Wall Rebound + tip reset in one jump, then the catch | 2500 |
| **The Greatest** | jump from in bounds, catch a disc flying out, throw it back in before landing | 2500 |
| **Reset Grab** | tip, use the reset (air cut or air layout), catch the same disc before landing | 2000 |
| **Self-D** | as a defender, tip it out of the air, then catch it yourself | 2000 |
| **Double Layout** | layout → Perfect pop-up → air layout catch | 1800 |
| **Reset Loop** | Perfect landing reset → burst → Perfect snap cut, twice in one chain | 1500 |
| **Skyball** | catch with your feet > 5 studs off the ground | 800 |
| **Tip Reset** | tip in the air, then use the air move it gave back | 500 |

When one catch completes several, only the highest in that order pays. A
catch confirmed after the landing that ended its airtime still counts in
that airtime (judged by timestamp). Achievements: Reset Artist (10
signatures), Flip Reset (a Double Tip), Self-Made (a Self-D).

---

## 5. Disc physics (`Disc/DiscPhysics.luau`)

Deterministic flight (plain doubles, fixed 1/120 s step) with lift, drag,
gyroscopic precession (turn and fade) and wind; real-frisbee coefficients
(Hummel 2003) in studs. **Tempo 1.5**: every flight runs 1.5× faster than
the real-time model (same shapes and ranges; speeds and spin ×1.5,
accelerations ×2.25), so a mid-range throw outpaces a sprinter about 1.4×
and hucks about 1.6×. Clients re-simulate the identical flight on server
time; nothing is streamed per frame.

### 5.1 Throws (right-handed, flat aim, no wind; `lune run tests/flight_table.luau`)

| Throw | Hold | Bank | Release | Speed | Range | Hang | Apex | Lateral | Best aim |
|---|---|---|---|---|---|---|---|---|---|
| Backhand | 0.15 s | +0 | Clean | 72 | 65 | 1.7 s | 9 | -8 | 67 (+0°) |
| Backhand | 0.35 s | +0 | Clean | 103 | 110 | 2.7 s | 20 | -13 | 126 (-5°) |
| Backhand | 0.60 s | +0 | Perfect | 139 | 157 | 3.5 s | 32 | +13 | 185 (-5°) |
| Forehand | 0.60 s | +0 | Over | 125 | 142 | 3.2 s | 26 | +1 | 165 (-5°) |
| Hammer | 0.60 s | +0 | Perfect | 118 | 132 | 2.2 s | 23 | +3 | 134 (+3°) |
| Scoober | 0.50 s | +0 | Perfect | 83 | 65 | 1.0 s | 11 | +6 | 78 (+18°) |
| Blade | 0.60 s | +0 | Perfect | 132 | 139 | 1.7 s | 9 | -30 | 158 (+11°) |
| Backhand | 0.60 s | +1 | Perfect | 139 | 131 | 1.6 s | 17 | +42 | 138 (+13°) |
| Backhand | 0.60 s | -1 | Perfect | 139 | 160 | 2.8 s | 21 | -75 | 164 (+0°) |

Field fit: a full Perfect backhand (171 flat / 185 best aim) pulled from a
Normal goal line lands around the receivers' brick (176); a Mini pull can
reach the end zone.

### 5.2 Throwing skill

* **Charge**: power rises to full at 0.55 s; release within 0.1 s after full
  = Perfect (+5 % speed, +15 % spin); longer = Over (spin decays).
* **Aim**: the throw converges on what the crosshair points at (the camera's
  centre ray, up to 220 studs), not the camera's own yaw, so over-the-shoulder
  aiming never misses to one side. Pitch comes from the camera.
* **Bank** Z / X (7 steps, ±35°); **type** 1–5, T or the wheel (backhand,
  forehand, hammer, scoober, blade).
* **Release height**: Mid; Low (hold C: knee height, extended toward the
  step); High (hop with Space, release before landing, over a low mark).
* **Fake**: RMB plays the real windup, then cancels (0.45 s apart).
* **Lead Pass assist** (R): solves aim for the teammate nearest the
  crosshair from their current velocity; you still release on the mark.
* **Preview arc**: the first 50 % of the flight (Mini), 35 % (Normal), 20 %
  (ranked); it turns red where it would cross a marker's hands.

---

## 6. Holding the disc: the pivot

* After a catch the slow-down starts on your *claim* (predicted): you keep
  facing your travel while you slide and turn to the camera as you stop. The
  pivot foot **P** plants when speed drops below 4 studs/s (or after
  0.45 s). P is authoritative on the server (`UBPivot`); the client proposes
  it and always adopts the server's value.
* **Step**: WASD (relative to your aim) steps the free foot around P up to
  R = 3.6 studs (lunge forward ≤ 0.75R, drop step ≤ 0.9R) on a critically
  damped spring. The body sits at P + 0.55 × step. The pivot foot stays
  pinned to P on screen; the free leg never swaps.
* **Quick Swing**: Q swings to the left side, E to the right (gamepad X: the
  other side), ~0.18 s, 0.4 s cooldown. Within 0.35 s of a fake it is a
  *Sold* swing; releasing within 0.3 s after a Sold swing is a **Break**
  (250 points).
* **Fake step**: RMB with a direction held lunges the foot 0.6R that way and
  back.
* **Hop**: Space, once per possession: a high release over a low mark. Land
  before releasing and the charge is lost.
* The **release point** is P + step + the type's side and height offsets, so
  a full step-out releases outside a marker's hands. The server validates the
  step against its view of the body (with latency and drive-lag slack).

---

## 7. Catching and defence

### 7.1 Catching (`Rules/CatchGeometry.luau`)

Zones from the fixed hitbox: **Secure** sphere at the chest (radius 2.4;
lower while sliding, on the turf while lying flat after a layout), **Reach**
capsule along your aim for 0.28 s after LMB, **Dive** capsule along the dive.
The client detects contact where your body really is and claims at the
disc's *closest approach* (≤ 0.08 s of tracking). Quality = the minimum depth
over 0.1 s: inside 80 % = Clean, beyond = Fingertip. Fingertip catches of a
very fast disc, or contested ones, bobble. A defender's touch is a Block
only right at the rim (depth > 0.9); deeper is an interception. Claims are
pooled 0.04 s so near-simultaneous touches are a fair contest; every claim is
answered (Denied → the client retries at once).

### 7.2 The mark

A human marker holds **RMB within 8 studs** of the holder's pivot: a mark
shuffle (15 studs/s, quick accel and brake, no turn radius, no drain) with
hands up; **C** toggles Low / High. The hand box faces the marker's facing
blended halfway toward P (at most 35° off): Low ±2.8 wide, 0.8–4.6 up; High
±2.2, 4.4–8.2 up; Relaxed (no stance) a small chest sphere. Jumping lifts it.
Stall range (9) and disc space (2.4) are measured from P, so a lunge can't
cause a disc-space call. Hand blocks rewind markers to where the thrower saw
them (round trip + interpolation, ≤ 0.25 s). Each team's markers force one
side per point (UBState ForceA/ForceB).

**Counterplay.** A shaded marker covers the force side; the break side needs
a full Low step-out or a step plus a little outward aim; a High release
clears Low hands; a hammer clears Low hands unless the marker jumps. A fake
that bites the marker, then a Quick Swing to the other side, beats a human's
reaction time (~3.5 studs to cover in 0.18 s).

**Bots** shade the force side, mirror the step with a reaction lag, switch
stance only on a live windup, jump-block hops and sometimes bite on fakes.
A human who steps up to mark takes over from a bot.

---

## 8. The sport (`Rules/RulesEngine.luau`)

Pulls (out of bounds → brick), no running with the disc (pivot + travel
check), stall count while marked within range (8 in Mini, 10 in Normal),
turnovers (incomplete, out of bounds, drop, block, stall), interceptions,
Callahans, goals only where you land, airborne catches resolved on landing,
the Greatest, time cap (leader wins between points; tie → universe point),
target score (5) with universe point at 4–4. Tips by the throwing team keep
the disc live; a defensive tip is a block (and can be caught for a Self-D).

---

## 9. Training (`TrainingService.luau`)

**Menu → Training** or walk to a terminal (G).

* **Movement School**: 18 steps (run, snap cut, plant, restart, burst, jab,
  sold cut, slide, slide cut, air redirect, precision landing, layout,
  recovery chain, catch, throw, pivot, quick swing, break).
* **Cutting Course**, **Momentum Shuttle**, **Aerial Catch**, **Throwing
  Range**, **Interception Drill**, **Combo Lab** (eight chains, rebound walls).
* **Break the Mark**: 8 reps against a bot marker whose skill ramps 0.5 → 0.85;
  feedback on which side was open.
* **Reset Lab**: high floaters keep arriving over your head at the Combo Lab;
  tip, reset, chase and catch. Ticks off Tip Reset, Reset Grab, Skyball,
  Double Layout, Wall Tip and Double Tip; scores their points (personal best).
* **Free Launcher**: set type, power, angle, curve and offset, then launch.

The Training menu also lists every signature move, how to do it and how many
you have landed.

---

## 10. Modes, teams and PvP (`Config/Modes.luau`, `Rules/MatchPlan.luau`)

| | Mini | Normal |
|---|---|---|
| Players | 3v3 | 7v7 |
| Field | Mini | Normal |
| To win / time cap | 5 / 7 min | 5 / 12 min |
| Stall | 8 | 10 |
| Throw preview | 50 % | 35 % |

* **Which mode**: by head count. Up to 6 humans → Mini; 10 or more → Normal;
  7–9 → players vote between them (default Mini at 7, Normal at 8–9). In a
  private server or Studio the host chooses. The vote list refreshes as
  people join and leave. Countdown 20 s with ≥ 2 humans, 30 s alone
  ("practice vs bots").
* **Teams**: humans are split with rating balance (counts within 1). At most
  TeamSize per team play each point; extras sit on the team **bench**
  (sideline) and rotate in (those who sat out longest first). **Bots fill
  empty spots** so the field is always exactly 3v3 or 7v7; a joining human
  takes a bot's place at the next point; a leaver is replaced by a bot.
* **Ranked** is automatic: a public server, an eligible mode and all-human
  lines (substitutes allowed). Ranked uses a 20 % preview and no special
  arenas, never takes private rules; a ranked leaver takes a loss and the
  result is voided for the others.
* **Private servers**: the host sets mode, bot fill, points, time cap, stall,
  pull, preview and landing shadow, and can start at once.
* **Line-ups**: frozen only 0.6 s after the line-up teleport, then free
  behind your own goal line until the pull (pulled back if offside).

---

## 11. Arenas and progression

Six themes on the same field sizes (Championship Stadium, Coastal Sunset,
Neon Rooftop, The Lab, Community Park, Windy Beach) plus **Neon Rooftop:
Rebound** with glowing walls (special rules, never ranked). Benches on every
sideline. Progression is cosmetic only: XP and levels, titles, trails, disc
skins, celebrations, achievements; ranked rating with divisions and a
leaderboard.

---

## 12. Networking and server authority

| Server decides | Client owns (validated) |
|---|---|
| possession, scoring, rules, stall, pivot P | its character's physics and techniques |
| every disc launch (from the thrower's *inputs*) | camera / aim |
| every catch, tip, block, bobble, hand block | catch and tip *claims* (timestamped) |
| match state, teams, bots, progression, data | visual prediction of its own throws, catches and tips |

* **Techniques**: sent in one small batch per frame only when something
  happened, each with its timestamp (clamped to 0.35 s old). The server checks
  names, rate (≤ 12/s), mirrored cooldowns (including reset refunds) and an
  exertion budget, allows one Air Redirect and one air Layout per airtime
  **plus one per validated reset** (a TipReset only counts right after a tip
  claim it is resolving), and replicates accepted ones as pose attributes.
* **Speed**: a 1 s sliding window against HardCap × 1.15 + 8; a snap only
  after two flagged seconds in a row, keeping rotation; grace after teleports.
* **Pivot / travel**: the root may stray PivotRadius + 1.5 + latency from P on
  two samples 0.1 s apart before a travel reset.
* **Teleports** are an explicit protocol (`UBTeleportPos/Yaw/Face`, then the
  `UBTeleport` counter); the client re-applies them and keeps its state.
* **Ping**: `Player:GetNetworkPing()` is a round trip; the server halves it
  once, and every latency allowance uses that one-way value.
* **Throws**: the server measures the charge, validates the pivot step and
  release point, accepts High only with recent airborne evidence, and checks
  hand blocks against rewound markers.
* **Flights**: launch values in the disc's attributes; every client
  re-simulates the same flight. Deflections are back-dated to the contact.

### Code map

```
src/shared   pure modules: MovementSim, DiscPhysics, ThrowModel, Solver,
             CatchGeometry, FieldGeometry, RulesEngine, MatchPlan,
             ComboEvaluator, Signatures, Rating; Config/* (incl. Hitbox,
             Signatures); Net, Actors, Locomotion, Util/*
src/server   Main + Services: Player, Data, Arena, Movement (validation),
             Disc, Catching, Defense, Throw, Leaderboard, Progression,
             Highlight, Team, Bot, Training, Match; Arena builders
src/client   Main + Controllers: Settings, Input, Camera, DiscRenderer,
             Movement, Catch, Throw, Pose, Audio, Effects, UI; UI modules
src/character  Animate (blended walk/run, replaces Roblox's default)
```

---

## 13. Controls (defaults; rebind in Menu → Controls)

| | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Move · sprint | WASD · auto (or hold Shift) | left stick · auto (L1 / L3) | stick (auto) · SPRINT |
| Jump · Cut · Slide · Layout · Burst | Space · Q · C / Ctrl · E · F | A · X · B · Y · R1 | buttons |
| Throw (hold) / reach | LMB | R2 | THROW |
| Fake / mark (hold near holder) / **tip** (in the air) | RMB | L2 | MARK · FAKE · TIP |
| With the disc | WASD step · Q / E swing · Space hop · C low · Z / X bank · 1–5, T, wheel type · R lead | stick · X swing · A hop · B low · D-pad bank / type · R3 lead | SWING L / R · HOP · LOW · BANK · TYPE · LEAD |
| Menu · free mouse · celebrate | M · LeftAlt · B | Select · — · D-pad down | MENU |
