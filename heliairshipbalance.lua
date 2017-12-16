--[[
From the Depths Airship Lift Balancer
Copyright 2016 Philip Boulain. Licensed under the ISC License.

Automatically adjusts all dedicated helispinners facing either up or down to
maintable stable hover.
]]--

-- Tunables --------------------------------------------------------------------
-- Desired cruise height in meters.
target_altitude          = 300
-- How much any one spinner can vary its deviation from the others. This is
-- *after* allowing for its offset relative to the CoM, so maps directly to
-- how much pitch/roll to put up with. Also affects drift from the target
-- altitude and aggression to correct it.
maximum_acceptable_delta = 5
-- How many meters to keep clear over terrain, raising target altitude as
-- needed. Zero to disable. Samples at the locations of the spinners, so may
-- still bump into very steep gradients if you have blocks beyond them (e.g.
-- their blades) or they are not powerful enough to match the climb rate.
minimum_ground_clearance = 100
-- How many meters to rise against any hostiles, zero to disable. Useful if
-- all your weapons are downward-facing.
above_enemies            = 100
-- Reverse spinners that face downwards, if you're not using Always Up force.
-- (Not recommended! Without Always Up, your lift rotors will cause positive
-- roll/yaw feedback and make your craft very unstable.)
respect_downwards        = false
-- Use engine power to *lose* altitude, if too high, rather than letting
-- gravity do it. In case you hate fuel, or something.
power_downwards          = false
-- Maximum spinner speed magnitude to ever use. 0--30.
maximum_speed            = 30
-- How often to scan the vehicle for spinners, in ticks. This can be pretty
-- high; 40 will do it every second, and that's plenty.
locate_interval          = 40
-- How often to balance spinners, in ticks. 1 for maximum smoothness.
balance_interval         = 1
-- True to spam the Lua block log with control output information.
dbg_trace                = false
--------------------------------------------------------------------------------

-- State
tick_counter = 0
lift_spinners = {} -- see LocateLiftSpinners for format
interval_period = locate_interval * balance_interval
last_spinner_count = 0 -- including unsuitable, for detecting damage

