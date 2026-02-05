_addon.name = 'fasttarget'

packets = require('packets')

local function target_from_packet(p)
    if not p or not p.Target or not p['Target Index'] then return end
    windower.packets.inject_outgoing(0x1A, 'IIHHd2':pack(0xE1A, p.Target, p['Target Index'], 0x0F, 0, 0))
end

windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x1A then return end
    local p = packets.parse('outgoing', data)
    if not p then return end

    if p.Category == 2 then
        target_from_packet(p)
    end
end)
