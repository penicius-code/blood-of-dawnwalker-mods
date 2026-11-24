-- Immersive Healing (formerly Lingering Meals), build 13
-- Human food lasts longer and heals slowly; salves and ointments are small top-ups; optional same-food stacking.
-- Build 13: stamina drinks (cocktails, alcohol, plain drinks) last longer too.
--
-- Food items (ItemConsumableDataAsset) reference a gameplay effect class that
-- adds HealthPercentRegen for a duration. This mod edits the default object
-- of those effect classes before they are applied:
--   * duration multiplied (if the duration is a plain value on the effect,
--     otherwise a duration value on the item itself, logged either way)
--   * stacking: aggregate on Coen, limit N, new stack refreshes the timer
-- Instant effects, and anything touching Blood or named vampire, are skipped.
-- Original values are stored, so changing the config never compounds.

local CONFIG_POLL_MS = 5000

local S = { cfg = {}, originals = {}, itemOriginals = {}, seenItems = {}, dumpedItemLayout = false }

---------------------------------------------------------------- config / log

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local CONFIG = nil
-- config.ini sits next to the Scripts folder, whatever the mod folder is called.
local SCRIPT_DIR = ((debug.getinfo(1, "S").source or ""):gsub("^@", "")):match("^(.*[/\\])") or ""
-- Renamed from Lingering Meals. If the old folder is still active next to this one, both would patch the
-- same effects and the changes would stack on top of each other, so this copy stays off until it is removed.
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end
if not SCRIPT_DIR:find("LingeringMeals", 1, true)
    and exists("ue4ss/Mods/LingeringMeals/enabled.txt") and exists("ue4ss/Mods/LingeringMeals/Scripts/main.lua") then
    print("[ImmersiveHealing] the old Lingering Meals folder (ue4ss\\Mods\\LingeringMeals) is still installed. "
        .. "Delete it: Immersive Healing replaces it. Immersive Healing is OFF until then.\n")
    return
end

for _, p in ipairs({ SCRIPT_DIR .. "../config.ini", "ue4ss/Mods/ImmersiveHealing/config.ini" }) do
    local f = io.open(p, "r"); if f then f:close(); CONFIG = p; break end
end
if not CONFIG then print("[ImmersiveHealing] config.ini not found, using built-in defaults\n") end

local function readConfig()
    local c = { enabled = "1", fooddurationseconds = "300", durationmultiplier = "3", stacklimit = "1", stackexpiration = "clear", logging = "0", medicinehealmultiplier = "0.08", ointmentsmallhealpercent = "2", ointmentmediumhealpercent = "4", ointmentbighealpercent = "8", medicinedurationmultiplier = "1", medicinedurationseconds = "60", foodhealmultiplier = "1", staminadurationseconds = "180" }
    if CONFIG then
        local f = io.open(CONFIG, "r")
        if f then
            for line in f:lines() do
                line = trim(line:gsub(";.*$", ""))
                local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
                if k then c[k:lower()] = trim(v) end
            end
            f:close()
        end
    end
    return {
        enabled = c.enabled ~= "0",
        duration = math.max(0.1, math.min(20, tonumber(c.durationmultiplier) or 3)),
        stacks = math.max(1, math.min(10, math.floor(tonumber(c.stacklimit) or 1))),
        -- "taper" / "clear" by hand, 1 / 0 from the Mod Setting Menu picker
        taper = c.stackexpiration:lower() == "taper" or c.stackexpiration == "1",
        logging = c.logging == "1",
        foodSeconds = math.max(0, math.min(3600, tonumber(c.fooddurationseconds) or 300)),
        medHeal = math.max(0.01, math.min(10, tonumber(c.medicinehealmultiplier) or 0.08)),
        -- build 12: ointments (instant heal) heal a fixed share of max HP per tier (vanilla 30 / 50 / 75 %)
        ointSmall = math.max(0, math.min(100, tonumber(c.ointmentsmallhealpercent) or 2)),
        ointMedium = math.max(0, math.min(100, tonumber(c.ointmentmediumhealpercent) or 4)),
        ointBig = math.max(0, math.min(100, tonumber(c.ointmentbighealpercent) or 8)),
        medDuration = math.max(0.1, math.min(100, tonumber(c.medicinedurationmultiplier) or 1)),
        medSeconds = math.max(0, math.min(3600, tonumber(c.medicinedurationseconds) or 60)),
        foodHeal = math.max(0.01, math.min(10, tonumber(c.foodhealmultiplier) or 1)),
        -- build 13: stamina drinks, fixed seconds; 0 = vanilla
        stamSeconds = math.max(0, math.min(3600, tonumber(c.staminadurationseconds) or 180)),
    }
