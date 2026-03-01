-- ========================================================
-- server/isolation.lua - RoutingBucket 隔離管理
-- ========================================================

local isolatedPlayers = {}

-- ========================================================
-- HardFix 隔離要求
-- ========================================================
RegisterNetEvent('syncfix:requestHardFixIsolation', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, _ = CheckRateLimit(Player.PlayerData.citizenid, 'hardFixIsolation', 3, 60, 5)
    if not ok then
        TriggerClientEvent('syncfix:hardFixIsolationFailed', src, 'Rate limit exceeded')
        return
    end

    if isolatedPlayers[src] then
        TriggerClientEvent('syncfix:hardFixIsolationFailed', src, 'Already isolated')
        return
    end

    local currentBucket = GetPlayerRoutingBucket(src)
    local tempBucket    = src + 50000

    isolatedPlayers[src] = {
        originalBucket = currentBucket,
        tempBucket     = tempBucket,
        isolatedAt     = os.time()
    }

    SetPlayerRoutingBucket(src, tempBucket)
    print(string.format('[SyncFix] HardFix isolation: Player %d -> bucket %d (was %d)',
        src, tempBucket, currentBucket))

    TriggerClientEvent('syncfix:hardFixIsolated', src, tempBucket)
end)

-- ========================================================
-- HardFix 隔離解除
-- ========================================================
RegisterNetEvent('syncfix:releaseHardFixIsolation', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local isoData = isolatedPlayers[src]
    if not isoData then
        SetPlayerRoutingBucket(src, 0)
        TriggerClientEvent('syncfix:hardFixRestored', src)
        print(string.format('[SyncFix] HardFix release (no isoData): Player %d -> bucket 0', src))
        return
    end

    local originalBucket = isoData.originalBucket
    isolatedPlayers[src] = nil

    SetPlayerRoutingBucket(src, originalBucket)
    print(string.format('[SyncFix] HardFix release: Player %d -> bucket %d (restored)',
        src, originalBucket))

    TriggerClientEvent('syncfix:hardFixRestored', src)
end)

-- ========================================================
-- 隔離タイムアウト監視（60秒でフェイルセーフ解除）
-- ========================================================
CreateThread(function()
    while true do
        Wait(10000)
        local now = os.time()
        for pid, data in pairs(isolatedPlayers) do
            if now - data.isolatedAt > 60 then
                print(string.format(
                    '^1[SyncFix] HardFix isolation TIMEOUT: Player %d (bucket %d) -> force restore to %d^7',
                    pid, data.tempBucket, data.originalBucket))
                SetPlayerRoutingBucket(pid, data.originalBucket)
                isolatedPlayers[pid] = nil
                TriggerClientEvent('syncfix:hardFixRestored', pid)
            end
        end
    end
end)

-- ========================================================
-- 管理者用次元リセット
-- ========================================================
RegisterNetEvent('syncfix:forceDimensionReset', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local g = Player.PlayerData.group
    if g ~= 'admin' and g ~= 'god' then
        print(string.format('[SyncFix] forceDimensionReset: no permission (src:%d)', src))
        return
    end

    local ok, _ = CheckRateLimit(Player.PlayerData.citizenid, 'dimensionReset', 3, 60, 15)
    if not ok then return end

    local currentBucket = GetPlayerRoutingBucket(src)
    local tempBucket    = src + 10000
    SetPlayerRoutingBucket(src, tempBucket)
    print(string.format('[SyncFix] Player %d -> bucket %d (admin temp reset)', src, tempBucket))

    SetTimeout(3000, function()
        SetPlayerRoutingBucket(src, currentBucket)
        print(string.format('[SyncFix] Player %d <- bucket %d (restored)', src, currentBucket))
        TriggerClientEvent('syncfix:dimensionResetComplete', src)
    end)
end)
