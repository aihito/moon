--- Center node: one center + one bridge (multi-connection). Game servers connect here for match.
--- See docs/game_server_gate_multinode.md §6.6 (Center + Room, no Gate).
if _G["__init__"] then
    arg = ...
    local ts = os.date("%Y%m%d-%H%M%S")
    -- 单 worker 保证 bridge 的 read_loop 在 moon.sleep(0) 后能立刻处理 match 发来的 forward(S2CMatchOk)
    return {
        thread = 1,
        enable_stdout = true,
        -- logfile = string.format("log/center-%s.log", ts),
        logfile = string.format("log/center.log"),
        loglevel = "DEBUG",
        path = table.concat({
            "./example/guess_gate_multinode_center_room/?.lua",
            "./example/guess_gate_multinode_center_room/?/init.lua",
            -- Append your lua module search path
        }, ";")

    }
end

local moon = require("moon")

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
local room_port = tonumber(os.getenv("CENTER_ROOM_PORT") or "13005") -- Room 节点主动连此端口

local services = {
    { unique = true, name = "match",     file = "center/match_service.lua",     threadid = 2 },
    { unique = true, name = "bridge",    file = "center/bridge_service.lua",    threadid = 3 },
    { unique = true, name = "room_gate", file = "center/room_gate_service.lua", threadid = 4 },
}

moon.async(function()
    for _, one in ipairs(services) do
        local id = moon.new_service(one)
        if id == 0 then
            moon.exit(-1)
            return
        end
    end

    local bridge_id = moon.queryservice("bridge")
    local room_gate_id = moon.queryservice("room_gate")
    local match_id = moon.queryservice("match")

    moon.send("lua", room_gate_id, "start", host, room_port)
    moon.send("lua", bridge_id, "start", host, port)
    moon.send("lua", match_id, "start")

    while true do
        moon.sleep(1000)
    end
end)

moon.shutdown(function()
    moon.async(function()
        local match_id = moon.queryservice("match")
        if match_id and match_id > 0 then
            moon.send("lua", match_id, "shutdown")
        end
        local bridge_id = moon.queryservice("bridge")
        if bridge_id and bridge_id > 0 then
            moon.send("lua", bridge_id, "shutdown")
        end
        local room_gate_id = moon.queryservice("room_gate")
        if room_gate_id and room_gate_id > 0 then
            moon.send("lua", room_gate_id, "shutdown")
        end
        while true do
            local size = moon.server_stats("service.count")
            if size == 1 then
                break
            end
            moon.sleep(200)
        end
        moon.quit()
    end)
end)
