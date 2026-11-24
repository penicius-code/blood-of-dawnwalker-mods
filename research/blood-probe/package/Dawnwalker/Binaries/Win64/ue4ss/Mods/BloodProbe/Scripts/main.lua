-- Blood Probe 0.1.0 (research tool)
--
-- Finds out how the blood on Coen's body and clothes works, why it is gone in dialogues,
-- and what the game knows about Coen standing in water. Log: BloodProbe.log next to
-- Dawnwalker.exe. Read-only, except the optional test key below.
--
--   * every 0.5 s, change based: the skinned decal sampler's counters, the DecalLast value
--     and material identity on each of Coen's meshes, view target / cinematic mode
--     (dialogue camera), movement mode and physics volume (water)
--   * hooks, Coen only: SpawnSkinnedDecalFromPoint, UpdateSkinnedDecalMeshes, and the
--     sampler's SpawnDecal / RemoveDecal / ClearAllDecals (these for every character)
--   * once, when Coen first appears: class chain, component list, the sampler's and the
--     material params component's functions, and all 25 character material param configs
--   * snapshot (Numpad 6, and automatically when the view target changes): full sampler
--     state, every material parameter on every mesh, material params component, water state
--   * Numpad 3: TEST, the only write. Calls ClearAllDecals on Coen's sampler.
--
-- One LoopAsync (100 ms) queues one game-thread tick at a time (every 0.5 s). Log writes,
-- hooks and key actions all run on the game thread. Only classes are kept between ticks.

local VERSION = "0.1.0"
local TAG = "[BloodProbe] "
local TICK_S = 0.5
local SETTLE_S = 3

local SNAPSHOT_KEY = Key.NUM_SIX
local CLEAR_KEY = Key.NUM_THREE

