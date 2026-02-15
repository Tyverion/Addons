_addon.name = 'Debuffed'
_addon.author = 'Xathe (Asura); Modified by Cypan (Bahamut); Modified by Ender'
_addon.version = '2.13.2026'
_addon.commands = {'db'}

config = require('config')
packets = require('packets')
res = require('resources')
texts = require('texts')
bit = require('bit')

require('luau')
require('logger')

defaults = {
    interval = .1,
    mode = 'blacklist',
    timers = true,
    hide_below_zero = false,
    rename_duplicates = true,
    show_target_box = true,
    show_watch_box = true,
    whitelist = S{},
    blacklist = S{},
    colors = {
        player = { red = 255, green = 255, blue = 255 },
        others = { red = 255, green = 255, blue = 0 },
    },
    box = {
        bg = {
            visible = true,
            alpha = 45,
            red = 0, green = 0, blue = 0,
        },
        text = {
            size = 10,
            font = 'Consolas',
            stroke = { width = 2, alpha = 180, red = 0, green = 0, blue = 0 },
        },
        pos = { x = 650, y = 0 },
        flags = { draggable = true },
    },
    watch_box = {
        bg = {
            visible = true,
            alpha = 45,
            red = 0, green = 0, blue = 0,
        },
        text = {
            size = 10,
            font = 'Consolas',
            stroke = { width = 2, alpha = 180, red = 0, green = 0, blue = 0 },
        },
        pos = { x = 650, y = 120 },
        flags = { draggable = true },
    },
}

settings = config.load(defaults)

box = texts.new('${current_string}', settings.box, settings)
box_watch = texts.new('${current_string}', settings.watch_box, settings)
box:show()
box_watch:show()

local INDENT = '  '
local function rgb_triplet(c) return ('%d,%d,%d'):format(c[1], c[2], c[3]) end
local HEADER = rgb_triplet{255,184,77}   -- amber header
local TARGET_HDR = rgb_triplet{120,200,255}
local WATCH_HDR  = rgb_triplet{255,140,160}

list_commands = T{
    w = 'whitelist',
    wlist = 'whitelist',
    white = 'whitelist',
    whitelist = 'whitelist',
    b = 'blacklist',
    blist = 'blacklist',
    black = 'blacklist',
    blacklist = 'blacklist'
}

sort_commands = T{
    a = 'add',
    add = 'add',
    ['+'] = 'add',
    r = 'remove',
    remove = 'remove',
    ['-'] = 'remove'
}

player_id = 0
frame_time = 0
label_for_id = {}
id_for_label = {}
id_for_label_lower = {}
debuffed_mobs = {}
mob_hp = {}
party = T{}
trusted = true
next_letter = {}
watch = nil
pending_expiries = {}
expiry_flush = false
pending_queue = {}
sending_queue = false
local NAME_W  = 13   -- width of the name column
local TIMER_W = 3    -- width of the timer column

-- duplicate name renames (tellapart-style)
local renames = {}
local zonecache = {}
local active_renames = false
local Cities = S{ 70, 247, 256, 249, 244, 234, 245, 257, 246, 248, 230, 53, 236, 233, 223, 238, 235, 226, 239, 240, 232, 250, 231, 284, 242, 26, 252, 280, 285, 225, 224, 237, 50, 241, 243, 71 }

local function letter_suffix(num)
    local s = ''
    while num >= 1 do
        local m = (num - 1) % 26 + string.byte('A')
        s = string.char(m) .. s
        num = math.floor((num - 1) / 26)
    end
    return ' ' .. s
end

