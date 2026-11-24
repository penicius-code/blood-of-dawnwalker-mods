-- Wolf Form Beta 0.2.0
-- Coen stays a wolf after a wolf Haste, until the hotkey (P) or something
-- only the human body can do: combat, dialogue/cutscene, Shadowstep, climbing,
-- crouching, interacting. He then stays human until the hotkey.
--
-- The wolf belongs to the Haste ability (GA_FastTravelVampireSprint): its
-- Blueprint function SetupWolfForm(bool) swaps in the wolf mesh
-- (FastTravelSkeletal), and Haste drops it again as soon as Coen slows down.
-- Blueprint functions can't be hooked in this UE4SS build, so the mod calls the
-- same function itself once Haste has ended. Nothing else is written.
--
-- 0.1.2: everything runs on the game thread (LoopInGameThreadAfterFrames, like HitchWatch);
-- the hotkey only sets a flag. 0.1.1's LoopAsync -> ExecuteInGameThread at 20/s corrupted the
-- Lua state ("Ref was not function", then a UE4SS crash; guess, strong).

local VERSION = "0.2.0"
local POLL_MS = 50
local CONFIG_POLL_MS = 2000

local GA_CLASS = "GA_FastTravelVampireSprint_C"
local TAG_HASTE = "Traversal.VampireSprint"
local TAG_TRAVERSAL = "Traversal"
local TAG_SHADOWSTEP = "Traversal.Shadowstep"
local TAG_COMBAT = "Player.IsEffectivelyInCombat"
local FRONTEND_CDO = "/Script/DogwoodUI.Default__UIFrontend"
local HUMAN_MESH = "CharacterMesh0"

local HOLD_DELAY_S = 0.0      -- after Haste ends (0.1.0 waited 0.25 s; the ability hides the wolf on the tag drop tick)
local HOLD_WAIT_S = 1.0       -- ...and wait up to this long for a lingering plain Traversal tag
local HOLD_HIDE_WAIT_S = 0.6  -- ...and for the ability to hide the wolf (it can lag the tag by a frame)
local CALL_GRACE_S = 1.5      -- after our call: montages and "wolf gone" are not checked yet
local AFTER_SNAPSHOT_S = 0.5
local PLAYER_SETTLE_S = 2.0   -- after a new pawn (load, death, respawn)

local MODE_WALKING, MODE_FALLING = 1, 3

local S = {
    enabled = true,
    holdAfterHaste = false,
    nightOnly = true,
    noSpeedUp = true,        -- NoSpeedUpTransitions
    rulesHandle = nil,       -- PushTransitionRules handle (an int, not an object)
    keyPressed = false,      -- set by the keybind thread, handled in the game-thread loop
    toastRetry = nil,        -- { at = os.clock(), fn = attempt }
    lastAnim = nil,
    logging = false,
    held = false,            -- the mod keeps Coen a wolf
    pawnAddr = nil,          -- address only, to notice a new pawn; never dereferenced
    pawnSince = 0,
    hasteOn = false,
    sawWolf = false,         -- wolf shown during the current Haste
    applyAt = nil,           -- os.clock() of the pending hold after Haste
    applyUntil = 0,
    applyHideUntil = 0,
    cycleSwap = nil,         -- { setPath, coenIdx, combatIdx } while the two cycle entries are swapped
    cycleBroken = false,     -- a swap write did not stick; stop trying this session
    lastCallAt = nil,
    snapAt = nil,
    snapLabel = nil,
    lastState = nil,
    toastSeq = 0,
    lastToast = nil,
}

---------------------------------------------------------------- config

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function configPath()
    for _, p in ipairs({
        "ue4ss/Mods/WolfForm/config.ini",
        "Mods/WolfForm/config.ini",
    }) do
        local f = io.open(p, "r")
        if f then f:close() return p end
    end
    return nil
end

local CONFIG = configPath()

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

