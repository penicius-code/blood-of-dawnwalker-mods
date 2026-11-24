-- Hitch Probe 0.1.0 (research tool). Read-only: measures frame times and what engine lookups cost.
-- Everything goes to UE4SS.log with the [HitchProbe] tag:
--   * one line per hitch (frame >= 2x base and >= base + 25 ms) with the gap to the previous hitch, so a
--     timer-driven mod shows up as a fixed period (0.5 s, 1 s, 3 s, 5 s, ...);
--   * a summary every 30 s in the world (paused frames and loading stalls are not counted): fps, frame time
--     percentiles, spikes (frame >= 1.8x base = a dropped frame) with their times;
--   * a lookup benchmark 20 s after world entry and on Numpad 8: StaticFindObject, FindFirstOf, FindAllOf,
--     property reads, UFunction calls, file reads. One group per frame; its own time is not counted as a hitch.
-- Only the GameEngine singleton and the GameplayStatics CDO are kept between frames (workspace rule).

local VERSION = "0.1.0"
local TAG = "[HitchProbe] "

local HITCH_RATIO = 2.0      -- hitch: frame >= 2x base ...
local HITCH_EXTRA = 0.025    -- ... and >= base + 25 ms
local SPIKE_RATIO = 1.8      -- spike: frame >= 1.8x base (one dropped frame)
local STALL_S = 1.5          -- longer frames are loading / window switches, not counted
local SUMMARY_S = 30
local STATE_S = 1.0
local BENCH_DELAY_S = 20
local MAX_HITCH_LINES = 800
local MAX_SPIKES_LISTED = 60

local clock = os.clock -- MSVC: wall time since process start, 1 ms resolution

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

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

---------------------------------------------------------------- world state (once per second)

local engine, engineRetryAt = nil, 0
local function gameEngine(now)
    if valid(engine) then return engine end
    engine = nil
    if now < engineRetryAt then return nil end
    engineRetryAt = now + 5
    local t0 = clock()
    local ok, e = pcall(FindFirstOf, "GameEngine")
    if ok and valid(e) then
        engine = e
        log("GameEngine found (FindFirstOf took %.1f ms)", (clock() - t0) * 1000)
    end
    return engine
end

local statics = nil
local function gameplayStatics()
    if valid(statics) then return statics end
    local ok, g = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and valid(g) then statics = g end
    return statics
end

