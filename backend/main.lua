local logger = require("logger")
local millennium = require("millennium")
local http = require("http")
local json = require("json")
local settings = require("settings")
local io = require("io")
local os = require("os")
local has_lfs, lfs = pcall(require, "lfs")
if not has_lfs then
    lfs = nil
end

local TIMEOUT = 10
local get_game_name_from_steam

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

local function escape_cargo_string(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    return s
end

local function html_decode(value)
    if type(value) ~= "string" then return "" end

    local decoded = value
    decoded = decoded:gsub("&nbsp;", " ")
    decoded = decoded:gsub("&quot;", '"')
    decoded = decoded:gsub("&apos;", "'")
    decoded = decoded:gsub("&lt;", "<")
    decoded = decoded:gsub("&gt;", ">")
    decoded = decoded:gsub("&#x([%da-fA-F]+);", function(hex)
        local num = tonumber(hex, 16)
        return num and string.char(num) or ""
    end)
    decoded = decoded:gsub("&#(%d+);", function(num)
        local n = tonumber(num)
        return n and string.char(n) or ""
    end)
    decoded = decoded:gsub("&amp;", "&")

    return decoded
end

local function strip_html(value)
    if type(value) ~= "string" then return "" end
    local plain = value:gsub("<br%s*/?>", ", ")
    plain = plain:gsub("<.->", " ")
    plain = html_decode(plain)
    plain = plain:gsub("%s+", " ")
    return trim(plain)
end

local function build_browser_headers(cookie_value)
    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
    }

    local cookie_trimmed = trim(cookie_value or "")
    if cookie_trimmed ~= "" then
        headers["Cookie"] = cookie_trimmed
    end

    return headers
end

local KNOWN_ENGINES = {
    { key = "unreal engine 5", label = "Unreal Engine 5" },
    { key = "unreal engine 4", label = "Unreal Engine 4" },
    { key = "unreal engine", label = "Unreal Engine" },
    { key = "unity", label = "Unity" },
    { key = "godot", label = "Godot" },
    { key = "source 2", label = "Source 2" },
    { key = "source engine", label = "Source" },
    { key = "frostbite", label = "Frostbite" },
    { key = "cryengine", label = "CryEngine" },
    { key = "id tech", label = "id Tech" },
    { key = "creation engine", label = "Creation Engine" },
    { key = "love2d", label = "LÖVE" },
    { key = "l\195\150ve", label = "LÖVE" },
    { key = "l\195\182ve", label = "LÖVE" },
    { key = "l\195\150ve2d", label = "LÖVE" },
    { key = "l\195\182ve2d", label = "LÖVE" },
    { key = "game maker", label = "GameMaker" },
    { key = "gamemaker", label = "GameMaker" },
    { key = "ren'py", label = "Ren'Py" },
    { key = "renpy", label = "Ren'Py" },
}

local function find_known_engine_in_text(text)
    if type(text) ~= "string" or text == "" then return nil end
    local lower = text:lower()
    for _, engine in ipairs(KNOWN_ENGINES) do
        if lower:find(engine.key, 1, true) then
            return engine.label
        end
    end
    return nil
end

local function sanitize_engine_result(value)
    if type(value) ~= "string" then return nil end

    local raw = trim(strip_html(value))
    if raw == "" then return nil end

    local canonical = find_known_engine_in_text(raw)
    if canonical then return canonical end

    local lower = raw:lower()

    -- Drop common non-engine metadata that sometimes leaks from external payloads.
    if lower:find("platform", 1, true)
        or lower:find("windows", 1, true)
        or lower:find("linux", 1, true)
        or lower:find("mac", 1, true)
        or lower:find("release", 1, true)
        or lower:find("genre", 1, true)
        or lower:find("developer", 1, true)
        or lower:find("publisher", 1, true)
        or lower:find("website", 1, true)
        or lower:find("https://", 1, true)
        or lower:find("http://", 1, true)
        or raw:find("=", 1, true)
    then
        return nil
    end

    if #raw > 80 then return nil end
    return raw
end

local function normalize_lookup_text(value)
    local s = trim(value or ""):lower()
    s = s:gsub("[^%w]", "")
    return s
end

local function pick_best_wikidata_game(results, game_name)
    if type(results) ~= "table" or #results == 0 then return nil end
    local target = normalize_lookup_text(game_name)

    local best = nil
    local best_score = -1
    for _, item in ipairs(results) do
        local label = trim(item.label or "")
        local normalized = normalize_lookup_text(label)
        local score = 0

        if normalized ~= "" and normalized == target then
            score = 100
        elseif normalized ~= "" and target ~= "" and (normalized:find(target, 1, true) or target:find(normalized, 1, true)) then
            score = 60
        elseif trim(item.description or ""):lower():find("video game", 1, true)
            or trim(item.description or ""):lower():find("computer game", 1, true) then
            score = 30
        end

        if score > best_score then
            best_score = score
            best = item
        end
    end

    return best
