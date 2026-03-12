# TCP Server: 从 listen 到回调的整体流程

本文梳理 `example/tcp_server.lua` 中 **监听 → 接受连接 → 收发包 → 关闭** 的完整数据流，涉及 Lua 与 C++ 的调用关系。

---

## 1. 流程总览

```
Lua: socket.listen() → socket.start() → [注册 socket.on 回调]
         ↓                    ↓
C++:  socket_server::listen   socket_server::accept(listenfd, 0, owner)  // 开始 async_accept
         ↓
      [客户端连接] → async_accept 完成 → add_connection → moon_connection::start()
         ↓
      handle_message(owner, message{PTYPE_SOCKET_MOON, fd, socket_accept, 0, address})
         ↓
      worker → lua_service::dispatch() → Lua callback(cb_ctx) → moonsocket 协议 dispatch
         ↓
Lua:  socket.on("accept", fn) 被调用 → fd, msg
```

后续 **message** / **close** 同理：C++ 层构造 `message`（type=PTYPE_SOCKET_MOON, receiver=socket_recv/socket_close 等），经 worker 投递到 lua_service，再根据协议派发到 `socket.on("message", ...)` / `socket.on("close", ...)`。

---

## 2. Lua 侧入口

### 2.1 `socket.listen(HOST, PORT, moon.PTYPE_SOCKET_MOON)`

- **Lua**：`lualib/moon/socket.lua` 没有封装 `listen`，直接用的是 `core`（即 asio.core）。
- **C 绑定**：`src/lualib-src/lua_moon.cpp` 中 `lasio_listen`：
  - 取当前 service 的 `worker` 和 `socket_server`；
  - 调 `sock.listen(host, port, S->id(), type)`；
  - 返回 `listenfd`（以及可选 address/port）。

**C++**（`src/moon/core/network/socket_server.cpp`）`socket_server::listen`：

- 创建 `acceptor_context`（type=PTYPE_SOCKET_MOON, owner=当前 service id）；
- `resolver.resolve` → `acceptor.open/bind/listen`；
- `ctx->reset_reserve()` 为下一次 `async_accept` 准备 `reserve` socket；
- `acceptors_.try_emplace(id, ctx)` 把监听 fd 登记到 `acceptors_`；
- 返回 `(listenfd, local_endpoint)`。

此时仅完成**监听**，尚未开始 accept。

### 2.2 `socket.start(listenfd)` —— 开始接受连接

- **Lua**：`lualib/moon/socket.lua` 中 `socket.start(listenfd)` 调 `accept(listenfd, id, 0)`。
- **C 绑定**：`lasio_accept` 调 `sock.accept(fd, session, owner)`，这里 **session=0** 表示“不等待一次 accept 结果”，而是**持续接受**。

**C++**（`socket_server.cpp`）`socket_server::accept`：

- 在 `acceptors_` 里找到 `listenfd` 对应的 `acceptor_context`；
- `make_connection(owner, ctx->type, tcp::socket(...))` 创建 `moon_connection`（因为 type 为 PTYPE_SOCKET_MOON）；
- `ctx->acceptor.async_accept(c->socket(), lambda)` 启动一次 **async_accept**；
- 在 lambda 里：
  - 成功：`c->fd(server_->nextfd())`，`add_connection(this, ctx, c, sessionid)`；
  - 若 `sessionid == 0`，会再次调用 `accept(ctx->fd, sessionid, owner)`，形成**循环 accept**（每接受一个连接就再投递一次 accept）。

也就是说：**start = 在 listenfd 上挂上第一次 async_accept，并在每次接受成功后自动再挂一次**。

### 2.3 注册回调：`socket.on("accept" | "message" | "close", fn)`

- **Lua**：`lualib/moon/socket.lua` 中：
  - `socket_data_type`: `accept=2`, `message=3`, `close=4`；
  - `socket.on(name, cb)` 把 `callbacks[sdt] = cb`；
  - `moon.raw_dispatch("moonsocket", function(msg) ...)` 注册 **PTYPE_SOCKET_MOON** 的 raw 派发函数：
    - `local fd, sdt = moon.decode(msg, "SR")` → `fd = msg.sender`, `sdt = msg.receiver`（即 socket_data_type）；
    - `callbacks[sdt](fd, msg)` 根据事件类型调用 `accept` / `message` / `close` 回调。

C++ 发来的 `message` 里：

- `type = PTYPE_SOCKET_MOON`（11）；
- `sender = fd`（连接 fd）；
- `receiver = socket_data_type`（2=accept, 3=message, 4=close）；
- `session = 0`（事件型消息）；
- `data`：accept 时为 address 字符串，message 时为包体，close 时为错误信息 JSON 等。

Lua 用 `decode(msg, "SR")` 取 sender/receiver，再根据 receiver 派发到对应 `socket.on` 回调。

---

## 3. C++ 侧：从 accept 到 Lua 回调

### 3.1 接受连接并加入 connections_

`add_connection`（`socket_server.cpp`）：

- `asio::dispatch(context_, [this, from, ctx, c, sessionid] { ... })` 在**本 worker 的 io_context** 上执行：
  - `connections_.try_emplace(c->fd(), c)`；
  - `c->start(true)`（server 端连接）；
  - 若 `sessionid != 0`，再 `asio::dispatch(from->context_, ...)` 向 **owner 所在 context** 投递一条 `handle_message(ctx->owner, message{PTYPE_INTEGER, 0, 0, sessionid, fd})`（用于 `socket.accept()` 的 wait 返回）。
