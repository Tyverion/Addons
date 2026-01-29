_addon.name = 'Trade'
_addon.author = 'Ivaar + Ender'
_addon.version = '4.5'
_addon.command = 'trade'

require('luau')
require('pack')
local item_groups = require('item_groups')
local config = require('config')
local packets = require('packets')
local res = require('resources')

local trade_count
local pending_trade = nil

local function reset_trade_state()
    pending_trade = nil
    count = nil
    sending_count = 0
    sending_slots = {}
    trade_confirmed = false
    trade_active = false
end

local trade_status = 0

settings = config.load({})

local whitelist_path = windower.addon_path .. 'whitelist.lua'
local whitelist = loadfile(whitelist_path)()
if type(whitelist) ~= 'table' then
    whitelist = {}
end

local bag_ids = {
    inventory = 0,
    satchel   = 5,
    sack      = 6,
    case      = 7,
    wardrobe  = 8,
    wardrobe2 = 10,
    wardrobe3 = 11,
    wardrobe4 = 12,
    wardrobe5 = 13,
    wardrobe6 = 14,
    wardrobe7 = 15,
    wardrobe8 = 16,
}

local function save_whitelist()
    local f = io.open(whitelist_path, 'w')
    if not f then
        windower.add_to_chat(123, '[Trade] Failed to save whitelist.')
        return
    end
    f:write('return {\n')
    for name, entry in pairs(whitelist) do
        f:write(('    ["%s"] = { id = %d, last_seen = %d },\n'):format(
            name, entry.id, entry.last_seen or os.time()))
    end
    f:write('}\n')
    f:close()
end

local function offer_trade(target_id, target_index)
    windower.add_to_chat(207, ('[Trade] Offering trade to: %s'):format(windower.ffxi.get_mob_by_id(target_id).name))
    packets.inject(packets.new('outgoing', 0x32, {
        ['Target'] = target_id,
        ['Target Index'] = target_index,
    }))
end

local function send_full_trade(target_id, target_index, item_id, total_count)
    local inventory = windower.ffxi.get_items().inventory
    local trade_slot = 1

    if not trade_active or not pending_trade then return end

    if pending_trade.grouped and pending_trade.item_list then
        for _, item in ipairs(pending_trade.item_list) do
            if trade_slot > 8 then break end

            local send_count = math.min(item.count, 99)

            packets.inject(packets.new('outgoing', 0x34, {
                ['Count'] = send_count,
                ['Item'] = item.id,
                ['Inventory Index'] = item.index,
                ['Slot'] = trade_slot,
            }))

            windower.add_to_chat(207, ('[Trade] Adding %d x %s'):format(send_count, res.items[item.id].en))
            trade_slot = trade_slot + 1
        end
    end
    if not pending_trade.grouped then
        local inventory = windower.ffxi.get_items().inventory
        local count_needed = total_count
        local trade_slot = 1
        if not trade_active or not pending_trade then return end

        for i, item in ipairs(inventory) do
            if item and item.id == item_id and item.count > 0 then
                local send_count = math.min(item.count, 99, count_needed)

                local trade_packet = packets.new('outgoing', 0x34, {
                    ['Count'] = send_count,
                    ['Item'] = item.id,
                    ['Inventory Index'] = i,
                    ['Slot'] = trade_slot,
                })

                windower.add_to_chat(207, ('[Trade] Adding item %s x %d'):format(res.items[item.id].en, send_count))
                packets.inject(trade_packet)

                count_needed = count_needed - send_count
                trade_slot = trade_slot + 1

                if count_needed <= 0 or trade_slot > 8 then
                    break
                end
            end
        end

        if tonumber(count_needed) > 0 then
            windower.add_to_chat(123, ('[Trade] Not enough of item ID %s. Missing %d.'):format(res.items[item_id].en, count_needed))
            return
        end
    end
end

local function move_item_packet(src_bag_id, src_index, count, item_id)
    packets.inject(packets.new('outgoing', 0x29, {
        ['Count'] = count,
        ['Bag'] = src_bag_id,
        ['Target Bag'] = 0, -- inventory
        ['Current Index'] = src_index,
        ['Target Index'] = 0x52, -- "auto" index
    }))

    local bag_name = 'UNKNOWN'
    for name, id in pairs(bag_ids) do
        if id == src_bag_id then
            bag_name = name
            break
        end
    end

    windower.add_to_chat(207, ('[Trade] Moving %d x %s to inventory'):format(count, bag_name))
end

local function move_items_to_inventory(item_id, needed_count)
    local bags = windower.ffxi.get_items()
    local moved = false

    for bag_name, bag_id in pairs(bag_ids) do
        if bag_id ~= 0 then
            local bag = bags[bag_name]
            for slot, item in ipairs(bag) do
                if item and item.id == item_id and item.status == 0 and needed_count > 0 then
                    local move_count = math.min(item.count, needed_count)
                    move_item_packet(bag_id, slot, move_count, item_id)
                    coroutine.sleep(0.1)
                    needed_count = needed_count - move_count
                    moved = true
                    if needed_count <= 0 then
                        return true
                    end
                end
            end
        end
    end

    return moved
