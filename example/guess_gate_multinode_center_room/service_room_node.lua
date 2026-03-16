--- Room node: listen RPC (create_room) and game-server connections (attach_room, guess).
--- One service holds all rooms and both listen ports.
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("protocol")
local random = require("random")

local ROOM_GAME_HOST = "0.0.0.0"
local ROOM_GAME_PORT = tonumber(os.getenv("ROOM_GAME_PORT") or "13002")
local ROOM_RPC_PORT = tonumber(os.getenv("ROOM_RPC_PORT") or "13005")

local rooms = {}           -- room_id -> { players, conns = { fd -> { player_ids } }, random_num, min_guess, max_guess }
local fd_to_room = {}     -- fd -> room_id

local function write_room_fd(fd, target, player_ids, cmd, data)
    if not fd or fd <= 0 then return end
    socket.write(fd, protocol.format_downstream(target, player_ids, cmd, data))
end

local function broadcast_room(room_id, cmd, data, exclude_player_id)
    local room = rooms[room_id]
    if not room then return end
    local ids = {}
    for _, pid in ipairs(room.players) do
        if not exclude_player_id or pid ~= exclude_player_id then
            ids[#ids + 1] = pid
        end
    end
    for fd, _ in pairs(room.conns) do
        if fd_to_room[fd] == room_id then
            write_room_fd(fd, "broadcast", ids, cmd, data)
        end
    end
end

local function send_to_player_room(room_id, player_id, cmd, data)
    local room = rooms[room_id]
    if not room then return end
    for fd, pids in pairs(room.conns) do
        for _, p in ipairs(pids) do
            if p == player_id then
                write_room_fd(fd, "player", player_id, cmd, data)
                return
            end
        end
    end
end

local function game_over(room_id)
    local room = rooms[room_id]
    if not room then return end
    for fd, _ in pairs(room.conns) do
        fd_to_room[fd] = nil
        socket.close(fd)
    end
    rooms[room_id] = nil
end

local function on_room_line(room_id, fd, line)
    local room = rooms[room_id]
    if not room then return end
    local req = protocol.parse_upstream(line)
    if req.cmd == "guess" then
        local num = math.tointeger(req.args[1])
        if not num then
            send_to_player_room(room_id, req.player_id, "msg", "无效的数字格式!")
            return
        end
        if room.random_num == num then
            broadcast_room(room_id, "msg", req.player_id .. " 猜测成功, 游戏结束")
            broadcast_room(room_id, "game_over", "win", req.player_id)
            send_to_player_room(room_id, req.player_id, "game_over", "win")
            for _, pid in ipairs(room.players) do
                if pid ~= req.player_id then
                    send_to_player_room(room_id, pid, "game_over", "lose")
                end
            end
            game_over(room_id)
        else
            if num > room.min_guess and num < room.max_guess then
                if room.random_num > num then room.min_guess = num end
                if room.random_num < num then room.max_guess = num end
            end
            broadcast_room(room_id, "msg",
                ("%s 猜测失败, 现在的区间是[%d-%d]"):format(req.player_id, room.min_guess, room.max_guess))
        end
    end
end

--- Handle one game-server connection: first line = attach_room room_id p1 p2
local function handle_room_conn(fd)
    moon.async(function()
        local line, err = socket.read(fd, "\n", 5000)
        if not line then
            socket.close(fd)
            return
        end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        local parts = {}
        for s in line:gmatch("%S+") do parts[#parts + 1] = s end
        if parts[1] ~= "attach_room" or #parts < 3 then
            write_room_fd(fd, "player", "*", "msg", "首行请发送 attach_room room_id player_id1 player_id2 ...")
            socket.close(fd)
            return
        end
        local room_id = parts[2]
        local player_ids = {}
        for i = 3, #parts do player_ids[#player_ids + 1] = parts[i] end
        local room = rooms[room_id]
        if not room then
            write_room_fd(fd, "player", "*", "msg", "房间不存在: " .. room_id)
            socket.close(fd)
            return
        end
        room.conns[fd] = player_ids
        fd_to_room[fd] = room_id
        write_room_fd(fd, "player", "*", "msg", "已加入房间 " .. room_id .. " 区间[" .. room.min_guess .. "-" .. room.max_guess .. "]")

        while fd_to_room[fd] do
            local data, e = socket.read(fd, "\n")
            if not data then
                break
            end
            on_room_line(room_id, fd, data)
        end
        room = rooms[room_id]
        if room and room.conns[fd] then
            room.conns[fd] = nil
        end
        fd_to_room[fd] = nil
        socket.close(fd)
    end)
end

--- RPC accept loop: create_room\troom_id\tp1\tp2 -> ok\troom_id
local function rpc_listen_loop(listenfd)
    moon.async(function()
        while true do
            local fd, err = socket.accept(listenfd, moon.id)
            if not fd then break end
            moon.async(function()
                local line = socket.read(fd, "\n", 2000)
                if line and line:match("^create_room\t") then
                    local parts = {}
                    for s in line:gmatch("[^\t]+") do parts[#parts + 1] = s end
                    if parts[1] == "create_room" and #parts >= 3 then
                        local room_id = parts[2]
                        local players = {}
                        for i = 3, #parts do players[#players + 1] = parts[i] end
                        rooms[room_id] = {
                            players = players,
                            conns = {},
                            random_num = random.rand_range(1, 100),
                            min_guess = 1,
                            max_guess = 100,
                        }
                        socket.write(fd, "ok\t" .. room_id .. "\n")
                    end
                end
                socket.close(fd)
            end)
        end
    end)
end

--- Game-server accept loop
local function game_listen_loop(listenfd)
    moon.async(function()
        while true do
            local fd, err = socket.accept(listenfd, moon.id)
            if not fd then break end
            handle_room_conn(fd)
        end
    end)
end

local listenfd_rpc = 0
local listenfd_game = 0

moon.dispatch("lua", function(sender, session, cmd, ...)
    if cmd == "start" then
        listenfd_rpc = socket.listen(ROOM_GAME_HOST, ROOM_RPC_PORT, moon.PTYPE_SOCKET_TCP)
        listenfd_game = socket.listen(ROOM_GAME_HOST, ROOM_GAME_PORT, moon.PTYPE_SOCKET_TCP)
        if listenfd_rpc == 0 or listenfd_game == 0 then
            moon.error("room_node listen failed")
            if session and session > 0 then moon.response("lua", sender, session, false) end
            return
        end
        print("room_node: RPC listen", ROOM_GAME_HOST, ROOM_RPC_PORT)
        print("room_node: game listen", ROOM_GAME_HOST, ROOM_GAME_PORT)
        rpc_listen_loop(listenfd_rpc)
        game_listen_loop(listenfd_game)
        if session and session > 0 then moon.response("lua", sender, session, true) end
    else
        moon.error("room_node unknown", cmd)
    end
end)
