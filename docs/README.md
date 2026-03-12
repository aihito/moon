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
| [socket_try_open.md](socket_try_open.md) | `socket_server::try_open` 的作用，以及为何其中的 acceptor 不会加入 `acceptors_` |
| [tcp_server_listen_to_callback_flow.md](tcp_server_listen_to_callback_flow.md) | TCP 服务从 `listen` 到 `socket.on("accept"\|"message"\|"close")` 回调的完整流程（Lua 与 C++ 调用链） |
| [socket_close_and_lua_callback.md](socket_close_and_lua_callback.md) | 对端关闭时 C++ 行为，以及为何只有“出错”路径会触发 Lua close 回调、本端主动 close 不触发 |

---

## 其他

更多内容可参考项目根目录 [README.md](../README.md) 与 [Wiki](https://github.com/sniper00/moon/wiki)。
