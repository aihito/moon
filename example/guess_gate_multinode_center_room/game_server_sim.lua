--- 单人客户端：连 Center 匹配 -> 收 S2CMatchOk -> 连 Room 进房 -> 自动猜数。全 protobuf 帧。
if _G["__init__"] then
    -- 从脚本所在目录或仓库根解析 path（run.sh 从仓库根执行，moon 可能 cwd 为脚本目录）
    arg = ...
    local player_id = os.getenv("SIM_PLAYER") or (arg and arg[1]) or "unknown"
    local ts = os.date("%Y%m%d-%H%M%S")
    return {
        thread = 1,
        enable_stdout = true,
        logfile = string.format("log/sim-%s-%s.log", player_id, ts),
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

print(os.getenv("PWD"))

local function load_protocol()
    local pb = require("pb")
    local f = io.open("example/guess_gate_multinode_center_room/protocol/guess.pb", "rb")
    if not f then f = io.open("protocol/guess.pb", "rb") end
    if f then
        local ok = pcall(pb.load, f:read("*a"))
        f:close()
        return ok
    end
    local protoc = require("protoc")
    local parser = protoc.new()
    local ok = pcall(parser.loadfile, parser, "example/guess_gate_multinode_center_room/protocol/proto/guess.proto")
    if not ok then ok = pcall(parser.loadfile, parser, "protocol/proto/guess.proto") end
    return ok
end
if not load_protocol() then
    print("game_server_sim: load_protocol failed")
    moon.exit(-1)
    return
end

local protocol = require("shared.protocol_pb")

local CFG = {
    center_host = os.getenv("CENTER_HOST") or "127.0.0.1",
    center_port = tonumber(os.getenv("CENTER_PORT") or "13001"),
    match_timeout_ms = 15000,
    room_connect_timeout_ms = 3000,
}

local player_id = os.getenv("SIM_PLAYER") or (arg and arg[1]) or "alice"

--- 阶段1：连 Center，自动 ready，读 S2CNotify / S2CMatchOk，返回 room_addr, room_id 或 nil,nil
local function match_phase()
    local cf = socket.connect(CFG.center_host, CFG.center_port, moon.PTYPE_SOCKET_TCP, CFG.room_connect_timeout_ms)
    if not cf or cf <= 0 then
        print("[", player_id, "] connect center failed")
        return nil, nil
    end

    local cmd_id, payload = protocol.read_frame(cf, 5000)
    if not cmd_id then
        print("[", player_id, "] center welcome timeout")
        socket.close(cf)
        return nil, nil
    end
    local name, req = protocol.decode(cmd_id, payload)
    if name == "S2CNotify" then
        print("[Center->", player_id, "]", req.text or "", "reason=", req.reason or "")
    end

    -- 客户端处理协议后只发一次 ready，等待 Center 返回 S2CMatchOk 后再进入 Room 阶段。
    -- 不再周期 ping，避免造成 match 阶段重复 ready / 重复入队刷日志。
    protocol.write_frame(cf, "C2SReady", { player_id = player_id })
    moon.sleep(80)

    local match_done = { v = false }

    local room_addr, room_id
    while true do
        cmd_id, payload = protocol.read_frame(cf, CFG.match_timeout_ms)
        if not cmd_id then
            print("[", player_id, "] center read timeout/closed")
            break
        end
        name, req = protocol.decode(cmd_id, payload)
        if name == "S2CNotify" then
            print("[Center->", player_id, "]", req.text or "", "reason=", req.reason or "")
            if req.reason == "NOTIFY_REASON_CREATE_ROOM_FAILED" then
                match_done.v = true
                break
            end
        elseif name == "S2CMatchOk" then
            match_done.v = true
            room_addr = (tostring(req.room_addr or "")):gsub("^%s+", ""):gsub("%s+$", "")
            room_id = (tostring(req.room_id or "")):gsub("^%s+", ""):gsub("%s+$", "")
            print("[", player_id, "] match_ok", room_addr, room_id)
            break
        end
    end
    socket.close(cf)
    return room_addr, room_id
end

--- 阶段2：连 Room，发 C2SAttachRoom，读 S2CNotify / S2CGuessRange / S2CGameOver，猜数
local function room_phase(room_addr, room_id)
    room_addr = (room_addr or ""):gsub("^%s+", ""):gsub("%s+$", "")
    room_id = (room_id or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local host, port = room_addr:match("^([^:]+):(%d+)$")
    if not host then host, port = room_addr, "13002" end
    port = tonumber(port) or 13002

    local rf = socket.connect(host, port, moon.PTYPE_SOCKET_TCP, CFG.room_connect_timeout_ms)
    if not rf or rf <= 0 then
        print("[", player_id, "] connect room failed")
        return
    end
    protocol.write_frame(rf, "C2SAttachRoom", { room_id = room_id, player_ids = { player_id } })
    print("[", player_id, "] attached room, guessing...")

    local min_guess, max_guess = 1, 100
    local last_lo, last_hi = nil, nil
    while true do
        local cid, pay = protocol.read_frame(rf, 10000)
        if not cid then break end
        local msg_name, req = protocol.decode(cid, pay)
        if msg_name == "S2CNotify" then
            print("[Room->", player_id, "]", req.text or "", "reason=", req.reason or "")
            if req.reason == "NOTIFY_REASON_PLAYER_LEFT" or req.reason == "NOTIFY_REASON_GUESS_SUCCESS" then
                break
            end
        elseif msg_name == "S2CGuessRange" then
            if req.lo and req.hi then
                min_guess, max_guess = req.lo, req.hi
                if min_guess < max_guess and (last_lo ~= min_guess or last_hi ~= max_guess) then
                    last_lo, last_hi = min_guess, max_guess
                    local num = math.floor((min_guess + max_guess) / 2)
                    protocol.write_frame(rf, "C2SGuess", { room_id = room_id, player_id = player_id, number = num })
                    moon.sleep(1000)
                end
            end
        elseif msg_name == "S2CGameOver" then
            print("[Room->", player_id, "] game_over", req.result, req.answer or "")
            break
        end
    end
    socket.close(rf)
    print("[", player_id, "] done")
end

moon.async(function()
    print("Sim (single): player=", player_id, "| Center:", CFG.center_host .. ":" .. CFG.center_port)
    local room_addr, room_id = match_phase()
    if not room_addr or not room_id then
        print("[", player_id, "] no match_ok, exit")
        moon.quit()
        return
    end
    room_phase(room_addr, room_id)
    moon.quit()
end)
