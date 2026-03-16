# Moon 网络管理架构

本文档梳理 Moon 框架的网络层整体架构：进程与线程模型、socket_server 与连接归属、listen/accept/connect 流程、连接类型与消息投递，以及和 Lua 的衔接。

---

## 1. 进程与线程模型

- **server**：单进程内唯一，持有 `workers_`（多个 worker）、全局 `nextfd()`、`get_worker(workerid, serviceid)` 等。
- **worker**：每个 worker 一个线程，拥有：
  - 自己的 `asio::io_context`（所有该线程上的异步 IO 都在此执行）；
  - 自己的 **socket_server** 实例（见下）；
  - 本线程上的 **service** 表（Lua 服务）；
  - 消息队列 `mq_`，从其他线程或本线程 IO 回调投递过来的 message 在此消费。
- **service**：Lua 服务，必属某一个 worker；service id 高字节编码了 worker id（`worker_id(serviceid) = (serviceid >> WORKER_ID_SHIFT) & 0xFF`），用于 `get_worker(0, serviceid)` 定位到对应 worker。

**结论**：所有“网络对象”（listen fd、连接 fd、UDP fd）都挂在**某个 worker** 的 socket_server 上，且只在该 worker 的 io_context 上做 IO，不存在跨线程共享同一个 fd 的读写。

---

## 2. socket_server：每 worker 一个

每个 **worker** 持有一个 **socket_server**，即“网络管理”是**按线程划分**的：

| 成员 | 含义 |
|------|------|
| `server_` | 所属 server |
| `worker_` | 所属 worker（即本线程） |
| `context_` | 本 worker 的 asio::io_context |
| **acceptors_** | `fd → acceptor_context`：本线程上的 **监听 socket**（listen 产生的 fd） |
| **connections_** | `fd → connection`：本线程上的 **TCP 连接**（accept 或 connect 产生的 fd） |
| **udp_** | `fd → udp_context`：本线程上的 **UDP socket** |

- **acceptor_context**：监听用，包含 `type`（接受后的连接类型，如 PTYPE_SOCKET_TCP/MOON）、`owner`（持有该 acceptor 的 service id）、`acceptor`（asio 的 tcp::acceptor）、`reserve`（用于 async_accept 的预备 socket）等。
- **connection**：继承自 `base_connection`，具体类型由 `make_connection(type, ...)` 根据 `type` 创建（见下节）。
- 全局 **fd** 由 `server_->nextfd()` 分配，在 `try_lock_fd`/`unlock_fd` 下保证不重复使用；close 时从对应 map 移除并 `unlock_fd`。

因此：**listen 在哪个 worker 调，listenfd 就落在哪个 worker 的 acceptors_**；**accept( listenfd, owner )** 时新连接会挂在 **owner 所在 worker** 的 connections_；**connect** 在哪个 worker 调，新连接就挂在哪个 worker 的 connections_。同一 fd 的 read/write/close 只会在**拥有该 fd 的 worker** 上执行。

---

## 3. 连接类型与 make_connection

TCP 连接在创建时确定**类型**（listen 时的 `type` 或 connect 时的 `type`），对应不同协议与读法：

| type | 类名 | 说明 |
|------|------|------|
| **PTYPE_SOCKET_TCP** (8) | stream_connection | 流式：Lua 侧 `socket.read(fd, delim)` / `socket.read(fd, count)`，按分隔符或定长读；无内置包头。 |
| **PTYPE_SOCKET_MOON** (11) | moon_connection | 2 字节长度头 + body；accept/connect 后自动发 accept/connect 事件，然后按长度读包，回调 message/close。 |
| **PTYPE_SOCKET_WS** (10) | ws_connection | WebSocket 协议。 |

- **listen(host, port, owner, type)**：在本 worker 的 acceptors_ 里新建 acceptor，`type` 表示“之后 accept 出来的连接”的类型。
- **accept(fd, sessionid, owner)**：在**本 worker** 的 acceptors_ 里找到 listenfd；取 **owner 所在 worker** `w`，在 `w` 里 `make_connection(owner, ctx->type, tcp::socket(w->io_context()))`，即新 socket 用 **owner 的 io_context**；然后对本线程的 `ctx->acceptor.async_accept(c->socket(), ...)`，完成后在 **owner 的 worker** 上 `add_connection`，并把 fd 通过 message 回给调用 accept 的 service（通常即 listen 所在 service）。
- **connect(host, port, owner, type, sessionid, timeout)**：在**当前 worker** 上 `make_connection(owner, type, tcp::socket(context_))`，async_connect 成功后把 conn 放入**当前 worker** 的 connections_，并给 owner 发一条带 fd 的 message（owner 可能与当前 worker 不同，但连接 fd 一定在当前 worker）。

要点：**listen 与 accept 的调用、以及 async_accept 的完成，都发生在“持有 listenfd 的 worker”上；新连接 fd 的归属由 accept 的 owner 或 connect 的当前 worker 决定，之后该 fd 的 read/write 只在该 worker 上执行。** 详见 [game_server_extension_integration.md](game_server_extension_integration.md) 中的“线程与 fd”说明。

---

## 4. listen / accept / connect 流程概览

### 4.1 listen

1. Lua：`socket.listen(host, port, type)` → 当前 service 所在 worker 的 socket_server。
2. C++：`listen(host, port, owner, type)` 在本 worker 的 `context_` 上创建 `acceptor_context`，bind + listen，`nextfd()` 得到 listenfd，放入本 worker 的 **acceptors_**，返回 (listenfd, endpoint)。

### 4.2 accept(listenfd, owner)