end

local logHandle = nil
local function log(fmt, ...)
    if not S.cfg.logging then return end
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[ImmersiveHealing] " .. msg .. "\n")
    if not logHandle then logHandle = io.open("ImmersiveHealing.log", "a") end
    if logHandle then
        logHandle:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
        logHandle:flush()
    end
end

---------------------------------------------------------------- helpers

local function valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
-- Build 3: never ask an object for its name without checking it first.
-- Asking a null object crashes the game natively (pcall cannot catch it).
local function fname(o)
    if not valid(o) then return "none" end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

local function superChainHas(cls, target)
    local cur, depth = cls, 0
    while cur and depth < 15 do
        local ok, n = pcall(function() return cur:GetFName():ToString() end)
        if not ok then return false end
        if n == target then return true end
        local okS, sup = pcall(function() return cur:GetSuperStruct() end)
        if not (okS and valid(sup)) then return false end
        cur, depth = sup, depth + 1
    end
    return false
end

-- Iterate every property of an object's class chain.
local function eachProperty(obj, fn)
    local cls = obj:GetClass()
    local depth = 0
    while valid(cls) and depth < 10 do
        local cn = fname(cls)
        if cn == "Object" or cn == "DataAsset" or cn == "PrimaryDataAsset" then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                fn(fname(prop), prop:GetClass():GetFName():ToString(), prop)
            end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        if not ok then break end
        cls, depth = sup, depth + 1
    end
end

---------------------------------------------------------------- effect inspection

local POLICY = { [0] = "Instant", [1] = "Infinite", [2] = "HasDuration" }
local CALC = { [0] = "ScalableFloat", [1] = "AttributeBased", [2] = "CustomClass", [3] = "SetByCaller" }

local function modifierAttributes(cdo)
    local names = {}
    pcall(function()
        local mods = cdo.Modifiers
        for i = 1, #mods do
            local ok, n = pcall(function() return mods[i].Attribute.AttributeName:ToString() end)
            table.insert(names, ok and n or "?")
        end
    end)
    return names
end

-- Decide whether an effect class is a human food regeneration effect.
-- Build 7: three categories.
--   food             regeneration effects from food items (fruit, berries, food, meals)
--   medicine         regeneration effects from salves (Medicaments items)
--   medicine_instant instant heals from ointments (Medicaments items, healing salve)
-- Build 13:
--   stamina          timed stamina regeneration from drinks (Drinks, AlkoDrink cocktails). The stamina
--                    tonics (Medicaments10-15) are Infinite effects, timed elsewhere, and stay vanilla.
local function classify(cls, cdo, itemName)
    local name = fname(cls)
    local lname = name:lower()
    local litem = (itemName or ""):lower()
    local policy = -1
    pcall(function() policy = cdo.DurationPolicy end)
    local attrs = modifierAttributes(cdo)
    local hasRegen, hasInstant, hasStamina, touchesBlood = false, false, false, false
    for _, a in ipairs(attrs) do
        if a == "HealthPercentRegen" then hasRegen = true end
        if a == "InstantHealPercent" then hasInstant = true end
        if a == "StaminaRegenerationMultiplier" or a == "StaminaAmountMultiplier" then hasStamina = true end
        if a:lower():find("blood") then touchesBlood = true end
    end
    if touchesBlood or lname:find("blood") or lname:find("vampire") then return nil, "blood or vampire effect", attrs end
    local isMedicine = litem:find("medicaments") or litem:find("healingsalve")
    if policy == 0 then
        if hasInstant and isMedicine then return "medicine_instant", "ointment instant heal", attrs end
        return nil, "policy Instant", attrs
    end
    if policy ~= 2 then return nil, "policy " .. (POLICY[policy] or tostring(policy)), attrs end
    if not hasRegen then
        if hasStamina and not isMedicine then return "stamina", "stamina drink", attrs end
        return nil, "no HealthPercentRegen or stamina modifier", attrs
    end
    if isMedicine then return "medicine", "salve regeneration", attrs end
    return "food", "food regeneration", attrs
