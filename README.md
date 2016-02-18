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
