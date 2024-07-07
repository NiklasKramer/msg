-- MSG (Modulated Stereo Glut)
-- Granular sampler with LFO modulation. Requires a grid zero and arc.
--

arc_utils = include('lib/arc_utils')
utils = include('lib/utils')

engine.name = 'MSG'
local LFO = require 'lfo'
local lfos = {}

local grid_device = grid.connect()
local arc_device = arc.connect()

-- Arc screen mode
-- local arc_alt_mode = false
local selected_arc = 1
local arc1_params = { "position", "speed", "size", "density" }
local arc2_params = { "volume", "spread", "jitter", "filter" }
local arc3_params = { "filterbank", "saturation", "reverb", "delay" }
local speed_display_values = { 0, 12.5, 25, 50, 100, 200, 400, 800 }


-- Voice and control parameters
local selected_voice = 1
local VOICES = 10
local RECORDER = 16
local STATES = 16
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
local grid_ctl = gridbuf.new(16, 16)
local grid_voc = gridbuf.new(16, 16)

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

-- MIN/MAX values for parameters
local min_size = 1
local max_size = 200
local min_density = 0
local max_density = 200
local min_speed = -800
local max_speed = 800
local min_position = 0
local max_position = 1
local min_filterbank = -60
local max_filterbank = 20
local min_saturation = -60
local max_saturation = 20
local min_reverb = -60
local max_reverb = 20
local min_delay = -60
local max_delay = 20
local min_spread = 0
local max_spread = 100
local min_jitter = 0
local max_jitter = 500
local min_filter = 0
local max_filter = 1
local min_pan = -1
local max_pan = 1
local min_semitones = -36
local max_semitones = 36
local min_octaves = -7
local max_octaves = 7
local min_volume = -60
local max_volume = 20
local min_delay_send = -60
local max_delay_send = 20
local min_filterbank_send = -60
local max_filterbank_send = 20
local min_saturation_send = -60
local max_saturation_send = 20
local min_reverb_send = -60
local max_reverb_send = 20

--state
local state_led_levels = {}
for i = 1, STATES do
  state_led_levels[i] = 0
end


local LFO_TARGETS = {
  SIZE = 1,
  DENSITY = 2,
  POSITION = 3,
  SPEED = 4,
  FILTER = 5,
  VOLUME = 6,
  SPREAD = 7,
  JITTER = 8,
  PAN = 9,
}

local LFO_TARGET_OPTIONS = {
  { "Size",     LFO_TARGETS.SIZE },
  { "Density",  LFO_TARGETS.DENSITY },
  { "Position", LFO_TARGETS.POSITION },
  { "Speed",    LFO_TARGETS.SPEED },
  { "Filter",   LFO_TARGETS.FILTER },
  { "Volume",   LFO_TARGETS.VOLUME },
  { "Spread",   LFO_TARGETS.SPREAD },
  { "Jitter",   LFO_TARGETS.JITTER },
  { "Pan",      LFO_TARGETS.PAN }
}



function init()
  setup_grid_key()
  init_params()
  init_polls()
  setup_recorders()
  init_metros()
  setup_lfos()
  update_lfo_ranges()

  for i = 1, RECORDER do
    local grid_pattern_serialized = params:get("pattern_" .. i .. "_grid")
    local arc_pattern_serialized = params:get("pattern_" .. i .. "_arc")
    load_pattern_from_param(i, grid_pattern_serialized, arc_pattern_serialized)
  end

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
  local current_arc_params = {
    {
      params:get(selected_voice .. arc1_params[1]),
      params:get(selected_voice .. arc1_params[2]),
      params:get(selected_voice .. arc1_params[3]),
      params:get(selected_voice .. arc1_params[4]) },

    {
      params:get(selected_voice .. arc2_params[1]),
      params:get(selected_voice .. arc2_params[2]),
      params:get(selected_voice .. arc2_params[3]),
      params:get(selected_voice .. arc2_params[4]) },

    {
      params:get(selected_voice .. arc3_params[1]),
      params:get(selected_voice .. arc3_params[2]),
      params:get(selected_voice .. arc3_params[3]),
      params:get(selected_voice .. arc3_params[4]) }
  }

  local arc_params = { {}, {}, {} }
  arc_params[selected_arc][n] = current_arc_params[selected_arc][n]

  if record_bank > 0 then
    local current_time = util.time()
    record_prevtime = record_prevtime < 0 and current_time or record_prevtime

    if d ~= 0 then
      local time_delta = current_time - record_prevtime
      table.insert(arc_pattern_banks[record_bank],
        { time_delta, 'arc', arc_params[1], arc_params[2], arc_params[3], selected_voice })
      record_prevtime = current_time
    end
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

  -- Save the updated patterns to params
  save_patterns_to_params()

  -- Reset recording state
  record_bank = -1
  record_prevtime = -1
end


