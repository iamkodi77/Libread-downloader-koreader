local Errors = require("libread/errors")
local Urls = require("libread/urls")

local Http = {}
Http.__index = Http

local redirects = { [301]=true, [302]=true, [303]=true, [307]=true, [308]=true }

local function clamp(value, default, minimum, maximum)
    value = tonumber(value) or default
    return math.min(maximum, math.max(minimum, value))
end

local function find_ca(ssl)
    local candidates = { "data/ca-bundle.crt", "common/ca-bundle.crt", "/etc/ssl/certs/ca-certificates.crt" }
    if ssl.get_system_ca then
        local system_ca = ssl.get_system_ca()
        if system_ca then table.insert(candidates, 1, system_ca) end
    end
    for _, path in ipairs(candidates) do
        local file = io.open(path, "rb")
        if file then file:close(); return path end
    end
    Errors.raise("network", "KOReader's CA certificate bundle is missing. Update or reinstall KOReader; TLS verification must remain enabled.")
end

function Http.new(options, dependencies)
    options, dependencies = options or {}, dependencies or {}
    local self = setmetatable({}, Http)
    self.transport = dependencies.transport or require("ssl.https").request
    self.socketutil = dependencies.socketutil or require("socketutil")
    self.sleep = dependencies.sleep or require("socket").sleep
    self.cafile = dependencies.cafile or find_ca(require("ssl"))
    self.timeout = clamp(options.timeout, 30, 10, 120)
    self.delay = clamp(options.delay, 0.5, 0.3, 5)
    self.retries = math.floor(clamp(options.retries, 3, 1, 5))
    return self
end

function Http:_once(url, kind)
    local chunks, received, sink_error = {}, 0, nil
    local maximum = kind == "image" and 12 * 1024 * 1024 or 4 * 1024 * 1024
    local started = os.time()
    local function sink(chunk, err)
        if err then sink_error = err; return nil, err end
        if chunk then
            received = received + #chunk
            if received > maximum then sink_error = "response too large"; return nil, sink_error end
            if os.time() - started > self.timeout then sink_error = "transfer timed out"; return nil, sink_error end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    self.sleep(self.delay)
    self.socketutil:set_timeout(math.min(15, self.timeout), self.timeout)
    local ok, result, code, headers = pcall(self.transport, {
        url = url, method = "GET", redirect = false, sink = sink,
        -- KOReader's LuaSec also verifies the hostname. Never opt out of verification.
        verify = "peer", cafile = self.cafile,
        headers = {
            ["User-Agent"] = (self.socketutil.USER_AGENT or "KOReader") .. " LibRead-KOReader/1.0",
            ["Accept"] = kind == "image" and "image/*" or "text/html,application/xhtml+xml",
            ["Accept-Encoding"] = "identity",
            ["Accept-Language"] = "en-US,en;q=0.9", ["Referer"] = Urls.BASE .. "/",
        },
    })
    self.socketutil:reset_timeout()
    local normalized = {}
    if type(headers) == "table" then
        for key, value in pairs(headers) do normalized[tostring(key):lower()] = value end
    end
    if sink_error == "response too large" then
        Errors.raise("limits", "The response exceeds the Kindle-safe limit (4 MiB HTML / 12 MiB per image).")
    end
    if not ok or not result or sink_error then
        return { error = tostring(sink_error or (ok and code or result) or "connection failed"), headers = normalized }
    end
    return { code = tonumber(code), body = table.concat(chunks), headers = normalized }
end

function Http:get(url, kind, allow_not_found)
    kind = kind or "html"
    local function permitted(candidate)
        return kind == "image" and Urls.is_media(candidate) or kind ~= "image" and Urls.is_site(candidate)
    end
    if not permitted(url) then Errors.raise("argument", "Refusing an unsupported or unsafe download URL.") end
    local last_error
    for attempt = 1, self.retries do
        local current, retry_wait = url, attempt * 1.5
        for hop = 0, 5 do
            local response = self:_once(current, kind)
            local code, headers = response.code, response.headers
            if response.error then
                last_error = { code = "network", message = "Network request failed: " .. response.error .. ". Check Wi-Fi, the Kindle clock and KOReader's certificates." }
                break
            elseif redirects[code] then
                local target = Urls.resolve(headers.location, current)
                if hop == 5 or not target or not permitted(target) then
                    Errors.raise("network", "The server returned an unsafe redirect or too many redirects.")
                end
                current = target
            elseif code == 200 then
                if headers["content-encoding"] and headers["content-encoding"]:lower() ~= "identity" then
                    Errors.raise("network", "The server ignored the request for uncompressed HTTP content.")
                end
                if #response.body == 0 then
                    last_error = { code = "network", message = "The server returned an empty response." }
                    break
                end
                local expected = tonumber(headers["content-length"])
                if expected and expected ~= #response.body then
                    last_error = { code = "network", message = "The download was incomplete. Please try again." }
                    break
                end
                return response.body
            elseif code == 404 and allow_not_found then
                return nil
            elseif code == 401 or code == 403 then
                Errors.raise("blocked", "LibRead refused access (HTTP " .. code .. "). Sign-in, locked content and browser/CAPTCHA challenges are not supported. Try again later.")
            elseif code == 429 or code and code >= 500 and code <= 599 then
                retry_wait = math.min(60, math.max(retry_wait, tonumber(headers["retry-after"]) or 0))
                last_error = { code = code == 429 and "rate_limited" or "network",
                    message = "LibRead returned HTTP " .. code .. ". Stop and try again later." }
                break
            elseif code == 404 or code == 410 then
                Errors.raise("missing", "The requested page is unavailable (HTTP " .. code .. ").")
            else
                Errors.raise("network", "Unexpected HTTP response: " .. tostring(code))
            end
        end
        if attempt < self.retries then self.sleep(retry_wait) end
    end
    error(last_error or { code = "network", message = "Could not download this page." }, 0)
end

function Http:get_text(url, allow_not_found)
    return self:get(url, "html", allow_not_found)
end

function Http:get_image(url)
    return self:get(url, "image")
end

return Http
