# qbx_syncfix_complete

FiveM QBX（QBox）フレームワーク向けの包括的な同期修正リソースです。  
プレイヤーのデシンク（非同期）問題を複数の方式で解決し、MLO読込不具合を予防します。

## 概要

GTA5 FiveM サーバーにおいて頻発する「デシンク」問題に対し、以下の修正手段を提供します。

### プレイヤーコマンド

| コマンド | 方式 | 所要時間 | 用途 |
|---------|------|---------|------|
| `/sync` | ブラックアウト（軽量） | 4-6秒 | 一般的なデシンク修正 |
| `/syncdeep` | 3層隔離（強力） | 8-12秒 | 重度のデシンク・MLO透明化 |
| `/mlofix` | インテリア専用（隠し） | 2-3秒 | MLO内部の透明化対策 |
| `/escape` | 緊急脱出 | 即時 | スタック時のレギオンスクエア脱出 |

### 管理者コマンド

| コマンド | 説明 |
|---------|------|
| `/syncstats` | 使用統計表示 |
| `/forcesync` | 全体同期リセット |
| `/synccheck` | 同期診断（interior ID確認可能） |
| `/checkload` | ストリーミング確認 |

## ファイル構成

```
qbx_syncfix_complete/
├── fxmanifest.lua          リソースマニフェスト (v3.1.0)
├── config.lua              SyncFix本体設定
├── tp_config.lua           テレポートポイント設定（専用ファイル）
├── client/
│   ├── utils.lua           共通ユーティリティ（通知・クールダウン）
│   ├── streaming.lua       MLO/Interiorストリーミング + InteriorLock
│   ├── fixes.lua           修正処理本体（QuickFix/HardFix/MLOFix/Emergency）
│   ├── autofix.lua         自動検知＆修復（Seat-Guard/TP-Guard/可視性/FadeWatch）
│   ├── commands.lua        コマンド登録・イベント受信
│   ├── diagnostics.lua     診断・統計
│   ├── teleport.lua        安全テレポートコア
│   ├── tp_target.lua       ox_target連携テレポート
│   └── tp_marker.lua       マーカー+Eキーテレポート
└── server/
    ├── main.lua            レート制限・Discord Webhook・ログ・同期イベント
    ├── isolation.lua        RoutingBucket隔離（HardFix用）
    └── admin.lua           管理者コマンド・自動同期・モニタリング
```

## 動作原理

### Quick Fix（`/sync`）
画面ブラックアウト中に周辺エンティティのストリーミングをリセットし、再読み込みを行います。

### Hard Fix（`/syncdeep`）
3層隔離方式による強力な同期リセット:
1. **Layer 1** - `FreezeEntityPosition` による物理落下防止
2. **Layer 2** - `SetFocusPosAndVel` によるストリーミング強制切替
3. **Layer 3** - `RoutingBucket`（サーバー側）によるネットワークエンティティ分離

### MLO Fix（`/mlofix`）
インテリアデータのリフレッシュに特化した修正。MLO内部が透明になる問題を解決します。  
※ Interior保護中（強盗中等）はリフレッシュをスキップし、コリジョン再読込のみ実行します。

### Emergency Escape（`/escape`）
テクスチャ欠けやスタック時にレギオンスクエアへ緊急脱出します。  
手錠中・死亡中・戦闘中は使用不可。

## テレポートモジュール

MLO読込不具合の**予防**として、SyncFixスクリプト内でテレポートを管理します。  
TP時に `EnsureMloLoadedAtCoords` で3段階MLOプリロードを自動実行するため、  
移動先のMLOが透明になる問題を防止します。

### 処理フロー（7フェーズ）
```
1. フェードアウト
2. エンティティ固定 (FreezeEntityPosition)
3. MLOプリロード (EnsureMloLoadedAtCoords)
   └ ForceStreamAt(広域) → RefreshInteriorAt → ForceStreamAt(精密)
4. 物理移動 (SetEntityCoords)
5. コリジョンロード待ち
6. Interior最終確認 (RefreshAndWaitInterior)
7. 解放・フェードイン
```

### 使用パターン

| パターン | 方式 | 設定 |
|----------|------|------|
| ターゲット | ox_target SphereZone | `type = 'target'` |
| マーカー+Eキー | DrawMarker + Eキー | `type = 'marker'` |
| 移動先1件 | 即テレポート | `destinations` が1要素 |
| 移動先複数 | ox_lib メニュー表示 | `destinations` が2要素以上 |

### 設定例（tp_config.lua）

```lua
Config.Teleports.Points = {
    -- ターゲット方式（ox_target でアイコン表示 → 即TP）
    {
        id     = 'garage_entrance',
        label  = 'ガレージ入口',
        type   = 'target',
        origin = vec3(215.0, -810.0, 30.0),
        radius = 1.5,
        icon   = 'fa-solid fa-door-open',
        destinations = {
            { label = 'ガレージ内部', coords = vec4(228.5, -995.5, -99.0, 0.0), isMlo = true }
        }
    },

    -- マーカー方式（地面にマーカー → Eキー → メニュー選択）
    {
        id     = 'elevator',
        label  = 'エレベーター',
        type   = 'marker',
        origin = vec3(-140.0, -630.0, 168.0),
        radius = 1.2,
        marker = {
            type      = 1,
            color     = {r = 50, g = 150, b = 250, a = 120},
            size      = {x = 0.8, y = 0.8, z = 0.5},
            bobUpDown = false
        },
        destinations = {
            { label = '1F ロビー',   coords = vec4(-140.0, -630.0, 42.0,  230.0), isMlo = true },
            { label = '屋上',        coords = vec4(-140.0, -630.0, 168.0, 230.0), isMlo = false },
            { label = '地下駐車場',  coords = vec4(-145.0, -635.0, -5.0,  230.0), isMlo = true }
        }
    },
}
```

