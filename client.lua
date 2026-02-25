-- ========================================================
-- client.lua (v2.2.0)
-- 変更点 (v2.2):
--  [v2.2-C1] createVirtualRoom / destroyVirtualRoom / カメラ関数を完全削除
--            props生成は不要（FreezeEntityPosition で落下防止）
--  [v2.2-C2] performHardFix を 3層隔離方式に全面刷新
--            Layer1: FreezeEntityPosition  → 物理落下防止
--            Layer2: SetFocusPosAndVel     → ストリーミング強制切替
--            Layer3: RoutingBucket (server) → ネットワークエンティティ分離
--  [v2.2-C3] drawHardFixText を独立関数に整理
--            Config.VirtualRoom 参照を Config.HardFix に変更
--  既存修正の継続:
--  [C1] performEmergencyEscape の isProcessing バグ修正
--  [C2] NetworkSetEntityInvisibleToNetwork の誤用修正
--  [C3] SetEntityLodDist 5000 → 500
--  [C4] pcall エラーハンドリング
--  [C5] NewLoadSceneStop() 追加
--  [C6] showCountdown キャンセルフラグ対応
--  [C7] NetworkRequestControlOfEntity 誤用修正
-- ========================================================

-- ========== 初期化 ==========
CreateThread(function()
    print('^2[SyncFix] ^7Client initialized (v2.2.0)')
end)

-- 状態管理
local isProcessing        = false
local lastUseTime         = 0
local useCount            = 0
local hourlyResetTime     = GetGameTimer()

-- 緊急脱出専用
local lastEmergencyUse    = 0
local emergencyUseCount   = 0
local emergencyHourlyReset = GetGameTimer()

-- [C6] カウントダウンキャンセルフラグ
local countdownActive = false

-- [v2.2] HardFix RoutingBucket 隔離フラグ
local hardFixIsolated = false

-- ox_lib確認
local hasOxLib = GetResourceState('ox_lib') == 'started'

-- ========================================================
-- 通知関数（ox_libフォールバック対応）
-- ========================================================
local function showNotification(title, message, notifType, duration)
    if hasOxLib then
        lib.notify({
            title    = title,
            description = message,
            type     = notifType or 'info',
            position = 'top-right',
            duration = duration or 3000
        })
    else
        SetNotificationTextEntry('STRING')
        AddTextComponentString(string.format('~b~%s:~s~ %s', title, message))
        DrawNotification(false, false)
    end
end

-- ========================================================
-- Streaming/Interior 待機ヘルパー（MLO透明化対策）
-- ========================================================
local function waitNewLoadSceneLoaded(timeoutMs)
    timeoutMs = timeoutMs or 7000
    local start = GetGameTimer()
    while not IsNewLoadSceneLoaded() and (GetGameTimer() - start) < timeoutMs do
        Wait(0)
    end
end

local IsInteriorReadyNative = IsInteriorReady
local function isInteriorReadySafe(interior)
    if not interior or interior == 0 then return true end
    if type(IsInteriorReadyNative) ~= 'function' then return false end
    return IsInteriorReadyNative(interior)
end

local function waitInteriorReady(interior, timeoutMs)
    timeoutMs = timeoutMs or 6000
    if not interior or interior == 0 then return true end

    local start = GetGameTimer()
    while not IsInteriorReady(interior) and (GetGameTimer() - start) < timeoutMs do
        Wait(50)
    end
    return IsInteriorReady(interior)
end

local function getInteriorSafe(ped, coords)
    local interior = GetInteriorFromEntity(ped)
    if interior == 0 then
        interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    end
    return interior
end

local function refreshAndWaitInterior(interior)
    if interior and interior ~= 0 then
        PinInteriorInMemory(interior)
        RefreshInterior(interior)
        SetInteriorActive(interior, true)
        return waitInteriorReady(interior, 7000)
    end
    return true
end

-- ========================================================
-- MLO/Interior 強制ロード（椅子/扉/ワープの透明化対策）
-- ========================================================
local function forceStreamAt(coords, radius, timeoutMs)
    radius = radius or 90.0
    timeoutMs = timeoutMs or 6000

    ClearFocus()
    ClearHdArea()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)

    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, radius, 0)

    local start = GetGameTimer()
    while not IsNewLoadSceneLoaded() and (GetGameTimer() - start) < timeoutMs do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
        Wait(0)
    end

    if IsNewLoadSceneActive() then
        NewLoadSceneStop()
    end
end

