-- utils.lua

-- Table Serializer/Deserializer
local function deserialize_table(serialized)
    local func, err = load("return " .. serialized)
    if func then
        local success, result = pcall(func)
        if success then
            return result
        else
            error("Error deserializing table: " .. result)
        end
    else
        error("Error loading serialized string: " .. err)
    end
end

local function serialize_table(t)
    local serialized = "{"
    for key, value in pairs(t) do
        if type(key) == "number" then
            serialized = serialized .. "[" .. tostring(key) .. "]="
        else
            serialized = serialized .. "['" .. tostring(key) .. "']="
        end

        if type(value) == "table" then
            serialized = serialized .. serialize_table(value)
        elseif type(value) == "number" then
            serialized = serialized .. value
        elseif type(value) == "string" then
            serialized = serialized .. "\"" .. value .. "\""
        elseif type(value) == "boolean" then
            serialized = serialized .. tostring(value)
        end

        serialized = serialized .. ","
    end
    serialized = serialized .. "}"
    return serialized
end

return {
    deserialize_table = deserialize_table,
    serialize_table = serialize_table
}
