-- ========================================================
-- client/teleport.lua - テレポートコア（安全TP・MLOプリロード・メニュー・エスコート同期）
-- ========================================================
-- 依存: client/utils.lua (ShowNotification, HasOxLib)
--       client/streaming.lua (EnsureMloLoadedAtCoords, ForceStreamAt, RefreshInteriorAt)

-- テレポート処理中フラグ
local isTeleporting = false

-- エスコート再アタッチ待機用
local escortReattachTarget = nil  -- 被連行者の serverId（完了通知待ち）

-- ========================================================
-- QBX metadata 取得ヘルパー
-- ========================================================
local function getPlayerMetadata()
    local playerData = nil
    if exports.qbx_core then
        local ok, data = pcall(function()
            return exports.qbx_core:GetPlayerData()
        end)
        if ok and data then playerData = data end
    end
    if not playerData then
        -- qb-core フォールバック
        local ok, QBCore = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        if ok and QBCore then
            playerData = QBCore.Functions.GetPlayerData()
        end
    end
    return playerData and playerData.metadata or {}
end

-- ========================================================
-- TP制限チェック（被連行者・手錠・死亡）
-- ========================================================
function CheckTeleportRestrictions()
    local restrictions = Config.Teleports and Config.Teleports.Restrictions
    if not restrictions then return true end -- 制限設定なし → 許可

    local meta = getPlayerMetadata()

    if restrictions.BlockIfEscorted and meta.isescorted then
        ShowNotification('テレポート', Config.Messages.Teleport.BlockedEscorted, 'error')
        return false
    end
    if restrictions.BlockIfHandcuffed and meta.ishandcuffed then
        ShowNotification('テレポート', Config.Messages.Teleport.BlockedHandcuffed, 'error')
        return false
    end
    if restrictions.BlockIfDead and (meta.isdead or meta.inlaststand) then
        ShowNotification('テレポート', Config.Messages.Teleport.BlockedDead, 'error')
        return false
    end

    return true
end

-- ========================================================
-- エスコート中の被連行者 ped を検出
-- ========================================================
-- qb-policejob: AttachEntityToEntity(target, dragger, 11816, ...)
-- 連行者の ped にアタッチされている他プレイヤー ped を探す
local function findEscortedPlayer(myPed)
    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() then
            local targetPed = GetPlayerPed(player)
            if DoesEntityExist(targetPed) and IsEntityAttachedToEntity(targetPed, myPed) then
                return player, targetPed, GetPlayerServerId(player)
            end
        end
    end
    return nil, nil, nil
end

