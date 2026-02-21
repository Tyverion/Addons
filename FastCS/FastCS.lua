_addon.name = "FastCS"
_addon.author = "Cairthenn; Modified by Ender"
_addon.version = "1.7"
_addon.commands = {"FastCS","FCS"}

--Requires:
packets = require('packets')
require("luau")

-- States
local player
local info

-- Settings:

defaults = {}
defaults.frame_rate_divisor = 1

settings = config.load(defaults)

-- FPS State
local FPS_STATE = {
    enabled = false, -- Boolean that indicates whether the Config speed-up is currently enabled
    zoning  = false, -- Boolean that indicates whether the player is zoning with the config speed-up enabled
}
local post_zone_boost_until = nil

local function disable()
    windower.send_command("config FrameRateDivisor ".. (settings.frame_rate_divisor or 1))
    FPS_STATE.enabled = false
end

local function enable()
    windower.send_command("config FrameRateDivisor 0")
    FPS_STATE.enabled = true
end

windower.register_event('outgoing chunk',function(id)
    if id == 0x5B then
        local p = packets.parse('outgoing', data)
        if info and not info.menu_open and not FPS_STATE.zoning and p._unknown1 ~= 16384 then
            enable()
        else
            return
        end
    end
    if id == 0x00D then -- Last packet sent when zoning out
        disable()
        FPS_STATE.zoning = true
    end
end)

windower.register_event('incoming chunk',function(id,o,m,is_inj)
    if id == 0x00A then
        FPS_STATE.zoning = false
        post_zone_boost_until = os.clock() + 1.5
        enable()
    end
end)

windower.register_event('load',function()
    disable()
end)

function status_change()
    player = windower.ffxi.get_player()
    info = windower.ffxi.get_info()
    if not player or not info then
        return
    end
    if FPS_STATE.zoning and FPS_STATE.enabled then
        disable()
        return
    end
    if post_zone_boost_until and os.clock() >= post_zone_boost_until then
        disable()
        post_zone_boost_until = nil
        return
    end
    if info.menu_open and FPS_STATE.enabled then
        disable()
    end
end
status_change:loop(.1)

-- Help text definition:
helptext = [[FastCS - Command List:
1. help - Displays this help menu.
2a. fps [30|60|uncapped]
2b. frameratedivisor [2|1|0]
	- Changes the default FPS after exiting a cutscene.
	- The prefix can be used interchangeably. For example, "fastcs fps 2" will set the default to 30 FPS.
3. exclusion [add|remove] <name>
    - Adds or removes a target from the exclusions list. Case insensitive.
 ]]
 
windower.register_event("addon command", function (command,...)
    command = command and command:lower() or "help"
    local args = T{...}:map(string.lower)
    
    if command == "help" then
        print(helptext)
    elseif command == "fps" or command == "frameratedivisor" then
        if #args == 0 then
            settings.frame_rate_divisor = (settings.frame_rate_divisor + 1) % 3
            local help_message = (settings.frame_rate_divisor == 0) and "Uncapped" or (settings.frame_rate_divisor == 1) and "60 FPS" or (settings.frame_rate_divisor == 2) and "30 FPS"
            notice("Default frame rate divisor is now: " .. settings.frame_rate_divisor .. " (" .. help_message .. ")" )
        elseif #args == 1 then
            if args[1] == "60" or args[1] == "1" then
                settings.frame_rate_divisor = 1
            elseif args[1] == "30" or args[1] == "2" then
                settings.frame_rate_divisor = 2
            elseif args[1] == "uncapped" or args[1] == "0" then
                settings.frame_rate_divisor = 0
            end
            local help_message = (settings.frame_rate_divisor == 0) and "Uncapped" or (settings.frame_rate_divisor == 1) and "60 FPS" or (settings.frame_rate_divisor == 2) and "30 FPS"
            notice("Default frame rate divisor is now: " .. settings.frame_rate_divisor .. " (" .. help_message .. ")" )
        else
            error("The command syntax was invalid.")
        end
        settings:save()
    end
end)

windower.register_event('unload',disable)
windower.register_event('logout',disable)
