# upb Lua 绑定与 Moon 引入方案

本文说明：**Google upb（micro protobuf）的 Lua 绑定是否线程安全**，以及**如何在 Moon 中引入 upb**（方案与步骤）。

---

## 1. upb 是否线程安全？

### 1.1 C 库层面：无全局状态、可重入

upb 的设计文档与代码表明：

- **无全局状态**：不在 C 里维护进程级静态变量来存放 schema 或解析状态。
- **可重入**：接口通过显式传入 `upb_DefPool`（类型定义池）、`upb_Arena`（内存池）等上下文工作，不依赖隐式全局。
- **内存模型**：分配统一走 `upb_Arena`，由调用方创建与销毁，便于“每线程/每 L 一个 Arena”。

因此：**upb 的 C 库本身是“可在线程安全方式下使用”的**——只要每个线程（或每个 lua_State）使用自己的 DefPool/Arena，或对共享的 DefPool 自己做同步，就不会有数据竞争。与当前 `third/pb` 里依赖 `global_state` + `pb.share_state()` 的设计不同。

### 1.2 Lua 绑定层面：通常“每 L 一份状态”

官方/上游的 upb Lua 绑定（如 protocolbuffers/protobuf 或 grpc 中的 `lua/upb.c`）：

- 一般把 **DefPool / 类型信息** 存放在**当前 `lua_State` 的 registry**（或等价的 per-L 存储）里，而不是 C 的静态全局变量。
- 没有类似 `pb.share_state()` 的“跨 L 共享同一份 state”的机制；若要做共享，需要由 Lua 侧显式传递 DefPool/消息，而不是隐式全局。

因此：**在“每个服务一个 lua_State、且不显式共享 state”的用法下（如 Moon），upb 的 Lua 绑定可以视为与当前模型兼容且线程安全**。多 worker 时，每个 L 独立持有一份 DefPool，互不干扰。

### 1.3 与当前 pb 的对比

| 项目 | 当前 third/pb (lua-protobuf) | upb + Lua 绑定 |
|------|------------------------------|----------------|
| C 层全局状态 | 有（`global_state`），`share_state()` 会共享 | 无；显式 DefPool/Arena |
| 多线程下 share 行为 | 无锁共享 → 非线程安全 | 无“隐式共享”，需显式传 state |
| 每 L 一份 state | 默认是；share_state 后打破 | 默认即每 L 一份（或显式传） |
| 多 worker 安全 | 仅在不调 share_state 时安全 | 在“每 L 一份 / 不共享”用法下安全 |

**结论**：upb 的 C 库与常见 Lua 绑定在“每 L 一份 DefPool、不跨线程共享”的前提下，可以安全地在多线程（多 worker）下使用；当前 pb 则在多 worker 下不能使用 `share_state()`。

---

## 2. 如何引入 upb：总体思路

- **目标**：在 Moon 中提供基于 upb 的 protobuf 能力（可选替代或补充现有 `pb`），并保持多 worker 下的安全用法。
- **原则**：不修改 upb 的 C 源码设计，仅做集成与可选的 Lua API 封装；若需“全进程只加载一份 schema”，仍推荐用**集中 proto 服务**（见 `protobuf_usage_multithread.md`），而不是在 C 层做跨 L 共享。

---

## 3. 引入方案（三选一或组合）

### 方案 A：upb 作为独立 Lua C 模块（推荐起步）

