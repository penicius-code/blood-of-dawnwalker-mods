-- Corruption Rate 0.1.0
-- Keeps only a set share of every corruption gain (Vrakhiri mutation charge): drinks, the blood that keeps
-- coming after a drink, vials and other items. 10% = a tenth of the vanilla speed.
--
-- How: every 0.2 s the charge is read (CharacterDevelopmentSubsystem). Whatever it rose since the last read,
-- the unwanted share is taken back off. The write follows BetterCorruption build 8 (verified there, 2026-10-03):
-- the attribute is set one unit short and the game's own AddMutationCharges(1) adds the last unit, otherwise a
-- save keeps the game's value instead of the written one. The unit can arrive a frame later ("pending").
--
-- Left alone: AddMutationCharges calls made by anyone else (story rewards, BetterCorruption's own corrections),
-- drops in the charge, level changes other than one level up during a gain, the first 5 s after a load.
-- The level goes up only when a drink is over (GA_VampireMutation), so a charge kept low during the drink
-- delays the level-up as wanted. If a single jump crosses the level (an item), the level stays and only the
-- carry-over into the new level is scaled.
--
-- Hard rules followed: one game-thread loop (LoopInGameThreadAfterFrames + os.clock gate), no LoopAsync,
-- no *WithDelay. Only the subsystem class, a CDO and the game instance subsystem are kept between ticks;
-- the pawn and its attribute set are resolved fresh every tick.

local VERSION = "0.1.0"
local UEHelpers = require("UEHelpers")

local TICK_S = 0.2
local CONFIG_S = 2.0
local SETTLE_S = 5.0       -- the charge reads 0 for about a second after a load (BetterCorruption)
local WRITE_MIN = 0.05     -- smallest share taken back while the charge keeps rising
local QUIET_S = 0.6        -- after this long without a rise, any remainder is taken back
local BURST_END_S = 3.0    -- a gain summary is logged after this long without a rise
local EXEMPT_S = 3.0       -- how long another caller's AddMutationCharges stays exempt
local PENDING_S = 1.0      -- how long to wait for the game's unit after a write
local MAX_FAILS = 5        -- write failures in a row before the mod stops for the session

local S = {
    enabled = true, percent = 10, logging = false,
    pawnKey = nil, settleAt = nil,
    level = nil, charge = nil,      -- last known level and charge (after our writes)
    excess = 0.0,                   -- share of the gains not yet taken back
    lastGainAt = 0.0,
    pending = nil,                  -- { target, at } while the game's unit is on its way
    exempt = 0.0, exemptAt = 0.0,   -- AddMutationCharges from other callers, not scaled
    inOwnCall = false,
    burst = nil,                    -- gain summary for the log
    fails = 0, broken = false,
    pathNoted = {},
    total = { raw = 0.0, removed = 0.0 },
}

---------------------------------------------------------------- config

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function configPath()
    for _, p in ipairs({
        "ue4ss/Mods/CorruptionRate/config.ini",
        "Mods/CorruptionRate/config.ini",
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

---------------------------------------------------------------- logging

local logHandle = nil

local function write(msg)
    if not logHandle then logHandle = io.open("CorruptionRate.log", "a") end
    if logHandle then
        logHandle:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
        logHandle:flush()
    end
end

local function log(fmt, ...)
    if not S.logging then return end
    local ok, msg = pcall(string.format, fmt, ...)
    write(ok and msg or tostring(fmt))
end

-- Errors: CorruptionRate.log (always) and UE4SS.log, once per kind, then once a minute.
local errState = {}
local function err(kind, e)
    local now = os.clock()
    local st = errState[kind]
    if st and now - st < 60 then return end
    errState[kind] = now
    local msg = string.format("ERROR %s: %s", kind, tostring(e))
    write(msg)
    print("[CorruptionRate] " .. msg .. "\n")
end

local function num(v) return type(v) == "number" and string.format("%.3f", v) or "?" end

local function applyConfig(c)
    local old = S.enabled and S.percent or 100
    S.logging = c.logging == "1"
    S.enabled = c.enabled ~= "0"
    local p = tonumber(c.gainpercent or "")
    if p then S.percent = math.max(0, math.min(300, math.floor(p + 0.5))) end
    local new = S.enabled and S.percent or 100
    if new ~= old then
        log("CONFIG corruption gain %d%% -> %d%% (%s)", old, new, S.enabled and "enabled" or "disabled")
        if new == 100 then S.excess = 0.0 end
    end
end

local function rate() return (S.enabled and S.percent or 100) / 100 end

---------------------------------------------------------------- engine access

local function live(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function fullName(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and type(n) == "string" and n or "?"
end

local function playerPawn()
    local gi = UEHelpers.GetGameInstance()
    if not live(gi) then return nil end
    local lp = gi.LocalPlayers[1]
    if not live(lp) then return nil end
    local pc = lp.PlayerController
    if not live(pc) then return nil end
    local pawn = pc.Pawn
    if live(pawn) then return pawn end
    return nil
end

-- The subsystem: class + SubsystemBlueprintLibrary CDO (cheap), FindAllOf as a fallback (~40 ms, at most
-- every 30 s, 5 tries). A game instance subsystem lives the whole session.
local devClass, sblCdo, devSys = nil, nil, nil
local findRetryAt, findMisses = 0.0, 0

local function devSystem(pawn)
    if live(devSys) then return devSys end
    devSys = nil
    if not live(devClass) then
        devClass = StaticFindObject("/Script/DogwoodCharacterDevelopment.CharacterDevelopmentSubsystem")
    end
    if not live(sblCdo) then
        sblCdo = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    end
    if live(devClass) and live(sblCdo) then
        local ok, sys = pcall(function() return sblCdo:GetGameInstanceSubsystem(pawn, devClass) end)
        if ok and live(sys) then
            devSys = sys
            if not S.pathNoted.sys then S.pathNoted.sys = true log("SUBSYSTEM found via GetGameInstanceSubsystem") end
            return devSys
        end
    end
    local now = os.clock()
    if findMisses >= 5 or now < findRetryAt then return nil end
    findRetryAt = now + 30.0
    local t = os.clock()
    local ok, list = pcall(function() return FindAllOf("CharacterDevelopmentSubsystem") end)
    if ok and type(list) == "table" then
        for _, o in ipairs(list) do
            if live(o) and not fullName(o):find("Default__", 1, true) then devSys = o break end
        end
    end
    if devSys then
        findMisses = 0
        log("SUBSYSTEM found via FindAllOf (%.1f ms)", (os.clock() - t) * 1000)
    else
        findMisses = findMisses + 1
        if findMisses >= 5 then err("subsystem", "CharacterDevelopmentSubsystem not found after 5 searches, mod inactive") end
    end
    return devSys
end

local function readCorruption(sys)
    local lvl, ch = nil, nil
    pcall(function() lvl = sys:GetCurrentMutationLevel() end)
    pcall(function() ch = sys:GetCurrentMutationCharges() end)
    if type(lvl) ~= "number" or type(ch) ~= "number" then return nil, nil end
    return lvl, ch
end

local function readChargeData(set)
    local base, cur = nil, nil
    pcall(function()
        local d = set.MutationCharged
        base, cur = d.BaseValue, d.CurrentValue
    end)
    if type(base) ~= "number" or type(cur) ~= "number" then return nil, nil end
    return base, cur
end

-- Base to value, current moved by the same amount (BetterCorruption's RawWriteCharge). Read back.
local function rawWrite(set, value)
    local base0, cur0 = readChargeData(set)
    if not base0 then return false, "charge unreadable" end
    local wanted = cur0 + (value - base0)
    local ok, e = pcall(function()
        local d = set.MutationCharged
        d.BaseValue = value
        d.CurrentValue = wanted
    end)
    local base, cur = readChargeData(set)
    if base and math.abs(base - value) < 0.001 and math.abs(cur - wanted) < 0.001 then return true end
    return false, ok and string.format("no effect (base %s)", num(base)) or tostring(e)
end

-- Sets the charge to target. Returns ok, how, pending.
local function writeCharge(pawn, sys, target)
    local set = nil
    pcall(function() set = pawn.VampireAttributeSet end)
    if not live(set) then return false, "no VampireAttributeSet on the player" end
    if target < 1.0 then
        -- One unit short would go below zero; a plain write, the next write through the game call syncs it.
        local ok, e = rawWrite(set, target)
        return ok, ok and "plain write (below 1)" or e, false
    end
    local start = target - 1.0
    local ok, e = rawWrite(set, start)
    if not ok then return false, "write before the game call: " .. tostring(e), false end
    S.inOwnCall = true
    local called, cerr = pcall(function() sys:AddMutationCharges(1) end)
    S.inOwnCall = false
    local base = readChargeData(set)
    if called and base and math.abs(base - target) < 0.001 then return true, "game call, landed at once", false end
    if called and base and math.abs(base - start) < 0.001 then return true, "game call, unit pending", true end
    local ok2, e2 = rawWrite(set, target)
    local why = called and string.format("game call read %s", num(base)) or ("game call failed: " .. tostring(cerr))
    return ok2, why .. (ok2 and "; plain write instead" or ("; plain write failed: " .. tostring(e2))), false
end

---------------------------------------------------------------- the tick

local function resetTracking()
    S.level, S.charge, S.excess, S.pending, S.burst = nil, nil, 0.0, nil, nil
    S.exempt = 0.0
end

local function burstAdd(field, v)
    if not S.burst then
        S.burst = { at = os.clock(), raw = 0.0, exempt = 0.0, removed = 0.0, writes = 0 }
    end
    S.burst[field] = S.burst[field] + v
end

local function burstEnd(now)
    local b = S.burst
    if not b or now - S.lastGainAt < BURST_END_S then return end
    S.burst = nil
    S.total.raw = S.total.raw + b.raw
    S.total.removed = S.total.removed + b.removed
    log("GAIN %+.3f (exempt %+.3f) | kept %+.3f, taken back %.3f in %d writes | %.1f s | level %s charge %s | session: %.3f gained, %.3f taken back",
        b.raw + b.exempt, b.exempt, b.raw + b.exempt - b.removed, b.removed, b.writes, S.lastGainAt - b.at,
        tostring(S.level), num(S.charge), S.total.raw, S.total.removed)
end

local function doWrite(pawn, sys, target, why)
    local ok, how, pending = writeCharge(pawn, sys, target)
    if ok then
        S.fails = 0
        if pending then S.pending = { target = target, at = os.clock() } end
        if not S.pathNoted[how] then S.pathNoted[how] = true log("WRITE path: %s (%s, target %s)", how, why, num(target)) end
    else
        S.fails = S.fails + 1
        err("write", string.format("%s (%s, target %s), failure %d", tostring(how), why, num(target), S.fails))
        if S.fails >= MAX_FAILS then
            S.broken = true
            err("write", "too many failures, corruption is no longer scaled this session")
        end
    end
    return ok
end

local function tick()
    if S.broken then return end
    local now = os.clock()
    local pawn = playerPawn()
    if not pawn then return end
    local name = fullName(pawn)
    local key = tostring(pawn:GetAddress()) .. " " .. name
    local isPlayer = name:find("PlayerCharacter", 1, true) ~= nil
    if key ~= S.pawnKey then
        S.pawnKey = key
        burstEnd(math.huge)
        resetTracking()
        S.settleAt = isPlayer and (now + SETTLE_S) or nil
        return
    end
    if not isPlayer then return end
    if S.settleAt then
        if now < S.settleAt then return end
        S.settleAt = nil
    end

    local sys = devSystem(pawn)
    if not sys then return end
    local lvl, ch = readCorruption(sys)
    if not lvl then return end

    if S.level == nil then
        S.level, S.charge = lvl, ch
        log("PLAYER %s | corruption level %d charge %s | gain kept %d%%", name:match("([^%.%s]+)$") or "?", lvl, num(ch), math.floor(rate() * 100 + 0.5))
        return
    end

    if S.pending then
        if ch < S.pending.target - 0.5 then
            if now - S.pending.at < PENDING_S then return end
            local set = nil
            pcall(function() set = pawn.VampireAttributeSet end)
            local ok, e = false, "no VampireAttributeSet"
            if live(set) then ok, e = rawWrite(set, S.pending.target) end
            log("PENDING the game's unit never came: plain write of %s %s", num(S.pending.target), ok and "made" or ("FAILED: " .. tostring(e)))
            lvl, ch = readCorruption(sys)
            if not lvl then S.pending = nil return end
        end
        S.pending = nil
    end

    local exemptLive = S.exempt > 0 and now - S.exemptAt < EXEMPT_S
    if not exemptLive then S.exempt = 0.0 end
    local r = rate()

    if lvl ~= S.level then
        if lvl == S.level + 1 and not exemptLive and r < 1 and ch > 0.0005 then
            local target = ch * r
            burstAdd("raw", ch)
            if doWrite(pawn, sys, target, "carry-over after a level up") then
                burstAdd("removed", ch - target)
                burstAdd("writes", 1)
                log("LEVEL %d -> %d inside one gain: the level stays, carry-over %s scaled to %s", S.level, lvl, num(ch), num(target))
                ch = target
            end
            S.lastGainAt = now
        else
            log("LEVEL %d -> %d (charge %s)%s: left as the game set it", S.level, lvl, num(ch), exemptLive and ", exempt call" or "")
        end
        S.level, S.charge, S.excess = lvl, ch, 0.0
        burstEnd(now)
        return
    end

    local delta = ch - S.charge
    if delta < -0.0005 then
        if delta < -0.01 then log("DROP charge %s -> %s (not ours): new baseline", num(S.charge), num(ch)) end
        S.charge, S.excess = ch, 0.0
        burstEnd(now)
        return
    end
    if delta > 0.0005 then
        if exemptLive then
            local use = math.min(delta, S.exempt)
            S.exempt = S.exempt - use
            delta = delta - use
            burstAdd("exempt", use)
        end
        if delta > 0.0005 then
            burstAdd("raw", delta)
            if r ~= 1 then S.excess = S.excess + delta * (1 - r) end -- r > 1: negative excess = bonus added
        end
        S.lastGainAt = now
    end
    S.charge = ch

    if math.abs(S.excess) >= WRITE_MIN or (math.abs(S.excess) > 0.0005 and now - S.lastGainAt >= QUIET_S) then
        local target = math.max(0.0, ch - S.excess)
        local removed = ch - target
        S.excess = 0.0
        if doWrite(pawn, sys, target, "scaled gain") then
            S.charge = target
            burstAdd("removed", removed)
            burstAdd("writes", 1)
        end
    end
    burstEnd(now)
end

---------------------------------------------------------------- hooks

-- AddMutationCharges from anyone but this mod (story, BetterCorruption's corrections) is not scaled.
-- A Lua call fires this hook (seen by BetterCorruption on SetVampireMutationEnabled).
local hookOk, hookErr = pcall(function()
    RegisterHook("/Script/DogwoodCharacterDevelopment.CharacterDevelopmentSubsystem:AddMutationCharges",
        function(_, value)
            if S.inOwnCall then return end
            local ok, e = pcall(function()
                local v = value
                if type(v) ~= "number" then v = v:get() end
                if type(v) == "number" and v > 0 then
                    S.exempt = S.exempt + v
                    S.exemptAt = os.clock()
                    log("EXEMPT AddMutationCharges(%d) from another caller: not scaled", v)
                end
            end)
            if not ok then err("hook", e) end
        end)
end)

---------------------------------------------------------------- loop

applyConfig(readConfig())

local lastTick, lastConfig = 0.0, os.clock()
local function frame()
    local now = os.clock()
    if now - lastConfig >= CONFIG_S then
        lastConfig = now
        applyConfig(readConfig())
    end
    if now - lastTick >= TICK_S then
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
    print("[CorruptionRate] LoopInGameThreadAfterFrames missing in this UE4SS build, mod inactive\n")
end

log("==== session start %s | gain kept %d%% | hook %s | config %s", VERSION, math.floor(rate() * 100 + 0.5),
    hookOk and "ok" or ("FAILED " .. tostring(hookErr)), CONFIG or "not found, defaults")
print(string.format("[CorruptionRate] %s loaded (%s, gain kept %d%%, log %s, hook %s)\n", VERSION,
    S.enabled and "on" or "off", S.percent, S.logging and "on" or "off", hookOk and "ok" or "FAILED"))
