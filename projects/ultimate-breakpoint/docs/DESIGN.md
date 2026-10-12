# ULTIMATE: BREAKPOINT — Design

> Ultimate frisbee turned into a competitive movement-skill sport.
> A beginner sees a disc, runs to it, catches it and gets it. An expert plants,
> restarts, bursts into a lane, takes a lead pass at full extension and pops up
> into a quick release before the defense can turn around.

**Why "Breakpoint".** In ultimate, a *break* is a throw around the marker to the
side they are denying, and *breaking* a defender is what good cutting does. The
whole game is built around creating those two moments, so the working title
stayed.

All numbers below come from `src/shared/Config/*.luau`. Change them there; the
offline tests (`tests/`) will tell you if a change breaks an invariant
(speed caps, flight shapes, rule outcomes).

---

## 1. Pillars → where they live in the design

| Pillar | How it shows up |
|---|---|
| Skill over randomness | No hidden rolls anywhere. Throws, catches, bobbles, blocks and bot noise are deterministic functions of inputs and positions (bots use a seeded RNG for personality, never for outcomes). |
| Movement is a competitive mechanic | A sprinting player turns on a ~7-stud radius. Getting open requires techniques with timing windows (§3). |
| The disc is the centre | Combos only pay out when converted into a catch, block or interception (§7). |
| Easy to learn | WASD + Shift + Space + click works: running into the disc catches it, holding and releasing the mouse throws. Movement School teaches the rest. |
| Hard to master | Every technique has a Perfect/Clean/Sloppy window, chains have their own windows, throws have five types × bank × height × timing. |
| Earned spectacle | Highlights are detected from validated server facts only (§7). |
| Integrity / counterplay | Every technique has a cost, cooldown or commitment. Defenders get the same toolkit plus mark stances and hand blocks (§5). |
| Responsive controls | Movement is simulated on the client with zero input latency; the server validates instead of round-tripping (§11). |
| Teamwork | Stall count, no running with the disc, the Flow bonus for quick releases, and bots/humans who mark goal-side make passing the only way up the field. |
| No pay-to-win | Progression unlocks are cosmetic only (§9). There are no purchases in the code. |

---

## 2. Scale and feel

* 1 metre ≈ 3 studs (a 5.3-stud avatar ≈ 1.77 m).
* Sprint 26 studs/s (≈ 8.7 m/s, elite-runner pace), jog 17, hard cap 34.
* Character gravity 160 studs/s² with a 44 studs/s jump: ~6 studs of air in 0.55 s.
  Stylised and readable, but the disc uses real-scale physics (§4), so hang
  times and running under a huck feel like the real sport.
* Field (Standard): 190 × 100 playing proper, 40-stud end zones, brick 40 studs
  in. Small (Rush/Clutch): 124 × 76, 28-stud end zones.

---

## 3. Movement engine (`Movement/MovementSim.luau`)

### 3.1 Modes

```
            jump / dive / walk off edge
   Ground ───────────────────────────────► Air ──(dive)──► Dive
     ▲  │ slide                              │                │
     │  ▼                                    │ touch down      │ touch down
   Slide ──(slide ends / slide cut)──► Ground ◄── Landing ◄────┘ (no dive)
                                             ▲                 │
                                             │                 ▼ (dive)
                            Recover ◄─── DiveSlide        Precision Landing
                              │  pop window (0.2 s)          (skips Landing /
                              └──── Recovery Chain ──► Ground   becomes Roll-out)
   Frozen: line-ups and pulls. Holding: an overlay on any mode (decel → pivot).
```

### 3.2 Momentum model

Velocity is horizontal; vertical belongs to physics. Each frame on the ground
the desired velocity (input × top speed) is split into the component **along**
the current velocity and the component **across** it:

* along: speed up at 58 studs/s² (95 from below 7 studs/s), brake at 80 if the
  input opposes motion, coast down at 50 with no input, bleed overspeed at 38;
* across: limited to 92 studs/s² of lateral acceleration.

