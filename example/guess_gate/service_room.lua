--- Room: same guess-number game; clients are { player_id, name }. All send/broadcast via bridge.
local moon = require("moon")
local random = require("random")
local tablex = require("tablex")

local room_clients = {}
local addr_bridge = 0
local random_num = random.rand_range(1, 100)
local min_guess = 1
local max_guess = 100

local function bridge()
    if addr_bridge == 0 then addr_bridge = moon.queryservice("bridge") end
    return addr_bridge
end

local function broadcast(data, exclude_player_id)
    local ids = {}
    for _, c in ipairs(room_clients) do
        if not exclude_player_id or c.name ~= exclude_player_id then
            ids[#ids + 1] = c.name
        end
    end
    if #ids > 0 then
        moon.send("lua", bridge(), "forward_broadcast", ids, nil, "msg", data)
    end
end

local function send_to_player(player_id, data)
    moon.send("lua", bridge(), "forward", "player", player_id, nil, "msg", data)
end

local command = {}

function command.start(ready_client)
    room_clients = ready_client
    local names = {}
    for _, c in ipairs(ready_client) do
        names[#names + 1] = c.name
    end
    broadcast("游戏开始, 欢迎 " .. table.concat(names, ",") .. " 进入游戏房间 现在的区间是[" .. min_guess .. "-" .. max_guess .. "]")
    return true
end

function command.offline(client)
    tablex.remove_if(room_clients, function(v)
        return v.name == client.name
    end)
    broadcast(client.name .. " 离开了房间")
end

function command.online(client)
    broadcast(client.name .. " 进入了房间")
    room_clients[#room_clients + 1] = client
    send_to_player(client.name, ("现在的区间是[%d-%d]"):format(min_guess, max_guess))
end

function command.guess(name, num)
    num = math.tointeger(num)
    if not num then
        send_to_player(name, "无效的数字格式!")
        return
    end

    if random_num == num then
        broadcast(name .. " 猜测成功, 游戏结束，请开始匹配新的游戏。")
        for _, c in ipairs(room_clients) do
            moon.send("lua", bridge(), "forward", "player", c.name, nil, "game_over", c.name == name and "win" or "lose")
        end
        moon.send("lua", moon.queryservice("center"), "game_over", room_clients)
        moon.quit()
    else
        if num > min_guess and num < max_guess then
            if random_num > num then min_guess = num end
            if random_num < num then max_guess = num end
        end
        broadcast((name .. " 猜测失败, 现在的区间是[%d-%d]"):format(min_guess, max_guess))
    end
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        moon.response("lua", sender, session, fn(...))
    else
        moon.error("room unknown command", cmd, ...)
    end
end)
