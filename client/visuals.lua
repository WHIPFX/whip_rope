--[[
    whip_rope — LOOKS

    How a rope is drawn — Config.Visuals.Style: 'segments' (3D Clanker's rope pieces, client/mesh.lua),
    'gta' (GTA's own rope pinned along ours, client/mesh.lua) or 'balls' (a prop per node) — along the
    rope's points (its nodes, or more along a Catmull-Rom spline); someone hanging off the rope drawn by
    a stand-in ped; and the debug overlay.
]]

local DebugPrint = Rope.Util.DebugPrint

Rope.HANG_ANIM_DICT = 'missrappel'
Rope.HANG_ANIM_NAME = 'rappel_idle'

-- ============================================================================
-- WHICH LOOK
-- ============================================================================

Rope.STYLES = { segments = true, gta = true, balls = true }

local lookGeneration = 0      -- one more on every change of look: a rope still loading the old one waits on

--- The rope pieces' model: with shadows, or the cheaper one without.
function Rope.SegmentModel()
    if Config.Visuals.SegmentShadows == false then return Config.Visuals.SegmentModelNoShadow end
    return Config.Visuals.SegmentModel
end

--- The look ropes are drawn in on this game now.
function Rope.CurrentStyle()
    local style = Config.Visuals.Style or 'segments'
    if not Rope.STYLES[style] then style = 'balls' end
    -- The rope pieces need their model streamed (stream/, the ytyp in fxmanifest.lua); without it, balls
    if style == 'segments' and not IsModelInCdimage(Rope.SegmentModel()) then style = 'balls' end
    return style
end

function Rope.GtaRopeType()
    return Config.Visuals.GtaRopeType or 4
end

-- ============================================================================
-- LOADING A LOOK
-- ============================================================================

local loadedModels = {}

-- A look's model (or GTA's rope textures), loaded once. Waits: from a thread.
local function ensureLookLoaded(style)
    if style == 'gta' then return Rope.Mesh.EnsureGtaTextures() end
    local model = style == 'segments' and Rope.SegmentModel() or Config.Visuals.PropModel
    if loadedModels[model] then return true end
    if not Whip.core:LoadModel(model) then
        DebugPrint('the rope look did not load:', style)
        return false
    end
    loadedModels[model] = true
    return true
end

--- The look to draw in, loaded: the current one, or the balls when its model or textures will not load
--- (nil when neither will: whip_core is not up). Waits: from a thread.
function Rope.LoadLook()
    local style = Rope.CurrentStyle()
    if ensureLookLoaded(style) then return style end
    if style ~= 'balls' and ensureLookLoaded('balls') then return 'balls' end
    return nil
end

function Rope.LookGeneration() return lookGeneration end

--- Every rope drawn again in the look there is now (a setting changed).
function Rope.RedrawRopes()
    lookGeneration = lookGeneration + 1
    for _, rope in pairs(Rope.System.ropes) do
        Rope.DestroyRopeVisuals(rope)
        Rope.EnsureRopeProps(rope)
    end
end

--- whip_rope stopping: every model it loaded, let go.
function Rope.ReleaseLookModels()
    for model in pairs(loadedModels) do SetModelAsNoLongerNeeded(model) end
    loadedModels = {}
    Rope.Mesh.ReleaseGtaTextures()
end

-- The look's settings changed in /whip → Settings → Rope: the thickness is read every frame (each piece
-- placed again at once); anything else draws every rope again
Whip.onConfigChanged('Visuals', function(value, old, key)
    if value == old and type(value) ~= 'table' then return end
    if key == 'Visuals.SegmentThickness' or key == 'Visuals.SegmentOverlap' then
        for _, rope in pairs(Rope.System.ropes) do rope.segmentLast = nil end
        return
    end
    Rope.RedrawRopes()
end)

-- ============================================================================
-- PROPS (the balls)
-- ============================================================================