-- Scalar parameters read by name on every material (DecalFade etc. from LastingBlood's notes).
local KNOWN_SCALARS = { "DecalLast", "DecalFade", "DecalMax", "BloodAge", "BloodIntensity",
    "BloodNormalmapIntensity" }
-- Property names worth listing on the pawn, its movement component and controller.
local KEYWORDS = { "blood", "decal", "wet", "water", "swim", "dirt", "clean", "wash", "immers",
    "buoy", "dialog", "cinematic", "materialparam", "rain", "mud" }

---------------------------------------------------------------- log

local LOG_PATH, LOG_OLD = "BloodProbe.log", "BloodProbe.old.log" -- next to Dawnwalker.exe
local lines, flushedAt = {}, 0

do -- start a fresh file past 4 MB
    local f = io.open(LOG_PATH, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 4 * 1024 * 1024 then
            os.remove(LOG_OLD)
            os.rename(LOG_PATH, LOG_OLD)
        end
    end
end

local clock0 = os.clock()
local function stamp() return os.date("%H:%M:%S") .. string.format(" %7.2f  ", os.clock() - clock0) end
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
    if live(o) then return o end
    local ok, v = pcall(function() return o:get() end)
    if ok and live(v) then return v end
    return nil
end
local function text(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
-- Plain Lua value or nil. UE4SS returns a "TrivialObject" userdata (with a changing address) for
-- properties a class does not have; comparing its tostring would log a change on every tick.
local function plain(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return v end
    return nil
end
local function fmt(v)
    if v == nil then return "n/a" end
    if type(v) ~= "number" then return tostring(v) end
    if v == math.floor(v) and math.abs(v) < 1e9 then return string.format("%d", v) end
    return string.format("%.4g", v)
end
local function fname(o) return try(function() return o:GetFName():ToString() end) or "?" end
local function className(o) return try(function() return o:GetClass():GetFName():ToString() end) or "?" end
local function fullName(o) return try(function() return o:GetFullName() end) or "?" end
local function shortPath(p) return tostring(p):match("([^/%.:]+)$") or tostring(p) end
local function addr(o) return try(function() return o:GetAddress() end) end
local function each(arr, limit, fn)
    local n = 0
    pcall(function()
        arr:ForEach(function(_, e)
            n = n + 1
            if n <= limit then fn(e) end
        end)
    end)
    return n
end
local function hasKeyword(name)
    local l = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if l:find(k, 1, true) then return true end
    end
    return false
end
local function cls(path)
    local c = try(function() return StaticFindObject(path) end)
    if live(c) then return c end
    return nil
end

-- "Class /Script/Module.Name" -> "/Script/Module.Name"
local function classPath(c)
    local f = fullName(c)
    return f:match("^%S+%s+(%S+)$") or f
end

---------------------------------------------------------------- generic property reading

local SIMPLE = { IntProperty = true, Int8Property = true, Int16Property = true, Int64Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, FloatProperty = true,
    DoubleProperty = true, BoolProperty = true, ByteProperty = true, EnumProperty = true,
    NameProperty = true, StrProperty = true, TextProperty = true }

local function propType(p) return try(function() return p:GetClass():GetFName():ToString() end) or "?" end

local function enumName(p, v)
    return try(function() return p:GetEnum():GetNameByValue(v):ToString() end)
end

-- Formats one value of property p read from container c (object or struct).
local function valueOf(c, p, depth)
    local name = fname(p)
    local ptype = propType(p)
    local v = try(function() return c[name] end)
    if v == nil then return "nil" end
    local s = tostring(v)
    if type(v) == "userdata" and s:sub(1, 13) == "TrivialObject" then return "nil" end
    if type(v) == "number" then
        if ptype == "EnumProperty" or ptype == "ByteProperty" then
            local en = enumName(p, v)
            if en then return fmt(v) .. "(" .. shortPath(en) .. ")" end
        end
        return fmt(v)
    end
    if type(v) == "boolean" or type(v) == "string" then return tostring(v) end
    if ptype == "NameProperty" or ptype == "StrProperty" or ptype == "TextProperty" then return text(v) or "?" end
    if ptype == "ObjectProperty" or ptype == "ClassProperty" or ptype == "WeakObjectProperty"
        or ptype == "SoftObjectProperty" or ptype == "InterfaceProperty" then
        local o = obj(v)
        return o and (className(o) .. " " .. fname(o)) or "null"
    end
    if ptype == "ArrayProperty" then
        local n = try(function() return v:GetArrayNum() end)
        return "array n=" .. fmt(n)
    end
    if ptype == "MapProperty" or ptype == "SetProperty" then
        local n = each(v, 0, function() end)
        return ptype:gsub("Property", ""):lower() .. " n=" .. fmt(n)
    end
    if ptype == "StructProperty" then
        local sname = try(function() return p:GetStruct():GetFName():ToString() end) or "?"
        if depth and depth > 0 then
            local parts = {}
            pcall(function()
                p:GetStruct():ForEachProperty(function(fp)
                    if #parts < 12 and SIMPLE[propType(fp)] then
                        parts[#parts + 1] = fname(fp) .. "=" .. valueOf(v, fp, 0)
                    end
                end)
            end)
            if #parts > 0 then return sname .. "{" .. table.concat(parts, " ") .. "}" end
        end
        return "struct " .. sname
    end
    return ptype
end

-- Calls fn(prop, ownerClassName) for every property of o's class chain.
local function forEachProp(o, fn)
    local c = try(function() return o:GetClass() end)
    local guard = 0
    while c and live(c) and guard < 40 do
        guard = guard + 1
        local cn = fname(c)
        pcall(function() c:ForEachProperty(function(p) fn(p, cn) end) end)
        c = try(function() return c:GetSuperStruct() end)
    end
end

-- Used when this UE4SS build cannot describe a map's value struct (no GetValueProp).
-- The first three are known from LastingBlood; the rest are guesses.
local FALLBACK_FIELDS = { "FadeOutTime", "bClearOnDayTimeChanged", "bClearOnDialogueStarted", "FadeInTime",
    "ParameterName", "ParamName", "MaterialParameterName", "DefaultValue", "Value", "CurrentValue",
    "TargetValue", "RemainingTime", "Time", "Duration" }

-- Element fields of an array/map of structs, one line each (capped).
local function structLines(container, p, limit, indent)
    local out = {}
    local ptype = propType(p)
    local inner, isMap = nil, ptype == "MapProperty"
    if ptype == "ArrayProperty" then inner = try(function() return p:GetInner() end) end
    if isMap then inner = try(function() return p:GetValueProp() end) end
    local keyProp = isMap and try(function() return p:GetKeyProp() end) or nil
    local v = try(function() return container[fname(p)] end)
    if not v or (not inner and not isMap) then return out end
    local fields = {} -- { name, prop }
    if inner and propType(inner) == "StructProperty" then
        pcall(function()
            inner:GetStruct():ForEachProperty(function(fp) fields[#fields + 1] = { fname(fp), fp } end)
        end)
    elseif not inner then
        for _, n in ipairs(FALLBACK_FIELDS) do fields[#fields + 1] = { n, nil } end
    end
    local function describe(e)
        local ev = try(function() return e:get() end)
        if ev == nil then return "?" end
        if #fields == 0 then
            if type(ev) == "userdata" then
                local o = obj(ev)
                if o then return className(o) .. " " .. fname(o) end
                return text(ev) or "?"
            end
            return fmt(ev)
        end
        local parts = {}
        for _, f in ipairs(fields) do
            if #parts >= 14 then break end
            if f[2] then
                parts[#parts + 1] = f[1] .. "=" .. valueOf(ev, f[2], 1)
            else
                local fv = plain(try(function() return ev[f[1]] end))
                if fv ~= nil then parts[#parts + 1] = f[1] .. "=" .. fmt(fv) end
            end
        end
        return table.concat(parts, " ")
    end
    local n = 0
    pcall(function()
        if isMap then
            v:ForEach(function(k, e)
                n = n + 1
                if n > limit then return end
                local kv = try(function() return k:get() end)
                local ks = type(kv) == "number" and fmt(kv) or (text(kv) or tostring(kv))
                if keyProp and type(kv) == "number" then
                    local en = enumName(keyProp, kv)
                    if en then ks = ks .. "(" .. shortPath(en) .. ")" end
                end
                out[#out + 1] = indent .. "[" .. ks .. "] " .. describe(e)
            end)
        else
            v:ForEach(function(i, e)
                n = n + 1
                if n > limit then return end
                out[#out + 1] = indent .. "[" .. tostring(i - 1) .. "] " .. describe(e)
            end)
        end
    end)
    if n > limit then out[#out + 1] = indent .. string.format("(%d more)", n - limit) end
    return out
end

-- Every property of o, one per line; arrays and maps of structs expanded up to `limit` elements.
local function dumpAll(o, indent, limit)
    forEachProp(o, function(p, owner)
        local ptype = propType(p)
        raw(string.format("%s%s.%s (%s) = %s", indent, owner, fname(p), ptype, valueOf(o, p, 1)))
        if limit > 0 and (ptype == "ArrayProperty" or ptype == "MapProperty") then
            for _, l in ipairs(structLines(o, p, limit, indent .. "    ")) do raw(l) end
        end
    end)
end

-- Only properties whose name matches KEYWORDS.
local function dumpMatching(o, indent)
    local n = 0
    forEachProp(o, function(p, owner)
        if hasKeyword(fname(p)) then
            n = n + 1
            raw(string.format("%s%s.%s (%s) = %s", indent, owner, fname(p), propType(p), valueOf(o, p, 1)))
        end
    end)
    if n == 0 then raw(indent .. "(no matching properties)") end
end

local function functionNames(c)
    local out = {}
    pcall(function() c:ForEachFunction(function(f) out[#out + 1] = fname(f) end) end)
    table.sort(out)
    return out
end

---------------------------------------------------------------- player

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

local function controllerAndPawn()
    local e = gameEngine()
    if not e then return nil, nil end
    local pc = try(function()
        local lp = obj(e.GameViewport.World.OwningGameInstance.LocalPlayers[1])
        return lp and obj(lp.PlayerController)
    end)
    if not pc then return nil, nil end
    return pc, obj(try(function() return pc.Pawn end))
end

-- Classes found at runtime (classes may be cached; objects may not).
local C = {
    skinned = nil, actorComp = nil, mid = nil, sampler = nil, params = nil,
}
local function baseClasses()
    C.skinned = C.skinned or cls("/Script/Engine.SkinnedMeshComponent")
    C.actorComp = C.actorComp or cls("/Script/Engine.ActorComponent")
    C.mid = C.mid or cls("/Script/Engine.MaterialInstanceDynamic")
end

local function samplerOf(pawn)
    local s = obj(try(function() return pawn.SkinnedDecalSampler end))
    if s then return s end
    if C.sampler then return obj(try(function() return pawn:GetComponentByClass(C.sampler) end)) end
    return nil
end

local function paramsCompOf(pawn)
    if not C.params then return nil end
    return obj(try(function() return pawn:GetComponentByClass(C.params) end))
end

local function meshesOf(pawn)
    local out = {}
    if not C.skinned then return out end
    local arr = try(function() return pawn:K2_GetComponentsByClass(C.skinned) end)
    if not arr then return out end
    each(arr, 64, function(e)
        local m = obj(e)
        if m then out[#out + 1] = m end
    end)
    return out
end

local function isMid(m) return C.mid ~= nil and try(function() return m:IsA(C.mid) end) == true end

local function scalarOf(mat, name)
    if not isMid(mat) then return nil end
    return num(try(function() return mat:K2_GetScalarParameterValue(FName(name)) end))
end

---------------------------------------------------------------- hooks

local TOKEN = string.format("%d-%d", os.time(), math.random(1, 1000000000))
pcall(function() ModRef:SetSharedVariable("BloodProbe.loop", TOKEN) end)
local function current()
    local owner = try(function() return ModRef:GetSharedVariable("BloodProbe.loop") end)
    return owner == nil or owner == TOKEN
end

local S = { pawnAddr = nil, settleAt = 0, discovered = false, hooked = {} }
local rate = {} -- per hook: lines in the current 10 s window

local function limited(key)
    local now = os.clock()
    local r = rate[key]
    if not r or now - r.t > 10 then r = { t = now, n = 0, dropped = 0 }; rate[key] = r end
    r.n = r.n + 1
    if r.n > 25 then r.dropped = r.dropped + 1; return true end
    return false
end

local function isPlayer(o)
    if not o or not S.pawnAddr then return false end
    if addr(o) == S.pawnAddr then return true end
    local owner = obj(try(function() return o:GetOwner() end)) or obj(try(function() return o:GetOuter() end))
    return owner ~= nil and addr(owner) == S.pawnAddr
end

local function args(list, from)
    local parts = {}
    for i = from, #list do
        local v = try(function() return list[i]:get() end)
        if type(v) == "userdata" then
            local o = obj(v)
            v = o and fname(o) or (text(v) or tostring(v))
            if type(v) == "string" and v:sub(1, 13) == "TrivialObject" then v = "?" end
            if type(v) == "string" and v:find("^UScriptStruct") then v = "struct" end
        elseif type(v) == "number" then
            v = fmt(v)
        end
        parts[#parts + 1] = tostring(v)
    end
    return table.concat(parts, ", ")
end

-- playerOnly: log only when the context is Coen (or owned by Coen).
local function hook(path, label, playerOnly)
    if S.hooked[path] then return end
    S.hooked[path] = true
    local ok, err = pcall(RegisterHook, path, function(ctx, ...)
        if not current() then return end
        local self = obj(try(function() return ctx:get() end))
        local mine = isPlayer(self)
        if playerOnly and not mine then return end
        if limited(path) then return end
        note("CALL %s  on %s%s  (%s)", label, self and fname(self) or "?", mine and " [Coen]" or "",
            args({ ... }, 1))
    end)
    note("hook %-70s %s", path, ok and "ok" or ("FAILED " .. tostring(err)))
end

---------------------------------------------------------------- discovery (once, when Coen appears)

local function dumpParamsConfig()
    local cfgs = FindAllOf("CharacterMaterialParamsConfig") or {}
    if #cfgs == 0 then note("no CharacterMaterialParamsConfig loaded yet (will retry on next snapshot)"); return false end
    for _, cfg in ipairs(cfgs) do
        if live(cfg) then
            note("material params config %s", fullName(cfg))
            dumpAll(cfg, "    ", 40)
        end
    end
    return true
end

local configDone = false

local function discover(pawn)
    S.discovered = true
    note("---- discovery: pawn %s (%s)", fname(pawn), fullName(try(function() return pawn:GetClass() end)))

    -- class chain: gives the module paths for the character hooks
    local c, guard, charBase, humanoid = try(function() return pawn:GetClass() end), 0, nil, nil
    while c and live(c) and guard < 30 do
        guard = guard + 1
        local path = classPath(c)
        raw("    class " .. path)
        local n = fname(c)
        if n == "DawnwalkerCharacterBase" then charBase = path end
        if n == "HumanoidCharacter" then humanoid = path end
        c = try(function() return c:GetSuperStruct() end)
    end

    -- components on Coen (class names only)
    local comps = {}
    if C.actorComp then
        local arr = try(function() return pawn:K2_GetComponentsByClass(C.actorComp) end)
        if arr then
            each(arr, 200, function(e)
                local o = obj(e)
                if o then
                    local cn = className(o)
                    comps[#comps + 1] = cn .. " " .. fname(o)
                    if not C.params and cn:find("MaterialParams") then C.params = o:GetClass() end
                end
            end)
        end
    end
    table.sort(comps)
    note("components on Coen: %d", #comps)
    for _, l in ipairs(comps) do raw("    " .. l) end

    -- sampler class and its functions
    local sampler = samplerOf(pawn)
    if sampler then
        C.sampler = sampler:GetClass()
        local sp = classPath(C.sampler)
        note("sampler %s (%s)", fname(sampler), sp)
        raw("    functions: " .. table.concat(functionNames(C.sampler), ", "))
        hook(sp .. ":ClearAllDecals", "Sampler:ClearAllDecals", false)
        hook(sp .. ":RemoveDecal", "Sampler:RemoveDecal", true)
        hook(sp .. ":SpawnDecal", "Sampler:SpawnDecal", true)
    else
        warn("no SkinnedDecalSampler on the pawn (property missing); sampler hooks not registered")
    end
    if C.params then
        note("material params component class %s", classPath(C.params))
        raw("    functions: " .. table.concat(functionNames(C.params), ", "))
    else
        note("no component with 'MaterialParams' in its class name on Coen")
    end

    if charBase then hook(charBase .. ":SpawnSkinnedDecalFromPoint", "SpawnSkinnedDecalFromPoint", true) end
    if humanoid then hook(humanoid .. ":UpdateSkinnedDecalMeshes", "UpdateSkinnedDecalMeshes", true) end
    if not charBase then note("DawnwalkerCharacterBase not in the class chain; hit hook not registered") end

    configDone = dumpParamsConfig()
end

---------------------------------------------------------------- per tick state (change based)

local last = {}

local function changed(key, value)
    if last[key] == value then return false end
    local old = last[key]
    last[key] = value
    return true, old
end

-- Integer/bool properties and array/map sizes of the sampler. The property list (names only)
-- is built once per sampler class; the sampler itself is resolved fresh every tick.
local samplerProps = { classAddr = nil, list = {} }
local function samplerState(pawn)
    local s = samplerOf(pawn)
    if not s then return "no sampler" end
    local ca = addr(try(function() return s:GetClass() end))
    if samplerProps.classAddr ~= ca then
        samplerProps.classAddr, samplerProps.list = ca, {}
        forEachProp(s, function(p)
            local t = propType(p)
            if t == "IntProperty" or t == "BoolProperty" or t == "ByteProperty" or t == "EnumProperty"
                or t == "ArrayProperty" or t == "MapProperty" then
                samplerProps.list[#samplerProps.list + 1] = { name = fname(p), t = t }
            end
        end)
    end
    local parts = {}
    for _, e in ipairs(samplerProps.list) do
        local v = try(function() return s[e.name] end)
        if e.t == "ArrayProperty" then
            parts[#parts + 1] = e.name .. "#" .. fmt(try(function() return v:GetArrayNum() end))
        elseif e.t == "MapProperty" then
            parts[#parts + 1] = e.name .. "#" .. fmt(each(v, 0, function() end))
        else
            parts[#parts + 1] = e.name .. "=" .. fmt(plain(v))
        end
    end
    return table.concat(parts, " ")
end

local function meshState(pawn)
    local meshes = meshesOf(pawn)
    local decal, matSig, perMesh = {}, {}, {}
    for _, m in ipairs(meshes) do
        local mat = obj(try(function() return m:GetMaterial(0) end))
        local d = mat and scalarOf(mat, "DecalLast")
        local vis = try(function() return m:IsVisible() end)
        matSig[#matSig + 1] = fname(m) .. ":" .. tostring(mat and addr(mat) or 0) .. (vis == false and ":hidden" or "")
        if d then
            decal[#decal + 1] = d
            perMesh[#perMesh + 1] = fname(m) .. "=" .. fmt(d)
        end
    end
    local allSame = true
    for i = 2, #decal do if decal[i] ~= decal[1] then allSame = false end end
    local dl
    if #decal == 0 then dl = "DecalLast n/a"
    elseif allSame then dl = string.format("DecalLast=%s on %d/%d meshes", fmt(decal[1]), #decal, #meshes)
    else dl = "DecalLast " .. table.concat(perMesh, " ") end
    return dl, table.concat(matSig, " "), #meshes
end

local function viewState(pc)
    local vt = obj(try(function() return pc.PlayerCameraManager.ViewTarget.Target end))
    local cine = plain(try(function() return pc.bCinematicMode end))
    return string.format("viewTarget=%s %s cinematic=%s", vt and className(vt) or "none",
        vt and fname(vt) or "", tostring(cine))
end

local MOVE = { [0] = "None", "Walking", "NavWalking", "Falling", "Swimming", "Flying", "Custom" }
local function waterState(pawn)
    local cmc = obj(try(function() return pawn.CharacterMovement end))
    if not cmc then return "no CharacterMovement" end
    local mode = num(try(function() return cmc.MovementMode end))
    local custom = num(try(function() return cmc.CustomMovementMode end))
    local vol = obj(try(function() return cmc:GetPhysicsVolume() end))
    local water = vol and plain(try(function() return vol.bWaterVolume end))
    return string.format("move=%s custom=%s volume=%s water=%s", mode and (MOVE[mode] or fmt(mode)) or "?",
        fmt(custom), vol and fname(vol) or "none", tostring(water))
end

---------------------------------------------------------------- snapshot

local snapCount, snapWanted, snapReason, lastAutoSnap = 0, false, nil, -100

local function snapshotMeshes(pawn)
    for _, m in ipairs(meshesOf(pawn)) do
        local slots = num(try(function() return m:GetNumMaterials() end)) or 0
        raw(string.format("    mesh %s (%s) visible=%s slots=%s asset=%s", fname(m), className(m),
            tostring(try(function() return m:IsVisible() end)), fmt(slots),
            shortPath(fullName(obj(try(function() return m.SkeletalMesh end)) or
                obj(try(function() return m:GetSkinnedAsset() end)) or m))))
        for s = 0, math.min(slots, 12) - 1 do
            local mat = obj(try(function() return m:GetMaterial(s) end))
            if mat then
                local known = {}
                for _, n in ipairs(KNOWN_SCALARS) do
                    local v = scalarOf(mat, n)
                    if v then known[#known + 1] = n .. "=" .. fmt(v) end
                end
                raw(string.format("      [%d] %s (%s) %s", s, fname(mat), className(mat), table.concat(known, " ")))
                local sc = {}
                each(try(function() return mat.ScalarParameterValues end), 80, function(e)
                    local ev = try(function() return e:get() end)
                    local n = ev and text(try(function() return ev.ParameterInfo.Name end))
                    if n then sc[#sc + 1] = n .. "=" .. fmt(num(try(function() return ev.ParameterValue end))) end
                end)
                if #sc > 0 then raw("          scalars: " .. table.concat(sc, " ")) end
                local vc = {}
                each(try(function() return mat.VectorParameterValues end), 40, function(e)
                    local ev = try(function() return e:get() end)
                    local n = ev and text(try(function() return ev.ParameterInfo.Name end))
                    local c = ev and try(function() return ev.ParameterValue end)
                    if n then
                        vc[#vc + 1] = string.format("%s=(%s,%s,%s,%s)", n, fmt(num(try(function() return c.R end))),
                            fmt(num(try(function() return c.G end))), fmt(num(try(function() return c.B end))),
                            fmt(num(try(function() return c.A end))))
                    end
                end)
                if #vc > 0 then raw("          vectors: " .. table.concat(vc, " ")) end
                local tc = {}
                each(try(function() return mat.TextureParameterValues end), 40, function(e)
                    local ev = try(function() return e:get() end)
                    local n = ev and text(try(function() return ev.ParameterInfo.Name end))
                    local t = ev and obj(try(function() return ev.ParameterValue end))
                    if n then tc[#tc + 1] = n .. "=" .. (t and (className(t) .. ":" .. fname(t)) or "none") end
                end)
                if #tc > 0 then raw("          textures: " .. table.concat(tc, " ")) end
            end
        end
    end
end

local function snapshot(pc, pawn, reason)
    snapCount = snapCount + 1
    note("==== SNAPSHOT #%d (%s) ====", snapCount, reason)
    raw("  " .. viewState(pc))
    raw("  " .. waterState(pawn))

    local s = samplerOf(pawn)
    if s then
        raw("  -- sampler " .. fname(s))
        dumpAll(s, "    ", 12)
    else
        raw("  -- no sampler")
    end

    raw("  -- meshes and material parameters")
    snapshotMeshes(pawn)

    local pcomp = paramsCompOf(pawn)
    if pcomp then
        raw("  -- material params component " .. fname(pcomp))
        dumpAll(pcomp, "    ", 30)
    end
    if not configDone then configDone = dumpParamsConfig() end

    raw("  -- water: overlapping components of the capsule")
    local root = obj(try(function() return pawn:K2_GetRootComponent() end))
    local out = {}
    if root then pcall(function() root:GetOverlappingComponents(out) end) end
    local list = out.OutOverlappingComponents or out.OverlappingComponents or out
    local n = 0
    if type(list) == "table" then
        for _, e in ipairs(list) do
            local o = obj(e)
            if o and n < 25 then
                n = n + 1
                local owner = obj(try(function() return o:GetOwner() end))
                raw(string.format("    %s %s (owner %s %s)", className(o), fname(o),
                    owner and className(owner) or "?", owner and fname(owner) or ""))
            end
        end
    else
        n = each(list, 25, function(e)
            local o = obj(e)
            if o then
                local owner = obj(try(function() return o:GetOwner() end))
                raw(string.format("    %s %s (owner %s %s)", className(o), fname(o),
                    owner and className(owner) or "?", owner and fname(owner) or ""))
            end
        end)
    end
    if n == 0 then raw("    (none, or call not supported)") end

    raw("  -- keyword properties on pawn / movement / controller")
    dumpMatching(pawn, "    ")
    local cmc = obj(try(function() return pawn.CharacterMovement end))
    if cmc then dumpMatching(cmc, "    ") end
    dumpMatching(pc, "    ")
    note("==== end snapshot #%d ====", snapCount)
end

---------------------------------------------------------------- test clear (the only write)

local clearWanted = false

local function testClear(pawn)
    local s = samplerOf(pawn)
    if not s then warn("test clear: no sampler on Coen"); return end
    local before = select(1, meshState(pawn))
    local ok, err = pcall(function() s:ClearAllDecals() end)
    local after = select(1, meshState(pawn))
    warn("TEST ClearAllDecals on Coen: %s | before: %s | after: %s", ok and "called" or ("FAILED " .. tostring(err)),
        before, after)
end

---------------------------------------------------------------- tick

local function tick()
    local pc, pawn = controllerAndPawn()
    if not pawn then
        if changed("pawn", "none") then note("no player pawn") end
        S.pawnAddr = nil
        return
    end
    local a = addr(pawn)
    if S.pawnAddr ~= a then
        S.pawnAddr = a
        S.settleAt = os.clock() + SETTLE_S
        note("player pawn now %s (%s)", fname(pawn), className(pawn))
        last = {}
        return
    end
    if os.clock() < S.settleAt then return end
    baseClasses()
    if not S.discovered and className(pawn):find("PlayerCharacter") then discover(pawn) end

    local ch, old = changed("sampler", samplerState(pawn))
    if ch then note("sampler: %s", last.sampler) end

    local dl, sig, count = meshState(pawn)
    if changed("decal", dl) then note("meshes: %s", dl) end
    ch, old = changed("matsig", sig)
    if ch and old then
        -- which meshes got a different material or visibility
        local was = {}
        for e in old:gmatch("%S+") do was[e:match("^[^:]+")] = e end
        local diffs = {}
        for e in sig:gmatch("%S+") do
            local k = e:match("^[^:]+")
            if was[k] ~= e then diffs[#diffs + 1] = k .. (was[k] and "" or "(new)") .. (e:find(":hidden") and "(hidden)" or "") end
            was[k] = nil
        end
        for k in pairs(was) do diffs[#diffs + 1] = k .. "(gone)" end
        note("materials/visibility changed on %d of %d meshes: %s", #diffs, count, table.concat(diffs, " "))
    end

    local vs = viewState(pc)
    ch, old = changed("view", vs)
    if ch then
        note("view: %s", vs)
        if old and os.clock() - lastAutoSnap > 5 then
            lastAutoSnap = os.clock()
            snapWanted, snapReason = true, "auto: view target changed"
        end
    end
    if changed("water", waterState(pawn)) then note("water: %s", last.water) end

    if snapWanted then
        snapWanted = false
        local ok, err = pcall(snapshot, pc, pawn, snapReason or "Numpad 6")
        if not ok then warn("snapshot error: %s", tostring(err)) end
        snapReason = nil
    end
    if clearWanted then
        clearWanted = false
        local ok, err = pcall(testClear, pawn)
        if not ok then warn("test clear error: %s", tostring(err)) end
    end
end

---------------------------------------------------------------- loop and keys

local nextTick, busy, busySince = 0, false, 0

LoopAsync(100, function()
    if not current() then return true end
    local now = os.clock()
    if busy and now - busySince < 5 then return false end
    if now < nextTick and not snapWanted and not clearWanted then return false end
    nextTick = now + TICK_S
    busy, busySince = true, now
    local ok = pcall(ExecuteInGameThread, function()
        local okT, err = pcall(tick)
        if not okT then warnOnce("tick " .. tostring(err), "tick error: %s", tostring(err)) end
        for key, r in pairs(rate) do
            if r.dropped > 0 and os.clock() - r.t > 10 then
                note("(%d more calls of %s not logged)", r.dropped, key)
                r.dropped = 0
            end
        end
        if #lines > 0 and (os.clock() - flushedAt >= 2 or #lines >= 60) then
            flushedAt = os.clock()
            flushLog()
        end
        busy = false
    end)
    if not ok then busy = false end
    return false
end)

RegisterKeyBind(SNAPSHOT_KEY, function() snapWanted, snapReason = true, "Numpad 6" end)
RegisterKeyBind(CLEAR_KEY, function() clearWanted = true end)

note("---- session start, Blood Probe %s", VERSION)
warn("Blood Probe %s loaded (log %s; Numpad 6 snapshot, Numpad 3 test clear)", VERSION, LOG_PATH)
flushLog()
