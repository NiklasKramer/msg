-- arc_utils.lua

-- Helper function to normalize parameter values to a scale of 0 to 64
local function normalize_param_value(value, min, max)
    local range = max - min
    return math.floor(((value - min) / range) * 64)
end

-- Helper function to scale a value to an angle
local function scale_angle(value, scale)
    local angle = value * 2 * math.pi
    if math.abs(value - scale) < 0.0001 then -- Allow for a tiny margin of error
        angle = angle - 0.0001               -- Subtract a tiny value to avoid reaching 2 * pi
    end
    return angle
end

-- Display percent markers on the arc
local function display_percent_markers(arc_device, encoder, ...)
    local markers = { ... }
    for _, percent in ipairs(markers) do
        -- Map percent from [-200, 200] to LED positions [1, 64]
        local led_position = math.floor(((percent + 200) / 400) * 64) + 1
        led_position = util.clamp(led_position, 1, 64) -- Ensure LED position is within 1 to 64
        local brightness = 15

        -- Display the marker on the arc
        arc_device:led(encoder, led_position, brightness)
    end
end

-- Display spread pattern on the arc
local function display_spread_pattern(arc_device, encoder, value, min, max)
    local normalized = (value - min) / (max - min)
    local total_leds = 64
    local spread_leds = math.floor(normalized * total_leds / 2)

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    local center_led = math.floor(total_leds / 2)
    local start_led = math.max(center_led - spread_leds, 1)
    local end_led = math.min(center_led + spread_leds, total_leds)

    for led = start_led, end_led do
        local distance_from_center = math.max(math.abs(center_led - led), 1)
        local brightness = math.min(0 + (distance_from_center * 2), 15)
        brightness = math.max(brightness, 3)

        arc_device:led(encoder, led + 1 - 32, brightness)
    end
    arc_device:refresh()
end

-- Display progress bar on the arc
local function display_progress_bar(arc_device, encoder, value, min, max)
    local normalized = normalize_param_value(value, min, max)
    local brightness_max = 12
    local gradient_factor = 1

    for led = 1, 64 do
        if led <= normalized then
            local distance = math.abs(normalized - led)
            local brightness = math.max(1, brightness_max - (distance * gradient_factor))
            arc_device:led(encoder, led + 1, brightness)
        else
            arc_device:led(encoder, led + 1, 0)
        end
    end
end

-- Display filter pattern on the arc
local function display_filter_pattern(arc_device, encoder, value, min, max)
    local total_leds = 64
    local midpoint_led = total_leds / 2 + 1        -- LED 33 is the top center
    local normalized = (value - min) / (max - min) -- Normalize value to [0, 1]
    local brightness = 5

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    if value <= 0.5 then
        local active_leds_each_side = math.floor(normalized * 2 * midpoint_led)
        for i = 0, active_leds_each_side - 1 do
            arc_device:led(encoder, (midpoint_led - i - 1) % total_leds + 1, brightness) -- Left side
            arc_device:led(encoder, (midpoint_led + i - 1) % total_leds + 1, brightness) -- Right side
        end
    else
        local inactive_leds_each_side = math.floor((normalized - 0.5) * 2 * midpoint_led)
        for i = 0, midpoint_led - inactive_leds_each_side - 1 do
            arc_device:led(encoder, (1 + i - 1) % total_leds + 1, brightness)
            arc_device:led(encoder, (total_leds - i - 1) % total_leds + 1, brightness)
        end
    end

    if value == max then
        arc_device:led(encoder, midpoint_led, 15)
    elseif value == min then
        arc_device:led(encoder, 1, 15)
    else
        arc_device:led(encoder, 1, 15)
        arc_device:led(encoder, midpoint_led, 15)
    end
end

-- Display rotating pattern on the arc
local function display_rotating_pattern(arc_device, encoder, value, min, max)
    local normalized = normalize_param_value(value, min, max)
    local start_led = (normalized % 64) + 1
    local pattern_width = 2
    local max_brightness = 10

    for i = -pattern_width, pattern_width do
        local led = (start_led + i - 1) % 64 + 1
        local brightness = max_brightness - math.abs(i) * 3
        brightness = math.max(brightness, 1)
        arc_device:led(encoder, led, brightness)
    end
end

-- Display random pattern on the arc
local function display_random_pattern(arc_device, encoder, value, min, max)
    local normalized_value = (value - min) / (max - min)
    local chance = 1 - normalized_value

    for led = 1, 64 do
        if math.random() > chance then
            arc_device:led(encoder, led, math.random(5, 12))
        else
            arc_device:led(encoder, led, 0)
        end
    end
end

-- Display exponential pattern on the arc
local function display_exponential_pattern(arc_device, encoder, value, min, max)
    local normalized = (math.log(value) - math.log(min)) / (math.log(max) - math.log(min))
    local led_position = math.floor(normalized * 64)

    for led = 1, 64 do
        if led == led_position then
            arc_device:led(encoder, led, 15)
        elseif led < led_position then
            arc_device:led(encoder, led, 3)
        else
            arc_device:led(encoder, led, 0)
        end
    end
end

