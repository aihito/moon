# 多节点示例：Center + Room（单 bridge 多连接）

与 [guess_gate](../guess_gate/) 相同的猜数字玩法，但架构为**多节点**：

- **Center 节点**：**bridge** 接收游戏服连接；**room_gate** 统一持有 Room 节点连接池，对外提供 `create_room` 等 RPC；**match** 等任意服务只通过 room_gate 与 Room 通讯，便于扩展（多 match、统计等）。Room 节点主动连上 Center 后由 room_gate 注册。
- **Room 节点**：**主动连接 Center**（长连接收 create_room），并监听游戏服连接（attach_room、guess）；房间内战斗逻辑在本节点完成，下行直接写回游戏服连接。

对应文档： [game_server_gate_multinode.md](../../docs/game_server_gate_multinode.md) §6.6（Center + Room，Gate 非必须）、单 bridge 见 [game_server_gate_single_node.md](../../docs/game_server_gate_single_node.md) §8.1。

## 协议与 Protobuf

- **当前**：仍使用文本行协议（`shared/protocol.lua`），格式为 `player_id\tcmd\targs` / `target\tplayer_ids\tcmd\tdata`。
- **Protobuf**：已引入 `.proto` 定义与多线程加载，供后续扩展或切换为 pb 消息体。
  - 协议定义：`protocol/proto/guess.proto`（C2SReady、S2CMsg、S2CMatchOk、C2SGuess、S2CGameOver 等）。
  - 消息 ID 映射：`protocol/CmdCode.lua`。
  - **生成 .pb**（可选，用于启动时直接加载二进制）：在仓库根目录执行  
    `./example/guess_gate_multinode_center_room/run.sh gen_proto`  
    或  
    `./target/debug/moon example/guess_gate_multinode_center_room/tools/gen_proto.lua`  
    会编译 `protocol/proto/guess.proto` 并输出 `protocol/guess.pb`。
  - **多线程**：`center_main.lua` / `room_main.lua` 在创建服务前加载协议（优先 `protocol/guess.pb`，若无则用 `protoc` 从 .proto 编译），并调用 `pb.share_state()`，使各 worker 线程共享同一 schema。
  - 编解码封装：`shared/protocol_pb.lua`（`encode(name, tbl)` / `decode(name, bytes)`），可与现有文本协议并存。

## 端口

| 节点   | 端口   | 用途                               |
|--------|--------|------------------------------------|
| Center | 13001  | 游戏服连接（匹配阶段）             |
| Center | 13005  | Room 节点主动连此端口（收 create_room） |
| Room   | 13002  | 游戏服连接（房间阶段）             |

可通过环境变量覆盖：`CENTER_PORT`、`CENTER_ROOM_PORT`、`CENTER_HOST`（Room 连 Center 用）、`ROOM_GAME_PORT`、`ROOM_GAME_HOST`（match_ok 中 room_addr 的 fallback）、`ROOM_GAME_ADDR`（Room 节点在 create_room 响应中上报的对外地址，Center 原样通知客户端）。

## 运行顺序

### 方式一：用 shell 脚本（推荐，从仓库根目录执行）

以 `./target/debug/moon` 为例（可设置环境变量 `MOON` 覆盖）：

```bash
# 仓库根目录
MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh start   # 后台起 Room + Center
MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh test    # 跑一局（alice + bob）
MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh test_multi_room  # 多 Room 多客户端（见下）
example/guess_gate_multinode_center_room/run.sh stop    # 停掉 Room 与 Center
```

### 方式二：手动起进程

进入示例目录后，依次开两个终端运行 Center / Room，再运行模拟脚本：

```bash
cd example/guess_gate_multinode_center_room
```

1. **先启动 Center 节点**（Room 会主动连 Center，故 Center 需先监听）：
   ```bash
   moon center/main.lua
   ```

2. **再开一个终端，启动 Room 节点**：
   ```bash
   moon room/main.lua
   ```

