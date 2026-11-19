-- A small, bounded HTML reader for LibRead's pages, not a browser or JS engine.
-- Output is rebuilt from a whitelist: remote markup is never copied into the EPUB.
local Errors = require("libread/errors")
local entities = require("libread/entities")

local Html = {}
local void = { area=true, base=true, br=true, col=true, embed=true, hr=true,
    img=true, input=true, link=true, meta=true, param=true, source=true, track=true, wbr=true }
local raw = { script=true, style=true, noscript=true, iframe=true }
local discard = { script=true, style=true, noscript=true, iframe=true, form=true,
    button=true, input=true, select=true, textarea=true, object=true, embed=true,
    svg=true, canvas=true, audio=true, video=true, template=true }
local allowed = {}
for name in ("p div span h1 h2 h3 h4 h5 h6 br hr strong em b i u s sub sup small " ..
    "ul ol li blockquote pre code table caption thead tbody tfoot tr td th figure figcaption"):gmatch("%S+") do
    allowed[name] = true
end
local block = { p=true, div=true, h1=true, h2=true, h3=true, h4=true, h5=true,
    h6=true, ul=true, ol=true, table=true, blockquote=true, pre=true, hr=true }

local function codepoint(n)
    if not n or n > 0x10ffff or n < 0x20 and n ~= 9 and n ~= 10 and n ~= 13
        or n >= 0xd800 and n <= 0xdfff or n == 0xfffe or n == 0xffff then
        return "�"
    end
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xc0 + math.floor(n / 64), 0x80 + n % 64) end
    if n < 0x10000 then
        return string.char(0xe0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
    end
    return string.char(0xf0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
        0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

function Html.decode(text)
    return (tostring(text or ""):gsub("&([#%w]+);", function(entity)
        local n
        if entity:match("^#[xX]%x+$") then n = tonumber(entity:sub(3), 16)
        elseif entity:match("^#%d+$") then n = tonumber(entity:sub(2))
        else n = entities[entity] end
        return n and codepoint(n) or ("&" .. entity .. ";")
    end))
end

function Html.xml(text)
    return (tostring(text or ""):gsub("[%z\1-\8\11\12\14-\31]", "")
        :gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function attributes(text)
    local result, i = {}, 1
    while i <= #text do
        local first, last, name = text:find("^%s*([%w_:%.%-]+)", i)
        if not first then break end
        i = last + 1
        local _, finish = text:find("^%s*=%s*", i)
        local value = ""
        if finish then
            i = finish + 1
            local quote = text:sub(i, i)
            if quote == '"' or quote == "'" then
                local closing = text:find(quote, i + 1, true)
                if not closing then break end
                value, i = text:sub(i + 1, closing - 1), closing + 1
            else
                local start, ending = text:find("^[^%s>]+", i)
                if not start then break end
                value, i = text:sub(start, ending), ending + 1
            end
        end
        result[name:lower()] = Html.decode(value)
    end
    return result
end

local function tag_end(source, start)
    local quote
    for i = start, #source do
        local char = source:sub(i, i)
        if quote then
            if char == quote then quote = nil end
        elseif char == '"' or char == "'" then quote = char
        elseif char == ">" then return i end
    end
end

function Html.parse(source)
    local root = { name = "root", attrs = {}, children = {} }
    local stack, i, count, lower = { root }, 1, 0
    local function append(value)
        local children = stack[#stack].children
        children[#children + 1] = value
    end
    while i <= #source do
        local start = source:find("<", i, true)
        if not start then append(source:sub(i)); break end
        if start > i then append(source:sub(i, start - 1)) end
        if source:sub(start, start + 3) == "<!--" then
            local ending = source:find("-->", start + 4, true)
            i = ending and ending + 3 or #source + 1
        else
            local finish = tag_end(source, start + 1)
            if not finish then append(source:sub(start)); break end
            local text = source:sub(start + 1, finish - 1)
            local closing, name, rest = text:match("^%s*(/?)([%w:_%-]+)(.*)$")
            i = finish + 1
            if name then
                name = name:lower()
                if closing == "/" then
                    for index = #stack, 2, -1 do
                        if stack[index].name == name then
                            for _ = #stack, index, -1 do table.remove(stack) end
                            break
                        end
                    end
                elseif raw[name] then
                    lower = lower or source:lower()
                    local _, ending = lower:find("</" .. name .. "%s*>", i)
                    i = ending and ending + 1 or #source + 1
                else
                    -- Common HTML optional end tags, while retaining balanced XHTML output.
                    local top = stack[#stack].name
                    if (name == "li" and top == "li") or (block[name] and top == "p") then
                        table.remove(stack)
                    end
                    count = count + 1
                    if count > 20000 or #stack > 96 then
                        Errors.raise("limits", "The page is too complex for this plugin.")
                    end
                    local node = { name = name, attrs = attributes(rest), children = {}, parent = stack[#stack] }
                    append(node)
                    if not void[name] and not rest:match("/%s*$") then stack[#stack + 1] = node end
                end
            elseif text:sub(1, 1) ~= "!" and text:sub(1, 1) ~= "?" then
                append(source:sub(start, finish))
            end
        end
    end
    return root
end

function Html.walk(node, callback)
    if type(node) ~= "table" then return end
    if callback(node) == false then return end
    for _, child in ipairs(node.children) do Html.walk(child, callback) end
end

function Html.find(node, predicate)
    if type(node) ~= "table" then return nil end
    if predicate(node) then return node end
    for _, child in ipairs(node.children) do
        local found = Html.find(child, predicate)
        if found then return found end
    end
end

function Html.has_class(node, class)
    return (" " .. (node.attrs.class or ""):gsub("%s+", " ") .. " "):find(" " .. class .. " ", 1, true) ~= nil
end

function Html.text(node)
    local parts = {}
    local function collect(child)
        if type(child) == "string" then parts[#parts + 1] = Html.decode(child)
        elseif not discard[child.name] then
            for _, nested in ipairs(child.children) do collect(nested) end
            if block[child.name] or child.name == "br" then parts[#parts + 1] = " " end
        end
    end
    collect(node)
    return (table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Html.is_ad(node)
    local id = node.attrs.id or ""
    return Html.has_class(node, "reader-ad-skip") or Html.has_class(node, "fnw-media")
        or Html.has_class(node, "adsbygoogle") or id:match("^pf%-") or id:match("^bg%-ssp")
end

function Html.image_source(node)
    local a = node.attrs
    -- Lazy-loading attributes take precedence over a transparent src placeholder.
    for _, key in ipairs({ "data-src", "data-url", "src" }) do
        if a[key] and a[key] ~= "" and not a[key]:match("^data:") then return a[key] end
    end
    return a.srcset and a.srcset:match("^%s*([^,%s]+)")
end

function Html.sanitize(article, image_callback)
    local result, text_bytes, image_count = {}, 0, 0
    local function render(node)
        if type(node) == "string" then
            local text = Html.decode(node)
            text_bytes = text_bytes + #text:gsub("%s", ""):gsub(" ", "")
            result[#result + 1] = Html.xml(text)
            return
        end
        if discard[node.name] or Html.is_ad(node) then return end
        if node.name == "img" then
            local source = Html.image_source(node)
            local path = source and image_callback and image_callback(source)
            if path then
                image_count = image_count + 1
                result[#result + 1] = '<img src="' .. Html.xml(path) .. '" alt="' .. Html.xml(node.attrs.alt or "") .. '"/>'
            end
            return
        end
        local name = allowed[node.name] and node.name or nil
        if name then result[#result + 1] = "<" .. name .. (void[name] and "/>" or ">") end
        for _, child in ipairs(node.children) do render(child) end
        if name and not void[name] then result[#result + 1] = "</" .. name .. ">" end
    end
    for _, child in ipairs(article.children) do render(child) end
    return table.concat(result), text_bytes, image_count
end

return Html
