-- manager.lua
local recast_bar = require('bar')
local packets    = require('packets')
local res        = require('resources')

local manager = {
    bars       = {},
    order      = {},
    base_x     = 400,
    base_y     = 300,
    spacing    = 14,
    mode       = 'down',
    drag       = nil,
    bar_width  = 200,
    bar_height = 14,

    remote_bound   = true,   -- overridden by recast.lua
    remote_offsetX = 180,

    remote_x       = nil,     -- separate anchor for remote column
    remote_y       = nil,
    custom_x       = nil,
    custom_y       = nil,
    buff_x         = nil,
    buff_y         = nil,
    show_buffs     = true,
    last_buff_ids  = nil,
    last_buff_times = nil,

    remote_colors  = {},  -- name -> {r,g,b,a}
}

local STRATAGEM_RECAST_ID = 231
local DIG_ACTION_CATEGORY = 17
local DIG_BAR_KEY         = 'CUSTOM:dig'
local DIG_BAR_LABEL       = 'Chocobo Dig'
local DIG_RECAST_SECONDS  = 15
local BUFF_PACKET_ORDER   = 0x09
local BUFF_BAR_PREFIX     = 'BUFF:'
local BUFF_TIME_BASE      = 1009810800
local BUFF_TIME_ROLLOVER  = 0x100000000 / 60

local CHARGE_RECASTS = S{
    231, -- Stratagems
    -- 193, -- Quick Draw
    -- 102, -- Ready / Sic
}
local CHARGE_LABELS = {
    [231] = 'Stratagems',
}

-- Track SCH charge state locally
local strat_state = { max_charges = 0, charges = nil, last_seconds = nil }
local last_resync = 0

----------------------------------------------------------------
-- Category Helpers
----------------------------------------------------------------
local function get_stratagem_params()
    local p = windower.ffxi.get_player()
    if not p then
        return nil
    end

    if p.main_job == 'SCH' then
        return 5, 33
    end

    if p.sub_job == 'SCH' then
        return 3, 80
    end

    return nil
end

-- Derive stratagem state (charges and time to next) from recast seconds.
-- ability_recasts[231] is time to next charge; we track charges statefully.
local function stratagem_state(seconds)
    local max_charges, per = get_stratagem_params()
    if not max_charges or not per or per <= 0 then
        return nil
    end

    if not seconds or seconds <= 0 then
        return { max = max_charges, current = max_charges, missing = 0, next_in = 0, per = per }
    end

    -- ability_recasts[231] is additive per missing charge (33, 66, 99, ...)
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

local function get_recast_group_label(recast_id)
    local sp_override = {
        [0]   = 'SP Ability I',
        [254] = 'SP Ability II',
        [130] = 'SP Ability II (GEO)',
        [131] = 'SP Ability II (RUN)',
    }
    if sp_override[recast_id] then
        return sp_override[recast_id]
    end

    -- Use ability_recasts first
    local r = res.ability_recasts[recast_id]
    if r and r.name and r.name ~= '' then
        return r.name
    end

    -- Fallback (should rarely ever be needed)
    for _, ja in pairs(res.job_abilities) do
        if ja.recast_id == recast_id and ja.en then
            return ja.en
        end
    end

    return nil
end

local function should_skip_recast_id(recast_id, abil_recasts)
    -- Rune Enchantment (92) duplicates rune recast group (10)
    if recast_id == 92 then
        local r = abil_recasts or windower.ffxi.get_ability_recasts() or {}
        if r[10] then
            return true
        end
    end
    return false
end


----------------------------------------------------------------
-- Profiles: hide certain spells/JAs per job
----------------------------------------------------------------
local profile = {
    mode        = 'blacklist', -- or 'whitelist'
    hide_spells = {},
    hide_ja     = {},
    only_spells = {},
    only_ja     = {},
}
local buff_filters = {}

local function buff_allowed(name)
    if not name or name == '' then
        return false
    end

    return buff_filters[name:lower()] ~= true
end