local function refreshInteriorAt(coords, timeoutMs)
    timeoutMs = timeoutMs or 5000

    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    if interior == 0 then return 0 end

    PinInteriorInMemory(interior)  -- old name: _LOAD_INTERIOR [Source](https://docs.fivem.net/natives/?_0x2CA429C029CCF247)
    RefreshInterior(interior)
    SetInteriorActive(interior, true)

    local start = GetGameTimer()
    while not IsInteriorReady(interior) and (GetGameTimer() - start) < timeoutMs do
        Wait(50)
    end

    return interior
end

local function ensureMloLoadedAtCoords(coords)
    -- 広め → Interior refresh → 仕上げ
    forceStreamAt(coords, 140.0, 8000)
    refreshInteriorAt(coords, 6000)
    forceStreamAt(coords, 70.0, 4000)
end

-- 必要なら他リソースからも呼べる
exports('EnsureMloLoadedAtCoords', ensureMloLoadedAtCoords)


-- ========================================================
-- [C6] カウントダウン表示（キャンセル対応版）
-- ========================================================
local function showCountdown(seconds)
    countdownActive = true
    CreateThread(function()
        for i = seconds, 1, -1 do
            if not countdownActive then break end
            local message = string.format(Config.Messages.Hard.Countdown, i)
            showNotification('HardFix', message, 'warning', 1100)
            Wait(1000)
        end
        countdownActive = false
    end)
end

-- ========================================================
-- [v2.2-C3] HardFix 待機中テキスト表示
-- （Config.HardFix.WaitingText を参照）
-- ========================================================
local function drawHardFixText(stayTime)
    CreateThread(function()
        local endTime = GetGameTimer() + (stayTime * 1000)
        local cfg     = Config.HardFix.WaitingText
        while GetGameTimer() < endTime and countdownActive do
            local remaining = math.ceil((endTime - GetGameTimer()) / 1000)

            -- タイトル
            SetTextFont(0); SetTextProportional(1); SetTextScale(0.7, 0.7)
            SetTextColour(100, 200, 255, 255); SetTextDropshadow(0,0,0,0,255)
            SetTextEdge(1,0,0,0,255); SetTextDropShadow(); SetTextOutline(); SetTextCentre(true)
            SetTextEntry('STRING'); AddTextComponentString(cfg.header)
            DrawText(cfg.position.x, cfg.position.y - 0.08)

            -- 説明文
            SetTextFont(0); SetTextScale(0.4, 0.4); SetTextColour(255,255,255,255)
            SetTextCentre(true); SetTextOutline()
            SetTextEntry('STRING'); AddTextComponentString(cfg.description)
            DrawText(cfg.position.x, cfg.position.y - 0.02)

            -- 残り秒数
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
-- クールダウンチェック
-- ========================================================
local function checkCooldown()
    local currentTime = GetGameTimer()
    if currentTime - hourlyResetTime > 3600000 then
        useCount = 0
        hourlyResetTime = currentTime
    end
    if useCount >= Config.Limits.MaxUsesPerHour then
        showNotification('使用制限', '1時間の使用制限に達しました', 'error')
        return false
    end
    local timeSinceLastUse = (currentTime - lastUseTime) / 1000
    if timeSinceLastUse < Config.Limits.Cooldown then
        local remaining = math.ceil(Config.Limits.Cooldown - timeSinceLastUse)
        showNotification('使用制限', string.format('あと%d秒待ってください', remaining), 'error')
        return false
    end
    lastUseTime = currentTime
    useCount    = useCount + 1
    return true
end

local function checkEmergencyCooldown()
    local currentTime = GetGameTimer()
    if currentTime - emergencyHourlyReset > 3600000 then
        emergencyUseCount  = 0
        emergencyHourlyReset = currentTime
    end
    if emergencyUseCount >= Config.Emergency.MaxUsesPerHour then
        showNotification('緊急脱出制限', '1時間の使用制限に達しました', 'error')
        return false
    end
    local timeSinceLastUse = (currentTime - lastEmergencyUse) / 1000
    if timeSinceLastUse < Config.Emergency.Cooldown then
        local remaining = math.ceil(Config.Emergency.Cooldown - timeSinceLastUse)
        showNotification('緊急脱出制限', string.format('あと%d秒待ってください', remaining), 'error')
        return false
    end
    lastEmergencyUse    = currentTime
    emergencyUseCount   = emergencyUseCount + 1
    return true
end

-- ========================================================
-- ブラックアウト修正（QuickFix）
-- [C4] pcall でエラーハンドリング
-- ========================================================
local function performQuickFix()
    -- ========================================
    -- QuickFix 目標処理時間: 約10秒
    -- 内訳:
    --   通知+サーバーイベント : 1.5秒
    --   FadeOut              : 0.8秒
    --   ① 1回目 広域リロード  : 最大3秒
    --   安定待機             : 1.5秒
    --   ② 2回目 近距離リロード : 最大3秒（確実性向上）
    --   FadeIn               : 0.8秒
    --   合計                 : 約9〜11秒
    -- ========================================
    local ped     = PlayerPedId()
    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)

    TriggerServerEvent('syncfix:logUsage', 'QuickFix',
        string.format('Coords: %.1f, %.1f, %.1f', coords.x, coords.y, coords.z))

    showNotification('同期修正', Config.Messages.Quick.Start, 'info')
    TriggerServerEvent('syncfix:forceServerSync')
    TriggerServerEvent('syncfix:resetEntityOwnership')
    Wait(1500)  -- サーバーイベント処理待ち（1000→1500）

    DoScreenFadeOut(800)  -- フェード時間を少し長く（600→800）
    local t = 0
    while not IsScreenFadedOut() do Wait(10); t=t+10; if t>3000 then break end end

    showNotification('同期修正', Config.Messages.Quick.Processing, 'info')

    FreezeEntityPosition(ped, true)
    if vehicle ~= 0 then
        FreezeEntityPosition(vehicle, true)
        SetEntityCoords(vehicle, coords.x, coords.y, coords.z + 0.3, false, false, false, true)
        SetEntityHeading(vehicle, heading)
    else
        SetEntityCoords(ped, coords.x, coords.y, coords.z + 0.3, false, false, false, true)
        SetEntityHeading(ped, heading)
    end

    ClearFocus()
    ClearHdArea()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)

    -- ① 1回目: 広域リロード（半径200m格子状）
    for xOffset = -200, 200, 100 do
        for yOffset = -200, 200, 100 do
            RequestCollisionAtCoord(coords.x + xOffset, coords.y + yOffset, coords.z)
        end
    end
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 200.0, 0)

    -- ✅ 追加：ロード完了待ち（コリジョンだけだと室内が透明化しやすい）
    waitNewLoadSceneLoaded(6000)

    -- ✅ 変更：interior取得を安全に＋ready待ち
    local interior = getInteriorSafe(ped, coords)
    refreshAndWaitInterior(interior)


    t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do Wait(100); t=t+100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end  -- [C5]

    -- 安定待機（エンティティ再同期が落ち着くのを待つ）
    Wait(2000)  -- 1500→2000

    -- ② 2回目: 近距離精密リロード（確実性向上のため追加）
    showNotification('同期修正', '周辺エンティティを再同期中...', 'info')
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 100.0, 0)
    waitNewLoadSceneLoaded(4000)
    local interior2 = getInteriorSafe(ped, coords)
    refreshAndWaitInterior(interior2)


    t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 3000 do Wait(100); t=t+100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end  -- [C5]

    Wait(500)
    ClearFocus()
    FreezeEntityPosition(ped, false)
    if vehicle ~= 0 then FreezeEntityPosition(vehicle, false) end

    DoScreenFadeIn(800)  -- 600→800
    showNotification('同期修正', Config.Messages.Quick.Complete, 'success')
end

-- ========================================================
-- [v2.2-C2] HardFix（3層隔離方式）
--
-- 処理フロー:
--   フェーズ0: 元座標・状態を保存
--   フェーズ1: サーバーへ RoutingBucket 隔離を要求
--              → syncfix:hardFixIsolated イベントで応答待ち
--   フェーズ2: FreezeEntityPosition で落下防止
--              SetFocusPosAndVel で元の場所のストリーミングを切断
--              SetEntityCoords でマップ外座標へ物理移動
--   フェーズ3: 待機中に元の場所がアンロード
--              後半 StayTime/2 秒後から元座標のプリロードをバックグラウンドで開始
--   フェーズ4: サーバーへ RoutingBucket 解除を要求
--              → syncfix:hardFixRestored イベントで応答待ち
--   フェーズ5: 元の座標に物理復帰・コリジョン待機
-- ========================================================

-- hardFix 用の待機フラグ（サーバーイベント応答待ち用）
local hardFixIsolationReady   = false
local hardFixRestorationReady = false

RegisterNetEvent('syncfix:hardFixIsolated', function(bucket)
    hardFixIsolated       = true
    hardFixIsolationReady = true
    print(string.format('^2[SyncFix] ^7HardFix: isolated to bucket %d', bucket))
end)

RegisterNetEvent('syncfix:hardFixRestored', function()
    hardFixIsolated          = false
    hardFixRestorationReady  = true
    print('^2[SyncFix] ^7HardFix: RoutingBucket restored')
end)

RegisterNetEvent('syncfix:hardFixIsolationFailed', function(reason)
    hardFixIsolationReady = true   -- タイムアウト解除のためtrueにする
    print(string.format('^1[SyncFix] HardFix isolation FAILED: %s^7', reason))
end)

