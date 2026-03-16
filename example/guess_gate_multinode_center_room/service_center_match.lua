--- Center: match only. When full, RPC Room node to create room, then send match_ok(room_addr, room_id).
local moon = require("moon")
local socket = require("moon.socket")

local match_queue = {}
local match_state = {}
local user_rooms = {}
local max_player_number = 2
local addr_bridge = 0

-- Room node: RPC port (create_room), game-server port (for match_ok room_addr)
local ROOM_RPC_HOST = os.getenv("ROOM_RPC_HOST") or "127.0.0.1"
local ROOM_RPC_PORT = tonumber(os.getenv("ROOM_RPC_PORT") or "13005")
local ROOM_GAME_PORT = tonumber(os.getenv("ROOM_GAME_PORT") or "13002")

local function send_to_player(player_id, cmd, data)
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    moon.send("lua", addr_bridge, "forward", "player", player_id, nil, cmd, data or "")
end

--- TCP RPC to Room node: create_room(room_id, players) -> ok
local function rpc_create_room(room_id, players)
    local fd = socket.connect(ROOM_RPC_HOST, ROOM_RPC_PORT, moon.PTYPE_SOCKET_TCP, 3000)
    if not fd or fd <= 0 then
        return false, "connect to room node failed"
    end
    local line = "create_room\t" .. room_id .. "\t" .. table.concat(players, "\t") .. "\n"
    socket.write(fd, line)
    local resp, err = socket.read(fd, "\n", 2000)
    socket.close(fd)
    if not resp or not resp:match("^ok\t") then
        return false, err or resp
    end
    return true
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
            user_rooms[client.name] = true
        end
    end

    if #ready_client ~= max_player_number then
        for _, v in ipairs(ready_client) do
            user_rooms[v.name] = nil
            match_state[v.name] = true
            table.insert(match_queue, 1, v)
        end
        return
    end

    local room_id = ("%d_%s_%s"):format(os.time(), ready_client[1].name, ready_client[2].name)
    local players = { ready_client[1].name, ready_client[2].name }
    local ok, err = rpc_create_room(room_id, players)
    if not ok then
        moon.error("rpc_create_room failed", room_id, err)
        for _, v in ipairs(ready_client) do
            user_rooms[v.name] = nil
            send_to_player(v.name, "msg", "创建房间失败，请重试")
        end
        return
    end

    local room_addr = ("%s:%d"):format(ROOM_RPC_HOST, ROOM_GAME_PORT)
    local match_ok_data = ("room_addr=%s&room_id=%s"):format(room_addr, room_id)
    for _, c in ipairs(ready_client) do
        send_to_player(c.name, "match_ok", match_ok_data)
    end
    -- Multinode: Room never sends game_over to Center, so clear user_rooms so they can match again next time
    for _, c in ipairs(ready_client) do
        user_rooms[c.name] = nil
    end
end

local command = {}

function command.ready(client)
    if user_rooms[client.name] then
        send_to_player(client.name, "msg", "已经在房间中")
        return
    end
    if not match_state[client.name] then
        match_state[client.name] = true
        match_queue[#match_queue + 1] = client
        try_match()
    end
    send_to_player(client.name, "msg", "已加入匹配队列")
end

function command.shutdown()
    moon.quit()
    return true
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    local fn = command[cmd]
    if fn then
        moon.response("lua", sender, session, fn(...))
    else
        moon.error("center_match unknown command", cmd, ...)
    end
end)
