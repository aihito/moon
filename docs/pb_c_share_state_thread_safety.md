# third/pb/pb.c：pb.share_state 线程安全全盘分析

## 背景与结论先说

`third/pb/pb.c` 里的 `pb.share_state()` 会把“当前 Lua 状态里的 pb schema 状态”以 C 层的静态指针形式共享给其它 Lua 状态（其它 worker/其它线程里的 `lua_State`）。

## 什么是 pb schema（pb 类型描述）

在这份 Moon 项目里，所谓 **pb schema**，指的是 Protobuf 在运行时需要用到的“类型描述信息（descriptor）”，也就是 `pb.encode("SomeMessage", data)` / `pb.decode("SomeMessage", bytes)` 时要依赖的那份元数据。

你可以把它理解为：Protobuf 的“字段表 + tag 编号映射 + 类型结构信息”，它决定了二进制如何从 Lua 表编码、以及如何从二进制解码回 Lua 表。

### 1) pb schema 从哪里来

- 你通常通过 `.proto` + `protoc` 生成编译结果（也可能在运行时用 `protoc:load` 把 `.proto` 文本加载进来）。
- 在 Moon 的 pb 实现中，这份描述信息最终会被 `pb.load(...)` / `pb.loadfile(...)` 加载到当前 Lua 状态对应的 C 层 `lpb_State` 里（内部包含一个 `pb_State local`）。

在 pb.c 里，对应的加载入口包括：
- `Lpb_load`（`pb.load`）
- `Lpb_loadfile`（`pb.loadfile`）

### 2) pb schema 包含什么

运行时的 pb schema 主要包含这些内容：
- message 类型集合：能根据类型名找到对应的 `pb_Type`
- 字段集合：字段名、字段号(tag)、字段类型等 `pb_Field` 信息
- enum / oneof 等附加信息

没有 pb schema，就无法把 Lua 表和二进制 wire format 建立起映射关系。

### 3) pb schema 和“业务数据”有什么区别

业务数据是每条消息本身的取值，例如：
- `room_id = 1`
- `player_id = "alice"`

pb schema 则是“字段结构怎么编码/解码”的规则（相对稳定、由 `.proto` 定义）。

### 4) 为什么 pb schema 会影响线程安全

当你调用 `pb.share_state()` 时，pb.c 会把当前 Lua 状态里的 pb schema 状态指针替换成一个 C 层静态 `global_state`，从而让其它 Lua 状态共享同一份类型描述。

如果这份共享 schema 在并发下会被释放、清空，或在第一次使用时进行惰性缓存初始化写入，就会产生竞态与悬空指针风险。

**结论：在多线程/多 worker 的在线环境下，除非你能严格满足生命周期与“只读约束”，否则 `pb.share_state()` 本身不具备可证明的线程安全性**。主要风险来自：
1. C 层静态全局指针 `global_state` 的读写没有任何互斥/原子保护（数据竞争风险）。
2. 共享状态并不做引用计数；一旦持有该共享状态的 Lua 状态被销毁、或在共享状态上调用了会释放/清空类型的 API，可能出现 **use-after-free / 悬空指针**（线上致命风险）。

下面给出“逐接口”分析（仅基于 `pb.c`；不展开 `pb.h` 内部实现）。

---

## 代码证据：global_state 与状态绑定机制

### 1) C 层静态全局指针

在 `pb.c` 中定义了：
- `static const pb_State *global_state = NULL;`

`pb.share_state()` 会把某个 `lpb_State` 的 `local` 赋给 `global_state`：
- `Lpb_share_state`（约 1958 行左右）：当 `global_state == NULL` 时设置 `global_state = &LS->local`。

其它 Lua 状态在创建 `lpb_State` 时，会把 `LS->state` 指向：
- `LS->state = (NULL != global_state ? global_state : &LS->local);`

也就是说：
- `global_state` 指向某个“先调用 share_state 的 Lua 状态”内部 pb 数据结构内存。
- 后续其它 Lua 状态的 encode/decode/类型查找都会间接引用这份内存。

### 2) 生命周期清理会动到 global_state

`pb.delete`（`Lpb_delete`，被 `__gc` 调用）会释放 `LS->local`，并在发现释放对象等于当前 `global_state` 时把 `global_state = NULL`。
- 如果其它线程/其它 Lua 状态仍在使用 shared 指针，可能出现 UAF（悬空引用）。

`pb.clear()`（`Lpb_clear`）在“清空全部类型/字段”时也会对 `LS->local` 做释放/重置：
- 如果某个 Lua 状态在 share_state 后其 `LS->local` 正好等于 shared 的底层对象，则 clear 可能破坏共享数据。

---

## 逐接口线程安全分析（Lua 暴露的 pb API）

`luaopen_pb` 暴露的接口包括：`clear/load/loadfile/encode/decode/types/fields/type/field/typefmt/enum/defaults/hook/encode_hook/tohex/fromhex/result/option/state/share_state/pack/unpack`。

下面按“是否可能写共享 pb_State / 是否可能释放共享 pb_State / 是否只读使用 pb_State + 写线程私有缓冲”来分析。

