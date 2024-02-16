-- MSG (Modulated Stereo Glut)
-- Granular sampler with LFO modulation. Requires a grid.
--
-- Key Controls:
-- Grid rows 2-8: Trigger and
-- control voices.
-- Grid row 1: Record and
-- playback patterns.
-- Encoders: Adjust parameters.
-- Enc 1: Select voice.
-- Key 2: Toggle play/stop for
-- selected voice.
-- Key 3: Change screen.

-- Engine and device connections
engine.name = 'StereoGlut'
local LFO = require 'lfo'
local lfos = {}

local grid_device = grid.connect()
local arc_device = arc.connect()

-- Arc screen mode
local arc_alt_mode = false
local regular_params = { "position", "speed", "size", "density" }
local alt_params = { "volume", "spread", "jitter", "filter" }

-- Voice and control parameters
local selected_voice = 1
local VOICES = 7
local RECORDER = 6
local current_screen = 1

-- Voice state tracking
local positions = {}
local gates = {}
local voice_levels = {}
for i = 1, VOICES do
  positions[i] = -1
  gates[i] = 0
  voice_levels[i] = 0
end

-- Grid display buffers
local gridbuf = require 'lib/gridbuf'
local grid_ctl = gridbuf.new(16, 8)
local grid_voc = gridbuf.new(16, 8)

-- Metronome (metro) instances
local metro_grid_refresh
local metro_blink
local metro_swell

-- Recording and playback
local grid_pattern_banks = {}
local arc_pattern_banks = {}
local pattern_timers = {}
local pattern_leds = {}      -- for displaying button presses
local pattern_positions = {} -- playback positions
local record_bank = -1
local record_prevtime = -1
local alt = false
local blink = 0

-- Visual effect variables
local swell = 0
local swell_direction = 1

-- LFO configuration
local min_size = 1
local max_size = 500
local min_density = 0
local max_density = 20
local min_speed = -100
local max_speed = 100
local min_position = 0
local max_position = 1
local min_volume = -60
local max_volume = 20
local min_spread = 0
local max_spread = 100
local min_jitter = 0
local max_jitter = 500
local min_filter = 0
local max_filter = 1

local previous_regular_params = {}
local previous_alt_params = {}

local LFO_TARGETS = {
  SIZE = 1,
  DENSITY = 2,
  POSITION = 3,
  SPEED = 4,
  FILTER = 5,
  VOLUME = 6,
  SPREAD = 7,
  JITTER = 8
}

local LFO_TARGET_OPTIONS = {
  { "Size",     LFO_TARGETS.SIZE },
  { "Density",  LFO_TARGETS.DENSITY },
  { "Position", LFO_TARGETS.POSITION },
  { "Speed",    LFO_TARGETS.SPEED },
  { "Filter",   LFO_TARGETS.FILTER },
  { "Volume",   LFO_TARGETS.VOLUME },
  { "Spread",   LFO_TARGETS.SPREAD },
  { "Jitter",   LFO_TARGETS.JITTER }
}

for i = 1, VOICES do
  previous_regular_params[i] = { nil, nil, nil, nil }
  previous_alt_params[i] = { nil, nil, nil, nil }
end


function init()
  setup_grid_key()
  init_params()
  init_polls()
  setup_recorders()
  init_metros()
  setup_lfos()
  update_lfo_ranges()

  params:bang()
end

function add_lfo_target_param(voice, lfo_num)
  local options = {}
  for i, option in ipairs(LFO_TARGET_OPTIONS) do
    table.insert(options, option[1])
  end

  local param_id = voice .. "_lfo" .. lfo_num .. "_target"
  params:add_option(param_id, "LFO " .. lfo_num .. " Target", options, 1)
  params:set_action(param_id, function(value)
    update_lfo_ranges()
  end)
end

local function record_grid_event(x, y, z)
  if record_bank > 0 then
    local current_time = util.time()
    if record_prevtime < 0 then
      record_prevtime = current_time
    end

    local time_delta = current_time - record_prevtime
    table.insert(grid_pattern_banks[record_bank], { time_delta, 'grid', x, y, z })
    record_prevtime = current_time
  end
end


