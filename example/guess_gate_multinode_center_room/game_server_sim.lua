--- 单人客户端：连 Center 匹配 -> 收 S2CMatchOk -> 连 Room 进房 -> 自动猜数。全 protobuf 帧。
if _G["__init__"] then
    -- 从脚本所在目录或仓库根解析 path（run.sh 从仓库根执行，moon 可能 cwd 为脚本目录）
    local root = os.getenv("MOON_REPO_ROOT") or "./"
    if not os.getenv("MOON_REPO_ROOT") then
        local try = "../.."
        local f = io.open(try .. "/lualib/protoc.lua", "r")
        if f then f:close(); root = try .. "/" end
    end
    return {
        thread = 1,
        enable_stdout = true,
        path = table.concat({
            root .. "example/guess_gate_multinode_center_room/?.lua",
            root .. "example/guess_gate_multinode_center_room/?/init.lua",
            root .. "lualib/?.lua",
        }, ";"),
    }
end

local moon = require("moon")
local socket = require("moon.socket")

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

--- 阶段1：连 Center，发 C2SReady，读 S2CMsg / S2CMatchOk，返回 room_addr, room_id 或 nil,nil
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
    if name == "S2CMsg" and req.text then
        print("[Center->", player_id, "]", req.text)
    end

    protocol.write_frame(cf, "C2SReady", { player_id = player_id })
    moon.sleep(80)

    local room_addr, room_id
    while true do
        cmd_id, payload = protocol.read_frame(cf, CFG.match_timeout_ms)
        if not cmd_id then
            print("[", player_id, "] center read timeout/closed")
            break
        end
        name, req = protocol.decode(cmd_id, payload)
        if name == "S2CMsg" then
            print("[Center->", player_id, "]", req.text or "")
            if req.text and req.text:find("创建房间失败") then
                break
            end
        elseif name == "S2CMatchOk" then
            room_addr, room_id = req.room_addr, req.room_id
            print("[", player_id, "] match_ok", room_addr, room_id)
            break
        end
    end
    socket.close(cf)
    return room_addr, room_id
end

--- 阶段2：连 Room，发 C2SAttachRoom，读 S2CMsg / S2CGuessRange / S2CGameOver，猜数
local function room_phase(room_addr, room_id)
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
        if msg_name == "S2CMsg" then
            print("[Room->", player_id, "]", req.text or "")
            if req.text and (req.text:find("game_over") or req.text:find("猜测成功") or req.text:find("离开")) then
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
