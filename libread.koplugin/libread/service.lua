local Epub = require("libread/epub")
local Errors = require("libread/errors")
local Fs = require("libread/fs")
local Http = require("libread/http")
local Parser = require("libread/parser")
local Store = require("libread/store")
local Urls = require("libread/urls")

local Service = {}
Service.__index = Service

-- `run` executes one isolated step; the UI supplies a cancellable subprocess
-- runner. Tests use the same service synchronously with an injected HTTP client.
function Service.new(options)
    options = options or {}
    local self = setmetatable({}, Service)
    self.options = options
    self.include_images = options.include_images ~= false
    self.include_cover = options.include_cover ~= false
    self.run = options.run or function(_, task) return task() end
    self.client = options.client_factory or function() return Http.new(options) end
    return self
end

function Service:catalog(slug)
    slug = Urls.extract_slug(slug)
    local series, seen, total, locked_count, optional = nil, {}, 0, 0, false
    for page = 1, Parser.MAX_PAGES do
        local parsed = self.run("Loading chapter list…\nPage " .. page .. "\n\nTap to cancel.", function()
            local source = self.client():get_text(Urls.series(slug, page), optional)
            if not source then return { chapters = {}, not_found = true } end
            return Parser.series_page(source, slug, page)
        end)
        if not series then
            series = { slug = slug, title = parsed.title or slug, author = parsed.author or "",
                cover_url = parsed.cover_url, chapters = {} }
        end
        if #parsed.chapters == 0 then
            if page > 1 and optional then break end
            Errors.raise("missing", "No chapter list was found. The series may be unavailable, locked, or the website layout may have changed.")
        end
        local added = 0
        for _, chapter in ipairs(parsed.chapters) do
            if not seen[chapter.id] then
                seen[chapter.id], added, total = true, added + 1, total + 1
                if chapter.locked then locked_count = locked_count + 1
                else series.chapters[#series.chapters + 1] = chapter end
            end
        end
        if added == 0 then
            Errors.raise("network", "LibRead repeated a chapter-list page. Stopped to avoid an infinite loop or an incomplete catalog.")
        end
        if not parsed.next_explicit and #parsed.chapters < Parser.PER_PAGE then break end
        if page == Parser.MAX_PAGES or total >= Parser.MAX_CHAPTERS then
            Errors.raise("limits", "The series exceeds the catalog safety limit. No incomplete catalog was accepted.")
        end
        optional = not parsed.next_explicit
    end
    if #series.chapters == 0 then Errors.raise("missing", "No accessible chapters were found for this series.") end
    series.total_chapters, series.locked_count = total, locked_count
    return series
end

function Service.output_path(root, series, first, last)
    return Fs.join(Fs.join(root, series.slug), Fs.safe_name(series.title) .. " [" .. first .. "-" .. last .. "].epub")
end

function Service:download(series, first, last, root)
    if not first or not last or first ~= math.floor(first) or last ~= math.floor(last)
        or first < 1 or first > last or last > #series.chapters then
        Errors.raise("argument", "Invalid chapter range.")
    end
    local store = Store.open(root, series.slug)
    local output_path = store:output_path(series.title, first, last)
    local cover, warnings, failures, items, cached = nil, {}, {}, {}, 0
    if self.include_cover and series.cover_url then
        local ok, result = pcall(self.run, "Downloading cover…\n\nTap to cancel.", function()
            local current = Store.open(root, series.slug)
            local existing = current:cached_cover(series.cover_url)
            if existing then return existing end
            local data = self.client():get_image(series.cover_url)
            local extension, mime = Parser.image_type(data)
            return current:record_cover(series.cover_url, data, extension, mime)
        end)
        if ok then cover = result
        elseif Errors.is(result, "canceled") or Errors.is(result, "io") or Errors.is(result, "rate_limited") then error(result, 0)
        else warnings[#warnings + 1] = "Cover omitted: " .. Errors.message(result) end
    end
    for index = first, last do
        local chapter = series.chapters[index]
        local message = "Chapter " .. (index - first + 1) .. " / " .. (last - first + 1)
            .. "\n" .. chapter.title .. "\n\nTap to cancel. Completed chapters are cached."
        local ok, result = pcall(self.run, message, function()
            local current = Store.open(root, series.slug)
            local entry = current:cached_chapter(chapter, self.include_images)
            if entry then return { entry = entry, cached = true } end
            local client, images = self.client(), {}
            local source = client:get_text(chapter.url)
            local body = Parser.chapter(source, self.include_images and function(reference)
                if #images >= 200 then Errors.raise("limits", "This chapter has more than 200 images. Download a text-only edition or a smaller illustrated chapter.") end
                local url = Urls.resolve(reference, chapter.url)
                if not url or not Urls.is_media(url) then Errors.raise("image", "An image has an unsupported or unsafe URL.") end
                local data = client:get_image(url)
                local extension, mime = Parser.image_type(data)
                local filename = "c" .. chapter.id .. "-" .. string.format("%03d", #images + 1) .. extension
                Fs.atomic_write(current:path(filename), data)
                images[#images + 1] = { file = filename, mime = mime }
                return "images/" .. filename
            end or nil)
            entry = current:record_chapter(chapter, Epub.chapter(chapter.title, body), images, self.include_images)
            return { entry = entry, cached = false }
        end)
        if ok then
            items[#items + 1] = { chapter = chapter, entry = result.entry }
            if result.cached then cached = cached + 1 end
        elseif Errors.is(result, "missing") or Errors.is(result, "image") then
            failures[#failures + 1] = { index = index, title = chapter.title, message = Errors.message(result) }
        else
            -- In particular, don't hammer every remaining chapter after a block,
            -- rate limit, network failure, full disk, or unexpected runtime error.
            error(result, 0)
        end
    end
    if #items == 0 then
        Errors.raise("missing", "No chapters could be exported. " .. (failures[1] and failures[1].message or "Please try again."))
    end
    local ok, temporary = pcall(self.run, "Building EPUB…\n" .. #items .. " chapter(s)\n\nTap to cancel. Your previous EPUB is kept until this finishes.", function()
        return Epub.build(store, series, items, cover, first, last, output_path)
    end)
    if not ok then os.remove(output_path .. ".part"); error(temporary, 0) end
    local renamed, err = pcall(Fs.rename, temporary, output_path)
    if not renamed then os.remove(temporary); error(err, 0) end
    return { path = output_path, completed = #items, requested = last - first + 1,
        cached = cached, failures = failures, warnings = warnings }
end

return Service
