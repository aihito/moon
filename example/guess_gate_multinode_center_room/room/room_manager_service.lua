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

--- 上行帧处理：C2SAttachRoom / C2SGuess
local function on_upstream_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_MSG_TYPE", text = "未知消息类型" })
        return
    end
    local ok, _msg_name, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误" })
        return
    end

    if name == "C2SAttachRoom" then
        local room_id = req.room_id and tostring(req.room_id) or ""
        local player_ids = req.player_ids or {}
        if room_id == "" or #player_ids == 0 then
            write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_BAD_ATTACH_ROOM", text = "attach_room 需要 room_id 和 player_ids" })
            return
        end
        local room_sid = rooms[room_id]
        if not room_sid or room_sid == 0 then
            write_fd_binary(fd, "S2CNotify", { reason = "NOTIFY_REASON_ROOM_NOT_FOUND", text = "房间不存在: " .. room_id })
            return
        end
        moon.send("lua", room_sid, "add_conn", fd, player_ids)
        if not fd_rooms[fd] then fd_rooms[fd] = {} end
        fd_rooms[fd][room_id] = true
        return
    end

    if name == "C2SGuess" then
        local rid = req.room_id and tostring(req.room_id) or ""
        local pid = req.player_id and tostring(req.player_id) or ""
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

--- RPC 命令处理表：cmd -> handler(ctx)。RPC 协议为 \t 分隔，首段为 cmd。
local rpc_handlers = {}

--- Advertised address for clients to connect (Center forwards this in match_ok).
local ROOM_GAME_ADDR = os.getenv("ROOM_GAME_ADDR") or ("127.0.0.1:" .. tostring(ROOM_GAME_PORT))

function rpc_handlers.create_room(ctx)
    local fd = ctx.fd
    local parts = ctx.parts
    if #parts < 3 then
        print("[room_manager] create_room bad_args")
        socket.write(fd, "error\tbad_args\n")
        return
    end
    local room_id = parts[2]
    local players = {}
    for i = 3, #parts do
        players[#players + 1] = parts[i]
    end
    print("[room_manager] create_room", room_id, table.concat(players, ","))
    local sid = moon.new_service({ file = "room/room_service.lua" })
    if sid == 0 then
        print("[room_manager] create_room new_service failed")
        socket.write(fd, "error\tcreate_service_failed\n")
        return
    end
    moon.send("lua", sid, "init", moon.id, room_id, table.unpack(players))
    rooms[room_id] = sid
    -- Reply with room_id and room_addr so Center can notify clients (match_ok).
    socket.write(fd, ("ok\t%s\t%s\n"):format(room_id, ROOM_GAME_ADDR))
    print("[room_manager] create_room ok", room_id, ROOM_GAME_ADDR)
end

--- RPC 每行统一入口：\t 切分，按 cmd 查表分发。
local function on_rpc_line(fd, line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return end
    local parts = {}
    for s in line:gmatch("[^\t]+") do
        parts[#parts + 1] = s
    end
    if #parts == 0 then return end
    local cmd = parts[1]
    local handler = rpc_handlers[cmd]
    if handler then
        handler({ fd = fd, line = line, parts = parts })
    else
        socket.write(fd, "error\tunknown_rpc\n")
    end
end

--- Room 主动连 Center，长连接上读 create_room 请求并回复。
local function center_read_loop(fd)
    moon.async(function()
        while fd and fd > 0 and not stopping do
            local line, err = socket.read(fd, "\n")
            if not line then
                print("[room_manager] center connection closed, err=", err or "nil", "reconnect later")
                break
            end
            print("[room_manager] center rpc recv:", line:sub(1, 80))
            on_rpc_line(fd, line)
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
        if stopping then return end
        local fd = socket.connect(CENTER_HOST, CENTER_ROOM_PORT, moon.PTYPE_SOCKET_TCP, 5000)
        if fd and fd > 0 then
            center_fd = fd
            print("[room_manager] connected to Center", CENTER_HOST, CENTER_ROOM_PORT)
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

--- 内部命令表：cmd -> fn(sender, session, ...)，便于扩展。
local command = {}

function command.start(sender, session)
    listenfd_game = socket.listen(ROOM_GAME_HOST, ROOM_GAME_PORT, moon.PTYPE_SOCKET_TCP)
    if listenfd_game == 0 then
        moon.error("room_manager game listen failed")
        if session and session > 0 then moon.response("lua", sender, session, false) end
        return
    end
    print("room_manager: game listen", ROOM_GAME_HOST, ROOM_GAME_PORT)
    game_listen_loop(listenfd_game)
    connect_to_center()
    if session and session > 0 then moon.response("lua", sender, session, true) end
end

function command.shutdown(sender, session)
    stopping = true
    if center_fd and center_fd > 0 then
        socket.close(center_fd)
        center_fd = 0
    end
    if listenfd_game and listenfd_game > 0 then
        socket.close(listenfd_game)
        listenfd_game = 0
    end
    if session and session > 0 then moon.response("lua", sender, session, true) end
end

function command.write_fd(_sender, _session, fd, msg_name, data)
    if fd and fd > 0 and msg_name then
        write_fd_binary(fd, msg_name, data or {})
    end
end

function command.room_closed(_sender, _session, rid)
    if rid then rooms[rid] = nil end
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    if cmd == "connect_center" then
        connect_to_center()
        return
    end
    local fn = command[cmd]
    if fn then
        fn(sender, session, ...)
    else
        moon.error("room_manager unknown", cmd)
    end
end)
