-- Level Ceiling 1.1.0 (written from scratch)
--
-- Enemies far above Coen's level are brought down toward him once they are fighting him.
-- Enemies at or below his level are never touched (No Level Scaling keeps those at their
-- area level).
--
--   gap       = enemy level - Coen's level (only when above 0)
--   new level = Coen + min(cap, ceil(gap * GapKept%))      cap: NormalCap / BossCap
--
-- The enemy gets its own stat table row for the new level: every stat its stat profile
-- effect takes from the table (health, damage, stamina, resistances), so it fights like a
-- native enemy of that level. Lighter health (optional) takes only the health from a lower
-- row. The enemy's health percentage is kept.
-- 1.1.0: optional Raise weaker enemies: more than FloorGap levels below Coen -> Coen - FloorGap.
--
-- Light and safe by design:
--   * One LoopAsync (100 ms, off the game thread) reads config.ini every 5 s and writes the
--     log file. It queues one game-thread tick at a time: every 0.3 s in a fight, 0.6 s out.
--   * A tick reads the player through the engine (no object scans) and asks the combat
--     system which enemies are fighting him. Only those are looked at.
--   * Kept between ticks: the engine and a few default objects and classes. Enemies are
--     remembered by address + name with numbers only (their own level), never as objects.
--   * Per tick at most 4 enemy checks and 1 enemy change. Stat tables are read a few
--     columns per tick (1.5 ms budget) and kept as numbers.
--   * No hooks. Fails closed: an enemy whose stats don't match its own stat table is left
--     alone and one line is logged. Coen is never touched.

local VERSION = "1.1.0"
local TAG = "[LevelCeiling] "

local SETTLE_S = 0.5          -- wait after an enemy joins the fight (stats finish loading)
local RECHECK_S = 1.0         -- known enemies: level re-read this often
local TICK_FIGHT_S, TICK_IDLE_S = 0.3, 0.6
local TABLE_BUDGET_S = 0.0015 -- stat table reading per tick
local MAX_ENEMIES = 16
local MAX_RELEVELS = 3        -- the game resets an enemy's level more often: leave it alone
local MAX_FAILS = 3

---------------------------------------------------------------- config

local SCRIPT_DIR = ((debug.getinfo(1, "S").source or ""):gsub("^@", "")):match("^(.*[/\\])") or ""
local CONFIG = nil
for _, p in ipairs({ SCRIPT_DIR .. "../config.ini", "ue4ss/Mods/LevelCeiling/config.ini",
                     "Mods/LevelCeiling/config.ini" }) do
    local f = io.open(p, "r")
    if f then f:close(); CONFIG = p; break end
end

local function int(v, lo, hi, default)
    v = v ~= nil and tonumber(v) or nil
    if not v then return default end
    return math.max(lo, math.min(hi, math.floor(v + 0.5)))
end

local function flag(v, default)
    v = v ~= nil and tonumber(v) or nil
    if v == nil then return default end
    return v ~= 0
end

local function readConfig()
    local c = {}
    local f = CONFIG and io.open(CONFIG, "r")
    if f then
        for line in f:lines() do
            local k, v = (line:gsub(";.*$", "")):match("^%s*([%w_]+)%s*=%s*(%S+)")
            if k then c[k:lower()] = v end
        end
        f:close()
    end
    return {
        enabled = flag(c.enabled, true),
        normalCap = int(c.normalcap, 0, 10, 3),
        bossCap = int(c.bosscap, 0, 15, 6),
        gapKept = int(c.gapkept, 10, 100, 100),
        lighterHealth = flag(c.lighterhealth, false),
        healthGap = int(c.healthgappercent, 0, 100, 35),
        raiseWeaker = flag(c.raiseweaker, false),
        floorGap = int(c.floorgap, 0, 20, 5),
        combatLog = flag(c.combatlog, true),
    }
end

