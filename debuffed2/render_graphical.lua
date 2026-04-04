local M = {}

function M.new(helpers)
    local collect_rows = helpers.collect_rows
    local build_debuff_label = helpers.build_debuff_label
    local get_claim_bar_color = helpers.get_claim_bar_color

    local GRAPH_BAR_WIDTH = 250
    local GRAPH_BAR_HEIGHT = 10
    local GRAPH_INNER_PAD = 2
    local GRAPH_ICON_SIZE = 18
    local GRAPH_ICON_SPACING = 8
    local GRAPH_SLOT_WIDTH = 52
    local GRAPH_ROW_ICON_LIMIT = 8
    local GRAPH_ICON_LIMIT = 16
    local GRAPH_ROW_GAP = 34
    local GRAPH_BG_COLOR = {58, 16, 24}
    local GRAPH_TEXT_COLOR = {255, 190, 190}
    local GRAPH_STROKE_COLOR = {40, 0, 0}
    local GRAPH_LABEL_COLOR = {255, 255, 255}
    local GRAPH_ACTION_COLOR = {205, 220, 235}
    local GRAPH_STACK_COLOR = {255, 255, 255}
    local GRAPH_TARGET_TAG_COLOR = {120, 200, 255}
    local GRAPH_WATCH_TAG_COLOR = {255, 184, 77}
    local GRAPH_HP_COLOR = {255, 210, 150}
    local GRAPH_NAME_COLOR = {255, 255, 255}
    local GRAPH_BAR_ALPHA = 255
    local GRAPH_BG_ALPHA = 100
    local GRAPH_BG_TEXTURE = windower.addon_path .. 'data/BarBG_pill_12.png'
    local GRAPH_FG_TEXTURE = windower.addon_path .. 'data/BarFG_pill_12.png'
    local next_graph_prim_id = 0
    local function new_graph_prim(prefix)
        next_graph_prim_id = next_graph_prim_id + 1
        return ('%s%d'):format(prefix, next_graph_prim_id)
    end

    local function make_graphic_image(path, width, height, draggable)
        return images.new({
            texture = {
                path = windower.addon_path .. 'images/' .. path,
                fit = true,
            },
            size = {
                width = width,
                height = height,
            },
            repeatable = {
                x = 1,
                y = 1,
            },
            draggable = draggable or false,
            visible = false,
        })
    end

    local function make_graphic_text(style)
        return texts.new({
            pos = {x = 0, y = 0},
            padding = 0,
            bg = {visible = false},
            flags = {
                bold = false,
                italic = false,
                right = false,
                bottom = false,
                draggable = false,
            },
            text = {
                size = style.size or 10,
                font = style.font or 'Consolas',
                alpha = 255,
                red = GRAPH_TEXT_COLOR[1],
                green = GRAPH_TEXT_COLOR[2],
                blue = GRAPH_TEXT_COLOR[3],
                stroke = {
                    width = 2,
                    alpha = 220,
                    red = GRAPH_STROKE_COLOR[1],
                    green = GRAPH_STROKE_COLOR[2],
                    blue = GRAPH_STROKE_COLOR[3],
                },
            },
            visible = false,
        })
    end

    local function graphic_icon_path(effect_id)
        if effect_id == nil then
            return nil
        end
        local candidates = {
            windower.addon_path .. ('images/debufficons/%03d.png'):format(effect_id),
            windower.addon_path .. ('images/debufficons/%d.png'):format(effect_id),
            windower.addon_path .. ('images/icons/%03d.png'):format(effect_id),
            windower.addon_path .. ('images/icons/%d.png'):format(effect_id),
        }
        for _, path in ipairs(candidates) do
            if windower.file_exists(path) then
                return path
            end
        end
        return windower.addon_path .. 'images/debufficons/000.png'
    end

    local function make_graphic_renderer(position, draggable)
        local renderer = {
            body = make_graphic_image('fg_body.png', GRAPH_BAR_WIDTH, GRAPH_BAR_HEIGHT, draggable),
            cap_l = make_graphic_image('bg_cap_l.png', 2, GRAPH_BAR_HEIGHT, false),
            cap_r = make_graphic_image('bg_cap_r.png', 2, GRAPH_BAR_HEIGHT, false),
            fill = make_graphic_image('fg_body.png', GRAPH_BAR_WIDTH, GRAPH_BAR_HEIGHT, false),
            tag = make_graphic_text(settings.graphic_box.text),
            hp_pct = make_graphic_text(settings.graphic_box.text),
            mob_name = make_graphic_text(settings.graphic_box.text),
            action = make_graphic_text(settings.graphic_box.text),
            x = position.x,
            y = position.y,
            shown = false,
            icons = {},
            timers = {},
            labels = {},
            stacks = {},
            bg_prim = new_graph_prim('db2_bg_'),
            fg_prim = new_graph_prim('db2_fg_'),
        }

        renderer.body:alpha(0)
        renderer.body:pos(renderer.x, renderer.y)

        windower.prim.create(renderer.bg_prim)
        windower.prim.set_color(renderer.bg_prim, GRAPH_BG_ALPHA, GRAPH_BG_COLOR[1], GRAPH_BG_COLOR[2], GRAPH_BG_COLOR[3])
        windower.prim.set_size(renderer.bg_prim, GRAPH_BAR_WIDTH, GRAPH_BAR_HEIGHT)
        windower.prim.set_position(renderer.bg_prim, renderer.x, renderer.y)
        windower.prim.set_texture(renderer.bg_prim, GRAPH_BG_TEXTURE)
        windower.prim.set_fit_to_texture(renderer.bg_prim, false)
        windower.prim.set_visibility(renderer.bg_prim, false)

        windower.prim.create(renderer.fg_prim)
        windower.prim.set_color(renderer.fg_prim, GRAPH_BAR_ALPHA, 255, 110, 150)
        windower.prim.set_size(renderer.fg_prim, GRAPH_BAR_WIDTH - (GRAPH_INNER_PAD * 2), GRAPH_BAR_HEIGHT - (GRAPH_INNER_PAD * 2))
        windower.prim.set_position(renderer.fg_prim, renderer.x + GRAPH_INNER_PAD, renderer.y + GRAPH_INNER_PAD)
        windower.prim.set_texture(renderer.fg_prim, GRAPH_FG_TEXTURE)
        windower.prim.set_fit_to_texture(renderer.fg_prim, false)
        windower.prim.set_visibility(renderer.fg_prim, false)

        renderer.body:hide()
        renderer.cap_l:hide()
        renderer.cap_r:hide()
        renderer.fill:hide()
        renderer.tag:color(GRAPH_TARGET_TAG_COLOR[1], GRAPH_TARGET_TAG_COLOR[2], GRAPH_TARGET_TAG_COLOR[3])
        renderer.hp_pct:color(GRAPH_HP_COLOR[1], GRAPH_HP_COLOR[2], GRAPH_HP_COLOR[3])
        renderer.mob_name:color(GRAPH_NAME_COLOR[1], GRAPH_NAME_COLOR[2], GRAPH_NAME_COLOR[3])
        renderer.action:color(GRAPH_ACTION_COLOR[1], GRAPH_ACTION_COLOR[2], GRAPH_ACTION_COLOR[3])

        for i = 1, GRAPH_ICON_LIMIT do
            renderer.icons[i] = make_graphic_image('debufficons/000.png', GRAPH_ICON_SIZE, GRAPH_ICON_SIZE, false)
            renderer.timers[i] = make_graphic_text({size = 10, font = settings.graphic_box.text.font})
            renderer.labels[i] = make_graphic_text({size = 10, font = settings.graphic_box.text.font})
            renderer.stacks[i] = make_graphic_text({size = 10, font = settings.graphic_box.text.font})
            renderer.labels[i]:color(GRAPH_LABEL_COLOR[1], GRAPH_LABEL_COLOR[2], GRAPH_LABEL_COLOR[3])
            renderer.stacks[i]:color(GRAPH_STACK_COLOR[1], GRAPH_STACK_COLOR[2], GRAPH_STACK_COLOR[3])
        end

        return renderer
    end

    local function hide_graphic_renderer(renderer)
        windower.prim.set_visibility(renderer.bg_prim, false)
        windower.prim.set_visibility(renderer.fg_prim, false)
        renderer.body:hide()
        renderer.cap_l:hide()
        renderer.cap_r:hide()
        renderer.fill:hide()
        renderer.tag:hide()
        renderer.hp_pct:hide()
        renderer.mob_name:hide()
        renderer.action:hide()
        for i = 1, GRAPH_ICON_LIMIT do
            renderer.icons[i]:hide()
            renderer.timers[i]:hide()
            renderer.labels[i]:hide()
            renderer.stacks[i]:hide()
        end
        renderer.shown = false
    end

    local function sync_graphic_position(renderer, setting_pos)
        local x, y = renderer.body:pos()
        if x ~= 0 or y ~= 0 then
            renderer.x = x
            renderer.y = y
        end

        if setting_pos.x ~= math.floor(renderer.x) or setting_pos.y ~= math.floor(renderer.y) then
            setting_pos.x = math.floor(renderer.x)
            setting_pos.y = math.floor(renderer.y)
            settings:save()
        end
    end

    local function draw_effect_row(renderer, rows, row_y, start_slot)
        local slot = start_slot or 1
        for i = 1, GRAPH_ROW_ICON_LIMIT do
            local row = rows[i]
            if row then
                local ix = renderer.x + ((i - 1) * GRAPH_SLOT_WIDTH)
                renderer.icons[slot]:hide()

                local short_label = build_debuff_label(row.name)
                if short_label ~= '' then
                    renderer.labels[slot]:pos(ix, row_y - 1)
                    renderer.labels[slot]:text(short_label)
                    renderer.labels[slot]:show()
                else
                    renderer.labels[slot]:hide()
                end

                if row.kind == 'ability' and row.lvl and tonumber(row.lvl) and tonumber(row.lvl) > 0 then
                    renderer.stacks[slot]:pos(ix, row_y + 10)
                    renderer.stacks[slot]:text('Lv ' .. tostring(math.floor(row.lvl)))
                    renderer.stacks[slot]:show()
                else
                    renderer.stacks[slot]:hide()
                end

                if settings.timers then
                    local seconds = math.max(0, math.floor((row.remains or 0) + 0.5))
                    local timer_y = row_y + ((row.kind == 'ability') and 21 or 13)
                    renderer.timers[slot]:pos(ix, timer_y)
                    renderer.timers[slot]:text(tostring(seconds) .. 's')
                    renderer.timers[slot]:show()
                else
                    renderer.timers[slot]:hide()
                end
                slot = slot + 1
            end
        end

        return slot
    end

    local function draw_graphic_renderer(renderer, setting_pos, target, label_prefix)
        local payload = collect_rows(target)
        if not payload then
            hide_graphic_renderer(renderer)
            return
        end

        sync_graphic_position(renderer, setting_pos)

        local live_target = target and windower.ffxi.get_mob_by_id(target.id) or nil
        local hp = (live_target and live_target.hpp) or (target and target.hpp) or payload.hp or 0
        hp = tonumber(hp) or 0
        if hp < 0 then hp = 0 end
        if hp > 100 then hp = 100 end

        local inner_width = GRAPH_BAR_WIDTH - (GRAPH_INNER_PAD * 2)
        local inner_height = GRAPH_BAR_HEIGHT - (GRAPH_INNER_PAD * 2)
        local width = math.floor(inner_width * hp / 100)
        local x = renderer.x
        local y = renderer.y
        local fill_color = get_claim_bar_color(live_target or target)

        windower.prim.set_position(renderer.bg_prim, x, y)
        windower.prim.set_size(renderer.bg_prim, GRAPH_BAR_WIDTH, GRAPH_BAR_HEIGHT)
        windower.prim.set_position(renderer.fg_prim, x + GRAPH_INNER_PAD, y + GRAPH_INNER_PAD)
        windower.prim.set_size(renderer.fg_prim, math.max(0, width), inner_height)
        windower.prim.set_color(renderer.fg_prim, GRAPH_BAR_ALPHA, fill_color[1], fill_color[2], fill_color[3])
        renderer.body:pos(x, y)

        local tag = (label_prefix == 'WATCH') and '[W]' or '[T]'
        local tag_color = (label_prefix == 'WATCH') and GRAPH_WATCH_TAG_COLOR or GRAPH_TARGET_TAG_COLOR
        renderer.tag:color(tag_color[1], tag_color[2], tag_color[3])
        renderer.tag:pos(x + 4, y - 21)
        renderer.tag:text(tag)

        renderer.hp_pct:pos(x + 34, y - 21)
        renderer.hp_pct:text(('%d%%'):format(hp))

        renderer.mob_name:pos(x + 72, y - 21)
        renderer.mob_name:text(payload.label)

        renderer.action:pos(x + 6, y - 1)
        if payload.action and payload.action.name then
            renderer.action:text(payload.action.name)
            renderer.action:show()
        else
            renderer.action:text('')
            renderer.action:hide()
        end

        windower.prim.set_visibility(renderer.bg_prim, true)
        windower.prim.set_visibility(renderer.fg_prim, hp > 0)
        renderer.body:show()
        renderer.tag:show()
        renderer.hp_pct:show()
        renderer.mob_name:show()

        local base_y = y + GRAPH_BAR_HEIGHT + 6
        for i = 1, GRAPH_ICON_LIMIT do
            renderer.icons[i]:hide()
            renderer.timers[i]:hide()
            renderer.labels[i]:hide()
            renderer.stacks[i]:hide()
        end

        if #payload.abilities > 0 then
            draw_effect_row(renderer, payload.abilities, base_y, 1)
        end
        if #payload.spells > 0 then
            local spell_row_y = base_y + ((#payload.abilities > 0) and GRAPH_ROW_GAP or 0)
            draw_effect_row(renderer, payload.spells, spell_row_y, GRAPH_ROW_ICON_LIMIT + 1)
        end

        renderer.shown = true
    end

    local function destroy_graphic_renderer(renderer)
        if not renderer then
            return
        end
        windower.prim.delete(renderer.bg_prim)
        windower.prim.delete(renderer.fg_prim)
        renderer.body:destroy()
        renderer.cap_l:destroy()
        renderer.cap_r:destroy()
        renderer.fill:destroy()
        renderer.tag:destroy()
        renderer.hp_pct:destroy()
        renderer.mob_name:destroy()
        renderer.action:destroy()
        for i = 1, GRAPH_ICON_LIMIT do
            renderer.icons[i]:destroy()
            renderer.timers[i]:destroy()
            renderer.labels[i]:destroy()
            renderer.stacks[i]:destroy()
        end
    end

    return {
        make_renderer = make_graphic_renderer,
        draw = draw_graphic_renderer,
        hide = hide_graphic_renderer,
        destroy = destroy_graphic_renderer,
    }
end

return M
