--[[
From the Depths Airship Propeller Drive System
Copyright 2017 Philip Boulain. Licensed under the ISC License.

Automatically adjusts all dedicated helispinners facing forward for smooth
propulsion and yaw.

Requires four ACB-controlled hydroplanes, that set nonzero angle on desired
movement, in order from the front: forward, back, left, right.
]]--

-- Tunables --------------------------------------------------------------------
-- Maximum spinner speed magnitude to ever use. 0--30.
maximum_speed            = 30
-- Multiplier for spinning down a prop that should be turning the other way
braking_factor           = 0.8
-- Linear factor for accellerating a prop (also added when reversing it)
accel_factor             = 0.5
-- Steering factor; sums to -1 or 1 as AI holds a steer
steer_factor             = 0.005
-- How often to scan the vehicle for spinners, in ticks. This can be pretty
-- high; 40 will do it every second, and that's plenty.
locate_interval          = 40
-- How often to update spinners, in ticks. 1 for maximum smoothness.
update_interval          = 1
-- True to reverse spin direction on each side, for counterrotating propellers
reverse_left             = false
reverse_right            = false
-- True to spam the Lua block log with control output information.
dbg_trace                = false
-- Trace detected input to HUD
dbg_input                = false
-- Debug hydrofoil inputs to HUD
dbg_hydro                = false
--------------------------------------------------------------------------------

-- State
tick_counter = 0
spinners = {} -- see LocateSpinners for format
hydrofoil_f = -1 -- IDs of input hydrofoils
hydrofoil_b = -1
hydrofoil_l = -1
hydrofoil_r = -1
hydrofoils_good = false
steering = 0
interval_period = locate_interval * update_interval
last_spinner_count = 0 -- including unsuitable, for detecting damage
last_hydrofoil_count = 0
last_input = ""

