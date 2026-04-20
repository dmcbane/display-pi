-- mpv-health-overlay.lua
--
-- Renders two independent overlays on top of whatever mpv is playing:
--
--   * Bottom-left: hostname + IP address (gray, always visible).
--     Lets anyone glance at the HDMI output and know how to SSH to the Pi.
--
--   * Bottom-right: health status (yellow WARN / red FAIL / gray STALE).
--     Hidden when status is OK to avoid visual clutter.
--
-- Both overlays are driven by /tmp/kiosk-health.json, written every ~20s
-- by diagnostics/health-monitor.sh. If the file is missing or >60s old,
-- the health corner shows "HEALTH MONITOR STALE" so operators can
-- distinguish "unknown" from "healthy".
--
-- Uses create_osd_overlay() rather than set_osd_ass() so the two corners
-- can be updated independently.

local mp    = require 'mp'
local utils = require 'mp.utils'

local HEALTH_FILE     = '/tmp/kiosk-health.json'
local POLL_SEC        = 5
local STALE_THRESHOLD = 60  -- seconds

-- ASS colors are in BGR hex, not RGB.
local COLOR_WARN  = '&H0000FFFF&'  -- yellow
local COLOR_FAIL  = '&H000000FF&'  -- red
local COLOR_STALE = '&H00AAAAAA&'  -- gray
local COLOR_INFO  = '&H00AAAAAA&'  -- gray (bottom-left corner)

-- Two independent overlays. Each has its own OSD surface and z-order,
-- so updating one does not clobber the other.
local info_overlay   = mp.create_osd_overlay('ass-events')
local health_overlay = mp.create_osd_overlay('ass-events')
info_overlay.res_x   = 1920
info_overlay.res_y   = 1080
health_overlay.res_x = 1920
health_overlay.res_y = 1080

local function ass_escape(s)
    if not s then return '' end
    s = s:gsub('\\', '\\\\')
    s = s:gsub('{', '\\{')
    s = s:gsub('}', '\\}')
    return s
end

local function parse_health(content)
    if not content then return nil end
    local status   = content:match('"status"%s*:%s*"([^"]*)"')
    local message  = content:match('"message"%s*:%s*"([^"]*)"')
    local ip       = content:match('"ip"%s*:%s*"([^"]*)"')
    local hostname = content:match('"hostname"%s*:%s*"([^"]*)"')
    return status, message, ip, hostname
end

local function file_mtime(path)
    local st = utils.file_info(path)
    if not st then return nil end
    return st.mtime
end

local function read_all(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local content = f:read('*all')
    f:close()
    return content
end

-- Render the info corner (bottom-left). Gray, slightly more transparent
-- than the health corner so it reads as "reference info" not "alert."
--   \an1        = alignment bottom-left
--   \pos(20,..) = 20px padding from corner
--   \fs22       = smaller font than health alerts (reference info)
--   \alpha&H80& = ~50% opaque
local function render_info(ip, hostname)
    if not ip or ip == '' then
        info_overlay.data = ''
    else
        local label = ip
        if hostname and hostname ~= '' then
            label = hostname .. ' ' .. ip
        end
        info_overlay.data = string.format(
            '{\\an1\\pos(20,1060)\\fs22\\bord2\\3c&H000000&\\alpha&H80&\\c%s}%s',
            COLOR_INFO, ass_escape(label))
    end
    info_overlay:update()
end

-- Render the health corner (bottom-right). Only visible on WARN/FAIL/STALE.
--   \an3        = alignment bottom-right
--   \fs26       = larger than info corner (alerts should read at a glance)
--   \alpha&H60& = ~62% opaque
local function render_health(color, text)
    if not color then
        health_overlay.data = ''
    else
        health_overlay.data = string.format(
            '{\\an3\\pos(1900,1060)\\fs26\\bord2\\3c&H000000&\\alpha&H60&\\c%s}%s',
            color, ass_escape(text))
    end
    health_overlay:update()
end

local function tick()
    local mtime = file_mtime(HEALTH_FILE)

    -- No health file yet: clear both overlays.
    if not mtime then
        render_info(nil, nil)
        render_health(COLOR_STALE, 'HEALTH: no data')
        return
    end

    local content = read_all(HEALTH_FILE)
    local status, message, ip, hostname = parse_health(content)

    -- Always update the info corner first, using whatever we could parse.
    render_info(ip, hostname)

    -- Stale data beats parsed data — operators need to know the monitor died.
    local age = os.time() - mtime
    if age > STALE_THRESHOLD then
        render_health(COLOR_STALE,
            string.format('HEALTH MONITOR STALE (%ds)', age))
        return
    end

    if not status then
        render_health(COLOR_STALE, 'HEALTH: unparseable')
        return
    end

    if status == 'OK' then
        render_health(nil, nil)  -- hidden
        return
    end

    local color = (status == 'FAIL') and COLOR_FAIL or COLOR_WARN
    render_health(color, string.format('%s: %s', status, message or ''))
end

mp.add_periodic_timer(POLL_SEC, tick)
tick()  -- immediate first render
