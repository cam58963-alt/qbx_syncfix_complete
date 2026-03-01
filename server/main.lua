-- ========================================================
-- server/main.lua - コア機能（レート制限・Discord・ログ・同期イベント）
-- ========================================================

local playerStats     = {}
local serverStartTime = os.time()

-- ========================================================
-- レート制限
-- ========================================================
local eventRateLimits = {}

function CheckRateLimit(citizenid, eventName, maxCalls, windowSec, minIntervalSec)
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

ServerHasOxLib = GetResourceState('ox_lib') == 'started'

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
        QuickFix  = '軽量修正 (/'  .. Config.Commands.QuickFix  .. ')',
        HardFix   = '徹底修正 (/'   .. Config.Commands.HardFix   .. ')',
        MLOFix    = 'MLO修正 (/'    .. Config.Commands.MLOFix    .. ')',
        Emergency = '緊急脱出 (/' .. Config.Commands.Emergency .. ')',
        Teleport  = 'テレポート'
    }

    local embed = {{
        title  = 'SyncFix 使用ログ',
        color  = Config.Discord.Colors[commandType] or 3447003,
        fields = {
            { name = 'プレイヤー',  value = string.format('**名前:** %s\n**サーバーID:** %s\n**市民ID:** %s', playerName, source, citizenid), inline = true },
            { name = 'コマンド', value = commandNames[commandType] or commandType, inline = true },
            { name = '詳細', value = extraInfo or 'なし', inline = false },
            { name = 'Discord', value = discordId ~= 'N/A' and string.format('<@%s>', discordId) or '未連携', inline = true }
        },
        footer    = { text = string.format('%s | %s', Config.Discord.ServerName, os.date('%Y-%m-%d %H:%M:%S')) },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%S')
    }}

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
-- 使用ログ
-- ========================================================
RegisterNetEvent('syncfix:logUsage', function(commandType, details)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local ok, reason = CheckRateLimit(citizenid, 'logUsage', 6, 60, 8)
    if not ok then
        print(string.format('[SyncFix] logUsage blocked %s: %s', citizenid, reason))
        return
    end

    local validTypes = { QuickFix = true, HardFix = true, MLOFix = true, Emergency = true, Teleport = true }
    if not validTypes[commandType] then
        print(string.format('[SyncFix] Invalid commandType: %s (src:%d)', tostring(commandType), src))
        return
    end

    if not playerStats[citizenid] then
        playerStats[citizenid] = {
            name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
            QuickFix = 0, HardFix = 0, MLOFix = 0, Emergency = 0, Teleport = 0, lastUsed = os.time()
        }
    end

    playerStats[citizenid][commandType] = (playerStats[citizenid][commandType] or 0) + 1
    playerStats[citizenid].lastUsed     = os.time()

    sendDiscordNotification(src, commandType, details)
    print(string.format('[SyncFix] %s used %s - %s', playerStats[citizenid].name, commandType, details or ''))
end)

-- ========================================================
-- 緊急脱出制限チェック
-- ========================================================
RegisterNetEvent('syncfix:checkEmergencyRestrictions', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, reason = CheckRateLimit(Player.PlayerData.citizenid, 'emergencyCheck', 5, 60, 10)
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
    -- BlockIfInCombat はクライアント側で IsPedInCombat() を使って判定済み（server native なし）
    TriggerClientEvent('syncfix:emergencyCheckResult', src, restrictions)
end)

