-- recast.lua
_addon.name    = 'recast'
_addon.author  = 'Ender'
_addon.version = '2025.12.06'
_addon.command = 'recast'



local config         = require('config')
local recast_manager = require('manager')
require('luau')

----------------------------------------------------------------
-- Settings
----------------------------------------------------------------
local defaults = {
    recast_mode    = 'down',
    recast_x       = 202,
    recast_y       = 450,
    BAR_WIDTH      = 150,
    BAR_HEIGHT     = 12,
    remote_bound   = false,   -- true = share column, false = separate column
    remote_offsetX = 180,     -- default gap between stacks
    remote_x       = 34,
    remote_y       = 297,
    interval            = 0.1,
    hide_below_zero     = false,
    characters_to_watch = S{},
    JAs = S{
        "SP Ability","SP Ability II", 
        "Nightingale","Troubadour","Marcato","Soul Voice","Clarion Call",
        "Entrust","Blaze of Glory","Dematerialize","Ecliptic Attrition","Widened Compass","Bolster",
        "Blood Pact: Rage",
        "Stratagems"
    },
    remote_colors = {
        Default = { r = 190, g = 120, b = 255 }, -- fallback (current purple)
        Yuzzie  = { r = 120, g = 220, b = 255 }, -- light blue
        Kyohyi  = { r = 120, g = 255, b = 180 }, -- teal/green
    },
}

local settings = config.load(defaults)
_G.recast_settings = settings

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function normalize_name(name)
    if type(name) ~= 'string' then return nil end
    name = name:match('^%s*(.-)%s*$') or name
    if name == '' then return nil end
    name = name:lower()
    return name:sub(1,1):upper() .. name:sub(2)
end

