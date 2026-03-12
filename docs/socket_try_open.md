# socket_server::try_open 说明

本文说明 `socket_server::try_open` 的作用，以及为何其中的 acceptor 不会加入 `acceptors_`。

---

## 1. 函数作用

`try_open(host, port, is_connect)` 是一个**探测函数**：在真正建连或监听之前，先“试一次”是否可行，**不保留任何 socket 或 acceptor**。

### 1.1 `is_connect == true`（连接探测）

- 创建一个 TCP socket，对 `host:port` 执行一次 `connect`，然后立刻 `close`。
- 用途：检查**对端是否可达**（例如 Redis、MySQL 等服务是否在线）。
- 项目中的用法：`service/sqldriver.lua`、`service/redisd.lua` 里用 `socket.try_open(host, port, true)` 在启动时探测数据库/Redis 是否可用。

### 1.2 `is_connect == false`（端口探测）

- 解析 `host:port`，创建一个**临时的** `tcp::acceptor`，执行 `open`、`bind` 到该地址，然后立刻 `acceptor.close()`。
- 用途：检查**本机该地址/端口是否还能被绑定**（例如端口是否已被占用）。

两种情况下，函数都只做一次尝试，然后关闭资源并返回 `true`/`false`。

---

## 2. 为什么 acceptor 没有加入 acceptors_？

因为 **`try_open` 的职责就是“试一下”，不负责真正监听**：

- 这里的 `acceptor` 仅用于做一次 `bind` 探测，探测完就 `acceptor.close()`，因此** intentionally 不**加入 `acceptors_`。
- 真正要监听时，应调用 **`listen()`**。在 `listen()` 中会：
  - 创建 `acceptor_context`（包含真正的 acceptor），
  - 执行 `open`、`bind`、`listen`，
  - 通过 `acceptors_.try_emplace(id, ctx)` 把该 acceptor 上下文存入 `acceptors_`（见 `socket_server.cpp` 中 `listen` 实现）。

可以简单记为：

- **`try_open`**：只做“能不能连 / 能不能绑”的探测，用完即关，不加入 `acceptors_`。
- **`listen`**：真正开始监听，并把对应的 acceptor 存进 `acceptors_`。

---

## 3. 相关代码位置

| 内容           | 文件 |
|----------------|------|
| `try_open` 实现 | `src/moon/core/network/socket_server.cpp` |
| `listen` 实现   | `src/moon/core/network/socket_server.cpp`（创建 ctx 并 `acceptors_.try_emplace`） |
| Lua 绑定       | `src/lualib-src/lua_moon.cpp` 中 `lasio_try_open` |
| 使用示例       | `service/sqldriver.lua`、`service/redisd.lua` |
