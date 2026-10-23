-- ========================================================
-- client/autofix.lua - 自動検知＆修復システム
--   Seat-Guard / 可視性チェック / FadeWatch
-- ========================================================

-- ========================================================
-- 安定状態チェック（誤爆防止用共通関数）
-- ========================================================
local function isPedStable(ped)
    if IsPedJumping(ped) or IsPedFalling(ped) or IsPedRagdoll(ped) then return false end
    if IsPedRunning(ped) or IsPedSprinting(ped) then return false end
    if GetEntitySpeed(ped) > 1.2 then return false end
    return true
end

-- ========================================================
-- Seat-Guard（座り開始瞬間の透明化対策・フェード無し）
-- ========================================================
-- 負荷対策: 2000ms間隔 + 車両乗車中は完全スキップ
CreateThread(function()
    Wait(3000)
    print('^2[SyncFix] ^7Seat-Guard enabled (low-impact mode)')

    local lastFrozen = false
    local lastRun    = 0
    local COOLDOWN   = 10000

    while true do
        Wait(2000)
        if IsFixProcessing then goto cont end

        local ped = PlayerPedId()

        -- 車両乗車中はinterior固着が起きないためスキップ
        if IsPedInAnyVehicle(ped, false) then
            lastFrozen = false
            goto cont
        end

        local frozen       = IsEntityPositionFrozen(ped)
        local freezeJustOn = (frozen and not lastFrozen)
        lastFrozen = frozen

        if not freezeJustOn then goto cont end

        local coords       = GetEntityCoords(ped)
        local interiorHere = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        if interiorHere == 0 then goto cont end

        local now = GetGameTimer()
        if (now - lastRun) < COOLDOWN then goto cont end

        -- 保護中の interior なら自動修復スキップ
        if IsInteriorLocked() then goto cont end

        lastRun = now
        if not IsInteriorReadySafe(interiorHere) then
            EnsureMloLoadedAtCoordsFast(coords)
            Wait(250)
            EnsureMloLoadedAtCoordsFast(coords)
            -- ForceStreamAt はフォーカスを残すので解除（残すと移動先が読み込まれなくなる）
            ClearFocus()
        end

        ::cont::
    end
end)

-- ========================================================
-- HardFix 中断からの復帰
-- ========================================================
-- HardFix の待機中に切断・クラッシュすると、マップ外上空（SafeCoords, 高度2000m）が保存され
-- 次回ログイン時にそこへ出現して落下してしまう。またエラーやリソース再起動で
-- 待機状態が消えた場合も取り残される。待機中でも修正処理中でもないのに
-- SafeCoords 付近にいたら、サーバーが記録した元の場所（なければ緊急脱出地点）へ戻す。
local function recoverFromSafeCoords()
    local ped  = PlayerPedId()
    local dest = GetSavedReturnPoint()
    local hasReturnPoint = dest ~= nil
    dest = dest or Config.Emergency.EscapeLocation

    -- サーバー側でまだ隔離中なら元のバケットへ戻す（隔離していなければ何もしない）
    TriggerServerEvent('syncfix:releaseHardFixIsolation')
    print(string.format('^3[SyncFix] ^7Stranded at HardFix safe coords -> recovering to %.1f, %.1f, %.1f (%s)',
        dest.x, dest.y, dest.z, hasReturnPoint and 'saved origin' or 'escape location'))

    DoScreenFadeOut(300)
    Wait(300)

    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    SetPedCanRagdoll(ped, true)
    FreezeEntityPosition(ped, true)

    ClearFocus(); ClearHdArea()
    RequestCollisionAtCoord(dest.x, dest.y, dest.z)
    NewLoadSceneStart(dest.x, dest.y, dest.z, dest.x, dest.y, dest.z, 100.0, 0)

    SetEntityCoords(ped, dest.x, dest.y, dest.z, false, false, false, true)
    SetEntityHeading(ped, dest.w or 0.0)

    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do
        RequestCollisionAtCoord(dest.x, dest.y, dest.z)
        Wait(100); t = t + 100
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end

    FreezeEntityPosition(ped, false)
    ClearFocus()
    DoScreenFadeIn(500)
    ShowNotification('強力修正', '前回の修正が中断されていたため、元の場所へ戻しました', 'warning', 6000)

    TriggerServerEvent('syncfix:clearReturnPoint')
end

CreateThread(function()
    local safe   = Config.HardFix.SafeCoords
    local safeXY = vec2(safe.x, safe.y)
    while true do
        Wait(3000)
        if not IsFixProcessing and not HardFixWaiting and LocalPlayer.state.isLoggedIn then
            local c = GetEntityCoords(PlayerPedId())
            -- 上空から落下中でも検知できるよう水平距離だけで判定する
            if #(vec2(c.x, c.y) - safeXY) < 1000.0 then
                IsFixProcessing = true
                local ok, err = pcall(recoverFromSafeCoords)
                if not ok then
                    print('^1[SyncFix] HardFix recovery ERROR: ' .. tostring(err) .. '^7')
                    FreezeEntityPosition(PlayerPedId(), false)
                    ClearFocus()
                    DoScreenFadeIn(500)
                end
                IsFixProcessing = false
            end
        end
    end
end)

-- ========================================================
-- 可視性チェック（30秒周期・近接プレイヤー透明化復旧）
-- ========================================================
CreateThread(function()
    while true do
        Wait(30000)
        if not IsFixProcessing then
            local myPed    = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            for _, player in ipairs(GetActivePlayers()) do
                if player ~= PlayerId() then
                    local targetPed = GetPlayerPed(player)
                    if DoesEntityExist(targetPed) then
                        local dist = #(myCoords - GetEntityCoords(targetPed))
                        if dist < 50.0 and not IsEntityVisible(targetPed) then
                            SetEntityVisible(targetPed, true, false)
                        end
                    end
                end
            end
        end
    end
end)

-- ========================================================
-- Fade/Blackout 監視（デバッグ用 → 本番では無効化）
-- ========================================================
-- Wait(0) = 毎フレーム実行で極めて高負荷のため、本番では無効化
-- デバッグ時は Config.Debug = true にして有効化可能
if Config.Debug then
    CreateThread(function()
        Wait(3000)
        print('^3[SyncFix] ^7FadeWatch enabled (DEBUG MODE)')
        local lastFaded = false
        while true do
            Wait(500)  -- デバッグ時も500msに抑制（0msは禁止）
            local faded = IsScreenFadedOut()
            if faded and not lastFaded then
                local ped = PlayerPedId()
                local c   = GetEntityCoords(ped)
                print(('[FadeWatch] Screen faded OUT. isProcessing=%s interior=%d speed=%.2f'):format(
                    tostring(IsFixProcessing), GetInteriorAtCoords(c.x, c.y, c.z), GetEntitySpeed(ped)))
            end
            lastFaded = faded
        end
    end)
end
