-- ========================================================
-- server.lua (修正版 v2.2.0)
-- 変更点:
--  [v2.2] syncfix:requestHardFixIsolation を新設
--         HardFix用 RoutingBucket 隔離をサーバー側で管理
--         (クライアントから直接 SetPlayerRoutingBucket は呼べないため)
--  [v2.2] syncfix:releaseHardFixIsolation を新設
--         隔離解除をサーバー側で安全に処理
-- ========================================================
-- ========================================================
-- server.lua (修正版 v2.1.x から継続)
-- 修正点:
--  [S1] 全サーバーイベントにレート制限・バリデーション追加
--  [S2] GetEntityOwner に統一（サーバー側ネイティブ正しい使い方）
--  [S3] SetNetworkIdExistsOnAllMachines等サーバー非対応ネイティブ削除
--  [S4] forceDimensionReset を管理者専用に変更
--  [S5] コマンド名表示の不一致修正(/fix→/quickreload)
--  [S6] 異常座標のサーバー側バリデーション追加
--  [S7] 自動同期の不要な全体通知を抑制
-- ========================================================

local playerStats     = {}
local serverStartTime = os.time()

-- [S1] レート制限テーブル
local eventRateLimits = {}

local function checkRateLimit(citizenid, eventName, maxCalls, windowSec, minIntervalSec)
    local key = citizenid .. ':' .. eventName
    local now = os.time()
    if not eventRateLimits[key] then
        eventRateLimits[key] = { lastTime = 0, count = 0, windowStart = now }
    end
    local rl = eventRateLimits[key]
    if now - rl.windowStart >= windowSec then
        rl.count = 0
        rl.windowStart = now
    end
    if minIntervalSec and (now - rl.lastTime) < minIntervalSec then
        return false, string.format('wait %ds', minIntervalSec - (now - rl.lastTime))
    end
    if rl.count >= maxCalls then
        return false, string.format('rate limit: %d/%ds', maxCalls, windowSec)
    end
    rl.count    = rl.count + 1
    rl.lastTime = now
    return true
end

local hasOxLib = GetResourceState('ox_lib') == 'started'

-- ========================================================
-- Discord Webhook
-- ========================================================
local function getWebhookUrl()
    local convar = GetConvar('syncfix_webhook', '')
    if convar and convar ~= '' then return convar end
    return (Config.Discord and Config.Discord.WebhookURL) or ''
end

local function sendDiscordNotification(source, commandType, extraInfo)
    if not Config.Discord.Enabled then return end

    -- ✅ 1回だけ取得してローカル変数に保持
    local webhook = getWebhookUrl()
    if webhook == '' then return end

    local Player = exports.qbx_core:GetPlayer(source)
    if not Player then return end

    local charinfo   = Player.PlayerData.charinfo
    local playerName = charinfo.firstname .. ' ' .. charinfo.lastname
    local citizenid  = Player.PlayerData.citizenid

    local discordId = 'N/A'
    for _, identifier in ipairs(GetPlayerIdentifiers(source)) do
        if string.match(identifier, 'discord:') then
            discordId = string.gsub(identifier, 'discord:', '')
            break
        end
    end

    local commandNames = {
        QuickFix  = 'QuickFix (/'  .. Config.Commands.QuickFix  .. ')',
        HardFix   = 'HardFix (/'   .. Config.Commands.HardFix   .. ')',
        MLOFix    = 'MLOFix (/'    .. Config.Commands.MLOFix    .. ')',
        Emergency = 'Emergency (/' .. Config.Commands.Emergency .. ')'
    }

    local embed = {
        {
            title  = 'SyncFix Usage Log',
            color  = Config.Discord.Colors[commandType] or 3447003,
            fields = {
                {
                    name   = 'Player',
                    value  = string.format('**Name:** %s\n**Server ID:** %s\n**Citizen ID:** %s',
                        playerName, source, citizenid),
                    inline = true
                },
                {
                    name   = 'Command',
                    value  = commandNames[commandType] or commandType,
                    inline = true
                },
                {
                    name   = 'Details',
                    value  = extraInfo or 'N/A',
                    inline = false
                },
                {
                    name   = 'Discord',
                    value  = discordId ~= 'N/A' and string.format('<@%s>', discordId) or 'Not linked',
                    inline = true
                }
            },
            footer    = { text = string.format('%s | %s', Config.Discord.ServerName, os.date('%Y-%m-%d %H:%M:%S')) },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%S')
        }
    }

    -- ✅ Config.Discord.WebhookURL → webhook 変数に変更（これが本体の修正）
    PerformHttpRequest(webhook,
        function(err)
            if err ~= 200 and err ~= 204 then
                print(string.format('[SyncFix] Discord webhook error: HTTP %s', err))
            end
        end,
        'POST',
        json.encode({ username = 'SyncFix Monitor', embeds = embed }),
        { ['Content-Type'] = 'application/json' }
    )
