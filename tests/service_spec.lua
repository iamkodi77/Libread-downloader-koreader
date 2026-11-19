local E = require("libread/errors")
local Fs = require("libread/fs")
local P = require("libread/parser")
local Service = require("libread/service")
local Store = require("libread/store")
local U = require("libread/urls")

function fixture_client(routes)
    local calls = {}
    local function fetch(url, optional)
        calls[url] = (calls[url] or 0) + 1
        local value = routes[url]
        if type(value) == "table" and value.code then E.raise(value.code, value.message or value.code) end
        if value then return value end
        if optional then return nil end
        E.raise("missing", "No fixture for " .. url)
    end
    return { get_text = function(_, url, optional) return fetch(url, optional) end,
        get_image = function(_, url) return fetch(url) end }, calls
end

local function service(routes, options)
    options = options or {}
    local fake, calls = fixture_client(routes)
    options.client_factory = function() return fake end
    return Service.new(options), calls
end

function fixture_series(slug, count)
    local s = { slug = slug, title = 'A Tale: é & "Friends"', author = "A & B", chapters = {},
        total_chapters = count, locked_count = 0, cover_url = "https://libread.com/cover.png" }
    for i = 1, count do s.chapters[i] = { id = tostring(i), title = "Chapter " .. i .. " & more", url = U.series(slug) .. "/chapter-" .. i } end
    return s
end
local text = '<div id="article"><p>Read me &eacute; &amp; &unknown;.</p><script>Never export me</script></div>'

