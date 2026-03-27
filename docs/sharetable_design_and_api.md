# ShareTable 机制：设计思路与接口梳理（`third/sharetable` + `service/sharetable.lua`）

本文基于：
- `third/sharetable/lua-sharetable.c`（Lua C 扩展：`sharetable.core`）
- `service/sharetable.lua`（Moon 服务：`sharetable`）

目标是解释 ShareTable 的整体设计：**把配置表变成可跨 Lua 状态共享的只读数据（shared table / matrix）**，并在需要时支持**热更新**与**引用计数回收旧版本**。

---

## 1. 设计总览（为什么要有 sharetable）

在 Moon 里每个 service 都有独立 `lua_State`，如果你用普通 `require` 加载配置表：
- 每个 `lua_State` 都会各自解析/构造一份 Lua table
- 造成 **重复内存**、**加载开销**、以及热更新时需要自己处理“如何替换旧 table 引用”

ShareTable 设计的核心是：
1. **把配置加载到一个独立的 Lua 状态（matrix state）里**，并把其中的 table/字符串/函数等标记为“共享对象”
2. 其它 `lua_State` 通过一个轻量句柄（指针）去 **clone** 出本地可读的镜像/引用（实际实现依赖 Lua VM 的共享/克隆支持）
3. `service/sharetable.lua` 作为“管理服务”维护：
   - 文件名 -> matrix（当前版本）
   - 指针 -> 引用计数（哪些 client 还在用）
   - 热更新时：加载新版本 matrix，旧版本延迟回收

---

## 2. C 扩展层：`sharetable.core`（`lua-sharetable.c`）

`luaopen_sharetable_core` 暴露了 4 个函数：

### 2.1 `core.matrix(source, ...) -> matrix_state_ud`

**作用**
- 创建一个新的 `lua_State`（称为 matrix state），在其中执行配置脚本，然后把返回的 table 递归标记为“可共享对象（shared）”。
- 最终返回一个 userdata（本文称 `matrix_state_ud`），其方法包括 `close/getptr/size`（由 metatable `BOXMATRIXSTATE` 提供）。

**参数**
- `source: string`
  - 若 `source` 以 `@` 开头：按文件加载（`luaL_loadfilex_`）
  - 否则：按字符串加载（`luaL_loadstring`）
- `...`：会被转发进 matrix state 作为脚本入参
  - 只允许：boolean/number/lightuserdata/“无 upvalue 的轻量 C function”

**返回**
- `matrix_state_ud`（userdata）
  - `matrix_state_ud:close()`：关闭该 matrix state（释放整个 Lua 状态）
  - `matrix_state_ud:getptr()`：取出 matrix 里“共享 table 的指针”（lightuserdata），用于跨服务传递引用句柄
  - `matrix_state_ud:size()`：matrix state 当前 Lua GC 统计的内存大小（字节）

**关键实现点**
- `mark_shared(L)`：对 table 做 DFS，允许的值类型：table/number/boolean/lightuserdata/string/function（且 Lua 函数必须无 upvalue）
- 遇到 string：`lua_sharestring`
- 遇到 Lua 函数（非 C function）：`makeshared(f)` + `lua_sharefunction`
- 禁止 metatable：`Can't share metatable`
- 在 `make_matrix` 前会 `lua_gc(L, LUA_GCSTOP, 0)`：因为 shared 标记会影响 GC 标记逻辑（注释说明）

---

### 2.2 `core.clone(ptr) -> table`

**作用**
- 把一个 matrix 里共享 table 的指针 `ptr`（lightuserdata）克隆到当前 `lua_State`，得到可读 table。

**参数**
- `ptr: lightuserdata`（一般来自 `matrix_state_ud:getptr()`，或 sharetable 服务 `query/queryall` 返回的 ptr）

**返回**
- `table`：当前 `lua_State` 中的 table

---

### 2.3 `core.is_sharedtable(x) -> boolean`

**作用**
- 判断一个值是否是“共享 table”（内部通过 `isshared(Table*)` 判断）。

**参数**
- `x: any`（只有 table 才可能为 true）

**返回**
- `boolean`

---

### 2.4 `core.stackvalues(co, out_table) -> integer n`

**作用**
- 把另一个 coroutine（thread）的栈值搬到 `out_table`（数组）里，用于热更新时扫描堆栈引用。

**参数**
- `co: thread`
- `out_table: table`（数组形式承载返回的 stack values）

**返回**
- `n: integer`（栈上值数量）

**备注**
- 该函数在 Lua 层热更新替换（`sharetable.update`）中用于遍历线程栈，找到并替换旧 table 引用。

---

