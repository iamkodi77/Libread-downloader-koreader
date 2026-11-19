local E = require("libread/errors")
local Fs = require("libread/fs")
local H = require("libread/html")
local P = require("libread/parser")
local U = require("libread/urls")
local Store = require("libread/store")
local Zip = require("libread/zip")

function series_html(slug, first, last, next_page)
    local rows = { '<html><head><meta property="og:novel:author" content="A &amp; B"/>' ..
        '<meta property="og:image" content="/cover.png"/></head><body><h1 class="tit">Test &amp; Tale</h1><ul id="idData">' }
    for i = first, last do rows[#rows + 1] = '<li><a href="/libread/' .. slug .. '/chapter-' .. i .. '">Chapter ' .. i .. '</a></li>' end
    rows[#rows + 1] = '</ul>'
    if next_page then rows[#rows + 1] = '<a href="/libread/' .. slug .. '/' .. next_page .. '">Next</a>' end
    rows[#rows + 1] = '</body></html>'
    return table.concat(rows)
end

PIXEL = Fs.read(TEST_ROOT .. "/pixel.png")

test("series URLs, slugs, query strings and paths", function()
    eq(U.extract_slug("  test-name_123  "), "test-name_123")
    eq(U.extract_slug("http://www.libread.com/libread/test-name/?tracking=1#top"), "test-name")
    eq(U.extract_slug("/libread/test-name/"), "test-name")
    eq(U.series("test", 2), "https://libread.com/libread/test/2")
end)
test("reject host tricks, traversal, chapter URLs and overlong slugs", function()
    for _, value in ipairs({ "../secrets", "https://evil.test/libread/test", "https://libread.com.evil.test/libread/test",
        "https://libread.com@evil.test/libread/test", "https://libread.com:443/libread/test",
        "https://libread.com/libread/test/chapter-1", "a/b", "file:///etc/passwd", "", string.rep("a", 151) }) do
        raises("argument", function() U.extract_slug(value) end)
    end
end)
test("resolve and constrain chapter and media URLs", function()
    eq(U.resolve("../images/a.png?x=1&amp=2", "https://libread.com/libread/demo/chapter-1"), "https://libread.com/libread/images/a.png?x=1&amp=2")
    eq(U.resolve("//cdn.example.com/a.png", U.BASE), "https://cdn.example.com/a.png")
    eq(U.resolve("http://cdn.example.com/a.png"), "https://cdn.example.com/a.png")
    eq(U.resolve("javascript:alert(1)"), nil)
    eq(U.resolve("file:///tmp/test"), nil)
    eq(U.chapter("/libread/demo/chapter-42/?q=1", "demo"), U.series("demo") .. "/chapter-42")
    eq(U.chapter("/libread/other/chapter-42", "demo"), nil)
    eq(U.is_media("https://192.168.1.1/image"), false)
    eq(U.is_media("https://host.local/image"), false)
    eq(U.is_site("https://libread.com.evil.test/"), false)
end)
test("HTML entities decode once and always escape to valid XML", function()
    eq(H.decode("&eacute; &mdash; &#128512; &#x1F600; &amp;lt;"), "é — 😀 😀 &lt;")
    eq(H.decode("&#0; &#xD800;"), "� �")
    eq(H.xml(H.decode("&unknown; &lt;b&gt;")), "&amp;unknown; &lt;b&gt;")
end)
test("HTML attributes support quotes, greater-than signs and uppercase", function()
    local root = H.parse([[<H1 CLASS='tit' title="a > b">A &amp; B</H1><img data-src=/a.png alt='x'>]])
    eq(root.children[1].attrs.title, "a > b")
    eq(H.text(root.children[1]), "A & B")
    eq(root.children[2].attrs["data-src"], "/a.png")
end)
test("HTML sanitizer strips active content, forms and nested ads", function()
    local result = P.chapter([[<div id="article"><p onclick="bad()">A &amp; B<br>Line <b>bold</b></p>
        <SCRIPT>if (a < b) { var x = '<div id="article">fake</div>'; }</SCRIPT>
        <style>.x{}</style><iframe>frame</iframe><form>Sign in</form>
        <div class="reader-ad-skip"><div>Buy me</div></div><div class="fnw-media">Ad</div>
        <p><a href="javascript:bad()">End</a></p></div>]])
    contains(result, "A &amp; B<br/>Line <b>bold</b>")
    contains(result, "<p>End</p>")
    for _, unwanted in ipairs({ "onclick", "SCRIPT", "fake", "Sign in", "Buy me", "iframe", "javascript" }) do
        assert(not result:find(unwanted, 1, true), unwanted)
    end
end)
test("sanitizer balances common optional end tags", function()
    eq(P.chapter('<div id="article"><p>One<p>Two<br>Three</div>'), "<p>One</p><p>Two<br/>Three</p>")
end)
test("lazy images preserve mixed chapter text and safe alt text", function()
    local seen
    local text = P.chapter([[<div id="article"><p>Before</p><img src="data:placeholder" data-src="/real.png" alt="&lt;test&gt;"><p>After</p></div>]], function(url)
        seen = url; return "images/local.png"
    end)
    eq(seen, "/real.png")
    contains(text, '<img src="images/local.png" alt="&lt;test&gt;"/>')
    contains(text, "After")
end)
test("image-only chapters require an actual embedded image", function()
    raises("missing", function() P.chapter('<div id="article"><img src="/page.png"></div>') end)
    contains(P.chapter('<div id="article"><img src="/page.png"></div>', function() return "images/p.png" end), "images/p.png")
end)
test("missing, empty and visibly locked chapters are not cached as content", function()
    for _, source in ipairs({ '<p>Not an article</p>', '<div id="article"> &nbsp; </div>',
        '<div id="article" class="locked"><p>Pay now</p></div>' }) do
        raises("missing", function() P.chapter(source) end)
    end
end)
test("browser challenges are rejected even when HTTP returns 200", function()
    raises("blocked", function() P.series_page('<title>Just a moment...</title><div id="cf-chl-widget">x</div>', "demo") end)
    raises("blocked", function() P.chapter('<title>Attention Required! | Cloudflare</title>') end)
end)
test("HTML parser bounds nesting on untrusted pages", function()
    raises("limits", function() H.parse(string.rep("<div>", 100)) end)
end)
test("series metadata, chapter links and pagination", function()
    local s = P.series_page(series_html("demo", 1, 40, 2), "demo", 1)
    eq(s.title, "Test & Tale"); eq(s.author, "A & B"); eq(s.cover_url, "https://libread.com/cover.png")
    eq(#s.chapters, 40); eq(s.chapters[1].id, "1"); eq(s.next_explicit, true)
end)
test("chapter listing deduplicates, scopes links and detects lock icons", function()
    local source = [[<ul id="idData"><li><a href="/libread/demo/chapter-1" title="One">x</a></li>
        <li><a href="/libread/demo/chapter-1">Duplicate</a></li><li class="locked"><a href="/libread/demo/chapter-2">Two</a></li>
        <li><a href="/libread/demo/chapter-3"><i class="fa fa-lock"></i>Three</a></li>
        <li><a href="/libread/other/chapter-8">Wrong series</a></li></ul><a href="/libread/demo/chapter-9">Footer</a>]]
    local s = P.series_page(source, "demo")
    eq(#s.chapters, 3); eq(s.chapters[1].title, "One"); eq(s.chapters[2].locked, true); eq(s.chapters[3].locked, true)
end)
test("metadata fallback and lazy cover", function()
    local s = P.series_page('<meta property="og:title" content="Novel - LibRead"><img data-src="/cover.png">', "demo")
    eq(s.title, "Novel"); eq(s.cover_url, "https://libread.com/cover.png")
end)
test("inline title whitespace survives nested markup", function()
    local node = H.parse('<h1>Hello<span> brave </span>world</h1>').children[1]
    eq(H.text(node), "Hello brave world")
end)
test("an empty heading still permits the metadata-title fallback", function()
    local s = P.series_page('<h1 class="tit"> </h1><meta property="og:title" content="Novel - LibRead">', "demo")
    eq(s.title, "Novel")
end)
test("selection accepts all, a number, and inclusive ranges only", function()
    local first, last = P.selection(" ALL ", 50); eq(first, 1); eq(last, 50)
    first, last = P.selection("2 - 4", 50); eq(first, 2); eq(last, 4)
    first, last = P.selection("50", 50); eq(first, 50); eq(last, 50)
    for _, value in ipairs({ "0", "5-1", "1-51", "1,2", "-1", "1.5", "", "all; rm -rf" }) do eq(P.selection(value, 50), nil) end
    eq(P.selection("all", 0), nil)
end)
test("image magic takes precedence over filename and MIME hints", function()
    local ext, mime = P.image_type(PIXEL); eq(ext, ".png"); eq(mime, "image/png")
    eq(P.image_type("\255\216\255more"), ".jpg")
    eq(P.image_type("GIF89amore"), ".gif")
    eq(P.image_type("RIFFabcdWEBPmore"), ".webp")
    raises("image", function() P.image_type("<html>Challenge, not an image</html>") end)
end)
test("filesystem names are safe and UTF-8 truncation never splits a character", function()
    eq(Fs.safe_name(" ../A:B / C? "), "_A_B _ C_")
    eq(Fs.safe_name("ééé", 5), "éé")
    eq(Fs.safe_name("...."), "LibRead")
end)
test("atomic writes, bounded reads and directory creation use real disk", function()
    local path = TEST_ROOT .. "/fs/nested/file.txt"
    Fs.mkdir(TEST_ROOT .. "/fs/nested"); Fs.atomic_write(path, "one"); eq(Fs.read(path), "one")
    Fs.atomic_write(path, "two"); eq(Fs.read(path), "two")
    raises("limits", function() Fs.read(path, 2) end)
end)
test("cache persists JSON and validates referenced files and image mode", function()
    local s = Store.open(TEST_ROOT .. "/cache", "demo")
    local chapter = { id = "1", url = U.series("demo") .. "/chapter-1", title = "One" }
    Fs.atomic_write(s:path("c1-001.png"), PIXEL)
    s:record_chapter(chapter, "<html/>", { { file = "c1-001.png", mime = "image/png" } }, true)
    s = Store.open(TEST_ROOT .. "/cache", "demo")
    assert(s:cached_chapter(chapter, true)); eq(s:cached_chapter(chapter, false), nil)
    os.remove(s:path("c1-001.png")); eq(s:cached_chapter(chapter, true), nil)
end)
test("corrupt cache and path traversal are treated as a cache miss", function()
    local s = Store.open(TEST_ROOT .. "/cache", "corrupt")
    Fs.atomic_write(s.index_path, "not JSON")
    s = Store.open(TEST_ROOT .. "/cache", "corrupt"); eq(next(s.state.chapters), nil)
    s.state.chapters["1"] = { file = "../../private", url = "u", images = {}, images_enabled = true }
    eq(s:cached_chapter({ id = "1", url = "u" }, true), nil)
    raises("io", function() s:path("../private") end)
end)
test("cache rejects unsupported image types even if corrupt metadata omits MIME", function()
    local s = Store.open(TEST_ROOT .. "/cache", "bad-mime")
    local chapter = { id = "1", url = "u", title = "One" }
    s:record_chapter(chapter, "<html/>", {}, true)
    Fs.atomic_write(s:path("c1-001.exe"), "not an image")
    s.state.chapters["1"].images = { { file = "c1-001.exe" } }
    eq(s:cached_chapter(chapter, true), nil)
    Fs.atomic_write(s:path("cover.exe"), "not an image")
    s.state.cover = { file = "cover.exe", url = "u" }
    eq(s:cached_cover("u"), nil)
end)
test("ZIP writer streams multi-chunk files and handles write errors", function()
    local path = TEST_ROOT .. "/stream.txt"
    Fs.atomic_write(path, string.rep("stream-data\n", 100000))
    local z = Zip.open(TEST_ROOT .. "/stream.zip")
    z:add_text("empty", ""); z:add_file("stream.txt", path); z:close()
    local broken = setmetatable({ offset = 0, handle = { write = function() return nil, "disk full" end } }, { __index = Zip })
    raises("io", function() broken:_write("test") end)
    local bad = Zip.open(TEST_ROOT .. "/invalid.zip")
    raises("io", function() bad:add_text("../bad", "x") end); bad:abort()
end)
