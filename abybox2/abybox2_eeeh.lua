-- autobox
_addon.name     = 'autobox'
_addon.command  = 'ab'

require('luau')
require('tables')
require('pack')            -- for string:unpack
local packets = require('packets')
local res     = require('resources')
local bit     = require('bit')

------------------------------------------------------------
-- Config (no logic timers; only a light scan throttle)
------------------------------------------------------------
local SCAN_RADIUS   = 6.0     -- yalms
local DEBUG         = false

-- Feature toggles
local ENABLED           = true          -- //ab on|off
local TE_OPEN_ENABLED   = true          -- //ab te on|off
local KI_OPEN_ENABLED   = false         -- //ab ki on|off (manual by default)

-- Some servers send this when contents aren’t enumerated in 0x5C
local SENTINEL_UNSPEC   = 1

------------------------------------------------------------
-- State
------------------------------------------------------------
local TE              = false           -- time-extension present in current box?
local boxData         = {}              -- captured from auto 0x5B (menu context)
local CTX_BY_IDX      = {}              -- [index] -> {category, menu_id}
local validBox        = {}              -- [id] -> { id, index, model, color, dist }
local checkedBox      = {}              -- [id] = true if poked already
local OWNED_KI_ID     = {}              -- [ki_id] = true if you own it (filtered set)
local ACTIVE          = nil             -- { id, index } : we’ve poked and are waiting for 0x5C

-- KI/manual pause
local SCAN_ENABLED    = true
local WAITING_KI      = false
local PAUSED_FOR_KI   = false

------------------------------------------------------------
-- Box visuals → quick color filter
------------------------------------------------------------
local box_models = {
    [965] = 'Blue',
    [968] = 'Red',
    [969] = 'Gold',
}

------------------------------------------------------------
-- 0x34 w1 → category (your mapping)
------------------------------------------------------------
local W1_CATEGORY = {
    [0x023C]='pop_items',            -- small gold
    [0x0239]='scroll/af_feet/items', -- small gold
    [0x0238]='pop_items',            -- small gold
    [0x0235]='scroll/item',          -- small gold

    [0x0440]='key_item',             -- large gold
    [0x0141]='temp_item_gold',
    [0x013E]='temp_item_gold',

    [0x16CB]='laden_temp_items',     -- blue

    [0x033F]='powerful_items',       -- small gold
    [0x033B]='powerful_items',       -- small gold
    [0x0337]='powerful_items',       -- small gold

    [0x013A]='temp_items',           -- small gold
    [0x0136]='temp_item',            -- small gold

    -- red lights
    [0x0026]='intense_ruby_light',
    [0x001F]='strong_azure_light',
    [0x001E]='strong_pearl_light',
    [0x001D]='mild_amber_light',
    [0x001C]='mild_ruby_light',
    [0x001B]='mild_azure_light',
    [0x001A]='mild_pearl_light',
    [0x0028]='mild_golden_light',
    [0x0023]='faint_silvery_light',
    [0x0022]='faint_golden_light',
    [0x0019]='faint_amber_light',
    [0x0018]='faint_ruby_light',
    [0x0017]='faint_azure_light',
    [0x0016]='faint_pearl_light',

    -- blue lights
    [0x0015]='time',
    [0x0014]='tremendous_exp',
    [0x0013]='princely_cruor',
    [0x0012]='laden_temp_item',
    [0x0011]='recovery',

    [0x023D]='scroll/af_feet/item',  -- large gold
}

local function pretty_from_w1(cat)
    local map = {
        key_item='Key Item chest',
        temp_item='Temporary Item chest',
        temp_item_gold='Temporary Item chest',
        temp_items='Temporary Items chest',
        laden_temp_item='Many Temporary Items chest',
        laden_temp_items='Many Temporary Items chest',
        recovery='Recovery chest (soothing light)',
        time='Time-extension light chest',
        princely_cruor='Cruor chest',
        tremendous_exp='EXP/LP/CP/JP chest',
        powerful_items='High-quality item chest',
        pop_items='Pop-items chest',
        ['scroll/item']='Scroll / Item chest',
        ['scroll/af_feet/item']='Scroll/AF-feet/Item chest',
        ['scroll/af_feet/items']='Scroll/AF-feet/Items chest',
        unknown='Unknown chest',
    }
    return map[cat] or ('Chest: '..tostring(cat))