end

local function fetch_engine_from_wikidata(game_name)
    local name = trim(game_name or "")
    if name == "" then
        return nil, "No game name for Wikidata lookup"
    end

    local search_url = "https://www.wikidata.org/w/api.php"
        .. "?action=wbsearchentities"
        .. "&format=json"
        .. "&language=en"
        .. "&type=item"
        .. "&limit=5"
        .. "&search=" .. url_encode(name)

    local search_response, serr = http.get(search_url, { timeout = TIMEOUT })
    if not search_response then
        return nil, "Wikidata search failed: " .. tostring(serr or "unknown")
    end
    if search_response.status ~= 200 then
        return nil, "Wikidata search HTTP " .. tostring(search_response.status)
    end

    local ok1, search_payload = pcall(json.decode, search_response.body)
    if not ok1 or type(search_payload) ~= "table" or type(search_payload.search) ~= "table" then
        return nil, "Invalid Wikidata search payload"
    end

    local best_game = pick_best_wikidata_game(search_payload.search, name)
    if not best_game or type(best_game.id) ~= "string" then
        return nil, "No Wikidata game entity"
    end

    local game_entity_url = "https://www.wikidata.org/w/api.php"
        .. "?action=wbgetentities"
        .. "&format=json"
        .. "&ids=" .. url_encode(best_game.id)
        .. "&props=claims"

    local game_response, gerr = http.get(game_entity_url, { timeout = TIMEOUT })
    if not game_response then
        return nil, "Wikidata entity failed: " .. tostring(gerr or "unknown")
    end
    if game_response.status ~= 200 then
        return nil, "Wikidata entity HTTP " .. tostring(game_response.status)
    end

    local ok2, game_payload = pcall(json.decode, game_response.body)
    if not ok2 or type(game_payload) ~= "table" or type(game_payload.entities) ~= "table" then
        return nil, "Invalid Wikidata entity payload"
    end

    local entity = game_payload.entities[best_game.id]
    if type(entity) ~= "table" or type(entity.claims) ~= "table" or type(entity.claims.P408) ~= "table" then
        return nil, "No engine claim in Wikidata"
    end

    local engine_ids = {}
    local seen = {}
    for _, claim in ipairs(entity.claims.P408) do
        local id = claim and claim.mainsnak and claim.mainsnak.datavalue and claim.mainsnak.datavalue.value and claim.mainsnak.datavalue.value.id
        if type(id) == "string" and id ~= "" and not seen[id] then
            seen[id] = true
            table.insert(engine_ids, id)
        end
    end

    if #engine_ids == 0 then
        return nil, "No engine claim values in Wikidata"
    end

    local engines_url = "https://www.wikidata.org/w/api.php"
        .. "?action=wbgetentities"
        .. "&format=json"
        .. "&ids=" .. url_encode(table.concat(engine_ids, "|"))
        .. "&props=labels"
        .. "&languages=en"

    local engines_response, eerr = http.get(engines_url, { timeout = TIMEOUT })
    if not engines_response then
        return nil, "Wikidata engine labels failed: " .. tostring(eerr or "unknown")
    end
    if engines_response.status ~= 200 then
        return nil, "Wikidata engine labels HTTP " .. tostring(engines_response.status)
    end

    local ok3, engines_payload = pcall(json.decode, engines_response.body)
    if not ok3 or type(engines_payload) ~= "table" or type(engines_payload.entities) ~= "table" then
        return nil, "Invalid Wikidata engine labels payload"
    end

    local labels = {}
    for _, eid in ipairs(engine_ids) do
        local row = engines_payload.entities[eid]
        local label = row and row.labels and row.labels.en and row.labels.en.value
        if type(label) == "string" and trim(label) ~= "" then
            table.insert(labels, trim(label))
        end
    end

    if #labels == 0 then
        return nil, "No engine labels in Wikidata"
    end

    return table.concat(labels, ", "), "wikidata"
end

local function parse_wikipedia_engine_from_wikitext(wikitext)
    if type(wikitext) ~= "string" or wikitext == "" then return nil end

    local value = wikitext:match("\n|%s*[Ee]ngine%s*=%s*([^\n\r]+)")
    if not value then return nil end

    value = value:gsub("<ref[^>]*>.-</ref>", "")
    value = value:gsub("<ref[^/]*/>", "")
    value = value:gsub("{{[^{}]-}}", "")
    value = value:gsub("%[%[([^%]|]+)|([^%]]+)%]%]", "%2")
    value = value:gsub("%[%[([^%]]+)%]%]", "%1")
    value = value:gsub("<.->", " ")
    value = value:gsub("&nbsp;", " ")
    value = value:gsub("''", "")
    value = value:gsub("%s+", " ")
    value = trim(value)

    if value == "" then return nil end
    return value