local function record_arc_event(n, d)
  -- Current parameter values
  local current_regular_params = {
    params:get(selected_voice .. "position"),
    params:get(selected_voice .. "speed"),
    params:get(selected_voice .. "size"),
    params:get(selected_voice .. "density")
  }

  local current_alt_params = {
    params:get(selected_voice .. "volume"),
    params:get(selected_voice .. "spread"),
    params:get(selected_voice .. "jitter"),
    params:get(selected_voice .. "filter")
  }

  local regular_params = {}
  local alt_params = {}

  -- Update the parameters based on the encoder used
  if n == 1 and arc_alt_mode == false then
    regular_params[1] = current_regular_params[1] -- position
  elseif n == 2 and arc_alt_mode == false then
    regular_params[2] = current_regular_params[2] -- speed
  elseif n == 3 and arc_alt_mode == false then
    regular_params[3] = current_regular_params[3] -- size
  elseif n == 4 and arc_alt_mode == false then
    regular_params[4] = current_regular_params[4] -- density
  elseif n == 1 and arc_alt_mode == true then
    alt_params[1] = current_alt_params[1]         -- volume
  elseif n == 2 and arc_alt_mode == true then
    alt_params[2] = current_alt_params[2]         -- spread
  elseif n == 3 and arc_alt_mode == true then
    alt_params[3] = current_alt_params[3]         -- jitter
  elseif n == 4 and arc_alt_mode == true then
    alt_params[4] = current_alt_params[4]         -- filter
  end

  -- Record the event
  if record_bank > 0 then
    local current_time = util.time()
    if record_prevtime < 0 then
      record_prevtime = current_time
    end

    local time_delta = current_time - record_prevtime

    if d ~= 0 then
      table.insert(arc_pattern_banks[record_bank], { time_delta, 'arc', regular_params, alt_params, selected_voice })
    end
    record_prevtime = current_time
  end
end




local function start_playback(n)
  pattern_timers[n]:start(0.001, 1) -- TODO: timer doesn't start immediately with zero
end

local function stop_playback(n)
  pattern_timers[n]:stop()
  pattern_positions[n] = 1
end

local function arm_recording(n)
  record_bank = n
end

-- Function to update the final delta time and initiate playback
local function update_delta_and_start_playback(pattern_bank, current_time)
  local final_delta = current_time - record_prevtime
  pattern_bank[record_bank][1][1] = final_delta
  start_playback(record_bank)
end


local function stop_recording()
  local recorded_grid_events = #grid_pattern_banks[record_bank]
  local recorded_arc_events = #arc_pattern_banks[record_bank]
  local current_time = util.time()

  -- Validate record_bank
  if record_bank < 1 or record_bank > #grid_pattern_banks then
    error("Invalid record bank")
  end

  -- Handle grid and arc events
  if recorded_grid_events > 0 then
    update_delta_and_start_playback(grid_pattern_banks, current_time)
  elseif recorded_arc_events > 0 then
    update_delta_and_start_playback(arc_pattern_banks, current_time)
  end

  -- Reset recording state
  record_bank = -1
  record_prevtime = -1

  -- reset all voices
  -- for v in VOICES do
  --   previous_regular_params[v] = { nil, nil, nil, nil }
  --   previous_alt_params[v] = { nil, nil, nil, nil }
  -- end
end


function playback_arc_event(regular_params, alt_params, voice)
  -- Regular Params
  if regular_params[1] ~= nil then params:set(voice .. "position", regular_params[1]) end
  if regular_params[2] ~= nil then params:set(voice .. "speed", regular_params[2]) end
  if regular_params[3] ~= nil then params:set(voice .. "size", regular_params[3]) end
  if regular_params[4] ~= nil then params:set(voice .. "density", regular_params[4]) end

  -- Alt Params
  if alt_params[1] ~= nil then params:set(voice .. "volume", alt_params[1]) end
  if alt_params[2] ~= nil then params:set(voice .. "spread", alt_params[2]) end
  if alt_params[3] ~= nil then params:set(voice .. "jitter", alt_params[3]) end
  if alt_params[4] ~= nil then params:set(voice .. "filter", alt_params[4]) end
end

