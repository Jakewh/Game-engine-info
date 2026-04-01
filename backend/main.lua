local logger = require("logger")
local millennium = require("millennium")
local http = require("http")
local json = require("json")
local settings = require("settings")

local TIMEOUT = 10

local function trim(value)
    if not value then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function url_encode(str)
    return (str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function split_csv(value)
    local result = {}
    for part in value:gmatch("[^,]+") do
        table.insert(result, trim(part))
    end
    return result
end

-- ---------------------------------------------------------------------------
-- PCGamingWiki
-- ---------------------------------------------------------------------------

local function fetch_engine_from_pcgw(appid)
    local where = 'Steam_AppID HOLDS "' .. tostring(appid) .. '"'
    local params = {
        "action=cargoquery",
        "format=json",
        "tables=Infobox_game",
        "fields=Engines,Steam_AppID",
        "where=" .. url_encode(where)
    }
    local url = "https://www.pcgamingwiki.com/w/api.php?" .. table.concat(params, "&")
    local response, err = http.get(url, { timeout = TIMEOUT })

    if not response then return nil, err or "request failed" end
    if response.status ~= 200 then return nil, "HTTP " .. tostring(response.status) end

    local ok, payload = pcall(json.decode, response.body)
    if not ok or not payload then return nil, "Invalid JSON from PCGamingWiki" end
    if type(payload.cargoquery) ~= "table" or #payload.cargoquery == 0 then
        return nil, "No PCGamingWiki data"
    end

    local title = payload.cargoquery[1].title or {}
    local engines_raw = title.Engines
    if type(engines_raw) ~= "string" or engines_raw == "" then
        return nil, "No engine in PCGamingWiki payload"
    end

    local cleaned = {}
    for _, part in ipairs(split_csv(engines_raw)) do
        local value = part:gsub("^%s*[Ee]ngine:%s*", "")
        value = trim(value)
        if value ~= "" then table.insert(cleaned, value) end
    end

    if #cleaned == 0 then return nil, "Engine parsing produced no values" end
    return table.concat(cleaned, ", "), "pcgamingwiki"
end

-- ---------------------------------------------------------------------------
-- RAWG.io
-- ---------------------------------------------------------------------------

local function get_game_name_from_steam(appid)
    local url = "https://store.steampowered.com/api/appdetails?appids=" .. tostring(appid) .. "&filters=basic"
    local response, err = http.get(url, { timeout = TIMEOUT })
    if not response then return nil, "Steam API request failed: " .. tostring(err or "unknown") end
    if response.status ~= 200 then return nil, "Steam API HTTP " .. tostring(response.status) end

    local ok, data = pcall(json.decode, response.body)
    if not ok or type(data) ~= "table" then return nil, "Invalid JSON from Steam API" end

    local app = data[tostring(appid)]
    if not app or not app.success or type(app.data) ~= "table" then
        return nil, "App not found in Steam API"
    end

    local name = app.data.name
    if type(name) ~= "string" or name == "" then return nil, "No name in Steam API" end
    return name, nil
end

local function fetch_engine_from_rawg(appid, api_key)
    if not api_key or trim(api_key) == "" then
        return nil, "No RAWG API key configured"
    end
    api_key = trim(api_key)

    -- Step 1: Get game name from Steam
    local name, err = get_game_name_from_steam(appid)
    if not name then
        logger:warn("RAWG: Could not get game name for " .. tostring(appid) .. ": " .. tostring(err))
        return nil, "Could not get game name: " .. tostring(err)
    end

    -- Step 2: Search RAWG (filter by Steam store = stores=1)
    local search_url = "https://api.rawg.io/api/games"
        .. "?key=" .. url_encode(api_key)
        .. "&search=" .. url_encode(name)
        .. "&stores=1&page_size=5"

    local search_response, serr = http.get(search_url, { timeout = TIMEOUT })
    if not search_response then
        return nil, "RAWG search failed: " .. tostring(serr or "unknown")
    end
    if search_response.status ~= 200 then
        return nil, "RAWG search HTTP " .. tostring(search_response.status)
    end

    local ok2, search_data = pcall(json.decode, search_response.body)
    if not ok2 or type(search_data) ~= "table" or type(search_data.results) ~= "table" then
        return nil, "Invalid RAWG search response"
    end
    if #search_data.results == 0 then
        return nil, "No RAWG results for: " .. tostring(name)
    end

    local rawg_id = search_data.results[1].id
    if not rawg_id then return nil, "No RAWG game ID in results" end

    -- Step 3: Get game details for engine info
    local detail_url = "https://api.rawg.io/api/games/" .. tostring(rawg_id)
        .. "?key=" .. url_encode(api_key)

    local detail_response, derr = http.get(detail_url, { timeout = TIMEOUT })
    if not detail_response then
        return nil, "RAWG detail failed: " .. tostring(derr or "unknown")
    end
    if detail_response.status ~= 200 then
        return nil, "RAWG detail HTTP " .. tostring(detail_response.status)
    end

    local ok3, detail = pcall(json.decode, detail_response.body)
    if not ok3 or type(detail) ~= "table" then
        return nil, "Invalid RAWG detail response"
    end

    if type(detail.game_engines) == "table" and #detail.game_engines > 0 then
        local engines = {}
        for _, e in ipairs(detail.game_engines) do
            if type(e.name) == "string" and e.name ~= "" then
                table.insert(engines, e.name)
            end
        end
        if #engines > 0 then
            return table.concat(engines, ", "), "rawg"
        end
    end

    return nil, "No engine data in RAWG for: " .. tostring(name)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function GetEngine(appid, contentScriptQuery)
    local numeric_appid = tonumber(appid)
    if not numeric_appid then
        return json.encode({ success = false, error = "Invalid appid" })
    end

    logger:info("GetEngine request for appid " .. tostring(numeric_appid))

    local ok, result = pcall(function()
        -- 1. PCGamingWiki
        local engine, err = fetch_engine_from_pcgw(numeric_appid)
        if engine then
            logger:info("GetEngine PCGW success for " .. tostring(numeric_appid) .. ": " .. tostring(engine))
            return json.encode({ success = true, engine = engine, source = "pcgamingwiki" })
        end
        logger:info("GetEngine PCGW miss for " .. tostring(numeric_appid) .. ": " .. tostring(err))

        -- 2. RAWG fallback (only if API key configured)
        local cfg = settings.load()
        local rawg_engine, rawg_err = fetch_engine_from_rawg(numeric_appid, cfg.rawg_api_key)
        if rawg_engine then
            logger:info("GetEngine RAWG success for " .. tostring(numeric_appid) .. ": " .. tostring(rawg_engine))
            return json.encode({ success = true, engine = rawg_engine, source = "rawg" })
        end
        logger:info("GetEngine RAWG miss for " .. tostring(numeric_appid) .. ": " .. tostring(rawg_err))

        logger:warn("GetEngine not found for " .. tostring(numeric_appid))
        return json.encode({ success = false, error = "Engine not found" })
    end)

    if not ok then
        logger:error("GetEngine failed: " .. tostring(result))
        return json.encode({ success = false, error = tostring(result) })
    end
    return result
end

function GetSettings()
    local ok, result = pcall(function()
        local current = settings.load()
        return json.encode({ success = true, data = current })
    end)
    if not ok then
        logger:error("GetSettings error: " .. tostring(result))
        return json.encode({ success = false, error = tostring(result) })
    end
    return result
end

function SaveSettings(settings_json)
    local ok, result = pcall(function()
        local parsed = json.decode(settings_json)
        if type(parsed) ~= "table" then
            return json.encode({ success = false, error = "Invalid settings JSON" })
        end
        local merged = settings.merge_defaults(parsed)
        if not settings.save(merged) then
            return json.encode({ success = false, error = "Failed to write settings file" })
        end
        return json.encode({ success = true })
    end)
    if not ok then
        logger:error("SaveSettings error: " .. tostring(result))
        return json.encode({ success = false, error = tostring(result) })
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function on_load()
    logger:info("game-engine-info Lua backend loaded")
    millennium.ready()
end

local function on_frontend_loaded()
    logger:info("game-engine-info frontend loaded")
end

local function on_unload()
    logger:info("game-engine-info Lua backend unloaded")
end

return {
    on_load = on_load,
    on_frontend_loaded = on_frontend_loaded,
    on_unload = on_unload,
    GetEngine = GetEngine,
    GetSettings = GetSettings,
    SaveSettings = SaveSettings,
}
