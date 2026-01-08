-- autobox
_addon.name     = 'autobox'
_addon.command  = 'ab'

require('luau')
require('tables')
require('pack')            -- for string:unpack
local packets = require('packets')
local res     = require('resources')
local bit     = require('bit')

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local pStatus       = 0
local validBox      = T{}          -- [id] -> { id,index,model,color,dist }
local checkedBox    = {}          -- [id] = true if already poked
local OWNED_KI_ID   = {}       -- [ki_id] = true
local OWNED_KI_NAME = {}       -- [name]  = true
local CTX_BY_IDX    = {}       -- [idx]   = {category, menu_id}
local DESPAWN_TTL   = 180.0   -- seconds; boxes despawn ~180s after spawn, IDs can be reused

local boxData       = {}       -- captured from auto 0x5B (Option=111)
local TE            = false

-- Chest visuals → color
local box_models = { [965]='Blue', [968]='Red', [969]='Gold' }

-- 0x34 w1 → category
local W1_CATEGORY = {
  [0x023C]='pop_items', [0x0239]='scroll/af_feet/items', [0x0238]='pop_items', [0x0235]='scroll/item',
  [0x0440]='key_item', [0x0141]='temp_item', [0x013E]='temp_item', [0x16CB]='laden_temp_items',
  [0x033F]='powerful_items', [0x033B]='powerful_items', [0x0337]='powerful_items',
  [0x013A]='temp_items', [0x0136]='temp_item',
  [0x0026]='intense_ruby_light', [0x001F]='strong_azure_light', [0x001E]='strong_pearl_light',
  [0x001D]='mild_amber_light', [0x001C]='mild_ruby_light', [0x001B]='mild_azure_light',
  [0x001A]='mild_pearl_light', [0x0028]='mild_golden_light', [0x0023]='faint_silvery_light',
  [0x0022]='faint_golden_light', [0x0019]='faint_amber_light', [0x0018]='faint_ruby_light',
  [0x0017]='faint_azure_light', [0x0016]='faint_pearl_light',
  [0x0015]='time', [0x0014]='tremendous_exp', [0x0013]='princely_cruor',
  [0x012F]='temp_items', [0x0012]='laden_temp_item', [0x0011]='recovery',
  [0x023D]='scroll/af_feet/item',
}

local function pretty_from_w1(cat)
  local map = {
    key_item='Key Item chest', temp_item='Temporary Item chest', temp_items='Temporary Items chest',
    laden_temp_item='Many Temporary Items chest', laden_temp_items='Many Temporary Items chest',
    recovery='Recovery chest (soothing light)', time='Time-extension light chest',
    princely_cruor='Cruor chest', tremendous_exp='EXP/LP/CP/JP chest',
    powerful_items='High-quality item chest', pop_items='Pop-items chest',
    ['scroll/item']='Scroll / Item chest', ['scroll/af_feet/item']='Scroll/AF-feet/Item chest',
    ['scroll/af_feet/items']='Scroll/AF-feet/Items chest', unknown='Unknown chest',
  }
  return map[cat] or ('Chest: '..tostring(cat))
end

-- === user toggles / settings ===
local ENABLED         = true   -- //ab on|off
local TE_OPEN_ENABLED = true   -- //ab te on|off  (auto trade Forbidden Key on TE)
local KI_OPEN_ENABLED = true   -- //ab ki on|off  (pause on needed KI; if off, skip it)

local function onoff(b) return b and 'ON' or 'OFF' end

-- scanning pause flag (used when waiting for you to click a KI)
local SCAN_ENABLED = true

