# Ultimate Frisbee Movement Tech Spec

## How to use this doc

This is the full movement and disc tech list for the game: 33 mechanics across ground, air, catching, throwing and defense, each with inputs, a player walkthrough, exact timing values and build notes. Give it to Claude Code one build step at a time, in the order in Build order.

Every mechanic uses the same template:

- **What it is** — one line.
- **Input** — PC / controller.
- **Walkthrough** — the steps a player does to pull it off.
- **Rules** — timing windows, numbers, what success and failure do.
- **Build notes** — how to implement it in Roblox.
- **Skill ceiling** — why it's hard and what mastery looks like.

### Design pillars

1. **Speed is earned, never given.** Base movement is average. Every big speed gain comes from a tech done on time.
2. **Momentum is the resource.** Like boost in Rocket League, players manage speed. Bad inputs bleed it; good chains keep it.
3. **Tight windows, clear feedback.** Every timed input has a "perfect" window with a distinct sound, flash and speed bonus. Players should always know if they hit it.
4. **Everything chains.** Each tech can end in a state another tech starts from. The skill ceiling is the chain, not single moves.
5. **Ultimate rules stay intact.** The disc carrier can't run (pivot only). Movement tech lives with cutters, defenders and the disc in the air. That makes off-disc play the main skill.
6. **Same physics for everyone.** No stat upgrades that change movement. Cosmetics only.

## Core physics model

All tech sits on one custom momentum controller. Build this first and don't use Roblox's default Humanoid movement for speed, because it snaps to WalkSpeed and kills momentum.

### Movement rules

