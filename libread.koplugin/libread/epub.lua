local Html = require("libread/html")
local Urls = require("libread/urls")
local Zip = require("libread/zip")

local Epub = {}
local x = Html.xml
local stylesheet = [[
body { margin: 0 4%; }
h1, h2, h3 { text-align: left; }
p { margin: 0.5em 0; }
img { max-width: 100%; height: auto; }
.cover { text-align: center; }
pre { white-space: pre-wrap; }
table { max-width: 100%; }
]]

function Epub.document(title, body)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">'
        .. '<head><meta charset="UTF-8"/><title>' .. x(title) .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="stylesheet.css"/></head><body>' .. body .. '</body></html>'
end

function Epub.chapter(title, body)
    return Epub.document(title, "<h1>" .. x(title) .. "</h1>\n" .. body)
end

-- Build only a temporary file. The parent promotes it after the cancellable
-- subprocess completes, so cancellation never replaces a previously good book.
function Epub.build(store, series, items, cover, first, last, output_path)
    local temporary = output_path .. ".part"
    os.remove(temporary)
    local zip = Zip.open(temporary)
    local ok, err = pcall(function()
        local title = series.title .. " [" .. first .. "-" .. last .. "]"
        local identifier = Urls.series(series.slug) .. "#chapters-" .. first .. "-" .. last
        local manifest = {
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="css" href="stylesheet.css" media-type="text/css"/>',
        }
        local spine, nav, ncx, assets, seen = {}, {}, {}, {}, {}
        if cover then
            manifest[#manifest + 1] = '<item id="cover-image" href="images/' .. x(cover.file) .. '" media-type="' .. x(cover.mime) .. '" properties="cover-image"/>'
            manifest[#manifest + 1] = '<item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>'
            spine[#spine + 1] = '<itemref idref="cover-page" linear="no"/>'
            assets[#assets + 1] = cover
            seen[cover.file] = true
        end
        for position, item in ipairs(items) do
            local id, file, chapter_title = "c" .. item.chapter.id, item.entry.file, item.chapter.title
            manifest[#manifest + 1] = '<item id="' .. id .. '" href="' .. x(file) .. '" media-type="application/xhtml+xml"/>'
            spine[#spine + 1] = '<itemref idref="' .. id .. '"/>'
            nav[#nav + 1] = '<li><a href="' .. x(file) .. '">' .. x(chapter_title) .. '</a></li>'
            ncx[#ncx + 1] = '<navPoint id="' .. id .. '" playOrder="' .. position .. '"><navLabel><text>'
                .. x(chapter_title) .. '</text></navLabel><content src="' .. x(file) .. '"/></navPoint>'
            for _, image in ipairs(item.entry.images) do
                if not seen[image.file] then
                    seen[image.file] = true
                    assets[#assets + 1] = image
                    manifest[#manifest + 1] = '<item id="image-' .. #assets .. '" href="images/' .. x(image.file)
                        .. '" media-type="' .. x(image.mime) .. '"/>'
                end
            end
        end
        local cover_meta, guide = "", ""
        if cover then
            cover_meta = '<meta name="cover" content="cover-image"/>'
            guide = '<guide><reference type="cover" title="Cover" href="cover.xhtml"/></guide>'
        end
        local package = '<?xml version="1.0" encoding="UTF-8"?>'
            .. '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">'
            .. '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">' .. x(identifier) .. '</dc:identifier>'
            .. '<dc:title>' .. x(title) .. '</dc:title><dc:creator>' .. x(series.author ~= "" and series.author or "Unknown") .. '</dc:creator>'
            .. '<dc:language>en</dc:language><dc:source>' .. x(Urls.series(series.slug)) .. '</dc:source>'
            .. '<meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. '</meta>' .. cover_meta
            .. '</metadata><manifest>' .. table.concat(manifest) .. '</manifest><spine toc="ncx">'
            .. table.concat(spine) .. '</spine>' .. guide .. '</package>'

        zip:add_text("mimetype", "application/epub+zip")
        zip:add_text("META-INF/container.xml", '<?xml version="1.0"?>'
            .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            .. '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        zip:add_text("OEBPS/content.opf", package)
        zip:add_text("OEBPS/stylesheet.css", stylesheet)
        zip:add_text("OEBPS/nav.xhtml", Epub.document(title, '<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>' .. table.concat(nav) .. '</ol></nav>'))
        zip:add_text("OEBPS/toc.ncx", '<?xml version="1.0" encoding="UTF-8"?>'
            .. '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="' .. x(identifier)
            .. '"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>'
            .. '<docTitle><text>' .. x(title) .. '</text></docTitle><navMap>' .. table.concat(ncx) .. '</navMap></ncx>')
        if cover then
            zip:add_text("OEBPS/cover.xhtml", Epub.document("Cover", '<div class="cover"><img src="images/' .. x(cover.file) .. '" alt="Cover"/></div>'))
        end
        for _, item in ipairs(items) do zip:add_file("OEBPS/" .. item.entry.file, store:path(item.entry.file)) end
        for _, image in ipairs(assets) do zip:add_file("OEBPS/images/" .. image.file, store:path(image.file)) end
        zip:close()
    end)
    if not ok then zip:abort(); os.remove(temporary); error(err, 0) end
    return temporary
end

return Epub
