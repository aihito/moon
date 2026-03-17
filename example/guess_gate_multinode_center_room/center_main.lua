--- Center node: one center + one bridge (multi-connection). Game servers connect here for match.
--- See docs/game_server_gate_multinode.md §6.6 (Center + Room, no Gate).
if _G["__init__"] then
    arg = ...
    return {
        thread = 4,
        enable_stdout = true,
        logfile = string.format("log/game-%s-%s.log", arg[1], os.date("%Y-%m-%d-%H-%M-%S")),
        loglevel = "DEBUG",
        path = table.concat({
            "./example/guess_gate_multinode_center_room/?.lua",
            "./example/guess_gate_multinode_center_room/?/init.lua",
            -- Append your lua module search path
        }, ";")

    }
    
end

local moon = require("moon")
local socket = require("moon.socket")

-- 多线程共享：加载 protobuf 协议（仅一次），供各 service 使用
local function load_protocol()
    local pb = require("pb")
    local ok, err
    -- 优先加载已编译的 .pb（相对 cwd：仓库根或脚本目录）
    local pb_path = "protocol/guess.pb"
    local root_path = "example/guess_gate_multinode_center_room/protocol/guess.pb"
    local f = io.open(pb_path, "rb")
    if not f then
        f = io.open(root_path, "rb")
    end
    if f then
        local content = f:read("*a")
        f:close()
        ok = pcall(pb.load, content)
        if not ok then err = "pb.load failed" end
    else
        local protoc = require("protoc")
        local proto_path = "protocol/proto/guess.proto"
        local proto_root = "example/guess_gate_multinode_center_room/protocol/proto/guess.proto"
        local parser = protoc.new()
        ok, err = pcall(parser.loadfile, parser, proto_path)
        if not ok then
            ok, err = pcall(parser.loadfile, parser, proto_root)
        end
    end
    if not ok then
        moon.error("load_protocol failed: ", err or "unknown")
        return false
    end
    if pb.share_state then
        pb.share_state()
    end
    return true
end

if not load_protocol() then
    moon.exit(-1)
    return
end

local host = "0.0.0.0"
local port = tonumber(os.getenv("CENTER_PORT") or "13001")
local room_port = tonumber(os.getenv("CENTER_ROOM_PORT") or "13005")  -- Room 节点主动连此端口

local services = {
    { unique = true, name = "center", file = "center/match_service.lua", threadid = 2 },
    { unique = true, name = "bridge", file = "center/bridge_service.lua", threadid = 3 },
    { unique = true, name = "room_gate", file = "center/room_gate_service.lua", threadid = 4 },
}

local listenfd_ref = {}

print("cwd =", os.getenv("PWD"))

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
    local room_gate_id = moon.queryservice("room_gate")
    -- Room 端口在 room_gate 内 listen+accept，保证 fd 同线程，避免 Center->Room RPC 读回 EOF
    moon.send("lua", room_gate_id, "start_room_listen", host, room_port)

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
    local room_gate_id = moon.queryservice("room_gate")
    if room_gate_id and room_gate_id > 0 then
        moon.send("lua", room_gate_id, "shutdown")
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
        local room_gate_id = moon.queryservice("room_gate")
        if room_gate_id and room_gate_id > 0 then
            moon.kill(room_gate_id)
        end
        while true do
            local size = moon.server_stats("service.count")
            if size == 1 then break end
            moon.sleep(200)
        end
        moon.quit()
    end)
end)