end

local function fetch_wikipedia_wikitext_by_title(title)
    local url = "https://en.wikipedia.org/w/api.php"
        .. "?action=query"
        .. "&format=json"
        .. "&prop=revisions"
        .. "&rvprop=content"
        .. "&rvslots=main"
        .. "&formatversion=2"
        .. "&titles=" .. url_encode(title)

    local response, err = http.get(url, { timeout = TIMEOUT })
    if not response then return nil, "Wikipedia page failed: " .. tostring(err or "unknown") end
    if response.status ~= 200 then return nil, "Wikipedia page HTTP " .. tostring(response.status) end

    local ok, payload = pcall(json.decode, response.body)
    if not ok or type(payload) ~= "table" then return nil, "Invalid Wikipedia payload" end

    local pages = payload.query and payload.query.pages
    if type(pages) ~= "table" or #pages == 0 then return nil, "No Wikipedia page" end

    local first = pages[1]
    local revs = first and first.revisions
    local content = revs and revs[1] and revs[1].slots and revs[1].slots.main and revs[1].slots.main.content
    if type(content) ~= "string" or content == "" then
        return nil, "No Wikipedia wikitext"
    end

    return content, nil
end

local function fetch_engine_from_wikipedia(game_name)
    local name = trim(game_name or "")
    if name == "" then
        return nil, "No game name for Wikipedia lookup"
    end

    local queries = {
        name .. " (video game)",
        name,
    }

    local tested_titles = {}
    local seen = {}
    local function add_title(title)
        local t = trim(title or "")
        if t ~= "" and not seen[t] then
            seen[t] = true
            table.insert(tested_titles, t)
        end
    end

    for _, q in ipairs(queries) do
        local opensearch_url = "https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=5&search=" .. url_encode(q)
        local response = http.get(opensearch_url, { timeout = TIMEOUT })
        if response and response.status == 200 then
            local ok, payload = pcall(json.decode, response.body)
            if ok and type(payload) == "table" and type(payload[2]) == "table" then
                for _, title in ipairs(payload[2]) do
                    add_title(title)
                end
            end
        end
    end

    if #tested_titles == 0 then
        return nil, "No Wikipedia title candidates"
    end

    local last_error = "No Wikipedia engine field"
    for _, title in ipairs(tested_titles) do
        local wikitext, err = fetch_wikipedia_wikitext_by_title(title)
        if wikitext then
            local engine = parse_wikipedia_engine_from_wikitext(wikitext)
            if engine then
                return engine, "wikipedia"
            end
            last_error = "No Wikipedia engine field"
        else
            last_error = err or last_error
        end
    end

    return nil, last_error
end

local function looks_like_search_host(url)
    if type(url) ~= "string" then return true end
    local lower = url:lower()
    return lower:find("bing.com", 1, true)
        or lower:find("search.brave.com", 1, true)
        or lower:find("duckduckgo.com", 1, true)
        or lower:find("google.com", 1, true)
        or lower:find("steamdb.info", 1, true)
        or lower:find("r.bing.com", 1, true)
        or lower:find("imgs.search.brave.com", 1, true)
end

local function extract_candidate_urls(search_html)
    local urls = {}
    local seen = {}
    if type(search_html) ~= "string" then return urls end

    for href in search_html:gmatch('href="(https?://[^"]+)"') do
        local cleaned = html_decode(href):gsub("&amp;", "&")
        if not looks_like_search_host(cleaned) and not seen[cleaned] then
            seen[cleaned] = true
            table.insert(urls, cleaned)
        end
        if #urls >= 8 then
            break
        end
    end

    return urls
end

local function page_mentions_game(text, game_name)
    if type(text) ~= "string" or type(game_name) ~= "string" then return false end
    local lower_text = text:lower()
    local lower_name = game_name:lower()

    if lower_name ~= "" and lower_text:find(lower_name, 1, true) then
        return true
    end

    local hits = 0
    for token in lower_name:gmatch("[%w']+") do
        if #token >= 5 and lower_text:find(token, 1, true) then
            hits = hits + 1
        end
    end
    return hits >= 2
end