-- ========================================================
-- 安全テレポート実行
-- ========================================================
--  dest = { label, coords (vec4), isMlo (bool) }
--  pointLabel = ポイント名（通知用）
function PerformSafeTeleport(dest, pointLabel)
    if isTeleporting then
        ShowNotification('移動中', '移動処理を実行中です', 'error')
        return false
    end

    -- TP制限チェック
    if not CheckTeleportRestrictions() then
        return false
    end

    isTeleporting = true

    local ok, err = pcall(function()
        local ped     = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        local entity  = vehicle ~= 0 and vehicle or ped
        local cfg     = Config.Teleports
        local fadeDur = cfg.FadeDuration or 500
        local restrictions = cfg.Restrictions or {}

        -- エスコート同期: 自分にアタッチされている被連行者を検出
        local escortedPlayer, escortedPed, escortedServerId = nil, nil, nil
        if restrictions.EscortedPlayerSync then
            escortedPlayer, escortedPed, escortedServerId = findEscortedPlayer(ped)
        end

        -- ログ送信
        local c = GetEntityCoords(ped)
        local logDetail = string.format('移動: %s → %s (%.1f, %.1f, %.1f)',
            pointLabel or '不明', dest.label or '不明',
            dest.coords.x, dest.coords.y, dest.coords.z)
        if escortedServerId then
            logDetail = logDetail .. string.format(' [エスコート同期: ID %d]', escortedServerId)
        end
        TriggerServerEvent('syncfix:logUsage', 'Teleport', logDetail)

        -- フェーズ1: フェードアウト
        ShowNotification('テレポート', Config.Messages.Teleport.Start, 'info', 2000)
        DoScreenFadeOut(fadeDur)
        local t = 0
        while not IsScreenFadedOut() and t < 2000 do Wait(10); t = t + 10 end

        -- フェーズ1.5: エスコート同期 - サーバー経由で被連行者にTP通知
        if escortedServerId then
            ShowNotification('テレポート', Config.Messages.Teleport.EscortSync, 'info', 2000)
            -- 被連行者を一旦デタッチ（座標移動のため）
            DetachEntity(escortedPed, true, false)
            -- サーバー経由で被連行者のクライアントにTP指示
            TriggerServerEvent('syncfix:escortTeleportSync', escortedServerId, {
                x = dest.coords.x,
                y = dest.coords.y,
                z = dest.coords.z,
                w = dest.coords.w or 0.0
            }, dest.isMlo or false)
        end

        -- フェーズ2: エンティティ固定
        FreezeEntityPosition(entity, true)

        -- フェーズ2.5: 同一インテリア判定
        -- 転送元と転送先が同じ interior ID の場合、RefreshInterior を省略し
        -- 同一MLO内の他プレイヤーのインテリア描画が崩れるのを防ぐ
        local originInterior = GetInteriorFromEntity(entity)
        local destInterior   = GetInteriorAtCoords(dest.coords.x, dest.coords.y, dest.coords.z)
        local sameInterior   = (originInterior ~= 0 and destInterior ~= 0 and originInterior == destInterior)
        if sameInterior then
            print(string.format('^2[SyncFix] ^7Same interior TP detected (id=%d), skipping RefreshInterior to protect other players', originInterior))
        end

        -- フェーズ3: MLOプリロード（移動先がMLOの場合）
        if dest.isMlo then
            ShowNotification('テレポート', Config.Messages.Teleport.Loading, 'info', 3000)
            -- streaming.lua の関数を再利用して3段階ロード
            -- sameInterior なら RefreshInterior を省略
            EnsureMloLoadedAtCoords(dest.coords, sameInterior)
        else
            -- 屋外でも最低限のストリーミングは実行
            ForceStreamAt(dest.coords, 120.0, cfg.LoadTimeout or 8000)
        end

        -- フェーズ3.5: プリロード後、フォーカスを一旦クリア
        -- ※ ForceStreamAt が SetFocusPosAndVel を残したままなので
        --    エンティティ移動前にリセットする
        ClearFocus()
        ClearHdArea()

        -- フェーズ4: 物理移動
        SetEntityCoords(entity, dest.coords.x, dest.coords.y, dest.coords.z, false, false, false, true)
        SetEntityHeading(entity, dest.coords.w or 0.0)

        -- フェーズ4.5: エンティティ到着後、再度ストリーミング要求
        -- ※ エンティティが物理的に存在する状態でフォーカスを設定し直すことで
        --    ポータル検知とインテリア描画をエンジンに認識させる
        SetFocusPosAndVel(dest.coords.x, dest.coords.y, dest.coords.z, 0.0, 0.0, 0.0)

        -- フェーズ5: コリジョンロード待ち
        RequestCollisionAtCoord(dest.coords.x, dest.coords.y, dest.coords.z)
        RequestAdditionalCollisionAtCoord(dest.coords.x, dest.coords.y, dest.coords.z)
        t = 0
        while not HasCollisionLoadedAroundEntity(entity) and t < 5000 do
            RequestCollisionAtCoord(dest.coords.x, dest.coords.y, dest.coords.z)
            Wait(50); t = t + 50
        end

        -- フェーズ6: MLO interior 最終確認
        -- エンティティが到着した状態で interior を取得・アクティベート
        if dest.isMlo then
            local interior = GetInteriorAtCoords(dest.coords.x, dest.coords.y, dest.coords.z)
            if interior ~= 0 then
                -- Pin + Activate でポータルシステムを確実に起動
                PinInteriorInMemory(interior)
                SetInteriorActive(interior, true)
                -- 同一インテリア内TP の場合は RefreshInterior を省略
                -- RefreshInterior は portal/room 情報を全リロードするため
                -- 同じ interior にいる他プレイヤーの描画が崩れる
                if not sameInterior and not IsAreaLocked(dest.coords) then
                    RefreshInterior(interior)
                elseif sameInterior then
                    print(string.format('^2[SyncFix] ^7Phase6: RefreshInterior skipped (same interior id=%d)', interior))
                end
                WaitInteriorReady(interior, 7000)
            end
        end

        -- フェーズ7: 解放・フェードイン
        FreezeEntityPosition(entity, false)
        ClearFocus()
        ClearHdArea()
        Wait(200)

        -- フェーズ7.5: エスコート同期 - 被連行者のTP完了待ち → 再アタッチ
        if escortedServerId then
            -- 被連行者のTP完了をサーバー経由コールバックで待機（最大15秒）
            escortReattachTarget = escortedServerId
            local waitStart = GetGameTimer()
            while escortReattachTarget and (GetGameTimer() - waitStart) < 15000 do
                Wait(200)
            end

            -- 再度 ped を取得（移動後にハンドルが変わる可能性）
            ped = PlayerPedId()
            -- ストリームイン待ち（被連行者がまだ見えない可能性）
            local streamWait = 0
            local newEscortedPed = nil
            while streamWait < 5000 do
                local playerId = GetPlayerFromServerId(escortedServerId)
                if playerId and playerId ~= -1 then
                    local pedCheck = GetPlayerPed(playerId)
                    if DoesEntityExist(pedCheck) then
                        newEscortedPed = pedCheck
                        break
                    end
                end
                Wait(200)
                streamWait = streamWait + 200
            end

            if newEscortedPed and DoesEntityExist(newEscortedPed) then
                -- qb-policejob と同じアタッチ: bone 11816
                AttachEntityToEntity(newEscortedPed, ped, 11816,
                    0.45, 0.45, 0.0, 0.0, 0.0, 0.0,
                    false, false, false, false, 2, true)
                print(string.format('^2[SyncFix] ^7Escort re-attached after TP (target serverId: %d)', escortedServerId))
                ShowNotification('テレポート', Config.Messages.Teleport.EscortSynced, 'success')
            else
                print(string.format('^3[SyncFix] ^7Escort re-attach failed: target ped not streamed in (serverId: %d)', escortedServerId))
            end
            escortReattachTarget = nil
        end

        DoScreenFadeIn(fadeDur)
        ShowNotification('テレポート', Config.Messages.Teleport.Complete, 'success')
    end)

    if not ok then
        print('^1[SyncFix] PerformSafeTeleport ERROR: ' .. tostring(err) .. '^7')
        -- フェイルセーフ
        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 then FreezeEntityPosition(veh, false) end
        ClearFocus()
        DoScreenFadeIn(500)
        ShowNotification('テレポート', '移動中にエラーが発生しました', 'error')
    end

    isTeleporting = false
    return ok
