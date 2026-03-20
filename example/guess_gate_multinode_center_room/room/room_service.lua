--- Per-room service: one instance per room. Receives add_conn/on_msg/conn_closed from manager; writes via manager write_fd.
local moon = require("moon")
local random = require("random")

local manager_id = 0
local room_id = 0
local players = {}
local random_num = 0
local min_guess, max_guess = 1, 100
local closed = false

-- Game 服务逻辑只关心 player_id；连接/FD->player 的映射由 room_manager 管理。
local function send_to_player_room(player_id, msg_name, data)
    if player_id and player_id ~= "" then
        moon.send("lua", manager_id, "write_player", room_id, player_id, msg_name, data or {})
    end
end

local function broadcast_room(msg_name, data, exclude_player_id)
    for _, pid in ipairs(players) do
        if not exclude_player_id or pid ~= exclude_player_id then
            send_to_player_room(pid, msg_name, data)
        end
    end
end

local function notify_manager_closed()
    moon.send("lua", manager_id, "room_closed", room_id)
end

--- End this room: notify all conns (via manager), clear state, notify manager, quit. Do not close fd (may be used by other rooms).
local function game_over()
    if closed then return end
    closed = true
    print("[room_service] game_over, destroy room:", room_id, "reason=game_end")
    notify_manager_closed()
    moon.quit()
end

local function remain_players_number()
    local count = 0
    for _, _ in pairs(players) do
        count = count + 1
    end
    return count
end

local handlers = {}

function handlers.C2SGuess(msg)
    local player_id = msg.player_id
    local num = msg.number and math.tointeger(msg.number)
    if player_id == "" or not num then
        return
    end
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
            if random_num > num then
                min_guess = num
            end
            if random_num < num then
                max_guess = num
            end
        end
        broadcast_room("S2CGuessRange", { lo = min_guess, hi = max_guess })
        broadcast_room("S2CNotify",{ reason = "NOTIFY_REASON_GUESS_FAILED", text = ("%s 猜测失败, 现在的区间是[%d-%d]"):format(player_id, min_guess, max_guess) })
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

-- 有玩家进入房间：room_manager 负责 FD 关联，本服务只维护 player_id 集合与业务消息
function command.enter_room(player_id)
    if closed then
        return
    end
    if not players[player_id] then
        players[player_id] = true
    end
    send_to_player_room(player_id, "S2CNotify", { reason = "NOTIFY_REASON_JOIN_ROOM", text = "已加入房间 " .. room_id .. " 区间[" .. min_guess .. "-" .. max_guess .. "]" })
    send_to_player_room(player_id, "S2CGuessRange", { lo = min_guess, hi = max_guess })
end

function command.on_msg(cmd, msg)
    local handler = handlers[cmd]
    if not handler then
        return false
    end
    return handler(msg)
end

function command.leave_room(player_id)
    if closed then
        return
    end

    local player_info = players[player_id]
    if not player_info then
        return
    end

    if remain_players_number() > 0 then
        local text = "玩家 " .. player_id .. " 离开，本局结束"
        for _, pid in ipairs(players) do
            send_to_player_room(pid, "S2CNotify", { reason = "NOTIFY_REASON_PLAYER_LEFT", text = text })
            send_to_player_room(pid, "S2CGameOver", { result = "leave", answer = 0 })
        end
    end

    print(string.format("[room_service] %s leave_room, destroy room: room_id=%d reason=player_left players_left=%d", player_id, room_id, remain_players_number()))
    closed = true
    notify_manager_closed()
    moon.quit()
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