-- Update spinners with tables for each spinner, if changed
function LocateSpinners(I)
  local new_spinners = {}
  local up = Vector3(0, 1, 0)

  local spinner_count = I:GetSpinnerCount()
  last_spinner_count = spinner_count
  for spinner = 0, spinner_count - 1 do
    if I:IsSpinnerDedicatedHelispinner(spinner) then
      local spinner_info = I:GetSpinnerInfo(spinner)
      local spinner_thrust = spinner_info.LocalRotation * up
      if math.abs(spinner_thrust.z) > 0.5 then
        table.insert(new_spinners, {
          index  = spinner,
          speed  = 0,
	  rear   = (spinner_thrust.z < 0),
          offset = spinner_info.LocalPositionRelativeToCom.x
        })
      end
    end
  end

  if #spinners ~= #new_spinners then
    spinners = new_spinners
    I:LogToHud(string.format("Found %d forward spinners", #spinners))
    for ignore, spinner in ipairs(spinners) do
      I:Log(string.format("Found spinner %d at Z offset %g",
        spinner.index, spinner.offset))
    end
  end
end

function LocateHydrofoils(I)
  local hydrofoil_count = I:Component_GetCount(8)
  local hydrofoils = {}
  for hydrofoil = 0, hydrofoil_count - 1 do
    local pos = I:Component_GetLocalPosition(8, hydrofoil)
    table.insert(hydrofoils, {
      index  = hydrofoil,
      offset = pos.z
    })
  end

  -- With -Z being forward, these need to be sorted backwards
  table.sort(hydrofoils, function(a,b) return a.offset > b.offset end)

  hydrofoil_f = -1
  hydrofoil_b = -1
  hydrofoil_l = -1
  hydrofoil_r = -1
  for ignore, hydrofoil in ipairs(hydrofoils) do
    -- ick
    if     hydrofoil_f == -1 then hydrofoil_f = hydrofoil.index
    elseif hydrofoil_b == -1 then hydrofoil_b = hydrofoil.index
    elseif hydrofoil_l == -1 then hydrofoil_l = hydrofoil.index
    elseif hydrofoil_r == -1 then hydrofoil_r = hydrofoil.index
    end
  end
  if hydrofoil_r ~= -1 then hydrofoils_good = true end

  if not hydrofoils_good then
    I:LogToHud("Control hydrofoils damaged! Cannot sense movement intent!")
  end
  last_hydrofoil_count = hydrofoil_count
end

function UpdateSpinners(I)
  -- Avoid a crash if the number of spinners has changed, e.g. destroyed
  if last_spinner_count ~= I:GetSpinnerCount() then
    I:Log("Forcing spinner recount due to apparent damage")
    spinners = {}
    LocateSpinners(I)
  end

  if last_hydrofoil_count ~= I:Component_GetCount(8) then
    I:Log("Forcing hydrofoil redetect due to apparent damage")
    hydrofoils_good = false
    LocateHydrofoils(I)
  end

  if dbg_hydro then
    I:LogToHud(string.format("H: F%g(%g) B%g(%g) L%g(%g) R%g(%g)",
      hydrofoil_f, I:Component_GetFloatLogic(8, hydrofoil_f),
      hydrofoil_b, I:Component_GetFloatLogic(8, hydrofoil_b),
      hydrofoil_l, I:Component_GetFloatLogic(8, hydrofoil_l),
      hydrofoil_r, I:Component_GetFloatLogic(8, hydrofoil_r)))
  end

  -- Get targets for left and right sides
  local target_l = 0
  local target_r = 0
  local movement = "steady"
  if hydrofoils_good then
    if     I:Component_GetFloatLogic(8, hydrofoil_l) ~= 0 then
      steering = math.min(0, math.max(steering - steer_factor, -1))
      I:Component_SetFloatLogic(8, hydrofoil_l, 0)
    elseif I:Component_GetFloatLogic(8, hydrofoil_r) ~= 0 then
      steering = math.max(0, math.min(steering + steer_factor,  1))
      I:Component_SetFloatLogic(8, hydrofoil_r, 0)
    else
      steering = 0
    end
    if     I:Component_GetFloatLogic(8, hydrofoil_f) ~= 0 then
      target_l = maximum_speed
      target_r = maximum_speed
      movement = "fowards"
      I:Component_SetFloatLogic(8, hydrofoil_f, 0)
    elseif I:Component_GetFloatLogic(8, hydrofoil_b) ~= 0 then
      target_l = -maximum_speed
      target_r = -maximum_speed
      movement = "back"
      I:Component_SetFloatLogic(8, hydrofoil_b, 0)
    end
  end
  -- Hard turns get to override forward/backward movement with pivots
  target_l = target_l + (maximum_speed * 2 * steering)
  target_r = target_r - (maximum_speed * 2 * steering)
  if steering < -0.5 then movement = movement .. " and left" end
  if steering >  0.5 then movement = movement .. " and right" end
  if reverse_left  then target_l = -target_l end
  if reverse_right then target_r = -target_r end
  target_l = math.min(maximum_speed, math.max(-maximum_speed, target_l))
  target_r = math.min(maximum_speed, math.max(-maximum_speed, target_r))

  -- Set the spinner speeds to aim for our targets
  -- Unlike the lift logic, each spinner here is independently laggy
  for index, spinner in ipairs(spinners) do
    local target = 0
    local speed  = spinner.speed

    if spinner.offset < 0 then
      target = target_l
    else
      target = target_r
    end

    -- Some basic inertia to stop mad AI hysteresis
    if (target < 0 and speed > 0) or (target > 0 and speed < 0) then
      speed = speed * braking_factor
    end
    if target < speed then speed = speed - accel_factor end
    if target > speed then speed = speed + accel_factor end
    if math.abs(target - speed) < 1 then speed = target end

    if dbg_trace then I:Log(string.format(
      "Spinner %d set %g for %g",
      spinner.index, speed, target))
    end
    local reversable_speed = speed
    if spinner.rear then reversable_speed = -speed end
    I:SetSpinnerContinuousSpeed(spinner.index, reversable_speed)
    spinner.speed = speed
  end

  if dbg_input and last_input ~= movement then
    I:LogToHud(string.format("Detected desire to move %s", movement))
    last_input = movement
  end
end

-- Main updater
function Update(I)
  if tick_counter % locate_interval == 0 then
    LocateSpinners(I)
    LocateHydrofoils(I)
  end
  if tick_counter % update_interval == 0 then UpdateSpinners(I) end
  tick_counter = (tick_counter + 1) % interval_period
end