local function pattern_next(n)
  local grid_bank = grid_pattern_banks[n]
  local arc_bank = arc_pattern_banks[n]
  local pos = pattern_positions[n]

  local grid_event = grid_bank and grid_bank[pos]
  local arc_event = arc_bank and arc_bank[pos]

  -- Determine which event type is present at the current position
  if grid_event then
    local delta, eventType, x, y, z = table.unpack(grid_event)
    -- Handle grid event
    if eventType == 'grid' then
      grid_key(x, y, z, true)
    end
  elseif arc_event then
    local delta, eventType, regular_params, alt_params, voice = table.unpack(arc_event)
    playback_arc_event(regular_params, alt_params, voice)
  end



  -- Update pattern position and schedule the next event
  local next_pos = pos + 1
  if next_pos > #grid_bank and next_pos > #arc_bank then
    next_pos = 1
  end
  pattern_positions[n] = next_pos

  -- Find the next delta time, considering both grid and arc banks
  local next_delta = 1
  if grid_bank and grid_bank[next_pos] then
    next_delta = grid_bank[next_pos][1]
  elseif arc_bank and arc_bank[next_pos] then
    next_delta = arc_bank[next_pos][1]
  end
  pattern_timers[n]:start(next_delta, 1)
end


local function record_handler(n)
  if alt then
    -- clear pattern
    if n == record_bank then stop_recording() end
    if pattern_timers[n].is_running then stop_playback(n) end
    grid_pattern_banks[n] = {}
    arc_pattern_banks[n] = {}
    do return end
  end

  if n == record_bank then
    -- stop if pressed current recording
    stop_recording()
  else
    local grid_pattern = grid_pattern_banks[n]
    local arc_parrern = arc_pattern_banks[n]

    if #grid_pattern > 0 then
      -- toggle playback if there's data
      if pattern_timers[n].is_running then stop_playback(n) else start_playback(n) end
    elseif #arc_parrern > 0 then
      -- toggle playback if there's data
      if pattern_timers[n].is_running then stop_playback(n) else start_playback(n) end
    else
      -- stop recording if it's happening
      if record_bank > 0 then
        stop_recording()
      end
      -- arm new pattern for recording
      arm_recording(n)
    end
  end
end

local function display_voice(phase, width)
  local pos = phase * width

  local levels = {}
  for i = 1, width do levels[i] = 0 end

  local left = math.floor(pos)
  local index_left = left + 1
  local dist_left = math.abs(pos - left)

  local right = math.floor(pos + 1)
  local index_right = right + 1
  local dist_right = math.abs(pos - right)

  if index_left < 1 then index_left = width end
  if index_left > width then index_left = 1 end

  if index_right < 1 then index_right = width end
  if index_right > width then index_right = 1 end

  levels[index_left] = math.floor(math.abs(1 - dist_left) * 15)
  levels[index_right] = math.floor(math.abs(1 - dist_right) * 15)

  return levels
end

local function start_voice(voice)
  local pos = positions[voice] -- Get the position from the positions array
  engine.seek(voice, pos)
  engine.gate(voice, 1)
  gates[voice] = 1
  params:set(voice .. "play_stop", 1) -- Update the play/stop parameter
  arc_dirty = true
  -- No need to update the position parameter here since we are using its current value
end

local function stop_voice(voice)
  gates[voice] = 0
  engine.gate(voice, 0)
  params:set(voice .. "play_stop", 0) -- Update the parameter to reflect the voice state
  arc_dirty = true
end

local function grid_refresh()
  if grid_device == nil then
    return
  end

  grid_ctl:led_level_all(0)
  grid_voc:led_level_all(0)

  -- alt
  grid_ctl:led_level_set(16, 1, alt and 15 or 1)

  -- Voice controls
  for i = 1, VOICES do
    local voice_level = 2 -- Default soft lighting for unselected voices
    if gates[i] > 0 then
      voice_level = 8     -- Set level to 8 for running voices
    end

    if i == selected_voice then
      voice_level = math.floor(swell) -- Apply swell effect when any voice is playing
    end

    grid_ctl:led_level_set(i, 1, voice_level)
  end

  -- Recorder controls
  for i = 1, RECORDER do
    local level = 2 -- Default level for recorders

    if #grid_pattern_banks[i] > 0 then level = 5 end
    if #arc_pattern_banks[i] > 0 then level = 5 end
    if pattern_timers[i].is_running then
      level = 10

      if pattern_leds[i] > 0 then
        level = 12
      end
    end

    grid_ctl:led_level_set(i + 8, 1, level) -- Adjusted to start from the 9th column
  end

  if arc_alt_mode then
    grid_ctl:led_level_set(15, 1, 5)
  end

  -- blink armed pattern
  if record_bank > 0 then
    grid_ctl:led_level_set(8 + record_bank, 1, 10 * blink)
  end

  -- voice positions
  for i = 1, VOICES do
    if voice_levels[i] > 0 then
      grid_voc:led_level_row(1, i + 1, display_voice(positions[i], 16))
    end
  end

  local buf = grid_ctl | grid_voc
  buf:render(grid_device)
  grid_device:refresh()