end

windower.register_event('addon command', function(...)
    local args = {...}
    if not args[1] then return end

    local command = args[1]:lower()

    if command == 'add' then
        local target = windower.ffxi.get_mob_by_target('t')
        if not target or target.is_npc then
            windower.add_to_chat(123, '[Trade] Target a player first.')
            return
        end
        whitelist[target.name:lower()] = {
            id = target.id,
            last_seen = os.time()
        }
        save_whitelist()
        windower.add_to_chat(207, ('[Trade] Added %s to whitelist.'):format(target.name))
        return

    elseif command == 'remove' and args[2] then
        local name = args[2]:lower()
        if whitelist[name] then
            whitelist[name] = nil
            save_whitelist()
            windower.add_to_chat(207, ('[Trade] Removed %s from whitelist.'):format(name))
        else
            windower.add_to_chat(123, '[Trade] Name not in whitelist.')
        end
        return
    elseif command == 'complete' then
        packets.inject(packets.new('outgoing', 0x33, {
            ['Type'] = 2,
            ['Trade Count'] = 0,
        }))
    elseif command == 'cancel' then
        packets.inject(packets.new('outgoing', 0x33, {
            ['Type'] = 1,
            ['Trade Count'] = 0,
        }))

-- Quantity based trades
    elseif command == 'give' and args[2] and args[3] and args[4] then
        local target_name
        if args[2] ~= 't' then
            target_name = args[2]:lower()
        elseif args[2] == 't' then
            target_name = windower.ffxi.get_mob_by_target('t').name:lower()
        end
        
        local entry = whitelist[target_name]
        if not entry then
            windower.add_to_chat(123, ('[Trade] %s not in whitelist.'):format(target_name))
            return
        end

        local mob = windower.ffxi.get_mob_by_id(entry.id)
        if not mob then
            windower.add_to_chat(123, ('[Trade] Cannot find %s in range.'):format(target_name))
            return
        end

        local third_arg = args[3]:lower()
        local count = tonumber(third_arg)

        if count and args[4] then
            local item_input = table.concat(args, ' ', 4)
            local item_id = tonumber(item_input)
            local converted = windower.convert_auto_trans(table.concat(args, ' ', 4))
            item_input = (converted or item_input):lower()

            if not item_id then
                for id, item in pairs(res.items) do
                    if item.en:lower() == item_input then
                        item_id = id
                        break
                    end
                end
            end

            if not item_id then
                windower.add_to_chat(123, ('[Trade] Unknown item: %s'):format(item_input))
                return
            end

            pending_trade = {
                target_id = entry.id,
                target_index = mob.index,
                item_id = item_id,
                count = args[3],
                grouped = false,
            }

            local inventory_count = 0
            local items = windower.ffxi.get_items().inventory
            for _, item in ipairs(items) do
                if item.id == item_id then
                    inventory_count = inventory_count + item.count
                end
            end

            local total_needed = tonumber(args[3])
            if inventory_count < total_needed then
                move_items_to_inventory(item_id, total_needed - inventory_count)
                --coroutine.sleep(1)
            end

            offer_trade(entry.id, mob.index)
        else
            windower.add_to_chat(123, '[Trade] Invalid give syntax.')
        end

-- Grouped Based Trade
    elseif command == 'bulk' and args[2] and args[3] then
        local group_items = item_groups[args[3]]
        if not group_items then
            windower.add_to_chat(123, ('[Trade] Unknown group: %s'):format(args[3]))
            return
        end

        local target_name = args[2]:lower()
        local entry = whitelist[target_name]
        if not entry then
            windower.add_to_chat(123, ('[Trade] %s not in whitelist.'):format(target_name))
            return
        end

        local mob = windower.ffxi.get_mob_by_id(entry.id)
        if not mob then
            windower.add_to_chat(123, ('[Trade] Cannot find %s in range.'):format(target_name))
            return
        end

        local trade_list = {}
        local all_bags = windower.ffxi.get_items()
        local items_to_move = {}
        local moved_count = 0
        local matched_ids = {}  -- prevent duplicate trade entries
        local item_limit = 8

        -- Step 1: Search ALL bags for any item in the group list
        for bag_name, bag_id in pairs(bag_ids) do
            local bag = all_bags[bag_name]
            for slot, item in ipairs(bag) do
                if #items_to_move >= item_limit then break end
                if item and item.id and item.status == 0 then
                    local item_data = res.items[item.id]
                    if item_data then
                        for _, group_name in ipairs(group_items) do
                            if item_data.en:lower() == group_name:lower() and not matched_ids[item.id .. '_' .. slot] then
                                if bag_id ~= 0 then
                                    table.insert(items_to_move, {bag_id = bag_id, slot = slot, count = item.count})
                                else
                                    table.insert(items_to_move, {bag_id = 0, slot = slot, id = item.id, count = item.count})
                                end
                                matched_ids[item.id .. '_' .. slot] = true
                                break
                            end
                        end
                    end
                end
            end
            if #items_to_move >= item_limit then break end
        end

        -- Step 2: Move items to inventory (if not already there)
        for _, entry in ipairs(items_to_move) do
            if entry.bag_id ~= 0 then
                move_item_packet(entry.bag_id, entry.slot, entry.count)
                moved_count = moved_count + 1
            end
        end

        -- Step 3: Wait for movement to complete
        if moved_count > 0 then
            windower.add_to_chat(207, ('[Trade] Waiting for %d item(s) to move into inventory...'):format(moved_count))
            coroutine.sleep(1.0)
        end

        -- Step 4: Build trade list from refreshed inventory
        local inventory = windower.ffxi.get_items().inventory
        for slot, item in ipairs(inventory) do
            if #trade_list >= 8 then break end
            if item and item.id and item.status == 0 then
                local item_data = res.items[item.id]
                if item_data then
                    for _, name in ipairs(group_items) do
                        if item_data.en:lower() == name:lower() then
                            table.insert(trade_list, {
                                id = item.id,
                                index = slot,
                                count = item.count,
                            })
                            break
                        end
                    end
                end
            end
        end

        -- Step 5: Proceed with trade
        if #trade_list > 0 then
            windower.add_to_chat(207, ('[Trade] Preparing group trade (%s) to %s'):format(args[3], target_name))
            for _, t in ipairs(trade_list) do
                local item_name = res.items[t.id] and res.items[t.id].en or tostring(t.id)
                windower.add_to_chat(207, ('[Trade] Queued %d x %s'):format(t.count, item_name))
            end

            pending_trade = {
                target_id = entry.id,
                target_index = mob.index,
                item_list = trade_list,
                grouped = true,
            }

            offer_trade(entry.id, mob.index)
        else
            windower.add_to_chat(123, ('[Trade] No items found in inventory for group "%s".'):format(args[3]))
        end

    end

end)