- **详细接入文档**：多线程用法、两种考量（内存小 / 灵活重载）、示例与步骤见 **[upb_plan_a_integration.md](upb_plan_a_integration.md)**。
- **做法**：
  1. 从 [protocolbuffers/protobuf](https://github.com/protocolbuffers/protobuf)（或 [protocolbuffers/upb](https://github.com/protocolbuffers/upb)，注意 upb 仓库已归档，新代码可能在主 protobuf 仓库）获取 **upb 的 C 源码** 以及 **Lua 绑定**（如 `lua/upb.c`、`lua/def.c` 等，以实际仓库结构为准）。
  2. 将 upb 核心与 Lua 绑定放入 Moon 的 `third/` 下，例如 `third/upb/`（或 `third/protobuf/upb`），保持 upb 原有目录结构便于后续升级。
  3. 在 **premake5.lua** 中新增一个 Lua C 模块工程（可参考现有 `third/pb` 的 `add_lua_module("./third/pb", "pb")`），编译 upb 的 C 文件 + Lua 绑定，产出 `upb.so`（或当前平台等价物）。
  4. 在 Lua 中通过 `require "upb"` 使用；API 可能与现有 `pb` 不同，需在文档或封装层说明 encode/decode/load 的对应关系。

- **优点**：与现有 `pb` 并存，不破坏已有逻辑；可逐步迁移或仅在新服务中用 upb。  
- **缺点**：需维护两套 C 依赖；Lua API 可能与 `pb` 不一致，业务需适配或做薄封装。

### 方案 B：Lua 层封装为与 pb 兼容的 API

- **做法**：在引入 upb 的 C 模块后，再写一层 Lua 封装（如 `lualib/moon/upb_pb.lua`），对外提供与当前 `pb` 相同或相近的接口（如 `load`/`loadfile`、`encode(type_name, table)`、`decode(type_name, bytes)`），内部调用 upb 的 Lua API。这样现有业务只需把 `require "pb"` 改为 `require "moon.upb_pb"`（或通过配置切换），改动最小。
- **优点**：业务侧改动小；可配置“用 pb 还是 upb”。  
- **缺点**：需维护封装层；upb 的 API 若与 pb 差异大，封装可能较薄或需做类型/选项映射。

### 方案 C：替换 third/pb（长期可选）

- **做法**：在方案 A/B 稳定、且项目决定全面迁移后，将现有依赖 `pb` 的 Lua 代码改为使用 upb（或 upb 的兼容封装），并从 premake 与源码树中移除或降级对 `third/pb` 的依赖。
- **优点**：最终只维护一套 protobuf 实现；upb 无全局 state，多 worker + 未来若做“共享 schema”更易控制。  
- **缺点**：迁移成本与测试量较大；需确认 upb Lua 绑定对当前使用的 proto 特性（如反射、自定义选项等）支持是否完整。

---

## 4. 实施步骤建议（以方案 A 为主）

1. **获取源码**
   - 从 protocolbuffers/protobuf 仓库查找 upb 及 Lua 绑定（例如 `upb/`、`lua/upb.c` 等），或从 grpc 等依赖 upb 的仓库获取可用的 upb + Lua 绑定快照。
   - 将所需 C 文件放入 `third/upb/`（或 `third/protobuf/`），保持原有相对路径与头文件包含关系。

2. **集成构建**
   - 在 `premake5.lua` 中增加类似：
     - `add_lua_module("./third/upb", "upb", { ... })`
   - 根据 upb 实际需要的 include 与依赖调整 `includedirs`、`defines`；若有子目录，按现有 `add_lua_module` 的约定列出所有要参与编译的 C 文件。
   - 执行 `premake5 build`，确认生成 `upb.so`（或等价）且可被 `require "upb"` 加载。

3. **Lua 侧验证**
   - 写一个最小示例：在某个脚本中 `require "upb"`，按 upb 文档加载一份简单 .proto 并做一次 encode/decode，确认与现有 `pb` 行为可对比（同一份 .proto、同一份数据）。
   - 在多 worker 场景下起多个服务，每个服务只使用自己的 upb 状态（不跨 L 共享），确认无崩溃与错误结果。

4. **（可选）兼容封装与文档**
   - 若采用方案 B，在 `lualib/` 下实现 `upb_pb` 或类似模块，在文档中说明与 `pb` 的 API 对应关系及“全进程只加载一份”时仍推荐使用集中 proto 服务。
   - 在 `docs/protobuf_usage_multithread.md` 或本文中补充“若使用 upb”的注意点（每 L 一份 state、不共享 DefPool 等）。

5. **（可选）迁移与替换**
   - 若后续采用方案 C，在 CI 与测试中切到 upb，再移除对 `third/pb` 的依赖。

---

## 5. 注意事项

- **upb 仓库状态**：protocolbuffers/upb 已在 2025 年 12 月归档，新开发可能集中在主 protobuf 仓库；取源码时以官方 protocolbuffers 仓库为准。
- **Lua 版本**：确认 upb 的 Lua 绑定支持的 Lua 版本与 Moon 所用一致（如 5.3/5.4）；若有 `luaL_checkinteger` 等兼容性问题，需在绑定层或 Moon 的补丁中处理。
- **64 位整数**：upb 与 Lua 的 64 位整型语义（精度、cdata 等）需与现有 `pb` 行为对齐，避免业务侧出现数值不一致。
- **全进程一份 schema**：即使用 upb，仍建议通过**集中 proto 服务**（见 `protobuf_usage_multithread.md` 4.4）实现“只加载一份”，而不是在 C 层做跨 L/跨线程共享 DefPool，以保持边界清晰与可维护性。

---

## 6. 相关文档与代码

| 内容 | 路径或链接 |
|------|------------|
| upb 设计（无全局状态、Arena） | [upb Design](https://chromium.googlesource.com/chromium/src/+/master/third_party/protobuf/docs/upb/design.md)、[upb Wiki](https://github.com/protocolbuffers/upb/wiki) |
| upb / Lua 绑定源码 | protocolbuffers/protobuf 仓库中 upb 及 lua 目录 |
| Moon 当前 pb 集成 | `premake5.lua`（add_lua_module third/pb）、`third/pb/` |
| 多线程与“只加载一份”用法 | `docs/protobuf_usage_multithread.md` |

以上即为 upb 的线程安全性说明，以及在 Moon 中引入 upb 的可行方案与实施步骤。
