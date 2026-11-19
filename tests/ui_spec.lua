-- KOReader API-contract smoke tests. Widgets/network manager are stubs, while
-- menu callbacks execute the real HTTP, parser, cache, service and EPUB code.
local Fs = require("libread/fs")
local U = require("libread/urls")
local shown, opened, switched, registrations, connections = {}, nil, nil, 0, 0
local UI = {}
function UI:show(widget) shown[#shown + 1] = widget; self.last = widget end
function UI:close(widget) widget.closed = true end
local function widget(kind)
    local class = {}
    function class:new(options)
        options.kind = kind
        return setmetatable(options, { __index = self })
    end
    function class:getInputText() return self.input end
    function class:onShowKeyboard() self.keyboard_shown = true end
    return class
end
local Container = {}
function Container:extend(class)
    class.__index = class
    return setmetatable(class, { __index = self })
end
function Container:new(options)
    local instance = setmetatable(options, self)
    instance:init()
    return instance
end
package.preload["ui/widget/container/widgetcontainer"] = function() return Container end
package.preload["ui/uimanager"] = function() return UI end
for _, name in ipairs({ "confirmbox", "infomessage", "inputdialog", "menu", "pathchooser", "textviewer" }) do
    local kind = name
    package.preload["ui/widget/" .. kind] = function() return widget(kind) end
end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["logger"] = function() return { warn = function() end } end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return TEST_ROOT end, getDataDir = function() return TEST_ROOT end }
end
local settings_data = { options = { download_dir = TEST_ROOT .. "/ui-downloads", include_cover = true, include_images = true } }
local settings = { flushes = 0 }
function settings:readSetting(key, default) return settings_data[key] or default end
function settings:saveSetting(key, value) settings_data[key] = value end
function settings:flush() self.flushes = self.flushes + 1 end
package.preload["luasettings"] = function() return { open = function() return settings end } end
package.preload["dispatcher"] = function()
    return { registerAction = function(_, name, action) eq(name, "libread_downloader"); eq(action.event, "ShowLibRead"); registrations = registrations + 1 end }
end
local trapper = {}
function trapper:wrap(fn) return fn() end
function trapper:dismissableRunInSubprocess(fn)
    if self.cancel_next then self.cancel_next = false; return false end
    if self.corrupt_next then self.corrupt_next = false; return true end
    return true, fn()
end
package.preload["ui/trapper"] = function() return trapper end
package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_, callback) connections = connections + 1; callback() end }
end
local routes = {
    [U.series("ui-demo")] = series_html("ui-demo", 1, 2),
    [U.series("ui-demo") .. "/chapter-1"] = '<div id="article"><p>Offline text.</p><img src="/inline.png"></div>',
    [U.series("ui-demo") .. "/chapter-2"] = '<div id="article"><p>Another chapter.</p></div>',
    ["https://libread.com/inline.png"] = PIXEL, ["https://libread.com/cover.png"] = PIXEL,
}
package.preload["ssl"] = function() return { get_system_ca = function() return TEST_ROOT .. "/test-ca.crt" end } end
package.preload["ssl.https"] = function()
    return { request = function(request)
        eq(request.verify, "peer")
        local body = routes[request.url]
        request.sink(body or "Not found"); request.sink(nil)
        return 1, body and 200 or 404, {}
    end }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end, USER_AGENT = "KOReader/test" }
end
package.preload["socket"] = function() return { sleep = function() end } end

local Plugin = dofile(PROJECT_ROOT .. "/libread.koplugin/main.lua")
local plugin = Plugin:new{ ui = {
    menu = { registerToMainMenu = function() registrations = registrations + 1 end },
    openFile = function(_, path) opened = path end,
    switchDocument = function(_, path) switched = path end,
} }