end

------------------------------------------------------------
-- Forbidden Key helpers
------------------------------------------------------------
local FORBIDDEN_KEY_ID = (function()
    for id, row in pairs(res.items) do
        local en = (row.en or row.name or ''):lower()
        if en == 'forbidden key' then
            return id
        end
    end
    return nil
end)()

local function find_forbidden_key_slot()
    if not FORBIDDEN_KEY_ID then return nil end
    local items = windower.ffxi.get_items()
    if not items or not items.inventory then return nil end
    local inv = items.inventory
    local max = inv.max or 80
    for slot = 1, max do
        local it = inv[slot]
        if it and it.id == FORBIDDEN_KEY_ID and (it.count or 0) > 0 then
            return slot, it.count
        end
    end
    return nil
end

------------------------------------------------------------
-- Key Item cache
------------------------------------------------------------
local function refresh_owned_abyssea_kis()
    OWNED_KI_ID = {}
    local kis = windower.ffxi.get_key_items() or {}
    for _, kid in pairs(kis) do
        local rec = res.key_items[kid]
        if rec and rec.category == 'Abyssea' then
            local name = (rec.en or rec.name or ''):lower()
            if not name:match('^atma') and
               not name:match('traverser') and
               not name:match('trophy') and
               not name:match('abyssite') then
                OWNED_KI_ID[kid] = true
            end
        end
    end
end

------------------------------------------------------------
-- Scan / pick / poke (no timing logic, just gating by ACTIVE)
------------------------------------------------------------
local next_scan_at = 0

local function dprintf(fmt, ...)
    if DEBUG then windower.add_to_chat(207, ('[ab] '..fmt):format(...)) end
end

local function scan_boxes()
    local now = os.clock()
    if now < next_scan_at then return end
    next_scan_at = now + 0.25 -- CPU throttle only

    local mobs = windower.ffxi.get_mob_array() or {}
    for _, m in pairs(mobs) do
        if m and m.name == 'Sturdy Pyxis' and m.distance then
            local d = math.sqrt(m.distance)
            if d <= SCAN_RADIUS then
                local mdl   = m.models and m.models[1] or nil
                local color = mdl and box_models[mdl] or nil
                if color ~= 'Red' then
                    validBox[m.id] = {
                        id = m.id, index = m.index, model = mdl,
                        color = color or 'Unknown', dist = d,
                    }
                end
            end
        end
    end
end

local function pick_nearest_unchecked()
    local best, best_d = nil, 1e9
    for id, b in pairs(validBox) do
        if not checkedBox[id] and b.dist < best_d then
            best, best_d = b, b.dist
        end
    end
    return best
end

local function poke_box_by_id_index(id, index)
    local mob = windower.ffxi.get_mob_by_id(id)
    if not mob or not mob.distance then return false end
    local yalms = math.sqrt(mob.distance)
    print(yalms)
    if yalms > SCAN_RADIUS then return false end
    local mdl   = mob.models and mob.models[1] or nil
    local color = mdl and box_models[mdl] or nil
    if color == 'Red' then return false end

    packets.inject(packets.new('outgoing', 0x01A, { ['Target']=id, ['Target Index']=index }))
    checkedBox[id] = true
    ACTIVE = { id = id, index = index }
    dprintf('ACTIVE set: id=%s idx=%s', tostring(id), tostring(index))
    return true
end

------------------------------------------------------------
-- Menu helpers
------------------------------------------------------------
local function release_menu_via_052(menu_id)
    if not menu_id then return end
    windower.packets.inject_incoming( 0x052, string.char( 0,0,0,0,
            0x02,                                   -- type=2 (release)
            bit.band(menu_id, 0xFF),                -- lo byte
            bit.band(bit.rshift(menu_id, 8), 0xFF), -- hi byte
            0x00
        )
    )
end

local function escape_box()
    if boxData and boxData['Menu ID'] then
        release_menu_via_052(boxData['Menu ID'])
        boxData = {} -- don’t re-release same menu
    end
end