end

-- ========================================================
-- 被連行者側: サーバーから受信するTP同期イベント
-- ========================================================
-- 連行者がTPしたとき、被連行者のクライアントで実行される
-- フェード + デタッチ + MLOプリロード + 座標移動 + コリジョン待ち + フェードイン
RegisterNetEvent('syncfix:escortTeleportReceive', function(coords, isMlo, draggerServerId)
    CreateThread(function()
        local ped = PlayerPedId()
        local fadeDur = (Config.Teleports and Config.Teleports.FadeDuration) or 500

        local ok, err = pcall(function()
            -- デタッチ（まだアタッチされている場合）
            if IsEntityAttachedToAnyEntity(ped) then
                DetachEntity(ped, true, false)
            end

            -- フェードアウト
            DoScreenFadeOut(fadeDur)
            local t = 0
            while not IsScreenFadedOut() and t < 2000 do Wait(10); t = t + 10 end

            FreezeEntityPosition(ped, true)

            -- 同一インテリア判定（転送元と転送先が同じMLOなら RefreshInterior 省略）
            local destCoords = vec3(coords.x, coords.y, coords.z)
            local originInterior = GetInteriorFromEntity(ped)
            local destInterior   = GetInteriorAtCoords(coords.x, coords.y, coords.z)
            local sameInterior   = (originInterior ~= 0 and destInterior ~= 0 and originInterior == destInterior)
            if sameInterior then
                print(string.format('^2[SyncFix] ^7Escort: same interior TP (id=%d), skipping RefreshInterior', originInterior))
            end

            -- MLOプリロード
            if isMlo then
                EnsureMloLoadedAtCoords(destCoords, sameInterior)
            else
                ForceStreamAt(destCoords, 120.0, 6000)
            end

            -- プリロード後フォーカスクリア
            ClearFocus()
            ClearHdArea()

            -- 座標移動
            SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
            if coords.w then
                SetEntityHeading(ped, coords.w)
            end

            -- エンティティ到着後、再度フォーカス設定
            SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)

            -- コリジョン待ち
            RequestCollisionAtCoord(coords.x, coords.y, coords.z)
            RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
            t = 0
            while not HasCollisionLoadedAroundEntity(ped) and t < 5000 do
                RequestCollisionAtCoord(coords.x, coords.y, coords.z)
                Wait(50); t = t + 50
            end

            -- interior 最終確認（エンティティが存在する状態で再アクティベート）
            if isMlo then
                local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
                if interior ~= 0 then
                    PinInteriorInMemory(interior)
                    SetInteriorActive(interior, true)
                    -- 同一インテリア内TP の場合は RefreshInterior を省略
                    if not sameInterior and not IsAreaLocked(destCoords) then
                        RefreshInterior(interior)
                    elseif sameInterior then
                        print(string.format('^2[SyncFix] ^7Escort Phase6: RefreshInterior skipped (same interior id=%d)', interior))
                    end
                    WaitInteriorReady(interior, 7000)
                end
            end

            FreezeEntityPosition(ped, false)
            ClearFocus()
            ClearHdArea()
            Wait(200)

            DoScreenFadeIn(fadeDur)
            ShowNotification('テレポート', Config.Messages.Teleport.EscortSynced, 'success')
        end)

        if not ok then
            -- フェイルセーフ: エラー時にフリーズ・フェード・フォーカスを確実に解放
            print('^1[SyncFix] escortTeleportReceive ERROR: ' .. tostring(err) .. '^7')
            FreezeEntityPosition(ped, false)
            ClearFocus()
            DoScreenFadeIn(500)
            ShowNotification('テレポート', 'エスコート移動中にエラーが発生しました', 'error')
        end

        -- 完了通知をサーバー経由で連行者に送信
        if draggerServerId then
            TriggerServerEvent('syncfix:escortTeleportComplete', draggerServerId)
        end
    end)