So turning radius = v² / 92: 7.3 studs at sprint, 3.1 at jog. A plain reversal
from sprint takes ~0.75 s. That cost is what techniques buy back.

In the air, control is 20 studs/s² and can never raise speed more than 3 above
takeoff speed (or 10, whichever is higher). With no input, momentum is kept.

**Exertion** (0–100): sprinting drains 4.5/s; each technique has a cost;
regeneration is 20/s after 0.6 s without sprinting or techniques. When a
technique costs more than you have, it still happens, as a weaker *Gassed*
version (no lockouts that stop play). Below 15 exertion, sprint top speed
slides from 26 toward 21.

### 3.3 Techniques

All are reached from five actions — **Cut, Burst, Slide, Dive, Jump** —
pressed in a context and at a time.

| Technique | Input / context | Effect | Timing & quality | Cost / limits | Counterplay |
|---|---|---|---|---|---|
| **Snap Cut** | Cut with input 25–115° off travel, ≥ 9 studs/s | instant redirect keeping speed × retention | *Perfect* if you held one line ≥ 0.6 s at ≥ 85 % sprint (96 % kept, +2); *Clean* after ≥ 0.32 s (86 %); *Sloppy* otherwise or within 0.4 s of the last cut (62 %). Sharper angles lose up to 15 % more. | 10 exertion, 0.2 s min interval | Zig-zag spam bleeds speed; a defender who stays goal-side and doesn't bite on the line keeps up. |
| **Momentum Cancel** | Cut with input >115° off travel (or no input), ≥ 12 studs/s | 0.12 s plant at 330 studs/s² braking | Restart with Cut/Burst/Jump **0.10–0.32 s** after: 0.10–0.21 s = *Perfect* (leave at 92 % sprint), later = *Clean* (76 %). Pressing before 0.10 s locks restarts out for 0.15 s (no mashing). | 10, 0.45 s cooldown | A mistimed plant leaves you standing still next to your defender. |
| **Fake Commit** | Cut along travel (or while standing) | jab step: −20 % speed (or a 9 studs/s side jab) and a forward lean | Any cut ≥ 30° away within 0.45 s is **Sold**: always Perfect and leaves at ≥ 80 % sprint. Opponents see a generic lean — the same as a Burst's first frames. | 6, 0.7 s cooldown | Defenders who wait for actual displacement instead of the lean aren't fooled, but are a beat late on real bursts. |
| **Burst Step** | Burst on the ground | 0.2 s locked burst at max(speed, sprint) × 1.2 (29–32.5) | *Perfect* within 0.15 s of a Snap Cut; out of a plant window it is free and Perfect/Clean by the plant timing | 22, 1.6 s cooldown | Direction is locked for 0.2 s; read it and take the lane. |
| **Slide** | Slide while ≥ 14 studs/s | low slide, friction 13, steer 50°/s, ≤ 0.9 s; +3 speed (never past 29) | — | 8, 0.7 s | Low catch zone; you can't burst or dive out of it; slide hops can't exceed 29. |
| **Slide Cut** | Cut during a slide (after 0.15 s), ≤ 120° | leave the slide on a new line | 0.3–0.6 s into the slide = *Perfect* (94 %), else *Clean* (84 %) | 8 | — |
| **Jump** | Jump on ground/slide (0.1 s coyote time) | 44 + up to 5 with speed | slide hop keeps slide speed | — | — |
| **Air Redirect** | Cut in the air | rotate up to 80°, keep 92 %/82 %, arrest a fall to ≥ −6 | near the apex (\|vy\| < 9) = *Perfect* | 12, once per airtime (refreshed by a rebound) | Only one per jump; still committed after it. |
| **Layout (Dive)** | Dive on the ground or once in the air | ground: speed+4 clamped 24–32 with a 20 studs/s hop; air: +9 (≤ 31) | *Perfect* within 0.25 s of a Snap Cut/Burst/Slide Cut/Air Redirect/Recovery Chain | 18, 1.1 s cooldown | You slide 0.5–0.8 s and recover 0.5 s if you miss. |
| **Precision Landing** | Slide pressed ≤ 0.15 s before touchdown (or ≤ 0.06 s after) | no landing penalty, keep 100 %/96 % | offset ≤ 0.05 s = *Perfect*. Pressing earlier than 0.15 s locks it for 0.3 s. | free | Missing it costs 12 % speed and 0.12 s of reduced steering. |
| **Roll-out** | Precision Landing out of a dive | 0.16 s recovery keeping 72 %/58 % | as above | free | — |
| **Recovery Chain** | Cut / Burst / Jump in the 0.2 s pop window when a dive slide stops | skip the remaining recovery and leave at 75 %/55 % sprint (or pop-up jump) | first 0.09 s = *Perfect*. Pressing while still sliding locks out 0.25 s. | — | — |
| **Wall Rebound** | Jump in the air within 3 studs of a `Rebound`-tagged wall | reflect + push off (×0.9), 36 up | within 1.2 studs = *Perfect* | 10, 2 per airtime, never the same wall twice | Only in special arenas and the Combo Lab. |
| **Aerial Reach** | Primary while airborne | Catch Adjustment: hand extends toward your aim | — | once per airtime for combo credit | — |