end

-- Scale the health modifiers of an effect default object. Originals are kept
-- per modifier, so the result never compounds.
local HEAL_ATTRS = { HealthPercentRegen = true, InstantHealPercent = true }
local function scaleHealModifiers(key, cdo, o, factor, fixed)
    o.mods = o.mods or {}
    pcall(function()
        local mods = cdo.Modifiers
        for i = 1, #mods do
            local m = mods[i]
            local attr = "?"
            pcall(function() attr = m.Attribute.AttributeName:ToString() end)
            if HEAL_ATTRS[attr] then
                local rec = o.mods[i]
                if not rec then
                    rec = { attr = attr }
                    pcall(function() rec.calc = m.ModifierMagnitude.MagnitudeCalculationType end)
                    if rec.calc == 0 then
                        pcall(function() rec.value = m.ModifierMagnitude.ScalableFloatMagnitude.Value end)
                    elseif rec.calc == 1 then
                        pcall(function() rec.value = m.ModifierMagnitude.AttributeBasedMagnitude.Coefficient.Value end)
                    elseif rec.calc == 2 then
                        pcall(function() rec.value = m.ModifierMagnitude.CustomMagnitude.Coefficient.Value end)
                    end
                    o.mods[i] = rec
                    log("  %s modifier[%d] %s magnitude %s original %s", key, i, attr, CALC[rec.calc] or tostring(rec.calc), tostring(rec.value))
                end
                if type(rec.value) == "number" then
                    local want = rec.value * factor
                    -- build 12: optional fixed value (fraction of max HP), used for ointments
                    if fixed then want = fixed end
                    if rec.calc == 0 then
                        pcall(function() m.ModifierMagnitude.ScalableFloatMagnitude.Value = want end)
                    elseif rec.calc == 1 then
                        pcall(function() m.ModifierMagnitude.AttributeBasedMagnitude.Coefficient.Value = want end)
                    elseif rec.calc == 2 then
                        pcall(function() m.ModifierMagnitude.CustomMagnitude.Coefficient.Value = want end)
                    end
                    if rec.last ~= want then
                        rec.last = want
                        log("  %s modifier[%d] %s %s -> %s", key, i, attr, tostring(rec.value), tostring(want))
                    end
                elseif not rec.warned then
                    rec.warned = true
                    log("  %s modifier[%d] %s magnitude is %s, not adjustable here", key, i, attr, CALC[rec.calc] or tostring(rec.calc))
                end
            end
        end
    end)
end

---------------------------------------------------------------- tag / component inspection (v2)

local function tagsOf(container)
    local out = {}
    pcall(function()
        local arr = container.GameplayTags
        for i = 1, #arr do
            local ok, n = pcall(function() return arr[i].TagName:ToString() end)
            if ok then table.insert(out, n) end
        end
    end)
    return out
end

