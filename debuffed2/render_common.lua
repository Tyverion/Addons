local M = {}

function M.new(helpers)
    local assign_label = helpers.assign_label
    local ability_icon_overrides = helpers.ability_icon_overrides or {}

    local function should_show_effect(name)
        return (settings.mode == 'whitelist' and settings.whitelist:contains(name))
            or (settings.mode == 'blacklist' and not settings.blacklist:contains(name))
    end

    local function get_color(actor)
        if actor == player_id then
            return '%s,%s,%s':format(settings.colors.player.red, settings.colors.player.green, settings.colors.player.blue)
        end
        return '%s,%s,%s':format(settings.colors.others.red, settings.colors.others.green, settings.colors.others.blue)
    end

    local function collect_rows(target)
        if not target or not target.valid_target or (target.claim_id == 0 and target.spawn_type ~= 16) then
            return nil
        end

        local data = debuffed_mobs[target.id] or {}
        local action = mob_action[target.id]
        if action and action.expires and action.expires <= os.clock() then
            mob_action[target.id] = nil
            action = nil
        end
        if not next(data) and not action then
            return nil
        end

        local label = label_for_id[target.id] or assign_label(target.id, target.name)
        local abilities, spells = {}, {}

        for effect_id, e in pairs(data) do
            local remains = math.max(0, (e.timer or 0) - os.clock())
            if e.kind == 'ability' then
                local ja = res.job_abilities[e.id]
                local name = (ja and ja.name) or ('JA:' .. tostring(e.id))
                local icon_effect_id = ability_icon_overrides[name] or effect_id
                if (e.number or 0) > 5 then
                    remains = math.max(0, remains + 30)
                end
                if should_show_effect(name) then
                    abilities[#abilities + 1] = {
                        name = name,
                        remains = remains,
                        lvl = e.number or 0,
                        actor = e.actor,
                        effect_id = icon_effect_id,
                        kind = 'ability',
                    }
                end
            else
                local sp = res.spells[e.id]
                local name = (sp and sp.name) or ('Spell:' .. tostring(e.id))
                if should_show_effect(name) then
                    spells[#spells + 1] = {
                        name = name,
                        remains = remains,
                        actor = e.actor,
                        effect_id = effect_id,
                        kind = 'spell',
                    }
                end
            end
        end

        table.sort(abilities, function(a, b)
            if a.remains ~= b.remains then
                return a.remains > b.remains
            end
            return a.name < b.name
        end)

        table.sort(spells, function(a, b)
            if a.remains ~= b.remains then
                return a.remains > b.remains
            end
            return a.name < b.name
        end)

        return {
            label = label or target.name or 'Unknown',
            hp = mob_hp[target.id],
            action = action,
            abilities = abilities,
            spells = spells,
        }
    end

    return {
        should_show_effect = should_show_effect,
        get_color = get_color,
        collect_rows = collect_rows,
    }
end

return M
