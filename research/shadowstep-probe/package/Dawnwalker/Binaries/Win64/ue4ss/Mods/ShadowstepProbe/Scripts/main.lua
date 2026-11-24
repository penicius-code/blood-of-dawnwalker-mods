-- Shadowstep Probe 0.1.0 (research tool)
--
-- Questions, both while CombatDisengage has the player fleeing (weapon sheathed, player combat
-- component blocked, enemies still hunting):
--   1. Shadowstep only targets enemies (combat Shadowstep = appear behind a target). Which state makes
--      it do that, and what would let it aim at the world again?
--   2. The dodge button crouches (out-of-combat layout). Can a dodge still be started?
--
-- Read-only stream (every 0.1 s on the game thread, logged on change):
--   CombatDisengage phase (its shared variables), player combat component (active, mode, state),
--   combat subsystem (in combat, aggressive NPC count, boss), player gameplay tags (built by name,
--   GetGameplayTagCount), counts of the combat config's player effects (effectively in combat,
--   block player combat, combat started/ended), and the Shadowstep component.
--   Each aim: AIM START line with the full state, target state changes while aiming, AIM END with a
--   summary (how long each target state was shown).
--   Activation rules (tag containers + triggers) of the dodge, crouch and Shadowstep abilities: once,
--   3 s after the first combat, and on every MARK (object scans, ~40 ms each: a visible hitch).
-- Numpad /: MARK line with the full state, plus the ability rules.
-- Numpad *: cycles experiments  off -> A -> B -> off  (off at start). The only writes this probe does:
--   A: the player's "effectively in combat" gameplay effect (combat config EffectivelyInCombatEffectClass)
--      is removed through GAS (RemoveActiveGameplayEffectBySourceEffect) whenever it is present.
--   B: only while CombatDisengage says fleeing: when Coen starts to crouch (or a dodge/crouch input tag
--      appears), call PlayerCombatComponent:TryActivateDodgeAbility() and UnCrouch. If the dodge is
--      refused, try once more inside a momentary UnblockCombat / BlockCombat pair.
--
-- Log: ShadowstepProbe.log next to Dawnwalker.exe. One LoopAsync (100 ms) queues one game-thread tick
-- at a time. Only the engine and gameplay effect classes are kept between ticks.

local VERSION = "0.1.0"
local TAG = "[ShadowstepProbe] "
local TICK_S = 0.1

local WATCH_TAGS = {
    "Player.IsEffectivelyInCombat", "Combat.WeaponInHand", "Combat.Mode", "Combat.Mode.HumanSword",
    "Combat.Mode.VampireSword", "Combat.Mode.HumanHandToHand", "Combat.Mode.VampireHandToHand",
    "Combat.Mode.Fistfight", "Combat.AllowRunning", "Player.Input.Swordfight", "Player.Input.Traversal",
    "Traversal.Shadowstep", "Traversal.Shadowstep.ExtendedAiming", "Abilities.Shadowstep",
    "Abilities.ShadowstepBite", "Abilities.ShadowstepExecution", "Abilities.ShadowstepInProgress",
    "Effect.ShadowstepCooldown", "Effect.InfiniteShadowstep", "CharDev.ShadowstepDisabled", "Player.IsVampire",
    "Player.Input.Crouch", "Player.Input.Dodge", "Player.Input.LongDodge", "Abilities.Dodge",
    "Abilities.ShadowDodge", "Traversal.StandUpFromCrouchBlocked",
}
local RULE_CLASSES = { "GA_Dodge_C", "GA_Input_CombatDodge_C", "GA_Input_Crouch_C", "GA_StartCrouch_C",
    "GA_Shadowstep_C", "GA_ShadowstepBite_C", "GA_ShadowstepExecution_C" }
local RULE_PROPS = { "AbilityTags", "ActivationOwnedTags", "ActivationRequiredTags", "ActivationBlockedTags",
    "SourceRequiredTags", "SourceBlockedTags", "BlockAbilitiesWithTag", "CancelAbilitiesWithTag" }