local function trade_key_if_te()
    if not (TE and TE_OPEN_ENABLED) then return end
    if not boxData or not boxData.Target then return end
    local slot = select(1, find_forbidden_key_slot()); if not slot then return end
    packets.inject(packets.new('outgoing', 0x036, {
        ['Target']         = boxData.Target,
        ['Target Index']   = boxData['Target Index'],
        ['Item Index 1']   = slot,
        ['Item Count 1']   = 1,
        ['Number of Items']= 1,
    }))
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
windower.register_event('load', refresh_owned_abyssea_kis)

-- Incoming packets
windower.register_event('incoming chunk', function(id, data)
    -- 0x34: pre-open classifier (w1)
    if id == 0x52 then
        ACTIVE = nil
    end
    if id == 0x34 then
        local p = packets.parse('incoming', data)
        local s = p['Menu Parameters'] or ''
        local w1 = (#s >= 4) and s:unpack('H', 3) or 0
        local cat = W1_CATEGORY[w1] or 'unknown'
        local idx = p['NPC Index'] or p['Target Index']
        if idx then CTX_BY_IDX[idx] = { category = cat, menu_id = p['Menu ID'] } end
        return
    end

    -- 0x5C: contents (the only place we release)
    if id == 0x5C then
        -- we’re done waiting for this chest
        ACTIVE = nil

        local p = packets.parse('incoming', data)
        local s = p['Menu Parameters']
        if type(s) ~= 'string' or #s < 2 then return end

        local idx = (boxData and boxData['Target Index'])
        local ctx = idx and CTX_BY_IDX[idx] or nil
        local cat = (ctx and ctx.category) or 'unknown'

        local first16 = s:unpack('H')

        -- Unspecified → fallback to 0x34 classification
        if first16 == SENTINEL_UNSPEC then
            windower.add_to_chat(207, '[ab] ' .. pretty_from_w1(cat) .. ' (fallback via 0x34)')
            escape_box()      -- release menu only after 0x5C
            TE = false
            if idx then CTX_BY_IDX[idx] = nil end
            return
        end

        -- Short-form Time Extension
        if first16 == 600 then
            TE = true
            windower.add_to_chat(207, '[ab] Time Extension found!')
            escape_box()      -- release after 0x5C
            trade_key_if_te() -- trade key right after release
            if idx then CTX_BY_IDX[idx] = nil end
            return
        end

        -- Key Item chest: u16 kid
        if cat == 'key_item' then
            local kid = first16
            local rec = res.key_items[kid]
            if rec and rec.category == 'Abyssea' then
                local nm  = rec.en or rec.name or ('KI#'..kid)
                local low = nm:lower()
                if not (low:match('^atma') or low:match('traverser') or low:match('trophy') or low:match('abyssite')) then
                    windower.add_to_chat(207, '[ab] ' .. nm)
                    if OWNED_KI_ID[kid] then
                        -- already own → close and continue
                        escape_box()
                        if idx then CTX_BY_IDX[idx] = nil end
                    else
                        -- need it → pause scanning; user selects KI manually
                        WAITING_KI    = true
                        PAUSED_FOR_KI = true
                        SCAN_ENABLED  = false
                        windower.add_to_chat(207, ('[ab] KI needed: %s — select it manually; I will auto-exit afterward.'):format(nm))
                        -- DO NOT release here; release comes after you click (via chat watcher)
                    end
                    return
                end
            end
            -- fall-through if not recognized
        end

        -- Items / temps / powerful: u32 list
        do
            local printed = false
            for i = 1, #s, 4 do
                local id32 = s:unpack('I', i)
                if id32 == 0 then break end
                if id32 == 600 then
                    TE = true
                    windower.add_to_chat(207, '[ab] Time Extension found!')
                    printed = true
                elseif id32 ~= SENTINEL_UNSPEC then
                    local it = res.items[id32] or res.key_items[id32]
                    windower.add_to_chat(207, '[ab] '.. (it and it.en or ('ID#'..id32)))
                    printed = true
                end
            end
            if not printed then
                windower.add_to_chat(207, '[ab] ' .. pretty_from_w1(cat) .. ' (fallback via 0x34)')
            end
            escape_box()      -- release after 0x5C
            trade_key_if_te()
            if idx then CTX_BY_IDX[idx] = nil end
            return
        end
    end
end)

-- Outgoing packets
windower.register_event('outgoing chunk', function(id, data)
    if id == 0x1A then
        local p = packets.parse('outgoing', data)
        if p.Category == 0 and p.Target then
            checkedBox[p.Target] = true
        end
    elseif id == 0x5B then
        -- capture auto “open dialog” 0x5B (Option=111) to store menu context
        local p = packets.parse('outgoing', data)
        if p['Option Index'] == 111 then
            boxData = p
            local idx = p['Target Index']
            if idx then
                CTX_BY_IDX[idx] = CTX_BY_IDX[idx] or {}
                CTX_BY_IDX[idx].menu_id = p['Menu ID']
                CTX_BY_IDX[idx].target  = p['Target']
            end
        end
    elseif id == 0x36 then
        TE = false
    end
end)

-- Chat watcher: complete KI flow and resume (still *after* 0x5C)
windower.register_event('incoming text', function(original, modified, mode)
    if not WAITING_KI then return end
    local text = (original or ''):gsub('[%z\1-\31\127]', '')
    local low  = text:lower()

    if low:find('key item obtained:', 1, true)
    or low:find('you already possess the key item', 1, true)
    or low:find('you already possess that key item', 1, true) then
        refresh_owned_abyssea_kis()
        escape_box()            -- release menu now that KI was taken
        boxData = {}
        WAITING_KI    = false
        PAUSED_FOR_KI = false
        SCAN_ENABLED  = true
        windower.add_to_chat(207, '[ab] KI handled. Resuming.')
    end
end)

-- Driver (no timers; just “poke one, wait for 0x5C”)
windower.register_event('prerender', function()
    if not ENABLED or not SCAN_ENABLED or WAITING_KI then return end
    if ACTIVE then return end  -- wait for 0x5C from the last poke

    scan_boxes()

    local target = pick_nearest_unchecked()
    if not target then return end
    poke_box_by_id_index(target.id, target.index)
end)

-- Zone/reset
windower.register_event('zone change', function()
    CTX_BY_IDX      = {}
    validBox        = {}
    checkedBox      = {}
    TE              = false
    WAITING_KI      = false
    PAUSED_FOR_KI   = false
    SCAN_ENABLED    = true
    ACTIVE          = nil
    boxData         = {}
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
local function onoff(b) return b and 'ON' or 'OFF' end

windower.register_event('addon command', function(cmd, arg1)
    cmd  = (cmd or ''):lower()
    arg1 = (arg1 or ''):lower()

    if cmd == 'on' or cmd == 'off' then
        ENABLED = (cmd == 'on')
        windower.add_to_chat(207, ('[ab] %s'):format(onoff(ENABLED)))

    elseif cmd == 'te' then
        if arg1 == 'on' or arg1 == 'off' then TE_OPEN_ENABLED = (arg1 == 'on') end
        windower.add_to_chat(207, ('[ab] TE auto-open: %s'):format(onoff(TE_OPEN_ENABLED)))

    elseif cmd == 'ki' then
        if arg1 == 'on' or arg1 == 'off' then KI_OPEN_ENABLED = (arg1 == 'on') end
        windower.add_to_chat(207, ('[ab] KI auto-open: %s (manual by default; no 0x5B inject)'):format(onoff(KI_OPEN_ENABLED)))

    elseif cmd == 'resume' then
        PAUSED_FOR_KI = false
        WAITING_KI    = false
        SCAN_ENABLED  = true
        windower.add_to_chat(207, '[ab] Resumed.')

    elseif cmd == 'status' or cmd == '' then
        windower.add_to_chat(207, ('[ab] %s | TE:%s | KI:%s | radius: %.1f | paused:%s | waiting:%s | debug:%s')
            :format(onoff(ENABLED), onoff(TE_OPEN_ENABLED), onoff(KI_OPEN_ENABLED), SCAN_RADIUS, onoff(PAUSED_FOR_KI), onoff(WAITING_KI), onoff(DEBUG)))
        windower.add_to_chat(207, '[ab] //ab on|off | te on|off | ki on|off | resume | status | debug on|off')

    elseif cmd == 'debug' then
        if arg1 == 'on' or arg1 == 'off' then DEBUG = (arg1 == 'on') end
        windower.add_to_chat(207, ('[ab] debug: %s'):format(onoff(DEBUG)))

    else
        windower.add_to_chat(123, '[ab] Unknown command. Use: //ab on|off | te on|off | ki on|off | resume | status | debug on|off')
    end
end)
