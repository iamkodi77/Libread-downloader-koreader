local Http = require("libread/http")
local U = require("libread/urls")

local function client(script, options)
    local calls, sleeps = {}, {}
    local sockets = { USER_AGENT = "KOReader/test", set = 0, reset = 0 }
    function sockets:set_timeout() self.set = self.set + 1 end
    function sockets:reset_timeout() self.reset = self.reset + 1 end
    local function transport(request)
        calls[#calls + 1] = request
        local item = script[math.min(#calls, #script)]
        if item.throw then error(item.throw) end
        if item.error then return nil, item.error end
        local chunks = item.chunks or { item.body or "OK" }
        for _, chunk in ipairs(chunks) do
            local ok, err = request.sink(chunk)
            if not ok then return nil, err end
        end
        request.sink(nil)
        return 1, item.code or 200, item.headers or {}
    end
    return Http.new(options, { transport = transport, socketutil = sockets,
        cafile = "fixture-ca", sleep = function(delay) sleeps[#sleeps + 1] = delay end }), calls, sockets, sleeps
end

test("HTTP enforces TLS verification, identity encoding and timeout cleanup", function()
    local h, calls, sockets = client({ { body = "Hello", headers = { ["content-length"] = "5" } } })
    eq(h:get_text(U.series("demo")), "Hello")
    eq(#calls, 1); eq(calls[1].verify, "peer"); eq(calls[1].cafile, "fixture-ca")
    eq(calls[1].headers["Accept-Encoding"], "identity"); eq(calls[1].redirect, false)
    eq(sockets.set, 1); eq(sockets.reset, 1)
end)
test("HTTP retries transient failures then succeeds", function()
    local h, calls, sockets = client({ { code = 503 }, { error = "timeout" }, { body = "Recovered" } })
    eq(h:get_text(U.series("demo")), "Recovered"); eq(#calls, 3); eq(sockets.reset, 3)
end)
test("HTTP bounds retries and respects bounded Retry-After", function()
    local h, calls, _, sleeps = client({ { code = 429, headers = { ["retry-after"] = "99999" } } })
    raises("rate_limited", function() h:get_text(U.series("demo")) end)
    eq(#calls, 3); eq(sleeps[2], 60); eq(sleeps[4], 60)
end)
test("HTTP never retries permanent access errors", function()
    local h, calls = client({ { code = 403 } })
    raises("blocked", function() h:get_text(U.series("demo")) end); eq(#calls, 1)
end)
test("HTTP distinguishes optional pagination 404 from missing chapters", function()
    local h = client({ { code = 404 } })
    eq(h:get_text(U.series("demo", 2), true), nil)
    raises("missing", function() h:get_text(U.series("demo") .. "/chapter-1") end)
end)
test("HTTP follows safe redirects manually and upgrades HTTP links", function()
    local h, calls = client({ { code = 302, headers = { Location = "/libread/demo/2" } }, { body = "Next" } })
    eq(h:get_text(U.series("demo")), "Next"); eq(calls[2].url, U.series("demo", 2))
    h, calls = client({ { code = 301, headers = { location = "http://cdn.example.com/a.png" } }, { body = PIXEL } })
    eq(h:get_image("https://img.example.com/a.png"), PIXEL)
    eq(calls[2].url, "https://cdn.example.com/a.png")
end)
test("HTTP rejects off-site HTML redirects and redirect loops", function()
    local h = client({ { code = 302, headers = { location = "https://evil.example.com/" } } })
    raises("network", function() h:get_text(U.series("demo")) end)
    local loop, calls = client({ { code = 302, headers = { location = "/libread/demo" } } })
    raises("network", function() loop:get_text(U.series("demo")) end); eq(#calls, 6)
end)
test("HTTP refuses arbitrary sites, local IPs and unsafe media URLs", function()
    local h, calls = client({ {} })
    raises("argument", function() h:get_text("https://evil.example.com") end)
    raises("argument", function() h:get_image("http://libread.com/image") end)
    raises("argument", function() h:get_image("https://127.0.0.1/image") end)
    eq(#calls, 0)
end)
test("HTTP aborts oversized responses before buffering the entire body", function()
    local chunk = string.rep("a", 1024 * 1024)
    local h, calls, sockets = client({ { chunks = { chunk, chunk, chunk, chunk, chunk } } })
    raises("limits", function() h:get_text(U.series("demo")) end)
    eq(#calls, 1); eq(sockets.reset, 1)
end)
test("HTTP resets global timeouts after thrown TLS errors", function()
    local h, calls, sockets = client({ { throw = "TLS handshake failed" } }, { retries = 1 })
    raises("network", function() h:get_text(U.series("demo")) end)
    eq(#calls, 1); eq(sockets.reset, 1)
end)
test("HTTP rejects partial, empty, and unexpectedly compressed responses", function()
    local h = client({ { body = "short", headers = { ["content-length"] = "100" } } }, { retries = 1 })
    raises("network", function() h:get_text(U.series("demo")) end)
    h = client({ { body = "" } }, { retries = 1 })
    raises("network", function() h:get_text(U.series("demo")) end)
    h = client({ { headers = { ["content-encoding"] = "gzip" } } })
    raises("network", function() h:get_text(U.series("demo")) end)
end)