1. Lua：`socket.accept(listenfd, serviceid)`（serviceid 即 owner）→ 必须在**持有 listenfd 的 worker** 上调用，否则 acceptors_.find(fd) 找不到。
2. C++：在本 worker 的 acceptors_ 找到 fd；`get_worker(0, owner)` 得到 owner 的 worker `w`；在 `w` 上创建 `make_connection(owner, ctx->type, tcp::socket(w->io_context()))`；本 worker 的 `ctx->acceptor.async_accept(c->socket(), ...)`。
3. 异步完成时（仍在 listen 所在 worker 的 io_context）：`c->fd(server_->nextfd())`，`w->socket_server().add_connection(this, ctx, c, sessionid)`。
4. **add_connection** 在 **owner 的 worker** 上执行：`connections_[c->fd()] = c`，`c->start(true)`；再通过 `asio::dispatch(from->context_, ...)` 把 `message{PTYPE_INTEGER, 0, 0, sessionid, fd}` 发回**调用 accept 的 worker**，使 Lua 的 `moon.wait()` 收到 fd。

结果：**新连接 fd 只存在于 owner 的 worker 的 connections_**，后续 read/write 都在 owner 线程。

### 4.3 connect

1. Lua：`socket.connect(host, port, type, timeout)` → 当前 service 所在 worker 的 socket_server。
2. C++：在当前 worker 上 `make_connection(owner, type, tcp::socket(context_))`，async_resolve + async_connect；成功后在**当前 worker** 的 connections_ 里 `try_emplace(conn->fd(), conn)`，并给 owner 发 `message{PTYPE_INTEGER, 0, 0, sessionid, fd}`。
3. 若 owner 是当前 service，Lua 的 `moon.wait()` 收到 fd；若 owner 是其他 service，消息会投递到该 service 所在 worker。

---

## 5. 连接上的 read / write / close

- **read(fd, n, delim, sessionid)**：在**持有 fd 的 worker** 上，`connections_.find(fd)` 得到 connection，调用其 `read(...)`。stream_connection 按 delim 或长度异步读，读完后通过 `handle_message(owner, message{...})` 把数据发给 owner；moon_connection 内部按 2 字节头读包，再回调。
- **write(fd, data, mask)**：同样在持有 fd 的 worker 上，找到 connection，`send(data)` 入写队列，asio::async_write 在同一个 io_context 上发出。
- **close(fd)**：在**当前** socket_server 上查找 fd（connections_ / udp_ / acceptors_），找到则关闭并 erase，并 `server_->unlock_fd(fd)`。因此 **close 必须在持有该 fd 的 worker 上调用**（通常由该 worker 上的 service 调用，或通过消息让该 worker 上的 service 调）。

---

## 6. 从 C++ 到 Lua 的消息投递

- connection 上产生事件（收到数据、对端关闭、accept/connect 成功等）时，调用 `parent_->handle_message(serviceid_, message{...})`，即 **socket_server::handle_message(serviceid, msg)**。
- handle_message 里：`find_service(serviceid)` 得到本 worker 上的 service（Lua），然后 **moon::handle_message(s, std::forward<Message>(m))**，把 message 投递到该 service 的 Lua 层。
- 若 message 的 type 为 **PTYPE_SOCKET_TCP** / **PTYPE_SOCKET_MOON** 等，Lua 侧通过 `moon.raw_dispatch("moonsocket", fn)` 或按 type 的 dispatch 收到；msg 中 **sender** 常为 fd，**receiver** 或 body 中带事件类型（accept、message、close 等）。详见 [tcp_server_listen_to_callback_flow.md](tcp_server_listen_to_callback_flow.md)、[moon_decode_format_reference.md](moon_decode_format_reference.md)。

**要点**：socket 事件只会投递到**该 fd 所属 worker** 上的 service；若希望由其他 worker 上的 service 处理，必须在 Lua 里把 fd 或数据再通过 `moon.send` 转发到目标 service（例如 guess_game_extension 中 bootstrap accept 后把 fd 发给 bridge，fd 本身已在 bridge 的 worker 上）。

---

## 7. UDP

- **udp_open(owner, host, port)**：在本 worker 的 context_ 上创建 udp::socket，放入 **udp_**，并启动 do_receive。
- 收包在 do_receive 里完成，然后 `handle_message(owner, msg)`，msg.type = PTYPE_SOCKET_UDP，sender 等由 udp_context 填充。
- **send_to(fd, address, data)** 等同样在本 worker 的 udp_ 中查找 fd 后发送。

UDP 的 fd 与 TCP 的 fd 共用同一套 nextfd，但分别存在 udp_ 与 connections_ 中，close 时按类型在对应 map 中删除。

---

## 8. 小结表

| 概念 | 说明 |
|------|------|
| 网络对象归属 | 每个 listen fd / 连接 fd / UDP fd 只属于**一个 worker** 的 socket_server（acceptors_ / connections_ / udp_）。 |
| listen | 在哪个 worker 调 listen，listenfd 就在该 worker 的 acceptors_。 |
| accept | 必须在**持有 listenfd 的 worker** 上调用；新连接创建在 **owner 的 worker**，fd 加入 owner 的 connections_。 |
| connect | 在哪个 worker 调 connect，新连接就在该 worker 的 connections_。 |
| read/write/close | 必须由**持有该 fd 的 worker** 上的逻辑调用（通常即该 worker 上的 service 的 Lua 代码）。 |
| 消息到 Lua | connection 事件 → socket_server::handle_message(serviceid, msg) → 本 worker 的 service（Lua）；跨 worker 需业务层再转发。 |

相关文档：  
[tcp_server_listen_to_callback_flow.md](tcp_server_listen_to_callback_flow.md)、[socket_close_and_lua_callback.md](socket_close_and_lua_callback.md)、[moon_decode_format_reference.md](moon_decode_format_reference.md)、[game_server_extension_integration.md](game_server_extension_integration.md)。
