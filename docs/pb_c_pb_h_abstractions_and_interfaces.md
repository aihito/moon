# `third/pb/pb.c` / `third/pb/pb.h` 抽象与接口梳理文档

本文按“底层 Protobuf 引擎（`pb.h`）”与“Lua 绑定层（`pb.c`）”两级，把代码里的主要抽象对象与对外接口做一次归纳，便于你在审计线程安全、性能与扩展协议时快速定位。

---

## 1. 分层概览

1. `third/pb/pb.h`：C 层 Protobuf 运行时引擎与“schema 数据结构”
   - 保存/查找类型描述（`pb_State / pb_Type / pb_Field` 等）
   - 执行 wire format 的编码/解码（`pb_Buffer / pb_Slice` + `pb_read*/pb_add*`）
2. `third/pb/pb.c`：把 `pb.h` 封装成 Lua 模块 `pb`
   - 每个 `lua_State` 对应一个 `lpb_State`（线程/状态隔离关键点）
   - 可选 `pb.share_state()`：把一个 `lpb_State` 的 schema 指针共享给其它 `lua_State`
   - 对外暴露 Lua API：`clear/load/loadfile/encode/decode/.../pack/unpack`

---

## 2. 底层抽象：`pb.h`

### 2.1 输入/输出视图抽象

1. `pb_Slice`
   - 作用：对“输入二进制/文本”做零拷贝视图（`p/start/end`）
   - 常见用途：`pb.decode(...)` 的输入、wire 解析过程中移动游标
   - 对应接口（示例）：
     - `pb_slice / pb_lslice`
     - `pb_pos / pb_len`
     - `pb_readvarint32/pb_readfixed32/pb_readslice/...`
     - `pb_skipvalue / pb_skipvarint / pb_skipslice`

2. `pb_Buffer`
   - 作用：编码阶段的输出缓冲区
   - 常见用途：`pb.encode(...)` 里不断 `pb_add*` 写入
   - 对应接口（示例）：
     - `pb_initbuffer / pb_resetbuffer`
     - `pb_prepbuffsize_ / pb_addlength / pb_addslice / pb_addbytes`

---

### 2.2 schema 抽象：类型描述数据库

schema 指“Protobuf 类型结构在运行时的表示”，它决定：
- Lua 表 -> 二进制：字段 tag、字段类型、oneof/map/repeated 规则如何编码
- 二进制 -> Lua 表：tag 如何映射到字段，字段类型如何解析为 Lua 值

`pb.h` 里主要抽象是：

1. `pb_State`
   - 作用：schema 的顶层数据库容器（类型表、name 表、内存池等）
   - 关键成员：
     - `pb_NameTable nametable`（名字/字符串的缓存与复用）
     - `pb_Table types`（类型名 -> pb_TypeEntry）
     - `pb_Pool typepool`、`pb_Pool fieldpool`（对象内存池）

2. `pb_Name`
   - 作用：对“类型名/字段名/枚举名/默认值名”等字符串做 intern（并带引用管理）
   - 关键接口：
     - `pb_newname / pb_delname / pb_usename`
     - `pb_name(...)`（带 cache 的类型名解析）

3. `pb_Type`
   - 作用：message/enum/map 的类型描述
   - 关键成员（结构体在 `pb.h` 中明确定义）：
     - `pb_Field **sorted_fields`（按 field number 排序后的字段指针数组，encode/decode/pack/unpack 会用到）
     - `pb_Table field_tags` / `pb_Table field_names`（tag 与字段名的映射索引）
     - `pb_Table oneof_index`、`oneof_count/oneof_field`
     - `field_count/is_enum/is_map/is_proto3/is_dead`

4. `pb_Field`
   - 作用：某个 message/类型下的字段描述
   - 关键成员：
     - `pb_Name *name`、`pb_Type *type`
     - `pb_Name *default_value`
     - `number`（tag 编号）
     - `sorted_idx`（排序位置，用于 unpack 默认填充/跳过统计）
     - `repeated/packed/oneof_idx/type_id` 等字段属性

5. `pb_Cache`
   - 作用：给字符串名到内部名字对象（`pb_Name`）的查找提供局部缓存（减少哈希查找次数）
   - 在 `pb.h` 中以 `PB_CACHE_SIZE=53` 的 slot 结构存在

