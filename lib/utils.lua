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

local function check_grid_device(grid_device)
    if grid_device ~= nil then
        local device_name = grid_device.name or "Unknown"
        local device_rows = grid_device.rows or 0
        local device_cols = grid_device.cols or 0

        print("Grid device connected:")
        print("Name: " .. device_name)
        print("Rows: " .. device_rows)
        print("Cols: " .. device_cols)

        -- Adjust script behavior based on the grid size if necessary
        if device_rows == 8 and device_cols == 16 then
            print("8x16 grid detected. Adjusting layout.")
            -- Modify any layout or behavior specific to an 8x16 grid
        elseif device_rows == 16 and device_cols == 16 then
            print("16x16 grid detected.")
            -- Modify any layout or behavior specific to a 16x16 grid
        else
            print("Custom grid size detected.")
            -- Handle custom grid sizes
        end

        return device_rows -- Return the number of rows
    else
        print("No grid device connected.")
        return 0 -- Return 0 if no grid is connected
    end
end


return {
    deserialize_table = deserialize_table,
    serialize_table = serialize_table,
    check_grid_device = check_grid_device
}
