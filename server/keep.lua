--[[
    whip_rope — WHO KEEPS WHAT A ROPE PULLS (client/keep.lua takes it on the keeper's game)

    Every car and prop is moved by one game: its network owner. A KEEPER is named for each car or networked prop
    a rope pulls (Config.Keep):
      pulled by a car someone drives        that driver
      pulled by a hand                      that hand (a driver beats a hand: a hand cannot pull what a car does)
      down a tow train (a car pulling a torn pump pulling a nozzle on the ground)   the train's keeper
    A car someone drives is its driver's and is never kept, so two driven cars on one rope each keep their own.
    A car a Director take drives (a recorded drive: whip_core's GetVehicleDriver) is driven the same way, by the game
    the take plays on. whip_core keeps it on that game, and a hand taking it would fight that every two seconds. That
    game is told which cars a take drives there ('whip_rope:driven'): the rope never pulls them, as the recording moves
    them.
    A map prop has no network id and nobody can keep it. The first keeper stays while it is still one, so two
    pullers never take turns.

    Worked out whenever an end changes (Ropes.sendEnds, Ropes.remove) and once a second while any rope or keeper
    is out (drivers get in and out). Each keeper's game is sent its whole list, only when it changes.
]]

Keepers = {
    of = {},          -- [netId] = the server id keeping it
    sent = {},        -- [server id] = { [netId] = true }: the list their game was last sent
    drivenSent = {},  -- [server id] = { [netId] = true }: the cars a take drives there, as their game was last told
    watched = {},     -- [netId] = { keptAt, want, stuckSince, toldAt, told }: all a rope has had kept (Keepers.watch)
}

local HAND, DRIVER = 1, 2   -- who wins when two would keep one thing

--- The player whose game drives this car, or nil, and how: 'seat' (at its wheel) or 'take' (a Director take, a
--- recorded drive, played on their game).
local function driverOf(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local ped = GetPedInVehicleSeat(veh, -1)
    if ped and ped ~= 0 and IsPedAPlayer(ped) then
        local src = NetworkGetEntityOwner(ped)   -- a player's ped is their own game's
        if src and src > 0 then return src, 'seat' end
    end
    -- (whip_core down: false and why, so no take drives it)
    local src, how = Whip.call('GetVehicleDriver', { netId = netId })
    if type(src) == 'number' and src > 0 and how == 'take' then return src, 'take' end
    return nil
end

--- What an end is: a PULLER (a server id and how strong) or a BODY (a network id something can keep), or neither.
--- A puller that is a take's car also answers 'take' (fourth).
local function roleOf(e)
    if e.type == 'held' and e.heldBy then return e.heldBy, HAND, nil end
    local netId = tonumber(e.netId) or 0
    if netId <= 0 then return nil end
    if e.type == 'vehicle' then
        local driver, how = driverOf(netId)
        if driver then return driver, DRIVER, nil, how end
        return nil, nil, netId
    end
    if e.type == 'object' then return nil, nil, netId end
    return nil
end

local function sameSet(a, b)
    if not a or not b then return a == b end
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

--- Each game whose set changed is sent its whole list (`event`); `sent` remembers what it was sent.
local function sendSets(sets, sent, event, what)
    local players = {}
    for src in pairs(sets) do players[src] = true end
    for src in pairs(sent) do players[src] = true end
    for src in pairs(players) do
        local set = sets[src]
        if not sameSet(set, sent[src]) then
            local out = {}
            for netId in pairs(set or {}) do out[#out + 1] = netId end
            TriggerClientEvent(event, src, out)
            Ropes.debug(what, src, 'now', #out, 'thing(s)')
            sent[src] = set
        end
    end
end

--- Who keeps what, now; each game whose list changed is told.
function Keepers.work()
    local want = {}    -- [netId] = { src, rank }
    local links = {}   -- [netId] = { netId, ... }: bodies tied to bodies
    local driven = {}  -- [server id] = { [netId] = true }: cars a take drives on their game
    local function drive(e, src, how)
        if how ~= 'take' then return end
        driven[src] = driven[src] or {}
        driven[src][tonumber(e.netId)] = true
    end
    local keep = not (Config.Keep and Config.Keep.Enabled == false)
    local function offer(body, src, rank)
        if not body or not src then return end
        local w = want[body]
        -- The stronger puller; between equals, the one keeping it already
        if not w or rank > w.rank or (rank == w.rank and src == Keepers.of[body]) then
            want[body] = { src = src, rank = rank }
        end
    end
    local function link(a, b)
        links[a] = links[a] or {}
        links[a][#links[a] + 1] = b
    end
    for _, rope in pairs(Ropes.all) do
        local pA, rA, bA, hA = roleOf(rope.origin)
        local pB, rB, bB, hB = roleOf(rope.tail)
        drive(rope.origin, pA, hA)
        drive(rope.tail, pB, hB)
        if keep then
            offer(bB, pA, rA)
            offer(bA, pB, rB)
            if bA and bB and bA ~= bB then link(bA, bB); link(bB, bA) end
        end
    end
    if keep then
        -- Down each tow train: a body tied to a kept one is its keeper's too, unless a stronger puller has it
        local queue = {}
        for netId in pairs(want) do queue[#queue + 1] = netId end
        local i = 1
        while i <= #queue do
            local from = queue[i]
            i = i + 1
            local w = want[from]
            for _, to in ipairs(links[from] or {}) do
                local t = want[to]
                if not t or t.rank < w.rank then
                    want[to] = { src = w.src, rank = w.rank }
                    queue[#queue + 1] = to
                end
            end
        end
    end

    local lists = {}
    Keepers.of = {}
    local now = GetGameTimer()
    for netId, w in pairs(want) do
        Keepers.of[netId] = w.src
        lists[w.src] = lists[w.src] or {}
        lists[w.src][netId] = true
        local watched = Keepers.watched[netId]
        if watched then watched.keptAt = now else Keepers.watched[netId] = { keptAt = now } end
    end
    sendSets(lists, Keepers.sent, 'whip_rope:keep', 'keeper')
    sendSets(driven, Keepers.drivenSent, 'whip_rope:driven', 'cars a take drives for')
    Keepers.sendLags()
end

-- ============================================================================
-- HOW LATE EACH SEES THE OTHER (a rope whose two ends two games move)
-- ============================================================================
-- Two driven cars on one rope (or a thing kept by one player and pulled by another) are each moved by their own
-- game, which sees the other one as it was: about the two players' pings ago (to the server and on), plus a
-- little for GTA's own sending. Each of those games is told, per rope, so its pull can allow for it
-- (client/physics.lua's pullPoint).

local SEND_MS = 0.05     -- s: GTA sends a moving car on every few frames, so half that again on top
local LAG_STEP = 0.02    -- s: a change smaller than this is not worth sending

Keepers.lagSent = {}     -- [server id] = { [ropeId] = s }: what their game was last told
Keepers.movers = {}      -- [ropeId] = { a, b }: the two games moving a rope's two ends, as last worked out

--- Who moves what an end is tied to: its driver, its keeper, or (neither) its network owner. nil for a hand,
--- a loose end, a map prop or a fixed spot.
local function moverOf(e)
    local netId = tonumber(e.netId) or 0
    if netId <= 0 or (e.type ~= 'vehicle' and e.type ~= 'object') then return nil end
    if e.type == 'vehicle' then
        local driver = driverOf(netId)
        if driver then return driver end
    end
    if Keepers.of[netId] then return Keepers.of[netId] end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    local owner = NetworkGetEntityOwner(entity)
    return owner and owner > 0 and owner or nil
end

local function pingOf(src)
    return (tonumber(GetPlayerPing(src)) or 0) / 1000.0
end

function Keepers.sendLags()
    local lags = {}   -- [server id] = { [ropeId] = s }
    local movers = {}
    for id, rope in pairs(Ropes.all) do
        local a, b = moverOf(rope.origin), moverOf(rope.tail)
        if a and b and a ~= b then
            local lag = (pingOf(a) + pingOf(b)) / 2.0 + SEND_MS
            lags[a] = lags[a] or {}
            lags[b] = lags[b] or {}
            lags[a][id], lags[b][id] = lag, lag
            movers[id] = { a, b }
        end
    end
    Keepers.movers = movers
    local players = {}
    for src in pairs(lags) do players[src] = true end
    for src in pairs(Keepers.lagSent) do players[src] = true end
    for src in pairs(players) do
        local now, was = lags[src], Keepers.lagSent[src]
        local changed = (now == nil) ~= (was == nil)
        if not changed and now then
            for id, s in pairs(now) do
                if not was[id] or math.abs(was[id] - s) >= LAG_STEP then changed = true break end
            end
            for id in pairs(was) do if not now[id] then changed = true break end end
        end
        if changed then
            TriggerClientEvent('whip_rope:lag', src, now or {})
            Keepers.lagSent[src] = now
        end
    end
end

--- One game's word on where it sees the far end of the ropes two games move (client/keep.lua), passed on to the
--- other game moving each: only for a rope the sender is one of the two movers of.
function Keepers.onSpan(source, _, batch)
    local out = {}   -- [server id] = { { r, x, y, z }, ... }
    for _, e in ipairs(batch) do
        local m = Keepers.movers[e.r]
        local other = m and (m[1] == source and m[2] or m[2] == source and m[1]) or nil
        if other then
            out[other] = out[other] or {}
            out[other][#out[other] + 1] = { r = e.r, x = e.x, y = e.y, z = e.z }
        end
    end
    for target, list in pairs(out) do TriggerClientEvent('whip_rope:theirSpan', target, list) end
end

-- Once a tick at most: an end change often comes in a run (both ends, several ropes)
local pending = false
function Keepers.soon()
    if pending then return end
    pending = true
    SetTimeout(0, function()
        pending = false
        Keepers.work()
    end)
end

--- Their game has started over (whip_rope restarted there): its list is sent again.
function Keepers.resend(source)
    Keepers.sent[source] = nil
    Keepers.lagSent[source] = nil
    Keepers.drivenSent[source] = nil
    Keepers.soon()
end

-- ============================================================================
-- NOBODY LEFT WITHOUT THE WHEEL
-- ============================================================================
-- A keeper's game locks what it keeps so GTA won't hand it on (client/keep.lua). The lock is on the car, not on the
-- game: it goes with the car when FiveM moves it anyway (its owner left, changed worlds at the character screen, or
-- went quiet), and the game holding it then has no idea. Nobody else gets control of it again: a player at its wheel
-- sits in a car that takes no notice of them, and a keeper's game asks for it forever, so its rope holds the other
-- end to it like a post, while its owner drives it fine. So every car or prop a rope has had kept is watched:
-- whoever should have it (the player at its wheel, else its keeper) and still doesn't after STUCK_MS has its owner's
-- game told to lift the lock ('whip_rope:letGo'), again every REMIND_MS. GTA hands a car to its driver, and a keeper
-- gets what it asks for, within a second or so, so this only ever fires on a stuck one.

local STUCK_MS = 3000
local REMIND_MS = 5000
local TELL_TIMES = 5              -- told this often and still not theirs: not a lock of whip_rope's
local FORGET_MS = 30 * 60 * 1000  -- a thing not kept for this long is no longer watched

local function nameOf(src) return ('%s (%d)'):format(GetPlayerName(src) or '?', src) end

function Keepers.watch()
    local now = GetGameTimer()
    for netId, w in pairs(Keepers.watched) do
        local e = NetworkGetEntityFromNetworkId(netId)
        local kind = e and e ~= 0 and DoesEntityExist(e) and GetEntityType(e) or 0
        if (kind ~= 2 and kind ~= 3) or (not Keepers.of[netId] and now - w.keptAt > FORGET_MS) then
            Keepers.watched[netId] = nil
        else
            -- Whoever should have it: the player at its wheel, else its keeper
            local ped = kind == 2 and GetPedInVehicleSeat(e, -1) or 0
            local driver = ped and ped ~= 0 and IsPedAPlayer(ped) and NetworkGetEntityOwner(ped) or nil
            if driver and driver <= 0 then driver = nil end
            local want = driver or Keepers.of[netId]
            local owner = NetworkGetEntityOwner(e)
            if want and owner and owner > 0 and owner ~= want then
                if w.want ~= want then w.want, w.stuckSince, w.toldAt, w.told = want, now, nil, nil end
                if now - w.stuckSince >= STUCK_MS and (w.told or 0) < TELL_TIMES
                    and (not w.toldAt or now - w.toldAt >= REMIND_MS) then
                    w.toldAt, w.told = now, (w.told or 0) + 1
                    TriggerClientEvent('whip_rope:letGo', owner, netId)
                    print(('[whip_rope] %s %s %d for %.0f s and still has no control: %s\'s game has it, told it to'
                        .. ' let go (%d)'):format(nameOf(want), driver and 'has sat at the wheel of car' or 'has kept',
                        netId, (now - w.stuckSince) / 1000, nameOf(owner), w.told))
                    if w.told == TELL_TIMES then
                        print(('[whip_rope] %d: %s\'s game never let go, so no rope\'s lock holds it (a FiveM'
                            .. ' ownership stall: getting out and in again, or another player getting in, may free'
                            .. ' it)'):format(netId, nameOf(owner)))
                    end
                end
            else
                if w.told and want and owner == want then
                    print(('[whip_rope] %d: %s has control now, %.0f s on'):format(netId, nameOf(want),
                        (now - w.stuckSince) / 1000))
                end
                w.want, w.stuckSince, w.toldAt, w.told = nil, nil, nil, nil
            end
        end
    end
end

-- Drivers get in and out, and takes start and end, without an end changing: looked at once a second while anything
-- is out (and the watched cars while any is left)
CreateThread(function()
    while true do
        Wait(1000)
        if next(Ropes.all) or next(Keepers.sent) or next(Keepers.lagSent) or next(Keepers.drivenSent) then
            Keepers.work()
        end
        if next(Keepers.watched) then Keepers.watch() end
    end
end)

AddEventHandler('playerDropped', function()
    Keepers.sent[source] = nil
    Keepers.lagSent[source] = nil
    Keepers.drivenSent[source] = nil
end)
