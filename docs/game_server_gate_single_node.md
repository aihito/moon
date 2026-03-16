# 游戏服网关 · 单节点接入方案（匹配 / 房间 / 战斗）

本文面向**已有游戏服、Moon 作为网关做扩展逻辑**的场景：玩家已在游戏服登录，游戏服与 Moon 建立**一条连接**，扩展玩法（匹配、房间、同房战斗）的消息由**游戏服转发**，Moon 只做逻辑，回包经游戏服再转发给玩家。结构上参考 `guess_game`，但**不**由 Moon 直接接客户端 TCP。

**多节点扩展**（多台 Moon 水平扩展、匹配策略、全局匹配等）见 [game_server_gate_multinode.md](game_server_gate_multinode.md)。本文为**单节点**方案。示例代码见 `example/guess_gate/`。

---

## 1. 与 guess_game 的差异

| 项目 | guess_game（Moon 即游戏服） | 本方案（游戏服 + Moon 网关） |
|------|-----------------------------|------------------------------|
| 客户端连接 | 客户端直连 Moon（socket.listen + 一连接一 user 服务） | 客户端只连**游戏服**；Moon 不接客户端 |
| 玩家身份 | 每个连接一个 `service_user`，持有 `fd` | 玩家身份由游戏服维护；Moon 侧只认 **player_id**，无额外“玩家服务” |
| 下行（Moon → 玩家） | `socket.write(client.fd, data)` | Moon 把数据发给 **bridge**，bridge 写 fd → 游戏服按 player_id 转发 |
| 上行（玩家 → Moon） | 客户端发 → user 服务读 fd → 解析命令 → center/room | 游戏服收客户端包 → 转发给 Moon（带 player_id/session/cmd）→ **bridge** 收 → 按 cmd 转 center 或 room |

**说明**：不需要为每个玩家再起 user_proxy 服务；bridge 维护 `player_id → room_id` 路由表即可，center/room 只发消息给 bridge 并带上 player_id(s)。

---

## 2. 整体架构（三服务：bridge + center + room）

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────────────────────────────┐
│   Client A  │◄────►│                  │      │  Moon 进程                            │
│   Client B  │      │   游戏服          │◄────►│  ┌─────────┐  ┌─────────┐  ┌────────┐ │
│   ...       │      │   (已有)          │ 一条  │  │ bridge  │◄─►│ center  │──►│ room   │ │
└─────────────┘      │                  │ 连接  │  │ 收/发+  │   │ (匹配)  │   │ (战斗) │ │
                      │  维护玩家会话     │      │  │ 路由表   │   └─────────┘   └────────┘ │
                      └──────────────────┘      │  └─────────┘                                │
                               │                 └─────────────────────────────────────────────┘
                               │ 转发上行/下行
