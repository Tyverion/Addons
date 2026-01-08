-- bar.lua — pill-style recast bar, single text (name column + timer)

local texts      = require('texts')
local addon_path = windower.addon_path

----------------------------------------------------------------
-- Texture selection by height
----------------------------------------------------------------
local function tex_paths_for_height(h)
    if h <= 12 then
        return addon_path .. 'data/BarBG_pill_12.png',
               addon_path .. 'data/BarFG_pill_12.png'
    elseif h <= 14 then
        return addon_path .. 'data/BarBG_pill_14.png',
               addon_path .. 'data/BarFG_pill_14.png'
    else
        return addon_path .. 'data/BarBG_pill_16.png',
               addon_path .. 'data/BarFG_pill_16.png'
    end
end

local function tex_exists(path)
    local f = io.open(path, 'rb')
    if f then f:close() return true end
    return false
end

local GLOW_TEXTURE = addon_path .. 'data/BarGlowMid.png'

local next_id = 0
local function gensym(prefix)
    next_id = next_id + 1
    return (prefix or 'bar_') .. next_id
end

-- how wide the name column is, in characters (monospace)
local NAME_COL_CHARS = 15

----------------------------------------------------------------
-- Constructor
----------------------------------------------------------------
local function new_recast_bar(x, y, width, height, mode)
    local bar = {

    width  = width  or 150,
    height = height or 12,
    x      = x or 400,
    y      = y or 300,
    mode   = (mode == 'up') and 'up' or 'down',

    _name          = '',
    _last_rem      = nil,
    _glow_alpha    = 0,
    _last_glow_sec = nil,

    enable_glow  = true,
    }

    local BG_TEXTURE, FG_TEXTURE = tex_paths_for_height(bar.height)
    local HAS_BG   = tex_exists(BG_TEXTURE)
    local HAS_FG   = tex_exists(FG_TEXTURE)
    local HAS_GLOW = tex_exists(GLOW_TEXTURE)

    -- inner padding so fill is inside the pill frame
    local INNER_PAD = math.max(1, math.floor(bar.height / 6))
    bar.inner_pad    = INNER_PAD
    bar.inner_width  = bar.width  - INNER_PAD * 2
    bar.inner_height = bar.height - INNER_PAD * 2

    ---------------------------------------------------------
    -- BACKGROUND (full pill frame)
    ---------------------------------------------------------
    bar.bg_prim = gensym('bg_')
    windower.prim.create(bar.bg_prim)
    windower.prim.set_color(bar.bg_prim, 255, 255, 255, 255)
    windower.prim.set_size(bar.bg_prim, bar.width, bar.height)
    windower.prim.set_position(bar.bg_prim, bar.x, bar.y)
    if HAS_BG then
        windower.prim.set_texture(bar.bg_prim, BG_TEXTURE)
        windower.prim.set_fit_to_texture(bar.bg_prim, false)
    end
    windower.prim.set_visibility(bar.bg_prim, true)

    ---------------------------------------------------------
    -- FOREGROUND (inner pill fill)
    ---------------------------------------------------------
    bar.fg_prim = gensym('fg_')
    windower.prim.create(bar.fg_prim)
    windower.prim.set_color(bar.fg_prim, 255, 90, 170, 255) -- themed by manager
    windower.prim.set_size(bar.fg_prim, bar.inner_width, bar.inner_height)
    windower.prim.set_position(bar.fg_prim,
        bar.x + INNER_PAD,
        bar.y + INNER_PAD
    )
    if HAS_FG then
        windower.prim.set_texture(bar.fg_prim, FG_TEXTURE)
        windower.prim.set_fit_to_texture(bar.fg_prim, false)
    end
    windower.prim.set_visibility(bar.fg_prim, true)

    ---------------------------------------------------------
    -- GLOW (pulse when nearly ready)
    ---------------------------------------------------------
    bar.glow_prim = gensym('glow_')
    windower.prim.create(bar.glow_prim)
    windower.prim.set_color(bar.glow_prim, 0, 255, 255, 255)
    windower.prim.set_size(bar.glow_prim, bar.inner_width, bar.inner_height)
    windower.prim.set_position(bar.glow_prim,
        bar.x + INNER_PAD,
        bar.y + INNER_PAD
    )
    if HAS_GLOW then
        windower.prim.set_texture(bar.glow_prim, GLOW_TEXTURE)
        windower.prim.set_fit_to_texture(bar.glow_prim, false)
    end
    windower.prim.set_visibility(bar.glow_prim, true)

    ---------------------------------------------------------
    -- SINGLE TEXT OBJECT (name column + timer)
    ---------------------------------------------------------
    local function text_center_y()
        return bar.y + math.floor(bar.height / 2) - 7
    end

    bar.text = texts.new('', {
        pos   = { x = bar.x + 6, y = text_center_y() },
        text  = {
            font  = 'Consolas',
            size  = 10,
            red   = 255, green = 255, blue = 255, alpha = 255,
            stroke = { width = 2, red = 0, green = 0, blue = 0, alpha = 255 },
        },
        flags = {
            right     = false,
            bold      = true,
            draggable = false,  -- bound to bar only
        },
        bg = { visible = false },
    })
    bar.text:show()

    ---------------------------------------------------------
    -- Helpers
    ---------------------------------------------------------
    function bar:_update_text_positions()
        local yc = bar.y + math.floor(bar.height / 2) - 7
        bar.text:pos(bar.x + 6, yc)
    end

    -- Format a time value in seconds as m:ss.xx or m:ss.xx (minutes always shown)
    function bar:_format_time(rem)
        if not rem or rem <= 0 then
            return ''
        end

        local cs = math.floor(rem * 100 + 0.5)
        local m  = math.floor(cs / 6000)
        local s  = math.floor((cs % 6000) / 100)
        local hs = cs % 100

        return ('%d:%02d.%02d'):format(m, s, hs)
    end

    -- Write "name-column   timer" into bar.text
    function bar:_update_text_line(rem)
        local name = bar._name or ''

        -- truncate to fit column
        if #name > NAME_COL_CHARS then
            name = name:sub(1, NAME_COL_CHARS)
        end

        if not rem or rem <= 0 then
            local line = ('%-' .. NAME_COL_CHARS .. 's'):format(name)
            bar.text:text(line)
            return
        end

        local t = bar:_format_time(rem)
        local fmt = '%-' .. NAME_COL_CHARS .. 's %s'
        local line = fmt:format(name, t)
        bar.text:text(line)
    end

    ---------------------------------------------------------
    -- Methods
    ---------------------------------------------------------
    function bar:set_mode(mode)
        mode = (mode or ''):lower()
        if mode == 'up' or mode == 'down' then
            self.mode = mode
        end
    end

    function bar:set_name(name)
        bar._name = name or ''
        bar:_update_text_line(bar._last_rem)
    end

    function bar:set_position(x, y)
        bar.x = x
        bar.y = y

        local pad = bar.inner_pad

        windower.prim.set_position(bar.bg_prim,   x,       y)
        windower.prim.set_position(bar.fg_prim,   x + pad, y + pad)
        windower.prim.set_position(bar.glow_prim, x + pad, y + pad)

        bar:_update_text_positions()
    end

    function bar:hit_test(mx, my)
        return mx >= bar.x and mx <= bar.x + bar.width
           and my >= bar.y and my <= bar.y + bar.height
    end

    -- remaining / total in seconds
    function bar:set(remaining, total)
        if not total or total <= 0 or not remaining or remaining <= 0 then
            bar._last_rem      = nil
            bar:_update_text_line(nil)
            bar._glow_alpha    = 0
            bar._last_glow_sec = nil
            -- reset both layers
            windower.prim.set_color(bar.glow_prim, 0,   255, 255, 255)
            windower.prim.set_color(bar.bg_prim,   255, 255, 255, 255)
            return
        end

        local rem = math.max(0, remaining)
        bar._last_rem = rem

        local pct_raw = rem / total
        -- clamp so we never overflow the bar width
        if pct_raw < 0 then
            pct_raw = 0
        elseif pct_raw > 1 then
            pct_raw = 1
        end

        local pct = (bar.mode == 'up') and (1 - pct_raw) or pct_raw

        local cur_w = math.max(1, math.floor(bar.inner_width * pct + 0.5))

        local pad = bar.inner_pad
        windower.prim.set_size(bar.fg_prim,   cur_w, bar.inner_height)
        windower.prim.set_size(bar.glow_prim, cur_w, bar.inner_height)
        windower.prim.set_position(bar.fg_prim,   bar.x + pad, bar.y + pad)
        windower.prim.set_position(bar.glow_prim, bar.x + pad, bar.y + pad)

        -- name column + timer
        bar:_update_text_line(rem)

        -----------------------------------------------------
        -- Glow pulse: last 5 seconds
        --  * mode 'down' : pulse BACKGROUND (bg_prim)
        --  * mode 'up'   : pulse GLOW (glow_prim)
        -----------------------------------------------------
        local pulse_prim, reset_prim
        if bar.mode == 'up' then
            pulse_prim = bar.glow_prim
            reset_prim = bar.bg_prim
        else
            pulse_prim = bar.bg_prim
            reset_prim = bar.glow_prim
        end

        -- reset the non-pulsed layer each frame
        if reset_prim == bar.glow_prim then
            windower.prim.set_color(bar.glow_prim, 0,   255, 255, 255)
        else
            windower.prim.set_color(bar.bg_prim,   255, 255, 255, 255)
        end

        local sec_int = math.floor(rem)
        if rem <= 5 then
            if bar._last_glow_sec ~= sec_int then
                bar._last_glow_sec = sec_int
                bar._glow_alpha = 255 -- strong pulse at each second tick
            end

            if bar._glow_alpha > 0 then
                bar._glow_alpha = math.max(0, bar._glow_alpha - 50)
                windower.prim.set_color(pulse_prim, bar._glow_alpha, 255, 255, 255)
            else
                -- fully faded
                if pulse_prim == bar.glow_prim then
                    windower.prim.set_color(bar.glow_prim, 0,   255, 255, 255)
                else
                    windower.prim.set_color(bar.bg_prim,   255, 255, 255, 255)
                end
            end
        else
            bar._glow_alpha    = 0
            bar._last_glow_sec = nil
            -- reset to normal
            windower.prim.set_color(bar.glow_prim, 0,   255, 255, 255)
            windower.prim.set_color(bar.bg_prim,   255, 255, 255, 255)
        end
    end

    function bar:hide()
        windower.prim.set_visibility(bar.bg_prim,   false)
        windower.prim.set_visibility(bar.fg_prim,   false)
        windower.prim.set_visibility(bar.glow_prim, false)
        bar.text:hide()
    end

    function bar:show()
        windower.prim.set_visibility(bar.bg_prim,   true)
        windower.prim.set_visibility(bar.fg_prim,   true)
        windower.prim.set_visibility(bar.glow_prim, true)
        bar.text:show()
    end

    -- initial placement
    bar:set_position(bar.x, bar.y)
    bar:show()

    return bar
end

return {
    new_recast_bar = new_recast_bar,
}
