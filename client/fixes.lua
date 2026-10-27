-- ========================================================
-- client/fixes.lua - 修正処理本体（QuickFix / HardFix / MLOFix）
-- ========================================================

-- HardFix RoutingBucket 隔離フラグ
HardFixIsolated = false

-- HardFix 待機中フラグ
--   1回目の /syncdeep で待機場所へ移動して true
--   2回目の /syncdeep で元の場所へ戻って false
HardFixWaiting = false

local hardFixWaitStart = 0     -- 待機を始めた時刻（GetGameTimer）
local hardFixOrigin    = nil   -- 元の場所（vec4）
local hardFixShell     = nil   -- 待機用シェルのエンティティ（自分の画面だけに出すローカルオブジェクト）

-- ========================================================
-- 待機用シェル（Config.HardFix.Shell）
-- ========================================================
-- モデル未設定・未ストリームなら nil を返し、従来のフリーズ待機に切り替える
local function getShellConfig()
    local shell = Config.HardFix.Shell
    if not shell or not shell.model or shell.model == '' then return nil end
    local hash = type(shell.model) == 'number' and shell.model or GetHashKey(shell.model)
    if not IsModelInCdimage(hash) then
        print(string.format('^3[SyncFix] ^7HardFix shell model not found: %s (fallback to freeze mode)',
            tostring(shell.model)))
        return nil
    end
    return shell, hash
end