-- in 21 (Trade Offer) out 33 (Accept Trade) 22 (Trade Started) 

local sending_slots = {}
local sending_count = 0
local trade_confirmed = false

local function complete_trade()
    packets.inject(packets.new('outgoing', 0x33, {
        ['Type'] = 2,
        ['Trade Count'] = 0,
    }))
    trade_confirmed = true
    reset_trade_state()
end

windower.register_event('outgoing chunk', function(id, data)
    if id == 0x33 then
        local p = packets.parse('outgoing', data)
        trade_status = p.Type
    end

    if id == 0x34 then
        local p = packets.parse('outgoing', data)

        if p.Slot >= 1 and p.Slot <= 8 then
            if p.Count == 0 then
                sending_slots[p.Slot] = nil -- removed item
            else
                sending_slots[p.Slot] = p.Count -- added item
            end

            -- Recalculate total
            sending_count = 0
            for _, v in pairs(sending_slots) do
                sending_count = sending_count + v
            end

            windower.add_to_chat(123, ('[Trade] Sending Count: %d'):format(sending_count))
        end

        if pending_trade == nil then return end

        complete_trade()
    end
end)

local count = nil
windower.register_event('incoming chunk', function(id, data)

    if id == 0x20 then
        local p = packets.parse('incoming', data)

    end

    if id == 0x021 then
        local p = packets.parse('incoming', data)
        local requester = windower.ffxi.get_mob_by_id(p.Player)

        if requester then
            windower.add_to_chat(207, ('[Trade] Trade request received from %s'):format(requester.name))
            if whitelist[requester.name:lower()] then
                windower.add_to_chat(207, ('[Trade] Accepting trade from %s'):format(requester.name))
                packets.inject(packets.new('outgoing', 0x33, {
                    ['Type'] = 0,
                    ['Trade Count'] = 0,
                }))
            else
                windower.add_to_chat(123, ('[Trade] Ignoring trade request from non-whitelisted: %s'):format(requester.name))
            end
        end

    elseif id == 0x022 then
        local p = packets.parse('incoming', data)
        local mob = windower.ffxi.get_mob_by_id(p.Player)
        trade_status = p.Type

        if p.Type == 0 then
            windower.add_to_chat(123, ('[Trade] Started'))
            trade_active = true
            if pending_trade then
                send_full_trade(pending_trade.target_id, pending_trade.target_index, pending_trade.item_id, pending_trade.count)
            end
        elseif p.Type == 1 then
            windower.add_to_chat(123, ('[Trade] Canceled'))
            reset_trade_state()
        elseif p.Type == 2 then
            windower.add_to_chat(123, ('[Trade] Completing Trade'))
            packets.inject(packets.new('outgoing', 0x33, {
                ['Type'] = 2,
                ['Trade Count'] = count,
            }))
        elseif p.Type == 9 then
            windower.add_to_chat(123, ('[Trade] Complete'))
            reset_trade_state()
        end

    elseif id == 0x023 then
        local p = packets.parse('incoming', data)
        count = p['Trade Count']

    end
end)