end)

-- 連行者側: 被連行者のTP完了通知を受信
RegisterNetEvent('syncfix:escortTeleportReady', function()
    -- 被連行者のTP完了 → 再アタッチ待機を解除
    escortReattachTarget = nil
    print('^2[SyncFix] ^7Escort target TP completed, proceeding to re-attach')
end)

-- ========================================================
-- 移動先選択メニュー（ox_lib 使用 / 1件なら即TP）
-- ========================================================
function OpenTeleportMenu(point)
    if not point or not point.destinations or #point.destinations == 0 then return end

    -- TP制限チェック（メニュー表示前にブロック）
    if not CheckTeleportRestrictions() then return end

    -- JOB制限チェック（メニュー表示前にブロック）
    if not CheckJobRestriction(point) then return end

    -- 移動先が1つなら即実行
    if #point.destinations == 1 then
        CreateThread(function()
            PerformSafeTeleport(point.destinations[1], point.label)
        end)
        return
    end

    -- 複数の場合: ox_lib メニュー or フォールバック
    if HasOxLib then
        local options = {}
        for i, dest in ipairs(point.destinations) do
            options[i] = {
                title       = dest.label,
                description = dest.isMlo and 'MLO内' or '屋外',
                icon        = dest.isMlo and 'fa-solid fa-building' or 'fa-solid fa-road',
                onSelect    = function()
                    CreateThread(function()
                        PerformSafeTeleport(dest, point.label)
                    end)
                end
            }
        end

        lib.registerContext({
            id      = 'syncfix_tp_' .. point.id,
            title   = point.label .. ' - 移動先選択',
            position = Config.Teleports.MenuPosition or 'top-right',
            options = options
        })
        lib.showContext('syncfix_tp_' .. point.id)
    else
        -- ox_lib なしフォールバック: チャットで番号入力方式はUX悪いため1番目に自動TP
        ShowNotification('テレポート', '移動先: ' .. point.destinations[1].label, 'info')
        CreateThread(function()
            PerformSafeTeleport(point.destinations[1], point.label)
        end)
    end
end

-- ========================================================
-- TP処理中チェック（外部から参照用）
-- ========================================================
function IsTeleporting()
    return isTeleporting
end

-- TP制限チェック export（外部リソースからも利用可能）
exports('PerformSafeTeleport', PerformSafeTeleport)
exports('IsTeleporting', IsTeleporting)
exports('CheckTeleportRestrictions', CheckTeleportRestrictions)

print('^2[SyncFix] ^7Teleport module loaded (escort sync enabled)')
