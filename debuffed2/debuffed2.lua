_addon.name = 'Debuffed2'
_addon.author = 'Ender'
_addon.version = '4.3.2026'
_addon.commands = {'db2', 'debuffed2'}

config = require('config')
packets = require('packets')
res = require('resources')
texts = require('texts')
images = require('images')
bit = require('bit')

require('luau')
require('logger')

defaults = {
    interval = .1,
    mode = 'blacklist',
    ui_mode = 'graphical',
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
            alpha = 25,
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
            alpha = 25,
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
    graphic_box = {
        bg = {
            visible = true,
            alpha = 100,
            red = 14, green = 18, blue = 24,
        },
        text = {
            size = 11,
            font = 'Consolas',
            stroke = { width = 2, alpha = 220, red = 0, green = 0, blue = 0 },
        },
        pos = { x = 650, y = 0 },
        padding = 8,
        flags = { draggable = true },
    },
    graphic_watch_box = {
        bg = {
            visible = true,
            alpha = 100,
            red = 14, green = 18, blue = 24,
        },
        text = {
            size = 11,
            font = 'Consolas',
            stroke = { width = 2, alpha = 220, red = 0, green = 0, blue = 0 },
        },
        pos = { x = 650, y = 140 },
        padding = 8,
        flags = { draggable = true },
    },
}

settings = config.load(defaults)

box = texts.new('${current_string}', settings.box, settings)
box_watch = texts.new('${current_string}', settings.watch_box, settings)
graphic_box = texts.new('${current_string}', settings.graphic_box, settings)
graphic_watch_box = texts.new('${current_string}', settings.graphic_watch_box, settings)
box:show()
box_watch:show()
graphic_box:hide()
graphic_watch_box:hide()

local GRAPH_UNCLAIMED_COLOR = {255, 215, 80}
local GRAPH_CLAIMED_COLOR = {255, 110, 150}
local GRAPH_OTHER_CLAIM_COLOR = {170, 110, 255}

local debuff_short_labels = {
    ['Quickstep']           = 'Quick',
    ['Box Step']            = 'Box',
    ['Stutter Step']        = 'Stutt',
    ['Feather Step']        = 'Feath',
    ['Frazzle']             = 'Fraz',
    ['Frazzle II']          = 'Fraz2',
    ['Frazzle III']         = 'Fraz3',
    ['Distract']            = 'Dist',
    ['Distract II']         = 'Dist2',
    ['Distract III']        = 'Dist3',
    ['Dia']                 = 'Dia',
    ['Dia II']              = 'Dia2',
    ['Dia III']             = 'Dia3',
    ['Bio']                 = 'Bio',
    ['Bio II']              = 'Bio2',
    ['Bio III']             = 'Bio3',
    ['Carnage Elegy']       = 'Elegy',
    ['Fire Threnody']       = 'F.Thren',
    ['Fire Threnody II']    = 'F.Thren2',
    ['Ice Threnody']        = 'I.Thren',
    ['Ice Threnody II']     = 'I.Thren2',
    ['Wind Threnody']       = 'W.Thren',
    ['Wind Threnody II']    = 'W.Thren2',
    ['Earth Threnody']      = 'E.Thren',
    ['Earth Threnody II']   = 'E.Thren2',
    ['Ltng. Threnody']      = 'Lt.Thren',
    ['Ltng. Threnody II']   = 'Lt.Thren2',
    ['Water Threnody']      = 'W.Thren',
    ['Water Threnody II']   = 'W.Thren2',
    ['Light Threnody']      = 'L.Thren',
    ['Light Threnody II']   = 'L.Thren2',
    ['Dark Threnody']       = 'D.Thren',
    ['Dark Threnody II']    = 'D.Thren2',
    ['Pining Nocturne']     = 'Nocturn',
    ['Foe Lullaby']         = 'Lullaby',
    ['Foe Lullaby II']      = 'Lullaby',
    ['Horde Lullaby']       = 'Lullaby',
    ['Horde Lullaby II']    = 'Lullaby',
    ['Foe Requiem']         = 'Requiem',
    ['Foe Requiem II']      = 'Requiem',
    ['Foe Requiem III']     = 'Requiem',
    ['Foe Requiem IV']      = 'Requiem',
    ['Foe Requiem V']       = 'Requiem',
    ['Foe Requiem VI']      = 'Requiem',
    ['Foe Requiem VII']     = 'Requiem',
    ['Absorb-STR']          = 'STR-D',
    ['Absorb-DEX']          = 'DEX-D',
    ['Absorb-VIT']          = 'VIT-D',
    ['Absorb-AGI']          = 'AGI-D',
    ['Absorb-INT']          = 'INT-D',
    ['Absorb-MND']          = 'MND-D',
    ['Absorb-CHR']          = 'CHR-D',
    ['Stun']                = 'Stun',
    ['Flash']               = 'Flash',
}

