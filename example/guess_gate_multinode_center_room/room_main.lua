--- Room node: room/battle only. Listens RPC from Center (create_room) and game servers (attach_room, guess).
--- See docs/game_server_gate_multinode.md §6.6.
if _G["__init__"] then
    arg = ...
    local ts = os.date("%Y%m%d-%H%M%S")
    return {
        thread = 3,
        enable_stdout = true,
        -- logfile = string.format("log/room-%s.log", ts),
        logfile = string.format("log/room.log"),
        loglevel = "DEBUG",
        path = table.concat({
            "./example/guess_gate_multinode_center_room/?.lua",
            "./example/guess_gate_multinode_center_room/?/init.lua",
        }, ";")
    }
end

local moon = require("moon")

-- 多线程共享：加载 protobuf 协议（与 Center 节点相同，需从仓库根启动）
local function load_protocol()
    local pb = require("pb")
    local ok, err
    local f = io.open("example/guess_gate_multinode_center_room/protocol/guess.pb", "rb")
    if not f then
        f = io.open("protocol/guess.pb", "rb")
    end
    if f then
        local content = f:read("*a")
        f:close()
        ok = pcall(pb.load, content)
        if not ok then err = "pb.load failed" end
    else
        local protoc = require("protoc")
        local parser = protoc.new()
        ok, err = pcall(parser.loadfile, parser, "example/guess_gate_multinode_center_room/protocol/proto/guess.proto")
        if not ok then
            ok, err = pcall(parser.loadfile, parser, "protocol/proto/guess.proto")
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

moon.async(function()
    local id = moon.new_service({ unique = true, name = "room_manager", file = "room/room_manager_service.lua" })
    if id == 0 then
        moon.exit(-1)
        return
    end
    moon.sleep(100)
    moon.send("lua", id, "start")
end)

moon.shutdown(function()
    moon.async(function()
        local room_manager_id = moon.queryservice("room_manager")
        if room_manager_id and room_manager_id > 0 then
            moon.send("lua", room_manager_id, "shutdown")
        end
        while true do
            local n = moon.server_stats("service.count")
            if n == 1 then break end
            moon.sleep(100)
        end
        moon.quit()
    end)
end)
