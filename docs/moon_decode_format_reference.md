# moon.decode 解析格式参考

`moon.decode(msg, format)` 用于从消息对象 `msg`（`message_ptr`，即 raw 协议回调收到的参数）中按格式串解析出若干字段。格式串由单个字符组成，每个字符对应一个返回值（`C` 除外，返回两个值）。

**定义位置**：`src/lualib-src/lua_moon.cpp` 中 `message_decode`。

---

## 格式字符一览

| 字符 | 含义 | 返回值类型 | 说明 |
|------|------|------------|------|
| **S** | Sender | integer | 发送方 ID（如 service id、socket fd） |
| **R** | Receiver | integer | 接收方 ID（如 socket 事件类型 socket_data_type） |
| **E** | sEssion | integer | 会话 ID（sessionid），用于 request-response 配对 |
| **Z** | 数据（字符串） | string \| nil | 消息体：有数据时为 Lua 字符串，无数据时为 nil |
| **N** | 长度（Number） | integer | 消息体字节数 `size()` |
| **B** | Buffer（只读引用） | lightuserdata | `as_buffer()`：buffer 指针，不转移所有权，消息仍持有数据 |
| **L** | 取出 Buffer（转移所有权） | lightuserdata | `into_buffer()`：取出 buffer，消息不再持有，调用方需负责释放 |
| **C** | 原始数据/指针 + 长度 | (ptr, size) 两个值 | 见下表 |

---

## 各格式详细说明

### S（Sender）

- **C++ 对应**：`m->sender`
- **类型**：integer
- **常见用途**：发送方 service id、socket 的 fd 等。  
- **示例**：`local fd, sdt = moon.decode(msg, "SR")` 中 `fd` 即 sender（在 socket 消息里表示连接 fd）。

### R（Receiver）

- **C++ 对应**：`m->receiver`
- **类型**：integer
- **常见用途**：接收方 ID；在 PTYPE_SOCKET_MOON 中复用为事件类型（如 2=accept, 3=message, 4=close）。  
- **示例**：`local fd, sdt = moon.decode(msg, "SR")` 中 `sdt` 即 receiver，用于 `callbacks[sdt](fd, msg)`。

### E（Session）

- **C++ 对应**：`m->session`
- **类型**：integer
- **常见用途**：request-response 配对、超时与回调匹配。  
- **示例**：`local sender, sessionid, sz, len = moon.decode(msg, "SEC")` 取发送方、会话 ID 以及原始数据指针与长度。

### Z（消息体字符串）

- **C++ 对应**：`m->data()` 与 `m->size()`；无数据时等价为 nil
- **类型**：string 或 nil
- **常见用途**：把消息体当 Lua 字符串使用（如 JSON 文本、错误信息、地址字符串）。  
- **示例**：`moon.decode(msg, "Z")` 取包体；`moon.decode(msg, "SR")` 与 `moon.decode(msg, "Z")` 分别取元信息和内容。

### N（长度）

- **C++ 对应**：`m->size()`
- **类型**：integer
- **说明**：消息体字节数，不返回实际数据。

### B（Buffer 引用）

- **C++ 对应**：`m->as_buffer()`
- **类型**：lightuserdata（buffer*）
- **说明**：只读引用消息内部的 buffer，不转移所有权；消息生命周期内指针有效。适合只读访问或配合其他 API 使用。

### L（取出 Buffer）

- **C++ 对应**：`m->into_buffer()`
- **类型**：lightuserdata（buffer*）
- **说明**：从消息中取出 buffer 所有权，消息不再持有；调用方需按约定释放或交给接受 ownership 的 API。适合需要长期持有或修改 buffer 的场景。

### C（原始数据/指针 + 长度）

- **C++ 对应**：根据 `m->is_bytes()` 分支：
  - **is_bytes() == true**：`(m->data(), m->size())` → 压栈为 **(lightuserdata, integer)**
  - **is_bytes() == false**：`(m->as_ptr(), m->size())` → 压栈为 **(integer, integer)**
- **返回值**：**两个**（ptr 或 integer，以及 size）
- **常见用途**：需要指针/长度对时使用，如 `moon.decode(msg, "SEC")` 得到 sender、session、数据指针、长度。  
- **示例**：`local sender, sessionid, sz, len = moon.decode(msg, "SEC")` 中 `sz` 为数据指针或整数，`len` 为长度。

---

## 常见组合示例

| 格式 | 含义 | 典型场景 |
|------|------|----------|
| `"SR"` | fd, socket_data_type | moonsocket 回调：`local fd, sdt = moon.decode(msg, "SR")` |
| `"Z"` | 消息体字符串 | 取包体：`moon.decode(msg, "Z")` |
| `"SC"` | fd, (ptr, size) 共 3 个值 | UDP：`local fd, p, n = moon.decode(msg, "SC")` |
| `"SEC"` | sender, session, (ptr, size) 共 4 个值 | 带会话的 raw 数据：`moon.decode(msg, "SEC")` |
| `"SZ"` | sender, 数据字符串 | system 协议等：`local sender, data = moon.decode(msg, "SZ")` |
| `"B"` | buffer 引用 | 需要 buffer* 不转移所有权时 |
| `"L"` | 取出的 buffer | 需要独占 buffer 所有权时 |

---

## message 结构简要说明

C++ 中 `message` 主要字段（与格式对应关系）：

- `type`：协议类型（PTYPE_*），decode 不直接提供，可从协议层得知。
- `sender` → **S**
- `receiver` → **R**
- `session` → **E**
- 数据区：`data()`/`size()`、`as_buffer()`、`into_buffer()`、`as_ptr()` 等 → **Z / N / B / L / C**。

数据区有两种内部表示：**bytes**（buffer）或 **ptr/integer**（如 fd、timerid）。`C` 会根据 `is_bytes()` 返回指针或整数加长度。

---

## 相关文件

| 内容 | 路径 |
|------|------|
| decode 实现 | `src/lualib-src/lua_moon.cpp`（message_decode） |
| message 定义 | `src/moon/core/message.hpp` |
| 使用示例 | `lualib/moon/socket.lua`、`lualib/moon.lua`、`service/sqldriver.lua`、`service/cluster.lua` 等 |