## Interior保護機構（InteriorLock）

強盗スクリプト等がinterior状態（爆破された壁・ドア等）を管理している間、  
SyncFixの `RefreshInterior` が走ると状態が初期化されてしまう問題を防止します。

### 動的ロック（推奨）
外部スクリプトからexportsで座標ベースで制御:
```lua
-- 強盗開始時にロック（座標 + 半径 + 高さで円柱型保護エリア指定）
local coords = vec3(x, y, z)
exports.qbx_syncfix_complete:LockInteriorAtCoords(coords, 30.0, 10.0)
--                                                       半径↑    ↑高さ(中心Z±10m)

-- 強盗終了時に解除
exports.qbx_syncfix_complete:UnlockInteriorAtCoords(coords)

-- 全interior一括ロック/解除
exports.qbx_syncfix_complete:LockAllInteriors()
exports.qbx_syncfix_complete:UnlockAllInteriors()

-- ロック状態確認
exports.qbx_syncfix_complete:IsInteriorLocked()    -- プレイヤー現在座標で判定
exports.qbx_syncfix_complete:IsAreaLocked(coords)   -- 任意の座標で判定
```

### 静的保護
`config.lua` に常時保護するエリアを座標+半径+高さで記載:
```lua
Config.ProtectedInteriors = {
    { label = 'ユニオン預金', coords = vec3(x, y, z), radius = 30.0, height = 10.0 },
}
```
※ interior ID はサーバー再起動で変わるため、座標ベースで判定します。

### ガード適用箇所
ロック中は以下の全箇所で `RefreshInterior` / `DisableInterior` をスキップします:
- 自動修復（Seat-Guard / TP-Guard）
- 手動コマンド（`/mlofix` / `/syncdeep` / `/forcesync`）
- テレポート処理
- 全体強制リセット

## 依存リソース

- [qbx_core](https://github.com/Qbox-project/qbx_core)
- [ox_lib](https://github.com/overextended/ox_lib)
- [ox_target](https://github.com/overextended/ox_target)（テレポートのtarget方式に必要。なくても動作）

## インストール

1. このリポジトリをサーバーの `resources` フォルダにクローンまたはダウンロード
2. `server.cfg` に以下を追加:
   ```cfg
   ensure ox_lib
   ensure qbx_core
   ensure qbx_syncfix_complete
   ```
3. （推奨）Discord Webhook を環境変数で設定:
   ```cfg
   setr syncfix_webhook "https://discord.com/api/webhooks/YOUR_WEBHOOK_URL"
   ```
4. `tp_config.lua` にテレポートポイントを設定

## 設定ファイル

### config.lua（SyncFix本体）
- **コマンド名** - 各コマンドの名前変更
- **Discord Webhook** - 使用ログの送信先・サーバー名・カラー
- **HardFix パラメータ** - 隔離座標・滞在時間・待機中テキスト
- **緊急脱出** - 脱出先座標・制限設定
- **クールダウン** - 使用回数・間隔制限
- **Interior保護** - `Config.ProtectedInteriors` で常時保護対象を指定
- **通知メッセージ** - 各種メッセージのカスタマイズ

### tp_config.lua（テレポート専用）
- **有効/無効** - `Config.Teleports.Enabled`
- **フェード設定** - フェードアウト/インの時間
- **メニュー設定** - ox_lib メニューの表示位置
- **ポイント一覧** - `Config.Teleports.Points` にTP地点を追加

## セキュリティ

- サーバー側でのレート制限（全イベント）
- 座標バリデーション（異常座標検知）
- RoutingBucket のサーバー側管理
- 管理者コマンドの権限制御
- Webhook URL の環境変数管理（Convar推奨）

## Exports一覧

### クライアント側
```lua
-- テレポート
exports.qbx_syncfix_complete:PerformSafeTeleport(dest, label)
exports.qbx_syncfix_complete:IsTeleporting()

-- MLOロード
exports.qbx_syncfix_complete:EnsureMloLoadedAtCoords(coords)

-- Interior保護（座標ベース）
exports.qbx_syncfix_complete:LockInteriorAtCoords(coords, radius, height)
exports.qbx_syncfix_complete:UnlockInteriorAtCoords(coords)
exports.qbx_syncfix_complete:LockAllInteriors()
exports.qbx_syncfix_complete:UnlockAllInteriors()
exports.qbx_syncfix_complete:IsInteriorLocked()      -- プレイヤー座標で判定
exports.qbx_syncfix_complete:IsAreaLocked(coords)     -- 任意座標で判定
```

## バージョン履歴

- **v3.1.0** - テレポートモジュール追加、Interior保護機構、Discord日本語化、TP設定分離、vec統一
- **v3.0.1** - HardFix後MLOFix誤実行修正、カメラアングル異常修正
- **v3.0.0** - モジュール分割（client 6ファイル / server 3ファイル）、重複コード除去
- **v2.2.0** - VirtualRoom/Camera廃止、FreezeEntityPosition + RoutingBucket 3層隔離方式に刷新
- **v2.1.x** - レート制限・バリデーション強化
- **v2.0.0** - 初回リリース

## ライセンス

このリソースは特定サーバー向けに作成されています。  
利用条件については作者にお問い合わせください。

## 技術仕様

- **FiveM fx_version**: cerulean
- **Lua**: 5.4
- **フレームワーク**: QBX (QBox)
- **ゲーム**: GTA5
