-- ==============================================================================
-- PRO AUTOZOOM (THE FINAL BUILD)
-- Description: Layout-safe mouse tracking script with dynamic visual indicator.
-- Compatible with OBS 29 & OBS 30+.
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
    ind_mode = "Off",
    ind_color = 2147549183, -- Default: Semi-transparent Yellow (ABGR format)
    ind_size = 60,
    debug_mode = false
}

local cur_crop = { left = 0, top = 0, right = 0, bottom = 0 }
local target_crop = { left = 0, top = 0, right = 0, bottom = 0 }

local zoom_hotkey_id = obs.OBS_INVALID_HOTKEY_ID
local ind_hotkey_id = obs.OBS_INVALID_HOTKEY_ID
local is_ind_hotkey_active = false
local internal_zoom_active = false

-- ------------------------------------------------------------------------------
-- UI Definitions
-- ------------------------------------------------------------------------------
function script_description()
    return "<h2>Pro AutoZoom (Studio Edition)</h2>" ..
           "<p>A layout-safe mouse tracking engine for OBS. Features dynamic crop mapping and integrated cursor highlights.</p>" ..
           "<p><b>Required Setup:</b> Right-click your Target Source -> Transform -> Edit Transform. " ..
           "Set Bounding Box Type to <i>Scale to inner bounds</i> and enter your Box dimensions.</p>"
end

