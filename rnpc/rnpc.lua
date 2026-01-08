
_addon.command = 'rnpc'
require('luau')
packets = require('packets')

windower.register_event('ipc message', function(message)
    msg = message:split(' ')

    if msg[1] == 'reload' then
        packets.inject(packets.new('outgoing', 0x016, {
            ['Target Index'] = msg[2],
            ['_junk1'] = 0
        }))
    log('Attempted to reload NPC')
    end
end)

windower.register_event('addon command', function(...)
    local arg = L{...}:map(string.lower)
    local target = windower.ffxi.get_mob_by_target('t')

    log('Attempted to reload NPC')
    windower.send_ipc_message('reload %d':format(target.index))

end)