-- C-330/C-330M work-speed-aware automatic gearbox correction.
-- Loaded before C330TransmissionFix.lua, but installs on the first mission update
-- so it wraps the final validated controller instead of the raw GIANTS method.

C330TransmissionWorkFix = C330TransmissionWorkFix or {}

local LOW_RANGE = 1
local HIGH_RANGE = 2
local LOW_RANGE_RATIO = 0.24691358
local MAX_RPM = 2200
local WORK_MIN_RPM_AT_LIMIT = 1500
local WORK_RANGE_UP_RPM = 2050
local WORK_RANGE_UP_DWELL_MS = 2000
local WORK_RELEASE_HOLD_MS = 2500
local LUG_DOWNSHIFT_RPM = 1450
local LUG_DOWNSHIFT_LOAD = 0.75
local LUG_DOWNSHIFT_ACCEL = 0.85
local RANGE_CHANGE_COOLDOWN_MS = 800
local modDirectory = g_currentModDirectory

-- Nominal high-range speeds at 2200 rpm. Low range is the same three gears
-- through the factory 0.24691358 reducer.
local HIGH_RANGE_SPEEDS = {
    ["C-330"] = {7.389, 14.324, 22.878},
    ["C-330M"] = {8.491, 16.460, 26.290}
}

local function endsWith(value, suffix)
    return type(value) == "string"
        and type(suffix) == "string"
        and string.sub(value, -string.len(suffix)) == suffix
end

local function isTargetVehicle(vehicle)
    if vehicle == nil or type(vehicle.configFileName) ~= "string" then
        return false
    end
    if modDirectory ~= nil
        and string.sub(vehicle.configFileName, 1, string.len(modDirectory)) ~= modDirectory then
        return false
    end
    return endsWith(vehicle.configFileName, "c330m.xml")
end

local function getMotorName(motor)
    if motor == nil or not isTargetVehicle(motor.vehicle) then
        return nil
    end
    if motor.c330WorkMotorName ~= nil then
        return motor.c330WorkMotorName
    end

    local vehicle = motor.vehicle
    local configurations = vehicle.configurations
    if configurations == nil or configurations.motor == nil or vehicle.xmlFile == nil then
        return nil
    end

    local key = ConfigurationUtil.getXMLConfigurationKey(
        vehicle.xmlFile,
        configurations.motor,
        "vehicle.motorized.motorConfigurations.motorConfiguration",
        "vehicle.motorized",
        "motor"
    )
    if key == nil then
        return nil
    end

    local name = vehicle.xmlFile:getValue(key .. "#name")
    if HIGH_RANGE_SPEEDS[name] ~= nil then
        motor.c330WorkMotorName = name
        return name
    end
    return nil
end

local function isAutomaticForward(motor)
    return getMotorName(motor) ~= nil
        and motor.gearGroups ~= nil
        and #motor.gearGroups == 2
        and motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC
        and (motor.currentDirection or 1) >= 0
end

local function getRpm(motor)
    if motor ~= nil and motor.getLastModulatedMotorRpm ~= nil then
        local value = tonumber(motor:getLastModulatedMotorRpm())
        if value ~= nil then
            return value
        end
    end
    return tonumber(motor ~= nil and motor.lastMotorRpm) or 0
end

local function getLoad(motor)
    return C330Runtime.load(motor)
end

local function getFiniteSpeedLimit(vehicle, withTools)
    if vehicle == nil or type(vehicle.getSpeedLimit) ~= "function" then
        return nil
    end
    -- Capture only the first return value. getSpeedLimit can also return a boolean.
    local ok, value = pcall(vehicle.getSpeedLimit, vehicle, withTools)
    if not ok then
        return nil
    end
    value = tonumber(value)
    if value == nil or value <= 0 or value == math.huge or value > 1000 then
        return nil
    end
    return value
end

local function getActiveWorkSpeedLimit(vehicle)
    local toolsLimit = getFiniteSpeedLimit(vehicle, true)
    if toolsLimit == nil then
        return nil
    end

    local vehicleLimit = getFiniteSpeedLimit(vehicle, false)
    if vehicleLimit ~= nil and toolsLimit >= vehicleLimit - 0.05 then
        return nil
    end
    return toolsLimit
