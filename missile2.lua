--[[
From the Depths Missile Controller MkII
Copyright 2016 Philip Boulain. Licensed under the GNU GPL.

MkII learns some tricks from https://github.com/wcripe/ftd-lancer-missile
(and borrows a few code snippets, hence the license change).

Shortcomings:
  - Doesn't try to avoid overkill.
  - Prediction is nowhere near as smart as Blothorn's (...currently none).
  - Doesn't try to burn the last of the fuel in a final charge like Kharel's
    (this works as a tradeoff: these will make multiple passes).

Autodetection:
  - The presence of thrusters/propellers set the domain of missiles. Cross-
    domain missiles with both are permitted.
  - Measurement mode and performance estimates are gone. Varying thrust means
    they just aren't constant enough (plus atmospheric fin changes).
]]--

-- Tunables --------------------------------------------------------------------
-- Minimum and maximum thrust fractions to ever use, for variable thrusters.
min_thrust               = 0.0
max_thrust               = 0.33
-- Jump/dive depth for missiles, allowing them to cross-target (meters)
sea_crossover_tolerance  = 10
-- Distance beyond which won't even *try* to persue targets (meters)
maximum_range            = 1500
-- If less than this fraction of fuel remains, arm the proximity overshoot
-- trigger and detonate if distance to target starts increasing.
-- Target block changes can make this ineffective at large values.
-- FIXME Going to be broken for anything but pure variable thruster missiles.
prox_abort_fuel          = 0.25
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
-- If true, a missile will only switch to another target if it determines its
-- current one is no longer valid (becomes unreachable, is destroyed, etc.).
-- Otherwise they may break off to go for opportune targets en-route.
sticky_targetting        = true
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

-- Really finnicky tunables ----------------------------------------------------
-- You probably don't actually have to mess with these unless you're having
-- problems.
-- Spam the Lua block log with de-bugging messages
dbg_spam                 = false
-- Spam the HUD with profiling messages
profile_spam             = false
-- Spam the HUD when we do something cool
hud_spam                 = true
-- Update intervals. Lower is more frequent (better guidance), higher may save
-- you some CPU time if your machine is struggling. Some work is always done
-- per-tick.
-- How often a missile should re-evaluate its target, in seconds. This is done
-- from the target's own lifespan counter so they don't all recalculate at once.
target_assign_interval   = 0.2
-- How often to steer the missiles, in ticks (40 = one second).
steer_interval           = 1

-- Missile behaviour -----------------------------------------------------------
tick_counter = 0
interval_period = steer_interval
targets = {} -- returns of GetTargetInfo(); gets resorted(!)

-- Targetting decisions; map from missile ID to a table with:
--   target_id   - id of target
--   last_update - time target was last considered by missile clock
--   is_air      - missile can traverse air (has thrusters)
--   is_water    - missile can traverse water (has propellers)
--   fuel_max    - fuel capacity of this missile
--   fuel_rate   - estimated fuel burn per steer interval
--   fuel_left   - estimated fuel remaining
--   thrusters   - table of variable thruster indicies in the missile parts
targetting_decisions = {}
profile_decisions    = 0

-- *ToTarget caches; tables of missile IDs mapping to tables of target IDs
-- mapping to the result (see the *ToTarget functions)
cache_angle_to_target = {}
cache_time_to_target  = {}
profile_cache_hits    = 0

-- Invalidate the *ToTarget calculation caches
function ClearCalculationCaches(I)
  cache_angle_to_target = {}
  cache_time_to_target  = {}
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

