-- NoLockReticle 0.4.4. 0.4.4: FindAllOf bar diagnostic removed (~40 ms hitch per launch). 0.4.3: the helper reticle and helper bar (CombatHelperIndicator / CombatHelperBar, shown at
-- full opacity on enemy attacks: the "flash") follow Opacity / BarOpacity. 0.4.2: every-frame check of 0.4.1 removed again (the game never reset the opacity); Logging 1 adds a
-- combat widget log (attack warning, helper widgets, other widgets on enemies) to find what flashes on enemy attacks. 0.4.0: optional boss bar fade (BossBarOpacity, 100 = untouched). Hides the combat target / lock-on reticle or makes it faint, and fades enemy health bars:
-- the locked target's bar (BarOpacity) and the bars over all other enemies in combat (OtherBarOpacity).
--
-- The reticle is one widget component on the player, ADawnwalkerPlayerCharacter.CombatTargetIndicator
-- (WBP_CombatTargetIndicator_C: diamond, hard-lock frame, arrows). Every tick the mod sets the root widget's
-- RenderOpacity to the configured value (only when the read-back value differs). Animations move the child
-- images, the root opacity multiplies over them.
-- One LoopInGameThreadAfterFrames(1) loop gated by os.clock(). No UObject is kept between ticks: the player is
-- re-resolved every tick through the GameEngine singleton (allowed to be cached). No hotkey.

local VERSION = "0.4.4"
local TAG = "[NoLockReticle] "

local MOD_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])[Ss]cripts[\\/]") or "ue4ss/Mods/NoLockReticle/"

local clock = os.clock -- MSVC: wall time since process start, 1 ms resolution

---------------------------------------------------------------- config

local CFG = { Enabled = 1, Opacity = 0, BarOpacity = 35, OtherBarOpacity = 25, BossBarOpacity = 50, Logging = 1, TickMs = 100 }
local CONFIG_EVERY_S = 2.0