-- Display panning value on the arc
local function display_panning_value(arc_device, encoder, value, min, max)
    local total_leds = 64
    local center_led = math.floor(total_leds / 2) + 1
    local range = max - min
    local normalized_value = (value - min) / range
    local led_position = math.floor((normalized_value - 0.5) * total_leds / 3) + center_led

    -- Clear all LEDs first
    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    -- Light up LEDs based on the value
    if value < 0 then
        for led = center_led, led_position, -1 do
            arc_device:led(encoder, led, 15)
        end
    elseif value > 0 then
        for led = center_led, led_position do
            arc_device:led(encoder, led, 15)
        end
    else
        arc_device:led(encoder, center_led, 15)
    end
end

-- Display loop information: start, end, and playhead position
local function display_loop_params(arc_device, encoder, loop_start, loop_end, playhead)
    local total_leds = 64
    local start_led = math.floor(loop_start * total_leds) + 1
    local end_led = math.floor(loop_end * total_leds) + 1
    local playhead_led = playhead and (math.floor(playhead * total_leds) + 1) or nil

    if loop_start == 0 and loop_end == 1 then
        for led = 1, total_leds do
            arc_device:led(encoder, led, 0)
        end
        arc_device:refresh()
        return
    end

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    for led = start_led, end_led do
        arc_device:led(encoder, led, 5)
    end

    arc_device:led(encoder, playhead_led, 15)
end

-- Display only loop start position
local function display_loop_start_params(arc_device, encoder, loop_start, loop_end, playhead, loop_active)
    local total_leds = 64
    local start_led = math.floor(loop_start * total_leds) + 1
    local end_led = math.floor(loop_end * total_leds) + 1
    local playhead_led = playhead and (math.floor(playhead * total_leds) + 1) or nil

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end


    if loop_active then
        -- Draw loop region
        if start_led <= end_led then
            for led = start_led, end_led do
                arc_device:led(encoder, led, 5)
            end
        else
            for led = start_led, total_leds do
                arc_device:led(encoder, led, 5)
            end
            for led = 1, end_led do
                arc_device:led(encoder, led, 5)
            end
        end
        -- Highlight loop start
        arc_device:led(encoder, start_led, 15)
        arc_device:led(encoder, end_led, 10)
    end

    -- Show playhead
    if playhead_led then
        local in_loop = false
        if loop_active then
            if start_led <= end_led then
                in_loop = playhead_led >= start_led and playhead_led <= end_led
            else
                in_loop = playhead_led >= start_led or playhead_led <= end_led
            end
        end
        arc_device:led(encoder, playhead_led, in_loop and 10 or 2)
    end
end

-- Display only loop end position
local function display_loop_end_params(arc_device, encoder, loop_start, loop_end, playhead, loop_active)
    local total_leds = 64
    local end_led = math.floor(loop_end * total_leds) + 1
    local start_led = math.floor(loop_start * total_leds) + 1
    local playhead_led = math.floor(playhead * total_leds) + 1


    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    if loop_active then
        arc_device:led(encoder, end_led, 15)
        arc_device:led(encoder, start_led, 10)
    end

    arc_device:led(encoder, playhead_led, 2)
    arc_device:refresh()
end

-- Display loop length as a bar from start to end
local function display_loop_length_params(arc_device, encoder, loop_start, loop_end)
    local total_leds = 64
    local start_led = math.floor(loop_start * total_leds) + 1
    local end_led = math.floor(loop_end * total_leds) + 1

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    for led = start_led, end_led do
        arc_device:led(encoder, led, 12)
    end
end

-- Display both loop start and end with playhead position
local function display_loop_segment_params(arc_device, encoder, loop_start, loop_end, playhead, loop_active)
    local total_leds = 64
    local start_led = math.floor(loop_start * total_leds) + 1
    local end_led = math.floor(loop_end * total_leds) + 1
    local playhead_led = playhead and (math.floor(playhead * total_leds) + 1) or nil

    for led = 1, total_leds do
        arc_device:led(encoder, led, 0)
    end

    if loop_active then
        if start_led <= end_led then
            for led = start_led, end_led do
                arc_device:led(encoder, led, 5)
            end
        else
            for led = start_led, total_leds do
                arc_device:led(encoder, led, 5)
            end
            for led = 1, end_led do
                arc_device:led(encoder, led, 5)
            end
        end
        arc_device:led(encoder, start_led, 15)
        arc_device:led(encoder, end_led, 15)
    end

    if playhead_led then
        local in_loop = false
        if loop_active then
            if start_led <= end_led then
                in_loop = playhead_led >= start_led and playhead_led <= end_led
            else
                in_loop = playhead_led >= start_led or playhead_led <= end_led
            end
        end
        arc_device:led(encoder, playhead_led, in_loop and 10 or 2)
    end

    arc_device:refresh()
end

-- Export the functions
return {
    display_percent_markers = display_percent_markers,
    display_spread_pattern = display_spread_pattern,
    display_progress_bar = display_progress_bar,
    display_filter_pattern = display_filter_pattern,
    display_rotating_pattern = display_rotating_pattern,
    display_random_pattern = display_random_pattern,
    display_exponential_pattern = display_exponential_pattern,
    display_panning_value = display_panning_value,
    normalize_param_value = normalize_param_value,
    scale_angle = scale_angle,
    display_loop_params = display_loop_params,
    display_loop_start_params = display_loop_start_params,
    display_loop_end_params = display_loop_end_params,
    display_loop_length_params = display_loop_length_params,
    display_loop_segment_params = display_loop_segment_params
}