end

-- ========================================================
-- [S1] 使用ログ - レート制限付き（60秒/6回・最低8秒間隔）
-- ========================================================
RegisterNetEvent('syncfix:logUsage', function(commandType, details)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    local ok, reason = checkRateLimit(citizenid, 'logUsage', 6, 60, 8)
    if not ok then
        print(string.format('[SyncFix] logUsage blocked %s: %s', citizenid, reason))
        return
    end

    -- 許可リストチェック（不正コマンドタイプ拒否）
    local validTypes = { QuickFix=true, HardFix=true, MLOFix=true, Emergency=true }
    if not validTypes[commandType] then
        print(string.format('[SyncFix] Invalid commandType: %s (src:%d)', tostring(commandType), src))
        return
    end

    if not playerStats[citizenid] then
        playerStats[citizenid] = {
            name     = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
            QuickFix = 0, HardFix = 0, MLOFix = 0, Emergency = 0,
            lastUsed = os.time()
        }
    end

    playerStats[citizenid][commandType] = (playerStats[citizenid][commandType] or 0) + 1
    playerStats[citizenid].lastUsed     = os.time()

    sendDiscordNotification(src, commandType, details)
    print(string.format('[SyncFix] %s used %s - %s',
        playerStats[citizenid].name, commandType, details or ''))
end)

-- ========================================================
-- [S1] 緊急脱出制限チェック - レート制限付き
-- ========================================================
RegisterNetEvent('syncfix:checkEmergencyRestrictions', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local ok, reason = checkRateLimit(citizenid, 'emergencyCheck', 5, 60, 10)
    if not ok then
        TriggerClientEvent('syncfix:emergencyCheckResult', src, { reason })
        return
    end

    local restrictions = {}
    if Config.Emergency.Restrictions.BlockIfHandcuffed then
        if Player.PlayerData.metadata and Player.PlayerData.metadata.ishandcuffed then
            table.insert(restrictions, 'Handcuffed')
        end
    end
    if Config.Emergency.Restrictions.BlockIfDead then
        if Player.PlayerData.metadata and
           (Player.PlayerData.metadata.isdead or Player.PlayerData.metadata.inlaststand) then
            table.insert(restrictions, 'Dead/Downed')
        end
    end
    TriggerClientEvent('syncfix:emergencyCheckResult', src, restrictions)
end)

-- ========================================================
-- 統計データ集計
-- ========================================================
local function getStatsData()
    local statsData = {
        serverUptime = math.floor((os.time() - serverStartTime) / 3600),
        playerCount  = 0,
        totalUsage   = { QuickFix=0, HardFix=0, MLOFix=0, Emergency=0 }
    }
    for _, data in pairs(playerStats) do
        statsData.playerCount              = statsData.playerCount + 1
        statsData.totalUsage.QuickFix  = statsData.totalUsage.QuickFix  + data.QuickFix
        statsData.totalUsage.HardFix   = statsData.totalUsage.HardFix   + data.HardFix
        statsData.totalUsage.MLOFix    = statsData.totalUsage.MLOFix    + data.MLOFix
        statsData.totalUsage.Emergency = statsData.totalUsage.Emergency + data.Emergency
    end
    return statsData