local function normalize_watch_list(tbl)
    if type(tbl) ~= 'table' then return S{} end

    -- Collect normalized names into an array, then build a Set from that array
    local names = {}
    for k, v in pairs(tbl) do
        local name
        if type(k) == 'number' or (type(k) == 'string' and k:match('^%d+$')) then
            name = v                -- array-style: value is the name
        else
            name = k                -- map-style: key is the name
        end
        if v then
            name = normalize_name(name)
            if name then
                local lname = name:lower()
                if lname ~= 'true' and lname ~= 'false' then
                    names[#names + 1] = name
                end
            end
        end
    end
    return S(names)
end

local function normalize_ja_set(tbl)
    if type(tbl) ~= 'table' then return S{} end

    local names = {}
    for k, v in pairs(tbl) do
        local name
        if type(k) == 'number' or (type(k) == 'string' and k:match('^%d+$')) then
            name = v
        else
            name = k
        end
        if v then
            name = normalize_name(name)
            if name then
                local lname = name:lower()
                if lname ~= 'true' and lname ~= 'false' then
                    names[#names + 1] = name
                end
            end
        end
    end
    return S(names)
end

local function normalize_settings()
    settings.characters_to_watch = normalize_watch_list(settings.characters_to_watch)
    settings.JAs                 = normalize_ja_set(settings.JAs)
end

normalize_settings()

-- keep normalized on config reloads (login/load)
config.register(settings, function()
    normalize_settings()
end)
require('cooldowns_remote')

-- push initial settings into manager
recast_manager.base_x         = settings.recast_x
recast_manager.base_y         = settings.recast_y
recast_manager.bar_width      = settings.BAR_WIDTH
recast_manager.bar_height     = settings.BAR_HEIGHT
recast_manager.remote_bound   = settings.remote_bound
recast_manager.remote_offsetX = settings.remote_offsetX
recast_manager.remote_x       = settings.remote_x
recast_manager.remote_y       = settings.remote_y
recast_manager:set_remote_colors(settings.remote_colors)
recast_manager:set_mode(settings.recast_mode)

----------------------------------------------------------------
-- Persist anchors when you finish dragging (mouse up)
----------------------------------------------------------------
windower.register_event('mouse', function(type)
    -- type 2 = left button release; avoid spamming saves otherwise
    if type ~= 2 then return end

    local x, y   = recast_manager:get_anchor()
    local rx, ry = recast_manager:get_remote_anchor()

    if x == settings.recast_x and y == settings.recast_y
       and rx == settings.remote_x and ry == settings.remote_y then
        return
    end

    -- pull latest to avoid overwriting another client, then save globally
    config.reload(settings)
    settings.recast_x = x
    settings.recast_y = y
    settings.remote_x = rx
    settings.remote_y = ry
    config.save(settings, 'all')
end)

----------------------------------------------------------------
-- Persist anchor on unload
----------------------------------------------------------------
windower.register_event('unload', function()
    -- Pull latest settings from disk so we don't overwrite another character's changes
    config.reload(settings)

    local x, y = recast_manager:get_anchor()
    settings.recast_x = x
    settings.recast_y = y

    local rx, ry = recast_manager:get_remote_anchor()
    settings.remote_x = rx
    settings.remote_y = ry

    config.save(settings, 'all')
end)

----------------------------------------------------------------
-- Addon commands
----------------------------------------------------------------
--  //recast style up|down
--  //recast sizeh small|mid|large
--  //recast sizew <80-400>
local function print_help()
    windower.add_to_chat(207, '[Recast] Commands:')
    windower.add_to_chat(207, '//recast help                          - show this help')
    windower.add_to_chat(207, '//recast style up|down                 - stack direction')
    windower.add_to_chat(207, '//recast sizeh small|mid|large         - bar height presets')
    windower.add_to_chat(207, '//recast sizew <80-400>                - bar width')
    windower.add_to_chat(207, '//recast stacked on|off                - share local/remote column')
    windower.add_to_chat(207, '//recast watch add|remove <name>       - track another character')
    windower.add_to_chat(207, '//recast watch list                    - list watched characters')
    windower.add_to_chat(207, '//recast ja add|remove <name>          - track/untrack a JA group')
    windower.add_to_chat(207, '//recast ja list                       - list tracked JA groups')
    windower.add_to_chat(207, '//recast color list                    - show remote colors')
    windower.add_to_chat(207, '//recast color <name|default> r g b    - set remote bar color')
    windower.add_to_chat(207, '//recast profile blacklist|whitelist   - save per-job filter profile')
end

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or ''):lower()
    local args = {...}
    local arg  = (args[1] or ''):lower()

    if cmd == '' or cmd == 'help' then
        print_help()
        return
    end

    -- //recast style up|down
    if cmd == 'style' then
        if arg == 'up' or arg == 'down' then
            settings.recast_mode = arg
            config.save(settings, 'all')
            recast_manager:set_mode(arg)
            windower.add_to_chat(207, ('[Recast] Mode set to: %s'):format(arg))
        else
            windower.add_to_chat(207, '[Recast] Usage: //recast style up|down')
        end

    elseif cmd == 'stacked' then
        if arg == 'on' or arg == 'off' then
            local bound = (arg == 'on')

            -- save config
            settings.remote_bound = bound
            config.save(settings, 'all')

            -- apply immediately to manager
            recast_manager.remote_bound = bound

            -- if we’re going back to stacked, forget the separate remote anchor
            if bound then
                recast_manager.remote_x = nil
                recast_manager.remote_y = nil
            end

            -- expose this in manager.lua:
            -- function manager:reflow() reflow() end
            recast_manager:reflow()

            windower.add_to_chat(207,
                ('[Recast] Stacked set to: %s'):format(bound and 'on' or 'off'))
        else
            windower.add_to_chat(207,
                '[Recast] Usage: //recast stacked on|off')
        end

    elseif cmd == 'watch' then
        if type(settings.characters_to_watch) ~= 'table' then
            settings.characters_to_watch = S{}
        else
            settings.characters_to_watch = normalize_watch_list(settings.characters_to_watch)
        end

        local sub  = (args[1] or ''):lower()      -- add/remove/list
        local name = normalize_name(args[2])      -- normalize case

        if sub == 'add' and name then
            settings.characters_to_watch = settings.characters_to_watch or S{}
            settings.characters_to_watch[name] = true
            config.save(settings, 'all')
            windower.add_to_chat(207, ('[Recast] Now watching: %s'):format(name))

        elseif sub == 'remove' and name then
            settings.characters_to_watch = settings.characters_to_watch or S{}
            settings.characters_to_watch[name] = nil
            config.save(settings, 'all')

            if recast_manager.clear_remote_for then
                recast_manager:clear_remote_for(name)
            end

            windower.add_to_chat(207, ('[Recast] No longer watching: %s'):format(name))

        elseif sub == 'list' then
            windower.add_to_chat(207, '[Recast] Currently watching:')
            local empty = true
            for cname in pairs(settings.characters_to_watch) do
                empty = false
                windower.add_to_chat(207, '  - '..cname)
            end
            if empty then
                windower.add_to_chat(207, '  (none)')
            end 

        else
            windower.add_to_chat(207, '[Recast] Usage:')
            windower.add_to_chat(207, '  //recast watch add <name>')
            windower.add_to_chat(207, '  //recast watch remove <name>')
            windower.add_to_chat(207, '  //recast watch list')
        end

    elseif cmd == 'ja' then
        if type(settings.JAs) ~= 'table' then
            settings.JAs = S{}
        else
            settings.JAs = normalize_ja_set(settings.JAs)
        end

        local sub  = (args[1] or ''):lower()      -- add/remove/list
        local ja   = normalize_name(args[2])

        if sub == 'add' and ja then
            settings.JAs[ja] = true
            config.save(settings, 'all')

            -- rebuild the tracked JA recast list in cooldowns_remote
            if rebuild_tracked_JAs then
                rebuild_tracked_JAs()
            end

            -- clear remote bars so they repopulate under the new filter
            for cname in pairs(settings.characters_to_watch) do
                recast_manager:clear_remote_for(cname)
            end

            windower.add_to_chat(207, ('[Recast] Now watching: %s'):format(ja))

        elseif sub == 'remove' and ja then
            settings.JAs[ja] = nil
            config.save(settings, 'all')

            if rebuild_tracked_JAs then
                rebuild_tracked_JAs()
            end

            for cname in pairs(settings.characters_to_watch) do
                recast_manager:clear_remote_for(cname)
            end

            windower.add_to_chat(207, ('[Recast] Not watching: %s'):format(ja))

        elseif sub == 'list' then
            windower.add_to_chat(207, '[Recast] Currently watching:')
            table.vprint(settings.JAs)

        else
            windower.add_to_chat(207, '[Recast] Usage:')
            windower.add_to_chat(207, '  //recast ja add <name>')
            windower.add_to_chat(207, '  //recast ja remove <name>')
            windower.add_to_chat(207, '  //recast ja list')
        end

    elseif cmd == 'color' then
        if type(settings.remote_colors) ~= 'table' then
            settings.remote_colors = {}
        end

        local sub = (args[1] or ''):lower()

        -- list
        if sub == 'list' then
            windower.add_to_chat(207, '[Recast] Remote colors:')
            for name, c in pairs(settings.remote_colors) do
                windower.add_to_chat(207,
                    ('  %s = (%d,%d,%d)'):format(name,
                        c.r or 0, c.g or 0, c.b or 0))
            end
            return
        end

        -- set: //recast color <name|default> <r> <g> <b>
        local name = args[1]
        local r    = tonumber(args[2])
        local g    = tonumber(args[3])
        local b    = tonumber(args[4])

        if not name or not r or not g or not b
        or r < 0 or r > 255
        or g < 0 or g > 255
        or b < 0 or b > 255 then

            windower.add_to_chat(207, '[Recast] Usage:')
            windower.add_to_chat(207, '  //recast color list')
            windower.add_to_chat(207, '  //recast color <name|default> <r> <g> <b>')
            return
        end

        if name:lower() == 'default' then
            name = 'Default'
        else
            name = normalize_name(name)
        end

        settings.remote_colors[name] = { r = r, g = g, b = b, a = 255 }
        config.save(settings, 'all')
        recast_manager:set_remote_colors(settings.remote_colors)

        windower.add_to_chat(207,
            ('[Recast] Remote color for %s set to (%d,%d,%d)')
                :format(name, r, g, b))

    -- //recast sizeh small|mid|large
    elseif cmd == 'sizeh' then
        local h
        if arg == 'small' then
            h = 12
        elseif arg == 'mid' or arg == 'medium' then
            h = 14
        elseif arg == 'large' then
            h = 16
        end

        if h then
            settings.BAR_HEIGHT = h
            config.save(settings, 'all')
            recast_manager:apply_size(settings.BAR_WIDTH, settings.BAR_HEIGHT)
            windower.add_to_chat(207, ('[Recast] Bar height set to %d'):format(h))
        else
            windower.add_to_chat(207, '[Recast] Usage: //recast sizeh small|mid|large')
        end

    -- //recast sizew <number>
    elseif cmd == 'sizew' then
        local w = tonumber(arg)
        if w and w >= 80 and w <= 400 then
            settings.BAR_WIDTH = w
            config.save(settings, 'all')

            -- resize live bars and remember width for future bars
            recast_manager:set_width(w)

            windower.add_to_chat(207, ('[Recast] Bar width set to %d'):format(w))
        else
            windower.add_to_chat(207, '[Recast] Usage: //recast sizew <80-400>')
        end

    elseif cmd == 'profile' then
        if arg ~= 'blacklist' and arg ~= 'whitelist' then
            windower.add_to_chat(207, '[Recast] Usage: //recast profile blacklist|whitelist')
            return
        end

        local p    = windower.ffxi.get_player()
        local job  = p and p.main_job and p.main_job:upper() or 'DEFAULT'
        local path = windower.addon_path .. 'data/profiles/' .. job .. '.lua'

        -- load existing profile table (if any)
        local prof = {
            mode        = arg,
            hide_spells = {},
            hide_ja     = {},
            only_spells = {},
            only_ja     = {},
        }

        local chunk = loadfile(path)
        if chunk then
            local ok, t = pcall(chunk)
            if ok and type(t) == 'table' then
                prof.hide_spells = t.hide_spells or {}
                prof.hide_ja     = t.hide_ja     or {}
                prof.only_spells = t.only_spells or {}
                prof.only_ja     = t.only_ja     or {}
            end
        end
        prof.mode = arg

        -- write back to file
        local f = io.open(path, 'w')
        if not f then
            windower.add_to_chat(207, ('[Recast] Failed to write profile: %s'):format(path))
            return
        end

        local function write_table(name, tbl)
            f:write('    ', name, ' = {\n')
            for k, v in pairs(tbl) do
                if v then
                    -- escape single quotes
                    k = tostring(k):gsub("'", "\\'")
                    f:write(("        ['%s'] = true,\n"):format(k))
                end
            end
            f:write('    },\n')
        end

        f:write('return {\n')
        f:write(("    mode = '%s',\n"):format(arg))
        write_table('hide_spells', prof.hide_spells)
        write_table('hide_ja',     prof.hide_ja)
        write_table('only_spells', prof.only_spells)
        write_table('only_ja',     prof.only_ja)
        f:write('}\n')
        f:close()

        recast_manager:reload_profile()
        windower.add_to_chat(207,
            ('[Recast] %s profile set to %s mode'):format(job, arg))

    else
        print_help()
    end
end)