-- Walks a struct or object one or two levels deep and returns every tag list
-- and plain value, e.g. "RemoveGameplayEffectQueries[1].EffectTagQuery...".
local function dumpTagsDeep(obj, structType, prefix, out, depth)
    if depth > 2 then return end
    local function visit(prop)
        local n = fname(prop)
        local t = prop:GetClass():GetFName():ToString()
        local path = prefix .. n
        if t == "StructProperty" then
            local okS, st = pcall(function() return prop:GetStruct() end)
            if not (okS and valid(st)) then return end
            local sn = fname(st)
            local okV, v = pcall(function() return obj[n] end)
            if not okV then return end
            if sn == "GameplayTagContainer" then
                local tags = tagsOf(v)
                if #tags > 0 then table.insert(out, path .. " = [" .. table.concat(tags, ", ") .. "]") end
            elseif sn == "GameplayTag" then
                local okT, tn = pcall(function() return v.TagName:ToString() end)
                if okT and tn ~= "None" then table.insert(out, path .. " = " .. tn) end
            else
                dumpTagsDeep(v, st, path .. ".", out, depth + 1)
            end
        elseif t == "ArrayProperty" then
            local okA, arr = pcall(function() return obj[n] end)
            if not okA then return end
            local count = 0
            pcall(function() count = #arr end)
            if count > 0 then
                table.insert(out, path .. " count=" .. count)
                local okI, inner = pcall(function() return prop:GetInner() end)
                if okI then
                    local it = inner:GetClass():GetFName():ToString()
                    if it == "StructProperty" then
                        local st = inner:GetStruct()
                        if not valid(st) then return end
                        for i = 1, math.min(count, 4) do
                            pcall(function() dumpTagsDeep(arr[i], st, path .. "[" .. i .. "].", out, depth + 1) end)
                        end
                    elseif it == "ClassProperty" then
                        for i = 1, math.min(count, 8) do
                            pcall(function()
                                local e = arr[i]
                                table.insert(out, path .. "[" .. i .. "] = " .. (valid(e) and fname(e) or "none"))
                            end)
                        end
                    end
                end
            end
        elseif t == "ClassProperty" then
            local okV, v = pcall(function() return obj[n] end)
            if okV and valid(v) then table.insert(out, path .. " = " .. fname(v)) end
        elseif t == "BoolProperty" or t == "IntProperty" or t == "FloatProperty" or t == "ByteProperty" or t == "EnumProperty" then
            local okV, v = pcall(function() return obj[n] end)
            if okV and v ~= false and v ~= 0 then table.insert(out, path .. " = " .. tostring(v)) end
        end
    end
    if structType then
        pcall(function() structType:ForEachProperty(visit) end)
    else
        local cls = obj:GetClass()
        local d = 0
        while valid(cls) and d < 6 do
            local cn = fname(cls)
            if cn == "Object" then break end
            pcall(function() cls:ForEachProperty(visit) end)
            local ok, sup = pcall(function() return cls:GetSuperStruct() end)
            if not ok then break end
            cls, d = sup, d + 1
        end
    end
end

local DEF_TAG_FIELDS = { "InheritableGameplayEffectTags", "InheritableOwnedTagsContainer",
    "InheritableBlockedAbilityTagsContainer", "RemoveGameplayEffectsWithTags",
    "ApplicationTagRequirements", "OngoingTagRequirements", "RemovalTagRequirements",
    "GrantedApplicationImmunityTags", "CachedAssetTags", "CachedGrantedTags", "CachedBlockedAbilityTags" }

local detailedDumps = 0
local function inspectEffect(key, cdo)
    local comps = {}
    local okC = pcall(function()
        local arr = cdo.GEComponents
        for i = 1, #arr do
            if valid(arr[i]) then table.insert(comps, arr[i]) end
        end
    end)
    local names = {}
    for _, c in ipairs(comps) do table.insert(names, fname(c:GetClass())) end
    log("  %s components: [%s]%s", key, table.concat(names, ", "), okC and "" or " (unreadable)")

    if detailedDumps >= 4 then return comps end
    detailedDumps = detailedDumps + 1
    local out = {}
    for _, f in ipairs(DEF_TAG_FIELDS) do
        pcall(function()
            local cls = cdo:GetClass()
            local v = cdo[f]
            local t = tagsOf(v)
            if #t > 0 then table.insert(out, "def." .. f .. " = [" .. table.concat(t, ", ") .. "]") end
            -- InheritedTagContainer and TagRequirements wrap containers
            for _, sub in ipairs({ "CombinedTags", "Added", "Removed", "RequireTags", "IgnoreTags" }) do
                pcall(function()
                    local st = tagsOf(v[sub])
                    if #st > 0 then table.insert(out, "def." .. f .. "." .. sub .. " = [" .. table.concat(st, ", ") .. "]") end
                end)
            end
        end)
    end
    for i, c in ipairs(comps) do
        pcall(function() dumpTagsDeep(c, nil, "comp" .. i .. ":" .. fname(c:GetClass()) .. ".", out, 0) end)
    end
    log("  %s detail:", key)
    for _, l in ipairs(out) do log("    %s", l) end
    return comps
end

---------------------------------------------------------------- patching

local function patchEffect(cls, itemObj, itemName)
    local okC, cdo = pcall(function() return cls:GetCDO() end)
    if not (okC and valid(cdo)) then log("  %s: no default object", fname(cls)); return end
    local key = fname(cls)
    local category, reason, attrs = classify(cls, cdo, itemName)
    local ok = category ~= nil

    local o = S.originals[key]
    if not o then
        o = { item = itemName }
        pcall(function() o.calc = cdo.DurationMagnitude.MagnitudeCalculationType end)
        pcall(function() o.duration = cdo.DurationMagnitude.ScalableFloatMagnitude.Value end)
        pcall(function() o.stackingType = cdo.StackingType end)
        pcall(function() o.stackLimit = cdo.StackLimitCount end)
        pcall(function() o.refresh = cdo.StackDurationRefreshPolicy end)
        pcall(function() o.expiration = cdo.StackExpirationPolicy end)
        pcall(function() o.coef = cdo.DurationMagnitude.CustomMagnitude.Coefficient.Value end)
        pcall(function() o.pre = cdo.DurationMagnitude.CustomMagnitude.PreMultiplyAdditiveValue.Value end)
        pcall(function() o.post = cdo.DurationMagnitude.CustomMagnitude.PostMultiplyAdditiveValue.Value end)
        pcall(function() o.calcClass = fname(cdo.DurationMagnitude.CustomMagnitude.CalculationClassMagnitude) end)
        S.originals[key] = o
        log("EFFECT %s (item %s): %s; modifiers [%s]; duration %s value=%s; stacking type=%s limit=%s refresh=%s expiration=%s",
            key, itemName, ok and ("TARGET " .. category) or ("skipped: " .. reason), table.concat(attrs, ", "),
            CALC[o.calc] or tostring(o.calc), tostring(o.duration),
            tostring(o.stackingType), tostring(o.stackLimit), tostring(o.refresh), tostring(o.expiration))
    end
    o.target = ok
    o.category = category
    if not ok then return end
    if not o.inspected then
        o.inspected = true
        if category ~= "medicine_instant" then
            log("  %s duration calc class=%s coefficient=%s pre=%s post=%s", key,
                tostring(o.calcClass), tostring(o.coef), tostring(o.pre), tostring(o.post))
        end
    end

    local c = S.cfg
    local on = c.enabled

    -- Build 10: food healing strength (FoodHealMultiplier), edited on the effect default object
    -- like the medicine heal. Replaces Configurable Combat Overhaul's item_healing, which walks the
    -- player's active effects and refuses once there are more than 128 of them (the test game had ~156).
    if category == "food" then
        scaleHealModifiers(key, cdo, o, on and c.foodHeal or 1)
    end

    -- Medicine: stronger heal (salves and ointments), no stacking change.
    if category == "medicine" then
        scaleHealModifiers(key, cdo, o, on and c.medHeal or 1)
    elseif category == "medicine_instant" then
        -- tier from the effect name: GE_Consumable_Health_<Small|Medium|Big>Restore_...
        local pct = key:find("BigRestore", 1, true) and c.ointBig
            or key:find("SmallRestore", 1, true) and c.ointSmall or c.ointMedium
        scaleHealModifiers(key, cdo, o, 1, on and pct / 100 or nil)
    end
    if category == "medicine_instant" then return end

    -- Duration. Food: fixed seconds (FoodDurationSeconds), or the multiplier
    -- when that is 0. Medicine: MedicineDurationMultiplier. Stamina drinks: StaminaDurationSeconds, 0 = vanilla.
    local function durationFor(orig)
        if not on then return orig end
        if category == "medicine" then
            if c.medSeconds > 0 then return c.medSeconds end
            return orig * c.medDuration
        end
        if category == "stamina" then
            if c.stamSeconds > 0 then return c.stamSeconds end
            return orig
        end
        if c.foodSeconds > 0 then return c.foodSeconds end
        return orig * c.duration
    end
    if o.calc == 0 and type(o.duration) == "number" then
        local want = durationFor(o.duration)
        pcall(function() cdo.DurationMagnitude.ScalableFloatMagnitude.Value = want end)
        local now = nil
        pcall(function() now = cdo.DurationMagnitude.ScalableFloatMagnitude.Value end)
        if now ~= o.lastDuration then
            o.lastDuration = now
            log("  %s duration %s -> %s", key, tostring(o.duration), tostring(now))
        end
    elseif o.calc == 2 and type(o.coef) == "number" then
        -- Custom calculation: result = (calc + pre) * coefficient + post.
        -- Scaling coefficient and post scales the whole duration.
        -- The coefficient is the base duration in seconds (15 salves, 20 meals,
        -- 35 food, 50 fruit and berries); perks multiply on top of it.
        local wantCoef = durationFor(o.coef)
        pcall(function() cdo.DurationMagnitude.CustomMagnitude.Coefficient.Value = wantCoef end)
        local now = nil
        pcall(function() now = cdo.DurationMagnitude.CustomMagnitude.Coefficient.Value end)
        if now ~= o.lastCoef then
            o.lastCoef = now
            log("  %s duration coefficient %s -> %s", key, tostring(o.coef), tostring(now))
        end
    elseif not o.warnedDuration then
        o.warnedDuration = true
        log("  %s duration is %s, not adjustable here", key, CALC[o.calc] or tostring(o.calc))
    end

    -- Mixed foods: removed in build 6. Editing the shared food tag crashed
    -- the game on world entry in builds 4 and 5, both by emptying the tag
    -- lists and by renaming the entry in place.

    -- Stacking: aggregate on Coen (2), limit N, refresh on apply (0),
    -- expiration clear entire stack (0) or remove one and refresh (1).
    local stackOn = on and category == "food" and c.stacks > 1
    local wantType = stackOn and 2 or o.stackingType
    local wantLimit = stackOn and c.stacks or o.stackLimit
    local wantRefresh = stackOn and 0 or o.refresh
    local wantExp = stackOn and (c.taper and 1 or 0) or o.expiration
    pcall(function() cdo.StackingType = wantType end)
    pcall(function() cdo.StackLimitCount = wantLimit end)
    pcall(function() cdo.StackDurationRefreshPolicy = wantRefresh end)
    pcall(function() cdo.StackExpirationPolicy = wantExp end)
    local state = {}
    pcall(function() table.insert(state, tostring(cdo.StackingType)) end)
    pcall(function() table.insert(state, tostring(cdo.StackLimitCount)) end)
    pcall(function() table.insert(state, tostring(cdo.StackExpirationPolicy)) end)
    local st = table.concat(state, "/")
    if st ~= o.lastStack then
        o.lastStack = st
        log("  %s stacking type/limit/expiration now %s", key, st)
    end
end

-- Item side: find effect classes and any duration value on the item.
local function processItem(item)
    local itemName = fname(item)
    local firstTime = not S.seenItems[itemName]
    S.seenItems[itemName] = true

    if not S.dumpedItemLayout and S.cfg.logging then
        S.dumpedItemLayout = true
        local layout = {}
        eachProperty(item, function(n, t) table.insert(layout, n .. ":" .. t) end)
        log("item layout (%s): %s", itemName, table.concat(layout, ", "))
    end

    local effects, durationFields = {}, {}
    eachProperty(item, function(n, t, prop)
        if t == "ClassProperty" then
            local ok, v = pcall(function() return item[n] end)
            if ok and valid(v) and superChainHas(v, "GameplayEffect") then table.insert(effects, v) end
        elseif (t == "FloatProperty" or t == "DoubleProperty") and n:lower():find("duration") then
            table.insert(durationFields, n)
        elseif t == "StructProperty" then
            pcall(function()
                local st = prop:GetStruct()
                if not valid(st) then return end
                local val = item[n]
                st:ForEachProperty(function(sp)
                    local sn = fname(sp)
                    local stype = sp:GetClass():GetFName():ToString()
                    if stype == "ClassProperty" then
                        local okV, v = pcall(function() return val[sn] end)
                        if okV and valid(v) and superChainHas(v, "GameplayEffect") then table.insert(effects, v) end
                    end
                end)
            end)
        elseif t == "ArrayProperty" then
            pcall(function()
                -- Only arrays of classes; object arrays are not followed.
                local inner = prop:GetInner():GetClass():GetFName():ToString()
                if inner ~= "ClassProperty" then return end
                local arr = item[n]
                for i = 1, #arr do
                    local v = arr[i]
                    if valid(v) and superChainHas(v, "GameplayEffect") then table.insert(effects, v) end
                end
            end)
        end
    end)

    if firstTime then
        local en = {}
        for _, e in ipairs(effects) do table.insert(en, fname(e)) end
        log("ITEM %s: effects [%s] duration fields [%s]", itemName, table.concat(en, ", "), table.concat(durationFields, ", "))
    end

    local anyTarget = false
    for _, e in ipairs(effects) do
        patchEffect(e, item, itemName)
        local o = S.originals[fname(e)]
        if o and o.target and o.calc ~= 0 then anyTarget = true end
    end

    -- Item side duration, only when the effect duration is not a plain value.
    if anyTarget then
        for _, n in ipairs(durationFields) do
            local k = itemName .. "." .. n
            if S.itemOriginals[k] == nil then
                local ok, v = pcall(function() return item[n] end)
                if ok and type(v) == "number" then
                    S.itemOriginals[k] = v
                    log("  item field %s original %s", k, tostring(v))
                end
            end
            local orig = S.itemOriginals[k]
            if type(orig) == "number" then
                local want = S.cfg.enabled and orig * S.cfg.duration or orig
                pcall(function() item[n] = want end)
            end
        end
    end
end

local function inGame()
    local pc = FindFirstOf("BP_PlayerController_C")
    if not valid(pc) then return false end
    local ok, p = pcall(function() return pc.Pawn end)
    return ok and valid(p)
end

-- Returns true when the items were processed, false when the player is not in the world yet.
local function scanItems(reason)
    -- Build 3: do nothing until the player is in the world. Food assets are
    -- loaded during startup, and inspecting them that early is not needed.
    if not inGame() then
        if not S.waitLogged then S.waitLogged = true; log("waiting for the player to be in game") end
        return false
    end
    if not S.inGameLogged then S.inGameLogged = true; log("player in game, processing food effects") end
    local items = FindAllOf("ItemConsumableDataAsset")
    if not items then
        if not S.warnedNoItems then S.warnedNoItems = true; log("no ItemConsumableDataAsset loaded yet") end
        return false
    end
    local t0 = os.clock()
    for _, item in ipairs(items) do
        if valid(item) then
            local ok, err = pcall(processItem, item)
            if not ok then log("error on %s: %s", fname(item), tostring(err)) end
        end
    end
    log("scan (%s): %d items, %.0f ms", reason, #items, (os.clock() - t0) * 1000)
    return true
end

---------------------------------------------------------------- loop

-- Build 9: no periodic scan. Build 8 ran FindFirstOf + FindAllOf + a reflection walk over every
-- consumable every 5 s on the game thread, a hitch every 5 s. The effect default objects keep the
-- edits for the whole session, so a scan is only needed when something can have changed:
--   * the player enters the world (after each load / respawn, via ClientRestart), for newly loaded items
--   * config.ini changes
-- Until the first scan succeeds (main menu, hot reload) the loop keeps checking every 5 s.
local SCAN_DELAY_S = 3
local RESTART_DEDUPE_S = 15 -- build 11: a restart right after a scan (world entry fires both) is skipped
local scanAt, scanReason = nil, nil
local firstScanDone, dispatching = false, false
local lastScanAt = -1000

local function requestScan(delay, reason)
    local due = os.clock() + delay
    if scanAt == nil or due < scanAt then scanAt, scanReason = due, reason end
end

S.cfg = readConfig()
log("==== Immersive Healing build 13 loaded: enabled=%s food %ss (x%s if 0) heal x%s stacks %d expiration %s salve heal x%s ointments %s/%s/%s%% duration %ss (x%s if 0) stamina drinks %ss",
    tostring(S.cfg.enabled), tostring(S.cfg.foodSeconds), tostring(S.cfg.duration), tostring(S.cfg.foodHeal), S.cfg.stacks,
    S.cfg.taper and "taper" or "clear", tostring(S.cfg.medHeal), tostring(S.cfg.ointSmall), tostring(S.cfg.ointMedium), tostring(S.cfg.ointBig), tostring(S.cfg.medSeconds), tostring(S.cfg.medDuration), tostring(S.cfg.stamSeconds))

-- Only sets a timestamp; the scan itself runs later from the loop (no writes inside a hook during loading).
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        if os.clock() - lastScanAt < RESTART_DEDUPE_S then return end
        requestScan(SCAN_DELAY_S, "player restart")
    end)
end)

