-- Hitch Watch 0.1.1. Always-on background monitor, read-only: it never touches the game.
--
-- Writes HitchWatch.log in this mod's folder (kept across launches, rotates to HitchWatch.old.log):
--   * session header: every Lua/C++ mod UE4SS started and every Vortex mod (name, Nexus id, version),
--     plus what changed since the previous session;
--   * hitches (frame >= 2x base and >= base + HitchMs) with the UE4SS.log lines other mods printed during
--     that frame, so a hitch that some mod logs is named;
--   * recurring hitches: the same period 5+ times in a row (a silent timer in some mod), announced once
--     with period and size, then only counted;
--   * loading stalls (>= 1.5 s) with the lines around them;
--   * Lua errors: the first line of each mod's first error, then counts;
--   * every SummaryMinutes of play: fps, frame time percentiles, dropped frames, hitches, chatty log tags,
--     and this monitor's own cost.
--   * Numpad /: a MARK line (press it when something felt wrong).
--
-- Cost: one Lua call per frame (a clock read and a few sums), a state check once per second (about
-- 0.03 ms measured), and a read of the new UE4SS.log text every 0.5 s. No object scans, no hooks.
-- Only the GameEngine singleton and the GameplayStatics CDO are kept between frames (workspace rule).

local VERSION = "0.1.1"
local TAG = "[HitchWatch] "

local MOD_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])[Ss]cripts[\\/]") or "ue4ss/Mods/HitchWatch/"
local LOG_PATH = MOD_DIR .. "HitchWatch.log"
local OLD_PATH = MOD_DIR .. "HitchWatch.old.log"
local STATE_PATH = MOD_DIR .. "HitchWatch.state"
local UE_LOG = MOD_DIR .. "../../UE4SS.log"
local VORTEX = {
    MOD_DIR .. "../vortex.deployment.dawnwalker-ue4ss.json",
    MOD_DIR .. "../../../vortex.deployment.dawnwalker-ue4ss-injector.json",
    MOD_DIR .. "../../../../../Content/Paks/~mods/vortex.deployment.dawnwalker-pak.json",
    MOD_DIR .. "../../../../../../vortex.deployment.dawnwalker-root.json",
}

local clock = os.clock -- MSVC: wall time since process start, 1 ms resolution

---------------------------------------------------------------- config

local CFG = { HitchMs = 25, SummaryMinutes = 5, TailLog = 1, MaxLogMB = 2 }
do
    local f = io.open(MOD_DIR .. "config.ini", "r")
    if f then
        for line in f:lines() do
            local k, v = line:gsub(";.*$", ""):match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
            if k and CFG[k] ~= nil then CFG[k] = tonumber(v) or CFG[k] end
        end
        f:close()
    end
end

local HITCH_RATIO = 2.0
local HITCH_EXTRA = CFG.HitchMs / 1000
local SPIKE_RATIO = 1.8
local STALL_S = 1.5
local SUMMARY_S = CFG.SummaryMinutes * 60
local MAX_BYTES = math.floor(CFG.MaxLogMB * 1024 * 1024)

---------------------------------------------------------------- own log

local out, outSize = nil, 0

local function openOut()
    if out then return out end
    local f = io.open(LOG_PATH, "a")
    if not f then return nil end
    outSize = f:seek("end") or 0
    out = f
    return out
end

local function writeRaw(text)
    local f = openOut()
    if not f then return end
    f:write(text, "\n")
    f:flush()
    outSize = outSize + #text + 1
    if outSize > MAX_BYTES then
        f:close()
        out = nil
        os.remove(OLD_PATH)
        os.rename(LOG_PATH, OLD_PATH)
    end
end

