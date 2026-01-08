-- cooldowns_remote.lua
-- IPC-based multi-char cooldown tracking, driving Recast's purple bars

require('luau')
local socket         = require('socket')
local res            = require('resources')
local recast_manager = require('manager')

------------------------------------------------------------
-- Settings (reuses recast's config file from recast.lua)
------------------------------------------------------------
local settings = _G.recast_settings or error('recast_settings not initialized')

------------------------------------------------------------
-- Build tracked JA recast groups from settings.JAs
------------------------------------------------------------
TRACKED_JA_RECASTS = {}
JA_REC_NAME        = {}

local SP_OVERRIDE = {
    [0]   = 'SP I',
    [254] = 'SP II',
    [130] = 'SP II (GEO)',
    [131] = 'SP II (RUN)',
}

function rebuild_tracked_JAs()
    TRACKED_JA_RECASTS = {}
    JA_REC_NAME        = {}

    -- settings.JAs is a set of names: JA names or group names
    for name, enabled in pairs(settings.JAs) do
        if enabled then
            local lower_name = name:lower()
            local found = false

            -- 1) Prefer recast-group names (ability_recasts)
            if res.ability_recasts then
                for recast_id, rec in pairs(res.ability_recasts) do
                    if rec.name and rec.name:lower() == lower_name then
                        TRACKED_JA_RECASTS[recast_id] = true
                        JA_REC_NAME[recast_id]        = rec.name
                        found = true
                        break
                    end
                end
            end

            -- 2) Fall back to individual JA names
            if not found then
                for _, ja in pairs(res.job_abilities) do
                    if ja.en and ja.recast_id
                       and ja.en:lower() == lower_name then
                        TRACKED_JA_RECASTS[ja.recast_id] = true
                        -- if multiple JAs share this recast_id, first wins
                        if not JA_REC_NAME[ja.recast_id] then
                            JA_REC_NAME[ja.recast_id] = ja.en
                        end
                        break
                    end
                end
            end
        end
    end
end

-- Simplified SCH rules: 99 main SCH w/550 JP gift, or /SCH
local function get_stratagem_params_simple()
    local p = windower.ffxi.get_player()
    if not p then
        return nil
    end

    if p.main_job == 'SCH' then
        return 5, 33
    elseif p.sub_job == 'SCH' then
        return 3, 80
    end

    return nil
end

-- build once on load
rebuild_tracked_JAs()

------------------------------------------------------------
-- Stratagem charge helper (local only, for sending)
------------------------------------------------------------
local STRATAGEM_RECAST_ID = 231

local function get_stratagem_params()
    local p = windower.ffxi.get_player()
    if not p then
        return nil
    end

    local ml       = p.master_level or 0
    local main_lvl = (p.main_job_level or 0) + ml
    local sub_lvl  = p.sub_job_level or 0

    local max_charges, per = 0, 0

    if p.main_job == 'SCH' then
        if main_lvl >= 90 then
            max_charges = 5; per = 48
        elseif main_lvl >= 70 then
            max_charges = 4; per = 60
        elseif main_lvl >= 50 then
            max_charges = 3; per = 80
        elseif main_lvl >= 30 then
            max_charges = 2; per = 120
        elseif main_lvl >= 10 then
            max_charges = 1; per = 240
        end

        -- 550 JP gift → 33s per charge
        local jp_sch = (p.job_points and p.job_points.SCH and p.job_points.SCH.jp_spent) or 0
        if max_charges > 0 and jp_sch >= 550 then
            per = 33
        end

    elseif p.sub_job == 'SCH' then
        -- SCH subjob: up to 3 charges
        if sub_lvl >= 50 then
            max_charges = 3; per = 80
        elseif sub_lvl >= 30 then
            max_charges = 2; per = 120
        elseif sub_lvl >= 10 then
            max_charges = 1; per = 240
        end
    end

    if max_charges == 0 or per == 0 then
        return nil
    end

    return max_charges, per
end

-- Derive stratagem state (charges and time to next) from recast seconds.
-- ability_recasts[231] behaves like (missing_charges - 1) * per (time to next charge for SCH stratagems)
local function stratagem_state(seconds)
    local max_charges, per = get_stratagem_params_simple()
    if not max_charges or not per or per <= 0 then
        return nil
    end

    if not seconds or seconds <= 0 then
        return { max = max_charges, current = max_charges, missing = 0, next_in = 0, per = per }
    end

    -- Recast value is additive per missing charge (33, 66, 99, ...)
    local missing = math.min(max_charges, math.max(0, math.ceil(seconds / per)))
    local current = max_charges - missing
    if current < 0 then current = 0 end

    local next_in = seconds % per
    if next_in == 0 and seconds > 0 then
        next_in = per
    end

    return {
        max     = max_charges,
        missing = missing,
        current = current,
        next_in = next_in,
        per     = per,
    }
