# ULTIMATE: BREAKPOINT — Core design

This is the design document every change is checked against. It is the
owner's brief, kept word for word below, followed by the decisions made
on top of it.

## The brief

### The core idea

The game should be as hard to master as Rocket League: easy to pick up in the first five minutes, but with a skill ceiling so high that a great player looks like they are playing a different game than a new player. The way Rocket League does this is with very few buttons that combine in deep ways (jump, boost, and air roll alone produce flip resets, wave dashes, ceiling shots, and so on), and that is exactly the philosophy I want here. Depth has to come from how a small number of inputs interact with momentum, timing, and physics, not from adding more buttons or more moves. If you ever find yourself wanting to add a new key for a new action, stop and find a way to make it come out of the existing inputs combined with the player's current state (grounded, airborne, sprinting, holding the disc, diving, landing, and so on), and if you can't, tell me instead of adding the key.

### Controls (keep this list small and fixed)

The full input set should be: WASD to move, mouse to control the camera and aim, Space to jump, Shift to sprint/burst, Left Mouse to throw (hold to charge, release to throw), and Right Mouse to aim/fake while holding the disc. That's it. There is no slide button, no dive button, no crouch button, no C, no Q, no E. Each player has exactly one special ability, and it is triggered with a chord that uses existing keys (default: Space + Shift pressed together, but put the binding in one config spot so we can change it easily). Mobile and controller support can come later, but structure the input code so actions are mapped through one input module and not hardcoded across scripts, so adding those later is easy.

Moves that other games would give their own button must instead come out of combinations and context. For example: pressing Space a second time while airborne with a direction held should be a dive/layout in that direction (similar to how a flip works in Rocket League), so diving is part of jumping, not a separate key. A slide should happen naturally when the player cuts hard at high speed or lands out of a dive, not from a button. A fake should be Right Mouse into a canceled throw. Good players should be able to chain these: cut, jump, dive, catch out of the dive, and throw before landing.

### Movement and turning (this is the most important part)

Movement must be momentum-based, not the default Roblox Humanoid walk where you instantly reach full speed and instantly stop. I want acceleration and deceleration curves, a sprint that builds up speed, and turning that depends on speed: at low speed you can turn sharply, at high speed wide turns keep your momentum but sharp turns cost speed. A skilled "cut" (a sharp direction change timed well, for example planting by releasing input briefly and then snapping a new direction) should keep more speed than a sloppy one, so there is a real skill difference in how people cut to get open, the same way real ultimate players juke defenders. The character should lean into turns and the animation should match the actual velocity so it never looks like ice skating or sliding feet. Jumping should feel snappy with good air control but limited, so you commit to a jump. Landing from a dive should have a short recovery that skilled players can cancel or shorten with good timing.

Please replace or heavily override the default Humanoid movement as needed to get this feel, and put every tuning value (max speed, acceleration, turn rates, jump height, dive distance, recovery time, catch radius, etc.) in a single config ModuleScript so I can tweak feel without digging through code.

### The disc and throwing

The disc should use custom flight physics, not a ball with gravity: it should have lift, drag, spin, and curve, so it floats, banks, and fades like a real frisbee. Throw power comes from how long Left Mouse is held, direction comes from the camera/mouse aim, and the curve comes from what the player is doing on release (for example holding A or D on release bends the throw left or right like a backhand or forehand, and aiming steeply up with high power should produce a hammer-style throw). Release timing should matter, with a small "perfect release" window that gives a cleaner, faster throw, so throwing has its own skill ceiling just like movement.

Follow the real ultimate rule that you can't run with the disc, but adapted for feel: when you catch it, your momentum carries you into a short skid to a stop (which looks great and keeps catches from feeling like hitting a wall), and then you can only pivot. Add a stall count so the holder has to throw within a set time. Catching out of a dive or a jump and throwing before touching the ground should be legal and is one of the main high-skill plays.

### Catching

Catching should feel generous enough that new players catch easy throws, but rewarding for skilled players. Use a catch radius in front of the player so the disc snaps cleanly into the hands with a short animation instead of awkwardly bouncing off the body. Hard catches (layout catches at the end of a dive, sky catches at the top of a jump over a defender, catches at full sprint) should have a tighter timing window and a satisfying visual and audio reward when pulled off. Defenders should be able to block the disc with a well-timed jump or dive, and if two players contest the disc, the one with better positioning and timing should win, not just whoever is closest.

