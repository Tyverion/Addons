-- addons/autobox/init.lua
_addon.name    = 'autobox'
_addon.version = '0.1'
_addon.author  = 'you+gpt'
_addon.command = 'ab'

local packets = require('packets')
local res     = require('resources')

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local ENABLED = true

-- Recently seen chest menu by NPC Index
-- RECENT[idx] = { zone, menu_id, w1, tail, signature, ts }
local RECENT = {}

-- Last parsed 0x5C id-list per idx (for simple dedupe)
local LAST_LIST = {}   -- [idx] = "id1|id2|..."

-- Owned Abyssea KIs (IDs and names), excluding Atma
local OWNED_KI_ID  = {}  -- [id] = true
local OWNED_KI_NAM = {}  -- [name] = true

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function ts_utc() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

local function zone_id()
    local info = windower.ffxi.get_info()
    return (info and info.zone) or 0
end

local function u16le(s, i) local b1,b2 = s:byte(i, i+1); return b1 + b2*256 end
local function u32le(s, i) local b1,b2,b3,b4 = s:byte(i, i+4); return b1 + b2*256 + b3*65536 + b4*16777216 end

local function classify_w1(w1)
    local map = {
        [0x0440]='key_item',
        [0x033F]='item',
        [0x0141]='temp_item', [0x013E]='temp_item',
        [0x0015]='time', [0x0014]='exp', [0x0013]='cruor', [0x0011]='recovery', [0x0012]='temp_item',
    }
    return map[w1] or 'unknown'
end

local function refresh_owned_abyssea_kis()
    OWNED_KI_ID, OWNED_KI_NAM = {}, {}
    local kis = windower.ffxi.get_key_items() or {}
    for _,kid in pairs(kis) do
        local rec = res.key_items[kid]
        if rec and rec.category == 'Abyssea' then
            -- exclude Atma family
            local name = rec.en or rec.name or ''
            if not name:lower():match('^atma') then
                OWNED_KI_ID[kid] = true
                OWNED_KI_NAM[name] = true
            end
        end
    end
end

----------------------------------------------------------------
-- Packet hooks
----------------------------------------------------------------

-- 0x34: Menu (has 32B "Menu Parameters")
windower.register_event('incoming chunk', function(id, data)
    if not ENABLED then return end

    if id == 0x34 then
        local p = packets.parse('incoming', data) or {}
        local idx = p['NPC Index'] or p['Target Index']
        local menu_id = p['Menu ID'] or p['MenuID'] or p['Menu Id']
        local params = p['Menu Parameters']
        local w1, d7, tail8

        if type(params) == 'string' and #params >= 32 then
            w1   = u16le(params, 3)
            d7   = u32le(params, 29)  -- last dword ("tail")
            tail8 = string.format('%08X', d7 or 0)
        end

        local cat = (w1 and classify_w1(w1)) or 'unknown'
        local sig = string.format('%d:%s:%s', zone_id(), tostring(menu_id or 0), tail8 or '00000000')

        if idx then
            RECENT[idx] = {
                zone = zone_id(), menu_id = menu_id, w1 = w1, tail = tail8, signature = sig, ts = os.clock(),
            }
        end

        -- Light debug line
        if idx then
            print(('[ab] 0x34 idx=%s  w1=0x%04X  cat=%s  sig=%s'):format(tostring(idx), w1 or 0, cat, sig))
        end
        return
    end

    -- 0x5C: Event String (its Menu Parameters carry row IDs for the submenu)
    if id == 0x5C then
        local p = packets.parse('incoming', data) or {}
        local idx = p['NPC Index'] or p['Target Index']
        local params = p['Menu Parameters']
        if not (idx and type(params) == 'string' and #params >= 4) then return end

        local attach = RECENT[idx]
        if not attach then return end  -- no context

        -- Parse up to 8 dwords, stop at first 0
        local ids, parts = {}, {}
        for off = 1, #params, 4 do
            if off + 3 > #params then break end
            local idv = u32le(params, off)
            if idv == 0 then break end
            ids[#ids+1] = idv
            parts[#parts+1] = tostring(idv)
        end
        if #ids == 0 then return end

        -- Simple dedupe per idx
        local key = table.concat(parts, '|')
        if LAST_LIST[idx] == key then return end
        LAST_LIST[idx] = key

        -- Resolve & print
        local cat = classify_w1(attach.w1 or 0)
        local header = ('[ab] sig=%s  (%s)'):format(attach.signature or '?', cat)
        print(header)

        for row, idv in ipairs(ids) do
            if idv == 600 then
                print('Found a Time extension')
            else
                local name, kind
                local ki = res.key_items[idv]
                if ki then
                    name, kind = (ki.en or ki.name or ('KI#'..idv)), 'KI'
                    local owned = OWNED_KI_ID[idv] and ' (owned)' or ' (NEEDED)'
                    print(('  [%d] %s: %s (#%d)%s'):format(row, kind, name, idv, owned))
                else
                    local it = res.items[idv]
                    if it then
                        name, kind = (it.en or it.name or ('Item#'..idv)), 'Item'
                        print(('  [%d] %s: %s (#%d)'):format(row, kind, name, idv))
                    else
                        -- temp items are in res.items too; if not found, just show raw
                        print(('  [%d] Unknown id: #%d'):format(row, idv))
                    end
                end
            end
        end

        -- Simulate the action we would take now
        print('Fake Trade')

        return
    end
end)

----------------------------------------------------------------
-- Commands
----------------------------------------------------------------
windower.register_event('addon command', function(cmd)
    cmd = (cmd or ''):lower()
    if cmd == 'on' then
        ENABLED = true
        print('[ab] on')
    elseif cmd == 'off' then
        ENABLED = false
        print('[ab] off')
    elseif cmd == 'kis' then
        refresh_owned_abyssea_kis()
        local n = 0
        for _ in pairs(OWNED_KI_ID) do n = n + 1 end
        print(('[ab] Abyssea KIs cached (excl. Atma): %d'):format(n))
    else
        print('[ab] //ab on|off|kis')
    end
end)

windower.register_event('load', function()
    refresh_owned_abyssea_kis()
    print('[ab] loaded. Interact with a chest to see contents (no peek needed).')
end)