end

------------------------------------------------------------
-- Time encoding helpers (from original Cooldowns)
------------------------------------------------------------
local now = 0
local function gettime()
    now = math.floor(socket.gettime() * 10 + 0.5) / 10
    return now
end

local function skip_decimal_modulus(value, modulo)
    local int = math.floor(value)
    return int % modulo + value - int
end

local function encode_time(time)
    local base_time = now - skip_decimal_modulus(now, 3605)
    local encoded_time = time - base_time
    if encoded_time > 3605 then
        return skip_decimal_modulus(time, 3605) + 3605
    elseif encoded_time > 3600 or encoded_time < 5 then
        return skip_decimal_modulus(time, 3605) * -1
    else
        return encoded_time
    end
end

local function decode_time(encoded_time)
    local seconds_from_base_time = skip_decimal_modulus(now, 3605)
    local base_time = now - seconds_from_base_time
    if encoded_time < 0 then
        if seconds_from_base_time < 5 then
            if encoded_time > -5 then
                return base_time - encoded_time
            else
                return base_time - 3605 - encoded_time
            end
        elseif seconds_from_base_time > 3600 then
            if encoded_time > -5 then
                return base_time + 3605 - encoded_time
            else
                return base_time - encoded_time
            end
        else
            return base_time + encoded_time
        end
    else
        return base_time + encoded_time
    end
end

local function convert_to_timestamps(data)
    for index, value in pairs(data) do
        data[index] = encode_time(now + value)
    end
    return data
end

local function decode_timestamps(data)
    for index, value in pairs(data) do
        data[index] = decode_time(value)
    end
    return data
end

------------------------------------------------------------
-- IPC encode/decode
------------------------------------------------------------
local function encode(value)
    local typename = type(value)
    if typename == "string" then
        return '"'..value..'"'
    elseif typename == "table" then
        value = T(value)
        return '{' .. value:keyset():map(function(key)
            return '[' .. encode(key) .. ']=' .. encode(value[key])
        end):concat(',') .. '}'
    else
        return tostring(value)
    end
end

local function decode(value)
    local chunk, err = loadstring('return ' .. value .. ';')
    if not chunk then
        -- malformed payload; ignore
        return nil
    end

    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' then
        return nil
    end

    gettime()
    if data.abilities then
        data.abilities = decode_timestamps(data.abilities)
    end
    if data.spells then
        data.spells = decode_timestamps(data.spells)
    end
    -- data.charges is plain table data; no decode needed
    return data
end

------------------------------------------------------------
-- State: cooldown timestamps + total caches
------------------------------------------------------------
-- cooldowns[name] = {
--   abilities = { [recast_id] = ready_time },
--   charges   = { [recast_id] = { max = N, current = C } }  -- OPTIONAL
-- }
local cooldowns = {}
local totals    = {}   -- name -> { [recast_id] = total_seconds }

------------------------------------------------------------
-- Send our own cooldowns to others
------------------------------------------------------------
local function send_cooldown_update()
    gettime()

    local abilities_raw = windower.ffxi.get_ability_recasts() or {}
    local player        = windower.ffxi.get_player()
    if not player then return end

    --------------------------------------------------------
    -- Build optional charges table (e.g. for Stratagems)
    --------------------------------------------------------
    local charges = {}

    do
        local seconds = abilities_raw[STRATAGEM_RECAST_ID]
        local state   = stratagem_state(seconds)

        if state then
            charges[STRATAGEM_RECAST_ID] = {
                max     = state.max,
                current = state.current,
                per     = state.per,
            }
        end
    end

    -- convert ability recasts to timestamps for IPC
    local abilities = convert_to_timestamps(abilities_raw)

    local data = {
        name      = player.name,
        abilities = abilities,
        charges   = charges, -- may be empty
    }

    local message = encode(data)
    windower.send_ipc_message(message)
end

local function schedule_update()
    coroutine.schedule(send_cooldown_update, 0.2)
end

function request_cooldown_updates()
    local player = windower.ffxi.get_player()
    if not player then return end

    local data = {
        name    = player.name,
        request = 'cooldowns',
    }

    local message = encode(data)
    windower.send_ipc_message(message)
end

