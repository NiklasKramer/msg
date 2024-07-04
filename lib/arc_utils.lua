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
}
