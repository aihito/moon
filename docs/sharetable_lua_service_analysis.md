# `service/sharetable.lua` 机制梳理（服务端 + 客户端 + 热更新）

本文只聚焦 `service/sharetable.lua`，把它的运行模式、数据结构、对外接口与热更新算法（`sharetable.update`）系统梳理出来。

关联的 C 扩展在 `third/sharetable/lua-sharetable.c`（模块名 `sharetable.core`），其接口细节可参考 `docs/sharetable_design_and_api.md`。

---

## 1) 文件有两种运行形态（非常关键）

`service/sharetable.lua` 通过 `conf = ...` 判断自己是：

### A. 服务端模式（sharetable 服务实例）

触发条件：
- `if conf and conf.name then sharetable_service(); return end`

此时该文件会：
- 启动一个 sharetable 管理服务（用 `moon.dispatch("lua", ...)` 提供 RPC）
- 维护 matrix 版本、文件映射与 client 引用计数

### B. 客户端库模式（业务服务 require 使用）

当 `conf.name` 不存在时：
- 该文件返回一个 `sharetable` table（带 `__index` 懒加载 address + `__gc` 自动 close）
- 业务服务通过它调用 sharetable 服务的 RPC
- 并提供 `sharetable.update(...)` 做“热更新替换旧引用”

---

## 2) 服务端模式：核心数据结构

`sharetable_service()` 内部维护三个表：

1. `files: { filename -> matrix_state_ud }`
   - 记录每个配置文件当前加载出的 matrix（最新版本）

2. `matrix: { ptr -> ref }`
   - ptr 是 `matrix_state_ud:getptr()` 取到的 lightuserdata
   - ref 的结构：
     - `filename`: 对应文件
     - `count`: 被多少个 client service 引用
     - `matrix`: 指向 `matrix_state_ud`（注意：历史版本会保留到无人引用才 close）
     - `refs`: `{ [source_service_id]=true }` 去重用

3. `clients: { source_service_id -> {ptr1, ptr2, ...} }`
   - 反向索引：某个 client service 当前持有哪些 ptr，用于 close 时统一减引用

---

## 3) 服务端模式：RPC 接口与语义

所有 RPC 通过：
- `moon.dispatch("lua", function(sender, session, cmd, ...) sharetable[cmd](sender, session, ...) end)`

### 3.1 `loadfile(source, sessionid, filename, ...)`

**作用**
- 从文件加载配置，生成新的 matrix 版本，并替换 `files[filename]`

**细节**
- 若配置了 `conf.dir`：`filename = fs.join(conf.dir, filename)`，服务端内部统一用 join 后的完整路径当 key
- `close_matrix(files[filename])`：尝试回收旧 matrix（仅在无人引用时关闭）
- `files[filename] = core.matrix("@"..filename, ...)`

**返回**
- `moon.response(..., true)`

### 3.2 `loadstring(source, sessionid, filename, datasource, ...)`

**作用**
- 从字符串加载配置（常用于在线下发/动态生成），替换 `files[filename]`

**返回**
- 这里的实现只 `moon.response("lua", source, sessionid)`（无显式 true/false）

### 3.3 `query(source, sessionid, filename) -> ptr|nil`

**作用**
- 返回 filename 当前版本的 ptr（lightuserdata）
- 并为该 `source` 建立引用计数（去重）

**返回**
- 找不到文件：返回 nil
- 找到：`moon.response(..., ptr)`

### 3.4 `queryall(source, sessionid, filelist?) -> map`

**作用**
- 批量返回 ptr 映射

**参数**
- `filelist` 可选：若传入，则只返回列表中存在的文件；否则返回 `files` 全部

**返回**
- `all_ptr[name] = ptr`
  - 这里的 `name` 来自 `fs.split(filename)` 的文件名部分（不含路径）

### 3.5 `clients(source, sessionid) -> {service_id...}`

**作用**
- 返回当前持有引用的 client service id 列表

### 3.6 `close(source)`

**作用**
- client 析构/关闭时调用，释放它持有的所有 ptr 引用

**关键逻辑**
- 遍历 `clients[source]` 列表：
  - 对每个 ptr：如果 `ref.refs[source]` 存在则清掉，并 `ref.count -= 1`
  - 若 `ref.count == 0` 且 `files[ref.filename] ~= ref.matrix`：说明这是历史版本（非最新），立刻 `ref.matrix:close()` 并从 `matrix[ptr]` 删除