function playback_arc_event(arc1_params, arc2_params, arc3_params, voice)
  if arc1_params[1] ~= nil then params:set(voice .. "position", arc1_params[1]) end
  if arc1_params[2] ~= nil then params:set(voice .. "speed", arc1_params[2]) end
  if arc1_params[3] ~= nil then params:set(voice .. "size", arc1_params[3]) end
  if arc1_params[4] ~= nil then params:set(voice .. "density", arc1_params[4]) end

  if arc2_params[1] ~= nil then params:set(voice .. "volume", arc2_params[1]) end
  if arc2_params[2] ~= nil then params:set(voice .. "spread", arc2_params[2]) end
  if arc2_params[3] ~= nil then params:set(voice .. "jitter", arc2_params[3]) end
  if arc2_params[4] ~= nil then params:set(voice .. "filter", arc2_params[4]) end

  if arc3_params[1] ~= nil then params:set(voice .. "filterbank", arc3_params[1]) end
  if arc3_params[2] ~= nil then params:set(voice .. "saturation", arc3_params[2]) end
  if arc3_params[3] ~= nil then params:set(voice .. "reverb", arc3_params[3]) end
  if arc3_params[4] ~= nil then params:set(voice .. "delay", arc3_params[4]) end
end

local function pattern_next(n)
  local grid_bank = grid_pattern_banks[n]
  local arc_bank = arc_pattern_banks[n]
  local pos = pattern_positions[n]

  local grid_event = grid_bank and grid_bank[pos]
  local arc_event = arc_bank and arc_bank[pos]

  if grid_event then
    local delta, eventType, x, y, z = table.unpack(grid_event)
    if eventType == 'grid' then
      grid_key(x, y, z, true)
    end
  elseif arc_event then
    local delta, eventType, arc1_params, arc2_params, arc3_params, voice = table.unpack(arc_event)
    if eventType == 'arc' then
      playback_arc_event(arc1_params, arc2_params, arc3_params, voice)
    end
  end

  local next_pos = pos + 1
  if next_pos > #grid_bank and next_pos > #arc_bank then
    next_pos = 1
  end
  pattern_positions[n] = next_pos

  local next_delta = 1
  if grid_bank and grid_bank[next_pos] then
    next_delta = grid_bank[next_pos][1]
  elseif arc_bank and arc_bank[next_pos] then
    next_delta = arc_bank[next_pos][1]
  end
  pattern_timers[n]:start(next_delta, 1)
end

local function handle_state_grid(x, z)
  if z == 1 then
    if alt then
      -- Clear state if alt is pressed
      params:set("state_" .. x, "")
      state_led_levels[x] = 0
    else
      local state_serialized = params:get("state_" .. x)
      if state_serialized == "" then
        -- Save state
        save_state(x)
        state_led_levels[x] = 2
      else
        -- Load state
        load_state(x)
        for i = 1, STATES do
          if i == x then
            state_led_levels[i] = 15
          elseif params:get("state_" .. i) ~= "" then
            state_led_levels[i] = 2
          else
            state_led_levels[i] = 0
          end
        end
      end
    end
  end
end

local function record_handler(n)
  if alt then
    -- clear pattern
    if n == record_bank then stop_recording() end
    if pattern_timers[n].is_running then stop_playback(n) end
    grid_pattern_banks[n] = {}
    arc_pattern_banks[n] = {}
    params:set("pattern_" .. n, "{}")
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

function grid_refresh()
  if grid_device == nil then
    return
  end

  grid_ctl:led_level_all(0)
  grid_voc:led_level_all(0)

  grid_ctl:led_level_set(16, 1, alt and 15 or 8)

  for i = 1, VOICES do
    local voice_level = 1
    if gates[i] > 0 then
      voice_level = 4
    end
    if i == selected_voice then
      voice_level = math.floor(swell)
    end
    if i <= 5 then
      grid_ctl:led_level_set(i, 1, voice_level)
    else
      grid_ctl:led_level_set(i - 5, 2, voice_level)
    end
  end

  for i = 1, RECORDER do
    local level = 3
    if #grid_pattern_banks[i] > 0 or #arc_pattern_banks[i] > 0 then
      level = 7
    end
    if pattern_timers[i].is_running then
      level = 15
      if pattern_leds[i] > 0 then
        level = 15
      end
    end
    local row = (i <= 8) and 1 or 2
    local col = ((i - 1) % 8) + 7
    grid_ctl:led_level_set(col, row, level)
  end

  if selected_arc == 1 then
    grid_ctl:led_level_set(16, 2, 1)
  elseif selected_arc == 2 then
    grid_ctl:led_level_set(16, 2, 9)
  elseif selected_arc == 3 then
    grid_ctl:led_level_set(16, 2, 15)
  end

  if record_bank > 0 then
    local row = (record_bank <= 8) and 1 or 2
    local col = ((record_bank - 1) % 8) + 7
    grid_ctl:led_level_set(col, row, 12 * blink)
  end

  for i = 1, VOICES do
    if voice_levels[i] > 0 then
      if i <= 6 then
        grid_voc:led_level_row(1, i + 2, display_voice(positions[i], 16))
      else
        grid_voc:led_level_row(1, (i - 6) + 8, display_voice(positions[i], 16))
      end
    end
  end

  local value
  if alt then
    value = params:get(selected_voice .. "octaves")
  else
    value = params:get(selected_voice .. "semitones")
  end
  for col = 1, 16 do
    local level = 1
    if col == 8 or col == 9 then
      level = 5
    end
    grid_ctl:led_level_set(col, 16, level)
  end
  if value < 0 and value > -8 then
    grid_ctl:led_level_set(value + 8, 16, 15)
  elseif value > 0 and value < 8 then
    grid_ctl:led_level_set(value + 9, 16, 15)
  elseif value == 0 then
    grid_ctl:led_level_set(8, 16, 15)
    grid_ctl:led_level_set(9, 16, 15)
  end

  local speed = params:get(selected_voice .. "speed")
  local max_brightness = 15

  local function calculate_brightness(speed, value)
    if speed == 0 and value == 0 then
      return 2
    end
    local diff = math.abs(speed - value)
    if diff == 0 then
      return max_brightness
    elseif diff < math.abs(speed) then
      return max_brightness - math.floor((diff / math.abs(speed)) * (max_brightness - 1))
    else
      return 0
    end
  end
  for i, value in ipairs(speed_display_values) do
    local col = i + 8
    local level = calculate_brightness(math.abs(speed), value)
    grid_ctl:led_level_set(col, 15, level)
  end
  if math.abs(speed) < 100 then
    grid_ctl:led_level_set(13, 15, 1)
  end
  grid_ctl:led_level_set(9, 15, 1)

  local speed_direction = params:get(selected_voice .. "speed") > 0 and 1 or -1
  grid_ctl:led_level_set(7, 15, speed_direction == -1 and 12 or 5)

  local hold = params:get(selected_voice .. "hold")
  local granular = params:get(selected_voice .. "granular")
  local mute = params:get(selected_voice .. "mute")
  grid_ctl:led_level_set(1, 15, hold == 0 and 12 or 5)
  grid_ctl:led_level_set(2, 15, granular == 0 and 12 or 5)
  grid_ctl:led_level_set(3, 15, mute == 1 and 12 or 5)

  for i = 1, STATES do
    grid_ctl:led_level_set(i, 14, state_led_levels[i])
  end

  local buf = grid_ctl | grid_voc
  buf:render(grid_device)
  grid_device:refresh()
