-- Door Closer 1.1.0
-- Tap Numpad 5 near an open door to close it. Optional (off by default): hold it at a
-- locked door to force the door open.
--
-- Doors are native /Script/DogwoodWorld.Door actors (BP subclasses, DoubleDoor).
-- Closes with the native Door:Close (Method 1, animated) or Door:CloseInstantly
-- (Method 2), after releasing a forced-open state. Forcing = SetDoorState(Open)
-- + Door:Open(pawn), for plain locked and time-locked doors. Key doors stay locked.
--
-- Lightweight: no polling loop. Everything runs on the key press only, and no
-- UObject is kept between presses (the hold check stores the door's path string).

local VERSION = "1.1.0"
local TAG = "[DoorCloser] "
local FRONTEND_CDO = "/Script/DogwoodUI.Default__UIFrontend"
local QUEST_CONFIRM_S = 10

-- EDoorState (CXXHeaderDump DogwoodWorld_enums.hpp)
local OPEN, KEY_LOCKED, DISABLED, INVALID = 0, 3, 6, 7
local STATE_NAMES = {
    [0] = "Open", [1] = "OpenEvenInCombat", [2] = "Locked", [3] = "KeyLocked",
    [4] = "TimeOpenByDay", [5] = "TimeOpenByNight", [6] = "Disabled", [7] = "Invalid",
}

-- UE4SS key name -> Unreal key name, for the hold check (IsInputKeyDown).
local UNREAL_KEYS = {
    NUM_ZERO = "NumPadZero", NUM_ONE = "NumPadOne", NUM_TWO = "NumPadTwo", NUM_THREE = "NumPadThree",
    NUM_FOUR = "NumPadFour", NUM_FIVE = "NumPadFive", NUM_SIX = "NumPadSix", NUM_SEVEN = "NumPadSeven",
    NUM_EIGHT = "NumPadEight", NUM_NINE = "NumPadNine", HOME = "Home", END = "End", INS = "Insert",
    DEL = "Delete", PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
}

local S = {
    logging = false,
    method = 1,
    range = 350,
    bash = false,
    holdMs = 500,
    questWarning = true,
    showInfo = false,
    holdKey = nil,      -- Unreal key name for the hold check
    pendingAt = nil,    -- os.clock() of a running hold check
    warned = nil,       -- { path, at } of the last quest warning
    toastSeq = 0,
    lastToast = nil,
    openDoors = false,  -- OpenDoors mod enabled
    hooked = false,     -- compat hooks registered
    closed = {},        -- full names of doors closed with the key (OpenDoors compat)
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

local CONFIG = findFile("DoorCloser/config.ini")

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

local function applyConfig()
    local c = readConfig()
    S.logging = c.logging == "1"
    S.method = tonumber(c.method or "") or 1
    S.range = tonumber(c.range or "") or 350
    S.bash = c.bash == "1"
    S.holdMs = tonumber(c.holdms or "") or 500
    S.questWarning = c.questwarning ~= "0"
    S.showInfo = c.showinfo == "1"
end

---------------------------------------------------------------- logging

local function log(fmt, ...)
    if not S.logging then return end
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

-- Classes and default objects live as long as the game: kept, re-found if they ever go stale.
local statics = {}
local function static(path)
    local o = statics[path]
    if live(o) then return o end
    o = try(function() return StaticFindObject(path) end)
    statics[path] = live(o) and o or nil
    return statics[path]
end

---------------------------------------------------------------- world

-- The engine lives as long as the game: kept. World, controller and pawn are read fresh.
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

local function playerController()
    local e = gameEngine()
    if not e then return nil end
    return try(function()
        local player = ref(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        return ref(player.PlayerController)
    end)
end

local function playerPawn()
    local pc = playerController()
    return pc and try(function() return ref(pc.Pawn) end)
end

---------------------------------------------------------------- toast

local frontendRetry = 0

-- UIFrontend.GetFrontend(world) (verified in DecapitationFinishers / BloodVials); FindAllOf is the fallback.
local function toastWidget()
    local world = worldOf()
    local cdo = static(FRONTEND_CDO)
    if world and cdo then
        local f = try(function() return ref(cdo:GetFrontend(world)) end)
        local w = f and try(function() return ref(f.ToastWidget) end)
        if w then return w end
    end
    if os.clock() < frontendRetry then return nil end
    frontendRetry = os.clock() + 5
    for _, f in ipairs(FindAllOf("UIFrontend") or {}) do
        local n = try(function() return f:GetFullName() end) or ""
        if live(f) and not n:find("Default__", 1, true) then
            local w = try(function() return ref(f.ToastWidget) end)
            if w then return w end
        end
    end
    return nil
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
            local w = toastWidget()
            if not w then return "no toast widget" end
            local busy = try(function() return w:IsShowingToast() end)
            local ours = S.lastToast ~= nil and os.clock() - S.lastToast < 4
            if busy == true and not ours then return "busy" end
            w:Show({ Type = 0, Message = FText(msg) })
            S.lastToast = os.clock()
            return "shown"
        end)
        if ok and res == "busy" and tries < 8 then
            ExecuteWithDelay(400, function() ExecuteInGameThread(attempt) end)
            return
        end
        log("toast '%s': %s", msg, ok and res or ("error: " .. tostring(res)))
    end
    attempt()
end

---------------------------------------------------------------- doors

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Nearest door to the player within S.range. One object scan per key press
-- (FindAllOf returns subclasses, so double doors are included).
local function findNearestDoor(pawn)
    local okL, ploc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okL then return nil end
    local best, bestD = nil, S.range
    for _, d in ipairs(FindAllOf("Door") or {}) do
        if live(d) then
            local okD, dl = pcall(function() return d:K2_GetActorLocation() end)
            if okD then
                local dd = dist(ploc, dl)
                if dd < bestD then best, bestD = d, dd end
            end
        end
    end
    return best, bestD
end

local function readProp(door, name)
    local ok, v = pcall(function() return door[name] end)
    if ok then return v end
    return nil
end

local function doorState(door)
    return num(try(function() return door:GetDoorState() end)) or num(readProp(door, "DoorState"))
end

-- Guess: doors a quest refers to carry ID tags on their QuestComponent. Read only.
local function questTagCount(door)
    local qc = ref(readProp(door, "QuestComponent"))
    if not qc then return 0 end
    local n = try(function() return #qc.IDTags.GameplayTags end)
    if n == nil then n = try(function() return qc.IDTags.GameplayTags:GetArrayNum() end) end
    return n or 0
end

local function infoSuffix(door)
    if not S.showInfo then return "" end
    local st = doorState(door)
    return string.format(" [%s (%s), quest tags %d]", STATE_NAMES[st] or "?", tostring(st), questTagCount(door))
end

-- "Class /Game/...:PersistentLevel.Actor" -> "/Game/...:PersistentLevel.Actor" for StaticFindObject.
local function pathOf(fullName)
    return fullName and fullName:match("^%S+%s+(.+)$")
end

---------------------------------------------------------------- close

-- Door:Close(WasSystemicallyClosed), Door:CloseInstantly(),
-- Door:SetDoorForcedOpen(bInForcedOpen, InOpenDirection, bFromSave).
-- A door forced open (OpenDoors does this) is released first, then closed.
local function releaseForcedOpen(door)
    if readProp(door, "bForceDoorWideOpen") == true then
        pcall(function() door.bForceDoorWideOpen = false end)
    end
    local dir = readProp(door, "DoorOpenDirection") or 0
    pcall(function() door:SetDoorForcedOpen(false, dir, false) end)
end

local METHODS = {
    -- 1: animated close, same as the game's own (not systemic, so no combat lock)
    [1] = function(door) door:Close(false) return "Close(false)" end,
    -- 2: snap shut without animation
    [2] = function(door) door:CloseInstantly() return "CloseInstantly()" end,
}

---------------------------------------------------------------- OpenDoors compat
-- OpenDoors (Aloncifer, Nexus 140) sets bForceDoorWideOpen in pre-hooks on
-- OnApproachTriggerBeginOverlap and OnTraversalAreaEndOverlap. It does not hook
-- Close. Our pre-hooks are registered on the first key press, after OpenDoors'.
-- They only touch doors closed with the key and store door names, never UObjects.

local DOOR_FN = "/Script/DogwoodWorld.Door:"

local function ctxDoorName(ctx)
    local ok, n = pcall(function() return ctx:get():GetFullName() end)
    return ok and n or nil
end

local function registerCompatHooks()
    if S.hooked or not S.openDoors then return end
    S.hooked = true

    -- Walking away from a door we closed: undo OpenDoors' wide-open flag.
    local ok1, e1 = pcall(RegisterHook, DOOR_FN .. "OnTraversalAreaEndOverlap", function(ctx)
        if next(S.closed) == nil then return end
        local n = ctxDoorName(ctx)
        if n and S.closed[n] then
            pcall(function() ctx:get().bForceDoorWideOpen = false end)
        end
    end)

    -- Walking up to it again: hand the door back to OpenDoors (it may open it).
    local ok2, e2 = pcall(RegisterHook, DOOR_FN .. "OnApproachTriggerBeginOverlap", function(ctx)
        if next(S.closed) == nil then return end
        local n = ctxDoorName(ctx)
        if n then S.closed[n] = nil end
    end)

    log("compat hooks for OpenDoors: TraversalEnd %s, ApproachBegin %s",
        ok1 and "ok" or tostring(e1), ok2 and "ok" or tostring(e2))
end

local function closeDoor(door, d)
    local doorName = door:GetFullName()
    registerCompatHooks()
    releaseForcedOpen(door)

    local fn = METHODS[S.method] or METHODS[1]
    local ok, res = pcall(fn, door)
    log("%s at %.0f cm: %s %s", doorName, d, ok and "closed with" or "FAILED", tostring(res))
    if ok and S.openDoors then S.closed[doorName] = true end
    if S.showInfo then toast("Door closed" .. infoSuffix(door)) end
end

---------------------------------------------------------------- force open

-- Plain locked (2) and time-locked (4, 5) doors. Key doors (3), disabled (6) and
-- invalid (7) are refused. SetDoorState(Open) is saved with the door: the lock stays broken.
local function forceOpen(door, path)
    local info = infoSuffix(door)
    local st = doorState(door)
    if st == KEY_LOCKED then toast("This door needs a key" .. info) return end
    if st == DISABLED or st == INVALID then toast("This door can't be forced" .. info) return end

    if S.questWarning and questTagCount(door) > 0 then
        local w = S.warned
        if not (w and w.path == path and os.clock() - w.at < QUEST_CONFIRM_S) then
            S.warned = { path = path, at = os.clock() }
            toast("This door is part of a quest. Hold again to force it anyway." .. info)
            return
        end
    end
    S.warned = nil

    local pawn = playerPawn()
    local okS, eS = pcall(function() door:SetDoorState(OPEN) end)
    local okO, eO = pcall(function() door:Open(pawn) end)
    log("forced %s: SetDoorState %s, Open %s", path, okS and "ok" or tostring(eS), okO and "ok" or tostring(eO))
    if okS then
        toast("You force the door open" .. info)
    else
        toast("The door won't give" .. info)
    end
end

-- Runs HoldMs after the press: key still down -> force the door, else a hint.
local function finishHold(path, info)
    local pc = playerController()
    local keyName = S.holdKey
    local held = pc and keyName and try(function()
        return pc:IsInputKeyDown({ KeyName = FName(keyName) })
    end)
    if held == nil then toast("Door Closer: can't read the key state" .. info) return end
    if held ~= true then toast("Hold to force the door open" .. info) return end

    local door = ref(try(function() return StaticFindObject(path) end))
    if not door then log("hold: door %s gone", path) return end
    forceOpen(door, path)
end

---------------------------------------------------------------- key press

local function onPress()
    -- A hold check is running (key repeat while held): ignore.
    if S.pendingAt and os.clock() - S.pendingAt < 3 then return end
    S.pendingAt = nil

    applyConfig()
    local pawn = playerPawn()
    if not pawn then return end

    local door, d = findNearestDoor(pawn)
    if not door then log("no door within %s cm", tostring(S.range)) return end

    local unlocked = try(function() return door:IsDoorUnlocked() end)
    if not (S.bash and unlocked == false) then
        closeDoor(door, d)
        return
    end

    -- Locked: wait for the hold. Only the path string is kept.
    local path = pathOf(door:GetFullName())
    if not path then return end
    local info = infoSuffix(door)
    S.pendingAt = os.clock()
    ExecuteWithDelay(S.holdMs, function()
        ExecuteInGameThread(function()
            S.pendingAt = nil
            local ok, err = pcall(finishHold, path, info)
            if not ok then log("hold error: %s", tostring(err)) end
        end)
    end)
end

---------------------------------------------------------------- startup

applyConfig()
local cfg = readConfig()
local keyName = (cfg.key or "NUM_FIVE"):upper()
local key = keyName ~= "" and Key[keyName] or nil
S.holdKey = (cfg.holdkey ~= nil and cfg.holdkey ~= "") and cfg.holdkey or UNREAL_KEYS[keyName]
    or (keyName:match("^F%d+$") and keyName) or (keyName:match("^%u$") and keyName)
if key then
    RegisterKeyBind(key, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(onPress)
            if not ok then log("error: %s", tostring(err)) end
        end)
    end)
elseif keyName ~= "" then
    print(TAG .. "unknown Key '" .. keyName .. "', hotkey disabled\n")
end

S.openDoors = findFile("OpenDoors/enabled.txt") ~= nil

print(string.format("%s%s loaded (key %s, hold key %s%s)\n", TAG, VERSION,
    key and keyName or "none", tostring(S.holdKey), S.openDoors and ", OpenDoors compat" or ""))
