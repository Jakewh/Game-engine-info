local json = require("json")
local logger = require("logger")
local millennium = require("millennium")

local M = {}

M.DEFAULTS = {
    rawg_api_key = "",
}

local function get_settings_path()
    return millennium.get_install_path() .. "/settings.json"
end

function M.load()
    local path = get_settings_path()
    local file = io.open(path, "r")
    if not file then
        return M.merge_defaults({})
    end
    local content = file:read("*a")
    file:close()
    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        return M.merge_defaults({})
    end
    return M.merge_defaults(parsed)
end

function M.save(s)
    local path = get_settings_path()
    local file, err = io.open(path, "w")
    if not file then
        logger:error("Failed to write settings: " .. (err or "unknown"))
        return false
    end
    file:write(json.encode(s))
    file:close()
    return true
end

function M.merge_defaults(s)
    local result = {}
    for k, v in pairs(M.DEFAULTS) do
        if s[k] ~= nil then
            result[k] = s[k]
        else
            result[k] = v
        end
    end
    return result
end

return M