----------------------------------------------------------------
-- Forbidden Key
----------------------------------------------------------------
local FORBIDDEN_KEY_ID = (function()
    for id,row in pairs(res.items) do
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
        local inv, max = items.inventory, items.inventory.max or 80
        for slot=1,max do
            local it = inv[slot]
            if it and it.id == FORBIDDEN_KEY_ID and (it.count or 0) > 0 then
                return slot, it.count
            end
        end
    return nil
end

----------------------------------------------------------------
-- Owned KIs
----------------------------------------------------------------
local function refresh_owned_abyssea_kis()
  OWNED_KI_ID, OWNED_KI_NAME = {}, {}
  local kis = windower.ffxi.get_key_items() or {}
    for _,kid in pairs(kis) do
        local rec = res.key_items[kid]
        if rec and rec.category == 'Abyssea' then
            local name = rec.en or rec.name or ''
            local low  = name:lower()
            if not low:match('^atma') and not low:match('traverser')
                and not low:match('trophy') and not low:match('abyssite') then
                OWNED_KI_ID[kid]   = true
                OWNED_KI_NAME[name]= true
            end
        end
    end
end

----------------------------------------------------------------
-- Poke logic
----------------------------------------------------------------
local function poke_one_box()
    if pStatus ~= 0 then return end  -- only when idle
    for id, v in pairs(validBox) do
        if type(v.index) == 'number' then
            -- sanity (6y + non-red) — validBox is already filtered but re-check is cheap
            local m = windower.ffxi.get_mob_by_id(id)
            if m and m.distance and (math.sqrt(m.distance) <= 6.0) then
                local mdl = m.models and m.models[1] or nil
                local color = mdl and box_models[mdl] or nil
                if color ~= 'Red' then
                    packets.inject(packets.new('outgoing', 0x01A, { ['Target']=id, ['Target Index']=v.index }))
                    checkedBox[id] = true
                    validBox[id]   = nil   -- remove from queue
                    break                  -- poke ONE per tick
                end
            else
                validBox[id] = nil  -- out of range; drop it
            end
        else
            validBox[id] = nil
        end
    end
end

-- trade forbidden key (only call when TE is true)
local function trade_forbidden_key()
    if not (TE and TE_OPEN_ENABLED) then return end

    if not boxData or not boxData.Target then return end

    local slot = select(1, find_forbidden_key_slot()); if not slot then return end

    packets.inject(packets.new('outgoing', 0x036, {
        ['Target'] = boxData.Target,
        ['Target Index'] = boxData['Target Index'],
        ['Item Index 1'] = slot,
        ['Item Count 1'] = 1,
        ['Number of Items'] = 1,
    }))
end

-- release menu via incoming 0x52 Type=2; requires Menu ID
local function release_menu()
    if not ENABLED then return end
    local mid = boxData and boxData['Menu ID']

    if not mid then return end

    windower.packets.inject_incoming( 0x052, string.char(0,0,0,0, 0x02, bit.band(mid,0xFF), bit.band(bit.rshift(mid,8),0xFF), 0x00) )
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
windower.register_event('load', refresh_owned_abyssea_kis)

-- scan every second
local function scan_boxes()
    if not ENABLED or not SCAN_ENABLED then return end
    local now = os.clock()
    pStatus = (windower.ffxi.get_player() or {}).status or 0
    local mobs = windower.ffxi.get_mob_array() or {}

    for _, m in pairs(mobs) do
        if m and m.name == 'Sturdy Pyxis' and m.distance and m.valid_target then
            local d = math.sqrt(m.distance)
            if d <= 6.0 and not checkedBox[m.id] then
                local mdl   = m.models and m.models[1] or nil
                local color = mdl and box_models[mdl] or nil
                if color ~= 'Red' then
                    local e = validBox[m.id]
                    if not e then
                        -- new sighting for this ID
                        validBox[m.id] = {
                            id         = m.id,
                            index      = m.index,
                            model      = mdl,
                            color      = color or 'Unknown',
                            dist       = d,
                            first_seen = now,
                            last_seen  = now,
                        }
                    else
                        -- existing ID – update, and detect reuse via index change
                        if e.index ~= m.index then
                            -- treat as a fresh spawn (old ID reused); clear state tied to old index
                            if e.index then CTX_BY_IDX[e.index] = nil end
                            checkedBox[m.id] = nil
                            e.first_seen = now
                        end
                        e.index     = m.index
                        e.model     = mdl
                        e.color     = color or 'Unknown'
                        e.dist      = d
                        e.last_seen = now
                    end
                end
            end
        end
    end
    poke_one_box()
    -- TTL reaper: boxes can live ~180s; after that the server may reuse the ID
    for id, b in pairs(validBox) do
        if (now - (b.first_seen or now)) >= DESPAWN_TTL then
            -- purge this chest from all state to avoid “checked” carryover on ID reuse
            validBox[id]   = nil
            checkedBox[id] = nil
            if b.index then CTX_BY_IDX[b.index] = nil end
        end
    end

end
scan_boxes:loop(1)

-- incoming packets
windower.register_event('incoming chunk', function(id, data)
    -- 0x34: label chest type (DO NOT release here)
    if id == 0x34 then
        local p = packets.parse('incoming', data)
        local s = p['Menu Parameters'] or ''
        local w1 = (#s >= 4) and s:unpack('H', 3) or 0
        local cat = W1_CATEGORY[w1] or 'unknown'
        local idx = p['NPC Index'] or p['Target Index']

        if idx then
            CTX_BY_IDX[idx] = { category = cat, menu_id = p['Menu ID'] } 
        end
        return
    end

    -- 0x5C: contents (release ONLY here)
    if id == 0x5C then
        local p = packets.parse('incoming', data)
        local s = p['Menu Parameters']
        if type(s) ~= 'string' or #s < 2 then return end

        -- try to align context with this menu session
        local idx = (boxData and boxData['Target Index']) or p['Target Index'] or p['NPC Index']
        local ctx = idx and CTX_BY_IDX[idx] or nil
        local cat = ctx and ctx.category or 'unknown'

        local first16 = s:unpack('H')

        -- sentinel / unknown contents → fallback to 0x34 label
        if first16 == 1000 or first16 == 1 then
            windower.add_to_chat(207, '[ab] '..pretty_from_w1(cat)..' (fallback via 0x34)')
            release_menu()

            if TE then
                trade_forbidden_key()
            end

            if idx then
                CTX_BY_IDX[idx] = nil
            end

            return
        end

        -- Time Extension
        if first16 == 600 then
            TE = true
            windower.add_to_chat(207, '[ab] Time Extension found!')
            release_menu()
            trade_forbidden_key()
            if idx then 
                CTX_BY_IDX[idx] = nil
            end
            return
        end

        -- Key Item chest (u16)
        if cat == 'key_item' then
            local kid = first16
            local rec = res.key_items[kid]
            if rec and rec.category == 'Abyssea' then
                local nm  = rec.en or rec.name or ('KI#'..kid)
                local low = nm:lower()
                if not (low:match('^atma') or low:match('traverser') or low:match('trophy') or low:match('abyssite')) then
                    windower.add_to_chat(207, '[ab] '..nm)
                    if OWNED_KI_ID[kid] then
                        -- already own → close and move on
                        release_menu()
                        if idx then
                            CTX_BY_IDX[idx] = nil
                        else
                            if KI_OPEN_ENABLED then
                                -- pause scanning so you can click it
                                SCAN_ENABLED  = false
                                windower.add_to_chat(207, ('[ab] KI needed: %s — select it manually; I will auto-exit afterward.'):format(nm))
                            else
                                -- user disabled KI handling → skip it, just close
                                windower.add_to_chat(207, ('[ab] KI found (%s) but KI auto-handling is OFF — skipping.'):format(nm))
                                release_menu()
                                if idx then 
                                    CTX_BY_IDX[idx] = nil
                                end
                            end
                        end
                    end
                    return
                end
            end
            -- fallthrough if not recognized: treat as items
        end

        -- Items / temps / powerful: u32 list
        local printed = false
        for i = 1, #s, 4 do
            local id32 = s:unpack('I', i)
            if id32 == 0 then break end
                if id32 == 600 then
                    TE = true
                    windower.add_to_chat(207, '[ab] Time Extension found!')
                    printed = true
                elseif id32 ~= 1000 then
                    local it = res.items[id32] or res.key_items[id32]
                    windower.add_to_chat(207, '[ab] '..(it and it.en or ('ID#'..id32)))
                    printed = true
                end
            end

            if not printed then
            windower.add_to_chat(207, '[ab] '..pretty_from_w1(cat)..' (fallback via 0x34)')
            end

            release_menu()
            trade_forbidden_key()

            if idx then
                CTX_BY_IDX[idx] = nil
            end
        return
    end
end)

-- outgoing packets
windower.register_event('outgoing chunk', function(id, data)
    if id == 0x1A then
        local p = packets.parse('outgoing', data)
        if p.Category == 0 and p.Target then
            checkedBox[p.Target] = true
        end
    elseif id == 0x5B then
        -- capture auto “open” (Option=111) to get menu context for 0x52 release
        local p = packets.parse('outgoing', data)
        if p['Option Index'] == 111 then
            boxData = p
        end
    elseif id == 0x36 then
        -- trade done -> clear TE flag
        TE = false
    end
end)

-- chat watcher: finish KI flow and resume
windower.register_event('incoming text', function(original, modified, mode)
    local text = (original or ''):gsub('[%z\1-\31\127]', '')
    local low  = text:lower()
    if low:find('key item obtained:', 1, true)
    or low:find('you already possess the key item', 1, true)
    or low:find('you already possess that key item', 1, true) then
        SCAN_ENABLED  = true
        refresh_owned_abyssea_kis()
        release_menu()  -- safe even if already closed
    end
end)

-- periodic scanner (already set with :loop above)
-- zone/reset
windower.register_event('zone change', function()
    CTX_BY_IDX  = {}
    validBox    = T{}
    checkedBox  = {}
    TE          = false
    boxData     = {}
end)

-- commands
windower.register_event('addon command', function(cmd, arg1)
    cmd  = (cmd or ''):lower()
    arg1 = (arg1 or ''):lower()

    if cmd == 'on' or cmd == 'off' then
        ENABLED = (cmd == 'on')
        if ENABLED then SCAN_ENABLED = true end
        windower.add_to_chat(207, ('[ab] addon: %s'):format(onoff(ENABLED)))

    elseif cmd == 'te' then
        if arg1 == 'on' or arg1 == 'off' then TE_OPEN_ENABLED = (arg1 == 'on') end
        windower.add_to_chat(207, ('[ab] TE auto-open: %s'):format(onoff(TE_OPEN_ENABLED)))

    elseif cmd == 'ki' then
        if arg1 == 'on' or arg1 == 'off' then KI_OPEN_ENABLED = (arg1 == 'on') end
        windower.add_to_chat(207, ('[ab] KI handling: %s'):format(onoff(KI_OPEN_ENABLED)))

    elseif cmd == 'resume' then
        SCAN_ENABLED = true
        windower.add_to_chat(207, '[ab] Scanning resumed.')

    elseif cmd == 'radius' then
        local n = tonumber(arg1)
        if n and n > 0 then
        SCAN_RADIUS = n
        windower.add_to_chat(207, ('[ab] Scan radius set to %.1f yalms'):format(SCAN_RADIUS))
        else
        windower.add_to_chat(123, '[ab] Usage: //ab radius <number>')
        end

    elseif cmd == 'status' or cmd == '' then
        local vb, cb = 0, 0
        for _ in pairs(validBox)   do vb = vb + 1 end
        for _ in pairs(checkedBox) do cb = cb + 1 end
        windower.add_to_chat(207, ('[ab] ON:%s  TE:%s  KI:%s  Scan:%s  Radius:%.1f  Queued:%d  Checked:%d')
        :format(onoff(ENABLED), onoff(TE_OPEN_ENABLED), onoff(KI_OPEN_ENABLED), onoff(SCAN_ENABLED), SCAN_RADIUS, vb, cb))
        windower.add_to_chat(207, '[ab] cmds: //ab on|off | te on|off | ki on|off | resume | radius <n> | status')

    else
        windower.add_to_chat(123, '[ab] Unknown cmd. Use: //ab on|off | te on|off | ki on|off | resume | radius <n> | status')
    end
end)