local function write(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    writeRaw(os.date("%Y-%m-%d %H:%M:%S  ") .. (ok and msg or tostring(fmt)))
end

local function say(fmt, ...) -- UE4SS.log, sparingly
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

---------------------------------------------------------------- helpers

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function unwrap(o)
    if o == nil then return nil end
    if valid(o) then return o end
    local ok, v = pcall(function() return o:get() end)
    if ok and valid(v) then return v end
    return nil
end

local function ms(x) return math.floor(x * 1000 + 0.5) end

local function shorten(s, n)
    s = s:gsub("%s+", " ")
    if #s > n then return s:sub(1, n - 3) .. "..." end
    return s
end

---------------------------------------------------------------- world state (once per second)

local engine, engineRetryAt = nil, 0
local statics = nil

local function gameEngine(now)
    if valid(engine) then return engine end
    engine = nil
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 10
    local ok, e = pcall(FindFirstOf, "GameEngine") -- once per run (a ~38 ms scan, done in the main menu)
    if ok and valid(e) then engine = e end
    return engine
end

local function gameplayStatics()
    if valid(statics) then return statics end
    local ok, g = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and valid(g) then statics = g end
    return statics
end

local st = { inWorld = false, paused = false, cine = false, pawnAddr = nil, pawnIsPlayer = false,
    nextCheck = 0, everInWorld = false }

local function stateCheck(now)
    st.nextCheck = now + 1.0
    local e = gameEngine(now)
    local world, pawn
    if e then
        pcall(function()
            world = unwrap(e.GameViewport.World)
            local lp = unwrap(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
            local pc = lp and unwrap(lp.PlayerController)
            pawn = pc and unwrap(pc.Pawn)
        end)
    end
    local inWorld, paused, cine = false, false, false
    if valid(pawn) then
        local addr = pawn:GetAddress()
        if addr ~= st.pawnAddr then
            st.pawnAddr = addr
            local ok, name = pcall(function() return pawn:GetClass():GetFName():ToString() end)
            st.pawnIsPlayer = ok and type(name) == "string" and name:find("PlayerCharacter", 1, true) ~= nil
        end
        inWorld = st.pawnIsPlayer
        if inWorld then
            local gs = gameplayStatics()
            if gs and world then
                local ok, p = pcall(function() return gs:IsGamePaused(world) end)
                paused = ok and p == true
            end
            local ok, c = pcall(function() return pawn.bCinematicMode end)
            cine = ok and c == true
        end
    else
        st.pawnAddr, st.pawnIsPlayer = nil, false
    end
    if inWorld and not st.everInWorld then st.everInWorld = true end
    st.inWorld, st.paused, st.cine = inWorld, paused, cine
end

---------------------------------------------------------------- UE4SS.log tail

local TS = "%[(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.?%d*)%] "
local tail = { f = nil, pos = 0, rest = "", offset = nil, lastTs = nil, caughtUp = false,
    dayBase = {}, ring = {}, ringNext = 1, startupDone = false, firstTs = nil, early = {} }
local RING = 120
local mods = {}           -- UE4SS mod names started this session
local tagLines = {}       -- window: log lines per tag
local errors = {}         -- session: tag -> { count, first }
local errorsWindow = 0

local function parseTs(s)
    local y, mo, d, H, M, S, frac = s:match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)(%.?%d*)$")
    if not y then return nil end
    local key = y .. mo .. d
    local base = tail.dayBase[key]
    if not base then
        base = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 0, min = 0, sec = 0 })
        tail.dayBase[key] = base
    end
    return base + tonumber(H) * 3600 + tonumber(M) * 60 + tonumber(S) + (tonumber(frac) or 0)
end

local function isError(lower)
    if lower:find("lua_errrun", 1, true) or lower:find("traceback", 1, true) then return true end
    if lower:find("%f[%w_]errors?%f[^%w_]") or lower:find("%f[%w_]exception%f[^%w_]") or lower:find("%f[%w_]fatal%f[^%w_]") then
        if lower:find("%f[%d]0 errors?%f[^%w_]") or lower:find("errors?%s*[=:]%s*0%f[%D]") then return false end
        return true
    end
    return false
end

local writeSessionHeader -- defined below