test("plugin metadata, menu registration and dispatcher work on initialization", function()
    eq(registrations, 2); eq(plugin.is_doc_only, false)
    local menu = {}; plugin:addToMainMenu(menu)
    eq(menu.libread.sorting_hint, "more_tools"); assert(menu.libread.callback)
    local meta = dofile(PROJECT_ROOT .. "/libread.koplugin/_meta.lua"); eq(meta.version, "1.0.0")
end)
test("complete UI flow loads catalog, selects range, downloads and opens EPUB", function()
    plugin:onShowLibRead(); eq(UI.last.kind, "menu")
    UI.last.item_table[1].callback(); eq(UI.last.kind, "inputdialog"); assert(UI.last.keyboard_shown)
    local input = UI.last; input.input = U.series("ui-demo"); input.buttons[1][2].callback()
    eq(UI.last.kind, "menu"); eq(UI.last.title, "Test & Tale"); eq(plugin.busy, false)
    UI.last.item_table[2].callback(); eq(UI.last.kind, "inputdialog")
    input = UI.last; input.input = "1-2"; input.buttons[1][2].callback()
    eq(UI.last.kind, "confirmbox"); UI.last.ok_callback()
    eq(UI.last.kind, "confirmbox"); eq(UI.last.ok_text, "Read now")
    contains(UI.last.text, "Saved 2 of 2 chapters"); assert(Fs.is_file(plugin.config.last_book))
    UI.last.ok_callback(); eq(opened, plugin.config.last_book)
    eq(#plugin.recent, 1); eq(plugin.recent[1].selection, "1-2"); assert(settings.flushes > 0)
    eq(connections, 2)
end)
test("read-now switches documents when invoked from the reader", function()
    plugin.ui.document = true; plugin:openBook(plugin.config.last_book)
    eq(switched, plugin.config.last_book); plugin.ui.document = nil
end)
test("invalid URL input never starts a network job", function()
    local previous = connections
    plugin:inputSeries(); local input = UI.last
    input.input = "https://evil.example.com/libread/test"; input.buttons[1][2].callback()
    eq(connections, previous); eq(UI.last.kind, "infomessage"); assert(not input.closed)
end)
test("UI cancellation clears the busy flag and explains resumable cache", function()
    trapper.cancel_next = true; plugin:loadSeries("ui-demo")
    eq(plugin.busy, false); eq(UI.last.kind, "infomessage"); contains(UI.last.text, "Completed chapters remain cached")
end)
test("UI handles worker crashes without hanging or losing the error", function()
    trapper.corrupt_next = true; plugin:loadSeries("ui-demo")
    eq(plugin.busy, false); contains(UI.last.text, "worker exited unexpectedly")
end)
test("UI enforces one job at a time", function()
    local previous = connections
    plugin.busy = true; plugin:loadSeries("ui-demo"); plugin.busy = false
    eq(connections, previous); contains(UI.last.text, "already running")
end)
test("settings validate numeric bounds and use KOReader's folder chooser", function()
    plugin:numberSetting("delay", "Delay", 0.3, 5)
    local input = UI.last; input.input = "0"; input.buttons[1][2].callback()
    eq(UI.last.kind, "infomessage"); eq(plugin.config.delay, 0.5)
    input.input = "0.75"; input.buttons[1][2].callback(); eq(plugin.config.delay, 0.75)
    plugin:chooseFolder(); eq(UI.last.kind, "pathchooser"); eq(UI.last.select_file, false)
    UI.last.onConfirm(TEST_ROOT); eq(plugin.config.download_dir, TEST_ROOT)
end)
test("recent series are capped, deduplicated and retain the previous range", function()
    for i = 1, 15 do plugin:remember({ slug = "recent-" .. i, title = "Recent " .. i }, "1-5") end
    eq(#plugin.recent, 12); eq(plugin.recent[1].slug, "recent-15")
    plugin:remember({ slug = "recent-15", title = "Updated" })
    eq(#plugin.recent, 12); eq(plugin.recent[1].selection, "1-5")
end)
test("help, report and missing-book flows surface standard KOReader widgets", function()
    plugin:showHelp(); eq(UI.last.kind, "textviewer"); contains(UI.last.text, "No login, DRM, paywall, or CAPTCHA bypass")
    plugin:openBook(TEST_ROOT .. "/not-a-book.epub"); eq(UI.last.kind, "infomessage")
    plugin:onShowLibRead(); UI.last.item_table[5].callback(); eq(UI.last.kind, "textviewer"); contains(UI.last.text, "Saved 2 of 2")
    plugin:onFlushSettings()
end)
