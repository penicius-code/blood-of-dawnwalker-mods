-- AlwaysFinishers 0.5.1. Raises the enemy HP threshold at which finishers become possible.
--
-- Numpad *: on/off (toast). The game marks an enemy "ready for finisher" when Health/MaxHealth <= its AI config's
-- FinishersHPPercentage (vanilla 0.2 longsword, 0.1 heavy/rogue); a Coen hit that leaves it at or below that then
-- starts a finisher. A blow from above the threshold straight to 0 gets none (FinisherProbe 0.2.0). While on, every
-- AI config met (a default object) that allows finishers gets at least Threshold %; never lowered. Vanilla values
-- are kept and written back when off.
-- One LoopInGameThreadAfterFrames(1) loop gated by os.clock(); the keybind only sets a flag. Enemies are re-resolved
-- every tick through the GameEngine singleton and CombatSubsystem.
--
-- Reload fix (2026-10-21, not yet tested in game; Nexus report 2026-10-20 "stops working after loading a save"):
-- a save load runs UEngine::LoadMap, which tears the world down and garbage collects the enemies' Blueprint classes.
-- The next enemy of a type brings a fresh Default__AIConfig_*_C with vanilla values under the same name, and 0.5.0
-- trusted its name keyed cache, so the raised threshold was never written again. Now only vanilla/allows are kept
-- per name; the object is re-attached from the live enemy whenever its address changes, dropped on a LoadMap or
-- world change, and its value is re-read every 2 s and rewritten when it is not what we want.

local VERSION = "0.5.1"
local TAG = "[AlwaysFinishers] "

local MOD_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])[Ss]cripts[\\/]") or "ue4ss/Mods/AlwaysFinishers/"
local FRONTEND_CDO = "/Script/DogwoodUI.Default__UIFrontend"

local clock = os.clock -- MSVC: wall time since process start, 1 ms resolution

---------------------------------------------------------------- config

local CFG = { Enabled = 1, Threshold = 30, Toast = 1, Logging = 0, TickMs = 100, Rearm = 1 }