local function performHardFix()
    local ped             = PlayerPedId()
    local originalCoords  = GetEntityCoords(ped)
    local originalHeading = GetEntityHeading(ped)
    local vehicle         = GetVehiclePedIsIn(ped, false)
    local safe            = Config.HardFix.SafeCoords
    -- HardFix 目標処理時間: 約20秒
    -- stayTime を config で 12秒に変更することで達成
    -- (RoutingBucket待ち・フェード・HasCollision待ちを含む総計が約20秒)
    local stayTime        = Config.HardFix.StayTime

    TriggerServerEvent('syncfix:logUsage', 'HardFix',
        string.format('Origin: %.1f, %.1f, %.1f', originalCoords.x, originalCoords.y, originalCoords.z))

    showNotification('強力修正', Config.Messages.Hard.Start, 'info')
    DoScreenFadeOut(500)
    Wait(600)

    -- --------------------------------------------------
    -- フェーズ1: Layer3 - RoutingBucket 隔離要求
    -- --------------------------------------------------
    showNotification('強力修正', Config.Messages.Hard.Moving, 'warning')

    hardFixIsolationReady = false
    TriggerServerEvent('syncfix:requestHardFixIsolation')

    -- サーバー応答を最大3秒待機
    local isoWait = 0
    while not hardFixIsolationReady and isoWait < 3000 do
        Wait(100); isoWait = isoWait + 100
    end
    if not hardFixIsolationReady then
        -- タイムアウト時はRoutingBucketなしで続行（Layer1+2のみで動作）
        print('^3[SyncFix] HardFix: RoutingBucket isolation timeout, continuing without it^7')
    end

    -- --------------------------------------------------
    -- フェーズ2: Layer1 - FreezeEntityPosition（落下・水泳防止）
    --            Layer2 - SetFocusPosAndVel（ストリーミング切断）
    --            物理移動（マップ外安全座標へ）
    --
    -- ⚠️ 順序が重要:
    --   ① FreezeEntityPosition(true) を「先に」呼ぶ
    --   ② SetEntityCoords で移動
    --   ③ SetEntityInvincible(true) で死亡/ラグドール防止
    --   ④ SetPedCanRagdoll(false) でラグドール無効化
    --   ⑤ ClearPedTasksImmediately で水泳タスクをキャンセル
    --
    -- フリーズ前に SetEntityCoords すると GTA のコリジョン補正が入り
    -- マップ外の海面(Z=0)に着地 → 水泳モードが発動してしまう
    -- --------------------------------------------------
    ClearFocus()
    ClearHdArea()

    -- Layer1-A: 先にフリーズ（移動前にかける）
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)           -- ダメージ・ラグドール防止
    SetPedCanRagdoll(ped, false)             -- ラグドール完全無効
    ClearPedTasksImmediately(ped)            -- 水泳・落下タスクをキャンセル

    if vehicle ~= 0 then
        FreezeEntityPosition(vehicle, true)
        -- 車両移動: コリジョン無効化してから座標設定
        SetEntityCollision(vehicle, false, false)
        SetEntityCoords(vehicle, safe.x, safe.y, safe.z, false, false, false, false)
        SetEntityHeading(vehicle, safe.w)
        SetEntityCollision(vehicle, true, true)
    else
        -- ped移動: コリジョン無効化してから座標設定
        SetEntityCollision(ped, false, false)
        SetEntityCoords(ped, safe.x, safe.y, safe.z, false, false, false, false)
        SetEntityHeading(ped, safe.w)
        SetEntityCollision(ped, true, true)
    end

    -- Layer1-B: 移動後もタスクキャンセル（水泳開始を確実に防ぐ）
    ClearPedTasksImmediately(ped)
    Wait(100)  -- コリジョン補正が入るフレームを待つ
    ClearPedTasksImmediately(ped)  -- もう一度キャンセル

    -- ★ ped・車両を非表示（バタバタアニメーション防止）
    --   FreezeEntityPosition は「座標」を止めるだけで「アニメーション」は止まらない
    --   地面なし・空中配置 → 落下アニメが再生されバタバタしてしまうため非表示にする
    --   復帰時（フェーズ5）に再表示する
    SetEntityVisible(ped, false, false)
    if vehicle ~= 0 then SetEntityVisible(vehicle, false, false) end

    -- Layer2: ストリーミングフォーカスをマップ外へ切り替え
    --         → 元の場所のエンティティが優先度を失いアンロードされる
    SetFocusPosAndVel(safe.x, safe.y, safe.z, 0.0, 0.0, 0.0)
    NewLoadSceneStart(safe.x, safe.y, safe.z, safe.x, safe.y, safe.z, 50.0, 0)

    local unloadWait = 0
    while IsNewLoadSceneActive() and unloadWait < 2000 do
        Wait(100); unloadWait = unloadWait + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end -- [C5]

    -- --------------------------------------------------
    -- フェーズ3: 待機（アンロード完了を待つ）
    -- --------------------------------------------------
    Wait(500)
    DoScreenFadeIn(500)
    showNotification('強力修正', Config.Messages.Hard.Waiting, 'warning', 2000)
    Wait(800)

    -- カウントダウン＋テキスト表示開始
    showCountdown(stayTime)
    drawHardFixText(stayTime)

    -- 後半から元座標のプリロードをバックグラウンドで開始
    CreateThread(function()
        Wait(math.floor(stayTime / 2) * 1000)
        SetFocusPosAndVel(
            originalCoords.x, originalCoords.y, originalCoords.z,
            0.0, 0.0, 0.0)
        RequestCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
        RequestAdditionalCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
        print('^2[SyncFix] ^7HardFix: preloading origin in background...')
    end)

    Wait(stayTime * 1000)

    -- --------------------------------------------------
    -- フェーズ4: Layer3 - RoutingBucket 解除要求
    -- --------------------------------------------------
    countdownActive = false -- [C6] カウントダウン強制停止

    hardFixRestorationReady = false
    TriggerServerEvent('syncfix:releaseHardFixIsolation')

    -- サーバー応答を最大3秒待機
    local restoreWait = 0
    while not hardFixRestorationReady and restoreWait < 3000 do
        Wait(100); restoreWait = restoreWait + 100
    end

    -- --------------------------------------------------
    -- フェーズ5: 元の場所へ復帰
    -- --------------------------------------------------
    showNotification('強力修正', Config.Messages.Hard.Returning, 'info')
    DoScreenFadeOut(500)
    Wait(500)

    -- ★ ped・車両を再表示（フェーズ2で非表示にしたものを元に戻す）
    SetEntityVisible(ped, true, false)
    if vehicle ~= 0 then SetEntityVisible(vehicle, true, false) end

    -- 無敵・ラグドール設定を戻す
    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)

    ClearFocus()
    SetFocusPosAndVel(originalCoords.x, originalCoords.y, originalCoords.z, 0.0, 0.0, 0.0)

    NewLoadSceneStart(
        originalCoords.x, originalCoords.y, originalCoords.z,
        originalCoords.x, originalCoords.y, originalCoords.z,
        200.0, 0
    )

    waitNewLoadSceneLoaded(8000)

    if IsNewLoadSceneActive() then
        NewLoadSceneStop()
    end
 
    -- ✅ ここで interior を “readyまで待つ”
    local interior = GetInteriorAtCoords(originalCoords.x, originalCoords.y, originalCoords.z)
    local okInterior = refreshAndWaitInterior(interior)

    -- ✅ readyにならない時だけ最終手段（mlofix相当）
    if interior ~= 0 and not okInterior then
        print('^3[SyncFix] HardFix: interior not ready -> fallback to MLOFix^7')
        pcall(performMLOFix)
    end

    Wait(1500)

    -- 元座標に物理復帰
    if vehicle ~= 0 then
        SetEntityCoords(vehicle,
            originalCoords.x, originalCoords.y, originalCoords.z + 0.5,
            false, false, false, true)
        SetEntityHeading(vehicle, originalHeading)
        FreezeEntityPosition(vehicle, false)
    else
        SetEntityCoords(ped,
            originalCoords.x, originalCoords.y, originalCoords.z + 0.5,
            false, false, false, true)
        SetEntityHeading(ped, originalHeading)
    end
    FreezeEntityPosition(ped, false)

    -- コリジョンロード完了を待機
    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 8000 do
        RequestCollisionAtCoord(originalCoords.x, originalCoords.y, originalCoords.z)
        Wait(100); t = t + 100
    end

    if IsNewLoadSceneActive() then NewLoadSceneStop() end -- [C5]

    -- 復帰後の水泳タスク残存クリア（念のため）
    ClearPedTasksImmediately(ped)

    Wait(500)
    ClearFocus()
    DoScreenFadeIn(500)
    showNotification('強力修正', Config.Messages.Hard.Complete, 'success')