test("catalog fetches short final page only once", function()
    local s, calls = service({ [U.series("short")] = series_html("short", 1, 3) })
    local result = s:catalog("short")
    eq(#result.chapters, 3); eq(result.total_chapters, 3); eq(calls[U.series("short", 2)], nil)
end)
test("catalog follows explicit pagination and deduplicates overlapping pages", function()
    local s = service({ [U.series("paged")] = series_html("paged", 1, 40, 2),
        [U.series("paged", 2)] = series_html("paged", 40, 42) })
    local result = s:catalog("paged"); eq(#result.chapters, 42); eq(result.chapters[41].id, "41")
end)
test("catalog handles an exact 40-chapter final page and speculative 404", function()
    local s, calls = service({ [U.series("exact")] = series_html("exact", 1, 40) })
    eq(#s:catalog("exact").chapters, 40); eq(calls[U.series("exact", 2)], 1)
end)
test("catalog stops repeated pages instead of looping or returning partial data", function()
    local source = series_html("repeat", 1, 40, 2)
    local s = service({ [U.series("repeat")] = source, [U.series("repeat", 2)] = source })
    raises("network", function() s:catalog("repeat") end)
end)
test("catalog rejects a missing explicitly linked page", function()
    local s = service({ [U.series("broken")] = series_html("broken", 1, 2, 2) })
    raises("missing", function() s:catalog("broken") end)
end)
test("catalog excludes visibly locked rows and counts them", function()
    local source = series_html("locks", 1, 3):gsub('<li><a href="/libread/locks/chapter%-2"', '<li class="locked"><a href="/libread/locks/chapter-2"')
    local s = service({ [U.series("locks")] = source })
    local result = s:catalog("locks"); eq(#result.chapters, 2); eq(result.locked_count, 1); eq(result.total_chapters, 3)
end)
test("catalog safety cap never silently truncates a series", function()
    local previous = P.MAX_PAGES; P.MAX_PAGES = 1
    local s = service({ [U.series("large")] = series_html("large", 1, 40, 2) })
    raises("limits", function() s:catalog("large") end)
    P.MAX_PAGES = previous
end)
test("download embeds cover, mixed content and image-only chapters; resumes and fills gaps", function()
    local series = fixture_series("integration", 4)
    local routes = { [series.cover_url] = PIXEL, ["https://libread.com/inline.png"] = PIXEL }
    routes[series.chapters[1].url] = '<div id="article"><p>Before &eacute;</p><img src="/inline.png"><p>After &amp; end</p></div>'
    routes[series.chapters[2].url] = '<div id="article"><img data-src="/inline.png"></div>'
    routes[series.chapters[3].url] = '<div>Locked or missing</div>'
    routes[series.chapters[4].url] = text
    local s, calls = service(routes)
    local root = TEST_ROOT .. "/downloads"
    local result = s:download(series, 1, 4, root)
    eq(result.completed, 3); eq(result.requested, 4); eq(#result.failures, 1); eq(result.failures[1].index, 3)
    eq(result.cached, 0); eq(#result.warnings, 0); assert(Fs.is_file(result.path))
    local current = Store.open(root, series.slug)
    local chapter = Fs.read(current:path("chapter-1.xhtml"))
    contains(chapter, "Before é"); contains(chapter, "images/c1-001.png"); contains(chapter, "After &amp; end")
    result = s:download(series, 1, 4, root)
    eq(result.cached, 3); eq(calls[series.chapters[1].url], 1); eq(calls[series.cover_url], 1); eq(calls[series.chapters[3].url], 2)
    routes[series.chapters[3].url] = text
    result = s:download(series, 1, 4, root)
    eq(result.completed, 4); eq(result.cached, 3); eq(#result.failures, 0)
    INITIAL_BOOK_DATA, TEST_BOOK = Fs.read(result.path), result.path
end)
test("changing image settings invalidates the chapter cache appropriately", function()
    local series = fixture_series("image-mode", 1)
    local routes = { [series.chapters[1].url] = '<div id="article"><p>Text</p><img src="/inline.png"></div>',
        ["https://libread.com/inline.png"] = PIXEL }
    local s, calls = service(routes, { include_cover = false, include_images = false })
    local root = TEST_ROOT .. "/downloads"
    s:download(series, 1, 1, root); eq(calls["https://libread.com/inline.png"], nil)
    local store = Store.open(root, series.slug); assert(not Fs.read(store:path("chapter-1.xhtml")):find("<img", 1, true))
    s, calls = service(routes, { include_cover = false, include_images = true })
    local result = s:download(series, 1, 1, root); eq(result.cached, 0); eq(calls["https://libread.com/inline.png"], 1)
end)
test("canceled chapter downloads keep completed cache entries and the old EPUB", function()
    local series = fixture_series("cancel-chapters", 3)
    local routes = {}
    for _, c in ipairs(series.chapters) do routes[c.url] = text end
    local root = TEST_ROOT .. "/downloads"
    local store = Store.open(root, series.slug)
    local output = store:output_path(series.title, 1, 3); Fs.atomic_write(output, INITIAL_BOOK_DATA)
    local s = service(routes, { include_cover = false, run = function(message, task)
        if message:find("Chapter 2 /", 1, true) then E.raise("canceled", "user canceled") end
        return task()
    end })
    raises("canceled", function() s:download(series, 1, 3, root) end)
    eq(Fs.read(output), INITIAL_BOOK_DATA)
    store = Store.open(root, series.slug); assert(store:cached_chapter(series.chapters[1], true))
    s = service(routes, { include_cover = false })
    local result = s:download(series, 1, 3, root); eq(result.cached, 1); eq(result.completed, 3)
end)
test("canceled EPUB build removes partial file and never replaces a valid output", function()
    local series = fixture_series("cancel-build", 1)
    local root = TEST_ROOT .. "/downloads"
    local output = Store.open(root, series.slug):output_path(series.title, 1, 1)
    Fs.atomic_write(output, INITIAL_BOOK_DATA)
    local s = service({ [series.chapters[1].url] = text }, { include_cover = false, run = function(message, task)
        if message:find("Building EPUB", 1, true) then
            Fs.atomic_write(output .. ".part", "partial ZIP"); E.raise("canceled", "user canceled")
        end
        return task()
    end })
    raises("canceled", function() s:download(series, 1, 1, root) end)
    eq(Fs.read(output), INITIAL_BOOK_DATA); eq(Fs.is_file(output .. ".part"), false)
end)
test("failed EPUB assembly cleans up without replacing a valid output", function()
    local series = fixture_series("broken-build", 1)
    local root = TEST_ROOT .. "/downloads"
    local store = Store.open(root, series.slug)
    local output = store:output_path(series.title, 1, 1); Fs.atomic_write(output, INITIAL_BOOK_DATA)
    local s = service({ [series.chapters[1].url] = text }, { include_cover = false, run = function(message, task)
        if message:find("Building EPUB", 1, true) then os.remove(store:path("chapter-1.xhtml")) end
        return task()
    end })
    raises("io", function() s:download(series, 1, 1, root) end)
    eq(Fs.read(output), INITIAL_BOOK_DATA); eq(Fs.is_file(output .. ".part"), false)
end)
test("fatal network failures stop remaining chapter requests", function()
    local series = fixture_series("network-stop", 3)
    local routes = { [series.chapters[1].url] = text, [series.chapters[2].url] = { code = "network" }, [series.chapters[3].url] = text }
    local s, calls = service(routes, { include_cover = false })
    raises("network", function() s:download(series, 1, 3, TEST_ROOT .. "/downloads") end)
    eq(calls[series.chapters[3].url], nil)
end)
test("failed images skip the affected chapter rather than silently losing illustrations", function()
    local series = fixture_series("broken-image", 2)
    local s = service({ [series.chapters[1].url] = '<div id="article"><p>Text</p><img src="/bad.jpg"></div>',
        [series.chapters[2].url] = text, ["https://libread.com/bad.jpg"] = "<html>Not an image</html>" }, { include_cover = false })
    local result = s:download(series, 1, 2, TEST_ROOT .. "/downloads")
    eq(result.completed, 1); eq(#result.failures, 1)
end)
test("optional cover failures produce an explicit warning but no broken image reference", function()
    local series = fixture_series("broken-cover", 1)
    local s = service({ [series.chapters[1].url] = text, [series.cover_url] = "Not an image" })
    local result = s:download(series, 1, 1, TEST_ROOT .. "/downloads"); eq(#result.warnings, 1); eq(result.completed, 1)
end)
test("cover rate limit aborts instead of hammering chapter endpoints", function()
    local series = fixture_series("cover-limit", 1)
    local s, calls = service({ [series.cover_url] = { code = "rate_limited" }, [series.chapters[1].url] = text })
    raises("rate_limited", function() s:download(series, 1, 1, TEST_ROOT .. "/downloads") end)
    eq(calls[series.chapters[1].url], nil)
end)
test("invalid download ranges and wholly unavailable selections do not create EPUBs", function()
    local series = fixture_series("no-content", 1)
    local s = service({ [series.chapters[1].url] = "<div>No article</div>" }, { include_cover = false })
    raises("argument", function() s:download(series, 2, 1, TEST_ROOT .. "/downloads") end)
    raises("missing", function() s:download(series, 1, 1, TEST_ROOT .. "/downloads") end)
    eq(Fs.is_file(Service.output_path(TEST_ROOT .. "/downloads", series, 1, 1)), false)
end)
