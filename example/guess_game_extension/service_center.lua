--- Center: match and room management. Client = { player_id, name } (no fd, no service id).
--- Sends to players via bridge forward; updates bridge player_room on join/leave.
local moon = require("moon")

local match_queue = {}
local match_state = {}
local user_rooms = {}
local max_player_number = 2
local addr_bridge = 0

local function send_to_player(player_id, text)
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    moon.send("lua", addr_bridge, "forward", "player", player_id, nil, "msg", text)
end

local function update_match()
    if #match_queue < max_player_number then return end

    local addr_room = moon.new_service({ name = "room", file = "service_room.lua" })
    if addr_room == 0 then
        moon.error("create room failed")
        return
    end

    local ready_client = {}
    while #ready_client < max_player_number do
        local client = table.remove(match_queue, 1)
        if not client then break end
        if match_state[client.name] then
            match_state[client.name] = nil
            ready_client[#ready_client + 1] = client
            user_rooms[client.name] = addr_room
        end
    end

    if #ready_client == max_player_number then
        moon.send("lua", addr_room, "start", ready_client)
        local reg = {}
        for _, c in ipairs(ready_client) do
            reg[c.name] = addr_room
        end
        moon.send("lua", addr_bridge, "register_room", reg)
    else
        for _, v in ipairs(ready_client) do
            user_rooms[v.name] = nil
            match_state[v.name] = true
            table.insert(match_queue, 1, v)
        end
        moon.kill(addr_room)
    end
end

local command = {}

function command.ready(client)
    if user_rooms[client.name] and user_rooms[client.name] > 0 then
        send_to_player(client.name, "已经在房间中")
        return
    end
    if not match_state[client.name] then
        match_state[client.name] = true
        match_queue[#match_queue + 1] = client
        update_match()
    end
    send_to_player(client.name, "匹配成功")
end

function command.online(client)
    local addr_room = user_rooms[client.name]
    if addr_room and addr_room > 0 then
        moon.send("lua", addr_room, "online", client)
        return addr_room
    end
    return 0
end

function command.offline(client)
    match_state[client.name] = nil
    local addr_room = user_rooms[client.name]
    if addr_room and addr_room > 0 then
        moon.send("lua", addr_room, "offline", client)
    end
end

function command.game_over(room_clients)
    local player_ids = {}
    for _, c in ipairs(room_clients) do
        user_rooms[c.name] = nil
        player_ids[#player_ids + 1] = c.name
    end
    moon.send("lua", addr_bridge, "unregister_room", player_ids)
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
        moon.error("center unknown command", cmd, ...)
    end
end)
