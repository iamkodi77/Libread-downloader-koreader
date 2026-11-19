local Errors = require("libread/errors")
local Fs = require("libread/fs")
local JSON = require("json")
local Urls = require("libread/urls")

local Store = {}
Store.__index = Store
Store.MIME = { [".jpg"] = "image/jpeg", [".png"] = "image/png", [".gif"] = "image/gif", [".webp"] = "image/webp" }

function Store.open(root, slug)
    if Urls.extract_slug(slug) ~= slug then Errors.raise("argument", "Invalid series slug.") end
    local self = setmetatable({}, Store)
    self.series_dir = Fs.join(root, slug)
    self.cache_dir = Fs.join(self.series_dir, ".libread-cache")
    self.index_path = Fs.join(self.cache_dir, "index.json")
    Fs.mkdir(self.cache_dir)
    self.state = { version = 1, slug = slug, chapters = {} }
    if Fs.is_file(self.index_path) then
        local ok, state = pcall(function() return JSON.decode(Fs.read(self.index_path, 4 * 1024 * 1024)) end)
        if ok and type(state) == "table" and state.version == 1 and state.slug == slug
            and type(state.chapters) == "table" then self.state = state end
    end
    return self
end

function Store:path(filename)
    if type(filename) ~= "string" or not filename:match("^[%w_%-]+%.[%w]+$") then
        Errors.raise("io", "Invalid cache filename.")
    end
    return Fs.join(self.cache_dir, filename)
end

function Store:save()
    local ok, encoded = pcall(JSON.encode, self.state)
    if not ok then Errors.raise("io", "Cannot encode the download cache index.") end
    Fs.atomic_write(self.index_path, encoded)
end

function Store:cached_chapter(chapter, images_enabled)
    local entry = self.state.chapters[chapter.id]
    if type(entry) ~= "table" or entry.url ~= chapter.url or entry.images_enabled ~= images_enabled
        or entry.file ~= "chapter-" .. chapter.id .. ".xhtml" or type(entry.images) ~= "table"
        or #entry.images > 200 or not Fs.is_file(self:path(entry.file)) then return nil end
    for _, image in ipairs(entry.images) do
        if type(image) ~= "table" or type(image.file) ~= "string" then return nil end
        local extension = image.file:match("^c" .. chapter.id .. "%-%d+(%.[%w]+)$")
        if not extension or not Store.MIME[extension] or Store.MIME[extension] ~= image.mime
            or not Fs.is_file(self:path(image.file)) then return nil end
    end
    return entry
end

function Store:record_chapter(chapter, document, images, images_enabled)
    local filename = "chapter-" .. chapter.id .. ".xhtml"
    Fs.atomic_write(self:path(filename), document)
    local entry = { file = filename, url = chapter.url, title = chapter.title,
        images = images, images_enabled = images_enabled }
    self.state.chapters[chapter.id] = entry
    self:save()
    return entry
end

function Store:cached_cover(url)
    local entry = self.state.cover
    if type(entry) ~= "table" or entry.url ~= url or type(entry.file) ~= "string" then return nil end
    local extension = entry.file:match("^cover(%.[%w]+)$")
    if extension and Store.MIME[extension] and Store.MIME[extension] == entry.mime
        and Fs.is_file(self:path(entry.file)) then return entry end
end

function Store:record_cover(url, data, extension, mime)
    local entry = { file = "cover" .. extension, url = url, mime = mime }
    Fs.atomic_write(self:path(entry.file), data)
    self.state.cover = entry
    self:save()
    return entry
end

function Store:output_path(title, first, last)
    return Fs.join(self.series_dir, Fs.safe_name(title) .. " [" .. first .. "-" .. last .. "].epub")
end

return Store
