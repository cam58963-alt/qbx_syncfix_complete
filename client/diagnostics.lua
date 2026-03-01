-- ========================================================
-- client/diagnostics.lua - 診断・統計表示
-- ========================================================

-- ========================================================
-- /synccheck - 同期診断
-- ========================================================
RegisterCommand('synccheck', function()
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)

    local visiblePlayers, totalPlayers   = 0, 0
    local visibleVehicles, totalVehicles = 0, 0

    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() then
            totalPlayers = totalPlayers + 1
            if IsEntityVisible(GetPlayerPed(player)) then
                visiblePlayers = visiblePlayers + 1
            end
        end
    end

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(coords - GetEntityCoords(vehicle)) < 100.0 then
            totalVehicles = totalVehicles + 1
            if IsEntityVisible(vehicle) then visibleVehicles = visibleVehicles + 1 end
        end
    end

    print('========== Sync Diagnostics ==========')
    print('Position   : ' .. string.format('%.1f, %.1f, %.1f', coords.x, coords.y, coords.z))
    print('Interior ID: ' .. GetInteriorFromEntity(ped))
    print('Collision  : ' .. (HasCollisionLoadedAroundEntity(ped) and 'OK' or 'NG'))
    print('Streaming  : ' .. (IsNewLoadSceneActive() and 'Active' or 'Idle'))
    print(string.format('Players    : %d/%d visible (%.1f%%)',
        visiblePlayers, totalPlayers,
        totalPlayers > 0 and (visiblePlayers / totalPlayers * 100) or 0))
    print(string.format('Vehicles   : %d/%d visible (%.1f%%)',
        visibleVehicles, totalVehicles,
        totalVehicles > 0 and (visibleVehicles / totalVehicles * 100) or 0))
    print(string.format('HardFix Isolated: %s', HardFixIsolated and 'YES' or 'no'))
    print('====================================')

    ShowNotification('同期診断',
        string.format('Players: %d/%d | Vehicles: %d/%d\nSee F8 for details',
            visiblePlayers, totalPlayers, visibleVehicles, totalVehicles),
        'info', 8000)
end, false)

-- ========================================================
-- /checkload - ストリーミング確認
-- ========================================================
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

    ShowNotification('ストリーミング確認',
        string.format('Vehicles: %d | Objects: %d\nSee F8 for details',
            nearbyVehicles, nearbyObjects), 'info', 5000)
end, false)

-- ========================================================
-- 統計イベント受信
-- ========================================================
RegisterNetEvent('syncfix:showStatsNotification', function(statsData)
    ShowNotification('SyncFix Statistics', string.format(
        'Uptime: %dh | Users: %d\n/%s: %d | /%s: %d\n/%s: %d | /%s: %d',
        statsData.serverUptime, statsData.playerCount,
        Config.Commands.QuickFix,  statsData.totalUsage.QuickFix,
        Config.Commands.HardFix,   statsData.totalUsage.HardFix,
        Config.Commands.MLOFix,    statsData.totalUsage.MLOFix,
        Config.Commands.Emergency, statsData.totalUsage.Emergency
    ), 'info', 8000)
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