local function fetch_engine_from_web_search(game_name)
    local name = trim(game_name or "")
    if name == "" then
        return nil, "No game name for web search"
    end

    local queries = {
        '"' .. name .. '" game engine',
        name .. " engine used",
    }

    local headers = build_browser_headers(nil)
    local last_error = "No web search provider succeeded"

    for _, query in ipairs(queries) do
        logger:info("WebSearch query: " .. query)
        local providers = {
            "https://search.brave.com/search?q=" .. url_encode(query) .. "&source=web",
            "https://www.bing.com/search?q=" .. url_encode(query),
        }

        for _, search_url in ipairs(providers) do
            local response, rerr = http.get(search_url, { timeout = TIMEOUT, headers = headers })
            if response and response.status == 200 and type(response.body) == "string" then
                local raw = response.body
                local plain = strip_html(raw)
                local found = find_known_engine_in_text(raw) or find_known_engine_in_text(plain)
                if found then
                    return found, "websearch"
                end

                local urls = extract_candidate_urls(raw)
                for i = 1, math.min(4, #urls) do
                    local url = urls[i]
                    local page_response = http.get(url, { timeout = TIMEOUT, headers = headers })
                    if page_response and page_response.status == 200 and type(page_response.body) == "string" then
                        local page_plain = strip_html(page_response.body)
                        if page_mentions_game(page_plain, name) then
                            local page_engine = find_known_engine_in_text(page_response.body)
                                or find_known_engine_in_text(page_plain)
                            if page_engine then
                                return page_engine, "websearch"
                            end
                        end
                    end
                end

                last_error = "No known engine keyword in web results"
            else
                if response then
                    last_error = "Web search HTTP " .. tostring(response.status)
                else
                    last_error = "Web search failed: " .. tostring(rerr or "unknown")
                end
            end
        end
    end

    return nil, last_error
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

local function parse_engines_from_pcgw_payload(payload)
    if type(payload) ~= "table" or type(payload.cargoquery) ~= "table" then
        return nil, "Invalid PCGamingWiki payload"
    end
    if #payload.cargoquery == 0 then
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
    return table.concat(cleaned, ", "), nil
end

local function resolve_pcgw_page_titles(game_name)
    local name = trim(game_name or "")
    if name == "" then return {} end

    local titles = {}
    local seen = {}

    local function add_title(value)
        local t = trim(value or "")
        if t ~= "" and not seen[t] then
            seen[t] = true
            table.insert(titles, t)
        end
    end

    add_title(name)

    local opensearch_url = "https://www.pcgamingwiki.com/w/api.php?action=opensearch&format=json&limit=5&search=" .. url_encode(name)
    local oresp = http.get(opensearch_url, { timeout = TIMEOUT })
    if oresp and oresp.status == 200 then
        local ok, data = pcall(json.decode, oresp.body)
        if ok and type(data) == "table" and type(data[2]) == "table" then
            for _, title in ipairs(data[2]) do
                add_title(title)
            end
        end
    end

    local search_url = "https://www.pcgamingwiki.com/w/api.php?action=query&list=search&format=json&srlimit=5&srsearch=" .. url_encode(name)
    local sresp = http.get(search_url, { timeout = TIMEOUT })
    if sresp and sresp.status == 200 then
        local ok, data = pcall(json.decode, sresp.body)
        if ok and type(data) == "table" and type(data.query) == "table" and type(data.query.search) == "table" then
            for _, row in ipairs(data.query.search) do
                add_title(row.title)
            end
        end
    end

    return titles
end

local function fetch_engine_from_pcgw_by_name(game_name)
    local name = trim(game_name or "")
    if name == "" then
        return nil, "No game name for PCGamingWiki name lookup"
    end

    local candidates = resolve_pcgw_page_titles(name)
    if #candidates == 0 then
        return nil, "No PCGamingWiki title candidates"
    end

    local last_error = "No PCGamingWiki data"
    for _, page_title in ipairs(candidates) do
        local escaped = escape_cargo_string(page_title)
        local where = '_pageName="' .. escaped .. '"'
        local params = {
            "action=cargoquery",
            "format=json",
            "tables=Infobox_game",
            "fields=Engines",
            "where=" .. url_encode(where),
            "limit=1"
        }

        local url = "https://www.pcgamingwiki.com/w/api.php?" .. table.concat(params, "&")
        local response, err = http.get(url, { timeout = TIMEOUT })
        if not response then
            last_error = err or "request failed"
        elseif response.status ~= 200 then
            last_error = "HTTP " .. tostring(response.status)
        else
            local ok, payload = pcall(json.decode, response.body)
            if not ok or not payload then
                last_error = "Invalid JSON from PCGamingWiki"
            else
                local engine, parse_err = parse_engines_from_pcgw_payload(payload)
                if engine then
                    return engine, "pcgamingwiki-name"
                end
                last_error = parse_err or last_error
            end
        end
    end

    if last_error == "Invalid PCGamingWiki payload" then
        last_error = "No PCGamingWiki data"
    end
    return nil, last_error
end

-- ---------------------------------------------------------------------------
-- Local Directory Detection
-- ---------------------------------------------------------------------------

local function dir_exists(path)
    if lfs and lfs.attributes then
        local a = lfs.attributes(path, "mode")
        return a == "directory"
    end

    local ok, _, code = os.rename(path, path)
    if ok then return true end
    if code == 13 then return true end
    return false
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function read_text_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function parse_installdir_from_appmanifest(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end

    local dir = content:match('"installdir"%s*"([^"]+)"')
    if type(dir) ~= "string" or trim(dir) == "" then
        return nil
    end

    return trim(dir)
end

local function collect_steam_library_roots()
    local home = os.getenv("HOME")

    local roots = {}
    local seen = {}

    local function add_root(path)
        local p = trim(path or "")
        if p == "" or seen[p] then return end
        seen[p] = true
        table.insert(roots, p)
    end

    -- Prefer Windows default Steam install locations first.
    local pf86 = os.getenv("PROGRAMFILES(X86)")
    local pf = os.getenv("PROGRAMFILES")
    if pf86 and pf86 ~= "" then
        add_root(pf86 .. "/Steam")
    end
    if pf and pf ~= "" then
        add_root(pf .. "/Steam")
    end

    -- Linux and Flatpak Steam locations.
    if home and home ~= "" then
        add_root(home .. "/.steam/steam")
        add_root(home .. "/.local/share/Steam")
        add_root(home .. "/.var/app/com.valvesoftware.Steam/data/Steam")
    end

    local function read_libraryfolders(steam_root)
        local vdf_path = steam_root .. "/steamapps/libraryfolders.vdf"
        local content = read_text_file(vdf_path)
        if type(content) ~= "string" or content == "" then
            return
        end

        for line in content:gmatch("[^\r\n]+") do
            local p = line:match('"path"%s*"([^"]+)"')
            if not p then
                -- Older formats may use numeric keys for library paths.
                p = line:match('"%d+"%s*"([^"]+)"')
            end

            if p then
                p = p:gsub("\\\\", "/")
                add_root(p)
            end
        end
    end

    -- Expand roots from each known Steam installation.
    local snapshot = {}
    for _, root in ipairs(roots) do table.insert(snapshot, root) end
    for _, root in ipairs(snapshot) do
        read_libraryfolders(root)
    end

    return roots
end

local function find_game_directory_by_appid(appid)
    local id = tostring(tonumber(appid) or "")
    if id == "" then return nil end

    local roots = collect_steam_library_roots()
    for _, root in ipairs(roots) do
        local steamapps = root .. "/steamapps"
        local manifest_path = steamapps .. "/appmanifest_" .. id .. ".acf"

        if file_exists(manifest_path) then
            local manifest = read_text_file(manifest_path)
            local install_dir_name = parse_installdir_from_appmanifest(manifest)
            if install_dir_name then
                local install_path = steamapps .. "/common/" .. install_dir_name
                if dir_exists(install_path) then
                    return install_path
                end
            end
        end
    end

    return nil
end

local function find_game_directory_in_steam_common(game_name)
    local home = os.getenv("HOME")
    local pf86 = os.getenv("PROGRAMFILES(X86)")
    local pf = os.getenv("PROGRAMFILES")
    
    -- Try multiple Steam library paths (Windows first, then Linux).
    local steam_paths = {}
    if pf86 and pf86 ~= "" then
        table.insert(steam_paths, pf86 .. "/Steam/steamapps/common")
    end
    if pf and pf ~= "" then
        table.insert(steam_paths, pf .. "/Steam/steamapps/common")
    end
    if home and home ~= "" then
        table.insert(steam_paths, home .. "/.steam/steam/steamapps/common")
        table.insert(steam_paths, home .. "/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common")
        table.insert(steam_paths, home .. "/.local/share/Steam/steamapps/common")
    end
    if #steam_paths == 0 then return nil end
    
    local normalized_game = (game_name or ""):lower():gsub("[^%w]", "")
    if normalized_game == "" then return nil end
    
    for _, base_path in ipairs(steam_paths) do
        if dir_exists(base_path) then
            if lfs and lfs.dir then
                for entry in lfs.dir(base_path) do
                    if entry ~= "." and entry ~= ".." then
                        local normalized_entry = entry:lower():gsub("[^%w]", "")
                        if normalized_entry == normalized_game or entry:lower() == game_name:lower() then
                            return base_path .. "/" .. entry
                        end
                    end
                end
            else
                -- Fallback when lfs.dir not available
                local possible = base_path .. "/" .. game_name
                if dir_exists(possible) then return possible end
            end
        end
    end
    
    return nil
end

local function detect_engine_from_game_directory(game_dir)
    if not game_dir or game_dir == "" then return nil end
    
    -- Unity detection
    if dir_exists(game_dir .. "/Assets") 
        or file_exists(game_dir .. "/UnityEngine.dll") 
        or file_exists(game_dir .. "/UnityPlayer.dll")
        or file_exists(game_dir .. "/UnityPlayer.so")
        or file_exists(game_dir .. "/UnityPlayer.dylib")
        or dir_exists(game_dir .. "/Data")
        or file_exists(game_dir .. "/game.exe") and (
            file_exists(game_dir .. "/Data/level1") 
            or file_exists(game_dir .. "/Data/level0")
            or dir_exists(game_dir .. "/Data/scenes")
        ) then
        return "Unity"
    end
    
    -- Unreal Engine detection
    if dir_exists(game_dir .. "/Binaries") and dir_exists(game_dir .. "/Content")
        or file_exists(game_dir .. "/Binaries/Win64/UE4Game.exe")
        or file_exists(game_dir .. "/Binaries/Win64/UE5Game.exe")
        or file_exists(game_dir .. "/Binaries/Linux/UE4Game")
        or dir_exists(game_dir .. "/Engine")
        or dir_exists(game_dir .. "/.uproject") then
        if file_exists(game_dir .. "/Binaries/Win64/UE5Game.exe") 
            or file_exists(game_dir .. "/Binaries/Win64/UnrealGame-Shipping.exe") and file_exists(game_dir .. "/Engine") 
            or file_exists(game_dir .. "/Binaries/Linux/UE5Game") then
            return "Unreal Engine 5"
        else
            return "Unreal Engine 4"
        end
    end
    
    -- Godot detection
    if file_exists(game_dir .. "/.godot/project.binary")
        or file_exists(game_dir .. "/export_presets.cfg")
        or file_exists(game_dir .. "/.godot/export_presets.cfg")
        or dir_exists(game_dir .. "/.godot/imported") then
        return "Godot"
    end
    
    -- Ren'Py detection
    if file_exists(game_dir .. "/renpy.py")
        or file_exists(game_dir .. "/lib/renpy.so")
        or dir_exists(game_dir .. "/renpy")
        or file_exists(game_dir .. "/game.rpyc") then
        return "Ren'Py"
    end
    
    -- GameMaker detection
    if file_exists(game_dir .. "/data.win")
        or file_exists(game_dir .. "/data.gm81")
        or file_exists(game_dir .. "/runner.exe") then
        return "GameMaker"
    end
    
    -- LÖVE detection
    if file_exists(game_dir .. "/game.love")
        or dir_exists(game_dir .. "/LÖVE")
        or dir_exists(game_dir .. "/love")
        or file_exists(game_dir .. "/main.lua") and (
            file_exists(game_dir .. "/conf.lua") 
            or dir_exists(game_dir .. "/res")
        ) then
        return "LÖVE"
    end
    
    -- CryEngine detection
    if dir_exists(game_dir .. "/Bin64") and dir_exists(game_dir .. "/Engine")
        or file_exists(game_dir .. "/Bin64/Game.exe") then
        return "CryEngine"
    end
    
    -- Source Engine detection
    if dir_exists(game_dir .. "/bin")
        and (dir_exists(game_dir .. "/csgo") or dir_exists(game_dir .. "/dota 2 beta") or dir_exists(game_dir .. "/tf"))
        or file_exists(game_dir .. "/GameInfo.txt")
        or dir_exists(game_dir .. "/tf/bin") then
        return "Source"
    end
    
    -- id Tech detection
    if file_exists(game_dir .. "/id1/progs.dat")
        or file_exists(game_dir .. "/base/pak0.pk3")
        or file_exists(game_dir .. "/base/pak1.pk3")
        or dir_exists(game_dir .. "/base") and file_exists(game_dir .. "/game_binaries.pk3") then
        return "id Tech"
    end
    
    return nil
end

local function fetch_engine_from_local_directory(appid, game_name)
    local name = trim(game_name or "")
    if name == "" then
        return nil, "No game name for local directory lookup"
    end

    local game_dir = find_game_directory_by_appid(appid)
    if game_dir then
        logger:info("Local directory resolved via appmanifest for " .. tostring(appid) .. ": " .. tostring(game_dir))
    end
    if not game_dir then
        game_dir = find_game_directory_in_steam_common(name)
        if game_dir then
            logger:info("Local directory resolved via name fallback for " .. tostring(name) .. ": " .. tostring(game_dir))
        end
    end

    if not game_dir then
        return nil, "Game directory not found in Steam library"
    end
    
    logger:info("Local directory found for " .. tostring(name) .. ": " .. tostring(game_dir))
    
    local detected = detect_engine_from_game_directory(game_dir)
    if not detected then
        return nil, "No engine signatures found in game directory"
    end
    
    return detected, "local-directory"
end

-- ---------------------------------------------------------------------------
-- SteamDB
-- ---------------------------------------------------------------------------

get_game_name_from_steam = function(appid)
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

local function try_get_steamdb_app_page(steamdb_appid, cfg)
    local app_url = "https://steamdb.info/app/" .. tostring(steamdb_appid) .. "/"
    local app_response, aerr = http.get(app_url, { timeout = TIMEOUT })

    if app_response and app_response.status == 403 then
        local with_headers = {
            timeout = TIMEOUT,
            headers = build_browser_headers(cfg and cfg.steamdb_cookie),
        }
        app_response, aerr = http.get(app_url, with_headers)
    end

    if not app_response then
        return nil, "SteamDB app page failed: " .. tostring(aerr or "unknown")
    end
    if app_response.status ~= 200 then
        if app_response.status == 403 then
            return nil, "SteamDB blocked by Cloudflare (HTTP 403)"
        end
        return nil, "SteamDB app page HTTP " .. tostring(app_response.status)
    end
    return app_response.body or "", nil
end

local function find_steamdb_appid_via_web_search(game_name, preferred_appid, cfg)
    local query = tostring(game_name or "") .. " site:steamdb.info/app"
    local search_url = "https://search.brave.com/search?q=" .. url_encode(query) .. "&source=web"

    local request_options = {
        timeout = TIMEOUT,
        headers = build_browser_headers(cfg and cfg.steamdb_cookie),
    }

    local response, err = http.get(search_url, request_options)
    if not response then
        return nil, "Web search failed: " .. tostring(err or "unknown")
    end
    if response.status ~= 200 then
        return nil, "Web search HTTP " .. tostring(response.status)
    end

    local html = response.body or ""
    local preferred = tostring(preferred_appid)

    if html:find("https://steamdb.info/app/" .. preferred .. "/", 1, true)
        or html:find("steamdb.info/app/" .. preferred .. "/", 1, true) then
        return preferred, nil
    end

    local direct = html:match("https://steamdb%.info/app/(%d+)/") or html:match("steamdb%.info/app/(%d+)/")
    if direct then return direct, nil end

    return nil, "No SteamDB app link found in web search"
end

local function extract_first_steamdb_technology(app_html)
    if type(app_html) ~= "string" then return nil end

    local cell = app_html:match('<th[^>]*>%s*Technologies%s*</th>%s*<td[^>]*>(.-)</td>')
    if not cell then
        cell = app_html:match('<td[^>]*>%s*Technologies%s*</td>%s*<td[^>]*>(.-)</td>')
    end
    if not cell then return nil end

    local first = cell:match('<a[^>]*>(.-)</a>')
    if not first then
        local cleaned_cell = strip_html(cell)
        first = cleaned_cell:match('^[^,|/]+') or cleaned_cell
    else
        first = strip_html(first)
    end

    first = trim(first or "")
    if first == "" then return nil end
    return first
end

local function fetch_engine_from_steamdb(appid, cfg, game_name)
    local name = trim(game_name or "")
    if name == "" then
        local fetched_name, err = get_game_name_from_steam(appid)
        if not fetched_name then
            logger:warn("SteamDB: Could not get game name for " .. tostring(appid) .. ": " .. tostring(err))
            return nil, "Could not get game name: " .. tostring(err)
        end
        name = fetched_name
    end

    -- Step 2: Try direct SteamDB app page by known AppID (avoids blocked search endpoint)
    local app_html, direct_err = try_get_steamdb_app_page(appid, cfg)
    if not app_html then
        logger:info("SteamDB direct app page miss for " .. tostring(appid) .. ": " .. tostring(direct_err))

        -- Step 3: If direct lookup fails, find SteamDB app link by game name via web search
        local steamdb_appid, lookup_err = find_steamdb_appid_via_web_search(name, appid, cfg)
        if not steamdb_appid then
            return nil, "SteamDB lookup failed: " .. tostring(lookup_err)
        end

        app_html, direct_err = try_get_steamdb_app_page(steamdb_appid, cfg)
        if not app_html then
            if (direct_err or ""):find("Cloudflare", 1, true) and trim(cfg and cfg.steamdb_cookie or "") == "" then
                local settings_path = "settings.json"
                if type(settings.get_path) == "function" then
                    settings_path = settings.get_path()
                end
                return nil, direct_err .. " (set steamdb_cookie in " .. settings_path .. ")"
            end
            return nil, direct_err
        end
    end

    local technology = extract_first_steamdb_technology(app_html)
    if not technology then
        return nil, "No Technologies data on SteamDB for: " .. tostring(name)
    end

    return technology, "steamdb"
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
        local engine_clean = sanitize_engine_result(engine)
        if engine_clean then
            logger:info("GetEngine PCGW success for " .. tostring(numeric_appid) .. ": " .. tostring(engine_clean))
            return json.encode({ success = true, engine = engine_clean, source = "pcgamingwiki" })
        end
        if engine then logger:info("GetEngine PCGW invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(engine)) end
        logger:info("GetEngine PCGW miss for " .. tostring(numeric_appid) .. ": " .. tostring(err))

        local game_name, game_name_err = get_game_name_from_steam(numeric_appid)
        if game_name then
            logger:info("GetEngine name for " .. tostring(numeric_appid) .. ": " .. tostring(game_name))
        else
            logger:info("GetEngine name miss for " .. tostring(numeric_appid) .. ": " .. tostring(game_name_err))
        end

        -- 2. PCGamingWiki fallback by game name
        local name_engine, name_err = fetch_engine_from_pcgw_by_name(game_name)
        local name_engine_clean = sanitize_engine_result(name_engine)
        if name_engine_clean then
            logger:info("GetEngine PCGW-name success for " .. tostring(numeric_appid) .. ": " .. tostring(name_engine_clean))
            return json.encode({ success = true, engine = name_engine_clean, source = "pcgamingwiki-name" })
        end
        if name_engine then logger:info("GetEngine PCGW-name invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(name_engine)) end
        logger:info("GetEngine PCGW-name miss for " .. tostring(numeric_appid) .. ": " .. tostring(name_err))

        -- 3. Local directory detection (game installation folder)
        local local_engine, local_err = fetch_engine_from_local_directory(numeric_appid, game_name)
        local local_engine_clean = sanitize_engine_result(local_engine)
        if local_engine_clean then
            logger:info("GetEngine local-directory success for " .. tostring(numeric_appid) .. ": " .. tostring(local_engine_clean))
            return json.encode({ success = true, engine = local_engine_clean, source = "local-directory" })
        end
        if local_engine then logger:info("GetEngine local-directory invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(local_engine)) end
        logger:info("GetEngine local-directory miss for " .. tostring(numeric_appid) .. ": " .. tostring(local_err))

        -- 4. Wikidata fallback by game name
        local wikidata_engine, wikidata_err = fetch_engine_from_wikidata(game_name)
        local wikidata_engine_clean = sanitize_engine_result(wikidata_engine)
        if wikidata_engine_clean then
            logger:info("GetEngine Wikidata success for " .. tostring(numeric_appid) .. ": " .. tostring(wikidata_engine_clean))
            return json.encode({ success = true, engine = wikidata_engine_clean, source = "wikidata" })
        end
        if wikidata_engine then logger:info("GetEngine Wikidata invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(wikidata_engine)) end
        logger:info("GetEngine Wikidata miss for " .. tostring(numeric_appid) .. ": " .. tostring(wikidata_err))

        -- 5. Wikipedia fallback by game name
        local wiki_engine, wiki_err = fetch_engine_from_wikipedia(game_name)
        local wiki_engine_clean = sanitize_engine_result(wiki_engine)
        if wiki_engine_clean then
            logger:info("GetEngine Wikipedia success for " .. tostring(numeric_appid) .. ": " .. tostring(wiki_engine_clean))
            return json.encode({ success = true, engine = wiki_engine_clean, source = "wikipedia" })
        end
        if wiki_engine then logger:info("GetEngine Wikipedia invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(wiki_engine)) end
        logger:info("GetEngine Wikipedia miss for " .. tostring(numeric_appid) .. ": " .. tostring(wiki_err))

        -- 6. Generic web-search fallback
        local web_engine, web_err = fetch_engine_from_web_search(game_name)
        local web_engine_clean = sanitize_engine_result(web_engine)
        if web_engine_clean then
            logger:info("GetEngine websearch success for " .. tostring(numeric_appid) .. ": " .. tostring(web_engine_clean))
            return json.encode({ success = true, engine = web_engine_clean, source = "websearch" })
        end
        if web_engine then logger:info("GetEngine websearch invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(web_engine)) end
        logger:info("GetEngine websearch miss for " .. tostring(numeric_appid) .. ": " .. tostring(web_err))

        -- 7. SteamDB fallback
        local cfg = settings.load()
        local steamdb_engine, steamdb_err = fetch_engine_from_steamdb(numeric_appid, cfg, game_name)
        local steamdb_engine_clean = sanitize_engine_result(steamdb_engine)
        if steamdb_engine_clean then
            logger:info("GetEngine SteamDB success for " .. tostring(numeric_appid) .. ": " .. tostring(steamdb_engine_clean))
            return json.encode({ success = true, engine = steamdb_engine_clean, source = "steamdb" })
        end
        if steamdb_engine then logger:info("GetEngine SteamDB invalid value ignored for " .. tostring(numeric_appid) .. ": " .. tostring(steamdb_engine)) end
        logger:info("GetEngine SteamDB miss for " .. tostring(numeric_appid) .. ": " .. tostring(steamdb_err))

        logger:warn("GetEngine not found for " .. tostring(numeric_appid))
        local public_error = "Not found on PCGameWiki"
        return json.encode({ success = false, error = public_error })
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