local function CreateRopeProp(position)
    local prop = CreateObject(Config.Visuals.PropModel, position.x, position.y, position.z,
        false, false, false)   -- not networked: every game draws its own rope
    if not DoesEntityExist(prop) then return nil end
    SetEntityCollision(prop, false, false)
    FreezeEntityPosition(prop, true)
    SetEntityLodDist(prop, 500)
    return prop
end

--- Only ever one of our own props (never whatever a stale handle now names).
function Rope.DeleteRopeProp(prop)
    if DoesEntityExist(prop) and GetEntityModel(prop) == Config.Visuals.PropModel then
        DeleteEntity(prop)
    end
end

-- ============================================================================
-- THE SPLINE
-- ============================================================================

local function CatmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    local point = 0.5 * ((2.0 * p1) + (p2 - p0) * t
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)
    local tangent = 0.5 * ((p2 - p0)
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * (2.0 * t)
        + (3.0 * p1 - p0 - 3.0 * p2 + p3) * (3.0 * t2))
    return point, tangent
end

-- The k-th prop's place along the rope (1-based)
local function SampleSpline(nodes, nodeCount, samplesPerSegment, k)
    local segIndex = math.floor((k - 1) / samplesPerSegment) + 1
    local t = ((k - 1) % samplesPerSegment) / samplesPerSegment
    if segIndex >= nodeCount then
        segIndex = nodeCount - 1
        t = 1.0
    end
    local p0 = nodes[math.max(1, segIndex - 1)].position
    local p1 = nodes[segIndex].position
    local p2 = nodes[math.min(nodeCount, segIndex + 1)].position
    local p3 = nodes[math.min(nodeCount, segIndex + 2)].position
    return CatmullRom(p0, p1, p2, p3, t)
end

-- ============================================================================
-- THE ROPE'S LOOK
-- ============================================================================

-- The rope's points this frame (its nodes, or more along the spline), into the rope's own list
local function RopePoints(rope)
    local nodes = rope.nodes
    local nodeCount = #nodes
    local samples = Config.Visuals.SplineSamplesPerSegment or 1
    local pts = rope.lookPoints or {}
    local count = (nodeCount - 1) * samples + 1
    if samples == 1 then
        -- One point a gap: the spline at each node IS the node (at t = 0 every other term is nought), so
        -- the nodes themselves, without its twenty-odd sums a point every frame
        for k = 1, count do pts[k] = nodes[k].position end
    else
        for k = 1, count do pts[k] = SampleSpline(nodes, nodeCount, samples, k) end
    end
    for k = count + 1, #pts do pts[k] = nil end
    rope.lookPoints = pts
    return pts
end

