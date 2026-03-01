-- ========================================================
-- client/fixes.lua - 修正処理本体（QuickFix / HardFix / MLOFix / Emergency）
-- ========================================================

-- カウントダウン制御フラグ
CountdownActive = false

-- HardFix RoutingBucket 隔離フラグ
HardFixIsolated = false

-- ========================================================
-- カウントダウン表示
-- ========================================================
local function showCountdown(seconds)
    CountdownActive = true
    CreateThread(function()
        for i = seconds, 1, -1 do
            if not CountdownActive then break end
            ShowNotification('HardFix',
                string.format(Config.Messages.Hard.Countdown, i), 'warning', 1100)
            Wait(1000)
        end
        CountdownActive = false
    end)
end

-- ========================================================
-- HardFix 待機中テキスト表示
-- ========================================================
local function drawHardFixText(stayTime)
    CreateThread(function()
        local endTime = GetGameTimer() + (stayTime * 1000)
        local cfg     = Config.HardFix.WaitingText
        while GetGameTimer() < endTime and CountdownActive do
            local remaining = math.ceil((endTime - GetGameTimer()) / 1000)

            SetTextFont(0); SetTextProportional(1); SetTextScale(0.7, 0.7)
            SetTextColour(100, 200, 255, 255); SetTextDropshadow(0,0,0,0,255)
            SetTextEdge(1,0,0,0,255); SetTextDropShadow(); SetTextOutline(); SetTextCentre(true)
            SetTextEntry('STRING'); AddTextComponentString(cfg.header)
            DrawText(cfg.position.x, cfg.position.y - 0.08)

            SetTextFont(0); SetTextScale(0.4, 0.4); SetTextColour(255,255,255,255)
            SetTextCentre(true); SetTextOutline()
            SetTextEntry('STRING'); AddTextComponentString(cfg.description)
            DrawText(cfg.position.x, cfg.position.y - 0.02)

            SetTextFont(0); SetTextScale(0.6, 0.6); SetTextColour(100,200,255,255)
            SetTextCentre(true); SetTextOutline()
            SetTextEntry('STRING')
            AddTextComponentString(string.format('%d秒後に元の場所に戻ります', remaining))
            DrawText(cfg.position.x, cfg.position.y + 0.05)

            Wait(0)
        end
    end)
end

-- ========================================================
-- QuickFix（ブラックアウト方式・約10秒）
-- ========================================================
function PerformQuickFix()
    local ped     = PlayerPedId()
    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)

    TriggerServerEvent('syncfix:logUsage', 'QuickFix',
        string.format('座標: %.1f, %.1f, %.1f', coords.x, coords.y, coords.z))

    ShowNotification('同期修正', Config.Messages.Quick.Start, 'info')
    TriggerServerEvent('syncfix:forceServerSync')
    TriggerServerEvent('syncfix:resetEntityOwnership')
    Wait(1500)

    DoScreenFadeOut(800)
    local t = 0
    while not IsScreenFadedOut() do Wait(10); t = t + 10; if t > 3000 then break end end

    ShowNotification('同期修正', Config.Messages.Quick.Processing, 'info')

    FreezeEntityPosition(ped, true)
    if vehicle ~= 0 then
        FreezeEntityPosition(vehicle, true)
        SetEntityCoords(vehicle, coords.x, coords.y, coords.z + 0.3, false, false, false, true)
        SetEntityHeading(vehicle, heading)
    else
        SetEntityCoords(ped, coords.x, coords.y, coords.z + 0.3, false, false, false, true)
        SetEntityHeading(ped, heading)
    end

    ClearFocus(); ClearHdArea()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)

    -- 1回目: 広域リロード
    for xOffset = -200, 200, 100 do
        for yOffset = -200, 200, 100 do
            RequestCollisionAtCoord(coords.x + xOffset, coords.y + yOffset, coords.z)
        end
    end
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 200.0, 0)
    WaitNewLoadSceneLoaded(6000)

    local interior = GetInteriorSafe(ped, coords)
    RefreshAndWaitInterior(interior)

    t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do Wait(100); t = t + 100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    Wait(2000)

    -- 2回目: 近距離精密リロード
    ShowNotification('同期修正', '周辺エンティティを再同期中...', 'info')
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 100.0, 0)
    WaitNewLoadSceneLoaded(4000)
    RefreshAndWaitInterior(GetInteriorSafe(ped, coords))

    t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 3000 do Wait(100); t = t + 100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    Wait(500)
    ClearFocus()
    FreezeEntityPosition(ped, false)
    if vehicle ~= 0 then FreezeEntityPosition(vehicle, false) end

    DoScreenFadeIn(800)
    ShowNotification('同期修正', Config.Messages.Quick.Complete, 'success')
