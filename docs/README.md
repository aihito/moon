# Moon 文档

本目录存放与 Moon 框架相关的说明与流程文档（中文）。

---

## API 参考

| 文档 | 说明 |
|------|------|
| [moon_decode_format_reference.md](moon_decode_format_reference.md) | **moon.decode(msg, format)** 解析格式完整参考（S/R/E/Z/N/B/L/C 等） |

## 网络与 Socket

| 文档 | 说明 |
|------|------|
| [network_architecture.md](network_architecture.md) | **网络管理架构总览**：进程/线程模型、socket_server 与 fd 归属、listen/accept/connect 流程、连接类型、消息到 Lua 的投递 |
| [socket_try_open.md](socket_try_open.md) | `socket_server::try_open` 的作用，以及为何其中的 acceptor 不会加入 `acceptors_` |
| [tcp_server_listen_to_callback_flow.md](tcp_server_listen_to_callback_flow.md) | TCP 服务从 `listen` 到 `socket.on("accept"\|"message"\|"close")` 回调的完整流程（Lua 与 C++ 调用链） |
| [socket_close_and_lua_callback.md](socket_close_and_lua_callback.md) | 对端关闭时 C++ 行为，以及为何只有“出错”路径会触发 Lua close 回调、本端主动 close 不触发 |

---

## 协议与序列化

| 文档 | 说明 |
|------|------|
| [pb_and_protoc_relationship.md](pb_and_protoc_relationship.md) | **pb** 与 **protoc** 的分工与关系；protoc 中“加载”与 pb 的衔接 |
| [protobuf_usage_multithread.md](protobuf_usage_multithread.md) | Protobuf（pb + protoc）使用方式，以及多线程下安全、高效实践 |
| [upb_lua_integration.md](upb_lua_integration.md) | Google upb 的 Lua 绑定是否线程安全，以及在 Moon 中引入 upb 的方案与步骤 |
| [upb_plan_a_integration.md](upb_plan_a_integration.md) | **方案 A 接入文档**：无全局状态/可重入的含义、什么可多线程共享、内存小 vs 灵活重载、示例与步骤 |

## 业务与集成

| 文档 | 说明 |
|------|------|
| [game_server_extension_integration.md](game_server_extension_integration.md) | **游戏服 + Moon 扩展**：玩家已在游戏服登录，Moon 作扩展（匹配/房间/战斗），消息由游戏服转发；与 guess_game 的对比与接入方案 |

## 其他

更多内容可参考项目根目录 [README.md](../README.md) 与 [Wiki](https://github.com/sniper00/moon/wiki)。