## 3. 服务层：`service/sharetable.lua`

该文件有两种运行方式：

1. **作为 sharetable 服务实例运行**（`conf.name` 存在时）：提供 RPC
2. **作为客户端库 require 使用**：提供 `sharetable.loadfile/query/queryall/update/...`

下面按“服务端 RPC”和“客户端 API”分别说明。

---

### 3.1 服务端：RPC 接口（`moon.dispatch("lua", ...)`）

#### `loadfile(filename, ...) -> true`

**作用**
- 从文件加载配置，构建新的 matrix 版本，替换当前 `files[filename]`。

**实现要点**
- `core.matrix("@" .. filename, ...)` 产生 `matrix_state_ud`
- 若该文件已有旧 matrix，会 `close_matrix`（当引用计数为 0 才真正 close）

**返回**
- `true`（通过 `moon.response`）

#### `loadstring(filename, datasource, ...)`

**作用**
- 从字符串加载配置（常用于在线下发/测试），替换 `files[filename]`。

#### `query(filename) -> ptr_or_nil`

**作用**
- 返回某文件当前版本 matrix 的 `ptr`（lightuserdata），并建立引用计数（按 caller/service 维度）。

**返回**
- `ptr: lightuserdata` 或 `nil`

#### `queryall([filelist]) -> map`

**作用**
- 批量返回多个配置文件的 ptr，返回结构是 `name -> ptr`。

**返回**
- `table`：`{ ["xxx.lua"]=ptr, ["yyy.lua"]=ptr, ... }`（实现里会对 filename 做 stem/name 处理）

#### `clients() -> {service_id...}`

**作用**
- 返回当前引用 sharetable 的所有 client service id 列表。

#### `close()`

**作用**
- client 断开/析构时通知 sharetable 服务释放引用计数；当某 ptr 的引用计数降为 0 且它不是当前 files[filename] 的最新版本，会关闭旧 matrix 版本。

---

### 3.2 客户端：库接口（`local sharetable = require "service.sharetable"` 的用法）

#### `sharetable.loadfile(filename, ...)`
- 调用服务端 `loadfile`

#### `sharetable.loadstring(filename, source, ...)`
- 调用服务端 `loadstring`

#### `sharetable.query(filename) -> table_or_nil, err?`

**作用**
- 先 RPC `query` 拿到 `ptr`，再 `core.clone(ptr)` 得到 table。
- 同时把 table 记录到 `RECORD[filename]`，用于后续热更新替换。

#### `sharetable.queryall([filelist]) -> table`

**作用**
- 批量拿 ptr 并 clone，返回 `{ stem -> table }`

---

## 4. 热更新：`sharetable.update(...)`

`sharetable.update(name1, name2, ...)` 的核心思路：
1. 对每个 name：重新 `query(name)` 得到新 table（新版本）
2. 对比旧 table 与新 table，构造 `replace_map`（old_table -> new_table）
3. 递归扫描并替换引用：
   - registry
   - table 的 value/key
   - userdata uservalue
   - function upvalues
   - coroutine 栈与 local（通过 `core.stackvalues` + `debug.getlocal/setlocal`）
   - metatable

**实现里会跳过 `core.is_sharedtable(v)` 的对象**，避免对共享只读对象做无意义修改。

---

## 5. 约束与注意事项（从 C 实现直接推导）

1. **共享表不允许 metatable**
   - `lua-sharetable.c` 里对 `mark_shared` 直接禁止 metatable
2. **共享表只允许有限类型**
   - table/number/boolean/lightuserdata/string/无 upvalue 的函数
3. **Lua 函数必须没有 upvalue**
   - 有 upvalue 会报错 `Invalid function with upvalue`
4. **GC 行为与共享标记耦合**
   - `make_matrix` 会 `lua_gc(L, LUA_GCSTOP, 0)`；共享对象的 GC/生命周期必须由上层（matrix state + close）管理

---

## 6. 你在工程里如何使用（典型流程）

1. 启动 sharetable 服务，配置 `conf.dir` 指向配置目录（可自动预加载 `.lua`）
2. 业务服务调用：
   - `local sharetable = require "service.sharetable"`
   - `local conf = sharetable.query("xxx.lua")`
3. 热更新时：
   - 服务端 `loadfile("xxx.lua")` 生成新版本
   - 业务侧调用 `sharetable.update("xxx.lua")` 把旧引用替换为新引用（尽量做到“无感更新”）

---

如果你希望我把 `sharetable.update` 的“替换范围/不会替换的范围/失败模式（例如 C 闭包、userdata 复杂引用）”也整理成 checklist，我可以继续补一节“热更新边界与排障指南”。