-- ========================================================
-- 同期イベント
-- ========================================================
RegisterNetEvent('syncfix:forceServerSync', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, reason = CheckRateLimit(Player.PlayerData.citizenid, 'forceServerSync', 4, 60, 15)
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

RegisterNetEvent('syncfix:resetEntityOwnership', function()
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local ok, _ = CheckRateLimit(Player.PlayerData.citizenid, 'resetOwnership', 3, 60, 15)
    if not ok then return end

    print(string.format('^2[SyncFix] Entity ownership reset requested by player %d^7', src))
    TriggerClientEvent('syncfix:refreshEntityOwnership', src)
end)

-- ========================================================
-- エスコート同期テレポート（連行者 → サーバー → 被連行者）
-- ========================================================
-- 連行者がTPしたとき、被連行者のクライアントにTP指示を中継する
RegisterNetEvent('syncfix:escortTeleportSync', function(targetServerId, coords, isMlo)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    -- レート制限
    local ok, reason = CheckRateLimit(Player.PlayerData.citizenid, 'escortTpSync', 5, 60, 3)
    if not ok then
        print(string.format('[SyncFix] escortTeleportSync blocked %s: %s', Player.PlayerData.citizenid, reason))
        return
    end

    -- ターゲット検証
    local targetId = tonumber(targetServerId)
    if not targetId then return end

    local TargetPlayer = exports.qbx_core:GetPlayer(targetId)
    if not TargetPlayer then
        print(string.format('[SyncFix] escortTeleportSync: target %d not found', targetId))
        return
    end

    -- エスコート関係の検証（被連行者が実際にエスコート状態か確認）
    local targetMeta = TargetPlayer.PlayerData.metadata
    if not targetMeta or not targetMeta.isescorted then
        print(string.format('[SyncFix] escortTeleportSync: target %d is NOT escorted, rejecting', targetId))
        return
    end

    -- 座標検証
    if type(coords) ~= 'table' or not coords.x or not coords.y or not coords.z then
        print(string.format('[SyncFix] escortTeleportSync: invalid coords from %d', src))
        return
    end

    -- 被連行者のクライアントにTP指示を転送（draggerServerId を追加で送信）
    TriggerClientEvent('syncfix:escortTeleportReceive', targetId, coords, isMlo, src)

    local srcName  = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local tgtName  = TargetPlayer.PlayerData.charinfo.firstname .. ' ' .. TargetPlayer.PlayerData.charinfo.lastname
    print(string.format('[SyncFix] Escort TP sync: %s (ID:%d) → %s (ID:%d) to (%.1f, %.1f, %.1f)',
        srcName, src, tgtName, targetId, coords.x, coords.y, coords.z))
end)

-- 被連行者のTP完了通知 → 連行者に中継
RegisterNetEvent('syncfix:escortTeleportComplete', function(draggerServerId)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local draggerId = tonumber(draggerServerId)
    if not draggerId then return end

    local DraggerPlayer = exports.qbx_core:GetPlayer(draggerId)
    if not DraggerPlayer then return end

    -- 連行者のクライアントに完了通知を転送
    TriggerClientEvent('syncfix:escortTeleportReady', draggerId)
    print(string.format('[SyncFix] Escort TP complete: target %d notified dragger %d', src, draggerId))
end)

-- ========================================================
-- 統計データ取得
-- ========================================================
function GetStatsData()
    local statsData = {
        serverUptime = math.floor((os.time() - serverStartTime) / 3600),
        playerCount  = 0,
        totalUsage   = { QuickFix = 0, HardFix = 0, MLOFix = 0, Emergency = 0, Teleport = 0 }
    }
    for _, data in pairs(playerStats) do
        statsData.playerCount          = statsData.playerCount + 1
        statsData.totalUsage.QuickFix  = statsData.totalUsage.QuickFix  + data.QuickFix
        statsData.totalUsage.HardFix   = statsData.totalUsage.HardFix   + data.HardFix
        statsData.totalUsage.MLOFix    = statsData.totalUsage.MLOFix    + data.MLOFix
        statsData.totalUsage.Emergency = statsData.totalUsage.Emergency + data.Emergency
        statsData.totalUsage.Teleport  = statsData.totalUsage.Teleport  + (data.Teleport or 0)
    end
    return statsData
end

-- 外部からアクセス用
function GetPlayerStats()
    return playerStats
end

-- ========================================================
-- 初期化
-- ========================================================
CreateThread(function()
    Wait(1000)
    local resVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?.?.?'
    print('^2[SyncFix] ^7QBX server initialized (v' .. resVersion .. ' modular)')
    if ServerHasOxLib then
        print('^2[SyncFix] ^7Running with ox_lib integration')
    else
        print('^3[SyncFix] ^7Running in fallback mode (no ox_lib)')
    end
    local webhook = getWebhookUrl()
    if Config.Discord.Enabled and webhook ~= '' then
        print('^2[SyncFix] ^7Discord notification enabled')
    else
        print('^3[SyncFix] ^7Discord: set syncfix_webhook convar or WebhookURL in config.lua')
    end
    print('^2[SyncFix] ^7HardFix: RoutingBucket isolation mode enabled')
end)
