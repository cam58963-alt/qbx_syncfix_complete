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

    local validTypes = { QuickFix = true, HardFix = true, MLOFix = true, Teleport = true }
    if not validTypes[commandType] then
        print(string.format('[SyncFix] Invalid commandType: %s (src:%d)', tostring(commandType), src))
        return
    end

    if not playerStats[citizenid] then
        playerStats[citizenid] = {
            name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
            QuickFix = 0, HardFix = 0, MLOFix = 0, Teleport = 0, lastUsed = os.time()
        }
    end

    playerStats[citizenid][commandType] = (playerStats[citizenid][commandType] or 0) + 1
    playerStats[citizenid].lastUsed     = os.time()

    sendDiscordNotification(src, commandType, details)
    print(string.format('[SyncFix] %s used %s - %s', playerStats[citizenid].name, commandType, details or ''))
end)

-- ========================================================
-- エスコート同期テレポート（連行者 → サーバー → 被連行者）
-- ========================================================
-- 連行者がTPしたとき、被連行者のクライアントにTP指示を中継する。
-- クライアントから届く座標・相手IDはそのまま信用しない:
--   ・行き先は「連行者が今いるポイントの行き先」だけ（座標はサーバーの設定値を使う）
--   ・相手は連行者の近くにいて、連行・搬送・手錠の状態であること
local ESCORT_ORIGIN_MARGIN = 5.0   -- 移動元から離れていてもよい距離（通信の遅れの余裕）
local ESCORT_MAX_DIST      = 8.0   -- 連行者と相手の最大距離
local TRANSPORT_STATES     = { 'isEscorted', 'isCarried', 'isDragged', 'beingDragged', 'cuffed', 'isHandcuffed' }

local function toVec3(c)
    return vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
end

local function hasJob(Player, jobList)
    if not jobList or #jobList == 0 then return true end
    local jobName = Player.PlayerData.job and Player.PlayerData.job.name
    for _, job in ipairs(jobList) do
        if job == jobName then return true end
    end
    return false
end

-- 連行者の現在地から行ける、設定済みの行き先を探す
local function findEscortDestination(src, Player, coords)
    if not tonumber(coords.x) or not tonumber(coords.y) or not tonumber(coords.z) then return nil end
    local tp = Config.Teleports
    if not tp or not tp.Points then return nil end

    local pedCoords = GetEntityCoords(GetPlayerPed(src))
    local requested = toVec3(coords)
    for _, point in ipairs(tp.Points) do
        local nearOrigin = #(pedCoords - toVec3(point.origin)) <= (point.radius or 1.5) + ESCORT_ORIGIN_MARGIN
        if nearOrigin and hasJob(Player, point.jobs) then
            for _, dest in ipairs(point.destinations or {}) do
                if #(requested - toVec3(dest.coords)) < 1.0 then return dest end
            end
        end
    end
    return nil
end

local function isTransported(targetId, TargetPlayer)
    local st = Player(targetId).state
    for _, key in ipairs(TRANSPORT_STATES) do
        if st[key] then return true end
    end
    local meta = TargetPlayer.PlayerData.metadata
    return meta and (meta.isescorted or meta.ishandcuffed) or false
end

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
    if not targetId or targetId == src then return end

    local TargetPlayer = exports.qbx_core:GetPlayer(targetId)
    if not TargetPlayer then
        print(string.format('[SyncFix] escortTeleportSync: target %d not found', targetId))
        return
    end

    -- 距離の検証（連行者の近くにいるか）
    local dist = #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(targetId)))
    if dist > ESCORT_MAX_DIST then
        print(string.format('[SyncFix] escortTeleportSync: target %d is too far from %d (%.1fm), rejecting', targetId, src, dist))
        return
    end

    -- 連行・搬送の状態の検証
    if not isTransported(targetId, TargetPlayer) then
        print(string.format('[SyncFix] escortTeleportSync: target %d is NOT escorted/carried, rejecting', targetId))
        return
    end

    -- 行き先の検証（設定済みの行き先だけ・座標はサーバーの設定値を使う）
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end
    local dest = findEscortDestination(src, Player, coords)
    if not dest then
        print(string.format('[SyncFix] escortTeleportSync: destination from %d is not a configured teleport, rejecting', src))
        return
    end
    local destCoords = { x = dest.coords.x, y = dest.coords.y, z = dest.coords.z, w = dest.coords.w or 0.0 }

    -- 被連行者のクライアントにTP指示を転送（draggerServerId を追加で送信）
    TriggerClientEvent('syncfix:escortTeleportReceive', targetId, destCoords, dest.isMlo or false, src)

    local srcName  = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local tgtName  = TargetPlayer.PlayerData.charinfo.firstname .. ' ' .. TargetPlayer.PlayerData.charinfo.lastname
    print(string.format('[SyncFix] Escort TP sync: %s (ID:%d) → %s (ID:%d) to (%.1f, %.1f, %.1f)',
        srcName, src, tgtName, targetId, destCoords.x, destCoords.y, destCoords.z))
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
        totalUsage   = { QuickFix = 0, HardFix = 0, MLOFix = 0, Teleport = 0 }
    }
    for _, data in pairs(playerStats) do
        statsData.playerCount          = statsData.playerCount + 1
        statsData.totalUsage.QuickFix  = statsData.totalUsage.QuickFix  + data.QuickFix
        statsData.totalUsage.HardFix   = statsData.totalUsage.HardFix   + data.HardFix
        statsData.totalUsage.MLOFix    = statsData.totalUsage.MLOFix    + data.MLOFix
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
