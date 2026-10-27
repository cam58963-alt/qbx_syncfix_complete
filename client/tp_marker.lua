-- ========================================================
-- client/tp_marker.lua - マーカー + Eキー テレポート
-- ========================================================
-- 依存: client/teleport.lua (OpenTeleportMenu, IsTeleporting)
--       client/utils.lua (IsFixProcessing, CheckJobRestriction)
--       ox_lib (lib.points / lib.showTextUI)
--
-- 負荷対策:
--   lib.points を使い、近くにあるポイントだけが毎フレーム動く
--   （以前は全ポイントとの距離を自前のループで測り続けていた）
--   ジョブ確認はキャッシュ済みのプレイヤーデータを使う（client/utils.lua）
--   テキストUIは表示・非表示が切り替わるときだけ送る（毎フレーム送らない）

local DRAW_DISTANCE = 10.0  -- マーカーを描き始める距離（m）
local INTERACT_KEY  = 38    -- E キー (INPUT_CONTEXT)

local function drawMarker(point, coords)
    local m = point.marker or {}
    local c = m.color or { r = 50, g = 150, b = 250, a = 120 }
    local s = m.size  or { x = 0.8, y = 0.8, z = 1.0 }

    DrawMarker(
        m.type or 1,
        coords.x, coords.y, coords.z,   -- origin は地面の高さで指定する
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        s.x, s.y, s.z,
        c.r, c.g, c.b, c.a,
        m.bobUpDown or false,
        true, 2, false, nil, nil, false
    )
end

CreateThread(function()
    if not Config.Teleports or not Config.Teleports.Enabled then return end
    if not lib or not lib.points then
        print('^3[SyncFix] ^7ox_lib (lib.points) not found - marker teleports disabled')
        return
    end

    local textShownFor     = nil  -- テキストUIを出しているポイントの id
    local interactCooldown = 0    -- 連打防止

    local function hideText(id)
        if textShownFor and (id == nil or textShownFor == id) then
            lib.hideTextUI()
            textShownFor = nil
        end
    end

    local count = 0
    for _, point in ipairs(Config.Teleports.Points or {}) do
        if point.type == 'marker' and point.origin and point.destinations then
            local radius = point.radius or 1.2
            local p = lib.points.new({
                coords   = vec3(point.origin.x, point.origin.y, point.origin.z),
                distance = DRAW_DISTANCE,
            })

            function p:nearby()
                -- job制限: 該当jobでなければマーカー自体を非表示
                if not CheckJobRestriction(point, true) then
                    hideText(point.id)
                    return
                end

                drawMarker(point, self.coords)

                if self.currentDistance > radius then
                    hideText(point.id)
                    return
                end

                if textShownFor ~= point.id then
                    lib.showTextUI(string.format(Config.Messages.Teleport.KeyHint, point.label or '移動する'),
                        { position = 'right-center' })
                    textShownFor = point.id
                end

                if IsControlJustReleased(0, INTERACT_KEY) then
                    local now = GetGameTimer()
                    if now > interactCooldown and not IsTeleporting() and not IsFixProcessing then
                        interactCooldown = now + 1500
                        hideText(point.id)
                        OpenTeleportMenu(point)   -- 制限・ジョブの確認（通知あり）はこの中で行う
                    end
                end
            end

            function p:onExit()
                hideText(point.id)
            end

            count = count + 1
        end
    end

    if count > 0 then
        print(string.format('^2[SyncFix] ^7Registered %d marker teleport point(s)', count))
    end
end)
