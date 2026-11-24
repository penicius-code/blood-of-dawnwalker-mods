-- Wolf Probe 0.1.0 (research tool, read-only)
--
-- Traces the vanilla bug where wolf Haste + Shadowstep onto a wall leaves the wolf
-- stuck on the ground afterwards (not moving, has to be transformed back and forth).
-- Nothing is written to the game. Log: WolfProbe.log next to Dawnwalker.exe.
--
--   every 0.1 s, logged on change: wolf form, Form, movement mode, custom gravity,
--     time dilation, capsule size, and per skeletal mesh (CharacterMesh0 and the wolf
--     mesh FastTravelSkeletal): visible, mesh asset, anim class, linked layers, montage
--   every 0.15 s, logged on change: gameplay tags (list below), active abilities,
--     gameplay cues, active effects, and pawn/component/anim properties whose names
--     contain wolf/form/shape/transform/movement/gravity/wall/sprint/traversal/...
--   speed: logged as a coarse bucket, plus "STUCK?" when in wolf form the pawn has
--     not moved for 1.5 s while the move input is held
--   Numpad 7: MARK line + full snapshot (press it when the wolf is stuck)
--
-- One LoopAsync (100 ms) queues one game-thread tick at a time. Only classes,
-- default objects and the engine are kept between ticks.

local VERSION = "0.1.0"
local TAG = "[WolfProbe] "
local TICK_S = 0.1
local HASTE_TAG = "Traversal.VampireSprint"
-- Checked one by one when GetOwnedGameplayTags fails (it did in HasteProbe).
local TAG_CHECKS = {
    "Traversal.VampireSprint", "Traversal", "Player.IsEffectivelyInCombat",
    "Wolf", "Form", "Shapeshift", "Transformation", "Player.Wolf", "Player.Form",
    "Ability.Wolf", "State.Wolf", "Traversal.Shadowstep", "Traversal.Planeshift", "Traversal.WallWalk",
}
local PROP_WORDS = { "wolf", "form", "shape", "transform", "morph", "movement", "gravity", "wall",
    "sprint", "traversal", "shadowstep", "planeshift", "antigrav", "stuck", "root", "locomotion", "profile" }


local LOG_PATH, LOG_OLD = "WolfProbe.log", "WolfProbe.old.log" -- next to Dawnwalker.exe
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
local function warnOnce(key, fmt, ...)
    key = tostring(key):gsub("%d+", "#")
    if warned[key] then return end
    warned[key] = true
    warn(fmt, ...)
end
local function flushLog()
    if #lines == 0 then return end
    local out = table.concat(lines, "\n") .. "\n"
    lines = {}
    local f = io.open(LOG_PATH, "a")
    if f then f:write(out); f:close() end
end

---------------------------------------------------------------- helpers

