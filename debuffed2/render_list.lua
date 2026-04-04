local M = {}

local INDENT = '  '
local NAME_W = 13
local TIMER_W = 3

function M.new(helpers)
    local get_color = helpers.get_color
    local collect_rows = helpers.collect_rows

    local function rgb_triplet(c)
        return ('%d,%d,%d'):format(c[1], c[2], c[3])
    end

    local HEADER = rgb_triplet{255, 184, 77}
    local TARGET_HDR = rgb_triplet{120, 200, 255}
    local WATCH_HDR = rgb_triplet{255, 140, 160}

    local function build_list_box(target, box_ref, header_color, label_prefix)
        local lines = L{}
        local payload = collect_rows(target)
        if not payload then
            box_ref.current_string = ''
            return
        end

        local function append_section(title, rows)
            if #rows == 0 then
                return
            end
            lines:append(('\\cs(%s)%s\\cr\n'):format(HEADER, title))
            for _, r in ipairs(rows) do
                local key = ('%-' .. NAME_W .. 's'):format(r.name)
                local timer = ('%' .. TIMER_W .. '.0f'):format(r.remains or 0)
                local lvl = (r.lvl and r.lvl ~= 0) and ('Lv %2d'):format(r.lvl) or ''

                if settings.timers and r.remains > 0 then
                    lines:append(('%s\\cs(%s)%s\\cr:%s%s\n'):format(INDENT, get_color(r.actor), key, lvl, timer))
                else
                    lines:append(('%s\\cs(%s)%s\\cr\n'):format(INDENT, get_color(r.actor), key))
                end
            end
        end

        local display = payload.label
        if payload.hp ~= nil then
            display = ('%s (%d%%)'):format(display, payload.hp)
        end
        lines:append(('\\cs(%s)%s\\cr %s\n'):format(header_color, label_prefix, display))
        if payload.action and payload.action.name then
            lines:append(('%s\\cs(%s)Action\\cr %s\n'):format(INDENT, HEADER, payload.action.name))
        end
        append_section('Abilities', payload.abilities)
        append_section('Spells', payload.spells)

        box_ref.current_string = (lines:length() == 0) and '' or lines:concat('')
    end

    return {
        HEADER = HEADER,
        TARGET_HDR = TARGET_HDR,
        WATCH_HDR = WATCH_HDR,
        build_list_box = build_list_box,
    }
end

return M
