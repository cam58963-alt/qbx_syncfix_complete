-- ========================================================
-- tp_config.lua - テレポートポイント設定
-- ========================================================
-- ★ このファイルにTPポイントを追加していくだけでOKです
--    config.lua を触る必要はありません
--
-- 各ポイントの構造:
--   id          : 一意な識別子（文字列）
--   label       : 表示名
--   type        : 'target' = ox_target で表示 / 'marker' = マーカー+Eキー
--   origin      : テレポート開始地点の座標 (vec3/vec4)
--   radius      : 反応範囲（接近判定半径 / ターゲットゾーン半径）
--   icon        : ox_target のアイコン名（type='target' 時のみ）
--   marker      : マーカー設定（type='marker' 時のみ）
--     type      : マーカータイプ（GTA native ID）
--     color     : {r, g, b, a}
--     size      : {x, y, z}
--     bobUpDown : 上下アニメーション
--   jobs        : 使用許可職業の配列（複数対応）
--                  nil / 空テーブル → 全員使用可
--                  {'ambulance'}            → EMS専用
--                  {'ambulance', 'police'}  → EMS + 警察
--   destinations: 移動先の配列（1件なら即TP、2件以上ならメニュー表示）
--     label     : メニュー表示名
--     coords    : 移動先座標 (vec4)  ← ゲーム内 /vec4 の値をそのまま貼り付けOK
--     isMlo     : true なら MLOプリロード実行（透明化・すり抜け防止）
-- ========================================================