**Holding the disc** (no running): after a catch you may only decelerate
(52 studs/s², ≤ 0.65 s, direction locked); then a pivot is set and you may move
within 3.2 studs of it at 10 studs/s. A hop (Jump) allows a high release but you
must release before landing ("travel" otherwise). All techniques are disabled.

### 3.4 Combinations

Techniques chain because each one's *exit state* is another's *entry
condition*, and several have explicit chain windows:

* Sprint → Snap Cut → Burst (≤ 0.15 s = Perfect) → separation catch.
* Fake Commit → Snap Cut (Sold, always Perfect).
* Sprint → Momentum Cancel → Restart Cut / Explosive Burst (0.10–0.21 s).
* Jump → Air Redirect (at apex) → Precision Landing → immediate Snap Cut.
* Slide → Slide Cut (0.3–0.6 s) → Burst → end-zone run.
* Snap Cut → Layout (≤ 0.25 s = Perfect) → Roll-out or Recovery Chain → mark.
* Wall Rebound → Air Redirect → Layout (Rebound arenas).

Nothing is a canned animation; every link is a separate input you can choose
to make or skip.

### 3.5 Anti-exploit invariants (tested)

* Horizontal speed is clamped to 34 every step. `tests/movement_spec` runs
  40 × 3000 random frames of random inputs, techniques, wall contacts and
  holding toggles and asserts the cap, no NaN and exertion bounds.
* Slide-hop chains are proven not to exceed the 29 slide ceiling.
* Every timing window has an early-press lockout (plant restart, precision
  landing, recovery pop) so mashing performs worse than timing.
* Cooldowns and costs are mirrored on the server (§11).

---

## 4. Disc physics (`Disc/DiscPhysics.luau`)

State: position, velocity, spin-axis normal **n**, spin rate. Fixed step 1/120 s,
semi-implicit Euler, plain doubles (not float32 `Vector3`) so the server and every
client compute bit-identical flights from the same replicated launch values.

* **Lift** `K·|v|²·CL(α)` along n minus its airflow component: tilting (banking)
  the disc tilts lift, which curves the flight. `CL = 0.15 + 1.4α`, stalling past 0.45 rad.
* **Drag** `K·|v|²·(0.08 + 2.72(α + 0.07)²)`, capped at 1.2.
* **Precession**: the pitching moment `CM = −0.01 + 1.0α` rolls the spin axis at a
  rate ∝ |v|²·CM / spin. Low α (fast, flat) rolls one way (*turn*), high α (slow,
  descending) the other (*fade*). The spin sign decides which way is which, so a
  right-handed backhand turns slightly right and fades left, a forehand mirrors
  it, and low spin (an overcharged release) rolls more.
* **Wind** enters through the airflow (velocity relative to the air). It is
  constant per arena, shown on the HUD, and teams switch ends every point.
