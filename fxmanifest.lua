fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbx_syncfix_complete'
author 'QBX SyncFix Team'
description 'Complete desync fix with Virtual Room for QBX Framework'
version '2.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'  -- これだけに統合
}

dependencies {
    'qbx_core',
    'ox_lib'
}

--[[Command
/quickreload - ブラックアウト修正（軽量・4-6秒）
/hardfix - Virtual Room修正（強力・8-12秒）
/mlofix - MLO専用修正（2-3秒）
/escape - 緊急脱出（レギオンスクエア）
/syncstats - 使用統計表示（管理者用）
/forcesync - 全体同期リセット（管理者専用）
/synccheck - 同期診断
/checkload - ストリーミング確認
]]
