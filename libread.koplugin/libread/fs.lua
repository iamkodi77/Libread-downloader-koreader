local Errors = require("libread/errors")
local lfs = require("libs/libkoreader-lfs")

local Fs = {}

function Fs.join(parent, child)
    return parent:gsub("/+$", "") .. "/" .. child
end

function Fs.is_file(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file" and attr.size > 0 or false
end

function Fs.mkdir(path)
    if type(path) ~= "string" or path == "" then
        Errors.raise("io", "No download folder has been selected.")
    end
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:gsub("/+$", ""):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then Fs.mkdir(parent) end
    local ok, err = lfs.mkdir(path)
    if not ok and lfs.attributes(path, "mode") ~= "directory" then
        Errors.raise("io", "Cannot create folder " .. path .. ": " .. tostring(err))
    end
end

function Fs.read(path, max_bytes)
    local handle, err = io.open(path, "rb")
    if not handle then Errors.raise("io", "Cannot read " .. path .. ": " .. tostring(err)) end
    local data = handle:read(max_bytes and (max_bytes + 1) or "*a") or ""
    handle:close()
    if max_bytes and #data > max_bytes then
        Errors.raise("limits", "File is too large: " .. path)
    end
    return data
end

function Fs.rename(source, destination)
    local ok, err = os.rename(source, destination)
    if not ok then Errors.raise("io", "Cannot save " .. destination .. ": " .. tostring(err)) end
end

function Fs.atomic_write(path, data)
    local temporary = path .. ".part"
    local handle, err = io.open(temporary, "wb")
    if not handle then Errors.raise("io", "Cannot write " .. temporary .. ": " .. tostring(err)) end
    local ok, write_err = handle:write(data)
    local closed, close_err = handle:close()
    if not ok or not closed then
        os.remove(temporary)
        Errors.raise("io", "Write failed (check free space): " .. tostring(write_err or close_err))
    end
    local renamed, rename_err = pcall(Fs.rename, temporary, path)
    if not renamed then os.remove(temporary); error(rename_err, 0) end
end

-- Truncate on a UTF-8 boundary, and never allow a title to become a path.
function Fs.safe_name(text, max_bytes)
    text = tostring(text or "LibRead"):gsub('[%c/\\:*?"<>|]', "_")
        :gsub("%s+", " "):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    max_bytes = max_bytes or 80
    if #text > max_bytes then
        local cut = max_bytes + 1
        while cut > 1 and text:byte(cut) >= 128 and text:byte(cut) < 192 do cut = cut - 1 end
        text = text:sub(1, cut - 1):gsub("[%s%.]+$", "")
    end
    return text ~= "" and text or "LibRead"
end

return Fs
