--- Room node manager: one connection per game server, multiple rooms over same connection.
--- Manager holds fd, reads lines, routes by room_id to room_service; room writes back via write_fd.
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol_pb")

local ROOM_GAME_HOST = "0.0.0.0"
local ROOM_GAME_PORT = tonumber(os.getenv("ROOM_GAME_PORT") or "13002")
local ROOM_GAME_ADDR = os.getenv("ROOM_GAME_ADDR") or ("127.0.0.1:" .. tostring(ROOM_GAME_PORT))
--- Room 主动连 Center 的地址（建立长连接，收 create_room 请求）
local CENTER_HOST = os.getenv("CENTER_HOST") or "127.0.0.1"
local CENTER_ROOM_PORT = tonumber(os.getenv("CENTER_ROOM_PORT") or "13005")

local rooms = {} -- room_id -> { service_id = room_service_id, players = { player_id... } }
local player_route = {}
local stopping = false
local center_fd = 0

local function write_fd_binary(fd, player_id, msg_name, data)
    data = data or {}

    local inner_cmd_id = protocol.cmd_id(msg_name)
    if not inner_cmd_id then
        return
    end

    local inner_payload = protocol.encode(msg_name, data)
    if not inner_payload then
        return
    end

    protocol.write_frame(
        fd,
        "GamePacket",
        {
            player_id = tostring(player_id or ""),
            inner_cmd_id = inner_cmd_id,
            inner_payload = inner_payload,
        }
    )
end

local function write_player_msg(player_id, msg_name, data)
    data = data or {}

    if not player_id or player_id == "" then
        return
    end

    local fd = player_route[player_id]
    if not fd or fd <= 0 then
        return
    end

    write_fd_binary(fd, player_id, msg_name, data)
end

local function write_room_msg(room_id, msg_name, data)
    data = data or {}

    if not room_id or room_id == 0 then
        return
    end

    local players = rooms[room_id].players
    if not players or #players == 0 then
        return
    end

    for _, player_id in ipairs(players) do
        write_player_msg(player_id, msg_name, data)
    end
end

local function decode_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_MSG_TYPE", text = "未知消息类型" })
        return nil
    end

    if name ~= "GamePacket" then
        print(string.format("[room_manager] decode_frame: unknown message type: %s", name))
        return nil
    end

    local ok, _outer_name, wrapper = pcall(protocol.decode, name, payload)
    if not ok or not wrapper then
        write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误(GamePacket)" })
        return nil
    end

    local inner_name, inner_req = protocol.decode(wrapper.inner_cmd_id, wrapper.inner_payload)
    if not inner_name or not inner_req then
        write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_DECODE_ERROR", text = "协议解析错误(inner)" })
        return nil
    end

    return wrapper, inner_name, inner_req
end

-- ---------- Upstream message handlers (naming style: same as protocol) ----------
local upstream_handlers = {}

function upstream_handlers.EnterRoom(ctx, req)
    local fd = ctx.fd
    local room_id = req.room_id
    local player_info = req.player_info or {}
    local player_id = player_info.player_id or req.player_id

    if not room_id or room_id == 0 or not player_id or player_id == "" then
        write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_BAD_ATTACH_ROOM", text = "EnterRoom 需要 room_id 和 player_info.player_id" })
        return
    end

    local room = rooms[room_id]
    if not room then
        write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_ROOM_NOT_FOUND", text = "房间不存在: " .. room_id })
        return
    end

    player_route[player_id] = fd

    moon.send("lua", room.service_id, "enter_room", player_id)
end



local function on_upstream_frame(fd, cmd_id, payload)
    local route, name, req = decode_frame(fd, cmd_id, payload)
    if not route then
        return
    end
    local fn = upstream_handlers[name]
    if fn then
        fn({ fd = fd }, req)
        return
    elseif route.room_id and route.room_id > 0 then
        local room = rooms[route.room_id]
        if room then
            moon.send("lua", room.service_id, "on_msg", name, req)
            return
        end
    end
    write_fd_binary(fd, 0, "S2CNotify", { reason = "NOTIFY_REASON_UNKNOWN_CMD", text = "未知命令: " .. name })
end

local function read_loop(fd)
    moon.async(function()
        while true do
            if stopping then
                break
            end
            local cmd_id, payload = protocol.read_frame(fd)
            if not cmd_id then
                break
            end
            on_upstream_frame(fd, cmd_id, payload)
        end
        socket.close(fd)
    end)
end

local center_handlers = {}

function center_handlers.CreateRoomReq(ctx, req)
    local fd = ctx.fd
    local room = req.room or {}
    local room_id = room.room_id
    local players = room.players or {}
    if #players == 0 then
        protocol.write_frame(fd, "CreateRoomResp", {
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
        protocol.write_frame(fd, "CreateRoomResp", {
            req_id = req.req_id,
            ok = false,
            err = "create_service_failed",
            room_info = { room_id = room_id, room_addr = "", players = players },
        })
        return
    end
    moon.send("lua", room_service_id, "init", moon.id, room_id, table.unpack(players))
    rooms[room_id] = {
        service_id = room_service_id,
        players = players,
    }
    protocol.write_frame(fd, "CreateRoomResp", {
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

function command.write_player(room_id, player_id, msg_name, data)
    if not (room_id and player_id and msg_name) then
        return
    end
    write_player_msg(player_id, msg_name, data)
end

function command.room_closed(room_id)
    if room_id then
        local room = rooms[room_id]
        if room then
            for _, player_id in ipairs(room.players) do
                player_route[player_id] = nil
            end
        end
        rooms[room_id] = nil
        print(string.format("[room_manager] room_closed: %d", room_id))
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