end

local function getVirtualGear(range, gear)
    return ((range or LOW_RANGE) - 1) * 3 + math.max(1, math.min(gear or 1, 3))
end

local function virtualToRangeGear(virtualGear)
    virtualGear = math.max(1, math.min(virtualGear or 1, 6))
    if virtualGear <= 3 then
        return LOW_RANGE, virtualGear
    end
    return HIGH_RANGE, virtualGear - 3
end

local function getWorkTarget(motor, speedLimit)
    local motorName = getMotorName(motor)
    local high = motorName ~= nil and HIGH_RANGE_SPEEDS[motorName] or nil
    if high == nil or speedLimit == nil then
        return nil, nil, nil, nil
    end

    local speeds = {
        high[1] * LOW_RANGE_RATIO,
        high[2] * LOW_RANGE_RATIO,
        high[3] * LOW_RANGE_RATIO,
        high[1], high[2], high[3]
    }

    -- Choose the highest real gear that would still keep the engine at or above
    -- the useful 1500 rpm floor at the implement's active working speed.
    for virtualGear = 6, 1, -1 do
        local requiredRpm = MAX_RPM * speedLimit / speeds[virtualGear]
        if requiredRpm >= WORK_MIN_RPM_AT_LIMIT then
            local range, gear = virtualToRangeGear(virtualGear)
            return range, gear, virtualGear, requiredRpm
        end
    end

    local requiredRpm = MAX_RPM * speedLimit / speeds[1]
    return LOW_RANGE, 1, 1, requiredRpm
end

local function markDecision(motor, range, gear, reason, workLimit, workTargetVirtual)
    local now = g_time or 0
    motor.c330FixRequestedRange = range
    motor.c330FixRequestedGear = gear
    motor.c330FixRequestedRangeAt = now
    motor.c330FixRequestedRangeReason = reason
    motor.c330WorkSpeedLimit = workLimit
    motor.c330WorkTargetVirtual = workTargetVirtual
end

local function setUpshiftHold(motor, untilTime)
    local current = tonumber(motor.c330FixUpshiftHoldUntil) or 0
    motor.c330FixUpshiftHoldUntil = math.max(current, untilTime)
end

local function requestRange(motor, targetRange, targetGear, reason, workLimit, targetVirtual)
    local now = g_time or 0
    markDecision(motor, targetRange, targetGear, reason, workLimit, targetVirtual)
    if (motor.activeGearGroupIndex or LOW_RANGE) ~= targetRange then
        motor:setGearGroup(targetRange)
    end
    motor.c330FixRangeCooldownUntil = now + RANGE_CHANGE_COOLDOWN_MS
    motor.c330FixRangeRecoverySince = nil
    motor.autoGearChangeTimer = math.max(motor.autoGearChangeTime or 0, RANGE_CHANGE_COOLDOWN_MS)
    return targetGear
end

-- P2: reserve estimates are selection heuristics, not a replacement engine model.
local function nominal(motor, range, gear)
    local speeds = HIGH_RANGE_SPEEDS[getMotorName(motor)]
    return speeds[gear] * (range == LOW_RANGE and LOW_RANGE_RATIO or 1)
end
local function state(motor)
    if motor.c330P2 == nil then motor.c330P2 = {} end
    return motor.c330P2
end
local function decision(motor, range, gear, reason)
    markDecision(motor, range, gear, reason, motor.c330WorkSpeedLimit, motor.c330WorkTargetVirtual)
    local s = state(motor)
    s.reason, s.decisionAt, s.decisionRange, s.decisionGear = reason, g_time or 0, range, gear
    s.decisionLoad, s.decisionSource, s.decisionRpm = s.load, s.source, s.rpm