end

function grid_key(x, y, z, skip_record)
  if y > 1 or (y == 1 and x < 9) then
    if not skip_record then
      record_grid_event(x, y, z)
    end
  end

  if z > 0 then
    if y > 1 then
      local voice = y - 1
      local new_position = (x - 1) / 16

      if alt and gates[voice] > 0 then
        -- Stop playback of the track if alt is pressed and the track is playing
        stop_voice(voice)
      else
        -- Start voice with new position
        positions[voice] = new_position               -- Update the position in the array
        params:set(voice .. "position", new_position) -- Update the position parameter
        start_voice(voice)
      end
    else
      if x == 16 then
        -- alt
        alt = true
      elseif x == 15 then
        -- Toggle arc screen mode
        arc_alt_mode = not arc_alt_mode
      elseif x > 8 and x < 15 then
        -- record handler
        record_handler(x - 8)
      elseif x == 8 then
        -- reserved
      elseif x < 8 then
        -- stop, only if alt is not pressed
        if alt then
          local voice = x
          stop_voice(voice)
        else
          -- select voice
          selected_voice = x
        end
      end
    end
  else
    -- release alt
    if x == 16 and y == 1 then alt = false end
  end
  redraw()
end

function setup_grid_key()
  grid_device.key = function(x, y, z)
    grid_key(x, y, z)
  end
  arc_device.delta = function(n, d)
    arc_enc_update(n, d)
  end
end

-- INIT
function init_polls()
  for v = 1, VOICES do
    local phase_poll = poll.set('phase_' .. v, function(pos)
      if gates[v] > 0 then
        positions[v] = pos
      end
    end)
    phase_poll.time = 0.05
    phase_poll:start()

    local level_poll = poll.set('level_' .. v, function(lvl) voice_levels[v] = lvl end)
    level_poll.time = 0.05
    level_poll:start()
  end
end

function init_metros()
  -- grid refresh timer, 40 fps
  metro_grid_refresh = metro.init(function(stage) grid_refresh() end, 1 / 40)
  metro_grid_refresh:start()

  metro_blink = metro.init(function(stage) blink = blink ~ 1 end, 1 / 4)
  metro_blink:start()

  metro_swell = metro.init(function(stage)
    swell = swell + swell_direction * 0.5
    if swell > 15 then
      swell = 15
      swell_direction = -1
    elseif swell < 3 then
      swell = 3
      swell_direction = 1
    end
  end, 1 / 40)
  metro_swell:start()

  local metro_redraw = metro.init(function(stage) redraw() end, 1 / 15)
  metro_redraw:start()

  local metro_arc_update = metro.init(function(stage)
    update_arc_display()
  end, 1 / 120)
  metro_arc_update:start()
end

function setup_recorders()
  for v = 1, RECORDER do
    table.insert(pattern_timers, metro.init(
      function(tick)
        pattern_next(v)
      end))
    table.insert(grid_pattern_banks, {})
    table.insert(arc_pattern_banks, {})
    table.insert(pattern_leds, 0)
    table.insert(pattern_positions, 1)
  end
end