local function prepare_names()
    if not settings.rename_duplicates then
        active_renames = false
        return
    end

    if Cities[windower.ffxi.get_info().zone] then
        active_renames = false
        return
    end

    zonecache = {}
    local mobs = windower.ffxi.get_mob_list()
    local duplicates = {}

    for index, name in pairs(mobs) do
        if #name > 1 then
            local list = duplicates[name]
            if list then
                list[#list + 1] = index
            else
                duplicates[name] = { index }
            end
        end
    end

    for name, indexes in pairs(duplicates) do
        if name ~= 'n' and #indexes > 1 then
            table.sort(indexes)
            local counter = 1
            for _, index in ipairs(indexes) do
                zonecache[index] = name:sub(1, 20) .. letter_suffix(counter)
                counter = counter + 1
            end
        end
    end

    renames = {}
    for idx in pairs(zonecache) do
        local t = windower.ffxi.get_mob_by_index(idx)
        if t and (t.spawn_type == 0x010) then
            renames[t.id] = zonecache[idx]
            zonecache[idx] = nil
        end
    end

    active_renames = true

    -- sync debuffed labels to renamed display names
    for id, label in pairs(renames) do
        label_for_id[id] = label
        id_for_label[label] = id
        id_for_label_lower[label:lower()] = id
    end
end

function reset_labels()
    label_for_id = {}
    id_for_label = {}
    id_for_label_lower = {}
    next_letter = {}
    debuffed_mobs = {}
    mob_hp = {}
    watch = nil
    pending_expiries = {}
    expiry_flush = false
    pending_queue = {}
    sending_queue = false
    renames = {}
    zonecache = {}
    active_renames = false
end

local function slug(name)
    return (name or ''):gsub('^%s+',''):gsub('%s+$',''):gsub('%s+',' ')
end

local function assign_label(id, name)
    if not id or not name then return nil end
    if renames[id] then
        local label = renames[id]
        label_for_id[id] = label
        id_for_label[label] = id
        id_for_label_lower[label:lower()] = id
        return label
    end
    if label_for_id[id] then
        return label_for_id[id]
    end
    local key = slug(name)
    if key == '' then return nil end
    local letter = next_letter[key] or 'A'
    local label = string.format('%s %s', key, letter)
    label_for_id[id] = label
    id_for_label[label] = id
    id_for_label_lower[label:lower()] = id
    local code = letter:byte()
    if code >= 65 and code < 90 then
        next_letter[key] = string.char(code + 1)
    else
        next_letter[key] = 'A'
    end
    return label
end

local function id_from_label(label)
    if not label then return nil end
    return id_for_label[label] or id_for_label_lower[label:lower()]
end

local function escape_pat(s)
    return (s:gsub("(%W)","%%%1"))
end

local function relabel_name(key)
    if not key or key == '' then return end
    local pat = '^'..escape_pat(key)..' %u$'
    local ids = {}
    for id, lbl in pairs(label_for_id) do
        if lbl:match(pat) then
            ids[#ids+1] = id
            id_for_label[lbl] = nil
            id_for_label_lower[lbl:lower()] = nil
        end
    end
    table.sort(ids)
    local code = string.byte('A')
    for _, id in ipairs(ids) do
        local letter = string.char(code)
        local newlabel = string.format('%s %s', key, letter)
        label_for_id[id] = newlabel
        id_for_label[newlabel] = id
        id_for_label_lower[newlabel:lower()] = id
        code = code + 1
    end
    if #ids > 0 then
        next_letter[key] = string.char(code)
    else
        next_letter[key] = 'A'
    end
end

local function resolve_watch_label(input)
    if not input or input == '' then return nil, 'empty' end
    -- exact match first
    local id = id_from_label(input)
    if id then return id, input end

    local lower = input:lower()
    local tokens = lower:split(' ')
    local suffix
    if #tokens >= 2 and #tokens[#tokens] == 1 then
        suffix = tokens[#tokens]
        table.remove(tokens, #tokens)
    end
    local namepart = table.concat(tokens, ' ')
    if namepart == '' then return nil, 'no_name' end

    local matches = {}
    for lbl, tid in pairs(id_for_label_lower) do
        local l = lbl:lower()
        local name_ok = l:find(namepart, 1, true) ~= nil
        local suffix_ok = (not suffix) or l:sub(-1) == suffix
        if name_ok and suffix_ok then
            matches[#matches+1] = {id = tid, label = lbl}
        end
    end

    if #matches == 1 then
        return matches[1].id, matches[1].label
    end
    return nil, (#matches == 0) and 'not_found' or 'ambiguous'
end

local function send_next_queued()
    if #pending_queue == 0 then
        sending_queue = false
        return
    end
    sending_queue = true
    local msg = table.remove(pending_queue, 1)
    windower.send_command('input /p '..msg)
    coroutine.schedule(send_next_queued, 1.2)
end

local function enqueue_party_message(msg)
    if not msg or msg == '' then return end
    table.insert(pending_queue, msg)
    if not sending_queue then
        send_next_queued()
    end
end

local function refresh_party()
    local p = windower.ffxi.get_party()
    if not p then return end
    party = T{}
    for _, v in pairs(p) do
        if type(v) == 'table' and v.mob then
            party[v.mob.name] = v.mob.id
        end
    end
    local me = windower.ffxi.get_player()
    if me and me.id then
        player_id = me.id
        party[me.name] = me.id
    end
end

local function build_box(target, box_ref, header_color, label_prefix)
    local lines  = L{}
    if not target or not target.valid_target or (target.claim_id == 0 and target.spawn_type ~= 16) then
        box_ref.current_string = ''
        return
    end

    local data = debuffed_mobs[target.id]
    if not data then
        box_ref.current_string = ''
        return
    end

    local abilities, spells = {}, {}
    local label = label_for_id[target.id] or assign_label(target.id, target.name)

    for effect_id, e in pairs(data) do
        local remains = math.max(0, (e.timer or 0) - os.clock())
        if e.kind == 'ability' then
            local ja   = res.job_abilities[e.id]
            local name = (ja and ja.name) or ('JA:'..tostring(e.id))
            if (e.number or 0) > 5 then remains = math.max(0, remains + 30) end
            table.insert(abilities, { name=name, remains=remains, lvl=e.number or 0, actor=e.actor })
        else
            local sp   = res.spells[e.id]
            local name = (sp and sp.name) or ('Spell:'..tostring(e.id))
            table.insert(spells, { name=name, remains=remains, actor=e.actor })
        end
    end

    local function should_show(name)
        return (settings.mode == 'whitelist' and settings.whitelist:contains(name))
            or (settings.mode == 'blacklist' and not settings.blacklist:contains(name))
    end

    local function append_section(title, rows)
        if #rows == 0 then return end
        lines:append(('\\cs(%s)%s\\cr\n'):format(HEADER, title))
        for _, r in ipairs(rows) do
            if should_show(r.name) then
                local key   = ('%-'..NAME_W..'s'):format(r.name)             -- left-pad name to fixed width
                local timer = ('%' ..TIMER_W..'.0f'):format(r.remains or 0)  -- right-pad timer
                local lvl   = (r.lvl and r.lvl ~= 0) and ('Lv %2d'):format(r.lvl) or ''

                if settings.timers and r.remains > 0 then
                    lines:append(('%s\\cs(%s)%s\\cr:%s%s\n'):format(INDENT, get_color(r.actor), key, lvl, timer ))
                else
                    -- still keep the name in the same column even without timer
                    lines:append(('%s\\cs(%s)%s\\cr\n'):format(INDENT, get_color(r.actor), key))
                end
            end
        end
    end

    local hp = mob_hp[target.id]
    local display = label or target.name or 'Unknown'
    if hp ~= nil then
        display = ('%s (%d%%)'):format(display, hp)
    end
    lines:append(('\\cs(%s)%s\\cr %s\n'):format(header_color, label_prefix, display))
    append_section('Abilities', abilities)
    append_section('Spells',    spells)

    box_ref.current_string = (lines:length() == 0) and '' or lines:concat('')
end

function update_box()
    if settings.show_target_box then
        local target = windower.ffxi.get_mob_by_target('t')
        build_box(target, box, TARGET_HDR, 'TARGET')
        box:show()
    else
        box.current_string = ''
        box:hide()
    end

    if settings.show_watch_box then
        local watch_target
        if watch then
            watch_target = windower.ffxi.get_mob_by_id(watch)
            if not (watch_target and watch_target.valid_target) then
                watch = nil
                watch_target = nil
            end
        end
        if watch_target then
            build_box(watch_target, box_watch, WATCH_HDR, 'WATCH')
        else
            box_watch.current_string = ''
        end
        box_watch:show()
    else
        box_watch.current_string = ''
        box_watch:hide()
    end
end

function get_color(actor)
    if actor == player_id then
        return '%s,%s,%s':format(settings.colors.player.red, settings.colors.player.green, settings.colors.player.blue)
    else
        return '%s,%s,%s':format(settings.colors.others.red, settings.colors.others.green, settings.colors.others.blue)
    end
end

function handle_shot(target)
    if not debuffed_mobs[target] or not debuffed_mobs[target][134] then
        return true
    end

    local current = debuffed_mobs[target][134].id
    if current > 22 and current < 26 then
        debuffed_mobs[target][134].id = current + 1
    end
end

function handle_overwrites(target, new, t)
    if not debuffed_mobs[target] then return true end
    for effect, ability in pairs(debuffed_mobs[target]) do
        local ja  = res.job_abilities[ability.id] or {}
        local old = ja.overwrites or {}
        if #old > 0 then
            for _,v in ipairs(old) do
                if new == v then return false end
            end
        end
        if t and #t > 0 then
            for _,v in ipairs(t) do
                if ability.id == v then debuffed_mobs[target][effect] = nil end
            end
        end
    end
    return true
end

-- ability
function apply_ability_debuff(target, effect_id, ability_id, actor, number)
    debuffed_mobs[target] = debuffed_mobs[target] or {}
    local mob = windower.ffxi.get_mob_by_id(target)
    assign_label(target, mob and mob.name)
    local base = (res.job_abilities[ability_id] and res.job_abilities[ability_id].duration) or 0
    debuffed_mobs[target][effect_id] = {
        kind='ability', id=ability_id, timer=os.clock()+base, actor=actor, number=number or 0
    }
end
-- run ability
function apply_run_ability_debuff(target, effect_id, ability_id, actor, number)
    debuffed_mobs[target] = debuffed_mobs[target] or {}
    local mob = windower.ffxi.get_mob_by_id(target)
    assign_label(target, mob and mob.name)
    local base = (res.job_abilities[ability_id] and res.job_abilities[ability_id].duration) or 0
    debuffed_mobs[target][effect_id] = {
        kind='ability', id=ability_id, timer=os.clock()+base, actor=actor
    }
end
-- spell
function apply_spell_debuff(target, effect_id, spell_id, actor)
    debuffed_mobs[target] = debuffed_mobs[target] or {}
    local mob = windower.ffxi.get_mob_by_id(target)
    assign_label(target, mob and mob.name)
    local base = (res.spells[spell_id] and res.spells[spell_id].duration) or 0
    debuffed_mobs[target][effect_id] = {
        kind='spell', id=spell_id, timer=os.clock()+base, actor=actor
    }
end

-- nil-safe helpers
local function has_effect(tid, eff)
    local t = debuffed_mobs[tid]
    return t and t[eff] ~= nil
end

local function clear_effect(tid, eff)
    if debuffed_mobs[tid] then debuffed_mobs[tid][eff] = nil end
end

local DIA_EFF, BIO_EFF, HELIX_EFF = 134, 135, 186
local DIA_IDS   = S{23,24,25,33,34}
local BIO_IDS   = S{230,231,232}
local HELIX_IDS = S{278,279,280,281,282,283,284,285, 885,886,887,888,889,891,892}

function inc_action(act)
    local party_by_id = {}
    for _, id in pairs(party) do party_by_id[id] = true end
    if player_id ~= 0 then
        party_by_id[player_id] = true
    end
    if not party_by_id[act.actor_id] then return end

    local spell = act.param
    local actor = act.actor_id

    -- Spells
    if act.category == 4 then
        for _, tgt in ipairs(act.targets) do
            local target    = tgt.id
            local a1        = tgt.actions and tgt.actions[1]
            local msg       = a1 and a1.message
            local effect_id = a1 and a1.param
            if target and not party_by_id[target] and target ~= player_id then
                if effect_id and S{82,203,205,230,236,237,266,267,268,269,270,271,272,277,278,279,280,283,425,581,656,659}:contains(msg) then
                    local sp = res.spells[spell]
                    if sp and sp.status == effect_id then apply_spell_debuff(target, effect_id, spell, actor) end
                elseif DIA_IDS:contains(spell) then
                    clear_effect(target, BIO_EFF); apply_spell_debuff(target, DIA_EFF, spell, actor)
                elseif BIO_IDS:contains(spell) then
                    clear_effect(target, DIA_EFF); apply_spell_debuff(target, BIO_EFF, spell, actor)
                elseif HELIX_IDS:contains(spell) then
                    clear_effect(target, HELIX_EFF); apply_spell_debuff(target, HELIX_EFF, spell, actor)
                end
            end
        end
    end

    -- Light Shot
    if act.category == 6 and act.param == 131 then
        for _, tgt in ipairs(act.targets) do
            local t = tgt.id
            if t and not party_by_id[t] and t ~= player_id then handle_shot(t) end
        end
    end

    -- Steps / Rayke / Gambit
    if act.category == 14 or act.category == 15 then
        local ability   = act.param
        local ja        = res.job_abilities[ability]
        local effect_id = ja and ja.status
        for _, tgt in ipairs(act.targets) do
            local t = tgt.id
            local a1 = tgt.actions and tgt.actions[1]
            local msg = a1 and a1.message
            local number = a1 and a1.param or 0
            if t and effect_id and not party_by_id[t] and t ~= player_id then
                if S{519,520,521,591}:contains(msg) then
                    apply_ability_debuff(t, effect_id, ability, actor, number)
                elseif act.category == 15 and S{320,672}:contains(msg) then
                    apply_run_ability_debuff(t, effect_id, ability, actor)
                end
            end
        end
    end
end

function inc_action_message(arr)
    -- Mob died
    if S{6,20,71,72,113,406,605,646}:contains(arr.message_id) then
        debuffed_mobs[arr.target_id] = nil
        mob_hp[arr.target_id] = nil
        local lbl = label_for_id[arr.target_id]
        local key = nil
        if lbl then
            label_for_id[arr.target_id] = nil
            id_for_label[lbl] = nil
            id_for_label_lower[lbl:lower()] = nil
            local name = lbl:match('^(.+)%s+[A-Z]$')
            if name then key = name end
        end
        if not key then
            local mob = windower.ffxi.get_mob_by_id(arr.target_id)
            if mob and mob.name then key = slug(mob.name) end
        end
        if key then
            next_letter[key] = nil
            relabel_name(key)
        end
        return
    end

    -- Debuff expired
    if S{64,204,206,350,531}:contains(arr.message_id) then
        if debuffed_mobs[arr.target_id] then
            debuffed_mobs[arr.target_id][arr.param_1] = nil
            if trusted then
                local mob = windower.ffxi.get_mob_by_id(arr.target_id)
                local label = assign_label(arr.target_id, mob and mob.name)
                local b = res.buffs[arr.param_1]
                if label and b and b.en then
                    enqueue_party_message(('%s %s wore!'):format(label, b.en))
                end
            end
        end
    end
end

windower.register_event('login','load', function()
    print('load')
    refresh_party()
    prepare_names()
end)

windower.register_event('logout','zone change', function()
    reset_labels()
end)

local function buff_id_from_name(name)
    if not name then return nil end
    for id, buff in pairs(res.buffs) do
        if buff.en == name or buff.enl == name then
            return id
        end
    end
    return nil
end

windower.register_event('incoming chunk', function(id, data)
    if id == 0x028 then
        inc_action(windower.packets.parse_action(data))

    elseif id == 0x029 then
        local arr = {}
        arr.target_id = data:unpack('I',0x09)
        arr.param_1 = data:unpack('I',0x0D)
        arr.message_id = data:unpack('H',0x19)%32768

        inc_action_message(arr)

    elseif id == 0x00E then
        local p = packets.parse('incoming', data)
        local tid = p.NPC or p['NPC']
        local hp = p['HP %']
        local mask = p.Mask or p['Mask'] or 0
        local has_hp = bit.band(mask, 0x04) ~= 0
        if tid and hp ~= nil and debuffed_mobs[tid] and has_hp then
            mob_hp[tid] = hp
        end
        local idx = data:unpack('H', 0x009)
        if zonecache[idx] then
            local t = windower.ffxi.get_mob_by_index(idx)
            if t then
                if t.spawn_type == 0x010 then
                    renames[t.id] = zonecache[idx]
                end
                zonecache[idx] = nil
            end
        end
    elseif id == 0x17 then
        local p = packets.parse('incoming', data)
        if p.Mode == 4 then
            if party[p['Sender Name']] then
                local msg = p.Message:split(' ')
                -- expected: "<label words> <buffname> wore!"
                if msg[#msg] == 'wore!' then
                    local buffname = msg[#msg-1]
                    local buff_id  = buff_id_from_name(buffname)
                    local label    = table.concat(msg, ' ', 1, #msg-2)
                    local target_id= id_from_label(label)
                    if target_id and buff_id and debuffed_mobs[target_id] then
                        debuffed_mobs[target_id][buff_id] = nil
                    end
                end
            end
        end
    elseif id == 0x0DD then
        local p = packets.parse('incoming', data)
        local name = p.Name
        local slot = p._unknown2
        if name and slot then
            if L{1, 2, 3, 4, 5}:contains(slot) then
                -- Member is in party
                if not party[name] then
                    party[name] = p.ID
                end
            elseif not L{1, 2, 3, 4, 5}:contains(slot) then
                -- Not in party or just left
                if name == windower.ffxi.get_player().name then
                    return
                elseif party[name] then
                    party[name] = nil
                end
            end
        end
    end
end)

windower.register_event('outgoing chunk', function(id, data)
    if id == 0x05C then
        reset_labels()
        prepare_names()
    elseif id == 0x00C then
        prepare_names()
    end
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x00A then
        reset_labels()
    end
end)

windower.register_event('prerender', function()
    if (player_id == 0 or next(party) == nil) then
        refresh_party()
    end
    local curr = os.clock()
    if curr > frame_time + settings.interval then
        frame_time = curr
        update_box()
    end

    if active_renames then
        for i, v in pairs(renames) do
            windower.set_mob_name(i, v)
        end
    end
end)

windower.register_event('addon command', function(...)
    local args = L{...}

    if args[1] == 'm' or args[1] == 'mode' then
        if settings.mode == 'blacklist' then
            settings.mode = 'whitelist'
        else
            settings.mode = 'blacklist'
        end
        log('Changed to %s mode.':format(settings.mode))
        settings:save()

    elseif args[1] == 'w' or args[1] == 'watch' then
        local label = table.concat(args, ' ', 2)

        if label == '' or label == 'clear' then
            watch = nil
            log('Cleared watch target.')
        else
            local target_id, resolved_label = resolve_watch_label(label)
            if target_id then
                watch = target_id
                log(('Watching debuffs on: %s (id %d)'):format(resolved_label or label, target_id))
            elseif resolved_label == 'ambiguous' then
                log(('Ambiguous label: %s (add letter suffix)'):format(label))
            else
                log(('No known label: %s'):format(label))
            end
        end

    elseif args[1] == 't' or args[1] == 'timers' then
        settings.timers = not settings.timers
        log('Timer display %s.':format(settings.timers and 'enabled' or 'disabled'))
        settings:save()

    elseif args[1] == 'targetbox' then
        if args[2] == 'on' or args[2] == 'off' then
            settings.show_target_box = (args[2] == 'on')
        else
            settings.show_target_box = not settings.show_target_box
        end
        log('Target box %s.':format(settings.show_target_box and 'enabled' or 'disabled'))
        settings:save()

    elseif args[1] == 'watchbox' then
        if args[2] == 'on' or args[2] == 'off' then
            settings.show_watch_box = (args[2] == 'on')
        else
            settings.show_watch_box = not settings.show_watch_box
        end
        log('Watch box %s.':format(settings.show_watch_box and 'enabled' or 'disabled'))
        settings:save()

    elseif args[1] == 'rename' then
        settings.rename_duplicates = not settings.rename_duplicates
        prepare_names()
        log('Rename duplicates %s.':format(settings.rename_duplicates and 'enabled' or 'disabled'))
        settings:save()

    elseif args[1] == 'i' or args[1] == 'interval' then
        settings.interval = tonumber(args[2]) or .1
        log('Refresh interval set to %s seconds.':format(settings.interval))
        settings:save()

    elseif args[1] == 'h' or args[1] == 'hide' then
        settings.hide_below_zero = not settings.hide_below_zero
        log('Timers that reach 0 will be %s.':format(settings.hide_below_zero and 'hidden' or 'shown'))
        settings:save()

    elseif list_commands:containskey(args[1]) then
        if sort_commands:containskey(args[2]) then
            local ability = res.job_abilities:with('name', windower.wc_match-{name})
            args[1] = list_commands[args[1]]
            args[2] = sort_commands[args[2]]

            if ability == nil then
                error('No abilitys found that match: %s':format(name))
            elseif args[2] == 'add' then
                settings[args[1]]:add(ability.name)
                log('Added ability to %s: %s':format(args[1], ability.name))
            else
                settings[args[1]]:remove(ability.name)
                log('Removed ability from %s: %s':format(args[1], ability.name))
            end
            settings:save()
        end

    elseif args[1] == 'trusted' then
        if not trusted then
            trusted = true
            log('Trusted party.')
        elseif trusted then
            trusted = false
            log('Creepy party.')
        end
    else
        log('%s (v%s)':format(_addon.name, _addon.version))
        log(' mode - Switches between blacklist and whitelist mode (default: blacklist)')
        log(' timers - Toggles display of debuff timers (default: true)')
        log(' interval <value> - Allows you to change the refresh interval (default: 0.1)')
        log(' watch <label|clear> - Watch a labeled mob (e.g. "Vampire Leech B") or clear watch')
        log(' targetbox [on|off] - Toggle the current target display box')
        log(' watchbox [on|off] - Toggle the watched mob display box')
        log(' rename - Toggle duplicate mob renaming (A/B/C suffix)')
        log(' blacklist|whitelist add|remove <name> - Adds or removes the ability <name> to the specified list')
    end
end)
