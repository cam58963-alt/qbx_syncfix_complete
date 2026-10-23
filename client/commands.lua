-- ========================================================
-- client/commands.lua - コマンド登録・イベント受信
-- ========================================================

-- ========================================================
-- 初期化
-- ========================================================
CreateThread(function()
    local resVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?.?.?'
    print('^2[SyncFix] ^7Client initialized (v' .. resVersion .. ' modular)')
end)

-- ========================================================
-- HardFix 待機中は他の修正コマンドを使わせない
-- （隔離・無敵・透明のまま別の場所へ移動してしまうため）
-- ========================================================
local function blockIfHardFixWaiting()
    if HardFixWaiting then
        ShowNotification('強力修正',
            string.format(Config.Messages.Hard.BlockedWhileWaiting, Config.Commands.HardFix), 'error')
        return true
    end
    return false
end

-- ========================================================
-- /sync（軽量修正）
-- ========================================================
local function cmdSync()
    if blockIfHardFixWaiting() then return end
    RunFix(CheckCooldown, PerformQuickFix, function(err)
        print('^1[SyncFix] performQuickFix ERROR: ' .. tostring(err) .. '^7')
        ClearFocus(); DoScreenFadeIn(600)
        ShowNotification('エラー', '同期修正中にエラーが発生しました', 'error')
    end, function()
        local ped = PlayerPedId()
        local c   = GetEntityCoords(ped)
        local interior = GetInteriorAtCoords(c.x, c.y, c.z)
        if interior ~= 0 and not IsInteriorReady(interior) then
            EnsureMloLoadedAtCoords(c)
            -- ForceStreamAt はフォーカスを残すので解除（残すと移動先が読み込まれなくなる）
            ClearFocus()
        end
    end)
end

-- ========================================================
-- /syncdeep（徹底修正・2回使う方式）
--   1回目: 待機場所へ移動し、元の場所を記録
--   2回目: 元の場所へ戻り、記録を削除（+ 必要なら MLOFix 追撃）
-- ========================================================
local lastStrongMloFix         = 0
local STRONG_MLOFIX_COOLDOWN   = 30000

local function hardFixError(err)
    print('^1[SyncFix] HardFix ERROR: ' .. tostring(err) .. '^7')
    HardFixFailSafe()
    ShowNotification('エラー', '徹底同期修正中にエラーが発生しました', 'error')
end

-- 元の場所に戻ったあと、室内が未ロードなら MLOFix で追撃
local function mloFixAfterReturn()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return end

    local c = GetEntityCoords(ped)
    -- 待機場所（マップ外）にまだいる場合はスキップ
    if math.abs(c.x) > 5000.0 or math.abs(c.y) > 5000.0 or c.z > 1500.0 then
        print('^3[SyncFix] SyncDeep: still at safe coords, skipping MLOFix^7')
        return
    end

    local interior = GetInteriorAtCoords(c.x, c.y, c.z)
    if interior == 0 or IsInteriorReady(interior) then return end

    local now = GetGameTimer()
    if (now - lastStrongMloFix) < STRONG_MLOFIX_COOLDOWN then return end
    lastStrongMloFix = now

    Wait(700)
    ShowNotification('SyncDeep', '室内(MLO)の復旧を実行中…', 'info', 2500)
    pcall(PerformMLOFix)
end

-- 元の場所へ戻す（2回目のコマンド・上限時間・サーバーのタイムアウトから呼ぶ）
-- 戻る操作はクールダウン・回数制限の対象外
function StartHardFixReturn(reason)
    if not HardFixWaiting then return end
    print(string.format('^2[SyncFix] ^7HardFix return (%s)', reason or 'unknown'))
    RunFix(nil, PerformHardFixReturn, hardFixError, mloFixAfterReturn)
end

local function cmdSyncDeep()
    -- 2回目: 元の場所へ戻る
    if HardFixWaiting then
        local remain = GetHardFixMinStayRemaining()
        if remain > 0 then
            ShowNotification('強力修正', string.format(Config.Messages.Hard.MinStayWait, remain), 'error')
            return
        end
        StartHardFixReturn('command')
        return
    end

    -- 1回目: 待機場所へ移動
    -- 車両内は不可（クールダウンを消費する前に弾く）
    if IsPedInAnyVehicle(PlayerPedId(), false) then
        ShowNotification('強力修正', '車両から降りてから実行してください', 'error')
        return
    end

    RunFix(CheckCooldown, PerformHardFixEnter, hardFixError)
end

-- ========================================================
-- /mlofix（隠しコマンド）
-- ========================================================
local function cmdMloFix()
    if blockIfHardFixWaiting() then return end
    RunFix(CheckCooldown, PerformMLOFix, function(err)
        print('^1[SyncFix] performMLOFix ERROR: ' .. tostring(err) .. '^7')
        ClearFocus(); DoScreenFadeIn(300)
        ShowNotification('エラー', 'MLO修正中にエラーが発生しました', 'error')
    end)
end

