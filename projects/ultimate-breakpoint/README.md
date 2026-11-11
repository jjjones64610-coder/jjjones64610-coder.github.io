# ULTIMATE: BREAKPOINT

A Roblox ultimate frisbee game built around movement skill: fast, smooth
running, snap cuts, plants, bursts, slides, layouts and wall rebounds, plus
**flip-reset style resets**. Tip the disc out of the air to get your air
moves back, then chain them into **signature moves** (Reset Grab, Double Tip,
Wall Tip, Double Layout…). It's real ultimate underneath: pulls, a **pivot**
you step around to break the mark, stall counts, turnovers, Callahans and the
Greatest. **PvP** in two modes, **Mini 3v3** and **Normal 7v7**, where bots
only fill empty spots, and everyone plays with the same **fixed hitbox**.

* **Design:** [`docs/DESIGN.md`](docs/DESIGN.md) covers every mechanic, number and counterplay.
* **Testing:** [`docs/TESTING.md`](docs/TESTING.md) covers what was verified offline and the Studio test plan.

> **Status — honest version.** The full game is written in strict Luau. It
> type-checks against the real Roblox API, lints clean and passes 230
> offline tests: movement fuzzing with resets, rules, physics, catch and tip
> geometry, signature moves, modes and teams. **It has not been run in Roblox
> Studio.** This version reworks movement after the first playtest (the
> character now moves through its own Humanoid, so running is smooth), adds
> the pivot, the two PvP modes on bigger fields, the fixed hitbox and the
> reset/signature system. Expect tuning on first play; `docs/TESTING.md` §2
> is the checklist. If something errors, copy the red `[Breakpoint]` or
> `MOVEMENT ERROR` lines from the Output window.

> **The tech engine (default).** Movement, catching and defense now follow
> [`docs/tech-spec.md`](docs/tech-spec.md): a momentum core (Movement/TechCore,
> every number in Config/Tech) with Burst, cuts, jukes, plant stops, slides,
> slide hops, air dodges, wavedash, reverse snap, burst dive, layouts, tech
> rolls and Sky; timed catching with Perfect Catch and Hot Hands; Mirror Step
> and the contact rule; anime-style poses and effects; four **abilities**
> charged by skill; bots on the same engine. Still to build from the spec:
> its disc flight model and throw controls (snap release, edge and angle on
> the mouse, fake switch), the 1.2-stud pivot, hand block / bid, fouls and
> per-tech training drills. **Menu → Settings → New movement core** off
> brings back the classic engine. Nothing tells you what chains off what:
> that is for players to find.

---

## Quick start

### Option A — open the place file
1. Open **`build/UltimateBreakpoint.rbxlx`** in Roblox Studio (File → Open from File).
2. Press **Play** (F5). You spawn on the sideline for warm-up. Alone, a
   **Mini 3v3 against bots** starts after ~30 s. In Studio you are the host:
   **M → Play → START MATCH NOW** skips the wait and lets you pick Mini or Normal.
3. Try **M → Training → Reset Lab** for the tip resets and signature moves,
   and **Break the Mark** for the pivot.