local function readConfig()
    local f = io.open(MOD_DIR .. "config.ini", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:gsub(";.*$", ""):match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
        if k and CFG[k] ~= nil then CFG[k] = tonumber(v) or CFG[k] end
    end
    f:close()
    for _, k in ipairs({ "Opacity", "BarOpacity", "OtherBarOpacity", "BossBarOpacity" }) do
        if CFG[k] < 0 then CFG[k] = 0 elseif CFG[k] > 100 then CFG[k] = 100 end
    end
    if CFG.TickMs < 16 then CFG.TickMs = 16 end
end
readConfig()

---------------------------------------------------------------- logging (change based)

local function say(fmt, ...)
    if CFG.Logging == 0 then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

local lastSaid = {}
-- Logs only when the text for `key` differs from the last one, so polled state does not flood UE4SS.log.
local function sayChanged(key, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    msg = ok and msg or tostring(fmt)
    if lastSaid[key] == msg then return end
    lastSaid[key] = msg
    say("%s", msg)
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

local function playerPawn(now)
    local e = gameEngine(now)
    if not e then return nil end
    local pawn
    pcall(function()
        local lp = unwrap(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        local pc = lp and unwrap(lp.PlayerController)
        pawn = pc and unwrap(pc.Pawn)
    end)
    return valid(pawn) and pawn or nil
end

---------------------------------------------------------------- widgets

local SETTLE_S = 3.0 -- wait after load, death or respawn before touching a new pawn
local pawnAddr, settleUntil = nil, 0
local restorePending = false -- Enabled went 1 -> 0: put the game's opacity (1.0) back once

-- Classes and CDOs only (allowed to be cached); looked up once with StaticFindObject (~0.1 ms each).
local statics = {}
local function static(path)
    local o = statics[path]
    if valid(o) then return o end
    local ok, v = pcall(StaticFindObject, path)
    statics[path] = (ok and valid(v)) and v or nil
    return statics[path]
end
local SUBLIB_CDO = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local COMBAT_SUBSYSTEM = "/Script/DogwoodCombat.CombatSubsystem"
local WIDGET_COMPONENT = "/Script/UMG.WidgetComponent"
local HUD_MANAGER = "/Script/DogwoodUI.HUDManagerSubsystem"

-- Calls fn(element) for every element of a UFunction return array (Lua table or TArray userdata).
local function each(arr, fn)
    if arr == nil then return end
    if type(arr) == "table" then
        for _, v in pairs(arr) do
            local o = unwrap(v)
            if o then fn(o) end
        end
        return
    end
    pcall(function()
        arr:ForEach(function(_, v)
            local o = unwrap(v)
            if o then fn(o) end
        end)
    end)
end

-- Fresh widget of one of the player's components, or nil. Never store the result outside one tick.
local function componentWidget(pawn, prop)
    local widget
    pcall(function()
        local comp = unwrap(pawn[prop])
        if not comp then return end
        widget = unwrap(comp:GetUserWidgetObject())
    end)
    return widget
end

local resets = {} -- per widget: how often the game put its own opacity back
-- Sets the root RenderOpacity when it differs from `target`; a plain read otherwise. `logKey` nil: quiet.
local function setOpacity(widget, target, logKey)
    local okRead, cur = pcall(function() return widget.RenderOpacity end)
    if okRead and type(cur) == "number" and math.abs(cur - target) < 0.001 then return true end
    if not valid(widget) then return false end
    local ok, e = pcall(function() widget:SetRenderOpacity(target) end)
    if not ok then
        sayChanged("err_" .. (logKey or "bar"), "%s SetRenderOpacity failed: %s", logKey or "bar", tostring(e))
        return false
    end
    if logKey then
        resets[logKey] = (resets[logKey] or 0) + 1
        sayChanged("set_" .. logKey, "%s opacity %.2f -> %.2f (reset #%d)", logKey, okRead and tonumber(cur) or -1, target,
            resets[logKey])
    end
    return true
end

local function isCharacterBar(widget)
    local ok, name = pcall(function() return widget:GetClass():GetFName():ToString() end)
    return ok and type(name) == "string" and name:find("CombatCharacterBar", 1, true) ~= nil
end

local function barTargetAddr(widget)
    local addr
    pcall(function()
        local c = unwrap(widget["Target Character"])
        addr = c and c:GetAddress() or nil
    end)
    return addr
end

-- Player's own widgets: the reticle and the bar over the locked target.
local function applyPlayerWidget(pawn, name, prop, target)
    local widget = componentWidget(pawn, prop)
    if not widget then
        sayChanged("widget_" .. name, "%s widget not found yet", name)
        return false, nil
    end
    sayChanged("widget_" .. name, "%s widget found (%s)", name, tostring(widget:GetFullName()))
    return setOpacity(widget, target, name), widget
end

-- Test builds only (Logging 1): which combat widgets show during an enemy attack (0.4.1 found the reticle and bar
-- opacity never reset, so the flash is another widget). Change based, at most WATCH_MAX_LINES lines per session.
local WATCH_MAX_LINES = 400
local watchLines = 0
local function watchSay(key, fmt, ...)
    if CFG.Logging == 0 or watchLines >= WATCH_MAX_LINES then return end
    local ok, msg = pcall(string.format, fmt, ...)
    msg = ok and msg or tostring(fmt)
    if lastSaid[key] == msg then return end
    lastSaid[key] = msg
    watchLines = watchLines + 1
    say("watch %.1f s %s", clock(), msg) -- time only in the output, so the change check ignores it
    if watchLines == WATCH_MAX_LINES then say("watch: %d lines, combat widget log stops", WATCH_MAX_LINES) end
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and tostring(n) or "?"
end

-- "comp visible <bool> | widget <class> vis <ESlateVisibility> opacity <root>": opacity in 0.1 steps against animation spam.
local function widgetState(comp, widget)
    local compVis, wVis, op = "?", "?", "?"
    pcall(function() compVis = tostring(comp:IsVisible()) end)
    if not widget then return string.format("comp visible %s | no widget", compVis) end
    pcall(function() wVis = tostring(widget:GetVisibility()) end)
    pcall(function() op = string.format("%.1f", widget.RenderOpacity) end)
    return string.format("comp visible %s | widget %s vis %s opacity %s", compVis, className(widget), wVis, op)
end

-- Player widget components besides the reticle and target bar (docs\engine-knowledge.md).
local WATCH_PROPS = { "AttackWarningIndicator" } -- the helper widgets are faded since 0.4.3
local function watchPlayerWidgets(pawn)
    if CFG.Logging == 0 then return end
    for _, prop in ipairs(WATCH_PROPS) do
        local comp, widget
        pcall(function()
            comp = unwrap(pawn[prop])
            widget = comp and unwrap(comp:GetUserWidgetObject())
        end)
        if comp then
            watchSay("watch_" .. prop, "%s: %s", prop, widgetState(comp, widget))
        else
            watchSay("watch_" .. prop, "%s: component not found", prop)
        end
    end
end

-- Non-bar widgets on aggressive enemies: each class logged once with its first state.
local enemyWidgetClasses = {}
local function noteEnemyWidget(comp, widget)
    if CFG.Logging == 0 then return end
    local cls = className(widget)
    if enemyWidgetClasses[cls] then return end
    enemyWidgetClasses[cls] = true
    local owner = "?"
    pcall(function() owner = className(comp:GetOwner()) end)
    watchSay("enemyw_" .. cls, "enemy widget on %s: %s", owner, widgetState(comp, widget))
end

-- Bars over the other enemies in combat: CombatSubsystem:GetAllAggressiveNPCActors() -> each actor's widget
-- components -> WBP_CombatCharacterBar_C. A bar showing the locked target (same Target Character as the player's
-- CombatOpponentBar) gets the targeted value. Returns bars seen, all set, aggressive actors.
local function applyEnemyBars(pawn, targetAddr, targetOpacity, otherOpacity)
    local lib, sscls, wccls = static(SUBLIB_CDO), static(COMBAT_SUBSYSTEM), static(WIDGET_COMPONENT)
    if not (lib and sscls and wccls) then
        sayChanged("enemy", "enemy bars: class lookup failed (lib %s, subsystem %s, widget component %s)",
            tostring(lib ~= nil), tostring(sscls ~= nil), tostring(wccls ~= nil))
        return 0, false, 0
    end
    local ss
    pcall(function() ss = unwrap(lib:GetWorldSubsystem(pawn, sscls)) end)
    if not ss then
        sayChanged("enemy", "enemy bars: CombatSubsystem not found")
        return 0, false, 0
    end
    local okList, list = pcall(function() return ss:GetAllAggressiveNPCActors() end)
    if not okList then return 0, false, 0 end
    local actors, seen, allSet = 0, 0, true
    each(list, function(actor)
        actors = actors + 1
        local okComps, comps = pcall(function() return actor:K2_GetComponentsByClass(wccls) end)
        if not okComps then return end
        each(comps, function(comp)
            local widget
            pcall(function() widget = unwrap(comp:GetUserWidgetObject()) end)
            if widget and isCharacterBar(widget) then
                seen = seen + 1
                local isTarget = targetAddr ~= nil and barTargetAddr(widget) == targetAddr
                allSet = setOpacity(widget, isTarget and targetOpacity or otherOpacity, nil) and allSet
            elseif widget then
                noteEnemyWidget(comp, widget)
            end
        end)
    end)
    sayChanged("enemy", "enemy bars: %d aggressive NPCs, %d bars on them", actors, seen)
    return seen, allSet, actors
end

-- Big boss bar at the top of the screen: HUDManagerSubsystem:GetActiveGameHUDWidget() (WBP_GameHUD_C) .BossBar.
local function applyBossBar(pawn, target)
    local lib, cls = static(SUBLIB_CDO), static(HUD_MANAGER)
    if not (lib and cls) then
        sayChanged("widget_bossbar", "bossbar: class lookup failed")
        return false
    end
    local bar
    pcall(function()
        local mgr = unwrap(lib:GetWorldSubsystem(pawn, cls))
        local hud = mgr and unwrap(mgr:GetActiveGameHUDWidget())
        bar = hud and unwrap(hud.BossBar)
    end)
    if not bar then
        sayChanged("widget_bossbar", "bossbar widget not found yet")
        return false
    end
    sayChanged("widget_bossbar", "bossbar widget found (%s)", tostring(bar:GetFullName()))
    return setOpacity(bar, target, "bossbar")
end

---------------------------------------------------------------- loop

local nextTick, nextConfig = 0, 0
local wasEnabled = CFG.Enabled ~= 0
-- The boss bar is left alone until BossBarOpacity drops below 100 once; from then on 100 is written back as 1.0.
local bossTouched = CFG.BossBarOpacity < 100
local failed = nil

local function tick(now)
    if now >= nextConfig then
        nextConfig = now + CONFIG_EVERY_S
        readConfig()
        local isEnabled = CFG.Enabled ~= 0
        if wasEnabled and not isEnabled then restorePending = true end
        wasEnabled = isEnabled
        sayChanged("cfg", "Enabled %d, Opacity %d%%, BarOpacity %d%%, OtherBarOpacity %d%%, BossBarOpacity %d%%",
            CFG.Enabled, CFG.Opacity, CFG.BarOpacity, CFG.OtherBarOpacity, CFG.BossBarOpacity)
        if CFG.BossBarOpacity < 100 then bossTouched = true end
    end

    local pawn = playerPawn(now)
    local addr = pawn and pawn:GetAddress() or nil
    if addr ~= pawnAddr then
        pawnAddr = addr
        settleUntil = now + SETTLE_S
        for _, k in ipairs({ "reticle", "healthbar", "helperreticle", "helperbar", "bossbar" }) do lastSaid["widget_" .. k], lastSaid["set_" .. k] = nil, nil end
        sayChanged("pawn", "player %s", addr and "found" or "gone")
    end
    if not pawn or now < settleUntil then return end

    local on = CFG.Enabled ~= 0
    if not on and not restorePending then return end
    local reticleOpacity = on and CFG.Opacity / 100 or 1.0
    local barOpacity = on and CFG.BarOpacity / 100 or 1.0
    local otherOpacity = on and CFG.OtherBarOpacity / 100 or 1.0

    local okR = applyPlayerWidget(pawn, "reticle", "CombatTargetIndicator", reticleOpacity)
    local okB, bar = applyPlayerWidget(pawn, "healthbar", "CombatOpponentBar", barOpacity)
    -- Second reticle and bar the game shows on enemy attacks (seen flashing at 100 %, 0.4.2 log).
    local okHR = applyPlayerWidget(pawn, "helperreticle", "CombatHelperIndicator", reticleOpacity)
    local okHB = applyPlayerWidget(pawn, "helperbar", "CombatHelperBar", barOpacity)
    local targetAddr = bar and barTargetAddr(bar) or nil
    local _, okE, actors = applyEnemyBars(pawn, targetAddr, barOpacity, otherOpacity)
    if actors > 0 then watchPlayerWidgets(pawn) end
    local okBoss = true
    if bossTouched then okBoss = applyBossBar(pawn, on and CFG.BossBarOpacity / 100 or 1.0) end

    if not on and okR and okB and okHR and okHB and okE and okBoss then restorePending = false end
end

if not LoopInGameThreadAfterFrames then
    print(TAG .. "LoopInGameThreadAfterFrames missing in this UE4SS build, inactive\n")
    return
end

LoopInGameThreadAfterFrames(1, function()
    local now = clock()
    if now < nextTick then return false end
    nextTick = now + CFG.TickMs / 1000
    local ok, err = pcall(tick, now)
    if not ok and failed ~= tostring(err) then
        failed = tostring(err)
        print(TAG .. "error: " .. failed .. "\n") -- errors are logged even with Logging = 0
    end
    return false
end)

say("%s loaded (Enabled %d, Opacity %d%%, BarOpacity %d%%, OtherBarOpacity %d%%, BossBarOpacity %d%%, Logging %d)",
    VERSION, CFG.Enabled, CFG.Opacity, CFG.BarOpacity, CFG.OtherBarOpacity, CFG.BossBarOpacity, CFG.Logging)