-- Returns boolean indicating if success is possible to intercept this target
function MissileCanHit(I, missile_info, target)
  local targetting_decision = targetting_decisions[missile_info.Id]
  local target_in_missile_coords =
    target.AimPointPosition - missile_info.Position
  local distance_to_target = target_in_missile_coords.magnitude

  -- Don't appear to be able to get height over sea-level for a
  -- missile_info, but sea is currently always the plane y == 0.
  local target_height_over_sea = target.AimPointPosition.y

  -- Is it in the wrong sphere of engagement (air/sea) for us?
  if not targetting_decision.is_air
    and target_height_over_sea >  sea_crossover_tolerance then
    return false end
  if not targetting_decision.is_water
    and target_height_over_sea < -sea_crossover_tolerance then
    return false end

  -- Is it beyond maximum engagement range?
  if distance_to_target > maximum_range then
    if dbg_spam then I:Log(string.format(
      "Missile %d can't reach target %d at distance %gm",
      missile_info.Id, target.Id, distance_to_target))
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
    -- Clamped to off_course_clamp; worse than that, fall to later rules
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

-- (Possibly) choose a target for the missile. Returns nothing (but updates the
-- targetting decision for it).
function TargetMissile(I, transciever, missile, missile_info)
  -- Find/initialize the targetting decision for this missile
  local targetting_decision = targetting_decisions[missile_info.Id]
  if targetting_decision == nil then
    targetting_decision = {
      target_id   = nil,
      last_update = -target_assign_interval,
      is_air      = false,
      is_water    = false,
      fuel_max    = 0,
      fuel_rate   = 0,
      fuel_left   = 0,
      thrusters   = {}
    }

    -- Scan the missile's design
    local parts = I:GetMissileInfo(transciever, missile)
    for part_id, part in ipairs(parts.Parts) do
      if(string.find(part.Name, 'fuel')) then
        targetting_decision.fuel_max = targetting_decision.fuel_max + 5000
      elseif(string.find(part.Name, 'variable speed thruster')) then
        targetting_decision.is_air = true
        table.insert(targetting_decision.thrusters, part_id)
        targetting_decision.fuel_rate = targetting_decision.fuel_rate
          + (part.Registers[2] / 40)
      elseif(string.find(part.Name, 'short range thruster')) then
        targetting_decision.is_air = true
      elseif (string.find(part.Name, 'propeller')) then
        targetting_decision.is_water = true
      end
    end
    targetting_decision.fuel_left = targetting_decision.fuel_max

    targetting_decisions[missile_info.Id] = targetting_decision
  end

  -- Is it time to reassess its target?
  if missile_info.TimeSinceLaunch >=
    targetting_decision.last_update + target_assign_interval then

    targetting_decision.last_update = missile_info.TimeSinceLaunch

    -- Do we already have a valid target?
    if sticky_targetting then
      local current_target = nil
      for ignore, target in ipairs(targets) do
        if target.Id == targetting_decision.target_id then
          current_target = target
        end
      end
      if current_target ~= nil
        and MissileCanHit(I, missile_info, current_target) then

        -- Stick to this target
        return
      end
    end

    -- Set the best target for this missile
    if profile_spam then profile_decisions = profile_decisions + 1 end
    local best_target_id = BestTargetForMissile(I, missile_info, targets)
    if best_target_id ~= nil then best_target_id = best_target_id.Id end
    targetting_decision.target_id = best_target_id
  end
end

