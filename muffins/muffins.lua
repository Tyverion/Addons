_addon.name = 'muffins'
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
local reportComplete = false
local baselineRequested = false
local exitRequested = false
local newZone = 0
local oldZone = 0

local file_path = windower.addon_path .. 'data/'

windower.register_event('load', function()
    -- Get the current zone on load
    if windower.ffxi.get_info().zone == baselineZone then

        if not windower.dir_exists(file_path) then
            windower.create_dir(file_path)
        end

        -- Capture baseline on load.
        packets.inject(packets.new('outgoing', 0x115))
        reportComplete = false
        baselineRequested = true
        exitRequested = false
    end

end)

windower.register_event('zone change', function(new,old)
    -- Whenever we change zone we want to know if it isn't Sortie so we can later calculate the difference.
    newZone = new
    oldZone = old

    -- If we're not entering or leaving Sortie we want to establish our baseline zone basically this should always be kamihr.
    if new == baselineZone and not validZones:contains(old) then
        reportComplete = false
        baselineRequested = true
        exitRequested = false
        packets.inject(packets.new('outgoing', 0x115))
    end

    -- Entering Sortie from a non-Sortie zone starts a new run.
    if validZones:contains(new) and not validZones:contains(baselineZone) then
        reportComplete = false
        exitRequested = false
        log('Entered Sortie')
        packets.inject(packets.new('outgoing', 0x115))
    end

    -- This is used to determine when we leave Sortie.
    if validZones:contains(old) and not validZones:contains(new) then
        exitRequested = true
        log('Exited Sortie')
        packets.inject(packets.new('outgoing', 0x115))
    end

end)

windower.register_event('incoming chunk', function(id, data)
    zone = windower.ffxi.get_info().zone

    if id == 0x118 then
        local p = packets.parse('incoming', data)
        -- Baseline is captured after a baseline request.
        if baselineRequested and not exitRequested then
            initialGalli = p['Gallimaufry']
            log('%d':format(p['Gallimaufry']))
            baselineRequested   = false
        -- We're checking if the current zone isn't a Sortie zone, if we leave Sortie by some means timeout, warp or whatever.
        elseif exitRequested then
            totalGalli = p['Gallimaufry']
            log('You have gained %d Muffins!':format(totalGalli - initialGalli))

            local export = io.open(file_path .. 'Totals' .. '.log', 'a')
            if export then
                export:write(('Total Muffins %d: Date %s!\n'):format(totalGalli - initialGalli, os.date('%Y-%m-%d')))
                export:close()
            else
                log('Failed to open data/Totals.log for writing')
            end
            log('Wrote Muffins total to data/Totals.log')
            -- Reset exitRequested to false after written to log.
            exitRequested       = false
            reportComplete      = true
        end
    end
end)