end

-- ========================================================
-- MLO修正
-- [C4] pcall ラップ
-- ========================================================
-- MLO修正（ポータルリセット強化版）
local function performMLOFix()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local interior = GetInteriorFromEntity(ped)
    
    -- インテリアIDの徹底的な取得
    if interior == 0 then
        interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    end
    
    -- それでもダメな場合、周囲を探索
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
    
    showNotification('MLO修正', 'ポータル判定とインテリアを修復中...', 'info')
    
    DoScreenFadeOut(300)
    Wait(300)
    
    showNotification('MLO修正', 'ポータル通過判定をリセット中...', 'info')
    
    -- ★重要：ポータル判定の強制リセット
    FreezeEntityPosition(ped, true)
    
    -- 一瞬だけ上空へ移動（ポータル判定リセット）
    local tempCoords = vector3(coords.x, coords.y, coords.z + 30.0)
    SetEntityCoords(ped, tempCoords.x, tempCoords.y, tempCoords.z, false, false, false, false)
    Wait(100)
    
    -- 元の場所に戻す（新規入場として認識させる）
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, heading)
    Wait(100)
    
    -- インテリアの強制読み込み
    if interior ~= 0 then
        showNotification('MLO修正', 'インテリアデータを完全リフレッシュ中...', 'info')
        
        PinInteriorInMemory(interior)
        
        -- 複数回のリフレッシュで確実性向上
        for i = 1, 3 do
            RefreshInterior(interior)
            Wait(100)
        end
        
        -- インテリアの無効化→有効化（完全リセット）
        DisableInterior(interior, true)
        Wait(200)
        DisableInterior(interior, false)
        
        -- インテリア準備完了まで待機
        local timeout = 0
        while not IsInteriorReady(interior) and timeout < 3000 do
            Wait(100)
            timeout = timeout + 100
        end
    end
    
    -- コリジョンの完全再構築
    ClearFocus()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)
    
    -- 広範囲のコリジョン読み込み
    for xOffset = -30, 30, 15 do
        for yOffset = -30, 30, 15 do
            RequestCollisionAtCoord(coords.x + xOffset, coords.y + yOffset, coords.z)
        end
    end
    
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 80.0, 0)
    
    -- コリジョン読み込み完了まで待機
    local timeout = 0
    while not HasCollisionLoadedAroundEntity(ped) and timeout < 5000 do
        Wait(100)
        timeout = timeout + 100
    end
    
    FreezeEntityPosition(ped, false)
    
    Wait(500)
    ClearFocus()
    DoScreenFadeIn(300)
    
    if interior ~= 0 then
        showNotification('MLO修正', string.format('インテリア(ID:%d)のポータル判定を修復しました', interior), 'success')
    else
        showNotification('MLO修正', '周辺の読み込みを強制リセットしました', 'success')
    end
end

-- ========================================================
-- Auto-Fix（ノークリップ誤検知対策版）
--  - “連続”異常速度のみ発火（TP/ジャンプの一発スパイクを除外）
--  - クールダウン付き
--  - isProcessing を勝手に長時間占有しない
-- ========================================================
local function isPedStableForLightReload(ped)
    if IsPedJumping(ped) or IsPedFalling(ped) or IsPedRagdoll(ped) then return false end
    if IsPedRunning(ped) or IsPedSprinting(ped) then return false end
    if GetEntitySpeed(ped) > 1.2 then return false end
    return true
end


local AUTO_NOCLIP_FIX_ENABLED = false
local AUTO_NOCLIP_COOLDOWN_MS = 30000   -- 30秒に1回まで
local AUTO_NOCLIP_SPEED = 50.0          -- m/s
local AUTO_NOCLIP_STREAK = 3            -- 3秒連続で異常速度なら発火

local autoFixBusy = false
local highSpeedStreak = 0
local lastAutoFix = 0

local lastPosition = vector3(0, 0, 0)
local lastCheckTime = 0

CreateThread(function()
    Wait(5000)
    local ped = PlayerPedId()
    lastPosition = GetEntityCoords(ped)
    lastCheckTime = GetGameTimer()

    while true do
        Wait(1000)

        ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local now = GetGameTimer()

        -- ★重要：busyでも基準点は必ず更新（ここがループ防止の肝）
        local dt = math.max(200, now - lastCheckTime) / 1000.0
        local dist = #(coords - lastPosition)
        local speed = dist / dt
        lastPosition = coords
        lastCheckTime = now

        if not AUTO_NOCLIP_FIX_ENABLED then goto cont end
        if isProcessing or autoFixBusy then goto cont end
        if IsPedInAnyVehicle(ped, false) then highSpeedStreak = 0; goto cont end

        local interior = GetInteriorFromEntity(ped)
        if interior == 0 then
            interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        end

        -- Interior 状態（座標ベースを優先）
        local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        if interior == 0 then
            interior = GetInteriorFromEntity(ped)
        end

        -- 「未ロード」判定（未ready の時だけ候補にする）
        local interiorNotReady = (interior ~= 0 and not isInteriorReadySafe(interior))

        -- 上空飛行の誤爆対策：地面から高い時は除外
        -- ※数値は好みで調整可。まずは 6.0m 推奨
        local heightAG = GetEntityHeightAboveGround(ped)
        local nearGround = (heightAG <= 6.0)

        -- 最終候補：未ready屋内 + 地面付近 + 高速
        local shouldCountStreak = interiorNotReady and nearGround and (speed > AUTO_NOCLIP_SPEED)

        if shouldCountStreak then
            highSpeedStreak = highSpeedStreak + 1
        else
            highSpeedStreak = 0
        end


        if highSpeedStreak >= AUTO_NOCLIP_STREAK and (now - lastAutoFix) >= AUTO_NOCLIP_COOLDOWN_MS then
            highSpeedStreak = 0
            lastAutoFix = now
            autoFixBusy = true

            -- 日本語printはF8で文字化けするので英語に（不要なら削除OK）
            print(('[Auto-Fix] High-speed + interiorNotReady (int=%d, speed=%.1f, hag=%.1f). Running MLOFix...'):format(
                interior, speed, heightAG
            ))

            CreateThread(function()
                local ok, err = pcall(performMLOFix)
                if not ok then
                    print('^1[SyncFix] Auto-MLOFix ERROR: ' .. tostring(err) .. '^7')
                    ClearFocus()
                    DoScreenFadeIn(300)
                end
                autoFixBusy = false
            end)
        end

        ::cont::
    end
end)

local function ensureInteriorReadyAt(coords, timeoutMs)
    timeoutMs = timeoutMs or 6000
    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    if interior == 0 then return 0 end

    PinInteriorInMemory(interior)
    RefreshInterior(interior)
    SetInteriorActive(interior, true)

    local start = GetGameTimer()
    while not IsInteriorReady(interior) and (GetGameTimer() - start) < timeoutMs do
        Wait(50)
    end

    return interior
end


-- ========================================================
-- 自動MLO復旧（椅子座り/ワープ後に透明化する対策）
-- 椅子リソースを改造せず、こちらで検知→修復
-- ========================================================
local AUTO_MLO_FIX_ENABLED = false
local AUTO_MLO_FIX_COOLDOWN_MS = 15000  -- 15秒に1回まで（重い処理なので）
local TELEPORT_DISTANCE = 6.0          -- 1秒で6m以上移動＝ワープ扱い（徒歩時）

local lastAutoFix = 0
local prevCoords = vector3(0,0,0)
local prevTime = GetGameTimer()
local wasInScenario = false