function init_params()
  local sep = ": "



  -- Audio and Granular Parameters
  for v = 1, VOICES do
    params:add_separator("VOICE " .. v)

    -- Audio Parameters
    params:add_group(v .. " AUDIO", 4)

    params:add_file(v .. "sample", v .. " sample")
    params:set_action(v .. "sample", function(file) engine.read(v, file) end)

    params:add_taper(v .. "volume", v .. " volume", -60, 20, 0, 0, "dB")
    params:set_action(v .. "volume", function(value) engine.volume(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "filter", v .. " filter", 0, 1, 0.5, 0)
    params:set_action(v .. "filter", function(value) engine.filter(v, value) end)

    params:add_binary(v .. "play_stop", v .. " Play/Stop", "toggle", 0)
    params:set_action(v .. "play_stop", function(value)
      if value == 1 then start_voice(v, positions[v]) else stop_voice(v) end
    end)

    -- Granular Parameters
    params:add_group(v .. " GRANULAR", 8)
    params:add_taper(v .. "speed", v .. sep .. "speed", -200, 200, 100, 0, "%")
    params:set_action(v .. "speed", function(value)
      local actual_speed = util.clamp(value, min_speed, max_speed)
      engine.speed(v, actual_speed / 100)
    end)

    params:add_taper(v .. "jitter", v .. sep .. "jitter", 0, 500, 0, 5, "ms")
    params:set_action(v .. "jitter", function(value) engine.jitter(v, value / 1000) end)

    params:add_taper(v .. "size", v .. sep .. "size", 1, 500, 100, 5, "ms")
    params:set_action(v .. "size", function(value)
      local actual_size = util.clamp(value, min_size, max_size)
      engine.size(v, actual_size / 1000)
    end)

    params:add_taper(v .. "density", v .. sep .. "density", 0, 20, 20, 6, "hz")
    params:set_action(v .. "density", function(value)
      local actual_density = util.clamp(value, min_density, max_density)
      engine.density(v, actual_density)
    end)



    params:add {
      type = "control",
      id = v .. "pitch",
      name = v .. "pitch",
      controlspec = controlspec.new(0, 4, "lin", 0.001, 1, "", 0.001),
      action = function(value)
        engine.pitch(v, value)
      end
    }

    params:add_taper(v .. "spread", v .. sep .. "spread", 0, 100, 0, 0, "%")
    params:set_action(v .. "spread", function(value) engine.spread(v, value / 100) end)

    params:add_taper(v .. "fade", v .. sep .. "att / dec", 1, 9000, 1000, 3, "ms")
    params:set_action(v .. "fade", function(value) engine.envscale(v, value / 1000) end)

    -- Voice Position
    params:add {
      type = "control",
      id = v .. "position",
      name = v .. " Position",
      controlspec = controlspec.new(0, 1, "lin", 0, 0, ""),
      action = function(value)
        local actual_position = util.clamp(value, 0, 1)
        positions[v] = actual_position
        if gates[v] > 0 then
          engine.seek(v, actual_position)
        end
      end
    }

    for lfo_num = 1, 4 do
      local lfo_id = v .. "_lfo" .. lfo_num

      -- LFO Group
      params:add_group(v .. " LFO " .. lfo_num, 5)

      -- Rate
      params:add_taper(lfo_id .. "_rate", "LFO " .. lfo_num .. " Rate", 0.001, 20, 0.5, 0, "Sec")
      params:set_action(lfo_id .. "_rate", function(value)
        lfos[v][lfo_num]:set('period', value)
      end)

      -- Depth
      params:add_taper(lfo_id .. "_depth", "LFO " .. lfo_num .. " Depth", 0, 1, 0.5, 0)
      params:set_action(lfo_id .. "_depth", function(value)
        lfos[v][lfo_num]:set('depth', value)
      end)

      -- Enable
      params:add_binary(lfo_id .. "_enable", "LFO " .. lfo_num .. " Enable", "toggle", 0)
      params:set_action(lfo_id .. "_enable", function(value)
        if value == 1 then lfos[v][lfo_num]:start() else lfos[v][lfo_num]:stop() end
      end)

      add_lfo_target_param(v, lfo_num)





      -- Offset
      params:add_taper(lfo_id .. "_offset", "LFO " .. lfo_num .. " Offset", -1, 1, 0, 0)
      params:set_action(lfo_id .. "_offset", function(value)
        lfos[v][lfo_num]:set('offset', value)
      end)
    end
  end


  -- Reverb Parameters
  params:add_separator("")
  params:add_separator("VERB")
  params:add_taper("reverb_mix", "*" .. sep .. "mix", 0, 100, 50, 0, "%")
  params:set_action("reverb_mix", function(value) engine.reverb_mix(value / 100) end)
  params:add_taper("reverb_room", "*" .. sep .. "room", 0, 100, 50, 0, "%")
  params:set_action("reverb_room", function(value) engine.reverb_room(value / 100) end)
  params:add_taper("reverb_damp", "*" .. sep .. "damp", 0, 100, 50, 0, "%")
  params:set_action("reverb_damp", function(value) engine.reverb_damp(value / 100) end)

  params:add_separator("")
  params:add_separator('header', 'ARC + General')

  params:add_control("arc_sens_1", "Arc Sensitivity 1", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_2", "Arc Sensitivity 2", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_3", "Arc Sensitivity 3", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_4", "Arc Sensitivity 4", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
end

function add_lfo_target_param(voice, lfo_num)
  local options = {}
  for i, option in ipairs(LFO_TARGET_OPTIONS) do
    table.insert(options, option[1])
  end

  local param_id = voice .. "_lfo" .. lfo_num .. "_target"
  params:add_option(param_id, "LFO " .. lfo_num .. " Target", options, 1)
  params:set_action(param_id, function(value)
    update_lfo_ranges()
  end)
end

-- ARC
function update_arc_display()
  if arc_alt_mode then
    -- Display parameters for arc screen mode
    local volume = params:get(selected_voice .. "volume")
    local spread = params:get(selected_voice .. "spread")
    local jitter = params:get(selected_voice .. "jitter")
    local filter = params:get(selected_voice .. "filter")

    display_progress_bar(1, volume, -60, 20)
    display_spread_pattern(2, spread, 0, 100) -- Update arc for spread
    display_random_pattern(3, jitter, 0, 500)
    display_filter_pattern(4, filter, 0, 1)
  else
    -- Original arc display logic
    local position = positions[selected_voice]
    local speed = params:get(selected_voice .. "speed")
    local size = params:get(selected_voice .. "size")
    local density = params:get(selected_voice .. "density")

    local position_angle = scale_angle(position, 1)
    arc_device:segment(1, position_angle, position_angle + 0.2, 15)

    -- Display speed parameter with markers
    -- Display speed parameter with markers
    display_progress_bar(2, speed, -200, 200)
    display_percent_markers(2, -100, 0, 100)


    display_progress_bar(3, size, 1, 500)
    display_progress_bar(4, density, 0, 20)
  end

  arc_device:refresh()
end

function display_percent_markers(encoder, ...)
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

function display_spread_pattern(encoder, value, min, max)
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

function display_progress_bar(encoder, value, min, max)
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

function display_filter_pattern(encoder, value, min, max)
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

function display_rotating_pattern(encoder, value, min, max)
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

function display_stepped_pattern(encoder, value, min, max, steps)
  local leds_per_step = 64 / steps
  local step = math.floor((value - min) / (max - min) * (steps - 1)) + 1

  if leds_per_step % 1 ~= 0 then
    arc_device:led(encoder, 1, 8)
  end

  for s = 1, steps do
    local start_led = math.floor((s - 1) * leds_per_step) + 1
    local end_led = math.floor(s * leds_per_step)

    for led = start_led, end_led do
      if s == step then
        arc_device:led(encoder, led, 12)
      else
        arc_device:led(encoder, led, 2)
      end
    end

    if start_led > 1 then
      arc_device:led(encoder, start_led - 1, 8)
    end
    if end_led < 64 then
      arc_device:led(encoder, end_led + 1, 8)
    end
  end

  if leds_per_step % 1 ~= 0 or steps * leds_per_step < 64 then
    arc_device:led(encoder, 64, 8)
  end
end

function display_random_pattern(encoder, value, min, max)
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

function display_exponential_pattern(encoder, value, min, max)
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

function normalize_param_value(value, min, max)
  local range = max - min
  return math.floor(((value - min) / range) * 64)
end

function scale_angle(value, scale)
  local angle = value * 2 * math.pi
  if math.abs(value - scale) < 0.0001 then -- Allow for a tiny margin of error
    angle = angle - 0.0001                 -- Subtract a tiny value to avoid reaching 2 * pi
  end
  return angle
end

function arc_enc_update(n, d)
  if not skip_record then
    record_arc_event(n, d)
  end
  local sensitivity = params:get("arc_sens_" .. n)
  local adjusted_delta = d * sensitivity
  local snap_threshold = 1

  local param_name = arc_alt_mode and alt_params[n] or regular_params[n]
  if not param_name then return end

  local param_id = selected_voice .. param_name

  if n == 2 then
    local new_value = params:get(param_id) + adjusted_delta
    if math.abs(new_value) < snap_threshold then
      new_value = 0
    end
    params:set(param_id, new_value)
  elseif param_name == "position" then
    local newPosition = positions[selected_voice] + (adjusted_delta / 100)
    newPosition = newPosition % 1
    positions[selected_voice] = newPosition
    params:set(param_id, newPosition)
  else
    params:delta(param_id, adjusted_delta)
  end

  redraw()
end

-- ENCODERS AND KEYS
function enc(n, d)
  if n == 1 then
    -- Change the selected voice
    selected_voice = util.clamp(selected_voice + d, 1, VOICES)
    arc_dirty = true
  elseif n == 2 then
    -- Parameter adjustments based on the current screen
    if current_screen == 1 then
      -- Adjusting 'jitter' instead of 'volume'
      params:delta(selected_voice .. "jitter", d)
    elseif current_screen == 2 then
      params:delta(selected_voice .. "size", d)
    elseif current_screen == 3 then
      -- Wrapping around for position
      local newPosition = positions[selected_voice] + (d / 100)
      if newPosition > 1 then
        newPosition = 0
      elseif newPosition < 0 then
        newPosition = 1
      end
      positions[selected_voice] = newPosition
      params:set(selected_voice .. "position", newPosition)
    end
  elseif n == 3 then
    if current_screen == 1 then
      -- Adjusting 'volume' here since it's now paired with 'jitter'
      params:delta(selected_voice .. "volume", d)
    elseif current_screen == 2 then
      params:delta(selected_voice .. "density", d)
    elseif current_screen == 3 then
      params:delta(selected_voice .. "speed", d)
    end
  end
  redraw()
end

function key(n, z)
  if n == 3 and z == 1 then
    -- Toggle the screen
    current_screen = (current_screen % 3) + 1
    redraw()
  elseif n == 2 and z == 1 then
    -- Toggle play/stop for the selected voice
    if gates[selected_voice] > 0 then
      stop_voice(selected_voice)
    else
      start_voice(selected_voice)
    end
  end
end

function redraw()
  screen.clear()

  -- Display selected track number at the top with large font
  screen.move(10, 20)
  screen.level(gates[selected_voice] > 0 and 15 or 2)
  screen.font_size(24)
  screen.text_right(selected_voice)
  screen.font_size(8)

  -- Set the start position for parameter display
  local param_y_start = 10
  local line_spacing = 10

  -- First pair: Jitter and Volume
  screen.move(96, param_y_start)
  screen.level(current_screen == 1 and 15 or 2)
  screen.text_right("Jitter: " .. string.format("%.2f ms", params:get(selected_voice .. "jitter")))

  screen.move(96, param_y_start + line_spacing)
  screen.level(current_screen == 1 and 15 or 2)
  screen.text_right("Volume: " .. string.format("%.2f dB", params:get(selected_voice .. "volume")))

  -- Second pair: Size and Density
  screen.move(96, param_y_start + 2 * line_spacing)
  screen.level(current_screen == 2 and 15 or 2)
  screen.text_right("Size: " .. string.format("%.2f ms", params:get(selected_voice .. "size")))

  screen.move(96, param_y_start + 3 * line_spacing)
  screen.level(current_screen == 2 and 15 or 2)
  screen.text_right("Density: " .. string.format("%.2f Hz", params:get(selected_voice .. "density")))

  -- Third pair: Position and Speed
  screen.move(96, param_y_start + 4 * line_spacing)
  screen.level(current_screen == 3 and 15 or 2)
  screen.text_right("Position: " .. string.format("%.2f", positions[selected_voice]))

  screen.move(96, param_y_start + 5 * line_spacing)
  screen.level(current_screen == 3 and 15 or 2)
  screen.text_right("Speed: " .. string.format("%.2f%%", params:get(selected_voice .. "speed")))

  -- Vertical track line and position indicator
  local trackLineX = 120
  local trackLineLength = 60
  local trackLineYStart = 2
  local trackLineYEnd = trackLineYStart + trackLineLength
  screen.level(2)
  screen.move(trackLineX, trackLineYStart)
  screen.line(trackLineX, trackLineYEnd)
  screen.stroke()

  -- Display position indicator only if the track is playing
  screen.level(15)
  if gates[selected_voice] > 0 then
    local position = positions[selected_voice]
    if position >= 0 then
      local positionY = trackLineYStart + (trackLineLength * position)
      screen.circle(trackLineX, positionY, 2)
      screen.fill()
    end
  end

  screen.update()
end

-- Setup LFOs for each voice
function setup_lfos()
  for v = 1, VOICES do
    lfos[v] = {}
    for lfo_num = 1, 4 do
      local lfo = LFO:new()
      lfo:set('shape', 'sine')
      lfo:set('min', 0) -- Default values, will be overridden later
      lfo:set('max', 1)
      lfo:set('mode', 'free')
      lfo:set('depth', params:get(v .. "_lfo" .. lfo_num .. "_depth"))
      lfo:set('period', params:get(v .. "_lfo" .. lfo_num .. "_rate"))
      lfo:set('action', function(scaled) lfo_action(v, lfo_num, scaled) end)
      lfo:start()

      lfos[v][lfo_num] = lfo
    end
  end
end

function update_lfo_ranges()
  for v = 1, VOICES do
    for lfo_num = 1, 2 do
      local target = params:get(v .. "_lfo" .. lfo_num .. "_target")
      if target == LFO_TARGETS.SIZE then
        lfos[v][lfo_num]:set('min', min_size)
        lfos[v][lfo_num]:set('max', max_size)
      elseif target == LFO_TARGETS.DENSITY then
        lfos[v][lfo_num]:set('min', min_density)
        lfos[v][lfo_num]:set('max', max_density)
      elseif target == LFO_TARGETS.POSITION then
        lfos[v][lfo_num]:set('min', min_position)
        lfos[v][lfo_num]:set('max', max_position)
      elseif target == LFO_TARGETS.SPEED then
        lfos[v][lfo_num]:set('min', min_speed)
        lfos[v][lfo_num]:set('max', max_speed)
      elseif target == LFO_TARGETS.VOLUME then
        lfos[v][lfo_num]:set('min', min_volume)
        lfos[v][lfo_num]:set('max', max_volume)
      elseif target == LFO_TARGETS.FILTER then
        lfos[v][lfo_num]:set('min', min_filter)
        lfos[v][lfo_num]:set('max', max_filter)
      elseif target == LFO_TARGETS.SPREAD then
        lfos[v][lfo_num]:set('min', min_spread)
        lfos[v][lfo_num]:set('max', max_spread)
      elseif target == LFO_TARGETS.JITTER then
        lfos[v][lfo_num]:set('min', min_jitter)
        lfos[v][lfo_num]:set('max', max_jitter)
      end
    end
  end
end

-- LFO Action Function
function lfo_action(voice, lfo_num, scaled)
  local target = params:get(voice .. "_lfo" .. lfo_num .. "_target")

  if target == LFO_TARGETS.SIZE then
    params:set(voice .. "size", scaled)
  elseif target == LFO_TARGETS.DENSITY then
    params:set(voice .. "density", scaled)
  elseif target == LFO_TARGETS.POSITION then
    params:set(voice .. "position", scaled)
  elseif target == LFO_TARGETS.SPEED then
    params:set(voice .. "speed", scaled)
  elseif target == LFO_TARGETS.FILTER then
    params:set(voice .. "filter", scaled)
  elseif target == LFO_TARGETS.VOLUME then
    params:set(voice .. "volume", scaled)
  elseif target == LFO_TARGETS.SPREAD then
    params:set(voice .. "spread", scaled)
  elseif target == LFO_TARGETS.JITTER then
    params:set(voice .. "jitter", scaled)
  end
end

function cleanup()
  for v = 1, VOICES do
    lfos[v]:stop()
  end
end
