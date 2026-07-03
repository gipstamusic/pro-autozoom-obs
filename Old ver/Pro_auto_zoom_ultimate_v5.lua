-- ==============================================================================
-- PRO AUTOZOOM (ULTIMATE COMMUNITY EDITION)
-- Developed by: Gipstamusic
-- Website: https://lnk.bio/gipstamusic
-- Compatibility: OBS 29.x & OBS 30+ Universal Layer (Windows)
-- ==============================================================================

local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    int GetCursorPos(POINT* lpPoint);
]]

-- ------------------------------------------------------------------------------
-- Global State & Cache Architecture
-- ------------------------------------------------------------------------------
local cache = {
    source_name = "",
    mon_w = 1920,
    mon_h = 1080,
    mon_x_offset = 0,
    mon_y_offset = 0,
    layout_style = "full",
    
    -- Camera Engine
    zoom_enabled = true,
    base_zoom = 2.0,
    punch_zoom = 4.0,
    tracking_speed = 0.12,
    deadzone = 15,
    auto_center = false,
    auto_center_delay = 3.0,
    
    -- Indicator
    ind_mode = "Always On",
    ind_color = 16776960,
    ind_opacity = 70,
    ind_size = 72
}

-- Runtime Variables
local cur_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local target_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local last_cam = { x = 960, y = 540 }
local cur_zoom = 1.0

local last_mouse_time = os.clock()
local last_mx, last_my = 0, 0

-- Hotkey States
local hk_zoom_id, hk_ind_id, hk_punch_id, hk_pause_id
local internal_zoom_active = true
local internal_ind_active = true
local is_punch_active = false
local is_pause_active = false

-- ------------------------------------------------------------------------------
-- GUI Engine
-- ------------------------------------------------------------------------------
function script_description()
    return "<h2>Pro AutoZoom (Ultimate Edition)</h2>" ..
           "<p>The definitive cinematic mouse-tracking engine for OBS content creators.</p>" ..
           "<p><b>Setup:</b> Right-click your Source -> Transform -> Edit Transform. " ..
           "Set Bounding Box Type to <i>Scale to inner bounds</i> and enter your exact Canvas Box dimensions.</p>"
end

