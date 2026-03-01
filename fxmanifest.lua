fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbx_syncfix_complete'
author 'QBX SyncFix Team'
description 'Complete desync fix for QBX Framework (modular)'
version '3.4.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config/config.lua',
    'config/tp_config.lua'
}

-- 読み込み順が重要: utils → streaming → fixes → autofix → commands → diagnostics → teleport → tp_target → tp_marker
client_scripts {
    'client/utils.lua',
    'client/streaming.lua',
    'client/fixes.lua',
    'client/autofix.lua',
    'client/commands.lua',
    'client/diagnostics.lua',
    'client/teleport.lua',
    'client/tp_target.lua',
    'client/tp_marker.lua'
}

-- 読み込み順が重要: main → isolation → admin
server_scripts {
    'server/main.lua',
    'server/isolation.lua',
    'server/admin.lua'
}

dependencies {
    'qbx_core',
    'ox_lib'
}

--[[
コマンド一覧:
  /sync      - 軽量同期修正（ブラックアウト方式・4-6秒）
  /syncdeep  - 徹底同期修正（3層隔離方式・8-12秒）
  /mlofix    - MLO専用修正（隠しコマンド・2-3秒）
  /escape    - 緊急脱出（レギオンスクエアへ移動）
  /syncstats - 使用統計表示（管理者用）
  /forcesync - 全体同期リセット（管理者専用）
  /synccheck - 同期診断
  /checkload - ストリーミング確認
]]