6. `pb_Table` / `pb_Entry`
   - 作用：哈希表实现（类型表、字段表、enum/oneof 等都依赖它）
   - 对应接口：
     - `pb_inittable / pb_freetable / pb_gettable / pb_settable / pb_nextentry`

---

### 2.3 schema 加载与类型查询接口

`pb.h` 给出的最核心接口（按使用顺序）：

1. 初始化/释放
   - `pb_init(pb_State *S)`
   - `pb_free(pb_State *S)`

2. 加载类型描述
   - `pb_load(pb_State *S, pb_Slice *s)`
   -（Lua 侧会提供 `pb.load/loadfile` 封装）

3. 类型查找与遍历
   - `pb_type(S, tname)`
   - `pb_fname(t, fname)`
   - `pb_field(t, number)`
   - `pb_oneofname(t, idx)`
   - `pb_nexttype(S, &ptype)`
   - `pb_nextfield(t, &pfield)`
   - `pb_sortedfields(t)`（会生成惰性排序结果）

---

## 3. Lua 绑定层抽象：`pb.c`

### 3.1 每 `lua_State` 一份 `lpb_State`

在 `pb.c` 中，核心抽象是：

- `lpb_State`：每个 Lua 状态独立的 pb 运行环境
  - 成员包括：
    - `const pb_State *state`：当前选择的 schema 指针（可能是 local，也可能指向共享 global_state）
    - `pb_State local`：该 Lua 状态私有的 schema 容器（未 share_state 时）
    - `pb_Cache cache`：名字查找缓存
    - `pb_Buffer buffer`：编码输出缓冲（私有）
    - `defs_index/enc_hooks_index/dec_hooks_index`：hooks/defaults 的 registry 引用
    - `encode_mode/enum_as_value/use_dec_hooks/use_enc_hooks/...`：编码/解码策略

`lpb_lstate(L)` 的行为：
- 如果 registry 里已有 `pb_State` userdata，则直接复用
- 否则创建新的 `lpb_State`，并把 `LS->state` 指向：
  - `global_state`（如果启用 share_state）
  - 或 `&LS->local`（默认的私有 schema）

这也是“多 worker 下天然隔离”的基础。

---

### 3.2 `pb.share_state()` 的抽象语义

`pb.share_state()` 通过 C 层静态指针：
- `static const pb_State *global_state = NULL;`

把某个 `lpb_State` 的 `local` schema 指针写入 `global_state`。

之后新建的 `lpb_State` 会把 `LS->state` 指向 `global_state`，达到跨 Lua 状态复用 schema 的目的。

从实现上看：
- 不存在锁/引用计数（因此需要严格生命周期与只读约束，具体分析见你之前的线程安全文档）。

---

## 4. `luaopen_pb` 暴露的 Lua 接口（抽象接口清单）

`pb.c:luaopen_pb` 里注册的 libs（可认为是“pb 模块对外 API”）包括：

- `clear`
- `load`
- `loadfile`
- `encode`
- `decode`
- `types`
- `fields`
- `type`
- `field`
- `typefmt`
- `enum`
- `defaults`
- `hook`
- `encode_hook`
- `tohex`
- `fromhex`
- `result`
- `option`
- `state`
- `share_state`
- `pack`
- `unpack`

## 4.1 `pb` Lua 接口：返回值/出参数与作用

`pb.c` 里这些函数的“出参数”体现在 Lua 返回值上；部分接口会根据参数/查找结果返回 0 个或多于 1 个值。