function script_properties()
    local props = obs.obs_properties_create()
    
    -- 1. Source & Hardware
    local p_sources = obs.obs_properties_add_list(props, "source_name", "Target Capture Source:", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local id = obs.obs_source_get_id(source)
            if string.find(id, "monitor_capture") or string.find(id, "window_capture") then
                obs.obs_property_list_add_string(p_sources, obs.obs_source_get_name(source), obs.obs_source_get_name(source))
            end
        end
        obs.source_list_release(sources)
    end

    local hw_group = obs.obs_properties_create()
    obs.obs_properties_add_int(hw_group, "mon_w", "Monitor Width (px):", 100, 7680, 1)
    obs.obs_properties_add_int(hw_group, "mon_h", "Monitor Height (px):", 100, 4320, 1)
    obs.obs_properties_add_int(hw_group, "mon_x_offset", "Monitor X Offset:", -10000, 10000, 1)
    obs.obs_properties_add_int(hw_group, "mon_y_offset", "Monitor Y Offset:", -10000, 10000, 1)
    obs.obs_properties_add_group(props, "grp_hw", "🖥️ Hardware Settings", obs.OBS_GROUP_NORMAL, hw_group)

    -- 2. Layouts
    local p_layout = obs.obs_properties_add_list(props, "layout_style", "Smart Canvas Layout:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_layout, "Full Screen Zoom", "full")
    obs.obs_property_list_add_string(p_layout, "Split: Webcam Top, Screen Bottom", "webcam_top")
    obs.obs_property_list_add_string(p_layout, "Split: Screen Top, Webcam Bottom", "webcam_bottom")
    obs.obs_property_list_add_string(p_layout, "Picture-in-Picture (Avoid Corners)", "pip")
    obs.obs_property_list_add_string(p_layout, "Ultrawide Center Strip", "ultrawide")

    -- 3. Camera Engine
    local cam_group = obs.obs_properties_create()
    obs.obs_properties_add_bool(cam_group, "zoom_enabled", "Enable Camera Tracking")
    obs.obs_properties_add_float_slider(cam_group, "base_zoom", "Base Zoom Factor:", 1.0, 5.0, 0.1)
    obs.obs_properties_add_float_slider(cam_group, "punch_zoom", "Punch Zoom (Detail Mode):", 1.0, 10.0, 0.1)
    obs.obs_properties_add_float_slider(cam_group, "tracking_speed", "Cinematic Smoothness:", 0.01, 0.50, 0.01)
    obs.obs_properties_add_int_slider(cam_group, "deadzone", "Lazy Deadzone Radius (%):", 0, 40, 1)
    obs.obs_properties_add_bool(cam_group, "auto_center", "Auto-Return to Center when Idle")
    obs.obs_properties_add_float_slider(cam_group, "auto_center_delay", "Idle Timeout (Seconds):", 1.0, 10.0, 0.5)
    obs.obs_properties_add_group(props, "grp_cam", "🎬 Cinematic Camera Engine", obs.OBS_GROUP_NORMAL, cam_group)

    -- 4. Indicator
    local ind_group = obs.obs_properties_create()
    local p_ind_mode = obs.obs_properties_add_list(ind_group, "ind_mode", "Visibility:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_ind_mode, "Off", "Off")
    obs.obs_property_list_add_string(p_ind_mode, "Always On", "Always On")
    obs.obs_property_list_add_string(p_ind_mode, "Hotkey Triggered", "Hotkey Only")
    
    obs.obs_properties_add_color(ind_group, "ind_color", "Ring Color:")
    obs.obs_properties_add_int_slider(ind_group, "ind_opacity", "Ring Opacity (%):", 10, 100, 5)
    obs.obs_properties_add_int_slider(ind_group, "ind_size", "Ring Size (px):", 20, 300, 5)
    obs.obs_properties_add_group(props, "grp_ind", "🎯 Visual Mouse Indicator", obs.OBS_GROUP_NORMAL, ind_group)

    -- The "Centering" hack: adding space padding based on OBS standard widths
    obs.obs_properties_add_button(props, "lnk_gipsta", "                ❤️ Made by Gipstamusic                ", function()
        os.execute('start "" "https://lnk.bio/gipstamusic"')
        return true
    end)
    
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source_name", "")
    obs.obs_data_set_default_int(settings, "mon_w", 1920)
    obs.obs_data_set_default_int(settings, "mon_h", 1080)
    obs.obs_data_set_default_string(settings, "layout_style", "full")
    obs.obs_data_set_default_bool(settings, "zoom_enabled", true)
    obs.obs_data_set_default_double(settings, "base_zoom", 2.0)
    obs.obs_data_set_default_double(settings, "punch_zoom", 4.0)
    obs.obs_data_set_default_double(settings, "tracking_speed", 0.12)
    obs.obs_data_set_default_int(settings, "deadzone", 15)
    obs.obs_data_set_default_bool(settings, "auto_center", false)
    obs.obs_data_set_default_double(settings, "auto_center_delay", 3.0)
    obs.obs_data_set_default_string(settings, "ind_mode", "Always On")
    obs.obs_data_set_default_int(settings, "ind_color", 16776960)
    obs.obs_data_set_default_int(settings, "ind_opacity", 70)
    obs.obs_data_set_default_int(settings, "ind_size", 72)
    
    cur_zoom = 2.0
end

function script_update(settings)
    cache.source_name = obs.obs_data_get_string(settings, "source_name")
    cache.mon_w = obs.obs_data_get_int(settings, "mon_w")
    cache.mon_h = obs.obs_data_get_int(settings, "mon_h")
    cache.mon_x_offset = obs.obs_data_get_int(settings, "mon_x_offset")
    cache.mon_y_offset = obs.obs_data_get_int(settings, "mon_y_offset")
    cache.layout_style = obs.obs_data_get_string(settings, "layout_style")
    cache.zoom_enabled = obs.obs_data_get_bool(settings, "zoom_enabled")
    cache.base_zoom = obs.obs_data_get_double(settings, "base_zoom")
    cache.punch_zoom = obs.obs_data_get_double(settings, "punch_zoom")
    cache.tracking_speed = obs.obs_data_get_double(settings, "tracking_speed")
    cache.deadzone = obs.obs_data_get_int(settings, "deadzone")
    cache.auto_center = obs.obs_data_get_bool(settings, "auto_center")
    cache.auto_center_delay = obs.obs_data_get_double(settings, "auto_center_delay")
    cache.ind_mode = obs.obs_data_get_string(settings, "ind_mode")
    cache.ind_color = obs.obs_data_get_int(settings, "ind_color")
    cache.ind_opacity = obs.obs_data_get_int(settings, "ind_opacity")
    cache.ind_size = obs.obs_data_get_int(settings, "ind_size")
    
    internal_zoom_active = cache.zoom_enabled
end

-- ------------------------------------------------------------------------------
-- Hotkey Engine
-- ------------------------------------------------------------------------------
function hk_zoom(pressed) if pressed then internal_zoom_active = not internal_zoom_active end end
function hk_ind(pressed) if pressed then internal_ind_active = not internal_ind_active end end
function hk_punch(pressed) is_punch_active = pressed end
function hk_pause(pressed) is_pause_active = pressed end

function script_load(settings)
    hk_zoom_id = obs.obs_hotkey_register_frontend("paz_zoom", "Pro AutoZoom: Toggle Camera", hk_zoom)
    hk_ind_id = obs.obs_hotkey_register_frontend("paz_ind", "Pro AutoZoom: Toggle Pointer", hk_ind)
    hk_punch_id = obs.obs_hotkey_register_frontend("paz_punch", "Pro AutoZoom: Hold for Detail Zoom (Punch)", hk_punch)
    hk_pause_id = obs.obs_hotkey_register_frontend("paz_pause", "Pro AutoZoom: Hold to Freeze Camera", hk_pause)
    
    obs.obs_hotkey_load(hk_zoom_id, obs.obs_data_get_array(settings, "arr_z"))
    obs.obs_hotkey_load(hk_ind_id, obs.obs_data_get_array(settings, "arr_i"))
    obs.obs_hotkey_load(hk_punch_id, obs.obs_data_get_array(settings, "arr_p"))
    obs.obs_hotkey_load(hk_pause_id, obs.obs_data_get_array(settings, "arr_f"))
end

function script_save(settings)
    obs.obs_data_set_array(settings, "arr_z", obs.obs_hotkey_save(hk_zoom_id))
    obs.obs_data_set_array(settings, "arr_i", obs.obs_hotkey_save(hk_ind_id))
    obs.obs_data_set_array(settings, "arr_p", obs.obs_hotkey_save(hk_punch_id))
    obs.obs_data_set_array(settings, "arr_f", obs.obs_hotkey_save(hk_pause_id))
end

-- ------------------------------------------------------------------------------
-- Core Physics & Rendering
-- ------------------------------------------------------------------------------
function get_or_create_filter(source)
    local f = obs.obs_source_get_filter_by_name(source, "CoreAutoZoom_Crop")
    if not f then
        local s = obs.obs_data_create()
        f = obs.obs_source_create_private("crop_filter", "CoreAutoZoom_Crop", s)
        obs.obs_source_filter_add(source, f)
        obs.obs_data_release(s)
    end
    return f
end

function get_canvas_bounds()
    local ovi = obs.obs_video_info()
    obs.obs_get_video_info(ovi)
    local cw, ch = ovi.base_width, ovi.base_height
    
    if cache.layout_style == "webcam_top" then return cw, ch - 608, 0, 608
    elseif cache.layout_style == "webcam_bottom" then return cw, ch - 608, 0, 0
    elseif cache.layout_style == "pip" then return cw, ch, 0, 0
    elseif cache.layout_style == "ultrawide" then return cw, ch / 3, 0, ch / 3
    else return cw, ch, 0, 0 end
end

function calculate_crop(mx, my, bw, bh)
    local c_aspect = bw / bh
    local m_aspect = cache.mon_w / cache.mon_h

    if not internal_zoom_active then
        cur_zoom = cur_zoom + (1.0 - cur_zoom) * cache.tracking_speed
        local cx, cy = 0, 0
        if m_aspect > c_aspect then cx = (cache.mon_w - (cache.mon_h * c_aspect)) / 2
        else cy = (cache.mon_h - (cache.mon_w / c_aspect)) / 2 end
        return cx, cy, cx, cy
    end

    -- Dynamic Zoom Lerping (Smooth Punch Mode)
    local target_z = is_punch_active and cache.punch_zoom or cache.base_zoom
    cur_zoom = cur_zoom + (target_z - cur_zoom) * (cache.tracking_speed * 1.5)

    local zw = cache.mon_w / cur_zoom
    local zh = zw / c_aspect
    if zh > cache.mon_h then zh = cache.mon_h zw = zh * c_aspect end

    if not is_pause_active then
        local dx = math.abs(mx - last_cam.x)
        local dy = math.abs(my - last_cam.y)
        local thresh_x = (zw * (cache.deadzone / 100))
        local thresh_y = (zh * (cache.deadzone / 100))

        if dx > thresh_x then last_cam.x = (mx > last_cam.x) and (mx - thresh_x) or (mx + thresh_x) end
        if dy > thresh_y then last_cam.y = (my > last_cam.y) and (my - thresh_y) or (my + thresh_y) end
        
        -- Auto-Return to Center Logic
        if dx > 2 or dy > 2 then
            last_mouse_time = os.clock()
        elseif cache.auto_center and (os.clock() - last_mouse_time > cache.auto_center_delay) then
            last_cam.x = last_cam.x + ((cache.mon_w / 2) - last_cam.x) * (cache.tracking_speed * 0.2)
            last_cam.y = last_cam.y + ((cache.mon_h / 2) - last_cam.y) * (cache.tracking_speed * 0.2)
        end
    end

    local left = last_cam.x - (zw / 2)
    local top = last_cam.y - (zh / 2)

    if left < 0 then left = 0 elseif left + zw > cache.mon_w then left = cache.mon_w - zw end
    if top < 0 then top = 0 elseif top + zh > cache.mon_h then top = cache.mon_h - zh end

    return left, top, cache.mon_w - (left + zw), cache.mon_h - (top + zh)
end

function script_tick(seconds)
    if cache.source_name == "" then return end
    
    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    local mx = tonumber(m_pos.x) - cache.mon_x_offset
    local my = tonumber(m_pos.y) - cache.mon_y_offset
    
    if mx < 0 then mx = 0 elseif mx > cache.mon_w then mx = cache.mon_w end
    if my < 0 then my = 0 elseif my > cache.mon_h then my = cache.mon_h end

    local source = obs.obs_get_source_by_name(cache.source_name)
    if not source then return end

    local bw, bh, bx, by = get_canvas_bounds()
    target_crop.left, target_crop.top, target_crop.right, target_crop.bottom = calculate_crop(mx, my, bw, bh)

    local spd = cache.tracking_speed
    if is_punch_active then spd = spd * 1.5 end -- Faster tracking during punch
    
    cur_crop.left = cur_crop.left + (target_crop.left - cur_crop.left) * spd
    cur_crop.top = cur_crop.top + (target_crop.top - cur_crop.top) * spd
    cur_crop.right = cur_crop.right + (target_crop.right - cur_crop.right) * spd
    cur_crop.bottom = cur_crop.bottom + (target_crop.bottom - cur_crop.bottom) * spd

    local filter = get_or_create_filter(source)
    if filter then
        local f_settings = obs.obs_source_get_settings(filter)
        obs.obs_data_set_int(f_settings, "left", math.floor(cur_crop.left))
        obs.obs_data_set_int(f_settings, "top", math.floor(cur_crop.top))
        obs.obs_data_set_int(f_settings, "right", math.floor(cur_crop.right))
        obs.obs_data_set_int(f_settings, "bottom", math.floor(cur_crop.bottom))
        obs.obs_source_update(filter, f_settings)
        obs.obs_data_release(f_settings)
        obs.obs_source_release(filter)
    end
    obs.obs_source_release(source)

    -- Vector Highlight Engine
    if cache.ind_mode ~= "Off" then
        local show = (cache.ind_mode == "Always On") or (cache.ind_mode == "Hotkey Triggered" and internal_ind_active)
        local p_source = obs.obs_get_source_by_name("ProAutoZoom_CirclePointer")
        local current_scene_source = obs.obs_frontend_get_current_scene()
        
        if show and current_scene_source then
            local scene = obs.obs_scene_from_source(current_scene_source)
            local alpha_val = math.floor((cache.ind_opacity / 100) * 255)
            local final_color = cache.ind_color + (alpha_val * 16777216)
            
            if not p_source then
                local s_settings = obs.obs_data_create()
                obs.obs_data_set_string(s_settings, "text", "●")
                obs.obs_data_set_int(s_settings, "color", final_color)
                local font_obj = obs.obs_data_create()
                obs.obs_data_set_string(font_obj, "face", "Arial")
                obs.obs_data_set_int(font_obj, "size", cache.ind_size)
                obs.obs_data_set_obj(s_settings, "font", font_obj)
                obs.obs_data_release(font_obj)
                
                p_source = obs.obs_source_create("text_gdiplus", "ProAutoZoom_CirclePointer", s_settings, nil)
                obs.obs_data_release(s_settings)
                obs.obs_scene_add(scene, p_source)
            else
                local s_settings = obs.obs_data_create()
                obs.obs_data_set_int(s_settings, "color", final_color)
                local font_obj = obs.obs_data_create()
                obs.obs_data_set_string(font_obj, "face", "Arial")
                obs.obs_data_set_int(font_obj, "size", cache.ind_size)
                obs.obs_data_set_obj(s_settings, "font", font_obj)
                obs.obs_data_release(font_obj)
                obs.obs_source_update(p_source, s_settings)
                obs.obs_data_release(s_settings)
            end
            
            local target_item = obs.obs_scene_find_source(scene, cache.source_name)
            local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")
            
            if target_item and pointer_item then
                local t_info = obs.obs_transform_info()
                if obs.obs_sceneitem_get_info2 then obs.obs_sceneitem_get_info2(target_item, t_info) else obs.obs_sceneitem_get_info(target_item, t_info) end
                
                local vis_w = cache.mon_w - cur_crop.left - cur_crop.right
                local vis_h = cache.mon_h - cur_crop.top - cur_crop.bottom
                
                if vis_w > 0 and vis_h > 0 then
                    local scale_x = t_info.bounds.x / vis_w
                    local scale_y = t_info.bounds.y / vis_h
                    local ind_x = t_info.pos.x + ((mx - cur_crop.left) * scale_x) - (cache.ind_size / 2)
                    local ind_y = t_info.pos.y + ((my - cur_crop.top) * scale_y) - (cache.ind_size / 1.35)
                    
                    local pos = obs.vec2()
                    obs.vec2_set(pos, ind_x, ind_y)
                    obs.obs_sceneitem_set_pos(pointer_item, pos)
                    obs.obs_sceneitem_set_visible(pointer_item, true)
                end
            end
        else
            if p_source and current_scene_source then
                local scene = obs.obs_scene_from_source(current_scene_source)
                local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_CirclePointer")
                if pointer_item then obs.obs_sceneitem_set_visible(pointer_item, false) end
            end
        end
        if p_source then obs.obs_source_release(p_source) end
        if current_scene_source then obs.obs_source_release(current_scene_source) end
    end
end