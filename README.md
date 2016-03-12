# From the Depths scripts
Lua scripts for custom behaviours in the game [From the Depths](http://fromthedepthsgame.com/).

## [Heli-Airship Balance](https://github.com/LionsPhil/fromthedepthsscripts/blob/master/heliairshipbalance.lua)
**[Demonstration video](https://www.youtube.com/watch?v=goeyjXUf5Gs)**

Takes control of vertically-mounted dedicated heliblade spinners on your vessel to balance it out at a target altitude, with dynamic adjustments for terrain and enemies. Self-configuring, although there are some tunables at the top. (The most interesting is the default `target_altitude` it will maintain.)

1. Build your vessel with some dedicated heliblade spinners facing either up or down (so they spin on a horizontal plane). Put them wherever you want so long as it's physically possible to balance the craft using them.
2. Set them all to have an Always Up fraction of 1. (You can *try* doing otherwise, but don't expect success!) They almost certainly want some Motor Drive too.
3. Place a LUA block and paste the script into it.
4. Provided your vessel has enough lift capacity in the right places, your vessel should hover in the sky in a controlled fashion.

Does not do anything about lateral movement, by design. Fit thrusters, or ACB-controlled propellers, and an Aerial AI card, and you should have a heliairship that still understands waypoints and stock combat AI. Or fit another LUA block which handles navigation.

## WIP [Missile Controller](https://github.com/LionsPhil/fromthedepthsscripts/blob/master/missile.lua)
Missile controller for Lua transciever missiles. Attempts to make good target selection decisions, and includes a missile measurement mode to discover the performance metrics it needs for tunables. Currently lacking target prediction, but the target *selection* is pretty advanced.

- "Measurement mode" to performance-test a missile and find the tuning values the code needs for you
- Sophisticated target prioritization, considering player orders, air/water domain, range, turning circle, stock combat AI priorities, and salvage status
- Optional sticky targeting (missiles only retarget if their current target becomes unreachable, is destroyed, etc.)
- Near-miss overshoot proximity triggering (try to turn misses into splash hits; will still wait for impact if on-target)
- Hydrophobia for air missiles; avoids dipping into the sea until the last moment for targets underwater, and gets out of it otherwise
- Climb/cruise mode for target-spotting when nothing is reachable
- Fairly aggressive at limiting and spreading computational load, at least so long as you stagger your huge volleys ;)

In theory supports torpedoes, but I haven't tested with them.
