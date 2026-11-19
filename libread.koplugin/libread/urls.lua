local Errors = require("libread/errors")

local Urls = { BASE = "https://libread.com" }

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_slug(slug)
    return type(slug) == "string" and #slug <= 150
        and slug:match("^[%w][%w_%-]*$") ~= nil
end

local function split(url)
    local scheme, authority, tail = url:match("^(https?)://([^/]+)(.*)$")
    if not scheme or authority:find("[@:%s%c\\]") then return nil end
    local host = authority:lower()
    if not host:match("^[a-z0-9][a-z0-9%.%-]+$") then return nil end
    return scheme, host, tail ~= "" and tail or "/"
end

function Urls.extract_slug(value)
    if type(value) ~= "string" then
        Errors.raise("argument", "Enter a LibRead series URL or slug.")
    end
    local candidate = trim(value)
    local slug = candidate
    if candidate:find("://", 1, true) then
        local _, host, path = split(candidate)
        if host ~= "libread.com" and host ~= "www.libread.com" then
            Errors.raise("argument", "Use a series URL on libread.com, not a chapter or another website.")
        end
        path = path:gsub("[?#].*$", ""):gsub("/+$", "")
        slug = path:match("^/libread/([^/]+)$")
    elseif candidate:sub(1, 9) == "/libread/" then
        slug = candidate:match("^/libread/([^/?#]+)/?$")
    end
    if not valid_slug(slug) then
        Errors.raise("argument", "Use a series URL such as https://libread.com/libread/series-name-123, or its slug (up to 150 letters, numbers, underscores and hyphens).")
    end
    return slug
end

function Urls.series(slug, page)
    if not valid_slug(slug) then Errors.raise("argument", "Invalid series slug.") end
    local url = Urls.BASE .. "/libread/" .. slug
    return page and page > 1 and (url .. "/" .. page) or url
end

local function normalize_path(path)
    local suffix = path:match("([?#].*)$") or ""
    path = path:gsub("[?#].*$", "")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/") .. suffix
end

-- Resolve only HTTP(S) references. Remote content must never become a local file URL.
function Urls.resolve(reference, base)
    if type(reference) ~= "string" then return nil end
    reference = trim(reference)
    if reference == "" or reference:find("[%s%c\\]") then return nil end
    base = base or (Urls.BASE .. "/")
    local _, host, path = split(base)
    if not host then return nil end
    if reference:sub(1, 2) == "//" then
        reference = "https:" .. reference
    elseif not reference:match("^[%a][%w+%.%-]*:") then
        if reference:sub(1, 1) == "/" then
            reference = "https://" .. host .. normalize_path(reference)
        else
            path = path:gsub("[?#].*$", ""):match("^(.*)/") or ""
            reference = "https://" .. host .. normalize_path(path .. "/" .. reference)
        end
    end
    local scheme, remote_host, remote_path = split(reference)
    if not scheme then return nil end
    -- Upgrade old HTTP links; never follow a TLS downgrade.
    return "https://" .. remote_host .. remote_path:gsub("#.*$", "")
end

function Urls.is_site(url)
    local scheme, host = split(url)
    return scheme == "https" and (host == "libread.com" or host == "www.libread.com")
end

function Urls.is_media(url)
    local scheme, host = split(url)
    if scheme ~= "https" or not host or not host:find("%.") then return false end
    if host:match("^[%d%.]+$") or host:match("%.local$")
        or host:match("%.localhost$") or host:match("%.internal$") then return false end
    return true
end

function Urls.chapter(reference, slug)
    local url = Urls.resolve(reference, Urls.series(slug))
    if not url or not Urls.is_site(url) then return nil end
    local _, _, path = split(url)
    path = path:gsub("[?#].*$", ""):gsub("/+$", "")
    local series_slug, id = path:match("^/libread/([^/]+)/chapter%-(%d+)$")
    if series_slug ~= slug or not id or #id > 12 then return nil end
    return Urls.series(slug) .. "/chapter-" .. id, id
end

function Urls.page(reference, slug)
    local url = Urls.resolve(reference, Urls.series(slug))
    if not url or not Urls.is_site(url) then return nil end
    local _, _, path = split(url)
    path = path:gsub("[?#].*$", ""):gsub("/+$", "")
    local series_slug, number = path:match("^/libread/([^/]+)/(%d+)$")
    if series_slug == slug then return tonumber(number) end
end

return Urls
