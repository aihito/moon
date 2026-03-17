--- Center: match only. When full, 通过 room_gate 向 Room 节点发起 create_room，再 send match_ok(room_addr, room_id)。
local moon = require("moon")

local match_queue = {}
-- in_queue[player] = true 表示已在匹配队列中（防止客户端 ping 重复入队）
local in_queue = {}
-- user_rooms[player_name] = { room_id = "...", room_addr = "host:port" }
local user_rooms = {}
local max_player_number = 2
local addr_bridge = 0
local addr_room_gate = 0

--- match_ok 中 room_addr 的配置（游戏服连 Room 的地址）
local ROOM_GAME_HOST = os.getenv("ROOM_GAME_HOST") or os.getenv("ROOM_RPC_HOST") or "127.0.0.1"
local ROOM_GAME_PORT = tonumber(os.getenv("ROOM_GAME_PORT") or "13002")

local function send_to_player(player_id, msg_name, data)
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    moon.send("lua", addr_bridge, "forward", "player", player_id, nil, msg_name, data or {})
end

--- 通过 room_gate 建房；返回 ok, err, room_addr。room_addr 由 Room 节点上报，用于 match_ok 通知客户端。
local function rpc_create_room(room_id, players)
    if addr_room_gate == 0 then addr_room_gate = moon.queryservice("room_gate") end
    print("[match] rpc_create_room call", room_id, "addr_room_gate=", addr_room_gate)
    local r = moon.call("lua", addr_room_gate, "create_room", room_id, players)
    print("[match] rpc_create_room ret", room_id, r and (r.ok and "ok" or "fail") or "nil")
    if r and r.ok then
        return true, nil, r.room_addr
    end
    return false, (r and r.err) or "room_gate create_room failed", nil
end

local function try_match()
    if #match_queue < max_player_number then return end

    local ready_client = {}
    while #ready_client < max_player_number do
        local client = table.remove(match_queue, 1)
        if not client then break end
        in_queue[client.name] = nil
        ready_client[#ready_client + 1] = client
    end

    if #ready_client ~= max_player_number then
        for _, v in ipairs(ready_client) do
            in_queue[v.name] = true
            table.insert(match_queue, 1, v)
        end
        return
    end

    local room_id = ("%d_%s_%s"):format(os.time(), ready_client[1].name, ready_client[2].name)
    local players = { ready_client[1].name, ready_client[2].name }
    -- 在 yield 等待 create_room 前先占位，避免等待期间 ready(ping) 再次入队导致重复 create_room
    for _, c in ipairs(ready_client) do
        user_rooms[c.name] = { creating = true }
    end
    print("[match] create_room start", room_id, table.concat(players, ","))
    local ok, err, room_addr = rpc_create_room(room_id, players)
    if not ok then
        print("[match] create_room failed", room_id, err)
        for _, v in ipairs(ready_client) do
            user_rooms[v.name] = nil
            if not in_queue[v.name] then
                in_queue[v.name] = true
                match_queue[#match_queue + 1] = v
            end
            send_to_player(v.name, "S2CNotify", { reason = "NOTIFY_REASON_CREATE_ROOM_FAILED", text = "创建房间失败，请重试" })
        end
        return
    end
    print("[match] create_room ok", room_id, room_addr or "")
    if not room_addr or room_addr == "" then
        room_addr = ("%s:%d"):format(ROOM_GAME_HOST, ROOM_GAME_PORT)
    end
    for _, c in ipairs(ready_client) do
        user_rooms[c.name] = { room_id = room_id, room_addr = room_addr }
        send_to_player(c.name, "S2CMatchOk", { room_addr = room_addr, room_id = room_id })
        print("[match] sent match_ok to", c.name)
    end
    moon.sleep(0)
end

local command = {}

function command.ready(client)
    print("[match] ready", client.name or client.player_id, "queue=", #match_queue)
    local ur = user_rooms[client.name]
    if ur then
        if ur.creating then
            -- 正在建房中，不重入队也不发 match_ok，直接忽略
            return
        end
        -- 已在房间：重发 match_ok（客户端 ping 或重连时）
        local addr = ur.room_addr
        if not addr or addr == "" then
            addr = ("%s:%d"):format(ROOM_GAME_HOST, ROOM_GAME_PORT)
        end
        local rid = ur.room_id or ""
        send_to_player(client.name, "S2CMatchOk", { room_addr = addr, room_id = rid })
        return
    end
    send_to_player(client.name, "S2CNotify", { reason = "NOTIFY_REASON_JOIN_QUEUE", text = "已加入匹配队列" })
    -- 仅首次 ready 入队并 try_match，重复 ready（如客户端 ping）不再入队
    if not in_queue[client.name] then
        in_queue[client.name] = true
        match_queue[#match_queue + 1] = client
        try_match()
    end
end

function command.shutdown()
    moon.quit()
    return true
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    if addr_room_gate == 0 then addr_room_gate = moon.queryservice("room_gate") end
    local fn = command[cmd]
    if fn then
        moon.response("lua", sender, session, fn(...))
    else
        moon.error("center_match unknown command", cmd, ...)
    end
end)
