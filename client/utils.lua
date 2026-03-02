-- ========================================================
-- client/utils.lua - 共通ユーティリティ（通知・クールダウン）
-- ========================================================

-- ox_lib 確認
HasOxLib = GetResourceState('ox_lib') == 'started'

-- 状態管理（グローバル）
IsFixProcessing = false

-- ========================================================
-- 通知関数（ox_lib フォールバック対応）
-- ========================================================
function ShowNotification(title, message, notifType, duration)
    if HasOxLib then
        lib.notify({
            title       = title,
            description = message,
            type        = notifType or 'info',
            position    = 'top-right',
            duration    = duration or 3000
        })
    else
        SetNotificationTextEntry('STRING')
        AddTextComponentString(string.format('~b~%s:~s~ %s', title, message))
        DrawNotification(false, false)
    end
end

-- ========================================================
-- クールダウン管理
-- ========================================================
local lastUseTime     = 0
local useCount        = 0
local hourlyResetTime = GetGameTimer()

function CheckCooldown()
    local currentTime = GetGameTimer()
    if currentTime - hourlyResetTime > 3600000 then
        useCount        = 0
        hourlyResetTime = currentTime
    end
    if useCount >= Config.Limits.MaxUsesPerHour then
        ShowNotification('使用制限', '1時間の使用制限に達しました', 'error')
        return false
    end
    local timeSinceLastUse = (currentTime - lastUseTime) / 1000
    if timeSinceLastUse < Config.Limits.Cooldown then
        local remaining = math.ceil(Config.Limits.Cooldown - timeSinceLastUse)
        ShowNotification('使用制限', string.format('あと%d秒待ってください', remaining), 'error')
        return false
    end
    lastUseTime = currentTime
    useCount    = useCount + 1
    return true
end

-- 緊急脱出専用クールダウン
local lastEmergencyUse     = 0
local emergencyUseCount    = 0
local emergencyHourlyReset = GetGameTimer()

function CheckEmergencyCooldown()
    local currentTime = GetGameTimer()
    if currentTime - emergencyHourlyReset > 3600000 then
        emergencyUseCount    = 0
        emergencyHourlyReset = currentTime
    end
    if emergencyUseCount >= Config.Emergency.MaxUsesPerHour then
        ShowNotification('緊急脱出制限', '1時間の使用制限に達しました', 'error')
        return false
    end
    local timeSinceLastUse = (currentTime - lastEmergencyUse) / 1000
    if timeSinceLastUse < Config.Emergency.Cooldown then
        local remaining = math.ceil(Config.Emergency.Cooldown - timeSinceLastUse)
        ShowNotification('緊急脱出制限', string.format('あと%d秒待ってください', remaining), 'error')
        return false
    end
    lastEmergencyUse  = currentTime
    emergencyUseCount = emergencyUseCount + 1
    return true
end

-- ========================================================
-- JOB制限チェック（TPポイントごとのjob制限）
-- ========================================================
-- point.jobs が設定されている場合、プレイヤーの現在のjobが
-- リスト内に含まれていなければ false を返す。
-- point.jobs が nil / 空テーブル → 制限なし（全員使用可能）
--
-- 使用例:
--   point.jobs = {'ambulance'}            -- EMS専用
--   point.jobs = {'ambulance', 'police'}  -- EMS + 警察
--   point.jobs = nil                      -- 制限なし
-- ========================================================

--- プレイヤーの現在の job name を取得
--- @return string jobName (取得失敗時は空文字)
function GetPlayerJobName()
    -- QBX (qbx_core) を優先
    if exports.qbx_core then
        local ok, data = pcall(function()
            return exports.qbx_core:GetPlayerData()
        end)
        if ok and data and data.job and data.job.name then
            return data.job.name
        end
    end
    -- qb-core フォールバック
    local ok, QBCore = pcall(function()
        return exports['qb-core']:GetCoreObject()
    end)
    if ok and QBCore then
        local pd = QBCore.Functions.GetPlayerData()
        if pd and pd.job and pd.job.name then
            return pd.job.name
        end
    end
    return ''
end

--- TPポイントの job 制限をチェック
--- @param point table TPポイント設定 (point.jobs を参照)
--- @param silent boolean? true なら通知を出さない（マーカー非表示用）
--- @return boolean allowed
function CheckJobRestriction(point, silent)
    -- jobs が未設定 or 空テーブル → 制限なし
    if not point.jobs or #point.jobs == 0 then
        return true
    end

    local currentJob = GetPlayerJobName()

    for _, allowedJob in ipairs(point.jobs) do
        if currentJob == allowedJob then
            return true
        end
    end

    -- 制限に引っかかった
    if not silent then
        ShowNotification('テレポート', Config.Messages.Teleport.BlockedJob or 'この職業では使用できません', 'error')
    end
    return false
end

-- ========================================================
-- 実行ラッパー（pcall + isProcessing 管理）
-- ========================================================
function RunFix(cooldownFn, fn, onError, onSuccess)
    if IsFixProcessing then
        ShowNotification('処理中', '修正処理を実行中です', 'error')
        return
    end
    if cooldownFn and not cooldownFn() then return end

    IsFixProcessing = true
    CreateThread(function()
        local ok, err = pcall(fn)
        if not ok then
            if onError then onError(err) end
            IsFixProcessing = false
            return
        end
        if onSuccess then pcall(onSuccess) end
        IsFixProcessing = false
    end)
end