CreateThread(function()
    Wait(5000) -- 起動直後の安定待ち
    prevCoords = GetEntityCoords(PlayerPedId())
    prevTime = GetGameTimer()

    while true do
        Wait(1000)
        if not AUTO_MLO_FIX_ENABLED then goto continue end
        if isProcessing then goto continue end  -- あなたのSyncFix処理中は干渉しない

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        -- ワープ検知（徒歩で急移動した時）
        local now = GetGameTimer()
        local dt = math.max(1, now - prevTime) / 1000.0
        local dist = #(coords - prevCoords)
        local teleportLike = (dt <= 1.2 and dist >= TELEPORT_DISTANCE and not IsPedInAnyVehicle(ped, false))

        -- 椅子座り等の scenario 検知
        local inScenario = IsPedActiveInScenario(ped)

        -- Interior 状態
        local interior = GetInteriorFromEntity(ped)
        if interior == 0 then
            interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        end
        local interiorNotReady = (interior ~= 0 and not IsInteriorReady(interior))

        -- 「座り始めた瞬間」または「ワープっぽい移動」または「Interiorがreadyじゃない」
        local scenarioJustStarted = (inScenario and not wasInScenario)

        local stable = isPedStableForLightReload(ped)

        -- 椅子の“開始瞬間”は即時が大事なので stable を要求しない
        local shouldLightFix =
            scenarioJustStarted
            or (teleportLike and stable)
            or (interiorNotReady and stable)

        if shouldLightFix and (now - lastAutoFix) > AUTO_MLO_FIX_COOLDOWN_MS then
            lastAutoFix = now
            ensureMloLoadedAtCoords(coords)
        end

        wasInScenario = inScenario
        prevCoords = coords
        prevTime = now
        ::continue::
    end
end)

-- ========================================================
-- 緊急脱出
-- [C1] isProcessing を emergencyCheckResult 側で管理
-- ========================================================
local function performEmergencyEscape()
    if not Config.Emergency.Enabled then
        showNotification('緊急脱出', 'この機能は無効化されています', 'error')
        return
    end
    TriggerServerEvent('syncfix:checkEmergencyRestrictions')
end

-- ========================================================
-- イベント受信処理
-- ========================================================

-- [C1] emergencyCheckResult
RegisterNetEvent('syncfix:emergencyCheckResult', function(restrictions)
    if #restrictions > 0 then
        local restrictionText = table.concat(restrictions, '、')
        showNotification('緊急脱出',
            string.format('%s\n理由: %s', Config.Messages.Emergency.Blocked, restrictionText), 'error')
        isProcessing = false
        return
    end

    local ped           = PlayerPedId()
    local currentCoords = GetEntityCoords(ped)

    TriggerServerEvent('syncfix:logUsage', 'Emergency',
        string.format('Escape from: %.1f, %.1f, %.1f', currentCoords.x, currentCoords.y, currentCoords.z))

    showNotification('緊急脱出', Config.Messages.Emergency.Start, 'warning')
    DoScreenFadeOut(500)
    Wait(500)

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 then
        TaskLeaveVehicle(ped, vehicle, 0)
        Wait(1000)
    end

    showNotification('緊急脱出', Config.Messages.Emergency.Moving, 'info')

    local escape = Config.Emergency.EscapeLocation
    SetEntityCoords(ped, escape.x, escape.y, escape.z, false, false, false, true)
    SetEntityHeading(ped, escape.w)

    RequestCollisionAtCoord(escape.x, escape.y, escape.z)
    NewLoadSceneStart(escape.x, escape.y, escape.z, escape.x, escape.y, escape.z, 100.0, 0)

    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do Wait(100); t=t+100 end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end -- [C5]

    Wait(1000)
    DoScreenFadeIn(500)
    showNotification('緊急脱出', Config.Messages.Emergency.Complete, 'success')

    isProcessing = false
end)

-- 汎用通知受信
RegisterNetEvent('syncfix:notify', function(data)
    showNotification(data.title or 'SyncFix', data.description or '', data.type or 'info')
end)

-- ========================================================
-- syncfix:receiveSyncPulse
-- [C2] NetworkSetEntityInvisibleToNetwork を他プレイヤーへ適用しない
-- [C3] SetEntityLodDist 5000 → 500
-- [C7] NetworkRequestControlOfEntity を他プレイヤーペドに使用しない
-- ========================================================
RegisterNetEvent('syncfix:receiveSyncPulse', function(sourcePid)
    local myPed    = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local fixCount = 0

    local players = GetActivePlayers()
    for _, player in ipairs(players) do
        local targetPed = GetPlayerPed(player)
        if targetPed ~= myPed and DoesEntityExist(targetPed) then
            local targetCoords = GetEntityCoords(targetPed)
            local distance     = #(myCoords - targetCoords)
            if distance < 300.0 then
                SetEntityVisible(targetPed, true, false)
                SetEntityAlpha(targetPed, 255, false)
                SetEntityLodDist(targetPed, 500) -- [C3]
                fixCount = fixCount + 1
            end
        end
    end

    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        local vehCoords = GetEntityCoords(vehicle)
        if #(myCoords - vehCoords) < 200.0 then
            SetEntityVisible(vehicle, true, false)
            SetEntityAlpha(vehicle, 255, false)
            SetEntityLodDist(vehicle, 500) -- [C3]
        end
    end

    if fixCount > 0 then
        showNotification('サーバー同期',
            string.format('%d個のエンティティを再同期しました', fixCount), 'success')
    end
end)

-- ========================================================
-- その他イベント受信
-- ========================================================
RegisterNetEvent('syncfix:emergencySync', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    showNotification('緊急同期', 'サーバーから緊急同期指示を受信', 'warning')
    DoScreenFadeOut(500)
    Wait(500)
    ClearFocus(); ClearHdArea()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 500.0, 0)
    Wait(3000)
    if IsNewLoadSceneActive() then NewLoadSceneStop() end -- [C5]
    ClearFocus()
    DoScreenFadeIn(500)
    showNotification('緊急同期', '緊急同期が完了しました', 'success')
end)

RegisterNetEvent('syncfix:dimensionResetComplete', function()
    showNotification('次元同期', '次元間移動による同期リセット完了', 'success')
end)

-- ========================================================
-- syncmanager:forceReset
-- [C2] NetworkSetEntityInvisibleToNetwork 削除
-- [C3] LOD距離 5000 → 500
-- ========================================================
RegisterNetEvent('syncmanager:forceReset', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    ClearFocus(); ClearHdArea()

    local players = GetActivePlayers()
    for _, player in ipairs(players) do
        if player ~= PlayerId() then
            local targetPed = GetPlayerPed(player)
            if DoesEntityExist(targetPed) then
                SetEntityVisible(targetPed, true, false)
                SetEntityAlpha(targetPed, 255, false)
                SetEntityLodDist(targetPed, 500) -- [C3]
            end
        end
    end

    local vehicles = GetGamePool('CVehicle')
    for _, veh in ipairs(vehicles) do
        SetEntityVisible(veh, true, false)
        SetEntityAlpha(veh, 255, false)
        SetEntityLodDist(veh, 500) -- [C3]
    end

    local objects = GetGamePool('CObject')
    for _, obj in ipairs(objects) do
        local objCoords = GetEntityCoords(obj)
        if #(coords - objCoords) < 200.0 then
            SetEntityVisible(obj, true, false)
            SetEntityAlpha(obj, 255, false)
        end
    end

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 300.0, 0)

    local interior = GetInteriorFromEntity(ped)
    if interior ~= 0 then RefreshInterior(interior) end

    Wait(2000)
    if IsNewLoadSceneActive() then NewLoadSceneStop() end -- [C5]
    ClearFocus()
