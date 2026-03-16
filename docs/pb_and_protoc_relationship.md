# pb 与 protoc 的关系说明

本文说明项目中 **pb** 与 **protoc** 两个模块分别做什么、彼此如何配合，以及“protoc 里加载 schema 和 pb 的关系”。

---

## 1. 一句话分工

| 模块 | 角色 | 是否依赖对方 |
|------|------|----------------|
| **pb** | **运行时**：加载“已编译的 schema 二进制”、按类型名 encode/decode 消息 | 不依赖 protoc |
| **protoc** | **编译器**：把 .proto **文本** 解析成“描述信息”，再借 pb 变成二进制并载入到 pb 里 | 依赖 pb（仅用于“编译结果”的序列化与注册） |

也就是说：**解析 .proto 的是 protoc（纯 Lua）；真正“加载 schema、做编解码”的是 pb（C + Lua）。**

---

## 2. pb 做什么（与 protoc 无关的部分）

**pb**（`third/pb/`，C 实现 + Lua 绑定）提供：

- **pb.load(binary)** / **pb.loadfile(path)**：把一段**二进制**（FileDescriptorSet 的 wire 格式）加载进当前 Lua 状态的 pb 运行时，注册其中的 message/enum 等类型。  
  - 不读 .proto 文本，只认“已经编好的”二进制。
- **pb.encode(typename, lua_table)**：按已注册类型名，把 Lua 表编码成二进制字符串。
- **pb.decode(typename, binary)**：按已注册类型名，把二进制解码成 Lua 表。

所以：**pb 只关心“二进制 schema + 按类型名编解码”，和 .proto 源码、和 protoc 都无关。**  
只要有办法得到“符合 FileDescriptorSet 格式的二进制”，用 `pb.load()` 即可，不一定非用 protoc（例如可以用官方 `protoc --descriptor_set_out=xx.pb` 生成 .pb 再 `pb.loadfile`）。

---

## 3. protoc 做什么（绝大部分与 pb 无关）

**protoc**（`lualib/protoc.lua`）主体是**纯 Lua** 的 .proto 编译器：

- **Lexer**：对 .proto 源码做词法分析。
- **Parser**：语法分析，得到“文件/消息/字段/枚举”等结构，用 Lua 表表示，**结构和 Google 的 FileDescriptorSet 一致**（即 `google.protobuf.FileDescriptorSet` 等描述符在内存里的那种形状）。

这一整块（约 990 行）**完全不 require pb**，也不做任何 encode/decode/load。  
所以“看 protoc 源码里加载 pb 好像跟 pb 没啥关系”是**对的**：**解析 .proto、构建描述表，都和 pb 无关。**

---

## 4. protoc 里“和 pb 有关”的那一小块

只有在**把“解析结果”变成 pb 能用的东西**时，protoc 才会用到 pb。这段逻辑全部在 `if has_pb then ... end` 里（约 993–1191 行）：

```lua
local has_pb, pb = pcall(require, "pb")
if has_pb then
   -- 1) 内嵌的 descriptor.proto 的“已编译二进制”
   local descriptor_pb = "\10\179;..."  -- FileDescriptorSet 的 wire 格式

   function Parser.reload()
      assert(pb.load(descriptor_pb), "load descriptor msg failed")
   end

   -- 2) 把 Parser 输出的 Lua 表编成二进制
   function Parser:compile(s, name)
      local set = do_compile(self, self.parse, self, s, name)
      return pb.encode('.google.protobuf.FileDescriptorSet', set)
   end

   -- 3) 把这段二进制交给 pb 加载，完成“注册类型”
   function Parser:load(s, name)
      local ret, pos = pb.load(self:compile(s, name))
      ...
   end
   ...
   Parser.reload()  -- 模块加载时先让 pb 认识 FileDescriptorSet
end
```

含义可以归纳为三件事：

1. **Parser.reload()**  
   - 用内嵌的 **descriptor_pb**（即 `descriptor.proto` 的**预编译二进制**）调一次 **pb.load(descriptor_pb)**。  
   - 这样当前 Lua 状态里的 pb 就“认识” `.google.protobuf.FileDescriptorSet` 等描述符类型，后面才能对“描述符表”做 encode。

2. **Parser:compile / :compilefile**  
   - 输入：.proto 文本（或文件）。  
   - 内部：纯 Lua 的 **parse/parsefile** 得到 Lua 表 `set`（结构同 FileDescriptorSet）。  
   - 输出：**pb.encode('.google.protobuf.FileDescriptorSet', set)**，得到一段**二进制**。  
   - 所以“编译”的实质是：**.proto 文本 →（protoc 解析）→ Lua 表 →（pb.encode）→ 二进制**。**真正做“加载进运行时”的只有 pb.load。**

