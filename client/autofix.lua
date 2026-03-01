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
        end

        ::cont::
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