local function load_profile(job)
    job = job or 'DEFAULT'
    local path  = string.format('%sdata/profiles/%s.lua', windower.addon_path, job)
    local chunk = loadfile(path)

    if chunk then
        local ok, prof = pcall(chunk)
        if ok and type(prof) == 'table' then
            profile = {
                mode        = prof.mode or 'blacklist',
                hide_spells = prof.hide_spells or {},
                hide_ja     = prof.hide_ja     or {},
                only_spells = prof.only_spells or {},
                only_ja     = prof.only_ja     or {},
            }
            windower.add_to_chat(207, ('[Recast] Loaded profile: %s (%s)'):format(job, profile.mode))
            return
        end
    end

    profile = {
        mode        = 'blacklist',
        hide_spells = {},
        hide_ja     = {},
        only_spells = {},
        only_ja     = {},
    }
    windower.add_to_chat(207, ('[Recast] Using default blacklist profile for %s'):format(job))
end

function manager:reload_profile()
    local p = windower.ffxi.get_player()
    load_profile(p and p.main_job)
    -- rebuild bars under new mode
    for _, data in pairs(self.bars) do
        if data.bar then data.bar:hide() end
    end
    self.bars  = {}
    self.order = {}
    self:initialize_bars()
end


----------------------------------------------------------------
-- Layout helpers
----------------------------------------------------------------
-- Build grouped order: purple (remote) → blue (JA) → green (spells)
local function build_grouped_order()
    local buffs, customs, remotes, jas, spells = {}, {}, {}, {}, {}

    for _, key in ipairs(manager.order) do
        local data = manager.bars[key]
        if data then
            if data.source == 'buff' then
                buffs[#buffs + 1] = key
            elseif data.source == 'custom' then
                customs[#customs + 1] = key
            elseif data.source == 'remote' then
                remotes[#remotes + 1] = key
            elseif data.kind == 'ja' then
                jas[#jas + 1] = key
            elseif data.kind == 'spell' then
                spells[#spells + 1] = key
            end
        end
    end

    table.sort(buffs, function(a, b)
        local da = manager.bars[a]
        local db = manager.bars[b]
        local ra = da and ((da.expires or 0) - os.time()) or 0
        local rb = db and ((db.expires or 0) - os.time()) or 0
        if ra == rb then
            return (da and da.name or '') < (db and db.name or '')
        end
        return ra < rb
    end)

    local ordered = {}
    for _, k in ipairs(buffs)   do ordered[#ordered + 1] = k end
    for _, k in ipairs(customs) do ordered[#ordered + 1] = k end
    for _, k in ipairs(remotes) do ordered[#ordered + 1] = k end
    for _, k in ipairs(jas)     do ordered[#ordered + 1] = k end
    for _, k in ipairs(spells)  do ordered[#ordered + 1] = k end

    return ordered
end

local function get_default_buff_anchor()
    local gap = manager.remote_offsetX or (manager.bar_width + 20)
    return math.max(0, manager.base_x - (gap * 2)), manager.base_y
end

local function get_default_custom_anchor()
    local gap = manager.remote_offsetX or (manager.bar_width + 20)
    return math.max(0, manager.base_x - gap), manager.base_y
end

function manager:reflow()
    -- rebuild grouped order every time
    manager.order = build_grouped_order()

    local bx, by = manager.buff_x, manager.buff_y
    if not bx or not by then
        bx, by = get_default_buff_anchor()
    end

    local cx, cy = manager.custom_x, manager.custom_y
    if not cx or not cy then
        cx, cy = get_default_custom_anchor()
    end

    if manager.remote_bound then
        -- buff/custom bars in their own columns; everything else in the local stack
        local idx = 1
        local idx_buff = 1
        local idx_custom = 1
        for _, key in ipairs(manager.order) do
            local data = manager.bars[key]
            if data and data.bar then
                if data.source == 'buff' then
                    local y = by + (idx_buff - 1) * manager.spacing
                    data.bar:set_position(bx, y)
                    idx_buff = idx_buff + 1
                elseif data.source == 'custom' then
                    local y = cy + (idx_custom - 1) * manager.spacing
                    data.bar:set_position(cx, y)
                    idx_custom = idx_custom + 1
                else
                    local y = manager.base_y + (idx - 1) * manager.spacing
                    data.bar:set_position(manager.base_x, y)
                    idx = idx + 1
                end
            end
        end
    else
        -- split: buff far left, custom left, local center, remote right
        if not manager.remote_x then
            manager.remote_x = manager.base_x + (manager.remote_offsetX or (manager.bar_width + 20))
        end
        if not manager.remote_y then
            manager.remote_y = manager.base_y
        end

        local idx_buff   = 1
        local idx_custom = 1
        local idx_local  = 1
        local idx_remote = 1
        local lx, ly     = manager.base_x,   manager.base_y
        local rx, ry     = manager.remote_x, manager.remote_y

        for _, key in ipairs(manager.order) do
            local data = manager.bars[key]
            if data and data.bar then
                if data.source == 'buff' then
                    local y = by + (idx_buff - 1) * manager.spacing
                    data.bar:set_position(bx, y)
                    idx_buff = idx_buff + 1
                elseif data.source == 'custom' then
                    local y = cy + (idx_custom - 1) * manager.spacing
                    data.bar:set_position(cx, y)
                    idx_custom = idx_custom + 1
                elseif data.source == 'remote' then
                    local y = ry + (idx_remote - 1) * manager.spacing
                    data.bar:set_position(rx, y)
                    idx_remote = idx_remote + 1
                else
                    local y = ly + (idx_local - 1) * manager.spacing
                    data.bar:set_position(lx, y)
                    idx_local = idx_local + 1
                end
            end
        end
    end
end

local function apply_color_theme(bar, kind)
    if kind == 'spell' then
        -- green-ish
        windower.prim.set_color(bar.fg_prim, 255,  80, 255,  80)
    elseif kind == 'buff' then
        -- amber
        windower.prim.set_color(bar.fg_prim, 255, 255, 165,  80)
    elseif kind == 'custom' then
        -- yellow
        windower.prim.set_color(bar.fg_prim, 255, 255, 215,  80)
    else
        -- blue-ish
        windower.prim.set_color(bar.fg_prim, 255,  90, 170, 255)
    end
end

local function create_bar(name, key, kind, id, recast_id, total)
    if manager.bars[key] then
        return
    end

    -- profile filters (unchanged)
    if profile.mode == 'blacklist' then
        if kind == 'spell' and profile.hide_spells[name] then return end
        if kind == 'ja'    and profile.hide_ja[name]     then return end
    else
        if kind == 'spell' and not profile.only_spells[name] then return end
        if kind == 'ja'    and not profile.only_ja[name]     then return end
    end

    local x = manager.base_x
    local y = manager.base_y + (#manager.order) * manager.spacing

    local bar = recast_bar.new_recast_bar(x, y, manager.bar_width, manager.bar_height, manager.mode)
    bar:set_name(name)
    apply_color_theme(bar, kind)

    manager.bars[key] = {
        name      = name,
        kind      = kind,      -- 'ja' or 'spell'
        source    = 'local',
        id        = id,        -- spell.id or abil.id
        recast_id = recast_id, -- recast group / spell recast_id
        total     = total or 0,
        bar       = bar,
        started   = nil,
    }
    table.insert(manager.order, key)
    manager:reflow()
end

local function create_custom_bar(name, key, total)
    if manager.bars[key] then
        local data = manager.bars[key]
        data.total   = total
        data.started = os.clock()
        data.expires = data.started + total
        if data.bar then
            data.bar:set_name(name)
        end
        return
    end

    local x = manager.base_x
    local y = manager.base_y + (#manager.order) * manager.spacing

    local bar = recast_bar.new_recast_bar(x, y, manager.bar_width, manager.bar_height, manager.mode)
    bar:set_name(name)
    apply_color_theme(bar, 'custom')

    manager.bars[key] = {
        name    = name,
        kind    = 'custom',
        source  = 'custom',
        total   = total,
        bar     = bar,
        started = os.clock(),
        expires = os.clock() + total,
    }
    table.insert(manager.order, key)
    manager:reflow()
end

local function remove_bar(key)
    local data = manager.bars[key]
    if not data then return end

    if data.bar then
        if data.bar.destroy then
            data.bar:destroy()
        else
            data.bar:hide()
        end
    end
    manager.bars[key] = nil

    for i, k in ipairs(manager.order) do
        if k == key then
            table.remove(manager.order, i)
            break
        end
    end

    manager:reflow()
end

function manager:clear_remote_for(owner)
    if not owner then return end
    local owner_l = owner:lower()

    -- remove remote bars owned by this character
    for key, data in pairs(self.bars) do
        if data.source == 'remote'
           and data.owner
           and data.owner:lower() == owner_l then
            if data.bar then
                if data.bar.destroy then
                    data.bar:destroy()
                else
                    data.bar:hide()
                end
            end
            self.bars[key] = nil
        end
    end

    -- rebuild order and reflow the stack
    local new_order = {}
    for _, key in ipairs(self.order) do
        if self.bars[key] then
            table.insert(new_order, key)
        end
    end
    self.order = new_order

    manager:reflow()
end

function manager:start_custom_bar(name, total, key)
    if not name or name == '' then
        return false
    end

    total = tonumber(total)
    if not total or total <= 0 then
        return false
    end

    key = key or ('CUSTOM:%s'):format(name:lower())
    create_custom_bar(name, key, total)
    return true
end

local function truncate(str, n)
    if not str then return '' end
    if #str <= n then return str end
    return str:sub(1, n)
end

----------------------------------------------------------------
-- Public: mode + size + anchor
----------------------------------------------------------------
function manager:set_mode(mode)
    mode = (mode or ''):lower()
    if mode ~= 'up' and mode ~= 'down' then return end
    self.mode = mode
    for _, data in pairs(self.bars) do
        if data.bar and data.bar.set_mode then
            data.bar:set_mode(mode)
        end
    end
end

function manager:set_width(w)
    if not w or w <= 0 then return end

    self.bar_width = w

    -- resize existing bars if the bar object supports it
    for _, data in pairs(self.bars) do
        if data.bar and data.bar.set_width then
            data.bar:set_width(w)
        end
    end
end

function manager:apply_size(w, h)
    if w then self.bar_width  = w end
    if h then self.bar_height = h end

    -- destroy old bars
    for _, data in pairs(self.bars) do
        if data.bar then data.bar:hide() end
    end
    self.bars  = {}
    self.order = {}

    self:initialize_bars()
end

function manager:get_anchor()
    return self.base_x, self.base_y
end
function manager:get_remote_anchor()
    return self.remote_x, self.remote_y
end
function manager:get_custom_anchor()
    local x, y = self.custom_x, self.custom_y
    if not x or not y then
        x, y = get_default_custom_anchor()
    end
    return x, y
end
function manager:get_buff_anchor()
    local x, y = self.buff_x, self.buff_y
    if not x or not y then
        x, y = get_default_buff_anchor()
    end
    return x, y
end

function manager:clear_buff_bars()
    local keys = {}
    for key, data in pairs(self.bars) do
        if data.source == 'buff' then
            keys[#keys + 1] = key
        end
    end
    for _, key in ipairs(keys) do
        remove_bar(key)
    end
end

function manager:set_buffs_visible(visible)
    self.show_buffs = not not visible
    if not self.show_buffs then
        self:clear_buff_bars()
    elseif self.last_buff_ids and self.last_buff_times then
        self:update_buff_bars(self.last_buff_ids, self.last_buff_times)
    end
end

function manager:set_buff_filters(filters)
    buff_filters = filters or {}
    if self.show_buffs and self.last_buff_ids and self.last_buff_times then
        self:update_buff_bars(self.last_buff_ids, self.last_buff_times)
    else
        self:clear_buff_bars()
    end
end

-- Remote cooldown bar: owner = character name, abil = JA/spell name
-- kind = 'ja' or 'spell', rem/total in seconds
function manager:set_remote_colors(tbl)
    self.remote_colors = tbl or {}

    -- recolor existing remote bars
    for _, key in ipairs(self.order) do
        local data = self.bars[key]
        if data and data.source == 'remote' and data.bar then
            local a, r, g, b = self:get_remote_color(data.owner)
            windower.prim.set_color(data.bar.fg_prim, a, r, g, b)
        end
    end
end

function manager:get_remote_color(owner)
    local colors = self.remote_colors or {}
    local c = (owner and colors[owner]) or colors.Default

    local a = (c and c.a) or 255
    local r = (c and c.r) or 190
    local g = (c and c.g) or 120
    local b = (c and c.b) or 255

    return a, r, g, b
end

function manager:set_remote_cooldown(owner, abil, kind, rem, total, group_id)
    owner = owner or '?'
    abil  = abil  or '?'
    kind  = kind  or 'ja'

    -- Use recast_id/group_id if provided so name changes (e.g. Stratagems [N])
    -- do NOT create new bars.
    local key_id = group_id or abil
    local key    = ('CD:%s:%s'):format(owner, key_id)

    -- remove when finished
    if not rem or rem <= 0 then
        local data = self.bars[key]
        if data then
            if data.bar then
                if data.bar.destroy then
                    data.bar:destroy()
                else
                    data.bar:hide()
                end
            end
            self.bars[key] = nil
            for i, k in ipairs(self.order) do
                if k == key then
                    table.remove(self.order, i)
                    break
                end
            end
            -- reflow stack
            local idx = 1
            for _, k in ipairs(self.order) do
                local d = self.bars[k]
                if d and d.bar then
                    local y = self.base_y + (idx - 1) * self.spacing
                    d.bar:set_position(self.base_x, y)
                    idx = idx + 1
                end
            end
            manager:reflow()
        end
        return
    end

    local data = self.bars[key]
    if not data then
        local x = self.base_x
        local y = self.base_y + (#self.order) * self.spacing

        local bar = recast_bar.new_recast_bar(x, y, self.bar_width, self.bar_height, self.mode)
        bar:set_name(('%s  %s'):format(owner, abil))

        -- purple for remote cooldowns
        local a, r, g, b = self:get_remote_color(owner)
        windower.prim.set_color(bar.fg_prim, a, r, g, b)

        data = {
            name      = abil,
            kind      = kind,
            source    = 'remote',
            owner     = owner,
            total     = total or rem,
            recast_id = group_id or nil,
            id        = nil,
            bar       = bar,
        }
        self.bars[key] = data
        table.insert(self.order, key)

        manager:reflow()
    else
        -- name can change (e.g. "Stratagems [3]"), so update text
        data.name = abil
        if data.bar and data.bar.set_name then
            local owner3 = truncate(owner, 3)
            local abil_short = abil:gsub("Stratagems", "Strat")  -- optional short alias

            data.bar:set_name(('%s  %s'):format(owner3, abil_short))
        end
    end

    if not data.total or data.total <= 0 then
        data.total = total or rem
    end

    data.bar:set(rem, data.total)
end

----------------------------------------------------------------
-- Initialize bars for existing recasts on load
----------------------------------------------------------------
function manager:initialize_bars()
    local spell_recasts = windower.ffxi.get_spell_recasts()  or {}
    local abil_recasts  = windower.ffxi.get_ability_recasts() or {}

    -- Spells: use recast_id from resources
    for spell_id, sp in pairs(res.spells) do
        if sp.recast_id and sp.en and not profile.hide_spells[sp.en] then
            local seconds = spell_recasts[sp.recast_id]
            if seconds and seconds > 0 then
                local key   = ('SP:%d'):format(spell_id)
                local total = seconds    -- already seconds
                coroutine.sleep(.1)
                create_bar(sp.en, key, 'spell', spell_id, sp.recast_id, total)
            end
        end
    end

    -- Job abilities: abil_recasts keyed by recast_id
    for recast_id, seconds in pairs(abil_recasts) do
        if seconds > 0 then
            if not should_skip_recast_id(recast_id, abil_recasts) then
                if recast_id == STRATAGEM_RECAST_ID then
                    -- Stratagems: grouped bar, charge logic handled in update()
                    local label = CHARGE_LABELS[recast_id] or 'Stratagems'
                    if not profile.hide_ja[label] then
                        local key   = ('JA:%d'):format(recast_id)
                        local total = seconds
                        create_bar(label, key, 'ja', nil, recast_id, total)
                    end

                else
                    -- Everything else: one bar per recast_id, name from ability_recasts or first JA
                    local label = get_recast_group_label(recast_id)

                    if label and not profile.hide_ja[label] then
                        local key   = ('JA:%d'):format(recast_id)
                        local total = seconds
                        create_bar(label, key, 'ja', nil, recast_id, total)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------
-- Periodic resync: rebuild any missing bars (handles lost action packets)
----------------------------------------------------------------
function manager:resync_missing()
    local spell_recasts = windower.ffxi.get_spell_recasts()  or {}
    local abil_recasts  = windower.ffxi.get_ability_recasts() or {}

    -- Spells: use recast_id from resources
    for spell_id, sp in pairs(res.spells) do
        if sp.recast_id and sp.en and not profile.hide_spells[sp.en] then
            local seconds = spell_recasts[sp.recast_id]
            if seconds and seconds > 0 then
                local key = ('SP:%d'):format(spell_id)
                if not self.bars[key] then
                    create_bar(sp.en, key, 'spell', spell_id, sp.recast_id, seconds)
                end
            end
        end
    end

    -- Job abilities: abil_recasts keyed by recast_id
    for recast_id, seconds in pairs(abil_recasts) do
        if seconds > 0 then
            if not should_skip_recast_id(recast_id, abil_recasts) then
                local key = ('JA:%d'):format(recast_id)
                if not self.bars[key] then
                    if recast_id == STRATAGEM_RECAST_ID then
                        local label = CHARGE_LABELS[recast_id] or 'Stratagems'
                        create_bar(label, key, 'ja', nil, recast_id, seconds)
                    else
                        local label = get_recast_group_label(recast_id)
                        if label then
                            create_bar(label, key, 'ja', nil, recast_id, seconds)
                        end
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------
-- Update every frame (via prerender)
----------------------------------------------------------------
function manager:update()
    local abil_recasts  = windower.ffxi.get_ability_recasts()  or {}
    local spell_recasts = windower.ffxi.get_spell_recasts()    or {}
    local now = os.clock()

    for key, data in pairs(self.bars) do
        -- remote cooldowns are driven externally
        if data.source == 'local' or data.source == 'custom' or data.source == 'buff' then
            local rem = 0

            if data.kind == 'ja' then
                local seconds = abil_recasts[data.recast_id] or 0

                -- Special handling for Stratagems (recast group 231)
                if data.recast_id == STRATAGEM_RECAST_ID then
                    local state = stratagem_state(seconds)

                    if state then
                        rem        = state.next_in
                        data.total = state.per or state.next_in or data.total

                        -- Label like: "Stratagems [3]"
                        local base_name = CHARGE_LABELS[STRATAGEM_RECAST_ID] or data.name or 'Stratagems'
                        data.bar:set_name(('%s [%d]'):format(base_name, state.current or 0))
                    else
                        -- no valid SCH data; fall back to raw seconds
                        rem = seconds
                        if data.total <= 0 then
                            data.total = rem
                        end
                    end
                else
                    -- Normal JA
                    rem = seconds
                    if data.total <= 0 then
                        data.total = rem
                    end
                end

            elseif data.kind == 'spell' then
                local frames = spell_recasts[data.id] or 0
                rem = frames / 60
                if data.total <= 0 then
                    data.total = rem
                end
            elseif data.kind == 'custom' then
                rem = (data.expires or 0) - now
            elseif data.kind == 'buff' then
                rem = (data.expires or 0) - os.time()
            end

            if rem <= 0 then
                remove_bar(key)
            else
                local total = (data.total and data.total > 0) and data.total or rem
                data.bar:set(rem, total)
            end
        end
    end

    local interval = self.resync_interval or 0
    if interval > 0 and (now - last_resync) >= interval then
        last_resync = now
        self:resync_missing()
    end
end

local function decode_buff_end_time(raw)
    if not raw or raw <= 0 then
        return nil
    end

    local now = os.time()
    local epoch = math.floor((now - BUFF_TIME_BASE) / BUFF_TIME_ROLLOVER)
    local candidate = BUFF_TIME_BASE + (raw / 60) + (epoch * BUFF_TIME_ROLLOVER)

    if candidate < (now - 3600) then
        candidate = candidate + BUFF_TIME_ROLLOVER
    elseif candidate > (now + BUFF_TIME_ROLLOVER) then
        candidate = candidate - BUFF_TIME_ROLLOVER
    end

    return candidate
end

function manager:update_buff_bars(buff_ids, buff_times)
    if not self.show_buffs then
        return
    end

    self.last_buff_ids = {}
    self.last_buff_times = {}
    for i = 1, 32 do
        self.last_buff_ids[i] = buff_ids and buff_ids[i]
        self.last_buff_times[i] = buff_times and buff_times[i]
    end

    local seen = {}
    local now = os.time()

    for i = 1, 32 do
        local buff_id = buff_ids and buff_ids[i]
        local raw_end = buff_times and buff_times[i]
        local key = ('%s%d'):format(BUFF_BAR_PREFIX, i)

        if buff_id and buff_id ~= 0 and buff_id ~= 255 and raw_end and raw_end > 0 then
            local buff = res.buffs[buff_id]
            local expires = decode_buff_end_time(raw_end)
            local remaining = expires and (expires - now) or 0
            local buff_name = buff and (buff.en or buff.name)

            if buff_name and buff_allowed(buff_name) and remaining > 0 then
                seen[key] = true

                local data = self.bars[key]
                if not data then
                    local x = self.base_x
                    local y = self.base_y + (#self.order) * self.spacing
                    local bar = recast_bar.new_recast_bar(x, y, self.bar_width, self.bar_height, self.mode)
                    bar:set_name(buff_name)
                    apply_color_theme(bar, 'buff')

                    data = {
                        name = buff_name,
                        kind = 'buff',
                        source = 'buff',
                        buff_id = buff_id,
                        slot = i,
                        total = remaining,
                        bar = bar,
                        expires = expires,
                        last_remaining = remaining,
                    }
                    self.bars[key] = data
                    table.insert(self.order, key)
                else
                    if data.bar and data.name ~= buff_name then
                        data.bar:set_name(buff_name)
                    end
                    data.name = buff_name
                    data.buff_id = buff_id
                    data.slot = i
                    data.expires = expires

                    if not data.total or remaining > (data.last_remaining or 0) + 2 then
                        data.total = remaining
                    end
                    data.last_remaining = remaining
                end
            end
        end
    end

    local stale = {}
    for key, data in pairs(self.bars) do
        if data.source == 'buff' and not seen[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        remove_bar(key)
    end

    self:reflow()
end

----------------------------------------------------------------
-- Action listener: create bars when you use JA/spell
----------------------------------------------------------------
windower.register_event('action', function(act)
    local me = windower.ffxi.get_player()
    if not me or act.actor_id ~= me.id then
        return
    end

    local cat   = act.category
    local param = act.param

    -- Spells (category 4)
    if cat == 4 then
        local spell = res.spells[param]
        if spell and spell.recast_id and spell.en then
            local key = ('SP:%d'):format(spell.id)
            create_bar(spell.en, key, 'spell', spell.id, spell.recast_id, 0)
        end
    end

    -- Job abilities (categories 6/14/15 etc.)
    if S{3,6,14,15}:contains(cat) then
        local abil = res.job_abilities[param]
        if abil and abil.recast_id and abil.en then
            local recast_id = abil.recast_id
            if not should_skip_recast_id(recast_id) then
                local key       = ('JA:%d'):format(recast_id)
                local label     = get_recast_group_label(recast_id) or abil.en
                create_bar(label, key, 'ja', nil, recast_id, 0)
            end
        end
    end

end)

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
    if injected or blocked or id ~= 0x1A then
        return
    end

    local ok, packet = pcall(packets.parse, 'outgoing', data)
    if not ok or not packet then
        return
    end

    if packet.Category == DIG_ACTION_CATEGORY then
        create_custom_bar(DIG_BAR_LABEL, DIG_BAR_KEY, DIG_RECAST_SECONDS)
    end
end)

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if injected or blocked or id ~= 0x063 then
        return
    end

    if data:byte(5) ~= BUFF_PACKET_ORDER then
        return
    end

    local ok, packet = pcall(packets.parse, 'incoming', data)
    if not ok or not packet then
        return
    end

    local buff_ids = {}
    local buff_times = {}

    for i = 1, 32 do
        buff_ids[i] = packet['Buffs ' .. i]
        buff_times[i] = packet['Time ' .. i]
    end

    manager:update_buff_bars(buff_ids, buff_times)
end)

----------------------------------------------------------------
-- Continuous update (prerender)
----------------------------------------------------------------
windower.register_event('prerender', function()
    manager:update()
end)

----------------------------------------------------------------
-- Mouse: drag the whole stack
----------------------------------------------------------------
windower.register_event('mouse', function(type, x, y, delta, blocked)
    if blocked then
        return
    end

    -- move
    if type == 0 then
        if manager.drag then
            if manager.drag.stack == 'remote' and not manager.remote_bound then
                manager.remote_x = x - manager.drag.dx
                manager.remote_y = y - manager.drag.dy
            elseif manager.drag.stack == 'buff' then
                manager.buff_x = x - manager.drag.dx
                manager.buff_y = y - manager.drag.dy
            elseif manager.drag.stack == 'custom' then
                manager.custom_x = x - manager.drag.dx
                manager.custom_y = y - manager.drag.dy
            else
                manager.base_x = x - manager.drag.dx
                manager.base_y = y - manager.drag.dy
            end
            manager:reflow()
            return true
        end

    -- left down
    elseif type == 1 then
        for _, key in ipairs(manager.order) do
            local data = manager.bars[key]
            if data and data.bar and data.bar:hit_test(x, y) then
                local stack, ax, ay

                if not manager.remote_bound and data.source == 'remote' then
                    if not manager.remote_x then
                        manager.remote_x = manager.base_x + (manager.remote_offsetX or (manager.bar_width + 20))
                    end
                    if not manager.remote_y then
                        manager.remote_y = manager.base_y
                    end
                    stack = 'remote'
                    ax    = manager.remote_x
                    ay    = manager.remote_y
                elseif data.source == 'buff' then
                    if not manager.buff_x then
                        manager.buff_x, manager.buff_y = get_default_buff_anchor()
                    end
                    if not manager.buff_y then
                        manager.buff_y = manager.base_y
                    end
                    stack = 'buff'
                    ax    = manager.buff_x
                    ay    = manager.buff_y
                elseif data.source == 'custom' then
                    if not manager.custom_x then
                        manager.custom_x, manager.custom_y = get_default_custom_anchor()
                    end
                    if not manager.custom_y then
                        manager.custom_y = manager.base_y
                    end
                    stack = 'custom'
                    ax    = manager.custom_x
                    ay    = manager.custom_y
                else
                    stack = 'local'
                    ax    = manager.base_x
                    ay    = manager.base_y
                end

                manager.drag = {
                    stack = stack,
                    dx    = x - ax,
                    dy    = y - ay,
                }
                return true
            end
        end

    -- left up
    elseif type == 2 then
        if manager.drag then
            manager.drag = nil
            return true
        end
    end
end)

----------------------------------------------------------------
-- Load / job change: profile + initial bars
----------------------------------------------------------------
windower.register_event('load', function()
    local p = windower.ffxi.get_player()
    load_profile(p and p.main_job)
    manager:initialize_bars()
end)

windower.register_event('job change', function(new, old)
    load_profile(new)
    -- rebuild bars for new job (in case profile hides different stuff)
    for _, data in pairs(manager.bars) do
        if data.bar then data.bar:hide() end
    end
    manager.bars  = {}
    manager.order = {}
    manager:initialize_bars()
end)

return manager