3. **Parser:load / :loadfile**  
   - 先通过 **:compile / :compilefile** 得到上面的二进制，再 **pb.load(二进制)**，把用户定义的 message/enum 注册进当前 pb 运行时。  
   - 之后就可以 **pb.encode("Person", data)** / **pb.decode("Person", bytes)** 等。

所以：**“加载”始终是 pb 在做；protoc 只负责“从 .proto 到那一段二进制的生产”，并把这段二进制交给 pb.load。**

---

## 5. 数据流小结（example_pb.lua 里的一次 protoc:load）

```
┌─────────────────────────────────────────────────────────────────┐
│  .proto 文本 (字符串，如 "message Person { ... }")                │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  protoc（纯 Lua）                                                 │
│  Lexer + Parser → 得到“描述符”Lua 表 set（与 FileDescriptorSet 同构）│
│  这里完全不涉及 pb                                                │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  pb.encode('.google.protobuf.FileDescriptorSet', set)           │
│  把描述符表序列化成一段二进制（protoc 调用 pb 的唯一“编码”用途）    │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  pb.load(这段二进制)                                             │
│  在 pb 运行时里注册 Person、Phone 等类型                          │
│  之后 pb.encode("Person", data) / pb.decode("Person", bytes) 可用 │
└─────────────────────────────────────────────────────────────────┘
```

- **和 pb 没关系的**：从 .proto 文本到“描述符 Lua 表”的整条解析链（Lexer/Parser/parse/parsefile）。
- **和 pb 有关系的**：  
  - 用 **pb.encode(FileDescriptorSet, set)** 把这张表变成二进制；  
  - 用 **pb.load(二进制)** 把类型注册进 pb，之后的“加载”和“编解码”都是 pb 的能力。

---

## 6. 为何需要内嵌的 descriptor_pb（Parser.reload）

- **pb.encode('.google.protobuf.FileDescriptorSet', set)** 要求 pb 里**已经**注册过 `FileDescriptorSet` 这个类型。
- 该类型来自 Google 的 **descriptor.proto**（描述“描述符”的元 schema）。
- protoc 在**不**依赖外部文件的前提下，把 descriptor.proto 的**预编译二进制**直接写死在源码里，即 **descriptor_pb** 长字符串。
- **Parser.reload()** 在 `require "protoc"` 时执行一次 **pb.load(descriptor_pb)**，这样当前 Lua 状态里的 pb 就自举了“描述符类型”，才能对 Parser 产出的 Lua 表做 **pb.encode(FileDescriptorSet, ...)**。

所以：**“加载 pb”在 protoc 里的含义 = 先让 pb 加载 descriptor 元 schema（reload），再用 pb 把用户 .proto 的编译结果 encode 成二进制并 load 进去。** 和“用户写的 .proto”打交道的仍是 protoc 的解析器；和“二进制、运行时、encode/decode”打交道的都是 pb。

---

## 7. 对照表（谁干什么）

| 步骤 | 谁在做 | 用不用 pb |
|------|--------|------------|
| 读 .proto 文本、词法/语法分析 | protoc（纯 Lua） | 不用 |
| 得到“描述符”Lua 表（FileDescriptorSet 同构） | protoc（纯 Lua） | 不用 |
| 把描述符表变成二进制 | **pb.encode**(FileDescriptorSet, set) | 用 |
| 把二进制“加载进运行时”（注册类型） | **pb.load**(binary) | 用 |
| 业务消息 encode/decode | **pb.encode** / **pb.decode** | 用 |

---

## 8. 相关代码位置

| 内容 | 路径 |
|------|------|
| protoc 入口、与 pb 的衔接（has_pb, compile, load, reload） | `lualib/protoc.lua` 约 993–1191 行 |
| Parser 解析（parse/parsefile，与 pb 无关） | `lualib/protoc.lua` Lexer/Parser 等前约 990 行 |
| pb.load / encode / decode | `third/pb/pb.c` |
| 示例（protoc:load + pb.encode/decode） | `example/example_pb.lua` |

总结：**pb = 只认二进制的运行时；protoc = 只认 .proto 文本的编译器，通过“描述符表 → pb.encode → 二进制 → pb.load”把两者串起来；真正“加载 schema”的始终是 pb，protoc 源码里和 pb 的关系就这一条链。**