function script_properties()
    local props = obs.obs_properties_create()
    
    -- Main Source Selection
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
    
    -- Core Tracking Controls
    obs.obs_properties_add_bool(props, "zoom_enabled", "Enable Camera Tracking (Default)")
    obs.obs_properties_add_float_slider(props, "zoom_factor", "Camera Zoom Factor:", 1.0, 5.0, 0.1)
    obs.obs_properties_add_float_slider(props, "tracking_speed", "Tracking Smoothness (Lower = Smoother):", 0.01, 1.0, 0.01)
    
    -- 1. Display Group
    local display_group = obs.obs_properties_create()
    obs.obs_properties_add_int(display_group, "mon_w", "Monitor Width (px):", 100, 7680, 1)
    obs.obs_properties_add_int(display_group, "mon_h", "Monitor Height (px):", 100, 4320, 1)
    obs.obs_properties_add_int(display_group, "mon_x_offset", "Monitor X Offset (Multi-monitor):", -10000, 10000, 1)
    obs.obs_properties_add_int(display_group, "mon_y_offset", "Monitor Y Offset (Multi-monitor):", -10000, 10000, 1)
    obs.obs_properties_add_group(props, "grp_display", "1. Capture Monitor Settings", obs.OBS_GROUP_NORMAL, display_group)
    
    -- 2. Layout Group
    local layout_group = obs.obs_properties_create()
    obs.obs_properties_add_int(layout_group, "box_w", "Target Box Width (px):", 100, 3840, 1)
    obs.obs_properties_add_int(layout_group, "box_h", "Target Box Height (px):", 100, 3840, 1)
    
    local p_idle = obs.obs_properties_add_list(layout_group, "idle_behavior", "When Zoom is OFF:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_idle, "Crop to Fill Box (No Black Bars)", "fill")
    obs.obs_property_list_add_string(p_idle, "Show Full Screen (Letterbox)", "full")
    obs.obs_properties_add_group(props, "grp_layout", "2. OBS Canvas Layout Settings", obs.OBS_GROUP_NORMAL, layout_group)

    -- 3. Mouse Indicator Group
    local ind_group = obs.obs_properties_create()
    local p_ind_mode = obs.obs_properties_add_list(ind_group, "ind_mode", "Indicator Mode:", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_ind_mode, "Off", "Off")
    obs.obs_property_list_add_string(p_ind_mode, "Always On", "Always On")
    obs.obs_property_list_add_string(p_ind_mode, "Hotkey Only", "Hotkey Only")
    
    obs.obs_properties_add_color(ind_group, "ind_color", "Indicator Color:")
    obs.obs_properties_add_int_slider(ind_group, "ind_size", "Indicator Size (px):", 10, 200, 1)
    obs.obs_properties_add_group(props, "grp_ind", "3. Visual Mouse Indicator", obs.OBS_GROUP_NORMAL, ind_group)

    -- 4. Branding
    obs.obs_properties_add_text(props, "credit_text", "❤️ Made by Gipstamusic\n🌐 https://lnk.bio/gipstamusic", obs.OBS_TEXT_INFO)
    
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
    obs.obs_data_set_default_string(settings, "ind_mode", "Off")
    obs.obs_data_set_default_int(settings, "ind_color", 2147549183)
    obs.obs_data_set_default_int(settings, "ind_size", 60)
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
    settings_cache.ind_mode = obs.obs_data_get_string(settings, "ind_mode")
    settings_cache.ind_color = obs.obs_data_get_int(settings, "ind_color")
    settings_cache.ind_size = obs.obs_data_get_int(settings, "ind_size")
    
    internal_zoom_active = settings_cache.zoom_enabled
end

-- ------------------------------------------------------------------------------
-- Hotkey Management
-- ------------------------------------------------------------------------------
function toggle_zoom_hotkey(pressed)
    if not pressed then return end
    internal_zoom_active = not internal_zoom_active
end

function toggle_indicator_hotkey(pressed)
    if not pressed then return end
    is_ind_hotkey_active = not is_ind_hotkey_active
end

function script_load(settings)
    zoom_hotkey_id = obs.obs_hotkey_register_frontend("pro_autozoom_toggle", "Pro AutoZoom: Toggle Camera", toggle_zoom_hotkey)
    local z_array = obs.obs_data_get_array(settings, "pro_autozoom_hotkey")
    obs.obs_hotkey_load(zoom_hotkey_id, z_array)
    obs.obs_data_array_release(z_array)
    
    ind_hotkey_id = obs.obs_hotkey_register_frontend("pro_autozoom_ind_toggle", "Pro AutoZoom: Toggle Indicator", toggle_indicator_hotkey)
    local i_array = obs.obs_data_get_array(settings, "pro_autozoom_ind_hotkey")
    obs.obs_hotkey_load(ind_hotkey_id, i_array)
    obs.obs_data_array_release(i_array)
end

function script_save(settings)
    local z_array = obs.obs_hotkey_save(zoom_hotkey_id)
    obs.obs_data_set_array(settings, "pro_autozoom_hotkey", z_array)
    obs.obs_data_array_release(z_array)
    
    local i_array = obs.obs_hotkey_save(ind_hotkey_id)
    obs.obs_data_set_array(settings, "pro_autozoom_ind_hotkey", i_array)
    obs.obs_data_array_release(i_array)
end

-- ------------------------------------------------------------------------------
-- Core Engine (Math & Rendering)
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

function calculate_target_crop(mx, my)
    local c_aspect = settings_cache.box_w / settings_cache.box_h
    local m_aspect = settings_cache.mon_w / settings_cache.mon_h

    if not internal_zoom_active then
        if settings_cache.idle_behavior == "full" then
            return 0, 0, 0, 0
        else
            local crop_x, crop_y = 0, 0
            if m_aspect > c_aspect then
                local target_w = settings_cache.mon_h * c_aspect
                crop_x = (settings_cache.mon_w - target_w) / 2
            else
                local target_h = settings_cache.mon_w / c_aspect
                crop_y = (settings_cache.mon_h - target_h) / 2
            end
            return crop_x, crop_y, crop_x, crop_y
        end
    end

    local zoom_w = settings_cache.mon_w / settings_cache.zoom_factor
    local zoom_h = zoom_w / c_aspect

    if zoom_h > settings_cache.mon_h then
        zoom_h = settings_cache.mon_h
        zoom_w = zoom_h * c_aspect
    end

    local left = mx - (zoom_w / 2)
    local top = my - (zoom_h / 2)

    if left < 0 then left = 0 elseif left + zoom_w > settings_cache.mon_w then left = settings_cache.mon_w - zoom_w end
    if top < 0 then top = 0 elseif top + zoom_h > settings_cache.mon_h then top = settings_cache.mon_h - zoom_h end

    local right = settings_cache.mon_w - (left + zoom_w)
    local bottom = settings_cache.mon_h - (top + zoom_h)

    return left, top, right, bottom
end

function script_tick(seconds)
    if settings_cache.source_name == "" then return end
    
    -- Grab Mouse Coordinates
    local m_pos = ffi.new("POINT")
    ffi.C.GetCursorPos(m_pos)
    local mx = tonumber(m_pos.x) - settings_cache.mon_x_offset
    local my = tonumber(m_pos.y) - settings_cache.mon_y_offset
    
    if mx < 0 then mx = 0 elseif mx > settings_cache.mon_w then mx = settings_cache.mon_w end
    if my < 0 then my = 0 elseif my > settings_cache.mon_h then my = settings_cache.mon_h end

    local source = obs.obs_get_source_by_name(settings_cache.source_name)
    if not source then return end

    -- 1. Apply Dynamic Crop Mapping
    target_crop.left, target_crop.top, target_crop.right, target_crop.bottom = calculate_target_crop(mx, my)

    local spd = settings_cache.tracking_speed
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

    -- 2. Mouse Indicator Subsystem
    if settings_cache.ind_mode ~= "Off" then
        local show_indicator = false
        if settings_cache.ind_mode == "Always On" then show_indicator = true
        elseif settings_cache.ind_mode == "Hotkey Only" then show_indicator = is_ind_hotkey_active end

        local p_source = obs.obs_get_source_by_name("ProAutoZoom_Pointer")
        local current_scene_source = obs.obs_frontend_get_current_scene()
        
        if show_indicator and current_scene_source then
            local scene = obs.obs_scene_from_source(current_scene_source)
            
            -- Auto-Generate the Pointer Graphic
            if not p_source then
                local s_settings = obs.obs_data_create()
                obs.obs_data_set_int(s_settings, "color", settings_cache.ind_color)
                obs.obs_data_set_int(s_settings, "width", settings_cache.ind_size)
                obs.obs_data_set_int(s_settings, "height", settings_cache.ind_size)
                p_source = obs.obs_source_create("color_source", "ProAutoZoom_Pointer", s_settings, nil)
                obs.obs_data_release(s_settings)
                obs.obs_scene_add(scene, p_source)
            else
                local s_settings = obs.obs_data_create()
                obs.obs_data_set_int(s_settings, "color", settings_cache.ind_color)
                obs.obs_data_set_int(s_settings, "width", settings_cache.ind_size)
                obs.obs_data_set_int(s_settings, "height", settings_cache.ind_size)
                obs.obs_source_update(p_source, s_settings)
                obs.obs_data_release(s_settings)
            end
            
            -- Map to the Scene Coordinates
            local target_item = obs.obs_scene_find_source(scene, settings_cache.source_name)
            local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_Pointer")
            
            if target_item and pointer_item then
                local t_info = obs.obs_transform_info()
                -- Universal Version Fix (OBS 29 vs OBS 30+)
                if obs.obs_sceneitem_get_info2 then
                    obs.obs_sceneitem_get_info2(target_item, t_info)
                else
                    obs.obs_sceneitem_get_info(target_item, t_info)
                end
                
                local vis_w = settings_cache.mon_w - cur_crop.left - cur_crop.right
                local vis_h = settings_cache.mon_h - cur_crop.top - cur_crop.bottom
                
                if vis_w > 0 and vis_h > 0 then
                    -- Math calculates the exact ratio of the crop box to the physical canvas box
                    local scale_x = t_info.bounds.x / vis_w
                    local scale_y = t_info.bounds.y / vis_h
                    local c_offset = settings_cache.ind_size / 2
                    
                    local ind_x = t_info.pos.x + ((mx - cur_crop.left) * scale_x) - c_offset
                    local ind_y = t_info.pos.y + ((my - cur_crop.top) * scale_y) - c_offset
                    
                    local pos = obs.vec2()
                    obs.vec2_set(pos, ind_x, ind_y)
                    obs.obs_sceneitem_set_pos(pointer_item, pos)
                    obs.obs_sceneitem_set_visible(pointer_item, true)
                end
            end
        else
            -- Hide Indicator Safely
            if p_source and current_scene_source then
                local scene = obs.obs_scene_from_source(current_scene_source)
                local pointer_item = obs.obs_scene_find_source(scene, "ProAutoZoom_Pointer")
                if pointer_item then obs.obs_sceneitem_set_visible(pointer_item, false) end
            end
        end
        
        if p_source then obs.obs_source_release(p_source) end
        if current_scene_source then obs.obs_source_release(current_scene_source) end
    end
end