--- Draw a rope in `style` (loaded already: Rope.LoadLook), where it lies now — a rope asleep is not
--- drawn again until it wakes. False when GTA would not make its rope (the watchdog asks again).
function Rope.CreateRopeVisuals(rope, style)
    rope.props = {}
    rope.propLastPos = {}
    if not Config.Visuals.RenderProps then return false end

    if style == 'segments' then
        local points = RopePoints(rope)
        -- A resource's rope in its own pieces (its `look`, as a pump's hose's rubber), loaded before it is drawn
        -- (client/api.lua); the rope's own when they will not load.
        local model = Rope.SegmentModel()
        local own = Rope.OwnLookModel(rope)
        if own and HasModelLoaded(own) then model = own end
        Rope.Mesh.Create(rope, #points, model)
        Rope.Mesh.Update(rope, points)
    elseif style == 'gta' then
        if not Rope.Mesh.CreateGta(rope, Rope.GtaRopeType()) then return false end
        Rope.Mesh.UpdateGta(rope, RopePoints(rope))
    else
        style = 'balls'
        local nodes = rope.nodes
        local nodeCount = #nodes
        local samples = Config.Visuals.SplineSamplesPerSegment or 1
        for k = 1, (nodeCount - 1) * samples + 1 do
            local prop = CreateRopeProp(SampleSpline(nodes, nodeCount, samples, k))
            if prop then rope.props[#rope.props + 1] = prop end
        end
    end
    rope.lookStyle = style
    rope.lookReady = true
    return true
end

--- Take a rope's look away (all of it, whichever look it was drawn in).
function Rope.DestroyRopeVisuals(rope)
    for _, prop in ipairs(rope.props or {}) do Rope.DeleteRopeProp(prop) end
    rope.props = {}
    rope.propLastPos = {}
    Rope.Mesh.Delete(rope)
    Rope.Mesh.DeleteGta(rope)
    rope.lookReady = false
    rope.lookStyle = nil
end

local MIN_MOVE_DIST_SQ = 0.02 * 0.02   -- under 2 cm a prop is not moved

function Rope.UpdateRopeVisuals(rope)
    if not Config.Visuals.RenderProps or not rope.lookReady then return end
    if rope.lookStyle == 'segments' then
        return Rope.Mesh.Update(rope, RopePoints(rope))
    elseif rope.lookStyle == 'gta' then
        return Rope.Mesh.UpdateGta(rope, RopePoints(rope))
    end

    local nodes = rope.nodes
    local nodeCount = #nodes
    local samples = Config.Visuals.SplineSamplesPerSegment or 1
    local rotate = Config.Visuals.RotateProps
    local lastPositions = rope.propLastPos

    for k, prop in ipairs(rope.props) do
        local pos, tangent = SampleSpline(nodes, nodeCount, samples, k)
        local lastPos = lastPositions[k]
        local moved = true
        if lastPos then
            local dx, dy, dz = pos.x - lastPos.x, pos.y - lastPos.y, pos.z - lastPos.z
            moved = dx * dx + dy * dy + dz * dz >= MIN_MOVE_DIST_SQ
        end
        if moved and DoesEntityExist(prop) then
            SetEntityCoords(prop, pos.x, pos.y, pos.z, false, false, false, false)
            lastPositions[k] = pos
            if rotate then
                local len = #tangent
                if len > 0.01 then
                    local dir = tangent / len
                    local heading = math.deg(math.atan(dir.x, dir.y)) + 90
                    local pitch = math.deg(math.acos(math.max(-1, math.min(1, dir.z))))
                    SetEntityRotation(prop, pitch, 0.0, heading, 2, true)
                end
            end
        end
    end
end

-- ============================================================================
-- THE STAND-IN FOR SOMEONE HANGING OFF IT
-- ============================================================================
-- The hanging player's own ped is hidden from every other game (whip's ped hold), and each of those games draws a
-- stand-in of them hanging from its own rope (a rope is each game's own: its nodes are a little apart on each).
--
-- On their OWN game, hanging as a ragdoll (Config.PlayerHang.Style), the body on the rope is their real ped, so the
-- camera follows the body that swings. Hanging by the animation, a stand-in hangs there too, and the hidden ped is
-- put under the hand every frame (no animation survives that).

--- A stand-in for `serverId`, dressed as `realPed` (on our own game, hanging as a ragdoll: `realPed` itself, rigged).
--- Waits (model, animation, the tie): from a thread.
function Rope.CreatePlayerClone(serverId, realPed)
    if Rope.Clones[serverId] then return Rope.Clones[serverId].ped end

    if serverId == Rope.MyServerId() and Rope.HangOwnBody then
        local hangData = Rope.HangingPlayers[serverId]
        local rope = hangData and Rope.System.ropes[hangData.serverRopeId]
        local node = rope and rope.nodes[hangData.nodeIndex]
        local cloneData = { ped = realPed, realPed = realPed, own = true, rigging = true }
        Rope.Clones[serverId] = cloneData
        ---@type table|nil, string|nil
        local rig, why = nil, 'no node'
        if node then rig, why = Rope.HangRig.start(cloneData, rope, node.position) end
        cloneData.rigging = nil
        -- Let go meanwhile: no rig left behind (one made after the let-go has nobody to take it down)
        if not Rope.HangingPlayers[serverId] or Rope.Clones[serverId] ~= cloneData then
            Rope.HangRig.stop(cloneData)
            return nil
        end
        if rig then return realPed end
        Rope.Clones[serverId] = nil
        DebugPrint('our ragdoll hang could not be made', why, ': a stand-in with the animation instead')
        Rope.HangPedOn(realPed, false)   -- our ped as under a stand-in: no collision, no ragdoll, put under the hand
    end

    local pedModel = GetEntityModel(realPed)
    if not Whip.core:LoadModel(pedModel) then
        DebugPrint('the stand-in model did not load for', serverId)
        return nil
    end
    -- The wait above: they may have let go meanwhile, or another call made one
    if not Rope.HangingPlayers[serverId] or Rope.Clones[serverId] or not DoesEntityExist(realPed) then
        SetModelAsNoLongerNeeded(pedModel)
        return Rope.Clones[serverId] and Rope.Clones[serverId].ped or nil
    end

    local c = GetEntityCoords(realPed)
    local clonePed = CreatePed(4, pedModel, c.x, c.y, c.z, GetEntityHeading(realPed), false, false)
    SetModelAsNoLongerNeeded(pedModel)
    if not DoesEntityExist(clonePed) then return nil end

    ClonePedToTarget(realPed, clonePed)
    SetEntityInvincible(clonePed, true)
    SetBlockingOfNonTemporaryEvents(clonePed, true)
    SetPedCanBeTargetted(clonePed, false)
    SetPedCanBeTargettedByPlayer(clonePed, PlayerId(), false)

    local cloneData = { ped = clonePed, realPed = realPed }
    Rope.Clones[serverId] = cloneData

    -- AS A RAGDOLL (Config.PlayerHang.Style, client/hang_ragdoll.lua): GTA's Euphoria body hanging by its right hand
    -- from the node. Could it not be (no anchor, a tie that missed), or the style is 'animation': the looped hang
    -- animation, with no collision and no ragdoll.
    if (Config.PlayerHang.Style or 'ragdoll') == 'ragdoll' then
        local hangData = Rope.HangingPlayers[serverId]
        local rope = hangData and Rope.System.ropes[hangData.serverRopeId]
        local node = rope and rope.nodes[hangData.nodeIndex]
        if node then
            cloneData.rigging = true
            local rig, why = Rope.HangRig.start(cloneData, rope, node.position)
            cloneData.rigging = nil
            if rig then return clonePed end
            DebugPrint('the ragdoll hang could not be made for', serverId, why, ': the animation instead')
        end
        if Rope.Clones[serverId] ~= cloneData or not DoesEntityExist(clonePed) then return nil end
    end

    SetEntityCollision(clonePed, false, false)
    SetPedCanRagdoll(clonePed, false)
    if Whip.core:LoadAnimDict(Rope.HANG_ANIM_DICT) and DoesEntityExist(clonePed) then
        TaskPlayAnim(clonePed, Rope.HANG_ANIM_DICT, Rope.HANG_ANIM_NAME, 8.0, -8.0, -1, 1, 0, false, false, false)
    end
    return clonePed
end

function Rope.DeletePlayerClone(serverId)
    local cloneData = Rope.Clones[serverId]
    if not cloneData then return end
    -- A rig still being made (its anchor's model loading) sees this and takes itself down (Rope.HangRig.start)
    cloneData.gone = true
    Rope.HangRig.stop(cloneData)
    -- (Our own ped, when it was the body on the rope, is ours: never deleted)
    if not cloneData.own and DoesEntityExist(cloneData.ped) then DeleteEntity(cloneData.ped) end
    Rope.Clones[serverId] = nil
end

function Rope.DeleteAllClones()
    for serverId in pairs(Rope.Clones) do
        Rope.DeletePlayerClone(serverId)
    end
end

-- The spot under a node a hanging ped is drawn at: hands at the node, never through the ground
local function HangSpot(nodePos)
    local targetZ = nodePos.z - 1.0
    local hit, hitPos = Rope.SyncProbe(nodePos.x, nodePos.y, nodePos.z + 0.5,
        nodePos.x, nodePos.y, nodePos.z - 2.0, 1 + 16, 0)
    if hit and targetZ < hitPos.z + 1.0 then targetZ = hitPos.z + 1.0 end
    return nodePos.x, nodePos.y, targetZ
end

local function PlaceClone(cloneData, x, y, z)
    local clonePed = cloneData.ped
    if not DoesEntityExist(clonePed) then return end
    SetEntityCoordsNoOffset(clonePed, x, y, z, false, false, false)
    if HasAnimDictLoaded(Rope.HANG_ANIM_DICT)
        and not IsEntityPlayingAnim(clonePed, Rope.HANG_ANIM_DICT, Rope.HANG_ANIM_NAME, 3) then
        TaskPlayAnim(clonePed, Rope.HANG_ANIM_DICT, Rope.HANG_ANIM_NAME, 8.0, -8.0, -1, 1, 0, false, false, false)
    end
end

--- Every frame: each hanging player's stand-in at their node, and our own ped: the body on the rope (a ragdoll hang),
--- drawn here though hidden from the others, or put with its stand-in (the camera follows our real ped).
function Rope.UpdateHangingVisuals(rope)
    -- Not gated on PlayerHang.Enabled: a hang already on is drawn until it ends (ui.lua lets go)
    local serverRopeId = rope.serverRopeId
    if not serverRopeId then return end
    local myServerId = Rope.MyServerId()

    for serverId, hangData in pairs(Rope.HangingPlayers) do
        if hangData.serverRopeId == serverRopeId then
            local node = rope.nodes[hangData.nodeIndex]
            if node then
                -- The spot under the node (HangSpot casts a ray): worked out only for what is put there, the animation's
                -- stand-in and our own ped under it. A ragdoll hangs from the node itself.
                local x, y, z
                local cloneData = Rope.Clones[serverId]
                if cloneData then
                    -- Their real ped is hidden here but may still be solid, and hangs where the stand-in does (on
                    -- their own game it is the ragdoll): the two never touch
                    if not cloneData.own and DoesEntityExist(cloneData.ped) and DoesEntityExist(cloneData.realPed) then
                        SetEntityNoCollisionEntity(cloneData.ped, cloneData.realPed, true)
                    end
                    -- A ragdoll hangs by its tie (its anchor kept at the node); the animation's stand-in is put there
                    if cloneData.rig then
                        Rope.HangRig.update(cloneData, node.position)
                    elseif not cloneData.rigging then
                        x, y, z = HangSpot(node.position)
                        PlaceClone(cloneData, x, y, z)
                    end
                end

                if serverId == myServerId then
                    local ped = PlayerPedId()
                    if Rope.HangOwnBody then
                        -- The ped hold hides it from everyone; here it is the body (both natives draw it this frame
                        -- only: the entity's, and the local player's own)
                        SetEntityLocallyVisible(ped)
                        SetLocalPlayerVisibleLocally(false)
                    else
                        if not x then x, y, z = HangSpot(node.position) end
                        if IsPedRagdoll(ped) then ClearPedTasksImmediately(ped) end
                        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
                        SetEntityVelocity(ped, 0.0, 0.0, 0.0)
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- DEBUG (Config.Debug, or /ropedebug for yourself)
-- ============================================================================

local function DrawDebugText(x, y, text)
    SetTextFont(0)
    SetTextScale(0.35, 0.35)
    SetTextColour(255, 255, 255, 255)
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

function Rope.DrawRopeDebug(rope)
    local nodes = rope.nodes
    local nodeCount = #nodes
    for i = 1, nodeCount do
        local p = nodes[i].position
        if Config.DrawDebugSpheres then
            local r, g, b = 255, 255, 0
            if i == 1 then r, g, b = 0, 255, 0 elseif i == nodeCount then r, g, b = 255, 0, 0 end
            DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.06, 0.06, 0.06, r, g, b, 200,
                ---@diagnostic disable-next-line: param-type-mismatch -- no texture: nil (the natives library types them string)
                false, false, 2, false, nil, nil, false)
        end
        if Config.DrawDebugLines and i < nodeCount then
            local q = nodes[i + 1].position
            DrawLine(p.x, p.y, p.z, q.x, q.y, q.z, 255, 255, 255, 200)
        end
    end
end

local function EndString(rope, which, me)
    local t = rope[which .. 'Type']
    if t == 'held' then
        local by = rope[which .. 'HeldBy']
        return by == me and 'ME' or ('#' .. tostring(by))
    elseif t == 'vehicle' or t == 'object' then
        local mass = rope[which .. 'Mass']
        local label = t == 'vehicle' and 'VEH' or 'OBJ'
        local entity = rope[which .. 'Entity']
        if not entity or not DoesEntityExist(entity) then return label .. '(away)' end
        -- Whether the rope moves it at all (a frozen prop, or a map prop not woken, is an anchor), whether
        -- THIS game does (only the game in charge of it pulls it), and how fast it goes: a tied thing that
        -- "will not budge" shows which it is
        local how
        if not Rope.BodyOf(rope, which) then
            how = 'anchor, not pulled'
        elseif not NetworkGetEntityIsNetworked(entity) or NetworkGetEntityOwner(entity) == PlayerId() then
            how = 'moved here'
        else
            how = 'moved by another game'
        end
        return ('%s(%.0fkg, %.1fm/s, %s)'):format(label, mass or 0, GetEntitySpeed(entity), how)
    end
    return tostring(t)
end

function Rope.DrawDebugOverlay()
    local y = 0.1
    local spacing = 0.02
    local me = Rope.MyServerId()

    local ropeCount = 0
    for _ in pairs(Rope.System.ropes) do ropeCount = ropeCount + 1 end
    DrawDebugText(0.01, y, ('whip_rope — %d rope(s)'):format(ropeCount))
    y = y + spacing
    -- The ground's two ways compared (Config.WorldCollision.Ground): every ray the rope casts, and the grid's points
    DrawDebugText(0.01, y, ('Ground: %s | rays %d a second | grid points kept %d | links touching another rope %d%s'):format(
        Config.WorldCollision.Ground == 'grid' and 'GRID' or 'RAYS', Rope.RaysPerSecond(), Rope.GridPoints(),
        Rope.Touching or 0, Rope.Carrying() and ' (taking each other\'s weight)' or ''))
    y = y + spacing

    local hang = Rope.HangingPlayers[me]
    local _, heldKey, heldEnd = Rope.MyHeld()
    if hang then
        DrawDebugText(0.01, y, ('HANGING on rope %d, node %d'):format(hang.serverRopeId, hang.nodeIndex))
        y = y + spacing
    elseif heldKey then
        DrawDebugText(0.01, y, ('HOLDING the %s of rope %s'):format(heldEnd, tostring(heldKey)))
        y = y + spacing
    end
    y = y + spacing

    for ropeKey, rope in pairs(Rope.System.ropes) do
        DrawDebugText(0.01, y, ('Rope #%s (srv:%s) | O:%s T:%s | %s'):format(
            tostring(ropeKey), tostring(rope.serverRopeId or 'pending'),
            EndString(rope, 'origin', me), EndString(rope, 'tail', me),
            rope.simulated == false and 'asleep (far)' or (rope.resting and 'at rest' or 'simulated')))
        y = y + spacing
        if rope.debugRopeLength then
            DrawDebugText(0.01, y, ('  Len:%.2fm | Along:%.2fm | Ends:%.2fm | Straight:%.0f%% | Over:%.2fm'):format(
                rope.debugRopeLength or 0, rope.debugActualLength or 0, rope.debugDistance or 0,
                (rope.debugStraightness or 0) * 100, rope.debugOverstretch or 0))
            y = y + spacing
            DrawDebugText(0.01, y, ('  Tension %.1f kN | Pull O:%.1f T:%.1f m/s² | Held fast: %.2f | Drawing back: %.2f m/s | Snap:%s'):format(
                (rope.debugTension or 0) / 1000, rope.debugOriginForce or 0, rope.debugTailForce or 0,
                rope.debugLimitDv or 0, rope.debugReturnDv or 0, rope.isSnapBackActive and 'ACTIVE' or 'idle'))
            y = y + spacing
        end
        y = y + spacing * 0.5
    end
end