### 接口级别结论速查表（share_state 场景）

> 说明：这里的“安全/不安全”指在 `pb.share_state()` 之后的多线程并发场景下，不加锁是否还能成立。

| 接口 | 读 shared pb schema | 是否会修改 shared schema | 线程安全性（share_state 场景） |
|---|---|---|---|
| `share_state` | 读当前 LS | 写 C 静态 `global_state` | 不安全：全局指针无锁 + 生命周期风险 |
| `clear` | 可能读 | 可能释放/重置 `LS->local`（若 shared 则会破坏） | 不安全 |
| `load/loadfile` | 可能读 | 写 `LS->local`（shared LS 上写则破坏共享语义） | 不安全（除非保证只在非 shared LS 上调用） |
| `encode` | 只读类型 | 通常不写 shared（写线程私有 buffer） | 通常可行：前提 shared 不被 clear/load/delete |
| `decode` | 只读类型 | 通常不写 shared（写线程私有 Lua 结果） | 通常可行：前提 shared 不被 clear/load/delete |
| `pack/unpack` | 只读类型 + 惰性缓存 | `pb_sortedfields()` 会写共享 `pb_Type->sorted_fields/sorted_idx` | 不安全：惰性缓存无锁写共享字段 |
| `types/fields/type/field/enum/defaults/typefmt/result/tohex/fromhex` | 只读遍历 | 通常不写 shared | 通常可行：前提 shared 不被释放 |
| `hook/encode_hook` | 只读类型指针 | 写本 Lua 状态的 hooks registry | 通常可行：前提 shared 类型指针有效 |
| `option/state` | 读 shared（查类型时） | 写当前 Lua 状态的 `lpb_State` 配置 | 通常可行：前提 shared 类型指针有效 |

### 0) 前置统一假设（用于“分析线程安全 vs 不安全”）

在多线程环境中：
- 每个 worker 有自己的 `lua_State`，C 扩展会为每个 `lua_State` 创建独立的 `lpb_State` 实例（含 `buffer`、`cache`、hooks 索引、encode/decode mode 等）。
- `share_state` 后，`lpb_State->state` 会指向同一份 `global_state`（共享 pb schema 描述数据）。

因此，线程安全的关键不是 encode/decode 是否会写 pb buffer（它们有线程私有 buffer），而是**共享 pb schema 的生命周期与只读性**。

---

### 1) share_state（不线程安全，需强约束）

`share_state` 通过静态全局指针 `global_state` 完成共享：
- 没有锁/原子操作。
- 如果多个线程同时调用，在 `global_state == NULL` 的判断处存在竞争窗口。
- 即使你“只在单线程调用一次”，也仍存在生命周期问题（见后文“线上风险点”）。

**结论：**
- 多线程并发调用不安全（数据竞争）。
- 即使只调用一次，也不能保证“加载 share 的那份 Lua 状态不会被销毁/不会 clear/load 到共享对象”。

---

### 2) clear（不安全：可能释放/重置共享对象）

`Lpb_clear` 的关键行为：
- 传 `nil` 时：`pb_free(&LS->local)` + `pb_init(&LS->local)`，并清理若干 registry refs。
- 若清类型/字段：会在 `LS->state` 临时切换后调用 `pb_deltype/pb_delfield`，再恢复 `LS->state`。

如果某个 Lua 状态在 share_state 后其 `LS->state == global_state`，并且 `LS->local` 也与 shared 共享底层对象相关，那么 clear 会破坏共享数据。

**结论：clear 在 share_state 场景下对共享对象是破坏性的，不安全。**

---

### 3) load / loadfile（不安全：可能修改/替换 schema 读取路径）

`Lpb_load/loadfile` 把 schema 加载到 `LS->local`：
- 这在“未 share_state 的 LS”里是线程隔离的。
- 但在 share_state 之后，如果调用 load 的是共享 LS，`LS->local` 可能就是 shared 对象或与 shared 对象绑定，造成并发修改风险。

**结论：**
- 在 share_state 的共享 Lua 状态上调用 load/clear 是高风险。
- 其它 Lua 状态如果不调用 load，且共享对象保持只读，则这类修改风险可避免；但“可避免”不等于“库层面保证安全”。线上仍需使用约束。

---

### 4) encode / pack（通常线程安全，但依赖共享对象寿命）

`Lpb_encode/Lpb_pack`：
- 通过 `lpb_lstate(L)` 取出当前 `lpb_State`。
- 通过 `lpb_type(...)` 做类型解析（依赖 `lpbS_state(LS)`，也就是 shared 或 local pb_State）。
- 编码过程主要写到当前 `lpb_State` 的 `buffer`（线程私有）。
- hooks 的查找与调用使用当前 Lua 状态的 registry/hook table（线程私有）。

`encode` 本身并不修改共享 pb schema（按 pb.c 逻辑看是只读查找）。

**真正的风险仍是共享对象生命周期：**
- 如果 shared pb_State 被 `__gc/delete/clear` 释放，则 encode 会解引用悬空指针。

