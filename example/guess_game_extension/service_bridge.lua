--- Bridge: holds the single fd to game server; routes upstream to center/room, downstream to fd.
--- Protocol: one line per message. Up: "player_id\tcmd\targ1\targ2..."; Down: "target\tplayer_id(s)\tcmd\tdata"
local moon = require("moon")
local socket = require("moon.socket")

local fd = 0
local player_room = {}  -- player_id -> room_id
local addr_center = 0

local function write_downstream(target, player_ids, cmd, data)
    if fd <= 0 then return end
    local ids = type(player_ids) == "table" and table.concat(player_ids, ",") or tostring(player_ids)
    local line = target .. "\t" .. ids .. "\t" .. tostring(cmd) .. "\t" .. tostring(data or "") .. "\n"
    socket.write(fd, line)
end

local function start_read_loop()
    moon.async(function()
        while fd > 0 do
            local data, err = socket.read(fd, "\n")
            if not data then
                if fd > 0 then
                    socket.close(fd)
                end
                fd = 0
                return
            end
            data = data:gsub("^%s+", ""):gsub("%s+$", "")
            if #data == 0 then goto continue end

            local parts = {}
            for s in (data .. "\t"):gmatch("(.-)\t") do
                parts[#parts + 1] = s
            end
            local player_id = parts[1]
            local cmd = parts[2] or ""
            local arg1 = parts[3]

            if cmd == "ready" or cmd == "join_match" then
                moon.send("lua", addr_center, "ready", { player_id = player_id, name = player_id })
            elseif cmd == "guess" then
                local room_id = player_room[player_id]
                if room_id and room_id > 0 then
                    moon.send("lua", room_id, "guess", player_id, arg1)
                else
                    write_downstream("player", player_id, "msg", "你不在房间中")
                end
            else
                write_downstream("player", player_id, "msg", "未知命令: " .. cmd)
            end
            ::continue::
        end
    end)
end

local command = {}

function command.set_fd(new_fd)
    if fd > 0 then
        socket.close(fd)
    end
    fd = new_fd
    addr_center = moon.queryservice("center")
    write_downstream("player", "*", "msg", "欢迎来到猜数字扩展，输入 ready 匹配，匹配成功后输入 guess <1-100>")
    start_read_loop()
end

function command.forward(target, player_id, _session_id, cmd, data)
    write_downstream(target or "player", player_id, cmd, data)
end

function command.forward_broadcast(player_ids, _session_id, cmd, data)
    write_downstream("broadcast", player_ids, cmd, data)
end

function command.register_room(tbl)
    for pid, rid in pairs(tbl) do
        player_room[pid] = rid
    end
end

function command.unregister_room(player_ids)
    for _, pid in ipairs(player_ids) do
        player_room[pid] = nil
    end
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        fn(...)
        if session and session > 0 then
            moon.response("lua", sender, session, true)
        end
    else
        moon.error("bridge unknown command", cmd, ...)
    end
end)