- 当 `sessionid == 0`（即 `socket.start(listenfd)` 的用法）时，不推 PTYPE_INTEGER，而是依赖下面 **moon_connection::start** 推的 **accept 事件**。

### 3.2 moon_connection::start(true) → 触发 “accept” 回调

`src/moon/core/network/moon_connection.hpp` 中：

- `start(server=true)` 里调用：
  - `handle_message(message{ type_, 0, socket_data_type::socket_accept, 0, address() })`；
- `base_connection::handle_message` 里会设置 `m.sender = fd_`，然后 `parent_->handle_message(serviceid_, std::forward<Message>(m))`。

即：**C++ 发出一条 type=PTYPE_SOCKET_MOON、receiver=socket_accept(2)、sender=fd、data=address 的 message**。

### 3.3 handle_message 到 Lua

- `socket_server::handle_message(serviceid, message)`（模板）：
  - `find_service(serviceid)` 得到 `service* s`（即 lua_service）；
  - `moon::handle_message(s, std::move(m))` → `s->dispatch(&m)`。
- 若在同一 worker，`dispatch` 直接在当前线程执行；若 message 被 redirect（改 `m.receiver`），会走 `server_->send_message` 投递到对应 worker 的队列。
- **lua_service::dispatch**（`src/moon/services/lua_service.cpp`）：
  - 把 `m->type, m->sender, m->session, m->data()/as_ptr(), m->size(), m` 压栈；
  - 调用在 `moon.register_protocol` 时注册的 **moonsocket** 协议的 **callback**（即 `raw_dispatch("moonsocket", fn)` 里的 `fn`）；
  - 该 fn 在 Lua 里用 `moon.decode(msg, "SR")` 得到 fd 和 sdt，再调 `callbacks[sdt](fd, msg)`。

因此 **accept** 事件下，Lua 看到的是：`socket.on("accept", function(fd, msg) ... end)` 被调用，`fd` 为新连接 fd，`msg` 为同一 message（可再用 `moon.decode(msg, "Z")` 取 address 等）。

---

## 4. 收包 → “message” 回调

- **moon_connection** 在 `start()` 里调 `read_header()`，按 **PTYPE_SOCKET_MOON** 的 2 字节长度头 +  body 解析；
- 收完一个完整包后 `handle_body(true)` → `handle_message(message{ type_, 0, socket_data_type::socket_recv, 0, std::move(data_) })`；
- 同样经 `socket_server::handle_message` → worker → `lua_service::dispatch` → moonsocket 的 raw dispatch → Lua 里 `callbacks[3](fd, msg)`，即 **socket.on("message", fn)**。

Lua 侧在 `message` 回调里用 `moon.decode(msg, "Z")` 取包体，再 `socket.write(fd, ...)` 等。

---

## 5. 关闭 → “close” 回调

- **base_connection::error**（如读超时、对端关闭、写失败等）或主动 `socket_server::close(fd)`：
  - 调 `handle_message(message{ type_, 0, socket_data_type::socket_close, 0, content })`（content 为错误信息等）；
  - 然后 `parent_->close(fd_)`，从 `connections_` 移除。
- 同样经 worker → lua_service → moonsocket dispatch → Lua 里 `callbacks[4](fd, msg)`，即 **socket.on("close", fn)**。

---

## 6. 关键文件与符号对照

| 阶段           | Lua 层                     | C++ 层 |
|----------------|----------------------------|--------|
| listen         | `core.listen` → lasio_listen | `socket_server::listen` |
| start accept   | `socket.start` → core.accept(listenfd, id, 0) | `socket_server::accept`，sessionid=0 时循环 accept |
| 注册回调       | `socket.on("accept"\|"message"\|"close", cb)`，`moon.raw_dispatch("moonsocket", fn)` | 协议 PTYPE_SOCKET_MOON，israw=true |
| accept 事件    | moonsocket dispatch → decode(msg,"SR") → callbacks[2](fd,msg) | `moon_connection::start(true)` → handle_message(..., socket_accept, address()) |
| message 事件   | callbacks[3](fd, msg)       | `moon_connection::handle_body` → handle_message(..., socket_recv, data) |
| close 事件     | callbacks[4](fd, msg)       | `base_connection::error` / `socket_server::close` → handle_message(..., socket_close, content) |
| 派发到 Lua     | core.callback(_dispatch) → protocol[PTYPE].dispatch(msg) | lua_service::dispatch → 按 type 调对应协议 dispatch |

---

## 7. 小结

- **listen**：Lua 调 core.listen → C++ 在 `acceptors_` 里创建并绑定 acceptor，返回 listenfd。
- **start**：Lua 调 core.accept(listenfd, id, 0) → C++ 在 listenfd 上启动 async_accept，并在每次成功接受后再次调用 accept，实现持续监听。
- **accept 事件**：async_accept 完成 → add_connection → moon_connection::start(true) → 发 PTYPE_SOCKET_MOON + socket_accept → worker → lua_service::dispatch → moonsocket raw_dispatch → Lua `socket.on("accept", fn)`。
- **message/close**：moon_connection 收包或 base_connection::error/close → 发 PTYPE_SOCKET_MOON + socket_recv/socket_close → 同一条派发链到 `socket.on("message"|"close", fn)`。

整体上，C++ 只负责 TCP 与协议解析，所有“事件类型”通过 `message.receiver`（socket_data_type）区分，由 Lua 的 moonsocket 协议和 `callbacks[sdt]` 映射到具体业务回调。
