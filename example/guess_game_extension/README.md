# Guess Game Extension (游戏服连 Moon)

与 [guess_game](../guess_game/) 相同的猜数字玩法，但**客户端不直连 Moon**，而是由**游戏服**与 Moon 保持**一条 TCP 连接**，按约定协议转发上下行。对应文档：`docs/game_server_extension_integration.md`。

## 架构（无 user_proxy）

- **bridge**：持有与游戏服的 fd，维护 `player_id → room_id`，上行解包后转 center/room，下行收 `forward`/`forward_broadcast` 写 fd。
- **center**：匹配与房间管理，玩家为 `{ player_id, name }`，发给玩家一律经 bridge。
- **room**：房间内猜数字逻辑，广播/单发都经 bridge。

## 协议（行文本，`\n` 结尾）

- **上行（游戏服 → Moon）**：`player_id\tcmd\targ1\targ2...`
  - `ready`：加入匹配。
  - `guess\t<数字>`：猜数字（仅在房间内有效）。
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