end)

-- ========================================================
-- 統計・診断イベント
-- ========================================================
RegisterNetEvent('syncfix:showStatsNotification', function(statsData)
    showNotification('SyncFix Statistics', string.format(
        'Uptime: %dh | Users: %d\n/%s: %d | /%s: %d\n/%s: %d | /%s: %d\n(See F8 for details)',
        statsData.serverUptime, statsData.playerCount,
        Config.Commands.QuickFix,  statsData.totalUsage.QuickFix,
        Config.Commands.HardFix,   statsData.totalUsage.HardFix,
        Config.Commands.MLOFix,    statsData.totalUsage.MLOFix,
        Config.Commands.Emergency, statsData.totalUsage.Emergency
    ), 'info', 8000)
end)

RegisterNetEvent('syncfix:checkCoordinates', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    if coords.x ~= coords.x or coords.y ~= coords.y or coords.z ~= coords.z or
       coords.z < -1000.0 or coords.z > 2000.0 then
        TriggerServerEvent('syncfix:reportAbnormalCoords', coords)
    end
end)

RegisterNetEvent('syncfix:showDetailedStats', function(playerStats, summary)
    print('========================================')
    print('       SyncFix Detailed Stats Report    ')
    print('========================================')
    print(string.format('Server Uptime  : %d hours', summary.serverUptime))
    print(string.format('Total Users    : %d', summary.playerCount))
    print('')
    print('Command Usage:')
    print(string.format('  /%s (QuickFix) : %d', Config.Commands.QuickFix,  summary.totalUsage.QuickFix))
    print(string.format('  /%s (HardFix)  : %d', Config.Commands.HardFix,   summary.totalUsage.HardFix))
    print(string.format('  /%s (MLOFix)   : %d', Config.Commands.MLOFix,    summary.totalUsage.MLOFix))
    print(string.format('  /%s (Emergency): %d', Config.Commands.Emergency, summary.totalUsage.Emergency))
    print('')
    print('Per-player breakdown:')
    for cid, data in pairs(playerStats) do
        local total = (data.QuickFix or 0) + (data.HardFix or 0) + (data.MLOFix or 0) + (data.Emergency or 0)
        print(string.format('  [%s] %s  Q:%d H:%d M:%d E:%d  Total:%d',
            cid, data.name or '?',
            data.QuickFix or 0, data.HardFix or 0, data.MLOFix or 0, data.Emergency or 0, total))
    end
    print('========================================')
end)

-- エンティティ所有権リフレッシュの受信
RegisterNetEvent('syncfix:refreshEntityOwnership', function()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local refreshCount = 0
    
    -- 周囲の車両の制御権を要求
    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        local vehCoords = GetEntityCoords(vehicle)
        if #(myCoords - vehCoords) < 200.0 then
            if NetworkGetEntityIsNetworked(vehicle) then
                NetworkRequestControlOfEntity(vehicle)
                refreshCount = refreshCount + 1
            end
        end
    end
    
    -- 周囲のオブジェクトも同様に処理
    local objects = GetGamePool('CObject')
    for _, obj in ipairs(objects) do
        local objCoords = GetEntityCoords(obj)
        if #(myCoords - objCoords) < 100.0 then
            if NetworkGetEntityIsNetworked(obj) then
                NetworkRequestControlOfEntity(obj)
                refreshCount = refreshCount + 1
            end
        end
    end
    
    if refreshCount > 0 then
        print(string.format('[SyncFix] Refreshed ownership for %d entities', refreshCount))
    end
end)



-- ========================================================
-- 可視性チェック（周期スレッド）
-- [C2] NetworkSetEntityInvisibleToNetwork 削除
-- ========================================================
CreateThread(function()
    while true do
        Wait(10000)
        if not isProcessing then
            local myPed    = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            local players  = GetActivePlayers()
            for _, player in ipairs(players) do
                if player ~= PlayerId() then
                    local targetPed = GetPlayerPed(player)
                    if DoesEntityExist(targetPed) then
                        local targetCoords = GetEntityCoords(targetPed)
                        local distance     = #(myCoords - targetCoords)
                        if distance < 50.0 and not IsEntityVisible(targetPed) then
                            SetEntityVisible(targetPed, true, false)
                        end
                    end
                end
            end
        end
    end
end)

-- ========================================================
-- MLO透明化の「強制復旧」が必要か判定＆実行
-- ========================================================
local lastStrongMloFix = 0
local STRONG_MLOFIX_COOLDOWN_MS = 30000 -- 30秒に1回まで（重い＆フェードあり）

local function shouldRunStrongMloFix()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    -- 1) interior を座標から取る（壊れてる時 GetInteriorFromEntity が 0 の場合があるため）
    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)

    -- interior が取れない = 屋外扱い。強制MLOFixは不要
    if interior == 0 then return false, 0 end

    -- 2) interior が ready じゃない（＝透明化/未ロードの典型）
    if not IsInteriorReady(interior) then
        return true, interior
    end

    -- 3) 椅子など scenario 中に再発しやすいので、念のため
    if IsPedActiveInScenario(ped) then
        return true, interior
    end

    return false, interior
end

local function runStrongMloFixIfNeeded(reasonLabel)
    local now = GetGameTimer()
    if (now - lastStrongMloFix) < STRONG_MLOFIX_COOLDOWN_MS then
        return
    end

    local need, interior = shouldRunStrongMloFix()
    if not need then
        return
    end

    -- 車両中はpedだけ飛ばすと事故りやすいので、ここでは強制MLOFixしない（安全優先）
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        showNotification('SyncDeep', '車両から降りてから再実行してください（室内復旧が必要）', 'warning', 5000)
        return
    end

    lastStrongMloFix = now
    print(('^3[SyncFix] Strong MLOFix triggered (%s). interior=%d^7'):format(reasonLabel or 'unknown', interior))

    -- ここが“効くやつ”本体
    pcall(performMLOFix)
end


-- ========================================================
-- 診断コマンド
-- ========================================================
RegisterCommand('synccheck', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local debugInfo = {
        position  = string.format('%.1f, %.1f, %.1f', coords.x, coords.y, coords.z),
        interior  = GetInteriorFromEntity(ped),
        collision = HasCollisionLoadedAroundEntity(ped),
        streaming = IsNewLoadSceneActive(),
        visiblePlayers = 0, totalPlayers  = 0,
        visibleVehicles = 0, totalVehicles = 0
    }
    local players = GetActivePlayers()
    for _, player in ipairs(players) do
        if player ~= PlayerId() then
            debugInfo.totalPlayers = debugInfo.totalPlayers + 1
            if IsEntityVisible(GetPlayerPed(player)) then
                debugInfo.visiblePlayers = debugInfo.visiblePlayers + 1
            end
        end
    end
    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        if #(coords - GetEntityCoords(vehicle)) < 100.0 then
            debugInfo.totalVehicles = debugInfo.totalVehicles + 1
            if IsEntityVisible(vehicle) then debugInfo.visibleVehicles = debugInfo.visibleVehicles + 1 end
        end
    end
    print('========== Sync Diagnostics ==========')
    print('Position   : ' .. debugInfo.position)
    print('Interior ID: ' .. debugInfo.interior)
    print('Collision  : ' .. (debugInfo.collision and 'OK' or 'NG'))
    print('Streaming  : ' .. (debugInfo.streaming and 'Active' or 'Idle'))
    print(string.format('Players    : %d/%d visible (%.1f%%)',
        debugInfo.visiblePlayers, debugInfo.totalPlayers,
        debugInfo.totalPlayers > 0 and (debugInfo.visiblePlayers/debugInfo.totalPlayers*100) or 0))
    print(string.format('Vehicles   : %d/%d visible (%.1f%%)',
        debugInfo.visibleVehicles, debugInfo.totalVehicles,
        debugInfo.totalVehicles > 0 and (debugInfo.visibleVehicles/debugInfo.totalVehicles*100) or 0))
    print(string.format('HardFix Isolated: %s', hardFixIsolated and 'YES' or 'no'))
    print('====================================')
    showNotification('同期診断',
        string.format('Players: %d/%d | Vehicles: %d/%d\nSee F8 for details',
            debugInfo.visiblePlayers, debugInfo.totalPlayers,
            debugInfo.visibleVehicles, debugInfo.totalVehicles),
        'info', 8000)
end, false)