end

function grid_key(x, y, z, skip_record)
  -- Record grid events if necessary
  if (y > 2 and y < 15) and not skip_record then
    record_grid_event(x, y, z)
  end

  if y == 14 then
    handle_state_grid(x, z)
  elseif z == 1 then
    if y > 2 and y < 15 then
      -- Handle voice triggering and positioning
      local voice = y - 2
      local new_position = (x - 1) / 16

      if alt and gates[voice] > 0 then
        -- Stop playback if alt is pressed and the track is playing
        stop_voice(voice)
      else
        -- Start voice with new position
        positions[voice] = new_position
        params:set(voice .. "position", new_position)
        start_voice(voice)
      end
    elseif y == 16 then
      -- Handle semitone changes on the last row
      local semitone_value
      if x > 9 then
        semitone_value = x - 9
      elseif x == 9 or x == 8 then
        semitone_value = 0
      else
        semitone_value = x - 8
      end
      if alt then
        params:set(selected_voice .. "octaves", semitone_value)
      else
        params:set(selected_voice .. "semitones", semitone_value)
      end
    elseif y == 15 then
      if x == 1 then
        -- Toggle hold on/off
        local hold = params:get(selected_voice .. "hold")
        params:set(selected_voice .. "hold", hold == 0 and 1 or 0)
      elseif x == 2 then
        -- Toggle between buffer and granular mode
        local granular = params:get(selected_voice .. "granular")
        params:set(selected_voice .. "granular", granular == 0 and 1 or 0)
      elseif x == 3 then
        -- Toggle mute on/off
        local mute = params:get(selected_voice .. "mute")
        params:set(selected_voice .. "mute", mute == 0 and 1 or 0)
      elseif x == 7 then
        -- Toggle between forward and reverse for speed
        local speed = params:get(selected_voice .. "speed") * -1
        params:set(selected_voice .. "speed", speed)
      else
        -- Handle speed changes
        local index = x - 8
        if index >= 1 and index <= #speed_display_values then
          local speed_value = speed_display_values[index]
          local direction = params:get(selected_voice .. "speed") > 0 and 1 or -1
          params:set(selected_voice .. "speed", speed_value * direction)
        end
      end
    else
      topbar_key(x, y, z)
    end
  else
    if y > 2 and y < 15 then
      -- Stop voice if hold is not active
      local voice = y - 2
      if params:get(voice .. "hold") == 0 then
        stop_voice(voice)
      end
    end

    -- Release alt if necessary
    if x == 16 and y == 1 then
      alt = false
    end
  end

  redraw()
end

