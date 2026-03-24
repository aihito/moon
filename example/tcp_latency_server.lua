local moon = require("moon")
local socket = require("moon.socket")

local conf = ...
conf = conf or {}
conf.host = conf.host or "0.0.0.0"
conf.port = conf.port or 12345

-- Pure-text TCP latency test server.
-- Protocol (one line per request, newline-delimited):
--   PING <client_ts_ms> [delay_ms]
--     -> PONG <client_ts_ms> <server_recv_ts_ms> <server_send_ts_ms>
--
--   ECHO <any_text>
--     -> ECHO_REPLY <any_text>
--
--   NOW
--     -> NOW_REPLY <server_ts_ms>
--
--   QUIT
--     -> (close connection)

local function split_words(s)
    local t = {}
    if s then
        for w in tostring(s):gmatch("%S+") do
            t[#t + 1] = w
        end
    end
    return t
end

local function handle_line(fd, line)
    local parts = split_words(line)
    local cmd = parts[1]

    if cmd == "ping" then
        local client_ts = tonumber(parts[2]) or 0
        local delay_ms = tonumber(parts[3]) or 0

        local server_recv_ts = moon.time() -- ms
        if delay_ms > 0 then
            moon.sleep(delay_ms)
        end

        local server_send_ts = moon.time() -- ms (after optional delay)
        socket.write(fd, string.format("pong %d %d %d\n", client_ts, server_recv_ts, server_send_ts))
        print(string.format("tcp_latency_server: pong %d %d %d", client_ts, server_recv_ts, server_send_ts))
        return
    end

    if cmd == "ECHO" then
        -- Keep raw rest-of-line as text (spaces included).
        local text = ""
        if parts[2] then
            text = line:match("^%s*ECHO%s+(.+)$") or ""
        end
        socket.write(fd, "ECHO_REPLY " .. text .. "\n")
        return
    end

    if cmd == "NOW" then
        socket.write(fd, string.format("NOW_REPLY %d\n", moon.time()))
        return
    end

    if cmd == "QUIT" then
        return false
    end

    socket.write(fd, "ERR unknown_cmd\n")
    return true
end

local function handle_connection(fd)
    print(string.format("tcp_latency_server: new connection from %s", fd))
    moon.async(function()
        local function close_conn(reason)
            print(string.format("tcp_latency_server: connection closed fd=%s reason=%s", fd, tostring(reason or "unknown")))
            if fd and fd > 0 then
                socket.close(fd)
            end
        end

        while true do
            local line, err = socket.read(fd, "\n")
            if not line then
                -- Client disconnected / read timeout / read error.
                close_conn(err or "read_failed")
                return
            end
            line = string.trim(line)
            if line == "" then
                socket.write(fd, "ERR empty_line\n")
                moon.sleep(0)
            else
                local ok = handle_line(fd, line)
                if ok == false then
                    close_conn("client_quit")
                    return
                end
            end
        end
    end)
end

moon.async(function()
    local listenfd = socket.listen(conf.host, conf.port, moon.PTYPE_SOCKET_TCP)
    if listenfd == 0 then
        error(string.format("tcp_latency_server: listen failed on %s:%d", conf.host, conf.port))
    end

    print(string.format("tcp_latency_server listening on %s:%d", conf.host, conf.port))
    while true do
        local fd = socket.accept(listenfd)
        handle_connection(fd)
    end
end)

moon.shutdown(function()
    moon.quit()
end)
