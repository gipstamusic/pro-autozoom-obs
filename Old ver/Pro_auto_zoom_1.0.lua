-- ==============================================================================
-- Pro AutoZoom for OBS Studio
-- Description: A bulletproof, layout-safe mouse tracking zoom script.
-- Uses internal Crop Filters constrained to a Bounding Box to prevent scene breakage.
-- ==============================================================================

local obs = obslua
local ffi = require("ffi")

-- ------------------------------------------------------------------------------
-- Windows API Binding for Mouse Tracking
-- ------------------------------------------------------------------------------
ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    int GetCursorPos(POINT* lpPoint);
]]

-- ------------------------------------------------------------------------------
-- Global State & Settings
-- ------------------------------------------------------------------------------
local settings_cache = {
    source_name = "",
    zoom_enabled = false,
    zoom_factor = 2.0,
    tracking_speed = 0.15,
    mon_x_offset = 0,
    mon_y_offset = 0,
    mon_w = 1920,
    mon_h = 1080,
    box_w = 1080,
    box_h = 1312,
    idle_behavior = "fill",
    debug_mode = false
}

local cur_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local target_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local hotkey_id = obs.OBS_INVALID_HOTKEY_ID

-- ------------------------------------------------------------------------------
-- UI Definitions
-- ------------------------------------------------------------------------------
function script_description()
    return "<h2>Pro AutoZoom</h2>" ..
           "<p>A layout-safe mouse tracking script for OBS. Perfect for vertical reels and tutorials.</p>" ..
           "<p><b>Setup:</b> Right-click your source in OBS -> Transform -> Edit Transform.<br/>" ..
           "Set Bounding Box Type to <i>Scale to inner bounds</i> and enter your exact Target Box dimensions.</p>"
end