function topbar_key(x, y, z)
  if y == 1 or y == 2 then
    if x == 16 and y == 1 then
      -- alt
      alt = z == 1
    elseif x == 16 and y == 2 then
      -- Toggle arc screen mode
      selected_arc = selected_arc + 1
      if selected_arc > 3 then selected_arc = 1 end
    elseif x >= 7 and x <= 14 then
      -- record handler
      local recorder = (x - 7) + 8 * (y - 1) + 1
      record_handler(recorder)
    elseif x <= 5 then
      -- stop, only if alt is not pressed
      if alt then
        local voice = x + 5 * (y - 1)
        --toggle hold for voice
        local hold = params:get(voice .. "hold")
        params:set(voice .. "hold", hold == 0 and 1 or 0)
      else
        selected_voice = x + 5 * (y - 1)
      end
    end
  end
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
  end, 1 / 30)
  metro_swell:start()

  local metro_redraw = metro.init(function(stage) redraw() end, 1 / 5)
  metro_redraw:start()

  local metro_arc_update = metro.init(function(stage)
    update_arc_display()
  end, 1 / 30)
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

  -- Global Parameters
  params:add_separator("SAMPLES ")
  params:add_group("SAMPLES", VOICES)

  for v = 1, VOICES do
    params:add_file(v .. "sample", v .. " sample")
    params:set_action(v .. "sample", function(file) engine.read(v, file) end)
  end

  params:add_separator("Sends")
  params:add_group("SATURATION", 9)

  params:add_taper("saturation_depth", "saturation_depth", 1, 32, 32, 0)
  params:set_action("saturation_depth", function(value) engine.saturation_depth(value) end)

  params:add_taper("saturation_rate", "saturation_rate", 1, 48000, 48000, 0)
  params:set_action("saturation_rate", function(value) engine.saturation_rate(value) end)

  params:add_taper('crossover', 'crossover', 50, 20000, 1400, 0)
  params:set_action('crossover', function(value) engine.saturation_crossover(value) end)

  params:add_taper('dist', 'dist', 1, 500, 15, 0)
  params:set_action('dist', function(value) engine.saturation_dist(value) end)

  params:add_taper('low bias', 'low bias', 0.01, 1, 0.04, 0)
  params:set_action('low bias', function(value) engine.saturation_lowbias(value) end)

  params:add_taper('high bias', 'high bias', 0.01, 1, 0.12, 0)
  params:set_action('high bias', function(value) engine.saturation_highbias(value) end)

  params:add_taper('hiss', 'hiss', 0, 1, 0, 0)
  params:set_action('hiss', function(value) engine.saturation_hiss(value) end)

  params:add_taper('cutoff', 'cutoff', 20, 20000, 11500, 0)
  params:set_action('cutoff', function(value) engine.saturation_cutoff(value) end)

  params:add_taper('output_volume', 'output_volume', 0, 1, 1, 0)
  params:set_action('output_volume', function(value) engine.saturation_volume(value) end)


  params:add_group("DELAY", 9)

  --delay_delay
  params:add_taper('delay_time', 'delay', 0.001, 2, 0.2, 0)
  params:set_action('delay_time', function(value) engine.delay_delay(value) end)

  params:add_taper('delay_feedback', 'delay_feedback', 0.1, 10, 1, 0)
  params:set_action('delay_feedback', function(value) engine.delay_time(value) end)

  params:add_taper('delay_mix', 'delay_mix', 0, 1, 1, 0)
  params:set_action('delay_mix', function(value) engine.delay_mix(value) end)

  --delay_lpf
  params:add_taper('delay_lpf', 'delay_lpf', 20, 20000, 20000, 0)
  params:set_action('delay_lpf', function(value) engine.delay_lpf(value) end)

  --delay_hpf
  params:add_taper('delay_hpf', 'delay_hpf', 20, 20000, 20, 0)
  params:set_action('delay_hpf', function(value) engine.delay_hpf(value) end)

  --delay_w_rate
  params:add_taper('delay_w_rate', 'delay_w_rate', 0.1, 10, 1, 0)
  params:set_action('delay_w_rate', function(value) engine.delay_w_rate(value) end)

  --delay_w_depth
  params:add_taper('delay_w_depth', 'delay_w_depth', 0, 1, 0, 0)
  params:set_action('delay_w_depth', function(value) engine.delay_w_depth(value / 100) end)

  --delay_rotate
  params:add_taper('delay_rotate', 'delay_rotate', 0, 1, 0.5, 0)
  params:set_action('delay_rotate', function(value) engine.delay_rotate(value) end)

  --delay_max_del
  params:add_taper('delay_max_del', 'delay_max_del', 0.0, 10, 1, 0)
  params:set_action('delay_max_del', function(value) engine.delay_max_del(value) end)





  params:add_group("REVERB", 5)

  -- Reverb Parameters
  params:add_taper("reverb_mix", "*" .. sep .. "mix", 0, 100, 100, 0, "%")
  params:set_action("reverb_mix", function(value) engine.reverb_mix(value / 100) end)

  params:add_taper("reverb_time", "*" .. sep .. "time", 0.1, 15, 4, 0, "s")
  params:set_action("reverb_time", function(value) engine.reverb_time(value) end)

  params:add_taper("reverb_lpf", "*" .. sep .. "lpf", 20, 20000, 20000, 0, "hz")
  params:set_action("reverb_lpf", function(value) engine.reverb_lpf(value) end)

  params:add_taper("reverb_hpf", "*" .. sep .. "hpf", 20, 20000, 150, 0, "hz")
  params:set_action("reverb_hpf", function(value) engine.reverb_hpf(value) end)

  params:add_taper("reverb_srate", "*" .. sep .. "srate", 0.1, 10, 1, 0, "s")
  params:set_action("reverb_srate", function(value) engine.reverb_srate(value) end)



  -- Group for Filterbank Parameters
  params:add_group("FILTERBANK", 11)

  -- Filterbank Parameters
  params:add_taper("filterbank_amp", "*" .. sep .. "amp", 0, 1, 1, 0, "")
  params:set_action("filterbank_amp", function(value) engine.filterbank_amp(value) end)

  params:add_taper("filterbank_gate", "*" .. sep .. "gate", 0, 1, 1, 0, "")
  params:set_action("filterbank_gate", function(value) engine.filterbank_gate(value) end)

  params:add_taper("filterbank_spread", "*" .. sep .. "spread", 0, 1, 1, 0, "")
  params:set_action("filterbank_spread", function(value) engine.filterbank_spread(value) end)

  params:add_taper("filterbank_q", "*" .. sep .. "q", 0.0001, 1, 0.1, 0, "")
  params:set_action("filterbank_q", function(value) engine.filterbank_q(value) end)

  params:add_taper("filterbank_modRate", "*" .. sep .. "modRate", 0.1, 10, 0.2, 0, "")
  params:set_action("filterbank_modRate", function(value) engine.filterbank_modRate(value) end)

  params:add_taper("filterbank_depth", "*" .. sep .. "depth", 0, 1, 0.5, 0, "")
  params:set_action("filterbank_depth", function(value) engine.filterbank_depth(value) end)

  params:add_taper("filterbank_qModRate", "*" .. sep .. "qModRate", 0.1, 10, 0.1, 0, "")
  params:set_action("filterbank_qModRate", function(value) engine.filterbank_qModRate(value) end)

  params:add_taper("filterbank_qModDepth", "*" .. sep .. "qModDepth", 0, 1, 0.01, 0, "")
  params:set_action("filterbank_qModDepth", function(value) engine.filterbank_qModDepth(value) end)

  params:add_taper("filterbank_panModRate", "*" .. sep .. "panModRate", 0.1, 10, 0.4, 0, "")
  params:set_action("filterbank_panModRate", function(value) engine.filterbank_panModRate(value) end)

  params:add_taper("filterbank_panModDepth", "*" .. sep .. "panModDepth", 0, 1, 1, 0, "")
  params:set_action("filterbank_panModDepth", function(value) engine.filterbank_panModDepth(value) end)

  params:add_taper("filterbank_wet", "*" .. sep .. "wet", 0, 1, 1, 0, "")
  params:set_action("filterbank_wet", function(value) engine.filterbank_wet(value) end)




  -- Voice Parameters
  for v = 1, VOICES do
    params:add_separator("VOICE " .. v)

    -- Audio Parameters
    params:add_group(v .. " AUDIO", 11)

    params:add_taper(v .. "filter", v .. " filter", 0, 1, 0.5, 0)
    params:set_action(v .. "filter", function(value) engine.filter(v, value) end)

    params:add_taper(v .. "pan", v .. " pan", -1, 1, 0, 0)
    params:set_action(v .. "pan", function(value) engine.pan(v, value) end)

    params:add_binary(v .. "mute", v .. " mute", "toggle", 1)
    params:set_action(v .. "mute", function(value) engine.mute(v, value) end)

    params:add_binary(v .. "play_stop", v .. " play/stop", "toggle", 0)
    params:set_action(v .. "play_stop", function(value)
      if value == 1 then start_voice(v, positions[v]) else stop_voice(v) end
    end)



    params:add_binary(v .. "granular", v .. " granular/buffer", "toggle", 0)
    params:set_action(v .. "granular", function(value) engine.useBufRd(v, value) end)


    params:add_separator("LEVELS/SENDS")

    params:add_taper(v .. "volume", v .. " volume", min_volume, max_volume, 0, 0, "dB")
    params:set_action(v .. "volume", function(value) engine.volume(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "saturation", v .. " saturation", min_saturation_send, max_saturation_send, min_delay_send, 0,
      "dB")
    params:set_action(v .. "saturation", function(value) engine.saturation(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "delay", v .. " delay", min_delay_send, max_delay_send, min_delay_send, 0, "dB")
    params:set_action(v .. "delay", function(value) engine.delay(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "reverb", v .. " reverb", min_reverb_send, max_reverb_send, min_delay_send, 0, "dB")
    params:set_action(v .. "reverb", function(value) engine.reverb(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "filterbank", v .. " filterbank", min_filterbank_send, max_filterbank_send, min_delay_send, 0,
      "dB")
    params:set_action(v .. "filterbank", function(value) engine.filterbank(v, math.pow(10, value / 20)) end)

    -- Granular Parameters
    params:add_group(v .. " GRANULAR", 9)
    params:add {
      type = "control",
      id = v .. "finetune",
      name = v .. ": finetune",
      controlspec = controlspec.new(0, 4, "lin", 0.001, 1, "", 0.001),
      action = function(value)
        engine.finetune(v, value)
      end
    }

    params:add_number(v .. "semitones", v .. sep .. "semitones", min_semitones, max_semitones, 0)
    params:set_action(v .. "semitones", function(value) engine.semitones(v, math.floor(value + 0.5)) end)

    params:add_number(v .. "octaves", v .. sep .. "octaves", min_octaves, max_octaves, 0)
    params:set_action(v .. "octaves", function(value) engine.octaves(v, math.floor(value + 0.5)) end)


    params:add_taper(v .. "speed", v .. sep .. "speed", min_speed, max_speed, 100, 0, "%")
    params:set_action(v .. "speed", function(value)
      local actual_speed = util.clamp(value, min_speed, max_speed)
      engine.speed(v, actual_speed / 100)
    end)



    -- Voice Position
    params:add {
      type = "control",
      id = v .. "position",
      name = v .. sep .. "position",
      controlspec = controlspec.new(0, 1, "lin", 0, 0, ""),
      action = function(value)
        local actual_position = util.clamp(value, 0, 1)
        positions[v] = actual_position
        if gates[v] > 0 then
          engine.seek(v, actual_position)
        end
      end
    }

    params:add_taper(v .. "jitter", v .. sep .. "jitter", min_jitter, max_jitter, 0, 5, "ms")
    params:set_action(v .. "jitter", function(value) engine.jitter(v, value / 1000) end)

    params:add_taper(v .. "size", v .. sep .. "size", min_size, max_size, 100, 5, "ms")
    params:set_action(v .. "size", function(value) engine.size(v, value / 1000) end)

    params:add_taper(v .. "density", v .. sep .. "density", min_density, max_density, 20, 6, "hz")
    params:set_action(v .. "density", function(value) engine.density(v, value) end)

    params:add_taper(v .. "spread", v .. sep .. "spread", 0, 100, 0, 0, "%")
    params:set_action(v .. "spread", function(value) engine.spread(v, value / 100) end)


    params:add_group(v .. " ENV", 5)

    params:add_taper(v .. "fade", v .. sep .. "att / dec", 0, 9000, 1000, 0, "ms")
    params:set_action(v .. "fade", function(value) engine.envscale(v, value / 1000) end)

    params:add_taper(v .. "attack", v .. sep .. "attack", 0, 10, 1, 0)
    params:set_action(v .. "attack", function(value) engine.attack(v, value) end)

    params:add_taper(v .. "sustain", v .. sep .. "sustain", 0, 10, 1, 0)
    params:set_action(v .. "sustain", function(value) engine.sustain(v, value) end)

    params:add_taper(v .. "release", v .. sep .. "release", 0, 10, 1, 0)
    params:set_action(v .. "release", function(value) engine.release(v, value) end)

    -- add param called hold, that can be on or off (0 or 1)
    params:add_binary(v .. "hold", v .. sep .. "hold", "toggle", 1)


    -- LFO Parameters
    for lfo_num = 1, 4 do
      local lfo_id = v .. "_lfo" .. lfo_num

      -- LFO Group
      params:add_group(v .. " LFO " .. lfo_num, 5)

      -- Rate
      params:add_taper(lfo_id .. "_rate", "LFO " .. lfo_num .. " rate", 0.001, 20, 0.5, 0, "Sec")
      params:set_action(lfo_id .. "_rate", function(value)
        lfos[v][lfo_num]:set('period', value)
      end)

      -- Depth
      params:add_taper(lfo_id .. "_depth", "LFO " .. lfo_num .. " depth", 0, 1, 0.5, 0)
      params:set_action(lfo_id .. "_depth", function(value)
        lfos[v][lfo_num]:set('depth', value)
      end)

      -- Enable
      params:add_binary(lfo_id .. "_enable", "LFO " .. lfo_num .. " enable", "toggle", 0)
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

  params:add_separator("")
  params:add_separator('header', 'ARC + General')

  params:add_control("arc_sens_1", "Arc Sensitivity 1", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_2", "Arc Sensitivity 2", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_3", "Arc Sensitivity 3", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))
  params:add_control("arc_sens_4", "Arc Sensitivity 4", controlspec.new(0.01, 2, 'lin', 0.01, 0.2))



  -- HIDDEN params
  for v = 1, VOICES do
    params:add_number(v .. "semitones_precise", v .. sep .. "semitones_precise", min_semitones, max_semitones, 0)
    params:hide(v .. "semitones_precise")
  end

  for i = 1, RECORDER do
    params:add_text("pattern_" .. i .. "_grid", "Pattern " .. i .. " Grid", "")
    params:hide("pattern_" .. i .. "_grid")
    params:add_text("pattern_" .. i .. "_arc", "Pattern " .. i .. " Arc", "")
    params:hide("pattern_" .. i .. "_arc")
    params:set_action("pattern_" .. i .. "_grid", function(value)
      load_pattern_from_param(i, value, params:get("pattern_" .. i .. "_arc"))
    end)
    params:set_action("pattern_" .. i .. "_arc", function(value)
      load_pattern_from_param(i, params:get("pattern_" .. i .. "_grid"), value)
    end)
  end


  for state = 1, 16 do
    params:add_text("state_" .. state, "State " .. state, "")
    params:set_action("state_" .. state, function(value)
      load_state(state)
      if value ~= "" then
        state_led_levels[state] = 2
      else
        state_led_levels[state] = 0
      end
    end)
    params:hide("state_" .. state)
  end
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
function arc_enc_update(n, d)
  if not skip_record then
    record_arc_event(n, d)
  end
  local sensitivity = params:get("arc_sens_" .. n)
  local adjusted_delta = d * sensitivity

  local param_name = ''
  if selected_arc == 1 then
    param_name = arc1_params[n]
  elseif selected_arc == 2 then
    param_name = arc2_params[n]
  elseif selected_arc == 3 then
    param_name = arc3_params[n]
  else
    return
  end

  -- position is a special case
  if not param_name then return end
  local param_id = selected_voice .. param_name

  if param_name == "position" then
    local newPosition = positions[selected_voice] + (adjusted_delta / 100)
    newPosition = newPosition % 1
    positions[selected_voice] = newPosition
    params:set(param_id, newPosition)
  elseif param_name == "semitones" then
    -- local semitones = params:get(param_id)
    local semitones_precise = params:get(selected_voice .. "semitones_precise")
    semitones_precise = semitones_precise + adjusted_delta
    params:set(selected_voice .. "semitones_precise", semitones_precise)
    params:set(param_id, math.floor(semitones_precise))
  else
    params:delta(param_id, adjusted_delta)
  end

  redraw()
end

function update_arc_display()
  if selected_arc == 1 then
    -- Original arc display logic
    local position = positions[selected_voice]
    local speed = params:get(selected_voice .. "speed")
    local size = params:get(selected_voice .. "size")
    local density = params:get(selected_voice .. "density")

    local position_angle = arc_utils.scale_angle(position, 1)
    arc_device:segment(1, position_angle, position_angle + 0.2, 15)

    arc_utils.display_progress_bar(arc_device, 2, speed, min_speed, max_speed)
    arc_utils.display_percent_markers(arc_device, 2, -100, 0, 100)
    arc_utils.display_progress_bar(arc_device, 3, size, min_size, max_size)
    arc_utils.display_progress_bar(arc_device, 4, density, min_density, max_density)
  elseif selected_arc == 2 then
    -- Display parameters for arc screen mode
    local volume = params:get(selected_voice .. "volume")
    local spread = params:get(selected_voice .. "spread")
    local jitter = params:get(selected_voice .. "jitter")
    local filter = params:get(selected_voice .. "filter")

    arc_utils.display_progress_bar(arc_device, 1, volume, min_volume, max_volume)
    arc_utils.display_spread_pattern(arc_device, 2, spread, 0, max_spread) -- Update arc for spread
    arc_utils.display_random_pattern(arc_device, 3, jitter, 0, max_jitter)
    arc_utils.display_filter_pattern(arc_device, 4, filter, 0, max_filter)
  elseif selected_arc == 3 then
    -- Display parameters for arc screen mode
    local filterbank = params:get(selected_voice .. "filterbank")
    local saturation = params:get(selected_voice .. "saturation")
    local reverb = params:get(selected_voice .. "reverb")
    local delay = params:get(selected_voice .. "delay")

    arc_utils.display_progress_bar(arc_device, 1, filterbank, min_filterbank, max_filterbank)
    arc_utils.display_progress_bar(arc_device, 2, saturation, min_saturation, max_saturation)
    arc_utils.display_progress_bar(arc_device, 3, reverb, min_reverb, max_reverb)
    arc_utils.display_progress_bar(arc_device, 4, delay, min_delay, max_delay)
  end

  arc_device:refresh()
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
      -- Adjusting 'filter' instead of 'volume'
      params:delta(selected_voice .. "filter", d)
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
      -- Adjusting 'volume' here since it's now paired with 'filter'
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
  local track_number_x = 0
  local track_number_y = 20
  screen.move(track_number_x, track_number_y)
  screen.level(gates[selected_voice] > 0 and 15 or 2)
  screen.font_size(24)
  screen.text(string.format(selected_voice))
  screen.font_size(8)

  -- Underline the track number if hold is off
  if params:get(selected_voice .. "hold") == 0 then
    local underline_start_x = track_number_x
    local underline_end_x = track_number_x + 30
    local underline_y = track_number_y + 4
    screen.move(underline_start_x, underline_y)
    screen.line(underline_end_x, underline_y)
    screen.close()
    screen.stroke()
  end

  local hold_state_y = track_number_y + 20

  -- Display Granular/Buffer mode with graphical representation
  local mode_y = hold_state_y
  screen.level(15)
  if params:get(selected_voice .. "granular") == 0 then
    -- Draw particles for Granular mode
    for i = 1, 10 do
      local x = track_number_x + math.random(0, 10)
      local y = mode_y + math.random(-10, 10)
      screen.pixel(x, y)
    end
    screen.fill()
  end

  -- Display Mute state with graphical representation
  local mute_state_y = mode_y + 18
  local mute_state_x = track_number_x + 1
  local mute_box_size = 10
  screen.move(mute_state_x, mute_state_y)
  screen.level(2)
  screen.rect(mute_state_x, mute_state_y, mute_box_size, mute_box_size / 2)
  screen.stroke()
  if params:get(selected_voice .. "mute") == 1 then
    screen.level(12)
    screen.rect(mute_state_x, mute_state_y, mute_box_size - 1, mute_box_size / 2 - 1)
    screen.fill()
  end

  -- Set the start position for parameter display
  local param_y_start = 10
  local param_x_start = 50
  local line_spacing = 10

  -- First pair: Filter and Volume
  screen.move(param_x_start, param_y_start)
  screen.level(current_screen == 1 and 15 or 2)
  screen.text("Filter: " .. string.format("%.2f", params:get(selected_voice .. "filter")))

  screen.move(param_x_start, param_y_start + line_spacing)
  screen.level(current_screen == 1 and 15 or 2)
  screen.text("Volume: " .. string.format("%.2f dB", params:get(selected_voice .. "volume")))

  -- Second pair: Size and Density
  screen.move(param_x_start, param_y_start + 2 * line_spacing)
  screen.level(current_screen == 2 and 15 or 2)
  screen.text("Size: " .. string.format("%.2f ms", params:get(selected_voice .. "size")))

  screen.move(param_x_start, param_y_start + 3 * line_spacing)
  screen.level(current_screen == 2 and 15 or 2)
  screen.text("Density: " .. string.format("%.2f Hz", params:get(selected_voice .. "density")))

  -- Third pair: Position and Speed
  screen.move(param_x_start, param_y_start + 4 * line_spacing)
  screen.level(current_screen == 3 and 15 or 2)
  screen.text("Position: " .. string.format("%.2f", positions[selected_voice]))

  screen.move(param_x_start, param_y_start + 5 * line_spacing)
  screen.level(current_screen == 3 and 15 or 2)
  screen.text("Speed: " .. string.format("%.2f%%", params:get(selected_voice .. "speed")))

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
      elseif target == LFO_TARGETS.PAN then
        lfos[v][lfo_num]:set('min', min_pan)
        lfos[v][lfo_num]:set('max', max_pan)
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
  elseif target == LFO_TARGETS.PAN then
    params:set(voice .. "pan", scaled)
  end
end

function cleanup()
  for v = 1, VOICES do
    lfos[v]:stop()
  end
end

-- Function to save patterns to params
function save_patterns_to_params()
  for i = 1, RECORDER do
    local grid_pattern_serialized = utils.serialize_table(grid_pattern_banks[i])
    local arc_pattern_serialized = utils.serialize_table(arc_pattern_banks[i])
    params:set("pattern_" .. i .. "_grid", grid_pattern_serialized)
    params:set("pattern_" .. i .. "_arc", arc_pattern_serialized)
  end
end

-- Function to load patterns from params
function load_pattern_from_param(n, grid_serialized, arc_serialized)
  if grid_serialized ~= "" then
    grid_pattern_banks[n] = utils.deserialize_table(grid_serialized)
  else
    grid_pattern_banks[n] = {}
  end

  if arc_serialized ~= "" then
    arc_pattern_banks[n] = utils.deserialize_table(arc_serialized)
  else
    arc_pattern_banks[n] = {}
  end
end

-- Function to save a state
function save_state(state)
  local state_table = {}
  for voice = 1, VOICES do
    state_table[voice] = gather_voice_params(voice)
  end
  local serialized = utils.serialize_table(state_table)
  params:set("state_" .. state, serialized)
end

-- Function to load a state
function load_state(state)
  print("Loading state ")
  local serialized = params:get("state_" .. state)
  if serialized ~= "" then
    local state_table = utils.deserialize_table(serialized)
    if state_table then
      for voice = 1, VOICES do
        set_voice_params(voice, state_table[voice])
      end
      grid_refresh() -- Call grid_refresh to update the grid after loading the state
    end
  end
end

function gather_voice_params(voice)
  return {
    sample = params:get(voice .. "sample"),
    filter = params:get(voice .. "filter"),
    pan = params:get(voice .. "pan"),
    -- play_stop = params:get(voice .. "play_stop"),
    granular = params:get(voice .. "granular"),
    volume = params:get(voice .. "volume"),
    saturation = params:get(voice .. "saturation"),
    delay = params:get(voice .. "delay"),
    reverb = params:get(voice .. "reverb"),
    filterbank = params:get(voice .. "filterbank"),
    finetune = params:get(voice .. "finetune"),
    semitones = params:get(voice .. "semitones"),
    speed = params:get(voice .. "speed"),
    -- position = params:get(voice .. "position"),
    jitter = params:get(voice .. "jitter"),
    size = params:get(voice .. "size"),
    density = params:get(voice .. "density"),
    spread = params:get(voice .. "spread"),
    fade = params:get(voice .. "fade"),
    attack = params:get(voice .. "attack"),
    sustain = params:get(voice .. "sustain"),
    release = params:get(voice .. "release"),
    -- hold = params:get(voice .. "hold")
  }
end

-- Function to set all voice parameters from a table
function set_voice_params(voice, params_table)
  params:set(voice .. "sample", params_table.sample)
  params:set(voice .. "filter", params_table.filter)
  params:set(voice .. "pan", params_table.pan)
  -- params:set(voice .. "play_stop", params_table.play_stop)
  params:set(voice .. "granular", params_table.granular)
  params:set(voice .. "volume", params_table.volume)
  params:set(voice .. "saturation", params_table.saturation)
  params:set(voice .. "delay", params_table.delay)
  params:set(voice .. "reverb", params_table.reverb)
  params:set(voice .. "filterbank", params_table.filterbank)
  params:set(voice .. "finetune", params_table.finetune)
  params:set(voice .. "semitones", params_table.semitones)
  params:set(voice .. "speed", params_table.speed)
  -- params:set(voice .. "position", params_table.position)
  params:set(voice .. "jitter", params_table.jitter)
  params:set(voice .. "size", params_table.size)
  params:set(voice .. "density", params_table.density)
  params:set(voice .. "spread", params_table.spread)
  params:set(voice .. "fade", params_table.fade)
  params:set(voice .. "attack", params_table.attack)
  params:set(voice .. "sustain", params_table.sustain)
  params:set(voice .. "release", params_table.release)
  -- params:set(voice .. "hold", params_table.hold)
end