end
local function sample(motor, dt)
    local s, now = state(motor), g_time or 0
    local load, sourceName, ads, native = getLoad(motor)
    local speed = C330Runtime.number(C330Runtime.first(motor.vehicle, "getLastSpeed")) or 0
    local elapsed = s.sampleAt and math.max(1, now - s.sampleAt) or math.max(dt or 16, 1)
    if s.sampleAt ~= now then
        local alpha = 1 - math.exp(-elapsed / 400)
        s.filteredLoad = load and ((s.filteredLoad or load) + alpha * (load - (s.filteredLoad or load))) or nil
        s.speedTrend = s.speed and ((s.speedTrend or 0) + alpha * ((speed - s.speed) * 1000 / elapsed - (s.speedTrend or 0))) or 0
        s.sampleAt, s.speed = now, speed
    end
    s.load, s.source, s.adsRaw, s.nativeRaw = load, sourceName, ads, native
    s.rpm, s.slip = getRpm(motor), C330Runtime.rearSlip(motor.vehicle)
    return s
end
local function canUpshift(motor, range, gear, targetRange, targetGear, now)
    local s = state(motor)
    local ratio = nominal(motor, range, gear) / nominal(motor, targetRange, targetGear)
    local predicted = (s.rpm or 0) * ratio
    local load = s.load and math.max(s.load, s.filteredLoad or s.load)
    local currentTorque = C330Runtime.number(C330Runtime.first(motor, "getTorqueCurveValue", s.rpm))
    local nextTorque = C330Runtime.number(C330Runtime.first(motor, "getTorqueCurveValue", predicted))
    local demand = load and load / ratio
    if demand and currentTorque and nextTorque and nextTorque > 0 then demand = demand * currentTorque / nextTorque end
    s.predictedRpm, s.predictedLoad, s.candidateVirtual = predicted, demand, getVirtualGear(targetRange, targetGear)
    s.candidateAt = now
    local reason
    if (motor.gear or 0) <= 0 or (motor.gearChangeTimer or -1) >= 0
        or (motor.groupChangeTimer or 0) > 0 then reason = "SHIFT IN PROGRESS"
    elseif motor.c330FixUpshiftHoldUntil and now < motor.c330FixUpshiftHoldUntil then reason = "UPSHIFT HOLD"
    elseif (s.rpm or 0) < WORK_RANGE_UP_RPM then reason = "UPSHIFT RPM"
    elseif predicted < 1000 then reason = "POSTSHIFT RPM"
    elseif demand == nil or demand > 0.90 then reason = "TORQUE RESERVE"
    elseif (s.slip or 0) > 0.25 then reason = "WHEEL SLIP"
    elseif (s.speed or 0) < nominal(motor, range, gear) * (s.rpm or 0) / MAX_RPM * 0.75 then reason = "GROUND SPEED"
    elseif (s.speedTrend or 0) < -0.30 then reason = "SPEED FALLING"
    end
    local failure = s.failure
    if reason == nil and failure and failure.to == s.candidateVirtual then
        -- Keep the work-load improvement rule. On an unloaded road run, a
        -- failed low-RPM attempt must not permanently blacklist the top gear.
        -- Retry only with current reserve, usable RPM and sustained readiness;
        -- elapsed time alone is never enough.
        local loadImproved = load ~= nil and load <= failure.load - 0.12
        local roadRecovered = motor.c330WorkSpeedLimit == nil
            and predicted >= 1300 and demand ~= nil and demand <= 0.75
        if now < failure.at + 5000 or not (loadImproved or roadRecovered)
            or (s.speed or 0) < failure.speed - 0.2 then reason = "FAILED GEAR MEMORY" end
    end
    if reason ~= nil then
        s.readyAt, s.readyCandidate, s.gate = nil, nil, reason
        return false
    end
    if s.readyCandidate ~= s.candidateVirtual then s.readyAt, s.readyCandidate = now, s.candidateVirtual end
    local readyDuration = failure and failure.to == s.candidateVirtual and 2000 or 800
    s.gate = now - (s.readyAt or now) >= readyDuration and "READY" or "STABILIZING"
    return s.gate == "READY"
end
local function rememberPlan(motor, fromRange, fromGear, toRange, toGear)
    local s = state(motor)
    s.plan = {from=getVirtualGear(fromRange, fromGear), to=getVirtualGear(toRange, toGear),
        at=g_time or 0, load=math.max(s.load or 0, s.filteredLoad or 0), speed=s.speed or 0}
