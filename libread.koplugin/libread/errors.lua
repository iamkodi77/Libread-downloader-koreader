local Errors = {}

function Errors.raise(code, message)
    error({ code = code, message = message }, 0)
end

function Errors.is(err, code)
    return type(err) == "table" and err.code == code
end

function Errors.message(err)
    if type(err) == "table" and type(err.message) == "string" then
        return err.message
    end
    return tostring(err)
end

-- Keep subprocess return values serializable, including unexpected Lua errors.
function Errors.serializable(err)
    return { code = type(err) == "table" and err.code or "unexpected",
        message = Errors.message(err) }
end

return Errors
