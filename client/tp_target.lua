-- ========================================================
-- client/tp_target.lua - ox_target 連携テレポート
-- ========================================================
-- 依存: client/teleport.lua (OpenTeleportMenu, IsTeleporting)
--       client/utils.lua (IsFixProcessing, CheckJobRestriction)
--       ox_target (必須)

-- ox_target がなければスキップ
if GetResourceState('ox_target') ~= 'started' then
    print('^3[SyncFix] ^7ox_target not found - target teleports disabled')
    return
end

-- ========================================================
-- Config から type='target' のポイントを登録
-- ========================================================
CreateThread(function()
    if not Config.Teleports or not Config.Teleports.Enabled then return end

    local points = Config.Teleports.Points
    if not points then return end

    local count = 0
    for _, point in ipairs(points) do
        if point.type == 'target' and point.origin and point.destinations then
            -- ox_target の SphereZone を使用
            exports.ox_target:addSphereZone({
                coords = point.origin,
                radius = point.radius or 1.5,
                debug  = false,
                options = {
                    {
                        name     = 'syncfix_tp_' .. point.id,
                        label    = point.label or '移動する',
                        icon     = point.icon or 'fa-solid fa-door-open',
                        distance = point.radius or 1.5,
                        canInteract = function()
                            return not IsTeleporting() and not IsFixProcessing
                                and CheckTeleportRestrictions()
                                and CheckJobRestriction(point, true)
                        end,
                        onSelect = function()
                            OpenTeleportMenu(point)
                        end
                    }
                }
            })
            count = count + 1
        end
    end

    if count > 0 then
        print(string.format('^2[SyncFix] ^7Registered %d target teleport point(s)', count))
    end
end)
