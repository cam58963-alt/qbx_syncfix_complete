-- ========================================================
-- client/tp_marker.lua - マーカー + Eキー テレポート
-- ========================================================
-- 依存: client/teleport.lua (OpenTeleportMenu, IsTeleporting)
--       client/utils.lua (IsFixProcessing, CheckJobRestriction)

-- ========================================================
-- 描画用ヘルパー
-- ========================================================
local function drawMarker3D(cfg, origin)
    local m = cfg.marker or {}
    local mType = m.type or 1
    local c     = m.color or {r = 50, g = 150, b = 250, a = 120}
    local s     = m.size  or {x = 0.8, y = 0.8, z = 0.5}
    local bob   = m.bobUpDown or false

    DrawMarker(
        mType,
        origin.x, origin.y, origin.z - 0.95,  -- 地面に接地
        0.0, 0.0, 0.0,       -- 方向
        0.0, 0.0, 0.0,       -- 回転
        s.x, s.y, s.z,       -- スケール
        c.r, c.g, c.b, c.a,  -- 色
        bob,                  -- 上下アニメ
        false, 2, false, nil, nil, false
    )
end

local function drawHelpText(text)
    SetTextComponentFormat('STRING')
    AddTextComponentString(text)
    DisplayHelpTextFromStringLabel(0, false, true, -1)
end

-- ========================================================
-- マーカーポイント収集
-- ========================================================
CreateThread(function()
    if not Config.Teleports or not Config.Teleports.Enabled then return end

    local points = Config.Teleports.Points
    if not points then return end

    -- type='marker' のポイントだけ抽出
    local markerPoints = {}
    for _, point in ipairs(points) do
        if point.type == 'marker' and point.origin and point.destinations then
            markerPoints[#markerPoints + 1] = point
        end
    end

    if #markerPoints == 0 then return end

    print(string.format('^2[SyncFix] ^7Registered %d marker teleport point(s)', #markerPoints))

    -- ========================================================
    -- 描画 + 操作検知ループ
    -- ========================================================
    local interactKey     = 38   -- E キー (INPUT_CONTEXT)
    local drawDistance    = 15.0 -- マーカー描画開始距離（負荷軽減のため30→15m）
    local interactCooldown = 0   -- 連打防止

    while true do
        local ped       = PlayerPedId()
        local pedCoords = GetEntityCoords(ped)
        local sleep     = 500  -- デフォルトは低負荷

        for _, point in ipairs(markerPoints) do
            local dist = #(pedCoords - point.origin)

            if dist < drawDistance then
                -- job制限: 該当jobでなければマーカー自体を非表示
                if not CheckJobRestriction(point, true) then
                    goto continue_marker
                end

                sleep = 4  -- 近くにいる → ~15fps描画（0ms=毎フレームは高負荷）

                -- マーカー描画
                drawMarker3D(point, point.origin)

                -- 操作圏内チェック
                local radius = point.radius or 1.2
                if dist < radius then
                    -- ヘルプテキスト表示
                    local hintText = string.format(
                        Config.Messages.Teleport.KeyHint,
                        point.label or '移動する'
                    )
                    drawHelpText(hintText)

                    -- Eキー押下
                    if IsControlJustReleased(0, interactKey) then
                        local now = GetGameTimer()
                        if now > interactCooldown
                            and not IsTeleporting()
                            and not IsFixProcessing
                            and CheckTeleportRestrictions()
                            and CheckJobRestriction(point) then

                            interactCooldown = now + 1500  -- 1.5秒クールダウン
                            OpenTeleportMenu(point)
                        end
                    end
                end
            end

            ::continue_marker::
        end

        Wait(sleep)
    end
end)
