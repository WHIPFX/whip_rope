-- Ropes in the Director: cards for whip_core's scenario builder, through its card API (Whip.card):
--
--   Make a Rope                     a rope between placed cars, props or spots, in the player's hand, or lying loose;
--                                   whether players may pick it up and hang off it
--   Move a Rope End                 one of its ends tied, handed over or dropped somewhere else
--   Change Rope Rules               whether players may pick it up and hang off it, from now on
--   Remove a Rope
--   Goal: Tie a Rope                on once a rope is tied to a placed car or prop (or spot), or between two
--   Goal: Hang on a Rope            on once a run player hangs off a rope, for as long as it asks
--   When a Rope Is Pulled Too Far   on once the run's rope is pulled past a stretch; it can snap
--
-- A run's ropes are kept by name (the cards' Rope field: 'rope' unless a scenario has more than one) and go when the run
-- ends (run:ended; for a builder's Test, a look every few seconds). The goals wait on the ropes' own changes
-- (Ropes.onChange), not a timer, except for a time limit, a car that goes, and how long someone has hung.

local RES = GetCurrentResourceName()

local TEST_LOOK_MS = 3000   -- how often a builder's Test with ropes out is looked for (it sends no run:ended)
local WATCH_MS = 500        -- a goal's own look: its time limit, its car, how long they have hung
local TIE_NEAR = 2.0        -- m: an end tied this near a spot or a prop standing still is tied to it
local GOAL_TIMEOUT = 3600   -- a goal's Give up after (its own time limit is the one players see)

local runs = {}    -- [runId] = { test, ropes = { [name] = ropeId } }
local goals = {}   -- [callId] = a goal waiting (below)

-- ============================================
-- A run's ropes
-- ============================================

--- A rope's name as the cards write it: trimmed, any case; 'rope' when empty.
local function nameOf(v)
    local s = type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
    return s ~= '' and s:lower() or 'rope'
end

local function runOf(card)
    local r = runs[card.runId]
    if not r then
        r = { test = card.test == true, ropes = {} }
        runs[card.runId] = r
    end
    return r
end

--- The run's rope of that name, while it is still out (nil when it never was, or has gone).
local function ropeOf(runId, name)
    local r = runs[runId]
    local id = r and r.ropes[name]
    if id and Ropes.all[id] then return Ropes.all[id] end
    if r then r.ropes[name] = nil end
    return nil
end

--- A run ended: its goals forgotten, its ropes taken away.
local function endRun(runId)
    local r = runs[runId]
    if not r then return end
    runs[runId] = nil
    for callId, g in pairs(goals) do
        if g.runId == runId then goals[callId] = nil end
    end
    for _, id in pairs(r.ropes) do Ropes.removeOwn(id, RES) end
end

AddEventHandler('whip_core:run:ended', function(e)
    if GetInvokingResource() ~= 'whip_core' or type(e) ~= 'table' or type(e.run) ~= 'table' then return end
    endRun(e.run.id)
end)

-- A builder's Test sends no events: looked for while it has ropes out
CreateThread(function()
    while true do
        Wait(TEST_LOOK_MS)
        for runId, r in pairs(runs) do
            if r.test and not Whip.core:GetScenarioRun(runId, { tests = true }) then endRun(runId) end
        end
    end
end)

-- ============================================
-- Where an end goes
-- ============================================

local EDGES = { front = 'front', back = 'back' }

--- The car a run made for a placed car, out in the world now, or nil.
local function carOf(made)
    if type(made) ~= 'table' then return nil end
    local ent
    if made.vehicleId then
        local v = Whip.core:GetVehicle(made.vehicleId)
        ent = type(v) == 'table' and v.entity or nil
    end
    local netId = tonumber(made.netId)
    if (not ent or ent == 0) and netId then ent = NetworkGetEntityFromNetworkId(netId) end
    if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
    return nil
end

--- An end, from a card's choice: `where` 'thing' (the placed `thing`: a car, at its `edge`; a prop; a spot), 'hand' (the
--- player the run acts for) or 'loose'. Answers the end and a note for the console, or nil and why.
local function endFor(card, where, thing, edge)
    if where == 'loose' then return { type = 'free' } end
    if where == 'hand' then
        local src = tonumber(card.player)
        if not src then return nil, 'nobody in the run to hand it to' end
        if Ropes.heldBy(src) or Ropes.hanging[src] then
            -- One pair of hands: at their feet instead
            local at = Ropes.pedPos(src)
            if not at then return nil, 'they are not in the world' end
            return { type = 'fixed', pos = Ropes.wire(at) }, 'their hands are full: put down at their feet'
        end
        return { type = 'held', heldBy = src }
    end
    if type(thing) ~= 'table' then return nil, 'no placed thing is picked' end
    local label = thing.label or 'it'
    if thing.kind == 'npc' then return nil, 'a rope ties to a car, a prop or a spot, not an NPC' end
    local made = card:made(thing.id)
    if thing.kind == 'vehicle' then
        local ent = carOf(made)
        if not ent then return nil, label .. ' is not out in the world' end
        return { type = 'vehicle', netId = NetworkGetNetworkIdFromEntity(ent), edge = EDGES[edge] }
    end
    -- A prop that moves (its physics object, networked): tied to it; one standing still (each game shows its own) and a
    -- spot: at its place
    local propNetId = thing.kind == 'prop' and type(made) == 'table' and tonumber(made.netId)
    if propNetId then
        local ent = NetworkGetEntityFromNetworkId(propNetId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return { type = 'object', netId = propNetId } end
    end
    local c = thing.coords
    if type(c) ~= 'table' or not c.x then return nil, label .. ' has no place' end
    return { type = 'fixed', pos = { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0 }, tied = true }
end

-- ============================================
-- The fields the cards share
-- ============================================

local WHERE = {
    { value = 'thing', label = 'Tied to a placed thing' },
    { value = 'hand', label = "In the player's hand" },
    { value = 'loose', label = 'Lying loose' },
}
local EDGE_OPTIONS = {
    { value = 'back', label = 'Its back' },
    { value = 'front', label = 'Its front' },
    { value = 'middle', label = 'Its middle' },
}

local function ropeField(label)
    return { key = 'name', kind = 'text', label = label or 'Rope', default = 'rope', maxLength = 24,
             hint = 'The name Make a Rope gave it' }
end

--- A placed thing of the scenario's, by its id (a card's Check).
local function worldIn(doc, id)
    for _, w in ipairs(type(doc) == 'table' and type(doc.world) == 'table' and doc.world or {}) do
        if w.id == id then return w end
    end
    return nil