function script_properties()
    local props = obs.obs_properties_create()
    
    -- Source Selection
    local p_sources = obs.obs_properties_add_list(props, "source_name", "Target Source:", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
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
    
    -- Core Controls
    obs.obs_properties_add_bool(props, "zoom_enabled", "Enable Tracking (Can also use Hotkey)")
    obs.obs_properties_add_float_slider(props, "zoom_factor", "Zoom Factor:", 1.0, 5.0, 0.1)
    obs.obs_properties_add_float_slider(props, "tracking_speed", "Tracking Smoothness (Lower = Smoother):", 0.01, 1.0, 0.01)
    
    -- Display Settings
    local display_group = obs.obs_properties_create()
    obs.obs_properties_add_int(display_group, "mon_w", "Monitor Width (px):", 100, 7680, 1)
    obs.obs_properties_add_int(display_group, "mon_h", "Monitor Height (px):", 100, 4320, 1)
    obs.obs_properties_add_int(display_group, "mon_x_offset", "Monitor X Offset (Multi-monitor):", -10000, 10000, 1)
    obs.obs_properties_add_int(display_group, "mon_y_offset", "Monitor Y Offset (Multi-monitor):", -10000, 10000, 1)
    obs.obs_properties_add_group(props, "grp_display", "1. Capture Monitor Settings", obs.OBS_GROUP_NORMAL, display_group)
    
    -- Layout Settings
    local layout_group = obs.obs_properties_create()
    obs.obs_properties_add_int(layout_group, "box_w", "Target Box Width (px):", 100, 3840, 1)
    obs.obs_properties_add_int(layout_group, "box_h", "Target Box Height (px):", 100, 3840, 1)
    
    local p_idle = obs.obs_properties_add_list(layout_group, "idle_behavior", "When Zoom is OFF:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_idle, "Crop to Fill Box (No Black Bars)", "fill")
    obs.obs_property_list_add_string(p_idle, "Show Full Screen (Letterbox)", "full")
    
    obs.obs_properties_add_group(props, "grp_layout", "2. OBS Canvas Layout Settings", obs.OBS_GROUP_NORMAL, layout_group)

    -- Developer
    obs.obs_properties_add_bool(props, "debug_mode", "Enable Debug Logs")
    
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "zoom_enabled", false)
    obs.obs_data_set_default_double(settings, "zoom_factor", 2.0)
    obs.obs_data_set_default_double(settings, "tracking_speed", 0.15)
    obs.obs_data_set_default_int(settings, "mon_w", 1920)
    obs.obs_data_set_default_int(settings, "mon_h", 1080)
    obs.obs_data_set_default_int(settings, "mon_x_offset", 0)
    obs.obs_data_set_default_int(settings, "mon_y_offset", 0)
    obs.obs_data_set_default_int(settings, "box_w", 1080)
    obs.obs_data_set_default_int(settings, "box_h", 1312)
    obs.obs_data_set_default_string(settings, "idle_behavior", "fill")
end

function script_update(settings)
    settings_cache.source_name = obs.obs_data_get_string(settings, "source_name")
    settings_cache.zoom_enabled = obs.obs_data_get_bool(settings, "zoom_enabled")
    settings_cache.zoom_factor = obs.obs_data_get_double(settings, "zoom_factor")
    settings_cache.tracking_speed = obs.obs_data_get_double(settings, "tracking_speed")
    settings_cache.mon_w = obs.obs_data_get_int(settings, "mon_w")
    settings_cache.mon_h = obs.obs_data_get_int(settings, "mon_h")
    settings_cache.mon_x_offset = obs.obs_data_get_int(settings, "mon_x_offset")
    settings_cache.mon_y_offset = obs.obs_data_get_int(settings, "mon_y_offset")
    settings_cache.box_w = obs.obs_data_get_int(settings, "box_w")
    settings_cache.box_h = obs.obs_data_get_int(settings, "box_h")
    settings_cache.idle_behavior = obs.obs_data_get_string(settings, "idle_behavior")
    settings_cache.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")
end

-- ------------------------------------------------------------------------------
-- Hotkey Management
-- ------------------------------------------------------------------------------
function toggle_zoom(pressed)
    if not pressed then return end
    settings_cache.zoom_enabled = not settings_cache.zoom_enabled
    
    -- Update the UI checkbox to reflect the hotkey press
    local settings = obs.obs_data_create()
    obs.obs_data_set_bool(settings, "zoom_enabled", settings_cache.zoom_enabled)
    obs.obs_apply_private_data(settings)
    obs.obs_data_release(settings)
    
    if settings_cache.debug_mode then
        obs.script_log(obs.OBS_LOG_INFO, "Zoom Toggled: " .. tostring(settings_cache.zoom_enabled))
    end
end

function script_load(settings)
    hotkey_id = obs.obs_hotkey_register_frontend("pro_autozoom_toggle", "Toggle Pro AutoZoom", toggle_zoom)
    local hotkey_save_array = obs.obs_data_get_array(settings, "pro_autozoom_hotkey")
    obs.obs_hotkey_load(hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end

function script_save(settings)
    local hotkey_save_array = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "pro_autozoom_hotkey", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end

-- ------------------------------------------------------------------------------
-- Core Engine
-- ------------------------------------------------------------------------------
function get_or_create_filter(source)
    local filter_name = "ProAutoZoom_Crop"
    local filter = obs.obs_source_get_filter_by_name(source, filter_name)
    if not filter then
        local settings = obs.obs_data_create()
        filter = obs.obs_source_create_private("crop_filter", filter_name, settings)
        obs.obs_source_filter_add(source, filter)
        obs.obs_data_release(settings)
    end
    return filter
end

function calculate_target_crop()
    local c_aspect = settings_cache.box_w / settings_cache.box_h
    local m_aspect = settings_cache.mon_w / settings_cache.mon_h

    if not settings_cache.zoom_enabled then
        if settings_cache.idle_behavior == "full" then
            return 0, 0, 0, 0
        else
            -- Idle Behavior: Fill (Calculates edge crops to make monitor match canvas aspect ratio)
            local crop_x, crop_y = 0, 0
            if m_aspect > c_aspect then
                -- Monitor is wider, crop sides
                local target_w = settings_cache.mon_h * c_aspect
                crop_x = (settings_cache.mon_w - target_w) / 2
            else
                -- Monitor is taller, crop top/bottom
                local target_h = settings_cache.mon_w / c_aspect
                crop_y = (settings_cache.mon_h - target_h) / 2
            end
            return crop_x, crop_y, crop_x, crop_y
        end
    end

    -- Zoom Behavior: Calculate active mouse tracking crop
    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    
    -- Normalize mouse coordinates to the target monitor
    local mx = tonumber(m_pos.x) - settings_cache.mon_x_offset
    local my = tonumber(m_pos.y) - settings_cache.mon_y_offset
    
    if mx < 0 then mx = 0 elseif mx > settings_cache.mon_w then mx = settings_cache.mon_w end
    if my < 0 then my = 0 elseif my > settings_cache.mon_h then my = settings_cache.mon_h end

    local zoom_w = settings_cache.mon_w / settings_cache.zoom_factor
    local zoom_h = zoom_w / c_aspect

    if zoom_h > settings_cache.mon_h then
        zoom_h = settings_cache.mon_h
        zoom_w = zoom_h * c_aspect
    end

    local left = mx - (zoom_w / 2)
    local top = my - (zoom_h / 2)

    -- Clamp to edges
    if left < 0 then left = 0 elseif left + zoom_w > settings_cache.mon_w then left = settings_cache.mon_w - zoom_w end
    if top < 0 then top = 0 elseif top + zoom_h > settings_cache.mon_h then top = settings_cache.mon_h - zoom_h end

    local right = settings_cache.mon_w - (left + zoom_w)
    local bottom = settings_cache.mon_h - (top + zoom_h)

    return left, top, right, bottom
end

function script_tick(seconds)
    if settings_cache.source_name == "" then return end
    local source = obs.obs_get_source_by_name(settings_cache.source_name)
    if not source then return end

    -- 1. Calculate Target
    target_crop.left, target_crop.top, target_crop.right, target_crop.bottom = calculate_target_crop()

    -- 2. Lerp (Smoothly transition current values to target values)
    local spd = settings_cache.tracking_speed
    cur_crop.left = cur_crop.left + (target_crop.left - cur_crop.left) * spd
    cur_crop.top = cur_crop.top + (target_crop.top - cur_crop.top) * spd
    cur_crop.right = cur_crop.right + (target_crop.right - cur_crop.right) * spd
    cur_crop.bottom = cur_crop.bottom + (target_crop.bottom - cur_crop.bottom) * spd

    -- 3. Apply to Filter
    local filter = get_or_create_filter(source)
    if filter then
        local f_settings = obs.obs_source_get_settings(filter)
        -- math.floor prevents micro-stuttering/jitter caused by decimal pixel values
        obs.obs_data_set_int(f_settings, "left", math.floor(cur_crop.left))
        obs.obs_data_set_int(f_settings, "top", math.floor(cur_crop.top))
        obs.obs_data_set_int(f_settings, "right", math.floor(cur_crop.right))
        obs.obs_data_set_int(f_settings, "bottom", math.floor(cur_crop.bottom))
        
        obs.obs_source_update(filter, f_settings)
        obs.obs_data_release(f_settings)
        obs.obs_source_release(filter)
    end

    obs.obs_source_release(source)
end