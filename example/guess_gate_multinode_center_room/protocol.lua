--- Game server <-> Moon line protocol (same as guess_gate).
--- Upstream: player_id cmd [arg1 arg2 ...]
--- Downstream: target\tplayer_id(s)\tcmd\tdata

local protocol = {}

protocol.DOWNSTREAM_SEP = "\t"

function protocol.parse_upstream(line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    local parts = {}
    for s in line:gmatch("%S+") do
        parts[#parts + 1] = s
    end
    local args = {}
    for i = 3, #parts do
        args[#args + 1] = parts[i]
    end
    return {
        player_id = parts[1] or "",
        cmd = parts[2] or "",
        args = args,
    }
end

function protocol.format_downstream(target, player_ids, cmd, data)
    local ids = type(player_ids) == "table" and table.concat(player_ids, ",") or tostring(player_ids)
    local sep = protocol.DOWNSTREAM_SEP
    return target .. sep .. ids .. sep .. tostring(cmd) .. sep .. tostring(data or "") .. "\n"
end

function protocol.format_upstream(player_id, cmd, ...)
    local parts = { player_id, cmd }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, "\t") .. "\n"
end

return protocol
