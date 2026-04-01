local logger = require("logger")
local millennium = require("millennium")
local http = require("http")
local json = require("json")

local TIMEOUT = 10

local function trim(value)
    if not value then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_html(value)
    if not value then
        return ""
    end
    local normalized = value:gsub("<[^>]->", " ")
    normalized = normalized:gsub("%s+", " ")
    return trim(normalized)
end

local function is_challenge_page(html)
    local lowered = html:lower()
    return lowered:find("just a moment", 1, true)
        or lowered:find("cf%-mitigated", 1, true)
        or lowered:find("captcha", 1, true)
end

local function parse_engine_from_steamdb(html)
    if not html or html == "" then
        return nil
    end

    if is_challenge_page(html) then
        return nil
    end

    local cell = html:match("[Gg]ame%s*[Ee]ngine%s*</th>%s*<td[^>]->(.-)</td>")
    if not cell then
        cell = html:match("[Ee]ngine%s*</th>%s*<td[^>]->(.-)</td>")
    end
    if cell then
        local parsed = strip_html(cell)
        if parsed ~= "" then
            return parsed
        end
    end

    local plain = html:match("\n%s*[Ee]ngine%s*\n%s*([^\n]+)")
    if plain then
        plain = trim(plain)
        if plain ~= "" and plain:lower() ~= "n/a" and plain:lower() ~= "unknown" and plain:lower() ~= "none" then
            return plain
        end
    end

    return nil
end

local function steamdb_request(url)
    local response, err = http.get(url, {
        timeout = TIMEOUT,
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123 Safari/537.36"
        }
    })

    if not response then
        return nil, err or "request failed"
    end

    if response.status ~= 200 then
        return nil, "HTTP " .. tostring(response.status)
    end

    return response.body, nil
end

local function fetch_engine_from_steamdb(appid)
    local urls = {
        "https://steamdb.info/app/" .. tostring(appid) .. "/tech/",
        "https://steamdb.info/app/" .. tostring(appid) .. "/info/",
        "https://steamdb.info/app/" .. tostring(appid) .. "/"
    }

    for _, url in ipairs(urls) do
        local body, err = steamdb_request(url)
        if body then
            local engine = parse_engine_from_steamdb(body)
            if engine then
                return engine, "steamdb"
            end
        else
            logger:warn("SteamDB request failed for " .. url .. ": " .. tostring(err))
        end
    end

    return nil, "SteamDB engine not found"
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

    if not response then
        return nil, err or "request failed"
    end

    if response.status ~= 200 then
        return nil, "HTTP " .. tostring(response.status)
    end

    local ok, payload = pcall(json.decode, response.body)
    if not ok or not payload then
        return nil, "Invalid JSON from PCGamingWiki"
    end

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
        if value ~= "" then
            table.insert(cleaned, value)
        end
    end

    if #cleaned == 0 then
        return nil, "Engine parsing produced no values"
    end

    return table.concat(cleaned, ", "), "pcgamingwiki"
end

function GetEngine(appid, contentScriptQuery)
    local numeric_appid = tonumber(appid)
    if not numeric_appid then
        return json.encode({ success = false, error = "Invalid appid" })
    end

    local ok, result = pcall(function()
        local engine, source_or_error = fetch_engine_from_steamdb(numeric_appid)
        if engine then
            return json.encode({ success = true, engine = engine, source = source_or_error })
        end

        local fallback_engine, fallback_source_or_error = fetch_engine_from_pcgw(numeric_appid)
        if fallback_engine then
            return json.encode({ success = true, engine = fallback_engine, source = fallback_source_or_error })
        end

        return json.encode({
            success = false,
            error = "Engine not found",
            details = {
                steamdb = source_or_error,
                pcgamingwiki = fallback_source_or_error
            }
        })
    end)

    if not ok then
        logger:error("GetEngine failed: " .. tostring(result))
        return json.encode({ success = false, error = tostring(result) })
    end

    return result
end

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
    on_unload = on_unload
}
