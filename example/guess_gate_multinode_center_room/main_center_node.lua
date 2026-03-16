--- Center node: one center + one bridge (multi-connection). Game servers connect here for match.
--- See docs/game_server_gate_multinode.md §6.6 (Center + Room, no Gate).
if _G["__init__"] then
    return { thread = 4, enable_stdout = true }
end

local moon = require("moon")
local socket = require("moon.socket")

local host = "0.0.0.0"
local port = tonumber(os.getenv("CENTER_PORT") or "13001")

local services = {
    { unique = true, name = "center", file = "service_center_match.lua", threadid = 2 },
    { unique = true, name = "bridge", file = "service_bridge_multi.lua", threadid = 3 },
}

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

    print("center_node: listen", host, port, "(game servers connect here)")

    local bridge_id = moon.queryservice("bridge")
    while true do
        local fd, err = socket.accept(listenfd, bridge_id)
        if not fd then
            if listenfd_ref.shutdown then break end
            print("center_node accept error:", err)
        else
            moon.send("lua", bridge_id, "add_fd", fd)
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
        while true do
            local size = moon.server_stats("service.count")
            if size == 1 then break end
            moon.sleep(200)
        end
        moon.quit()
    end)
end)