end
local function rememberFailure(motor, currentVirtual, now)
    local s = state(motor)
    local attempt = s.attempt
    if attempt and attempt.to == currentVirtual and now - (attempt.settledAt or now) < 8000
        and math.abs(motor.lastAcceleratorPedal or 0) >= 0.85 and (s.load or 0) >= 0.50 then
        s.failure = {to=attempt.to, load=attempt.load, speed=attempt.speed, at=now}
        s.attempt = nil
    end
end
local function observeSettled(motor, now)
    local s = state(motor)
    if (motor.gear or 0) <= 0 or (motor.gearChangeTimer or -1) >= 0
        or (motor.groupChangeTimer or 0) > 0 then return end
    local virtual = getVirtualGear(motor.activeGearGroupIndex, motor.gear)
    if virtual ~= s.settled then
        if s.settled and virtual > s.settled then
            local plan = s.plan
            s.attempt = plan and plan.from == s.settled and plan.to == virtual and plan or nil
            if s.attempt then s.attempt.settledAt = now end
        elseif s.settled and virtual < s.settled then
            local attempt = s.attempt
            if attempt and attempt.to == s.settled and now - (attempt.settledAt or now) < 8000
                and math.abs(motor.lastAcceleratorPedal or 0) >= 0.85 and (s.load or 0) >= 0.50 then
                s.failure = {to=attempt.to, load=attempt.load, speed=attempt.speed, at=now}
            end
            s.attempt = nil
        end
        s.settled, s.settledAt, s.readyAt, s.readyCandidate = virtual, now, nil, nil
        if s.reduction then
            if virtual == s.reduction.to then s.reductionCompletedAt = now end
            s.reduction = nil
        end
    end
end
local function reduce(motor, range, curGear, targetRange, targetGear, reason)
    local s, now = state(motor), g_time or 0
    local predicted = getRpm(motor) * nominal(motor, range, curGear) / nominal(motor, targetRange, targetGear)
    -- A newly lowered tool must not force overspeed on a road-speed downshift.
    if predicted > MAX_RPM + 100 then
        decision(motor, range, curGear, "DOWNSHIFT RPM GUARD")
        return curGear
    end
    rememberFailure(motor, getVirtualGear(range, curGear), now)
    if s.reduction == nil then
        s.reduction = {at=now, to=getVirtualGear(targetRange, targetGear)}
        s.reductionRequestedAt, s.reductionCompletedAt = now, nil
    end
    s.vetoBefore = motor.allowGearChangeTimer
    -- The GIANTS updateGear direction veto runs AFTER prediction. Release only
    -- that veto for this confirmed reduction. Mechanical/clutch timers stay intact.
    motor.allowGearChangeTimer = 0
    motor.autoGearChangeTimer = 0
    s.vetoReleasedAt = now
    setUpshiftHold(motor, now + WORK_RELEASE_HOLD_MS)
    decision(motor, targetRange, targetGear, reason)
    if targetRange ~= range then return requestRange(motor, targetRange, targetGear, reason, motor.c330WorkSpeedLimit, motor.c330WorkTargetVirtual) end
    return targetGear
