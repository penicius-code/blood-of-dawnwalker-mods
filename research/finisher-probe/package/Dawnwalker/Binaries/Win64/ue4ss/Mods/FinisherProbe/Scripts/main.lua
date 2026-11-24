-- Finisher Probe 0.3.0 (research for Always Finishers). Read-only: writes nothing to the game.
--
-- Question: why does a killing blow play a finisher or not? The AI side (static read 2026-10-12):
-- logic condition LTC_CheckHPForFinisher = Health / MaxHealth <= AI config FinishersHPPercentage (0.2 for
-- normal humans), then task LTT_SetReadyForFinisher -> native BP_ReadyForFinisher(stub, bEnable) sets the
-- board flag bIsReadyForFinisher. The player side decides natively (unknown), so this probe logs per kill:
--   KILL #n  finisher yes/no, HP before the killing blow, blow size, hits taken below the threshold,
--            ready flag (poll + hook) and when it changed, distance vs FinishersDistance and the global
--            FinishersDistanceThreshold, allows flag, finisher tags, setting, Coen's style and montages,
--            enemies left, enemy type -> "gate guess".
--   HIT      every health drop of an aggressive NPC (by which Coen montage, distance, ready).
--   READY    ready flag changes (poll) and BP_ReadyForFinisher calls (hook).
--   FINISHER every Coen finisher montage start, with the victim's state right before it.
--   once     Finishers game setting, CombatConfig, each AI config, each Coen combat config's finisher table.
-- One game-thread loop (LoopInGameThreadAfterFrames, os.clock gate): every 0.1 s with enemies, 1 s without.
-- Hooks registered from that loop 15 s after start. Kept between ticks: the engine and default objects only;
-- enemies are remembered as address|name -> numbers and strings.
-- Log: FinisherProbe.log next to Dawnwalker.exe (appended, FinisherProbe.old.log past 2 MB) and
-- [FinisherProbe] lines in UE4SS.log.

local VERSION = "0.3.0"
local TAG = "[FinisherProbe] "
local LOG_PATH, LOG_OLD = "FinisherProbe.log", "FinisherProbe.old.log"  -- next to Dawnwalker.exe
local HOOK_MONTAGE = "/Script/DogwoodCombat.CombatComponentBase:OnCombatMontageStarted"
local HOOK_READY = "/Script/RebelAI.RebelAICombatBlueprintFunctionLibrary:BP_ReadyForFinisher"
local HOOK_ASK = "/Script/RebelAI.RebelAIBoardBlueprintFunctionLibrary:GetIsReadyForFinisher"
local BOARD_CDO = "/Script/RebelAI.Default__RebelAIBoardBlueprintFunctionLibrary"
local GUS_CDO = "/Script/Engine.Default__GameUserSettings"
local SETTING_FINISHERS = 60          -- ERebelSetting::Game_Accessibility_ShowFinishers
local HOOK_DELAY = 15                 -- s after start
local TICK_FIGHT, TICK_IDLE = 0.1, 1.0
local MAX_ENEMIES = 16
local KILL_WAIT = 1.0                 -- s after a death before the verdict (a finisher may start late)
local FIN_BEFORE, FIN_AFTER = 3.0, 1.0  -- finisher start within [death - 3 s, death + 1 s] counts
local TAG_WORDS = { "finish", "immortal", "invulner", "dead", "death", "dying", "stun", "unconscious",
    "knock", "helpless", "execut", "ragdoll", "block", "blind", "sand", "trick", "shadow", "slow", "time" }
-- Checked one by one when GetOwnedGameplayTags gives nothing (names from the exe, 2026-10-12).
local FALLBACK_TAGS = { "Character.State.BlockFinisher", "Character.State.AllowFinishersWhenImmortal",
    "Character.State.TargetedByFinisherAbility", "Character.State.Stun", "RebelAI.CharacterState.Finisher",
    "RebelAI.Action.Reaction.Stunned", "Combat.StunAttack", "Abilities.Shadowstorm", "RebelAI.Flag.Unconscious" }
