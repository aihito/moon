--- Center 侧「Room 网关」：统一持有 Room 节点连接池，对外提供 create_room 等 RPC。
--- 本服务内 listen + accept，保证 accepted fd 与 write/read 同线程，避免跨线程 fd 导致 EOF。
local moon = require("moon")
local socket = require("moon.socket")
local protocol = require("shared.protocol_pb")

--- Room 节点连上来后注册的 fd 池（与「房间 room_id」无关，是节点连接）
local room_node_fds = {}
--- fd -> advertised room game addr ("host:port")
local room_node_addr = {}
--- req_id -> coroutine (waiting create_room response)
local pending_create = {}
local next_req_id = 1
local next_room_id = 1
local listenfd_room = 0

local GMAE_TYEP_GUESS = 1

local function trim(s)
    return (tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function generate_req_id()
    local id = next_req_id
    next_req_id = next_req_id + 1
    if next_req_id > 0x7fffffff then
        next_req_id = 1
    end
    return id
end

local function generate_room_id()
    local id = next_room_id
    next_room_id = next_room_id + 1
    if next_room_id > 0x7fffffff then
        next_room_id = 1
    end
    return id
end

local function remove_fd(fd)
    for i = #room_node_fds, 1, -1 do
        if room_node_fds[i] == fd then
            table.remove(room_node_fds, i)
            room_node_addr[fd] = nil
            if fd > 0 then
                socket.close(fd)
            end
            return
        end
    end
end

local function wake_pending(req_id, resp)
    local co = pending_create[req_id]
    pending_create[req_id] = nil
    if co then
        moon.wakeup(co, resp)
    end
end

local function decode_room_node_frame(fd, cmd_id, payload)
    local name = protocol.CmdCode.name(cmd_id)
    if not name then
        print("[room_gate] room node unknown cmd_id fd=", fd, "cmd_id=", cmd_id)
        return nil, nil
    end
    local ok, _msg_name, req = pcall(protocol.decode, name, payload)
    if not ok or not req then
        print("[room_gate] room node decode failed fd=", fd, "name=", name)
        return nil, nil
    end
    return name, req
end

local room_node_handlers = {}

function room_node_handlers.RoomNodeRegister(ctx, req)
    local fd = ctx.fd
    local addr = trim(req.node_addr)
    room_node_addr[fd] = addr
    print("[room_gate] room node registered fd=", fd, "addr=", addr)
end

function room_node_handlers.CreateRoomResp(ctx, req)
    wake_pending(req.req_id, req)
end

local function on_room_node_frame(fd, cmd_id, payload)
    local name, req = decode_room_node_frame(fd, cmd_id, payload)
    if not name then
        return
    end
    local fn = room_node_handlers[name]
    if fn then
        fn({ fd = fd }, req)
    else
        print("[room_gate] room node unknown msg fd=", fd, "name=", name)
    end
end

local function start_read_loop(fd)
    moon.async(function()
        while fd and fd > 0 do
            local cmd_id, payload_or_err = protocol.read_frame(fd)
            if not cmd_id then
                print(string.format("[room_gate] room node read failed, closing fd=%d err=%s", fd, payload_or_err or "nil"))
                remove_fd(fd)
                return
            end
            on_room_node_frame(fd, cmd_id, payload_or_err)
        end
    end)
end

--- 向某个 Room 连接发 create_room，读响应。返回 ok, err, room_addr（room_addr 由 Room 节点上报，供 Center 通知客户端）。
local function do_create_room(game_type, players)
    if #room_node_fds == 0 then
        print("[room_gate] create_room: no room node connected")
        return false, "no room node connected", nil
    end
    local fd = room_node_fds[1]
    local req_id = generate_req_id()
    local room_id = generate_room_id()

    print(string.format("[room_gate] create_room send to room node: fd=%d game_type=%d room_id=%d players=%s req_id=%d", fd, game_type, room_id, table.concat(players, ","), req_id))
    local ok = protocol.write_frame(fd, "CreateRoomReq", {
        req_id = req_id,
        room = {
            room_id = room_id,
            room_addr = "",
            players = players,
        },
    })
    if not ok then
        remove_fd(fd)
        print(string.format("[room_gate] create_room send to room node failed: fd=%d game_type=%d room_id=%d players=%s req_id=%d", fd, game_type, room_id, table.concat(players, ","), req_id))
        return false, "send CreateRoomReq failed", nil
    end

    print(string.format("[room_gate] create_room waiting response: req_id=%d", req_id))

    pending_create[req_id] = coroutine.running()
    local timerid = moon.timeout(2000, function()
        if pending_create[req_id] then
            print(string.format("[room_gate] create_room timeout: req_id=%d", req_id))
            wake_pending(req_id, {
                req_id = req_id,
                ok = false,
                err = "timeout",
                room_info = { room_id = room_id, room_addr = "", players = players },
            })
        end
    end)

    local resp = moon.wait()
    moon.remove_timer(timerid)
    if not resp or not resp.ok then
        print("[room_gate] create_room resp bad", room_id, resp and resp.err or "nil")
        return false, (resp and resp.err) or "create_room failed", nil
    end

    local room_info = resp.room_info
    print("[room_gate] create_room ok", room_id, print_r(resp, true))
    return true, nil, room_info
end

local command = {}

--- 在 room_gate 本线程内启动 Room 端口监听与 accept，保证 fd 同线程，避免 EOF。
function command.start(host, port)
    if listenfd_room and listenfd_room > 0 then
        return
    end

    listenfd_room = socket.listen(host, port, moon.PTYPE_SOCKET_TCP)
    if listenfd_room == 0 then
        print("[room_gate] listen failed", host, port)
        return
    end

    print("[room_gate] listen", host, port, "(room nodes connect here)")

    moon.async(function()
        while true do
            local fd, err = socket.accept(listenfd_room, moon.id)
            if not fd then
                print("[room_gate] accept error:", err)
            else
                table.insert(room_node_fds, fd)
                print("[room_gate] room node connected, fd=", fd, "total=", #room_node_fds)
                start_read_loop(fd)
            end
        end
    end)
end

--- 兼容：若由 center_main 传入 fd 则仍注册（不推荐，可能跨线程）。
function command.register_room_conn(fd)
    if fd and fd > 0 then
        table.insert(room_node_fds, fd)
    end
end

--- 建房 RPC：供 match 等任意服务调用。返回 { ok = true, room_addr = "host:port" } 或 { ok = false, err = "..." }。
function command.create_room(game_type, players)
    local ok, err, room_info = do_create_room(game_type, players)
    if ok then
        return { ok = true, room_info = room_info }
    else
        return { ok = false, err = err }
    end
end

function command.room_conn_count()
    return #room_node_fds
end

function command.shutdown()
    if listenfd_room > 0 then
        socket.close(listenfd_room)
    end
    moon.quit()
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        local ok, ret = xpcall(fn, debug.traceback, ...)
        if not ok then
            print(string.format("[room_gate] command %s failed: error=%s", cmd, ret))
        end
        moon.response("lua", sender, session, ret)
    else
        moon.error("room_gate unknown command", cmd)
    end
end)
