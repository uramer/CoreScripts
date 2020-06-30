local async = {}

local function throw(err)
    error(err)
end

function async.Wrap(func, ...)
    local co = coroutine.create(func)
    --[[function(...)
        local args = {...}
        local status, res = pcall(function()
            return func(unpack(args))
        end)
        if not status then
            error(res)
        end
        return res
    end)]]
    return async.Resume(co, ...)
end

function async.Resume(co, ...)
    local status, res = coroutine.resume(co, ...)
    if not status then
        error(res)
    end
    return res
end

function async.CurrentCoroutine()
    local currentCoroutine = coroutine.running()
    if not currentCoroutine then
        error("Must run inside a coroutine!\n" .. debug.traceback())
    end
    return currentCoroutine
end

function async.WaitAll(funcs, timeout, callback)
    local total = #funcs
    local counter = 0
    local results = {}
    local returned = false
    if timeout then
        timers.Timeout(function(id)
            if counter < total then
                callback(results)
                returned = true
            end
        end, timeout)
    end
    for i, func in pairs(funcs) do
        async.Wrap(function()
            local result = func()
            results[i] = result
            counter = counter + 1
            if not returned and counter == total then
                callback(results)
                returned = true
            end
        end)
    end
end

function async.WaitAllAsync(funcs, timeout)
    local currentCoroutine = async.CurrentCoroutine()
    async.WaitAll(funcs, timeout, function(results)
        async.Resume(currentCoroutine, results)
    end)
    return coroutine.yield()
end

return async
