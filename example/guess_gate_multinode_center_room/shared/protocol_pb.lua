--- Protobuf 二进制帧协议：所有 客户端<->Center、客户端<->Room 通讯均使用此格式。
--- 帧格式：[2B payload_len LE][2B cmd_id LE][payload]；payload 为 pb.encode(message_name, tbl) 结果。
--- 需在 main 中先 load_protocol() 并 pb.share_state()。
local pb = require("pb")
local socket = require("moon.socket")
local CmdCode = require("protocol.CmdCode")

local M = {}

local function pack_u16(n)
    return string.pack("<H", n & 0xFFFF)
end

local function unpack_u16(s, offset)
    local a, b = string.unpack("<H", s, offset or 1)
    return a, (offset or 1) + 2
end

--- 打包一帧：cmd_id (number) + payload (string)
function M.pack_frame(cmd_id, payload)
    payload = payload or ""
    return pack_u16(#payload) .. pack_u16(cmd_id) .. payload
end

--- 从 fd 读一帧。返回 cmd_id, payload；或 nil, err
--- 注意：当前 moon.socket.read(fd, delim, maxcount) 语义里第三个参数是 maxcount
--- 并不提供真正的 frame-level timeout，因此这里不再接受 timeout 参数。
function M.read_frame(fd)
    local head, err = socket.read(fd, 4)
    if not head or #head < 4 then
        return nil, err or "read header failed"
    end
    local len = unpack_u16(head, 1)
    local cmd_id = unpack_u16(head, 3)
    if len > 0 then
        local payload, err2 = socket.read(fd, len)
        if not payload or #payload ~= len then
            return nil, err2 or "read payload failed"
        end
        return cmd_id, payload
    end
    return cmd_id, ""
end

--- 编码消息：name (string) -> payload bytes
function M.encode(name, tbl)
    if type(name) == "number" then
        name = CmdCode.name(name)
    end
    if not name then return nil end
    return pb.encode(name, tbl or {})
end

--- 解码消息：cmd_id 或 name + payload -> name, tbl
function M.decode(name_or_id, payload)
    local name = name_or_id
    if type(name_or_id) == "number" then
        name = CmdCode.name(name_or_id)
    end
    if not name or not payload then return nil end
    return name, pb.decode(name, payload)
end

--- 写一帧到 fd：msg_name (string), data (table)
function M.write_frame(fd, msg_name, data)
    local cid = CmdCode[msg_name]
    if not cid then return false end
    local payload = M.encode(msg_name, data)
    local frame = M.pack_frame(cid, payload)
    return socket.write(fd, frame)
end

--- 按消息名取 CmdCode id
function M.cmd_id(name)
    return CmdCode[name]
end

M.CmdCode = CmdCode

return M
