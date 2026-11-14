--[[
    whip_rope — HANGING AS A RAGDOLL (Config.PlayerHang.Style = 'ragdoll')

    Someone hanging off a rope is drawn on every other game by a stand-in of them (client/visuals.lua: a local copy, not
    networked; their own ped is hidden there), and on their own game by their own ped, so the camera follows the body.
    With this style that body is GTA's Euphoria ragdoll, hanging from the rope by
    its right hand: it sways, swings and reacts as a body does.

      THE TIE      an invisible anchor at the rope's node, the ragdolled stand-in tied to it by its right hand
                   (AttachEntityToEntityPhysically). The anchor's COLLISION STAYS ON: with it off an object has no
                   physics body, and the tie pulls the body to 0, 0, 0 under the map.
      THE POINT    PlayerHang.Point: 'frozen' (the anchor put at the node every frame: the steadiest) or 'driven'
                   (a heavy anchor with no gravity, its speed set to reach the node each frame).
      THE HAND     PlayerHang.Hand: 'free' (a ball joint: it turns about the rope), 'settle' (free until the arm has
                   swung up the rope and the hand stops turning, then locked at that natural angle) or 'locked' (as
                   it is the moment it is tied: the arm still hanging down from standing, so the wrist kinks).
      KEPT HOLD    GTA ends a ragdoll and stands the ped up, and the tie goes with it: the ragdoll's timer is reset
                   every frame, the ragdoll started again the moment it ends, the tie made again if it breaks.
      THE ROPE     the body never pushes the rope (Rope.OnRope), and the rope's probes look through the anchor
                   (rope.probeIgnore): either would make the node by the hand kink and snap (client/collision.lua).
      EUPHORIA     its grab (the hands on the rope) and dangle are sent when PlayerHang.GrabMessage / DangleMessage
                   name their NM message numbers (0: not sent). Without the grab only the right hand holds (the tie):
                   GrabHands = 'both' needs the grab.
]]

Rope.HangRig = {}

local ANCHOR_MODEL = `prop_golf_ball`
local R_HAND = 57005               -- SKEL_R_Hand
local KEEP_MS = 60000              -- each ragdoll asked for this long (its timer reset every frame besides)
local NM_RESEND_MS = 400           -- the grab sent again this often (the rope moves)
local DRIVE_MAX = 25.0             -- m/s: the fastest a driven anchor is sent
local ANCHOR_MASS = 2000.0         -- kg: a driven anchor the body does not drag down
local SETTLE_STILL_DEG = 1.5       -- 'settle': the hand turning less than this a frame...
local SETTLE_STILL_FRAMES = 8      -- ...this many frames in a row
local SETTLE_MAX_MS = 1500         -- ...or this long at most
local TIE_MISS = 3.0               -- metres: a hand this far from the node once tied is a tie that missed
local TASKS = { relax = 0, script = 1, balance = 2 }

local function cfg() return Config.PlayerHang or {} end
local function task() return TASKS[cfg().RagdollTask] or 2 end

local function debugLine(text)
    if Rope.Util and Rope.Util.DebugPrint then Rope.Util.DebugPrint('[hang] ' .. text) end
end

-- ---- Euphoria (NM messages) ----

---@diagnostic disable-next-line: undefined-global -- not in the natives library; nil on a game without them (sendNm skips those)
local NM = { bool = SetNmMessageBool, float = SetNmMessageFloat, int = SetNmMessageInt, vec3 = SetNmMessageVec3 }

local function sendNm(ped, id, args)
    CreateNmMessage(true, id)
    for _, a in ipairs(args or {}) do
        local set = NM[a[1]]
        if set then
            if a[1] == 'vec3' then set(a[2], a[3], a[4], a[5]) else set(a[2], a[3]) end
        end
    end
    GivePedNmMessage(ped)
end

local function sendGrab(ped, p)
    local id = math.tointeger(tonumber(cfg().GrabMessage)) or 0
    if id <= 0 then return end
    sendNm(ped, id, {
        { 'bool', 'useRight', true }, { 'bool', 'useLeft', cfg().GrabHands == 'both' },
        { 'vec3', 'pos1', p.x, p.y, p.z }, { 'vec3', 'pos2', p.x, p.y, p.z },
        { 'int', 'instanceIndex', -1 }, { 'bool', 'dontLetGo', true }, { 'bool', 'lookAtGrab', true },
        { 'float', 'grabStrength', -1.0 }, { 'float', 'stickyHands', 4.0 },
        { 'float', 'pullUpStrengthRight', 0.0 }, { 'float', 'pullUpStrengthLeft', 0.0 },
        { 'float', 'grabHoldMaxTimer', 100.0 },
    })