ability_icon_overrides = {}
spell_overrides = {
    [112] = {status = 156}, -- Flash
    [252] =  {status = 10}, -- Stun
    [266] = {status = 136}, -- Absorb-STR STR Down
    [267] = {status = 137}, -- Absorb-DEX DEX Down
    [268] = {status = 138}, -- Absorb-VIT VIT Down
    [269] = {status = 139}, -- Absorb-AGI AGI Down
    [270] = {status = 140}, -- Absorb-INT INT Down
    [271] = {status = 141}, -- Absorb-MND MND Down
    [272] = {status = 142}, -- Absorb-CHR CHR Down
}

local function get_spell_resource(spell_id)
    local sp = res.spells[spell_id]
    local override = spell_overrides[spell_id]
    if not sp and not override then
        return nil
    end

    if not override then
        return sp
    end

    local merged = {}
    if sp then
        for k, v in pairs(sp) do
            merged[k] = v
        end
    end
    for k, v in pairs(override) do
        merged[k] = v
    end
    return merged
end

local function build_debuff_label(name)
    if not name or name == '' then
        return ''
    end

    if debuff_short_labels[name] then
        return debuff_short_labels[name]
    end

    local cleaned = name:gsub("%b()", "")
    local roman = cleaned:match('%s+(I+V?)$') or cleaned:match('%s+(V?I*)$')
    if roman then
        cleaned = cleaned:gsub('%s+' .. roman .. '$', '')
    end

    local words = {}
    for word in cleaned:gmatch('%S+') do
        words[#words + 1] = word
    end

    local label
    if #words >= 2 then
        label = (words[1]:sub(1, 2) .. words[2]:sub(1, 1)):gsub("[^%a%d]", "")
    else
        label = cleaned:gsub("[^%a%d]", ""):sub(1, 3)
    end

    if label == '' then
        label = cleaned:sub(1, 3)
    end

    if roman and roman ~= '' then
        local digit_map = {I='1', II='2', III='3', IV='4', V='5'}
        label = label .. (digit_map[roman] or roman)
    end

    if #label > 4 then
        label = label:sub(1, 4)
    end

    return label
end

local function is_party_claim(claim_id, player_id)
    if not claim_id or claim_id == 0 then
        return false
    end
    if claim_id == player_id then
        return true
    end

    local party_info = windower.ffxi.get_party()
    if not party_info then
        return false
    end

    for _, member in pairs(party_info) do
        if type(member) == 'table' and member.mob and member.mob.id == claim_id then
            return true
        end
    end

    return false
end

local function slug(name)
    return (name or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
end

local function get_claim_bar_color(target)
    if not target or target.spawn_type ~= 16 then
        return GRAPH_CLAIMED_COLOR
    end

    if target.claim_id == 0 then
        return GRAPH_UNCLAIMED_COLOR
    end

    local player = windower.ffxi.get_player()
    if player and is_party_claim(target.claim_id, player.id) then
        return GRAPH_CLAIMED_COLOR
    end

    return GRAPH_OTHER_CLAIM_COLOR
end

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
mob_action = {}
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

renames = {}
zonecache = {}
active_renames = false
local function load_module(filename)
    return assert(loadfile(windower.addon_path .. filename))()
end

local label_helpers = load_module('labels.lua')
local prepare_names = label_helpers.prepare_names
local reset_labels = label_helpers.reset_labels
local assign_label = label_helpers.assign_label
local id_from_label = label_helpers.id_from_label
local relabel_name = label_helpers.relabel_name
local resolve_watch_label = label_helpers.resolve_watch_label
local parse_wore_message = label_helpers.parse_wore_message

local common_helpers = load_module('render_common.lua').new({
    assign_label = assign_label,
    ability_icon_overrides = ability_icon_overrides,
})
local module_collect_rows = common_helpers.collect_rows

local list_renderer = load_module('render_list.lua').new(common_helpers)
local TARGET_HDR = list_renderer.TARGET_HDR
local WATCH_HDR = list_renderer.WATCH_HDR
local build_list_box_mod = list_renderer.build_list_box

local graphical_renderer_mod = load_module('render_graphical.lua').new({
    collect_rows = module_collect_rows,
    build_debuff_label = build_debuff_label,
    get_claim_bar_color = get_claim_bar_color,
})

local target_graphic = graphical_renderer_mod.make_renderer(settings.graphic_box.pos, settings.graphic_box.flags.draggable)
local watch_graphic = graphical_renderer_mod.make_renderer(settings.graphic_watch_box.pos, settings.graphic_watch_box.flags.draggable)

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

function update_box()
    local use_graphical = settings.ui_mode == 'graphical'
    if settings.show_target_box then
        local target = windower.ffxi.get_mob_by_target('t')
        if use_graphical then
            graphical_renderer_mod.draw(target_graphic, settings.graphic_box.pos, target, 'TARGET')
            graphic_box.current_string = ''
            graphic_box:hide()
            box.current_string = ''
            box:hide()
        else
            build_list_box_mod(target, box, TARGET_HDR, 'TARGET')
            if box.current_string == '' then
                box:hide()
            else
                box:show()
            end
            graphical_renderer_mod.hide(target_graphic)
            graphic_box.current_string = ''
            graphic_box:hide()
        end
    else
        box.current_string = ''
        box:hide()
        graphical_renderer_mod.hide(target_graphic)
        graphic_box.current_string = ''
        graphic_box:hide()
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
            if use_graphical then
                graphical_renderer_mod.draw(watch_graphic, settings.graphic_watch_box.pos, watch_target, 'WATCH')
                graphic_watch_box.current_string = ''
                graphic_watch_box:hide()
                box_watch.current_string = ''
                box_watch:hide()
            else
                build_list_box_mod(watch_target, box_watch, WATCH_HDR, 'WATCH')
                if box_watch.current_string == '' then
                    box_watch:hide()
                else
                    box_watch:show()
                end
                graphical_renderer_mod.hide(watch_graphic)
                graphic_watch_box.current_string = ''
                graphic_watch_box:hide()
            end
        else
            box_watch.current_string = ''
            box_watch:hide()
            graphical_renderer_mod.hide(watch_graphic)
            graphic_watch_box.current_string = ''
            graphic_watch_box:hide()
        end
    else
        box_watch.current_string = ''
        box_watch:hide()
        graphical_renderer_mod.hide(watch_graphic)
        graphic_watch_box.current_string = ''
        graphic_watch_box:hide()
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
    local sp = get_spell_resource(spell_id)
    local base = (sp and sp.duration) or 0
    debuffed_mobs[target][effect_id] = {
        kind='spell', id=spell_id, timer=os.clock()+base, actor=actor
    }
end

local function has_effect(tid, eff)
    local t = debuffed_mobs[tid]
    return t and t[eff] ~= nil
end

local function clear_effect(tid, eff)
    if debuffed_mobs[tid] then debuffed_mobs[tid][eff] = nil end
end

local DIA_EFF, BIO_EFF, HELIX_EFF, KAST_EFF = 134, 135, 186, 23
local ACTION_DISPLAY_SECONDS = 10
local SPELL_NO_EFFECT_MESSAGES = S{75, 283, 659}
local SPELL_DEBUFF_APPLY_MESSAGES = S{82,203,205,230,236,237,266,267,268,269,270,271,272,277,278,279,280,283,329,330,331,332,333,334,335,425,581,656,659}
local SPELL_PARAMLESS_APPLY_MESSAGES = S{329,330,331,332,333,334,335}
local ACTION_WEAKNESSES = {
    Aita = {
        ['Eroding Flesh']   = 'Wind',
        ['Flaming Kick']    = 'Water',
        ['Flashflood']      = 'Thunder',
        ['Fulminous Smash'] = 'Earth',
        ['Icy Grasp']       = 'Fire',
    },
    Degei = {
        ['Eroding Flesh']   = 'Wind',
        ['Flaming Kick']    = 'Water',
        ['Flashflood']      = 'Thunder',
        ['Fulminous Smash'] = 'Earth',
        ['Icy Grasp']       = 'Fire',
    },
}
local DIA_IDS   = S{23,24,25,33,34}
local BIO_IDS   = S{230,231,232}
local HELIX1_IDS = S{278,279,280,281,282,283,284,285}
local HELIX2_IDS = S{885,886,887,888,889,891,892}
local HELIX_IDS = HELIX1_IDS + HELIX2_IDS

function inc_action(act)
    local party_by_id = {}
    for _, id in pairs(party) do party_by_id[id] = true end
    if player_id ~= 0 then
        party_by_id[player_id] = true
    end

    local spell = act.param
    local actor = act.actor_id
    local actor_mob = windower.ffxi.get_mob_by_id(actor)
    if actor_mob and actor_mob.spawn_type == 16 then
        local action_name
        if act.category == 8 then
            local sp = res.spells[spell]
            action_name = sp and (sp.name or sp.en)
        elseif S{3,7,11}:contains(act.category) and spell and spell > 255 then
            local ma = res.monster_abilities[spell]
            action_name = ma and (ma.name or ma.en)
        end
        if action_name then
            local weakness = ACTION_WEAKNESSES[actor_mob.name] and ACTION_WEAKNESSES[actor_mob.name][action_name]
            if weakness then
                action_name = ('%s (%s)'):format(action_name, weakness)
            end
            mob_action[actor] = {
                name = action_name,
                expires = os.clock() + ACTION_DISPLAY_SECONDS,
            }
            assign_label(actor, actor_mob.name)
        end
    end

    if not party_by_id[act.actor_id] then return end

    -- Spells
    if act.category == 4 then
        for _, tgt in ipairs(act.targets) do
            local target    = tgt.id
            local a1        = tgt.actions and tgt.actions[1]
            local msg       = a1 and a1.message
            local effect_id = a1 and a1.param
            if target and not party_by_id[target] and target ~= player_id then
                local sp = get_spell_resource(spell)
                if SPELL_DEBUFF_APPLY_MESSAGES:contains(msg) then
                    if sp and sp.status and (sp.status == effect_id or SPELL_PARAMLESS_APPLY_MESSAGES:contains(msg)) then
                        apply_spell_debuff(target, sp.status, spell, actor)
                    end
                elseif sp and sp.status and SPELL_NO_EFFECT_MESSAGES:contains(msg) then
                    apply_spell_debuff(target, sp.status, spell, actor)
                elseif DIA_IDS:contains(spell) then
                    clear_effect(target, BIO_EFF); apply_spell_debuff(target, DIA_EFF, spell, actor)
                elseif BIO_IDS:contains(spell) then
                    clear_effect(target, DIA_EFF); apply_spell_debuff(target, BIO_EFF, spell, actor)
                elseif HELIX_IDS:contains(spell) then
                    local existing = debuffed_mobs[target] and debuffed_mobs[target][HELIX_EFF]
                    local old_id = existing and existing.id
                    -- Helix I cannot overwrite Helix II
                    if old_id and HELIX2_IDS:contains(old_id) and HELIX1_IDS:contains(spell) then
                        -- keep existing Helix II
                    else
                        clear_effect(target, HELIX_EFF)
                        apply_spell_debuff(target, HELIX_EFF, spell, actor)
                    end
                elseif spell == 502 then
                    clear_effect(target, KAST_EFF); apply_spell_debuff(target, KAST_EFF, spell, actor)
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
        mob_action[arr.target_id] = nil
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
                local target_id, buffname = parse_wore_message(p.Message)
                local buff_id = buff_id_from_name(buffname)
                if target_id and buff_id and debuffed_mobs[target_id] then
                    debuffed_mobs[target_id][buff_id] = nil
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

    if args[1] == 'ui' or args[1] == 'display' then
        local choice = (args[2] or ''):lower()
        if choice == 'graphical' or choice == 'graphic' or choice == 'targetbar' then
            settings.ui_mode = 'graphical'
        elseif choice == 'list' or choice == 'text' then
            settings.ui_mode = 'list'
        else
            settings.ui_mode = (settings.ui_mode == 'graphical') and 'list' or 'graphical'
        end
        log('UI mode set to %s.':format(settings.ui_mode))
        settings:save()

    elseif args[1] == 'mode' then
        if settings.mode == 'blacklist' then
            settings.mode = 'whitelist'
        else
            settings.mode = 'blacklist'
        end
        log('Changed to %s mode.':format(settings.mode))
        settings:save()

    elseif args[1] == 'watch' then
        
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

    elseif args[1] == 'watchonly' then
        settings.show_target_box = not settings.show_target_box

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

    elseif args[1] == 'timers' then
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

    elseif args[1] == 'interval' then
        settings.interval = tonumber(args[2]) or .1
        log('Refresh interval set to %s seconds.':format(settings.interval))
        settings:save()

    elseif args[1] == 'hide' then
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
        log(' ui [list|graphical] - Switches between compact list and panel view')
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

local function destroy_graphic_renderer(renderer)
    if not renderer then
        return
    end
    graphical_renderer_mod.destroy(renderer)
end

windower.register_event('unload', function()
    graphical_renderer_mod.hide(target_graphic)
    graphical_renderer_mod.hide(watch_graphic)
    destroy_graphic_renderer(target_graphic)
    destroy_graphic_renderer(watch_graphic)
    graphic_box:destroy()
    graphic_watch_box:destroy()
    box:destroy()
    box_watch:destroy()
end)