- **Velocity is kept, not set.** Input adds acceleration toward a target direction. Speed only drops from friction, turning or overspeed decay.
- **Run speed:** 22 studs/s top, 60 studs/s² acceleration. With no input, ground friction slows at 80 studs/s².
- **Overspeed:** Tech can push you above run speed. Above it, speed decays toward run speed at 15 studs/s² on the ground and 4 studs/s² in the air. This is why chaining matters: air keeps speed, ground eats it.
- **Hard cap:** 60 studs/s. Nothing exceeds it.
- **Turn rate:** Turning is instant under 12 studs/s. Above that, max turn rate drops with speed (300°/s at 12, 180°/s at 30, 90°/s at 50). Steering harder than the limit makes you drift and lose 25% of the extra angle as speed. Fast players need tech (cuts, slides) to change direction.
- **Gravity:** 140 studs/s² (lower than Roblox's 196.2 so air tech has room). Fall gravity is 1.3x when moving down, so jumps feel snappy.

### Player states

One state machine drives everything. Each tech lists which states it can start from.

| State | Meaning |
| --- | --- |
| Grounded | Running or standing |
| Sliding | Low, low-friction ground slide |
| Airborne | In the air, may still have air dodge |
| AirDodging | Mid air-dodge burst (0.18 s) |
| Diving | Committed horizontal layout |
| Downed | On the ground after a dive, can't move |
| Recovering | Getting up |
| HoldingDisc | Has the disc, pivot only |
| Marking | Guarding the disc holder |

### Roblox architecture

- **Client-side movement.** Run the controller on the client (players own their character by default) so inputs feel instant. Set velocity through a `LinearVelocity` constraint or `AssemblyLinearVelocity` every frame.
- **Fixed timestep.** Step physics at a fixed 120 Hz inside `RunService.Heartbeat` with an accumulator. Timing windows must not change with frame rate.
- **Timing with `os.clock()`.** Measure every window in milliseconds on the client.
- **Input buffer.** Store each press for 100 ms. If a tech's window opens during that time, it fires. This keeps tight windows fair.
- **Server sanity checks.** Server checks speed never passes the cap plus a small margin and flags teleports. It doesn't re-simulate movement.
- **Disc is server-owned.** The disc runs on a custom flight model (see Throwing) on the server. The thrower's client predicts the flight locally for instant feedback. Other clients interpolate the server's positions.
- **Humanoid for animation only.** Keep the Humanoid so animations work, but drive movement with your own code. Disable auto-jump and default jump.
- **Feedback channel.** One `TechFeedback` module plays sound, screen flash, particles and a small text pop ("PERFECT CUT") for every successful tech. Every section below uses it.

## Ground movement tech

Ground tech is about changing direction without losing speed. Base turning bleeds speed fast, so every good cutter lives on these.

### Controls

| Action | PC | Controller |
| --- | --- | --- |
| Move | WASD | Left stick |
| Camera / aim | Mouse | Right stick |
| Jump / air dodge | Space | A |
| Burst | Left Shift | LB |
| Slide (hold) | C | B |
| Cut | Q | RB |
| Dive / layout | E | X |
| Catch / throw backhand | Left mouse | RT |
| Throw forehand / block | Right mouse | LT |
| Overhead modifier | F (hold) | Y (hold) |
| Fake (while charging) | Slide key | B |

All keys must be rebindable.

### 1. Burst

- **What it is:** The sprint meter. This is your Rocket League boost.
- **Input:** Hold Burst.
- **Walkthrough:** Hold Burst while running to raise your top speed. Let go to refill. Land perfect techs to refill faster.
- **Rules:** Meter is 0–100. Holding drains 30/s, raises top speed from 22 to 30 studs/s and acceleration from 60 to 90. Refills 15/s when not held. Every "perfect" tech in this doc refunds +10 unless it says otherwise. At 0 the meter locks until it refills to 20.
- **Build notes:** Meter lives in the controller. Show it as a bar under the crosshair. Send its value to the server only for UI on teammates.
- **Skill ceiling:** Meter is scarce on purpose. Good players fund their burst with perfect techs instead of refill time.

### 2. Burst Kick

- **What it is:** A short burst tap for instant speed.
- **Input:** Tap Burst (release within 120 ms).
- **Walkthrough:** While running, tap Burst quickly instead of holding it. You get a sharp push forward.
- **Rules:** Adds +6 studs/s instantly in your move direction. Costs 15 meter. 0.5 s cooldown. Can push you above top speed (overspeed rules apply).
- **Build notes:** Detect press length. If released under 120 ms, apply the kick and refund the meter that drained during the hold.
- **Skill ceiling:** Kick right after a cut or landing to stack speed. Spamming it drains you dry.

### 3. Hard Cut and Perfect Cut

- **What it is:** A planted direction change that keeps most of your speed. The core cutting tech.
- **Input:** Hold a new direction, press Cut.
- **Walkthrough:**
  1. Run at speed (above 12 studs/s).
  2. Snap your movement input to a new direction at least 45° away from where you're going.
  3. Press Cut. Your character plants a foot and launches the new way.
  4. For a Perfect Cut, press Cut within 80 ms of the moment your input crosses 45°. Do the direction change and the Cut press as one motion.
- **Rules:**
  - Plant takes 0.12 s. Velocity is redirected to the new direction.
  - Normal cut: keeps 70% of speed.
  - Perfect Cut: keeps 100% of speed, adds +3 studs/s, refunds +10 burst.
  - Late cut (input changed over 80 ms before Cut): normal cut.
  - Cut within 0.6 s of your last cut: speed kept is capped at 85%, even if perfect. This stops infinite zigzag.
  - Cooldown 0.35 s.
- **Build notes:** Track the timestamp when the input direction first crosses 45° from velocity. On Cut press, compare `os.clock()` to it. Use the 100 ms input buffer so a Cut pressed slightly early still checks against the crossing time.
- **Skill ceiling:** Perfect cuts are how you lose a defender. Mastery is hitting them every time at full speed.

### 4. Juke

- **What it is:** A fake cut. Shows the plant, keeps your line.
- **Input:** Snap input to a new direction, press Cut, snap input back to original direction within 120 ms.
- **Walkthrough:**
  1. Run at speed.
  2. Flick your input sideways and press Cut, like a real cut.
  3. Within 120 ms, return your input to your original direction.
  4. Your character plays the plant animation but keeps going straight.
- **Rules:** Keep 90% of speed. Uses the cut cooldown. Defenders see the exact same first 0.12 s of animation as a real cut.
- **Build notes:** On Cut press, start the plant animation and delay the velocity redirect by 120 ms. If input returns within that window, cancel the redirect and apply the 10% loss.
- **Skill ceiling:** Only works because the animation is identical. Pairs with Mirror Step on defense (Defense section).

### 5. Plant Stop

- **What it is:** An instant stop that loads your next start.
- **Input:** Release all movement, press Cut.
- **Walkthrough:** Running at speed, let go of movement and press Cut. You stop dead. Push any direction within 0.3 s to explode out.
- **Rules:** Speed drops to 0 over 0.15 s. For the next 0.3 s, acceleration is 2x. Perfect: re-accelerate within 100 ms of the stop finishing for 2.5x acceleration and +10 burst.
- **Build notes:** A separate branch of the Cut handler when move input is zero.
- **Skill ceiling:** The best counter to a defender matching your speed: stop, then leave the other way.

### 6. Slide

- **What it is:** A low-friction ground slide that holds your speed.
- **Input:** Hold Slide while above 18 studs/s.
- **Walkthrough:** At speed, hold Slide. You drop low and glide. Release to stand.
- **Rules:**
  - Friction drops to 15 studs/s². Overspeed decay is off while sliding.
  - Max slide time 1.2 s, then you stand automatically.
  - Turn rate is fixed at 60°/s.
  - **Landing Slide:** start a slide within 100 ms of landing from a jump to keep 100% of your air speed. Perfect (within 40 ms) also refunds +10 burst. This is the main way to keep speed off a jump.
- **Build notes:** Shrink the character's collision height to half. Track time since landing for the landing window.
- **Skill ceiling:** Landing slides are what make air speed useful. Missing them wastes every jump.

### 7. Slide Carve

- **What it is:** A tight turn at speed.
- **Input:** While sliding, steer and hold Burst.
- **Walkthrough:** Mid slide, hold Burst and steer. You whip around a tight corner.
- **Rules:** Turn rate rises to 220°/s. Friction rises to 40 studs/s². Drains burst at the normal rate.
- **Build notes:** Modifier on the slide state.
- **Skill ceiling:** Trades meter and some speed for a turn no other ground tech can make.

### 8. Slide Hop

- **What it is:** Jumping out of a slide for extra speed. Chains like a bunny hop.
- **Input:** Jump during a slide.
- **Walkthrough:**
  1. Slide.
  2. Jump between 0.15 s and 0.30 s after the slide started.
  3. Land and immediately Landing Slide again.
  4. Repeat.
- **Rules:**
  - Perfect hop (0.15–0.30 s): +6 studs/s.
  - Outside the window: +2 studs/s.
  - Chain bonus shrinks: +6, +4, +2, then 0 on the fourth hop in a row. Resets after 1 s on the ground.
  - Jump height is a short hop (60% of a normal jump).
- **Build notes:** Keep a chain counter that resets on any non-slide grounded time over 1 s.
- **Skill ceiling:** A clean 3-hop chain is the fastest way across the field. One missed landing slide breaks it.

## Air movement tech

Air keeps speed (low overspeed decay) but you can barely steer. Air tech is about launching well, redirecting once, and landing into the next move.

### 9. Jump

- **What it is:** Variable-height jump that keeps horizontal speed.
- **Input:** Tap or hold Jump.
- **Walkthrough:** Tap for a short hop. Hold up to 0.2 s for a full jump.
- **Rules:** Tap: 34 studs/s up (about 4 studs high). Full hold: 46 studs/s up (about 7.5 studs). Horizontal speed is unchanged. Starts the 1.25 s air dodge timer.
- **Build notes:** Apply 34 on press, then add upward force while held for up to 0.2 s. Release early ends the boost.

### 10. Air Steer

- **What it is:** Limited control in the air.
- **Input:** Movement keys while airborne.
- **Rules:** 20 studs/s² acceleration, 90°/s max redirect. Can't raise speed above your takeoff speed. Overspeed decay is only 4 studs/s².
- **Skill ceiling:** You commit to a line when you leave the ground. Pick it before you jump.

### 11. Air Dodge

- **What it is:** One directional burst per airtime. Like a Rocket League flip.
- **Input:** Press Jump again in the air while holding a direction.
- **Walkthrough:** Jump, then press Jump again with a direction held. You burst that way. No direction gives a small double jump.
- **Rules:**
  - Available until 1.25 s after leaving the ground. One per airtime.
  - Directional: +12 studs/s in the held direction. Vertical speed is set to 0 for 0.18 s (a short hang), then gravity resumes.
  - Neutral: +20 studs/s upward.
  - Refreshed by landing or by Disc Reset.
- **Build notes:** `AirDodging` state for 0.18 s. Store `airDodgeAvailable` and `airborneSince`.
- **Skill ceiling:** Using it for speed means you don't have it for a late reach on the disc. That choice is the whole air game.

### 12. Fast Fall

- **What it is:** Drop faster to control when you land.
- **Input:** Hold Slide in the air.
- **Rules:** Gravity becomes 2.2x while held. Pairs with Landing Slide: hold Slide in the air and you'll enter the slide the instant you touch down (counts as perfect if you were holding it).
- **Skill ceiling:** Lets you cut a jump short to hit a landing window on purpose.

### 13. Wavedash

- **What it is:** Turn a tiny hop into a ground dash. The fastest way to gain speed from a jog.
- **Input:** Short hop, then directional Air Dodge right before you land.
- **Walkthrough:**
  1. Tap Jump for a short hop.
  2. As you come down, hold a direction and press Jump again just before your feet touch.
  3. Instead of a dodge, you skid along the ground with a burst.
- **Rules:**
  - Air Dodge pressed 0–80 ms before landing: +10 studs/s along the ground, no landing lag.
  - Perfect (0–40 ms before landing): +14 studs/s and +10 burst.
  - Pressed earlier than 80 ms: a normal air dodge.
  - You're grounded after it, so your air dodge is ready again.
- **Build notes:** On Air Dodge input, raycast down and solve time-to-ground from current height and vertical speed. If under 80 ms, flag a pending wavedash and apply it on the landing frame. Fixed timestep matters here.
- **Skill ceiling:** The window is tiny. Wavedash into a Perfect Cut is the signature cutter move.

### 14. Reverse Snap

- **What it is:** Turn 180° at full speed. Like a Rocket League half flip.
- **Input:** Jump, backward Air Dodge, then Cut.
- **Walkthrough:**
  1. Running one way, jump.
  2. Air Dodge backward (away from where you're facing).
  3. Press Cut 60–140 ms after the dodge starts.
  4. Your character flips to face the new direction and keeps the dodge speed.
- **Rules:** Success: face the dodge direction, keep 90% of dodge speed. Perfect (80–110 ms): keep 100% and +10 burst. Miss: you land facing backward and stumble for 0.3 s.
- **Build notes:** During `AirDodging`, if Cut pressed in window and dodge was backward (over 120° from facing), rotate the character and keep velocity.
- **Skill ceiling:** Lets a defender turn and chase a deep throw without the slow turn-rate limit.

### 15. Burst Dive

- **What it is:** Fastest start from a standstill. Like a Rocket League speed flip. Used on the pull.
- **Input:** Jump, diagonal-forward Air Dodge within 80 ms, then Cut within 50–120 ms.
- **Walkthrough:**
  1. Standing still, tap Jump.
  2. Almost at once (within 80 ms), Air Dodge forward-diagonal.
  3. Press Cut 50–120 ms into the dodge to cancel the spin.
  4. You land running forward at high speed.
- **Rules:** Success: land at 28 studs/s, about 0.3 s faster than burst-running to the same speed. Perfect (70–100 ms Cut): 32 studs/s. Miss: normal diagonal dodge.
- **Build notes:** Treat as a special case of the dodge-cancel used in Reverse Snap, with a forward-diagonal check.
- **Skill ceiling:** On every pull, the team that burst-dives gets downfield first.

### 16. Disc Reset

- **What it is:** Touching the disc in the air gives your Air Dodge back. Like a Rocket League flip reset.
- **Input:** Tip, block or bobble the disc while airborne.
- **Walkthrough:** Jump for a disc. Use your dodge to reach it. Touch it (a tip pass, a block, or a bobble). Your dodge is ready again for a second reach or a recovery.
- **Rules:** Once per airtime. Catching the disc also counts (useful for The Greatest).
- **Build notes:** On any disc contact event while airborne, set `airDodgeAvailable = true` and reset the 1.25 s timer.
- **Skill ceiling:** Enables double plays: tip to a teammate, dodge, and catch the tip back or block the next throw.

## Catching and layout tech

Catching is timed, not automatic. A dropped disc is a turnover, so this is where pressure lands.

### 17. Timed Catch

- **What it is:** Press Catch as the disc reaches your hands.
- **Input:** Catch button when the disc is in range.
- **Walkthrough:** Get your body to the disc. Watch the catch ring (a circle that closes on the disc as it nears your hands). Press Catch when the ring closes.
- **Rules:**
  - Catch radius: 2.5 studs from the hands bone.
  - Clean catch: within ±150 ms of the disc's closest point to your hands.
  - Perfect Catch: within ±40 ms. Unlocks Hot Hands (Throwing section) and +10 burst.
  - Outside the window: bobble. The disc pops up 2 studs and slows 60%. You get one re-press within 0.3 s. Miss that and it's a drop.
  - **Catch run-out:** If you catch while moving, you can't keep running. You slow at 50 studs/s² to a stop, then enter `HoldingDisc`.
- **Build notes:** Each frame, predict the disc's closest approach to each nearby player's hands (sample the flight model ahead). Store that time. Grade the Catch press against it. Server confirms catches using its own disc position plus a 100 ms lag allowance.
- **Skill ceiling:** Perfect catches make the next throw faster. Clean but sloppy catches slow the whole offense.

### 18. Layout

- **What it is:** A full horizontal dive for a disc out of reach.
- **Input:** Dive, aimed with the camera.
- **Walkthrough:** Running at the disc, press Dive. You launch flat toward where you're looking. Press Catch as you reach the disc.
- **Rules:**
  - Needs at least 15 studs/s.
  - Launch: current speed +8 studs/s toward aim (within 45° of velocity), +10 studs/s up.
  - Catch radius extends 1.5 studs forward during the dive.
  - Can be done from the air by spending your Air Dodge.
  - On landing: `Downed` for 0.9 s.
- **Build notes:** `Diving` state with a stretched horizontal hitbox. Dive animation with arms out.
- **Skill ceiling:** Huge range, huge cost. A missed layout takes you out of the play for almost a second.

### 19. Tech Roll

- **What it is:** Recover fast from a layout.
- **Input:** Jump right as you hit the ground from a dive.
- **Walkthrough:** During a layout, press Jump the moment your body touches the ground. You roll back to your feet.
- **Rules:** Within 0–100 ms of impact: recover in 0.25 s instead of 0.9 s, keep 50% speed. Perfect (0–40 ms): keep 75% and +10 burst. Miss: full 0.9 s down.
- **Build notes:** Same landing-time check as Landing Slide.
- **Skill ceiling:** A layout plus perfect tech roll lets you catch and be back in the play before anyone else.

### 20. Sky

- **What it is:** A charged high jump to catch over a defender.
- **Input:** Hold Jump while grounded, release.
- **Walkthrough:**
  1. Read where the disc will come down.
  2. Hold Jump. You crouch and slow to 60% speed as it charges.
  3. Release at full charge to leap high with arms up.
  4. Press Catch at the top.
- **Rules:**
  - Charge up to 0.4 s. Jump height scales up to 1.6x a full jump.
  - Perfect release (0.35–0.40 s): 1.7x height and hands-up pose extends reach 1 stud.
  - **Contest rule:** if two players press Catch within 50 ms of each other, the one with higher hands wins.
- **Build notes:** Separate from a tap jump: if Jump is held over 0.2 s while grounded and not moving fast, switch to sky charge.
- **Skill ceiling:** Timing the charge so you peak exactly when the disc arrives.

### 21. The Greatest

- **What it is:** Save a disc flying out of bounds by catching it in the air and throwing it back in before you land. A real ultimate play.
- **Input:** Jump from in bounds, catch in the air, throw before landing.
- **Walkthrough:**
  1. Disc is heading out of bounds.
  2. Jump from inside the field toward it.
  3. Catch it in the air (counts as a Disc Reset, so your Air Dodge is back).
  4. Throw it to a teammate before your feet touch. Use the Air Dodge hang (0.18 s) to buy time.
- **Rules:** Legal only if your last ground contact was in bounds. Throws in the air are capped at 70% power and skip the charge minimum. Landing out of bounds with the disc is a turnover.
- **Build notes:** Track `lastGroundedPositionInBounds`. Allow throw inputs in the `Airborne` state when holding the disc.
- **Skill ceiling:** Needs Sky or a dodge, a timed catch, and a throw in under a second. The highlight-reel play.

### 22. Tip Pass

- **What it is:** Redirect the disc to a teammate without catching it.
- **Input:** Hold Cut and press Catch.
- **Walkthrough:** As the disc arrives, hold Cut and press Catch in the catch window, aiming at a teammate. You knock it their way.
- **Rules:** Disc keeps 40% of its speed and heads toward your aim. Uses the same timing window as a Timed Catch. Tipping to yourself is not allowed (real rule): if you touch it again before anyone else, it's a turnover.
- **Build notes:** On a tip, give the disc a new velocity and set `lastTouchedBy`. Counts as a Disc Reset.
- **Skill ceiling:** Turns a contested disc into a completion. Pairs with Disc Reset for two-touch plays.

## Throwing tech

The thrower can't run, so throwing skill is aim, curve, timing and fakes. Curve directions below are for a right-handed thrower. Add a handedness setting that mirrors them.

### Disc flight model

Every throw runs on one simulation. Claude Code should build this before any throw type.

- **Disc state:** position, velocity, spin (0–1.2), tilt (edge roll angle), attack angle, inverted (true for overheads).
- **Each step:**
  - Gravity: 60 studs/s² down.
  - Drag: `-0.0035 × speed × velocity`.
  - Lift: `0.0028 × speed² × liftFactor(attack)` along the disc's up-normal. Inverted discs flip the normal, so they dive.
  - Because the normal is tilted by the edge angle, part of the lift pushes sideways. That's the curve.
  - Spin decays at 0.15/s. Tilt drifts toward the fade side at `(1 − spin) × 40°/s`. Low spin = early fade.
- **Build notes:** Pure Luau, no Roblox physics. Server runs it at 120 Hz. Same module on the client for prediction and for the aim preview. Add a debug mode that draws the full predicted path so values can be tuned fast.

### 23. Pivot

- **What it is:** Footwork while holding the disc.
- **Input:** Movement keys while in `HoldingDisc`.
- **Walkthrough:** Your pivot foot is planted. A/D (or stick left/right) rotate you around it. W/S step your free foot forward or back. Double-tap a direction to lunge.
- **Rules:** Free foot reach 1.2 studs. Lunge reaches 1.8 studs, 0.25 s recovery. Lifting the pivot foot (leaving range) is a travel: turnover.
- **Build notes:** Lock the root to a circle around the pivot point. Rotate the camera with the body.
- **Skill ceiling:** Stepping around the mark to open a throwing lane.

### 24. Throw Types

| Throw | Input | Max speed (studs/s) | Flight | Use |
| --- | --- | --- | --- | --- |
| Backhand | Catch/throw button | 90 | Flat release fades left | Main long throw |
| Forehand (flick) | Forehand button | 85 | Flat release fades right | Breaking the mark |
| Hammer | Overhead + forehand | 70 | Starts upside down, arcs over, dives late | Over the mark |
| Scoober | Overhead + backhand | 45 | Short, upside down, quick drop | Short over-the-top dump |
| Blade | Any throw with edge over 35° | Throw max | Hard curve, drops fast | Into tight space |
| Pull | Backhand at point start | 110 | Long, high hang time | Start of each point |

### 25. Charge and Snap Release

- **What it is:** Power vs. stability. The core throwing skill.
- **Input:** Hold a throw button, release.
- **Walkthrough:**
  1. Hold the throw button. A ring fills around the crosshair over 1.0 s.
  2. A marked snap zone sits at 75–85% fill.
  3. Release inside the snap zone for a clean, stable throw.
  4. Release dead center (80% ±20 ms) for a Snap Release.
- **Rules:**
  - Power scales 30% to 100% with fill.
  - Below the snap zone: low power, full spin (1.0).
  - Inside the zone: 75–85% power, full spin.
  - Snap Release: 85% power, 1.2 spin. Holds its edge longer and flies farther. +10 burst for every teammate within 20 studs (a small team reward).
  - Above the zone: up to 100% power, but spin drops to 0.6. Wobbles and fades early.
  - Held over 1.2 s: spin 0.4 and the aim cone widens 5°.
- **Skill ceiling:** Max power costs control. Pros hit Snap on almost every throw and only overcharge on purpose.

### 26. Edge and Launch Angle

- **What it is:** Shaping the curve.
- **Input:** While charging: mouse left/right (or right stick) for edge, up/down for launch angle.
- **Walkthrough:**
  1. Start charging.
  2. Move left/right to tilt the edge. The preview path bends.
  3. Move up/down to aim higher or lower.
  4. Release.
- **Rules:**
  - Edge from −40° (outside-in: curves out, then back toward the target) to +40° (inside-out: curves away from your throwing side).
  - Launch angle from −5° to +35°. High angle = more hang time, less distance.
  - Preview path shows only the first 40% of the flight (training mode shows all of it). Players must learn the rest.
- **Build notes:** While charging, the camera locks. Mouse delta drives edge and angle instead of looking.
- **Skill ceiling:** Inside-out and outside-in throws bend around the mark. Combined with the fade from spin, the same release can land in three different spots.

### 27. Pump Fake and Fake Switch

- **What it is:** Faking a throw to move the mark.
- **Input:** Start a throw, press Fake before releasing.
- **Walkthrough:**
  1. Start charging a backhand. The windup animation plays.
  2. Press Fake. The throw cancels.
  3. Fake Switch: within 150 ms of the fake, start the other throw (forehand). It skips the recovery.
- **Rules:** The first 0.15 s of a fake looks identical to a real throw. Normal fake recovery is 0.2 s. Fake Switch has no recovery. Stall count keeps running.
- **Build notes:** Windup animation must be the same for real throws and fakes for the first 0.15 s.
- **Skill ceiling:** Baits the marker's Hand Block, then throws past the whiff.

### 28. Hot Hands

- **What it is:** A fast release after a perfect catch.
- **Input:** Throw within 0.4 s of a Perfect Catch.
- **Rules:** Skips the charge. Throws instantly at 70% power, full spin, and +10% speed. Works during catch run-out.
- **Skill ceiling:** Fast swing passes that beat the defense before they reset.

### 29. Run-Through Release

- **What it is:** Throwing before your catch run-out stops.
- **Input:** Throw during catch run-out.
- **Rules:** Allowed (real ultimate lets you throw while slowing down). Aim cone widens 1° per 5 studs/s of speed you still have. A Perfect Catch halves the widening.
- **Skill ceiling:** Keeps the offense moving fast at the cost of accuracy.

## Defense tech

Defense uses all the movement tech above plus four of its own. The goal is to read fakes and punish them, not to out-stat anyone.

### 30. Mark and Force

- **What it is:** Guarding the thrower and starting the stall count.
- **Input:** Stand within 3 studs of the thrower. Tap Cut to switch force side.
- **Walkthrough:** Get in front of the thrower. The stall count starts. Pick which side to block (force forehand or force backhand). Shuffle with the pivot to stay on that side.
- **Rules:**
  - Stall counts 1 per second. At 10, the thrower turns it over.
  - Marker must stay at least 1 stud away (disc space). Closer pauses the count.
  - Marker can shuffle side to side at 14 studs/s with instant turning.
- **Build notes:** `Marking` state. Stall count runs on the server and shows above the thrower.
- **Skill ceiling:** Staying on the force side while the thrower pivots and fakes.

### 31. Hand Block

- **What it is:** Swatting a throw as it leaves the thrower's hand.
- **Input:** Block button plus aim direction while marking.
- **Walkthrough:** Watch the thrower's windup. Swing your arm into the lane they're throwing through. Time it with their release.
- **Rules:**
  - Arm hitbox is active for 0.2 s.
  - Any disc passing through it in the first 0.15 s of flight is blocked.
  - Point Block: swing within 80 ms of the release. The disc drops at your feet and +20 burst.
  - Whiff (no throw, or a fake): 0.4 s recovery. The thrower has an open lane.
- **Build notes:** Server checks the disc's first frames against the arm hitbox using the throw's start time. Allow 80 ms of lag.
- **Skill ceiling:** Blocking on reads instead of reactions. Swinging at a Pump Fake gets you punished.

### 32. Mirror Step

- **What it is:** Matching a cutter's cut instantly.
- **Input:** Cut in the same direction as the player you're guarding.
- **Walkthrough:** Guard a cutter. When they cut, cut the same way as fast as you can.
- **Rules:**
  - Cut within 120 ms after your matchup's cut: Mirror. Your cut counts as perfect and adds +2 studs/s.
  - If their cut was a Juke and you mirrored it, you lose 30% speed (you bit on the fake).
  - Only checks the player you're closest to within 8 studs.
- **Build notes:** On every cut, broadcast `cutEvent(player, direction, time, isJuke)`. The defender's client checks it. `isJuke` resolves after 120 ms, so the penalty lands then.
- **Skill ceiling:** Mirror vs. Juke is the mind game of the whole game. Reacting too fast gets you juked; too slow and the cutter's free.

### 33. Bid

- **What it is:** A defensive layout to knock the disc down.
- **Input:** Dive at the disc, press Block at contact.
- **Rules:** Same launch, Downed time and Tech Roll as Layout. Contact knocks the disc to the ground (a block). Counts as a Disc Reset if airborne. Hitting a player instead of the disc is a foul (see below).
- **Skill ceiling:** Layout blocks are the defensive highlight play. Miss and your matchup is wide open.

### Contact rule

Ultimate is non-contact. Players pass through each other but lose 30% speed when overlapping. A defender who overlaps a receiver within 0.3 s of a catch attempt gives a foul: the disc goes back to the receiver. This stops blocking by body-checking and keeps the game about tech.

## Tuning constants

All numbers live in one `TechConfig` ModuleScript so they can be tuned without touching logic. These are starting values; expect to change them after playtests.

| Constant | Value | Unit |
| --- | --- | --- |
| RUN_TOP_SPEED | 22 | studs/s |
| RUN_ACCEL | 60 | studs/s² |
| GROUND_FRICTION | 80 | studs/s² |
| OVERSPEED_DECAY_GROUND | 15 | studs/s² |
| OVERSPEED_DECAY_AIR | 4 | studs/s² |
| HARD_SPEED_CAP | 60 | studs/s |
| PLAYER_GRAVITY | 140 | studs/s² |
| FALL_GRAVITY_MULT | 1.3 | x |
| BURST_TOP_SPEED | 30 | studs/s |
| BURST_DRAIN / REFILL | 30 / 15 | per s |
| PERFECT_BURST_REFUND | 10 | meter |
| BURST_KICK | +6, cost 15 | studs/s, meter |
| CUT_KEEP / PERFECT_KEEP | 0.70 / 1.00 | fraction |
| CUT_PERFECT_WINDOW | 80 | ms |
| CUT_REPEAT_CAP | 0.85 within 0.6 s | fraction |
| JUKE_WINDOW | 120 | ms |
| SLIDE_MIN_SPEED | 18 | studs/s |
| SLIDE_FRICTION / MAX_TIME | 15 / 1.2 | studs/s², s |
| LANDING_SLIDE_WINDOW | 100 (perfect 40) | ms |
| SLIDE_HOP_WINDOW | 0.15–0.30 | s |
| SLIDE_HOP_BONUS | 6, 4, 2, 0 | studs/s |
| JUMP_TAP / JUMP_FULL | 34 / 46 | studs/s up |
| AIR_DODGE_WINDOW | 1.25 | s |
| AIR_DODGE_BURST | 12 | studs/s |
| AIR_DODGE_HANG | 0.18 | s |
| WAVEDASH_WINDOW | 80 (perfect 40) | ms before landing |
| WAVEDASH_BURST | 10 (perfect 14) | studs/s |
| REVERSE_SNAP_WINDOW | 60–140 (perfect 80–110) | ms |
| BURST_DIVE_SPEED | 28 (perfect 32) | studs/s |
| CATCH_RADIUS | 2.5 | studs |
| CATCH_WINDOW | ±150 (perfect ±40) | ms |
| LAYOUT_DOWN_TIME | 0.9 | s |
| TECH_ROLL_WINDOW | 100 (perfect 40) | ms |
| SKY_CHARGE / PERFECT | 0.4 / 0.35–0.40 | s |
| DISC_GRAVITY | 60 | studs/s² |
| DISC_DRAG | 0.0035 | coefficient |
| DISC_LIFT | 0.0028 | coefficient |
| SPIN_DECAY | 0.15 | per s |
| SNAP_ZONE | 75–85% (snap 80% ±20 ms) | charge |
| STALL_COUNT | 10 | s |
| HAND_BLOCK_ACTIVE | 0.2 | s |
| MIRROR_WINDOW | 120 | ms |
| INPUT_BUFFER | 100 | ms |
| PHYSICS_RATE | 120 | Hz |

## Build order and Claude Code prompts

Build in this order and playtest after each step. Tech built on a bad controller has to be redone, so don't skip ahead.

1. **Controller core:** momentum, turn rate, gravity, state machine, input buffer, fixed timestep, `TechConfig`, `TechFeedback`.
2. **Debug HUD:** speed, current state, burst meter, and the timing of the last tech in ms ("Cut: 34 ms early"). You need this to tune anything.
3. **Ground tech:** 1–8.
4. **Air tech:** 9–16.
5. **Disc flight model** with the debug path preview.
6. **Catching:** 17–22.
7. **Throwing:** 23–29.
8. **Defense and rules:** 30–33, contact rule, stall count, turnovers, end zones, scoring, pulls.
9. **Training mode:** one drill per tech. Each shows the timing window as a bar and your press on it, with "x ms early/late". This is what makes hard tech feel learnable instead of unfair.
10. **Network pass:** server checks, catch and block lag allowance, disc interpolation on other clients.

### Signature chains to test

These should all be possible once steps 1–7 are done. If one isn't, a window or value is off.

- **The Shake:** Wavedash → Burst Kick → Juke → Perfect Cut the other way.
- **Deep Chase:** Burst → Slide Hop x3 → Reverse Snap → Layout → Tech Roll.
- **Pull Race:** Burst Dive → Burst → Landing Slide → Slide Hop.
- **The Greatest:** Sky → Perfect Catch out of bounds (Disc Reset) → Air Dodge hang → Hot Hands throw.
- **Double Touch:** Air Dodge → Tip Pass (Disc Reset) → Air Dodge → Catch the return.
- **Bait Block:** Pump Fake → marker whiffs Hand Block → Fake Switch → inside-out break throw.

### Prompt template for Claude Code

Save this file in your project as `docs/tech-spec.md`, then use one prompt per build step:

```
Read docs/tech-spec.md. Implement build step [N]: [name].
Only build what's in that step. Use values from TechConfig.
Follow the Build notes for each mechanic in that step.
Add each tech's timing readout to the debug HUD.
When done, list what I should playtest and which constants to tune first.
```

For the controller core, add: "Don't use Humanoid WalkSpeed or Humanoid jumping for movement. The Humanoid is for animation only."
