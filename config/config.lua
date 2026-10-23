-- ========================================================
-- config/config.lua
-- バージョンは fxmanifest.lua の version フィールドで一元管理
-- ========================================================

Config = {}

-- デバッグモード（FadeWatch等のデバッグ専用機能を有効化 ※本番はfalse）
Config.Debug = false

-- 基本コマンド設定
Config.Commands = {
    QuickFix  = 'sync',
    HardFix   = 'syncdeep',
    MLOFix    = 'mlofix'    -- 残す（ただし suggestion には出さない）
}

-- ========================================================
-- [CFG1] Discord Webhook設定
-- ⚠️ 警告: WebhookURL をソースコードに直接記述しないでください。
--   推奨: server.cfg に以下を追加して環境変数として管理
--     setr syncfix_webhook "https://discord.com/api/webhooks/..."
--   Lua 側で GetConvar('syncfix_webhook', '') で取得してください。
-- ========================================================
Config.Discord = {
    Enabled    = true,

    -- ✅ 推奨: server.cfg の Convar から読み込む
    --   setr syncfix_webhook "https://discord.com/api/webhooks/..."
    -- server.lua 側で GetConvar('syncfix_webhook', '') を優先します
    WebhookURL = '',

    ServerName = 'Midnight city',
    Colors = {
        QuickFix  = 3447003,
        HardFix   = 15158332,
        MLOFix    = 10181046,
        Teleport  = 5025616
    }
}


-- ========================================================
-- HardFix設定（/syncdeep・2回使う方式）
--   1回目: 待機場所へ移動し、元の場所を記録（サーバーの metadata.syncfix_return）
--   2回目: 元の場所へ戻り、記録を削除
--   待機中に切断しても、次回ログイン時に記録した元の場所へ自動で戻る
--
-- SafeCoords: 待機場所（マップ外の上空）
--   元の場所のストリーミングが確実に切れるよう、マップから十分離れた座標にする
--
-- RoutingBucket: 待機中は src+50000 の一時バケットに隔離（server/isolation.lua）
-- ========================================================
Config.HardFix = {
    -- 待機場所（マップ外の上空）
    SafeCoords = vec4(12000.0, 12000.0, 2000.0, 0.0),

    -- 元の場所の記録がないまま待機場所に取り残されたときの戻り先（レギオンスクエア）
    FallbackLocation = vec4(200.04, -921.56, 29.50, 155.86),

    -- 戻れるようになるまでの最短待機秒数
    -- 元の場所の読み込みが消えきる前に戻ると効果が落ちるため（0 で無効）
    MinStay = 5,

    -- 待機の上限秒数。過ぎると自動で元の場所に戻す（0 で無制限）
    -- 無制限にすると、無敵・隔離状態のまま隠れ続けられる点に注意
    MaxStay = 600,

    -- 待機用シェル（任意）
    --   model を設定すると、SafeCoords にシェルを出して中へ送る（待機中は自由に歩ける）
    --   未設定、またはモデルが見つからないときは空中でフリーズして待機する
    --   spawnOffset: シェルの中心からの立ち位置（x, y, z, 向き）。シェルごとに調整が必要
    Shell = {
        model       = nil,   -- 例: 'shell_example'
        spawnOffset = vec4(0.0, 0.0, 0.0, 0.0)
    },

    -- 待機中の画面表示
    WaitingText = {
        header = '同期修正 待機中',
        description = 'エリアデータをリセットしています',
        position = {x = 0.5, y = 0.8}
    }
}


-- 基本使用制限
Config.Limits = {
    Cooldown       = 10,
    MaxUsesPerHour = 12
}

-- ========================================================
-- Interior保護設定（座標ベース・円柱型判定）
-- ========================================================
-- RefreshInterior を禁止するエリアを座標+半径+高さで指定。
-- 強盗MLO等、スクリプトが壁・ドアの状態を管理している場所に設定する。
-- interior ID はサーバー再起動やMLO更新で変わるため、座標で判定する。
--
--   coords : エリア中心座標 (vec3)
--   radius : 水平方向の判定半径 (XY平面)   デフォルト 30.0
--   height : 垂直方向の判定幅 (中心Z ± height)  デフォルト 10.0
--
-- 動的ロック（強盗開始時にロック→終了時に解除）も可能:
--   exports.qbx_syncfix_complete:LockInteriorAtCoords(vec3, radius, height)
--   exports.qbx_syncfix_complete:UnlockInteriorAtCoords(vec3)
--   exports.qbx_syncfix_complete:LockAllInteriors()
--   exports.qbx_syncfix_complete:UnlockAllInteriors()
-- ========================================================
Config.ProtectedInteriors = {
    { label = 'ユニオン強盗', coords = vec3(6.48, -658.91, 15.13), radius = 50.0, height = 10.0 },
}

-- ========================================================
-- テレポート設定 → tp_config.lua に分離
-- ========================================================
-- ポイント定義は tp_config.lua を編集してください

-- 通知メッセージ
Config.Messages = {
    Quick = {
        Start      = '画面ブラックアウト方式で修正開始',
        Processing = '周辺データを再読込中...',
        Complete   = '同期修正が完了しました'
    },
    Hard = {
        Start     = '強力同期リセット開始（3層隔離）',
        Moving    = '安全な隔離空間へ移動中...',
        Waiting   = '待機中です。/%s をもう一度入力すると元の場所に戻ります',
        ReturnHint = '/%s で元の場所に戻ります',
        MinStayWait = 'あと %d 秒待ってから戻ってください',
        BlockedWhileWaiting = '待機中です。先に /%s で元の場所に戻ってください',
        Returning = '元の場所へ復帰中...',
        Complete  = '強力修正が完了しました'
    },
    MLO = {
        Start      = 'インテリア専用修正を開始',
        Processing = 'インテリアデータをリフレッシュ中...',
        Complete   = 'インテリア修正完了'
    },
    Teleport = {
        Start    = '移動を開始します...',
        Loading  = 'エリアデータを読み込み中...',
        Complete = '移動が完了しました',
        KeyHint  = '[E] %s',
        BlockedEscorted   = 'エスコート中は移動できません',
        BlockedHandcuffed = '手錠中は移動できません',
        BlockedDead       = 'この状態では移動できません',
        EscortSync        = '連行中のプレイヤーも一緒に移動します',
        EscortSynced      = '連行者と一緒に移動しました',
        BlockedJob         = 'この職業では使用できません'
    }
}
