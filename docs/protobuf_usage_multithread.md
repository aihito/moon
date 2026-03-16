# Moon 下 Protobuf 使用方式与多线程安全、高效实践

本文结合 `example/example_pb.lua` 分析项目中 protobuf（`pb` + `protoc`）的用法，并说明在多线程（多 worker）场景下如何**安全、高效**地使用。

---

## 1. 示例中的使用方式概览

`example/example_pb.lua` 的流程可以概括为：

1. **加载 schema**：用 `protoc:load(...)` 把 `.proto` 文本编译成二进制并载入到当前 Lua 状态的 pb 中。
2. **编码**：`pb.encode("Person", data)` 把 Lua 表编码成二进制字符串。
3. **解码**：`pb.decode("Person", bytes)` 把二进制解码回 Lua 表。

```lua
-- 1. 加载 schema（每个使用 pb 的脚本/服务都要做）
assert(protoc:load [[
syntax = "proto3";
message Person { ... }
]])

-- 2. 编码 / 解码
local bytes = assert(pb.encode("Person", data))
local data2 = assert(pb.decode("Person", bytes))
```

也就是说：**谁要用 pb，谁就要先在自己的 Lua 环境里 load 一遍 schema**。下面说明为什么是这样，以及多线程下如何做更安全、更省成本。

---

## 2. Moon 的线程与 Lua 模型（和 pb 的关系）

- Moon 有**多个 worker 线程**，每个 worker 有一个 `io_context`，上面跑多个 **service**。
- 每个 **lua_service** 拥有**自己独立的** `lua_State`（见 `lua_service.h` 中的 `std::unique_ptr<lua_State, ...> lua_`）。
- 任意时刻，一个 `lua_State` 只会在**一个 worker 线程**里被调度，**不会**被多线程同时使用。

因此：

- **每个服务**里 `require "pb"` / `require "protoc"` 得到的是**该服务自己的**模块实例，数据在**该** `lua_State` 的 registry 里。
- **pb 的 C 实现**（`third/pb/pb.c`）会为每个 `lua_State` 在 registry 里维护一个 `lpb_State`（含 `pb_State local`），**默认**所有 load/encode/decode 都只操作这份“每线程、每服务”的状态。
- 只有在显式调用 **`pb.share_state()`** 时，会把当前 Lua 状态的 `pb_State` 设成 C 里的 **`global_state`**，被其他 Lua 状态复用，从而**跨线程共享**，且 C 层没有加锁，**不是线程安全的**。

结论：  
- **不调用 `pb.share_state()` 时**：每个服务在自己的 `lua_State` 里 load/encode/decode，**天然按服务、按线程隔离，是安全的**。  
- **若在多 worker 环境下使用 `pb.share_state()`**：会破坏这种隔离，存在数据竞争，**不应使用**。

---

## 3. 安全使用要点（多线程 / 多服务）

### 3.1 不要使用 `pb.share_state()`

- `pb.share_state()` 会设置 C 里的 `global_state`，让多个 `lua_State` 共用同一份类型信息。
- 该全局状态**没有锁**，多 worker 下会存在竞态。
- **建议**：在 Moon 中**不要调用** `pb.share_state()`，让每个服务用自己 registry 里的 pb 状态即可。

### 3.2 每个服务自己 load schema

- 使用 pb 的**每个服务**在**自己的** `lua_State` 里做一次 schema 加载（`protoc:load(...)` 或 `pb.load` / `pb.loadfile`）。
- 这样每个服务都有一份独立的类型信息，无跨线程共享，**安全**。
- 若希望“逻辑上共用同一份 .proto”，可以：
  - 多个服务读**同一份 .proto 文件**或同一份预编译二进制，各自 load 一次；或
  - 由一个“协议服务”统一 load，其他服务通过**发消息把数据交给该服务 encode/decode**（见下文“高效”部分）。

### 3.3 不在服务间共享“已编码的 buffer”以外的可变状态

- 跨服务只传递**编码后的字符串**（或只读的二进制），在接收方服务里再 `pb.decode`。
- 不要跨服务共享“同一个 pb state 对象”或依赖 `share_state` 的跨 L 用法。

### 3.4 不同服务加载不同 proto、同名类型不同内容是否有影响？

**结论先说不影响、再说不该怎么做：**

- **不同服务加载不同 proto 文件**  
  每个服务有**自己独立的** `lua_State` 和 pb 状态（类型表、schema 都在各自 registry 里）。  
  服务 A 加载 `game.proto`、服务 B 加载 `login.proto`，或 A 和 B 各加载一份“同名但内容不同”的 proto，**彼此完全隔离**，**不会互相影响**。