**结论：**
- 在 shared pb_State **不被释放/不被 clear/load 修改** 的前提下，encode/pack 是“读共享 + 写线程私有”的模式，更接近线程安全。
- 但库层不保证共享对象不会被其它线程/其它 Lua 状态销毁或清空，因此不能给出“严格线程安全”。

---

### 5) decode / unpack（同 encode：通常线程安全但依赖共享对象寿命）

`Lpb_decode/Lpb_unpack`：
- 使用 `lpb_type(...)` 查类型信息。
- 对当前 Lua state 进行解码，把结果写回到当前 Lua 栈/表（线程私有）。

同样：
- decode 过程本身不需要修改共享 pb schema。
- 风险点依旧是 shared pb_State 的生命周期。

---

### 6) types/fields/type/field/enum/defaults/typefmt/result（通常只读、但同样依赖 shared 寿命）

这些接口主要做 schema introspection：
- 遍历类型/字段列表
- 返回常量信息或默认值
- 生成字符串表示

一般情况下是“只读使用 pb_State + 写 Lua 栈”。

但如果 shared pb_State 被释放或 clear 了，仍可能 UAF。

---

### 7) hook / encode_hook（通常线程隔离，但依赖 shared 寿命）

`hook/encode_hook` 的行为是：
- 取 pb_Type 指针
- 在当前 Lua 状态 registry 的 hooks table 里挂函数

hooks table 是“每 Lua 状态独立”的（Lua 状态间互不共享）。

因此：hooks 的设置在“多线程”下通常更接近安全。

但它仍需要 `pb_Type`（来自 shared pb_State）的指针有效，否则可能悬空。

---

### 8) option/state（修改当前 LS 自身参数：通常安全）

`option`：修改 `lpb_State` 内部编码/解码模式（如 encode_mode、use_dec_hooks 等），属于当前 Lua 状态私有数据。

`state`：返回当前 lpb_State（或允许设置默认 state 用户数据），也属于当前 Lua 状态私有数据。

它们不直接写 shared pb schema，因此相对安全。

---

## 线上风险点（你在多 worker 在线部署时需要特别关注）

1. **UAF（use-after-free）**
   - `global_state` 没有引用计数或锁。
   - share_state 后，一旦持有共享 pb_State 的 Lua 状态被回收，`__gc/delete` 会释放该 pb_State，并把 `global_state = NULL`。
   - 其它线程/其它 Lua 状态里的 `lpb_State->state` 可能仍指向已释放内存，直接导致崩溃或随机行为。

2. **数据竞争（global_state 指针写入竞争）**
   - 如果多线程同时首次调用 share_state（global_state==NULL 的竞态窗口），会把 global_state 指向错误对象或造成不可预测行为。

3. **共享对象被 clear/load 修改**
   - 如果共享 LS 上调用 `pb.clear()` 或 `pb.load/loadfile()`，会修改共享 schema；与其它线程的 encode/decode 的只读假设冲突。

4. **pb_Type 的“惰性缓存”导致的竞争（pack/unpack 特别需要注意）**

即使你只做 encode/decode，仍要注意 `pack/unpack` 会走 `pb_sortedfields(t)`：
- 在 `third/pb/pb.h`：`pb_sortedfields` 在发现 `t->sorted_fields == NULL` 时会做 `malloc/qsort`，并把结果写回到共享的 `pb_Type` 字段：
  - `((pb_Type*)t)->sorted_fields = list;`
  - 并设置每个字段的 `sorted_idx`

这个写入没有任何锁/原子保护。

因此：当多个线程首次并发调用 `pb.pack/pb.unpack`（或其它内部最终调用到 `pb_sortedfields`）时，会发生真实的数据竞争（写共享字段）。

---

## 推荐使用准则（让“看起来单线程 share 后多线程读”变得可控）

如果你确实要在多线程环境启用 `pb.share_state()`，至少要满足：
1. **share_state 只能在启动阶段、且由单线程/单 worker 调用一次**（禁止并发）。
2. 调用 share_state 的那个 Lua 状态对应的服务必须**长期存活**，不能退出/重启/触发 GC。
3. 在这份 shared 状态上 **绝对禁止**调用 `pb.clear/load/loadfile` 等会释放或修改 schema 的 API。
4. 其它线程只做 `encode/decode/pack/unpack/types/.../option/state` 等“只读使用 shared pb schema”的操作。

并且补充：
- `pack/unpack` 如果会被并发调用：建议在多线程启动前由**单线程**对所有你会用到的 message type 做一次 `pb.pack`/`pb.unpack`“预热”，确保 `sorted_fields/sorted_idx` 已完成惰性初始化。
- 否则：pack/unpack 也无法被视为严格线程安全。

如果你无法严格满足上述条件：建议走文档里更稳的策略（集中 proto 服务或每 worker 独立 load schema），避免 share_state。

---

## 与现有文档的关系

`docs/protobuf_usage_multithread.md` 已经给出“多 worker 不要使用 pb.share_state()”的方向性结论。
本文件提供了基于 `third/pb/pb.c` 的更细粒度证据与逐接口推导，用于线上风险评估与代码审查。

