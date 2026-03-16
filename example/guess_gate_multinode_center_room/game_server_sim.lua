--- Simulate two game servers: connect to Center for match, then to Room for battle.
--- Run: 1) start Room node (main_room_node.lua), 2) start Center node (main_center_node.lua), 3) run this.
if _G["__init__"] then
    return { thread = 1, enable_stdout = true }
end

local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("protocol")

local CENTER_HOST = os.getenv("CENTER_HOST") or "127.0.0.1"
local CENTER_PORT = tonumber(os.getenv("CENTER_PORT") or "13001")

local function parse_match_ok(data)
    local room_addr, room_id
    for part in (data or ""):gmatch("[^&]+") do
        local k, v = part:match("^([^=]+)=(.+)$")
        if k == "room_addr" then room_addr = v end
        if k == "room_id" then room_id = v end
    end
    return room_addr, room_id
end

local function connect_center()
    local fd, err = socket.connect(CENTER_HOST, CENTER_PORT, moon.PTYPE_SOCKET_TCP, 3000)
    if not fd or fd <= 0 then
        return nil, err
    end
    return fd
end

local function player_flow(player_id, on_done)
    moon.async(function()
        local cf, err = connect_center()
        if not cf then
            print("[", player_id, "] connect center failed", err)
            if on_done then on_done() end
            return
        end
        socket.write(cf, protocol.format_upstream(player_id, "ready"))

        local room_addr, room_id
        while true do
            local line, e = socket.read(cf, "\n", 10000)
            if not line then
                print("[", player_id, "] center read closed", e)
                socket.close(cf)
                if on_done then on_done() end
                return
            end
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            print("[Center->", player_id, "]", line)
            if line:find("match_ok") then
                local parts = {}
                for s in line:gmatch("[^\t]+") do parts[#parts + 1] = s end
                local data = parts[4] or ""
                room_addr, room_id = parse_match_ok(data)
                break
            end
        end
        socket.close(cf)

        if not room_addr or not room_id then
            print("[", player_id, "] no room_addr/room_id")
            if on_done then on_done() end
            return
        end
        local host, port = room_addr:match("^([^:]+):(%d+)$")
        if not host then host, port = room_addr, "13002" end
        port = tonumber(port) or 13002

        local rf, err = socket.connect(host, port, moon.PTYPE_SOCKET_TCP, 3000)
        if not rf or rf <= 0 then
            print("[", player_id, "] connect room failed", err)
            if on_done then on_done() end
            return
        end
        socket.write(rf, "attach_room\t" .. room_id .. "\t" .. player_id .. "\n")

        -- Binary-search guessing: parse interval from room messages (welcome or "现在的区间是[min-max]"), guess midpoint until game over
        local min_guess, max_guess = 1, 100
        local game_ended = false

        while not game_ended do
            local line, e = socket.read(rf, "\n", 10000)
            if not line then break end
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            print("[Room->", player_id, "]", line)

            if line:find("game_over") or line:find("猜测成功") then
                game_ended = true
                break
            end
            -- Parse interval from "区间[min-max]" (welcome) or "现在的区间是[min-max]" (after wrong guess)
            local lo, hi = line:match("区间%[(%d+)%-(%d+)%]") or line:match("现在的区间是%[(%d+)%-(%d+)%]")
            if lo and hi then
                min_guess = tonumber(lo)
                max_guess = tonumber(hi)
            end
            if min_guess >= max_guess then break end
            local mid = math.floor((min_guess + max_guess) / 2)
            socket.write(rf, protocol.format_upstream(player_id, "guess", tostring(mid)))
        end
        socket.close(rf)
        print("[", player_id, "] done")
        if on_done then on_done() end
    end)
end

local done_count = 0
local function on_player_done()
    done_count = done_count + 1
    if done_count >= 2 then
        moon.quit()
    end
end

moon.async(function()
    player_flow("alice", on_player_done)
    moon.sleep(200)
    player_flow("bob", on_player_done)
end)
