--- Bridge: 客户端 <-> Center，二进制 protobuf 帧。
--- 帧格式见 shared/protocol_pb；上行 C2S 解析后转发 center，下行 S2C 由 match 经 forward 写出。
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol_pb")

local addr_center = 0
local player_fd = {}
local conns = {}

local function write_downstream(fd, target, player_id, msg_name, data)
    if not fd or not conns[fd] then return end
    protocol.write_frame(fd, msg_name, data)
end

local upstream_handlers = {}

function upstream_handlers.C2SReady(req)
    req.fd = req.fd
    local pid = (req.player_id and tostring(req.player_id)):gsub("^%s+", ""):gsub("%s+$", "")
    if pid ~= "" and pid ~= "nil" then
        player_fd[pid] = req.fd
        print("[bridge] player registered: pid=", pid, "fd=", req.fd)
    end
    if addr_center == 0 then addr_center = moon.queryservice("center") end
    moon.send("lua", addr_center, "ready", { player_id = pid, name = pid })
end

upstream_handlers.join_match = upstream_handlers.C2SReady

function upstream_handlers.C2SGuess(req)
    write_downstream(req.fd, "player", req.player_id, "S2CMsg", { text = "请先匹配并连接房间服" })
end

local function on_upstream_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        write_downstream(fd, "player", "*", "S2CMsg", { text = "未知消息类型" })
        return
    end
    local ok, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        write_downstream(fd, "player", "*", "S2CMsg", { text = "协议解析错误" })
        return
    end
    req.fd = fd
    if req.player_id then
        local pid = (tostring(req.player_id)):gsub("^%s+", ""):gsub("%s+$", "")
        req.player_id = pid
        player_fd[pid] = fd
    end
    local fn = upstream_handlers[name]
    if fn then
        fn(req)
    else
        write_downstream(fd, "player", req.player_id or "*", "S2CMsg", { text = "未知命令: " .. name })
    end
end

local function start_read_loop(fd)
    moon.async(function()
        while conns[fd] do
            local cmd_id, payload = protocol.read_frame(fd)
            if not cmd_id then
                conns[fd] = nil
                for pid, f in pairs(player_fd) do
                    if f == fd then player_fd[pid] = nil end
                end
                if fd > 0 then socket.close(fd) end
                return
            end
            on_upstream_frame(fd, cmd_id, payload)
        end
    end)
end

local command = {}

function command.add_fd(fd)
    conns[fd] = true
    if addr_center == 0 then
        addr_center = moon.queryservice("center")
    end
    write_downstream(fd, "player", "*", "S2CMsg", { text = "欢迎，输入 ready 匹配；匹配成功后请连接房间服" })
    local cmd_id, payload = protocol.read_frame(fd, 300)
    if cmd_id then
        on_upstream_frame(fd, cmd_id, payload)
    end
    start_read_loop(fd)
end

function command.forward(target, player_id, _session_id, msg_name, data)
    if msg_name == "S2CMatchOk" then
        print("[bridge] forward match_ok recv player=", player_id)
    end
    local fd = player_fd[player_id]
    if fd and conns[fd] then
        protocol.write_frame(fd, msg_name, data)
        if msg_name == "S2CMatchOk" then
            print("[bridge] forward match_ok written ->", player_id, "fd=", fd)
        end
    elseif msg_name == "S2CMatchOk" then
        print("[bridge] forward match_ok SKIP: no fd for player", player_id)
    end
end

function command.forward_broadcast(player_ids, _session_id, msg_name, data)
    for _, pid in ipairs(player_ids) do
        local fd = player_fd[pid]
        if fd and conns[fd] then
            protocol.write_frame(fd, msg_name, data)
        end
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
        moon.error("bridge unknown command", cmd, ...)
    end
end)
