_addon.name    = 'tracker'
_addon.author  = 'Ender'
_addon.command = 'track'

local packets = require('packets')
local texts = require('texts')
local tracker_box = texts.new('', {
    pos = {x = 900, y = 320},
    bg = {alpha = 45, red = 0, green = 0, blue = 0, visible = true},
    flags = {bold = true, right = false, bottom = false, draggable = true},
    padding = 6,
    text = {
        font = 'Consolas',
        size = 10,
        alpha = 255,
        red = 255,
        green = 255,
        blue = 255,
        stroke = {width = 2, alpha = 255, red = 0, green = 0, blue = 0},
    },
})

local track = {
    name = nil,
    index = nil,
    pos = nil,
    last_dir = nil,
    last_emit = 0,
}

local pending_choices = nil
local zone_index_map = {}
local zone_name_map = {}
local zone_cache_pending = false
tracker_box:hide()

local function slug(s)
    return (s or ''):gsub('%z.*', ''):lower()
end

local function rebuild_zone_cache()
    zone_cache_pending = false
    zone_index_map = {}
    zone_name_map = {}

    local mob_list = windower.ffxi.get_mob_list() or {}
    for index, name in pairs(mob_list) do
        if type(name) == 'string' and name ~= '' then
            zone_index_map[index] = name
            local s = slug(name)
            if s ~= '' then
                zone_name_map[s] = zone_name_map[s] or {}
                zone_name_map[s][#zone_name_map[s] + 1] = {
                    name = name,
                    index = index,
                }
            end
        end
    end

end

local function schedule_zone_cache(delay)
    if zone_cache_pending then
        return
    end
    zone_cache_pending = true
    coroutine.schedule(rebuild_zone_cache, delay or 2)
end

local function angle_diff(a, b)
    local d = a - b
    while d < -math.pi do d = d + 2 * math.pi end
    while d > math.pi do d = d - 2 * math.pi end
    return d
end

local function dir_label(diff)
    local ad = math.abs(diff)
    local straight_tol = math.rad(30)
    local back_tol = math.rad(30)

    if ad <= straight_tol then
        return 'straight'
    end
    if math.pi - ad <= back_tol then
        return 'back'
    end
    return diff > 0 and 'right' or 'left'
end

local function clear_tracking()
    track = {name=nil, index=nil, pos=nil, last_dir=nil, last_emit=0}
    pending_choices = nil
    tracker_box:hide()
    packets.inject(packets.new('outgoing', 0x0F6, {}))
end

local function choose_target(choice)
    if not choice then
        windower.add_to_chat(167, '[tracker] invalid selection.')
        return
    end

    track.name = choice.name
    track.index = choice.index
    track.pos = nil
    track.last_dir = nil
    track.last_emit = 0
    pending_choices = nil

    packets.inject(packets.new('outgoing', 0x0F5, {
        ['Index'] = choice.index,
        ['_junk1'] = 0,
    }))

    tracker_box:text(('Tracking\n%s\nWaiting for position...'):format(choice.name))
    tracker_box:show()
    windower.add_to_chat(207, ('[tracker] tracking "%s" (idx %d)'):format(choice.name, choice.index))
end

local function find_candidates(name)
    local s = slug(name)
    local exact = {}
    local partial = {}

    local function build_entry(entry, distance)
        return {
            name = entry.name,
            index = entry.index,
            distance = distance,
        }
    end

    for key, entries in pairs(zone_name_map) do
        if key == s then
            for _, entry in ipairs(entries) do
                exact[#exact + 1] = build_entry(entry)
            end
        elseif key:find(s, 1, true) then
            for _, entry in ipairs(entries) do
                partial[#partial + 1] = build_entry(entry)
            end
        end
    end

    local function sort_candidates(t)
        table.sort(t, function(a, b)
            if a.distance and b.distance and a.distance ~= b.distance then
                return a.distance < b.distance
            end
            if a.name ~= b.name then
                return slug(a.name) < slug(b.name)
            end
            return a.index < b.index
        end)
    end

    sort_candidates(exact)
    sort_candidates(partial)

    if #exact > 0 then
        return exact
    end
    return partial
end

local function start_tracking(name)
    local candidates = find_candidates(name)
    if #candidates == 0 then
        windower.add_to_chat(167, ('[tracker] no match for "%s"'):format(name))
        return
    end

    if #candidates == 1 then
        choose_target(candidates[1])
        return
    end

    pending_choices = candidates
    windower.add_to_chat(207, ('[tracker] multiple matches for "%s":'):format(name))
    for i, entry in ipairs(candidates) do
        local dist = entry.distance and ('%.1f'):format(entry.distance) or '?'
        windower.add_to_chat(207, ('  %d. %s (idx %d, %s yalms)'):format(i, entry.name, entry.index, dist))
        if i >= 8 then
            break
        end
    end
    windower.add_to_chat(207, '[tracker] use //track <number>')
end

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or ''):lower()
    local args = {...}

    if pending_choices and cmd:match('^%d+$') and #args == 0 then
        choose_target(pending_choices[tonumber(cmd)])
        return
    end

    if cmd == 'stop' then
        clear_tracking()
        windower.add_to_chat(207, '[tracker] stopped.')
        return
    end

    if cmd == 'choose' then
        local n = tonumber(args[1] or '')
        if not pending_choices or not n then
            windower.add_to_chat(167, '[tracker] no pending choices.')
            return
        end
        choose_target(pending_choices[n])
        return
    end

    local parts = {}
    if cmd ~= '' then parts[#parts + 1] = cmd end
    for _, v in ipairs(args) do
        if v and v ~= '' then
            parts[#parts + 1] = v
        end
    end

    local target = table.concat(parts, ' ')
    if target == '' then
        windower.add_to_chat(207, '[tracker] usage: //track <npc name>')
        windower.add_to_chat(207, '[tracker]        //track choose <number>')
        windower.add_to_chat(207, '[tracker]        //track stop')
        return
    end

    start_tracking(target)
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x0F5 then
        local p = packets.parse('incoming', data)
        if p and track.index and p.Index == track.index then
            track.pos = {x = p.X, y = p.Y, z = p.Z}
        end
    elseif id == 0x00A then
        clear_tracking()
        schedule_zone_cache(6)
    end
end)

windower.register_event('prerender', function()
    if not track.index then return end

    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return end

    if not track.pos then
        return
    end

    local dx = track.pos.x - me.x
    local dy = track.pos.y - me.y
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist <= 6 then
        windower.add_to_chat(207, ('[tracker] %s reached; stopping.'):format(track.name))
        clear_tracking()
        return
    end

    local bearing = -math.atan2(dy, dx)
    local diff = angle_diff(bearing, me.heading)
    local label = dir_label(diff)

    tracker_box:text(('Tracking\n%s\n%.1f yalms\nRun: %s'):format(track.name, dist, label))
    tracker_box:show()
    track.last_dir = label
    track.last_emit = os.clock()
end)

windower.register_event('unload', function()
    if tracker_box then
        tracker_box:destroy()
    end
end)

schedule_zone_cache(2)
