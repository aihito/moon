--- 游戏服 <-> Moon 行协议：上行/下行格式与解析，便于扩展新命令。
--- 上行：player_id cmd [arg1 arg2 ...]（空格或 Tab 分隔）
--- 下行：target\tplayer_id(s)\tcmd\tdata（Tab 分隔）

local protocol = {}

--- 下行字段分隔符（游戏服解析用）
protocol.DOWNSTREAM_SEP = "\t"

--- 解析上行一行 -> { player_id, cmd, args = { ... } }
--- 支持空格或 Tab 分隔，便于 telnet 输入。
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

--- 拼下行一行：target\tplayer_id(s)\tcmd\tdata\n
function protocol.format_downstream(target, player_ids, cmd, data)
    local ids = type(player_ids) == "table" and table.concat(player_ids, ",") or tostring(player_ids)
    local sep = protocol.DOWNSTREAM_SEP
    return target .. sep .. ids .. sep .. tostring(cmd) .. sep .. tostring(data or "") .. "\n"
end

--- 拼上行一行（给 game_server_sim 或脚本用）：player_id\tcmd\targ1\t...
function protocol.format_upstream(player_id, cmd, ...)
    local parts = { player_id, cmd }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, "\t") .. "\n"
end

return protocol
