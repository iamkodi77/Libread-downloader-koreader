package.path = PROJECT_ROOT .. "/libread.koplugin/?.lua;" .. PROJECT_ROOT .. "/tests/?.lua;" .. package.path

local count, failed = 0, 0
function test(name, fn)
    count = count + 1
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        io.write("FAIL ", name, ": ", require("libread/errors").message(err), "\n")
    else io.write("PASS ", name, "\n") end
end
function eq(actual, expected)
    if actual ~= expected then error("expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
function contains(text, needle)
    assert(text:find(needle, 1, true), "missing: " .. needle)
end
function raises(code, fn)
    local ok, err = pcall(fn)
    assert(not ok, "expected an error")
    eq(type(err) == "table" and err.code or tostring(err), code)
    return err
end

require("core_spec")
require("http_spec")
require("service_spec")
require("ui_spec")

io.write(string.format("\n%d tests, %d failed (%s)\n", count, failed, jit.version))
assert(failed == 0, "test suite failed")
