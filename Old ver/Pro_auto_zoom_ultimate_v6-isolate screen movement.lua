-- ==============================================================================
-- PRO AUTOZOOM (ULTIMATE COMMUNITY EDITION) - v8 Dual-Monitor Fix
-- Developed by: Gipstamusic
-- Website: https://lnk.bio/gipstamusic
-- Compatibility: OBS 29.x & OBS 30+ Universal Layer (Windows)
-- ==============================================================================

local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    int GetCursorPos(POINT* lpPoint);
    typedef long LONG;
    typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;
    typedef struct { RECT rcMonitor; RECT rcWork; unsigned long dwFlags; wchar_t szDevice[32]; } MONITORINFOEXW;
    void* MonitorFromPoint(POINT pt, unsigned long dwFlags);
    int GetMonitorInfoW(void* hMonitor, MONITORINFOEXW* lpmi);
]]

-- ------------------------------------------------------------------------------
-- Global State & Cache
-- ------------------------------------------------------------------------------
local cache = {
    source_name       = "",
    mon_w             = 1920,
    mon_h             = 1080,
    mon_x_offset      = 0,
    mon_y_offset      = 0,
    manual_hw_override= false,
    layout_style      = "full",

    -- Camera Engine
    zoom_enabled      = true,
    base_zoom         = 2.0,
    punch_zoom        = 4.0,
    tracking_speed    = 0.12,
    deadzone          = 15,
    auto_center       = false,
    auto_center_delay = 3.0,
    debug_mode        = false,

    -- Source dimension cache
    source_w          = 0,
    source_h          = 0,
    source_has_dims   = false,
    source_dim_source = "",

    -- Indicator
    ind_mode    = "Always On",
    ind_color   = 16776960,
    ind_opacity = 70,
    ind_size    = 72
}

-- Runtime state
local cur_crop    = { left = 0, top = 0, right = 0, bottom = 0 }
local target_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local last_cam    = { x = 960, y = 540 }
local cur_zoom    = 1.0

local last_mouse_time = os.clock()
local last_debug_time = os.clock() -- Used to throttle tick logs

-- Hotkey handles & states
local hk_zoom_id, hk_ind_id, hk_punch_id, hk_pause_id
local zoom_active        = false
local internal_ind_active = true
local is_punch_active    = false
local is_pause_active    = false
local last_source_name   = ""

-- ------------------------------------------------------------------------------
-- Debug helper
-- ------------------------------------------------------------------------------
local function debug_log(msg, throttle)
    if cache.debug_mode then
        if throttle then
            local now = os.clock()
            if now - last_debug_time > 1.0 then 
                obs.script_log(obs.LOG_INFO, "ProAutoZoom [TICK]: " .. tostring(msg))
                last_debug_time = now
            end
        else
            obs.script_log(obs.LOG_INFO, "ProAutoZoom: " .. tostring(msg))
        end
    end
end

-- ------------------------------------------------------------------------------
-- GUI Callbacks
-- ------------------------------------------------------------------------------
local function toggle_hw_visibility(props, property, settings)
    local is_manual = obs.obs_data_get_bool(settings, "manual_hw_override")
    
    local p_w = obs.obs_properties_get(props, "mon_w")
    local p_h = obs.obs_properties_get(props, "mon_h")
    local p_x = obs.obs_properties_get(props, "mon_x_offset")
    local p_y = obs.obs_properties_get(props, "mon_y_offset")
    
    obs.obs_property_set_visible(p_w, is_manual)
    obs.obs_property_set_visible(p_h, is_manual)
    obs.obs_property_set_visible(p_x, is_manual)
    obs.obs_property_set_visible(p_y, is_manual)
    
    debug_log("UI: Manual Monitor Override toggled to: " .. tostring(is_manual))
    return true
end

