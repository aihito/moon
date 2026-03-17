--- Center 侧「Room 网关」：统一持有 Room 节点连接池，对外提供 create_room 等 RPC。
--- 本服务内 listen + accept，保证 accepted fd 与 write/read 同线程，避免跨线程 fd 导致 EOF。
local moon = require("moon")
local socket = require("moon.socket")

--- Room 节点连上来后注册的 fd 池（与「房间 room_id」无关，是节点连接）
local room_node_fds = {}
local listenfd_room = 0
local room_listen_ref = {}

local function remove_fd(fd)
    for i = #room_node_fds, 1, -1 do
        if room_node_fds[i] == fd then
            table.remove(room_node_fds, i)
            if fd > 0 then socket.close(fd) end
            return
        end
    end
end

--- 向某个 Room 连接发 create_room，读响应。返回 ok, err, room_addr（room_addr 由 Room 节点上报，供 Center 通知客户端）。
local function do_create_room(room_id, players)
    if #room_node_fds == 0 then
        print("[room_gate] create_room: no room node connected")
        return false, "no room node connected", nil
    end
    local fd = room_node_fds[1]
    local line = "create_room\t" .. room_id .. "\t" .. table.concat(players, "\t") .. "\n"
    print("[room_gate] create_room send", room_id, table.concat(players, ","))
    socket.write(fd, line)
    local resp, err = socket.read(fd, "\n", 2000)
    if not resp or not resp:match("^ok\t") then
        print("[room_gate] create_room resp bad", room_id, err or resp)
        remove_fd(fd)
        return false, err or resp, nil
    end
    -- Room may reply "ok\troom_id" or "ok\troom_id\troom_addr"
    local _, room_addr = resp:match("^ok\t[^\t]+\t(.+)$")
    print("[room_gate] create_room ok", room_id, room_addr or "")
    return true, nil, room_addr
end

local command = {}

--- 在 room_gate 本线程内启动 Room 端口监听与 accept，保证 fd 同线程，避免 EOF。
function command.start_room_listen(host, port)
    if listenfd_room and listenfd_room > 0 then
        return
    end
    listenfd_room = socket.listen(host, port, moon.PTYPE_SOCKET_TCP)
    if listenfd_room == 0 then
        print("[room_gate] listen failed", host, port)
        return
    end
    room_listen_ref.fd = listenfd_room
    print("[room_gate] listen", host, port, "(room nodes connect here)")
    moon.async(function()
        while listenfd_room and listenfd_room > 0 and not room_listen_ref.shutdown do
            local fd, err = socket.accept(listenfd_room, moon.id)
            if not fd then
                if room_listen_ref.shutdown then break end
                print("[room_gate] accept error:", err)
            else
                table.insert(room_node_fds, fd)
                print("[room_gate] room node connected, fd=", fd, "total=", #room_node_fds)
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
function command.create_room(room_id, players)
    local ok, err, room_addr = do_create_room(room_id, players)
    if ok then
        return { ok = true, room_addr = room_addr }
    end
    return { ok = false, err = err }
end

--- 可选：查询当前已连 Room 节点数，便于监控或负载策略。
function command.room_conn_count()
    return #room_node_fds
end

function command.shutdown()
    room_listen_ref.shutdown = true
    if listenfd_room and listenfd_room > 0 then
        socket.close(listenfd_room)
        listenfd_room = 0
    end
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local fn = command[cmd]
    if fn then
        local ret = fn(...)
        if session and session > 0 then
            moon.response("lua", sender, session, ret)
        end
    else
        moon.error("room_gate unknown command", cmd)
    end
end)
