# upb 方案 A 接入文档：多线程用法与两种考量

本文面向**方案 A**（upb 作为独立 Lua C 模块接入 Moon），重点说明：**“无全局状态、可重入”的设计含义**、**什么可以多线程共享**、**两种使用维度**（内存占用小 vs 灵活重载），并给出可直接参考的示例与接入步骤。

---

## 1. “无全局状态、可重入”的设计思路

### 1.1 无全局状态

- **含义**：upb 的 C 层**不**使用进程级静态变量（如 `static pb_State* global_state`）来保存 schema 或解析状态。
- **实现方式**：所有“状态”都通过**参数显式传入**：
  - **upb_DefPool**：类型定义池，存放从 .proto 加载的 message/enum 等定义；
  - **upb_Arena**：内存池，每次解析/序列化时的临时分配都从 Arena 要，不直接 malloc。
- **结果**：谁持有 DefPool、谁持有 Arena，完全由调用方（或 Lua 绑定）决定；**没有隐藏的跨调用共享**，因此不会出现“多线程改同一份全局 state”的竞态。

### 1.2 可重入

- **含义**：同一份 C 代码在多个线程里同时执行时，**不依赖静态变量**，因此每个线程只要传入**自己的** DefPool/Arena，就不会互相干扰。
- **实现方式**：所有会分配内存或查表的 API 都显式带上 `upb_DefPool*` 和/或 `upb_Arena*`；没有“从某个全局指针读 state”的分支。
- **结果**：多线程下只要遵守“每线程用自己的 Arena、按需共享只读 DefPool”（见下），就是安全的。

### 1.3 什么可以多线程共享、什么不可以

| 对象 | 是否可多线程共享 | 说明 |
|------|------------------|------|
| **upb_DefPool**（只读使用） | ✅ 可以 | 加载完 schema 后不再调用 `AddFile` 等写操作，仅做类型查找（如按名取 MessageDef）。多线程只读同一 DefPool 是安全的，且**一份 DefPool 多线程共用 = 加载数据占用内存小**。 |
| **upb_DefPool**（正在写入） | ❌ 不可以 | 若某线程仍在 `AddFile` 或修改 DefPool，其他线程不得同时读/写该 DefPool，需外部加锁或单线程初始化。 |
| **upb_Arena** | ❌ 不可以 | Arena 是“每线程/每次请求”的分配器，upb 文档明确为 **thread-compatible, not thread-safe**。多线程必须各用各的 Arena，或对同一 Arena 做外部加锁（一般不推荐）。 |
| **upb_Message 等消息实例** | ❌ 不跨线程共享写 | 消息挂在某个 Arena 上；该 Arena 归属某线程。若要把消息传到另一线程，应序列化成字节再传，在另一线程用本线程 Arena 反序列化。 |

**小结**：  
- **可以多线程共享的**：**只读的 DefPool**（schema 加载一次，多线程只做 encode/decode 时查类型）。  
- **不能多线程共享的**：Arena、以及“正在被修改”的 DefPool。

---

## 2. 两种使用维度

### 维度 1：加载数据占用内存小

- **目标**：全进程（或每 worker）只保留**一份** schema 数据，避免每个服务各加载一份导致内存翻倍。
- **做法**：
  - **方式 A-1**：集中 **proto 服务**（推荐）：一个专门的服务在 init 时加载一次 schema，其他服务通过 `moon.call` 请求 encode/decode；schema 只在该服务所在 Lua 状态里占一份内存。与是否用 upb 无关，当前 pb 也可用同一模式。
  - **方式 A-2**：若 upb 的 Lua 绑定支持“从外部传入 DefPool”：可由一个服务（或 bootstrap）创建 DefPool 并加载 schema，再通过**只读方式**把该 DefPool 传给其他服务使用（具体取决于绑定是否暴露 DefPool 句柄）。这样 C 层只有一份 DefPool，多线程只读共享。
- **注意**：多数 upb Lua 绑定默认“每 L 一个 DefPool”，不暴露 DefPool 句柄；此时**内存最优**仍靠**集中 proto 服务**（方式 A-1），而不是 C 层共享 DefPool。

### 维度 2：灵活重新加载

- **目标**：某个服务希望在不影响其他服务的前提下，**重新加载**或**热更** proto（例如灰度新版本 schema）。
- **做法**：该服务**自己持有一份 DefPool**（即每 L 一份，不与其他服务共享）。需要重载时，在本服务内新建 DefPool、重新 load 新 schema，然后只在本服务内用新 DefPool 做 encode/decode；其他服务仍用各自旧 schema，互不影响。
- **代价**：每个服务一份 DefPool，内存占用比“集中 proto 服务”略高；换来自主重载的灵活性。

### 对照表

