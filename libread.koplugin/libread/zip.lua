-- Streaming, uncompressed ZIP32 writer. Only LuaJIT's built-in bit module is
-- needed: no architecture-specific plugin binaries, shell commands or ZIP tools.
local bit = require("bit")
local Errors = require("libread/errors")
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local crc_table = {}
for n = 0, 255 do
    local crc = n
    for _ = 1, 8 do crc = bxor(rshift(crc, 1), band(crc, 1) ~= 0 and 0xedb88320 or 0) end
    crc_table[n] = crc
end

local function update_crc(crc, data)
    for i = 1, #data do crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, data:byte(i)), 255)]) end
    return crc
end

local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end
local function u32(n)
    if n < 0 then n = n + 4294967296 end
    return u16(n % 65536) .. u16(math.floor(n / 65536))
end

local Zip = {}
Zip.__index = Zip

function Zip.open(path)
    local handle, err = io.open(path, "wb")
    if not handle then Errors.raise("io", "Cannot create EPUB: " .. tostring(err)) end
    local date = os.date("*t")
    local year = math.max(1980, math.min(2107, date.year))
    return setmetatable({ handle = handle, entries = {}, offset = 0,
        dos_time = date.hour * 2048 + date.min * 32 + math.floor(date.sec / 2),
        dos_date = (year - 1980) * 512 + date.month * 32 + date.day }, Zip)
end

function Zip:_write(data)
    if self.offset + #data > 4294967295 then Errors.raise("limits", "EPUB exceeds the ZIP32 size limit. Download a smaller range.") end
    local ok, err = self.handle:write(data)
    if not ok then Errors.raise("io", "EPUB write failed (check free space): " .. tostring(err)) end
    self.offset = self.offset + #data
end

function Zip:_add(name, read, size)
    if #self.entries >= 65535 or size > 4294967295 then
        Errors.raise("limits", "Too many or oversized EPUB files. Download a smaller range.")
    end
    if not name:match("^[%w%._%-%/]+$") or name:sub(1, 1) == "/"
        or ("/" .. name .. "/"):find("/../", 1, true) or #name > 65535 then
        Errors.raise("io", "Invalid EPUB entry name.")
    end
    local entry = { name = name, size = size, offset = self.offset }
    -- UTF-8 flag; method 0 (STORE). No extra field or data descriptor.
    self:_write("PK\3\4" .. u16(20) .. u16(2048) .. u16(0) .. u16(self.dos_time) .. u16(self.dos_date)
        .. u32(0) .. u32(size) .. u32(size) .. u16(#name) .. u16(0) .. name)
    local crc, count = -1, 0
    while true do
        local chunk, err = read()
        if err then Errors.raise("io", "Cannot read cached chapter: " .. tostring(err)) end
        if not chunk then break end
        count, crc = count + #chunk, update_crc(crc, chunk)
        self:_write(chunk)
    end
    if count ~= size then Errors.raise("io", "A cached file changed while building the EPUB. Please retry.") end
    entry.crc = bit.bnot(crc)
    -- Patch CRC in the local header without buffering the entire entry in RAM.
    local position, err = self.handle:seek("set", entry.offset + 14)
    if not position then Errors.raise("io", "Cannot seek in EPUB: " .. tostring(err)) end
    local written, write_err = self.handle:write(u32(entry.crc))
    if not written then Errors.raise("io", "Cannot finalize EPUB entry: " .. tostring(write_err)) end
    if not self.handle:seek("set", self.offset) then Errors.raise("io", "Cannot seek in EPUB.") end
    self.entries[#self.entries + 1] = entry
end

function Zip:add_text(name, text)
    local done = false
    self:_add(name, function()
        if done then return nil end
        done = true
        return text
    end, #text)
end

function Zip:add_file(name, path)
    local input, err = io.open(path, "rb")
    if not input then Errors.raise("io", "Cannot read cached file: " .. tostring(err)) end
    local size = input:seek("end")
    if not size or not input:seek("set", 0) then input:close(); Errors.raise("io", "Cannot seek in cached file.") end
    local ok, result = pcall(self._add, self, name, function() return input:read(65536) end, size)
    input:close()
    if not ok then error(result, 0) end
end

function Zip:close()
    local central_start = self.offset
    for _, entry in ipairs(self.entries) do
        self:_write("PK\1\2" .. u16(20) .. u16(20) .. u16(2048) .. u16(0)
            .. u16(self.dos_time) .. u16(self.dos_date) .. u32(entry.crc) .. u32(entry.size) .. u32(entry.size)
            .. u16(#entry.name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0) .. u32(entry.offset) .. entry.name)
    end
    local central_size = self.offset - central_start
    self:_write("PK\5\6" .. u16(0) .. u16(0) .. u16(#self.entries) .. u16(#self.entries)
        .. u32(central_size) .. u32(central_start) .. u16(0))
    local ok, err = self.handle:close()
    self.handle = nil
    if not ok then Errors.raise("io", "Cannot close EPUB (check free space): " .. tostring(err)) end
end

function Zip:abort()
    if self.handle then self.handle:close(); self.handle = nil end
end

return Zip
