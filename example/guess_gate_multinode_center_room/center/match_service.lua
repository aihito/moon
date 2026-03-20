--- Center: match only. When full, 通过 room_gate 向 Room 节点发起 create_room，再 send match_ok(room_addr, room_id)。
local moon = require("moon")
local game_def = require("shared.game_def")

local match_queue = {}
-- in_queue[player] = true 表示已在匹配队列中（防止客户端 ping 重复入队）
local in_queue = {}
-- user_rooms[player_name] = { room_id = "...", room_addr = "host:port" }
local user_rooms = {}
local max_player_number = 2
local addr_bridge = 0
local addr_room_gate = 0

local function send_to_player(player_id, msg_name, data)
    -- print(string.format("[match] send to player: player_id=%s msg_name=%s data=%s", player_id, msg_name, data or "nil"))
    moon.send("lua", addr_bridge, "forward", "player", player_id, nil, msg_name, data or {})
end

local function try_start_game(ready_client)
    print("[match] try_start_game", print_r(ready_client, true))

    local players = { ready_client[1].player_id, ready_client[2].player_id }
    for _, c in ipairs(ready_client) do
        user_rooms[c.player_id] = { creating = true }
    end
    local r = moon.call("lua", addr_room_gate, "create_room", game_def.GAME_TYPE_GUESS, players)
    print("[match] create_room ret", table.concat(players, ","), print_r(r, true))

    if not r or not r.ok then
        print("[match] create_room failed", r and (r.room_info and r.room_info.room_id or r.err) or "nil")
        for _, v in ipairs(ready_client) do
            user_rooms[v.player_id] = nil
            if not in_queue[v.player_id] then
                in_queue[v.player_id] = true
                match_queue[#match_queue + 1] = v
            end
            send_to_player(v.player_id, "S2CNotify", { reason = "NOTIFY_REASON_CREATE_ROOM_FAILED", text = "创建房间失败，请重试" })
        end
        return
    end

    print("[match] create_room ok", r.room_info.room_id, r.room_info.room_addr)

    for _, c in ipairs(ready_client) do
        user_rooms[c.player_id] = r.room_info
        send_to_player(c.player_id, "S2CMatchOk", r.room_info)
        print("[match] sent match_ok to", c.player_id)
    end
end

local function try_match()
    if #match_queue < max_player_number then
        return
    end

    local ready_client = {}
    while #ready_client < max_player_number do
        local client = table.remove(match_queue, 1)
        if not client then
            break
        end
        in_queue[client.player_id] = nil
        ready_client[#ready_client + 1] = client
    end

    if #ready_client ~= max_player_number then
        for _, v in ipairs(ready_client) do
            in_queue[v.player_id] = true
            table.insert(match_queue, 1, v)
        end
        return
    end

    try_start_game(ready_client)
end

local command = {}

function command.ready(player)
    print(string.format("[match] ready: player_id=%s queue=%d", player.player_id, #match_queue))

    local ur = user_rooms[player.player_id]
    if ur then
        print("[match] user_rooms found", print_r(ur, true))
        if ur.creating then
            -- 正在建房中，不重入队也不发 match_ok，直接忽略
            return
        end
        -- 已在房间：重发 match_ok（客户端 ping 或重连时）
        local addr = ur.room_addr
        if not addr or addr == "" then
            print("[match] room_addr not found for", player.player_id)
            return
        end
        local rid = ur.room_id or ""
        send_to_player(player.player_id, "S2CMatchOk", { room_addr = addr, room_id = rid })
        return
    end

    send_to_player(player.player_id, "S2CNotify", { reason = "NOTIFY_REASON_JOIN_QUEUE", text = "已加入匹配队列" })

    if not in_queue[player.player_id] then -- 仅首次 ready 入队并 try_match，重复 ready（如客户端 ping）不再入队
        print("[match] player not in queue", player.player_id)
        in_queue[player.player_id] = true
        match_queue[#match_queue + 1] = player
        print(string.format("[match] player %s joined queue, queue=%d", player.player_id, #match_queue))
        local ok, err = xpcall(try_match, debug.traceback)
        if not ok then 
            print(string.format("[match] try_match failed: error=%s", err))
            return
        end
    end
end

function command.start()
    addr_bridge = moon.queryservice("bridge")
    if not addr_bridge or addr_bridge == 0 then
        print("[match] bridge service not found")
        return
    end
    addr_room_gate = moon.queryservice("room_gate")
    if not addr_room_gate or addr_room_gate == 0 then
        print("[match] room_gate service not found")
        return
    end
end

function command.shutdown()
    moon.quit()
    return true
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        local ok, ret = xpcall(fn, debug.traceback, ...)
        if not ok then
            print(string.format("[match] command %s failed: error=%s", cmd, ret))
        end
        moon.response("lua", sender, session, ret)
    else
        moon.error("center_match unknown command", cmd, ...)
    end
end)
