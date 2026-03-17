--- Game server <-> Moon line protocol.
--- Usage (reference MoonDemo common.protocol):
---   local name, req = protocol.decode(line)   -- req = { player_id, cmd, args }
---   handlers[name](req)
---   socket.write(fd, protocol.encode(player_id, cmd, data))
---   socket.write(fd, protocol.encode_downstream(target, player_ids, cmd, data))
---
--- Upstream: player_id\tcmd\t[arg1\targ2...]\n
--- Downstream: target\tplayer_id(s)\tcmd\tdata\n

local protocol = {}

protocol.DOWNSTREAM_SEP = "\t"

local function trim(line)
    return (line and tostring(line)):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Parse upstream line into parts. Internal.
local function parse_upstream(line)
    line = trim(line)
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

--- Decode upstream line. Returns cmd_name, req (table) like MoonDemo protocol.decode.
--- req has: player_id, cmd, args. Caller can dispatch with handlers[name](req).
function protocol.decode(line)
    if not line or trim(line) == "" then
        return nil, nil
    end
    local req = parse_upstream(line)
    if req.cmd == "" then
        return nil, nil
    end
    return req.cmd, req
end

--- Encode upstream message. data can be nil, a table (args), or varargs.
--- Like MoonDemo protocol.encode(uid, id, t).
function protocol.encode(player_id, cmd, data)
    local parts = { tostring(player_id), tostring(cmd) }
    if data ~= nil then
        if type(data) == "table" then
            for i = 1, #data do
                parts[#parts + 1] = tostring(data[i])
            end
        else
            parts[#parts + 1] = tostring(data)
        end
    end
    return table.concat(parts, "\t") .. "\n"
end

--- Encode downstream message (Center/Room -> client).
function protocol.encode_downstream(target, player_ids, cmd, data)
    local ids = type(player_ids) == "table" and table.concat(player_ids, ",") or tostring(player_ids)
    return target .. protocol.DOWNSTREAM_SEP .. ids .. protocol.DOWNSTREAM_SEP .. tostring(cmd) .. protocol.DOWNSTREAM_SEP .. tostring(data or "") .. "\n"
end

--- Decode downstream line (client side). Returns target, player_ids_str, cmd, data.
function protocol.decode_downstream(line)
    line = trim(line)
    local a, b, c, d = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if not a or not c then
        return nil, nil, nil, nil
    end
    return a, b or "", c, d or ""
end

--- Upstream with room_id: room_id\tplayer_id\tcmd\targ1...
function protocol.encode_with_room(room_id, player_id, cmd, ...)
    local parts = { room_id, player_id, cmd }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, "\t") .. "\n"
end

--- Decode upstream line with room_id. Returns cmd, req where req has room_id, player_id, cmd, args.
function protocol.decode_with_room(line)
    line = trim(line)
    local parts = {}
    for s in line:gmatch("%S+") do
        parts[#parts + 1] = s
    end
    if #parts < 3 then
        return nil, nil
    end
    local args = {}
    for i = 4, #parts do
        args[#args + 1] = parts[i]
    end
    local req = {
        room_id = parts[1],
        player_id = parts[2],
        cmd = parts[3],
        args = args,
    }
    return req.cmd, req
end

-- Backward compatibility aliases
protocol.parse_upstream = function(line)
    local req = parse_upstream(line)
    return req
end
protocol.format_downstream = protocol.encode_downstream
protocol.format_upstream = protocol.encode
protocol.format_upstream_with_room = protocol.encode_with_room
protocol.parse_upstream_with_room = function(line)
    local cmd, req = protocol.decode_with_room(line)
    if not req then return nil end
    return req.room_id, req.player_id, req.cmd, req.args
end

return protocol
