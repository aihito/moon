#!/usr/bin/env lua
--- 将 .proto 编译为 .pb 二进制（FileDescriptorSet），供 pb.loadfile() 使用。
--- 用法（在仓库根目录执行）:
---   ./target/debug/moon example/guess_gate_multinode_center_room/tools/gen_proto.lua
---   ./target/debug/moon example/guess_gate_multinode_center_room/tools/gen_proto.lua protocol/proto/guess.proto
---
--- 若不传参数，默认编译 protocol/proto/guess.proto，输出 protocol/guess.pb

-- 确保能从仓库根目录找到 lualib（pb 为 C 库内置，protoc 在 lualib）
local repo_root = os.getenv("MOON_REPO_ROOT") or (os.getenv("PWD") or ".")
if not package.path:match("lualib") then
    package.path = repo_root .. "/lualib/?.lua;" .. package.path
end

local pb = require("pb")
local protoc = require("protoc")
local moon = require("moon")

local function compile_proto(proto_path, out_path)
    local root = os.getenv("MOON_REPO_ROOT") or os.getenv("PWD") or "."
    local full_path = proto_path
    if not full_path:match("^/") and not full_path:match("^%a:") then
        full_path = root .. "/" .. proto_path
    end
    local f = io.open(full_path, "r")
    if not f then
        io.stderr:write("gen_proto: cannot open ", full_path, "\n")
        os.exit(1)
    end
    f:close()

    local parser = protoc.new()
    local binary = parser:compilefile(full_path)
    if not binary then
        io.stderr:write("gen_proto: compile failed for ", proto_path, "\n")
        os.exit(1)
    end

    local out = out_path or (proto_path:gsub("%.proto$", ".pb"):gsub("^.*/protocol/proto/", "protocol/"))
    if not out:match("^/") and not out:match("^%a:") then
        out = root .. "/" .. out
    end
    local dir = out:match("^(.+)/[^/]+$")
    if dir then
        os.execute("mkdir -p " .. dir)
    end
    local of = assert(io.open(out, "wb"))
    of:write(binary)
    of:close()
    print("gen_proto: wrote ", out)
end

local repo_root = os.getenv("MOON_REPO_ROOT") or (os.getenv("PWD") or ".")
local prefix = "example/guess_gate_multinode_center_room"
local argv = type(arg) == "table" and arg or {}
local proto_path = argv[1] or (prefix .. "/protocol/proto/guess.proto")
local out_path = argv[2]

-- 默认输出：protocol/guess.pb（相对仓库根或相对当前目录）
if not out_path then
    out_path = proto_path:gsub("%.proto$", ".pb")
    out_path = out_path:gsub("^.*/protocol/proto/", prefix .. "/protocol/")
end

compile_proto(proto_path, out_path)

-- local moon = package.loaded.moon
if moon and moon.quit then
    moon.async(function()
        moon.sleep(1000)
        moon.quit()
    end)
end