local EFFECTS = { -- combat config property -> short name
    { "EffectivelyInCombatEffectClass", "effInCombat" },
    { "BlockPlayerCombatEffectClass", "blockPlayer" },
    { "PlayerCombatStartedEffectClass", "combatStarted" },
    { "PlayerCombatEndedEffectClass", "combatEnded" },
}
local AIM_STATE = { [0] = "Invalid", [1] = "Busy", [2] = "Ready" }
local TARGET_STATE = { [0] = "Undefined", [1] = "Normal", [2] = "SnapBehind", [3] = "AntiGrav",
    [4] = "CannotSnapBehind", [5] = "OutOfReach", [6] = "InvalidTarget", [7] = "ForbiddenSurface" }
local SS_STATE = { [0] = "Idle", [1] = "Transition", [2] = "StartMontage", [3] = "EndMontage",
    [4] = "BlendOut", [5] = "TeleportTransition" }

---------------------------------------------------------------- log

local LOG_PATH, LOG_OLD = "ShadowstepProbe.log", "ShadowstepProbe.old.log" -- next to Dawnwalker.exe
local lines, flushedAt = {}, 0

do -- start a fresh file past 3 MB
    local f = io.open(LOG_PATH, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 3 * 1024 * 1024 then
            os.remove(LOG_OLD)
            os.rename(LOG_PATH, LOG_OLD)
        end
    end
end

local t0 = os.clock()
local function stamp() return os.date("%H:%M:%S") .. string.format(" %8.2f  ", os.clock() - t0) end
local function note(fmt, ...) lines[#lines + 1] = stamp() .. string.format(fmt, ...) end
local function raw(s) lines[#lines + 1] = s end
local function warn(fmt, ...)
    local msg = string.format(fmt, ...)
    print(TAG .. msg .. "\n")
    lines[#lines + 1] = stamp() .. msg
end
local warned = {}
local function noteOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    note(fmt, ...)
end
local function flushLog()
    if #lines == 0 then return end
    local out = table.concat(lines, "\n") .. "\n"
    lines = {}
    local f = io.open(LOG_PATH, "a")
    if f then f:write(out); f:close() end
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
local function ref(o)
    if type(o) ~= "userdata" then return nil end
    if live(o) then return o end
    local ok, v = pcall(function() return o:Get() end)
    if ok and live(v) then return v end
    ok, v = pcall(function() return o:get() end)
    if ok and live(v) then return v end
    return nil
end
local function oname(o)
    o = ref(o)
    if not o then return nil end
    return try(function() return o:GetFName():ToString() end)
end
local function fmtv(v)
    if v == nil then return "?" end
    if type(v) == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.3g", v)
    end
    return tostring(v)
end

local engine, engineRetryAt = nil, 0
local function gameEngine()
    if live(engine) then return engine end
    engine = nil
    local now = os.clock()
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 5
    for _, e in ipairs(FindAllOf("GameEngine") or {}) do
        if live(e) then engine = e; break end
    end
    return engine
end
local function playerPawn()
    local e = gameEngine()
    if not e then return nil end
    return try(function()
        local lp = ref(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and ref(lp.PlayerController)
        return pc and ref(pc.Pawn)
    end)
end

local builtTags = nil
local function tagsOf(asc)
    if not builtTags then
        builtTags = {}
        for i, n in ipairs(WATCH_TAGS) do builtTags[i] = { TagName = FName(n) } end
    end
    local out = {}
    for i, n in ipairs(WATCH_TAGS) do
        local c = try(function() return asc:GetGameplayTagCount(builtTags[i]) end)
        if c == nil then noteOnce("tag " .. n, "tag %s not readable", n) end
        if c and c > 0 then out[#out + 1] = n .. (c > 1 and ("x" .. c) or "") end
    end
    return out
end

-- GetGameplayEffectCount(class, instigatorFilter, onGoingCheck): try a null filter first, then the
-- player's own ASC (effects the player applies to itself).
local nullFilterOK = nil
local function effectCount(asc, cls)
    if nullFilterOK ~= false then
        local ok, n = pcall(function() return asc:GetGameplayEffectCount(cls, nil, false) end)
        if ok and type(n) == "number" then nullFilterOK = true; return n end
        if nullFilterOK == nil then
            nullFilterOK = false
            note("GetGameplayEffectCount with a nil instigator failed (%s), using the player's ASC as filter", tostring(n))
        end
    end
    return try(function() return asc:GetGameplayEffectCount(cls, asc, false) end)
end

-- Tag names of an FGameplayTagContainer property (elements via :get(), as sheath_input does).
local function tagList(container)
    local arr = try(function() return container.GameplayTags end)
    if not arr then return nil end
    local out = {}
    pcall(function()
        arr:ForEach(function(_, v)
            local ok, t = pcall(function() return v:get() end)
            if not ok or t == nil then t = v end
            local n = try(function() return t.TagName:ToString() end)
            if n then out[#out + 1] = n end
        end)
    end)
    return out
end
local function dumpRules()
    note("---- ability rules")
    for _, cname in ipairs(RULE_CLASSES) do
        local o = ref(try(function() return FindFirstOf(cname) end))
        if not o then
            note("  %s: not loaded", cname)
        else
            local parts = {}
            for _, prop in ipairs(RULE_PROPS) do
                local l = tagList(try(function() return o[prop] end))
                if l and #l > 0 then parts[#parts + 1] = prop .. "=[" .. table.concat(l, ", ") .. "]" end
            end
            local trig = {}
            pcall(function()
                o.AbilityTriggers:ForEach(function(_, v)
                    local ok, t = pcall(function() return v:get() end)
                    if not ok or t == nil then t = v end
                    trig[#trig + 1] = (try(function() return t.TriggerTag.TagName:ToString() end) or "?")
                        .. "/" .. fmtv(try(function() return t.TriggerSource end))
                end)
            end)
            if #trig > 0 then parts[#parts + 1] = "Triggers=[" .. table.concat(trig, ", ") .. "]" end
            note("  %s (%s): %s", cname, oname(o) or "?", #parts > 0 and table.concat(parts, " ") or "(no tags read)")
        end
    end
end

---------------------------------------------------------------- state

local S = { exp = "off", mark = false, last = nil, aiming = false, aim = nil, removals = 0,
    rulesDone = false, combatSeenAt = nil, prevCrouch = false, prevInput = false, dodgeCool = 0 }

local function read(pawn)
    local st = { tags = {} }
    local pb = try(function() return ModRef:GetSharedVariable("CombatDisengage.rc16.playerBlocked") end)
    local ab = try(function() return ModRef:GetSharedVariable("CombatDisengage.rc16.aiBlocked") end)
    st.cd = pb and (ab and "held" or "fleeing") or (ab and "aiOnly" or "-")

    local comp = ref(try(function() return pawn.CombatComponent end))
    st.comp = comp
    st.crouched = try(function() return pawn.bIsCrouched end)
    if comp then
        st.active = try(function() return comp:IsActive() end)
        st.mode = try(function() return comp.CurrentCombatMode end)
        st.cstate = try(function() return comp:GetCurrentState() end)
        local sub = ref(try(function() return comp.CombatSubsystem end))
        if sub then
            st.inCombat = try(function() return sub:GetIsInCombat() end)
            st.aggr = try(function() return sub:GetAggressiveNpcCount() end)
            st.boss = live(try(function() return sub:GetCurrentBossNPC() end))
            st.cfg = ref(try(function() return sub:GetCombatConfig() end))
        end
    end
    st.focus = try(function() return pawn.bIsInFocusMode end)

    local asc = ref(try(function() return pawn.AbilitySystemComponent end))
    st.asc = asc
    if asc then
        st.tags = tagsOf(asc)
        if st.cfg then
            st.effects = {}
            for _, e in ipairs(EFFECTS) do
                local cls = ref(try(function() return st.cfg[e[1]] end))
                if cls then
                    if e[2] == "effInCombat" then st.effClass = cls end
                    st.effects[#st.effects + 1] = e[2] .. "=" .. fmtv(effectCount(asc, cls))
                else
                    st.effects[#st.effects + 1] = e[2] .. "=noclass"
                end
            end
        end
    end

    local ss = ref(try(function() return pawn.ShadowstepComponent end))
    if ss then
        st.aimOn = try(function() return ss:GetAimingEnabled() end)
        st.aimState = try(function() return ss:GetAimingState() end)
        st.target = try(function() return ss:GetShadowstepTargetState() end)
        st.ssState = try(function() return ss:GetShadowstepState() end)
        st.valid = try(function() return ss:HasValidShadowstepTarget() end)
        st.snapDist = try(function() return ss.SnappingBehindDistance end)
        st.attackR = try(function() return ss.AttackRadius end)
        st.range = try(function() return ss:GetShadowstepHorizontalRange() end)
    end
    return st
end

local function base(st) -- everything except the per-frame aim target
    return string.format("cd=%s | comp active=%s mode=%s state=%s | sub inCombat=%s aggr=%s boss=%s | focus=%s crouched=%s | %s | tags: %s",
        st.cd, fmtv(st.active), fmtv(st.mode), fmtv(st.cstate), fmtv(st.inCombat), fmtv(st.aggr), fmtv(st.boss),
        fmtv(st.focus), fmtv(st.crouched), st.effects and table.concat(st.effects, " ") or "effects ?",
        #st.tags > 0 and table.concat(st.tags, ", ") or "(none)")
end
local function ssText(st)
    return string.format("ss aimOn=%s aim=%s target=%s state=%s valid=%s snapDist=%s attackR=%s range=%s",
        fmtv(st.aimOn), AIM_STATE[st.aimState] or fmtv(st.aimState), TARGET_STATE[st.target] or fmtv(st.target),
        SS_STATE[st.ssState] or fmtv(st.ssState), fmtv(st.valid), fmtv(st.snapDist), fmtv(st.attackR), fmtv(st.range))
end
local function isAiming(st)
    return st.aimOn == true or st.aimState == 1 or st.aimState == 2
        or (type(st.ssState) == "number" and st.ssState ~= 0)
end

local function hasTagNamed(st, name)
    for _, t in ipairs(st.tags) do
        if t == name or t:sub(1, #name + 1) == name .. "x" then return true end
    end
    return false
end
local function expDodge(st, pawn)
    local input = hasTagNamed(st, "Player.Input.Crouch") or hasTagNamed(st, "Player.Input.Dodge")
    local crouchStart = st.crouched == true and not S.prevCrouch
    local inputStart = input and not S.prevInput
    S.prevCrouch, S.prevInput = st.crouched == true, input
    if S.exp ~= "B" or st.cd ~= "fleeing" or not st.comp then return end
    if not (crouchStart or inputStart) or os.clock() < S.dodgeCool then return end
    S.dodgeCool = os.clock() + 0.5
    local ok, r = pcall(function() return st.comp:TryActivateDodgeAbility() end)
    local how = "direct"
    if not (ok and r == true) then
        how = "unblock/dodge/block"
        local okU = pcall(function() st.comp:UnblockCombat() end)
        ok, r = pcall(function() return st.comp:TryActivateDodgeAbility() end)
        local okB, errB = pcall(function() st.comp:BlockCombat() end)
        if not okU or not okB then
            how = how .. string.format(" (unblock %s, block %s %s)", tostring(okU), tostring(okB), tostring(errB))
        end
    end
    local unc = "-"
    if try(function() return pawn.bIsCrouched end) == true then
        unc = tostring(pcall(function() pawn:UnCrouch(false) end))
    end
    note("EXP-B %s: TryActivateDodgeAbility %s = %s, uncrouch %s, crouched now %s",
        crouchStart and "crouch started" or "input tag", how, ok and tostring(r) or ("ERROR " .. tostring(r)),
        unc, fmtv(try(function() return pawn.bIsCrouched end)))
end

local function experiment(st)
    if S.exp ~= "A" or not st.asc or not st.effClass then return end
    local before = effectCount(st.asc, st.effClass)
    if not before or before <= 0 then return end
    local ok, err = pcall(function() st.asc:RemoveActiveGameplayEffectBySourceEffect(st.effClass, nil, -1) end)
    if not ok then
        ok, err = pcall(function() st.asc:RemoveActiveGameplayEffectBySourceEffect(st.effClass, st.asc, -1) end)
    end
    local after = effectCount(st.asc, st.effClass)
    S.removals = S.removals + 1
    if S.removals <= 5 or S.removals % 20 == 0 then
        note("EXP remove effectively-in-combat effect #%d: count %s -> %s%s", S.removals, fmtv(before), fmtv(after),
            ok and "" or (" ERROR " .. tostring(err)))
    end
end

local function tick()
    local pawn = playerPawn()
    if not pawn then S.last = nil; return end
    local st = read(pawn)
    experiment(st)
    expDodge(st, pawn)
    if st.inCombat == true and not S.combatSeenAt then S.combatSeenAt = os.clock() end
    if not S.rulesDone and S.combatSeenAt and os.clock() - S.combatSeenAt >= 3 then
        S.rulesDone = true
        dumpRules()
    end

    local b = base(st)
    if b ~= S.last then
        note("%s", b)
        S.last = b
    end

    local aiming = isAiming(st)
    local tname = TARGET_STATE[st.target] or fmtv(st.target)
    if aiming and not S.aiming then
        S.aim = { start = os.clock(), target = tname, since = os.clock(), time = {} }
        note("AIM START  %s", ssText(st))
    elseif aiming and S.aim and tname ~= S.aim.target then
        local a = S.aim
        a.time[a.target] = (a.time[a.target] or 0) + (os.clock() - a.since)
        note("  aim target %s -> %s  (valid=%s)", a.target, tname, fmtv(st.valid))
        a.target, a.since = tname, os.clock()
    elseif not aiming and S.aiming and S.aim then
        local a = S.aim
        a.time[a.target] = (a.time[a.target] or 0) + (os.clock() - a.since)
        local parts = {}
        for k, v in pairs(a.time) do parts[#parts + 1] = string.format("%s %.1fs", k, v) end
        table.sort(parts)
        note("AIM END    %.1fs: %s | %s", os.clock() - a.start, table.concat(parts, ", "), ssText(st))
        S.aim = nil
    end
    S.aiming = aiming

    if S.mark then
        S.mark = false
        note("MARK  %s", b)
        note("MARK  %s  experiment=%s", ssText(st), S.exp)
        dumpRules()
    end
end

---------------------------------------------------------------- loop

pcall(function()
    RegisterKeyBind(Key.DIVIDE, function() S.mark = true end)
    RegisterKeyBind(Key.MULTIPLY, function()
        S.exp = (S.exp == "off" and "A") or (S.exp == "A" and "B") or "off"
        S.removals = 0
        note("==== EXPERIMENT %s", S.exp == "A" and "A ON (remove the effectively-in-combat effect while present)"
            or S.exp == "B" and "B ON (dodge instead of crouch while fleeing)" or "OFF")
    end)
end)

local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("ShadowstepProbe.loop", TOKEN) end)

local nextTick, busy, busySince = 0, false, 0

LoopAsync(100, function()
    local owner = try(function() return ModRef:GetSharedVariable("ShadowstepProbe.loop") end)
    if owner ~= nil and owner ~= TOKEN then return true end
    local now = os.clock()
    if #lines > 0 and (now - flushedAt >= 2 or #lines >= 60) then
        flushedAt = now
        flushLog()
    end
    if busy and now - busySince < 5 then return false end
    if now < nextTick then return false end
    nextTick = now + TICK_S
    busy, busySince = true, now
    local ok = pcall(ExecuteInGameThread, function()
        local okT, err = pcall(tick)
        if not okT then noteOnce("tick " .. tostring(err):gsub("%d+", "#"), "tick error: %s", tostring(err)) end
        busy = false
    end)
    if not ok then busy = false end
    return false
end)

raw("")
note("---- session start, Shadowstep Probe %s", VERSION)
warn("Shadowstep Probe %s loaded (log %s; Numpad / = mark, Numpad * = experiment)", VERSION, LOG_PATH)