end

local function sendDangle(ped)
    local id = math.tointeger(tonumber(cfg().DangleMessage)) or 0
    if id > 0 then sendNm(ped, id, {}) end
end

-- ---- the hand ----

local function turnBetween(a, b)
    local function d(x, y) return math.abs((x - y + 180.0) % 360.0 - 180.0) end
    return math.max(d(a.x, b.x), d(a.y, b.y), d(a.z, b.z))
end

local function handRotation(ped)
    if not GetEntityBoneRotation then return nil end
    return GetEntityBoneRotation(ped, GetPedBoneIndex(ped, R_HAND))
end

local function boneOf(ped)
    if cfg().TieBone == 'ragdoll' then return GetPedRagdollBoneIndex(ped, R_HAND) end
    return GetPedBoneIndex(ped, R_HAND)
end

local function tie(rig, fixed)
    AttachEntityToEntityPhysically(rig.ped, rig.anchor, rig.bone, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        1000000.0, fixed == true, true, false, false, 2)
end

-- ---- the anchor, and the rope's view of it ----

local function makeAnchor(p, driven)
    if not Whip.call('LoadModel', ANCHOR_MODEL, 3000) then return nil end
    local anchor = CreateObject(ANCHOR_MODEL, p.x, p.y, p.z, false, false, false)
    SetModelAsNoLongerNeeded(ANCHOR_MODEL)
    if not DoesEntityExist(anchor) then return nil end
    SetEntityVisible(anchor, false, false)
    if driven then
        FreezeEntityPosition(anchor, false)
        SetEntityDynamic(anchor, true)
        SetEntityHasGravity(anchor, false)
        if SetObjectPhysicsParams then
            pcall(SetObjectPhysicsParams, anchor, ANCHOR_MASS, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0)
        end
        ActivatePhysics(anchor)
    else
        FreezeEntityPosition(anchor, true)
    end
    return anchor
end

local function onRope(rig, rope)
    Rope.OnRope[rig.ped] = rope.serverRopeId
    rope.probeIgnore = rope.probeIgnore or {}
    rope.probeIgnore[rig.anchor] = true
    rig.ropeKey = rope.serverRopeId
end

local function offRope(rig)
    if rig.ped and Rope.OnRope[rig.ped] then Rope.OnRope[rig.ped] = nil end
    local rope = rig.ropeKey and Rope.System.ropes[rig.ropeKey]
    if rope and rope.probeIgnore then rope.probeIgnore[rig.anchor] = nil end
end

-- ============================================
-- The rig: made, kept each frame, taken down
-- ============================================