### Option B — Rojo (for editing the code)
1. Install [Rojo](https://rojo.space) 7.4+ and the Rojo Studio plugin.
2. `rojo serve` in this folder, then connect from the plugin in an empty place.
3. Or build a fresh place: `rojo build default.project.json -o build/UltimateBreakpoint.rbxlx`.

### Studio settings
| Setting | Where | Why |
|---|---|---|
| Avatar type **R15** | Game Settings → Avatar (also set in the place) | poses, leg IK and the standard body target R15 |
| **Enable Studio Access to API Services** | Game Settings → Security (after publishing) | saving, ranked rating, leaderboard. Without it the game runs and says progress isn't saved |
| Multiplayer test | Test → Clients and Servers (2–14 players) | PvP, catches, tips, marking, replication |
| Server size ≥ 16 | Game Settings → Places (when published) | Normal 7v7 plus a bench |

Place-level properties are set in `default.project.json`: gravity 160,
streaming off, Future lighting, shift-lock off, the default character
controls replaced (movement modes Scriptable; the game reads input itself).

### Required Roblox objects
**None to build by hand.** At runtime the server creates the remotes
(`ReplicatedStorage.UBRemotes`), match state (`UBState`), discs (`UBDiscs`),
the Teams (TIDE, BLAZE, SIDELINE), the arena with benches, the Training hall,
`Workspace.UBBots` and the collision groups. Clients create `Workspace.UBVisuals`
and the `UBInterface` ScreenGui.

---

## Controls (defaults, all rebindable in Menu → Controls)

Everything sits under the left hand around WASD (the tech-spec layout):

| | Keyboard / mouse | Gamepad |
|---|---|---|
| Move | WASD | left stick |
| Jump (tap / hold) · Air Dodge (in the air) | Space | A |
| Burst (hold) · Burst Kick (tap) | Shift | LB |
| Cut (with a new direction) · Plant Stop (no direction) | Q | RB |
| Layout / Dive (aims with the camera) | E | X |
| Slide (hold; in the air: Fast Fall) | C | B |
| Catch (timed) · Throw (hold, release) | LMB | RT |
| Fake / mark / tip | RMB | LT |
| Overhead modifier | F (hold) | Y (hold) |
| Ability (when FLOW is full) | G | L3 |
| Menu · free mouse · celebrate | M · LeftAlt · B | Select · — · D-pad down |

Catching is a press: hit LMB as the ring on the disc closes on your hands
(gold = Perfect). Pick your ability in **Menu → Settings → Ability**; FLOW
fills from Perfect techs, catches, blocks and goals. The tech debug HUD
(speed, state, Burst, the last timing in ms) is on in Studio.

---

## Project layout

```
default.project.json        Rojo project (place settings + script locations)
build/UltimateBreakpoint.rbxlx   ready-to-open place (generated by rojo build)
src/shared/                 ReplicatedStorage.Shared — pure, tested modules
  Config/                   ALL tuning: Movement (incl. resets), Disc, Hitbox,
                            Signatures, Modes, Arenas, Input, Progression,
                            Audio, Teams
  Movement/MovementSim      movement engine (client sim, server mirror, bots)
  Disc/DiscPhysics          deterministic flight model
  Disc/ThrowModel           inputs -> launch (types, bank, height, pivot step)
  Disc/Solver               lead-pass solver (bots, launcher, assist)
  Rules/RulesEngine         the sport as a state machine
  Rules/MatchPlan           teams, bench, per-point lines, bot fill, ranked
  Rules/CatchGeometry       catch, tip and mark volumes, contests, bobbles
  Rules/Signatures          signature move recognition
  Rules/FieldGeometry       bounds, end zones, line-up and bench spots
  Rules/ComboEvaluator      combo chains and payouts
  Rules/Rating              Elo, levels, team balance
  Animation/Locomotion      blended walk/run animation
  Net, Actors, Util/*       remote names, player/bot ids, helpers
src/server/                 ServerScriptService.Server
  Main.server.luau          bootstrap (Init/Start in order)
  Services/                 Player, Data, Arena, Movement (validation),
                            Disc, Catching, Defense, Throw, Leaderboard,
                            Progression, Highlight, Team, Bot, Training, Match
  Arena/                    ArenaBuilder (6 themes), TrainingBuilder, Build
src/client/                 StarterPlayerScripts.Client
  Main.client.luau          bootstrap
  Controllers/              Settings, Input, Camera, DiscRenderer, Movement,
                            Catch, Throw, Pose, Audio, Effects, UI
  UI/                       Theme, Hud, ThrowHud, Menu, Panels, Mobile
src/character/Animate       replaces Roblox's default Animate script
tests/                      Lune harness + specs, place structure check,
                            flight table generator
scripts/check.sh            format, lint, types, references, tests, build
docs/                       DESIGN.md, TESTING.md
```

## Development

Tools used (all free): Rojo 7.4.4, luau-lsp 1.70 (with Roblox
`globalTypes.d.luau`), Selene 0.27, StyLua 0.20, Lune 0.9.4.

```
ROBLOX_DEFS=path/to/globalTypes.d.luau ./scripts/check.sh   # everything
lune run tests/run.luau                                     # tests only
lune run tests/run.luau signatures                          # one spec
lune run tests/flight_table.luau                            # throw table
```

---

## What changed after the first playtest

| Feedback | Change |
|---|---|
| "You can't really run" | The Humanoid now moves the body from the movement sim's velocity every frame. Before, a weak force fought a Humanoid told to stand still. Auto-sprint, faster stops and tighter turns. |
| "The moving mechanics and combos don't work" | Every press does something or says why; 0.15 s input buffer; cuts judged against your line from before the steer; no lockouts; a combo widget from the first technique. |
| "The field is too small" | Normal field 360 × 136, Mini 240 × 90; throws retuned to fit; flights 1.5× faster so throws outpace runners. |
| "PvP 3v3 (mini) and 7v7 (normal)" | Exactly those two modes, picked by head count or vote; bots only fill empty spots; bench rotation; automatic ranked. |
| "Pivot with the disc to break the mark" | Planted pivot foot, WASD step-out, Q/E quick swings, fakes, hop; the throw leaves from where you stepped; markers shuffle, aim their hands and switch stance. |
| "Feels janky" | Fixes to teleports, speed checks, the catch pipeline, disc blending, animation, camera, aim convergence, leg posing and remote poses. |
| "Everyone has a fixed hitbox" | Standard body scales on spawn and gameplay zones measured from the feet; optional overlay. |
| "Combos like a flip reset" | Tip resets, wall/landing/recovery resets, Charged moves and nine signature moves worth up to 3000 points. |

## Not done yet
* Cross-server ranked **matchmaking** (MemoryStore queue + reserved servers).
* Authored animations and audio (ForgeGUI sound generation needs a paid
  plan; the art in `Config/Art.luau` is ForgeGUI-made). Poses are procedural and sounds are engine
  built-ins; the crowd-loop slots are empty for your own uploads.
* Bots don't tip or chase signature moves.
* Contact fouls aren't called yet (the contact rule only costs speed).
* Everything in `docs/TESTING.md` §0 and §2 needs a first run in Studio.
* From the tech spec: the disc flight model (5), throws 23–27 and 29 (the
  current throw system stays), Hand Block / Bid / Force (30–31, 33), one
  training drill per tech (9), and the network pass (10). Bots hold the
  disc on the classic engine.