end

-- ========================================================
-- syncstats コマンド（管理者専用）
-- ========================================================
if hasOxLib then
    lib.addCommand('syncstats', {
        help = 'SyncFix stats', restricted = 'group.admin'
    }, function(source)
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local statsData = getStatsData()
        TriggerClientEvent('syncfix:showStatsNotification', source, statsData)
        TriggerClientEvent('syncfix:showDetailedStats', source, playerStats, statsData)
        print('========== SyncFix Statistics ==========')
        print(string.format('Uptime:%dh | Users:%d | /%s:%d /%s:%d /%s:%d /%s:%d',
            statsData.serverUptime, statsData.playerCount,
            Config.Commands.QuickFix,  statsData.totalUsage.QuickFix,
            Config.Commands.HardFix,   statsData.totalUsage.HardFix,
            Config.Commands.MLOFix,    statsData.totalUsage.MLOFix,
            Config.Commands.Emergency, statsData.totalUsage.Emergency))
        print('=======================================')
    end)

    lib.addCommand('myperm', { help = 'Check own permission info' }, function(source)
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local permInfo = '[Identifiers]\n'
        for _, id in ipairs(GetPlayerIdentifiers(source)) do permInfo = permInfo .. id .. '\n' end
        if Player.PlayerData.group then
            permInfo = permInfo .. '\n[QBX Group]\n' .. Player.PlayerData.group
        end
        permInfo = permInfo .. '\n[ACE: command.syncstats] '
            .. (IsPlayerAceAllowed(source, 'command.syncstats') and 'Allowed' or 'Denied')
        TriggerClientEvent('chat:addMessage', source, {
            color={100,255,100}, multiline=true, args={'Permission Check', permInfo}
        })
    end)
else
    RegisterCommand('syncstats', function(source)
        if source == 0 then
            local statsData = getStatsData()
            print('========== SyncFix Console Stats ==========')
            for _, data in pairs(playerStats) do
                local total = data.QuickFix + data.HardFix + data.MLOFix + data.Emergency
                print(string.format('  %s: %d uses', data.name, total))
            end
            print('==========================================')
            return
        end
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local g = Player.PlayerData.group
        if g ~= 'admin' and g ~= 'god' then
            TriggerClientEvent('chat:addMessage', source, {color={255,100,100}, args={'Error','Admin only'}})
            return
        end
        local statsData = getStatsData()
        TriggerClientEvent('syncfix:showDetailedStats', source, playerStats, statsData)
    end, false)
end

-- ========================================================
-- [S1] forceServerSync - レート制限（15秒間隔・60秒/4回）
-- ========================================================
RegisterNetEvent('syncfix:forceServerSync', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, reason = checkRateLimit(Player.PlayerData.citizenid, 'forceServerSync', 4, 60, 15)
    if not ok then
        print(string.format('[SyncFix] forceServerSync blocked: %s', reason))
        return
    end

    local syncCount = 0
    for _, targetId in ipairs(GetPlayers()) do
        local targetSrc = tonumber(targetId)
        if targetSrc ~= src then
            TriggerClientEvent('syncfix:receiveSyncPulse', targetSrc, src)
            syncCount = syncCount + 1
        end
    end
    TriggerClientEvent('syncfix:receiveSyncPulse', src, src)
    print(string.format('[SyncFix] Player %d triggered server sync for %d players', src, syncCount))
end)

-- ========================================================
-- [S1] resetEntityOwnership - レート制限付き
-- ========================================================
RegisterNetEvent('syncfix:resetEntityOwnership', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, _ = checkRateLimit(Player.PlayerData.citizenid, 'resetOwnership', 3, 60, 15)
    if not ok then return end

    print(string.format('^2[SyncFix] Entity ownership reset requested by player %d^7', src))
    TriggerClientEvent('syncfix:refreshEntityOwnership', src)
end)

