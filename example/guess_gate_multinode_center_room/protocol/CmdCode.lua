--- 消息名 <-> 数字 ID 映射，用于二进制帧（可选）.
--- 与 guess.proto 中的消息名一致。
local CmdCode = {
    -- C2S
    C2SReady = 1,
    C2SAttachRoom = 2,
    C2SGuess = 3,
    -- S2C
    S2CNotify = 101,
    S2CMatchOk = 102,
    S2CGuessRange = 103,
    S2CGameOver = 104,
}

local id_to_name = {}
for name, id in pairs(CmdCode) do
    id_to_name[id] = name
end

function CmdCode.name(id)
    return id_to_name[id]
end

return CmdCode