local GAMEPLAY_STATICS = "/Script/Engine.Default__GameplayStatics"

---------------------------------------------------------------- log

do  -- start a fresh file past 2 MB
    local f = io.open(LOG_PATH, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 2 * 1024 * 1024 then
            os.remove(LOG_OLD)
            os.rename(LOG_PATH, LOG_OLD)
        end
    end
end

local lines, t0 = {}, os.clock()

local function flush()
    if #lines == 0 then return end
    local out = table.concat(lines, "\n") .. "\n"
    lines = {}
    local f = io.open(LOG_PATH, "a")
    if f then f:write(out) f:close() end
end

local function log(fmt, ...)
    local s = string.format(fmt, ...)
    print(TAG .. s .. "\n")
    lines[#lines + 1] = string.format("%s %8.2f  %s", os.date("%H:%M:%S"), os.clock() - t0, s)
    if #lines >= 80 then flush() end
end

local errs = {}
local function errOnce(key, fmt, ...)
    errs[key] = (errs[key] or 0) + 1
    if errs[key] <= 3 then log("error (%s): " .. fmt, key, ...) end
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

-- Hook params, array elements, weak pointers: the object inside, or nil.
local function ref(o)
    if live(o) then return o end
    if type(o) ~= "userdata" then return nil end
    local v = try(function() return o:get() end)
    if live(v) then return v end
    v = try(function() return o:Get() end)
    if live(v) then return v end
    return nil
end

local function param(v)
    if type(v) ~= "userdata" then return v end
    local ok, r = pcall(function() return v:get() end)
    if ok and r ~= nil then return r end
    return v
end

local function num(v)
    v = param(v)
    if type(v) == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    end
    if type(v) == "boolean" then return v and 1 or 0 end
    return tonumber(tostring(v))
end

local function bool(v)
    v = param(v)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    return nil
end

-- Native arrays come back as a copied 1-based Lua table in this UE4SS build; TArray just in case.
local function list(v, limit)
    local out = {}
    if type(v) == "table" then
        for i = 1, math.min(#v, limit) do out[i] = v[i] end
    elseif type(v) == "userdata" then
        pcall(function()
            v:ForEach(function(_, e)
                if #out < limit then out[#out + 1] = e end
            end)
        end)
    end
    return out
end

local function fullName(o) return try(function() return o:GetFullName() end) end
local function nameOf(o) return o and try(function() return o:GetFName():ToString() end) or "nil" end

local function objPath(o)
    local full = fullName(o)
    return full and full:match("^%S+%s+(.+)$")
end

local function short(s)
    s = tostring(s or "?")
    return (s:gsub("^Default__", ""):gsub("_C_%d+$", ""):gsub("_C$", ""))
end

local function tagName(k)
    return try(function() return param(k).TagName:ToString() end)
end

local function pct(x) return x and string.format("%.0f%%", x * 100) or "?" end
local function f2(x) return x and string.format("%.2f", x) or "?" end
local function m1(x) return x and string.format("%.1f m", x / 100) or "?" end
local function yn(b) if b == nil then return "?" end return b and "yes" or "no" end

local function find(path)
    local o = try(function() return StaticFindObject(path) end)
    if live(o) then return o end
    return nil
end

---------------------------------------------------------------- player

local engine, engineRetryAt = nil, 0

local function gameEngine()
    if live(engine) then return engine end
    engine = nil
    local now = os.clock()
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 10
    for _, e in ipairs(FindAllOf("GameEngine") or {}) do  -- lint: ok SCAN-IN-LOOP (until found, at most every 10 s)
        if live(e) then engine = e break end
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

local function ownerOf(c)
    return c and ref(try(function() return c:GetOwner() end)) or nil
end

local function distance(a, b)
    local p = a and try(function() return a:K2_GetActorLocation() end)
    local q = b and try(function() return b:K2_GetActorLocation() end)
    if not p or not q then return nil end
    local dx, dy, dz = p.X - q.X, p.Y - q.Y, p.Z - q.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function montageOf(a)
    local m = ref(try(function() return a:GetCurrentMontage() end))
    return m and nameOf(m) or "none"
end

---------------------------------------------------------------- default objects (kept)

local D = { retryAt = 0 }

local function defaults()
    if live(D.board) and live(D.gus) then return true end
    if os.clock() < D.retryAt then return false end
    D.retryAt = os.clock() + 10
    D.board = find(BOARD_CDO)
    D.gus = find(GUS_CDO)
    if not D.logged then
        D.logged = true
        log("default objects: board library %s, GameUserSettings %s", live(D.board) and "found" or "MISSING",
            live(D.gus) and "found" or "MISSING")
    end
    return live(D.board) and live(D.gus)
end

---------------------------------------------------------------- state

local S = {
    setting = nil, settingAt = -100,
    combatCfg = nil, distThreshold = nil,
    style = nil, styles = {},       -- Coen combat config class -> logged
    cfgs = {},                      -- AI config name -> { allows, hp, dist, path }
    selfAsk = false,
    asks = 0, askOwners = {}, askLogAt = 0,
    killSeq = 0, finSeq = 0,
}
local E = {}          -- address|name -> enemy record
local byName = {}     -- actor FName -> key (for hooks)
local coenMontages = {}   -- ring of { t, name }
local finishers = {}      -- { t, victim, montage, id }
local pending = {}        -- enemy records waiting for their verdict

local function keyOf(a)
    local addr = try(function() return a:GetAddress() end)
    return tostring(addr) .. "|" .. nameOf(a)
end

local function recentCoen(before, n)
    local out = {}
    for i = #coenMontages, 1, -1 do
        local c = coenMontages[i]
        if c.t <= before + 0.05 then
            out[#out + 1] = string.format("%s (%.2f s before)", short(c.name), before - c.t)
            if #out >= n then break end
        end
    end
    return #out > 0 and table.concat(out, ", ") or "none"
end

---------------------------------------------------------------- once-per-thing dumps

local function readSetting(now)
    if now - S.settingAt < 10 then return end
    S.settingAt = now
    if not defaults() then return end
    local gs = ref(try(function() return D.gus:GetGameUserSettings() end))
    local out = {}
    local ok = gs and try(function() return gs:GetSetting(SETTING_FINISHERS, out) end)
    local v = ok and num(out.OutSettingValue)
    local s = v and (v ~= 0 and "ON" or "OFF") .. string.format(" (%s)", tostring(v)) or "unreadable"
    if s ~= S.setting then
        S.setting = s
        log("SETTING Finishers (Game_Accessibility_ShowFinishers): %s", s)
    end
end

local function dumpCoenConfig(comp)
    local cfg = ref(try(function() return comp:GetCurrentCombatAnimations() end))
    local cname = cfg and nameOf(try(function() return cfg:GetClass() end)) or "none"
    if cname ~= S.style then
        S.style = cname
        log("Coen style %s", cname)
    end
    if cfg and not S.styles[cname] then
        S.styles[cname] = true
        local rows = {}
        pcall(function()
            cfg.Finishers:ForEach(function(k, v)
                local t = (tagName(k) or "?"):gsub("^RebelAI%.Action%.Finisher%.", "")
                local m = ref(v)
                rows[#rows + 1] = t .. "=" .. (m and short(nameOf(m)) or "nil")
            end)
        end)
        local cat = try(function() return cfg.FinishersCategoryTag.TagName:ToString() end)
        log("  config %s: category %s, %d finisher entries: %s", cname, tostring(cat), #rows, table.concat(rows, " "))
    end
    if not S.combatCfg then
        local cc = ref(try(function() return comp:GetConfig() end))
        if cc then
            S.combatCfg = objPath(cc) or nameOf(cc)
            S.distThreshold = num(try(function() return cc.FinishersDistanceThreshold end))
            local fe = param(try(function() return cc.FinisherEffectClass end))
            log("CombatConfig %s: FinishersDistanceThreshold %s, FinisherEffectClass %s", S.combatCfg,
                tostring(S.distThreshold), short(nameOf(ref(fe))))
        end
    end
end

-- AI config of an enemy, through its stub. Logged once per config; returns name and record.
local function aiConfig(a)
    local stub = ref(try(function() return a.StubComponent.Stub end))
    local def = stub and ref(try(function() return stub:GetAIDefinition() end))
    local cfg = def and ref(try(function() return def:GetAIConfig() end))
    if not cfg then return "unknown", nil, stub end
    local cname = nameOf(cfg)
    if not S.cfgs[cname] then
        local c = {
            allows = bool(try(function() return cfg.bEnemyAllowsFinishers end)),
            hp = num(try(function() return cfg.FinishersHPPercentage end)),
            dist = num(try(function() return cfg.FinishersDistance end)),
            path = objPath(cfg) or "?",
            obj = cfg,   -- a default object (Default__AIConfig_*_C): allowed to be kept
        }
        S.cfgs[cname] = c
        log("AI CONFIG %s (%s): bEnemyAllowsFinishers %s, FinishersHPPercentage %s, FinishersDistance %s; def %s",
            short(cname), c.path, tostring(c.allows), tostring(c.hp), tostring(c.dist), short(nameOf(def)))
    end
    return cname, S.cfgs[cname], stub
end

-- The threshold now (Always Finishers changes it at runtime); logged when it changes.
local function cfgHp(c)
    if not c then return nil end
    local v = live(c.obj) and num(try(function() return c.obj.FinishersHPPercentage end))
    if v and (not c.hp or math.abs(v - c.hp) > 0.0001) then
        log("AI CONFIG %s threshold now %s (was %s)", short(nameOf(c.obj)), tostring(v), tostring(c.hp))
        c.hp = v
    end
    return c.hp
end

local function isReady(stub)
    if not stub or not live(D.board) then return nil end
    S.selfAsk = true
    local r = try(function() return D.board:GetIsReadyForFinisher(stub) end)
    S.selfAsk = false
    return bool(r)
end

-- All owned tags of an actor's ASC as a sorted list. 0.2.0 read `#arr` on the container's array and never got a tag;
-- now the array goes through list() (Lua table or TArray). If that gives nothing, the known tags are checked one by one
-- with the ASC's HasMatchingGameplayTag (interface calls on the actor itself fail in this UE4SS build).
local tagMethodLogged = {}
local function tagList(a, who)
    local asc = ref(try(function() return a.AbilitySystemComponent end))
    if not asc then return nil end
    local out, method = {}, "GetOwnedGameplayTags"
    pcall(function()
        local c = param(asc:GetOwnedGameplayTags())
        for _, t in ipairs(list(c.GameplayTags, 300)) do
            local n = tagName(t)
            if n and n ~= "None" then out[#out + 1] = n end
        end
    end)
    if #out == 0 then
        method = "fallback list"
        for _, t in ipairs(FALLBACK_TAGS) do
            if try(function() return asc:HasMatchingGameplayTag({ TagName = FName(t) }) end) == true then
                out[#out + 1] = t
            end
        end
    end
    if not tagMethodLogged[who] then
        tagMethodLogged[who] = true
        log("tags of %s read via %s (%d now)", who, method, #out)
    end
    table.sort(out)
    return out
end

-- Tags worth showing in KILL / FINISHER lines.
local function interesting(tags)
    local out = {}
    for _, n in ipairs(tags or {}) do
        local low = n:lower()
        for _, w in ipairs(TAG_WORDS) do
            if low:find(w, 1, true) then out[#out + 1] = n break end
        end
    end
    return table.concat(out, ",")
end

-- "+a +b -c" between two sorted tag lists; nil when equal.
local function tagDiff(old, new)
    local was, now, parts = {}, {}, {}
    for _, n in ipairs(old or {}) do was[n] = true end
    for _, n in ipairs(new) do
        now[n] = true
        if not was[n] then parts[#parts + 1] = "+" .. n end
    end
    for _, n in ipairs(old or {}) do if not now[n] then parts[#parts + 1] = "-" .. n end end
    return #parts > 0 and table.concat(parts, " ") or nil
end

---------------------------------------------------------------- verdict

local function finisherFor(e)
    local at = e.deathAt or e.goneAt
    local best = nil
    for _, f in ipairs(finishers) do
        if f.t >= at - FIN_BEFORE and f.t <= at + FIN_AFTER then
            if f.victim == e.name then return f, "victim" end
            if not f.victim or f.victim == "nil" then best = f end
        end
    end
    if best then return best, "unknown victim, same time" end
    return nil, nil
end

local function verdict(e)
    S.killSeq = S.killSeq + 1
    local at = e.deathAt or e.goneAt
    local f, how = finisherFor(e)
    local last = e.hits[#e.hits]
    local c = S.cfgs[e.cfg]
    local thr = cfgHp(c)
    local below = 0
    for _, h in ipairs(e.hits) do
        if thr and h.from <= thr + 0.0001 then below = below + 1 end
    end
    local readyEver = e.readyAt ~= nil or e.hookReadyAt ~= nil
    local guess
    if f then
        guess = "finisher played"
    elseif S.setting and S.setting:find("^OFF") then
        guess = "game setting Finishers is OFF"
    elseif c and c.allows == false then
        guess = "enemy type does not allow finishers"
    elseif e.tags and e.tags:lower():find("blockfinisher", 1, true) then
        guess = "BlockFinisher tag"
    elseif not readyEver then
        if last and thr and last.from > thr + 0.0001 then
            guess = string.format("never ready: killing blow from %s, above the %s threshold", pct(last.from), pct(thr))
        else
            guess = "never ready although below the threshold (AI logic did not run?)"
        end
    elseif e.ready == false and last and last.ready == false then
        guess = "ready was cleared again before the blow"
    elseif last and last.dist and c and c.dist and last.dist > c.dist then
        guess = string.format("too far: %s > FinishersDistance %s", m1(last.dist), m1(c.dist))
    elseif last and last.dist and S.distThreshold and last.dist > S.distThreshold then
        guess = string.format("too far: %s > FinishersDistanceThreshold %s", m1(last.dist), m1(S.distThreshold))
    else
        guess = "none failed (attack type? see Coen montages)"
    end
    log("KILL #%d %s (%s, %s): finisher %s%s | %s | HP before blow %s, blow %s, hits %d (%d below threshold %s) | ready at blow %s, ready first %s, hook %s | dist at blow %s (AI %s, global %s) | allows %s | tags at blow [%s], now [%s] | Coen tags at blow [%s], time %s | Coen %s; montages %s | enemies left %d | setting %s | GATE: %s",
        S.killSeq, short(e.name), short(e.cls), short(e.cfg), f and "YES" or "NO",
        f and string.format(" (#%d %s, %s, %+.2f s)", f.id, short(f.montage), how, f.t - at) or "",
        e.deathAt and "HP reached 0" or string.format("left the aggressive list at HP %s", pct(e.ratio)),
        last and pct(last.from) or "?", last and pct(last.from - last.to) or "?", #e.hits, below, pct(thr),
        yn(last and last.ready), e.readyAt and string.format("HP %s, %.2f s before", pct(e.readyRatio), at - e.readyAt) or "never",
        e.hookReadyAt and string.format("%s %.2f s before", tostring(e.hookEnable), at - e.hookReadyAt) or "never",
        last and m1(last.dist) or "?", c and m1(c.dist) or "?", m1(S.distThreshold), tostring(c and c.allows),
        tostring(last and last.tags), tostring(e.tags), tostring(last and last.coen), tostring(last and last.dil),
        tostring(S.style and short(S.style) or "?"), last and recentCoen(last.t, 3) or "?",
        e.enemiesLeft or -1, tostring(S.setting), guess)
    flush()
end

---------------------------------------------------------------- tick

local function enemyStep(a, pawn, now, count)
    local key = keyOf(a)
    local e = E[key]
    if not e then
        local cname, _, stub = aiConfig(a)
        e = { name = nameOf(a), cls = nameOf(try(function() return a:GetClass() end)), cfg = cname,
            hits = {}, firstAt = now }
        E[key] = e
        byName[e.name] = key
        e.stubOk = stub ~= nil
        log("ENEMY %s (%s), AI config %s%s", short(e.name), short(e.cls), short(cname), stub and "" or ", no stub")
    end
    e.seen = now
    if e.deathAt then return end
    if e.cfg == "unknown" and now - e.firstAt > 1 then  -- stub not ready at first sight: retry once a second
        e.firstAt = now
        e.cfg = aiConfig(a)
        if e.cfg ~= "unknown" then log("ENEMY %s AI config %s (late)", short(e.name), short(e.cfg)) end
    end
    local hp = num(try(function() return a.CharacterAttributeSet.Health.CurrentValue end))
    local mx = num(try(function() return a.CharacterAttributeSet.MaxHealth.CurrentValue end))
    local ratio = hp and mx and mx > 0 and hp / mx or nil
    local dist = distance(a, pawn)
    local stub = ref(try(function() return a.StubComponent.Stub end))
    local ready = isReady(stub)
    local tl = tagList(a, "enemies")
    if ready ~= e.ready then
        if e.ready ~= nil or ready then
            log("READY %s %s (poll) at HP %s, dist %s", short(e.name), tostring(ready), pct(ratio), m1(dist))
        end
        if ready and not e.readyAt then e.readyAt, e.readyRatio = now, ratio end
        e.ready = ready
    end
    if tl then
        local d = tagDiff(e.tagList, tl)
        if d then log("TAGS %s %s%s", short(e.name), e.tagList and "" or "(first) ", d) end
        e.tagList, e.tags = tl, interesting(tl)
    end
    if ratio and e.ratio and ratio < e.ratio - 0.0005 then
        local h = { t = now, from = e.ratio, to = ratio, dist = dist, ready = e.ready, tags = e.tags,
            coen = S.coenTags, dil = S.dil }
        e.hits[#e.hits + 1] = h
        log("HIT %s %s -> %s (-%s) dist %s ready %s | Coen %s, montage %s", short(e.name), pct(h.from), pct(h.to),
            pct(h.from - h.to), m1(dist), tostring(e.ready), recentCoen(now, 1), montageOf(pawn))
    end
    if ratio then e.ratio = ratio end
    e.dist = dist
    if ratio and ratio <= 0 then
        e.deathAt = now
        e.enemiesLeft = count - 1
        pending[#pending + 1] = e
    end
end

-- Coen's own tags (diffs) and time dilation (global + his own), for Shadowstorm / slow motion. Changes only.
local staticsCdo = nil
local function coenState(pawn)
    local tl = tagList(pawn, "Coen")
    if tl then
        local d = tagDiff(S.coenList, tl)
        if d then log("COEN TAGS %s%s", S.coenList and "" or "(first) ", d) end
        S.coenList, S.coenTags = tl, interesting(tl)
    end
    if not live(staticsCdo) then staticsCdo = find(GAMEPLAY_STATICS) end
    local world = engine and ref(try(function() return engine.GameViewport.World end))
    local g = staticsCdo and world and num(try(function() return staticsCdo:GetGlobalTimeDilation(world) end))
    local own = num(try(function() return pawn.CustomTimeDilation end))
    local dil = string.format("global %s, Coen %s", g and string.format("%.2f", g) or "?", own and string.format("%.2f", own) or "?")
    if dil ~= S.dil then
        log("TIME dilation %s", dil)
        S.dil = dil
    end
end

local function tick(now)
    local pawn = playerPawn()
    if not pawn then return false end
    local comp = ref(try(function() return pawn.CombatComponent end))
    readSetting(now)
    if comp then pcall(dumpCoenConfig, comp) end
    local okC, errC = pcall(coenState, pawn)
    if not okC then errOnce("coen", "%s", tostring(errC)) end
    local sub = comp and ref(try(function() return comp.CombatSubsystem end))
    local actors = sub and list(try(function() return sub:GetAllAggressiveNPCActors() end), MAX_ENEMIES) or {}
    local pAddr = try(function() return pawn:GetAddress() end)
    local count = 0
    for _, v in ipairs(actors) do
        local a = ref(v)
        if a and try(function() return a:GetAddress() end) ~= pAddr then count = count + 1 end
    end
    for _, v in ipairs(actors) do
        local a = ref(v)
        if a and try(function() return a:GetAddress() end) ~= pAddr then
            local ok, err = pcall(enemyStep, a, pawn, now, count)
            if not ok then errOnce("enemy", "%s", tostring(err)) end
        end
    end
    -- left the list without HP 0 (died between ticks, fled, combat ended)
    for key, e in pairs(E) do
        if e.seen < now - 0.001 and not e.deathAt and not e.goneAt then
            e.goneAt = now
            e.enemiesLeft = count
            pending[#pending + 1] = e
        end
        if (e.deathAt or e.goneAt) and now - (e.deathAt or e.goneAt) > 30 then
            E[key] = nil
            if byName[e.name] == key then byName[e.name] = nil end
        end
    end
    return count > 0
end

local function verdicts(now)
    local keep = {}
    for _, e in ipairs(pending) do
        if now - (e.deathAt or e.goneAt) >= KILL_WAIT then
            -- never hit: combat ended or it fled, not a kill
            if e.goneAt and #e.hits == 0 and not finisherFor(e) then
                log("GONE %s left the aggressive list at HP %s without being hit, no verdict", short(e.name), pct(e.ratio))
            else
                if e.goneAt then
                    -- the list dropped it before HP 0 was polled: the killing blow was not seen, add it
                    e.hits[#e.hits + 1] = { t = e.goneAt, from = e.ratio or 0, to = 0, dist = e.dist, ready = e.ready }
                end
                local ok, err = pcall(verdict, e)
                if not ok then errOnce("verdict", "%s", tostring(err)) end
            end
        else
            keep[#keep + 1] = e
        end
    end
    pending = keep
    while #finishers > 0 and now - finishers[1].t > 60 do table.remove(finishers, 1) end
    while #coenMontages > 0 and now - coenMontages[1].t > 30 do table.remove(coenMontages, 1) end
end

---------------------------------------------------------------- hooks

local function onMontageStart(ctx, mp)
    local comp = ref(ctx)
    if not comp then return end
    local owner = ownerOf(comp)
    if not nameOf(owner):find("PlayerCharacter", 1, true) then return end
    local m = ref(mp)
    if not m then return end
    local mname = nameOf(m)
    local now = os.clock()
    coenMontages[#coenMontages + 1] = { t = now, name = mname }
    local path = objPath(m) or mname
    if not path:lower():find("finisher", 1, true) then return end
    local prev = finishers[#finishers]
    if prev and prev.montage == mname and now - prev.t < 0.5 then return end

    S.finSeq = S.finSeq + 1
    local victim = ref(try(function() return comp.OpponentBeingKilledByFinisher end))
        or ownerOf(ref(try(function() return comp.CurrentLockTarget end)))
        or ownerOf(ref(try(function() return comp:GetTargetedEnemy() end)))
    local vname = victim and nameOf(victim) or "nil"
    finishers[#finishers + 1] = { t = now, victim = vname, montage = mname, id = S.finSeq }
    local e = E[byName[vname] or ""]
    local hp = victim and num(try(function() return victim.CharacterAttributeSet.Health.CurrentValue end))
    local mx = victim and num(try(function() return victim.CharacterAttributeSet.MaxHealth.CurrentValue end))
    log("FINISHER #%d Coen %s | victim %s HP %s (last polled %s), ready %s, dist %s, tags [%s] | style %s | Coen tags [%s], time %s",
        S.finSeq, path, short(vname), pct(hp and mx and mx > 0 and hp / mx or nil), pct(e and e.ratio),
        tostring(e and e.ready), m1(victim and distance(victim, owner)), tostring(e and e.tags), short(S.style),
        tostring(S.coenTags), tostring(S.dil))
end

local function onReady(_, stubP, enableP)
    local stub = ref(stubP)
    local pawn = stub and ref(try(function() return stub:GetPawn() end))
    local name = pawn and nameOf(pawn) or "nil"
    local enable = bool(enableP)
    local e = E[byName[name] or ""]
    local now = os.clock()
    if e then e.hookReadyAt, e.hookEnable = now, enable end
    local hp = pawn and num(try(function() return pawn.CharacterAttributeSet.Health.CurrentValue end))
    local mx = pawn and num(try(function() return pawn.CharacterAttributeSet.MaxHealth.CurrentValue end))
    log("READY %s %s (hook BP_ReadyForFinisher) at HP %s", short(name), tostring(enable),
        pct(hp and mx and mx > 0 and hp / mx or nil))
end

local function onAsk(_, stubP)
    if S.selfAsk then return end
    S.asks = S.asks + 1
    local stub = ref(stubP)
    local pawn = stub and ref(try(function() return stub:GetPawn() end))
    local name = short(pawn and nameOf(pawn) or "nil")
    S.askOwners[name] = (S.askOwners[name] or 0) + 1
end

local function askReport(now)
    if now - S.askLogAt < 5 then return end
    S.askLogAt = now
    if S.asks == 0 then return end
    local parts = {}
    for n, c in pairs(S.askOwners) do parts[#parts + 1] = n .. " x" .. c end
    log("ASK GetIsReadyForFinisher called %d times in the last 5 s (not by the probe): %s", S.asks, table.concat(parts, ", "))
    S.asks, S.askOwners = 0, {}
end

local function register(path, fn, label)
    local ok, err = pcall(RegisterHook, path, function(...)
        local okF, errF = pcall(fn, ...)
        if not okF then errOnce(label, "%s", tostring(errF)) end
    end)
    log("hook %s: %s", label, ok and "ok" or tostring(err))
end

---------------------------------------------------------------- loop (game thread)

if not LoopInGameThreadAfterFrames then
    log("==== Finisher Probe %s: LoopInGameThreadAfterFrames missing, inactive", VERSION)
    flush()
    return
end

local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("FinisherProbe.loop", TOKEN) end)

local hooked, nextTick, flushAt = false, 0, 0

LoopInGameThreadAfterFrames(1, function()
    local owner = try(function() return ModRef:GetSharedVariable("FinisherProbe.loop") end)
    if owner ~= nil and owner ~= TOKEN then return true end
    local now = os.clock()
    if not hooked then
        if now - t0 < HOOK_DELAY then return false end
        hooked = true
        gameEngine()
        defaults()
        register(HOOK_MONTAGE, onMontageStart, "CombatComponentBase:OnCombatMontageStarted")
        register(HOOK_READY, onReady, "BP_ReadyForFinisher")
        register(HOOK_ASK, onAsk, "GetIsReadyForFinisher")
        log("engine %s", live(engine) and "found" or "not found")
        flush()
    end
    if now >= nextTick then
        local ok, fight = pcall(tick, now)
        if not ok then errOnce("tick", "%s", tostring(fight)) fight = false end
        nextTick = now + (fight and TICK_FIGHT or TICK_IDLE)
        local okV, errV = pcall(verdicts, now)
        if not okV then errOnce("verdicts", "%s", tostring(errV)) end
        askReport(now)
    end
    if now - flushAt >= 2 then
        flushAt = now
        flush()
    end
    return false
end)

log("==== Finisher Probe %s loaded (read-only, log %s, hooks in %d s)", VERSION, LOG_PATH, HOOK_DELAY)
flush()
