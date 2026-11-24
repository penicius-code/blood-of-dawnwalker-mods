-- Blood Vials 1.4.1
-- ] (ExtractKey) next to a dead or unconscious body (within Range, 1.5 m by default) draws its blood
-- into a vial: human blood into the human vial, animal blood into the animal vial. Each body once.
-- [ (DrinkKey) drinks a dose (human vial first by default) with a short animation and refills part of
-- Coen's blood bar through the game's BloodBarComponent:RestoreAmount. Empty vials: a message says so.
-- AnimTestKey (empty = off) plays the next extraction animation candidate; used to pick them.
-- The vials are not items: they live in state.txt in the mod folder. Messages use the game's toast.
--
-- Bodies: RebelAISubsystem:GetStubsInRange around Coen (one native query). If that finds no body,
-- GameplayStatics:GetAllActorsOfClass(DawnwalkerCharacterBase) (native, no hitch; spawned corpses have
-- no AI stub). FindAllOf (~40 ms) only if that call fails. Dead = IsAlive() false.
-- Unconscious = the AI stub has RebelAI.Flag.Unconscious or RebelAI.Flag.BloodDirnkingUnconscious
-- (the game's spelling). Human or animal: CreaturesSubsystem:GetCreatureEntryFromActor (Category
-- 1 Human, 2 Animal, 3 Monster), else the BloodDrinkableComponent's entry, else the actor class.
-- Distance: horizontal, to the nearest of the actor origin and the mesh's pelvis / head.
--
-- Everything runs on the game thread on key press. Kept between presses: the game engine, default
-- objects and classes. Nothing else; extractions per body are counted by full name only.

local VERSION = "1.4.1"
local TAG = "[BloodVials] "
local MOD = "BloodVials"

local FRONTEND_CDO = "/Script/DogwoodUI.Default__UIFrontend"
local SUBLIB_CDO = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local AI_CLASS = "/Script/RebelAI.RebelAISubsystem"
local CREATURES_CLASS = "/Script/DogwoodSystem.CreaturesSubsystem"
local DRINKABLE_CLASS = "/Script/Dawnwalker.BloodDrinkableComponent"
local HUMANOID_NPC_CLASS = "/Script/Dawnwalker.HumanoidNPCBase"
local QUADRUPED_CLASS = "/Script/Dawnwalker.QuadrupedCharacter"
local SCAN_CLASS = "DawnwalkerCharacterBase"
local CHAR_CLASS = "/Script/Dawnwalker.DawnwalkerCharacterBase"
local GS_CDO = "/Script/Engine.Default__GameplayStatics"
local BLOODBAR_CLASS = "/Script/DogwoodStats.BloodBarComponent"

local UNCONSCIOUS_TAGS = { "RebelAI.Flag.Unconscious", "RebelAI.Flag.BloodDirnkingUnconscious" }
local BONES = { "pelvis", "head" }
local HUMAN, ANIMAL, MONSTER = 1, 2, 3
local CATEGORY = { [0] = "none", "human", "animal", "monster" }
local MAX_DZ = 200         -- cm: a body may lie lower or higher than Coen's centre
local SEARCH_EXTRA = 300   -- cm added to Range for the AI query (a ragdoll can drift from its actor origin)
local MAX_LOGGED = 12      -- candidates described per press

local S = {
    range = 150,           -- cm, horizontal
    capacity = 1,          -- fills per vial (one body = one fill)
    dosesPerFill = 2,      -- drinks per fill
    maxDoses = 2,          -- capacity * dosesPerFill; the vials count drinks
    scan = true,           -- list all characters when the AI query finds no body
    humanRestore = 20,     -- % of the blood bar per human drink (2 drinks per body = 40%)
    animalRestore = 10,    -- % of the blood bar per animal drink (2 drinks per body = 20%)
    humanCorruption = 1.5, -- mutation charges per human drink before Corruption Rate's share (0 = off). Animal: none
    drinkFirst = 1,        -- 1 human vial first, 2 animal vial first
    healDamage = true,     -- a drink also fills segments lost to permanent blood damage (like vanilla vials)
    gesture = true,        -- drinking animation
    animIndex = 5,         -- DRINK_ANIMS entry used for drinking (5 picked in testing, 2026-09-30)
    animSlot = "Upperbody_Override",
    drinkAt = 2.0,         -- s after the start: blood restored (the sip; 2.0 is a guess)
    stopAt = 0,            -- s after the start: animation cut (0 = full length)
    stopBlend = 0.4,
    animTime = 1.15,        -- s the drinking animation lasts (sped up); 0 = normal speed
    extractAnim = 2,       -- EXTRACT_ANIMS entry used for extracting, 0 = none (2 picked in testing, 2026-09-30)
    extractSpeed = 1.38,   -- play rate when ExtractAnimTime is 0 (20% faster, then 15% more)
    extractSlot = "DefaultSlot", -- whole body
    extractAnimTime = 0,   -- s the extraction animation lasts; 0 = normal speed
    fillAt = 3.0,          -- s of animation time: vial filled (guess)
    extractStopAt = 0,     -- s of animation time: extraction animation cut (0 = full length)
    logging = false,
    human = 0,
    animal = 0,
    drained = {},          -- body full name -> extractions so far (this game session)
    maxExtract = 3,        -- extractions per body; then "The blood has gone cold"
    toastSeq = 0,
    lastToast = nil,
}

---------------------------------------------------------------- config and state

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function findDir()
    for _, prefix in ipairs({ "ue4ss/Mods/", "Mods/" }) do
        local f = io.open(prefix .. MOD .. "/config.ini", "r")
        if f then f:close() return prefix .. MOD .. "/" end
    end
    return nil
end

local DIR = findDir()

local function readIni(path)
    local cfg = {}
    local f = path and io.open(path, "r")
    if not f then return cfg end
    for line in f:lines() do
        line = trim(line:gsub(";.*$", ""))
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        if k then cfg[k:lower()] = trim(v) end
    end
    f:close()
    return cfg
end

local function readConfig() return readIni(DIR and (DIR .. "config.ini")) end

local function clamp(v, lo, hi, def)
    v = math.floor(tonumber(v or "") or def)
    if v < lo or v > hi then return def end
    return v
end

local function applyConfig()
    local c = readConfig()
    S.range = clamp(c.range, 50, 500, 150)
    S.humanRestore = clamp(c.humanrestore, 1, 100, 20)
    S.animalRestore = clamp(c.animalrestore, 1, 100, 10)
    S.humanCorruption = tonumber(c.humancorruption or "") or 1.5
    if S.humanCorruption < 0 or S.humanCorruption > 10 then S.humanCorruption = 1.5 end
    S.drinkFirst = clamp(c.drinkfirst, 1, 2, 1)
    S.maxExtract = clamp(c.maxextract, 1, 10, 3)
    S.healDamage = (c.healdamage or "1") == "1"
    S.gesture = (c.gesture or "1") == "1"
    S.animIndex = clamp(c.anim, 1, 10, 5)
    S.animSlot = (c.animslot and c.animslot ~= "") and c.animslot or "Upperbody_Override"
    S.drinkAt = math.max(0, tonumber(c.drinkat or "") or 2.0)
    S.stopAt = math.max(0, tonumber(c.stopat or "") or 0)
    S.stopBlend = math.max(0, tonumber(c.stopblend or "") or 0.4)
    S.animTime = math.max(0, tonumber(c.animtime or "") or 1.15)
    S.extractAnim = clamp(c.extractanim, 0, 11, 2)
    S.extractSpeed = math.max(0.1, tonumber(c.extractspeed or "") or 1.38)
    S.extractSlot = (c.extractslot and c.extractslot ~= "") and c.extractslot or "DefaultSlot"
    S.extractAnimTime = math.max(0, tonumber(c.extractanimtime or "") or 0)
    S.fillAt = math.max(0, tonumber(c.fillat or "") or 3.0)
    S.extractStopAt = math.max(0, tonumber(c.extractstopat or "") or 0)
    S.capacity = clamp(c.capacity, 1, 10, 1)
    S.scan = (c.scan or "1") == "1"
    S.logging = (c.logging or "0") == "1"
    S.dosesPerFill = clamp(c.dosesperfill, 1, 10, 2)
    S.maxDoses = S.capacity * S.dosesPerFill
    S.human = math.min(S.human, S.maxDoses)
    S.animal = math.min(S.animal, S.maxDoses)
end

-- Vial contents live in state.txt (written by the mod, not in the zip), so the Mod Setting Menu
-- and the mod never write the same file.
local function loadState()
    local f = DIR and io.open(DIR .. "state.txt", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*(%a+)%s*=%s*(%d+)")
        if k == "human" then S.human = tonumber(v) end
        if k == "animal" then S.animal = tonumber(v) end
    end
    f:close()
end

local function saveState()
    local f = DIR and io.open(DIR .. "state.txt", "w")
    if not f then return false end
    f:write("human=", tostring(S.human), "\n", "animal=", tostring(S.animal), "\n")
    f:close()
    return true
end

---------------------------------------------------------------- logging

local function log(fmt, ...)
    if S.logging then print(TAG .. string.format(fmt, ...) .. "\n") end
end

local function say(fmt, ...)
    print(TAG .. string.format(fmt, ...) .. "\n")
end

---------------------------------------------------------------- helpers

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function live(o)
    if type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- Properties, array elements, weak pointers: the object inside, or nil.
local function ref(o)
    if live(o) then return o end
    if type(o) ~= "userdata" then return nil end
    local v = try(function() return o:get() end)
    if live(v) then return v end
    v = try(function() return o:Get() end)
    if live(v) then return v end
    return nil
end

local function num(v)
    if type(v) == "userdata" then
        local ok, r = pcall(function() return v:get() end)
        if ok and r ~= nil then v = r end
    end
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    return tonumber(tostring(v))
end

local function fullName(o)
    return try(function() return o:GetFullName() end)
end

local function nameOf(o)
    return try(function() return o:GetFName():ToString() end) or "?"
end

local function addr(o)
    return try(function() return o:GetAddress() end)
end

-- Classes and default objects live as long as the game: kept, re-found if they ever go stale.
local statics = {}
local function static(path)
    local o = statics[path]
    if live(o) then return o end
    o = try(function() return StaticFindObject(path) end)
    statics[path] = live(o) and o or nil
    return statics[path]
end

local function isA(o, classPath)
    local c = static(classPath)
    if not c then return false end
    local ok, r = pcall(function() return o:IsA(c) end)
    return ok and r == true
end

local function locOf(a)
    local ok, x, y, z = pcall(function()
        local v = a:K2_GetActorLocation()
        return v.X, v.Y, v.Z
    end)
    if ok and type(x) == "number" then return x, y, z end
    return nil
end

---------------------------------------------------------------- world

-- The engine lives as long as the game: kept. World, pawn and subsystems are read fresh.
local engine, engineRetryAt = nil, 0

local function gameEngine()
    if live(engine) then return engine end
    engine = nil
    local now = os.clock()
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 10
    for _, e in ipairs(FindAllOf("GameEngine") or {}) do
        if live(e) then engine = e break end
    end
    return engine
end

local function worldOf()
    local e = gameEngine()
    return e and try(function() return ref(e.GameViewport.World) end)
end

local function playerPawn()
    local e = gameEngine()
    if not e then return nil end
    return try(function()
        local player = ref(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        return ref(player.PlayerController.Pawn)
    end)
end

local function subsystem(ctx, classPath, world)
    local lib, cls = static(SUBLIB_CDO), static(classPath)
    if not (lib and cls) then return nil end
    return try(function()
        if world then return ref(lib:GetWorldSubsystem(ctx, cls)) end
        return ref(lib:GetGameInstanceSubsystem(ctx, cls))
    end)
end

-- Live AI stubs around a point, from one native query (valid for this press only).
local function stubsNear(ai, x, y, z, radius)
    local out = {}
    local ok, err = pcall(function() ai:GetStubsInRange({ X = x, Y = y, Z = z }, radius, out) end)
    if not ok then return nil, err end
    local list = out.Stubs or out
    local stubs = {}
    if type(list) == "table" then
        for _, e in ipairs(list) do
            local v = ref(e)
            if v then stubs[#stubs + 1] = v end
        end
    else
        pcall(function()
            list:ForEach(function(_, e)
                local v = ref(e)
                if v then stubs[#stubs + 1] = v end
            end)
        end)
    end
    return stubs
end

---------------------------------------------------------------- bodies

local function aliveOf(a)
    local ok, v = pcall(function() return a:IsAlive() end)
    if ok and type(v) == "boolean" then return v, "actor" end
    local c = try(function() return ref(a.CombatComponent) end)
    if c then
        ok, v = pcall(function() return c:IsAlive() end)
        if ok and type(v) == "boolean" then return v, "combat component" end
    end
    return nil, "unreadable"
end

local function unconsciousOf(stub)
    if not stub then return false, nil end
    for _, t in ipairs(UNCONSCIOUS_TAGS) do
        local ok, v = pcall(function() return stub:HasTag({ TagName = FName(t) }) end)
        if ok and v == true then return true, t end
    end
    return false, nil
end

-- Returns category (1 human, 2 animal, 3 monster, nil unknown), creature type, source, drinkable flag.
local function creatureOf(a, creatures)
    local ctype = try(function() return a.CreatureType:ToString() end) or "?"
    if creatures then
        -- bool& bOutResult: unverified whether this UE4SS build wants a table or a value there
        for _, outArg in ipairs({ {}, false }) do
            local ok, cat, drink = pcall(function()
                local e = creatures:GetCreatureEntryFromActor(a, outArg)
                return num(e.Category), e.bDrinkable
            end)
            if ok and cat and cat > 0 then return cat, ctype, "creature table", drink end
        end
    end
    local dc = static(DRINKABLE_CLASS)
    if dc then
        local ok, cat, drink = pcall(function()
            local comp = a:GetComponentByClass(dc)
            if not live(comp) then return nil end
            local e = comp.CreatureEntry
            return num(e.Category), e.bDrinkable
        end)
        if ok and cat and cat > 0 then return cat, ctype, "drinkable component", drink end
    end
    if isA(a, QUADRUPED_CLASS) then return ANIMAL, ctype, "class", nil end
    if isA(a, HUMANOID_NPC_CLASS) then return HUMAN, ctype, "class", nil end
    return nil, ctype, "unknown", nil
end

-- Horizontal distance (cm) from Coen to the nearest of the body's actor origin, pelvis and head,
-- counting only points within MAX_DZ height. nil if none is.
local function distanceTo(a, px, py, pz)
    local pts = {}
    local x, y, z = locOf(a)
    if x then pts[#pts + 1] = { x, y, z } end
    local mesh = try(function() return ref(a.Mesh) end)
    if mesh then
        for _, bone in ipairs(BONES) do
            local ok, bx, by, bz = pcall(function()
                local v = mesh:GetSocketLocation(FName(bone))
                return v.X, v.Y, v.Z
            end)
            if ok and type(bx) == "number" then pts[#pts + 1] = { bx, by, bz } end
        end
    end
    local best = nil
    for _, p in ipairs(pts) do
        if math.abs(p[3] - pz) <= MAX_DZ then
            local d = math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2)
            if not best or d < best then best = d end
        end
    end
    return best
end

-- Everything known about one character near Coen.
local function describe(a, stub, via, ctx)
    local c = { actor = a, stub = stub, via = via, name = nameOf(a) }
    c.key = fullName(a) or c.name
    c.dist = distanceTo(a, ctx.px, ctx.py, ctx.pz)
    c.alive, c.aliveVia = aliveOf(a)
    c.unconscious, c.flag = unconsciousOf(stub)
    c.body = c.alive == false or c.unconscious
    if c.body or (c.dist and c.dist <= S.range) then
        c.cat, c.ctype, c.catVia, c.drinkable = creatureOf(a, ctx.creatures)
    end
    return c
end

local function line(c)
    local state = c.alive == false and "dead" or (c.unconscious and "unconscious") or
        (c.alive == true and "alive") or "alive?"
    return string.format("%s [%s] %s%s, %s %s (%s%s), %s%s", c.name, c.via, state,
        c.flag and (" " .. c.flag) or "", c.cat and CATEGORY[c.cat] or "creature ?", c.ctype or "?",
        c.catVia or "-", c.drinkable ~= nil and (", drinkable " .. tostring(c.drinkable)) or "",
        c.dist and string.format("%.0f cm", c.dist) or "too high/low",
        S.drained[c.key] and string.format(", extracted %dx", S.drained[c.key]) or "")
end

-- All characters in the world, for this press only. GameplayStatics:GetAllActorsOfClass fills the out
-- table (0.00 ms in BodyProbe, 2026-10-10). FindAllOf (~40 ms) only if the native call fails, or while
-- it has never returned anything (once it has, an empty answer is real).
local nativeProven = false
local function characters(ctx)
    local gs, cls = static(GS_CDO), static(CHAR_CLASS)
    if gs and cls then
        local out = {}
        local ok, ret = pcall(function() return gs:GetAllActorsOfClass(ctx, cls, out) end)
        local src = (#out > 0 and out) or (type(ret) == "table" and ret) or
            (type(out.OutActors) == "table" and out.OutActors) or {}
        local list = {}
        for _, a in ipairs(src) do
            a = ref(a)
            if a then list[#list + 1] = a end
        end
        if ok and (#list > 0 or nativeProven) then
            nativeProven = true
            return list, "native"
        end
    end
    local list = {}
    for _, a in ipairs(FindAllOf(SCAN_CLASS) or {}) do
        a = ref(a)
        if a and not (fullName(a) or ""):find("Default__", 1, true) then list[#list + 1] = a end
    end
    return list, "scan"
end

-- Characters near Coen: the AI query first, the character list only if the query found no body.
local function survey(pawn, px, py, pz)
    local ctx = { px = px, py = py, pz = pz }
    ctx.creatures = subsystem(pawn, CREATURES_CLASS, false)
    local ai = subsystem(pawn, AI_CLASS, true)
    local found, seen = {}, {}
    local pawnAddr = addr(pawn)
    if pawnAddr then seen[pawnAddr] = true end
    local radius = S.range + SEARCH_EXTRA
    local notes = {}

    local t0 = os.clock()
    if ai then
        local stubs, err = stubsNear(ai, px, py, pz, radius)
        if stubs then
            for _, stub in ipairs(stubs) do
                local isPlayer = try(function() return stub:IsPlayer() end)
                local a = not isPlayer and try(function() return ref(stub:GetActor()) end)
                local k = a and addr(a)
                if a and k and not seen[k] then
                    seen[k] = true
                    found[#found + 1] = describe(a, stub, "query", ctx)
                end
            end
            notes[#notes + 1] = string.format("query %d stub(s) within %.0f cm (%.1f ms)", #stubs, radius,
                (os.clock() - t0) * 1000)
        else
            notes[#notes + 1] = "query failed: " .. tostring(err):sub(1, 160)
        end
    else
        notes[#notes + 1] = "no AI subsystem"
    end

    local anyBody = false
    for _, c in ipairs(found) do
        if c.body and c.dist and c.dist <= S.range then anyBody = true break end
    end

    if not anyBody and S.scan then
        local t1 = os.clock()
        local all, how = characters(pawn)
        local t2 = os.clock()
        local added = 0
        for _, a in ipairs(all) do
            local k = live(a) and addr(a)
            if k and not seen[k] then
                seen[k] = true
                local x, y, z = locOf(a)
                if x and math.abs(z - pz) <= MAX_DZ + SEARCH_EXTRA and
                    (x - px) ^ 2 + (y - py) ^ 2 <= radius ^ 2 then
                    local stub = ai and try(function() return ref(ai:GetAIStubFromActor(a)) end)
                    found[#found + 1] = describe(a, stub, "scan", ctx)
                    added = added + 1
                end
            end
        end
        notes[#notes + 1] = string.format("%s %d character(s), %d more nearby (%.2f ms list + %.1f ms)",
            how, #all, added, (t2 - t1) * 1000, (os.clock() - t2) * 1000)
    end

    table.sort(found, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
    return found, table.concat(notes, "; "), ctx.creatures ~= nil
end

---------------------------------------------------------------- toast

local frontendRetry = 0

-- UIFrontend.GetFrontend(world) (verified 2026-09-30 in DecapitationFinishers); FindAllOf is the fallback.
local function toastWidget()
    local world = worldOf()
    local cdo = static(FRONTEND_CDO)
    if world and cdo then
        local f = try(function() return ref(cdo:GetFrontend(world)) end)
        local w = f and try(function() return ref(f.ToastWidget) end)
        if w then return w, "GetFrontend" end
    end
    if os.clock() < frontendRetry then return nil, "no toast widget" end
    frontendRetry = os.clock() + 5
    for _, f in ipairs(FindAllOf("UIFrontend") or {}) do
        if live(f) and not (fullName(f) or ""):find("Default__", 1, true) then
            local w = try(function() return ref(f.ToastWidget) end)
            if w then return w, "scan" end
        end
    end
    return nil, "no toast widget"
end

-- The game's toast. A toast of the game's own is waited for (0.4 s steps, 8 tries); one of ours
-- is replaced; a newer message drops an older one still waiting. Game thread.
local function toast(msg)
    S.toastSeq = S.toastSeq + 1
    local id, tries = S.toastSeq, 0
    local function attempt()
        if id ~= S.toastSeq then return end
        tries = tries + 1
        local ok, res = pcall(function()
            local w, via = toastWidget()
            if not w then return via end
            local busy = try(function() return w:IsShowingToast() end)
            local ours = S.lastToast ~= nil and os.clock() - S.lastToast < 4
            if busy == true and not ours then return "busy" end
            w:Show({ Type = 0, Message = FText(msg) })
            S.lastToast = os.clock()
            return "shown via " .. via
        end)
        res = ok and res or ("error: " .. tostring(res))
        if res == "busy" and tries < 8 then
            ExecuteWithDelay(400, function() ExecuteInGameThread(attempt) end)
            return
        end
        log("toast '%s': %s (try %d)", msg, res, tries)
    end
    attempt()
end

---------------------------------------------------------------- vials

local LABEL = { [HUMAN] = "Human", [ANIMAL] = "Animal" }
local SLOT = { [HUMAN] = "human", [ANIMAL] = "animal" }

-- n = drinks left in a vial.
local function amount(n)
    if n <= 0 then return "empty" end
    return string.format("%d of %d drink%s", n, S.maxDoses, S.maxDoses == 1 and "" or "s")
end

local function status()
    if S.human <= 0 and S.animal <= 0 then return "Your blood vials are now empty." end
    return string.format("Human vial: %s. Animal vial: %s.", amount(S.human), amount(S.animal))
end

-- Why this body cannot fill a vial now (message), or nil when it can.
local function fillRefusal(c)
    local slot = SLOT[c.cat]
    if not slot then
        log("body %s: %s blood, not bottled", c.name, c.cat and CATEGORY[c.cat] or "unknown")
        return "This blood is of no use"
    end
    if S[slot] >= S.maxDoses then return LABEL[c.cat] .. " blood vial is already full" end
    return nil
end

-- Fills DosesPerFill drinks (up to the vial's size) from body `c` (checked again: it may run seconds after the key press).
local function fill(c)
    local refusal = fillRefusal(c)
    if refusal then return refusal end
    if (S.drained[c.key] or 0) >= S.maxExtract then return "The blood has gone cold" end
    local slot, label = SLOT[c.cat], LABEL[c.cat]
    S[slot] = math.min(S.maxDoses, S[slot] + S.dosesPerFill)
    S.drained[c.key] = (S.drained[c.key] or 0) + 1
    local saved = saveState()
    log("filled %s vial from %s (%s): now %d/%d drinks%s", slot, c.name, c.ctype or "?", S[slot], S.maxDoses,
        saved and "" or ", state.txt not written")
    return string.format("%s blood vial filled (%s)", label, amount(S[slot]))
end

---------------------------------------------------------------- drinking

-- Coen's blood bar component: on the pawn, else on its player state (found on pawn.PlayerState,
-- 2026-09-30). Read fresh on every drink.
local function bloodBar(pawn)
    local cls = static(BLOODBAR_CLASS)
    if not cls then return nil, "no BloodBarComponent class" end
    local owners = {
        { "pawn", function() return pawn end },
        { "pawn.PlayerState", function() return ref(pawn.PlayerState) end },
        { "controller.PlayerState", function() return ref(ref(pawn.Controller).PlayerState) end },
    }
    for _, o in ipairs(owners) do
        local owner = try(o[2])
        local comp = owner and try(function() return ref(owner:GetComponentByClass(cls)) end)
        if comp then return comp, o[1] end
    end
    return nil, "no blood bar found"
end

local function readBar(bar)
    return num(try(function() return bar:GetBlood() end)),
        num(try(function() return bar:GetBloodBarLength() end)),
        num(try(function() return bar:GetBloodPermDamage() end))
end

-- Runs fn on the game thread after seconds.
local function later(seconds, fn)
    ExecuteWithDelay(math.max(0, math.floor(seconds * 1000)), function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then say("delayed step error: %s", tostring(err)) end
        end)
    end)
end

-- Human blood raises mutation ("corruption"; only human blood, only our vials). Vanilla human
-- vial in the test game: +0.30 charges, with the Corruption Rate mod keeping GainPercent (20) of every gain, so
-- HumanCorruption (1.5) is the unscaled amount and Corruption Rate's share is applied here (read from its
-- config.ini: an AddMutationCharges call from another mod is exempt from its scaling, so it would not scale ours).
-- AddMutationCharges takes an int32 (1.4.0: 1 unit = +1.0), so the fractional amount uses Corruption Rate's
-- write: the attribute one unit short of the target, then the game's AddMutationCharges(1), so saves keep it.
local DEV_CLASS = "/Script/DogwoodCharacterDevelopment.CharacterDevelopmentSubsystem"

-- Share of a corruption gain that Corruption Rate (a separate mod in this collection) keeps: 1 when it is absent or off.
local function corruptionShare()
    if not DIR then return 1, "mod folder unknown" end
    local base = DIR:sub(1, #DIR - #MOD - 1)
    local f = io.open(base .. "CorruptionRate/enabled.txt", "r")
    if not f then return 1, "no Corruption Rate" end
    f:close()
    local c = readIni(base .. "CorruptionRate/config.ini")
    if (c.enabled or "1") == "0" then return 1, "Corruption Rate off" end
    local pct = tonumber(c.gainpercent or "") or 10
    if pct < 0 or pct > 100 then pct = 10 end
    return pct / 100, string.format("Corruption Rate keeps %g%%", pct)
end

local function chargeData(set)
    local b, c = nil, nil
    pcall(function() b, c = set.MutationCharged.BaseValue, set.MutationCharged.CurrentValue end)
    if type(b) ~= "number" or type(c) ~= "number" then return nil, nil end
    return b, c
end

-- Base to value, current moved by the same amount (Corruption Rate's rawWrite). True if it reads back.
local function rawCharge(set, value)
    local b0, c0 = chargeData(set)
    if not b0 then return false end
    pcall(function()
        set.MutationCharged.BaseValue = value
        set.MutationCharged.CurrentValue = c0 + (value - b0)
    end)
    local b = chargeData(set)
    return b ~= nil and math.abs(b - value) < 0.001
end

local function addCorruption(pawn)
    local share, why = corruptionShare()
    local amount = S.humanCorruption * share
    if amount <= 0 then return end
    local dev = subsystem(pawn, DEV_CLASS, false)
    if not dev then log("corruption: no CharacterDevelopmentSubsystem") return end
    local set = try(function() return ref(pawn.VampireAttributeSet) end)
    if not set then log("corruption: no VampireAttributeSet on the player") return end
    local before = chargeData(set)
    if not before then log("corruption: charge unreadable") return end
    local target = before + amount
    local how
    if target < 1 then
        how = rawCharge(set, target) and "plain write (below 1)" or "plain write FAILED"
    elseif not rawCharge(set, target - 1) then
        how = "write before the game call FAILED"
    else
        local called, cerr = pcall(function() dev:AddMutationCharges(1) end)
        local b = chargeData(set)
        if called and b and math.abs(b - target) < 0.001 then
            how = "game call, landed at once"
        elseif called and b and math.abs(b - (target - 1)) < 0.001 then
            how = "game call, unit pending"
            later(1, function()
                local p = playerPawn()
                local s2 = p and try(function() return ref(p.VampireAttributeSet) end)
                local b2 = s2 and chargeData(s2)
                if b2 and b2 < target - 0.5 then
                    log("corruption: the game's unit never came, plain write of %.3f: %s", target,
                        rawCharge(s2, target) and "made" or "FAILED")
                end
            end)
        else
            how = (called and string.format("game call read %s", tostring(b)) or ("game call failed: " .. tostring(cerr)))
                .. (rawCharge(set, target) and "; plain write instead" or "; plain write FAILED")
        end
    end
    log("corruption: +%.3f (%.2f x %s), charges %.3f -> %.3f, %s", amount, S.humanCorruption, why, before, target, how)
end

-- Restores one dose of `cat` blood: a share of the blood bar through the game's own
-- BloodBarComponent:RestoreAmount (RestorePercentage if the bar length is unreadable).
-- Everything is re-read here (it may run seconds after the key press, at the sip).
local function applyDose(cat)
    local slot = SLOT[cat]
    local pct = cat == HUMAN and S.humanRestore or S.animalRestore
    if S[slot] <= 0 then return "Your blood vials are empty" end
    local pawn = playerPawn()
    local bar, via = nil, "no player character"
    if pawn then bar, via = bloodBar(pawn) end
    if not bar then
        log("drink: %s", via)
        return "You can't drink now"
    end
    local before, len, perm = readBar(bar)

    local how
    local ok, err
    if len and len > 0 then
        how = string.format("RestoreAmount(%.2f)", len * pct / 100)
        ok, err = pcall(function() bar:RestoreAmount(len * pct / 100, S.healDamage) end)
    else
        how = string.format("RestorePercentage(%.2f)", pct / 100)
        ok, err = pcall(function() bar:RestorePercentage(pct / 100, S.healDamage) end)
    end
    if not ok then
        log("drink: %s failed: %s", how, tostring(err))
        return "You can't drink now"
    end
    S[slot] = S[slot] - 1
    saveState()
    if cat == HUMAN then
        local okC, errC = pcall(addCorruption, pawn)
        if not okC then log("corruption error: %s", tostring(errC)) end
    end
    local after, _, permAfter = readBar(bar)
    log("drink %s via %s, ignore perm damage %s (%s): blood %s -> %s of %s, perm damage %s -> %s; vials human %d, animal %d",
        slot, how, tostring(S.healDamage), via, tostring(before), tostring(after), tostring(len), tostring(perm),
        tostring(permAfter), S.human, S.animal)
    if S.logging then
        later(1, function()
            local p = playerPawn()
            local b = p and bloodBar(p)
            if b then
                local b1, _, p1 = readBar(b)
                log("  1 s later: blood %s, perm damage %s", tostring(b1), tostring(p1))
            end
        end)
    end
    return string.format("You drink the %s blood. %s", slot, status())
end

---------------------------------------------------------------- gestures

-- NPC community animations use SK_Coen_IK_Skeleton and play on Coen (BloodWash 0.4.x). Props (mug,
-- bottle, torch) are not shown. Upperbody_Override = upper body only; DefaultSlot = whole body.
local COMMUNITY = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/"
local function anim(sub, name) return COMMUNITY .. sub .. "/" .. name .. "." .. name end
local STAND, STAND_B = "Male_Human_Community_Background_Standing", "Male_Human_Community_Background_Standing_B"
local WASH, MISERABLE = "Male_Human_Community_Washing_Face", "Male_Human_Community_Miserable"

-- Drinking: 5 was picked in testing (2026-09-30).
local DRINK_ANIMS = {
    anim(STAND_B, "Male_Human_Community_Drinking_Vodka_Bottle_Start"),    -- 3.27 s
    anim(STAND, "Male_Human_Community_Drinking_Mug_Loop_01"),             -- 3.33 s
    anim(STAND, "Male_Human_Community_Drinking_Mug_Loop_06"),             -- 3.50 s
    anim(STAND, "Male_Human_Community_Drinking_Loop_02"),                 -- 3.53 s
    anim(STAND, "Male_Human_Community_Drinking_Mug_Loop_05"),             -- 3.97 s
    anim(STAND, "Male_Human_Community_Drinking_Mug_Start"),               -- 5.17 s
    anim(STAND_B, "Male_Human_Community_Drinking_Vodka_Bottle_Idle_02"),  -- 5.33 s
    anim(STAND, "Male_Human_Community_Drinking_Start"),                   -- 5.77 s
    anim(STAND_B, "Male_Human_Community_Drinking_Vodka_Bottle_Stop"),     -- 2.77 s
    anim(STAND, "Male_Human_Community_Drinking_Mug_Stop"),                -- 4.70 s
}

-- Extraction candidates (crouching / reaching to the ground), auditioned with the test key.
local EXTRACT_ANIMS = {
    "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Interactions/Coen_Human_Torch/Coen_Crouch_Torch_Start.Coen_Crouch_Torch_Start", -- 2.00 s
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Start"),   -- 5.50 s
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Loop_01"), -- 5.87 s
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Loop_02"), -- 4.90 s
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Loop_03"), -- 4.07 s
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Loop_04"), -- 3.67 s (BloodWash crouching wipe)
    anim(WASH, "Male_Human_Community_Washing_Face_Low_Container_Loop_05"), -- 5.20 s
    anim(STAND, "Male_Human_Community_Crouching_Resting_A_Start"),         -- 4.73 s
    anim(STAND, "Male_Human_Community_Crouching_Resting_B_Start"),         -- 6.47 s
    anim(MISERABLE, "Male_Human_Community_Crouching_Depressed_A_Start"),   -- 5.83 s
    "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Interactions/Male_Human_Reactions/Male_Human_Torch_Investigate_01.Male_Human_Torch_Investigate_01", -- 8.80 s
}

local G = { busyUntil = 0, seq = 0, test = 0, slot = nil }

local function animInstance(pawn)
    local mesh = try(function() return ref(pawn.Mesh) end)
    return mesh and try(function() return ref(mesh:GetAnimInstance()) end)
end

-- StaticFindObject if loaded, else a blocking load (UE4SS LoadAsset does nothing in this build).
-- Never pass a Lua table as the soft reference: that crashes natively.
local function loadAnim(path)
    local a = try(function() return StaticFindObject(path) end)
    if live(a) then return a, "loaded" end
    local ksl = static("/Script/Engine.Default__KismetSystemLibrary")
    if not ksl then return nil, "KismetSystemLibrary not found" end
    local ok, res = pcall(function()
        return ksl:LoadAsset_Blocking(ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path)))
    end)
    if ok and live(res) then return res, "load" end
    a = try(function() return StaticFindObject(path) end)
    if live(a) then return a, "load, found after" end
    return nil, "could not load: " .. (ok and "nothing returned" or tostring(res))
end

-- Plays `path` on Coen in `slot`, sped up to last `seconds`, or at `speed` when seconds is 0 (default 1).
-- Returns the real length in seconds and the play rate, or nil and why not.
local function playGesture(pawn, path, slot, seconds, speed)
    if try(function() return pawn:IsInWolfForm() end) == true then return nil, "wolf form" end
    if try(function() return pawn.bCinematicMode end) == true then return nil, "dialogue/cutscene" end
    local ai = animInstance(pawn)
    if not ai then return nil, "no AnimInstance" end
    local asset, how = loadAnim(path)
    if not asset then return nil, "animation " .. how end
    local len = num(try(function() return asset:GetPlayLength() end)) or 3
    local rate = (seconds > 0 and len > 0) and len / seconds or (speed or 1.0)
    local m = try(function()
        return ai:PlaySlotAnimationAsDynamicMontage(asset, FName(slot), 0.2, 0.25, rate, 1, -1.0, 0.0)
    end)
    if not live(m) then return nil, "mesh refused the animation" end
    G.slot = slot
    log("gesture %s (%s, %.2f s at x%.2f = %.2f s) in %s", nameOf(asset), how, len, rate, len / rate, slot)
    return len / rate, rate
end

local function stopGesture(seq)
    if seq ~= G.seq or not G.slot then return end
    local pawn = playerPawn()
    local ai = pawn and animInstance(pawn)
    if ai then pcall(function() ai:StopSlotAnimation(S.stopBlend, FName(G.slot)) end) end
    log("gesture stopped at StopAt")
end

-- Plays a gesture and runs `action` (returns the message) at `atAnimTime` seconds of animation time.
-- Returns nil when the message comes later, or the message now if no gesture played.
local function withGesture(pawn, path, slot, seconds, speed, atAnimTime, stopAnimTime, action, what)
    local glen, rate = playGesture(pawn, path, slot, seconds, speed)
    if not glen then
        log("%s: no gesture (%s), instant", what, tostring(rate))
        return action()
    end
    G.seq = G.seq + 1
    local seq = G.seq
    -- animation time -> real time by the play rate
    local at = math.min(atAnimTime / rate, glen)
    local stopAt = (stopAnimTime > 0 and stopAnimTime / rate < glen) and stopAnimTime / rate or 0
    G.busyUntil = os.clock() + (stopAt > 0 and stopAt + S.stopBlend or glen)
    later(at, function() toast(action()) end)
    if stopAt > 0 then later(stopAt, function() stopGesture(seq) end) end
    return nil
end

---------------------------------------------------------------- vanilla comparison (Logging only)

-- How the game's own blood consumables refill the bar, to copy them exactly:
-- 1. hooks on BloodBarComponent:RestoreAmount / RestorePercentage log every call made through
--    reflection (ours and, if they go this way, the vanilla vials'), with the damage flag;
-- 2. once, the modifiers of the vanilla blood consumable effects (class default objects).
-- Hooks are registered 5 s after the first world entry (not at mod load).
local VANILLA_GES = {
    "GE_Consumable_Blood_MicroRestore_C", "GE_Consumable_Blood_SmallRestore_C",
    "GE_Consumable_Blood_MediumRestore_C", "GE_Consumable_Blood_BigRestore_C",
    "GE_Consumable_Blood_HugeRestore_C", "GE_HumanBlood_C", "GE_AnimalBlood_C",
    "GE_ItemAdditionalVampireRestore_C", "GE_PostDrinkBlood_Human_C", "GE_PostDrinkBlood_Animal_C",
    "GE_Consumable_Mutation_SmallIncrease_C", "GE_Consumable_Mutation_MediumIncrease_C",
    "GE_Consumable_Mutation_BigIncrease_C", "GE_DepleteMutationCharges_C",
}
local D = { hooked = false, dumped = false, worldSeq = 0 }

local function barState()
    local p = playerPawn()
    local b = p and bloodBar(p)
    if not b then return "bar ?" end
    local blood, len, perm = readBar(b)
    local segs = num(try(function() return b:GetSegmentCount() end))
    return string.format("blood %s of %s, perm damage %s, segments %s", tostring(blood), tostring(len),
        tostring(perm), tostring(segs))
end

local function hookRestore(fname)
    local path = "/Script/DogwoodStats.BloodBarComponent:" .. fname
    local ok, err = pcall(RegisterHook, path, function(ctx, amount, ignore)
        pcall(function()
            local a, i = num(amount), ignore
            if type(i) == "userdata" then i = try(function() return i:get() end) end
            local before = barState()
            log("%s(%s, ignorePermDamage %s) called; before: %s", fname, tostring(a), tostring(i), before)
            later(0.5, function() log("  %s 0.5 s later: %s", fname, barState()) end)
        end)
    end)
    log("hook BloodBarComponent:%s: %s", fname, ok and "ok" or tostring(err))
end

local function describeModifier(m)
    m = (type(m) == "userdata" and try(function() return m:get() end)) or m
    local attr = try(function() return m.Attribute.AttributeName:ToString() end) or "?"
    local op = num(try(function() return m.ModifierOp end))
    local mag = try(function() return m.ModifierMagnitude end)
    local calc = mag and num(try(function() return mag.MagnitudeCalculationType end))
    local value = mag and num(try(function() return mag.ScalableFloatMagnitude.Value end))
    local caller = mag and try(function() return mag.SetByCallerMagnitude.DataTag.TagName:ToString() end)
    return string.format("%s op %s calc %s value %s%s", attr, tostring(op), tostring(calc), tostring(value),
        (caller and caller ~= "None" and caller ~= "") and (" setbycaller " .. caller) or "")
end

local function dumpVanilla()
    D.dumped = true
    local t0 = os.clock()
    for _, cname in ipairs(VANILLA_GES) do
        local cdo = nil
        for _, o in ipairs(FindAllOf(cname) or {}) do
            if (fullName(o) or ""):find("Default__", 1, true) then cdo = o break end
        end
        if not cdo then
            log("vanilla %s: not loaded", cname)
        else
            local parts = {}
            pcall(function()
                cdo.Modifiers:ForEach(function(_, m) parts[#parts + 1] = describeModifier(m) end)
            end)
            local dur = num(try(function() return cdo.DurationPolicy end))
            local durMag = try(function() return num(cdo.DurationMagnitude.ScalableFloatMagnitude.Value) end)
            local execs = 0
            pcall(function() cdo.Executions:ForEach(function() execs = execs + 1 end) end)
            log("vanilla %s: duration policy %s (%s s), %d execution(s), modifiers: %s", cname,
                tostring(dur), tostring(durMag), execs,
                #parts > 0 and table.concat(parts, "; ") or "none")
            log("  path %s", tostring(fullName(cdo)))
        end
    end
    log("vanilla dump done (%.0f ms)", (os.clock() - t0) * 1000)
end

-- Mutation ("corruption", guess) watch: logs Coen's mutation charges / level and the blood bar whenever they
-- change, read twice a second on the game thread (property reads + 2 UFunction calls). Logging only.
-- (1.4.0: the vanilla effect dump is no longer run; it found nothing and hitched ~0.5 s.)
local W = { started = false, last = nil, dumpedAfterChange = false }

local function mutationState()
    local p = playerPawn()
    if not p then return nil end
    local dev = subsystem(p, DEV_CLASS, false)
    local charges = dev and num(try(function() return dev:GetCurrentMutationCharges() end))
    local level = dev and num(try(function() return dev:GetCurrentMutationLevel() end))
    local b = bloodBar(p)
    local blood, len, perm = nil, nil, nil
    if b then blood, len, perm = readBar(b) end
    local set = b and try(function() return ref(b.VampireAttributeSet) end)
    local charged = set and num(try(function() return set.MutationCharged.CurrentValue end))
    local mlevel = set and num(try(function() return set.MutationLevel.CurrentValue end))
    return { charges = charges, level = level, charged = charged, mlevel = mlevel, blood = blood, len = len,
        perm = perm, dev = dev ~= nil }
end

local function fmtN(v) return v and string.format("%.2f", v) or "?" end

local function watchTick()
    local s = mutationState()
    if not s then return end
    local l = W.last
    W.last = s
    if not l then
        log("mutation watch start: charges %s level %s (attribute set: charged %s level %s), blood %s of %s, perm %s%s",
            fmtN(s.charges), fmtN(s.level), fmtN(s.charged), fmtN(s.mlevel), fmtN(s.blood), fmtN(s.len), fmtN(s.perm),
            s.dev and "" or ", no CharacterDevelopmentSubsystem")
        return
    end
    local mutChanged = s.charges ~= l.charges or s.level ~= l.level or s.charged ~= l.charged or s.mlevel ~= l.mlevel
    local bloodChanged = s.blood and l.blood and math.abs(s.blood - l.blood) >= 1
    local permChanged = s.perm ~= l.perm
    if not (mutChanged or bloodChanged or permChanged) then return end
    log("change: mutation charges %s -> %s, level %s -> %s (set: charged %s -> %s, level %s -> %s); blood %s -> %s of %s, perm %s -> %s",
        fmtN(l.charges), fmtN(s.charges), fmtN(l.level), fmtN(s.level), fmtN(l.charged), fmtN(s.charged),
        fmtN(l.mlevel), fmtN(s.mlevel), fmtN(l.blood), fmtN(s.blood), fmtN(s.len), fmtN(l.perm), fmtN(s.perm))
end

local function startWatch()
    if W.started then return end
    W.started = true
    LoopAsync(500, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(watchTick)
            if not ok then log("watch error: %s", tostring(err)) end
        end)
        return false
    end)
    log("mutation watch running (0.5 s)")
end

local function onPlayer()
    if not S.logging then return end
    D.worldSeq = D.worldSeq + 1
    local seq = D.worldSeq
    later(5, function()
        if seq ~= D.worldSeq or D.hooked then return end
        D.hooked = true
        hookRestore("RestoreAmount")
        hookRestore("RestorePercentage")
        log("now: %s", barState())
        startWatch()
    end)
end

---------------------------------------------------------------- keys

local function busy(what)
    if os.clock() < G.busyUntil then
        log("%s key ignored: animation still playing", what)
        return true
    end
    return false
end

-- Drink key. Drinks one dose: the preferred vial if it holds blood, else the other one. A full bar
-- keeps the dose. No body search here.
local function drinkKey()
    applyConfig()
    if busy("drink") then return end
    local pawn = playerPawn()
    if not pawn then log("drink: no player character") return end
    local order = S.drinkFirst == ANIMAL and { ANIMAL, HUMAN } or { HUMAN, ANIMAL }
    local cat = nil
    for _, c in ipairs(order) do
        if S[SLOT[c]] > 0 then cat = c break end
    end
    local msg
    if not cat then
        msg = "Your blood vials are empty"
    else
        local bar, via = bloodBar(pawn)
        local before, len, perm
        if bar then before, len, perm = readBar(bar) end
        if not bar then
            log("drink: %s", via)
            msg = "You can't drink now"
        elseif before and len and len > 0 and before >= len - (S.healDamage and 0 or (perm or 0)) - 0.01 then
            log("drink: bar full (blood %.2f of %.2f, perm damage %s), dose kept", before, len, tostring(perm))
            msg = (not S.healDamage and (perm or 0) > 0.5) and "Your blood is full, the rest is permanent damage"
                or "Your blood is already full"
        elseif not S.gesture then
            msg = applyDose(cat)
        else
            msg = withGesture(pawn, DRINK_ANIMS[S.animIndex] or DRINK_ANIMS[5], S.animSlot, S.animTime, 1.0,
                S.drinkAt, S.stopAt, function() return applyDose(cat) end, "drink")
        end
    end
    log("drink key: vials human %d, animal %d -> \"%s\"", S.human, S.animal, msg or "message at the sip")
    if msg then toast(msg) end
end

-- Extract key. Nearest dead or unconscious body within Range with extractions left fills the vial.
local function extractKey()
    applyConfig()
    if busy("extract") then return end
    local t0 = os.clock()
    local pawn = playerPawn()
    local px, py, pz
    if pawn then px, py, pz = locOf(pawn) end
    if not px then
        log("extract: no player character")
        return
    end

    local found, notes, hasCreatures = survey(pawn, px, py, pz)
    local target, drained = nil, nil
    for _, c in ipairs(found) do
        if c.dist and c.dist <= S.range and c.body then
            if (S.drained[c.key] or 0) < S.maxExtract then
                if not target then target = c end
            elseif not drained then
                drained = c
            end
        end
    end

    local msg
    if target then
        msg = fillRefusal(target)
        if not msg then
            if S.extractAnim > 0 and EXTRACT_ANIMS[S.extractAnim] then
                msg = withGesture(pawn, EXTRACT_ANIMS[S.extractAnim], S.extractSlot, S.extractAnimTime,
                    S.extractSpeed, S.fillAt, S.extractStopAt, function() return fill(target) end, "extract")
            else
                msg = fill(target)
            end
        end
    elseif drained then
        msg = "The blood has gone cold"
    else
        msg = "No body close enough"
    end

    if S.logging then
        log("extract key: range %d cm, %s%s; %.1f ms", S.range, notes,
            hasCreatures and "" or ", no creature subsystem", (os.clock() - t0) * 1000)
        for i, c in ipairs(found) do
            if i > MAX_LOGGED then
                log("  ... %d more", #found - MAX_LOGGED)
                break
            end
            log("  %s%s", c == target and "> " or "", line(c))
        end
        log("  vials: human %d, animal %d (max %d drinks) -> \"%s\"", S.human, S.animal, S.maxDoses,
            msg or "message at the fill")
    end
    if msg then toast(msg) end
end

-- Test key (temporary): each press plays the next extraction candidate. Nothing is filled.
local function testKey()
    applyConfig()
    if busy("test") then return end
    local pawn = playerPawn()
    if not pawn then return end
    G.test = G.test % #EXTRACT_ANIMS + 1
    local path = EXTRACT_ANIMS[G.test]
    local short = (path:match("%.([%w_]+)$") or path):gsub("^Male_Human_Community_", "")
    local len, why = playGesture(pawn, path, S.extractSlot, 0)
    local msg
    if not len then
        msg = string.format("Extract test %d (%s): not played, %s", G.test, short, tostring(why))
    else
        G.busyUntil = os.clock() + len
        msg = string.format("Extract test %d of %d: %s", G.test, #EXTRACT_ANIMS, short)
    end
    log("test key: %s", msg)
    toast(msg)
end

---------------------------------------------------------------- startup

applyConfig()
loadState()
applyConfig()

local function bind(cfgKey, default, fn, label)
    local name = (readConfig()[cfgKey] or default):upper()
    if name == "" then return "none" end
    local k = Key[name]
    if not k then
        say("unknown %s '%s', key disabled", cfgKey, name)
        return "none"
    end
    RegisterKeyBind(k, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then say("%s error: %s", label, tostring(err)) end
        end)
    end)
    return name
end

local okP, errP = pcall(NotifyOnNewObject, "/Script/Dawnwalker.DawnwalkerPlayerCharacter", function() pcall(onPlayer) end)
if not okP then say("player watch unavailable: %s", tostring(errP)) end

local drinkName = bind("drinkkey", "OEM_FOUR", drinkKey, "drink")
local extractName = bind("extractkey", "OEM_SIX", extractKey, "extract")
local testName = bind("animtestkey", "", testKey, "test")

say("%s loaded: drink %s, extract %s, anim test %s; range %d cm, max %d drinks, human %d, animal %d, restore %d/%d%%, drink anim %s, extract anim %s, scan %s, logging %s%s",
    VERSION, drinkName, extractName, testName, S.range, S.maxDoses, S.human, S.animal, S.humanRestore, S.animalRestore,
    S.gesture and tostring(S.animIndex) or "off", S.extractAnim > 0 and tostring(S.extractAnim) or "off",
    S.scan and "on" or "off", S.logging and "on" or "off", DIR and "" or ", config.ini not found (defaults, vials not saved)")
