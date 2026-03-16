--- Single bridge holding multiple game-server fds (one bridge, multi-connection).
--- Maintains player_id -> fd; upstream to center, downstream by player_id.
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("protocol")

local addr_center = 0
local player_fd = {}   -- player_id -> fd
local conns = {}       -- fd -> true

local function write_downstream(fd, target, player_ids, cmd, data)
    if not fd or not conns[fd] then return end
    socket.write(fd, protocol.format_downstream(target, player_ids, cmd, data))
end

local upstream_handlers = {}

function upstream_handlers.ready(req)
    player_fd[req.player_id] = req.fd
    if addr_center == 0 then addr_center = moon.queryservice("center") end
    moon.send("lua", addr_center, "ready", { player_id = req.player_id, name = req.player_id })
end

upstream_handlers.join_match = upstream_handlers.ready

function upstream_handlers.guess(req)
    -- room_action goes to Room node; in this demo we keep guess on Center->Room via game servers
    -- so bridge only sees ready/join_match for match phase; guess is sent to Room node by game server
    -- So we don't handle guess here; game server sends guess to Room node after attach_room
    write_downstream(req.fd, "player", req.player_id, "msg", "请先匹配并连接房间服")
end

local function on_upstream_line(fd, data)
    local req = protocol.parse_upstream(data)
    if req.player_id == "" or req.cmd == "" then return end
    req.fd = fd
    player_fd[req.player_id] = fd
    local fn = upstream_handlers[req.cmd]
    if fn then
        fn(req)
    else
        write_downstream(fd, "player", req.player_id, "msg", "未知命令: " .. req.cmd)
    end
end

local function start_read_loop(fd)
    moon.async(function()
        while conns[fd] do
            local data, err = socket.read(fd, "\n")
            if not data then
                conns[fd] = nil
                for pid, f in pairs(player_fd) do
                    if f == fd then player_fd[pid] = nil end
                end
                if fd > 0 then socket.close(fd) end
                return
            end
            on_upstream_line(fd, data)
        end
    end)
end

local command = {}

function command.add_fd(fd)
    conns[fd] = true
    if addr_center == 0 then addr_center = moon.queryservice("center") end
    write_downstream(fd, "player", "*", "msg", "欢迎，输入 ready 匹配；匹配成功后请连接房间服")
    start_read_loop(fd)
end

function command.forward(target, player_id, _session_id, cmd, data)
    local fd = player_fd[player_id]
    if fd then
        write_downstream(fd, target or "player", player_id, cmd, data)
    end
end

function command.forward_broadcast(player_ids, _session_id, cmd, data)
    local by_fd = {}
    for _, pid in ipairs(player_ids) do
        local fd = player_fd[pid]
        if fd then
            if not by_fd[fd] then by_fd[fd] = {} end
            by_fd[fd][#by_fd[fd] + 1] = pid
        end
    end
    for fd, pids in pairs(by_fd) do
        write_downstream(fd, "broadcast", pids, cmd, data)
    end
end

function command.register_room(_tbl) end
function command.unregister_room(_player_ids) end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        fn(...)
        if session and session > 0 then
            moon.response("lua", sender, session, true)
        end
    else
        moon.error("bridge_multi unknown command", cmd, ...)
    end
end)