-- ------------------------------------------------------------------------------
-- GUI
-- ------------------------------------------------------------------------------
function script_description()
    return "<h2>Pro AutoZoom (Ultimate Edition)</h2>" ..
           "<p>The definitive cinematic mouse-tracking engine for OBS content creators.</p>" ..
           "<p><b>Setup:</b> Select your monitor/window capture source from the dropdown. " ..
           "The script detects the capture size and uses it for auto-zooming.</p>" ..
           "<p>Assign and press the Toggle Camera hotkey to start/stop.</p>"
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Source selector
    local p_sources = obs.obs_properties_add_list(
        props, "source_name", "Target Capture Source:",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources then
        for _, src in ipairs(sources) do
            local id = obs.obs_source_get_id(src)
            if id and (string.find(id, "monitor_capture") or
                       string.find(id, "window_capture")  or
                       string.find(id, "game_capture")) then
                local name = obs.obs_source_get_name(src)
                obs.obs_property_list_add_string(p_sources, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    obs.obs_properties_add_button(props, "refresh_source_dims",
        "Refresh Source Dimensions",
        function(_, _, settings)
            cache.source_has_dims = false
            cache.source_w = 0
            cache.source_h = 0
            
            debug_log("User clicked 'Refresh Source Dimensions'. Initiating detection...")
            local ok = update_monitor_from_source(settings, true)
            
            if ok then
                obs.script_log(obs.LOG_INFO, 
                    "ProAutoZoom: Refresh SUCCESS. Detected Source: '" .. 
                    cache.source_name .. "' -> Dimensions: " .. 
                    cache.source_w .. "x" .. cache.source_h .. 
                    " | Offset: X=" .. cache.mon_x_offset .. ", Y=" .. cache.mon_y_offset)
            else
                obs.script_log(obs.LOG_WARNING,
                    "ProAutoZoom: Refresh failed — source not found or dimensions " ..
                    "could not be detected. Enable Manual Monitor Override to set manually.")
            end
            return true
        end)

    local hw_group = obs.obs_properties_create()
    local p_override = obs.obs_properties_add_bool(hw_group, "manual_hw_override", "Enable Manual Monitor Settings Override")
    
    local p_w = obs.obs_properties_add_int(hw_group, "mon_w",         "Monitor Width (px):",  100, 7680,   1)
    local p_h = obs.obs_properties_add_int(hw_group, "mon_h",         "Monitor Height (px):", 100, 4320,   1)
    local p_x = obs.obs_properties_add_int(hw_group, "mon_x_offset",  "Monitor X Offset:",  -10000, 10000, 1)
    local p_y = obs.obs_properties_add_int(hw_group, "mon_y_offset",  "Monitor Y Offset:",  -10000, 10000, 1)
    
    obs.obs_property_set_visible(p_w, cache.manual_hw_override)
    obs.obs_property_set_visible(p_h, cache.manual_hw_override)
    obs.obs_property_set_visible(p_x, cache.manual_hw_override)
    obs.obs_property_set_visible(p_y, cache.manual_hw_override)
    
    obs.obs_property_set_modified_callback(p_override, toggle_hw_visibility)
    obs.obs_properties_add_group(props, "grp_hw", "🖥️ Monitor / Display Settings", obs.OBS_GROUP_NORMAL, hw_group)

    -- Layout
    local p_layout = obs.obs_properties_add_list(
        props, "layout_style", "Smart Canvas Layout:",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_layout, "Full Screen Zoom",                  "full")
    obs.obs_property_list_add_string(p_layout, "Split: Webcam Top, Screen Bottom",  "webcam_top")
    obs.obs_property_list_add_string(p_layout, "Split: Screen Top, Webcam Bottom",  "webcam_bottom")
    obs.obs_property_list_add_string(p_layout, "Picture-in-Picture (Avoid Corners)","pip")
    obs.obs_property_list_add_string(p_layout, "Ultrawide Center Strip",            "ultrawide")

    -- Camera engine group
    local cam_group = obs.obs_properties_create()
    obs.obs_properties_add_bool(cam_group,         "zoom_enabled",      "Enable Camera Tracking")
    obs.obs_properties_add_float_slider(cam_group, "base_zoom",         "Base Zoom Factor:",           1.0, 5.0,  0.1)
    obs.obs_properties_add_float_slider(cam_group, "punch_zoom",        "Punch Zoom (Detail Mode):",   1.0, 10.0, 0.1)
    obs.obs_properties_add_float_slider(cam_group, "tracking_speed",    "Cinematic Smoothness:",       0.01, 0.50, 0.01)
    obs.obs_properties_add_int_slider(cam_group,   "deadzone",          "Lazy Deadzone Radius (%):",   0, 40, 1)
    obs.obs_properties_add_bool(cam_group,         "auto_center",       "Auto-Return to Center when Idle")
    obs.obs_properties_add_float_slider(cam_group, "auto_center_delay", "Idle Timeout (Seconds):",     1.0, 10.0, 0.5)
    obs.obs_properties_add_bool(cam_group,         "debug_mode",        "Debug Mode")
    obs.obs_properties_add_group(props, "grp_cam", "🎬 Cinematic Camera Engine", obs.OBS_GROUP_NORMAL, cam_group)

    -- Indicator group
    local ind_group  = obs.obs_properties_create()
    local p_ind_mode = obs.obs_properties_add_list(
        ind_group, "ind_mode", "Visibility:",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_ind_mode, "Off",             "Off")
    obs.obs_property_list_add_string(p_ind_mode, "Always On",       "Always On")
    obs.obs_property_list_add_string(p_ind_mode, "Hotkey Triggered","Hotkey Triggered")
    obs.obs_properties_add_color(ind_group,      "ind_color",   "Ring Color:")
    obs.obs_properties_add_int_slider(ind_group, "ind_opacity", "Ring Opacity (%):", 10, 100, 5)
    obs.obs_properties_add_int_slider(ind_group, "ind_size",    "Ring Size (px):",   20, 300, 5)
    obs.obs_properties_add_group(props, "grp_ind", "🎯 Visual Mouse Indicator", obs.OBS_GROUP_NORMAL, ind_group)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source_name",       "")
    obs.obs_data_set_default_bool  (settings, "manual_hw_override",false)
    obs.obs_data_set_default_int   (settings, "mon_w",             1920)
    obs.obs_data_set_default_int   (settings, "mon_h",             1080)
    obs.obs_data_set_default_string(settings, "layout_style",      "full")
    obs.obs_data_set_default_bool  (settings, "zoom_enabled",      true)
    obs.obs_data_set_default_double(settings, "base_zoom",         2.0)
    obs.obs_data_set_default_double(settings, "punch_zoom",        4.0)
    obs.obs_data_set_default_double(settings, "tracking_speed",    0.12)
    obs.obs_data_set_default_int   (settings, "deadzone",          15)
    obs.obs_data_set_default_bool  (settings, "auto_center",       false)
    obs.obs_data_set_default_double(settings, "auto_center_delay", 3.0)
    obs.obs_data_set_default_bool  (settings, "debug_mode",        false)
    obs.obs_data_set_default_string(settings, "ind_mode",          "Always On")
    obs.obs_data_set_default_int   (settings, "ind_color",         16776960)
    obs.obs_data_set_default_int   (settings, "ind_opacity",       70)
    obs.obs_data_set_default_int   (settings, "ind_size",          72)
end

-- ------------------------------------------------------------------------------
-- Camera helpers
-- ------------------------------------------------------------------------------
local function get_canvas_bounds()
    local ovi = obs.obs_video_info()
    if not ovi then return 0, 0, 0, 0 end
    obs.obs_get_video_info(ovi)
    local cw, ch = ovi.base_width or 0, ovi.base_height or 0

    if cache.layout_style == "webcam_top" then return cw, math.max(ch - 608, 0), 0, 608
    elseif cache.layout_style == "webcam_bottom" then return cw, math.max(ch - 608, 0), 0, 0
    elseif cache.layout_style == "ultrawide" then return cw, ch / 3, 0, ch / 3
    else return cw, ch, 0, 0 end
end

local function reset_camera_position()
    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    local mx = tonumber(m_pos.x) - cache.mon_x_offset
    local my = tonumber(m_pos.y) - cache.mon_y_offset
    mx = math.max(0, math.min(mx, cache.mon_w))
    my = math.max(0, math.min(my, cache.mon_h))
    last_cam.x = mx
    last_cam.y = my
    debug_log("reset_camera_position: Resetting to MX=" .. mx .. " MY=" .. my)
end

local function reset_crop_filter()
    if cache.source_name == "" then return end
    
    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then return end

    local src_w = cache.manual_hw_override and cache.mon_w or cache.source_w
    local src_h = cache.manual_hw_override and cache.mon_h or cache.source_h
    
    if src_w == 0 or src_h == 0 then
        src_w, src_h = 1920, 1080 
    end

    local bw, bh = get_canvas_bounds()
    bw = math.max(bw, 1)
    bh = math.max(bh, 1)
    local c_aspect = bw / bh
    local base_w = math.max(src_w, 1)
    local base_h = math.max(src_h, 1)
    
    local zw = base_w
    local zh = zw / c_aspect
    if zh > base_h then
        zh = base_h
        zw = zh * c_aspect
    end

    local left   = (base_w - zw) / 2
    local top    = (base_h - zh) / 2
    local right  = base_w - (left + zw)
    local bottom = base_h - (top + zh)

    local filter = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
    if filter then
        local f_settings = obs.obs_data_create()
        obs.obs_data_set_int(f_settings, "left", math.floor(left))
        obs.obs_data_set_int(f_settings, "top", math.floor(top))
        obs.obs_data_set_int(f_settings, "right", math.floor(right))
        obs.obs_data_set_int(f_settings, "bottom", math.floor(bottom))
        obs.obs_source_update(filter, f_settings)
        obs.obs_data_release(f_settings)
        obs.obs_source_release(filter)
        debug_log("reset_crop_filter: Viewport fully restored to center-cut.")
    end
    obs.obs_source_release(source)

    cur_crop    = { left = left, top = top, right = right, bottom = bottom }
    target_crop = { left = left, top = top, right = right, bottom = bottom }
    cur_zoom    = 1.0
    last_cam.x  = base_w / 2
    last_cam.y  = base_h / 2
end

-- ------------------------------------------------------------------------------
-- Settings update
-- ------------------------------------------------------------------------------
function script_update(settings)
    cache.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")
    debug_log("script_update: Processing UI changes...")

    cache.manual_hw_override = obs.obs_data_get_bool(settings, "manual_hw_override")
    
    if cache.manual_hw_override then
        cache.mon_w        = obs.obs_data_get_int(settings, "mon_w")
        cache.mon_h        = obs.obs_data_get_int(settings, "mon_h")
        cache.mon_x_offset = obs.obs_data_get_int(settings, "mon_x_offset")
        cache.mon_y_offset = obs.obs_data_get_int(settings, "mon_y_offset")
        debug_log("script_update: Manual Override ON -> W:"..cache.mon_w.." H:"..cache.mon_h.." X:"..cache.mon_x_offset.." Y:"..cache.mon_y_offset)
    else
        debug_log("script_update: Manual Override OFF -> Relying on auto-detection.")
    end

    local new_source = obs.obs_data_get_string(settings, "source_name")
    cache.layout_style = obs.obs_data_get_string(settings, "layout_style")
    cache.zoom_enabled = obs.obs_data_get_bool  (settings, "zoom_enabled")
    cache.base_zoom    = obs.obs_data_get_double(settings, "base_zoom")
    cache.punch_zoom   = obs.obs_data_get_double(settings, "punch_zoom")
    cache.tracking_speed    = obs.obs_data_get_double(settings, "tracking_speed")
    cache.deadzone          = obs.obs_data_get_int   (settings, "deadzone")
    cache.auto_center       = obs.obs_data_get_bool  (settings, "auto_center")
    cache.auto_center_delay = obs.obs_data_get_double(settings, "auto_center_delay")
    cache.ind_mode    = obs.obs_data_get_string(settings, "ind_mode")
    cache.ind_color   = obs.obs_data_get_int   (settings, "ind_color")
    cache.ind_opacity = obs.obs_data_get_int   (settings, "ind_opacity")
    cache.ind_size    = obs.obs_data_get_int   (settings, "ind_size")

    if new_source ~= last_source_name then
        debug_log("script_update: Source changed from '" .. last_source_name .. "' to '" .. new_source .. "'")
        last_source_name        = new_source
        cache.source_name       = new_source
        cache.source_has_dims   = false
        cache.source_w          = 0
        cache.source_h          = 0
        zoom_active             = false
        cur_zoom                = 1.0
        update_monitor_from_source(settings, false)
    else
        cache.source_name = new_source
    end

    if not cache.zoom_enabled then
        zoom_active = false
    end
end

-- ------------------------------------------------------------------------------
-- Hotkeys
-- ------------------------------------------------------------------------------
local function hk_zoom(pressed)
    if not pressed or not cache.zoom_enabled then return end
    zoom_active = not zoom_active
    
    if zoom_active then
        reset_camera_position()
        cur_zoom = cache.base_zoom
        last_mouse_time = os.clock()
        debug_log("HOTKEY: Tracking ACTIVATED")
    else
        debug_log("HOTKEY: Tracking DEACTIVATED, resetting crop.")
        reset_crop_filter()
    end
end

local function hk_ind  (pressed) if pressed then internal_ind_active = not internal_ind_active; debug_log("HOTKEY: Indicator toggled") end end
local function hk_punch(pressed) is_punch_active = pressed; debug_log("HOTKEY: Punch Zoom state: " .. tostring(pressed)) end
local function hk_pause(pressed) is_pause_active = pressed; debug_log("HOTKEY: Pause Camera state: " .. tostring(pressed)) end

function script_load(settings)
    hk_zoom_id  = obs.obs_hotkey_register_frontend("paz_zoom",  "Pro AutoZoom: Toggle Camera",              hk_zoom)
    hk_ind_id   = obs.obs_hotkey_register_frontend("paz_ind",   "Pro AutoZoom: Toggle Pointer",             hk_ind)
    hk_punch_id = obs.obs_hotkey_register_frontend("paz_punch", "Pro AutoZoom: Hold for Detail Zoom (Punch)", hk_punch)
    hk_pause_id = obs.obs_hotkey_register_frontend("paz_pause", "Pro AutoZoom: Hold to Freeze Camera",      hk_pause)

    local arr_z = obs.obs_data_get_array(settings, "arr_z")
    local arr_i = obs.obs_data_get_array(settings, "arr_i")
    local arr_p = obs.obs_data_get_array(settings, "arr_p")
    local arr_f = obs.obs_data_get_array(settings, "arr_f")
    obs.obs_hotkey_load(hk_zoom_id,  arr_z)
    obs.obs_hotkey_load(hk_ind_id,   arr_i)
    obs.obs_hotkey_load(hk_punch_id, arr_p)
    obs.obs_hotkey_load(hk_pause_id, arr_f)
    obs.obs_data_array_release(arr_z)
    obs.obs_data_array_release(arr_i)
    obs.obs_data_array_release(arr_p)
    obs.obs_data_array_release(arr_f)
end

function script_save(settings)
    local arr_z = obs.obs_hotkey_save(hk_zoom_id)
    local arr_i = obs.obs_hotkey_save(hk_ind_id)
    local arr_p = obs.obs_hotkey_save(hk_punch_id)
    local arr_f = obs.obs_hotkey_save(hk_pause_id)
    obs.obs_data_set_array(settings, "arr_z", arr_z)
    obs.obs_data_set_array(settings, "arr_i", arr_i)
    obs.obs_data_set_array(settings, "arr_p", arr_p)
    obs.obs_data_set_array(settings, "arr_f", arr_f)
    obs.obs_data_array_release(arr_z)
    obs.obs_data_array_release(arr_i)
    obs.obs_data_array_release(arr_p)
    obs.obs_data_array_release(arr_f)
end

-- ------------------------------------------------------------------------------
-- Source / filter helpers
-- ------------------------------------------------------------------------------
local function get_or_create_filter(source)
    local f = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
    if not f then
        debug_log("get_or_create_filter: Filter not found, creating new one.")
        local s = obs.obs_data_create()
        f = obs.obs_source_create_private("crop_filter", "CoreAutoZoom_Crop", s)
        obs.obs_data_release(s)
        if f then
            obs.obs_source_filter_add(source, f)
            obs.obs_source_release(f)
            f = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
        end
    end
    return f
end

local function get_source_dimensions(source, use_monitor_fallback)
    local width, height = 0, 0
    local x_off, y_off = 0, 0

    local ssettings = obs.obs_source_get_settings(source)
    if ssettings then
        local string_keys = {
            "monitor_id", "monitor", "display", "display_id",
            "device_id",  "screen",  "monitor_name",
        }
        local display_str = ""
        for _, key in ipairs(string_keys) do
            local val = obs.obs_data_get_string(ssettings, key)
            if val and val ~= "" then
                display_str = val
                debug_log("get_source_dimensions: Found display string -> " .. display_str)
                break
            end
        end

        if display_str ~= "" then
            local size_patterns = {
                "(%d%d%d+)x(%d%d%d+)%s*@",
                "(%d%d%d+)x(%d%d%d+)%+",
                "(%d%d%d+)%s*[xX]%s*(%d%d%d+)",
                "(%d%d%d+)[xX](%d%d%d+)",
            }
            for _, pat in ipairs(size_patterns) do
                local pw, ph = string.match(display_str, pat)
                if pw and ph then
                    pw = tonumber(pw)
                    ph = tonumber(ph)
                    if pw and ph and pw >= 640 and pw <= 16384 then
                        width  = pw
                        height = ph
                        debug_log("get_source_dimensions: Parsed native resolution via regex -> " .. width .. "x" .. height)
                        break
                    end
                end
            end

            local ox, oy = string.match(display_str, "@%s*(%-?%d+),(%-?%d+)")
            if not ox then ox, oy = string.match(display_str, "%d+[xX]%d+%+?(%-?%d+)%+?(%-?%d+)") end
            if ox and oy then
                x_off = tonumber(ox) or 0
                y_off = tonumber(oy) or 0
                debug_log("get_source_dimensions: Parsed native offset via regex -> X=" .. x_off .. " Y=" .. y_off)
            end
        end

        if width == 0 or height == 0 then
            debug_log("get_source_dimensions: Regex failed, checking standard OBS properties.")
            local candidates = {
                { "capture_width",  "capture_height"  },
                { "width",          "height"          },
                { "monitor_width",  "monitor_height"  },
                { "base_width",     "base_height"     },
            }
            for _, keys in ipairs(candidates) do
                local w = obs.obs_data_get_int(ssettings, keys[1])
                local h = obs.obs_data_get_int(ssettings, keys[2])
                if w > 0 then width  = w end
                if h > 0 then height = h end
                if width > 0 and height > 0 then break end
            end
            
            if width == 0 and obs.obs_source_get_width then 
                width = obs.obs_source_get_width(source)
                height = obs.obs_source_get_height(source)
                debug_log("get_source_dimensions: Used dynamic obs_source_get_width -> " .. width .. "x" .. height)
            end
        end

        obs.obs_data_release(ssettings)
    end

    if width > 0 and height > 0 then
        return width, height, x_off, y_off
    end

    if use_monitor_fallback and ffi.C.MonitorFromPoint then
        debug_log("get_source_dimensions: Trying ffi MonitorFromPoint fallback...")
        local p = ffi.new("POINT")
        ffi.C.GetCursorPos(p)
        local hmon = ffi.C.MonitorFromPoint(p, 2)
        if hmon ~= nil then
            local mi = ffi.new("MONITORINFOEXW")
            mi.rcMonitor.left   = 0; mi.rcMonitor.top    = 0
            mi.rcMonitor.right  = 0; mi.rcMonitor.bottom = 0
            if ffi.C.GetMonitorInfoW(hmon, mi) ~= 0 then
                local mw = tonumber(mi.rcMonitor.right  - mi.rcMonitor.left)
                local mh = tonumber(mi.rcMonitor.bottom - mi.rcMonitor.top)
                if mw > 0 and mh > 0 then
                    width  = mw; height = mh
                    x_off  = tonumber(mi.rcMonitor.left) or 0
                    y_off  = tonumber(mi.rcMonitor.top) or 0
                end
            end
        end
    end

    return width, height, x_off, y_off
end

function update_monitor_from_source(settings, write_to_ui)
    if cache.source_name == "" then return false end

    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then return false end

    local w, h, x_off, y_off = get_source_dimensions(source, true)
    obs.obs_source_release(source)

    if w > 0 and h > 0 then
        cache.source_w          = w
        cache.source_h          = h
        cache.source_has_dims   = true
        cache.source_dim_source = cache.source_name

        debug_log("update_monitor_from_source: Detected " .. w .. "x" .. h .. " Offset " .. x_off .. "," .. y_off)

        if write_to_ui and settings then
            if cache.manual_hw_override then
                debug_log("update_monitor_from_source: Manual override active. Ignoring auto-detected values for UI.")
            else
                obs.obs_data_set_int(settings, "mon_w",        w)
                obs.obs_data_set_int(settings, "mon_h",        h)
                obs.obs_data_set_int(settings, "mon_x_offset", x_off)
                obs.obs_data_set_int(settings, "mon_y_offset", y_off)
                cache.mon_w        = w
                cache.mon_h        = h
                cache.mon_x_offset = x_off
                cache.mon_y_offset = y_off
                debug_log("update_monitor_from_source: Updated UI properties with detected values.")
            end
        end
        return true
    end

    debug_log("update_monitor_from_source: FAILED to detect resolution.")
    return false
end

-- ------------------------------------------------------------------------------
-- Crop mathematics
-- ------------------------------------------------------------------------------
local function calculate_crop(mx, my, bw, bh, src_w, src_h, is_on_screen)
    bw = math.max(bw, 1); bh = math.max(bh, 1)
    local c_aspect = bw / bh

    local base_w = cache.manual_hw_override and cache.mon_w or ((src_w and src_w > 0) and src_w or cache.mon_w)
    local base_h = cache.manual_hw_override and cache.mon_h or ((src_h and src_h > 0) and src_h or cache.mon_h)
    base_w = math.max(base_w, 1); base_h = math.max(base_h, 1)

    local target_z = is_punch_active and cache.punch_zoom or cache.base_zoom
    cur_zoom = cur_zoom + (target_z - cur_zoom) * (cache.tracking_speed * 1.5)

    local zw = base_w / cur_zoom
    local zh = zw / c_aspect
    if zh > base_h then
        zh = base_h
        zw = zh * c_aspect
    end

    if not is_pause_active then
        -- Only move the camera bounds if the mouse is actively on the target screen
        if is_on_screen then
            local dx = mx - last_cam.x
            local dy = my - last_cam.y
            local adx = math.abs(dx)
            local ady = math.abs(dy)
            local thresh_x = zw * (cache.deadzone / 100)
            local thresh_y = zh * (cache.deadzone / 100)

            if adx > thresh_x then last_cam.x = last_cam.x + (dx - (dx > 0 and thresh_x or -thresh_x)) end
            if ady > thresh_y then last_cam.y = last_cam.y + (dy - (dy > 0 and thresh_y or -thresh_y)) end

            -- Only reset the idle timer if the mouse is making significant movements ON the target screen
            if adx > 2 or ady > 2 then
                last_mouse_time = os.clock()
            end
        end

        -- If Auto-Center is enabled, this will pull the camera back to center if time expires
        -- (This naturally triggers when moving to a second monitor because last_mouse_time stops updating)
        if cache.auto_center and (os.clock() - last_mouse_time > cache.auto_center_delay) then
            local speed = cache.tracking_speed * 0.2
            last_cam.x = last_cam.x + ((base_w / 2) - last_cam.x) * speed
            last_cam.y = last_cam.y + ((base_h / 2) - last_cam.y) * speed
        end
    end

    last_cam.x = math.max(zw / 2, math.min(last_cam.x, base_w - zw / 2))
    last_cam.y = math.max(zh / 2, math.min(last_cam.y, base_h - zh / 2))

    local left = last_cam.x - (zw / 2)
    local top  = last_cam.y - (zh / 2)

    return left, top, base_w - (left + zw), base_h - (top + zh)
end

-- ------------------------------------------------------------------------------
-- Main tick
-- ------------------------------------------------------------------------------
function script_tick(seconds)
    if cache.source_name == "" or not zoom_active then return end

    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    
    local active_mon_w = cache.manual_hw_override and cache.mon_w or cache.source_w
    local active_mon_h = cache.manual_hw_override and cache.mon_h or cache.source_h
    local active_off_x = cache.mon_x_offset
    local active_off_y = cache.mon_y_offset
    
    if active_mon_w == 0 then active_mon_w = 1920 end
    if active_mon_h == 0 then active_mon_h = 1080 end

    local raw_x = tonumber(m_pos.x)
    local raw_y = tonumber(m_pos.y)
    
    -- Check if the cursor is actually inside the boundaries of the target monitor
    local is_on_screen = (raw_x >= active_off_x and raw_x <= active_off_x + active_mon_w) and
                         (raw_y >= active_off_y and raw_y <= active_off_y + active_mon_h)

    local mx = raw_x - active_off_x
    local my = raw_y - active_off_y

    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then return end

    local src_w, src_h = active_mon_w, active_mon_h
    
    if not cache.manual_hw_override and not cache.source_has_dims then
        src_w, src_h = get_source_dimensions(source, false)
        if src_w > 0 and src_h > 0 then
            cache.source_w          = src_w
            cache.source_h          = src_h
            cache.source_has_dims   = true
            debug_log("script_tick: First-time auto detection grabbed " .. src_w .. "x" .. src_h)
        else
            src_w, src_h = cache.mon_w, cache.mon_h
        end
    end

    local bw, bh, bx, by = get_canvas_bounds()
    if bw <= 0 or bh <= 0 then
        obs.obs_source_release(source)
        return
    end

    -- Pass the on_screen flag to the math calculator
    target_crop.left, target_crop.top, target_crop.right, target_crop.bottom =
        calculate_crop(mx, my, bw, bh, src_w, src_h, is_on_screen)

    local spd = cache.tracking_speed * (is_punch_active and 1.5 or 1.0)
    cur_crop.left   = cur_crop.left   + (target_crop.left   - cur_crop.left)   * spd
    cur_crop.top    = cur_crop.top    + (target_crop.top    - cur_crop.top)    * spd
    cur_crop.right  = cur_crop.right  + (target_crop.right  - cur_crop.right)  * spd
    cur_crop.bottom = cur_crop.bottom + (target_crop.bottom - cur_crop.bottom) * spd

    debug_log(string.format("CROP -> L:%.1f T:%.1f R:%.1f B:%.1f | MOUSE: X:%d Y:%d (OnScreen: %s)", 
              cur_crop.left, cur_crop.top, cur_crop.right, cur_crop.bottom, mx, my, tostring(is_on_screen)), true)

    local filter = get_or_create_filter(source)
    if filter then
        local f_settings = obs.obs_source_get_settings(filter)
        if f_settings then
            obs.obs_data_set_int(f_settings, "left",   math.floor(cur_crop.left))
            obs.obs_data_set_int(f_settings, "top",    math.floor(cur_crop.top))
            obs.obs_data_set_int(f_settings, "right",  math.floor(cur_crop.right))
            obs.obs_data_set_int(f_settings, "bottom", math.floor(cur_crop.bottom))
            obs.obs_source_update(filter, f_settings)
            obs.obs_data_release(f_settings)
        end
        obs.obs_source_release(filter)
    end
    obs.obs_source_release(source)

    -- Mouse indicator overlay
    if cache.ind_mode == "Off" then return end

    -- Hide the indicator if the mouse is on another screen
    local show = is_on_screen and ( (cache.ind_mode == "Always On") or (cache.ind_mode == "Hotkey Triggered" and internal_ind_active) )

    local current_scene_source = obs.obs_frontend_get_current_scene()
    if not current_scene_source then return end

    local scene = obs.obs_scene_from_source(current_scene_source)
    if not scene then
        obs.obs_source_release(current_scene_source)
        return
    end

    local p_source = obs.obs_get_source_by_name("ProAutoZoom_CirclePointer")

    if show then
        local alpha_val  = math.floor((cache.ind_opacity / 100) * 255)
        local base_color = cache.ind_color % 16777216 
        local final_color = base_color + (alpha_val * 16777216)

        if not p_source then
            local s_settings = obs.obs_data_create()
            local font_obj   = obs.obs_data_create()
            obs.obs_data_set_string(s_settings, "text",  "●")
            obs.obs_data_set_int   (s_settings, "color", final_color)
            obs.obs_data_set_string(font_obj,   "face",  "Arial")
            obs.obs_data_set_int   (font_obj,   "size",  cache.ind_size)
            obs.obs_data_set_obj   (s_settings, "font",  font_obj)
            obs.obs_data_release(font_obj)

            p_source = obs.obs_source_create("text_gdiplus", "ProAutoZoom_CirclePointer", s_settings, nil)
            obs.obs_data_release(s_settings)

            if p_source then
                obs.obs_scene_add(scene, p_source)
            end
        else
            local s_settings = obs.obs_data_create()
            local font_obj   = obs.obs_data_create()
            obs.obs_data_set_int   (s_settings, "color", final_color)
            obs.obs_data_set_string(font_obj,   "face",  "Arial")
            obs.obs_data_set_int   (font_obj,   "size",  cache.ind_size)
            obs.obs_data_set_obj   (s_settings, "font",  font_obj)
            obs.obs_data_release(font_obj)
            obs.obs_source_update(p_source, s_settings)
            obs.obs_data_release(s_settings)
        end

        local target_item  = obs.obs_scene_find_source(scene, cache.source_name)
        local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")

        if target_item and pointer_item then
            local t_info = obs.obs_transform_info()
            if t_info then
                if obs.obs_sceneitem_get_info2 then
                    obs.obs_sceneitem_get_info2(target_item, t_info)
                else
                    obs.obs_sceneitem_get_info(target_item, t_info)
                end

                if t_info.bounds and t_info.pos and
                   t_info.bounds.x > 0 and t_info.bounds.y > 0 then

                    local vis_w = src_w - cur_crop.left - cur_crop.right
                    local vis_h = src_h - cur_crop.top  - cur_crop.bottom

                    if vis_w > 0 and vis_h > 0 then
                        local scale_x  = t_info.bounds.x / vis_w
                        local scale_y  = t_info.bounds.y / vis_h
                        local ind_x    = t_info.pos.x + ((mx - cur_crop.left) * scale_x) - (cache.ind_size / 2)
                        local ind_y    = t_info.pos.y + ((my - cur_crop.top)  * scale_y) - (cache.ind_size / 1.35)

                        if obs.vec2 and obs.vec2_set then
                            local pos = obs.vec2()
                            obs.vec2_set(pos, ind_x, ind_y)
                            obs.obs_sceneitem_set_pos(pointer_item, pos)
                            obs.obs_sceneitem_set_visible(pointer_item, true)
                        end
                    end
                end
            end
        end
    else
        local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")
        if pointer_item then
            obs.obs_sceneitem_set_visible(pointer_item, false)
        end
    end

    if p_source then obs.obs_source_release(p_source) end
    obs.obs_source_release(current_scene_source)
end