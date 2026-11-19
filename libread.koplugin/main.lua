local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Errors = require("libread/errors")
local Fs = require("libread/fs")
local Parser = require("libread/parser")
local Service = require("libread/service")
local Urls = require("libread/urls")

local LibRead = WidgetContainer:extend{
    name = "libread",
    is_doc_only = false,
}

local function default_folder()
    if lfs.attributes("/mnt/us/documents", "mode") == "directory" then return "/mnt/us/documents/LibRead" end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    return Fs.join(home or DataStorage:getDataDir(), "LibRead")
end

function LibRead:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/libread.lua")
    self.config = self.settings:readSetting("options", {})
    if type(self.config) ~= "table" then self.config = {} end
    if type(self.config.download_dir) ~= "string" or self.config.download_dir == "" then self.config.download_dir = default_folder() end
    if self.config.include_images == nil then self.config.include_images = true end
    if self.config.include_cover == nil then self.config.include_cover = true end
    self.config.timeout = math.max(10, math.min(120, tonumber(self.config.timeout) or 30))
    self.config.delay = math.max(0.3, math.min(5, tonumber(self.config.delay) or 0.5))
    self.recent = self.settings:readSetting("recent", {})
    if type(self.recent) ~= "table" then self.recent = {} end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function LibRead:onDispatcherRegisterActions()
    Dispatcher:registerAction("libread_downloader", {
        category = "none", event = "ShowLibRead", title = _("LibRead downloader"), general = true,
    })
end

function LibRead:addToMainMenu(menu_items)
    menu_items.libread = {
        text = _("LibRead downloader"), sorting_hint = "more_tools",
        callback = function() self:onShowLibRead() end,
    }
end

function LibRead:saveSettings()
    self.settings:saveSetting("options", self.config)
    self.settings:saveSetting("recent", self.recent)
    self.settings:flush()
end

function LibRead:onFlushSettings()
    self:saveSettings()
end

