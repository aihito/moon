--- 模拟游戏服：一条 TCP 连 Moon，按 protocol 发上行、打印下行。
--- 先启动 main_extension.lua，再运行本脚本。
if _G["__init__"] then
    return { thread = 1, enable_stdout = true }
end

local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("example.guess_gate_multinode_center_room.common.protocol")

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
        socket.write(fd, protocol.format_upstream(player_id, cmd, ...))
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
