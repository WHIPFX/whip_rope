--[[
    whip_rope — HOW THE ROPE IS DRAWN, BEYOND A PROP PER NODE

    'segments': one rope piece per gap between two points (the nodes, or the spline's samples).
    The piece is whip_rope_seg (docs/whip_rope_seg.txt): a capsule SegmentLength (0.25 m) long on its
    own +Y, centred on its origin. Each frame SetEntityMatrix puts it
      * at the middle of the two points,
      * with +Y along the gap, scaled to the gap's length (a stretched rope stretches its pieces).
        With no overlap the rounded caps sit on the nodes, so neighbours meet and the strands line up;
        overlap puts lumps on bends,
      * with X and Z scaled by the thickness, both equally (unequal scaling breaks the lighting).

    The roll is carried from piece to piece (a rotation-minimising frame), so the strand twist runs
    across joints instead of jumping.
]]

Rope.Mesh = {}

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b)
    return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

local WORLD_UP = vector3(0.0, 0.0, 1.0)
local WORLD_X = vector3(1.0, 0.0, 0.0)

--- A first "right" square to `t`: across it, level with the ground (or along X for a rope hanging
--- straight down).
local function startRight(t)
    local r = cross(t, WORLD_UP)
    local len = #r
    if len < 1e-4 then
        r = cross(t, WORLD_X)
        len = #r
    end
    return r / len
end