-- Steer the given missile toward its target
function SteerMissile(I, transciever, missile, missile_info)
  -- Get the target we've been assigned; we should always have a decision
  local best_target = nil
  local targetting_decision = targetting_decisions[missile_info.Id]
  local thrust_fraction = min_thrust
  -- This is not wonderously efficient, but the list should always be small
  for ignore, target in ipairs(targets) do
    if target.Id == targetting_decision.target_id then
      best_target = target
    end
  end

  if best_target == nil then
    -- Nothing we can hit!
    if targetting_decision.is_air
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

    -- Set the thrust fraction based on the turn we're trying to make; if we're
    -- perpendicular, we want minimum thrust
    local angle_to_target = AngleToTarget(
      I, missile_info, best_target, target_in_missile_coords)
    --local angle_convergence = 1.0 - (angle_to_target / (math.pi / 2.0))
    local angle_convergence = math.cos(angle_to_target)
    if angle_to_target > math.pi / 2.0 then angle_convergence = 0.0 end
    if angle_convergence < 0.0 then angle_convergence = 0.0 end
    thrust_fraction = min_thrust +
      ((max_thrust - min_thrust) * angle_convergence)

    -- If our target is under the skim height, stay dry and fast until the last
    -- moment.
    -- TODO this got much dumber with the removal of turn_rate and TimeToTarget
    -- TODO this is broken if the missile is very close since it doesn't
    --      consider the angle to the proposed aim_at.y point
    if not targetting_decision.is_water and aim_at.y < sea_skim_height then
      if angle_to_target < (off_course_clamp / 2.0) then
        -- Can still make the turn later
        aim_at.y = sea_skim_height
        if dbg_spam then I:Log(
          "Missile " .. missile_info.Id ..
          " is sea-skimming before a dive") end
      end
    end

    -- Are we a non-torpedo missile that's taken a dunk (or been launched from
    -- underwater without enough force to clear the surface yet?), and we're
    -- not *trying* to hit something underwater? (Missiles without an intial
    -- target should climb anyway; missiles that have lost their target are
    -- probably better off coasting.) Ignores sea_crossover_tolerance, as
    -- air missiles below the waterline can't move themselves.
    if not targetting_decision.is_water
      and missile_info.Position.y < 0
      and aim_at.y > missile_info.Position.y then
      -- Forget the target, get airborn before we burn out
      aim_at = missile_info.Position
      aim_at.y = aim_at.y + 1000000
      -- Stop burning fuel best we can; it's doing nothing! Override min_thrust.
      thrust_fraction = 0.0
    end

    -- Aim the point we've decided on, with the throttle we've decided on
    I:SetLuaControlledMissileAimPoint(transciever, missile,
      aim_at.x, aim_at.y, aim_at.z)

    local parts = I:GetMissileInfo(transciever, missile)
    for ignore, thruster in ipairs(targetting_decision.thrusters) do
      --parts.Parts[thruster]:SendRegister(2,
      --  (9050 / thrust_fraction) + 50)
      parts.Parts[thruster]:SendRegister(2, thrust_fraction * 1000) -- why 1K?
    end

    -- Update fuel rate estimate
    -- FIXME This ignores SRTs/propellers
    targetting_decision.fuel_rate =
      thrust_fraction * steer_interval *
      (table.getn(targetting_decision.thrusters) / 40)

    -- If low on fuel, work out if we've overshot
    if targetting_decision.fuel_left <
      (targetting_decision.fuel_max * prox_abort_fuel) then

      local distance_to_target = target_in_missile_coords.magnitude
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

  -- Update fuel estimate for this upcoming burn
  if targetting_decision.fuel_left > 0 then
    targetting_decision.fuel_left = targetting_decision.fuel_left -
      targetting_decision.fuel_rate
  end
end

-- Update handler --------------------------------------------------------------
function Update(I)
  -- These are always per-tick because doing anything else with stale target
  -- intel is a waste of time, and the cache is invalidated by missiles
  -- moving.
  ClearCalculationCaches(I)
  ScanForTargets(I)

  -- Do something with each missile
  local missile_id_seen = {}
  local transciever_count = I:GetLuaTransceiverCount()
  for transciever = 0, transciever_count-1 do
    local missiles = I:GetLuaControlledMissileCount(transciever)
    for missile = 0, missiles-1 do
      local missile_info = I:GetLuaControlledMissileInfo(transciever, missile)
      missile_id_seen[missile_info.Id] = true
      TargetMissile(I, transciever, missile, missile_info)
      if tick_counter % steer_interval == 0 then
        SteerMissile(I, transciever, missile, missile_info)
      end
    end
  end

  -- Clean up targetting decisions for missiles that no longer exist
  for missile_id, ignore in ipairs(targetting_decisions) do
    if missile_id_seen[missile_id] == nil then
      targetting_decisions[missile_id] = nil
    end
  end

  -- Profiling noise
  if profile_spam then
    I:LogToHud(
      profile_decisions .. " decisions; " ..
      profile_cache_hits .. " cache hits")
    profile_decisions = 0
    profile_cache_hits = 0
  end
end