local function spawnShell(hash, safe)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 5000 do Wait(50); t = t + 50 end
    if not HasModelLoaded(hash) then return nil end

    -- isNetwork = false: 自分の画面にだけ出す（他プレイヤーには見えない）
    -- NoOffset: モデルの原点をそのまま座標に置く（ハウジング系スクリプトのシェル配置と同じ）
    local obj = CreateObjectNoOffset(hash, safe.x, safe.y, safe.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 then return nil end

    SetEntityHeading(obj, safe.w)
    FreezeEntityPosition(obj, true)
    return obj
end

-- シェル内の現在位置を spawnOffset の形で返す（立ち位置の調整用）
function GetHardFixShellOffset()
    if not (HardFixWaiting and hardFixShell and DoesEntityExist(hardFixShell)) then return nil end
    local ped = PlayerPedId()
    local off = GetOffsetFromEntityGivenWorldCoords(hardFixShell, GetEntityCoords(ped))
    local h   = (GetEntityHeading(ped) - GetEntityHeading(hardFixShell)) % 360.0
    return vec4(off.x, off.y, off.z, h)
end

local function deleteShell()
    if hardFixShell and DoesEntityExist(hardFixShell) then
        DeleteEntity(hardFixShell)
    end
    hardFixShell = nil
end

-- ========================================================
-- サーバーに保存された復帰地点（metadata.syncfix_return）
-- ========================================================
function GetSavedReturnPoint()
    local ok, data = pcall(function() return exports.qbx_core:GetPlayerData() end)
    local rp = ok and data and data.metadata and data.metadata.syncfix_return
    if type(rp) == 'table' and rp.x and rp.y and rp.z then
        return vec4(rp.x, rp.y, rp.z, rp.w or 0.0)
    end
    return nil
end

-- 戻れるようになるまでの残り秒数（Config.HardFix.MinStay）
function GetHardFixMinStayRemaining()
    local minStayMs = (Config.HardFix.MinStay or 0) * 1000
    local elapsed   = GetGameTimer() - hardFixWaitStart
    return math.max(0, math.ceil((minStayMs - elapsed) / 1000))
end

-- ========================================================
-- HardFix 待機中テキスト表示（待機が終わるまで表示し続ける）
-- ========================================================
local function drawWaitingText()
    CreateThread(function()
        local cfg     = Config.HardFix.WaitingText
        local hint    = string.format(Config.Messages.Hard.ReturnHint, Config.Commands.HardFix)
        local maxStay = Config.HardFix.MaxStay or 0

        while HardFixWaiting do
            SetTextFont(0); SetTextProportional(1); SetTextScale(0.7, 0.7)
            SetTextColour(100, 200, 255, 255); SetTextDropshadow(0,0,0,0,255)
            SetTextEdge(1,0,0,0,255); SetTextDropShadow(); SetTextOutline(); SetTextCentre(true)
            SetTextEntry('STRING'); AddTextComponentString(cfg.header)
            DrawText(cfg.position.x, cfg.position.y - 0.08)

            SetTextFont(0); SetTextScale(0.4, 0.4); SetTextColour(255,255,255,255)
            SetTextCentre(true); SetTextOutline()
            SetTextEntry('STRING'); AddTextComponentString(cfg.description)
            DrawText(cfg.position.x, cfg.position.y - 0.02)

            local line = hint
            if maxStay > 0 then
                local left = math.max(0, maxStay - math.floor((GetGameTimer() - hardFixWaitStart) / 1000))
                line = string.format('%s（自動で戻るまで %d:%02d）', hint, left // 60, left % 60)
            end
            SetTextFont(0); SetTextScale(0.5, 0.5); SetTextColour(100,200,255,255)
            SetTextCentre(true); SetTextOutline()
            SetTextEntry('STRING'); AddTextComponentString(line)
            DrawText(cfg.position.x, cfg.position.y + 0.05)

            Wait(0)
        end
    end)
end

-- ========================================================
-- 周辺プレイヤー・車両の表示を戻す（自分の画面だけ）
-- ========================================================
local function refreshNearbyEntities(myCoords)
    local myPed = PlayerPedId()
    for _, player in ipairs(GetActivePlayers()) do
        local targetPed = GetPlayerPed(player)
        if targetPed ~= myPed and DoesEntityExist(targetPed)
            and #(myCoords - GetEntityCoords(targetPed)) < 300.0 then
            SetEntityVisible(targetPed, true, false)
            SetEntityAlpha(targetPed, 255, false)
            SetEntityLodDist(targetPed, 500)
        end
    end
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(myCoords - GetEntityCoords(vehicle)) < 200.0 then
            SetEntityVisible(vehicle, true, false)
            SetEntityAlpha(vehicle, 255, false)
            SetEntityLodDist(vehicle, 500)
        end
    end
end

-- ========================================================
-- QuickFix（ブラックアウト方式・約10秒）
-- 自分の画面だけで完結する（他のプレイヤーには何も送らない）
-- ========================================================
function PerformQuickFix()
    local ped     = PlayerPedId()
    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)

    TriggerServerEvent('syncfix:logUsage', 'QuickFix',
        string.format('座標: %.1f, %.1f, %.1f', coords.x, coords.y, coords.z))

    ShowNotification('同期修正', Config.Messages.Quick.Start, 'info')
    refreshNearbyEntities(coords)
    Wait(500)

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

-- サーバー側の待機上限（Config.HardFix.MaxStay + 余裕）を超えたとき
RegisterNetEvent('syncfix:hardFixForceReturn', function()
    if HardFixWaiting then
        StartHardFixReturn('server timeout')
    end
end)

-- ========================================================
-- HardFix フェイルセーフ
-- ========================================================
-- 待機場所に取り残された場合は autofix.lua の復帰処理が元の場所へ戻す
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
    HardFixWaiting          = false
    hardFixOrigin           = nil
    deleteShell()

    ClearFocus()
    DoScreenFadeIn(500)
end

-- ========================================================
-- HardFix 1回目: 待機場所へ移動（元の場所を記録）
-- ========================================================
function PerformHardFixEnter()
    local ped             = PlayerPedId()
    local originalCoords  = GetEntityCoords(ped)
    local originalHeading = GetEntityHeading(ped)
    local safe            = Config.HardFix.SafeCoords

    -- 車両内では実行しない
    -- ClearPedTasksImmediately で ped が車から強制的に降ろされ、車だけがマップ外へ飛ぶ。
    -- また RoutingBucket はプレイヤーだけを移すので、車両は元のバケットに残る。
    if IsPedInAnyVehicle(ped, false) then
        ShowNotification('強力修正', '車両から降りてから実行してください', 'error')
        return
    end

    TriggerServerEvent('syncfix:logUsage', 'HardFix',
        string.format('元座標: %.1f, %.1f, %.1f', originalCoords.x, originalCoords.y, originalCoords.z))

    ShowNotification('強力修正', Config.Messages.Hard.Start, 'info')
    DoScreenFadeOut(500)
    Wait(600)

    -- RoutingBucket 隔離要求（サーバーはここで元の場所を metadata に記録する）
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

    -- ストリーミング切断 + 物理移動
    ClearFocus(); ClearHdArea()
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    ClearPedTasksImmediately(ped)

    -- シェルが設定されていれば、その中へ送って自由に歩けるようにする
    local shell, shellHash = getShellConfig()
    local shellObj = shell and spawnShell(shellHash, safe)
    local shellSpawn = nil

    if shellObj then
        hardFixShell = shellObj
        local off = shell.spawnOffset or vec4(0.0, 0.0, 0.0, 0.0)
        shellSpawn = GetOffsetFromEntityInWorldCoords(shellObj, off.x, off.y, off.z)

        SetEntityCoords(ped, shellSpawn.x, shellSpawn.y, shellSpawn.z, false, false, false, false)
        SetEntityHeading(ped, (safe.w + (off.w or 0.0)) % 360.0)
        SetFocusPosAndVel(shellSpawn.x, shellSpawn.y, shellSpawn.z, 0.0, 0.0, 0.0)
        Wait(800)   -- シェルのコリジョンが有効になるのを待つ
        ClearFocus()
        FreezeEntityPosition(ped, false)
    else
        -- シェルなし: 空中でフリーズして待機（落下アニメ防止のため透明化）
        SetPedCanRagdoll(ped, false)
        SetEntityCollision(ped, false, false)
        SetEntityCoords(ped, safe.x, safe.y, safe.z, false, false, false, false)
        SetEntityHeading(ped, safe.w)
        SetEntityCollision(ped, true, true)

        ClearPedTasksImmediately(ped)
        Wait(100)
        ClearPedTasksImmediately(ped)

        SetEntityVisible(ped, false, false)

        SetFocusPosAndVel(safe.x, safe.y, safe.z, 0.0, 0.0, 0.0)
        NewLoadSceneStart(safe.x, safe.y, safe.z, safe.x, safe.y, safe.z, 50.0, 0)

        local unloadWait = 0
        while IsNewLoadSceneActive() and unloadWait < 2000 do
            Wait(100); unloadWait = unloadWait + 100
        end
        if IsNewLoadSceneActive() then NewLoadSceneStop() end
    end

    -- 待機開始（2回目の /syncdeep まで待つ）
    hardFixOrigin    = vec4(originalCoords.x, originalCoords.y, originalCoords.z, originalHeading)
    hardFixWaitStart = GetGameTimer()
    HardFixWaiting   = true

    Wait(500)
    DoScreenFadeIn(500)
    ShowNotification('強力修正',
        string.format(Config.Messages.Hard.Waiting, Config.Commands.HardFix), 'warning', 8000)
    drawWaitingText()

    -- シェルから落ちたら入口へ戻す（コリジョン抜け対策）
    if shellSpawn then
        local startedAt = hardFixWaitStart
        CreateThread(function()
            while HardFixWaiting and hardFixWaitStart == startedAt do
                local p = PlayerPedId()
                if GetEntityCoords(p).z < shellSpawn.z - 15.0 then
                    SetEntityCoords(p, shellSpawn.x, shellSpawn.y, shellSpawn.z, false, false, false, false)
                end
                Wait(500)
            end
        end)
    end

    -- 待機の上限時間を過ぎたら自動で戻す（0 なら無制限）
    local maxStay = Config.HardFix.MaxStay or 0
    if maxStay > 0 then
        local startedAt = hardFixWaitStart
        CreateThread(function()
            while HardFixWaiting and hardFixWaitStart == startedAt do
                if (GetGameTimer() - startedAt) >= maxStay * 1000 and not IsFixProcessing then
                    StartHardFixReturn('max stay')
                end
                Wait(1000)
            end
        end)
    end
end

-- ========================================================
-- HardFix 2回目: 元の場所へ戻る（記録を削除）
-- ========================================================
function PerformHardFixReturn()
    local ped    = PlayerPedId()
    local origin = hardFixOrigin or GetSavedReturnPoint() or Config.HardFix.FallbackLocation

    HardFixWaiting = false   -- 待機中テキストを止める
    hardFixOrigin  = nil

    ShowNotification('強力修正', Config.Messages.Hard.Returning, 'info')
    DoScreenFadeOut(500)
    Wait(500)

    -- RoutingBucket 解除
    HardFixRestorationReady = false
    TriggerServerEvent('syncfix:releaseHardFixIsolation')

    local restoreWait = 0
    while not HardFixRestorationReady and restoreWait < 3000 do
        Wait(100); restoreWait = restoreWait + 100
    end

    FreezeEntityPosition(ped, true)   -- シェル内を歩いていた場合も止める
    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)

    -- 元の場所を先に読み込む
    ClearFocus()
    SetFocusPosAndVel(origin.x, origin.y, origin.z, 0.0, 0.0, 0.0)
    NewLoadSceneStart(origin.x, origin.y, origin.z, origin.x, origin.y, origin.z, 200.0, 0)
    WaitNewLoadSceneLoaded(8000)
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    local interior   = GetInteriorAtCoords(origin.x, origin.y, origin.z)
    local okInterior = RefreshAndWaitInterior(interior)

    Wait(1500)

    -- 物理復帰（MLOFix は GetEntityCoords(ped) を使うので必ずこの後に実行する）
    SetEntityCoords(ped, origin.x, origin.y, origin.z + 0.5, false, false, false, true)
    SetEntityHeading(ped, origin.w or 0.0)
    FreezeEntityPosition(ped, false)
    deleteShell()

    -- 元の場所に戻れたのでサーバー側の記録を削除
    TriggerServerEvent('syncfix:clearReturnPoint')

    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 8000 do
        RequestCollisionAtCoord(origin.x, origin.y, origin.z)
        Wait(100); t = t + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    ClearPedTasksImmediately(ped)

    -- カメラリセット（上空見下ろしアングル防止）
    ClearFocus()
    ClearHdArea()

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