RegisterCommand('checkload', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    print('========== Streaming Status ==========')
    print('Position : ' .. string.format('%.1f, %.1f, %.1f', coords.x, coords.y, coords.z))
    print('Streaming: ' .. (IsNewLoadSceneActive() and 'Active' or 'Idle'))
    print('Collision: ' .. (HasCollisionLoadedAroundEntity(ped) and 'OK' or 'NG'))
    local nearbyVehicles, nearbyObjects = 0, 0
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if #(coords - GetEntityCoords(veh)) < 300.0 then nearbyVehicles = nearbyVehicles + 1 end
    end
    for _, obj in ipairs(GetGamePool('CObject')) do
        if #(coords - GetEntityCoords(obj)) < 300.0 then nearbyObjects = nearbyObjects + 1 end
    end
    print('Vehicles nearby: ' .. nearbyVehicles)
    print('Objects  nearby: ' .. nearbyObjects)
    print('==========================================')
    showNotification('ストリーミング確認',
        string.format('Vehicles: %d | Objects: %d\nSee F8 for details',
            nearbyVehicles, nearbyObjects), 'info', 5000)
end, false)

-- ========================================================
-- Seat-Guard（座り開始 “瞬間” の透明化対策）
-- 椅子側を改造せず、SyncFix側だけで先回りする
-- ========================================================
local seatGuardBusy = false
local seatGuardLast = 0
local SEAT_GUARD_COOLDOWN_MS = 8000

-- 座り瞬間は「長い処理」をすると体験が悪いので、短い版を用意
local function ensureMloLoadedAtCoordsFast(coords)
    -- 速攻だけ（短時間で終える）
    forceStreamAt(coords, 110.0, 1200)
    refreshInteriorAt(coords, 1200)
end

-- ========================================================
-- Seat-Guard v2（座った瞬間の透明化対策）
-- ========================================================
-- ========================================================
-- Seat-Guard（椅子の“座り開始瞬間”だけ拾う／フェード無し）
-- ========================================================
CreateThread(function()
    Wait(3000)
    print('^2[SyncFix] ^7Seat-Guard enabled')

    local ped = PlayerPedId()
    local lastCoords = GetEntityCoords(ped)
    local lastFrozen = IsEntityPositionFrozen(ped)
    local lastTime = GetGameTimer()

    local lastRun = 0
    local COOLDOWN_MS = 8000
    local DEBUG = false

    local function isPedStableForInteriorFix(ped)
        -- 走ってる/ジャンプ中/ラグドール/落下中は「誤爆源」なので除外
        if IsPedJumping(ped) or IsPedRagdoll(ped) or IsPedFalling(ped) then return false end
        if IsPedRunning(ped) or IsPedSprinting(ped) then return false end

        -- 速度でも弾く（歩行以上なら基本弾く）
        if GetEntitySpeed(ped) > 1.2 then return false end

        return true
    end

    while true do
        Wait(200)
        if isProcessing then goto cont end

        ped = PlayerPedId()
        local now = GetGameTimer()
        local coords = GetEntityCoords(ped)

        -- 屋内のみ（屋外のブレ誤検知をゼロにする）
        local interiorHere = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        local inInterior = (interiorHere ~= 0)

        local frozen = IsEntityPositionFrozen(ped)
        local freezeJustOn = (frozen and not lastFrozen)

        local trigger = freezeJustOn and inInterior and (not IsPedInAnyVehicle(ped, false))

        if trigger and (now - lastRun) >= COOLDOWN_MS then
            lastRun = now

            if DEBUG then
                local dt = math.max(1, now - lastTime)
                local dist = #(coords - lastCoords)
                print(('[SyncFix] Seat-Guard trigger dt=%dms dist=%.2f interior=%d'):format(dt, dist, interiorHere))
            end

            -- フェード無し軽量補助（2パス）
            if not isInteriorReadySafe(interiorHere) then
                ensureMloLoadedAtCoordsFast(coords)
                Wait(250)
                ensureMloLoadedAtCoordsFast(coords)
            end
        end

        lastCoords = coords
        lastFrozen = frozen
        lastTime = now
        ::cont::
    end
end)

-- ========================================================
-- TP-Guard（瞬間移動後に室内が透明化するのを抑える／フェード無し）
-- ========================================================
CreateThread(function()
    Wait(3500)
    print('^2[SyncFix] ^7TP-Guard enabled')

    local ped = PlayerPedId()
    local lastCoords = GetEntityCoords(ped)
    local lastTime = GetGameTimer()

    local lastRun = 0
    local COOLDOWN_MS = 6000
    local TP_DISTANCE = 6.0     -- 6m以上を一瞬で移動したらTP扱い

    local function isPedStableForInteriorFix(ped)
        -- 走ってる/ジャンプ中/ラグドール/落下中は「誤爆源」なので除外
        if IsPedJumping(ped) or IsPedRagdoll(ped) or IsPedFalling(ped) then return false end
        if IsPedRunning(ped) or IsPedSprinting(ped) then return false end

        -- 速度でも弾く（歩行以上なら基本弾く）
        if GetEntitySpeed(ped) > 1.2 then return false end

        return true
    end

    while true do
        Wait(250)
        if isProcessing then goto cont end

        ped = PlayerPedId()
        local now = GetGameTimer()
        local coords = GetEntityCoords(ped)

        local dt = now - lastTime
        local dist = #(coords - lastCoords)

        local tpLike = (dt <= 800 and dist >= TP_DISTANCE and not IsPedInAnyVehicle(ped, false))
        if tpLike and (now - lastRun) >= COOLDOWN_MS then
            lastRun = now

            -- まずは軽量補助
            ensureMloLoadedAtCoordsFast(coords)
            Wait(250)
            ensureMloLoadedAtCoordsFast(coords)

            -- それでも interior が取れて未ready なら、少し強め（フェード無し）
            local interiorHere = GetInteriorAtCoords(coords.x, coords.y, coords.z)
            if interiorHere ~= 0 and not isInteriorReadySafe(interiorHere) then
                ensureMloLoadedAtCoords(coords) -- あなたの3段（広め→refresh→仕上げ）
            end
        end

        lastCoords = coords
        lastTime = now
        ::cont::
    end
end)

-- ========================================================
-- コマンド登録（最終版）
--  表示: /sync, /syncdeep, /escape のみ
--  互換: /quickreload, /hardfix は残す（suggestion非表示）
--  隠し: /mlofix は残す（suggestion非表示）
--
--  syncdeep: HardFix 後に「必要なら」自動で performMLOFix を追撃して
--            MLO透明化/未ロードを直しに行く
-- ========================================================

