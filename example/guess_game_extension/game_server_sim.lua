--- Simulates the game server: one TCP connection to Moon, sends upstream lines and prints downstream.
--- Run: first start Moon with moon example/guess_game_extension/main_extension.lua
---       then run moon example/guess_game_extension/game_server_sim.lua
--- Protocol: send "player_id\tcmd\targ1\targ2...\n"; receive "target\tplayer_id(s)\tcmd\tdata\n"
if _G["__init__"] then
    return { thread = 1, enable_stdout = true }
end

local moon = require("moon")
local socket = require("moon.socket")

local HOST = "127.0.0.1"
local PORT = 12346

moon.async(function()
    local fd, err = socket.connect(HOST, PORT, moon.PTYPE_SOCKET_TCP, 3000)
    if not fd then
        print("game_server_sim: connect failed", err)
        moon.exit(-1)
        return
    end
    print("game_server_sim: connected to", HOST, PORT)

    local function send_line(player_id, cmd, ...)
        local args = { ... }
        local line = player_id .. "\t" .. cmd
        for _, a in ipairs(args) do
            line = line .. "\t" .. tostring(a)
        end
        socket.write(fd, line .. "\n")
    end

    -- reader: print every line from Moon
    moon.async(function()
        while true do
            local data, err = socket.read(fd, "\n")
            if not data then
                print("game_server_sim: read closed", err)
                break
            end
            print("[Moon->GameServer]", (data:gsub("^%s+", ""):gsub("%s+$", "")))
        end
    end)

    -- two players join match
    send_line("alice", "ready")
    moon.sleep(100)
    send_line("bob", "ready")
    moon.sleep(500)
    -- alice guesses 50
    send_line("alice", "guess", "50")
    moon.sleep(300)
    send_line("bob", "guess", "75")
    moon.sleep(200)
    send_line("alice", "guess", "62")
    moon.sleep(200)
    send_line("bob", "guess", "63")
    -- keep running so we see all messages; exit after a while
    moon.sleep(3000)
    socket.close(fd)
    moon.quit()
end)