```

- **游戏服**：已有逻辑；与 Moon 之间维持**一条**连接，负责上行（player_id + cmd + 参数）与下行（target + player_id(s) + data）的转发。
- **Moon 内**（仅三个服务，无 user_proxy）：
  - **bridge**：持有与游戏服的 fd；维护 `player_id → room_id` 路由表（由 center 在进房/退房时更新）；上行解包后 `join_match` 转 center、`room_action` 查表转 room；下行收 center/room 的 `forward` / `forward_broadcast`，编码写 fd。
  - **center**：匹配与房间管理；“玩家”即 `{ player_id, name }`，无 fd；满人则 new room，并通知 bridge 更新路由；发给玩家一律 `moon.send(bridge, "forward", ...)`。
  - **room**：房间内战斗/玩法；房间内玩家即 `{ player_id, name }` 列表；广播/单发都 `moon.send(bridge, "forward_broadcast" | "forward", ...)`，由 bridge 统一发回游戏服。

---

## 3. 连接与协议约定（游戏服 ↔ Moon）

### 3.1 连接方式

- **方式一**：游戏服主动连 Moon 的 TCP 端口（推荐）。Moon 里 `socket.listen` 一个“游戏服专用”端口，`accept` 得到**一个** fd，交给 bridge；游戏服侧维护这条长连接，所有扩展协议都走这条连接。
- **方式二**：Moon 主动连游戏服。游戏服提供“扩展服务端口”，Moon 启动时 `socket.connect` 一次，连接 fd 交给 bridge。逻辑对称，仅谁 listen / 谁 connect 不同。

### 3.2 包格式（示例，可替换为 protobuf）

建议每条消息带“谁发的、回给谁、请求/响应标识”，便于转发与匹配：

**上行（游戏服 → Moon）**（每包一条）：

- `player_id`：游戏服内玩家唯一 id（数字或字符串）。
- `session_id`：可选，请求 id，下行原样带回，便于游戏服做 request/response 映射。
- `cmd`：扩展命令，如 `"join_match"`、`"room_action"`、`"leave_room"`。
- `args`：表或二进制，由 cmd 决定。

示例（Lua 表序列化或 JSON）：  
`{ player_id = 10001, session_id = 1, cmd = "join_match", args = {} }`

**下行（Moon → 游戏服）**（每包一条）：

- `target`：`"player" | "room_broadcast"`；
  - `"player"` 时带 `player_id`（单发）；
  - `"room_broadcast"` 时带 `player_ids`（房间内列表），游戏服对列表里每人发一份或按需优化。
- `session_id`：可选，对应上行。
- `cmd`：如 `"match_ok"`、`"room_start"`、`"room_broadcast"`、`"game_over"`。
- `data`：业务数据。

示例：  
`{ target = "player", player_id = 10001, session_id = 1, cmd = "match_ok", data = { ... } }`  
`{ target = "room_broadcast", player_ids = { 10001, 10002 }, cmd = "room_broadcast", data = "游戏开始..." }`

游戏服与 Moon 可约定：前 2 字节长度 +  body（如 Lua pack 或 pb），由 bridge 与游戏服侧各实现编解码。

---

## 4. Moon 内服务职责与消息流（无 user_proxy）

### 4.1 bridge（与游戏服的一条连接）

- **持有**：fd（与游戏服）；表 `player_room[player_id] = room_id`（由 center 在进房时写入、退房时清除），用于把 `room_action` 路由到正确房间。
- **上行**：读 fd 解包得到 `player_id, session_id, cmd, args`：
  - `join_match` → `moon.send("lua", center_id, "ready", { player_id, name })`（name 可由游戏服在上行里带过来，或用 player_id 代替）。
  - `room_action` → `room_id = player_room[player_id]`，若存在则 `moon.send("lua", room_id, "action", player_id, session_id, cmd, args)`。
- **下行**：处理两类消息（由 center/room 发来）：
  - `forward(target, player_id, session_id, cmd, data)`：单发，target = `"player"`，编码后写 fd。
  - `forward_broadcast(player_ids, session_id, cmd, data)`：房间广播，编码成多条或一条带 player_ids 的包，写 fd。
- **路由表更新**：center 在“满人进房”时 `moon.send("lua", bridge_id, "register_room", { [player_id] = room_id, ... })`；在“房间结束”时 `moon.send("lua", bridge_id, "unregister_room", player_ids)`，bridge 清除这些 player_id 的映射。

### 4.2 center（匹配与房间管理）

- 与 guess_game 类似：维护 `match_queue`、`match_state`、`user_rooms[player_id] = room_id`；“玩家”即 `{ player_id, name }`，无 service id。
- 满 N 人：`moon.new_service(room)`，`moon.send("lua", room_id, "start", [ { player_id, name }, ... ])`；再 `moon.send("lua", bridge_id, "register_room", { [player_id] = room_id for each })`，并写 `user_rooms[player_id] = room_id`。
- 发给玩家：一律 `moon.send("lua", bridge_id, "forward", "player", player_id, session_id, cmd, data)`（如“匹配成功”提示）。
- 房间结束：`moon.send("lua", bridge_id, "unregister_room", player_ids)`，并清空 `user_rooms`。

### 4.3 room（房间内战斗/玩法）

- `room_clients` = `[ { player_id, name }, ... ]`，无 service id。
- **广播**：`moon.send("lua", bridge_id, "forward_broadcast", player_ids, nil, "room_msg", data)`，bridge 负责发回游戏服（游戏服再对 player_ids 每人发一份或按协议优化）。
- **单发**：`moon.send("lua", bridge_id, "forward", "player", player_id, session_id, cmd, data)`。
- 游戏结束 / 有人离开：通知 center（如 `game_over(room_clients)`），center 再调 bridge 的 `unregister_room`。

---

## 5. 目录与文件建议（三服务，无 user_proxy）

```
guess_gate/
├── main.lua              # 入口：启动 center、监听“游戏服连接”端口、accept 后把 fd 交给 bridge
├── service_bridge.lua    # 与游戏服的一条连接：收包解包 → 转 center/room；维护 player_room；收 forward/forward_broadcast → 写 fd
├── service_center.lua    # 匹配逻辑（与 guess_game 的 center 类似，client = { player_id, name }）
├── service_room.lua      # 房间逻辑（与 guess_game 的 room 类似，broadcast/单发都发 bridge 的 forward/forward_broadcast）
└── protocol.lua          # 协议解析与组包（可选，便于扩展）
```

- **main.lua**：  
  - `moon.new_service` center（unique）；  
  - `socket.listen(host, port_for_gameserver, moon.PTYPE_SOCKET_TCP)`（或 MOON 协议）；  
  - 循环里 `socket.accept(listenfd, bridge_id)` 接受连接，把 fd 通过 `moon.send("lua", bridge_id, "set_fd", fd)` 交给 bridge；若断线可再 accept 等待游戏服重连。  
  - **线程与 fd**：`accept(listenfd, bridge_id)` 的第二个参数是 **owner**：新连接在 C++ 侧被创建并加入 **bridge 所在 worker** 的 `connections_`（见 `socket_server::accept` → `get_worker(0, owner)` → `add_connection`）。因此 fd 的 read/write 与 bridge 在同一线程，框架支持“在 bootstrap 里 accept、在 bridge 里读写”这种用法。

- **service_bridge.lua**：  
  - 持有 `fd`（与游戏服）、表 `player_room[player_id] = room_id`；`set_fd(fd)`；`dispatch` 里处理上行包（解包 → `join_match` 转 center、`room_action` 查表转 room）、`forward`/`forward_broadcast`（编码写 fd）、`register_room`/`unregister_room`（更新/清除路由表）。

- **service_center.lua**：  
  - 与 guess_game 的 `service_center.lua` 几乎一致，仅“client”为 `{ player_id, name }`，无 fd；满人时 `send(bridge, "register_room", ...)`；发给玩家一律 `send(bridge, "forward", ...)`；房间结束 `send(bridge, "unregister_room", player_ids)`。

- **service_room.lua**：  
  - 与 guess_game 的 `service_room.lua` 类似；`room_clients` 为 `[ { player_id, name }, ... ]`；广播/单发都 `send(bridge, "forward_broadcast" | "forward", ...)`。

---

## 6. 消息流示例（匹配 → 进房 → 战斗，无 user_proxy）

1. **游戏服**收到玩家 A 的“进入扩展匹配”请求 → 发上行到 Moon：`{ player_id = "A", cmd = "join_match" }`。
2. **bridge** 收包 → `send(center, "ready", { player_id = "A", name = "A" })`（name 可由游戏服上行带过来）。
3. **center** 把 A 加入 match_queue；若凑满 2 人，`new_service(room)`，`send(room, "start", [ { player_id = "A", name = "A" }, { player_id = "B", name = "B" } ])`，并 `send(bridge, "register_room", { ["A"] = room_id, ["B"] = room_id })`，bridge 更新 `player_room`；center 记录 `user_rooms["A"] = room_id`，B 同理。
4. **room** 收到 `start` → 广播“游戏开始...”：`send(bridge, "forward_broadcast", { "A", "B" }, nil, "msg", "游戏开始...")`；bridge 编码写 fd → **游戏服**收包 → 转发给玩家 A、B。
5. **游戏服**收到玩家 A 的“房间内操作”（如出招）→ 上行 `{ player_id = "A", cmd = "room_action", args = { action = "hit", target = "B" } }`。
6. **bridge** 查 `player_room["A"]` 得 room_id，`send(room, "action", "A", nil, "room_action", args)`。
7. **room** 处理逻辑 → 广播结果（如“A 对 B 造成 10 点伤害”）：`send(bridge, "forward_broadcast", { "A", "B" }, nil, "room_msg", data)` → bridge 写 fd → 游戏服 → 客户端。

---

## 7. 小结

| 项目 | 说明 |
|------|------|
| 连接 | 游戏服与 Moon **一条连接**（TCP）；由 **bridge** 持有 fd，负责上行解包与下行发包。 |
| 玩家在 Moon 侧 | 仅 **player_id（及 name）**，无 fd、无 user_proxy；bridge 维护 `player_room[player_id]=room_id` 做上行路由；下行由 center/room 发 bridge 的 `forward`/`forward_broadcast`，bridge 写 fd，游戏服按 player_id(s) 转发。 |
| 匹配 / 房间 / 战斗 | 与 guess_game 一致：center 做匹配与房间分配，room 做房间内逻辑；“客户端”即 `{ player_id, name }`，广播/单发都经 bridge。 |
| 协议 | 上行带 player_id、session_id、cmd、args；下行带 target（player / room_broadcast）、player_id(s)、cmd、data；具体格式可与游戏服约定（JSON、pb 等）。 |

按此方案即可在保留 guess_game 式“匹配 + 房间 + 同房战斗”的前提下，把“客户端连接”全部放在游戏服，Moon 只做网关逻辑、消息经由游戏服转发；**无需 user_proxy**，仅 bridge + center + room 三服务。

---

## 8. 扩展：单节点多游戏服（多 bridge）

当**游戏服数量多**但**单 Moon 进程仍可承受**时，可在同一节点内使用**多个 bridge**：每 `accept` 一个连接就 `new_service(bridge)` 并把 fd 交给该 bridge，**center 唯一**，维护 `player_id → bridge_id` 和 `player_id → room_id`，下行按 bridge_id 转发。

```
┌─────────────┐                    ┌─────────────────────────────────────────────────────────┐
│  游戏服 A   │─── 连接 ──────────►│  Moon 进程（单节点）                                       │
└─────────────┘                    │  ┌─────────┐  ┌─────────┐  ┌────────┐  ┌────────┐       │
┌─────────────┐                    │  │bridge_A│  │bridge_B │  │bridge_C│  │ ...    │       │
│  游戏服 B   │─── 连接 ──────────►│  │ fd_A   │  │ fd_B   │  │ fd_C   │  │        │       │
└─────────────┘                    │  └────┬────┘  └────┬────┘  └────┬───┘  └────────┘       │
┌─────────────┐                    │       └────────────┼────────────┘                      │
│  游戏服 C   │─── 连接 ──────────►│                    ▼                                    │
└─────────────┘                    │  ┌─────────────────────────────────────────────────────┐ │
                                   │  │ center（唯一）                                       │ │
                                   │  │ player_id → bridge_id；player_id → room_id          │ │
                                   │  └─────────────────────────────────────────────────────┘ │
                                   └─────────────────────────────────────────────────────────┘
```

**要点**：listen 端口不变，每 `accept` 得到 fd 后 `moon.new_service({ name = "bridge", file = "service_bridge.lua" })` 得到新 bridge_id，再 `set_fd(fd)`；bridge 在首包或协议中上报 player_id / game_server_id，center 维护 `player_bridge[player_id] = bridge_id`；下行时 center/room 按 player_id 查 bridge_id 再 `send(bridge_id, "forward", ...)` 或按 bridge_id 分组 `forward_broadcast`。

**多节点**（多台 Moon 水平扩展、仅本节点匹配 / 全局匹配、房间路由）见 [game_server_gate_multinode.md](game_server_gate_multinode.md)。
