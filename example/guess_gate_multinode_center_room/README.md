# 多节点示例：Center + Room（单 bridge 多连接）

与 [guess_gate](../guess_gate/) 相同的猜数字玩法，但架构为**多节点**：

- **Center 节点**：一个 **bridge** 服务接收**所有**游戏服连接（单 bridge 多 fd）；**center** 只做匹配，满人后通过 TCP RPC 通知 Room 节点建房，并向游戏服下发 `match_ok(room_addr, room_id)`。
- **Room 节点**：监听 RPC（create_room）与游戏服连接（attach_room、guess）；房间内战斗逻辑在本节点完成，下行直接写回游戏服连接。

对应文档： [game_server_gate_multinode.md](../../docs/game_server_gate_multinode.md) §6.6（Center + Room，Gate 非必须）、单 bridge 见 [game_server_gate_single_node.md](../../docs/game_server_gate_single_node.md) §8.1。

## 端口

| 节点   | 端口   | 用途                         |
|--------|--------|------------------------------|
| Center | 13001  | 游戏服连接（匹配阶段）       |
| Room   | 13002  | 游戏服连接（房间阶段）       |
| Room   | 13005  | Center → Room 的 create_room RPC |

可通过环境变量覆盖：`CENTER_PORT`、`ROOM_GAME_PORT`、`ROOM_RPC_PORT`、`ROOM_RPC_HOST`（Center 连 Room 时用）。

## 运行顺序

进入示例目录后，依次开两个终端运行 Center / Room，再运行模拟脚本：

```bash
cd example/guess_gate_multinode_center_room
```

1. **先启动 Room 节点**（否则 Center 建房 RPC 会失败）：
   ```bash
   moon main_room_node.lua
   ```

2. **再开一个终端，启动 Center 节点**：
   ```bash
   moon main_center_node.lua
   ```

3. **第三个终端运行游戏服模拟**（模拟两名玩家、两台“游戏服”连接 Center 匹配后直连 Room）：
   ```bash
   moon game_server_sim.lua
   ```

单机测试时，Center 与 Room 为两个 Moon 进程；`game_server_sim.lua` 连本机 Center，收到 match_ok 后连本机 Room 完成对局。

## 文件说明

| 文件                      | 说明 |
|---------------------------|------|
| `main_center_node.lua`    | Center 节点入口：起 center + bridge，listen 13001，accept 后 bridge add_fd。 |
| `service_center_match.lua` | 匹配逻辑；满人后 TCP RPC 到 Room 建房，再下发 match_ok。 |
| `service_bridge_multi.lua` | 单 bridge 多连接：player_id→fd，add_fd/forward/forward_broadcast。 |
| `main_room_node.lua`     | Room 节点入口：起 room_node 并发送 start。 |
| `service_room_node.lua`  | 监听 13005（RPC）、13002（游戏服）；create_room、attach_room、guess 与猜数字逻辑。 |
| `protocol.lua`           | 上行/下行行协议（与 guess_gate 一致）。 |
| `game_server_sim.lua`    | 模拟两台“游戏服”：连 Center 发 ready，收 match_ok 后连 Room 发 attach_room 与 guess。 |