local function applyConfig(c)
    S.logging = c.logging == "1"
    S.enabled = c.enabled ~= "0"
    S.holdAfterHaste = c.holdafterhaste == "1"
    S.nightOnly = c.nightonly ~= "0"
    S.noSpeedUp = c.nospeeduptransitions ~= "0"
end

---------------------------------------------------------------- logging

local logHandle = nil
local t0 = os.clock()

local function write(msg)
    if not logHandle then logHandle = io.open("WolfForm.log", "a") end
    if logHandle then
        logHandle:write(string.format("[%s +%.2fs] %s\n", os.date("%H:%M:%S"), os.clock() - t0, msg))
        logHandle:flush()
    end
end

-- WolfForm.log only (state stream, snapshots).
local function log(fmt, ...)
    if not S.logging then return end
    write(string.format(fmt, ...))
end

-- Calls, drops, key presses: WolfForm.log and UE4SS.log.
local function say(fmt, ...)
    if not S.logging then return end
    local msg = string.format(fmt, ...)
    print("[WolfForm] " .. msg .. "\n")
    write(msg)
end

-- Errors: always in UE4SS.log.
local function err(where, e)
    local msg = string.format("%s error: %s", where, tostring(e))
    print("[WolfForm] " .. msg .. "\n")
    if S.logging then write(msg) end
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

-- Array elements, weak pointers: the object inside, or nil.
local function ref(o)
    if live(o) then return o end
    if type(o) ~= "userdata" then return nil end
    local v = try(function() return o:get() end)
    if live(v) then return v end
    v = try(function() return o:Get() end)
    if live(v) then return v end
    return nil
end

local function className(o)
    return try(function() return o:GetClass():GetFName():ToString() end) or "?"
end

local function objName(o)
    return o and try(function() return o:GetFName():ToString() end) or "none"
end

local function fullName(o) return try(function() return o:GetFullName() end) end

local function sameObj(a, b)
    local x = try(function() return a:GetAddress() end)
    return x ~= nil and x == try(function() return b:GetAddress() end)
end

local function num(v, f)
    if type(v) ~= "number" then return "?" end
    return string.format(f or "%.0f", v)
end

local function dumpTable(t)
    local parts = {}
    for k, v in pairs(t) do table.insert(parts, tostring(k) .. "=" .. tostring(v)) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

---------------------------------------------------------------- player (engine cached, pawn resolved every tick)

local engine, engineRetryAt, frontendCdo, skelClass = nil, 0, nil, nil

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