| 维度 | 目标 | 推荐做法 | 共享方式 |
|------|------|----------|----------|
| 加载数据占用内存小 | 少占内存 | 集中 proto 服务；或（若绑定支持）只读共享一个 DefPool | 不共享 DefPool（各服务 call 同一 proto 服务）；或 C 层只读共享 DefPool |
| 灵活重新加载 | 某服务可独立热更 schema | 每服务一个 DefPool，需要时在本 L 内重建 DefPool 并 reload | 不共享；每 L 独立 DefPool |

---

## 3. 方案 A 接入步骤（简要）

1. **获取 upb + Lua 绑定源码**  
   从 [protocolbuffers/protobuf](https://github.com/protocolbuffers/protobuf) 取 upb 及 `lua/` 下绑定代码，放入 `third/upb/`（或 `third/protobuf/upb`），保持目录与 include 关系。

2. **加入构建**  
   在 `premake5.lua` 中增加：
   ```lua
   add_lua_module("./third/upb", "upb", { ... })
   ```
   根据 upb 实际文件列表与依赖配置 `files`、`includedirs`、`defines`，产出 `upb.so`。

3. **验证**  
   - 单脚本：`require "upb"`，加载一份 .proto，做一次 encode/decode。  
   - 多 worker：多个服务各自 `require "upb"` 并各自 load schema，确认无崩溃、结果正确。

4. **（可选）封装**  
   若希望 API 与现有 `pb` 接近，可在 Lua 层写薄封装（如 `load`/`loadfile`、`encode(type, table)`、`decode(type, bytes)`），内部调 upb 的 Lua API。

---

## 4. 示例（按两种维度）

以下示例为**伪代码风格**，假设 upb 的 Lua 绑定提供类似 `upb.load_proto`、`upb.encode`、`upb.decode` 的接口；实际 API 以你使用的绑定为准（可能是 `defpool:AddFile`、`encode(msg_def, tbl, arena)` 等），只需把“每 L 一份 DefPool”和“Arena 每请求/每线程”的规则套进去即可。

### 4.1 维度一：内存占用小——集中 proto 服务（与是否 upb 无关）

proto 服务（只加载一份 schema，对外提供 encode/decode）：

```lua
-- 服务：proto（unique，可固定 threadid 或单例）
local moon = require "moon"
local upb = require "upb"  -- 或 require "pb"

local function init()
    -- 只加载一次
    upb.load_proto_file("path/to/all.proto")  -- 或 upb.defpool:AddFile(...)
    return true
end

moon.dispatch("lua", function(sender, session, cmd, type_name, ...)
    local args = { ... }
    if cmd == "encode" then
        local ok, bytes = pcall(upb.encode, type_name, args[1])
        moon.response("lua", sender, session, ok and bytes or nil, ok and nil or tostring(args[1]))
    elseif cmd == "decode" then
        local ok, tbl = pcall(upb.decode, type_name, args[1])
        moon.response("lua", sender, session, ok and tbl or nil, ok and nil or tostring(args[1]))
    end
end)
```

业务服务（不加载 schema，只发请求）：

```lua
local moon = require "moon"
local proto_id = moon.queryservice("proto")

local function encode(type_name, tbl)
    return moon.call("lua", proto_id, "encode", type_name, tbl)
end

local function decode(type_name, bytes)
    return moon.call("lua", proto_id, "decode", type_name, bytes)
end

-- 使用
local bytes = encode("Person", { name = "alice", age = 18 })
local data = decode("Person", bytes)
```

这样**全进程（或每 worker 一个 proto 服务时）只加载一份 schema**，内存占用小；多线程安全由 Moon 的“每服务一个 L、消息单线程投递”保证。

### 4.2 维度二：灵活重新加载——每服务一份 DefPool

服务在 init 时加载自己的 schema；需要热更时在本服务内重新加载，不影响其他服务。

```lua
local moon = require "moon"
local upb = require "upb"

-- 当前使用的 schema 版本（或 DefPool 封装）
local current_loader = nil

local function load_schema(proto_path)
    -- 每服务自己的 DefPool；重新加载会替换当前使用的 schema
    current_loader = upb.new_defpool()  -- 伪 API：新建 DefPool
    current_loader:add_file(proto_path) -- 或 load_proto_file 绑定到该 DefPool
    return true
end

local function reload_schema(proto_path)
    -- 灵活重载：仅本服务生效
    load_schema(proto_path)
end

local function init()
    load_schema("path/to/my.proto")
    return true
end

-- 请求处理：用当前 DefPool 做 encode/decode（每请求可用新 Arena，由绑定或 C 层管理）
local function on_message(type_name, data, is_encode)
    if is_encode then
        return upb.encode(current_loader, type_name, data)  -- 绑定可能接受 defpool + type_name + table
    else
        return upb.decode(current_loader, type_name, data)
    end
end
```

热更时只需在该服务内调用 `reload_schema("path/to/new.proto")`，其他服务不受影响；代价是该服务独占一份 DefPool 内存。

### 4.3 “shared_defpool”能在多个 lua_State 之间共享吗？

**结论先说：Lua 里的 `local shared_defpool = upb.new_defpool()` 这个「变量」本身不能直接在多个 lua_State 之间共享；只有在 C 层把「同一个 DefPool」暴露成多个 L 都能用的句柄时，才算跨 L 共享。**

#### 为什么 Lua 变量不能跨 lua_State 共享？

- 每个 **lua_State** 有自己独立的栈、registry、全局表。在**某个 L 里**的 `local shared_defpool` 只是这个 L 的一个局部值（例如 userdata），**别的 L 根本拿不到这个变量**。
- 跨服务 / 跨 worker 时，数据通常通过 **moon 消息**传；消息里可以带字符串、数字、序列化后的表等，**不能**把“当前 L 的 userdata 指针”直接塞进消息让另一个 L 用（userdata 是进程内某 L 的地址，另一个 L 里没有对应对象，反序列化也没法还原成“同一个 C 对象”）。
- 所以：**单靠 Lua 的 `shared_defpool` 变量，无法让“多个 lua_State 共用同一个 DefPool”。**

#### 怎样才算在多个 lua_State 之间“共享”同一个 DefPool？

必须满足：

1. **DefPool 在 C 层只存在一份**（例如 C 里用 static 或全局指针保存，或存在某处 keyed by id）。
2. **每个 lua_State 拿到的是一份“句柄”**（例如 lightuserdata、或整数 id），而不是各自新建一个 DefPool。
3. **每个 L 在调用 encode/decode 时把这个句柄传给 C**；C 根据句柄找到**同一份** DefPool 来查类型、编解码。

也就是说：**共享的是 C 层的 DefPool 对象；Lua 侧只是多个 L 各自持有一个“指向同一 DefPool”的句柄。** 这需要 upb 的 **Lua 绑定**提供类似能力，例如：

- “在 C 里注册一个 DefPool，返回 handle（id 或 lightuserdata），其他 L 用 handle 来 encode/decode”；或  
- “绑定内部维护一个全局 DefPool，所有 L 的 encode/decode 都用它”（等价于单例 DefPool）。

**多数 upb Lua 绑定并没有做“跨 L 传 DefPool 句柄”**，而是每个 L 自己 `new_defpool()`，DefPool 存在该 L 的 registry 里，所以**默认就是“每 lua_State 一份 DefPool”，不能跨 L 共享同一对象。**  

若绑定不支持跨 L 句柄，**实践中要“少占内存、多 L 共用一份 schema”就只能用 4.1 的集中 proto 服务**：一个服务持有一份 DefPool，其他服务不拿 DefPool，只通过消息找它做 encode/decode。

#### 多线程下的“只读共享 DefPool”概念示例（若绑定支持 C 层句柄）

若绑定**支持**“在 C 层存一份 DefPool、多 L 通过句柄使用”，才可能写出类似下面的逻辑（伪代码）：

```lua
-- 在某个“主”服务或 bootstrap 中（仅此服务执行一次）
local defpool_handle = upb.new_defpool()  -- 绑定在 C 层保存，返回 handle
defpool_handle:add_file("path/to/common.proto")
-- 通过某种方式把 defpool_handle 传给其他服务（例如绑定支持 by id，或进程内约定“默认用全局 DefPool”）

-- 其他服务（别的 lua_State）只做 encode/decode，传入 handle
local function encode(type_name, tbl)
    return upb.encode(defpool_handle, type_name, tbl)  -- 同一 C DefPool，只读
end
```

- **可多线程共享的**：是 **C 层的那一份 DefPool**（只读使用）；每个 L 的 `defpool_handle` 只是指向它的句柄。
- **不可共享的**：每个线程/每次请求仍应用**自己的 Arena**（由绑定在 encode/decode 内部按请求或按线程创建）。

若绑定**不**支持这种句柄（大多数情况），就**不要**写“多个 lua_State 共享同一个 `shared_defpool` 变量”，而应使用 **4.1 的集中 proto 服务** 达到“加载数据占用内存小”的效果。

---

## 5. 小结

| 问题 | 结论 |
|------|------|
| **“无全局状态、可重入”是什么** | 所有状态（DefPool、Arena）显式传入，无静态全局变量；多线程各传各的或只读共享 DefPool，即可安全使用。 |
| **什么可以多线程共享** | **只读的 DefPool**（加载完后不再修改）；Arena 与“正在写入的 DefPool”不可并发共享。 |
| **内存占用小** | 集中 proto 服务（推荐）；或若绑定支持，只读共享一个 DefPool。 |
| **灵活重新加载** | 每服务一个 DefPool，需要时在本服务内重新 load，不影响其他服务。 |

按上述思路，在方案 A 下接入 upb 后，多线程侧只需遵守：**Arena 每线程/每请求；DefPool 要么每 L 一份，要么只读共享一份**；结合 Moon 的“每服务一个 lua_State”，即可安全且高效地使用 upb。
