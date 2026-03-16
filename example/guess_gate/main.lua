--- Guess game extension: game server connects to Moon (one connection).
--- No user_proxy; bridge + center + room only.
--- See docs/game_server_extension_integration.md.
if _G["__init__"] then
    return { thread = 4, enable_stdout = true }
end

local moon = require("moon")
local socket = require("moon.socket")

local host = "0.0.0.0"
local port = 12346  -- game server connects here (different from guess_game's 12345)

local services = {
    { unique = true, name = "center", file = "service_center.lua", threadid = 2 },
    { unique = true, name = "bridge", file = "service_bridge.lua", threadid = 3 },
}

-- Shared ref so shutdown callback can close listenfd (unblock accept in worker 1).
local listenfd_ref = {}

moon.async(function()
    for _, one in ipairs(services) do
        local id = moon.new_service(one)
        if id == 0 then
            moon.exit(-1)
            return
        end
    end

    local listenfd = socket.listen(host, port, moon.PTYPE_SOCKET_TCP)
    if listenfd == 0 then
        moon.exit(-1)
        return
    end
    listenfd_ref.fd = listenfd

    print("guess_game_extension: listen", host, port, " (game server connects here)")

    -- accept(listenfd, bridge_id): new connection is owned by bridge's worker (see socket_server::accept).
    local bridge_id = moon.queryservice("bridge")
    while true do
        local fd, err = socket.accept(listenfd, bridge_id)
        if not fd then
            if listenfd_ref.shutdown then
                break
            end
            print("accept error:", err)
        else
            moon.send("lua", bridge_id, "set_fd", fd)
        end
    end
end)

moon.shutdown(function()
    listenfd_ref.shutdown = true
    if listenfd_ref.fd and listenfd_ref.fd > 0 then
        socket.close(listenfd_ref.fd)
        listenfd_ref.fd = 0
    end
    moon.async(function()
        local center_id = moon.queryservice("center")
        if center_id and center_id > 0 then
            moon.send("lua", center_id, "shutdown")
        end
        local bridge_id = moon.queryservice("bridge")
        if bridge_id and bridge_id > 0 then
            moon.kill(bridge_id)
        end
        -- wait until only bootstrap left (like guess_game)
        while true do
            local size = moon.server_stats("service.count")
            if size == 1 then
                break
            end
            moon.sleep(200)
            print("guess_game_extension: wait all service quit, now count:", size)
        end
        moon.quit()
    end)
end)