### Abilities

Each player picks one ability before the match and only has that one. Abilities should add to the movement and throwing system rather than replace skill. For example: a short directional air burst, a throw with extra curve, a brief speed surge, or a moment of slowed time while aiming. They should run on a cooldown, never feel mandatory, and never be strong enough that the ability wins the play by itself. Build the ability system so adding a new ability is just one new module that plugs into a shared framework.

### Art style and game feel

The look is anime style. Roblox doesn't support custom shaders, so get there with: bright saturated colors, a clean, simple stylized field and arena, outlines on players and the disc (using Highlight instances, keeping in mind Roblox limits how many can render at once, so plan around that), stylized trails on the disc and on fast-moving players, speed lines and a slight camera FOV push at high speed, impact frames and very short hit-stop on big catches and blocks, camera shake on dives and landings, and particle bursts for perfect throws and highlight plays. The goal is that every big play looks like an anime highlight. Effects should be driven by gameplay events (perfect release, layout catch, block, score) through one effects module, so I can turn them up or down from config.

### Networking

This is multiplayer, so responsiveness matters as much as the mechanics. Each player's movement should feel instant on their own screen (client-side movement with server sanity checks, so it feels smooth but can't be easily exploited), and the disc needs to look smooth and consistent for everyone, using whatever mix of network ownership and client-side prediction gives the cleanest result. Catches and blocks should be resolved fairly on the server. Explain the approach you pick and the tradeoffs before building it.

### How to build it

Build in this order, and get each stage feeling great before moving on, because feel is the whole game:

1. Movement and turning, in an empty test field.
2. Jump, dive, and landing recovery, and how they chain with movement.
3. The disc's flight physics and throwing.
4. Catching and blocking.
5. Basic match rules (teams, end zones, scoring, stall count, turnovers).
6. The ability framework and a few starting abilities.
7. Visual effects, camera feel, and the anime style pass.
8. Multiplayer polish and testing.

At each stage, say what to test in Studio and what to pay attention to, then wait for feedback before moving on. Keep the code organized into clear modules (input, movement, disc physics, catching, abilities, effects, match rules, config), and comment the parts that control feel. If any part of this design conflicts with something Roblox can't do well, say so directly and suggest the closest alternative instead of quietly working around it. Anything that cannot be done in code uses ForgeGUI.

## Decisions on top of the brief

- **Ability chord:** every action in `Config/Input.AbilityChord.actions`
  (Jump + Burst) going down within `window` (0.04 s) of each other. The jump
  is never delayed and still happens; the ability fires as well.
- **Menu:** M opens the menu. It is not a gameplay action (Roblox reserves Esc).
- **Extras** (shop, Robux, progression, signature plays, drills, bots,
  music) stay in the project but are not touched until stage 8.
- **Networking:** client-owned movement on a fixed 120 Hz step with server
  limit checks; deterministic disc flights replicated as launch values and
  re-simulated on every client against the server clock; client catch claims
  validated on the server with lag compensation, contests decided by
  catch-zone depth and timing.
- **Roblox limits:** no per-player slow time in multiplayer (the "slowed
  time while aiming" idea becomes a hover / slow-fall plus a local slow-mo
  look); hit-stop is a 2-4 frame client-side freeze of camera and poses;
  at most 31 Highlights render, so outlines go to the disc, the holder and
  the nearest players within a configured budget; animation is procedural
  (ForgeGUI animation tools only target their own rigs, not R15).

## Stage log

- **Stage 2 — jump, dive, landing recovery (built, awaiting playtest).**
  Space again in the air is the one air action: a dive toward the held
  direction, a wavedash slide near the ground, or a Sky Reach with no
  direction. Dives land in a belly slide; Space on the touchdown tech-rolls,
  later it scrambles. The separate air dodge, fast fall, crouch jump, stall,
  reverse snap, burst dive and ground layouts are gone.
- **Stage 1 — movement and turning (built, awaiting playtest).** Cuts come
  from the stick (let go, then snap); skids from yanks without a plant; one
  engine; six inputs plus the chord; `Config/Tuning.luau`; the test field.