end

--- What is wrong with an end set to a placed thing (a card's Check), or nil.
local function endProblem(doc, where, id, which)
    if (where or 'thing') ~= 'thing' then return nil end
    if type(id) ~= 'string' or id == '' then return which .. ': pick a placed car, prop or spot' end
    local w = worldIn(doc, id)
    if w and w.kind == 'npc' then return which .. ': a rope ties to a car, a prop or a spot, not an NPC' end
    return nil
end

-- ============================================
-- Make, move, change, remove
-- ============================================

Whip.card('rope.make', {
    categoryTitle = 'Ropes', color = 'amber', icon = 'pickup',
    title = 'Make a Rope',
    desc = 'A rope between two places: placed cars, props or spots, the player\'s hand, or lying loose.',
    outputs = { 'made', 'failed' },
    labels = { made = 'Made', failed = 'Could not' },
    bad = { 'failed' },
    test = 'run',
    props = {
        { key = 'name', kind = 'text', label = 'Name', default = 'rope', maxLength = 24,
          hint = 'Other rope cards find it by this name' },
        { key = 'fromIs', kind = 'select', label = 'Where', options = WHERE, default = 'thing', group = 'First end' },
        { key = 'from', kind = 'world', label = 'Placed thing' },
        { key = 'fromEdge', kind = 'select', label = 'On a car', options = EDGE_OPTIONS, default = 'back' },
        { key = 'toIs', kind = 'select', label = 'Where', options = WHERE, default = 'loose', group = 'Second end' },
        { key = 'to', kind = 'world', label = 'Placed thing' },
        { key = 'toEdge', kind = 'select', label = 'On a car', options = EDGE_OPTIONS, default = 'front' },
        { key = 'length', kind = 'number', label = 'Length', unit = 'm', min = 1, max = 30, default = 6, group = 'The rope' },
        { key = 'take', kind = 'bool', label = 'Players can pick it up and untie it', default = true },
        { key = 'hang', kind = 'bool', label = 'Players can hang off it', default = true },
    },
    check = function(props, doc)
        local why = endProblem(doc, props.fromIs, props.from, 'First end') or endProblem(doc, props.toIs, props.to, 'Second end')
        if why then return why end
        if (props.fromIs or 'thing') == 'loose' and (props.toIs or 'loose') == 'loose' then
            return 'Both ends loose: tie one to something, or put it in the player\'s hand'
        end
        if props.fromIs == 'hand' and props.toIs == 'hand' then
            return 'One player holds one end: the second will lie loose', 'warning'
        end
        return nil
    end,
    run = function(card)
        local p = card.props
        local a, noteA = endFor(card, p.fromIs or 'thing', p.from, p.fromEdge)
        if not a then card:log('the first end: %s', noteA) return 'failed' end
        if noteA then card:log('the first end: %s', noteA) end
        local b, noteB = endFor(card, p.toIs or 'loose', p.to, p.toEdge)
        if not b then card:log('the second end: %s', noteB) return 'failed' end
        if noteB then card:log('the second end: %s', noteB) end
        if a.type == 'held' and b.type == 'held' then b = { type = 'free' } end   -- one pair of hands

        local name, r = nameOf(p.name), runOf(card)
        -- Made again under the same name: the old one goes first
        if r.ropes[name] then Ropes.removeOwn(r.ropes[name], RES) end
        local id, why = Ropes.create({
            origin = a, tail = b, length = tonumber(p.length), player = tonumber(card.player), kind = 'director',
            take = p.take ~= false, hang = p.hang ~= false,
        }, RES)
        if not id then card:log('%s', tostring(why)) return 'failed' end
        r.ropes[name] = id
        return 'made'
    end,
})

Whip.card('rope.moveEnd', {
    categoryTitle = 'Ropes', color = 'amber', icon = 'pickup',
    title = 'Move a Rope End',
    desc = 'Ties one end of a rope this run made somewhere else, hands it to the player, or drops it.',
    outputs = { 'moved', 'noRope', 'failed' },
    labels = { moved = 'Moved', noRope = 'No such rope', failed = 'Could not' },
    bad = { 'noRope', 'failed' },
    test = 'run',
    props = {
        ropeField(),
        { key = 'which', kind = 'select', label = 'End', default = 'first',
          options = { { value = 'first', label = 'The first end' }, { value = 'second', label = 'The second end' } } },
        { key = 'toIs', kind = 'select', label = 'To', options = WHERE, default = 'thing' },
        { key = 'to', kind = 'world', label = 'Placed thing' },
        { key = 'edge', kind = 'select', label = 'On a car', options = EDGE_OPTIONS, default = 'back' },
    },
    check = function(props, doc) return endProblem(doc, props.toIs, props.to, 'To') end,
    run = function(card)
        local p = card.props
        local rope = ropeOf(card.runId, nameOf(p.name))
        if not rope then return 'noRope' end
        local e, note = endFor(card, p.toIs or 'thing', p.to, p.edge)
        if not e then card:log('%s', note) return 'failed' end
        if note then card:log('%s', note) end
        local ok, why = Ropes.setEnd(rope.id, p.which == 'second' and 'tail' or 'origin', e, RES)
        if not ok then card:log('%s', tostring(why)) return 'failed' end
        return 'moved'
    end,
})

Whip.card('rope.rules', {
    categoryTitle = 'Ropes', color = 'amber', icon = 'pickup',
    title = 'Change Rope Rules',
    desc = 'Whether players may pick up and hang off a rope this run made, from now on.',
    outputs = { 'changed', 'noRope' },
    labels = { changed = 'Changed', noRope = 'No such rope' },
    bad = { 'noRope' },
    test = 'run',
    props = {
        ropeField(),
        { key = 'take', kind = 'bool', label = 'Players can pick it up and untie it', default = true },
        { key = 'hang', kind = 'bool', label = 'Players can hang off it', default = true },
    },
    run = function(card)
        local rope = ropeOf(card.runId, nameOf(card.props.name))
        if not rope then return 'noRope' end
        Ropes.setRules(rope.id, { take = card.props.take ~= false, hang = card.props.hang ~= false }, RES)
        return 'changed'
    end,
})

Whip.card('rope.remove', {
    categoryTitle = 'Ropes', color = 'amber', icon = 'pickup',
    title = 'Remove a Rope',
    desc = 'Takes away a rope this run made. Anyone hanging off it drops.',
    outputs = { 'removed', 'noRope' },
    labels = { removed = 'Removed', noRope = 'No such rope' },
    test = 'run',
    props = { ropeField() },
    run = function(card)
        local name = nameOf(card.props.name)
        local rope = ropeOf(card.runId, name)
        if not rope then return 'noRope' end
        runs[card.runId].ropes[name] = nil
        Ropes.removeOwn(rope.id, RES)
        return 'removed'
    end,
})

-- ============================================
-- Goals and waits: what they share
-- ============================================

--- A goal answered: what it showed taken down first (a card that has answered is refused its methods).
local function finish(goal, pin, src)
    if goals[goal.id] ~= goal then return end
    goals[goal.id] = nil
    if goal.shown then goal.card:clearObjective() end
    if goal.timed then goal.card:clock(0) end
    if goal.stop then goal.stop() end
    if pin ~= 'outOfTime' and src then goal.card:record(pin, { source = src }) end
    Whip.answerCard(goal.id, pin, src and { source = src } or nil)
end

--- Is `src` one of the goal's run's players? Its players as the card started, and the run asked again for one who
--- joined since.
local function inRun(goal, src)
    if not src then return false end
    if goal.who[src] then return true end
    local run = Whip.core:GetScenarioRun(goal.runId, { tests = true })
    for _, p in ipairs(type(run) == 'table' and run.players or {}) do
        goal.who[tonumber(p.source)] = true
    end
    return goal.who[src] == true
end

--- The ropes a goal looks at: the run's of its name, or every rope a player can handle (a player's own too).
local function ropesFor(goal)
    if goal.name then
        local rope = ropeOf(goal.runId, goal.name)
        return rope and { rope } or {}
    end
    local out = {}
    for _, rope in pairs(Ropes.all) do
        if not Ropes.locked(rope) then out[#out + 1] = rope end
    end
    return out
end

--- A goal's card, run and players, before it looks at anything (inRun needs them).
local function setUp(goal, card)
    goal.id, goal.card, goal.runId = card.callId, card, card.runId
    goal.who = {}
    for _, s in ipairs(card.players or {}) do goal.who[tonumber(s)] = true end
    return goal
end

--- The goal (setUp already), waiting: its objective and clock, and its own look (a time limit, `goal.tick`) until it is
--- answered. Only from a card's run that then returns nothing: an answer in the run itself is its return.
local function wait(goal, text, seconds)
    local card = goal.card
    goals[goal.id] = goal
    if text and text ~= '' then
        card:objective(text)
        goal.shown = true
    end
    seconds = tonumber(seconds)
    if seconds and seconds > 0 then
        card:clock(seconds, text)
        goal.timed, goal.endsAt = true, GetGameTimer() + math.floor(seconds * 1000)
    end
    CreateThread(function()
        while goals[goal.id] == goal do
            Wait(WATCH_MS)
            if goals[goal.id] ~= goal then return end
            if goal.endsAt and GetGameTimer() >= goal.endsAt then return finish(goal, 'outOfTime') end
            if goal.tick then goal.tick() end
        end
    end)
end

--- Ended without our answer (Give up after, its run ended): forgotten.
local function onEnd(callId)
    local goal = goals[callId]
    if not goal then return end
    goals[callId] = nil
    if goal.stop then goal.stop() end
end

-- Every rope change, to the goals waiting on one
Ropes.onChange(function(what, rope, source)
    local list = {}
    for _, goal in pairs(goals) do list[#list + 1] = goal end
    for _, goal in ipairs(list) do
        if goals[goal.id] == goal and goal.on then goal.on(what, rope, source) end
    end
end)

local function onlyRunsFields()
    return {
        { key = 'runOnly', kind = 'bool', label = 'Only a rope this run made', default = false },
        { key = 'name', kind = 'text', label = 'Rope', default = 'rope', maxLength = 24, showIf = 'runOnly',
          hint = 'The name Make a Rope gave it' },
    }
end

local function limitField()
    return { key = 'seconds', kind = 'duration', label = 'Time limit', unit = 's', min = 0, max = 3600, default = 0,
             hint = '0: none (Give up after still ends it)' }
end

-- ============================================
-- Goal: Tie a Rope
-- ============================================

--- A goal's target: what an end must be tied to. nil and why for none, or an NPC.
local function targetOf(card, thing)
    if type(thing) ~= 'table' then return nil, 'no placed thing is picked' end
    if thing.kind == 'npc' then return nil, 'a rope ties to a car, a prop or a spot, not an NPC' end
    local t = { kind = thing.kind, label = thing.label or 'it', coords = thing.coords }
    local made = card:made(thing.id)
    if thing.kind == 'vehicle' then
        t.made = made
        if not carOf(made) then return nil, t.label .. ' is not out in the world' end
    elseif thing.kind == 'prop' and type(made) == 'table' and tonumber(made.netId) then
        t.netId = tonumber(made.netId)
    end
    return t
end

--- Is end `e` tied to target `t` now?
local function tiedTo(e, t)
    if t.kind == 'vehicle' then
        local ent = carOf(t.made)
        return ent ~= nil and e.type == 'vehicle' and tonumber(e.netId) == NetworkGetNetworkIdFromEntity(ent)
    end
    if t.netId then return e.type == 'object' and tonumber(e.netId) == t.netId end
    -- A spot, or a prop standing still: an end tied there (to the map, or to the prop's own copy on a game)
    local c = t.coords
    if type(c) ~= 'table' or not c.x then return false end
    local p
    if e.type == 'fixed' and e.tied then p = e.pos
    elseif e.type == 'object' and (tonumber(e.netId) or 0) == 0 then p = e.point or e.worldPos end
    return p ~= nil and #(vector3(p.x, p.y, p.z) - vector3(c.x, c.y, c.z)) <= TIE_NEAR
end

--- The run player behind a tie: the one who tied it (`by`), else whoever holds the rope's other end, else the one the run
--- acts for.
local function tierOf(goal, rope, by)
    if inRun(goal, tonumber(by)) then return tonumber(by) end
    for _, which in ipairs({ 'origin', 'tail' }) do
        local e = rope[which]
        if e.type == 'held' and inRun(goal, tonumber(e.heldBy)) then return tonumber(e.heldBy) end
    end
    return tonumber(goal.card.player)
end

Whip.card('rope.goalTie', {
    category = 'goals',
    title = 'Goal: Tie a Rope',
    desc = 'On once a rope is tied to a placed car, prop or spot, or between two.',
    outputs = { 'tied', 'outOfTime', 'lost' },
    labels = { tied = 'Tied', outOfTime = 'Out of time', lost = 'Car lost' },
    bad = { 'outOfTime', 'lost' },
    timeout = GOAL_TIMEOUT,
    test = 'run',
    props = (function()
        local props = {
            { key = 'text', kind = 'text', label = 'Objective', maxLength = 120,
              hint = 'Empty: "Tie a rope to the ..."' },
            { key = 'target', kind = 'world', label = 'Tie it to', required = true },
            { key = 'target2', kind = 'world', label = 'And to (the other end)' },
        }
        for _, f in ipairs(onlyRunsFields()) do props[#props + 1] = f end
        props[#props + 1] = limitField()
        return props
    end)(),
    check = function(props, doc)
        for _, key in ipairs({ 'target', 'target2' }) do
            local w = type(props[key]) == 'string' and worldIn(doc, props[key]) or nil
            if w and w.kind == 'npc' then return 'A rope ties to a car, a prop or a spot, not an NPC' end
        end
        if props.target2 and props.target2 ~= '' and props.target2 == props.target then
            return 'Both ends to the same thing: pick another for the other end', 'warning'
        end
        return nil
    end,
    run = function(card)
        local p = card.props
        -- A car not out in the world is Car lost; anything else wrong with a target (none picked, an NPC: Check says
        -- so first) is the card's Didn't Work, with why
        local a, why = targetOf(card, p.target)
        if not a then
            if type(p.target) == 'table' and p.target.kind == 'vehicle' then card:log('%s', why) return 'lost' end
            error(why, 0)
        end
        local b
        if type(p.target2) == 'table' then
            b, why = targetOf(card, p.target2)
            if not b then
                if p.target2.kind == 'vehicle' then card:log('%s', why) return 'lost' end
                error(why, 0)
            end
        end
        local goal = setUp({ a = a, b = b, name = p.runOnly == true and nameOf(p.name) or nil }, card)

        local function tied()
            for _, rope in ipairs(ropesFor(goal)) do
                local o, t = rope.origin, rope.tail
                local done
                if goal.b then
                    done = (tiedTo(o, goal.a) and tiedTo(t, goal.b)) or (tiedTo(o, goal.b) and tiedTo(t, goal.a))
                else
                    done = tiedTo(o, goal.a) or tiedTo(t, goal.a)
                end
                if done then return rope end
            end
            return nil
        end
        -- Tied already: nothing to do
        local already = tied()
        if already then return 'tied', { source = tierOf(goal, already) } end

        goal.on = function(what, _, by)
            if what ~= 'ends' then return end
            local rope = tied()
            if rope then finish(goal, 'tied', tierOf(goal, rope, by)) end
        end
        -- A car to tie to that has gone (put away, deleted): lost
        goal.tick = function()
            for _, t in ipairs({ goal.a, goal.b }) do
                if t.kind == 'vehicle' and not carOf(t.made) then return finish(goal, 'lost') end
            end
        end
        local text = p.text
        if not text or text == '' then
            text = b and ('Tie a rope between the %s and the %s'):format(a.label, b.label) or ('Tie a rope to the %s'):format(a.label)
        end
        wait(goal, text, p.seconds)
        return nil   -- answered when it is tied (goal.on), or by its look
    end,
    onEnd = onEnd,
})

-- ============================================
-- Goal: Hang on a Rope
-- ============================================

Whip.card('rope.goalHang', {
    category = 'goals',
    title = 'Goal: Hang on a Rope',
    desc = 'On once a run player hangs off a rope, for as long as it asks.',
    outputs = { 'hung', 'outOfTime' },
    labels = { hung = 'Hung on', outOfTime = 'Out of time' },
    bad = { 'outOfTime' },
    timeout = GOAL_TIMEOUT,
    test = 'run',
    props = (function()
        local props = {
            { key = 'text', kind = 'text', label = 'Objective', maxLength = 120, hint = 'Empty: "Hang on the rope"' },
            { key = 'hold', kind = 'duration', label = 'Hang on for', unit = 's', min = 0, max = 600, default = 0,
              hint = '0: as soon as they take hold' },
        }
        for _, f in ipairs(onlyRunsFields()) do props[#props + 1] = f end
        props[#props + 1] = limitField()
        return props
    end)(),
    run = function(card)
        local p = card.props
        local hold = math.max(0, tonumber(p.hold) or 0) * 1000
        local goal = setUp({ name = p.runOnly == true and nameOf(p.name) or nil, since = {} }, card)

        local function counts(rope)
            for _, r in ipairs(ropesFor(goal)) do if r == rope then return true end end
            return false
        end
        local function hanging(src, rope) return rope ~= nil and counts(rope) and inRun(goal, src) end
        -- Someone of the run hanging already: on at once, or counted from now
        for src, h in pairs(Ropes.hanging) do
            if hanging(src, Ropes.all[h.serverRopeId]) then
                if hold == 0 then return 'hung', { source = src } end
                goal.since[src] = GetGameTimer()
            end
        end

        goal.on = function(what, rope, src)
            if what == 'hang' and hanging(src, rope) then
                goal.since[src] = goal.since[src] or GetGameTimer()
                if hold == 0 then finish(goal, 'hung', src) end
            elseif what == 'unhang' then
                goal.since[src] = nil
            end
        end
        goal.tick = function()
            local now = GetGameTimer()
            for src, t in pairs(goal.since) do
                if not Ropes.hanging[src] then
                    goal.since[src] = nil
                elseif now - t >= hold then
                    return finish(goal, 'hung', src)
                end
            end
        end

        local text = p.text
        if not text or text == '' then
            text = hold > 0 and ('Hang on the rope for %d seconds'):format(math.floor(hold / 1000)) or 'Hang on the rope'
        end
        wait(goal, text, p.seconds)
        return nil
    end,
    onEnd = onEnd,
})

-- ============================================
-- When a Rope Is Pulled Too Far
-- ============================================

Whip.card('rope.whenPulled', {
    categoryTitle = 'Ropes', color = 'amber', icon = 'pickup',
    title = 'When a Rope Is Pulled Too Far',
    desc = 'On once a rope this run made is pulled past a stretch, and it can snap.',
    outputs = { 'pulled', 'noRope' },
    labels = { pulled = 'Pulled too far', noRope = 'No such rope' },
    bad = { 'noRope' },
    timeout = GOAL_TIMEOUT,
    test = 'run',
    props = {
        ropeField(),
        { key = 'stretch', kind = 'number', label = 'Past its length by', unit = '%', min = 5, max = 200, default = 35 },
        { key = 'snap', kind = 'bool', label = 'It snaps (the rope goes)', default = true },
    },
    run = function(card)
        local p = card.props
        local rope = ropeOf(card.runId, nameOf(p.name))
        if not rope then return 'noRope' end
        local id = rope.id
        Ropes.setRules(id, { stretch = (tonumber(p.stretch) or 35) / 100 }, RES)
        local goal = setUp({}, card)
        goal.stop = function() Ropes.setRules(id, { stretch = false }, RES) end
        goal.on = function(what, r, src)
            if r.id ~= id then return end
            if what == 'removed' then
                goal.stop = nil   -- (nothing left to stop)
                return finish(goal, 'noRope')
            end
            if what == 'stretched' then
                finish(goal, 'pulled', inRun(goal, src) and src or nil)
                if p.snap ~= false then Ropes.removeOwn(id, RES) end
            end
        end
        wait(goal, nil, nil)
        return nil
    end,
    onEnd = onEnd,
})