end
function C330TransmissionWorkFix:install()
    if self.installed or VehicleMotor == nil then return end
    local originalPrediction, originalUpdateGear = VehicleMotor.findGearChangeTargetGearPrediction, VehicleMotor.updateGear
    if type(originalPrediction) ~= "function" or type(originalUpdateGear) ~= "function" then return end
    self.installed = true
    VehicleMotor.updateGear = function(motor, acceleratorPedal, brakePedal, dt)
        if not isAutomaticForward(motor) or motor.vehicle.isServer == false then
            if motor.c330P2 then motor.c330P2, motor.c330P2RangeUpAllowed = nil, nil end
            return originalUpdateGear(motor, acceleratorPedal, brakePedal, dt)
        end
        sample(motor, dt)
        observeSettled(motor, g_time or 0)
        -- Preserve both adjusted pedals; GIANTS may change braking during reversal.
        local result, adjustedBrake = originalUpdateGear(motor, acceleratorPedal, brakePedal, dt)
        observeSettled(motor, g_time or 0)
        return result, adjustedBrake
    end
    VehicleMotor.findGearChangeTargetGearPrediction = function(motor, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
        if not isAutomaticForward(motor) or motor.vehicle.isServer == false or not curGear or curGear <= 0 or not gears or #gears < 1 then
            return originalPrediction(motor, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
        end
        local now, range = g_time or 0, motor.activeGearGroupIndex or LOW_RANGE
        local s = sample(motor, dt)
        local workLimit = getActiveWorkSpeedLimit(motor.vehicle)
        local _, _, workVirtual = getWorkTarget(motor, workLimit)
        motor.c330WorkSpeedLimit, motor.c330WorkTargetVirtual, motor.c330WorkLoadSource = workLimit, workVirtual, s.source
        if s.workLimit ~= workLimit then
            if s.workLimit ~= nil and workLimit == nil then setUpshiftHold(motor, now + WORK_RELEASE_HOLD_MS) end
            s.failure, s.attempt, s.readyAt, s.readyCandidate = nil, nil, nil, nil
            s.workLimit = workLimit
        end
        -- Gate the base controller BEFORE it can mutate the range. This also
        -- prevents a low work-speed ceiling being bypassed by the base controller.
        motor.c330P2RangeUpAllowed = true
        if range == LOW_RANGE and curGear == 3 then
            if workVirtual and workVirtual < 4 then motor.c330P2RangeUpAllowed = false
            else motor.c330P2RangeUpAllowed = canUpshift(motor, range, curGear, HIGH_RANGE, 1, now) end
        end
        local result = originalPrediction(motor, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
        local afterRange = motor.activeGearGroupIndex or LOW_RANGE
        if afterRange ~= range then
            if afterRange > range then rememberPlan(motor, range, curGear, afterRange, result)
            else rememberFailure(motor, getVirtualGear(range, curGear), now) end
            decision(motor, afterRange, result, motor.c330FixRequestedRangeReason or "BASE RANGE CHANGE")
            return result
        end
        local accel = math.abs(tonumber(acceleratorPedal) or 0)
        local currentVirtual = getVirtualGear(range, curGear)
        -- Rescue takes precedence over the upshift ceiling, even if vanilla
        -- simultaneously predicts another upshift.
        if curGear > 1 and accel >= LUG_DOWNSHIFT_ACCEL and s.load and s.load >= LUG_DOWNSHIFT_LOAD and s.rpm <= LUG_DOWNSHIFT_RPM then
            return reduce(motor, range, curGear, range, curGear - 1, "LUG DOWNSHIFT")
        end
        if workVirtual and currentVirtual > workVirtual then
            local tr, tg = virtualToRangeGear(currentVirtual - 1)
            return reduce(motor, range, curGear, tr, tg, "WORK GEAR DOWN")
        end
        if workVirtual and currentVirtual == workVirtual and result and result > curGear then
            decision(motor, range, curGear, "WORK GEAR HOLD")
            return curGear
        end
        if workVirtual and currentVirtual == 3 and workVirtual >= 4
            and motor.c330P2RangeUpAllowed and now - (s.settledAt or now) >= WORK_RANGE_UP_DWELL_MS then
            rememberPlan(motor, range, curGear, HIGH_RANGE, 1)
            decision(motor, HIGH_RANGE, 1, "WORK RANGE UP")
            return requestRange(motor, HIGH_RANGE, 1, "WORK RANGE UP", workLimit, workVirtual)
        end
        if result and result > curGear then
            if motor.c330FixUpshiftHoldUntil and now < motor.c330FixUpshiftHoldUntil then
                decision(motor, range, curGear, "BLOCK UPSHIFT HOLD")
                return curGear
            end
            if not canUpshift(motor, range, curGear, range, result, now) then
                decision(motor, range, curGear, s.gate)
                return curGear
            end
            rememberPlan(motor, range, curGear, range, result)
        end
        decision(motor, range, result or curGear, result == curGear and "KEEP GEAR" or "BASE PREDICTION")
        return result
    end
end
function C330TransmissionWorkFix:update(dt)
    if not self.installed then self:install() end
end
if not C330TransmissionWorkFix.listenerAdded then
    C330TransmissionWorkFix.listenerAdded = true
    addModEventListener(C330TransmissionWorkFix)
end