LoopAsync(CONFIG_POLL_MS, function()
    local c = readConfig()
    local changed = c.enabled ~= S.cfg.enabled or c.duration ~= S.cfg.duration
        or c.stacks ~= S.cfg.stacks or c.taper ~= S.cfg.taper or c.foodSeconds ~= S.cfg.foodSeconds
        or c.medHeal ~= S.cfg.medHeal or c.medDuration ~= S.cfg.medDuration or c.medSeconds ~= S.cfg.medSeconds
        or c.foodHeal ~= S.cfg.foodHeal or c.stamSeconds ~= S.cfg.stamSeconds
        or c.ointSmall ~= S.cfg.ointSmall or c.ointMedium ~= S.cfg.ointMedium or c.ointBig ~= S.cfg.ointBig
    S.cfg = c
    if changed then
        log("config changed: enabled=%s food %ss (x%s if 0) heal x%s stacks %d expiration %s salve heal x%s ointments %s/%s/%s%% duration %ss (x%s if 0) stamina drinks %ss",
            tostring(c.enabled), tostring(c.foodSeconds), tostring(c.duration), tostring(c.foodHeal), c.stacks,
            c.taper and "taper" or "clear", tostring(c.medHeal), tostring(c.ointSmall), tostring(c.ointMedium), tostring(c.ointBig), tostring(c.medSeconds), tostring(c.medDuration), tostring(c.stamSeconds))
        requestScan(0, "config changed")
    end
    if not firstScanDone and scanAt == nil then requestScan(0, "first scan") end
    if dispatching or scanAt == nil or os.clock() < scanAt then return false end
    local reason = scanReason
    scanAt, scanReason = nil, nil
    dispatching = true
    ExecuteInGameThread(function()
        local ok, done = pcall(scanItems, reason)
        if not ok then log("scan error: %s", tostring(done))
        elseif done then firstScanDone = true; lastScanAt = os.clock() end
        dispatching = false
    end)
    return false
end)