-- ========================================================
-- 強制MLOFix（重いのでクールダウン付き）
-- ========================================================
local lastStrongMloFix = 0
local STRONG_MLOFIX_COOLDOWN_MS = 30000 -- 30秒に1回まで（フェード等があるため）

local function shouldRunStrongMloFix()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    -- interior は coords から取る（壊れてると GetInteriorFromEntity が 0 のことがある）
    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    if interior == 0 then
        return false, 0
    end

    -- interior が ready じゃない = 透明化/未ロードの典型
    if not IsInteriorReady(interior) then
        return true, interior
    end

    -- 椅子など scenario 中は再発しやすいので、徹底修正時は追撃しておく
    if IsPedActiveInScenario(ped) then
        return true, interior
    end

    return false, interior
end

local function runStrongMloFixIfNeeded(reasonLabel)
    local now = GetGameTimer()
    if (now - lastStrongMloFix) < STRONG_MLOFIX_COOLDOWN_MS then
        return
    end

    local need, interior = shouldRunStrongMloFix()
    if not need then
        return
    end

    -- 車両中に ped だけズラすと事故りやすいので安全優先で止める
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        showNotification('SyncDeep', '室内復旧が必要ですが車両中のため中断しました。降りてから再実行してください。', 'warning', 6000)
        return
    end

    lastStrongMloFix = now
    print(('[SyncFix] Strong MLOFix triggered (%s) interior=%d'):format(reasonLabel or 'unknown', interior))

    -- ここが「効くやつ」本体
    pcall(performMLOFix)
end


-- ========================================================
-- HardFix フェイルセーフ（透明/無敵/隔離で固まらないように）
-- ========================================================
local function hardFixFailSafe()
    local _ped = PlayerPedId()
    SetEntityVisible(_ped, true, false)
    SetEntityInvincible(_ped, false)
    SetPedCanRagdoll(_ped, true)
    FreezeEntityPosition(_ped, false)

    if hardFixIsolated then
        TriggerServerEvent('syncfix:releaseHardFixIsolation')
        hardFixIsolated = false
    end

    hardFixIsolationReady = false
    hardFixRestorationReady = false
    countdownActive = false

    ClearFocus()
    DoScreenFadeIn(500)
end

-- ========================================================
-- 実行ラッパー
-- ========================================================
local function runFix(commonCooldownFn, fn, onError, onSuccess)
    if isProcessing then
        showNotification('処理中', '修正処理を実行中です', 'error')
        return
    end
    if commonCooldownFn and not commonCooldownFn() then
        return
    end

    isProcessing = true
    CreateThread(function()
        local ok, err = pcall(fn)
        if not ok then
            if onError then onError(err) end
            isProcessing = false
            return
        end

        if onSuccess then
            pcall(onSuccess)
        end

        isProcessing = false
    end)
end

-- ========================================================
-- sync（軽量）
-- ========================================================
local function cmdSync()
    runFix(checkCooldown, performQuickFix, function(err)
        print('^1[SyncFix] performQuickFix ERROR: ' .. tostring(err) .. '^7')
        ClearFocus()
        DoScreenFadeIn(600)
        showNotification('エラー', '同期修正中にエラーが発生しました', 'error')
    end, function()
        -- 軽量側は「基本」強制MLOFixまではしない（副作用を抑える）
        -- ただし室内で interior が not ready なら軽い補助だけ入れる
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        local interior = GetInteriorAtCoords(c.x, c.y, c.z)
        if interior ~= 0 and not IsInteriorReady(interior) then
            ensureMloLoadedAtCoords(c)
        end
    end)
end

-- ========================================================
-- syncdeep（徹底）：HardFix + 必要なら強制MLOFix追撃
-- ========================================================
local function cmdSyncDeep()
    runFix(checkCooldown, performHardFix, function(err)
        print('^1[SyncFix] performHardFix ERROR: ' .. tostring(err) .. '^7')
        hardFixFailSafe()
        showNotification('エラー', '徹底同期修正中にエラーが発生しました', 'error')
    end, function()
        if IsPedInAnyVehicle(PlayerPedId(), false) then return end

        local now = GetGameTimer()
        if (now - lastStrongMloFix) < STRONG_MLOFIX_COOLDOWN_MS then return end
        lastStrongMloFix = now

        Wait(700)
        showNotification('SyncDeep', '室内(MLO)の復旧を実行中…', 'info', 2500)
        pcall(performMLOFix)
    end)
end

-- ========================================================
-- mlofix（隠し/奥の手）
-- ========================================================
local function cmdMloFix()
    runFix(checkCooldown, performMLOFix, function(err)
        print('^1[SyncFix] performMLOFix ERROR: ' .. tostring(err) .. '^7')
        ClearFocus()
        DoScreenFadeIn(300)
        showNotification('エラー', 'MLO修正中にエラーが発生しました', 'error')
    end)
end

-- ========================================================
-- escape（TP）
-- ========================================================
local function cmdEscape()
    if isProcessing then
        showNotification('処理中', '修正処理を実行中です', 'error')
        return
    end
    if not checkEmergencyCooldown() then
        return
    end

    isProcessing = true
    CreateThread(function()
        local ok, err = pcall(performEmergencyEscape)
        if not ok then
            print('^1[SyncFix] performEmergencyEscape ERROR: ' .. tostring(err) .. '^7')
            showNotification('エラー', '緊急脱出処理中にエラーが発生しました', 'error')
            isProcessing = false
            return
        end

        -- フェイルセーフ: 10秒後に強制解放
        CreateThread(function()
            Wait(10000)
            if isProcessing then
                isProcessing = false
                print('^3[SyncFix] emergencyEscape failsafe: force-released isProcessing^7')
            end
        end)
    end)
end

-- ========================================================
-- 実コマンド（Config優先）
-- ========================================================
RegisterCommand(Config.Commands.QuickFix, cmdSync, false)        -- /sync
RegisterCommand(Config.Commands.HardFix,  cmdSyncDeep, false)    -- /syncdeep
RegisterCommand(Config.Commands.Emergency, cmdEscape, false)     -- /escape

-- ========================================================
-- 互換コマンド（suggestionには出さない）
-- ========================================================
RegisterCommand('quickreload', cmdSync, false)
RegisterCommand('hardfix',     cmdSyncDeep, false)

-- ========================================================
-- 隠し（suggestionには出さない）
-- ========================================================
RegisterCommand(Config.Commands.MLOFix, cmdMloFix, false)

-- ========================================================
-- チャットコマンド候補（3つだけ表示）
-- ========================================================
CreateThread(function()
    Wait(2000)
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.QuickFix,  '軽量な同期修正（NPC/プレイヤー/描画の軽症向け）')
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.HardFix,   '徹底同期修正（MLO透明化など重症向け）')
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.Emergency, '緊急脱出（レギオンスクエアへ移動）')
end)

-- ========================================================
-- Fade/Blackout 監視（原因切り分け用）
-- ========================================================
CreateThread(function()
    Wait(3000)
    print('^2[SyncFix] ^7FadeWatch enabled')

    local lastFaded = false
    while true do
        Wait(0) -- できるだけ取りこぼさない

        local faded = IsScreenFadedOut()
        if faded and not lastFaded then
            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            local interior = GetInteriorAtCoords(c.x, c.y, c.z)
            print(('[FadeWatch] Screen faded OUT. isProcessing=%s interior=%d speed=%.2f'):format(
                tostring(isProcessing), interior, GetEntitySpeed(ped)
            ))
        end

        lastFaded = faded
    end
end)
