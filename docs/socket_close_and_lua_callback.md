# Socket 关闭与 Lua close 回调说明

本文说明两件事：**对端关闭连接时 C++ 侧会发生什么**，以及 **为什么只有“出错”路径会通知 Lua 的 close 回调，而本端主动 close 不会触发回调**。

---

## 1. 对端关闭时会发生什么

### 1.1 触发点：async_read 完成并带回错误

以 **moon_connection**（PTYPE_SOCKET_MOON）为例，连接在 `read_header()` 或 `read_body()` 里通过 `asio::async_read` 等待数据。当**对端关闭连接**（FIN 或 RST）时：

- `async_read` 会完成（complete），并带上一个非空的 `asio::error_code e`；
- 常见错误码包括：
  - `asio::error::eof`：对端正常关闭（收到 FIN）；
  - `asio::error::connection_reset`：对端 RST 或网络异常。

### 1.2 回调链：error(e) → 通知 Lua → 从 connections_ 移除

在 `moon_connection.hpp` 中，`async_read` 的完成回调是：

```cpp
if (!e) {
  handle_header();  // 或 handle_body 等
  return;
}
error(e);   // 对端关闭或读错误时走这里
```

即：**只要 `e` 非空，就会调用 `base_connection::error(e)`**。

在 **base_connection.hpp** 的 `error()` 里会：

1. 若 `parent_` 已为空则直接返回（防止重复处理）；
2. 用 `e.message()` 和 `e.value()` 拼出 JSON 字符串 `content`（包含 `addr`、`code`、`message`）；
3. 调用 **`parent_->close(fd_)`**：在 `socket_server` 里从 `connections_` 移除该连接并 `unlock_fd`；
4. 调用 **`handle_message(message{..., socket_data_type::socket_close, 0, content})`**：向 Lua 所在 service 发一条 **PTYPE_SOCKET_MOON + socket_close** 消息，消息体为上述 JSON；
5. 置 **`parent_ = nullptr`**，避免再次进入 `error` 或其它逻辑。

因此：**对端关闭 → async_read 带错完成 → error(e) → 发 socket_close 给 Lua → Lua 的 `socket.on("close", fn)` 被调用**，`msg` 里可以 `moon.decode(msg, "Z")` 得到错误信息 JSON。

### 1.3 其它会走到 error() 的情况

以下情况同样会调用 `error(e)`，从而触发 Lua 的 close 回调：

- **读超时**：`base_connection::timeout()` 里 `error(make_error_code(moon::error::read_timeout))`；
- **写失败**：`post_send()` 里 `async_write` 完成时 `if (e) error(e)`；
- **发送队列过大**：`send()` 里 `error(make_error_code(moon::error::send_queue_too_big))`；
- **moon_connection 包过大**：`send()` 或协议检查里 `error(make_error_code(moon::error::write_message_too_big))` 等。

以上都会：关闭连接、从 `connections_` 移除、并给 Lua 发一条 **socket_close** 消息。

---

## 2. 为什么只有“出错”才通知 Lua，而 close 不通知？

### 2.1 设计区分：谁导致的关闭

- **“出错”路径**：对端关闭、超时、读写失败等 → 连接是**被动/意外**断开的，Lua 侧需要知道“这个 fd 已经没了，原因是什么”，所以通过 **socket_close 消息** 通知 Lua，并带上错误信息（JSON）。
- **“本端主动 close”路径**：Lua 调用了 `socket.close(fd)`（或内部等价逻辑）→ 连接是**本端主动**关的，调用方自己知道在关哪个 fd，不需要再收一条“该 fd 已关闭”的回调。

因此：**Lua 的 close 回调只用于“被动/异常关闭”；主动 close 不触发 close 回调**。

### 2.2 本端主动 close 时 C++ 做了什么（不通知 Lua）

当 Lua 调用 **`socket.close(fd)`** 时：

- 绑定到 **`socket_server::close(fd)`**（见 `socket_server.cpp`）；
- 在 `connections_` 里找到该 fd，调用 **`iter->second->close()`**；
- `base_connection::close()` 仅做：
  - `socket_.shutdown(shutdown_both)`
  - `socket_.close()`
- 然后 **`connections_.erase(iter)`**、**`server_->unlock_fd(fd)`**。

这里**没有**调用 `error()`，也**没有** `handle_message(socket_close, ...)`，所以 **Lua 不会收到该 fd 的 close 回调**。这是有意为之：避免“我关了 fd，再收一条 close 事件”的冗余。

### 2.3 write_then_close 的情况

若 Lua 使用 **`socket.write_then_close(fd, data)`**，C++ 在 `post_send()` 里等 `async_write` 成功后，若带有 `would_close` 标记，会执行：

```cpp
parent_->close(fd_);
parent_ = nullptr;
```

同样是**只从 connections_ 移除并清空 parent_**，**不**调用 `error()`，**不**发 socket_close。因为“发完再关”也是本端主动关闭，不需要再通知 Lua 一次。

---

## 3. 小结表

| 关闭原因           | 是否调用 error() | 是否发 socket_close 给 Lua | Lua 是否收到 close 回调 |
|--------------------|------------------|----------------------------|-------------------------|
| 对端关闭（eof/RST）| 是               | 是                         | 是                      |
| 读超时             | 是               | 是                         | 是                      |
| 写失败             | 是               | 是                         | 是                      |
| 发送队列过大等错误 | 是               | 是                         | 是                      |
| Lua 调用 socket.close(fd) | 否        | 否                         | 否                      |
| write_then_close 完成 | 否           | 否                         | 否                      |

结论：

- **对端关闭**：`async_read` 带错完成 → `error(e)` → 发 socket_close → Lua 的 `socket.on("close", fn)` 被调用。
- **只有“错误/被动关闭”路径会通过 `error()` 通知 Lua；本端主动 close 不会触发 close 回调**，这样避免重复通知，语义也更清晰。

---

## 4. 相关代码位置

| 内容 | 文件 |
|------|------|
| async_read 完成时调用 error(e) | `src/moon/core/network/moon_connection.hpp`（read_header / read_body 的 lambda） |
| error() 实现：发 socket_close、parent_->close、parent_=nullptr | `src/moon/core/network/base_connection.hpp` |
| socket_server::close(fd)：只 close() + erase，不通知 Lua | `src/moon/core/network/socket_server.cpp` |
| post_send 中 would_close 时 parent_->close，不通知 | `src/moon/core/network/base_connection.hpp` |