**为什么要区分“历史版本”**
- 最新版本由 `files[filename]` 持有，不会因为 count=0 立即关闭（否则会导致下一次 query 失效）
- 历史版本只有在没人引用时才会被回收

---

## 4) 服务端模式：启动时自动预加载

如果配置了 `conf.dir`：
- 会 `fs.listdir(conf.dir, 0, ".lua")` 列出所有 `.lua`
- 对每个文件名调用 `sharetable.loadfile(0, 0, name)` 预热加载

注意：预加载时 sender/session=0，不走返回值流程。

---

## 5) 客户端库模式：对外 API

客户端模式返回的 `sharetable` 主要提供：

### 5.1 address 懒加载

`sharetable.address` 首次访问会触发：
- `moon.queryservice("sharetable")`

### 5.2 `__gc` 自动 close

`sharetable` table 的 metatable 有 `__gc = report_close`：
- 当该 sharetable 库对象被 GC 时，会向 sharetable 服务发送 `close`，释放引用计数

> 这意味着：业务服务一般不需要手动 close，但也要注意如果你把 sharetable table 放在全局，它可能不会被 GC，引用计数也就不会自动释放。

### 5.3 `sharetable.loadfile/loadstring/clients/query/queryall`

- `loadfile/loadstring/clients`：直接透传 RPC
- `query/queryall`：RPC 拿 ptr 后，会 `core.clone(ptr)` 生成 table，并记录到 `RECORD` 用于更新

---

## 6) 热更新核心：`RECORD` 与 `sharetable.update(...)`

### 6.1 RECORD 的意义

`RECORD[filename]` 维护一个 set：
- key 是“曾经 clone 出来的旧 table 引用”
- value 是 `true`

用途：
- update 时能找到“所有旧版本 table”，并把它们替换成新版本 table

### 6.2 `sharetable.update(name1, name2, ...)` 的高层流程

1. 对每个 name：
   - 取出 `map = RECORD[name]`
   - `new_t = sharetable.query(name)`（注意：这会 clone 新版本并加入 RECORD）
2. 遍历 map 中的 old_t：
   - `insert_replace(old_t, new_t, replace_map)`：构建 old->new 的替换映射（递归子表）
   - 把 old_t 从 map 里删掉
3. 若 `replace_map` 非空：
   - `resolve_replace(replace_map)`：对整个 Lua 世界做“引用替换”

### 6.3 insert_replace：只递归 table 值

`insert_replace` 的策略：
- 只递归 old_t 中 value 为 table 的条目
- `replace_map[ov] = nv`（不存在的 nv 用特殊的 `NILOBJ` 表示）
- 最终 `replace_map[old_t] = new_t`

这决定了 update 的替换粒度：主要面向“配置树形表”。

### 6.4 resolve_replace：扫描并替换引用（范围极大）

resolve_replace 会构造 `match` 分派表，并递归处理：
- `table`：替换 value；并支持替换 key（先收集 keys 再二次处理）
- `function`：扫描 upvalues（debug.getupvalue/setupvalue）
- `userdata`：替换 uservalue（debug.getuservalue/setuservalue）
- `thread`：扫描栈值（`core.stackvalues`）+ locals（debug.getlocal/setlocal）+ 每层函数 upvalues
- `metatable`：尝试替换或递归扫描 mt
- 最后从 `debug.getregistry()` 作为 root 开始扫描整个引用图

并且有三条重要“跳过规则”：
- `v == nil` 跳过
- `record_map[v]`（已处理过）跳过
- `is_sharedtable(v)` 跳过（避免去改 sharetable 的共享只读对象）

---

## 7) 失败模式/边界（你线上要注意）

1. update 的扫描范围非常大：registry + 所有协程栈/locals/upvalues 可能带来明显卡顿。
2. 只支持替换“可访问的引用”：如果某些 C 模块内部缓存了 Lua table 指针（不在 Lua 可遍历结构里），update 无法替换。
3. `is_sharedtable` 会跳过共享对象：这很重要，否则会破坏 sharetable 只读约束。

---

## 8) 推荐使用姿势（经验）

- 配置尽量保持“纯数据表”（table/string/number/bool），避免复杂 userdata、闭包、metatable。
- 更新时按文件粒度调用 `sharetable.update("xxx.lua", "yyy.lua")`，避免一次更新扫描过多无关引用。
- 如果只需要“新配置生效给新请求”，可以不调用 update，而是让业务代码在关键路径重新 query/取新 table（降低全局替换成本）。

