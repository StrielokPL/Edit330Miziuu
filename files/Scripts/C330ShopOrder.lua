-- C330ShopOrder.lua
-- Local shop configuration ordering for Ursus C-330/C-330M only.
-- Does not change global GIANTS configuration priorities; it only returns a
-- reordered copy while this mod's c330m.xml is open in ShopConfigScreen.

C330ShopOrder = C330ShopOrder or {}

if not C330ShopOrder.installed and g_vehicleConfigurationManager ~= nil then
    C330ShopOrder.installed = true

    local TARGET_SUFFIX = "c330m.xml"
    local ORDER = {
        -- Functional base / ballast
        "motor",
        "wheel",
        "design24",      -- water in rear tyres
        "design3",       -- front ballast
        "vehicleType",   -- cabin configuration set
        "frontloader",   -- loader console
        "designColor6",  -- loader-console material
        "designColor12", -- loader-console/cover colour

        -- Remaining equipment, roughly front -> rear
        "design2",       -- front grille
        "designColor9",
        "designColor11",
        "design23",      -- front axle plate
        "design13",      -- front axle appearance
        "design12",      -- air filter
        "design8",       -- exhaust/muffler
        "design10",      -- generator / alternator
        "design9",       -- compressor
        "design6",       -- model stickers
        "designColor2",  -- engine colour
        "designColor",   -- sheet/body colour
        "rimColor",      -- wheel/rim colour
        "design4",       -- fenders
        "designColor7",  -- front-fender colour
        "design5",       -- mudflaps
        "design11",      -- steering wheel
        "design15",      -- steering-wheel accessory
        "designColor3",  -- cabin material
        "designColor4",  -- door material
        "designColor5",  -- roof material
        "design7",       -- warning beacons
        "design20",      -- additional lighting
        "design21",      -- searchlight
        "design22",      -- fender seat
        "designColor13", -- fender-seat colour
        "design16",      -- rear reflectors
        "design19",      -- rear lamp type
        "design14",      -- warning triangle
        "design17",      -- box
        "design18",      -- cables
        "designColor10"  -- cable-cover colour
    }

    local rank = {}
    for index, name in ipairs(ORDER) do
        rank[name] = index
    end

    local function endsWith(value, suffix)
        if type(value) ~= "string" or type(suffix) ~= "string" then
            return false
        end
        value = string.lower(value)
        suffix = string.lower(suffix)
        return string.sub(value, -string.len(suffix)) == suffix
    end

    local function hasTargetFilename(value)
        if type(value) ~= "table" then
            return false
        end
        local filename = rawget(value, "xmlFilename")
            or rawget(value, "rawXMLFilename")
            or rawget(value, "configFileName")
        return endsWith(filename, TARGET_SUFFIX)
    end

    local function containsTargetStoreItem(root)
        if type(root) ~= "table" then
            return false
        end

        local seen = {}
        local visited = 0
        local maxVisited = 160

        local function scan(value, depth)
            if type(value) ~= "table" or seen[value] or visited >= maxVisited then
                return false
            end
            seen[value] = true
            visited = visited + 1

            if hasTargetFilename(value) then
                return true
            end
            if depth <= 0 then
                return false
            end

            -- Known/likely ShopConfigScreen data containers first.
            local preferredKeys = {
                "storeItem", "currentStoreItem", "item", "buyData",
                "vehicleLoadingData", "loadingData", "saleItem", "data"
            }
            for _, key in ipairs(preferredKeys) do
                local child = rawget(value, key)
                if scan(child, depth - 1) then
                    return true
                end
            end

            -- Conservative fallback for changed GIANTS field names.
            for key, child in pairs(value) do
                if type(key) == "string" and type(child) == "table" then
                    local lower = string.lower(key)
                    if string.find(lower, "store", 1, true)
                        or string.find(lower, "item", 1, true)
                        or string.find(lower, "vehicle", 1, true)
                        or string.find(lower, "buy", 1, true) then
                        if scan(child, depth - 1) then
                            return true
                        end
                    end
                end
            end

            return false
        end

        return scan(root, 3)
    end

    local function isC330ShopOpen()
        if g_gui == nil or g_gui.currentGuiName ~= "ShopConfigScreen" then
            return false
        end
        local currentGui = g_gui.currentGui
        local target = currentGui ~= nil and currentGui.target or nil
        return containsTargetStoreItem(target)
    end

    local originalGetSorted = g_vehicleConfigurationManager.getSortedConfigurationTypes
    if originalGetSorted ~= nil then
        g_vehicleConfigurationManager.getSortedConfigurationTypes = function(self, ...)
            local original = originalGetSorted(self, ...)
            if type(original) ~= "table" or not isC330ShopOpen() then
                return original
            end

            local indexed = {}
            for index, name in ipairs(original) do
                table.insert(indexed, {name=name, originalIndex=index})
            end

            table.sort(indexed, function(a, b)
                local ra = rank[a.name]
                local rb = rank[b.name]
                if ra ~= nil and rb ~= nil then
                    return ra < rb
                elseif ra ~= nil then
                    return true
                elseif rb ~= nil then
                    return false
                end
                return a.originalIndex < b.originalIndex
            end)

            local sorted = {}
            for _, entry in ipairs(indexed) do
                table.insert(sorted, entry.name)
            end
            return sorted
        end
    else
        Logging.warning("[C330SHOP] getSortedConfigurationTypes unavailable; leaving default shop order")
    end
end
