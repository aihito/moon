--- Bridge: 持有一条与游戏服的 fd，维护 player_id->room_id 路由；上行按协议分发，下行写 fd。
--- 协议与格式见 protocol.lua；扩展新上行命令只需在 upstream_handlers 中加一项。
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol")

local fd = 0
local player_room = {}  -- player_id -> room_id
local addr_center = 0

local function write_downstream(target, player_ids, cmd, data)
    if fd <= 0 then return end
    socket.write(fd, protocol.format_downstream(target, player_ids, cmd, data))
end

--- 上行命令处理表：cmd -> function(req) ，扩展新命令在此添加
local upstream_handlers = {}

function upstream_handlers.ready(req)
    moon.send("lua", addr_center, "ready", { player_id = req.player_id, name = req.player_id })
end

upstream_handlers.join_match = upstream_handlers.ready

function upstream_handlers.guess(req)
    local room_id = player_room[req.player_id]
    if room_id and room_id > 0 then
        moon.send("lua", room_id, "guess", req.player_id, req.args[1])
    else
        write_downstream("player", req.player_id, "msg", "你不在房间中")
    end
end

local function on_upstream_line(data)
    local req = protocol.parse_upstream(data)
    if req.player_id == "" or req.cmd == "" then
        return
    end
    local fn = upstream_handlers[req.cmd]
    if fn then
        fn(req)
    else
        write_downstream("player", req.player_id, "msg", "未知命令: " .. req.cmd)
    end
end

local function start_read_loop()
    moon.async(function()
        while fd > 0 do
            local data, err = socket.read(fd, "\n")
            if not data then
                if fd > 0 then socket.close(fd) end
                fd = 0
                return
            end
            on_upstream_line(data)
        end
    end)
end

--- 内部命令（center/room 调用）
local command = {}

function command.set_fd(new_fd)
    if fd > 0 then socket.close(fd) end
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
