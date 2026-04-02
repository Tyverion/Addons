_addon.name = 'Digger'
_addon.author = 'Ender'
_addon.command = 'Digger'

local config = require('config')
local packets = require('packets')
local res = require('resources')
local texts = require('texts')

local DIG_START_PACKET_ID = 0x1A
local DIG_FINISH_PACKET_ID = 0x63
local DIG_ANIMATION_PACKET_ID = 0x2F
local DIG_ACTION_ID = 17
local EGG_HELM_ID = 16109

local ARRIVAL_TOLERANCE = 0.5
local RECORD_MIN_DISTANCE = 5
local JST_OFFSET = 9 * 60 * 60

local defaults = {
    fatigue = 0,
    fatigue_day = '',
    box_x = 900,
    box_y = 360,
}

local settings = config.load(defaults)
local fatigue = settings.fatigue or 0
local last_dig_result = 'None'
local hovered_button = nil
local drag_state = nil

local digger_box = texts.new('', {
    pos = {x = settings.box_x, y = settings.box_y},
    bg = {alpha = 45, red = 0, green = 0, blue = 0, visible = true},
    flags = {bold = true, right = false, bottom = false, draggable = false},
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

local state = {
    active = false,
    recording = false,
    route = {},
    route_index = 1,
    target = nil,
    waiting_for_result = false,
    saw_finish_packet = false,
    saw_animation_packet = false,
    last_recorded = nil,
}

local BUTTON_RECORD = 'record'
local BUTTON_RUN = 'run'

local function get_jst_day(now)
    return os.date('!%Y-%m-%d', (now or os.time()) + JST_OFFSET)
end

local function get_next_jst_midnight(now)
    now = now or os.time()
    local jst_now = now + JST_OFFSET
    return jst_now - (jst_now % 86400) + 86400 - JST_OFFSET
end

local function save_fatigue(value, day)
    fatigue = value
    settings.fatigue = value
    settings.fatigue_day = day or get_jst_day()
    config.save(settings)
end

local function sync_fatigue_reset()
    local current_day = get_jst_day()
    if settings.fatigue_day ~= current_day then
        save_fatigue(0, current_day)
    else
        fatigue = settings.fatigue or 0
    end
end

function get_chocobo_buff()
    for _,buff_id in pairs(windower.ffxi.get_player().buffs) do
        if buff_id == 252 then
            return true
        end
    end
    return false
end

function get_gysahl_count()
    local count = 0
    for _,item in pairs(windower.ffxi.get_items(0)) do
        if type(item) == 'table' and item.id == 4545 and item.status == 0 then
            count = count + item.count
        end
    end
    return count
end

function get_gysahl_greens()
    return get_gysahl_count()
end

local function is_wearing_egg_helm()
    local items = windower.ffxi.get_items()
    if not items or not items.equipment or not items.equipment.head then
        return false
    end

    local bag_id = items.equipment.head_bag
    local slot_id = items.equipment.head
    if not bag_id or not slot_id or slot_id == 0 then
        return false
    end

    local head_item = windower.ffxi.get_items(bag_id, slot_id)
    return (head_item and head_item.id == EGG_HELM_ID) or false
end

local function update_ui()
    if not get_chocobo_buff() then return end
    local now = os.time()
    local reset_epoch = get_next_jst_midnight(now)
    local seconds_until_reset = reset_epoch - now
    if seconds_until_reset <= 0 then
        seconds_until_reset = 86400
    end

    local reset_jst = os.date('!%Y-%m-%d %H:%M JST', reset_epoch + JST_OFFSET)
    local hours = math.floor(seconds_until_reset / 3600)
    local minutes = math.floor((seconds_until_reset % 3600) / 60)
    local seconds = seconds_until_reset % 60
    local record_label = state.recording and 'Record Stop' or 'Record Start'
    local run_label = state.active and 'Digger Stop' or 'Digger Start'
    local record_prefix = hovered_button == BUTTON_RECORD and '> ' or '[ '
    local record_suffix = hovered_button == BUTTON_RECORD and ' ]<' or ' ]'
    local run_prefix = hovered_button == BUTTON_RUN and '> ' or '[ '
    local run_suffix = hovered_button == BUTTON_RUN and ' ]<' or ' ]'

    digger_box:text((
        'Digger\nGreens: %d\nFatigue: %d/100\nLast Dig: %s\nReset In: %02d:%02d:%02d\n%s%s%s\n%s%s%s'
    ):format(
        get_gysahl_greens(),
        fatigue,
        last_dig_result,
        hours,
        minutes,
        seconds,
        record_prefix,
        record_label,
        record_suffix,
        run_prefix,
        run_label,
        run_suffix
    ))
    digger_box:show()
end

local function get_player_mob()
    return windower.ffxi.get_mob_by_target('me')
end

local function reset_dig_wait()
    state.waiting_for_result = false
    state.saw_finish_packet = false
    state.saw_animation_packet = false
end

local function distance_2d(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function current_point(player)
    return {x = player.x, y = player.y}
end

local function inject_dig_start()
    local self = windower.ffxi.get_player()
    if not self then return end

    windower.ffxi.run(false)
    state.waiting_for_result = true
    state.saw_finish_packet = false
    state.saw_animation_packet = false

    packets.inject(packets.new('outgoing', DIG_START_PACKET_ID, {
        ['Target'] = self.id,
        ['Target Index'] = self.index,
        ['Category'] = DIG_ACTION_ID,
        ['_unknown1'] = 0,
    }))
end

local function set_target_from_route()
    if #state.route == 0 then
        state.target = nil
        return
    end

    if state.route_index > #state.route then
        state.route_index = 1
    end

    local point = state.route[state.route_index]
    state.target = {x = point.x, y = point.y}
end

local function advance_route()
    if #state.route == 0 then return end
    state.route_index = state.route_index + 1
    if state.route_index > #state.route then
        state.route_index = 1
    end
    set_target_from_route()
end

local function add_route_point(player, force)
    local point = current_point(player)
    if force or not state.last_recorded then
        state.route[#state.route + 1] = point
        state.last_recorded = point
        windower.add_to_chat(207, ('[Digger] Point %d recorded: %.1f, %.1f'):format(#state.route, point.x, point.y))
        return
    end

    if distance_2d(point, state.last_recorded) >= RECORD_MIN_DISTANCE then
        state.route[#state.route + 1] = point
        state.last_recorded = point
        windower.add_to_chat(207, ('[Digger] Point %d recorded: %.1f, %.1f'):format(#state.route, point.x, point.y))
    end
end

local function stop_running()
    state.active = false
    state.target = nil
    reset_dig_wait()
    windower.ffxi.run(false)
end

local function start_recording(player)
    if not player then return end
    state.recording = true
    state.active = false
    state.target = nil
    reset_dig_wait()
    add_route_point(player, true)
    windower.add_to_chat(207, '[Digger] Recording started.')
end

local function stop_recording()
    state.recording = false
    windower.add_to_chat(207, ('[Digger] Recording stopped. %d points saved.'):format(#state.route))
end

local function start_running()
    if #state.route == 0 then
        windower.add_to_chat(207, '[Digger] No route recorded.')
        return
    end

    state.recording = false
    state.active = true
    state.route_index = 1
    set_target_from_route()
    windower.add_to_chat(207, ('[Digger] Running route with %d points.'):format(#state.route))
end

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
    if blocked or id ~= DIG_FINISH_PACKET_ID then
        return
    end

    if not state.active or not state.waiting_for_result then
        return
    end

    state.saw_finish_packet = true
    if state.saw_animation_packet and state.target then
        state.waiting_for_result = false
    end
end)

local does_not_count = S{1188, 4409, 4487, 4532, 4570}

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if not get_chocobo_buff() then return end
    if id == 0x2A then
        local p = packets.parse('incoming',data)
        local item = res.items[p['Param 1']]
        last_dig_result = item and item.en or ('Item ID ' .. tostring(p['Param 1']))
        local should_ignore = is_wearing_egg_helm() and does_not_count:contains(p['Param 1'])
        if not should_ignore and p['Message ID'] == 39181 then
            sync_fatigue_reset()
            save_fatigue(fatigue + 1)
        end
    end
    if blocked or id ~= DIG_ANIMATION_PACKET_ID then
        return
    end

    if state.active and state.waiting_for_result then
        state.saw_animation_packet = true
        if state.saw_finish_packet and state.target then
            state.waiting_for_result = false
        end
    end
end)

windower.register_event('prerender', function()
    local player = get_player_mob()
    if not player then
        digger_box:hide()
        return
    end

    sync_fatigue_reset()
    update_ui()

    if state.recording then
        add_route_point(player, false)
    end

    if not state.active or not state.target or state.waiting_for_result then
        return
    end

    local dx = state.target.x - player.x
    local dy = state.target.y - player.y
    local distance = math.sqrt(dx * dx + dy * dy)

    if distance <= ARRIVAL_TOLERANCE then
        windower.ffxi.run(false)
        inject_dig_start()
        advance_route()
        return
    end

    local heading = -math.atan2(dy, dx)
    windower.ffxi.run(heading)
    windower.ffxi.turn(heading)

    if not get_chocobo_buff() then
        digger_box:hide()
    end
end)

windower.register_event('mouse', function(type, x, y, delta, blocked)
    if drag_state then
        if type == 0 then
            digger_box:pos(x - drag_state.offset_x, y - drag_state.offset_y)
            return true
        end

        if type == 2 then
            settings.box_x = digger_box:pos_x()
            settings.box_y = digger_box:pos_y()
            config.save(settings)
            drag_state = nil
            return true
        end
    end

    if blocked then
        return
    end

    if not digger_box:visible() or not digger_box:hover(x, y) then
        if hovered_button ~= nil then
            hovered_button = nil
            update_ui()
        end
        return
    end

    local _, height = digger_box:extents()
    local lines = select(2, digger_box:text():gsub('\n', '\n')) + 1
    local offset_y = height / lines
    local pos_y = y - digger_box:pos_y()
    local line_index = math.floor(pos_y / offset_y) + 1
    local button = nil

    if line_index == 6 then
        button = BUTTON_RECORD
    elseif line_index == 7 then
        button = BUTTON_RUN
    end

    if type == 0 and hovered_button ~= button then
        hovered_button = button
        update_ui()
        return
    end

    local is_click = type == 1

    if is_click and line_index == 1 then
        drag_state = {
            offset_x = x - digger_box:pos_x(),
            offset_y = y - digger_box:pos_y(),
        }
        return true
    end

    if is_click and button == BUTTON_RECORD then
        local player = get_player_mob()
        if state.recording then
            stop_recording()
        else
            start_recording(player)
        end
        update_ui()
        return
    end

    if is_click and button == BUTTON_RUN then
        if state.active then
            stop_running()
            windower.add_to_chat(207, '[Digger] Stopped.')
        else
            start_running()
        end
        update_ui()
    end
end)

local function print_help()
    windower.add_to_chat(207, '[Digger] Commands:')
    windower.add_to_chat(207, '  //digger record start')
    windower.add_to_chat(207, '  //digger record stop')
    windower.add_to_chat(207, '  //digger record clear')
    windower.add_to_chat(207, '  //digger fatigue reset')
    windower.add_to_chat(207, '  //digger route add')
    windower.add_to_chat(207, '  //digger route list')
    windower.add_to_chat(207, '  //digger run')
    windower.add_to_chat(207, '  //digger stop')
end

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or ''
    local sub = args[2] and args[2]:lower() or ''
    local player = get_player_mob()

    if cmd == '' or cmd == 'help' then
        print_help()
        return
    end

    if cmd == 'record' then
        if sub == 'start' then
            start_recording(player)
        elseif sub == 'stop' then
            stop_recording()
        elseif sub == 'clear' then
            state.recording = false
            stop_running()
            state.route = {}
            state.route_index = 1
            state.last_recorded = nil
            windower.add_to_chat(207, '[Digger] Route cleared.')
        else
            windower.add_to_chat(207, '[Digger] Usage: //digger record start|stop|clear')
        end
        return
    end

    if cmd == 'route' then
        if sub == 'add' then
            if not player then return end
            add_route_point(player, true)
        elseif sub == 'list' then
            windower.add_to_chat(207, ('[Digger] Route points: %d'):format(#state.route))
            for i, point in ipairs(state.route) do
                windower.add_to_chat(207, ('  %d: %.1f, %.1f'):format(i, point.x, point.y))
            end
        else
            windower.add_to_chat(207, '[Digger] Usage: //digger route add|list')
        end
        return
    end

    if cmd == 'fatigue' then
        if sub == 'reset' then
            save_fatigue(0)
            windower.add_to_chat(207, '[Digger] Fatigue reset.')
        else
            windower.add_to_chat(207, '[Digger] Usage: //digger fatigue reset')
        end
        return
    end

    if cmd == 'run' then
        start_running()
        return
    end

    if cmd == 'stop' then
        stop_running()
        windower.add_to_chat(207, '[Digger] Stopped.')
        return
    end

    print_help()
end)

sync_fatigue_reset()

windower.register_event('unload', function()
    if digger_box then
        digger_box:destroy()
    end
end)