-- ========================================================
-- [S1][S6] 異常座標報告 - レート制限+サーバー側バリデーション
-- ========================================================
RegisterNetEvent('syncfix:reportAbnormalCoords', function(coords)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, _ = checkRateLimit(Player.PlayerData.citizenid, 'reportAbnormal', 2, 60, 30)
    if not ok then return end

    -- [S6] coords の型・値バリデーション
    if type(coords) ~= 'vector3' and type(coords) ~= 'table' then return end
    local x = tonumber(coords.x) or 0.0
    local y = tonumber(coords.y) or 0.0
    local z = tonumber(coords.z) or 0.0

    local isAbnormal = (x ~= x) or (y ~= y) or (z ~= z)
        or z < -1000.0 or z > 5000.0
        or math.abs(x) > 100000.0 or math.abs(y) > 100000.0

    if not isAbnormal then return end

    local n = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    print(string.format('^1[SyncManager] Abnormal coords: %s (ID:%d) - %.1f,%.1f,%.1f^7', n, src, x, y, z))
    TriggerClientEvent('syncfix:emergencySync', src)
end)

-- ========================================================
-- [v2.2] HardFix用 Routing Bucket 隔離
--
-- 設計:
--   ① クライアントが syncfix:requestHardFixIsolation を発火
--   ② サーバーが src+50000 の一時バケットにプレイヤーを移動
--      → 他プレイヤーのエンティティがネットワーク的に完全分離される
--   ③ サーバーが syncfix:hardFixIsolated をクライアントへ返す
--      → クライアントはこのイベントを受け取ってから物理移動・FocusPosを開始
--   ④ クライアントが待機完了後 syncfix:releaseHardFixIsolation を発火
--   ⑤ サーバーが元のバケットに戻す
--      → クライアントは syncfix:hardFixRestored を受け取り元座標へ復帰
--
-- バケット番号: src + 50000
--   → 通常ゲームプレイで 50000 番台を使うことはほぼない
--   → プレイヤーごとにユニークなので衝突しない
-- ========================================================

-- 隔離中プレイヤーの元バケットを保存するテーブル
local isolatedPlayers = {}

RegisterNetEvent('syncfix:requestHardFixIsolation', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    -- レート制限（HardFix全体のクールダウンはクライアント側で管理済み）
    -- ここでは多重発火防止として5秒間隔チェックのみ
    local ok, _ = checkRateLimit(Player.PlayerData.citizenid, 'hardFixIsolation', 3, 60, 5)
    if not ok then
        TriggerClientEvent('syncfix:hardFixIsolationFailed', src, 'Rate limit exceeded')
        return
    end

    -- すでに隔離中なら無視（二重隔離防止）
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

    -- クライアントに「隔離完了・物理移動開始してよい」を通知
    TriggerClientEvent('syncfix:hardFixIsolated', src, tempBucket)
end)