end

-- ========================================================
-- HardFix サーバーイベント受信
-- ========================================================
HardFixIsolationReady   = false
HardFixRestorationReady = false

RegisterNetEvent('syncfix:hardFixIsolated', function(bucket)
    HardFixIsolated       = true
    HardFixIsolationReady = true
    print(string.format('^2[SyncFix] ^7HardFix: isolated to bucket %d', bucket))
end)

RegisterNetEvent('syncfix:hardFixRestored', function()
    HardFixIsolated          = false
    HardFixRestorationReady  = true
    print('^2[SyncFix] ^7HardFix: RoutingBucket restored')
end)

RegisterNetEvent('syncfix:hardFixIsolationFailed', function(reason)
    HardFixIsolationReady = true
    print(string.format('^1[SyncFix] HardFix isolation FAILED: %s^7', reason))
end)

-- ========================================================
-- HardFix フェイルセーフ
-- ========================================================
function HardFixFailSafe()
    local _ped = PlayerPedId()
    SetEntityVisible(_ped, true, false)
    SetEntityInvincible(_ped, false)
    SetPedCanRagdoll(_ped, true)
    FreezeEntityPosition(_ped, false)

    if HardFixIsolated then
        TriggerServerEvent('syncfix:releaseHardFixIsolation')
        HardFixIsolated = false
    end

    HardFixIsolationReady   = false
    HardFixRestorationReady = false
    CountdownActive         = false

    ClearFocus()
    DoScreenFadeIn(500)
end

