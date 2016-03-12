--[[
From the Depths Missile Controller
Copyright 2016 Philip Boulain. Licensed under the ISC License.

Shortcomings:
  - Want a way to restrict this to affect just a single weapon group, then you
      can have one per missile type (torpedoes in particular need it).
  - Missiles are not sticky, although target-switching is discouraged by their
      estimation of if they can reach an alternative. Can perform some pretty
      vexing swerve-to-misses if priorities are unstable.
  - Doesn't try to avoid overkill.
  - Prediction is nowhere near as smart as Blothorn's (...currently none).
  - Pretty CPU-intensive, does a lot of recomputation every update.
]]--

-- Tunables --------------------------------------------------------------------
-- Are the missiles torpedos? Will try to stay above/below sea as needed.
is_torpedo               = false
-- Jump/dive depth for missiles, allowing them to cross-target (meters)
sea_crossover_tolerance  = 10
-- Distance beyond which won't even *try* to persue targets (meters)
maximum_range            = 800
-- Rate at which missile can turn (radians/second; use measurement mode!)
turn_rate                = 0.54
-- Estimated speed the missile will spend most of its lifespan at (m/s)
-- (use measurement mode!)
speed_estimate           = 115
-- If within this range, but now overshooting the target, detonate (meters)
-- (Like a proximity fuse, but will always try to get as close as possible)
-- Target block changes can make this ineffective at large values
prox_abort               = 3
-- Air missiles will avoid going below this height until they are close enough
-- that they have to turn into their target (not strictly skimming, since they
-- won't make effort to dive to it either). High values will currently make
-- missiles likely to abort and retarget due to being off-course. (meters)
sea_skim_height          = 2
-- If no target and younger than this, climb; otherwise cruise (seconds)
-- Setting this too high can cause missiles to swerve away if they are about
-- to slam down on a ship when the targetted block changes beyond their ability
-- to turn.
max_climb_age            = 1
-- Angle beyond which all targets are considered equally off-course. Wider thus
-- means the targetting decision will be dominated by where the missile is
-- already facing, even if it's an otherwise inferior target. Too narrow will
-- instead make missiles very indecisive. (Radians; note that the *cone* of
-- directional sensitive will be twice this, from side to side.)
off_course_clamp         = math.rad(45)
-- If there are no valid targets, try an invalid target. Basically disables
-- missiles trying to climb/cruise for a better target, but also stops them
-- giving up if the AI retargets at the last moment.
chase_unicorns           = true
-- Measurement mode: DON'T TRACK TARGETS, just do some missile acrobatics and
-- log values for the above to the Lua block. To use this, turn it on, fire
-- ONLY ONE MISSILE (rip up some launchpads if you have to), wait for the HUD
-- message, then go to the Lua block log and copy the measurments into the
-- tunables above and turn this back off (...and restore any launchpads).
-- You must save-and-run the code to reset state for each measurement run.
measurement_mode         = false
-- How long to give the missile to clear the vessel before measuring.
-- Particularly important for submarine-launched missiles that have to clear
-- the surface.
measurement_mode_start   = 0.5
-- How much of a turn to measure. Normal missiles should be fine one quarter.
measurement_mode_turn    = math.rad(90)
-- How long a missile can try to make the turn before measurements give up.
-- Useful to clean up for subsequent retries.
measurement_mode_timeout = 10

-- Really finnicky tunables ----------------------------------------------------
-- You probably don't actually have to mess with these unless you're having
-- problems.
-- Spam the Lua block log with de-bugging messages
dbg_spam                 = false
-- Spam the Lua block log with profiling messages
profile_spam             = true
-- Spam the HUD when we do something cool
hud_spam                 = true
-- Update intervals. Lower is more frequent, 40 is once per second. Setting
-- these too high will hurt missile responsiveness. Some work is always done
-- per-tick.
-- How often to steer the missiles. At present this also controls how often
-- they reconsider targets.
steer_interval           = 1

-- Measurement mode (mostly self-contained) ------------------------------------
mm_start_vector = nil
mm_complete     = false
function MeasurementModeGuidance(I, transciever, missile, missile_info)
  local missile_measure_time =
    missile_info.TimeSinceLaunch - measurement_mode_start

  -- Give the missile a chance to into open air
  if missile_measure_time < 0 then return end

  if mm_start_vector == nil then
    I:LogToHud("MEASUREMENT MODE ACTIVE - MISSILE IGNORING TARGETS")
    mm_start_vector = missile_info.Velocity.normalized
    -- Ask the missile to perform a complete turnaround by aiming behind itself
    local behind = missile_info.Position - mm_start_vector
    I:SetLuaControlledMissileAimPoint(transciever, missile,
      behind.x, behind.y, behind.z)
  end

  -- Is the missile now facing 90 degrees away from when it started?
  local angle_from_start = math.acos(Vector3.Dot(
    missile_info.Velocity.normalized,
    mm_start_vector))
  if angle_from_start > measurement_mode_turn then
    -- Allow for us getting updates even after detonation
    if not mm_complete then
      -- Work out how the missile fared
      local turn_rate = angle_from_start / missile_measure_time
      local speed = missile_info.Velocity.magnitude

      -- Log it (the log is displayed in reverse order in the UI)
      I:Log("(Missile took " .. missile_measure_time .. " to complete turn)")
      I:Log("speed_estimate = " .. speed)
      I:Log("turn_rate      = " .. turn_rate)
      I:Log("Measurement mode results:")

      -- Detonate it before it turns back home to its launcher
      I:DetonateLuaControlledMissile(transciever, missile)

      mm_complete = true
      I:LogToHud("MEASUREMENTS COMPLETE - INTERACT WITH LUA BLOCK")
    end
  else
      I:LogToHud(string.format("MEASURING - %gdeg in %gs",
        math.deg(angle_from_start), missile_measure_time))
      if missile_measure_time > measurement_mode_timeout then
        I:LogToHud("MEASUREMENTS ABORTED - RESETTING SYSTEM")
        I:DetonateLuaControlledMissile(transciever, missile)
        mm_start_vector = nil
        mm_complete = false
      end
  end
end

-- Regular behaviour -----------------------------------------------------------
tick_counter = 0
interval_period = steer_interval
targets = {} -- returns of GetTargetInfo(); see ScanForTargets

-- TODO cache for missile/target assignments, allows for target_assign_interval
-- TODO sticky targetting behaviour using cache, only recalcs if can't hit

-- *ToTarget caches; tables of missile IDs mapping to tables of target IDs
-- mapping to the result (see the *ToTarget functions)
cache_angle_to_target = {}
cache_time_to_target  = {}
profile_cache_hits    = 0

-- Invalidate the *ToTarget calculation caches
function ClearCalculationCaches(I)
  cache_angle_to_target = {}
  cache_time_to_target  = {}
  profile_cache_hits    = 0
end

-- Returns angle in radians between missile facing and direction to target.
-- target_in_missile_coords is optional, should you already have it.
function AngleToTarget(
  I, missile_info, target, target_in_missile_coords)

  -- Try/initialize the cache
  local cache_for_missile = cache_angle_to_target[missile_info.Id]
  if cache_for_missile == nil then
    cache_for_missile = {}
    cache_angle_to_target[missile_info.Id] = cache_for_missile
  else
    local cache_result = cache_for_missile[target.Id]
    if cache_result ~= nil then
      if profile_spam then profile_cache_hits = profile_cache_hits + 1 end
      return cache_result
    end
  end

  -- Calculate
  if target_in_missile_coords == nil then
    target_in_missile_coords = target.AimPointPosition - missile_info.Position
  end
  local result = math.acos(Vector3.Dot(
    missile_info.Velocity.normalized,
    target_in_missile_coords.normalized))

  -- Populate cache and return
  cache_for_missile[target.Id] = result
  return result
end

-- Returns estimated time to target in seconds.
-- Currently very dumb and (mostly) ignores that both are moving, let alone
-- accellerating.
-- target_in_missile_coords is optional, should you already have it.
function TimeToTarget(
  I, missile_info, target, target_in_missile_coords)

  -- Try/initialize the cache
  local cache_for_missile = cache_time_to_target[missile_info.Id]
  if cache_for_missile == nil then
    cache_for_missile = {}
    cache_time_to_target[missile_info.Id] = cache_for_missile
  else
    local cache_result = cache_for_missile[target.Id]
    if cache_result ~= nil then
      if profile_spam then profile_cache_hits = profile_cache_hits + 1 end
      return cache_result
    end
  end

  -- Calculate
  if target_in_missile_coords == nil then
    target_in_missile_coords = target.AimPointPosition - missile_info.Position
  end

  -- Early within the missile's life, velocity is changing rapidly; use the
  -- speed-at-turn as a minimum to assume we'll accellerate to it
  local missile_speed = missile_info.Velocity.magnitude
  if missile_speed < speed_estimate
    then missile_speed = speed_estimate end

  -- Estimate time-to-target in the most trivial case
  local time_to_target = target_in_missile_coords.magnitude / missile_speed

  -- The more off-course we are, the longer we'll take
  local angle_to_target = AngleToTarget(
    I, missile_info, target, target_in_missile_coords)
  -- Add the time needed to make the turn, factoring in time wasted travelling
  -- in the wrong direction. First term is simply time to rotate the missile;
  -- multiplied by a factor of how much of this time is spent not closing, which
  -- is zero for on-angle, half for perpendicular, and one for directly away.
  local time_to_turn =
    (angle_to_target / turn_rate) * (angle_to_target / math.pi)
  time_to_target = time_to_target + time_to_turn

  -- Populate cache and return
  cache_for_missile[target.Id] = time_to_target
  return time_to_target
end

-- Returns boolean indicating if success is possible to intercept this target
function MissileCanHit(I, missile_info, target)
  local target_in_missile_coords =
    target.AimPointPosition - missile_info.Position
  local distance_to_target = target_in_missile_coords.magnitude

  -- Don't appear to be able to get height over sea-level for a
  -- missile_info, but sea is currently always the plane y == 0.
  local target_height_over_sea = target.AimPointPosition.y

  -- Is it in the wrong sphere of engagement (air/sea) for us?
  if     is_torpedo and target_height_over_sea >  sea_crossover_tolerance then
    return false end
  if not is_torpedo and target_height_over_sea < -sea_crossover_tolerance then
    return false end

  -- Is it beyond maximum engagement range?
  if distance_to_target > maximum_range then
    if dbg_spam then I:Log(string.format(
      "Missile %d can't reach target %d at distance %gm",
      missile_info.Id, target.Id, distance_to_target))
    end
    return false
  end

  -- Is it within our turning circle? (Can we turn X degrees in Y distance?)
  local angle_to_target = AngleToTarget(
    I, missile_info, target, target_in_missile_coords)
  local time_to_target  = TimeToTarget(
    I, missile_info, target, target_in_missile_coords)
  if angle_to_target > turn_rate * time_to_target then
    if dbg_spam then I:Log(string.format(
      "Missile %d can't reach target %d by turning %gdeg in %gs",
      missile_info.Id, target.Id, math.deg(angle_to_target), time_to_target))
    end
    return false
  end

  return true
end

-- Returns the best thing in targets that the missile can aim for, or nil if
-- there are no valid targets.
function BestTargetForMissile(I, missile_info, targets)
  -- Sort the targets by how desirable they are
  -- ("Lesser" here means better: comes early in the sort results)
  -- (Wanted: std::partial_sort)
  table.sort(targets, function(a,b)
    -- First rule: player's target of choice
    if a.PlayerTargetChoice and not b.PlayerTargetChoice then return true  end
    if b.PlayerTargetChoice and not a.PlayerTargetChoice then return false end

    -- Second rule: salvage comes last
    if a.Protected and not b.Protected then return true  end
    if b.Protected and not a.Protected then return false end

    -- Third rule: angle (prefer what we're already aimed at)
    -- Clamped to 90 degrees; worse than that, fall to later rules
    local missile_normal = missile_info.Velocity.normalized
    local a_normal = (a.AimPointPosition - missile_info.Position).normalized
    local a_angle = math.acos(Vector3.Dot(missile_normal, a_normal))
    local b_normal = (b.AimPointPosition - missile_info.Position).normalized
    local b_angle = math.acos(Vector3.Dot(missile_normal, b_normal))
    if a_angle > off_course_clamp then a_angle = off_course_clamp end
    if b_angle > off_course_clamp then b_angle = off_course_clamp end
    if a_angle < b_angle then return true  end
    if b_angle < a_angle then return false end

    -- Fourth rule: priority (low is more prioritized)
    if a.Priority < b.Priority then return true  end
    if b.Priority < a.Priority then return false end

    -- Fifth rule: score (very unlikely to reach this far)
    if a.Score > b.Score then return true  end
    if b.Score > a.Score then return false end

    -- Sixth rule: raw distance
    local a_distance = (a.AimPointPosition - missile_info.Position).magnitude
    local b_distance = (b.AimPointPosition - missile_info.Position).magnitude
    if a_distance < b_distance then return true  end
    if b_distance < a_distance then return false end

    -- Equivalence
    return false
  end)

  -- Find the best target we can hit
  for ignore, target in ipairs(targets) do
    if MissileCanHit(I, missile_info, target) then
      return target
    end
  end

  -- Nothing valid to hit; aim for the best invalid one if allowed
  if chase_unicorns then
    for ignore, target in ipairs(targets) do
      return target
    end
  end

  -- Nothing to hit :(
  return nil
end

-- Update the global targets cache
function ScanForTargets(I)
  -- Get some targets
  targets = {}
  local mainframe_count = I:GetNumberOfMainframes()
  for mainframe = 0, mainframe_count-1 do
    local target_count = I:GetNumberOfTargets(mainframe)
    for target = 0, target_count-1 do
      local target_info = I:GetTargetInfo(mainframe, target)
      if target_info.Valid then
        table.insert(targets, target_info) end
    end
  end
end

-- Steer the given missile toward its target
-- (and, currently, pick that target for it)
function SteerMissile(I, transciever, missile, missile_info)
  local best_target = BestTargetForMissile(
    I, missile_info, targets)

  if best_target == nil then
    -- Nothing we can hit!
    if not is_torpedo
      and missile_info.TimeSinceLaunch < max_climb_age then

      -- Gain altitude, make our turn easier
      local climb = missile_info.Position
      climb.y = climb.y + 1000000 -- will cruise toward this; make it high
      I:SetLuaControlledMissileAimPoint(transciever, missile,
        climb.x, climb.y, climb.z)
    else
      -- Just cruise along on our last course
    end
  else
    -- We have a target!
    local aim_at = best_target.AimPointPosition

    local target_in_missile_coords = aim_at - missile_info.Position

    -- TODO use target and own Velocity to aim at intercept point

    -- If our target is under the skim height, stay dry and fast until the last
    -- moment.
    if not is_torpedo and aim_at.y < sea_skim_height then
      local angle_to_target = AngleToTarget(
        I, missile_info, best_target, target_in_missile_coords)
      local time_to_target = TimeToTarget(
        I, missile_info, best_target, target_in_missile_coords)
      local fudge = 2.0 -- get ready early so we don't abort
      if angle_to_target * fudge > turn_rate * time_to_target then
        -- Can still make the turn later
        aim_at.y = sea_skim_height
        if dbg_spam then I:Log(
          "Missile " .. missile_info.Id ..
          " is sea-skimming before a dive") end
      end
    end

    -- Aim the point we've decided on
    I:SetLuaControlledMissileAimPoint(transciever, missile,
      aim_at.x, aim_at.y, aim_at.z)

    -- If close enough, work out if we've overshot
    local distance_to_target = target_in_missile_coords.magnitude
    if distance_to_target < prox_abort then
      -- How close will we be half a second from now?
      local future_target  =
        aim_at                + (best_target.Velocity  * 0.5)
      local future_missile =
        missile_info.Position + (missile_info.Velocity * 0.5)
      local future_distance = (future_target - future_missile).magnitude
      if future_distance > distance_to_target then
        if hud_spam then I:LogToHud(
          "Missile " .. missile_info.Id .. " overshooting; detonating!")
        end
        I:DetonateLuaControlledMissile(transciever, missile)
      end
    end
  end
end

-- Update handler --------------------------------------------------------------
function Update(I)
  -- Measurement mode doesn't care about targets or the cache
  if not measurement_mode then
    -- These are always per-tick because doing anything else with stale target
    -- intel is a waste of time, and the cache is invalidated by missiles
    -- moving.
    ClearCalculationCaches(I)
    ScanForTargets(I)
  end

  -- Do something with each missile
  local already_measuring = false
  local transciever_count = I:GetLuaTransceiverCount()
  for transciever = 0, transciever_count-1 do
    local missiles = I:GetLuaControlledMissileCount(transciever)
    for missile = 0, missiles-1 do
      local missile_info = I:GetLuaControlledMissileInfo(transciever, missile)

      if measurement_mode then
        -- For best measurements, we want tick-accurate control, so there's
        -- no interval for this.
        if already_measuring then
          I:LogToHud(
            "TOO MANY ACTIVE MISSILES; MEASURMENTS INVALID; CLEANING UP!");
          -- Help the player get rid of any lurking mines, etc.
          -- Bonus if misused: turns volleys into launch-bay fireworks! :3c
          I:DetonateLuaControlledMissile(transciever, missile)
        else
          MeasurementModeGuidance(I, transciever, missile, missile_info)
          already_measuring = true
        end
      else
        -- Normal guidance
        if tick_counter % steer_interval == 0 then
          SteerMissile(I, transciever, missile, missile_info)
        end
      end
    end
  end

  if profile_spam then
    I:LogToHud(profile_cache_hits .. " cache hits")
  end
end