- **同一服务内：同名类型（如都叫 Person）但内容不一样**  
  若在**同一个服务**里多次 load，且两次加载的 schema 里都定义了**同名消息**（例如都叫 `Person`）但字段不同：
  - pb 的类型表是按“类型名”存的，后一次 `pb.load` 会覆盖或与先前的同名类型冲突（视实现而定）。
  - 结果是：该服务里对 `Person` 的 encode/decode 只认“最后一次加载”的定义，前面那份会失效或行为未定义，**容易出错**。
  - **建议**：同一服务内不要加载两份“定义同名类型且结构不同”的 schema；若必须用多份 proto，保证类型名不重复（例如用 package 或不同消息名）。

**简要对照：**

| 情况 | 是否互相影响 |
|------|----------------|
| 服务 A 加载 proto_a，服务 B 加载 proto_b（或同名文件不同内容） | **不影响**，各用各的 pb 状态。 |
| 同一服务先 load 定义 `Person` 的 proto1，再 load 定义另一个 `Person` 的 proto2 | **有影响**，后者会覆盖/冲突，应避免。 |

---

## 4. 高效使用要点

### 4.1 Schema 只加载一次，不要每次请求都 load

- **在服务初始化阶段**（例如 `init` 或首次进入处理逻辑前）做一次 `protoc:load(...)` 或 `pb.load` / `pb.loadfile`。
- 之后该服务的所有请求只做 `pb.encode` / `pb.decode`，**不要**在每条消息里再 load schema。

示例（在服务 init 里）：

```lua
-- 服务 init 时
local protoc = require "protoc"
local function init()
    local p = protoc.new()
    assert(p:loadfile("path/to/your.proto"))  -- 或 p:load([[ ... ]])
    -- 之后该服务只 encode/decode，不再 load
end
```

### 4.2 优先使用预编译 .pb 或 loadfile，减少运行时解析

- **`protoc:load(string)`**：在运行时把 .proto **文本**编译成 FileDescriptorSet 再 `pb.load`，每次 load 都会做词法/语法解析，开销相对大。
- **`pb.loadfile("xx.pb")`**：直接加载**已编译好的** .pb 二进制（可由 `protoc --descriptor_set_out=xx.pb` 生成），避免运行时解析 .proto 文本，**更快、更省 CPU**。
- 建议：构建时用 `protoc` 生成 `.pb`，部署时用 `pb.loadfile` 加载；若必须内嵌 .proto 文本，只在服务 init 时 `protoc:load` 一次。

### 4.3 多服务共用同一份协议时的两种做法

若多个服务都要用同一套 .proto：

- **方式 A（简单、推荐）**：每个服务在 **init 时各 load 一次**（同一份 .proto 或同一份 .pb 文件）。  
  - 优点：实现简单、无跨线程共享、安全。  
  - 代价：每个进程内多一份类型信息（内存换安全与简单）。

- **方式 B（集中编解码）**：在一个**专门的服务**（例如每 worker 一个 “proto” 服务）里 load 一次 schema，其他服务把“Lua 表”或“二进制”通过 **moon 消息**发给该服务，由该服务统一 `pb.encode` / `pb.decode` 再返回结果。  
  - 优点：整个 worker 只 load 一次 schema，内存更省。  
  - 代价：多一次消息往返和序列化，延迟和复杂度更高；只在对内存或 schema 数量非常敏感时考虑。

### 4.4 全进程共用一份 proto、程序只加载一份的最佳实践

若希望**全进程只加载一份** proto（或每 worker 只加载一份），推荐用**集中编解码的“proto 服务”**，避免每个业务服务各 load 一次。

#### 方案一：专用 proto 服务（推荐，多 worker 安全）

- **思路**：起一个（或每 worker 一个）**只做 pb 编解码**的服务，在它里面 **init 时 load 一次** schema；其他服务**不** require pb、不 load，需要编解码时通过 **moon.call** 把类型名 + 数据发给该服务，拿回结果。
- **“只加载一份”的两种粒度**：
  - **每 worker 一份**：每个 worker 里起一个 proto 服务（例如同名 unique 服务，或每个 worker 一个 threadid 固定的服务），该 worker 内所有服务都 call 它。这样进程内 load 次数 = worker 数，内存可控，且无跨线程共享。
  - **全进程一份**：整个进程只起**一个** proto 服务（例如固定放在 worker 0），所有 worker 上的服务都 call 它。这样真正只 load 一次，但该服务会成为热点，适合编解码请求量不大或可接受的场景。
- **优点**：schema 只在一处加载，内存省；多 worker 下无共享状态，安全。  
- **代价**：每次编解码多一次消息往返，延迟增加；若全进程一个 proto 服务，需注意该服务的 CPU 与队列深度。

#### 方案二：单 worker 时用 pb.share_state()（仅限单 worker）