Config.Teleports = {
    Enabled = true,

    -- フェード設定
    FadeDuration = 500,      -- フェードアウト/インの時間(ms)
    LoadTimeout  = 8000,     -- MLOロードの最大待ち時間(ms)

    -- メニュー設定（ox_lib）
    MenuPosition = 'top-right',

    -- ========================================================
    -- 制限設定
    -- ========================================================
    Restrictions = {
        -- エスコートされている側（被連行者）は単独TPをブロック
        BlockIfEscorted = true,

        -- 手錠をかけられている場合は単独TPをブロック
        BlockIfHandcuffed = true,

        -- 死亡・瀕死時はTPをブロック
        BlockIfDead = true,

        -- エスコートしている側がTPするとき、被連行者も一緒に移動
        -- ★ 病院ヘリポートなど、連行者と被連行者がセットで移動する必要がある場合に必須
        EscortedPlayerSync = true,
    },

    -- ========================================================
    -- テレポートポイント一覧
    -- ★ ここにポイントを追加していってください
    -- ========================================================
    Points = {

        -- ============================================
        -- 軍事基地エレベーター（ターゲット方式 / 即TP）
        -- ============================================
        {
            id     = 'military_base_1F',
            label  = '1F',
            type   = 'target',
            origin = vec3(-2361.25, 3250.75, 32.81),
            radius = 1.5,
            destinations = {
                { label = '上へ', coords = vec4(-2361.08, 3248.96, 92.9, 332.48), isMlo = true }
            }
        },

        {
            id     = 'military_base_R',
            label  = 'R',
            type   = 'target',
            origin = vec3(-2361.26, 3250.64, 92.9),
            radius = 1.5,
            destinations = {
                { label = '下へ', coords = vec4(-2360.88, 3249.0, 32.81, 331.25), isMlo = true }
            }
        },

        -- ============================================
        -- EMS エレベーター（マーカー方式 / メニュー）
        -- ★ jobs = {'ambulance'} → ambulance職のみ使用可
        -- ============================================
        {
            id     = 'EMS_Elevator_Hospital1F',
            label  = '石川病院1F',
            type   = 'marker',
            origin = vec3(1140.97, -1568.37, 35.50),
            radius = 1.2,
            jobs   = {'ambulance'},
            marker = {
                type      = 1,
                color     = {r = 50, g = 150, b = 250, a = 120},
                size      = {x = 0.8, y = 0.8, z = 0.5},
                bobUpDown = false
            },
            destinations = {
                { label = '石川病院2F',             coords = vec4(1140.95, -1568.24, 40.00, 358.56), isMlo = true },
                { label = '霧科クリニックヘリポート', coords = vec4(-251.24, 6324.78, 37.7, 230.64), isMlo = true },
                { label = '霧科クリニック1F',         coords = vec4(-251.72, 6324.52, 32.43, 312.15), isMlo = true },
                { label = '霧科クリニックB1F',        coords = vec4(-249.61, 6323.41, 29.73, 131.82), isMlo = true }
            }
        },

        {
            id     = 'EMS_Elevator_Hospital2F',
            label  = '石川病院2F',
            type   = 'marker',
            origin = vec3(1140.92, -1568.28, 39.5),
            radius = 1.2,
            jobs   = {'ambulance'},
            marker = {
                type      = 1,
                color     = {r = 50, g = 150, b = 250, a = 120},
                size      = {x = 0.8, y = 0.8, z = 0.5},
                bobUpDown = false
            },
            destinations = {
                { label = '石川病院1F',             coords = vec4(1140.87, -1568.63, 36.00, 357.3),  isMlo = true },
                { label = '霧科クリニックヘリポート', coords = vec4(-251.24, 6324.78, 37.7, 230.64), isMlo = true },
                { label = '霧科クリニック1F',         coords = vec4(-251.72, 6324.52, 32.43, 312.15), isMlo = true },
                { label = '霧科クリニックB1F',        coords = vec4(-249.61, 6323.41, 29.73, 131.82), isMlo = true }
            }
        },

        {
            id     = 'EMS_Elevator_ClinicHeli',
            label  = '霧科クリニックヘリポート',
            type   = 'marker',
            origin = vec3(-251.24, 6324.78, 37.7),
            radius = 1.2,
            jobs   = {'ambulance'},
            marker = {
                type      = 1,
                color     = {r = 50, g = 150, b = 250, a = 120},
                size      = {x = 0.8, y = 0.8, z = 0.5},
                bobUpDown = false
            },
            destinations = {
                { label = '石川病院1F',       coords = vec4(1140.87, -1568.63, 36.00, 357.3),  isMlo = true },
                { label = '石川病院2F',       coords = vec4(1140.95, -1568.24, 40.0, 358.56),  isMlo = true },
                { label = '霧科クリニック1F',  coords = vec4(-251.72, 6324.52, 32.43, 312.15), isMlo = true },
                { label = '霧科クリニックB1F', coords = vec4(-249.61, 6323.41, 29.73, 131.82), isMlo = true }
            }
        },

        {
            id     = 'EMS_Elevator_Clinic1F',
            label  = '霧科クリニック1F',
            type   = 'marker',
            origin = vec3(-251.72, 6324.52, 32.43),
            radius = 1.2,
            jobs   = {'ambulance'},
            marker = {
                type      = 1,
                color     = {r = 50, g = 150, b = 250, a = 120},
                size      = {x = 0.8, y = 0.8, z = 0.5},
                bobUpDown = false
            },
            destinations = {
                { label = '石川病院1F',             coords = vec4(1140.87, -1568.63, 36.00, 357.3),  isMlo = true },
                { label = '石川病院2F',             coords = vec4(1140.95, -1568.24, 40.0, 358.56),  isMlo = true },
                { label = '霧科クリニックヘリポート', coords = vec4(-251.24, 6324.78, 37.7, 230.64), isMlo = true },
                { label = '霧科クリニックB1F',        coords = vec4(-249.61, 6323.41, 29.73, 131.82), isMlo = true }
            }
        },

        {
            id     = 'EMS_Elevator_ClinicB1F',
            label  = '霧科クリニックB1F',
            type   = 'marker',
            origin = vec3(-249.61, 6323.41, 29.73),
            radius = 1.2,
            jobs   = {'ambulance'},
            marker = {
                type      = 1,
                color     = {r = 50, g = 150, b = 250, a = 120},
                size      = {x = 0.8, y = 0.8, z = 0.5},
                bobUpDown = false
            },
            destinations = {
                { label = '石川病院1F',             coords = vec4(1140.87, -1568.63, 36.00, 357.3),  isMlo = true },
                { label = '石川病院2F',             coords = vec4(1140.95, -1568.24, 39.5, 358.56),  isMlo = true },
                { label = '霧科クリニックヘリポート', coords = vec4(-251.24, 6324.78, 37.7, 230.64), isMlo = true },
                { label = '霧科クリニック1F',         coords = vec4(-251.72, 6324.52, 32.43, 312.15), isMlo = true },
            }
        },

    }
}
