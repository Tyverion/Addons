-- CurioMeds: auto–top-off items from Curio Vendor Moogle (CVM)
_addon.name    = 'CVM'
_addon.author  = 'Ender'
_addon.version = '2025-12-09'
_addon.command = 'cvm'

require('luau')
local packets = require('packets')
local res     = require('resources')

--------------------------------------------------------------------------------
-- Defaults: hardcoded menu option (opt) + slot per item
-- opt = outgoing 0x5B "Option Index" (e.g., 1 = Medicine)
--------------------------------------------------------------------------------
local wanted = {
    -- Medicine (opt=1)
    ['Panacea']          = { qty = 0,  slot = 11, opt = 1 },
    ['Echo Drops']       = { qty = 0,  slot = 13, opt = 1 },
    ['Antacid']          = { qty = 0,  slot = 14, opt = 1 },
    ['Holy Water']       = { qty = 0,  slot = 15, opt = 1 },
    ['Remedy']           = { qty = 0,  slot = 16, opt = 1 },
    ['Prism Powder']     = { qty = 0,  slot = 18, opt = 1 },
    ['Silent Oil']       = { qty = 0,  slot = 19, opt = 1 },
    ['Reraiser']         = { qty = 0,  slot = 21, opt = 1 },
    ['Hi-Reraiser']      = { qty = 0,  slot = 22, opt = 1 },
    ['Vile Elixir']      = { qty = 0,  slot = 23, opt = 1 },
    ['Vile Elixir +1']   = { qty = 0,  slot = 24, opt = 1 },

    -- Foodstuffs
    ['Grape Daifuku']    = { qty = 0, slot = 67, opt = 4 },
}

-- Known vendor(s) (expand as you collect)
local VENDORS = {
    [232] = { menu_id = 9601, target_id = 17727683 }, -- Curio Moogle Port Sandy
    [236] = { menu_id = 9601, target_id = 17744215 }, -- Curio Moogle Port Bastok
    [240] = { menu_id = 9601, target_id = 17760536 }, -- Curio Moogle Port Windy
}

local DEFAULT_MENU_ID  = 9601
local DIST2_NEAR       = 36    -- distance^2 ≈ 6y
local BUY_THROTTLE     = 0.10  -- small pacing after each confirmed buy

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local cvm = { id=nil, index=nil, zone=nil, menu_id=nil }

-- Grouped deficits (per opt)
local groups = {}               -- opt -> { {name, need, slot, opt}, ... }
local group_order = {}          -- array of opts in process order
local opt_idx = 0               -- index into group_order

-- Current purchase flow
local current = nil             -- {name, need, slot, opt}
local last_buy = nil            -- {name, slot, requested, opt}

-- Wait flags
local waiting_for_menu    = false  -- wait 0x34 after 0x1A
local waiting_for_shop    = false  -- wait 0x3C after 0x5B(opt)
local waiting_for_confirm = false  -- wait 0x3F after 0x83
local pending_opt         = nil    -- opt to open after 0x34

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function addon_message(msg)
    windower.add_to_chat(207, ('[CurioMeds] %s'):format(msg))
end