local function num(v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
    return nil
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
local function obj(o)
    if type(o) ~= "userdata" then return nil end
    local ok, v = pcall(function() return o:Get() end)
    if ok and live(v) then return v end
    ok, v = pcall(function() return o:get() end)
    if ok and live(v) then return v end
    if live(o) then return o end
    return nil
end
local function ref(o)
    if live(o) then return o end
    return obj(o)
end
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
local function list(v, limit)
    local out = {}
    limit = limit or 512
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
local function fmt(v)
    if v == nil then return "n/a" end
    if v == math.floor(v) and math.abs(v) < 1e7 then return string.format("%d", v) end
    return string.format("%.4g", v)
end
local function shortPath(p) return tostring(p):match("([^/%.%s]+)$") or tostring(p) end
local function fullName(o) return try(function() return o:GetFullName() end) end
local function oname(o)
    o = ref(o)
    if not o then return nil end
    return try(function() return o:GetFName():ToString() end)
end
local function clsName(o)
    o = ref(o)
    if not o then return nil end
    return try(function() return o:GetClass():GetFName():ToString() end)
end
local function hasWord(s, words)
    if not s then return false end
    s = s:lower()
    for _, w in ipairs(words) do
        if s:find(w, 1, true) then return true end
    end
    return false
end
-- Any readable value as a short string (nil when it is a struct/array we don't expand).
local function str(v)
    v = param(v)
    local t = type(v)
    if t == "number" then return fmt(v) end
    if t == "boolean" then return tostring(v) end
    if t == "string" then return v end
    if t == "nil" then return "nil" end
    if t ~= "userdata" and t ~= "table" then return nil end
    local s = text(v)
    if s then return s end
    if live(v) then return oname(v) or "?" end
    local x = num(try(function() return v.X end))
    if x then
        local parts = { fmt(x) }
        for _, k in ipairs({ "Y", "Z", "W" }) do
            local c = num(try(function() return v[k] end))
            if c then parts[#parts + 1] = fmt(c) end
        end
        return "(" .. table.concat(parts, ",") .. ")"
    end
    local r = num(try(function() return v.R end))
    if r then
        return string.format("(%s,%s,%s,%s)", fmt(r), fmt(num(try(function() return v.G end))),
            fmt(num(try(function() return v.B end))), fmt(num(try(function() return v.A end))))
    end
    return nil
end
local function tagNames(container, out)
    out = out or {}
    for _, t in ipairs(list(try(function() return container.GameplayTags end), 256)) do
        local n = text(try(function() return t.TagName end))
        if n then out[#out + 1] = n end
    end
    return out
end

---------------------------------------------------------------- engine objects (only CDOs/classes cached)

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

local function player()
    local e = gameEngine()
    if not e then return nil end
    local pc, pawn
    pcall(function()
        local lp = ref(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        pc = lp and ref(lp.PlayerController)
        pawn = pc and ref(pc.Pawn)
    end)
    return pc, pawn
end

local C = {}
local function cdo(key, path)
    if C[key] == nil or (C[key] and not live(C[key])) then
        C[key] = try(function() return StaticFindObject(path) end) or false
        if C[key] and not live(C[key]) then C[key] = false end
    end
    return C[key] or nil
end
local function GS() return cdo("gs", "/Script/Engine.Default__GameplayStatics") end
local function KML() return cdo("kml", "/Script/Engine.Default__KismetMaterialLibrary") end
local function cls(key, path) return cdo(key, path) end

---------------------------------------------------------------- stream: tags, abilities, cues, effects

local function readTags(asc)
    local c = try(function() return asc:GetOwnedGameplayTags() end)
    if c then return tagNames(c) end
    warnOnce("tags", "GetOwnedGameplayTags failed, using HasMatchingGameplayTag for %s only", HASTE_TAG)
    local has = try(function() return asc:HasMatchingGameplayTag({ TagName = FName(HASTE_TAG) }) end)
    return has and { HASTE_TAG } or {}
end

local function readAbilities(asc)
    local out = {}
    for _, s in ipairs(list(try(function() return asc.ActivatableAbilities.Items end), 400)) do
        local n = num(try(function() return s.ActiveCount end))
        if n and n > 0 then
            out[#out + 1] = shortPath(fullName(ref(s.Ability)) or "?")
        end
    end
    return out
end

local function readCues(asc)
    local out = {}
    for _, c in ipairs(list(try(function() return asc.ActiveGameplayCues.GameplayCues end), 200)) do
        local n = text(try(function() return c.GameplayCueTag.TagName end))
        if n then out[#out + 1] = n end
    end
    return out
end

-- name -> "cues=[..] mods=[..] dur=.."; name alone is the set key
local function readEffects(asc)
    local out, detail = {}, {}
    local effects = list(try(function() return asc.ActiveGameplayEffects.GameplayEffects_Internal end), 256)
    for _, e in ipairs(effects) do
        pcall(function()
            local spec = e.Spec
            local def = ref(spec.Def)
            local dname = shortPath(fullName(def) or "?")
            out[#out + 1] = dname
            if detail[dname] == nil then
                local cues = {}
                for _, gc in ipairs(list(try(function() return def.GameplayCues end), 16)) do
                    tagNames(try(function() return gc.GameplayCueTags end), cues)
                end
                local mods = {}
                local mags = list(try(function() return spec.Modifiers end), 32)
                for i, m in ipairs(list(try(function() return def.Modifiers end), 32)) do
                    local an = text(try(function() return m.Attribute.AttributeName end)) or "?"
                    local mag = mags[i] and num(try(function() return mags[i].EvaluatedMagnitude end))
                    mods[#mods + 1] = an .. " op" .. fmt(num(try(function() return m.ModifierOp end))) .. " " .. fmt(mag)
                end
                detail[dname] = string.format("cues=[%s] mods=[%s] dur=%s", table.concat(cues, " "),
                    table.concat(mods, ", "), fmt(num(try(function() return spec.Duration end))))
            end
        end)
    end
    return out, detail
end

-- Set diff of two string lists (duplicates counted).
local function diffSets(old, new)
    local count = {}
    for _, v in ipairs(old or {}) do count[v] = (count[v] or 0) + 1 end
    local added, removed = {}, {}
    for _, v in ipairs(new) do
        if (count[v] or 0) > 0 then count[v] = count[v] - 1 else added[#added + 1] = v end
    end
    for v, n in pairs(count) do
        for _ = 1, n do removed[#removed + 1] = v end
    end
    table.sort(added); table.sort(removed)
    return added, removed
end

---------------------------------------------------------------- property watches

-- W = list of { owner = "pawn"|"pc"|"pcm"|"anim"|"comp", cls = UClass (for comp), label, prop }
local W, Wlast, Wnoise = {}, {}, {}
local WATCH_TYPES = {
    BoolProperty = true, FloatProperty = true, DoubleProperty = true, IntProperty = true, ByteProperty = true,
    EnumProperty = true, NameProperty = true, ObjectProperty = true, StrProperty = true, UInt32Property = true,
    Int64Property = true, UInt16Property = true, Int16Property = true, WeakObjectProperty = true,
}

local function eachClass(c, fn)
    local depth = 0
    while live(c) and depth < 16 do
        fn(c)
        c = try(function() return c:GetSuperStruct() end)
        depth = depth + 1
    end
end

local function discover(owner, o, compCls, seen, info)
    o = ref(o)
    if not o then return end
    local label = owner == "comp" and (oname(compCls) or "comp") or owner
    eachClass(try(function() return o:GetClass() end), function(c)
        local cname = oname(c) or "?"
        pcall(function()
            c:ForEachProperty(function(p)
                local n = text(try(function() return p:GetFName() end))
                if n and hasWord(n, PROP_WORDS) then
                    local ty = text(try(function() return p:GetClass():GetFName() end)) or "?"
                    local key = label .. "." .. n
                    if WATCH_TYPES[ty] and not seen[key] and #W < 160 then
                        seen[key] = true
                        W[#W + 1] = { owner = owner, cls = compCls, label = key, prop = n }
                        info[#info + 1] = string.format("  watch %s (%s, on %s) = %s", key, ty, cname,
                            str(try(function() return o[n] end)) or "?")
                    elseif not WATCH_TYPES[ty] and not seen[key] then
                        seen[key] = true
                        info[#info + 1] = string.format("  seen  %s (%s, on %s, not watched)", key, ty, cname)
                    end
                end
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(f)
                local n = text(try(function() return f:GetFName() end))
                if n and hasWord(n, PROP_WORDS) and not seen[label .. ":" .. n] then
                    seen[label .. ":" .. n] = true
                    info[#info + 1] = string.format("  func  %s:%s (on %s)", label, n, cname)
                end
            end)
        end)
    end)
end

local function animInstance(pawn)
    return ref(try(function() return pawn.Mesh:GetAnimInstance() end))
end

local function buildWatches(pc, pawn)
    W, Wlast, Wnoise = {}, {}, {}
    local seen, info = {}, {}
    discover("pawn", pawn, nil, seen, info)
    discover("pc", pc, nil, seen, info)
    discover("pcm", try(function() return pc.PlayerCameraManager end), nil, seen, info)
    discover("anim", animInstance(pawn), nil, seen, info)
    local acc = cls("acc", "/Script/Engine.ActorComponent")
    local comps = acc and list(try(function() return pawn:K2_GetComponentsByClass(acc) end), 200) or {}
    local doneCls, names = {}, {}
    for _, comp in ipairs(comps) do
        comp = ref(comp)
        local c = comp and try(function() return comp:GetClass() end)
        local cn = c and oname(c)
        if cn then
            names[#names + 1] = (oname(comp) or "?") .. ":" .. cn
            if not doneCls[cn] then
                doneCls[cn] = true
                discover("comp", comp, c, seen, info)
            end
        end
    end
    note("pawn %s, %d components: %s", clsName(pawn) or "?", #names, table.concat(names, " "))
    note("anim instance %s, camera manager %s", clsName(animInstance(pawn)) or "none",
        clsName(try(function() return pc.PlayerCameraManager end)) or "none")
    note("property discovery (%d watched):", #W)
    for _, l in ipairs(info) do raw(l) end
end

local function readWatches(pc, pawn)
    local owners = {
        pawn = pawn, pc = pc,
        pcm = ref(try(function() return pc.PlayerCameraManager end)),
        anim = animInstance(pawn),
    }
    local compBy = {}
    local out = {}
    for i, w in ipairs(W) do
        local o
        if w.owner == "comp" then
            local key = oname(w.cls) or tostring(i)
            if compBy[key] == nil then
                compBy[key] = ref(try(function() return pawn:GetComponentByClass(w.cls) end)) or false
            end
            o = compBy[key] or nil
        else
            o = owners[w.owner]
        end
        out[i] = o and (str(try(function() return o[w.prop] end)) or "none") or "gone"
    end
    return out
end

---------------------------------------------------------------- snapshots


---------------------------------------------------------------- tags (fallback: checked one by one)

local function readTagsWolf(asc)
    local c = try(function() return asc:GetOwnedGameplayTags() end)
    local out = c and tagNames(c) or {}
    if #out > 0 then return out end
    for _, t in ipairs(TAG_CHECKS) do
        local has = try(function() return asc:HasMatchingGameplayTag({ TagName = FName(t) }) end)
        if has == true then out[#out + 1] = t end
    end
    return out
end

---------------------------------------------------------------- body state

local skinnedCls = nil
local function meshes(pawn)
    if not live(skinnedCls) then
        skinnedCls = try(function() return StaticFindObject("/Script/Engine.SkeletalMeshComponent") end)
    end
    if not live(skinnedCls) then return {} end
    return list(try(function() return pawn:K2_GetComponentsByClass(skinnedCls) end), 64)
end

local function layersOf(m)
    local names = {}
    for _, li in ipairs(list(try(function() return m.LinkedInstances end), 32)) do
        names[#names + 1] = clsName(li) or "?"
    end
    return table.concat(names, ",")
end

-- Only meshes with an anim instance (CharacterMesh0, FastTravelSkeletal); clothing
-- and hair follow them.
local function bodyState(pawn)
    local s = {}
    for _, m in ipairs(meshes(pawn)) do
        m = ref(m)
        local anim = m and ref(try(function() return m:GetAnimInstance() end))
        if anim then
            local n = oname(m) or "?"
            local asset = try(function() return m.SkeletalMesh end) or try(function() return m:GetSkeletalMeshAsset() end)
            local mont = ref(try(function() return anim:GetCurrentActiveMontage() end))
            s["mesh." .. n] = string.format("%s asset=%s anim=%s grav=%s montage=%s layers=[%s]",
                try(function() return m:IsVisible() end) and "vis" or "hid",
                oname(asset) or "?", clsName(anim) or "?",
                str(try(function() return anim.bHasCustomGravity end)) or "?",
                oname(mont) or "none", layersOf(m))
        end
    end
    s["wolf"] = str(try(function() return pawn:IsInWolfForm() end))
    s["form"] = str(try(function() return pawn.Form end))
    local cm = ref(try(function() return pawn.CharacterMovement end))
    if cm then
        s["move.mode"] = (str(try(function() return cm.MovementMode end)) or "?") .. "/" ..
            (str(try(function() return cm.CustomMovementMode end)) or "?")
        s["move.maxWalk"] = str(try(function() return cm.MaxWalkSpeed end))
        s["move.gravityScale"] = str(try(function() return cm.GravityScale end))
        s["move.gravityDir"] = str(try(function() return cm:GetGravityDirection() end))
    end
    s["pawn.ctd"] = str(try(function() return pawn.CustomTimeDilation end))
    local cap = ref(try(function() return pawn.CapsuleComponent end))
    if cap then
        s["capsule"] = fmt(num(try(function() return cap:GetUnscaledCapsuleHalfHeight() end))) .. "/" ..
            fmt(num(try(function() return cap:GetUnscaledCapsuleRadius() end)))
    end
    s["pawn.hidden"] = str(try(function() return pawn.bHidden end))
    s["pawn.collision"] = str(try(function() return pawn:GetActorEnableCollision() end))
    return s
end

local function speedOf(pawn)
    local v = try(function() return pawn:GetVelocity() end)
    local vx, vy, vz = num(try(function() return v.X end)), num(try(function() return v.Y end)), num(try(function() return v.Z end))
    if not (vx and vy) then return nil, nil end
    return math.sqrt(vx * vx + vy * vy), vz
end
local function bucket(sp)
    if not sp then return "?" end
    if sp < 10 then return "still" elseif sp < 300 then return "walk" elseif sp < 700 then return "run"
    elseif sp < 1500 then return "sprint" else return "haste" end
end

local function moveInput(pawn)
    local v = try(function() return pawn:GetLastMovementInputVector() end)
        or try(function() return pawn.CharacterMovement:GetLastInputVector() end)
    local x, y = num(try(function() return v.X end)), num(try(function() return v.Y end))
    return x and y and (x * x + y * y) > 0.01
end

local function logState(prefix, old, new, all)
    local keys = {}
    for k in pairs(new) do keys[#keys + 1] = k end
    for k in pairs(old or {}) do if new[k] == nil then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local o, n = old and old[k], new[k]
        if all or o ~= n then note("%s%s: %s -> %s", prefix, k, tostring(o or "-"), tostring(n or "gone")) end
    end
end

---------------------------------------------------------------- tick

local S = { pawnAddr = nil, ready = false, settleAt = 0, body = nil, speed = nil, still = nil, stuckLogged = false,
    tags = nil, abil = nil, cues = nil, eff = nil, effDetail = {}, lastStream = 0, mark = false }

local function logSetDiff(kind, old, new)
    if old == nil then
        note("%s at start: %s", kind, table.concat(new, " "))
        return
    end
    local added, removed = diffSets(old, new)
    for _, a in ipairs(added) do
        if kind == "effect" then note("effect + %s  %s", a, S.effDetail[a] or "")
        else note("%s + %s", kind, a) end
    end
    for _, r in ipairs(removed) do note("%s - %s", kind, r) end
end

local function tick()
    local pc, pawn = player()
    if not pawn then S.pawnAddr = nil; return end
    local addr = pawn:GetAddress()
    if S.pawnAddr ~= addr then
        S.pawnAddr, S.ready = addr, false
        S.body, S.tags, S.abil, S.cues, S.eff = nil, nil, nil, nil, nil
        S.settleAt = os.clock() + 2 -- wait after a player change
        note("new player pawn %s, settling", clsName(pawn) or "?")
        return
    end
    local now = os.clock()
    if now < S.settleAt then return end

    if not S.ready then
        S.ready = true
        buildWatches(pc, pawn)
        S.body = bodyState(pawn)
        logState("start ", nil, S.body, true)
        note("ready. Wolf Haste -> Shadowstep onto a wall -> drop -> Haste again. Numpad 7 = MARK")
        return
    end

    -- body state, every tick
    local body = bodyState(pawn)
    local sp, vz = speedOf(pawn)
    body["speed"] = bucket(sp)
    local mark = S.mark
    S.mark = false
    if mark then
        note("==== MARK (Numpad 7): speed %s vz %s input %s", fmt(sp and math.floor(sp)), fmt(vz and math.floor(vz)),
            tostring(moveInput(pawn)))
        logState("  ", nil, body, true)
    else
        logState("", S.body, body, false)
    end
    S.body = body

    -- stuck detector: wolf, input held, no movement for 1.5 s
    local held = moveInput(pawn)
    if body["wolf"] == "true" and held and sp and sp < 10 then
        S.still = S.still or now
        if now - S.still > 1.5 and not S.stuckLogged then
            S.stuckLogged = true
            note("==== STUCK? wolf form, move input held, speed %s for %.1fs", fmt(math.floor(sp)), now - S.still)
            logState("  ", nil, body, true)
        end
    else
        if S.stuckLogged then note("==== moving again (speed %s)", fmt(sp and math.floor(sp))) end
        S.still, S.stuckLogged = nil, false
    end

    -- stream, every 0.15 s
    if now - S.lastStream < 0.15 then return end
    S.lastStream = now
    local asc = ref(try(function() return pawn.AbilitySystemComponent end))
    if asc then
        local eff, detail = readEffects(asc)
        for k, v in pairs(detail) do S.effDetail[k] = v end
        local tags = readTagsWolf(asc)
        local abil = readAbilities(asc)
        local cues = readCues(asc)
        logSetDiff("tag", S.tags, tags); S.tags = tags
        logSetDiff("ability", S.abil, abil); S.abil = abil
        logSetDiff("cue", S.cues, cues); S.cues = cues
        logSetDiff("effect", S.eff, eff); S.eff = eff
    else
        warnOnce("asc", "player has no AbilitySystemComponent")
    end
    local wv = readWatches(pc, pawn)
    for i, w in ipairs(W) do
        local old, new = Wlast[i], wv[i]
        if old ~= nil and old ~= new then
            local nz = Wnoise[i] or { n = 0, since = now }
            if now - nz.since > 10 then nz.n, nz.since = 0, now end
            nz.n = nz.n + 1
            Wnoise[i] = nz
            if nz.n == 40 then note("prop %s changes constantly, muted", w.label)
            elseif nz.n < 40 and not nz.muted then note("prop %s: %s -> %s", w.label, old, new) end
            if nz.n >= 40 then nz.muted = true end
        end
    end
    Wlast = wv
end

---------------------------------------------------------------- loop

pcall(function()
    RegisterKeyBind(Key.NUM_SEVEN, function() S.mark = true end)
end)

local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("WolfProbe.loop", TOKEN) end)

local nextTick, busy, busySince = 0, false, 0

LoopAsync(100, function()
    local owner = try(function() return ModRef:GetSharedVariable("WolfProbe.loop") end)
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
        if not okT then warnOnce("tick " .. tostring(err), "tick error: %s", tostring(err)) end
        busy = false
    end)
    if not ok then busy = false end
    return false
end)

raw("")
note("---- session start, Wolf Probe %s", VERSION)
warn("Wolf Probe %s loaded (read-only, log %s)", VERSION, LOG_PATH)