local function getPlayer()
    local e = gameEngine()
    if not e then return nil end
    local pawn = try(function()
        local lp = ref(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and ref(lp.PlayerController)
        return pc and ref(pc.Pawn)
    end)
    if not pawn or className(pawn) ~= "BP_PlayerCharacter_C" then return nil end
    if (fullName(pawn) or ""):find("/Cutscenes/", 1, true) then return nil end
    return pawn
end

local function hasTag(asc, tag)
    return try(function() return asc:HasMatchingGameplayTag({ TagName = FName(tag) }) end) == true
end

---------------------------------------------------------------- body

local function wolfMesh(pawn) return ref(try(function() return pawn.FastTravelSkeletal end)) end

local function humanMesh(pawn)
    if not live(skelClass) then skelClass = try(function() return StaticFindObject("/Script/Engine.SkeletalMeshComponent") end) end
    if not live(skelClass) then return nil end
    local found = nil
    pcall(function()
        local arr = pawn:K2_GetComponentsByClass(skelClass)
        for i = 1, #arr do
            local m = ref(arr[i])
            if m and objName(m) == HUMAN_MESH then found = m break end
        end
    end)
    return found
end

local function isVisible(m) return m ~= nil and try(function() return m:IsVisible() end) == true end

local function montageOf(m)
    local a = m and ref(try(function() return m:GetAnimInstance() end))
    local mo = a and ref(try(function() return a:GetCurrentActiveMontage() end))
    return mo and objName(mo) or nil
end

local function layersOf(m)
    local names = {}
    pcall(function()
        local arr = m.LinkedInstances
        for i = 1, #arr do
            local li = ref(arr[i])
            if li then table.insert(names, className(li)) end
        end
    end)
    return table.concat(names, ",")
end

-- The wolf's own montages (transformation) don't count as "the human body is needed".
local function isWolfMontage(name)
    local l = name:lower()
    return l:find("wolf", 1, true) or l:find("wlf", 1, true) or l:find("shapeshift", 1, true)
end

local function speedBucket(pawn)
    local v = try(function() return pawn:GetVelocity() end)
    local x, y = v and try(function() return v.X end), v and try(function() return v.Y end)
    if type(x) ~= "number" or type(y) ~= "number" then return "?" end
    local sp = math.sqrt(x * x + y * y)
    if sp < 10 then return "still" elseif sp < 300 then return "walk" elseif sp < 700 then return "run"
    elseif sp < 1500 then return "sprint" else return "haste" end
end

local function snapshot(pawn, wolf, haste)
    local wm = wolfMesh(pawn)
    local hm = humanMesh(pawn)
    local cm = ref(try(function() return pawn.CharacterMovement end))
    local cap = ref(try(function() return pawn.CapsuleComponent end))
    return string.format(
        "held=%s wolf=%s form=%s haste=%s mode=%s speed=%s mesh=%s human=%s wolfMesh=%s wolfLayers=[%s] wolfMontage=%s humanMontage=%s capsule=%s/%s maxWalk=%s ctd=%s",
        tostring(S.held), tostring(wolf), tostring(try(function() return pawn.Form end)), tostring(haste),
        tostring(cm and try(function() return cm.MovementMode end)), speedBucket(pawn),
        objName(ref(try(function() return pawn.Mesh end))),
        hm and (isVisible(hm) and "vis" or "hid") or "?",
        wm and (isVisible(wm) and "vis" or "hid") or "?",
        wm and layersOf(wm) or "?", montageOf(wm) or "none", montageOf(hm) or "none",
        num(cap and try(function() return cap:GetUnscaledCapsuleHalfHeight() end)),
        num(cap and try(function() return cap:GetUnscaledCapsuleRadius() end)),
        num(cm and try(function() return cm.MaxWalkSpeed end)),
        num(try(function() return pawn.CustomTimeDilation end), "%.1f"))
end

---------------------------------------------------------------- the Haste ability

local function isOurs(ga, pawn)
    local a = ref(try(function() return ga:GetAvatarActorFromActorInfo() end))
        or ref(try(function() return ga["Player Character"] end))
    return a ~= nil and sameObj(a, pawn)
end

-- Resolved fresh on every use (key press, end of Haste), never kept. ASC spec
-- list first (cheap), FindAllOf (~40 ms) as the fallback; the log says which.
local function findAbility(pawn)
    local asc = ref(try(function() return pawn.AbilitySystemComponent end))
    if asc then
        local found = nil
        pcall(function()
            local items = asc.ActivatableAbilities.Items
            for i = 1, #items do
                local spec = items[i]
                if className(ref(spec.Ability)) == GA_CLASS then
                    for _, field in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
                        local arr = spec[field]
                        for j = 1, #arr do
                            local ga = ref(arr[j])
                            if ga and isOurs(ga, pawn) then found = ga return end
                        end
                    end
                    return
                end
            end
        end)
        if found then return found, "ASC spec" end
        pcall(function()
            local arr = asc.AllReplicatedInstancedAbilities
            for i = 1, #arr do
                local ga = ref(arr[i])
                if ga and className(ga) == GA_CLASS and isOurs(ga, pawn) then found = ga return end
            end
        end)
        if found then return found, "ASC replicated list" end
    end
    for _, ga in ipairs(FindAllOf(GA_CLASS) or {}) do
        if live(ga) and isOurs(ga, pawn) then return ga, "FindAllOf" end
    end
    return nil, "no instance for this pawn"
end

-- Same game-thread call from lookup to SetupWolfForm.
local function callSetup(pawn, on, why)
    local t = os.clock()
    local ga, via = findAbility(pawn)
    local ms = (os.clock() - t) * 1000
    if not ga then
        say("SetupWolfForm(%s) for %s: ability not found (%s, %.1f ms)", tostring(on), why, via, ms)
        return false
    end
    log("ability %s via %s in %.1f ms (bValuesInitialized=%s)", fullName(ga) or "?", via, ms,
        tostring(try(function() return ga.bValuesInitialized end)))
    if on and try(function() return ga.bValuesInitialized end) ~= true then
        local out = {}
        local okI, errI = pcall(function() ga:InitializeValues(out) end)
        say("InitializeValues: %s, out %s, bValuesInitialized now %s", okI and "ok" or ("error " .. tostring(errI)),
            dumpTable(out), tostring(try(function() return ga.bValuesInitialized end)))
    end
    log("before: %s", snapshot(pawn, try(function() return pawn:IsInWolfForm() end), false))
    local ok, e = pcall(function() ga:SetupWolfForm(on) end)
    say("SetupWolfForm(%s) for %s: %s", tostring(on), why, ok and "ok" or ("error " .. tostring(e)))
    log("right after: %s", snapshot(pawn, try(function() return pawn:IsInWolfForm() end), false))
    S.lastCallAt = os.clock()
    S.snapAt = S.lastCallAt + AFTER_SNAPSHOT_S
    S.snapLabel = string.format("+%.1fs after SetupWolfForm(%s)", AFTER_SNAPSHOT_S, tostring(on))
    return ok
end

---------------------------------------------------------------- rules

-- Why the human body is needed right now (nil = nothing). forKey: also refuse
-- in the air.
local function blocker(pawn, asc, forKey)
    if S.nightOnly and try(function() return pawn.Form end) == 0 then return "day" end
    if try(function() return pawn.bCinematicMode end) == true then return "dialogue/cutscene" end
    if asc then
        if hasTag(asc, TAG_COMBAT) then return "combat" end
        if hasTag(asc, TAG_SHADOWSTEP) then return "Shadowstep" end
        if hasTag(asc, TAG_TRAVERSAL) and not hasTag(asc, TAG_HASTE) then return "traversal" end
    end
    local mode = try(function() return pawn.CharacterMovement.MovementMode end)
    if type(mode) == "number" and mode ~= MODE_WALKING and (forKey or mode ~= MODE_FALLING) then
        return "movement mode " .. mode
    end
    if try(function() return pawn.bIsCrouched end) == true then return "crouching" end
    return nil
end

local function dropWolf(pawn, shown, why)
    S.held = false
    S.applyAt = nil
    say("back to human: %s", why)
    if shown then callSetup(pawn, false, why) end
end

---------------------------------------------------------------- toast

local function toastWidget()
    local e = gameEngine()
    local world = e and try(function() return ref(e.GameViewport.World) end)
    if not world then return nil end
    if not live(frontendCdo) then frontendCdo = try(function() return StaticFindObject(FRONTEND_CDO) end) end
    if not live(frontendCdo) then return nil end
    local f = try(function() return ref(frontendCdo:GetFrontend(world)) end)
    return f and try(function() return ref(f.ToastWidget) end)
end

-- The game's toast; waits for one of the game's own (0.4 s steps, 8 tries). Game thread.
local function toast(msg)
    S.toastSeq = S.toastSeq + 1
    local id, tries = S.toastSeq, 0
    local function attempt()
        if id ~= S.toastSeq then return end
        tries = tries + 1
        local ok, res = pcall(function()
            local w = toastWidget()
            if not w then return "no toast widget" end
            local ours = S.lastToast ~= nil and os.clock() - S.lastToast < 4
            if try(function() return w:IsShowingToast() end) == true and not ours then return "busy" end
            w:Show({ Type = 0, Message = FText(msg) })
            S.lastToast = os.clock()
            return "shown"
        end)
        res = ok and res or ("error " .. tostring(res))
        if res == "busy" and tries < 8 then
            S.toastRetry = { at = os.clock() + 0.4, fn = attempt }
            return
        end
        log("toast '%s': %s", msg, res)
    end
    attempt()
end

---------------------------------------------------------------- wolf locomotion tweaks (0.1.1)

-- Test 2026-10-04: walk -> run left the wolf's legs frozen (straight to run was fine), and the
-- front legs looked off at sprint. Guesses: (1) the layer's speed-up transition (SpeedUp flag,
-- CanSpeedUp) has no wolf animation; the movement component can switch speed-up/slow-down
-- transitions off with PushTransitionRules (fixed it, 2026-10-04). Only while held, shown and
-- not in Haste; popped otherwise. (Stride warping was already off at runtime, 0.1.1 log.)