local function deepcopy(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k,v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

local function set_wanted(tbl) wanted = tbl end

-- Lowercase item key search against `wanted`
local function find_item_key(q)
    if type(q) ~= 'string' then return nil end
    q = q:lower()

    -- deterministic order
    local names = {}
    for name,_ in pairs(wanted) do names[#names+1] = name end
    table.sort(names)

    -- exact (case-insensitive)
    for _, name in ipairs(names) do
        if name:lower() == q then return name end
    end
    -- prefix match
    for _, name in ipairs(names) do
        local ln = name:lower()
        if ln:find('^'..q, 1, true) then return name end
    end
    -- substring match
    for _, name in ipairs(names) do
        local ln = name:lower()
        if ln:find(q, 1, true) then return name end
    end
end

-- join arg[i..j] with spaces
local function join(arg, i, j)
    local t = {}
    for k=i,j do t[#t+1] = arg[k] end
    return table.concat(t, ' ')
end

-- inventory helpers (no wardrobes/moghouse)
local KNOWN_BAGS = { 'inventory','satchel','sack','case' }

local function get_item_id(name)
    for id,it in pairs(res.items) do
        if it.en == name then return id end
    end
end

local function get_stack_size(name)
    if name == 'Vile Elixir' or name == 'Vile Elixir +1' then return 1 end
    local id = get_item_id(name)
    local it = id and res.items[id]
    return (it and it.stack) or 12
end

local function inv_count(name)
    local id = get_item_id(name); if not id then return 0 end
    local items = windower.ffxi.get_items() or {}
    local total = 0
    for _,bag in ipairs(KNOWN_BAGS) do
        local b = items[bag]
        if type(b) == 'table' and b.enabled ~= false then
            for i=1,(b.max or 0) do
                local e = b[i]
                if e and e.id == id then total = total + (e.count or 1) end
            end
        end
    end
    return total
end

local function inventory_free_slots()
    local inv = (windower.ffxi.get_items() or {}).inventory
    if type(inv) ~= 'table' then return 0 end
    local used, max = 0, inv.max or 0
    for i=1,max do local e=inv[i]; if e and e.id and e.id>0 then used=used+1 end end
    return math.max(0, max - used)
end

--------------------------------------------------------------------------------
-- Per-user override: data/<player>.lua (skips profiles/settings)
--------------------------------------------------------------------------------
-- Try loading per-user wanted list from data/<player>.lua
local function load_user_wanted()
    local player = windower.ffxi.get_player()
    if not player or not player.name then
        return false
    end

    local fname = (player.name or '') .. '.lua'
    local path  = windower.addon_path .. 'Data/' .. fname
    local chunk, err = loadfile(path)
    if not chunk then
        addon_message(('No per-user config found at %s'):format(path))
        return false
    end

    local ok, cfg = pcall(chunk)
    if not ok then
        addon_message(('Error loading %s: %s'):format(path, tostring(cfg)))
        return false
    end

    local wanted_tbl = cfg
    if type(cfg) == 'table' and type(cfg.wanted) == 'table' then
        wanted_tbl = cfg.wanted
    end

    if type(wanted_tbl) == 'table' then
        set_wanted(deepcopy(wanted_tbl))
        return true
    else
        addon_message(('Config %s missing wanted table'):format(path))
    end

    return false
end

--------------------------------------------------------------------------------
-- Build grouped deficits (opt buckets)
--------------------------------------------------------------------------------
local function build_groups()
    groups, group_order = {}, {}
    local by_opt = {}
    for name,cfg in pairs(wanted) do
        local want = cfg.qty or 0
        if want > 0 and cfg.slot and cfg.opt then
            local have = inv_count(name)
            local need = math.max(0, want - have)
            if need > 0 then
                by_opt[cfg.opt] = by_opt[cfg.opt] or {}
                by_opt[cfg.opt][#by_opt[cfg.opt]+1] = { name=name, need=need, slot=cfg.slot, opt=cfg.opt }
            end
        end
    end
    for opt,list in pairs(by_opt) do
        table.sort(list, function(a,b) return a.name < b.name end)
        groups[opt] = list
        group_order[#group_order+1] = opt
    end
    table.sort(group_order)
    opt_idx = 0
    return #group_order > 0
end

local function has_more_in_group(opt)
    local list = groups[opt]
    return list and #list > 0
end

local function pop_next_in_group(opt)
    local list = groups[opt]
    if not list or #list == 0 then return nil end
    return table.remove(list, 1)
end

--------------------------------------------------------------------------------
-- NPC locate
--------------------------------------------------------------------------------
local function find_cvm()
    local info = windower.ffxi.get_info()
    local zone = info and info.zone
    local mobs = windower.ffxi.get_mob_array() or {}
    local vz = (zone and VENDORS[zone]) or {}

    if vz.target_id then
        for _,m in pairs(mobs) do
            if m and m.id == vz.target_id and (m.distance or 1e9) <= DIST2_NEAR then
                return { id=m.id, index=m.index, zone=zone, menu_id=(vz.menu_id or DEFAULT_MENU_ID) }
            end
        end
    end
    --[[for _,m in pairs(mobs) do
        if m and m.name == 'Curio Vendor Moogle' and (m.distance or 1e9) <= DIST2_NEAR then
            return { id=m.id, index=m.index, zone=zone, menu_id=(vz.menu_id or DEFAULT_MENU_ID) }
        end
    end]]
end

--------------------------------------------------------------------------------
-- Packet send helpers
--------------------------------------------------------------------------------
local function poke()
    packets.inject(packets.new('outgoing', 0x01A, {
        ['Target']       = cvm.id,
        ['Target Index'] = cvm.index,
        ['Category']     = 0,
        ['Param']        = 0,
    }))
end

local function choose_option(opt_index)
    packets.inject(packets.new('outgoing', 0x05B, {
        ['Target']            = cvm.id,
        ['Target Index']      = cvm.index,
        ['Option Index']      = opt_index,
        ['_unknown1']         = 0,
        ['Automated Message'] = false,
        ['_unknown2']         = 0,
        ['Zone']              = cvm.zone,
        ['Menu ID']           = cvm.menu_id or DEFAULT_MENU_ID,
    }))
end

local function release_npc()
    -- 0x05B: Option Index = 0, _unknown1 = 16384 to close the menu
    packets.inject(packets.new('outgoing', 0x05B, {
        ['Target']            = cvm.id,
        ['Target Index']      = cvm.index,
        ['Option Index']      = 0,
        ['_unknown1']         = 16384,
        ['Automated Message'] = false,
        ['_unknown2']         = 0,
        ['Zone']              = cvm.zone,
        ['Menu ID']           = cvm.menu_id or DEFAULT_MENU_ID,
    }))
end

local function buy_now(slot, count)
    packets.inject(packets.new('outgoing', 0x083, {
        ['Count']     = count,
        ['_unknown1'] = 0,
        ['Shop Slot'] = slot,
        ['_unknown3'] = 0,
        ['_unknown4'] = 0,
    }))
end

--------------------------------------------------------------------------------
-- Group flow
--------------------------------------------------------------------------------
local function open_group(opt)
    waiting_for_menu, waiting_for_shop, waiting_for_confirm = true, false, false
    pending_opt = opt
    poke()
    --addon_message(('Poked CVM; awaiting 0x34 to open opt=%d'):format(opt))

    -- timeout if 0x34 never arrives
    coroutine.schedule(function()
        if waiting_for_menu then
            waiting_for_menu = false
            addon_message('Timeout waiting for 0x34; retrying poke...')
            open_group(opt)
        end
    end, 3)
end

local function next_group_or_finish()
    opt_idx = opt_idx + 1
    if opt_idx > #group_order then
        addon_message('Done.')
        return
    end
    local opt = group_order[opt_idx]
    if has_more_in_group(opt) then
        open_group(opt)
    else
        return next_group_or_finish()
    end
end

local function send_next_batch_or_item_in_group(opt)
    if current and current.need and current.need > 0 then
        local stack = get_stack_size(current.name)
        local count = math.min(current.need, stack)
        last_buy = { name=current.name, slot=current.slot, requested=count, opt=current.opt }
        buy_now(current.slot, count)
        waiting_for_confirm = true
        addon_message(('Buying %dx %s (slot %d)'):format(count, current.name, current.slot))
        return
    end
    current = pop_next_in_group(opt)
    if current then
        if inventory_free_slots() == 0 then
            addon_message('No free inventory slots. Aborting.')
            groups, group_order = {}, {}
            current, last_buy = nil, nil
            waiting_for_shop, waiting_for_confirm = false, false
            return
        end
        return send_next_batch_or_item_in_group(opt)
    end
    release_npc()
    if BUY_THROTTLE > 0 then coroutine.sleep(BUY_THROTTLE) end
    return next_group_or_finish()
end

--------------------------------------------------------------------------------
-- Incoming (0x34, 0x3C, 0x3F)
--------------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data)
    -- 0x34: menu open after poke
    if id == 0x034 and waiting_for_menu then
        local r = packets.parse('incoming', data)
        cvm.menu_id = (r and (r['Menu ID'] or r['MenuID'])) or cvm.menu_id or DEFAULT_MENU_ID
        cvm.zone    = (r and (r['Zone'] or r['Zone ID'])) or cvm.zone
        cvm.index   = (r and (r['NPC Index'] or r['Target Index'])) or cvm.index

        waiting_for_menu = false

        if pending_opt then
            choose_option(pending_opt)
            waiting_for_shop = true
            --addon_message( ( 'Got 0x34 (menu %s); 0x5B opt=%d waiting 0x3C' ):format( tostring( cvm.menu_id ), pending_opt ) )
            pending_opt = nil

            coroutine.schedule(function()
                if waiting_for_shop and current == nil then
                    waiting_for_shop = false
                    addon_message('Timeout waiting for 0x3C after 0x5B; re-opening group...')
                    local opt = group_order[opt_idx]
                    if opt then open_group(opt) end
                end
            end, 3)
        end
        return
    end

    -- 0x3C: shop list gate
    if id == 0x03C and waiting_for_shop then
        waiting_for_shop = false
        local opt = group_order[opt_idx]
        if not opt then return end
        current = nil
        return send_next_batch_or_item_in_group(opt)
    end

    -- 0x3F: buy response {Shop Slot (U16), _unknown1 (U16), Count (U32)}
    if id == 0x03F and waiting_for_confirm then
        local r = packets.parse('incoming', data)
        local resp_slot = r and r['Shop Slot'] or nil
        local resp_cnt  = r and r['Count'] or 0

        if last_buy and resp_slot and last_buy.slot and resp_slot ~= last_buy.slot then
            addon_message(('Warning: 0x3F slot %d != requested %d'):format(resp_slot, last_buy.slot))
        end

        if current and last_buy and current.name == last_buy.name then
            current.need = math.max(0, (current.need or 0) - math.max(0, resp_cnt or 0))
        else
            if last_buy and last_buy.name then
                local cfg = wanted[last_buy.name]
                if cfg and cfg.qty then
                    local have_now = inv_count(last_buy.name)
                    local still = math.max(0, cfg.qty - have_now)
                    if still > 0 then
                        current = { name=last_buy.name, need=still, slot=last_buy.slot, opt=last_buy.opt }
                    else
                        current = nil
                    end
                end
            end
        end

        last_buy = nil
        waiting_for_confirm = false
        if BUY_THROTTLE > 0 then coroutine.sleep(BUY_THROTTLE) end
        local opt = group_order[opt_idx]
        return send_next_batch_or_item_in_group(opt)
    end
end)

--------------------------------------------------------------------------------
-- Load wanted list on load/login
--------------------------------------------------------------------------------
local function load_active_wanted()
    if load_user_wanted() then
        addon_message('Loaded Profile.')
        return
    end
    set_wanted( deepcopy(wanted) )
end

windower.register_event('load',  load_active_wanted)
windower.register_event('login', load_active_wanted)

--------------------------------------------------------------------------------
-- Commands (structured)
--------------------------------------------------------------------------------
windower.register_event('addon command', function(...)
    local arg = L{...}
    if #arg == 0 then
        -- default: try to run
        local found = find_cvm()
        if not found then addon_message('Stand near a Curio Vendor Moogle (<=6y).'); return end
        cvm.id, cvm.index, cvm.zone, cvm.menu_id = found.id, found.index, found.zone, found.menu_id
        if not build_groups() then addon_message('All set — no deficits.'); return end
        return next_group_or_finish()
    end

    local lower = arg:map(string.lower)
    local cmd   = lower[1]

    local function print_help()
        addon_message('Commands:')
        addon_message('  //cvm                  - run (buy deficits)')
        addon_message('  //cvm help             - show this help')
        addon_message('  //cvm status           - show needed items')
        addon_message('  //cvm list             - list configured items')
        addon_message('  //cvm buy <item> <n>   - set desired quantity')
        addon_message('  //cvm opt <item> <id>  - set menu option index')
        addon_message('  //cvm slot <item> <id> - set shop slot index')
        addon_message('  //cvm add <item> <opt> <slot> <qty> - add item')
        addon_message('  //cvm remove <item>    - remove item')
    end

    if cmd == 'help' then
        print_help()
        return
    end

    local commands = {}

    commands.run = function()
        local found = find_cvm()
        if not found then addon_message('Stand near a Curio Vendor Moogle (<=6y).'); return end
        cvm.id, cvm.index, cvm.zone, cvm.menu_id = found.id, found.index, found.zone, found.menu_id
        if not build_groups() then addon_message('All set — no deficits.'); return end
        return next_group_or_finish()
    end

    commands.status = function()
        if not build_groups() then addon_message('No deficits.'); return end
        for _, opt in ipairs(group_order) do
            addon_message(('Opt %d:'):format(opt))
            for _, it in ipairs(groups[opt]) do
                addon_message(('  Need %-16s %2d  (slot %d)'):format(it.name, it.need, it.slot))
            end
        end
    end

    commands.list = function()
        addon_message('Configured items:')
        for name,cfg in pairs(wanted) do
            addon_message(('  %-16s  qty=%-3d  opt=%-2s  slot=%s')
                :format(name, cfg.qty or 0, tostring(cfg.opt or '?'), tostring(cfg.slot or '?')))
        end
    end

    -- buy: //cvm buy <item name> <number>
    commands.buy = function()
        if #lower < 3 then addon_message('Usage: //cvm buy <item name> <qty>'); return end
        local qty = tonumber(lower[#lower]); if not qty or qty < 0 then addon_message('Invalid <qty>.'); return end
        local item_name = join(lower, 2, #lower-1)
        local key = find_item_key(item_name); if not key then addon_message(('Unknown item "%s"'):format(item_name)); return end
        wanted[key].qty = qty
        addon_message(('Set %s qty -> %d'):format(key, qty))
    end

    -- opt: //cvm opt <item name> <option_index>
    commands.opt = function()
        if #lower < 3 then addon_message('Usage: //cvm opt <item name> <option_index>'); return end
        local v = tonumber(lower[#lower]); if not v then addon_message('Invalid <option_index>.'); return end
        local item_name = join(lower, 2, #lower-1)
        local key = find_item_key(item_name); if not key then addon_message(('Unknown item "%s"'):format(item_name)); return end
        wanted[key].opt = v
        addon_message(('Set %s opt -> %d'):format(key, v))
    end

    -- slot: //cvm slot <item name> <slot_index>
    commands.slot = function()
        if #lower < 3 then addon_message('Usage: //cvm slot <item name> <slot_index>'); return end
        local v = tonumber(lower[#lower]); if not v then addon_message('Invalid <slot_index>.'); return end
        local item_name = join(lower, 2, #lower-1)
        local key = find_item_key(item_name); if not key then addon_message(('Unknown item "%s"'):format(item_name)); return end
        wanted[key].slot = v
        addon_message(('Set %s slot -> %d'):format(key, v))
    end

    -- add: //cvm add <item name> <opt> <slot> <qty>
    commands.add = function()
        if #lower < 5 then addon_message('Usage: //cvm add <item name> <opt> <slot> <qty>'); return end
        local qty  = tonumber(lower[#lower]);       if not qty  then addon_message('Invalid <qty>.');  return end
        local slot = tonumber(lower[#lower-1]);     if not slot then addon_message('Invalid <slot>.'); return end
        local opt  = tonumber(lower[#lower-2]);     if not opt  then addon_message('Invalid <opt>.');  return end
        local item_name = join(arg, 2, #arg-3) -- original casing for the key
        if wanted[item_name] then addon_message(('Item already exists: %s'):format(item_name)); return end
        wanted[item_name] = { qty=qty, slot=slot, opt=opt }
        addon_message(('Added %s (opt=%d, slot=%d, qty=%d)'):format(item_name, opt, slot, qty))
    end

    -- remove: //cvm remove <item name>
    commands.remove = function()
        if #lower < 2 then addon_message('Usage: //cvm remove <item name>'); return end
        local item_name = join(lower, 2, #lower)
        local key = find_item_key(item_name); if not key then addon_message(('Unknown item "%s"'):format(item_name)); return end
        wanted[key] = nil
        addon_message(('Removed %s'):format(key))
    end

    -- dispatch
    local action = commands[cmd]
    if action then
        return action()
    end

    -- fallback: "<item name> <qty>"
    if #lower >= 2 then
        local qty = tonumber(lower[#lower])
        if qty then
            local item_name = join(lower, 1, #lower-1)
            local key = find_item_key(item_name)
            if key then
                wanted[key].qty = qty
                addon_message(('Set %s qty -> %d'):format(key, qty))
                return
            end
        end
    end

    addon_message('Unknown command. Try: run | status | list | qty/opt/slot/add/remove')
end)
