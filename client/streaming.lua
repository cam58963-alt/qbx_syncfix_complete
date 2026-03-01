-- ========================================================
-- client/streaming.lua - MLO/Interior/ストリーミング ヘルパー
-- ========================================================

-- ========================================================
-- Interior 保護（RefreshInterior ロック機構 - 座標ベース）
-- ========================================================
-- 強盗等のスクリプトが interior 状態を管理している最中に
-- RefreshInterior が走ると、爆破した壁などが初期状態に戻る。
-- ロック中は RefreshInterior / DisableInterior をスキップする。
--
-- ★ interior ID はサーバー再起動やMLO更新で変わるため、
--    座標+半径で保護エリアを判定する。
--
-- 使い方（外部スクリプトから）:
--   exports.qbx_syncfix_complete:LockInteriorAtCoords(coords, radius)  -- 座標で保護
--   exports.qbx_syncfix_complete:UnlockInteriorAtCoords(coords)        -- 座標で解除
--   exports.qbx_syncfix_complete:LockAllInteriors()                     -- 全保護
--   exports.qbx_syncfix_complete:UnlockAllInteriors()                   -- 全解除
--   exports.qbx_syncfix_complete:IsInteriorLocked()                    -- 確認
-- ========================================================

local lockedZones = {}    -- { { coords = vec3, radius = number }, ... }
local globalLock  = false

-- 座標ベースでロック（円柱型: radius=水平, height=上下）
function LockInteriorAtCoords(coords, radius, height)
    if not coords then return end
    radius = radius or 30.0
    height = height or 10.0
    -- 重複チェック
    for _, zone in ipairs(lockedZones) do
        if #(vec3(zone.coords.x, zone.coords.y, 0.0) - vec3(coords.x, coords.y, 0.0)) < 1.0
            and math.abs(zone.coords.z - coords.z) < 1.0 then
            zone.radius = radius
            zone.height = height
            return
        end
    end
    lockedZones[#lockedZones + 1] = { coords = coords, radius = radius, height = height }
    print(string.format('^3[SyncFix] ^7Interior locked at (%.1f, %.1f, %.1f) r=%.1f h=%.1f',
        coords.x, coords.y, coords.z, radius, height))
end

-- 座標ベースで解除
function UnlockInteriorAtCoords(coords)
    if not coords then return end
    for i = #lockedZones, 1, -1 do
        if #(lockedZones[i].coords - coords) < 1.0 then
            print(string.format('^2[SyncFix] ^7Interior unlocked at (%.1f, %.1f, %.1f)',
                coords.x, coords.y, coords.z))
            table.remove(lockedZones, i)
            return
        end
    end
end

function LockAllInteriors()
    globalLock = true
    print('^3[SyncFix] ^7All interiors locked (RefreshInterior globally disabled)')
end

function UnlockAllInteriors()
    globalLock = false
    lockedZones = {}
    print('^2[SyncFix] ^7All interior locks released')
end

-- 円柱型判定ヘルパー
-- radius: 中心からの水平距離(XY平面)
-- height: 中心Zからの上下許容幅（中心±height の範囲）
local function isInsideCylinder(center, checkCoords, radius, height)
    -- 水平距離（XYのみ）
    local dx = checkCoords.x - center.x
    local dy = checkCoords.y - center.y
    local horizontalDist = math.sqrt(dx * dx + dy * dy)
    if horizontalDist > radius then return false end

    -- 高さチェック（中心Z ± height）
    local dz = math.abs(checkCoords.z - center.z)
    if dz > height then return false end

    return true
end

-- 座標がロックゾーン内かチェック（円柱型）
local function isCoordsInLockedZone(checkCoords)
    if not checkCoords then return false end
    -- 動的ロック
    for _, zone in ipairs(lockedZones) do
        if isInsideCylinder(zone.coords, checkCoords, zone.radius, zone.height or 10.0) then
            return true
        end
    end
    -- Config の静的保護
    if Config.ProtectedInteriors then
        for _, zone in ipairs(Config.ProtectedInteriors) do
            if zone.coords and isInsideCylinder(zone.coords, checkCoords, zone.radius or 30.0, zone.height or 10.0) then
                return true
            end
        end
    end
    return false
end

-- プレイヤー現在座標がロックゾーン内かチェック（引数不要）
function IsInteriorLocked()
    if globalLock then return true end
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    return isCoordsInLockedZone(coords)
end

-- 座標を直接渡してロック判定（interior ID 不要版）
function IsAreaLocked(coords)
    if globalLock then return true end
    return isCoordsInLockedZone(coords)
end

exports('LockInteriorAtCoords', LockInteriorAtCoords)
exports('UnlockInteriorAtCoords', UnlockInteriorAtCoords)
exports('LockAllInteriors', LockAllInteriors)
exports('UnlockAllInteriors', UnlockAllInteriors)
exports('IsInteriorLocked', IsInteriorLocked)
exports('IsAreaLocked', IsAreaLocked)

-- ========================================================
-- NewLoadScene ロード待ち
-- ========================================================
function WaitNewLoadSceneLoaded(timeoutMs)
    timeoutMs = timeoutMs or 7000
    local start = GetGameTimer()
    while not IsNewLoadSceneLoaded() and (GetGameTimer() - start) < timeoutMs do
        Wait(0)
    end
end

-- ========================================================
-- Interior Ready 安全チェック
-- ========================================================
local IsInteriorReadyNative = IsInteriorReady

function IsInteriorReadySafe(interior)
    if not interior or interior == 0 then return true end
    if type(IsInteriorReadyNative) ~= 'function' then return false end
    return IsInteriorReadyNative(interior)
end

function WaitInteriorReady(interior, timeoutMs)
    timeoutMs = timeoutMs or 6000
    if not interior or interior == 0 then return true end
    local start = GetGameTimer()
    while not IsInteriorReady(interior) and (GetGameTimer() - start) < timeoutMs do
        Wait(50)
    end
    return IsInteriorReady(interior)
end

-- ========================================================
-- Interior 取得ヘルパー
-- ========================================================
function GetInteriorSafe(ped, coords)
    local interior = GetInteriorFromEntity(ped)
    if interior == 0 then
        interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    end
    return interior
end

function RefreshAndWaitInterior(interior)
    if interior and interior ~= 0 then
        if IsInteriorLocked() then
            print(string.format('^3[SyncFix] ^7RefreshAndWaitInterior skipped: interior %d is locked', interior))
            return true  -- ロック中はスキップ（readyとして返す）
        end
        PinInteriorInMemory(interior)
        RefreshInterior(interior)
        SetInteriorActive(interior, true)
        return WaitInteriorReady(interior, 7000)
    end
    return true
end

-- ========================================================
-- ストリーミング強制ロード
-- ========================================================
function ForceStreamAt(coords, radius, timeoutMs)
    radius    = radius or 90.0
    timeoutMs = timeoutMs or 6000

    ClearFocus()
    ClearHdArea()
    SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)
    NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, radius, 0)

    local start = GetGameTimer()
    while not IsNewLoadSceneLoaded() and (GetGameTimer() - start) < timeoutMs do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)
        Wait(0)
    end
    if IsNewLoadSceneActive() then NewLoadSceneStop() end
