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
    MLOFix    = 'mlofix',   -- 残す（ただし suggestion には出さない）
    Emergency = 'escape'
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
        Emergency = 16776960,
        Teleport  = 5025616
    }
}


-- ========================================================
-- HardFix設定
-- [v2.2] props/カメラ廃止 → FreezeEntityPosition + RoutingBucket方式
--
-- SafeCoords: プレイヤーを一時待機させる座標
--   条件:
--     ① マップ外（X/Y が ±4000 以上）→ 元の場所が必ずストリーミング範囲外に出る
--     ② 高度50m程度     → 地形なし・海面なしで安定
--     ③ 全プレイヤーの元座標から十分離れている（最低8,000m以上推奨）
--
-- RoutingBucket: 隔離に使う一時バケット番号
--   ※ 既存バケット（0=通常、1〜9999=他用途）と重複しない番号を指定
--      一般的に 50000+playerServerId を動的に使うため、ここでは使用しない
--      → server.lua 側で src+50000 を自動計算
--
-- StayTime: 隔離中の待機秒数
--   短すぎると元の場所のアンロードが不完全になる
--   推奨: 6〜10秒
-- ========================================================
-- ★ 追加が必要（VirtualRoom → HardFix）
Config.HardFix = {
    -- マップ外の安全な座標
    SafeCoords = vec4(12000.0, 12000.0, 2000.0, 0.0),
    
    -- 滞在時間（秒）
    StayTime = 12,
    
    -- 待機中のテキスト表示
    WaitingText = {
        header = '同期修正実行中',
        description = 'エリアデータを完全リセット中...\nしばらくお待ちください',
        position = {x = 0.5, y = 0.8}
    }
}


-- 緊急脱出設定
Config.Emergency = {
    Enabled        = true,
    EscapeLocation = vec4(200.04, -921.56, 29.50, 155.86),

    Restrictions = {
        BlockIfHandcuffed = true,
        BlockIfDead       = true,
        BlockIfInCombat   = true
    },

    Cooldown       = 60,
    MaxUsesPerHour = 3
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
        Waiting   = '元エリアのデータを完全破棄中...',
        Countdown = 'あと %d 秒で元の場所に戻ります',
        Returning = '元の場所へ復帰中...',
        Complete  = '強力修正が完了しました'
    },
    MLO = {
        Start      = 'インテリア専用修正を開始',
        Processing = 'インテリアデータをリフレッシュ中...',
        Complete   = 'インテリア修正完了'
    },
    Emergency = {
        Start   = '緊急脱出を実行',
        Moving  = 'レギオンスクエアへ移動中...',
        Complete= 'レギオンスクエアに安全に到着しました',
        Blocked = 'この状況では緊急脱出を使用できません'
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