--- Hang the stand-in `cloneData.ped` from `nodePos` on `rope`. Waits a few frames: from a thread. The rig is kept on
--- cloneData.rig; nil and why when it could not be made (the caller draws the animation instead).
function Rope.HangRig.start(cloneData, rope, nodePos)
    local ped = cloneData.ped
    if not DoesEntityExist(ped) then return nil, 'no stand-in' end
    local driven = cfg().Point == 'driven'
    local anchor = makeAnchor(nodePos, driven)
    if not anchor then return nil, 'no anchor' end
    -- Let go while the anchor's model loaded (Rope.DeletePlayerClone): never tie a body nobody hangs any more
    if cloneData.gone then
        DeleteEntity(anchor)
        return nil, 'gone while it was made'
    end
    local rig = { ped = ped, anchor = anchor, driven = driven, hand = cfg().Hand or 'free', task = task(),
                  startedAt = GetGameTimer(), lastNm = 0, tied = false, stillFrames = 0 }
    cloneData.rig = rig
    onRope(rig, rope)

    SetEntityCollision(ped, true, true)   -- a ragdoll needs its body (the animation's stand-in has none)
    SetPedCanRagdoll(ped, true)
    SetPedToRagdoll(ped, KEEP_MS, KEEP_MS, rig.task, false, false, false)
    Wait(0); Wait(0)
    if cloneData.rig ~= rig or not DoesEntityExist(ped) then return nil, 'gone while it was made' end

    rig.bone = boneOf(ped)
    local locked = rig.hand == 'locked'
    if locked then
        local r = handRotation(ped)
        if r then rig.anchorRot = r; SetEntityRotation(anchor, r.x, r.y, r.z, 2, false) end
    end
    rig.settling = rig.hand == 'settle' and GetEntityBoneRotation ~= nil
    rig.locked = locked
    tie(rig, locked)
    rig.settleFrom = GetGameTimer()
    Wait(0); Wait(0)
    if cloneData.rig ~= rig or not DoesEntityExist(ped) then return nil, 'gone while it was made' end

    -- The hand must be at the node (a tie that missed pulls the body to 0, 0, 0)
    if #(GetPedBoneCoords(ped, R_HAND, 0.0, 0.0, 0.0) - GetEntityCoords(anchor)) > TIE_MISS then
        Rope.HangRig.stop(cloneData)
        return nil, 'the tie missed'
    end
    rig.tied = true
    sendNm(ped, 0, {})   -- stopAllBehaviours, then the grab and dangle (if they are set)
    sendGrab(ped, nodePos)
    sendDangle(ped)
    return rig
end

--- Every frame: the anchor at the node, the ragdoll and the tie kept, the hand locked once settled, the grab sent
--- again as the rope moves.
function Rope.HangRig.update(cloneData, nodePos)
    local rig = cloneData.rig
    if not rig or not rig.tied then return end
    local ped, anchor = rig.ped, rig.anchor
    if not DoesEntityExist(ped) or not DoesEntityExist(anchor) then return end

    ResetPedRagdollTimer(ped)
    if not IsPedRagdoll(ped) then
        SetPedToRagdoll(ped, KEEP_MS, KEEP_MS, rig.task, false, false, false)
        rig.rearmed = (rig.rearmed or 0) + 1
        if rig.rearmed == 1 or rig.rearmed % 50 == 0 then debugLine(('the game ended the ragdoll (%d): again'):format(rig.rearmed)) end
    end
    if not IsEntityAttachedToEntity(ped, anchor) then
        tie(rig, rig.locked)
        rig.retied = (rig.retied or 0) + 1
        if rig.retied == 1 or rig.retied % 50 == 0 then debugLine(('the tie broke (%d): tied again'):format(rig.retied)) end
    end

    -- The point
    local at = GetEntityCoords(anchor)
    if rig.driven then
        local v = (nodePos - at) / math.max(GetFrameTime(), 0.008)
        local speed = #v
        if speed > DRIVE_MAX then v = v * (DRIVE_MAX / speed) end
        SetEntityVelocity(anchor, v.x, v.y, v.z)
        if rig.locked and rig.anchorRot then
            SetEntityRotation(anchor, rig.anchorRot.x, rig.anchorRot.y, rig.anchorRot.z, 2, false)
            if SetEntityAngularVelocity then SetEntityAngularVelocity(anchor, 0.0, 0.0, 0.0) end
        end
    elseif #(nodePos - at) > 0.005 then
        SetEntityCoordsNoOffset(anchor, nodePos.x, nodePos.y, nodePos.z, false, false, false)
    end

    -- 'settle': locked once the hand has stopped turning (or SETTLE_MAX_MS)
    if rig.settling then
        local r = handRotation(ped)
        if r then
            if rig.lastRot and turnBetween(r, rig.lastRot) < SETTLE_STILL_DEG then rig.stillFrames = rig.stillFrames + 1
            else rig.stillFrames = 0 end
            rig.lastRot = r
            if rig.stillFrames >= SETTLE_STILL_FRAMES or GetGameTimer() - rig.settleFrom >= SETTLE_MAX_MS then
                rig.settling, rig.locked, rig.anchorRot = false, true, r
                SetEntityRotation(anchor, r.x, r.y, r.z, 2, false)
                DetachEntity(ped, true, true)
                tie(rig, true)
            end
        end
    end

    local now = GetGameTimer()
    if now - rig.lastNm >= NM_RESEND_MS then rig.lastNm = now; sendGrab(ped, nodePos) end
end

--- Take the rig down: the tie undone, Euphoria stopped, the anchor gone, the rope told
function Rope.HangRig.stop(cloneData)
    local rig = cloneData and cloneData.rig
    if not rig then return end
    cloneData.rig = nil
    offRope(rig)
    if DoesEntityExist(rig.ped) then
        DetachEntity(rig.ped, true, true)
        sendNm(rig.ped, 0, {})
    end
    if DoesEntityExist(rig.anchor) then DeleteEntity(rig.anchor) end
end