------------------------------------------------------------
-- Drive cooldown bars from stored timestamps
------------------------------------------------------------
local function refresh_remote_bars()
    gettime()

    for name, t in pairs(cooldowns) do
        if settings.characters_to_watch[name] or next(settings.characters_to_watch) == nil then
            if t.abilities then
                totals[name] = totals[name] or {}
                local tcache  = totals[name]
                local charges = t.charges or {}   -- optional per-recast charge info

                for recast_id, ready_time in pairs(t.abilities) do
                    if TRACKED_JA_RECASTS[recast_id] then
                        local base_name = SP_OVERRIDE[recast_id] or JA_REC_NAME[recast_id] or ('Recast %d'):format(recast_id)
                        local rem_raw   = ready_time - now
                        local rem       = rem_raw

                        local info      = charges[recast_id]
                        local abil_name = base_name

                        -- If we have per/max, derive current charges so the label counts back up
                        if info and info.max and info.per then
                            local derived_current
                            if rem_raw <= 0 then
                                derived_current = info.max
                            else
                                local missing = math.min(info.max, math.max(0, math.ceil(rem_raw / info.per)))
                                derived_current = info.max - missing
                                if derived_current < 0 then derived_current = 0 end
                            end
                            abil_name = ('%s [%d]'):format(base_name, derived_current)

                            if derived_current >= info.max then
                                rem = 0
                            else
                                -- For display, show time until next charge (per-chunk) instead of total to full
                                rem = rem_raw % info.per
                                if rem == 0 and rem_raw > 0 then
                                    rem = info.per
                                end
                            end
                        elseif info and info.current ~= nil then
                            -- Fallback to static value if per/max not available
                            abil_name = ('%s [%d]'):format(base_name, info.current)
                        end

                        if rem > 0 or not settings.hide_below_zero then
                            if rem > 0 then
                                if not tcache[recast_id] or rem > tcache[recast_id] + 0.1 then
                                    tcache[recast_id] = rem
                                end
                                local total = tcache[recast_id]
                                if recast_id == STRATAGEM_RECAST_ID and info and info.per then
                                    total = info.per
                                end
                                recast_manager:set_remote_cooldown(
                                    name, abil_name, 'ja', rem, total, recast_id
                                )
                            else
                                recast_manager:set_remote_cooldown(
                                    name, abil_name, 'ja', 0, tcache[recast_id] or 0, recast_id
                                )
                                tcache[recast_id] = nil
                            end
                        else
                            recast_manager:set_remote_cooldown(
                                name, abil_name, 'ja', 0, tcache[recast_id] or 0, recast_id
                            )
                            tcache[recast_id] = nil
                        end
                    end
                end
            end
        end
    end
end



-- run 10x/sec for smooth-ish updates
refresh_remote_bars:loop(0.1)

------------------------------------------------------------
-- Events (mostly copied from original Cooldowns)
------------------------------------------------------------
windower.register_event('action', function(action)
    local player = windower.ffxi.get_player()
    if not player then return end

    if action.actor_id == player.id then
        -- any action could change JAs (original only checked category 4)
        schedule_update()
    end
end)

windower.register_event('incoming chunk', function(id)
    if id == 0x119 then
        schedule_update()
    end
end)

windower.register_event('ipc message', function(msg)
    local data = decode(msg)
    if not data then return end

    -- job change broadcast → nuke that character's timers
    if data.jobchange and data.name then
        cooldowns[data.name] = nil
        totals[data.name]    = nil
        recast_manager:clear_remote_for(data.name)
        return
    end

    -- someone requested current cooldowns → reply with our snapshot
    if data.request == 'cooldowns' then
        -- small delay to avoid stampede if many respond
        coroutine.schedule(send_cooldown_update, 0.2)
        return
    end

    if data.name then
        cooldowns[data.name] = cooldowns[data.name] or {}
        local entry = cooldowns[data.name]
        entry.abilities = entry.abilities or T{}

        if data.abilities then
            for recast_id in pairs(TRACKED_JA_RECASTS) do
                if data.abilities[recast_id] then
                    entry.abilities[recast_id] = data.abilities[recast_id]
                end
            end
        end

        -- optional charge info (e.g. Stratagems)
        if data.charges then
            entry.charges = entry.charges or T{}
            for recast_id, info in pairs(data.charges) do
                entry.charges[recast_id] = info
            end
        end

        refresh_remote_bars()
    end
end)

windower.register_event('login', 'load', function()
    -- send our own snapshot
    send_cooldown_update()
    -- ask everyone else to send theirs
    coroutine.schedule(request_cooldown_updates, 0.5)
end)

windower.register_event('job change', function()
    local player = windower.ffxi.get_player()
    if not player then return end

    -- clear our own cached cooldowns
    cooldowns[player.name] = nil
    totals[player.name]    = nil

    -- tell everyone else we changed jobs
    local data = { name = player.name, jobchange = true }
    windower.send_ipc_message(encode(data))
    coroutine.schedule(send_cooldown_update, 1.0)
end)
