local request = require("drive.postgres.request")

local postgresDrive = {}

postgresDrive.threads = {}

postgresDrive.currentJobs = {}

function postgresDrive.ThreadWork(input, output)
    local Run = require("drive.postgres.thread")
    Run(input, output)
end

function postgresDrive.Initiate()
    for i = 1, config.postgres.threadCount do
        local threadId = threadHandler.CreateThread(postgresDrive.ThreadWork)
        table.insert(postgresDrive.threads, threadId)
        postgresDrive.currentJobs[threadId] = 0
    end
    local fl = true
    local results = postgresDrive.Connect(config.postgres.connectionString)
    for _, res in pairs(results) do
        print(res)
        if not res then
            fl = false
        end
    end
    if fl then
        tes3mp.LogMessage(enumerations.log.INFO, "[Postgres] Successfully connected all threads!")
    end

    local function ProcessMigration(id, path)
        tes3mp.LogMessage(enumerations.log.INFO, "[Postgres] Applying migration " .. path)
        local status = require("drive.postgres.migrations." .. path)(postgresDrive)
        if status ~= 0 then
            error("[Postgres] Fatal migration error!")
        end
        postgresDrive.Query([[INSERT INTO migrations(id) VALUES(?)]], {id})
    end

    local migrations = require("drive.postgres.migrations")
    local doneMigrations = postgresDrive.QueryAsync([[SELECT * FROM migrations]])
    local doneTable = {}
    if doneMigrations.error then
        tes3mp.LogMessage(enumerations.log.INFO, "[Postgres] Seeding database for the first time, ignore the SQL error above!")
        ProcessMigration(0, "0000_migrations")
    else
        for i = 1, doneMigrations.count do
            local row = doneMigrations.rows[i]
            doneTable[tonumber(row.id)] = true
        end
    end

    for i, path in ipairs(migrations) do
        if not doneTable[i] then
            ProcessMigration(i, path)
        end
    end
end

function postgresDrive.ProcessResponse(res)
    if res.error then
        tes3mp.LogMessage(enumerations.log.ERROR, "[Postgres] [[" .. res.error .. "]]")
    elseif res.log then
        tes3mp.LogMessage(enumerations.log.VERBOSE, "[Postgres] [[" .. res.log .. "]]")
    end
end

function postgresDrive.ChooseThread()
    local minThread = postgresDrive.threads[1]
    local min = postgresDrive.currentJobs[minThread]
    for _, thread in pairs(postgresDrive.threads) do
        if min == 0 then
            break
        end
        if postgresDrive.currentJobs[thread] < min then
            min = postgresDrive.currentJobs[thread]
            minThread = thread
        end
    end
    return minThread
end

function postgresDrive.StartJob(thread)
    postgresDrive.currentJobs[thread] = postgresDrive.currentJobs[thread] + 1
end

function postgresDrive.FinishJob(thread)
    postgresDrive.currentJobs[thread] = postgresDrive.currentJobs[thread] - 1
    if postgresDrive.currentJobs[thread] < 0 then
        postgresDrive.currentJobs[thread] = 0
    end
end

function postgresDrive.Send(thread, req, callback)
    postgresDrive.StartJob(thread)
    threadHandler.Send(
        thread,
        req,
        function(res)
            postgresDrive.FinishJob(thread)
            postgresDrive.ProcessResponse(res)
            if callback ~= nil then
                callback(res)
            end
        end
    )
end

function postgresDrive.SendAsync(thread, req)
    postgresDrive.StartJob(thread)
    local res = threadHandler.SendAsync(
        thread,
        req
    )
    postgresDrive.FinishJob(thread)
    postgresDrive.ProcessResponse(res)
    return res
end

function postgresDrive.Connect(connectString)
    local results = {}
    for _, thread in pairs(postgresDrive.threads) do
        table.insert(
            results,
            postgresDrive.SendAsync(thread, request.Connect(connectString))
        )
    end
    return results
end

function postgresDrive.ConnectAsync(connectString, timeout)
    local tasks = {}
    for _, thread in pairs(postgresDrive.threads) do
        table.insert(tasks, function()
            return postgresDrive.SendAsync(thread, request.Connect(connectString))
        end)
    end
    return async.WaitAll(tasks, timeout)
end

function postgresDrive.Disconnect(callback)
    local tasks = {}
    for _, thread in pairs(postgresDrive.threads) do
        table.insert(tasks, function()
            return postgresDrive.SendAsync(thread, request.Disconnect())
        end)
    end
    async.WaitAll(tasks, nil, callback)
end

function postgresDrive.DisconnectAsync()
    local currentCoroutine = async.CurrentCoroutine()
    postgresDrive.Disconnect(function(results)
        coroutine.resume(currentCoroutine, results)
    end)
    return coroutine.yield()
end

function postgresDrive.Query(sql, parameters, callback, numericalIndices)
    local thread = postgresDrive.ChooseThread()
    if numericalIndices then
        postgresDrive.Send(thread, request.QueryNumerical(sql, parameters), callback)
    else
        postgresDrive.Send(thread, request.Query(sql, parameters), callback)
    end
end

function postgresDrive.QueryAsync(sql, parameters, numericalIndices)
    local thread = postgresDrive.ChooseThread()
    if numericalIndices then
        return postgresDrive.SendAsync(thread, request.QueryNumerical(sql, parameters))
    else
        return postgresDrive.SendAsync(thread, request.Query(sql, parameters))
    end
end

postgresDrive.Initiate()

customEventHooks.registerHandler("OnServerExit", function(eventStatus)
    if eventStatus.validDefaultHandler then
        async.Wrap(function() postgresDrive.DisconnectAsync() end)
    end
end)

return postgresDrive