* Real-world frisbee coefficients (Hummel 2003) converted to studs
  (K = 0.0665/stud, g = 29.4 studs/s²), then tuned so that flights read well;
  see `tests/disc_spec.luau` for the shape assertions.

### 4.1 Throws (`Disc/ThrowModel.luau`, right-handed, flat aim, no wind)

| Throw | Hold | Bank | Release | Speed | Range | Hang | Apex | Lateral |
|---|---|---|---|---|---|---|---|---|
| Backhand | 0.15 s | 0 | Clean | 45 | 57 | 2.3 s | 8 | −7 (fades left) |
| Backhand | 0.35 s | 0 | Clean | 62 | 96 | 3.6 s | 16 | −14 |
| Backhand | 0.60 s | 0 | **Perfect** | 82 | 136 | 4.8 s | 27 | −2 (S-curve) |
| Forehand | 0.60 s | 0 | Over (charges 1.2× faster) | 74 | 123 | 4.3 s | 22 | +11 (fades right) |
| Hammer | 0.60 s | 0 | Perfect | 70 | 106 | 2.6 s | 20 | inverts, drops steeply |
| Scoober | 0.50 s | 0 | Perfect | 49 | 55 | 1.4 s | 10 | +5, inverted flip |
| Blade | 0.60 s | 0 | Perfect | 78 | 106 | 1.9 s | 8 | −20, fast edge dive |
| Backhand | 0.60 s | right | Perfect | 82 | 119 | 2.5 s | 15 | +42 |
| Backhand | 0.60 s | left | Perfect | 82 | 136 | 3.4 s | 16 | −61 |

(units: studs, studs/s.) Regenerate with the snippet in `docs/TESTING.md`.

### 4.2 Throwing skill — every input matters, nothing is rolled

* **Charge** — power rises linearly to full at 0.55 s (scaled by the type's
  charge rate). Releasing inside the 0.10 s window right after full charge is a
  **Perfect** release: +5 % speed, +15 % spin (a tighter, more stable line).
  Holding longer is *Over*: spin decays 0.8/s to a floor of 0.6, so the disc
  rolls more. Short holds are clean touch passes.
* **Aim** — camera yaw/pitch (+ each type's elevation offset).
* **Bank** — 7 steps (±35°) with Q/E: the disc goes where it is tilted, then
  fades by spin. Inside-out / outside-in emerge from bank + type.
* **Release height** — *Mid*; *Low* (hold Slide: a step-out at knee height up
  to 2.4 studs wide of the body, under a high mark); *High* (hop with Jump and
  release in the air, over a low mark).
* **Balance** — throwing airborne (other than a hop), off a layout from the
  ground, or while still moving > 12 studs/s costs power cap and spin.
* **Carry** — 45 % of the thrower's horizontal velocity is added (quick
  releases out of a running catch).
* **Fake** — Secondary plays the identical windup defenders see on a real
  throw, then cancels (0.3 s cooldown).
* **Lead Pass assist** (optional, R) — solves aim for the teammate nearest the
  crosshair using their *current* velocity and marks the ideal power on the
  meter. It cannot predict a cut, and you still have to release on the mark.
* **Preview arc** — shows the first fraction of the predicted flight: 100 % in
  training, 50 % casual, 35 % clutch, 20 % ranked.

---

## 5. Catching and defense

### 5.1 Catch zones (`Rules/CatchGeometry.luau`)

* **Secure**: 2.4-stud sphere at the chest (drops 1.4 studs while sliding).
* **Reach**: Primary opens a 0.28 s window; a 3.6-stud capsule from the near
  shoulder along your aim (a soft assist bends it toward a disc within 8 studs
  and 55°). Airborne reaches are the *Aerial Catch Adjustment*.
* **Dive**: during a layout, a 5.2-stud capsule along the dive direction.

Inside 60 % of a zone's radius is a **Clean** catch; near the rim is a
**Fingertip** catch.

### 5.2 Contests, bobbles, blocks — explainable outcomes

