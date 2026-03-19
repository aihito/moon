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

local function trim(s)
    return (tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_and_decode(fd)
    local cmd_id, payload = protocol.read_frame(fd)
    if not cmd_id then
        return nil, nil, payload
    end
    local name, req = protocol.decode(cmd_id, payload)
    return name, req, nil
end

local Game = {}
Game.__index = Game

function Game.new(cfg, pid)
    return setmetatable({
        cfg = cfg,
        pid = pid,
        center_fd = 0,
        room_fd = 0,
        room_addr = nil,
        room_id = nil,
        min_guess = 1,
        max_guess = 100,
        last_lo = nil,
        last_hi = nil,
        stage = "center", -- center -> room -> done
    }, Game)
end

function Game:connect_center()
    local fd = socket.connect(self.cfg.center_host, self.cfg.center_port, moon.PTYPE_SOCKET_TCP, self.cfg.room_connect_timeout_ms)
    if not fd or fd <= 0 then
        print("[", self.pid, "] connect center failed")
        return false
    end
    self.center_fd = fd
    return true
end

function Game:close_center()
    if self.center_fd and self.center_fd > 0 then
        socket.close(self.center_fd)
    end
    self.center_fd = 0
end

function Game:connect_room(room_addr)
    room_addr = trim(room_addr)
    local host, port = room_addr:match("^([^:]+):(%d+)$")
    if not host then host, port = room_addr, "13002" end
    port = tonumber(port) or 13002

    local fd = socket.connect(host, port, moon.PTYPE_SOCKET_TCP, self.cfg.room_connect_timeout_ms)
    if not fd or fd <= 0 then
        print("[", self.pid, "] connect room failed")
        return false
    end
    self.room_fd = fd
    return true
end

function Game:close_room()
    if self.room_fd and self.room_fd > 0 then
        socket.close(self.room_fd)
    end
    self.room_fd = 0
end

function Game:recv(fd, from_tag)
    local name, req, err = read_and_decode(fd)
    if not name then
        return nil, nil, err or (from_tag .. " read failed")
    end
    return name, req, nil
end

function Game:dispatch(map, name, req)
    local fn = map[name]
    if fn then
        return fn(self, req)
    end
    return nil
end

-- ---------- Message handlers (same name as protocol) ----------
function Game:S2CNotify(r)
    if self.stage == "center" then
        print("[Center->", self.pid, "]", r.text or "", "reason=", r.reason or "")
        if r.reason == "NOTIFY_REASON_CREATE_ROOM_FAILED" then
            self.stage = "done"
        end
    else
        print("[Room->", self.pid, "]", r.text or "", "reason=", r.reason or "")
        if r.reason == "NOTIFY_REASON_PLAYER_LEFT" or r.reason == "NOTIFY_REASON_GUESS_SUCCESS" then
            self.stage = "done"
        end
    end
end

function Game:S2CMatchOk(r)
    self.room_addr = trim(r.room_addr)
    self.room_id = trim(r.room_id)
    print("[", self.pid, "] match_ok", self.room_addr, self.room_id)
    self.stage = "room"
end

function Game:S2CGuessRange(r)
    if not (r.lo and r.hi) then
        return
    end
    self.min_guess, self.max_guess = r.lo, r.hi
    if self.min_guess < self.max_guess and (self.last_lo ~= self.min_guess or self.last_hi ~= self.max_guess) then
        self.last_lo, self.last_hi = self.min_guess, self.max_guess
        local num = math.floor((self.min_guess + self.max_guess) / 2)
        protocol.write_frame(self.room_fd, "C2SGuess", { room_id = self.room_id, player_id = self.pid, number = num })
        moon.sleep(1000)
    end
end

function Game:S2CGameOver(r)
    print("[Room->", self.pid, "] game_over", r.result, r.answer or "")
    self.stage = "done"
end

function Game:enter_center()
    self.stage = "center"
    if not self:connect_center() then
        self.stage = "done"
        return false
    end

    local name, req = self:recv(self.center_fd, nil, "center")
    if not name then
        print("[", self.pid, "] center welcome timeout")
        self:close_center()
        self.stage = "done"
        return false
    end
    self:dispatch(self._handlers, name, req)

    protocol.write_frame(self.center_fd, "C2SReady", { player_id = self.pid })
    moon.sleep(80)
    return true
end

function Game:enter_room()
    if not (self.room_addr and self.room_id) then
        self.stage = "done"
        return false
    end
    if not self:connect_room(self.room_addr) then
        self.stage = "done"
        return false
    end
    protocol.write_frame(self.room_fd, "C2SAttachRoom", { room_id = self.room_id, player_ids = { self.pid } })
    print("[", self.pid, "] attached room, guessing...")
    return true
end

function Game:run()
    self._handlers = {
        S2CNotify = Game.S2CNotify,
        S2CMatchOk = Game.S2CMatchOk,
        S2CGuessRange = Game.S2CGuessRange,
        S2CGameOver = Game.S2CGameOver,
    }

    if not self:enter_center() then
        return false
    end

    while self.stage ~= "done" do
        if self.stage == "center" then
            local name, req = self:recv(self.center_fd, "center")
            if not name then
                print("[", self.pid, "] center read timeout/closed")
                self.stage = "done"
            else
                self:dispatch(self._handlers, name, req)
                if self.stage == "room" then
                    self:close_center()
                    if not self:enter_room() then
                        self.stage = "done"
                    end
                end
            end
        elseif self.stage == "room" then
            local name, req = self:recv(self.room_fd, "room")
            if not name then
                self.stage = "done"
            else
                self:dispatch(self._handlers, name, req)
            end
        else
            self.stage = "done"
        end
    end

    self:close_center()
    self:close_room()
    print("[", self.pid, "] done")
    return true
end

moon.async(function()
    print("Sim (single): player=", player_id, "| Center:", CFG.center_host .. ":" .. CFG.center_port)
    local game = Game.new(CFG, player_id)
    game:run()
    moon.quit()
end)
