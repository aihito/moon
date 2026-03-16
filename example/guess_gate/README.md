# Guess Game Extension (游戏服连 Moon)

与 [guess_game](../guess_game/) 相同的猜数字玩法，但**客户端不直连 Moon**，而是由**游戏服**与 Moon 保持**一条 TCP 连接**，按约定协议转发上下行。对应文档：`docs/game_server_gate_single_node.md`。多节点扩展见 `docs/game_server_gate_multinode.md`。

## 目录

| 文件 | 说明 |
|------|------|
| `main_extension.lua` | 入口：起 center/bridge、监听 12346、accept 后把 fd 交给 bridge；Ctrl+C 时关 listenfd 并等 service 收尾后退出 |
| `service_bridge.lua` | 与游戏服一条连接：上行用 `protocol.parse_upstream` 解析，按 `upstream_handlers[cmd]` 分发；下行用 `protocol.format_downstream` 写行 |
| `service_center.lua` | 匹配与房间管理，玩家为 `{ player_id, name }`，发玩家经 bridge |
| `service_room.lua` | 房间内猜数字，广播/单发经 bridge |
| `protocol.lua` | **协议层**：`parse_upstream(line)`、`format_downstream(...)`、`format_upstream(...)`，上行/下行格式集中在此，便于扩展 |
| `game_server_sim.lua` | 模拟游戏服：连 12346，用 `protocol.format_upstream` 发上行并打印下行 |

**扩展新上行命令**：在 `service_bridge.lua` 的 `upstream_handlers` 中加一项，例如 `upstream_handlers.leave = function(req) ... end`，无需改协议解析逻辑。

## 架构（无 user_proxy）

- **bridge**：持有与游戏服的 fd，维护 `player_id → room_id`，上行解包后转 center/room，下行收 `forward`/`forward_broadcast` 写 fd。
- **center**：匹配与房间管理，玩家为 `{ player_id, name }`，发给玩家一律经 bridge。
- **room**：房间内猜数字逻辑，广播/单发都经 bridge。

## 协议（行文本，`\n` 结尾）

- **上行（游戏服 → Moon）**：`player_id cmd [arg1 ...]`，字段用 **空格或 Tab** 分隔。
  - `ready`：加入匹配。
  - `guess <数字>`：猜数字（仅在房间内有效）。
- **下行（Moon → 游戏服）**：`target\tplayer_id(s)\tcmd\tdata`
  - `target`：`player` 单发，`broadcast` 广播。
  - `player_id(s)`：一个 id 或逗号分隔的多个。
  - 例如：`player\talice\tmsg\t匹配成功`、`broadcast\talice,bob\tmsg\t游戏开始...`

## 运行

在仓库根目录执行：

```bash
# 终端 1：启动 Moon 扩展（监听 12346）
moon example/guess_game_extension/main_extension.lua

# 终端 2：模拟游戏服连接并自动发 ready/guess
moon example/guess_game_extension/game_server_sim.lua
```

游戏服也可用其它语言按上述协议实现：连接 `127.0.0.1:12346`，发送上行行、解析下行行并按 `player_id(s)` 转发给各自客户端。

---

## Telnet 测试

先启动 Moon 扩展（见上），再开一个终端用 telnet 连上，**一行一条上行**，字段用 **空格或 Tab** 分隔（`player_id`、`cmd`、可选 `arg1`…）。下行会由 Moon 按行打回同一连接。

```bash
telnet 127.0.0.1 12346
```

**示例输入（每行回车，空格分隔即可）：**

| 输入行 | 说明 |
|--------|------|
| `alice ready` | 玩家 alice 加入匹配 |
| `bob ready`   | 玩家 bob 加入匹配，二人满员进房 |
| `alice guess 50` | alice 猜 50 |
| `bob guess 75`   | bob 猜 75 |
| … | 继续猜直到有人猜中 |

**示例输出（Moon 下行）：**

- 连上后：`player	*	msg	欢迎来到猜数字扩展...`
- 匹配成功：`player	alice	msg	匹配成功`、`player	bob	msg	匹配成功`
- 进房广播：`broadcast	alice,bob	msg	游戏开始, 欢迎 alice,bob 进入游戏房间...`
- 猜数字结果：`broadcast	alice,bob	msg	alice 猜测失败, 现在的区间是[1-50]` 等

协议里仍可用 Tab（如脚本 `printf 'alice\tready\n'`）；telnet 下用空格即可。格式与解析统一在 `protocol.lua`，bridge 只做分发与转发。
