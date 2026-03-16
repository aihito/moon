--- Room node: room/battle only. Listens RPC from Center (create_room) and game servers (attach_room, guess).
--- See docs/game_server_gate_multinode.md §6.6.
if _G["__init__"] then
    return { thread = 3, enable_stdout = true }
end

local moon = require("moon")

moon.async(function()
    local id = moon.new_service({ unique = true, name = "room_node", file = "service_room_node.lua" })
    if id == 0 then
        moon.exit(-1)
        return
    end
    moon.sleep(100)
    moon.send("lua", id, "start")
end)