-- Update lift_spinners with tables for each spinner, if changed
function LocateLiftSpinners(I)
  local new_spinners = {}
  local up = Vector3(0, 1, 0)

  local spinners = I:GetSpinnerCount()
  last_spinner_count = spinners
  for spinner = 0, spinners - 1 do
    if I:IsSpinnerDedicatedHelispinner(spinner) then
      local spinner_info = I:GetSpinnerInfo(spinner)
      local spinner_thrust = spinner_info.LocalRotation * up
      if math.abs(spinner_thrust.y) > 0.5 then
        local downwards = (spinner_thrust.y < 0)

        table.insert(new_spinners, {
          index     = spinner,
          offset    = spinner_info.LocalPositionRelativeToCom.y,
          downwards = downwards
        })
      end
    end
  end

  if #lift_spinners ~= #new_spinners then
    lift_spinners = new_spinners
    I:LogToHud(string.format("Found %d lift spinners", #lift_spinners))
    for ignore, spinner in ipairs(lift_spinners) do
      local downwards = ""
      if spinner.downwards then downwards = " (facing down)" end
      I:Log(string.format("Found spinner %d at Y offset %g%s",
        spinner.index, spinner.offset, downwards))
    end
  end
end

function BalanceLiftSpinners(I)
  local effective_target_altitude = target_altitude

  -- Avoid a crash if the number of spinners has changed, e.g. destroyed
  if last_spinner_count ~= I:GetSpinnerCount() then
    I:Log("Forcing spinner recount due to apparent damage")
    lift_spinners = {}
    LocateLiftSpinners(I)
  end

  -- Scan for terrain under the spinners and boost altitude as necessary
  if minimum_ground_clearance > 0 then
    for ignore, spinner in ipairs(lift_spinners) do
      local spinner_info = I:GetSpinnerInfo(spinner.index)
      local terrain = I:GetTerrainAltitudeForPosition(spinner_info.Position)
      terrain = terrain + minimum_ground_clearance
      if terrain > effective_target_altitude then
        effective_target_altitude = terrain
      end
    end
  end

  -- Climb to gain a height advantage over any enemies
  if above_enemies > 0 then
    local mainframes = I:GetNumberOfMainframes()
    for mainframe = 0, mainframes - 1 do
      local targets = I:GetNumberOfTargets(mainframe)
      for target = 0, targets - 1 do
        -- (target_altitude is something else, remember)
        local target_info = I:GetTargetInfo(mainframe, target)
        local climb_to = target_info.Position.y + above_enemies
        if climb_to > effective_target_altitude then
          effective_target_altitude = climb_to
        end
      end
    end
  end

  -- Get the relative altitudes of every spinner
  local spinner_altitudes = {}
  local  lowest_altitude  =  1000000
  local highest_altitude  = -1000000
  local    mean_altitude  = 0
  for ignore, spinner in ipairs(lift_spinners) do
    local spinner_info = I:GetSpinnerInfo(spinner.index)
    local altitude = spinner_info.Position.y - spinner.offset
    spinner_altitudes[spinner.index] = altitude
    if altitude <  lowest_altitude then  lowest_altitude = altitude end
    if altitude > highest_altitude then highest_altitude = altitude end
    mean_altitude = mean_altitude + altitude
  end
  mean_altitude = mean_altitude / #lift_spinners

  -- Detect if one spinner is racing ahead/falling behind, and clamp the target
  -- to let the others/it catch up. This keeps pitch/roll under control, so long
  -- as the vehicle is still physically capable of doing so.
  if highest_altitude - lowest_altitude > maximum_acceptable_delta then
    -- Use the mean to judge how we're perfoming against the target, since this
    -- works even if the spinners are far away from the vehicle CoM. We'll catch
    -- up faster if we keep out target at the extreme extent, but for seriously
    -- weird designs with tight constraints (range of spinner offsets greater
    -- than the acceptable delta), we can get tangled in an endless climb or
    -- descent. Detect that and fallback to the mean to just stabilize.
    if effective_target_altitude > mean_altitude then
      -- Trying to ascend; clamp at the top end
      local new_target_altitude =  lowest_altitude + maximum_acceptable_delta
      if new_target_altitude > effective_target_altitude then
        effective_target_altitude = new_target_altitude
      else
        effective_target_altitude = mean_altitude
      end
    else
      -- Trying to descend; clamp at the bottom end
      local new_target_altitude = highest_altitude - maximum_acceptable_delta
      if new_target_altitude < effective_target_altitude then
        effective_target_altitude = new_target_altitude
      else
        effective_target_altitude = mean_altitude
      end
    end
  end

  -- Set the spinner speeds to aim for our target altitude
  for ignore, spinner in ipairs(lift_spinners) do
    local current_altitude = spinner_altitudes[spinner.index]

    -- Calculate error fraction:
    -- -1 at lowest acceptable, 0 on-target, 1 at highest acceptable
    local altitude_error = current_altitude - effective_target_altitude
    local error_fraction = altitude_error / maximum_acceptable_delta
    error_fraction = math.max(-1.0, error_fraction)
    error_fraction = math.min( 1.0, error_fraction)

    -- After much fussing with PIDs and simple linear ramps, it turns out making
    -- the spinner speed a pure multiplier of altitude error is actually far
    -- more stable and requires no tuning. The intertia of the craft provides
    -- the integral term to settle this to the stable hover speed, although it
    -- may still be prone to periodic oscillations. Without a constant offset
    -- term it will also hang below the midpoint of the acceptable range.
    local speed
    if power_downwards then
      -- Balance engine power around the error directly
      speed = maximum_speed * -error_fraction
    else
      -- Balance engine power to lurk somewhere in the range (-1..+1 -> 1..0)
      speed = maximum_speed * (1 - ((error_fraction + 1) * 0.5))
    end

    -- Clamp the speed to our maximum
    speed = math.min(maximum_speed, speed)
    if power_downwards then
      speed = math.max(-maximum_speed, speed)
    else
      speed = math.max(0, speed)
    end

    -- Reverse the direction if this spinner is upside-down and non-always up
    -- spinners are in use.
    if respect_downwards and spinner.downwards then speed = -speed end

    if dbg_trace then I:Log(string.format(
      "Spinner %d set %g for error %g (real %g)",
      spinner.index, speed, error_fraction, altitude_error))
    end
    I:SetSpinnerContinuousSpeed(spinner.index, speed)
  end
  if dbg_trace then I:Log(string.format(
    "Spinner altitude lowpoint %g highpoint %g mean %g targetting %g",
    lowest_altitude, highest_altitude, mean_altitude,
    effective_target_altitude))
  end
end

-- Main updater
function Update(I)
  if tick_counter % locate_interval  == 0 then  LocateLiftSpinners(I) end
  if tick_counter % balance_interval == 0 then BalanceLiftSpinners(I) end
  tick_counter = (tick_counter + 1) % interval_period
end