end

function RefreshInteriorAt(coords, timeoutMs, skipRefresh)
    timeoutMs = timeoutMs or 5000
    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    if interior == 0 then return 0 end

    if IsAreaLocked(coords) then
        print(string.format('^3[SyncFix] ^7RefreshInteriorAt skipped: area (%.1f, %.1f, %.1f) is locked',
            coords.x, coords.y, coords.z))
        return interior
    end

    PinInteriorInMemory(interior)
    if not skipRefresh then
        RefreshInterior(interior)
    else
        print(string.format('^2[SyncFix] ^7RefreshInteriorAt: RefreshInterior skipped (same interior) id=%d', interior))
    end
    SetInteriorActive(interior, true)

    local start = GetGameTimer()
    while not IsInteriorReady(interior) and (GetGameTimer() - start) < timeoutMs do
        Wait(50)
    end
    return interior
end

-- ========================================================
-- MLO 完全ロード（3段階: 広域→refresh→仕上げ）
-- ========================================================
-- skipRefresh: true の場合、RefreshInterior を省略する
--   同一インテリア内テレポート（1F→2F等）で他クライアントの
--   インテリア描画に影響を与えないために使用
function EnsureMloLoadedAtCoords(coords, skipRefresh)
    ForceStreamAt(coords, 140.0, 8000)
    RefreshInteriorAt(coords, 6000, skipRefresh)
    ForceStreamAt(coords, 70.0, 4000)
end

-- 高速版（座り瞬間など短時間用）
function EnsureMloLoadedAtCoordsFast(coords, skipRefresh)
    ForceStreamAt(coords, 110.0, 1200)
    RefreshInteriorAt(coords, 1200, skipRefresh)
end

-- 外部リソース用 export
exports('EnsureMloLoadedAtCoords', EnsureMloLoadedAtCoords)
