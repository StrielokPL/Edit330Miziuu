-- Ursus C-330/C-330M FS25 automatic range controller
-- Stable: validated 2 s upshift failsafe, mass-aware 6F/2R control and ADS-safe operation.
--
-- The C-330 range box is NOT a powershift splitter. In automatic mode the
-- intended virtual order is:
--   I/1 -> I/2 -> I/3 -> II/1 -> II/2 -> II/3
-- and the reverse order while downshifting.
--
-- Manual modes are left to GIANTS unchanged. Automatic forward and reverse use
-- explicit C-330-family range logic. C-330M inherits the validated controller.

C330TransmissionFix = C330TransmissionFix or {}

if not C330TransmissionFix.installed then
    C330TransmissionFix.installed = true

    local modDirectory = g_currentModDirectory

    local originalGetBestStartGear = VehicleMotor.getBestStartGear
    local originalFindGearChangeTargetGearPrediction = VehicleMotor.findGearChangeTargetGearPrediction
    local originalGetUseAutomaticGroupShifting = VehicleMotor.getUseAutomaticGroupShifting

    local LOW_RANGE = 1
    local HIGH_RANGE = 2

    -- Thresholds below were isolated and validated through the 0.0.1.x runtime tests.
    local RANGE_DOWNSHIFT_RPM = 1500
    local RANGE_DOWNSHIFT_LOAD = 0.75
    local RANGE_DOWNSHIFT_ACCEL = 0.85
    -- Full throttle alone must not force II/1 -> I/3 when the engine is lightly loaded.
    local RANGE_DOWNSHIFT_ACCEL_MIN_LOAD = 0.55
    -- Never command the mechanical II/1 -> I/3 range change above 6.0 km/h.
    local FORWARD_RANGE_DOWNSHIFT_MAX_SPEED = 6.0
    -- Force range I once forward speed is essentially walking pace.
    local FORWARD_LOW_SPEED_RANGE_RESET = 0.5

    -- Factory base mass is 1675 kg. A complete tractor+implement/trailer set below
    -- 1675 + 1500 = 3175 kg may start directly in I/3.
    local FACTORY_BASE_MASS_T = 1.675
    local LIGHT_START_EXTRA_MASS_T = 1.500
    local LIGHT_START_MAX_TOTAL_MASS_T = FACTORY_BASE_MASS_T + LIGHT_START_EXTRA_MASS_T

    local RANGE_UPSHIFT_RPM = 2050
    local RANGE_UPSHIFT_MAX_LOAD = 0.55
    local RANGE_UPSHIFT_STABLE_MS = 800

    -- No automatic upshift may be issued for the first 2 seconds after a
    -- mechanical gear/range has settled. Downshifts remain free.
    local UPSHIFT_MIN_DWELL_MS = 2000

    local NORMAL_UPSHIFT_GUARD_LOAD = 0.80
    local NORMAL_UPSHIFT_GUARD_RPM = 1750

    -- II/2 -> II/3 is the largest within-range step.
    local TOP_GEAR_POSTSHIFT_RPM_RATIO = 14.324 / 22.878
    local TOP_GEAR_POSTSHIFT_MIN_RPM = 1200
    local TOP_GEAR_PREDICTION_GUARD_MIN_LOAD = 0.55
    local TOP_GEAR_HIGH_LOAD = 0.70
    local TOP_GEAR_HIGH_LOAD_MIN_RPM = 2100
    local TOP_GEAR_HEAVY_SET_STABLE_MS = 2000

    local RANGE_CHANGE_COOLDOWN_MS = 800
    local LOAD_RECOVERY_HOLD_MS = 2500

    local function endsWith(value, suffix)
        return value ~= nil
            and suffix ~= nil
            and string.sub(value, -string.len(suffix)) == suffix
    end

    local function isTargetVehicle(vehicle)
        if vehicle == nil or vehicle.configFileName == nil then
            return false
        end

        if modDirectory ~= nil
            and string.sub(vehicle.configFileName, 1, string.len(modDirectory)) ~= modDirectory then
            return false
        end

        return endsWith(vehicle.configFileName, "c330m.xml")
    end

    local function getSelectedMotorConfigurationName(vehicle)
        if vehicle == nil or vehicle.configurations == nil or vehicle.configurations.motor == nil then
            return nil
        end

        local xmlFile = vehicle.xmlFile
        if xmlFile == nil then
            return nil
        end

        local key = ConfigurationUtil.getXMLConfigurationKey(
            xmlFile,
            vehicle.configurations.motor,
            "vehicle.motorized.motorConfigurations.motorConfiguration",
            "vehicle.motorized",
            "motor"
        )
        if key == nil then
            return nil
        end

        return xmlFile:getValue(key .. "#name")
    end

    local function isC330Motor(motor)
        if motor == nil or not isTargetVehicle(motor.vehicle) then
            return false
        end

        if motor.c330FixTargetCache == nil then
            local motorName = getSelectedMotorConfigurationName(motor.vehicle)
            motor.c330FixTargetCache = motorName == "C-330" or motorName == "C-330M"
        end

        return motor.c330FixTargetCache == true
    end

    local function hasFactoryRanges(motor)
        return motor ~= nil
            and motor.gearGroups ~= nil
            and #motor.gearGroups == 2
            and motor.gearGroups[LOW_RANGE] ~= nil
            and motor.gearGroups[HIGH_RANGE] ~= nil
    end

    local function isAutomaticC330(motor)
        return isC330Motor(motor)
            and hasFactoryRanges(motor)
            and motor.gearShiftMode == VehicleMotor.SHIFT_MODE_AUTOMATIC
    end

    local function isAutomaticForward(motor)
        return isAutomaticC330(motor)
            and (motor.currentDirection or 1) >= 0
    end

    local function isAutomaticReverse(motor)
        return isAutomaticC330(motor)
            and (motor.currentDirection or 1) < 0
    end

    local function getRpm(motor)
        if motor == nil then
            return 0
        end

        if motor.getLastModulatedMotorRpm ~= nil then
            local value = tonumber(motor:getLastModulatedMotorRpm())
            if value ~= nil then
                return value
            end
        end

        return tonumber(motor.lastMotorRpm) or 0
    end

    local function getSpeed(motor)
        local vehicle = motor ~= nil and motor.vehicle or nil
        if vehicle ~= nil and vehicle.getLastSpeed ~= nil then
            return tonumber(vehicle:getLastSpeed()) or 0
        end
        return 0
    end

    local function getTotalMassTons(motor)
        local vehicle = motor ~= nil and motor.vehicle or nil
        if vehicle ~= nil and vehicle.getTotalMass ~= nil then
            local value = tonumber(vehicle:getTotalMass())
            if value ~= nil and value > 0 then
                return value
            end
        end
        return nil
    end

    local function getForwardStartGear(motor, gears, fallbackGear)
        local maxGear = math.min(#gears, 3)
        local gear = math.max(1, math.min(fallbackGear or 1, maxGear))
        local totalMass = getTotalMassTons(motor)

        if maxGear >= 3
            and totalMass ~= nil
            and totalMass < LIGHT_START_MAX_TOTAL_MASS_T then
            return 3, totalMass, "LIGHT_I3"
        end

        return gear, totalMass, "NATIVE_LOW_RANGE"
    end

    local function getReverseStartRange(motor)
        local totalMass = getTotalMassTons(motor)

        if totalMass ~= nil and totalMass < LIGHT_START_MAX_TOTAL_MASS_T then
            return HIGH_RANGE, totalMass, "LIGHT_RII"
        end

        return LOW_RANGE, totalMass, "NATIVE_RI"
    end

    local function getLoad(motor)
        return C330Runtime.load(motor)
    end

    local function getUpshiftDwellState(motor, range, gear, now)
        local direction = (motor.currentDirection or 1) < 0 and -1 or 1
        local key = string.format("%d:%d:%d", direction, range or 0, gear or 0)

        if motor.c330FixSettledGearKey ~= key then
            motor.c330FixSettledGearKey = key
            motor.c330FixSettledGearSince = now
            return false, 0
        end

        local age = now - (motor.c330FixSettledGearSince or now)
        return age >= UPSHIFT_MIN_DWELL_MS, age
    end

    local function setAutomaticRange(motor, targetRange, targetGear, reason, rpm, load, loadSource, recoveryHold)
        local currentRange = motor.activeGearGroupIndex or LOW_RANGE
        local currentGear = motor.targetGear or motor.gear or 0
        local now = g_time or 0

        -- Shared controller state records the most recent range request.
        motor.c330FixRequestedRange = targetRange
        motor.c330FixRequestedGear = targetGear
        motor.c330FixRequestedRangeAt = now
        motor.c330FixRequestedRangeReason = reason

        if targetRange ~= currentRange then
            motor:setGearGroup(targetRange)
        end

        motor.c330FixRangeCooldownUntil = now + RANGE_CHANGE_COOLDOWN_MS
        motor.c330FixRangeRecoverySince = nil
        if recoveryHold then
            motor.c330FixUpshiftHoldUntil = now + LOAD_RECOVERY_HOLD_MS
        end
        motor.autoGearChangeTimer = math.max(motor.autoGearChangeTime or 0, RANGE_CHANGE_COOLDOWN_MS)

        return targetGear
    end

    -- GIANTS automatic group selection treats the two mechanical C-330 ranges as
    -- unrelated optimization choices. Disable it for the complete automatic 6F/2R
    -- gearbox. Manual modes still keep base-game group handling.
    function VehicleMotor:getUseAutomaticGroupShifting()
        if isAutomaticC330(self) then
            return false
        end

        return originalGetUseAutomaticGroupShifting(self)
    end

    function VehicleMotor:getBestStartGear(gears)
        local gear, group = originalGetBestStartGear(self, gears)

        if isAutomaticC330(self) then
            local startRange = LOW_RANGE
            gear = math.max(1, math.min(gear or 1, math.min(#gears, 3)))

            if isAutomaticForward(self) and #gears >= 3 then
                local totalMass, startMode
                gear, totalMass, startMode = getForwardStartGear(self, gears, gear)

            elseif isAutomaticReverse(self) then
                local totalMass, startMode
                gear = 1
                startRange, totalMass, startMode = getReverseStartRange(self)

            end

            group = startRange

            if self.activeGearGroupIndex ~= startRange then
                local now = g_time or 0
                self.c330FixRequestedRange = startRange
                self.c330FixRequestedGear = gear
                self.c330FixRequestedRangeAt = now
                if isAutomaticReverse(self) then
                    self.c330FixRequestedRangeReason = startRange == HIGH_RANGE
                        and "START REVERSE R-II" or "START REVERSE R-I"
                else
                    self.c330FixRequestedRangeReason = "START RANGE RESET"
                end
                self:setGearGroup(startRange)
            end

            self.c330FixRangeRecoverySince = nil
        end

        return gear, group
    end

    function VehicleMotor:findGearChangeTargetGearPrediction(curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt)
        local vanillaTarget = originalFindGearChangeTargetGearPrediction(
            self, curGear, gears, gearSign, gearChangeTimer, acceleratorPedal, dt
        )

        if not isAutomaticC330(self)
            or curGear == nil
            or curGear <= 0
            or gears == nil
            or #gears < 1 then
            return vanillaTarget
        end

        local now = g_time or 0
        if self.c330FixRangeCooldownUntil ~= nil and now < self.c330FixRangeCooldownUntil then
            return curGear
        end

        local range = self.activeGearGroupIndex or LOW_RANGE
        local rpm = getRpm(self)
        local load, loadSource = getLoad(self)
        local speed = getSpeed(self)
        local totalMass = getTotalMassTons(self)
        local accel = math.abs(tonumber(acceleratorPedal) or 0)
        local maxGear = math.min(#gears, 3)
        local upshiftDwellReady = getUpshiftDwellState(self, range, curGear, now)

        -- A near-stop can occasionally continue in range II without getBestStartGear
        -- resetting the box first. Force range I at walking pace.
        if isAutomaticForward(self)
            and range == HIGH_RANGE
            and speed <= FORWARD_LOW_SPEED_RANGE_RESET then
            local resetGear, totalMass, startMode = getForwardStartGear(self, gears, 1)

            return setAutomaticRange(
                self, LOW_RANGE, resetGear, "LOW SPEED RANGE RESET",
                rpm, load, loadSource, false
            )
        end

        -- Reverse uses one reverse gear through the same I/II range box.
        if isAutomaticReverse(self) then
            if range == HIGH_RANGE
                and curGear == 1
                and speed > 0.3
                and rpm <= RANGE_DOWNSHIFT_RPM
                and (
                    (load ~= nil and load >= RANGE_DOWNSHIFT_LOAD)
                    or (accel >= RANGE_DOWNSHIFT_ACCEL and load ~= nil and load >= RANGE_DOWNSHIFT_ACCEL_MIN_LOAD)
                ) then
                return setAutomaticRange(
                    self, LOW_RANGE, 1, "REVERSE RANGE DOWN",
                    rpm, load, loadSource, true
                )
            end

            local reverseRecoveryBaseReady = range == LOW_RANGE
                and curGear == 1
                and rpm >= RANGE_UPSHIFT_RPM
                and (load == nil or load <= RANGE_UPSHIFT_MAX_LOAD)
                and (self.c330FixUpshiftHoldUntil == nil or now >= self.c330FixUpshiftHoldUntil)

            if reverseRecoveryBaseReady and not upshiftDwellReady then

            end

            local reverseRecoveryReady = reverseRecoveryBaseReady and upshiftDwellReady

            if reverseRecoveryReady then
                if self.c330FixRangeRecoverySince == nil then
                    self.c330FixRangeRecoverySince = now
                elseif now - self.c330FixRangeRecoverySince >= RANGE_UPSHIFT_STABLE_MS then
                    return setAutomaticRange(
                        self, HIGH_RANGE, 1, "REVERSE RANGE UP",
                        rpm, load, loadSource, false
                    )
                end
            else
                self.c330FixRangeRecoverySince = nil
            end

            return 1
        end

        -- II/1 may fall back to I/3 before the tractor nearly stops.
        if range == HIGH_RANGE
            and curGear == 1
            and speed > 0.5
            and speed <= FORWARD_RANGE_DOWNSHIFT_MAX_SPEED
            and rpm <= RANGE_DOWNSHIFT_RPM
            and (
                (load ~= nil and load >= RANGE_DOWNSHIFT_LOAD)
                or (accel >= RANGE_DOWNSHIFT_ACCEL and load ~= nil and load >= RANGE_DOWNSHIFT_ACCEL_MIN_LOAD)
            ) then
            return setAutomaticRange(
                self, LOW_RANGE, maxGear, "RANGE DOWN",
                rpm, load, loadSource, true
            )
        end

        -- Crossing the upper range boundary is I/3 -> II/1. Require sustained
        -- recovery before leaving range I.
        local rangeRecoveryBaseReady = self.c330P2RangeUpAllowed ~= false
            and range == LOW_RANGE
            and curGear == maxGear
            and rpm >= RANGE_UPSHIFT_RPM
            and (load == nil or load <= RANGE_UPSHIFT_MAX_LOAD)
            and (self.c330FixUpshiftHoldUntil == nil or now >= self.c330FixUpshiftHoldUntil)

        if rangeRecoveryBaseReady and not upshiftDwellReady then

        end

        local rangeRecoveryReady = rangeRecoveryBaseReady and upshiftDwellReady

        if rangeRecoveryReady then
            if self.c330FixRangeRecoverySince == nil then
                self.c330FixRangeRecoverySince = now
            elseif now - self.c330FixRangeRecoverySince >= RANGE_UPSHIFT_STABLE_MS then
                return setAutomaticRange(
                    self, HIGH_RANGE, 1, "RANGE UP",
                    rpm, load, loadSource, false
                )
            end
        else
            self.c330FixRangeRecoverySince = nil
        end

        -- Keep vanilla's useful within-range prediction, but never let it skip
        -- multiple mechanical gears in a single decision.
        local targetGear = vanillaTarget or curGear
        if targetGear > curGear + 1 then
            targetGear = curGear + 1
        elseif targetGear < curGear - 1 then
            targetGear = curGear - 1
        end

        targetGear = math.max(1, math.min(targetGear, maxGear))

        -- Special protection for II/2 -> II/3 with the calibrated 100 Nm engine.
        if range == HIGH_RANGE
            and curGear == 2
            and targetGear == 3
            and load ~= nil then
            local heavySet = totalMass ~= nil and totalMass >= LIGHT_START_MAX_TOTAL_MASS_T

            if heavySet then
                if load >= TOP_GEAR_HIGH_LOAD then
                    self.c330FixTopGearLowLoadSince = nil

                    self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
                    return curGear
                end

                if self.c330FixTopGearLowLoadSince == nil then
                    self.c330FixTopGearLowLoadSince = now

                    self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
                    return curGear
                elseif now - self.c330FixTopGearLowLoadSince < TOP_GEAR_HEAVY_SET_STABLE_MS then

                    self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
                    return curGear
                end
            else
                self.c330FixTopGearLowLoadSince = nil

                if load >= TOP_GEAR_HIGH_LOAD and rpm < TOP_GEAR_HIGH_LOAD_MIN_RPM then

                    self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
                    return curGear
                end
            end

            if load >= TOP_GEAR_PREDICTION_GUARD_MIN_LOAD then
                local predictedRpm = rpm * TOP_GEAR_POSTSHIFT_RPM_RATIO
                if predictedRpm < TOP_GEAR_POSTSHIFT_MIN_RPM then

                    self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
                    return curGear
                end
            end
        else
            self.c330FixTopGearLowLoadSince = nil
        end

        -- Generic 2-second failsafe for every within-range automatic upshift.
        if targetGear > curGear and not upshiftDwellReady then

            self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
            return curGear
        end

        -- Do not allow a normal upshift when the engine is already heavily loaded
        -- below the useful upper-RPM band.
        if targetGear > curGear
            and load ~= nil
            and load >= NORMAL_UPSHIFT_GUARD_LOAD
            and rpm < NORMAL_UPSHIFT_GUARD_RPM then

            self.autoGearChangeTimer = math.max(self.autoGearChangeTime or 0, 250)
            return curGear
        end

        return targetGear
    end
end
