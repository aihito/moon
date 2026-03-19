--- Per-room service: one instance per room. Receives add_conn/on_msg/conn_closed from manager; writes via manager write_fd.
local moon = require("moon")
local random = require("random")

local manager_id = 0
local room_id = 0
local players = {}
local conns = {}       -- fd -> { player_ids }
local random_num = 0
local min_guess, max_guess = 1, 100
local closed = false

local function write_room_fd(fd, msg_name, data)
    if not fd or fd <= 0 then return end
    if manager_id and manager_id > 0 then
        moon.send("lua", manager_id, "write_fd", fd, msg_name, data or {})
    end
end

local function broadcast_room(msg_name, data, exclude_player_id)
    for fd, _ in pairs(conns) do
        write_room_fd(fd, msg_name, data)
    end
end

local function send_to_player_room(player_id, msg_name, data)
    for fd, pids in pairs(conns) do
        for _, p in ipairs(pids) do
            if p == player_id then
                write_room_fd(fd, msg_name, data)
                return
            end
        end
    end
end

local function notify_manager_closed()
    if manager_id and manager_id > 0 then
        moon.send("lua", manager_id, "room_closed", room_id)
    end
end

--- End this room: notify all conns (via manager), clear state, notify manager, quit. Do not close fd (may be used by other rooms).
local function game_over()
    if closed then return end
    closed = true
    print("[room_service] game_over, destroy room:", room_id, "reason=game_end")
    for fd, _ in pairs(conns) do
        conns[fd] = nil
    end
    conns = {}
    notify_manager_closed()
    moon.quit()
end

--- One connection left: remove fd, notify remaining; if no conns left, close room.
local function room_conn_left(fd, left_player_ids)
    if not conns[fd] then return end
    conns[fd] = nil
    for _, pid in ipairs(left_player_ids) do
        for i = #players, 1, -1 do
            if players[i] == pid then table.remove(players, i) break end
        end
    end
    local left_names = table.concat(left_player_ids, ",")
    for other_fd, _ in pairs(conns) do
        write_room_fd(other_fd, "S2CNotify", { reason = "NOTIFY_REASON_PLAYER_LEFT", text = "玩家 " .. left_names .. " 离开，本局结束" })
        write_room_fd(other_fd, "S2CGameOver", { result = "leave", answer = 0 })
    end
    if next(conns) == nil then
        print("[room_service] destroy room:", room_id, "reason=all_conns_left players=" .. left_names)
        closed = true
        notify_manager_closed()
        moon.quit()
    end
end

--- Handle one message (C2SGuess) from manager; data = { number = n }.
local function on_msg(fd, player_id, cmd, data)
    if closed then return end
    if cmd == "C2SGuess" then
        local num = data and data.number and math.tointeger(data.number)
        if not num then
            send_to_player_room(player_id, "S2CNotify", { reason = "NOTIFY_REASON_BAD_GUESS", text = "无效的数字格式!" })
            return
        end
        if random_num == num then
            broadcast_room("S2CNotify", { reason = "NOTIFY_REASON_GUESS_SUCCESS", text = player_id .. " 猜测成功, 游戏结束" })
            send_to_player_room(player_id, "S2CGameOver", { result = "win", answer = random_num })
            for _, pid in ipairs(players) do
                if pid ~= player_id then
                    send_to_player_room(pid, "S2CGameOver", { result = "lose", answer = random_num })
                end
            end
            game_over()
        else
            if num > min_guess and num < max_guess then
                if random_num > num then min_guess = num end
                if random_num < num then max_guess = num end
            end
            broadcast_room("S2CGuessRange", { lo = min_guess, hi = max_guess })
            broadcast_room("S2CNotify", { reason = "NOTIFY_REASON_GUESS_FAILED", text = ("%s 猜测失败, 现在的区间是[%d-%d]"):format(player_id, min_guess, max_guess) })
        end
    end
end

local command = {}

function command.init(mgr_id, rid, ...)
    manager_id = mgr_id
    room_id = rid
    players = { ... }
    random_num = random.rand_range(1, 100)
    min_guess, max_guess = 1, 100
end

function command.add_conn(fd, player_ids)
    if closed then return end
    conns[fd] = player_ids
    write_room_fd(fd, "S2CNotify", { reason = "NOTIFY_REASON_JOIN_ROOM", text = "已加入房间 " .. room_id .. " 区间[" .. min_guess .. "-" .. max_guess .. "]" })
    write_room_fd(fd, "S2CGuessRange", { lo = min_guess, hi = max_guess })
end

function command.on_msg(fd, player_id, cmd, data)
    on_msg(fd, player_id, cmd, data or {})
end

function command.conn_closed(fd)
    if conns[fd] then
        local left_player_ids = conns[fd]
        room_conn_left(fd, left_player_ids)
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
        moon.error("room_service unknown", cmd, ...)
    end
end)