RegisterNetEvent('syncfix:releaseHardFixIsolation', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local isoData = isolatedPlayers[src]
    if not isoData then
        -- 隔離データがない場合でもバケット0に戻す（フェイルセーフ）
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
-- 隔離タイムアウト監視（フェイルセーフ）
-- 万が一クライアントがクラッシュ・切断した場合に
-- RoutingBucket が 50000 番台のままになるのを防ぐ
-- ========================================================
CreateThread(function()
    while true do
        Wait(10000)  -- 10秒ごとにチェック
        local now = os.time()
        for pid, data in pairs(isolatedPlayers) do
            -- 60秒以上隔離中ならタイムアウトとして強制解除
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
-- [S4] forceDimensionReset - 管理者専用（既存機能は維持）
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

    local ok, _ = checkRateLimit(Player.PlayerData.citizenid, 'dimensionReset', 3, 60, 15)
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

-- ========================================================
-- 異常座標の自動検知スレッド
-- ========================================================
CreateThread(function()
    while true do
        Wait(30000)
        for _, playerId in ipairs(GetPlayers()) do
            TriggerClientEvent('syncfix:checkCoordinates', tonumber(playerId))
        end
    end
end)

-- ========================================================
-- 初期化ログ
-- ========================================================
CreateThread(function()
    Wait(1000)
    print('^2[SyncFix] ^7QBX server initialized (v2.2.0)')
    if hasOxLib then
        print('^2[SyncFix] ^7Running with ox_lib integration')
    else
        print('^3[SyncFix] ^7Running in fallback mode (no ox_lib)')
    end
    if Config.Discord.Enabled and Config.Discord.WebhookURL ~= 'YOUR_DISCORD_WEBHOOK_URL_HERE' then
        print('^2[SyncFix] ^7Discord notification enabled')
    else
        print('^3[SyncFix] ^7Discord: set WebhookURL in config.lua')
    end
    print('^2[SyncFix] ^7HardFix: RoutingBucket isolation mode enabled')
end)

-- ========================================================
-- 全体強制同期
-- ========================================================
local function forceGlobalSync()
    local players = GetPlayers()
    print('^3[SyncManager] Global sync reset START: ' .. #players .. ' players^7')
    for _, playerId in ipairs(players) do
        TriggerClientEvent('syncmanager:forceReset', tonumber(playerId))
    end
    SetTimeout(5000, function()
        for _, playerId in ipairs(players) do
            TriggerClientEvent('syncfix:notify', tonumber(playerId), {
                title='Server Sync', description='Server-wide sync has been reset', type='info'
            })
        end
        print('^2[SyncManager] Global sync reset DONE^7')
    end)
end

if hasOxLib then
    lib.addCommand('forcesync', {
        help='Global sync reset (admin only)', restricted='group.admin'
    }, function(source)
        forceGlobalSync()
        if source ~= 0 then
            TriggerClientEvent('syncfix:notify', source, {
                title='Admin', description='Global sync reset executed', type='success'
            })
        end
    end)
else
    RegisterCommand('forcesync', function(source)
        if source == 0 then forceGlobalSync() return end
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local g = Player.PlayerData.group
        if g == 'admin' or g == 'god' then
            forceGlobalSync()
            TriggerClientEvent('syncfix:notify', source, {title='Admin', description='Global sync reset executed', type='success'})
        else
            TriggerClientEvent('syncfix:notify', source, {title='Error', description='Admin only', type='error'})
        end
    end, false)
end

-- ========================================================
-- [S7] 30分ごとの自動同期（不要な全体通知を抑制）
-- ========================================================
CreateThread(function()
    while true do
        Wait(1800000)
        local players = GetPlayers()
        if #players == 0 then goto continue end

        print('^3[SyncManager] Auto global sync reset START^7')
        local batchSize = 8
        for i = 1, #players, batchSize do
            for j = i, math.min(i + batchSize - 1, #players) do
                TriggerClientEvent('syncmanager:forceReset', tonumber(players[j]))
            end
            if i + batchSize <= #players then Wait(1500) end
        end

        Wait(3000)
        print(string.format('^2[SyncManager] Auto sync DONE: %d players^7', #players))
        ::continue::
    end
end)

-- ========================================================
-- エンティティ存在確認スレッド（ゾンビ検出）
-- ========================================================
CreateThread(function()
    while true do
        Wait(60000)

        -- 1) 車両一覧の取得（環境差分を吸収）
        local vehicles = {}
        local ok, res = pcall(GetAllVehicles)
        if ok and type(res) == 'table' then
            vehicles = res
        else
            local ok2, pool = pcall(GetGamePool, 'CVehicle')
            if ok2 and type(pool) == 'table' then
                vehicles = pool
            end
        end

        -- 2) カウント計算（← これが抜けていた）
        local totalCount = #vehicles
        local ghostCount = 0

        for i = 1, totalCount do
            local veh = vehicles[i]
            -- veh が 0 / nil の場合や、すでに消えている場合を考慮
            if veh and veh ~= 0 and not DoesEntityExist(veh) then
                ghostCount = ghostCount + 1
            end
        end

        -- 3) ログ出力
        if ghostCount > 0 then
            print(string.format('^3[SyncManager] Ghost entities detected: %d/%d^7', ghostCount, totalCount))
        end
    end
end)

print('^2[SyncManager] ^7Server sync manager loaded (v2.2.0)')