local function profileOf(cm) return cm and ref(try(function() return cm:GetCurrentMovementProfile() end)) end

local function syncRules(pawn, cm, want)
    if want and not S.rulesHandle then
        local base = {}
        pcall(function()
            local r = profileOf(cm).MovementConfig.TransitionRules
            for _, k in ipairs({ "bDisableStartTransitions", "bDisableStopTransitions", "bDisablePivotTransitions",
                "bEnableStopWithTurnTransitions" }) do
                base[k] = r[k] == true
            end
        end)
        local rules = {
            bDisableStartTransitions = base.bDisableStartTransitions == true,
            bDisableStopTransitions = base.bDisableStopTransitions == true,
            bDisablePivotTransitions = base.bDisablePivotTransitions == true,
            bEnableSpeedUpTransitions = false,
            bEnableSlowDownTransitions = false,
            bEnableStopWithTurnTransitions = base.bEnableStopWithTurnTransitions == true,
        }
        local ok, h = pcall(function() return cm:PushTransitionRules(rules, 100) end)
        if ok and type(h) == "number" then S.rulesHandle = h end
        say("PushTransitionRules (no speed-up/slow-down): %s, stack now %s",
            ok and ("handle " .. tostring(h)) or ("error " .. tostring(h)),
            tostring(try(function() return #cm.TransitionRulesStack end)))
    elseif not want and S.rulesHandle then
        local h = S.rulesHandle
        S.rulesHandle = nil
        local ok, r = pcall(function() return cm:PopTransitionRules(h) end)
        say("PopTransitionRules(%s): %s", tostring(h), ok and tostring(r) or ("error " .. tostring(r)))
    end
end

local function locoLayer(wm)
    local loco = nil
    pcall(function()
        local arr = wm.LinkedInstances
        for i = 1, #arr do
            local li = ref(arr[i])
            if li and className(li) == "ABP_WolfLocomotionLayers_C" then loco = li break end
        end
    end)
    return loco
end

-- Haste gallop for sprint (0.1.3). The wolf layer's cycle set
-- DA_Wolf_FaceVelocity_CycleBlendSpaceSet holds BS_Wolf_COEN_CycleFaceVelocity (Haste) and
-- BS_Wolf_Combat_CycleFaceVelocity (used outside Haste; no sprint gallop, front legs stall).
-- While wanted, the two entries' BlendSpace pointers are swapped (in-place writes in existing
-- elements, no resize): the unconditioned entry plays the gallop, the Haste entry holds the Combat
-- blendspace. 0.1.4: both stay referenced by the set. 0.1.3 overwrote one pointer, the Combat
-- blendspace lost its last reference, got unloaded and could not be restored (log 22:32:47).
-- The set is a shared data asset.
local COEN_BS, COMBAT_BS = "BS_Wolf_COEN_CycleFaceVelocity", "BS_Wolf_Combat_CycleFaceVelocity"

local function assetPath(o)
    local n = fullName(o)
    return n and n:match("^%S+%s+(.+)$") or n
end

local function cycleNames(set)
    local names = {}
    pcall(function()
        local arr = set.Assets
        for i = 1, #arr do table.insert(names, objName(ref(arr[i].BlendSpace))) end
    end)
    return table.concat(names, ",")
end

local function swapEntries(set, i, j)
    return pcall(function()
        local arr = set.Assets
        local x, y = ref(arr[i].BlendSpace), ref(arr[j].BlendSpace)
        if not (x and y) then error("missing blendspace") end
        arr[i].BlendSpace = y
        arr[j].BlendSpace = x
    end)
end

local function entryName(set, i)
    return objName(ref(try(function() return set.Assets[i].BlendSpace end)))
end

local function restoreCycle(why)
    local sw = S.cycleSwap
    if not sw then return end
    S.cycleSwap = nil
    local set = try(function() return StaticFindObject(sw.setPath) end)
    local ok = live(set) and entryName(set, sw.coenIdx) == COMBAT_BS and swapEntries(set, sw.coenIdx, sw.combatIdx)
    ok = ok and entryName(set, sw.coenIdx) == COEN_BS and entryName(set, sw.combatIdx) == COMBAT_BS
    say("cycle restored (%s): %s, set now [%s]", why, ok and "ok" or "failed", live(set) and cycleNames(set) or "?")
end

local function syncCycle(wm, want, why)
    if not want then
        if S.cycleSwap then restoreCycle(why) end
        return
    end
    if S.cycleSwap or S.cycleBroken then return end
    local loco = locoLayer(wm)
    local set = loco and ref(try(function() return loco.CycleBlendSpaceSet end))
    if not set then return end
    local coenIdx, combatIdx = nil, nil
    pcall(function()
        local arr = set.Assets
        for i = 1, #arr do
            local n = objName(ref(arr[i].BlendSpace))
            if n == COEN_BS and not coenIdx then coenIdx = i
            elseif n == COMBAT_BS and not combatIdx then combatIdx = i end
        end
    end)
    if not (coenIdx and combatIdx) then
        S.cycleBroken = true
        say("cycle swap: entries not found in %s [%s], giving up", objName(set), cycleNames(set))
        return
    end
    local ok, e = swapEntries(set, coenIdx, combatIdx)
    local stuck = ok and entryName(set, combatIdx) == COEN_BS and entryName(set, coenIdx) == COMBAT_BS
    if stuck then
        S.cycleSwap = { setPath = assetPath(set), coenIdx = coenIdx, combatIdx = combatIdx }
    else
        S.cycleBroken = true
    end
    say("cycle swap (%s): %s, set now [%s]", why, stuck and "ok" or ("did not stick " .. tostring(e)), cycleNames(set))
end

-- Logged on change while the wolf is shown.
local function animDetail(pawn, cm, wm)
    local a = wm and ref(try(function() return wm:GetAnimInstance() end))
    local loco = locoLayer(wm)
    local function b(o, k) return o and tostring(try(function() return o[k] end)) or "?" end
    local function f(o, k) return o and num(try(function() return o[k] end), "%.1f") or "?" end
    local set = loco and ref(try(function() return loco.CycleBlendSpaceSet end))
    return string.format("profile=%s stride=%s cycleRate=%s rootScale=%s speed=%s | speedUp=%s slowDown=%s finishedStart=%s switcher=%s pace=%s | rules=%s cycle=[%s]",
        objName(profileOf(cm)), b(a, "bStrideWarpingEnabled"), f(a, "CyclePlayRate"), f(a, "RootSpeedScale"), f(a, "Speed"),
        b(loco, "SpeedUp"), b(loco, "SlowDown"), b(loco, "HasFinishedStart"), b(loco, "StartBlendspaceSwitcher"),
        loco and num(try(function() return loco.PaceValue end), "%.1f") or "?",
        tostring(cm and try(function() return #cm.TransitionRulesStack end)), set and cycleNames(set) or "?")
end

---------------------------------------------------------------- core

local function tick()
    local pawn = getPlayer()
    if not pawn then return end
    local now = os.clock()

    local addr = try(function() return pawn:GetAddress() end)
    if addr ~= S.pawnAddr then
        if S.pawnAddr then say("new player pawn (load, death or respawn): state reset") end
        S.pawnAddr, S.pawnSince = addr, now
        S.held, S.hasteOn, S.sawWolf, S.applyAt, S.snapAt, S.lastCallAt = false, false, false, nil, nil, nil
        S.lastState, S.lastAnim, S.rulesHandle = nil, nil, nil
        restoreCycle("new pawn")
    end
    if now - S.pawnSince < PLAYER_SETTLE_S then return end

    local asc = ref(try(function() return pawn.AbilitySystemComponent end))
    local haste = asc ~= nil and hasTag(asc, TAG_HASTE)
    local wm = wolfMesh(pawn)
    local wolf = try(function() return pawn:IsInWolfForm() end) == true
    local shown = wolf or isVisible(wm)

    local cm = ref(try(function() return pawn.CharacterMovement end))
    local wolfOn = S.held and shown and not haste and S.enabled
    syncRules(pawn, cm, wolfOn and S.noSpeedUp)
    local sprinting = objName(profileOf(cm)) == "DA_SprintOpenWorld_MovementProfile"
    -- Haste gallop while sprinting only (2026-10-04: off and always both looked wrong).
    local cycleWhy = nil
    if not wolfOn then cycleWhy = "not a held wolf"
    elseif not sprinting then cycleWhy = "not sprinting" end
    syncCycle(wm, cycleWhy == nil, cycleWhy or "sprint")

    if S.logging then
        if shown then
            local ad = animDetail(pawn, cm, wm)
            if ad ~= S.lastAnim then
                S.lastAnim = ad
                log("anim %s", ad)
            end
        end
        local st = snapshot(pawn, wolf, haste)
        if st ~= S.lastState then
            S.lastState = st
            log("state %s", st)
        end
        if S.snapAt and now >= S.snapAt then
            log("%s: %s", S.snapLabel, st)
            S.snapAt = nil
        end
    end

    -- During Haste the ability owns the wolf. Remember whether it showed.
    if haste then
        if not S.hasteOn then
            S.hasteOn, S.sawWolf = true, false
            log("Haste start (held=%s)", tostring(S.held))
        end
        if shown then S.sawWolf = true end
        S.applyAt = nil
        return
    end
    if S.hasteOn then
        S.hasteOn = false
        local wanted = S.sawWolf or S.held
        log("Haste end (wolf seen=%s, held=%s)", tostring(S.sawWolf), tostring(S.held))
        S.sawWolf = false
        if wanted and S.enabled and S.holdAfterHaste then
            S.applyAt, S.applyUntil, S.applyHideUntil = now + HOLD_DELAY_S, now + HOLD_WAIT_S, now + HOLD_HIDE_WAIT_S
        else
            S.held = false
        end
    end

    if S.applyAt then
        if now < S.applyAt then return end
        local why = blocker(pawn, asc, false)
        -- The plain Traversal tag can outlive Traversal.VampireSprint by a tick.
        if why == "traversal" and now < S.applyUntil then return end
        -- The ability can hide the wolf a frame after the tag drops (0.1.2 log): wait for it.
        if not why and shown and now < S.applyHideUntil then return end
        S.applyAt = nil
        if why then
            say("not holding the wolf after Haste: %s", why)
            S.held = false
            return
        end
        S.held = true
        if shown then
            say("wolf still shown %.1f s after Haste, holding it without a call", HOLD_HIDE_WAIT_S)
        else
            callSetup(pawn, true, "hold after Haste")
        end
        return
    end

    if not S.held then return end
    if not S.enabled then dropWolf(pawn, shown, "mod switched off"); return end
    local graceOver = not S.lastCallAt or now - S.lastCallAt >= CALL_GRACE_S
    if not shown then
        if graceOver then
            S.held = false
            say("wolf form ended by the game, hold off")
        end
        return
    end
    local why = blocker(pawn, asc, false)
    if not why and graceOver then
        local m = montageOf(wm)
        if m and not isWolfMontage(m) then why = "montage " .. m end
    end
    if why then dropWolf(pawn, shown, why) end
end

local REFUSE_TEXT = {
    day = "Wolf form only at night",
    combat = "Can't take wolf form in combat",
    ["dialogue/cutscene"] = "Can't take wolf form now",
}

local function onKey()
    local pawn = getPlayer()
    if not pawn then return end
    if not S.enabled then
        toast("Wolf Form is switched off in the mod settings")
        return
    end
    if os.clock() - S.pawnSince < PLAYER_SETTLE_S then return end
    local asc = ref(try(function() return pawn.AbilitySystemComponent end))
    if asc and hasTag(asc, TAG_HASTE) then
        say("key: ignored during Haste")
        toast("Can't change form during Haste")
        return
    end
    local wolf = try(function() return pawn:IsInWolfForm() end) == true
    local shown = wolf or isVisible(wolfMesh(pawn))
    if shown or S.held then
        S.held, S.applyAt = false, nil
        say("key: human (wolf shown=%s)", tostring(shown))
        if shown then callSetup(pawn, false, "key") end
        return
    end
    local why = blocker(pawn, asc, true)
    if why then
        say("key: wolf refused (%s)", why)
        toast(REFUSE_TEXT[why] or ("Can't take wolf form now (" .. why .. ")"))
        return
    end
    say("key: wolf")
    S.held = true
    if not callSetup(pawn, true, "key") then
        S.held = false
        toast("Wolf form failed (see WolfForm.log)")
    end
end

---------------------------------------------------------------- startup

local cfg = readConfig()
applyConfig(cfg)

local keyName = (cfg.togglekey or "P"):upper()
if keyName ~= "" then
    local key = Key[keyName]
    if key then
        RegisterKeyBind(key, function() S.keyPressed = true end)
    else
        print("[WolfForm] unknown ToggleKey '" .. keyName .. "', hotkey disabled\n")
        keyName = ""
    end
end

-- One game-thread loop: every frame while Haste is on or a hold is pending (so the wolf comes
-- back on the first frame after Haste drops it), otherwise every POLL_MS; config every 2 s.
local lastTick, lastConfig = 0, os.clock()
local function frame()
    local now = os.clock()
    if S.keyPressed then
        S.keyPressed = false
        local ok, e = pcall(onKey)
        if not ok then err("key", e) end
    end
    if S.toastRetry and now >= S.toastRetry.at then
        local fn = S.toastRetry.fn
        S.toastRetry = nil
        local ok, e = pcall(fn)
        if not ok then err("toast", e) end
    end
    if now - lastConfig >= CONFIG_POLL_MS / 1000 then
        lastConfig = now
        applyConfig(readConfig())
    end
    if S.hasteOn or S.applyAt or now - lastTick >= POLL_MS / 1000 then
        lastTick = now
        local ok, e = pcall(tick)
        if not ok then err("tick", e) end
    end
end

if LoopInGameThreadAfterFrames then
    LoopInGameThreadAfterFrames(1, function()
        local ok, e = pcall(frame)
        if not ok then err("frame", e) end
        return false
    end)
else
    print("[WolfForm] LoopInGameThreadAfterFrames missing in this UE4SS build, mod inactive\n")
end

print(string.format("[WolfForm] %s loaded (%s, hotkey %s, hold after Haste %s, night only %s, log %s, config %s)\n",
    VERSION, S.enabled and "on" or "off", keyName ~= "" and keyName or "none",
    S.holdAfterHaste and "on" or "off", S.nightOnly and "on" or "off", S.logging and "on" or "off",
    CONFIG or "not found, using defaults"))
log("==== session start %s", VERSION)