local function countError(tag, body)
    if tail.lastCounted then return end -- one error per log entry, even with a traceback below it
    tail.lastCounted = true
    errorsWindow = errorsWindow + 1
    local e = errors[tag]
    if not e then
        errors[tag] = { count = 1 }
        local line = string.format("ERROR first from %s: %s", tag, shorten(body, 220))
        if tail.startupDone then write("%s", line) else tail.early[#tail.early + 1] = line end
    else
        e.count = e.count + 1
    end
end

local function onEntry(tsText, text)
    local ts = parseTs(tsText)
    if not ts then return end
    tail.firstTs = tail.firstTs or tsText
    tail.lastTs = ts
    local body = text:match("^%[Lua%] (.*)$") or text
    local tag = body:match("^(%[[^%]]+%])") or (body ~= text and "[Lua]" or "[UE4SS]")

    if tag == "[HitchWatch]" then
        tail.lastTag = tag
        local c = body:match("clock ([%d%.]+)")
        if c then tail.offset = ts - tonumber(c) end
        return
    end

    if not tail.startupDone then
        local m = text:match("^Mod '(.-)' has enabled%.txt") or text:match("^Starting Lua mod '(.-)'")
            or text:match("^Starting C%+%+ mod '(.-)'")
        if m then mods[m] = true end
        if text:find("^Event loop start") then
            tail.startupDone = true
            pcall(writeSessionHeader)
        end
    end

    tagLines[tag] = (tagLines[tag] or 0) + 1
    tail.lastTag, tail.lastBody, tail.lastCounted = tag, body, false
    if isError(body:lower()) then countError(tag, body) end

    tail.ring[tail.ringNext] = { ts = ts, text = body }
    tail.ringNext = tail.ringNext % RING + 1
end

local function onLine(line)
    local s, e, ts = line:find(TS)
    if not s then -- continuation line (multi-line print); a traceback marks the entry above as an error
        if tail.lastTag and tail.lastTag ~= "[HitchWatch]" and line:find("^%s*stack traceback") then
            countError(tail.lastTag, tail.lastBody)
        end
        return
    end
    while s do
        local s2, e2, ts2 = line:find(TS, e + 1)
        onEntry(ts, line:sub(e + 1, s2 and s2 - 1 or -1))
        s, e, ts = s2, e2, ts2
    end
end

local function tailPass(budget)
    if not tail.f then
        tail.f = io.open(UE_LOG, "rb")
        if not tail.f then return end
    end
    tail.f:seek("set", tail.pos)
    local chunk = tail.f:read(budget)
    if not chunk or #chunk == 0 then tail.caughtUp = true return end
    tail.pos = tail.pos + #chunk
    tail.caughtUp = #chunk < budget
    local data = tail.rest .. chunk
    local cut = data:match(".*()\n")
    if not cut then
        tail.rest = #data < 65536 and data or ""
        return
    end
    tail.rest = data:sub(cut + 1)
    for line in data:sub(1, cut):gmatch("([^\n]*)\n") do
        onLine((line:gsub("\r$", "")))
    end
end

-- Lines logged between `from` and `to` (wall clock), newest last, at most n.
local function linesBetween(from, to, n)
    local found = {}
    for i = 0, RING - 1 do
        local r = tail.ring[(tail.ringNext + i - 1) % RING + 1]
        if r and r.ts >= from and r.ts <= to then found[#found + 1] = r end
    end
    table.sort(found, function(a, b) return a.ts < b.ts end)
    local picked = {}
    for i = math.max(1, #found - n + 1), #found do picked[#picked + 1] = shorten(found[i].text, 180) end
    return picked, #found
end

---------------------------------------------------------------- session header

local function readVortex()
    local list, seen = {}, {}
    for _, path in ipairs(VORTEX) do
        local f = io.open(path, "rb")
        if f then
            local text = f:read("a") or ""
            f:close()
            for src in text:gmatch('"source"%s*:%s*"([^"]*)"') do
                if not seen[src] then seen[src] = true; list[#list + 1] = src end
            end
        end
    end
    table.sort(list)
    return list
end

local function vortexLabel(src)
    return src:match("^(.-) %d%d%d%d%-%d%d%-%d%dT%d%d%-%d%dZ %S+$") or src
end

writeSessionHeader = function()
    local luaList = {}
    for name in pairs(mods) do luaList[#luaList + 1] = name end
    table.sort(luaList)
    local vortex = readVortex()

    local prev = { lua = {}, vortex = {}, when = nil, any = false }
    local f = io.open(STATE_PATH, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^(%w+)=(.*)$")
            if k == "lua" then prev.lua[v] = true; prev.any = true
            elseif k == "vortex" then prev.vortex[v] = true
            elseif k == "when" then prev.when = v end
        end
        f:close()
    end

    writeRaw("")
    write("=== SESSION  Hitch Watch %s, UE4SS.log from %s", VERSION, tostring(tail.firstTs))
    write("UE4SS mods (%d): %s", #luaList, table.concat(luaList, ", "))
    write("Vortex mods: %d (full list in HitchWatch.state)", #vortex)
    if not prev.any then
        write("changes: first session with Hitch Watch, nothing to compare")
    else
        local changes = {}
        local nowLua, nowVortex = {}, {}
        for _, n in ipairs(luaList) do
            nowLua[n] = true
            if not prev.lua[n] then changes[#changes + 1] = "+ UE4SS mod " .. n end
        end
        for n in pairs(prev.lua) do
            if not nowLua[n] then changes[#changes + 1] = "- UE4SS mod " .. n end
        end
        for _, s in ipairs(vortex) do
            nowVortex[s] = true
            if not prev.vortex[s] then changes[#changes + 1] = "+ Vortex " .. vortexLabel(s) end
        end
        for s in pairs(prev.vortex) do
            if not nowVortex[s] then changes[#changes + 1] = "- Vortex " .. vortexLabel(s) end
        end
        table.sort(changes, function(a, b) return a:sub(3) < b:sub(3) end)
        if #changes == 0 then
            write("changes since %s: none", tostring(prev.when))
        else
            write("changes since %s (%d):", tostring(prev.when), #changes)
            for _, c in ipairs(changes) do writeRaw("    " .. c) end
        end
    end

    -- Errors logged while the mods were starting, held back so they sit under this header.
    for _, line in ipairs(tail.early) do write("%s", line) end
    tail.early = {}

    local s = io.open(STATE_PATH, "w")
    if s then
        s:write("when=", os.date("%Y-%m-%d %H:%M"), "\n")
        for _, n in ipairs(luaList) do s:write("lua=", n, "\n") end
        for _, v in ipairs(vortex) do s:write("vortex=", v, "\n") end
        s:close()
    end
end

---------------------------------------------------------------- hitches and recurring patterns

local times = {}        -- clock of recent hitches, oldest first (max 40)
local patterns = {}     -- { period, lastT, lastActive, hits, windowHits, extraSum, active }
local pending = {}      -- hitches waiting for their log lines
local activeTime = 0    -- seconds in the world, not paused

local function near(g, p)
    for k = 1, 4 do
        if math.abs(g - p * k) <= math.max(0.15, 0.04 * p * k) then return true end
    end
    return false
end

local function findIn(target, tol)
    for i = #times, 1, -1 do
        if math.abs(times[i] - target) <= tol then return times[i] end
    end
    return nil
end

-- Returns the pattern this hitch belongs to (existing or just found), or nil.
local function classify(t, extra)
    for _, p in ipairs(patterns) do
        if near(t - p.lastT, p.period) then
            p.lastT, p.lastActive = t, activeTime
            p.hits, p.windowHits, p.extraSum = p.hits + 1, p.windowHits + 1, p.extraSum + extra
            if not p.active then
                p.active = true
                write("RECURRING again: every %.2f s", p.period)
            end
            return p
        end
    end
    -- New pattern: a chain of 5+ hitches spaced by the same period (one miss allowed per step).
    for i = #times - 1, math.max(1, #times - 10), -1 do
        local P = t - times[i]
        if P >= 0.3 and P <= 120 then
            local tol = math.max(0.15, 0.04 * P)
            local found, cur, earliest, steps = 1, t, t, 0
            while true do
                local hit = findIn(cur - P, tol)
                local step = 1
                if not hit then hit = findIn(cur - 2 * P, tol * 1.5); step = 2 end
                if not hit then break end
                found, cur, earliest, steps = found + 1, hit, hit, steps + step
                if found >= 12 then break end
            end
            if found >= 5 then
                local period = (t - earliest) / steps
                for _, old in ipairs(patterns) do
                    if not old.active and math.abs(old.period - period) <= 0.05 * period then
                        old.active, old.lastT, old.lastActive = true, t, activeTime
                        old.hits, old.windowHits, old.extraSum = old.hits + found, old.windowHits + found, old.extraSum + extra * found
                        write("RECURRING again: every %.2f s", old.period)
                        return old
                    end
                end
                local p = { period = period, lastT = t, lastActive = activeTime, hits = found,
                    windowHits = found, extraSum = extra * found, active = true }
                if #patterns >= 8 then table.remove(patterns, 1) end
                patterns[#patterns + 1] = p
                write("RECURRING hitch every %.2f s (%d so far, about +%d ms each): a timer in some mod, see watch list",
                    p.period, found, ms(extra))
                say("recurring hitch every %.2f s (+%d ms), see HitchWatch.log", p.period, ms(extra))
                return p
            end
        end
    end
    return nil
end

-- 10+ hitches within 10 s is a frame rate drop (alt-tab, heavy scene, shader compiling), not a mod timer:
-- one BURST line instead of a record per frame.
local burst = { active = false, count = 0 }

local function recentHitches(now, span)
    local n = 0
    for i = #times, 1, -1 do
        if now - times[i] > span then break end
        n = n + 1
    end
    return n
end

local function onHitch(now, dt, base, kind)
    local extra = dt - base
    local p = nil
    if kind == "hitch" then
        times[#times + 1] = now
        if #times > 40 then table.remove(times, 1) end
        if recentHitches(now, 10) >= 10 then
            burst.count = burst.count + 1
            if not burst.active then
                burst.active = true
                write("BURST: 10+ hitches within 10 s%s (frame rate drop: alt-tab, heavy scene or shader compiling); single hitches not listed until it ends",
                    st.cine and " [dialogue/cutscene]" or "")
            end
            return
        end
        p = classify(now, extra)
    end
    pending[#pending + 1] = { clock = now, dt = dt, extra = extra, kind = kind, cine = st.cine, pattern = p }
end

local function finalize(h)
    local lines, total = {}, 0
    if tail.offset then
        local wall = h.clock + tail.offset
        lines, total = linesBetween(wall - h.dt - 0.4, wall + 0.15, h.kind == "stall" and 6 or 4)
    end
    if h.pattern and #lines == 0 then return end -- counted in the pattern
    local head
    if h.kind == "stall" then
        head = string.format("STALL %.1f s (loading screen, alt-tab or freeze)", h.dt)
    else
        head = string.format("hitch %d ms (+%d)%s%s", ms(h.dt), ms(h.extra), h.cine and " [dialogue/cutscene]" or "",
            h.pattern and string.format(" [recurring %.1f s]", h.pattern.period) or "")
    end
    local stamp = tail.offset and os.date("%Y-%m-%d %H:%M:%S", math.floor(h.clock + tail.offset))
        or os.date("%Y-%m-%d %H:%M:%S")
    writeRaw(stamp .. "  " .. head .. (#lines == 0 and "  (no mod logged anything)" or ""))
    if total > #lines then writeRaw(string.format("    (%d lines logged, last %d:)", total, #lines)) end
    for _, l in ipairs(lines) do writeRaw("    near: " .. l) end
end

local function flushPending(now, force)
    local i = 1
    while i <= #pending do
        local h = pending[i]
        local ready = force or now - h.clock > 20
        if not ready and tail.offset and tail.lastTs then
            ready = tail.lastTs > h.clock + tail.offset + 0.5 or (tail.caughtUp and now - h.clock > 3)
        elseif not ready and CFG.TailLog == 0 then
            ready = true
        end
        if ready then
            table.remove(pending, i)
            pcall(finalize, h)
        else
            i = i + 1
        end
    end
end

local function checkPatterns(now)
    if burst.active and recentHitches(now, 10) < 3 then
        write("BURST ended: %d hitches", burst.count)
        burst.active, burst.count = false, 0
    end
    for _, p in ipairs(patterns) do
        if p.active and activeTime - p.lastActive > math.max(6 * p.period, 30) then
            p.active = false
            write("RECURRING stopped: every %.2f s (%d hits)", p.period, p.hits)
        end
    end
end

---------------------------------------------------------------- frame statistics

local function newWindow(now)
    return { startAt = now, active = 0, frames = 0, sum = 0, max = 0, hist = {}, spikes = 0, hitches = 0, stalls = 0 }
end

local win = newWindow(clock())
local base = nil
local cost = { sum = 0, frames = 0, max = 0 }

local function percentile(w, q)
    local want, seen = w.frames * q, 0
    for m = 0, 300 do
        seen = seen + (w.hist[m] or 0)
        if seen >= want then return m end
    end
    return 300
end

local function summary(now)
    local w = win
    if w.frames > 0 then
        write("summary %.1f min played: %.1f fps, frame p50 %d ms p90 %d p99 %d max %d; dropped frames %d, hitches %d, stalls %d; monitor %.3f ms/frame avg, %.1f ms max",
            w.active / 60, w.frames / w.sum, percentile(w, 0.5), percentile(w, 0.9), percentile(w, 0.99), ms(w.max),
            w.spikes, w.hitches, w.stalls, cost.frames > 0 and cost.sum / cost.frames * 1000 or 0, cost.max * 1000)
        for _, p in ipairs(patterns) do
            if p.windowHits > 0 then
                writeRaw(string.format("    recurring every %.2f s: %d hits, avg +%d ms", p.period, p.windowHits,
                    ms(p.extraSum / math.max(1, p.hits))))
            end
        end
        local chatty = {}
        for tag, n in pairs(tagLines) do
            if n >= 100 then chatty[#chatty + 1] = string.format("%s %d", tag, n) end
        end
        if #chatty > 0 then
            table.sort(chatty)
            writeRaw("    chatty log tags (>= 100 lines): " .. table.concat(chatty, ", "))
        end
        if errorsWindow > 0 then
            local list = {}
            for tag, e in pairs(errors) do list[#list + 1] = string.format("%s %d", tag, e.count) end
            table.sort(list)
            writeRaw(string.format("    error lines: %d this window; session totals: %s", errorsWindow, table.concat(list, ", ")))
        end
    end
    for _, p in ipairs(patterns) do p.windowHits = 0 end
    tagLines, errorsWindow = {}, 0
    cost.sum, cost.frames, cost.max = 0, 0, 0
    win = newWindow(now)
    say("clock %.4f", now) -- recalibrates the UE4SS.log time offset
end

local function record(now, dt)
    if dt >= STALL_S then
        if st.everInWorld then
            win.stalls = win.stalls + 1
            onHitch(now, dt, base or 0, "stall")
        end
        return
    end
    if not st.inWorld or st.paused then return end
    activeTime = activeTime + dt
    local w = win
    w.active = w.active + dt
    if not base then base = dt return end
    w.frames, w.sum = w.frames + 1, w.sum + dt
    if dt > w.max then w.max = dt end
    local m = ms(dt)
    local bin = m > 300 and 300 or m
    w.hist[bin] = (w.hist[bin] or 0) + 1
    if dt >= base * SPIKE_RATIO then w.spikes = w.spikes + 1 end
    if dt >= base * HITCH_RATIO and dt >= base + HITCH_EXTRA then
        w.hitches = w.hitches + 1
        onHitch(now, dt, base, "hitch")
    end
    local capped = dt > base * 1.5 and base * 1.5 or dt
    base = base * 0.95 + capped * 0.05
end

---------------------------------------------------------------- loop

local last, own = nil, 0
local nextTail, nextPatternCheck = 0, 0
local markRequested = false
local failed = nil

local function frame(now)
    if now >= st.nextCheck then stateCheck(now) end
    if CFG.TailLog ~= 0 and now >= nextTail then
        nextTail = now + 0.5
        tailPass(st.inWorld and 16384 or 65536)
    end
    if #pending > 0 then flushPending(now, false) end
    if now >= nextPatternCheck then
        nextPatternCheck = now + 1
        checkPatterns(now)
    end
    if markRequested then
        markRequested = false
        write("MARK (Numpad 8)%s%s", st.inWorld and "" or " [not in world]", st.cine and " [dialogue/cutscene]" or "")
        say("mark")
    end
    if win.active >= SUMMARY_S then summary(now) end
end

if not LoopInGameThreadAfterFrames then
    write("Hitch Watch %s: LoopInGameThreadAfterFrames missing in this UE4SS build, inactive", VERSION)
    return
end

LoopInGameThreadAfterFrames(1, function()
    local now = clock()
    if last then
        local ok, err = pcall(record, now, (now - last) - own)
        if not ok and failed ~= tostring(err) then failed = tostring(err); write("internal error (record): %s", failed) end
    end
    last = now
    local ok, err = pcall(frame, now)
    if not ok and failed ~= tostring(err) then failed = tostring(err); write("internal error (frame): %s", failed) end
    own = clock() - now
    cost.sum, cost.frames = cost.sum + own, cost.frames + 1
    if own > cost.max then cost.max = own end
    return false
end)

pcall(RegisterKeyBind, Key.DIVIDE, function() markRequested = true end)

say("%s loaded, writing HitchWatch.log; clock %.4f", VERSION, clock())