function LibRead:notify(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function LibRead:showMenu(title, items)
    local menu
    menu = Menu:new{
        title = title, item_table = items,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function LibRead:onShowLibRead()
    local recent_items = {}
    for _, entry in ipairs(self.recent) do
        local slug = entry.slug
        if type(slug) == "string" then
            recent_items[#recent_items + 1] = { text = entry.title or slug,
                callback = function() self:loadSeries(slug) end }
        end
    end
    if #recent_items == 0 then recent_items[1] = { text = _("No recent series"), select_enabled = false } end
    self:showMenu(_("LibRead downloader"), {
        { text = _("Add series URL or slug"), callback = function() self:inputSeries() end },
        { text = _("Recent series"), sub_item_table = recent_items },
        { text = _("Settings"), callback = function() self:showSettings() end },
        { text = _("Open last downloaded book"), select_enabled = self.config.last_book ~= nil,
            callback = function() self:openBook(self.config.last_book) end },
        { text = _("Last download report"), select_enabled = self.last_report ~= nil,
            callback = function() UIManager:show(TextViewer:new{ title = _("LibRead download report"), text = self.last_report }) end },
        { text = _("About / help"), callback = function() self:showHelp() end },
    })
    return true
end

function LibRead:remember(series, selection)
    local entries = { { slug = series.slug, title = series.title, selection = selection } }
    for _, entry in ipairs(self.recent) do
        if entry.slug ~= series.slug and #entries < 12 then entries[#entries + 1] = entry
        elseif entry.slug == series.slug and not selection then entries[1].selection = entry.selection end
    end
    self.recent = entries
    self:saveSettings()
end

function LibRead:makeService()
    return Service.new{
        timeout = self.config.timeout, delay = self.config.delay, retries = 3,
        include_cover = self.config.include_cover, include_images = self.config.include_images,
        run = function(message, task)
            local completed, packet = Trapper:dismissableRunInSubprocess(function()
                local ok, value = pcall(task)
                if ok then return { ok = true, value = value } end
                return { ok = false, error = Errors.serializable(value) }
            end, message)
            if not completed then Errors.raise("canceled", "Canceled") end
            if type(packet) ~= "table" or type(packet.ok) ~= "boolean" then
                Errors.raise("unexpected", "The download worker exited unexpectedly. Try a smaller range and check free memory/storage.")
            end
            if not packet.ok then error(packet.error, 0) end
            return packet.value
        end,
    }
end

function LibRead:job(work, done)
    if self.busy then self:notify(_("A LibRead task is already running.")); return end
    NetworkMgr:runWhenConnected(function()
        if self.busy then return end
        self.busy = true
        Trapper:wrap(function()
            local ok, result = pcall(function() return work(self:makeService()) end)
            self.busy = false
            if ok then
                done(result)
            elseif Errors.is(result, "canceled") then
                self:notify(_("Canceled. Completed chapters remain cached. Select the same range again to resume. Your previous EPUB was not replaced."))
            else
                logger.warn("LibRead:", Errors.message(result))
                self:notify(_("LibRead could not finish:") .. "\n\n" .. Errors.message(result)
                    .. "\n\n" .. _("Completed chapters remain cached; select the same range to retry."))
            end
        end)
    end)
end

function LibRead:inputSeries()
    local dialog
    dialog = InputDialog:new{
        title = _("LibRead series URL or slug"), input = self.config.last_input or "",
        input_hint = "https://libread.com/libread/series-name-123",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Load"), is_enter_default = true, callback = function()
                local ok, slug = pcall(Urls.extract_slug, dialog:getInputText())
                if not ok then self:notify(Errors.message(slug)); return end
                self.config.last_input = slug
                self:saveSettings()
                UIManager:close(dialog)
                self:loadSeries(slug)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibRead:loadSeries(slug)
    self:job(function(service) return service:catalog(slug) end, function(series)
        self:remember(series)
        self:showSeries(series)
    end)
end

function LibRead:showSeries(series)
    self:showMenu(series.title, {
        { text = string.format(_("%d accessible chapters; %d visibly locked skipped"), #series.chapters, series.locked_count), select_enabled = false },
        { text = _("Download chapter or range"), callback = function() self:inputRange(series) end },
        { text = _("Browse chapters"), callback = function() self:showChapters(series) end },
        { text = _("Download all accessible chapters"), callback = function() self:confirmDownload(series, 1, #series.chapters) end },
    })
end

function LibRead:showChapters(series)
    local items = {}
    for index, chapter in ipairs(series.chapters) do
        local position = index
        items[#items + 1] = { text = index .. ". " .. chapter.title,
            callback = function() self:confirmDownload(series, position, position) end }
    end
    self:showMenu(series.title, items)
end

function LibRead:inputRange(series)
    local previous = "1-" .. math.min(50, #series.chapters)
    for _, entry in ipairs(self.recent) do
        if entry.slug == series.slug and Parser.selection(entry.selection, #series.chapters) then previous = entry.selection end
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Select chapters"), input = previous, input_hint = "1-50",
        description = string.format(_("Enter all, one number, or an inclusive range (1-%d). Numbers are positions in Browse chapters, not necessarily the chapter title's number."), #series.chapters),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Continue"), is_enter_default = true, callback = function()
                local first, last = Parser.selection(dialog:getInputText(), #series.chapters)
                if not first then self:notify(_("Invalid selection. Enter all, a number, or a range such as 1-50.")); return end
                UIManager:close(dialog)
                self:confirmDownload(series, first, last)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibRead:confirmDownload(series, first, last)
    local path = Service.output_path(self.config.download_dir, series, first, last)
    local text = series.title .. "\n\n" .. string.format(_("Download %d chapter(s), positions %d-%d?"), last - first + 1, first, last)
        .. "\n\n" .. _("Completed cached chapters will be reused.") .. "\n\n" .. path
    if Fs.is_file(path) then text = text .. "\n\n" .. _("This EPUB already exists. It will be replaced only after a successful export.") end
    if last - first + 1 > 100 then text = text .. "\n\n" .. _("Large downloads can take a long time and use substantial battery/storage. Smaller ranges are recommended on Kindle.") end
    UIManager:show(ConfirmBox:new{
        text = text, ok_text = _("Download"),
        ok_callback = function()
            self:remember(series, first .. "-" .. last)
            self:job(function(service) return service:download(series, first, last, self.config.download_dir) end,
                function(result) self:downloadFinished(result) end)
        end,
    })
end

function LibRead:downloadFinished(result)
    self.config.last_book = result.path
    self:saveSettings()
    local summary = string.format(_("Saved %d of %d chapters (%d reused from cache)."), result.completed, result.requested, result.cached)
    local report = { summary, result.path, "" }
    for _, warning in ipairs(result.warnings) do report[#report + 1] = warning end
    for _, failure in ipairs(result.failures) do
        report[#report + 1] = failure.index .. ". " .. failure.title .. ": " .. failure.message
    end
    self.last_report = table.concat(report, "\n")
    if #result.failures > 0 or #result.warnings > 0 then
        summary = summary .. "\n\n" .. string.format(_("%d chapter(s) skipped; %d warning(s). See Last download report. Retry the same range to fill gaps."), #result.failures, #result.warnings)
    end
    UIManager:show(ConfirmBox:new{
        text = summary .. "\n\n" .. result.path,
        cancel_text = _("Close"), ok_text = _("Read now"),
        ok_callback = function() self:openBook(result.path) end,
    })
end

function LibRead:openBook(path)
    if not path or not Fs.is_file(path) then self:notify(_("The downloaded EPUB is no longer at its saved location.")); return end
    if self.ui.document then self.ui:switchDocument(path) else self.ui:openFile(path) end
end

function LibRead:showSettings()
    self:showMenu(_("LibRead settings"), {
        { text = _("Download folder") .. ": " .. self.config.download_dir, callback = function() self:chooseFolder() end },
        { text = _("Include cover") .. ": " .. (self.config.include_cover and _("on") or _("off")), callback = function()
            self.config.include_cover = not self.config.include_cover; self:saveSettings(); self:showSettings()
        end },
        { text = _("Include chapter images") .. ": " .. (self.config.include_images and _("on") or _("off")), callback = function()
            self.config.include_images = not self.config.include_images; self:saveSettings(); self:showSettings()
        end },
        { text = _("Request timeout (seconds)") .. ": " .. self.config.timeout, callback = function()
            self:numberSetting("timeout", _("Request timeout (10-120 seconds)"), 10, 120)
        end },
        { text = _("Delay before requests (seconds)") .. ": " .. self.config.delay, callback = function()
            self:numberSetting("delay", _("Request delay (0.3-5 seconds)"), 0.3, 5)
        end },
    })
end

function LibRead:chooseFolder()
    local path = lfs.attributes(self.config.download_dir, "mode") == "directory" and self.config.download_dir
        or (lfs.attributes("/mnt/us/documents", "mode") == "directory" and "/mnt/us/documents" or DataStorage:getDataDir())
    UIManager:show(PathChooser:new{
        path = path, select_directory = true, select_file = false, show_files = false,
        onConfirm = function(chosen)
            self.config.download_dir = chosen
            self:saveSettings()
        end,
    })
end

function LibRead:numberSetting(key, title, minimum, maximum)
    local dialog
    dialog = InputDialog:new{
        title = title, input = tostring(self.config[key]), input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = tonumber(dialog:getInputText())
                if not value or value ~= value or value < minimum or value > maximum then
                    self:notify(_("Enter a number within the displayed range.")); return
                end
                self.config[key] = value
                self:saveSettings()
                UIManager:close(dialog)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibRead:showHelp()
    UIManager:show(TextViewer:new{
        title = _("LibRead downloader 1.0.0"),
        text = _([[Add a libread.com series URL or slug, then browse chapters or select all, one position, or a range such as 1-50.

EPUBs open inside KOReader. The stock Kindle library does not natively read these files.

Tap a progress window to cancel. Completed chapters are saved in a hidden .libread-cache folder beside the EPUB. Retry the same range to resume. After exporting, that cache can be deleted over USB to reclaim space; keep it for fast retries.

Images and covers are optional. Start with 10-50 chapters on a Kindle. ZIP storage is uncompressed to avoid extra binaries and keep memory usage low; allow space for both the cache and EPUB.

Only download material you are authorized to save. No login, DRM, paywall, or CAPTCHA bypass is included. Site changes can break the parser.

Inspired by mrcloudworks-glitch/libread-downloader. This is an independent Lua implementation, not the Python program running on Kindle.

Source and installation:
https://github.com/iamkodi77/Libread-downloader-koreader]]),
    })
end

return LibRead
