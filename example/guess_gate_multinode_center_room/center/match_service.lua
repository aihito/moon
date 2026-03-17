--- Center: match only. When full, 通过 room_gate 向 Room 节点发起 create_room，再 send match_ok(room_addr, room_id)。
local moon = require("moon")

local match_queue = {}
local match_state = {}
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
    local r = moon.call("lua", addr_room_gate, "create_room", room_id, players)
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
        if match_state[client.name] then
            match_state[client.name] = nil
            ready_client[#ready_client + 1] = client
        end
    end

    if #ready_client ~= max_player_number then
        for _, v in ipairs(ready_client) do
            match_state[v.name] = true
            table.insert(match_queue, 1, v)
        end
        return
    end

    local room_id = ("%d_%s_%s"):format(os.time(), ready_client[1].name, ready_client[2].name)
    local players = { ready_client[1].name, ready_client[2].name }
    print("[match] create_room start", room_id, table.concat(players, ","))
    local ok, err, room_addr = rpc_create_room(room_id, players)
    if not ok then
        print("[match] create_room failed", room_id, err)
        for _, v in ipairs(ready_client) do
            send_to_player(v.name, "S2CMsg", { text = "创建房间失败，请重试" })
        end
        return
    end
    print("[match] create_room ok", room_id, room_addr or "")
    -- Room 节点信息由 Center 通知到客户端：优先使用 Room 上报的 room_addr，否则用配置
    if not room_addr or room_addr == "" then
        room_addr = ("%s:%d"):format(ROOM_GAME_HOST, ROOM_GAME_PORT)
    end
    for _, c in ipairs(ready_client) do
        user_rooms[c.name] = { room_id = room_id, room_addr = room_addr }
        send_to_player(c.name, "S2CMatchOk", { room_addr = room_addr, room_id = room_id })
        print("[match] sent match_ok to", c.name)
    end
    -- Yield so bridge (other thread) can process forward and write to client fds
    moon.sleep(0)
end

local command = {}

function command.ready(client)
    print("[match] ready", client.name or client.player_id, "queue=", #match_queue)
    local ur = user_rooms[client.name]
    if ur then
        -- Player already in a room: resend match_ok so client can reconnect to Room node.
        local addr = ur.room_addr
        if not addr or addr == "" then
            addr = ("%s:%d"):format(ROOM_GAME_HOST, ROOM_GAME_PORT)
        end
        local rid = ur.room_id or ""
        send_to_player(client.name, "S2CMatchOk", { room_addr = addr, room_id = rid })
        return
    end
    send_to_player(client.name, "S2CMsg", { text = "已加入匹配队列" })
    if not match_state[client.name] then
        match_state[client.name] = true
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