-- ========================================================
-- HardFix（3層隔離方式・約20秒）
-- ========================================================
function PerformHardFix()
    local ped             = PlayerPedId()
    local originalCoords  = GetEntityCoords(ped)
    local originalHeading = GetEntityHeading(ped)
    local vehicle         = GetVehiclePedIsIn(ped, false)
    local safe            = Config.HardFix.SafeCoords
    local stayTime        = Config.HardFix.StayTime

    TriggerServerEvent('syncfix:logUsage', 'HardFix',
        string.format('元座標: %.1f, %.1f, %.1f', originalCoords.x, originalCoords.y, originalCoords.z))

    ShowNotification('強力修正', Config.Messages.Hard.Start, 'info')
    DoScreenFadeOut(500)
    Wait(600)

    -- フェーズ1: RoutingBucket 隔離要求
    ShowNotification('強力修正', Config.Messages.Hard.Moving, 'warning')
    HardFixIsolationReady = false
    TriggerServerEvent('syncfix:requestHardFixIsolation')

    local isoWait = 0
    while not HardFixIsolationReady and isoWait < 3000 do
        Wait(100); isoWait = isoWait + 100
    end
    if not HardFixIsolationReady then
        print('^3[SyncFix] HardFix: RoutingBucket isolation timeout, continuing without it^7')
    end

    -- フェーズ2: Freeze + ストリーミング切断 + 物理移動
    ClearFocus(); ClearHdArea()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    ClearPedTasksImmediately(ped)

    if vehicle ~= 0 then
        FreezeEntityPosition(vehicle, true)
        SetEntityCollision(vehicle, false, false)
        SetEntityCoords(vehicle, safe.x, safe.y, safe.z, false, false, false, false)
        SetEntityHeading(vehicle, safe.w)
        SetEntityCollision(vehicle, true, true)
    else
        SetEntityCollision(ped, false, false)
        SetEntityCoords(ped, safe.x, safe.y, safe.z, false, false, false, false)
        SetEntityHeading(ped, safe.w)
        SetEntityCollision(ped, true, true)
    end

    ClearPedTasksImmediately(ped)
    Wait(100)
    ClearPedTasksImmediately(ped)

    SetEntityVisible(ped, false, false)
    if vehicle ~= 0 then SetEntityVisible(vehicle, false, false) end

    SetFocusPosAndVel(safe.x, safe.y, safe.z, 0.0, 0.0, 0.0)
    NewLoadSceneStart(safe.x, safe.y, safe.z, safe.x, safe.y, safe.z, 50.0, 0)

    local unloadWait = 0
    while IsNewLoadSceneActive() and unloadWait < 2000 do
        Wait(100); unloadWait = unloadWait + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    -- フェーズ3: 待機
    Wait(500)
    DoScreenFadeIn(500)
    ShowNotification('強力修正', Config.Messages.Hard.Waiting, 'warning', 2000)
    Wait(800)

    showCountdown(stayTime)
    drawHardFixText(stayTime)

    -- 後半からプリロード開始
    CreateThread(function()
        Wait(math.floor(stayTime / 2) * 1000)
        SetFocusPosAndVel(originalCoords.x, originalCoords.y, originalCoords.z, 0.0, 0.0, 0.0)
        RequestCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
        RequestAdditionalCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
    end)

    Wait(stayTime * 1000)

    -- フェーズ4: RoutingBucket 解除
    CountdownActive = false
    HardFixRestorationReady = false
    TriggerServerEvent('syncfix:releaseHardFixIsolation')

    local restoreWait = 0
    while not HardFixRestorationReady and restoreWait < 3000 do
        Wait(100); restoreWait = restoreWait + 100
    end

    -- フェーズ5: 元の場所へ復帰
    ShowNotification('強力修正', Config.Messages.Hard.Returning, 'info')
    DoScreenFadeOut(500)
    Wait(500)

    SetEntityVisible(ped, true, false)
    if vehicle ~= 0 then SetEntityVisible(vehicle, true, false) end

    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)

    ClearFocus()
    SetFocusPosAndVel(originalCoords.x, originalCoords.y, originalCoords.z, 0.0, 0.0, 0.0)
    NewLoadSceneStart(
        originalCoords.x, originalCoords.y, originalCoords.z,
        originalCoords.x, originalCoords.y, originalCoords.z, 200.0, 0)
    WaitNewLoadSceneLoaded(8000)
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    local interior = GetInteriorAtCoords(originalCoords.x, originalCoords.y, originalCoords.z)
    local okInterior = RefreshAndWaitInterior(interior)

    -- ★ バグ修正: MLOFixは必ず物理復帰「後」に実行する
    -- （PerformMLOFix は GetEntityCoords(ped) で現在座標を取得するため、
    --   ped がまだ安全座標にいる段階で呼ぶと 12000,12000,2001 で実行されてしまう）

    Wait(1500)

    -- ★ 物理復帰を先に実行
    if vehicle ~= 0 then
        SetEntityCoords(vehicle, originalCoords.x, originalCoords.y, originalCoords.z + 0.5,
            false, false, false, true)
        SetEntityHeading(vehicle, originalHeading)
        FreezeEntityPosition(vehicle, false)
    else
        SetEntityCoords(ped, originalCoords.x, originalCoords.y, originalCoords.z + 0.5,
            false, false, false, true)
        SetEntityHeading(ped, originalHeading)
    end
    FreezeEntityPosition(ped, false)

    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 8000 do
        RequestCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
        Wait(100); t = t + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    ClearPedTasksImmediately(ped)

    -- ★ カメラリセット（上空見下ろしアングル防止）
    ClearFocus()
    ClearHdArea()

    -- ★ 物理復帰「後」にinteriorが未readyならMLOFixを実行
    if interior ~= 0 and not okInterior then
        print('^3[SyncFix] HardFix: interior not ready -> fallback to MLOFix^7')
        pcall(PerformMLOFix)
    end

    Wait(500)
    DoScreenFadeIn(500)
    ShowNotification('強力修正', Config.Messages.Hard.Complete, 'success')
end