- **前提**：确认进程**只有一个 worker**（或只有跑 pb 的那一个线程会做 encode/decode）。
- **做法**：由**第一个**加载 proto 的服务（例如 bootstrap 或固定 init 顺序的第一个服务）在 load 完成后调用 **pb.share_state()**，之后同进程内**其他服务**首次 `require "pb"` 时会复用这份全局 state，无需再 load。
- **优点**：真正只加载一份，且无额外消息 hop，性能最好。  
- **注意**：多 worker 时 `pb.share_state()` 会设 C 层 `global_state`，多线程并发访问无锁，**有数据竞争**，因此**仅建议在单 worker 部署时使用**。

#### proto 服务示例（方案一）

下面是一个“每 worker 一个 proto 服务”的简化示例：该服务 init 时 load 一次，对外用 `moon.call("lua", proto_svc_id, "encode", type_name, table)` / `("decode", type_name, bytes)` 即可。

```lua
-- 以 unique 服务为例，名字如 "proto"
local moon = require "moon"
local pb = require "pb"
local protoc = require "protoc"

local function init()
    local p = protoc.new()
    assert(p:loadfile("proto/your.proto"))  -- 或 pb.loadfile("proto/your.pb")，只执行一次
    return true
end

moon.dispatch("lua", function(sender, session, cmd, ...)
    local args = { ... }
    if cmd == "encode" then
        local type_name, data = args[1], args[2]
        local ok, bytes = pcall(pb.encode, type_name, data)
        moon.response("lua", sender, session, ok and bytes or nil, not ok and tostring(data) or nil)
    elseif cmd == "decode" then
        local type_name, bytes = args[1], args[2]
        local ok, data = pcall(pb.decode, type_name, bytes)
        moon.response("lua", sender, session, ok and data or nil, not ok and tostring(bytes) or nil)
    end
end)
```

业务侧调用示例（先 `moon.queryservice("proto")` 得到 id，再 call）：

```lua
local proto_id = moon.queryservice("proto")
local bytes = moon.call("lua", proto_id, "encode", "Person", { name = "alice", age = 18 })
local data = moon.call("lua", proto_id, "decode", "Person", bytes)
```

- 若希望**全进程只加载一份**：把 proto 服务只起在某个固定 worker（如 `threadid = 0`），且全进程仅起一个实例；其他服务统一 call 该 id 即可。
- 若希望**每 worker 一份、减少单点**：每个 worker 起一个 proto 服务（例如用不同 name，或同一 unique 名由框架按 worker 分布），业务服务 call 本 worker 的 proto 服务，这样 load 次数 = worker 数，无跨线程共享。

---

## 5. 推荐用法小结（多线程安全 + 高效）

| 项目 | 建议 |
|------|------|
| **线程安全** | 不使用 `pb.share_state()`（多 worker 时）；每个服务使用自己 `lua_State` 里的 pb 状态，或走集中 proto 服务。 |
| **Schema 加载** | 每个使用 pb 的服务在 **init 时** load 一次；或全进程/每 worker 只起一个 proto 服务，由它 load 一次（见 4.4）。 |
| **请求处理** | 只做 `pb.encode` / `pb.decode`，不在请求路径里 load。 |
| **格式** | 优先预编译 .pb + `pb.loadfile`；若用 .proto 文本，用 `protoc:loadfile` 或 `protoc:load` 在 init 时加载。 |
| **跨服务** | 只传编码后的二进制或只读数据；不在服务间共享 pb state。 |
| **全进程共用一份 proto** | 用专用 proto 服务集中 load 一次，业务侧 call 其 encode/decode（见 4.4）；单 worker 时可考虑 `pb.share_state()`。 |

---

## 6. 示例：服务内安全且高效的一段式写法

```lua
local moon = require "moon"
local pb = require "pb"
local protoc = require "protoc"

-- 服务启动时：编译并加载 schema，只执行一次
local function load_schema()
    local p = protoc.new()
    -- 方式1：从文件加载 .proto 文本（适合开发）
    assert(p:loadfile("proto/your.proto"))
    -- 方式2：若已有 .pb 二进制，可直接（在 C 层需用 pb.loadfile，此处用 protoc 示例）
    -- 实际项目中可统一用 pb.loadfile("proto/your.pb") 在 init 里调一次
end

local function init()
    load_schema()
    return true
end

-- 处理请求时：只 encode/decode，不再 load
local function on_message(type_name, data)
    local bytes = assert(pb.encode(type_name, data))
    -- ...
    local decoded = assert(pb.decode(type_name, bytes))
    return decoded
end
```

---

## 7. 相关代码与文档

| 内容 | 路径 |
|------|------|
| 示例 | `example/example_pb.lua` |
| protoc（.proto 编译） | `lualib/protoc.lua` |
| pb C 实现（load/encode/decode/state） | `third/pb/pb.c`（注意 `global_state` 与 `Lpb_share_state`） |
| 服务与 lua_State 一对一 | `src/moon/services/lua_service.h` |

遵循上述做法，即可在 Moon 的多线程、多服务环境下**安全且高效**地使用 protobuf。
