--- Room node manager: one connection per game server, multiple rooms over same connection.
--- Manager holds fd, reads lines, routes by room_id to room_service; room writes back via write_fd.
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol_pb")

local ROOM_GAME_HOST = "0.0.0.0"
local ROOM_GAME_PORT = tonumber(os.getenv("ROOM_GAME_PORT") or "13002")
--- Room 主动连 Center 的地址（建立长连接，收 create_room 请求）
local CENTER_HOST = os.getenv("CENTER_HOST") or "127.0.0.1"
local CENTER_ROOM_PORT = tonumber(os.getenv("CENTER_ROOM_PORT") or "13005")

--- room_id -> room_service_id
local rooms = {}
--- fd -> { [room_id] = true }, set of rooms this connection is in
local fd_rooms = {}
local stopping = false
local center_fd = 0

--- 下行写回：room_service 调用 write_fd(fd, msg_name, data)，此处组帧并写出。
local function write_fd_binary(fd, msg_name, data)
    if not fd or fd <= 0 then return end
    protocol.write_frame(fd, msg_name, data)
end

local function trim(s)
    return (tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function decode_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_MSG_TYPE", text = "未知消息类型" })
        return nil, nil
    end
    local ok, _msg_name, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误" })
        return nil, nil
    end
    return name, req
end

-- ---------- Upstream message handlers (naming style: same as protocol) ----------
local upstream_handlers = {}

function upstream_handlers.C2SAttachRoom(ctx, req)
    local fd = ctx.fd
    local room_id = req.room_id
    local player_ids = req.player_ids or {}
    if not room_id or room_id == 0 or #player_ids == 0 then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_BAD_ATTACH_ROOM", text = "attach_room 需要 room_id 和 player_ids" })
        return
    end
    local room_sid = rooms[room_id]
    if not room_sid or room_sid == 0 then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_ROOM_NOT_FOUND", text = "房间不存在: " .. room_id })
        return
    end
    moon.send("lua", room_sid, "add_conn", fd, player_ids)
    fd_rooms[fd] = fd_rooms[fd] or {}
    fd_rooms[fd][room_id] = true
end

function upstream_handlers.C2SGuess(ctx, req)
    local fd = ctx.fd
    local rid = req.room_id
    local pid = trim(req.player_id)
    local num = req.number and math.tointeger(req.number)
    if rid == "" or not num then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_BAD_GUESS", text = "C2SGuess 需要 room_id 和 number" })
        return
    end
    local room_sid = rooms[rid]
    if room_sid and room_sid > 0 then
        moon.send("lua", room_sid, "on_msg", fd, pid, "C2SGuess", { number = num })
    else
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_ROOM_NOT_FOUND", text = "房间不存在: " .. rid })
    end
end

local function on_upstream_frame(fd, cmd_id, payload)
    local name, req = decode_frame(fd, cmd_id, payload)
    if not name then
        return
    end
    local fn = upstream_handlers[name]
    if fn then
        fn({ fd = fd }, req)
        return
    end
    write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_CMD", text = "未知命令: " .. name })
end

--- Per-connection read loop: 二进制帧
local function read_loop(fd)
    moon.async(function()
        fd_rooms[fd] = fd_rooms[fd] or {}
        while true do
            if stopping then break end
            local cmd_id, payload = protocol.read_frame(fd)
            if not cmd_id then
                break
            end
            on_upstream_frame(fd, cmd_id, payload)
        end

        for room_id, _ in pairs(fd_rooms[fd] or {}) do
            local room_sid = rooms[room_id]
            if room_sid and room_sid > 0 then
                moon.send("lua", room_sid, "conn_closed", fd)
            end
        end
        fd_rooms[fd] = nil
        socket.close(fd)
    end)
end

--- Advertised address for clients to connect (Center forwards this in match_ok).
local ROOM_GAME_ADDR = os.getenv("ROOM_GAME_ADDR") or ("127.0.0.1:" .. tostring(ROOM_GAME_PORT))

local center_handlers = {}

function center_handlers.RoomCreateRoomReq(ctx, req)
    local fd = ctx.fd
    local room = req.room or {}
    local room_id = room.room_id
    local players = room.players or {}
    if #players == 0 then
        protocol.write_frame(fd, "RoomCreateRoomResp", {
            req_id = req.req_id,
            ok = false,
            err = "bad_args",
            room_info = { room_id = room_id or 0, room_addr = "", players = players },
        })
        return
    end
    print("[room_manager] create_room(req)", room_id, table.concat(players, ","))
    local room_service_id = moon.new_service({ file = "room/room_service.lua" })
    if not room_service_id or room_service_id == 0 then
        protocol.write_frame(fd, "RoomCreateRoomResp", {
            req_id = req.req_id,
            ok = false,
            err = "create_service_failed",
            room_info = { room_id = room_id, room_addr = "", players = players },
        })
        return
    end
    moon.send("lua", room_service_id, "init", moon.id, room_id, table.unpack(players))
    rooms[room_id] = room_service_id
    protocol.write_frame(fd, "RoomCreateRoomResp", {
        req_id = req.req_id,
        ok = true,
        err = "",
        room_info = { room_id = room_id, room_addr = ROOM_GAME_ADDR, players = players },
    })
    print("[room_manager] create_room(resp) ok", room_id, ROOM_GAME_ADDR)
end

local function decode_center_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        return nil, nil
    end
    local ok, _msg_name, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        return nil, nil
    end
    return name, req
end

--- Room 主动连 Center(room_gate)，长连接上读 protobuf RPC 并回复。
local function center_read_loop(fd)
    moon.async(function()
        while fd and fd > 0 and not stopping do
            local cmd_id, payload_or_err = protocol.read_frame(fd)
            if not cmd_id then
                print("[room_manager] center connection closed, err=", payload_or_err or "nil", "reconnect later")
                break
            end
            local name, req = decode_center_frame(fd, cmd_id, payload_or_err)
            if name then
                local fn = center_handlers[name]
                if fn then
                    fn({ fd = fd }, req)
                else
                    print("[room_manager] center rpc unknown:", tostring(name))
                end
            else
                print("[room_manager] center rpc decode failed")
            end
        end
        if fd == center_fd and center_fd > 0 then
            socket.close(center_fd)
            center_fd = 0
        end
        if not stopping then
            -- 连接断开后再尝试重连
            moon.sleep(3000)
            if not stopping then
                require("moon").send("lua", require("moon").id, "connect_center")
            end
        end
    end)
end

--- 连接 Center 并启动读循环；只在未连接时尝试；失败则延时后由自身再次触发。
local function connect_to_center()
    if stopping or (center_fd and center_fd > 0) then
        return
    end
    moon.async(function()
        if stopping then
            return
        end
        local fd = socket.connect(CENTER_HOST, CENTER_ROOM_PORT, moon.PTYPE_SOCKET_TCP, 5000)
        if fd and fd > 0 then
            center_fd = fd
            print("[room_manager] connected to Center", CENTER_HOST, CENTER_ROOM_PORT)
            protocol.write_frame(fd, "RoomNodeRegister", { node_addr = ROOM_GAME_ADDR })
            center_read_loop(fd)
        else
            print("[room_manager] connect to Center failed, retry in 3s")
            moon.sleep(3000)
            if not stopping then
                connect_to_center()
            end
        end
    end)
end

--- Game-server accept: one connection can join multiple rooms; manager reads and routes by room_id.
local function game_listen_loop(listenfd)
    moon.async(function()
        while true do
            local fd, err = socket.accept(listenfd, moon.id)
            if not fd then break end
            read_loop(fd)
        end
    end)
end

local listenfd_game = 0

local command = {}

function command.start()
    listenfd_game = socket.listen(ROOM_GAME_HOST, ROOM_GAME_PORT, moon.PTYPE_SOCKET_TCP)
    if listenfd_game == 0 then
        moon.error("room_manager game listen failed")
        return
    end
    print("room_manager: game listen", ROOM_GAME_HOST, ROOM_GAME_PORT)
    game_listen_loop(listenfd_game)
    connect_to_center()
end

function command.shutdown()
    stopping = true
    if center_fd and center_fd > 0 then
        socket.close(center_fd)
        center_fd = 0
    end
    if listenfd_game and listenfd_game > 0 then
        socket.close(listenfd_game)
        listenfd_game = 0
    end
    moon.quit()
end

function command.write_fd(fd, msg_name, data)
    if fd and fd > 0 and msg_name then
        write_fd_binary(fd, msg_name, data or {})
    end
end

function command.room_closed(rid)
    if rid then
        rooms[rid] = nil
    end
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    if cmd == "connect_center" then
        connect_to_center()
        return
    end
    local fn = command[cmd]
    if fn then
        fn(...)
    else
        moon.error("room_manager unknown", cmd)
    end
end)