-- ========================================================
-- MLOFix（ポータルリセット強化版）
-- ========================================================
function PerformMLOFix()
    local ped     = PlayerPedId()
    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local interior = GetInteriorFromEntity(ped)

    if interior == 0 then
        interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    end
    -- 周囲探索
    if interior == 0 then
        for xOffset = -10, 10, 5 do
            for yOffset = -10, 10, 5 do
                interior = GetInteriorAtCoords(coords.x + xOffset, coords.y + yOffset, coords.z)
                if interior ~= 0 then break end
            end
            if interior ~= 0 then break end
        end
    end

    TriggerServerEvent('syncfix:logUsage', 'MLOFix',
        string.format('インテリアID: %d, 座標: %.1f, %.1f, %.1f', interior, coords.x, coords.y, coords.z))

    ShowNotification('MLO修正', 'ポータル判定とインテリアを修復中...', 'info')
    DoScreenFadeOut(300)
    Wait(300)

    ShowNotification('MLO修正', 'ポータル通過判定をリセット中...', 'info')
    FreezeEntityPosition(ped, true)

    -- ポータル判定リセット（一瞬上空移動→復帰）
    SetEntityCoords(ped, coords.x, coords.y, coords.z + 30.0, false, false, false, false)
    Wait(100)
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, heading)
    Wait(100)

    if interior ~= 0 then
        if IsInteriorLocked() then
            -- ★ 保護中: RefreshInterior/DisableInterior をスキップ
            -- 強盗等でスクリプトが壁状態を管理しているためリセット禁止
            ShowNotification('MLO修正', 'このエリアは保護中のため、コリジョン再読込のみ実行', 'warning')
            print(string.format('^3[SyncFix] ^7MLOFix: interior %d is locked, skipping RefreshInterior', interior))
        else
            ShowNotification('MLO修正', 'インテリアデータを完全リフレッシュ中...', 'info')
            PinInteriorInMemory(interior)
            for i = 1, 3 do RefreshInterior(interior); Wait(100) end
            DisableInterior(interior, true)
            Wait(200)
            DisableInterior(interior, false)

            local timeout = 0
            while not IsInteriorReady(interior) and timeout < 3000 do
                Wait(100); timeout = timeout + 100
            end
        end
    end

    ClearFocus()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)

    for xOffset = -30, 30, 15 do
        for yOffset = -30, 30, 15 do
            RequestCollisionAtCoord(coords.x + xOffset, coords.y + yOffset, coords.z)
        end
    end

    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 80.0, 0)

    local timeout = 0
    while not HasCollisionLoadedAroundEntity(ped) and timeout < 5000 do
        Wait(100); timeout = timeout + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    FreezeEntityPosition(ped, false)
    Wait(500)
    ClearFocus()
    DoScreenFadeIn(300)

    if interior ~= 0 then
        ShowNotification('MLO修正', string.format('インテリア(ID:%d)のポータル判定を修復しました', interior), 'success')
    else
        ShowNotification('MLO修正', '周辺の読み込みを強制リセットしました', 'success')
    end
end

-- ========================================================
-- 緊急脱出（サーバー確認 → 実行）
-- ========================================================
function PerformEmergencyEscape()
    if not Config.Emergency.Enabled then
        ShowNotification('緊急脱出', 'この機能は無効化されています', 'error')
        return
    end
    -- クライアント側の戦闘チェック（IsPedInMeleeCombat/IsPedInCombat はクライアント専用native）
    if Config.Emergency.Restrictions.BlockIfInCombat then
        local ped = PlayerPedId()
        if IsPedInMeleeCombat(ped) or IsPedInCombat(ped, 0) then
            ShowNotification('緊急脱出',
                string.format('%s\n理由: 戦闘中', Config.Messages.Emergency.Blocked), 'error')
            IsFixProcessing = false
            return
        end
    end
    TriggerServerEvent('syncfix:checkEmergencyRestrictions')
end

RegisterNetEvent('syncfix:emergencyCheckResult', function(restrictions)
    if #restrictions > 0 then
        local restrictionText = table.concat(restrictions, '、')
        ShowNotification('緊急脱出',
            string.format('%s\n理由: %s', Config.Messages.Emergency.Blocked, restrictionText), 'error')
        IsFixProcessing = false
        return
    end

    local ped           = PlayerPedId()
    local currentCoords = GetEntityCoords(ped)

    TriggerServerEvent('syncfix:logUsage', 'Emergency',
        string.format('脱出元: %.1f, %.1f, %.1f', currentCoords.x, currentCoords.y, currentCoords.z))

    ShowNotification('緊急脱出', Config.Messages.Emergency.Start, 'warning')
    DoScreenFadeOut(500)
    Wait(500)

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 then
        TaskLeaveVehicle(ped, vehicle, 0)
        Wait(1000)
    end

    ShowNotification('緊急脱出', Config.Messages.Emergency.Moving, 'info')

    local escape = Config.Emergency.EscapeLocation
    SetEntityCoords(ped, escape.x, escape.y, escape.z, false, false, false, true)
    SetEntityHeading(ped, escape.w)

    RequestCollisionAtCoord(escape.x, escape.y, escape.z)
    NewLoadSceneStart(escape.x, escape.y, escape.z, escape.x, escape.y, escape.z, 100.0, 0)

    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do Wait(100); t = t + 100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    Wait(1000)
    DoScreenFadeIn(500)
    ShowNotification('緊急脱出', Config.Messages.Emergency.Complete, 'success')
    IsFixProcessing = false
end)
