-- mpv-health-overlay.lua
--
-- Persistent health indicator rendered as OSD text in the bottom-right
-- corner of the HDMI output. Polls /tmp/kiosk-health.json (written by
-- diagnostics/health-monitor.sh) every POLL_SEC seconds.
--
-- When status is OK, the overlay is hidden (no visual clutter). When
-- status is WARN or FAIL, the reason is shown in yellow or red with
-- 75% opacity so it never obscures the stream completely.
--
-- If the health file is missing or older than STALE_THRESHOLD seconds,
-- a "HEALTH MONITOR STALE" message is shown so operators can distinguish
-- "kiosk is healthy" from "monitor died and state is unknown."

local mp   = require 'mp'
local utils = require 'mp.utils'

local HEALTH_FILE      = '/tmp/kiosk-health.json'
local POLL_SEC         = 5
local STALE_THRESHOLD  = 60  -- seconds

-- ASS color constants (BGR hex, not RGB). bord/shad give the text a
-- dark outline so it stays legible over any video content.
local COLOR_WARN = '&H0000FFFF&'  -- yellow
local COLOR_FAIL = '&H000000FF&'  -- red
local COLOR_STALE = '&H00AAAAAA&' -- gray

-- Escape a string for ASS. Backslashes and braces are special.
local function ass_escape(s)
    if not s then return '' end
    s = s:gsub('\\', '\\\\')
    s = s:gsub('{', '\\{')
    s = s:gsub('}', '\\}')
    return s
end

-- Minimal JSON-ish parser: extracts top-level "status" and "message"
-- string values. The health monitor writes a simple flat object so we
-- don't need a full JSON parser here.
local function parse_health(content)
    if not content then return nil end
    local status  = content:match('"status"%s*:%s*"([^"]*)"')
    local message = content:match('"message"%s*:%s*"([^"]*)"')
    return status, message
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

local function clear_overlay()
    mp.set_osd_ass(0, 0, '')
end

local function render_overlay(color, text)
    -- ASS tags:
    --   \an3        = alignment bottom-right
    --   \pos(x,y)   = 20px padding from the corner
    --   \fs26       = font size
    --   \bord2      = 2px outline
    --   \3c&H...&   = outline color (black)
    --   \alpha&H60& = ~62% opaque (0x00 = opaque, 0xFF = transparent)
    --   \c<color>   = fill color
    local escaped = ass_escape(text)
    local ass = string.format(
        '{\\an3\\pos(1900,1060)\\fs26\\bord2\\3c&H000000&\\alpha&H60&\\c%s}%s',
        color, escaped)
    mp.set_osd_ass(1920, 1080, ass)
end

local function tick()
    local mtime = file_mtime(HEALTH_FILE)
    if not mtime then
        render_overlay(COLOR_STALE, 'HEALTH: no data')
        return
    end

    local age = os.time() - mtime
    if age > STALE_THRESHOLD then
        render_overlay(COLOR_STALE,
            string.format('HEALTH MONITOR STALE (%ds)', age))
        return
    end

    local content = read_all(HEALTH_FILE)
    local status, message = parse_health(content)

    if not status then
        render_overlay(COLOR_STALE, 'HEALTH: unparseable')
        return
    end

    if status == 'OK' then
        clear_overlay()
        return
    end

    local color = (status == 'FAIL') and COLOR_FAIL or COLOR_WARN
    local text  = string.format('%s: %s', status, message or '')
    render_overlay(color, text)
end

mp.add_periodic_timer(POLL_SEC, tick)
tick()  -- immediate first render
