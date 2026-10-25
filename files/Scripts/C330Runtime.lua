-- Shared, read-only load/traction access for this mod. No optional mod is required.
C330Runtime = {}
local directory = g_currentModDirectory
function C330Runtime.isTarget(vehicle)
    local path = vehicle and vehicle.configFileName
    return type(path) == "string" and type(directory) == "string"
        and path:sub(1, #directory) == directory and path:sub(-9):lower() == "c330m.xml"
end
function C330Runtime.number(value)
    value = tonumber(value)
    if value ~= nil and value == value and math.abs(value) < math.huge then return value end
    return nil
end
function C330Runtime.first(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(object[method], object, ...)
    if ok then return value end
    return nil
end
function C330Runtime.load(motor)
    local vehicle = motor and motor.vehicle
    local ads = vehicle and vehicle.spec_AdvancedDamageSystem
    local raw = C330Runtime.number(ads and ads.dynamicMotorLoad)
    local native = C330Runtime.number(C330Runtime.first(motor, "getSmoothLoadPercentage"))
    -- ADS overloads above 100% are valid. Negative/NaN/infinite samples are not.
    if raw ~= nil and raw >= 0 then return math.min(raw, 2), "ADS", raw, native end
    if native ~= nil then return math.max(0, math.min(native, 2)), "GIANTS", raw, native end
    return nil, "n/a", raw, native
end
function C330Runtime.rearSlip(vehicle)
    local wheels = vehicle and vehicle.spec_wheels and vehicle.spec_wheels.wheels
    if wheels == nil then return nil end
    local result
    for _, index in ipairs({3, 4}) do
        local physics = wheels[index] and wheels[index].physics
        local value = physics and physics.netInfo and C330Runtime.number(physics.netInfo.slip)
        if value ~= nil then result = math.max(result or 0, math.abs(value)) end
    end
    return result
end