3. **第三个终端运行游戏服模拟**（单人客户端，需跑两份才能凑齐 2 人匹配）：
   ```bash
   # 方式一：run.sh test 会自动起 alice + bob 两个进程
   MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh test
   # 方式二：手动开两终端各跑一个
   SIM_PLAYER=alice ./target/debug/moon example/guess_gate_multinode_center_room/game_server_sim.lua
   SIM_PLAYER=bob   ./target/debug/moon example/guess_gate_multinode_center_room/game_server_sim.lua
   ```

单机测试时，Center 与 Room 为两个 Moon 进程；`game_server_sim.lua` 为**单人客户端**，连 Center 发 ready，收到 match_ok 后连 Room 进房猜数。多人则多开进程（不同 `SIM_PLAYER`）。

## 详细测试：多 Room 多客户端

**场景**：多房间、多组客户端同时匹配，验证 Center 单 bridge 多连接、多房间并发。

- **多房间**：Center 每次凑齐 2 人建一间 Room，多组玩家同时匹配会形成多间房。
- **多客户端**：每人一个 sim 进程（单人客户端），多进程并行连 Center。

**用例**：2 个房间、4 名玩家 —— 同时跑四个 `game_server_sim.lua`（SIM_PLAYER=alice/bob/carol/dave）：

| 进程       | 玩家   | 结果     |
|------------|--------|----------|
| sim 进程 1 | alice  | 匹配进房间 A |
| sim 进程 2 | bob    | 匹配进房间 A |
| sim 进程 3 | carol  | 匹配进房间 B |
| sim 进程 4 | dave   | 匹配进房间 B |

**步骤**（从仓库根目录）：

1. 启动节点（若未启动）：
   ```bash
   MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh start
   ```

2. 一键跑“多 Room 多客户端”测试（脚本会并行起两个 sim，等两者都结束）：
   ```bash
   MOON=./target/debug/moon example/guess_gate_multinode_center_room/run.sh test_multi_room
   ```

   脚本内部：并行起 4 个单人客户端（alice, bob, carol, dave），前两人进房间 1，后两人进房间 2。

3. 手动分终端跑（可选）：
   ```bash
   SIM_PLAYER=alice "$MOON" "$EX/game_server_sim.lua"
   SIM_PLAYER=bob   "$MOON" "$EX/game_server_sim.lua"
   # 另两终端
   SIM_PLAYER=carol "$MOON" "$EX/game_server_sim.lua"
   SIM_PLAYER=dave  "$MOON" "$EX/game_server_sim.lua"
   ```

**预期**：Center 的 match_queue 先后凑齐 (alice,bob) 与 (carol,dave)，对 Room 发起两次 create_room RPC，产生两间房；两组 sim 分别收到各自的 match_ok，连 Room 后各自完成猜数字对局。

## 文件说明

| 文件 / 目录 | 说明 |
|-------------|------|
| `center/main.lua` | Center 节点入口：起 match、bridge、room_gate；listen 13001（游戏服）、13005（Room 连入）。 |
| `center/match_service.lua` | 匹配逻辑；满人后通过 room_gate 建房，再下发 match_ok。 |
| `center/bridge_service.lua` | 单 bridge 多连接：player_id→fd，add_fd/forward。 |
| `center/room_gate_service.lua` | **Room 网关**：持有 Room 连接池，对外提供 create_room、room_conn_count 等 RPC；match 及其他需与 Room 通讯的服务均经此扩展。 |
| `room/main.lua` | Room 节点入口：起 room_manager 并发送 start。 |
| `room/room_manager_service.lua` | 主动连 Center、监听游戏服；按 room_id 分发上行。 |
| `room/room_service.lua` | 每房间一个服务：create_room/add_conn/on_msg/conn_closed，猜数字逻辑。 |
| `shared/protocol.lua` | 上行/下行行协议（与 guess_gate 一致）。 |
| `game_server_sim.lua` | 单人客户端：连 Center 发 ready，收 match_ok 后连 Room 进房并二分猜数。多人在多进程/多终端各跑一份。 |
| `run.sh` | 测试脚本：`start` 起 Center+Room，`test` 跑一局，`stop` 停节点。 |
