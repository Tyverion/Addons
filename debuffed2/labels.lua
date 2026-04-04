local M = {}

local Cities = S{
    70, 247, 256, 249, 244, 234, 245, 257,
    246, 248, 230, 53, 236, 233, 223, 238,
    235, 226, 239, 240, 232, 250, 231, 284,
    242, 26, 252, 280, 285, 225, 224, 237, 50,
    241, 243, 71
}

local function letter_suffix(num)
    local s = ''
    while num >= 1 do
        local m = (num - 1) % 26 + string.byte('A')
        s = string.char(m) .. s
        num = math.floor((num - 1) / 26)
    end
    return ' ' .. s
end

local function slug(name)
    return (name or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
end

local function escape_pat(s)
    return (s:gsub('(%W)', '%%%1'))
end

function M.prepare_names()
    if not settings.rename_duplicates then
        active_renames = false
        return
    end

    if Cities[windower.ffxi.get_info().zone] then
        active_renames = false
        return
    end

    zonecache = {}
    local mobs = windower.ffxi.get_mob_list()
    local duplicates = {}

    for index, name in pairs(mobs) do
        if #name > 1 then
            local list = duplicates[name]
            if list then
                list[#list + 1] = index
            else
                duplicates[name] = {index}
            end
        end
    end

    for name, indexes in pairs(duplicates) do
        if name ~= 'n' and #indexes > 1 then
            table.sort(indexes)
            local counter = 1
            for _, index in ipairs(indexes) do
                zonecache[index] = name:sub(1, 20) .. letter_suffix(counter)
                counter = counter + 1
            end
        end
    end

    renames = {}
    for idx in pairs(zonecache) do
        local t = windower.ffxi.get_mob_by_index(idx)
        if t and t.spawn_type == 0x010 then
            renames[t.id] = zonecache[idx]
            zonecache[idx] = nil
        end
    end

    active_renames = true

    for id, label in pairs(renames) do
        label_for_id[id] = label
        id_for_label[label] = id
        id_for_label_lower[label:lower()] = id
    end
end

function M.reset_labels()
    label_for_id = {}
    id_for_label = {}
    id_for_label_lower = {}
    next_letter = {}
    debuffed_mobs = {}
    mob_hp = {}
    mob_action = {}
    watch = nil
    pending_expiries = {}
    expiry_flush = false
    pending_queue = {}
    sending_queue = false
    renames = {}
    zonecache = {}
    active_renames = false
end

function M.assign_label(id, name)
    if not id or not name then
        return nil
    end
    if renames[id] then
        local label = renames[id]
        label_for_id[id] = label
        id_for_label[label] = id
        id_for_label_lower[label:lower()] = id
        return label
    end
    if label_for_id[id] then
        return label_for_id[id]
    end
    local key = slug(name)
    if key == '' then
        return nil
    end
    local letter = next_letter[key] or 'A'
    local label = string.format('%s %s', key, letter)
    label_for_id[id] = label
    id_for_label[label] = id
    id_for_label_lower[label:lower()] = id
    local code = letter:byte()
    if code >= 65 and code < 90 then
        next_letter[key] = string.char(code + 1)
    else
        next_letter[key] = 'A'
    end
    return label
end

function M.id_from_label(label)
    if not label then
        return nil
    end
    return id_for_label[label] or id_for_label_lower[label:lower()]
end

function M.relabel_name(key)
    if not key or key == '' then
        return
    end
    local pat = '^' .. escape_pat(key) .. ' %u$'
    local ids = {}
    for id, lbl in pairs(label_for_id) do
        if lbl:match(pat) then
            ids[#ids + 1] = id
            id_for_label[lbl] = nil
            id_for_label_lower[lbl:lower()] = nil
        end
    end
    table.sort(ids)
    local code = string.byte('A')
    for _, id in ipairs(ids) do
        local letter = string.char(code)
        local newlabel = string.format('%s %s', key, letter)
        label_for_id[id] = newlabel
        id_for_label[newlabel] = id
        id_for_label_lower[newlabel:lower()] = id
        code = code + 1
    end
    if #ids > 0 then
        next_letter[key] = string.char(code)
    else
        next_letter[key] = 'A'
    end
end

function M.resolve_watch_label(input)
    if not input or input == '' then
        return nil, 'empty'
    end

    local id = M.id_from_label(input)
    if id then
        return id, input
    end

    local lower = input:lower()
    local tokens = lower:split(' ')
    local suffix
    if #tokens >= 2 and #tokens[#tokens] == 1 then
        suffix = tokens[#tokens]
        table.remove(tokens, #tokens)
    end
    local namepart = table.concat(tokens, ' ')
    if namepart == '' then
        return nil, 'no_name'
    end

    local matches = {}
    for lbl, tid in pairs(id_for_label_lower) do
        local l = lbl:lower()
        local name_ok = l:find(namepart, 1, true) ~= nil
        local suffix_ok = (not suffix) or l:sub(-1) == suffix
        if name_ok and suffix_ok then
            matches[#matches + 1] = {id = tid, label = lbl}
        end
    end

    if #matches == 1 then
        return matches[1].id, matches[1].label
    end
    return nil, (#matches == 0) and 'not_found' or 'ambiguous'
end

function M.parse_wore_message(message)
    if not message or message == '' then
        return nil, nil
    end

    local trimmed = message:gsub('%s+$', '')
    if not trimmed:match(' wore!$') then
        return nil, nil
    end

    local body = trimmed:gsub(' wore!$', '')
    local best_label
    local best_id

    for label, tid in pairs(id_for_label) do
        local prefix = label .. ' '
        if body:sub(1, #prefix):lower() == prefix:lower() then
            if not best_label or #label > #best_label then
                best_label = label
                best_id = tid
            end
        end
    end

    if not best_label then
        return nil, nil
    end

    local buff_name = body:sub(#best_label + 2)
    if buff_name == '' then
        return nil, nil
    end

    return best_id, buff_name
end

return M
