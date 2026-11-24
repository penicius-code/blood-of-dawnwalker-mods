-- Blood Wash 0.8.2
--   0.8.2: Numpad 3 = shoulder brush (dialogue breaker_04, picked in testing); old hands-together gesture = menu toggle BodyHands.
--          Speed sliders BodyRate / WipeRate / CrouchRate (+ TestRate); ClearAt/StopAt are animation seconds, scaled by speed.
--          MouthBrush = 1: Numpad 6 plays the shoulder brush too (mouth blood goes at BrushClearAt)
--          TestKey (audition, empty = off): each press plays the next TestN entry, cleans nothing
--   0.8.1: bite blood no longer counted as a second rise 1 s later; no restores in the last 2 s of the lifetime
--          (10 s test: bite blood lasted 20 s through one restore at 9 s)
--   0.8.0: separate MouthSeconds / BodySeconds (sliders); Keep mouth blood only during the blood's lifetime (it fought the
--          game's own fade and kept short times from ever ending); Voracious Bite leaves mouth blood (BiteBlood)
--   0.7.2: MouthGesture toggle (Numpad 6 instant when off); CrouchWipe picker 0 off / 1 crouching gesture / 2 instant
--   0.7.1: PermanentSeconds is the real fade time (written both ways, slow fades allowed); default 3600
--   0.7.0: PermanentBlood (menu, default on): mouth and body blood never fade or clear on their own
--   0.6.3: body gesture ends when the body blood goes (BodyStopAt 1.0)
--   0.6.2: WipeStopAt / BodyStopAt cut the gesture short (face rub stops at 2.1 s, 0.4 s blend back)
--   0.6.1: Numpad 9 = crouching mouth wipe (menu toggle CrouchWipe, default on); Numpad 6 always standing
--   0.6.0: Numpad 6 = mouth wipe with gesture (instant mouth key and Numpad 9 removed); water gate removed
--   0.5.1: DialogueClearsMouth (menu): mouth blood wiped for good when a dialogue/cutscene starts
--   0.5.0: gestures on Coen's own skeleton: Numpad 9 = face rub (standing, or crouching via menu),
--          Numpad 3 = hands-together gesture before the body blood goes (menu toggle); slot search and test code trimmed
--   0.4.x: gesture research (dialogue gesture failed: its arms do not reach Coen's skeleton; slots and loader found)
--   0.4.0: Numpad 9 animated mouth wipe; scan removed
--   0.3.0: Keep mouth blood (sticky: restores it after sudden resets, e.g. wolf form), diagnostics hooks
--   0.2.0: temporary Numpad 9 animation scan
-- Numpad 3 washes the combat blood off Coen's body and clothes (with a short gesture by default).
-- Numpad 6 wipes the feeding blood off his mouth with a gesture: Coen rubs his mouth, the blood goes mid-gesture.
-- Numpad 9 does the same crouching (whole body; standing version while moving).
-- Where no gesture can play (dialogue, cutscene, wolf form) the blood goes at once.
--
-- Body blood is the game's skinned decal system (DawnwalkerCharacterBase.SkinnedDecalSampler);
-- ClearAllDecals() removes it (verified with BloodProbe, 2026-09-29).
-- Mouth blood is the BloodDrink character material param (ECharacterMaterialParamType 0);
-- CharacterMaterialParamsLibrary:ForceClearCharacterMaterialParam clears it (verified 2026-09-29).
-- The value lives in a custom primitive data slot (PrimitiveDataIndex of BloodDrink) on Coen's meshes.
--
-- Keep mouth blood: one LoopAsync queues a game-thread check every 1 s. It reads the slot on
-- Coen's meshes, remembers the highest value, follows slow fading, and writes the value back
-- when it drops suddenly. Only the GameEngine singleton and classes are kept between ticks.

local VERSION = "0.8.2"
local TAG = "[BloodWash] "
local BLOOD_DRINK = 0
local TICK_S = 1.0
local SETTLE_S = 2.0
-- NPC animations on SK_Coen_IK_Skeleton (Coen's own skeleton), picked in the 0.4.3 test.
local COMMUNITY = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/"
local WIPE_ANIM = COMMUNITY .. "Male_Human_Community_Washing_Face/Male_Human_Community_Washing_Face_Low_Container_Loop_04.Male_Human_Community_Washing_Face_Low_Container_Loop_04"
-- Shoulder brush (picked 2026-10-13, seen in sq710): a dialogue breaker; plays fine on Coen in Upperbody_Override.
local BRUSH_ANIM = "/Game/_Dawnwalker/Animation/Dialogues/Male/Stand/Neutral/Breakers/m_stand_neutral_breaker_04.m_stand_neutral_breaker_04"
local BODY_ANIM = COMMUNITY .. "Male_Human_Community_Background_Standing/Male_Human_Community_Coughing_Loop_03.Male_Human_Community_Coughing_Loop_03"

local S = {
    logging = false,
    sticky = true,
    drop = 0.1, -- a fall bigger than this within one tick counts as a reset, not fading
    dialogueClearsMouth = false,
    permanent = true,
    mouthSeconds = 1200,
    bodySeconds = 1200,
    biteBlood = true,
    bodyGesture = true,
    mouthGesture = true,
    bodyAnim = BODY_ANIM,
    bodySlot = "Upperbody_Override",
    bodyClearAt = 1.0,
    wipeAnim = WIPE_ANIM,
    wipeSlot = "Upperbody_Override",
    crouchWipe = 1, -- Numpad 9: 0 off, 1 crouching gesture, 2 instant wipe
    wipeCrouchSlot = "DefaultSlot",
    clearAt = 1.5,
    wipeStopAt = 2.1, -- test video: the face rub is done 2.1 s in, the animation runs 3.67 s
    bodyStopAt = 1.0, -- test video: blood goes 1.27 s in (1.0 + loop delay); the gesture ends with it
    stopBlend = 0.4,
    bodyRate = 1.0,
    wipeRate = 1.0,
    crouchRate = 1.0,
    bodyHands = false,
    mouthBrush = false,
    brushClearAt = 2.5,
    brushStopAt = 0,
    testRate = 1.0,
    cycle = false,
    tests = {},
}

---------------------------------------------------------------- config

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function findFile(rel)
    for _, prefix in ipairs({ "ue4ss/Mods/", "Mods/" }) do
        local f = io.open(prefix .. rel, "r")
        if f then f:close() return prefix .. rel end
    end
    return nil
end

local CONFIG = findFile("BloodWash/config.ini")

local function readConfig()
    local cfg = {}
    if not CONFIG then return cfg end
    local f = io.open(CONFIG, "r")
    if not f then return cfg end
    for line in f:lines() do
        line = trim(line:gsub(";.*$", ""))
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        if k then cfg[k:lower()] = trim(v) end
    end
    f:close()
    return cfg
end

local function text(v, default)
    if v and v ~= "" then return v end
    return default
end

local function applyConfig()
    local c = readConfig()
    S.logging = c.logging == "1"
    S.sticky = c.keepmouthblood ~= "0"
    S.drop = tonumber(c.resetthreshold or "") or 0.1
    S.dialogueClearsMouth = c.dialogueclearsmouth == "1"
    S.permanent = c.permanentblood ~= "0"
    -- PermanentSeconds (0.7.x) is the fallback for both
    local legacy = tonumber(c.permanentseconds or "")
    S.mouthSeconds = tonumber(c.mouthseconds or "") or legacy or 1200
    S.bodySeconds = tonumber(c.bodyseconds or "") or legacy or 1200
    S.biteBlood = c.biteblood ~= "0"
    S.bodyGesture = c.bodygesture ~= "0"
    S.mouthGesture = c.mouthgesture ~= "0"
    S.bodyAnim = text(c.bodyanim, BODY_ANIM)
    S.brushAnim = c.brushanim
    S.bodySlot = text(c.bodyslot, "Upperbody_Override")
    S.bodyClearAt = tonumber(c.bodyclearat or "") or 1.0
    S.wipeAnim = text(c.wipeanim, WIPE_ANIM)
    S.wipeSlot = text(c.wipeslot, "Upperbody_Override")
    S.crouchWipe = tonumber(c.crouchwipe or "") or 1
    S.wipeCrouchSlot = text(c.wipecrouchslot, "DefaultSlot")
    S.clearAt = tonumber(c.wipeclearat or "") or 1.5
    S.wipeStopAt = tonumber(c.wipestopat or "") or 2.1
    S.bodyStopAt = tonumber(c.bodystopat or "") or 1.0
    S.stopBlend = tonumber(c.stopblend or "") or 0.4
    S.bodyRate = math.max(tonumber(c.bodyrate or "") or 1.0, 0.1)
    S.testRate = math.max(tonumber(c.testrate or "") or 1.0, 0.1)
    S.wipeRate = math.max(tonumber(c.wiperate or "") or 1.0, 0.1)
    S.crouchRate = math.max(tonumber(c.crouchrate or "") or 1.0, 0.1)
    S.bodyHands = c.bodyhands == "1"
    S.mouthBrush = c.mouthbrush == "1"
    S.brushClearAt = tonumber(c.brushclearat or "") or 2.5
    S.brushStopAt = tonumber(c.brushstopat or "") or 0
    -- research: WipeCycle = 1 makes each Numpad 6 press play the next TestN entry ("Slot | /Game/path")
    S.cycle = c.wipecycle == "1"
    S.tests = {}
    for i = 1, 16 do
        local slot, path = (c["test" .. i] or ""):match("^(.-)%s*|%s*(/.+)$")
        if slot and slot ~= "" then S.tests[#S.tests + 1] = { slot = slot, path = path, n = i } end
    end
end

---------------------------------------------------------------- logging

local function log(fmt, ...)
    if not S.logging then return end
    print(TAG .. string.format(fmt, ...) .. "\n")
end

---------------------------------------------------------------- helpers

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v == true
end

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function unwrap(o)
    if valid(o) then return o end
    local v = try(function() return o:get() end)
    if valid(v) then return v end
    return nil
end

local function nameOf(o)
    return try(function() return o:GetFName():ToString() end) or "?"
end

-- GameEngine is an engine singleton, so it may be kept; everything else is re-resolved.
local engine, engineRetryAt = nil, 0
local function gameEngine()
    if valid(engine) then return engine end
    engine = nil
    local now = os.clock()
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 5
    for _, e in ipairs(FindAllOf("GameEngine") or {}) do
        if valid(e) then engine = e; break end
    end
    return engine
end

-- Through the engine (property reads only); FindFirstOf (~40 ms) only as a fallback.
local function getPawn()
    local e = gameEngine()
    local p = e and try(function()
        local lp = unwrap(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and unwrap(lp.PlayerController)
        return pc and unwrap(pc.Pawn)
    end)
    if valid(p) then return p end
    local pc = FindFirstOf("PlayerController")
    if not valid(pc) then return nil end
    p = try(function() return pc.Pawn end)
    if valid(p) then return p end
    return nil
end

local function each(arr, fn)
    if type(arr) == "table" then
        for _, e in ipairs(arr) do fn(e) end
        return
    end
    pcall(function() arr:ForEach(function(_, e) fn(e) end) end)
end

---------------------------------------------------------------- mouth blood slot

-- Slot index of BloodDrink, read once from DA_CharacterMaterialParamsConfig (0 in the 2026-09-29 log).
local slot, configPath = nil, nil
local function mouthSlot()
    if slot then return slot end
    local cfg = FindFirstOf("CharacterMaterialParamsConfig")
    if not valid(cfg) then return nil end
    -- remembered as a string only; PermanentBlood re-finds the asset by path (StaticFindObject, ~2 ms)
    configPath = try(function() return cfg:GetFullName():match("^%S+%s+(.+)$") end)
    pcall(function()
        cfg.ParamsConfig:ForEach(function(k, v)
            if tonumber(tostring(k:get())) == BLOOD_DRINK then slot = v:get().PrimitiveDataIndex end
        end)
    end)
    if type(slot) ~= "number" then slot = nil end
    if slot then log("mouth blood slot = %d", slot) end
    return slot
end

local skinnedClass = nil
local function meshesOf(pawn)
    local out, seen = {}, {}
    local function add(m)
        m = unwrap(m)
        if not m then return end
        local a = try(function() return m:GetAddress() end)
        if a and not seen[a] then seen[a] = true; out[#out + 1] = m end
    end
    if not valid(skinnedClass) then
        skinnedClass = try(function() return StaticFindObject("/Script/Engine.SkinnedMeshComponent") end)
    end
    if valid(skinnedClass) then
        each(try(function() return pawn:K2_GetComponentsByClass(skinnedClass) end), add)
    end
    if #out == 0 then
        add(try(function() return pawn.Mesh end))
        each(try(function() return pawn.SkinnedDecalSampler.RenderMeshes end), add)
    end
    return out
end

local function cpdAt(m, idx)
    local data = try(function() return m.CustomPrimitiveDataInternal.Data end)
    if not data then return nil end
    local n = try(function() return data:GetArrayNum() end)
    if type(n) ~= "number" or n <= idx then return nil end
    local v = try(function() return data[idx + 1] end)
    if type(v) == "userdata" then v = try(function() return v:get() end) end
    if type(v) == "number" then return v end
    return nil
end

-- Highest mouth value over Coen's meshes, and the names of the meshes that carry it.
local function readMouth(pawn, idx)
    local best, holders, count = 0, {}, 0
    for _, m in ipairs(meshesOf(pawn)) do
        count = count + 1
        local v = cpdAt(m, idx)
        if v and v > 0.01 then
            holders[#holders + 1] = try(function() return m:GetFName():ToString() end) or "?"
            if v > best then best = v end
        end
    end
    return best, holders, count
end

local function writeMouth(pawn, idx, value, names)
    local want, n = {}, 0
    for _, nm in ipairs(names or {}) do want[nm] = true end
    for _, m in ipairs(meshesOf(pawn)) do
        local nm = try(function() return m:GetFName():ToString() end) or "?"
        if want[nm] then
            if pcall(function() m:SetCustomPrimitiveDataFloat(idx, value) end) then n = n + 1 end
        end
    end
    return n
end

local function library()
    local lib = try(function() return StaticFindObject("/Script/Dawnwalker.Default__CharacterMaterialParamsLibrary") end)
    if valid(lib) then return lib end
    return nil
end

---------------------------------------------------------------- actions

local function washBody()
    applyConfig()
    local pawn = getPawn()
    if not pawn then return end
    local sampler = try(function() return pawn.SkinnedDecalSampler end)
    if not valid(sampler) then log("body: no SkinnedDecalSampler on the player") return end
    local ok, err = pcall(function() sampler:ClearAllDecals() end)
    log("body: ClearAllDecals %s", ok and "done" or ("FAILED " .. tostring(err)))
end

-- Sticky state (numbers and strings only): remembered mouth value and the meshes that carried it.
local M = { value = 0, holders = {}, pending = nil, worldAddr = nil, pawnAddr = nil, settleAt = 0, wolf = nil, form = nil, cine = nil }

local function wipeMouth()
    applyConfig()
    local pawn = getPawn()
    if not pawn then return end
    local idx = mouthSlot()
    local before = idx and readMouth(pawn, idx) or nil
    M.value, M.pending = 0, nil -- stop keeping it

    local how = nil
    local lib = library()
    if valid(lib) then
        local ok, err = pcall(function() lib:ForceClearCharacterMaterialParam(pawn, BLOOD_DRINK) end)
        how = ok and "library ForceClearCharacterMaterialParam" or nil
        if not ok then log("mouth: library call failed: %s", tostring(err)) end
    end
    if not how then
        -- fallback: the component itself
        local comp = valid(lib) and try(function() return lib:FindMaterialParamsComponent(pawn) end)
        if valid(comp) then
            local ok, err = pcall(function() comp:ForceClearParam(BLOOD_DRINK) end)
            how = ok and "component ForceClearParam" or nil
            if not ok then log("mouth: component call failed: %s", tostring(err)) end
        end
    end

    -- A value we wrote back ourselves may not be known to the game's component; zero those slots too.
    local zeroed = 0
    if idx and #M.holders > 0 then zeroed = writeMouth(pawn, idx, 0, M.holders) end
    M.holders = {}
    log("mouth: %s | before %s | after %s | %d slot(s) zeroed directly", how or "NOT cleared",
        tostring(before), tostring(idx and readMouth(pawn, idx) or nil), zeroed)
end

---------------------------------------------------------------- keep mouth blood (loop)

local function worldAndPawn()
    local e = gameEngine()
    if not e then return nil, nil end
    local world = try(function() return e.GameViewport.World end)
    local pawn = try(function()
        local lp = unwrap(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and unwrap(lp.PlayerController)
        return pc and unwrap(pc.Pawn)
    end)
    return world, pawn
end

local function contextOf(pawn)
    local form = try(function() return pawn.Form end)
    local wolf = try(function() return pawn:IsInWolfForm() end)
    local cine = try(function() return pawn.bCinematicMode end)
    return string.format("form=%s wolf=%s cinematic=%s", tostring(form), tostring(wolf), tostring(cine)), wolf == true
end

-- PermanentBlood ("Long-lasting blood"): checked every PERM_S seconds (and right after a rise or leaving wolf form),
-- written when the value differs. The game resets the mouth value to 30 about once a minute and on wolf form.
-- Mouth: BloodDrink entry of DA_CharacterMaterialParamsConfig: FadeOutTime = MouthSeconds, dialogue/time-of-day wipes off.
-- Body: DecalFade (seconds, verified 2026-10-03) = BodySeconds on every material of Coen's decal sampler (body and
-- garments). The sampler builds its materials on the first hit; wolf form resets some of them to 0.
local PERM_S = 5
local P = { nextAt = 0, mouthLogged = false }

local function enforcePermanent(pawn)
    local target = S.mouthSeconds
    local cfg = configPath and try(function() return StaticFindObject(configPath) end)
    if valid(cfg) then
        pcall(function()
            cfg.ParamsConfig:ForEach(function(k, v)
                if tonumber(tostring(k:get())) ~= BLOOD_DRINK then return end
                local e = v:get()
                local fade = e.FadeOutTime
                if type(fade) == "number" and math.abs(fade - target) > 1 or e.bClearOnDialogueStarted or e.bClearOnDayTimeChanged then
                    e.FadeOutTime = target
                    e.bClearOnDialogueStarted = false
                    e.bClearOnDayTimeChanged = false
                    log("permanent: mouth FadeOutTime %s -> %s, dialogue/time-of-day wipes off", tostring(fade), tostring(e.FadeOutTime))
                end
            end)
        end)
    end
    local sampler = try(function() return pawn.SkinnedDecalSampler end)
    if not valid(sampler) then return end
    target = S.bodySeconds
    local name = FName("DecalFade")
    local total, changed, before = 0, 0, nil
    each(try(function() return sampler.Materials end), function(e)
        local mid = unwrap(e)
        if not mid then return end
        total = total + 1
        local cur = try(function() return mid:K2_GetScalarParameterValue(name) end)
        if type(cur) == "number" and math.abs(cur - target) > 1 then
            before = before or cur
            if pcall(function() mid:SetScalarParameterValue(name, target) end) then changed = changed + 1 end
        end
    end)
    if changed > 0 then log("permanent: body DecalFade %s -> %s on %d of %d materials", tostring(before), tostring(target), changed, total) end
end

-- FadeOutTime the asset holds right now (lifetime of the mouth blood when Long-lasting blood is off).
local function assetFadeTime()
    local cfg = configPath and try(function() return StaticFindObject(configPath) end)
    local t = nil
    if valid(cfg) then
        pcall(function()
            cfg.ParamsConfig:ForEach(function(k, v)
                if tonumber(tostring(k:get())) == BLOOD_DRINK then t = v:get().FadeOutTime end
            end)
        end)
    end
    return type(t) == "number" and t or 30
end

-- Voracious Bite drinks blood but never raises BloodDrink. A drink start (hook or polled victim) schedules a
-- check 1.5 s later: if the mouth did not rise by then, BloodWash adds the blood. Feeds raise it themselves.
-- Only numbers/strings are kept; the subsystem class is a class (may be cached).
local B = { checkAt = nil, base = 0, src = nil, hooked = false, hookOk = false, victim = nil, subClass = nil }

local function scheduleBite(src)
    if B.checkAt then return end
    B.checkAt, B.base, B.src = os.clock() + 1.5, M.value, src
end

local function hookBite()
    B.hooked = true
    -- Only "started" (drinking begins): "initialized" fires at the start of a feed's struggle, before any blood.
    for _, fn in ipairs({ "NotifyBloodDrinkingStarted" }) do
        local ok, err = pcall(RegisterHook, "/Script/Dawnwalker.DrinkBloodSubsystem:" .. fn, function()
            scheduleBite(fn)
        end)
        B.hookOk = B.hookOk or ok
        log("bite: hook %s %s", fn, ok and "ok" or ("FAILED " .. tostring(err)))
    end
end

-- Backup only when the hook could not register: the subsystem's current victim, polled once per keep tick.
-- (A feed may report its victim during the struggle, so this can add the blood a little early there.)
local function pollVictim(pawn)
    if not valid(B.subClass) then
        B.subClass = try(function() return StaticFindObject("/Script/Dawnwalker.DrinkBloodSubsystem") end)
    end
    local lib = try(function() return StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary") end)
    if not valid(B.subClass) or not valid(lib) then return end
    local sub = try(function() return lib:GetGameInstanceSubsystem(pawn, B.subClass) end)
    local victim = valid(sub) and try(function() return sub:GetCurrentlyDrinkedVictim() end)
    local addr = valid(victim) and try(function() return victim:GetAddress() end) or nil
    if addr and addr ~= B.victim then scheduleBite("victim poll") end
    B.victim = addr
end

local function keepTick()
    applyConfig()
    local world, pawn = worldAndPawn()
    if not valid(pawn) then return end
    local wa = try(function() return world:GetAddress() end)
    if wa ~= M.worldAddr then
        if M.worldAddr and M.value > 0 then log("keep: new world (load/travel), forgetting mouth blood") end
        M.worldAddr, M.value, M.holders, M.pending, M.riseAt = wa, 0, {}, nil, nil
        B.checkAt, B.victim = nil, nil
    end
    local pa = pawn:GetAddress()
    if pa ~= M.pawnAddr then
        M.pawnAddr, M.settleAt = pa, os.clock() + SETTLE_S
        P.nextAt = 0
        log("keep: player pawn changed (%s)", (try(function() return pawn:GetClass():GetFName():ToString() end) or "?"))
        return
    end
    if os.clock() < M.settleAt then return end
    local idx = mouthSlot()
    if not idx then return end
    if not B.hooked then hookBite() end

    local ctx, wolf = contextOf(pawn)
    if ctx ~= M.ctx then
        if M.ctx then log("keep: %s", ctx) end
        M.ctx = ctx
    end
    if M.wasWolf and not wolf then P.nextAt = 0 end -- wolf form reset part of the body materials
    M.wasWolf = wolf
    if wolf then return end -- human face not shown; restore once he is back
    if S.biteBlood and not B.hookOk then pcall(pollVictim, pawn) end

    if S.permanent and os.clock() >= P.nextAt then
        P.nextAt = os.clock() + PERM_S
        local okP, errP = pcall(enforcePermanent, pawn)
        if not okP then log("permanent error: %s", tostring(errP)) end
    end
    local keep = S.sticky or S.permanent
    local drop = S.drop

    local cur, holders, count = readMouth(pawn, idx)
    if M.meshCount ~= count then M.meshCount = count; log("keep: reading %d mesh(es)", count) end

    -- Optional: a dialogue/cutscene start wipes the mouth blood for good (LastingBlood keeps it otherwise).
    local cineNow = try(function() return pawn.bCinematicMode end) == true
    local started = cineNow and not M.wasCine
    M.wasCine = cineNow
    if started and S.dialogueClearsMouth and cur > 0.01 then
        log("keep: dialogue/cutscene started, wiping mouth blood (DialogueClearsMouth)")
        wipeMouth()
        return
    end

    -- Voracious Bite: add the blood if the drink did not raise it.
    if B.checkAt and os.clock() >= B.checkAt then
        B.checkAt = nil
        if not S.biteBlood then
            log("bite: off (BiteBlood = 0)")
        elseif cur <= B.base + 0.05 then
            local lib = library()
            if lib and pcall(function() lib:IncreaseCharacterMaterialParamValue(pawn, BLOOD_DRINK, 1.0) end) then
                -- counts as the rise; restoredAt keeps the next tick from counting our own blood again
                M.riseAt, M.restoredAt, P.nextAt = os.clock(), os.clock(), 0
                M.life = S.permanent and S.mouthSeconds or assetFadeTime()
                log("bite: added mouth blood (%s, mouth was %.2f)", tostring(B.src), cur)
            end
        else
            log("bite: game already added blood (%s, %.2f -> %.2f)", tostring(B.src), B.base, cur)
        end
    end

    if M.pending then
        -- last tick asked the game's component to restore; if that did not show, write the slots directly
        if cur < M.value - drop then
            local n = writeMouth(pawn, idx, M.value, M.holders)
            log("keep: component restore did not show (%.2f), wrote %.2f directly to %d mesh(es)", cur, M.value, n)
            if n == 0 then M.value, M.holders = cur, holders end -- nothing to write to: give up
        else
            log("keep: restored to %.2f through the game", cur)
        end
        M.pending = nil
        return
    end

    -- Keep only during the blood's lifetime, counted from the last real rise (feed/bite). A restore restarts the
    -- game's own fade, so restoring its natural end would loop forever (0.7.x bug, Nexus comment 2026-10-03).
    local now = os.clock()
    if cur > M.value + 0.01 then
        if now - (M.restoredAt or -1e9) > 3 then -- our own restore coming back is not a new rise
            M.riseAt, P.nextAt = now, 0
            M.life = S.permanent and S.mouthSeconds or assetFadeTime()
        end
        M.value, M.holders = cur, holders
        log("keep: mouth blood %.2f on %s", cur, table.concat(holders, ", "))
    elseif M.value > 0.01 and cur < M.value - drop then
        local age = now - (M.riseAt or -1e9)
        local life = S.permanent and S.mouthSeconds or (M.life or 30)
        -- margin: the rise is seen up to a tick late, and the game's fade may start just before the lifetime ends
        local restore = keep and age < life - math.min(2, life * 0.2)
        log("keep: mouth blood drop %.2f -> %.2f (%s, %.0f s after the rise, lifetime %.0f s)%s", M.value, cur, ctx,
            math.min(age, 99999), life, restore and ", restoring" or ", letting it fade")
        if restore then
            local lib = library()
            if lib then pcall(function() lib:IncreaseCharacterMaterialParamValue(pawn, BLOOD_DRINK, M.value) end) end
            M.pending, M.restoredAt = true, now
        else
            M.value, M.holders = cur, holders
        end
    elseif cur < M.value then
        M.value = cur -- slow fading (LastingBlood FadeOutTime): follow it
        if #holders > 0 then M.holders = holders end
    end
end

---------------------------------------------------------------- diagnostics hooks (Logging = 1 at startup)

local hookRate = {}
local function hookLog(path)
    local ok, err = pcall(RegisterHook, path, function(ctx, ...)
        if not S.logging then return end
        local now = os.clock()
        local r = hookRate[path]
        if not r or now - r.t > 10 then r = { t = now, n = 0 }; hookRate[path] = r end
        r.n = r.n + 1
        if r.n > 15 then return end
        local parts = {}
        for i, a in ipairs({ ... }) do
            local v = try(function() return a:get() end)
            if type(v) == "userdata" then
                v = try(function() return v:GetFName():ToString() end) or "struct"
            end
            parts[i] = tostring(v)
        end
        log("CALL %s (%s)", path:match("[^.]+$"), table.concat(parts, ", "))
    end)
    if not ok then log("hook %s FAILED: %s", path, tostring(err)) end
end

---------------------------------------------------------------- gestures

-- Coen plays an NPC animation made for his own skeleton (SK_Coen_IK_Skeleton) in a slot of his
-- AnimBP (ABP_Character_Main_C on CharacterMesh0), and the blood goes ClearAt seconds in.
-- Upperbody_Override = upper body only (works while walking); DefaultSlot = full body.
-- Dialogue gestures (metahuman_base_skel) do not work: their arm motion does not reach Coen's skeleton.
-- If no gesture can play, the action runs at once. Only strings and numbers are kept between steps.
local CHECK_S = 0.3
local STILL_SPEED = 10 -- cm/s; the crouching wipe (full-body slot) only plays below this
local G = { phase = nil, dueAt = nil, what = nil, slot = nil, clearAt = 1.0, stopAt = 0, startedAt = 0, busyUntil = 0, cycle = 0 }

local function mainAnim(pawn)
    local mesh = try(function() return pawn.Mesh end)
    local ai = valid(mesh) and try(function() return mesh:GetAnimInstance() end)
    if valid(ai) then return ai end
    return nil
end

-- StaticFindObject if loaded, otherwise a blocking load. UE4SS LoadAsset does nothing in this build;
-- MakeSoftObjectPath -> Conv_SoftObjPathToSoftObjRef -> LoadAsset_Blocking works (Headcovers loads icons that way).
-- Never pass a Lua table as the soft reference: that crashes natively.
local function loadAnim(path)
    local a = try(function() return StaticFindObject(path) end)
    if valid(a) then return a, "already loaded" end
    local ksl = try(function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if not valid(ksl) then return nil, "not loaded, KismetSystemLibrary not found" end
    local ok, res = pcall(function()
        return ksl:LoadAsset_Blocking(ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path)))
    end)
    if ok and valid(res) then return res, "loaded" end
    a = try(function() return StaticFindObject(path) end)
    if valid(a) then return a, "loaded, found after" end
    return nil, "could not load: " .. (ok and "nothing returned (path wrong?)" or tostring(res))
end

local function speedOf(pawn)
    local v = try(function() return pawn:GetVelocity() end)
    local x = v and try(function() return v.X end)
    local y = v and try(function() return v.Y end)
    if type(x) ~= "number" or type(y) ~= "number" then return 0 end
    return math.sqrt(x * x + y * y)
end

local function doAction(what)
    if what == "body" then washBody() elseif what == "mouth" then wipeMouth() end
end

local function gestureDone()
    G.phase, G.dueAt, G.what = nil, nil, nil
end

-- what = "body" (Numpad 3), "mouth" (Numpad 6 standing, Numpad 9 crouch = true) or "test" (TestKey audition, cleans nothing).
local function startGesture(what, crouch)
    applyConfig()
    if crouch and S.crouchWipe == 0 then log("mouth gesture: crouching wipe key is off (CrouchWipe = 0)") return end
    if what == "mouth" and ((crouch and S.crouchWipe == 2) or (not crouch and not S.mouthGesture)) then
        log("mouth: gesture off for this key, wiping at once")
        wipeMouth()
        return
    end
    if G.phase or os.clock() < G.busyUntil then log("%s gesture: previous one still playing, press ignored", what) return end
    local pawn = getPawn()
    if not pawn then return end

    local path, slotName, clearAt, stopAt, label = S.wipeAnim, S.wipeSlot, S.clearAt, S.wipeStopAt, ""
    local rate = S.wipeRate
    if what == "test" then
        if #S.tests == 0 then log("test key: no Test1..16 entries in config.ini") return end
        G.cycle = G.cycle + 1
        local t = S.tests[((G.cycle - 1) % #S.tests) + 1]
        path, slotName, clearAt, stopAt, rate = t.path, t.slot, 0, 0, S.testRate
        label = string.format(" (test press #%d = Test%d)", G.cycle, t.n)
    elseif what == "body" and S.bodyHands then
        path, slotName, clearAt, stopAt, rate = S.bodyAnim, S.bodySlot, S.bodyClearAt, S.bodyStopAt, S.bodyRate
    elseif what == "body" then
        path, slotName, clearAt, stopAt, rate = text(S.brushAnim, BRUSH_ANIM), S.bodySlot, S.brushClearAt, S.brushStopAt, S.bodyRate
    elseif S.cycle and #S.tests > 0 then
        G.cycle = G.cycle + 1
        local t = S.tests[((G.cycle - 1) % #S.tests) + 1]
        path, slotName, stopAt = t.path, t.slot, 0
        label = string.format(" (test press #%d = Test%d)", G.cycle, t.n)
    elseif not crouch and S.mouthBrush then
        path, slotName, clearAt, stopAt = text(S.brushAnim, BRUSH_ANIM), S.bodySlot, S.brushClearAt, S.brushStopAt
    elseif crouch then
        rate = S.crouchRate
        local speed = speedOf(pawn)
        if speed < STILL_SPEED then
            slotName = S.wipeCrouchSlot
        else
            log("mouth gesture: moving (%.0f cm/s), standing version instead of crouching", speed)
        end
    end

    local wolf = try(function() return pawn:IsInWolfForm() end) == true
    local cine = try(function() return pawn.bCinematicMode end) == true
    if wolf or cine then
        log("%s gesture: %s, cleaning without it", what, wolf and "wolf form" or "cinematic")
        doAction(what)
        return
    end
    local ai = mainAnim(pawn)
    local asset, how = loadAnim(path)
    local m = valid(ai) and asset and try(function()
        return ai:PlaySlotAnimationAsDynamicMontage(asset, FName(slotName), 0.25, 0.3, rate, 1, -1.0, 0.0)
    end)
    if not valid(m) then
        log("%s gesture: not played (%s), cleaning without it", what,
            not asset and ("animation " .. how) or (not valid(ai) and "no AnimInstance" or "mesh refused the animation"))
        doAction(what)
        return
    end
    local len = try(function() return asset:GetPlayLength() end)
    len = (type(len) == "number" and len or 2.5) / rate -- real seconds at this speed
    clearAt, stopAt = clearAt / rate, stopAt / rate -- config times are animation seconds
    if stopAt >= len then stopAt = 0 end
    G.what, G.slot, G.clearAt, G.stopAt, G.startedAt = what, slotName, clearAt, stopAt, os.clock()
    G.busyUntil = G.startedAt + (stopAt > 0 and stopAt + S.stopBlend or len)
    G.phase, G.dueAt = "check", G.startedAt + CHECK_S
    log("%s gesture: %s (%s, %.2f s%s) in slot %s%s", what, nameOf(asset), how, len,
        stopAt > 0 and string.format(", cut at %.2f s", stopAt) or "", slotName, label)
end

local function stopGesture(reason)
    local pawn = getPawn()
    local ai = pawn and mainAnim(pawn)
    if valid(ai) then pcall(function() ai:StopSlotAnimation(S.stopBlend, FName(G.slot)) end) end
    log("%s gesture: stopped at %.2f s (%s)", tostring(G.what), os.clock() - G.startedAt, reason)
end

-- check (slot active?) -> clear (blood goes at ClearAt) -> stop (cut at StopAt, if set).
local function gestureStep()
    local phase, what = G.phase, G.what
    G.dueAt = nil
    if phase == "check" then
        local pawn = getPawn()
        local ai = pawn and mainAnim(pawn)
        if valid(ai) and try(function() return ai:IsSlotActive(FName(G.slot)) end) == true then
            G.phase = "clear"
            G.dueAt = G.startedAt + math.max(G.clearAt, CHECK_S)
            log("%s gesture: slot %s active, cleaning at %.1f s", what, G.slot, G.clearAt)
            return
        end
        log("%s gesture: slot %s not active, cleaning now", what, G.slot)
        G.busyUntil = 0
        gestureDone()
        if what then doAction(what) end
    elseif phase == "clear" then
        if G.stopAt > 0 then
            G.phase = "stop"
            G.dueAt = G.startedAt + G.stopAt -- already past = next loop tick
        else
            gestureDone()
        end
        doAction(what)
    elseif phase == "stop" then
        stopGesture("StopAt")
        gestureDone()
    else
        gestureDone()
    end
end

-- A dialogue or cutscene that starts during a gesture stops it, so it cannot leak into the scene.
-- The pending clean still runs. Checked once per loop tick (1 s), only while a gesture plays.
local function stopForCinematic()
    if not G.slot or os.clock() >= G.busyUntil then return end
    local pawn = getPawn()
    if not pawn or try(function() return pawn.bCinematicMode end) ~= true then return end
    local ai = mainAnim(pawn)
    if valid(ai) then pcall(function() ai:StopSlotAnimation(0.2, FName(G.slot)) end) end
    G.busyUntil = 0
    log("gesture: dialogue/cutscene started, gesture stopped")
end

local function bodyKeyPressed()
    applyConfig()
    if S.bodyGesture then startGesture("body") else washBody() end
end

---------------------------------------------------------------- startup

applyConfig()
local cfg = readConfig()

local function bind(configKey, default, action, label)
    local keyName = (cfg[configKey] or default):upper()
    local key = keyName ~= "" and Key[keyName] or nil
    if key then
        RegisterKeyBind(key, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(action)
                if not ok then print(TAG .. label .. " error: " .. tostring(err) .. "\n") end
            end)
        end)
    elseif keyName ~= "" then
        print(TAG .. "unknown " .. label .. " key '" .. keyName .. "', disabled\n")
    end
    return key and keyName or "none"
end

local bodyKey = bind("bodykey", "NUM_THREE", bodyKeyPressed, "body")
local mouthKey = bind("mouthkey", "NUM_SIX", function() startGesture("mouth") end, "mouth")
local crouchKey = bind("crouchkey", "NUM_NINE", function() startGesture("mouth", true) end, "crouch wipe")
local testKey = bind("testkey", "", function() startGesture("test") end, "test")

if S.logging then
    for _, fn in ipairs({ "CharacterMaterialParamsComponent:RequestParamValue",
        "CharacterMaterialParamsComponent:ReleaseParamValue", "CharacterMaterialParamsComponent:IncreaseParamToValue",
        "CharacterMaterialParamsComponent:ForceClearParam", "CharacterMaterialParamsComponent:OnCinematicDialogueStarted",
        "CharacterMaterialParamsLibrary:RequestCharacterMaterialParamValue",
        "CharacterMaterialParamsLibrary:ReleaseCharacterMaterialParamValue",
        "CharacterMaterialParamsLibrary:IncreaseCharacterMaterialParamValue",
        "CharacterMaterialParamsLibrary:ForceClearCharacterMaterialParam" }) do
        hookLog("/Script/Dawnwalker." .. fn)
    end
end

-- One loop for keep-mouth-blood (every 1 s) and the gesture steps (when due).
-- The token stops an old loop after a hot reload.
local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("BloodWash.loop", TOKEN) end)
local nextTick, busy, busySince = 0, false, 0
LoopAsync(100, function()
    local owner = try(function() return ModRef:GetSharedVariable("BloodWash.loop") end)
    if owner ~= nil and owner ~= TOKEN then return true end
    local now = os.clock()
    if busy and now - busySince < 5 then return false end
    local doKeep = now >= nextTick
    local doGesture = G.dueAt ~= nil and now >= G.dueAt
    if not doKeep and not doGesture then return false end
    if doKeep then nextTick = now + TICK_S end
    busy, busySince = true, now
    local ok = pcall(ExecuteInGameThread, function()
        if doGesture then
            local okG, err = pcall(gestureStep)
            if not okG then log("gesture error: %s", tostring(err)); gestureDone() end
        end
        if doKeep then
            local okT, err = pcall(keepTick)
            if not okT then log("keep error: %s", tostring(err)) end
            pcall(stopForCinematic)
        end
        busy = false
    end)
    if not ok then busy = false end
    return false
end)

print(string.format("%s%s loaded (body %s%s, mouth %s, crouching mouth %s%s, keep mouth blood %s, long-lasting blood %s (mouth %s s, body %s s), bite blood %s, test key %s, logging %s)\n", TAG, VERSION,
    bodyKey, S.bodyGesture and " + gesture" or "", mouthKey, crouchKey, ({ [0] = " (off)", [2] = " (instant)" })[S.crouchWipe] or "",
    S.sticky and "on" or "off", S.permanent and "on" or "off", tostring(S.mouthSeconds), tostring(S.bodySeconds),
    S.biteBlood and "on" or "off", testKey, S.logging and "on" or "off"))
