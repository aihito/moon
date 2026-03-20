--- Bridge: 客户端 <-> Center，二进制 protobuf 帧。
--- 帧格式见 shared/protocol_pb；上行 C2S 解析后转发 center，下行 S2C 由 match 经 forward 写出。
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol_pb")

local addr_match = 0
local player_fd = {}
local conns = {}
local listenfd = 0

local function write_game_packet(fd, player_id, inner_msg_name, inner_data)
    if not fd or fd <= 0 then return end
    local inner_cmd_id = protocol.cmd_id(inner_msg_name)
    if not inner_cmd_id then
        print("[bridge] write_game_packet unknown inner msg:", tostring(inner_msg_name))
        return
    end
    local inner_payload = protocol.encode(inner_msg_name, inner_data or {})
    if not inner_payload then
        print("[bridge] write_game_packet encode failed:", tostring(inner_msg_name))
        return
    end
    protocol.write_frame(fd, "GamePacket", {
        player_id = tostring(player_id or ""),
        inner_cmd_id = inner_cmd_id,
        inner_payload = inner_payload,
    })
end

local function write_downstream(fd, player_id, msg_name, data)
    if not fd or not conns[fd] then
        return
    end
    write_game_packet(fd, player_id, msg_name, data)
end

local upstream_handlers = {}

function upstream_handlers.C2SReady(req)
    req.fd = req.fd
    local pid = req.player_id
    if pid and pid ~= "" then
        player_fd[pid] = req.fd
        print("[bridge] player registered: pid=", pid, "fd=", req.fd)
    end
    moon.send("lua", addr_match, "ready", { player_id = pid, name = pid })
end

function upstream_handlers.C2SGuess(req)
    write_downstream(req.fd, req.player_id, "S2CNotify", { reason = "NOTIFY_REASON_NEED_MATCH_FIRST", text = "请先匹配并连接房间服" })
end

local function on_upstream_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        write_downstream(fd, "", "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_MSG_TYPE", text = "未知消息类型" })
        return
    end

    if name == "GamePacket" then
        local ok, _outer_name, wrapper = pcall(protocol.decode, name, payload)
        if not ok or not wrapper then
            write_downstream(fd, "", "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误(GamePacket)" })
            return
        end
        local inner_name, inner_req = protocol.decode(wrapper.inner_cmd_id, wrapper.inner_payload)
        if not inner_name or not inner_req then
            write_downstream(fd, wrapper.player_id, "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误(inner)" })
            return
        end

        -- 给 handler 统一补一个 player_id（有的 inner message 可能没有该字段）
        inner_req.fd = fd
        if wrapper.player_id and wrapper.player_id ~= "" and (not inner_req.player_id or inner_req.player_id == "") then
            inner_req.player_id = wrapper.player_id
        end

        local fn = upstream_handlers[inner_name]
        if fn then
            fn(inner_req)
        else
            write_downstream(fd, wrapper.player_id, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_CMD", text = "未知命令: " .. inner_name })
        end
        return
    end

    -- 兼容：如果客户端仍在发旧协议（不使用 GamePacket），就按旧逻辑处理
    local ok, _msg_name, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        write_downstream(fd, "", "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误" })
        return
    end

    req.fd = fd
    if req.player_id then
        player_fd[req.player_id] = fd
    end

    local fn = upstream_handlers[name]
    if fn then
        fn(req)
    else
        write_downstream(fd, req.player_id, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_CMD", text = "未知命令: " .. name })
    end
end

--- 读循环：不在 fd 上 settimeout（C++ 超时会 close(fd) 导致断线）。每处理完一帧后 moon.sleep(0) 让出，
--- 以便本 worker 处理消息队列中的 forward(S2CMatchOk)。
--- 关键点：不要用无 timeout 的 socket.read，否则会阻塞整个 worker，导致 forward 写包也得不到调度。
local function start_read_loop(fd)
    moon.async(function()
        -- 使用当前 moon.socket.read 接口不支持 frame-level timeout。
        -- 这里仅依靠 moon.sleep(0) 让出调度，保证 forward(S2CMatchOk) 能及时执行。
        while conns[fd] do
            local cmd_id, payload_or_err = protocol.read_frame(fd)
            if not cmd_id then
                print(string.format("[bridge] read failed, closing fd=%d err=%s", fd, payload_or_err or "nil"))
                conns[fd] = nil
                for pid, f in pairs(player_fd) do
                    if f == fd then
                        player_fd[pid] = nil
                    end
                end
                if fd > 0 then
                    socket.close(fd)
                end
                return
            end
            on_upstream_frame(fd, cmd_id, payload_or_err)
            moon.sleep(0)
        end
    end)
end

local command = {}

function command.start(host, port)
    if listenfd and listenfd > 0 then
        return
    end

    listenfd = socket.listen(host, port, moon.PTYPE_SOCKET_TCP)
    if listenfd == 0 then
        print("[bridge] center listen failed", host, port)
        return
    end

    print("[bridge] center_node: listen", host, port, "(game servers connect here)")

    moon.async(function()
        while listenfd and listenfd > 0 do
            local fd, err = socket.accept(listenfd, moon.id)
            if not fd then
                print("[bridge] center accept error:", err)
            else
                command.add_fd(fd)
            end
        end
    end)

    addr_match = moon.queryservice("match")
    if not addr_match or addr_match == 0 then
        print("[bridge] match service not found")
        return
    end
end

function command.add_fd(fd)
    conns[fd] = true
    print("[bridge] add_fd fd=", fd)
    write_downstream(fd, "", "S2CNotify", { reason = "NOTIFY_REASON_WELCOME", text = "欢迎，客户端将自动 ready；匹配成功后请连接房间服" })
    start_read_loop(fd)
end

function command.forward(target, player_id, _session_id, msg_name, data)
    local fd = player_fd[player_id]
    print(string.format("[bridge] forward to player: fd=%d player_id=%s msg_name=%s data=%s", fd, player_id, msg_name, print_r(data, true)))
    if fd and conns[fd] then
        write_downstream(fd, player_id, msg_name, data or {})
    end
end

function command.forward_broadcast(player_ids, _session_id, msg_name, data)
    for _, pid in ipairs(player_ids) do
        local fd = player_fd[pid]
        if fd and conns[fd] then
            write_downstream(fd, pid, msg_name, data)
        end
    end
end

function command.shutdown()
    if listenfd and listenfd > 0 then
        socket.close(listenfd)
        listenfd = 0
    end
    for fd, _ in pairs(conns) do
        if fd and fd > 0 then
            socket.close(fd)
        end
        conns[fd] = nil
    end
    for pid, _ in pairs(player_fd) do
        player_fd[pid] = nil
    end
    moon.quit()
end

moon.dispatch(
    "lua",
    function(sender, session, cmd, ...)
        local fn = command[cmd]
        if fn then
            fn(...)
            if session and session > 0 then
                moon.response("lua", sender, session, true)
            end
        else
            moon.error("bridge unknown command", cmd, ...)
        end
    end
)