local function readConfig()
    local f = io.open(MOD_DIR .. "config.ini", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:gsub(";.*$", ""):match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
        if k and CFG[k] ~= nil then CFG[k] = tonumber(v) or CFG[k] end
    end
    f:close()
    CFG.Threshold = math.max(1, math.min(100, CFG.Threshold))
    CFG.TickMs = math.max(100, CFG.TickMs)
end

-- The key writes its state back, so the menu and the next start agree.
local function saveEnabled(v)
    local path = MOD_DIR .. "config.ini"
    local f = io.open(path, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    local out, n = text:gsub("(\n%s*Enabled%s*=%s*)%d+", "%1" .. v, 1)
    if n == 0 then out, n = text:gsub("^(%s*Enabled%s*=%s*)%d+", "%1" .. v, 1) end
    if n == 0 then return end
    f = io.open(path, "w")
    if f then f:write(out) f:close() end
end

readConfig()

---------------------------------------------------------------- logging (change based)

local function say(fmt, ...)
    if CFG.Logging == 0 then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

local lastSaid = {}
local function sayChanged(key, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    msg = ok and msg or tostring(fmt)
    if lastSaid[key] == msg then return end
    lastSaid[key] = msg
    say("%s", msg)
end

---------------------------------------------------------------- helpers

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function valid(o)
    if type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function unwrap(o)
    if valid(o) then return o end
    if type(o) ~= "userdata" then return nil end
    local v = try(function() return o:get() end)
    if valid(v) then return v end
    v = try(function() return o:Get() end)
    if valid(v) then return v end
    return nil
end

local function num(v)
    if type(v) == "number" and v == v then return v end
    return nil
end

local function nameOf(o) return try(function() return o:GetFName():ToString() end) or "?" end

---------------------------------------------------------------- player (re-resolved every tick)

local engine, engineRetryAt = nil, 0

local function gameEngine(now)
    if valid(engine) then return engine end
    engine = nil
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 10
    local ok, e = pcall(FindFirstOf, "GameEngine") -- singleton, one ~38 ms scan per run
    if ok and valid(e) then engine = e end
    return engine
end

-- Returns the pawn and the address of the world it was resolved through (both nil while there is none).
local function playerPawn(now)
    local e = gameEngine(now)
    if not e then return nil, nil end
    local pawn, worldAddr
    pcall(function()
        local world = unwrap(e.GameViewport.World)
        if not world then return end
        worldAddr = world:GetAddress()
        local lp = unwrap(world.OwningGameInstance.LocalPlayers[1])
        local pc = lp and unwrap(lp.PlayerController)
        pawn = pc and unwrap(pc.Pawn)
    end)
    return valid(pawn) and pawn or nil, worldAddr
end

---------------------------------------------------------------- toast

local frontendCdo = nil

local function toast(msg)
    if CFG.Toast == 0 then return end
    local ok, err = pcall(function()
        local world = unwrap(engine and engine.GameViewport.World)
        if not world then return end
        if not valid(frontendCdo) then frontendCdo = try(function() return StaticFindObject(FRONTEND_CDO) end) end
        local f = valid(frontendCdo) and unwrap(frontendCdo:GetFrontend(world))
        local w = f and unwrap(f.ToastWidget)
        if w then w:Show({ Type = 0, Message = FText(msg) }) end
    end)
    if not ok then say("toast failed: %s", tostring(err)) end
end

---------------------------------------------------------------- AI configs (default objects, cached per name)

-- config name -> { vanilla, allows, obj, addr, set, checkAt, seenAt }
-- vanilla and allows belong to the asset and are kept for the whole session. obj/addr is the default object as
-- last resolved through a live enemy; it is dropped on a reload (a save load recreates these objects with vanilla
-- values under the same name). set is the value last written to that object, checkAt the next time learn()
-- re-reads the value, seenAt the last time learn() saw the object.
local C = {}
local VERIFY_S = 2.0  -- one property read per known config, ~0.005 ms
local RETRY_S = 30.0  -- after a failed write

local function target(c)
    if CFG.Enabled == 0 or not c.allows or not c.vanilla then return c.vanilla end
    return math.max(c.vanilla, CFG.Threshold / 100)
end

local function apply(name, c, now)
    if not c.obj then return end -- dropped on a reload; learn() re-attaches it from the next enemy of that type
    if not valid(c.obj) then c.obj, c.addr, c.set = nil, nil, nil return end
    local want = target(c)
    if not want or c.set == want then return end
    local ok = pcall(function() c.obj.FinishersHPPercentage = want end)
    local got = num(try(function() return c.obj.FinishersHPPercentage end))
    c.set = want -- also on failure: don't retry every tick
    if ok and got and math.abs(got - want) < 0.0001 then
        say("%s: FinishersHPPercentage %.2f (vanilla %.2f)", name, want, c.vanilla)
    else
        c.checkAt = now + RETRY_S
        print(TAG .. string.format("%s: write failed (read back %s)\n", name, tostring(got)))
    end
end

-- Config or key change. Only objects learn() resolved in the last 5 s are touched; the others are dropped and get
-- the new value when their enemy type is met again (no IsValid() on an object that may be gone).
local function applyAll(now)
    for name, c in pairs(C) do
        if c.obj and now - (c.seenAt or 0) > 5 then c.obj, c.addr, c.set = nil, nil, nil end
        apply(name, c, now)
    end
end

local function learn(a, now)
    local cfg = try(function()
        return unwrap(unwrap(unwrap(a.StubComponent.Stub):GetAIDefinition()):GetAIConfig())
    end)
    if not cfg then return nil end
    local name = nameOf(cfg)
    local addr = try(function() return cfg:GetAddress() end)
    if not addr then return nil end
    local c = C[name]
    if not c then
        c = {
            vanilla = num(try(function() return cfg.FinishersHPPercentage end)),
            allows = try(function() return cfg.bEnemyAllowsFinishers end) == true,
        }
        C[name] = c
        say("new AI config %s: allows finishers %s, vanilla threshold %s", name, tostring(c.allows), tostring(c.vanilla))
    elseif c.addr ~= addr then
        say("%s: new default object%s, re-applying", name, c.addr and " (address changed)" or " after reload")
    end
    c.seenAt = now
    if c.addr ~= addr then
        c.obj, c.addr, c.set, c.checkAt = cfg, addr, nil, now + VERIFY_S
        apply(name, c, now)
    elseif now >= (c.checkAt or 0) then
        c.checkAt = now + VERIFY_S
        local want = target(c)
        local got = num(try(function() return cfg.FinishersHPPercentage end))
        if want and got and math.abs(got - want) > 0.0001 then
            say("%s: FinishersHPPercentage is %.2f, expected %.2f, re-applying", name, got, want)
            c.obj, c.set = cfg, nil
            apply(name, c, now)
        end
    end
    return c
end

---------------------------------------------------------------- re-arm (0.2.0)

-- The finisher seems to start only when the AI's ready flag switches on during a Coen attack, and the AI logic
-- clears the flag again or never sets it (blinded by Dirty Trick, FinisherProbe 2026-10-12). While on, an enemy whose
-- config allows finishers and whose health is at or below the threshold gets the flag set through the game's own
-- native setter. Only UFunction calls on library default objects (cached); nothing is written directly.
local COMBAT_LIB = "/Script/RebelAI.Default__RebelAICombatBlueprintFunctionLibrary"
local BOARD_LIB = "/Script/RebelAI.Default__RebelAIBoardBlueprintFunctionLibrary"
local libs, libsRetryAt = {}, 0
local rearmAt = {}   -- enemy name -> last re-arm time
local REARM_GAP = 0.3

local function libraries(now)
    if valid(libs.combat) and valid(libs.board) then return true end
    if now < libsRetryAt then return false end
    libsRetryAt = now + 10
    libs.combat = try(function() return StaticFindObject(COMBAT_LIB) end)
    libs.board = try(function() return StaticFindObject(BOARD_LIB) end)
    local ok = valid(libs.combat) and valid(libs.board)
    sayChanged("libs", "AI libraries %s", ok and "found" or "MISSING (re-arm off)")
    return ok
end

-- 0.5.0 pulse: an enemy that is already ready does not get a finisher from later hits (FinisherProbe 2026-10-12,
-- threshold 40-50 %: ready set by a bleed tick between attacks, then several Coen hits, no finisher). Finishers only
-- started 0.1-0.3 s after the ready flag switched on during a Coen attack. So when a Coen attack damages an enemy that
-- is already ready, the flag is switched off and on again through the same native setter, like the AI does on a hit.
local hpSeen = {}    -- enemy name -> last health ratio

local function attacking(montage)
    local m = (montage or ""):lower()
    if m:find("aa_", 1, true) then return false end  -- active abilities (Wide Swing, Charge, Artery Strike)
    return m:find("attack", 1, true) ~= nil or m:find("combo", 1, true) ~= nil or m:find("riposte", 1, true) ~= nil
end

local function rearm(a, c, now, coenMontage)
    if CFG.Enabled == 0 or CFG.Rearm == 0 or not c or not c.allows then return end
    local hp = num(try(function() return a.CharacterAttributeSet.Health.CurrentValue end))
    local mx = num(try(function() return a.CharacterAttributeSet.MaxHealth.CurrentValue end))
    if not hp or not mx or mx <= 0 or hp <= 0 then return end
    local ratio = hp / mx
    local name = nameOf(a)
    local prev = hpSeen[name]
    hpSeen[name] = ratio
    if ratio > (target(c) or 0) + 0.0001 then return end
    local hit = prev ~= nil and ratio < prev - 0.001 and attacking(coenMontage)
    if not hit and rearmAt[name] and now - rearmAt[name] < REARM_GAP then return end
    if not libraries(now) then return end
    local stub = unwrap(try(function() return a.StubComponent.Stub end))
    if not stub then return end
    local ready = try(function() return libs.board:GetIsReadyForFinisher(stub) end) == true
    if ready and not hit then return end
    rearmAt[name] = now
    local ok, err = pcall(function()
        if ready then libs.combat:BP_ReadyForFinisher(stub, false) end
        libs.combat:BP_ReadyForFinisher(stub, true)
    end)
    if ok then
        say("%s %s at HP %.0f%% (%s)", ready and "pulsed" or "re-armed", name, ratio * 100,
            hit and ("hit by " .. tostring(coenMontage)) or "no hit")
    else
        sayChanged("rearm", "re-arm failed: %s", tostring(err))
    end
end

---------------------------------------------------------------- reload (save load, map change)

-- A save load runs UEngine::LoadMap: new world, new pawn, and the enemies' Blueprint classes (with the AI config
-- default objects we wrote to) are garbage collected and loaded again. Drop everything that pointed into the old
-- world; vanilla values stay and learn() re-applies the threshold as enemies are met. Three nets: the LoadMap
-- pre-hook (only sets a flag, no engine access in a hook), the world/pawn address check in tick() in case the hook
-- is missing or does not fire, and the value re-read in learn() every 2 s.
local reloadPending = nil

local function onReload(why)
    local n = 0
    for _, c in pairs(C) do
        if c.obj then n = n + 1 end
        c.obj, c.addr, c.set, c.checkAt = nil, nil, nil, nil
    end
    hpSeen, rearmAt = {}, {}
    frontendCdo = nil
    say("%s: dropped %d AI config object(s), re-applied as enemies are met", why, n)
end

---------------------------------------------------------------- loop

local SETTLE_S = 3.0
local pawnAddr, worldAddr, settleUntil = nil, nil, 0
local toggleRequested = false
local nextTick, nextConfig = 0, 0
local failed, failedAt = nil, 0

local function tick(now)
    if reloadPending then
        local why = reloadPending
        reloadPending = nil
        onReload(why)
    end
    local pawn, world = playerPawn(now)
    local addr = pawn and pawn:GetAddress() or nil
    if world ~= worldAddr then
        worldAddr = world
        settleUntil = now + SETTLE_S
        onReload(world and "world changed" or "world gone")
    end
    if addr ~= pawnAddr then
        pawnAddr = addr
        settleUntil = now + SETTLE_S
        sayChanged("pawn", "player %s", addr and "found" or "gone")
    end
    if now >= nextConfig then
        nextConfig = now + 2
        local en, th = CFG.Enabled, CFG.Threshold
        readConfig()
        if en ~= CFG.Enabled or th ~= CFG.Threshold then
            say("config: %s, threshold %d%%", CFG.Enabled == 1 and "ON" or "OFF", CFG.Threshold)
            applyAll(now)
        end
    end
    if toggleRequested then
        toggleRequested = false
        CFG.Enabled = CFG.Enabled == 1 and 0 or 1
        saveEnabled(CFG.Enabled)
        applyAll(now)
        local msg = CFG.Enabled == 1 and string.format("Always Finishers: ON (%d%%)", CFG.Threshold)
            or "Always Finishers: OFF"
        say("key: %s", msg)
        toast(msg)
    end
    if not pawn or now < settleUntil then return end
    local sub = unwrap(try(function() return pawn.CombatComponent.CombatSubsystem end))
    local actors = sub and try(function() return sub:GetAllAggressiveNPCActors() end)
    if type(actors) ~= "table" then return end
    local m = unwrap(try(function() return pawn:GetCurrentMontage() end))
    local coenMontage = m and nameOf(m) or nil
    if #actors == 0 then hpSeen = {} end
    for i = 1, math.min(#actors, 16) do
        local a = unwrap(actors[i])
        if a and a:GetAddress() ~= addr then
            local ok, c = pcall(learn, a, now)
            if not ok then sayChanged("learn", "learn error: %s", tostring(c)) c = nil end
            local okR, errR = pcall(rearm, a, c, now, coenMontage)
            if not okR then sayChanged("rearmErr", "re-arm error: %s", tostring(errR)) end
        end
    end
end

if not LoopInGameThreadAfterFrames then
    print(TAG .. "LoopInGameThreadAfterFrames missing in this UE4SS build, inactive\n")
    return
end

LoopInGameThreadAfterFrames(1, function()
    local now = clock()
    if now < nextTick then return false end
    nextTick = now + (toggleRequested and 0 or CFG.TickMs / 1000)
    local ok, err = pcall(tick, now)
    if not ok then
        local msg = tostring(err)
        if failed ~= msg or now - failedAt >= 30 then -- a recurring error shows up again every 30 s
            failed, failedAt = msg, now
            print(TAG .. "error: " .. msg .. "\n") -- errors are logged even with Logging = 0
        end
    end
    return false
end)

-- (no hotkey: switch the mod on and off in the Mod Setting Menu)

-- The hook callback only sets a flag; tick() does the reset on the game thread before touching anything.
local loadMapHook = type(RegisterLoadMapPreHook) == "function"
    and pcall(RegisterLoadMapPreHook, function() reloadPending = "reload detected (LoadMap)" end)

say("%s loaded: %s, threshold %d%% (Logging %d, LoadMap hook %s)", VERSION, CFG.Enabled == 1 and "ON" or "OFF",
    CFG.Threshold, CFG.Logging, loadMapHook and "on" or "off")