* The earliest touch wins. Touches within 0.06 s of each other are a contest,
  won by the cleaner hand (smaller depth into the zone).
* A **fingertip** winner of a contest, or a fingertip catch of a disc moving
  faster than 70 studs/s relative to the hand, **bobbles**: the disc pops up and
  stays live (anyone can catch it). Clean catches never bobble.
* A defender's **fingertip** contact is a **block** (knocked down, live).
  A defender's clean contact is an **interception**.
* Nobody can catch in the first 0.15 s of a throw; the thrower can't catch
  their own throw unless someone else touched it.

### 5.3 The mark

* **Stall count**: one count per second (configurable) while an opponent is
  within 9 studs; 10 is a turnover (7/8 in Rush/Clutch). Pauses on a double
  team (a second defender in range who isn't guarding anyone else) and on a
  disc-space violation (marker inside 2.6 studs for 0.4 s); resets after 1.5 s
  unmarked.
* **Mark stance** (hold Secondary): *Low* = wide hands, knees to chest
  (±3.2 studs, 0.6–4.4 up); *High* (aim up) = narrower (±2.6), 4.6–8.6 up. Jumping
  lifts the zone. The stance is visible on the defender's body.
* **Hand blocks**: on every release the first 0.3 s of the flight is tested
  against nearby defenders' hand zones. Counter: pivot (3.2 studs), fake to
  move the hands, step-out low under a high mark, hop high over a low one, or
  throw the hammer over a low mark.

### 5.4 Defensive depth

Defenders use the full movement toolkit: anticipating a throw, cutting into
the lane, laying out (*Layout D*), and Recovery-Chaining back to their man.
The interception drill teaches lane positioning and reports your distance from
the throwing lane at the moment of release. Players never collide (non-contact
sport; collision groups), so there are no body-blocking stun locks.

---

## 6. The sport (`Rules/RulesEngine.luau`)

* Pull to start each point (or the offense starts with the disc at its goal
  line in Rush/Clutch). Receivers take it where it stops, or at the brick if
  it lands out; touching and dropping the pull is a turnover.
* No running with the disc (deceleration + pivot, enforced client and server).
* Turnovers: incomplete, dropped, blocked, out of bounds, stalled out.
  Turnover spots inside an end zone move to its goal line.
* A catch counts where the receiver first touches down. Airborne receivers
  must have left the ground in bounds. Catch in the end zone you attack: goal.
  A defender who intercepts in the end zone they defend: **Callahan** (goal).
* Catch airborne past a line and release before landing: **the Greatest**.
* Teams switch direction after every goal; the scored-on team receives.
* First to N; time cap finishes the current point; tied after the cap (or
  both teams at game point) → **universe point**.
* Line itself counts as in bounds (readability on a Roblox field).
* Not modelled: contact fouls (players do not collide), picks, injury calls.

Every rule above is unit tested in `tests/rules_spec.luau`.

---

## 7. Combos and highlights

`Rules/ComboEvaluator.luau`:
`event = base × quality (Perfect 1.5 / Clean 1 / Sloppy 0.5 / Gassed 0.3) ×
variety (repeat 0.25, in last three 0.6, new 1)`,
`chain = Σ × length bonus (1 + 0.2 per scoring tech, max 3) × unique bonus
(+0.08 per distinct tech, max 1.4)`. Chains end after 1 s without a technique.

Chains only pay out (XP, highlight tags, ×2) when **converted** into a catch,
interception or block during the chain or within 1.25 s of it. Pure movement
spam shows labels and nothing else. Tiers: NICE 400, SLICK 900, FILTHY 1600,
BREAKPOINT 2600.

`HighlightService` tags plays from server-validated facts only: LAYOUT, SKY
(airborne catch with a defender within 4.5 studs), HUCK (≥ 120 studs),
CONTESTED, FLOW ×N (consecutive quick releases), tiered COMBO, INTERCEPTION,
LAYOUT D, HAND BLOCK, BLOCK, CALLAHAN, GREATEST, HAMMER/BLADE/SCOOBER goals,
FLOW STATE (10+ pass point), CLUTCH, UNIVERSE. A highlight is a 2.6 s banner
and a crowd reaction; play never pauses and the camera is never taken away.

---

## 8. Training (`TrainingService.luau`)

A separate hall (built at `Arenas.TrainingOrigin`). Walk to a terminal and
press G (or use the menu):

| Drill | What it measures | Feedback you get |
|---|---|---|
| Movement School | every technique once, then a catch and a Perfect throw | step prompts; "released early / held too long" |
| Cutting Course | 8-gate slalom time trial (+2 s per missed gate) | splits, the slowest section and its speed, a technique suggestion, techniques used, PB |
| Momentum Shuttle | A→B→A→B→A | each reversal time graded, with "plant + restart 0.1–0.3 s later" advice when slow, PB |
| Aerial Catch | 10 scripted launches: floaters, skimmers, hammers, blades, layouts | miss distance, whether it was above/below/beyond you, whether your reach was early or late |
| Throwing Range | 10 throws at 4 rings + a moving ring | hit/miss distance, left/right + short/long with the fix, release quality, power, spin, bank |
| Interception Drill | bot thrower leads a bot receiver on 8 routes | INT/BLOCK/completion and your distance from the lane at release |
| Combo Lab | 8 named chains (with rebound walls) | completion checklist |
| Free Launcher | custom type, power, angle, curve, offset | catch quality and zone |

---

## 9. Progression (cosmetic only)

XP from playing, winning, catches, completions, goals, assists, blocks,
layouts, highlights, converted combos and drills; level curve `300 + 75·level`.
Unlocks: disc skins, movement trails (thin, translucent, only while > 18 studs/s),
celebrations (procedural poses), banners, titles; achievement-gated items
(Callahan Crest, Layout Artist, Hammer Time…). Stats, technique mastery
(count and Perfect %), personal bests and achievements are persistent.
Ranked: team Elo (K 40 for 10 placement games, then 24, small margin factor),
divisions Bronze → Breakpoint, seasonal OrderedDataStore leaderboard.

---

## 10. Arenas

Six themes on the same field: **Championship Stadium** (floodlights, packed
stands), **Coastal Sunset** (sea breeze 2.5), **Neon Rooftop** (skyline,
neon lines, breeze 1.5), **The Lab** (indoor, still), **Community Park**
(trees, playground) and **Windy Beach** (7 studs/s crosswind, casual only),
plus **Neon Rooftop: Rebound** with glowing sideline walls (special rules,
never ranked). End zones glow in the colour of the team attacking them.

---

## 11. Networking and architecture

### Authority

| Server decides | Client owns (validated) |
|---|---|
| possession, scoring, turnovers, rules, stall count | its character's physics and movement techniques |
| every disc launch (from the thrower's *inputs*) | camera / aim |
| every catch, block, bobble, hand block | catch *claims* (timestamped) |
| match state, teams, bots, progression, data | visual prediction of its own throw/catch |

### Per action

* **Movement**: simulated locally (zero latency). Technique events go to the
  server in one small batch per frame *only when something happened*. The
  server checks names, rate (≤ 12/s), mirrored cooldowns and an exertion
  budget, and replicates accepted ones as character attributes so every
  client poses that character. Speed is checked over 0.2 s windows against
  the cap + slack; repeated violations snap back. A holder leaving their pivot
  is snapped back (travel).
* **Throws**: the client sends type, aim, hold time, bank, height. The server
  measures the charge itself, decides balance from its own grounded check,
  recomputes the launch from its view of the thrower and checks hand blocks.
* **Flights**: the server writes launch values into the disc's attributes;
  every client re-simulates the identical deterministic flight on server time.
  No per-frame disc replication at all.
* **Catches**: the client detects contact where its body really is and claims
  with a server timestamp. The server rewinds the *disc* (≤ 0.3 s history),
  builds catch zones from its view of the claimer (which lags by about the
  same latency) and adds ping-scaled slack (≤ 3.5 studs). Claims are pooled
  for 0.1 s so simultaneous touches are a fair contest. Ground contact waits
  0.2 s for late claims. The claimer's disc snaps to the hand immediately and
  corrects if the server decides otherwise.

### Code map

```
src/shared   pure modules (MovementSim, DiscPhysics, ThrowModel, Solver,
             CatchGeometry, FieldGeometry, RulesEngine, ComboEvaluator,
             Rating), configs, Net (remote names), Actors (player/bot ids),
             Locomotion animation
src/server   Main + Services: Player, Data, Arena, Movement (validation),
             Disc, Catching, Defense, Throw, Leaderboard, Progression,
             Highlight, Team, Bot, Training, Match; Arena builders
src/client   Main + Controllers: Settings, Input, Camera, DiscRenderer,
             Movement, Catch, Throw, Pose, Audio, Effects, UI; UI modules
src/character  Animate (replaces Roblox's default, velocity-driven)
```

### Performance budget

Server: ≤ 14 root raycasts per frame, one 120 Hz disc sim per active disc, bot
AI at 10 Hz. Client: one disc sim per visible disc, one preview sim while
holding, BulkMoveTo for discs and the crowd (20 Hz), procedural poses within
300 studs. Network: event-driven only; the single stream is the defender's
optional 10 Hz `MarkAim` on an `UnreliableRemoteEvent`.

---

## 12. Controls

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Move / sprint | WASD / hold Shift | left stick / L1 | stick (push fully) / SPRINT |
| Jump · Cut · Slide · Dive · Burst | Space · Q · Ctrl or C · E · F | A · X · B · Y · R1 | buttons |
| Reach / throw (hold) | LMB | R2 | THROW/REACH |
| Mark stance / fake | RMB | L2 | FAKE/MARK |
| Bank · type | Q/E · 1–5, Z/X, wheel | D-pad | BANK, TYPE |
| Lead assist · celebrate · menu · mouse lock | R · B · M · LeftAlt | R3 · D-pad down · Select | LEAD · MENU |

Everything is rebindable (Menu → Controls) and saved with the profile.
Sensitivities, FOV, invert Y, camera shake, toggle sprint, left-handed
throwing, touch button size and audio levels are in Menu → Settings.

---

## 13. Modes

Casual (first to 5, 8 min cap, bots fill to 3 per team), Ranked (first to 7,
12 min, no bots, ≥ 2 humans per side for the result to count), Rush (small
field, stall 7, no pulls, 5 min), Clutch Point (one point, universe from the
start, 90 s). Private servers: the owner (or the first player in Studio) can
edit points, cap, stall count/interval, pulls, bots, preview length, shadows
and field size, and start immediately.

---

## 14. Quality bar — honest self-assessment

| Question | Answer |
|---|---|
| Fun to move without the disc? | Designed for it: the Combo Lab, Cutting Course and Shuttle are movement toys with PBs. **Needs playtesting** to confirm feel. |
| Can a skilled player outperform by movement alone? | Yes, measurably: a plain reversal takes ~0.75 s, a Perfect plant-restart ~0.2 s (tested). |
| Creative chains? | Yes: chains are open-ended inputs with windows, not canned sequences. |
| Throwing rewards execution? | Yes: deterministic, five types × bank × height × timing × balance. |
| Defense can counter? | Mark stances, hand blocks, layouts, lane reading, stall pressure. Needs balance testing with humans. |
| Catches exciting, not random? | Zones are geometric, bobbles follow stated rules. |
| Team strategy matters? | No running with the disc + stall + Flow bonus. Bots are basic, so this needs human playtests. |
| Readable for beginners? | Run into the disc to catch, glowing end zone shows where to score, attack arrow, Movement School. |
| Multiplayer responsive and fair? | Architecture is built for it (client-side movement, deterministic flights, rewind-validated claims). **Not yet measured under real latency.** |
| Long-term depth? | Technique mastery stats, PBs, ranked, tiers. Content beyond this vertical slice is on the roadmap. |
