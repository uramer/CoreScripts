local effil = require("effil")
local Request = require("postgres.request")

local DB = {}

DB.threads = {}

DB.currentJobs = {}

function DB.ThreadWork(input, output)
    local status, err = pcall(function()
        require("postgres.thread")
        Run(input, output)
    end)
    if err then
        print(err)
        output:push(effil.table{
            id = 0,
            message = effil.table{
                error = err
            }
        })
    end
end

function DB.Initiate()
    for i = 1, config.postgresThreadCount do
        local threadId = threadHandler.CreateThread(DB.ThreadWork)
        table.insert(DB.threads, threadId)
        DB.currentJobs[threadId] = 0
    end
end

function DB.ProcessResponse(res)
    if res.error then
        tes3mp.LogMessage(enumerations.log.ERROR, "[Postgres] [[" .. res.error .. "]]")
    elseif res.log then
        tes3mp.LogMessage(enumerations.log.INFO, "[Postgres] [[" .. res.log .. "]]")
    end
end

function DB.ChooseThread()
    local minThread = DB.threads[1]
    local min = DB.currentJobs[minThread]
    for _, thread in pairs(DB.threads) do
        if min == 0 then
            break
        end
        if DB.currentJobs[thread] < min then
            min = DB.currentJobs[thread]
            minThread = thread
        end
    end
    return minThread
end

function DB.StartJob(thread)
    DB.currentJobs[thread] = DB.currentJobs[thread] + 1
end

function DB.FinishJob(thread)
    DB.currentJobs[thread] = DB.currentJobs[thread] - 1
    if DB.currentJobs[thread] < 0 then
        DB.currentJobs[thread] = 0
    end
end

function DB.Send(thread, action, sql, parameters, callback)
    DB.StartJob(thread)
    threadHandler.Send(
        thread,
        Request.form(
            action,
            sql or "",
            parameters or {}
        ),
        function(res)
            DB.FinishJob(thread)
            DB.ProcessResponse(res)
            if callback ~= nil then
                callback(res)
            end
        end
    )
end

function DB.SendAwait(thread, action, sql, parameters)
    DB.StartJob(thread)
    local res = threadHandler.SendAwait(
        thread,
        Request.form(
            action,
            sql or "",
            parameters or {}
        )
    )
    DB.FinishJob(thread)
    DB.ProcessResponse(res)
    return res
end

function DB.Connect(connectString, callback)
    for i, thread in pairs(DB.threads) do
        DB.Send(thread, Request.CONNECT, connectString, callback)
    end
end

function DB.ConnectAwait(connectString)
    for i, thread in pairs(DB.threads) do
        DB.SendAwait(thread, Request.CONNECT, connectString)
    end
end

function DB.Disconnect(callback)
    for i, thread in pairs(DB.threads) do
        DB.Send(Request.DISCONNECT, callback)
    end
end

function DB.DisconnectAwait()
    for i, thread in pairs(DB.threads) do
        DB.SendAwait(thread, Request.DISCONNECT)
    end
end

function DB.Query(sql, parameters, callback, numericalIndices)
    local thread = DB.ChooseThread()
    if numericalIndices then
        DB.Send(thread, Request.QUERY_NUMERICAL_INDICES, sql, parameters, callback)
    else
        DB.Send(thread, Request.QUERY, sql, parameters, callback)
    end
end

function DB.QueryAwait(sql, parameters, numericalIndices)
    local thread = DB.ChooseThread()
    if numericalIndices then
        return DB.SendAwait(thread, Request.QUERY_NUMERICAL_INDICES, sql, parameters)
    else
        return DB.SendAwait(thread, Request.QUERY, sql, parameters)
    end
end

return DB
