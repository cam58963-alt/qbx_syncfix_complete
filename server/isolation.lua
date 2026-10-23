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

    -- 復帰地点をメタデータに保存（HardFix中に切断しても次回ログイン時に戻せるように）
    -- 座標はクライアント申告ではなくサーバーから見た ped 座標を使う
    -- ※ 隔離の成否に関係なくクライアントはマップ外へ移動するため、レート制限より前に保存する
    if not isolatedPlayers[src] then
        local ped    = GetPlayerPed(src)
        local origin = GetEntityCoords(ped)
        local safe   = Config.HardFix.SafeCoords
        if #(origin - vec3(safe.x, safe.y, safe.z)) > 1000.0 then
            Player.Functions.SetMetaData('syncfix_return', {
                x = origin.x, y = origin.y, z = origin.z, w = GetEntityHeading(ped)
            })
        end
    end

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
        -- 隔離していないプレイヤーのバケットは変更しない
        -- （以前は bucket 0 に戻していたため、このイベントを送るだけで
        --   牢屋・ハウジング等の他リソースのバケットから脱出できた）
        TriggerClientEvent('syncfix:hardFixRestored', src)
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
-- 隔離タイムアウト監視（フェイルセーフ）
-- ========================================================
-- 待機はプレイヤーが2回目の /syncdeep を打つまで続く。
-- 通常はクライアントが Config.HardFix.MaxStay で自動的に戻るので、
-- サーバーはその 60 秒後をフェイルセーフとして強制的に戻す。
-- MaxStay = 0（無制限）のときはタイムアウトしない。
CreateThread(function()
    while true do
        Wait(10000)
        local maxStay = Config.HardFix.MaxStay or 0
        if maxStay > 0 then
            local now = os.time()
            for pid, data in pairs(isolatedPlayers) do
                if now - data.isolatedAt > maxStay + 60 then
                    print(string.format(
                        '^1[SyncFix] HardFix isolation TIMEOUT: Player %d (bucket %d) -> force restore to %d^7',
                        pid, data.tempBucket, data.originalBucket))
                    SetPlayerRoutingBucket(pid, data.originalBucket)
                    isolatedPlayers[pid] = nil
                    TriggerClientEvent('syncfix:hardFixRestored', pid)
                    TriggerClientEvent('syncfix:hardFixForceReturn', pid)
                end
            end
        end
    end
end)

-- ========================================================
-- リソース停止時: 隔離中のプレイヤーを元のバケットへ戻す
-- ========================================================
-- 戻さないと再起動後に隔離データが消え、50000番台のバケットに取り残される
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for pid, data in pairs(isolatedPlayers) do
        SetPlayerRoutingBucket(pid, data.originalBucket)
    end
end)

-- ========================================================
-- 切断時の後始末
-- ========================================================
-- 隔離データを残すと、同じサーバーIDを引き継いだ次のプレイヤーが
-- 「Already isolated」で弾かれたり、タイムアウト時に別バケットへ移されたりする。
-- 復帰地点（metadata.syncfix_return）は次回ログイン時の復帰に使うので消さない。
AddEventHandler('playerDropped', function()
    local src = source
    if isolatedPlayers[src] then
        print(string.format('[SyncFix] HardFix: player %d dropped while isolated, cleared isoData', src))
        isolatedPlayers[src] = nil
    end
end)

-- ========================================================
-- 復帰地点の削除（クライアントが元の場所へ戻り終えた後に呼ぶ）
-- ========================================================
RegisterNetEvent('syncfix:clearReturnPoint', function()
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player then return end
    if Player.PlayerData.metadata and Player.PlayerData.metadata.syncfix_return then
        Player.Functions.SetMetaData('syncfix_return', false)
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
