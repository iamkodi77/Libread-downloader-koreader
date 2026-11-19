local Errors = require("libread/errors")
local Html = require("libread/html")
local Urls = require("libread/urls")

local Parser = { PER_PAGE = 40, MAX_PAGES = 500, MAX_CHAPTERS = 20000 }

local function nonempty(value)
    return value and value:match("%S") and value or nil
end

local function document(source)
    local root = Html.parse(source)
    local title = Html.find(root, function(node) return node.name == "title" end)
    local title_text = title and Html.text(title):lower() or ""
    if title_text:find("just a moment", 1, true)
        or title_text:find("attention required", 1, true)
        or title_text:find("verify you are human", 1, true)
        or Html.find(root, function(node)
            return (node.attrs.id or ""):match("^cf%-chl") ~= nil
        end) then
        Errors.raise("blocked", "LibRead returned a browser-verification page. This plugin cannot solve CAPTCHAs or browser challenges. Try again later; do not disable TLS verification.")
    end
    return root
end

local function meta(root, key)
    local found = Html.find(root, function(node)
        return node.name == "meta" and (node.attrs.property == key or node.attrs.name == key)
    end)
    return found and nonempty(found.attrs.content)
end

local function locked(node)
    local found = Html.find(node, function(child)
        return Html.has_class(child, "fa-lock") or Html.has_class(child, "locked")
            or Html.has_class(child, "chapter-locked") or child.attrs["data-locked"] == "true"
            or child.attrs["data-locked"] == "1"
    end)
    if found then return true end
    local parent = node.parent
    return parent and parent.name == "li" and
        (Html.has_class(parent, "locked") or parent.attrs["data-locked"] == "1"
            or Html.find(parent, function(child) return Html.has_class(child, "fa-lock") end) ~= nil) or false
end

function Parser.series_page(source, slug, page)
    local root = document(source)
    local heading = Html.find(root, function(node) return node.name == "h1" and Html.has_class(node, "tit") end)
    local heading_title = heading and nonempty(Html.text(heading))
    local title = heading_title or meta(root, "og:title")
    if not heading_title and title then title = title:match("^(.-)%s*|") or title:match("^(.-) %- ") or title end
    local cover = meta(root, "og:image") or meta(root, "image")
    if not cover then
        local image = Html.find(root, function(node) return node.name == "img" and node.attrs["data-src"] ~= nil end)
        cover = image and Html.image_source(image)
    end
    cover = cover and Urls.resolve(cover, Urls.BASE .. "/")
    if cover and not Urls.is_media(cover) then cover = nil end
    local series = {
        slug = slug, title = nonempty(title) or slug,
        author = meta(root, "og:novel:author") or "", cover_url = cover,
        chapters = {}, next_explicit = false,
    }
    local list = Html.find(root, function(node) return node.name == "ul" and node.attrs.id == "idData" end)
    if list then
        local seen = {}
        Html.walk(list, function(node)
            if node.name == "a" then
                local url, id = Urls.chapter(node.attrs.href, slug)
                if url and not seen[id] then
                    seen[id] = true
                    series.chapters[#series.chapters + 1] = {
                        id = id, url = url, title = nonempty(node.attrs.title) or nonempty(Html.text(node)) or ("Chapter " .. id),
                        locked = locked(node),
                    }
                end
            end
        end)
    end
    Html.walk(root, function(node)
        if node.name == "a" and Urls.page(node.attrs.href, slug) == (page or 1) + 1 then
            series.next_explicit = true
        end
    end)
    return series
end

function Parser.chapter(source, image_callback)
    local root = document(source)
    local article = Html.find(root, function(node) return node.name == "div" and node.attrs.id == "article" end)
    if not article or locked(article) then
        Errors.raise("missing", "Chapter is locked, requires sign-in, or has no readable article. It was not downloaded.")
    end
    local body, text_bytes, images = Html.sanitize(article, image_callback)
    if text_bytes == 0 and images == 0 then
        Errors.raise("missing", "Chapter is empty or image-only. Enable chapter images for illustrated chapters. Locked content is not supported.")
    end
    return body
end

function Parser.selection(text, count)
    if type(text) ~= "string" then return nil end
    text = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if count < 1 then return nil end
    if text == "all" or text == "a" or text == "*" then return 1, count end
    local first, last = text:match("^(%d+)%s*%-%s*(%d+)$")
    if not first then first = text:match("^(%d+)$"); last = first end
    first, last = tonumber(first), tonumber(last)
    if first and last and first >= 1 and first <= last and last <= count then return first, last end
end

function Parser.image_type(data)
    if data:sub(1, 3) == "\255\216\255" then return ".jpg", "image/jpeg" end
    if data:sub(1, 8) == "\137PNG\13\10\26\10" then return ".png", "image/png" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return ".gif", "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return ".webp", "image/webp" end
    Errors.raise("image", "The server did not return a supported image (JPEG, PNG, GIF or WebP).")
end

return Parser