--- Every piece's matrix along `points` (vector3s, in order), into `out[k]` = { f, r, u, at } with the
--- scales applied: f along the gap, as (its length + overlap) / the model's own length; r and u the
--- thickness (the SAME on both, or the model's lighting bends). Pure: no natives.
---@param points vector3[]
---@param thickness number    scale on the model's own X and Z
---@param overlap number      metres added to each piece's length
---@param modelLength number  the model's own length along +Y (metres)
function Rope.Mesh.Frames(points, thickness, overlap, out, modelLength)
    out = out or {}
    modelLength = modelLength or 1.0
    local right, lastT = nil, vector3(0.0, 1.0, 0.0)
    for k = 1, #points - 1 do
        local a, b = points[k], points[k + 1]
        local d = b - a
        local len = #d
        -- Two points on top of each other: the piece keeps the last one's way
        local t = len > 1e-5 and d / len or lastT
        lastT = t
        -- Carry the last right on: take away its part along the new gap
        if right then
            local r = right - t * dot(right, t)
            local rl = #r
            right = rl > 1e-4 and r / rl or startRight(t)
        else
            right = startRight(t)
        end
        local up = cross(right, t)
        local f = out[k] or {}
        f.f = t * ((len + overlap) / modelLength)
        f.r = right * thickness
        f.u = up * thickness
        f.at = (a + b) * 0.5
        out[k] = f
    end
    for k = #points, #out do out[k] = nil end
    return out
end

-- ============================================================================
-- THE PIECES ON THIS GAME
-- ============================================================================

--- The pieces for a rope, of `model` (loaded already: client/visuals.lua's Rope.LoadLook).
function Rope.Mesh.Create(rope, pointCount, model)
    rope.segments = {}
    rope.segmentFrames = {}
    rope.segmentLast = nil
    rope.segmentModel = model
    local at = rope.nodes[1].position
    for _ = 1, pointCount - 1 do
        local prop = CreateObject(model, at.x, at.y, at.z, false, false, false)
        if DoesEntityExist(prop) then
            SetEntityCollision(prop, false, false)
            FreezeEntityPosition(prop, true)
            SetEntityLodDist(prop, 500)
            rope.segments[#rope.segments + 1] = prop
        end
    end
end

--- Deletes only our own pieces (checked by the model they were made with, which the shadows setting may
--- have changed since), never whatever a stale handle now names.
function Rope.Mesh.Delete(rope)
    local model = rope.segmentModel
    for _, prop in ipairs(rope.segments or {}) do
        if DoesEntityExist(prop) and GetEntityModel(prop) == model then DeleteEntity(prop) end
    end
    rope.segments = {}
    rope.segmentLast = nil
end

-- ============================================================================
-- GTA'S OWN ROPE, PINNED ALONG OURS (Config.Visuals.Style = 'gta')
-- ============================================================================
-- One of GTA's ropes with every vertex pinned each frame along ours: one continuous textured tube, no
-- props or seams, and no physics of its own. Drawing only; our simulation and sync are unchanged.

local ropeTexturesLoaded = false

--- GTA's rope textures, once. Waits (at most 3 s): from a thread.
function Rope.Mesh.EnsureGtaTextures()
    if ropeTexturesLoaded then return true end
    RopeLoadTextures()
    local deadline = GetGameTimer() + 3000
    while not RopeAreTexturesLoaded() and GetGameTimer() < deadline do Wait(50) end
    ropeTexturesLoaded = RopeAreTexturesLoaded() and true or false
    return ropeTexturesLoaded
end

--- The point `s` metres along `points` (cum: the running lengths), walking on from index `k`.
local function along(points, cum, s, k)
    local n = #points
    while k < n - 1 and cum[k + 1] < s do k = k + 1 end
    local seg = cum[k + 1] - cum[k]
    local t = seg > 1e-6 and (s - cum[k]) / seg or 0.0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return points[k] + (points[k + 1] - points[k]) * t, k
end
Rope.Mesh.Along = along

--- GTA's rope of `ropeType` for one of ours (its textures loaded already: Rope.Mesh.EnsureGtaTextures).
function Rope.Mesh.CreateGta(rope, ropeType)
    if not ropeTexturesLoaded then return false end
    local a = rope.nodes[1].position
    local len = (#rope.nodes - 1) * Rope.LinkLength(rope)
    local handle = AddRope(a.x, a.y, a.z, 0.0, 0.0, 0.0, len, ropeType or 4,
        ---@diagnostic disable-next-line: redundant-parameter -- the last (0) is the native's unkPtr, passed in by FiveM; the natives library leaves it out
        len, 0.5, 0.0, false, false, false, 1.0, false, 0)
    if not handle or not DoesRopeExist(handle) then return false end
    RopeSetUpdatePinverts(handle)
    rope.gtaRope = handle
    return true
end

function Rope.Mesh.DeleteGta(rope)
    local handle = rope.gtaRope
    rope.gtaRope = nil
    if handle and DoesRopeExist(handle) then DeleteRope(handle) end
end

--- Every frame: each of GTA's vertices onto our rope, spaced evenly along its length.
function Rope.Mesh.UpdateGta(rope, points)
    local handle = rope.gtaRope
    if not handle then return end
    local count = GetRopeVertexCount(handle)
    if not count or count < 2 then return end
    local cum = rope.gtaCum or {}
    cum[1] = 0.0
    for k = 2, #points do cum[k] = cum[k - 1] + #(points[k] - points[k - 1]) end
    rope.gtaCum = cum
    local total = cum[#points]
    local k = 1
    for v = 0, count - 1 do
        local p
        p, k = along(points, cum, total * v / (count - 1), k)
        PinRopeVertex(handle, v, p.x, p.y, p.z)
    end
end

--- Done with GTA's rope textures (whip_rope stopping).
function Rope.Mesh.ReleaseGtaTextures()
    if ropeTexturesLoaded then
        RopeUnloadTextures()
        ropeTexturesLoaded = false
    end
end

local MOVE_EPS = 0.01   -- a piece whose two ends moved less than this keeps its matrix

--- Every frame: each piece onto its gap.
function Rope.Mesh.Update(rope, points)
    local segs = rope.segments
    if not segs or #segs == 0 then return end
    rope.segmentLast = rope.segmentLast or {}
    local last = rope.segmentLast
    -- A rope lying still: skip working out the frames at all
    local any = false
    for k = 1, math.min(#segs, #points - 1) do
        local l = last[k]
        if not l or #(l.a - points[k]) > MOVE_EPS or #(l.b - points[k + 1]) > MOVE_EPS then
            any = true
            break
        end
    end
    if not any then return end
    -- A rope with its own look keeps that look's thickness (its piece is made at its size: a pump's hose)
    local look = rope.opts and rope.opts.look
    local thickness = look and (look.thickness or 1.0) or Config.Visuals.SegmentThickness or 1.0
    local frames = Rope.Mesh.Frames(points, thickness,
        Config.Visuals.SegmentOverlap or 0.0, rope.segmentFrames, Config.Visuals.SegmentLength or 0.25)
    rope.segmentFrames = frames
    for k, prop in ipairs(segs) do
        local fr = frames[k]
        if fr then
            local a, b = points[k], points[k + 1]
            local l = last[k]
            if not l or #(l.a - a) > MOVE_EPS or #(l.b - b) > MOVE_EPS then
                SetEntityMatrix(prop, fr.f.x, fr.f.y, fr.f.z, fr.r.x, fr.r.y, fr.r.z,
                    fr.u.x, fr.u.y, fr.u.z, fr.at.x, fr.at.y, fr.at.z)
                if l then l.a, l.b = a, b else last[k] = { a = a, b = b } end
            end
        end
    end
end