-- ========================================================
-- /escape（緊急脱出）
-- ========================================================
local function cmdEscape()
    if blockIfHardFixWaiting() then return end
    if IsFixProcessing then
        ShowNotification('処理中', '修正処理を実行中です', 'error')
        return
    end
    if not CheckEmergencyCooldown() then return end

    IsFixProcessing = true
    CreateThread(function()
        local ok, err = pcall(PerformEmergencyEscape)
        if not ok then
            print('^1[SyncFix] performEmergencyEscape ERROR: ' .. tostring(err) .. '^7')
            ShowNotification('エラー', '緊急脱出処理中にエラーが発生しました', 'error')
            IsFixProcessing = false
            return
        end
        -- フェイルセーフ: 10秒後に強制解放
        CreateThread(function()
            Wait(10000)
            if IsFixProcessing then
                IsFixProcessing = false
                print('^3[SyncFix] emergencyEscape failsafe: force-released isProcessing^7')
            end
        end)
    end)
end

-- ========================================================
-- コマンド登録
-- ========================================================
RegisterCommand(Config.Commands.QuickFix,  cmdSync,     false)
RegisterCommand(Config.Commands.HardFix,   cmdSyncDeep, false)
RegisterCommand(Config.Commands.Emergency, cmdEscape,   false)
RegisterCommand(Config.Commands.MLOFix,    cmdMloFix,   false)

-- 互換コマンド
RegisterCommand('quickreload', cmdSync,     false)
RegisterCommand('hardfix',     cmdSyncDeep, false)

-- チャット候補（3つだけ表示）
CreateThread(function()
    Wait(2000)
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.QuickFix,  '軽量な同期修正（NPC/プレイヤー/描画の軽症向け）')
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.HardFix,   '徹底同期修正（1回目で待機場所へ、2回目で元の場所へ戻る）')
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.Emergency, '緊急脱出（レギオンスクエアへ移動）')
end)

-- ========================================================
-- サーバーイベント受信（汎用通知・同期パルス・強制リセット等）
-- ========================================================

-- 汎用通知
RegisterNetEvent('syncfix:notify', function(data)
    ShowNotification(data.title or 'SyncFix', data.description or '', data.type or 'info')
end)

-- 同期パルス受信
RegisterNetEvent('syncfix:receiveSyncPulse', function(sourcePid)
    local myPed    = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local fixCount = 0

    for _, player in ipairs(GetActivePlayers()) do
        local targetPed = GetPlayerPed(player)
        if targetPed ~= myPed and DoesEntityExist(targetPed) then
            if #(myCoords - GetEntityCoords(targetPed)) < 300.0 then
                SetEntityVisible(targetPed, true, false)
                SetEntityAlpha(targetPed, 255, false)
                SetEntityLodDist(targetPed, 500)
                fixCount = fixCount + 1
            end
        end
    end

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(myCoords - GetEntityCoords(vehicle)) < 200.0 then
            SetEntityVisible(vehicle, true, false)
            SetEntityAlpha(vehicle, 255, false)
            SetEntityLodDist(vehicle, 500)
        end
    end

    if fixCount > 0 then
        ShowNotification('サーバー同期',
            string.format('%d個のエンティティを再同期しました', fixCount), 'success')
    end
end)

RegisterNetEvent('syncfix:dimensionResetComplete', function()
    ShowNotification('次元同期', '次元間移動による同期リセット完了', 'success')
end)

-- 全体強制リセット
RegisterNetEvent('syncmanager:forceReset', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    ClearFocus(); ClearHdArea()

    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() then
            local targetPed = GetPlayerPed(player)
            if DoesEntityExist(targetPed) then
                SetEntityVisible(targetPed, true, false)
                SetEntityAlpha(targetPed, 255, false)
                SetEntityLodDist(targetPed, 500)
            end
        end
    end

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        SetEntityVisible(veh, true, false)
        SetEntityAlpha(veh, 255, false)
        SetEntityLodDist(veh, 500)
    end

    for _, obj in ipairs(GetGamePool('CObject')) do
        if #(coords - GetEntityCoords(obj)) < 200.0 then
            SetEntityVisible(obj, true, false)
            SetEntityAlpha(obj, 255, false)
        end
    end

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 300.0, 0)

    local interior = GetInteriorFromEntity(ped)
    if interior ~= 0 and not IsInteriorLocked() then RefreshInterior(interior) end

    Wait(2000)
    if IsNewLoadSceneActive() then NewLoadSceneStop() end
    ClearFocus()
end)

-- エンティティ所有権リフレッシュ
RegisterNetEvent('syncfix:refreshEntityOwnership', function()
    local myPed    = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local count    = 0

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(myCoords - GetEntityCoords(vehicle)) < 200.0 and NetworkGetEntityIsNetworked(vehicle) then
            NetworkRequestControlOfEntity(vehicle)
            count = count + 1
        end
    end

    for _, obj in ipairs(GetGamePool('CObject')) do
        if #(myCoords - GetEntityCoords(obj)) < 100.0 and NetworkGetEntityIsNetworked(obj) then
            NetworkRequestControlOfEntity(obj)
            count = count + 1
        end
    end

    if count > 0 then
        print(string.format('[SyncFix] Refreshed ownership for %d entities', count))
    end
end)
