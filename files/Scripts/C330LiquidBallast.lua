-- C330LiquidBallast.lua
-- Ursus C-330/C-330M rear tyre liquid ballast.
-- Stable layer: +132 kg per rear wheel and calibrated filled-tyre spring/damper.
-- Dry tyre baseline stays spring=12 / damper=22.

C330LiquidBallast = C330LiquidBallast or {}

if not C330LiquidBallast.installed then
    C330LiquidBallast.installed = true

    local CFG = {
        targetFileSuffix = "c330m.xml",
        configurationName = "design24",
        enabledIndex = 2,
        rearWheelIndices = { [3] = true, [4] = true },
        waterMassPerWheel = 0.132, -- tonnes = 132 kg
        springRatio = 14 / 12,
        damperRatio = 30 / 22
    }

    local modDirectory = g_currentModDirectory
    local originalLoadFromXML = Wheel.loadFromXML

    local function endsWith(value, suffix)
        return value ~= nil and suffix ~= nil and string.sub(value, -string.len(suffix)) == suffix
    end

    local function isTargetVehicle(vehicle)
        if vehicle == nil or vehicle.configFileName == nil then
            return false
        end
        if modDirectory ~= nil and string.sub(vehicle.configFileName, 1, string.len(modDirectory)) ~= modDirectory then
            return false
        end
        return endsWith(vehicle.configFileName, CFG.targetFileSuffix)
    end

    local function getConfigIndex(vehicle)
        local configurations = vehicle ~= nil and vehicle.configurations or nil
        return configurations ~= nil and tonumber(configurations[CFG.configurationName]) or 1
    end

    local function scaleNumber(tbl, key, factor)
        if tbl ~= nil and type(tbl[key]) == "number" then
            tbl[key] = tbl[key] * factor
        end
    end

    Wheel.loadFromXML = function(wheel, ...)
        local ok = originalLoadFromXML(wheel, ...)
        if not ok then
            return ok
        end

        local vehicle = wheel.vehicle
        if not isTargetVehicle(vehicle)
            or getConfigIndex(vehicle) ~= CFG.enabledIndex
            or not CFG.rearWheelIndices[wheel.wheelIndex] then
            return ok
        end

        wheel.additionalMass = (tonumber(wheel.additionalMass) or 0) + CFG.waterMassPerWheel

        local physics = wheel.physics
        if physics ~= nil then
            scaleNumber(physics, "spring", CFG.springRatio)
            scaleNumber(physics, "damperCompressionLowSpeed", CFG.damperRatio)
            scaleNumber(physics, "damperCompressionHighSpeed", CFG.damperRatio)
            scaleNumber(physics, "damperRelaxationLowSpeed", CFG.damperRatio)
            scaleNumber(physics, "damperRelaxationHighSpeed", CFG.damperRatio)
        end

        return ok
    end
end

-- Permanent gameplay layer. It registers an event listener here, but waits until
-- C330TransmissionFix has loaded before wrapping the final automatic controller.
local workFixPath = Utils.getFilename("Scripts/C330TransmissionWorkFix.lua", g_currentModDirectory)
if fileExists ~= nil and fileExists(workFixPath) then
    source(workFixPath)
end