-- Fresh every call, never kept: world and player pawn through the engine singleton.
local function worldAndPawn(now)
    local e = gameEngine(now)
    if not e then return nil, nil end
    local world, pawn
    pcall(function()
        world = unwrap(e.GameViewport.World)
        local lp = unwrap(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and unwrap(lp.PlayerController)
        pawn = pc and unwrap(pc.Pawn)
    end)
    return world, pawn
end

local st = {
    inWorld = false, paused = false, cine = false,
    pawnAddr = nil, nextCheck = 0,
    checks = 0, checkMs = 0,
    firstWorldAt = nil,
}

local function stateCheck(now)
    local t0 = clock()
    st.nextCheck = now + STATE_S
    local world, pawn = worldAndPawn(now)
    local inWorld, paused, cine = false, false, false
    if valid(pawn) then
        local addr = pawn:GetAddress()
        if addr ~= st.pawnAddr then
            st.pawnAddr = addr
            local ok, name = pcall(function() return pawn:GetClass():GetFName():ToString() end)
            st.pawnIsPlayer = ok and type(name) == "string" and name:find("PlayerCharacter", 1, true) ~= nil
            log("pawn changed: %s", ok and tostring(name) or "?")
        end
        inWorld = st.pawnIsPlayer == true
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
        st.pawnAddr = nil
    end
    if inWorld ~= st.inWorld then log(inWorld and "in world" or "left world") end
    if inWorld and not st.firstWorldAt then st.firstWorldAt = now end
    st.inWorld, st.paused, st.cine = inWorld, paused, cine
    st.checks = st.checks + 1
    st.checkMs = st.checkMs + (clock() - t0) * 1000
end

---------------------------------------------------------------- lookup benchmark

local function timeIt(label, n, fn)
    local t0 = clock()
    local ok, info = true, nil
    for _ = 1, n do
        ok, info = pcall(fn)
        if not ok then break end
    end
    local ms = (clock() - t0) * 1000
    if not ok then
        log("bench %-46s failed: %s", label, tostring(info))
        return
    end
    log("bench %-46s x%-3d %8.1f ms total %8.3f ms each%s", label, n, ms, ms / n,
        info ~= nil and ("  (" .. tostring(info) .. ")") or "")
end

local function countOf(list)
    return type(list) == "table" and (#list .. " found") or "none"
end

local SWORD = "/Game/_Dawnwalker/Combat/Player/HumanSword/DA_CM_HumanSword.DA_CM_HumanSword"

-- One group per frame. Each group re-resolves the pawn itself.
local BENCH = {
    function(_) timeIt("StaticFindObject class /Script/Engine.GameEngine", 20,
        function() StaticFindObject("/Script/Engine.GameEngine") end) end,
    function(_) timeIt("StaticFindObject asset DA_CM_HumanSword", 20,
        function() StaticFindObject(SWORD) end) end,
    function(pawn)
        local ok, full = pcall(function() return pawn:GetFullName() end)
        local path = ok and type(full) == "string" and full:match("^%S+%s+(.+)$")
        if not path then log("bench StaticFindObject instance: no pawn path") return end
        timeIt("StaticFindObject instance (player pawn path)", 10, function() StaticFindObject(path) end)
    end,
    function(_) timeIt("StaticFindObject miss /Engine/Transient.x", 10,
        function() StaticFindObject("/Engine/Transient.HitchProbe_NotThere") end) end,
    function(_) timeIt("FindFirstOf PlayerController", 5, function() FindFirstOf("PlayerController") end) end,
    function(_) timeIt("FindFirstOf CharacterMaterialParamsConfig", 5,
        function() FindFirstOf("CharacterMaterialParamsConfig") end) end,
    function(_) timeIt("FindAllOf GameEngine", 3, function() return countOf(FindAllOf("GameEngine")) end) end,
    function(_) timeIt("FindAllOf DawnwalkerTraversalMetaData", 1,
        function() return countOf(FindAllOf("DawnwalkerTraversalMetaData")) end) end,
    function(_) timeIt("FindAllOf NPCCombatComponent", 1,
        function() return countOf(FindAllOf("NPCCombatComponent")) end) end,
    function(_) timeIt("FindAllOf CommonActivatableWidget", 1,
        function() return countOf(FindAllOf("CommonActivatableWidget")) end) end,
    function(pawn) timeIt("property read pawn.CharacterMovement", 200,
        function() local _ = pawn.CharacterMovement end) end,
    function(pawn) timeIt("UFunction pawn:K2_GetActorLocation()", 200,
        function() pawn:K2_GetActorLocation() end) end,
    function(pawn) timeIt("pawn:GetFullName()", 100, function() pawn:GetFullName() end) end,
    function(_) timeIt("file open+read ue4ss/UE4SS-settings.ini", 20, function()
        local f = io.open("ue4ss/UE4SS-settings.ini", "r")
        if not f then error("not found") end
        local _ = f:read("a")
        f:close()
    end) end,
}

local bench = { step = nil, startedAt = nil, requested = false, autoDone = false }

local function benchStep(now)
    local _, pawn = worldAndPawn(now)
    if not valid(pawn) then return end -- try again next frame
    if bench.step == 1 then
        bench.startedAt = now
        log("bench start (one group per frame; ms per call; 1 ms clock resolution)")
    end
    local ok, err = pcall(BENCH[bench.step], pawn)
    if not ok then log("bench group %d error: %s", bench.step, tostring(err)) end
    bench.step = bench.step + 1
    if bench.step > #BENCH then
        log("bench done in %.1f s", clock() - bench.startedAt)
        bench.step = nil
    end
end

---------------------------------------------------------------- frame statistics

local function newWindow(now)
    return { startAt = now, frames = 0, sum = 0, max = 0, hist = {}, spikes = 0, hitches = 0, spikeList = {} }
end

local win = newWindow(clock())
local base = nil
local lastHitchAt = nil
local hitchLines = 0
local t0Probe = clock()

local function percentile(w, q)
    local want = w.frames * q
    local seen = 0
    for ms = 0, 300 do
        seen = seen + (w.hist[ms] or 0)
        if seen >= want then return ms end
    end
    return 300
end

local function summary(now)
    local w = win
    if w.frames > 0 then
        log("summary %.0f s: %d frames, %.1f fps, p50 %d ms, p90 %d, p99 %d, max %d; spikes %d, hitches %d; probe state check avg %.2f ms",
            now - w.startAt, w.frames, w.frames / w.sum, percentile(w, 0.5), percentile(w, 0.9),
            percentile(w, 0.99), math.floor(w.max * 1000 + 0.5), w.spikes, w.hitches,
            st.checks > 0 and st.checkMs / st.checks or 0)
        if #w.spikeList > 0 then
            log("spikes (t:ms): %s%s", table.concat(w.spikeList, " "), w.spikes > #w.spikeList and " ..." or "")
        end
    end
    st.checks, st.checkMs = 0, 0
    win = newWindow(now)
end

local function record(now, dt)
    if dt >= STALL_S then
        if st.inWorld then log("stall %.2f s (loading or window switch), not counted", dt) end
        return
    end
    if not st.inWorld or st.paused then return end
    if not base then base = dt return end
    local ms = math.floor(dt * 1000 + 0.5)
    local t = now - t0Probe
    local w = win
    w.frames = w.frames + 1
    w.sum = w.sum + dt
    if dt > w.max then w.max = dt end
    local bin = ms > 300 and 300 or ms
    w.hist[bin] = (w.hist[bin] or 0) + 1
    if dt >= base * SPIKE_RATIO then
        w.spikes = w.spikes + 1
        if #w.spikeList < MAX_SPIKES_LISTED then w.spikeList[#w.spikeList + 1] = string.format("%.2f:%d", t, ms) end
    end
    if dt >= base * HITCH_RATIO and dt >= base + HITCH_EXTRA then
        w.hitches = w.hitches + 1
        local gap = lastHitchAt and string.format("%.2f", now - lastHitchAt) or "-"
        lastHitchAt = now
        if hitchLines < MAX_HITCH_LINES then
            hitchLines = hitchLines + 1
            log("hitch %d ms (base %.1f) t=%.2f gap %s s%s", ms, base * 1000, t, gap, st.cine and " cine" or "")
        end
    end
    -- Spikes pull the base up only a little, so a lasting fps drop still becomes the new base.
    local capped = dt > base * 1.5 and base * 1.5 or dt
    base = base * 0.95 + capped * 0.05
end

---------------------------------------------------------------- loop

local last = nil
local own = 0 -- time this probe spent in the previous frame; taken out of the next frame time
local failed = nil

local function frame(now)
    if now >= st.nextCheck then stateCheck(now) end
    if st.inWorld and not st.paused then
        if not bench.autoDone and st.firstWorldAt and now - st.firstWorldAt >= BENCH_DELAY_S then
            bench.autoDone = true
            bench.requested = true
        end
        if bench.requested and not bench.step then
            bench.requested = false
            bench.step = 1
        end
        if bench.step then benchStep(now) end
    end
    if now - win.startAt >= SUMMARY_S then
        if win.frames > 0 or st.inWorld then summary(now) else win = newWindow(now) end
    end
end

if not LoopInGameThreadAfterFrames then
    log("%s: LoopInGameThreadAfterFrames missing in this UE4SS build, probe inactive", VERSION)
    return
end

LoopInGameThreadAfterFrames(1, function()
    local now = clock()
    if last then
        local ok, err = pcall(record, now, (now - last) - own)
        if not ok and failed ~= tostring(err) then failed = tostring(err); log("record error: %s", failed) end
    end
    last = now
    local ok, err = pcall(frame, now)
    if not ok and failed ~= tostring(err) then failed = tostring(err); log("frame error: %s", failed) end
    own = clock() - now
    return false
end)

pcall(RegisterKeyBind, Key.NUM_EIGHT, function() bench.requested = true end)

log("%s loaded: hitch >= %.1fx base and +%d ms, spike >= %.1fx base, summary every %d s, bench %d s after world entry and on Numpad 8",
    VERSION, HITCH_RATIO, math.floor(HITCH_EXTRA * 1000 + 0.5), SPIKE_RATIO, SUMMARY_S, BENCH_DELAY_S)