local function describe(c)
    return string.format("%s, cap +%d normal / +%d boss, gap kept %d%%, lighter health %s, raise weaker %s, combat log %s",
        c.enabled and "on" or "OFF", c.normalCap, c.bossCap, c.gapKept,
        c.lighterHealth and (c.healthGap .. "%") or "off",
        c.raiseWeaker and ("to -" .. c.floorGap) or "off", c.combatLog and "on" or "off")
end

local S = { cfg = readConfig(), gen = 1, lines = {}, flushedAt = 0, inFight = false }
S.cfgText = describe(S.cfg)

---------------------------------------------------------------- log

local LOG_PATH, LOG_OLD = "LevelCeiling.log", "LevelCeiling.old.log" -- next to Dawnwalker.exe

do -- start a fresh file past 2 MB
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

local function stamp() return os.date("%Y-%m-%d %H:%M:%S  ") end

-- Combat log (CombatLog = 1): buffered here, written to the file by the async loop.
local function note(fmt, ...)
    if S.cfg.combatLog then S.lines[#S.lines + 1] = stamp() .. string.format(fmt, ...) end
end

-- Load line, settings changes and problems: always, to UE4SS.log and the file.
local function warn(fmt, ...)
    local msg = string.format(fmt, ...)
    print(TAG .. msg .. "\n")
    S.lines[#S.lines + 1] = stamp() .. msg
end

local warned, warnedCount = {}, 0
local function warnOnce(key, fmt, ...)
    key = tostring(key):gsub("%d+", "#")
    if warned[key] or warnedCount >= 50 then return end
    warned[key] = true
    warnedCount = warnedCount + 1
    warn(fmt, ...)
end

local function flushLog()
    if #S.lines == 0 then return end
    local out = table.concat(S.lines, "\n") .. "\n"
    S.lines = {}
    local f = io.open(LOG_PATH, "a")
    if f then f:write(out); f:close() end
end

---------------------------------------------------------------- helpers

local function num(v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
    return nil
end

local function near(a, b)
    a, b = num(a), num(b)
    return a ~= nil and b ~= nil and math.abs(a - b) <= 0.001 * math.max(1, math.abs(a), math.abs(b))
end

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

-- Weak pointers and wrapped values: the object inside, or nil.
local function obj(o)
    if type(o) ~= "userdata" then return nil end
    local ok, v = pcall(function() return o:Get() end)
    if ok and live(v) then return v end
    ok, v = pcall(function() return o:get() end)
    if ok and live(v) then return v end
    if live(o) then return o end
    return nil
end

-- A property that normally holds the object itself.
local function ref(o)
    if live(o) then return o end
    return obj(o)
end

-- Returned array elements and out parameters: the value inside, if wrapped.
local function param(v)
    if type(v) ~= "userdata" then return v end
    local ok, r = pcall(function() return v:get() end)
    if ok and r ~= nil then return r end
    return v
end

local function text(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

local function number(v)
    local s = text(v)
    return s and tonumber(s) or nil
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

local function stat(actor, name)
    return num(try(function() return actor.CharacterAttributeSet[name].CurrentValue end))
end

local function levelOf(actor)
    local v = stat(actor, "Level")
    if v and v >= 1 and v <= 999 then return math.floor(v + 0.5) end
    return nil
end

local function shortName(s)
    s = tostring(s or "?")
    s = s:gsub("^Default__", ""):gsub("_C_%d+$", ""):gsub("_C$", ""):gsub("^NPCDef_", ""):gsub("^BP_", "")
    return s
end

local function shortPath(p) return p:match("([^/%.]+)$") or p end

---------------------------------------------------------------- player

-- The engine lives as long as the game: the one object kept between ticks besides
-- default objects. Everything else is read fresh through it.
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

---------------------------------------------------------------- default objects

local D = { ready = false, retryAt = 0 }
local PROFILE_CLASS = "/Game/_Dawnwalker/Stats/StatProfiles/GE_StatProfile.GE_StatProfile_C"
local PROFILE_CDO = "/Game/_Dawnwalker/Stats/StatProfiles/GE_StatProfile.Default__GE_StatProfile_C"
local HEAL_CLASS = "/Game/_Dawnwalker/Stats/StatsConfig/GE_AddHealthEffect.GE_AddHealthEffect_C"
local HEAL_CDO = "/Game/_Dawnwalker/Stats/StatsConfig/GE_AddHealthEffect.Default__GE_AddHealthEffect_C"
-- Stat table column for each attribute the profile sets; not listed = same name.
local COLUMN = { StaminaBase = "Stamina", HealthRegen = "HealthRegenPerSecond", StaminaRegen = "StaminaRegenPerSecond" }
-- Must match the table before anything is changed, even when they stay the same.
local SIGNATURE = { HealthBase = true, StaminaBase = true, BaseMeleeDamage = true, BaseMagicDamage = true,
    BaseUnarmedDamage = true, FocusResistance = true }

local function find(path)
    local o = try(function() return StaticFindObject(path) end)
    if live(o) then return o end
    return nil
end

-- Once, on the first tick with a player (StaticFindObject is slow in this UE4SS build).
local function setup()
    if D.ready then return true end
    local now = os.clock()
    if now < D.retryAt then return false end
    D.retryAt = now + 10
    D.lib = D.lib or find("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    D.dt = D.dt or find("/Script/Engine.Default__DataTableFunctionLibrary")
    D.profileClass = D.profileClass or find(PROFILE_CLASS)
    D.profile = D.profile or find(PROFILE_CDO)
    if not (D.lib and D.dt and D.profileClass and D.profile) then
        warnOnce("setup", "waiting for the stat profile classes (retry every 10 s)")
        return false
    end
    -- Every SetByCaller entry of the stat profile is a stat taken from the enemy's table.
    local fields, columns, seen = {}, { "HealthSegmentCount", "HealthPerSegment" }, {}
    local mods = D.profile.Modifiers
    for i = 1, #mods do
        local m = mods[i]
        if m.ModifierMagnitude.MagnitudeCalculationType == 3 then
            local name = text(m.Attribute.AttributeName)
            local tag = text(m.ModifierMagnitude.SetByCallerMagnitude.DataTag.TagName)
            if name and tag and tag ~= "None" and not seen[name] then
                seen[name] = true
                local f = { index = i, attr = name }
                if name ~= "Level" and name ~= "HealthBase" then
                    f.column = COLUMN[name] or name
                    columns[#columns + 1] = f.column
                end
                fields[#fields + 1] = f
            end
        end
    end
    if not (seen.Level and seen.HealthBase) then
        D.retryAt = math.huge
        warn("the stat profile has no Level or HealthBase entry: mod inactive")
        return false
    end
    D.fields, D.columns, D.profileAddr = fields, columns, D.profile:GetAddress()
    -- Instant health change, used to keep an enemy's health percentage.
    D.healClass, D.heal = find(HEAL_CLASS), find(HEAL_CDO)
    D.healOK = D.healClass ~= nil and try(function()
        local hm = D.heal.Modifiers
        local m = hm[1]
        return D.heal.DurationPolicy == 0 and #hm == 1 and text(m.Attribute.AttributeName) == "Health"
            and m.ModifierOp == 0 and m.ModifierMagnitude.MagnitudeCalculationType == 3
            and text(m.ModifierMagnitude.SetByCallerMagnitude.DataTag.TagName) == "Combat.Damage.Health"
    end) == true
    D.ready = true
    local names = {}
    for _, f in ipairs(fields) do names[#names + 1] = f.attr end
    warn("ready: the stat profile sets %d stats (%s); health correction %s", #fields,
        table.concat(names, " "), D.healOK and "ok" or "UNAVAILABLE")
    return true
end

---------------------------------------------------------------- stat tables

local T = {} -- tables read so far, numbers only: [path] = { levels, rows, max, next, done, bad, missing }

-- B.deadline is the tick's budget. Past it, one column is still read if none was read
-- this tick yet (B.forced), so a table always makes progress.
local function loadTable(tbl, B)
    local key = try(function() return tbl:GetFullName() end)
    if not key then return nil end
    local t = T[key]
    if t and (t.done or t.bad) then return t end
    if not t then
        t = { levels = {}, rows = {}, max = 0, next = 1, missing = {} }
        T[key] = t
        local out = {}
        local ok, err = pcall(function() D.dt:GetDataTableRowNames(tbl, out) end)
        local names = list(out.OutRowNames or out, 200)
        if not ok then t.bad = tostring(err)
        elseif #names == 0 then t.bad = "no rows" end
        for i, n in ipairs(names) do
            if t.bad then break end
            local lv = number(param(n))
            if not lv or lv ~= math.floor(lv) or t.rows[lv] then
                t.bad = "row names are not levels"
            else
                t.levels[i], t.rows[lv], t.max = lv, {}, math.max(t.max, lv)
            end
        end
        if t.bad then
            warnOnce("table " .. key, "stat table %s skipped: %s", shortPath(key), t.bad)
            return t
        end
    end
    while t.next <= #D.columns and (os.clock() < B.deadline or not B.forced) do
        B.forced = true
        local col = D.columns[t.next]
        local vals = list(try(function() return D.dt:GetDataTableColumnAsString(tbl, FName(col)) end), 200)
        if #vals == #t.levels then
            for i, lv in ipairs(t.levels) do t.rows[lv][col] = number(param(vals[i])) end
        else
            t.missing[#t.missing + 1] = col
        end
        t.next = t.next + 1
    end
    if t.next > #D.columns then
        t.done = true
        note("  stat table %s read (%d levels)", shortPath(key), #t.levels)
        if #t.missing > 0 then
            warnOnce("missing " .. key, "stat table %s has no column for: %s (those stats stay as they are)",
                shortPath(key), table.concat(t.missing, " "))
        end
    end
    return t
end

local function rowAt(t, lv)
    return t.rows[lv] or (lv > t.max and t.rows[t.max]) or nil
end

local function healthAt(t, lv)
    local r = rowAt(t, lv)
    if r and r.HealthSegmentCount and r.HealthPerSegment then return r.HealthSegmentCount * r.HealthPerSegment end
    return nil
end

-- Table value of one profile stat at level lv (health from level hp).
local function valueAt(t, f, lv, hp)
    if f.attr == "Level" then return lv end
    if f.attr == "HealthBase" then return healthAt(t, hp) end
    local r = rowAt(t, lv)
    return r and r[f.column]
end

---------------------------------------------------------------- enemies

local function definitionOf(a)
    local def = ref(try(function() return a.PawnDefinition end))
    if not def then return nil end
    local isClass = try(function() return def:IsClass() end)
    if isClass == nil then isClass = try(function() return def:IsAnyClass() end) end
    if isClass then def = ref(try(function() return def:GetCDO() end)) end
    return def
end

-- The enemy's day and night stat tables (from its equipment and its definition).
local function statTables(a, def)
    local out, seen = {}, {}
    local function add(config)
        config = ref(config)
        if not config then return end
        for _, phase in ipairs({ "DayStats", "NightStats" }) do
            local t = ref(try(function() return config[phase] end))
            if t and not seen[t:GetAddress()] then
                seen[t:GetAddress()] = true
                out[#out + 1] = t
            end
        end
    end
    local stub = ref(try(function() return a.StubComponent.Stub end))
    local proxy = stub and ref(try(function() return stub.EquipmentProxy end))
    if proxy then add(try(function() return proxy:GetEnemyConfig() end)) end
    if def then add(try(function() return def.EnemyConfig end)) end
    return out
end

-- Reads the enemy's tables within the tick budget. Returns the complete ones, and
-- whether all are complete.
local function readTables(a, def, B)
    local tables, ready = {}, true
    for _, tbl in ipairs(statTables(a, def)) do
        local t = loadTable(tbl, B)
        if t and not (t.done or t.bad) then ready = false
        elseif t and t.done then tables[#tables + 1] = t end
    end
    return tables, ready
end

-- Returns the active stat profile handles and the arrays that own them (kept alive by
-- the caller for the rest of the change).
local function profileHandle(asc)
    local found, keep = {}, {}
    local function scan(query)
        local arr = list(try(function() return asc:GetActiveEffects(query) end), 128)
        keep[#keep + 1] = arr
        for _, p in ipairs(arr) do
            local h = param(p)
            local def = try(function() return D.lib:GetGameplayEffectFromActiveEffectHandle(h) end)
            if live(def) and def:GetAddress() == D.profileAddr then found[#found + 1] = h end
        end
    end
    scan({ EffectDefinition = D.profileClass })
    if #found == 0 then scan({}) end
    return found, keep
end

local function setMagnitude(asc, h, f, v)
    local tag = D.profile.Modifiers[f.index].ModifierMagnitude.SetByCallerMagnitude.DataTag
    asc:UpdateActiveGameplayEffectSetByCallerMagnitude(h, tag, v)
end

local function samePlan(x, y)
    if #x ~= #y then return false end
    for i, c in ipairs(x) do
        if c.f ~= y[i].f or not near(c.after, y[i].after) then return false end
    end
    return true
end

-- Moves the enemy from level e.cur (health e.hp) to toL (health toH), using the table that
-- produced its current stats. Returns true, summary or false, reason.
local function transaction(a, e, tables, toL, toH)
    if #tables == 0 then return false, "no readable stat table" end
    local asc = ref(try(function() return a.AbilitySystemComponent end))
    if not asc then return false, "no ability system component" end
    local found, keep = profileHandle(asc)
    if #found ~= 1 then return false, #found .. " stat profile effects instead of 1" end
    local h = found[1]
    local cur = {}
    for _, f in ipairs(D.fields) do
        local attribute = D.profile.Modifiers[f.index].Attribute
        cur[f.attr] = num(try(function() return asc:GetGameplayEffectMagnitude(h, attribute) end))
        if cur[f.attr] == nil then return false, "cannot read " .. f.attr end
    end
    local fromL, fromH = e.cur, e.hp
    if not near(cur.Level, fromL) then
        return false, string.format("stat profile says level %s", tostring(cur.Level))
    end
    -- Every stat the table knows, from its current row to its target row. nil when this
    -- table did not produce the enemy's current stats.
    local function plan(t)
        if not healthAt(t, fromH) then return nil end
        local out = {}
        for _, f in ipairs(D.fields) do
            local from, to = valueAt(t, f, fromL, fromH), valueAt(t, f, toL, toH)
            if from ~= nil and to ~= nil then
                if (SIGNATURE[f.attr] or f.attr == "Level" or not near(from, to))
                    and not near(cur[f.attr], from) then return nil end
                out[#out + 1] = { f = f, before = cur[f.attr], after = to }
            end
        end
        return out
    end
    local steps
    for _, t in ipairs(tables) do
        local p = plan(t)
        if p then
            if steps and not samePlan(steps, p) then return false, "day and night tables both match" end
            steps = steps or p
        end
    end
    if not steps then return false, "stats don't match the enemy's stat table" end
    -- Only what changes; health last, so the new maximum is in place before the percentage.
    local changes, health = {}, nil
    for _, c in ipairs(steps) do
        if not near(c.before, c.after) then
            if c.f.attr == "HealthBase" then health = c else changes[#changes + 1] = c end
        end
    end
    if health then changes[#changes + 1] = health end
    local h0, m0 = stat(a, "Health"), stat(a, "MaxHealth")
    if not h0 or not m0 or h0 <= 0 or m0 <= 0 then return false, "health not readable" end
    local done = {}
    local ok, err = pcall(function()
        for _, c in ipairs(changes) do
            done[#done + 1] = c
            setMagnitude(asc, h, c.f, c.after)
        end
    end)
    local lvNow = levelOf(a)
    if not ok or lvNow ~= toL then
        for i = #done, 1, -1 do pcall(setMagnitude, asc, h, done[i].f, done[i].before) end
        return false, ok and string.format("level reads %s after the change, undone", tostring(lvNow))
            or ("change failed, undone: " .. tostring(err))
    end
    -- Keep the health percentage.
    local m1 = stat(a, "MaxHealth")
    local extra = ""
    if m1 and not near(m1, m0) then
        local want = math.min(1, h0 / m0) * m1
        local now = stat(a, "Health")
        if now and now > 0 and math.abs(now - want) > math.max(1, m1 * 0.002) then
            local fixed = false
            if D.healOK then
                pcall(function()
                    local tag = D.heal.Modifiers[1].ModifierMagnitude.SetByCallerMagnitude.DataTag
                    local spec = asc:MakeOutgoingSpec(D.healClass, 1, asc:MakeEffectContext())
                    asc:BP_ApplyGameplayEffectSpecToSelf(D.lib:AssignTagSetByCallerMagnitude(spec, tag, want - now))
                end)
                local after = stat(a, "Health")
                fixed = after ~= nil and math.abs(after - want) <= math.max(1, m1 * 0.01)
            end
            if not fixed then extra = ", health % not kept" end
        end
    end
    keep = nil -- the handle arrays stay alive until here
    return true, string.format("%d stats, max HP %.0f -> %.0f%s", #changes, m0, m1 or 0, extra)
end

-- Target level and health level for an enemy whose own level is native.
-- 1.1.0: RaiseWeaker lifts enemies more than FloorGap levels below Coen to Coen - FloorGap.
local function desired(native, P, boss)
    local c = S.cfg
    if not c.enabled then return native, native end
    if native < P then
        if c.raiseWeaker and native < P - c.floorGap then
            local lv = math.max(1, P - c.floorGap)
            return lv, lv
        end
        return native, native
    end
    if native == P then return native, native end
    local up = math.min(boss and c.bossCap or c.normalCap, ((native - P) * c.gapKept + 99) // 100)
    local lv = math.min(native, P + up)
    local hp = lv
    if c.lighterHealth and lv > P then hp = P + ((lv - P) * c.healthGap + 50) // 100 end
    return lv, hp
end

---------------------------------------------------------------- fights

local F = nil -- current fight, numbers only

local function endFight(why)
    if not F then return end
    note("fight end%s: %.0f s, %d enemies (%d changed), Coen lowest HP %.0f%%, biggest drop %.0f%% per tick%s; mod %.2f ms avg, %.2f ms max per tick",
        why and (" (" .. why .. ")") or "", F.last - F.start, F.enemies, F.changed, F.low * 100, F.drop * 100,
        F.died and ", Coen died" or "", F.ticks > 0 and F.ms / F.ticks or 0, F.maxMs)
    F = nil
end

local function fightTick(pawn, P, count, now)
    local hp, mx = stat(pawn, "Health"), stat(pawn, "MaxHealth")
    if count > 0 then
        if not F then
            F = { id = now, start = now, last = now, enemies = 0, changed = 0, low = 1, drop = 0,
                  died = false, ms = 0, ticks = 0, maxMs = 0 }
            note("fight start: Coen Lv %d, HP %.0f/%.0f", P, hp or -1, mx or -1)
        end
        F.last = now
    end
    if not F then return end
    if hp and mx and mx > 0 then
        F.low = math.min(F.low, hp / mx)
        if F.prevHp and F.prevHp > hp then F.drop = math.max(F.drop, (F.prevHp - hp) / mx) end
        F.prevHp = hp
        if hp <= 0 then F.died = true end
    end
    if count == 0 and now - F.last > 4 then endFight() end
end

---------------------------------------------------------------- per enemy

local E, enemyCount = {}, 0 -- [address|name] = numbers and strings only

local function firstLook(e, a, sub, def)
    e.name = shortName(def and try(function() return def:GetFName():ToString() end)
        or try(function() return a:GetFName():ToString() end))
    e.boss = def ~= nil and try(function() return def.bIsBoss end) == true
    if not e.boss then
        local cb = ref(try(function() return sub:GetCurrentBossNPC() end))
        e.boss = cb ~= nil and cb:GetAddress() == a:GetAddress()
    end
    local stub = ref(try(function() return a.StubComponent.Stub end))
    -- Unknown counts as hostile: the combat system lists it as fighting Coen.
    e.hostile = (stub and try(function() return stub:IsHostileTowardsPlayer() end)) ~= false
end

local function step(a, P, sub, now, B)
    local key = a:GetAddress() .. "|" .. (try(function() return a:GetFName():ToString() end) or "?")
    local e = E[key]
    if not e then
        e = { first = now, fails = 0, relevels = 0 }
        E[key] = e
        enemyCount = enemyCount + 1
    end
    e.seen = now
    if e.skip then return end
    if now - e.first < SETTLE_S then
        -- Use the wait to read the stat tables of an enemy above Coen.
        if not e.tablesRead and os.clock() < B.deadline then
            local lv = levelOf(a)
            if lv and desired(lv, P, false) ~= lv then
                local _, ready = readTables(a, definitionOf(a), B)
                e.tablesRead = ready
            end
        end
        return
    end
    if e.gen == S.gen and e.checked and now - e.checked < RECHECK_S then return end
    if B.checks <= 0 then return end
    B.checks = B.checks - 1
    e.checked, e.gen = now, S.gen
    local lv, hp = levelOf(a), stat(a, "Health")
    if not lv or not hp or hp <= 0 then return end
    local def
    if e.cur == nil then
        def = definitionOf(a)
        firstLook(e, a, sub, def)
        if not e.hostile then e.skip = true; return end
        e.native, e.cur, e.hp = lv, lv, lv
    elseif lv ~= e.cur then
        -- The game set a level itself (re-scaling, form change): that is its own level now.
        e.relevels = e.relevels + 1
        note("  %s: the game set level %d (was %d)", e.name, lv, e.cur)
        if e.relevels > MAX_RELEVELS then
            e.skip = true
            note("  %s: the game keeps resetting its level, left alone", e.name)
            return
        end
        e.native, e.cur, e.hp = lv, lv, lv
    end
    if F and e.fight ~= F.id then e.fight = F.id; F.enemies = F.enemies + 1 end
    local toL, toH = desired(e.native, P, e.boss)
    local boss = e.boss and " (boss)" or ""
    if toL == e.cur and toH == e.hp then
        if not e.noted then
            e.noted = true
            note("  %s%s Lv %d: %s", e.name, boss, lv, lv < P and "below Coen, unchanged" or lv == P and "Coen's level, unchanged"
                or "within the cap, unchanged")
        end
        return
    end
    if B.writes <= 0 then e.checked = nil; return end
    local tables, ready = readTables(a, def or definitionOf(a), B)
    if not ready then e.checked = nil; return end -- tables still loading, next tick
    B.writes = B.writes - 1
    local t0 = os.clock()
    local ok, msg = transaction(a, e, tables, toL, toH)
    local ms = (os.clock() - t0) * 1000
    local was, wasHp = e.cur, e.hp
    if ok then
        note("  %s%s Lv %d -> %d%s: %s, %.1f ms", e.name, boss, was, toL,
            toH ~= toL and string.format(" (health of Lv %d)", toH) or "", msg, ms)
        if F and (toL ~= e.native or toH ~= e.native) and (was == e.native and wasHp == e.native) then F.changed = F.changed + 1 end
        e.cur, e.hp, e.noted = toL, toH, true
    else
        e.fails = e.fails + 1
        note("  %s%s Lv %d: not changed (%s)", e.name, boss, was, msg)
        warnOnce("fail " .. msg, "an enemy was left alone: %s (details in %s)", msg, LOG_PATH)
        if e.fails >= MAX_FAILS then e.skip = true end
    end
end

-- Keeps the enemy list small; the oldest entries are long dead or despawned.
local function prune()
    local keys = {}
    for k in pairs(E) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return (E[x].seen or 0) < (E[y].seen or 0) end)
    for i = 1, #keys - 300 do E[keys[i]] = nil end
    enemyCount = math.min(#keys, 300)
end

---------------------------------------------------------------- tick (game thread)

local function tick()
    local t0 = os.clock()
    local pawn = playerPawn()
    if not pawn then S.inFight = false; endFight("no player"); return end
    local pAddr = pawn:GetAddress()
    if S.pawnAddr and S.pawnAddr ~= pAddr then endFight("player changed") end
    S.pawnAddr = pAddr
    if not setup() then return end
    local P = levelOf(pawn)
    if not P then return end
    if S.lastLevel and S.lastLevel ~= P then
        S.gen = S.gen + 1
        note("Coen is now level %d", P)
    end
    S.lastLevel = P
    local sub = obj(try(function() return pawn.CombatComponent.CombatSubsystem end))
    if not sub then return end
    local actors = list(try(function() return sub:GetAllAggressiveNPCActors() end), MAX_ENEMIES)
    S.inFight = #actors > 0
    fightTick(pawn, P, #actors, t0)
    local B = { checks = 4, writes = 1, deadline = t0 + TABLE_BUDGET_S, forced = false }
    for _, v in ipairs(actors) do
        local a = ref(v)
        if a and a:GetAddress() ~= pAddr then
            local ok, err = pcall(step, a, P, sub, t0, B)
            if not ok then warnOnce("step " .. tostring(err), "enemy check error: %s", tostring(err)) end
        end
    end
    if enemyCount > 400 then prune() end
    if F then
        local ms = (os.clock() - t0) * 1000
        F.ms, F.ticks, F.maxMs = F.ms + ms, F.ticks + 1, math.max(F.maxMs, ms)
    end
end

---------------------------------------------------------------- loop

-- A hot-reloaded copy takes over and this loop stops (restart the game anyway).
local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("LevelCeiling.loop", TOKEN) end)

local nextConfig, nextTick, busy, busySince = 5, 0, false, 0

LoopAsync(100, function()
    local owner = try(function() return ModRef:GetSharedVariable("LevelCeiling.loop") end)
    if owner ~= nil and owner ~= TOKEN then return true end
    local now = os.clock()
    if now >= nextConfig then
        nextConfig = now + 5
        local c = readConfig()
        local desc = describe(c)
        if desc ~= S.cfgText then
            S.cfg, S.cfgText, S.gen = c, desc, S.gen + 1
            warn("settings changed: %s", desc)
        end
    end
    if #S.lines > 0 and (now - S.flushedAt >= 2 or #S.lines >= 40) then
        S.flushedAt = now
        flushLog()
    end
    if busy and now - busySince < 5 then return false end
    if now < nextTick then return false end
    nextTick = now + (S.inFight and TICK_FIGHT_S or TICK_IDLE_S)
    busy, busySince = true, now
    local ok = pcall(ExecuteInGameThread, function()
        local okT, err = pcall(tick)
        if not okT then warnOnce("tick " .. tostring(err), "tick error: %s", tostring(err)) end
        busy = false
    end)
    if not ok then busy = false end
    return false
end)

warn("Level Ceiling %s loaded: %s (config %s)", VERSION, S.cfgText, CONFIG or "not found, defaults")
