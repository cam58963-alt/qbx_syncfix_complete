-- ========================================================
-- server/admin.lua - 管理者コマンド・自動同期・監視スレッド
-- ========================================================

-- ========================================================
-- syncstats コマンド
-- ========================================================
if ServerHasOxLib then
    lib.addCommand('syncstats', {
        help = 'SyncFix stats', restricted = 'group.admin'
    }, function(source)
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local statsData = GetStatsData()
        TriggerClientEvent('syncfix:showStatsNotification', source, statsData)
        TriggerClientEvent('syncfix:showDetailedStats', source, GetPlayerStats(), statsData)
        print('========== SyncFix Statistics ==========')
        print(string.format('Uptime:%dh | Users:%d | /%s:%d /%s:%d /%s:%d /%s:%d',
            statsData.serverUptime, statsData.playerCount,
            Config.Commands.QuickFix,  statsData.totalUsage.QuickFix,
            Config.Commands.HardFix,   statsData.totalUsage.HardFix,
            Config.Commands.MLOFix,    statsData.totalUsage.MLOFix,
            Config.Commands.Emergency, statsData.totalUsage.Emergency))
        print('=======================================')
    end)

    lib.addCommand('myperm', { help = 'Check own permission info' }, function(source)
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local permInfo = '[Identifiers]\n'
        for _, id in ipairs(GetPlayerIdentifiers(source)) do permInfo = permInfo .. id .. '\n' end
        if Player.PlayerData.group then
            permInfo = permInfo .. '\n[QBX Group]\n' .. Player.PlayerData.group
        end
        permInfo = permInfo .. '\n[ACE: command.syncstats] '
            .. (IsPlayerAceAllowed(source, 'command.syncstats') and 'Allowed' or 'Denied')
        TriggerClientEvent('chat:addMessage', source, {
            color = {100,255,100}, multiline = true, args = {'Permission Check', permInfo}
        })
    end)
else
    RegisterCommand('syncstats', function(source)
        if source == 0 then
            local statsData = GetStatsData()
            print('========== SyncFix Console Stats ==========')
            for _, data in pairs(GetPlayerStats()) do
                local total = data.QuickFix + data.HardFix + data.MLOFix + data.Emergency
                print(string.format('  %s: %d uses', data.name, total))
            end
            print('==========================================')
            return
        end
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local g = Player.PlayerData.group
        if g ~= 'admin' and g ~= 'god' then
            TriggerClientEvent('chat:addMessage', source, {color={255,100,100}, args={'Error','Admin only'}})
            return
        end
        local statsData = GetStatsData()
        TriggerClientEvent('syncfix:showDetailedStats', source, GetPlayerStats(), statsData)
    end, false)
end

-- ========================================================
-- 全体強制同期
-- ========================================================
local function forceGlobalSync()
    local players = GetPlayers()
    print('^3[SyncManager] Global sync reset START: ' .. #players .. ' players^7')
    for _, playerId in ipairs(players) do
        TriggerClientEvent('syncmanager:forceReset', tonumber(playerId))
    end
    SetTimeout(5000, function()
        for _, playerId in ipairs(players) do
            TriggerClientEvent('syncfix:notify', tonumber(playerId), {
                title = 'Server Sync', description = 'Server-wide sync has been reset', type = 'info'
            })
        end
        print('^2[SyncManager] Global sync reset DONE^7')
    end)
end

if ServerHasOxLib then
    lib.addCommand('forcesync', {
        help = 'Global sync reset (admin only)', restricted = 'group.admin'
    }, function(source)
        forceGlobalSync()
        if source ~= 0 then
            TriggerClientEvent('syncfix:notify', source, {
                title = 'Admin', description = 'Global sync reset executed', type = 'success'
            })
        end
    end)
else
    RegisterCommand('forcesync', function(source)
        if source == 0 then forceGlobalSync() return end
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return end
        local g = Player.PlayerData.group
        if g == 'admin' or g == 'god' then
            forceGlobalSync()
            TriggerClientEvent('syncfix:notify', source, {title='Admin', description='Global sync reset executed', type='success'})
        else
            TriggerClientEvent('syncfix:notify', source, {title='Error', description='Admin only', type='error'})
        end
    end, false)
end

local adminVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?.?.?'
print('^2[SyncManager] ^7Server sync manager loaded (v' .. adminVersion .. ' modular)')
