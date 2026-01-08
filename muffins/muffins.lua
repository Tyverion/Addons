_addon.name = '[Muffins]'
_addon.author = 'Ender'
_addon.version = '1.8.2026'

require('luau')
packets = require('packets')

local zone           = 0
local lastZone       = 0
local baselineZone   = 267 -- Kamihr Drifts
local validZones     = S{275, 133, 189} -- Three zones for Sortie
local initialGalli   = 1
local totalGalli     = 0
local updated        = false
local reportComplete = false

local file_path = windower.addon_path .. 'data/'

windower.register_event('load', function()
    -- Get the current zone on load
    zone = windower.ffxi.get_info().zone
    lastZone = zone

    if not windower.dir_exists(file_path) then
        windower.create_dir(file_path)
    end

    -- Capture baseline in Kamihr Drifts; fallback to Sortie if we load mid-run.
    if zone == baselineZone or validZones:contains(zone) then
        packets.inject(packets.new('outgoing', 0x115))
        updated  = false
        reportComplete = false
    end

end)

windower.register_event('zone change', function()
    -- Whenever we change zone we want to know if it isn't Sortie so we can later calculate the difference.
    local oldZone = zone
    zone = windower.ffxi.get_info().zone
    lastZone = oldZone

    -- Entering Kamihr Drifts from a non-Sortie zone establishes the baseline.
    if zone == baselineZone and not validZones:contains(oldZone) then
        updated = false
        reportComplete = false
        packets.inject(packets.new('outgoing', 0x115))
    end

    -- This is used to determine when we leave Sortie.
    if validZones:contains(oldZone) and not validZones:contains(zone) and updated and not reportComplete then
        packets.inject(packets.new('outgoing', 0x115))
    end

end)

windower.register_event('incoming chunk', function(id, data)
    zone = windower.ffxi.get_info().zone

    if id == 0x118 then
        local p = packets.parse('incoming', data)

        -- Baseline is captured in Kamihr Drifts when coming from a non-Sortie zone.
        if zone == baselineZone and not updated and not validZones:contains(lastZone) then
            initialGalli = p['Gallimaufry']
            log('%d':format(p['Gallimaufry']))
            updated = true
        -- Fallback for loading mid-Sortie.
        elseif validZones:contains(zone) and not updated then
            initialGalli = p['Gallimaufry']
            log('%d':format(p['Gallimaufry']))
            updated = true
        -- We're checking if the current zone isn't a Sortie zone, if we leave Sortie by some means timeout, warp or whatever.
        elseif not validZones:contains(zone) and validZones:contains(lastZone) and updated then
            totalGalli = p['Gallimaufry']
            log('You have gained %d Muffins!':format(totalGalli - initialGalli))
            reportComplete = true

            local export = io.open(file_path .. 'Totals' .. '.log', 'a')
            if export then
                export:write(('Total Muffins %d: Date %s!\n'):format(totalGalli - initialGalli, os.date('%Y-%m-%d')))
                export:close()
            else
                log('Failed to open data/Totals.log for writing')
            end
            log('Wrote Muffins total to data/Totals.log')
        end
    end
end)
