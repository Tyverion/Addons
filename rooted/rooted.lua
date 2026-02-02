_addon.name = 'rooted'

packets = require('packets')

windower.register_event('incoming chunk', function(id, data)
    local p = packets.parse('incoming', data)
    if id ~= 0x28 then return end

    if S{3,11}:contains(p.Category) then
        local player = windower.ffxi.get_player()
        if not player then return end
        local target_count = p['Target Count'] or p['Number of Targets'] or 6
        for x = 1, target_count do
            if p['Target %d ID':format(x)] == player.id then
                local key = 'Target %d Action 1 Knockback':format(x)
                if p[key] and p[key] ~= 0 then
                    p[key] = 0
                    return true, packets.build(p)
                end
                return
            end
        end
    end
end)