| 接口 | 作用 | 返回值（出参数） |
|---|---|---|
| `clear([type_or_field])` | 清空当前 `lua_State` 的 schema：不传参清空全部；传类型清空类型；传类型+字段清空字段 | `0` |
| `load(proto_bytes_or_text)` | 将 `.proto` 文本/字节加载到当前 `lua_State` 的 pb schema 中 | `2`：`boolean ok, integer next_pos` |
| `loadfile(filename)` | 从文件加载 schema（通常是预编译的 descriptor 集/二进制） | `2`：`boolean ok, integer next_pos` |
| `encode(type_name, tbl)` | 按 protobuf 类型把 Lua table 编码为 bytes（wire format） | `1`：`string bytes` |
| `decode(type_name, bytes[, start_table])` | 把 bytes 解码为 Lua table | `1`：`table decoded` |
| `types()` | 迭代当前 schema 内所有类型 | `3`：`iter_fn, nil, nil`（用于 `for x in pb.types() do ... end`） |
| `fields(type_name)` | 迭代某个类型下所有字段的元信息 | `3`：`iter_fn, type_name, nil`（用于 `for f in pb.fields("T") do ... end`） |
| `type(type_name)` | 查询某个类型的元信息 | `0` 或 `3`：`string name, string basename, string kind("map"/"enum"/"message")` |
| `field(type_name, field_selector)` | 查询某个字段的元信息（field_selector 可以是字段名或字段号） | `0` 或 `5` 或 `7`：字段名、tag(number)、字段类型、default、label（optional/repeated/packed…）；oneof 则额外返回 oneof 名与 oneof_idx |
| `typefmt(x)` | 格式化类型/符号，返回它对应的 wire/fmt 信息 | `2`：`string fmt, integer type_id` |
| `enum(type_name, enum_selector)` | 枚举双向映射（传值->取名，传名->取值） | `0` 或 `1`：找到则返回 `string`（selector 是 number 时）或 `integer`（selector 是字符串时） |
| `defaults(type_name[, clear])` | 获取/设置 protobuf 默认字段填充策略/默认元表（与 proto3 default 语义相关） | `1`：默认元表（或相关返回值） |
| `hook(type_name, fn_or_nil)` | 给解码 `decode` 挂 hook（按类型级别） | `1` |
| `encode_hook(type_name, fn_or_nil)` | 给编码 `encode` 挂 hook（按类型级别） | `1` |
| `tohex(bytes)` | bytes 切片转 hex 字符串 | `1`：`string hex` |
| `fromhex(hex_bytes)` | hex 字符串切片转 bytes | `1`：`string bytes` |
| `result(slice[, start[, end]])` | 从输入 slice 获取子区间（start/end 支持相对负数） | `1`：`string sub` |
| `option(opt_name)` | 设置 `lpb_State` 的编码/解码策略开关（如 int64 模式、encode_order、默认值/ hooks 等） | `0` |
| `state([state_ud])` | 获取/设置当前 `pb_State` userdata（用于关联/默认选择） | `1`：`state_ud_or_nil` |
| `share_state()` | 让当前 `lua_State` 的 schema 状态共享给其它 `lua_State`（C 层静态指针 `global_state`） | `0`（若已共享会抛错） |
| `pack(type_name, tbl1, tbl2, ...)` | “字段级 pack”：把一批字段打包成 bytes（实现内部会用到 `pb_sortedfields`） | `1`：`string bytes` |
| `unpack(type_name, bytes)` | 解包 bytes：按类型字段顺序/sorted_idx 把各字段值作为多返回值吐出 | `t->field_count` 个返回值（字段顺序位置对应 `sorted_idx`；部分可能是 `nil/默认值`） |

建议你理解为三类抽象接口：

1. **schema 管理/内省**
   - `load/loadfile/clear`
   - `types/type/fields/field/enum/defaults/typefmt`

2. **编码/解码**
   - `encode/decode`
   - `pack/unpack`（更偏“字段集”的打包解包语义；内部会触发惰性 sorted_fields 初始化）

3. **运行期策略与 hook**
   - `option`：编码/解码策略开关（如 int64 模式、encode_order、hooks 开启等）
   - `hook/encode_hook`：解码/编码时的函数钩子
   - `state`：取/设 pb 的默认 state userdata
   - `share_state`：schema 共享开关（跨 lua_State 的 schema 复用）

---

## 5. 文档落点建议

你后续如果要做“线上审计/扩展协议”，通常需要从两条路径分别读代码：

1. `pb.h`：先确认 schema 数据结构与 `pb_sortedfields` 等惰性行为（它决定 pack/unpack 是否可能写共享结构）
2. `pb.c`：再确认 Lua 绑定如何把这些结构挂到 `lpb_State`，以及 `global_state` 的生命周期和释放路径（`__gc/pb.delete`）

如果你希望我继续把本 doc 扩展为“每个 Lua 接口对应 pb.h 的哪条核心结构/函数”的映射表，我可以按你线上使用的 API 子集（例如只用 `encode/decode/pack/unpack`）进一步精简与落到风险点。

