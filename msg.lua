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

-- Global screen mode variable
local screen_mode = 1
local total_screens = 5
local screen_mode_b = false

-- Global variable to keep track of selected parameter index for each screen
local selected_param = { 1, 1, 1, 1, 1 }
local loop_keys = {}


-- Voice and control parameters
local selected_voice = 1
local VOICES = 8
local RECORDER = 18
local STATES = 16
local current_screen = 1

-- Parameter lists for each screen
local audio_params = { selected_voice .. "volume", selected_voice .. "pan", selected_voice .. "filterbank",
  selected_voice ..
  "saturation", selected_voice .. "reverb", selected_voice .. "delay" }
local filterbank_params = { "filterbank_q", "filterbank_reverb", "filterbank_delay", "filterbank_saturation" }
local saturation_params = { "saturation_depth", "saturation_rate", "crossover", "dist", "cutoff" }
local delay_params = { "delay_time", "delay_feedback", "delay_lpf", "delay_hpf", "delay_w_depth" }
local reverb_params = { "reverb_mix", "reverb_time", "reverb_lpf", "reverb_hpf", "reverb_srate" }

-- grid rows
local control_row = 15
local semitone_row = 16
local state_row = 14
local voices_start_row = 3  -- This assumes voices start from row 3, adjust as needed
local top_row = 1           -- The top row, often used for special controls like `alt`
local arc_selection_row = 2 -- Row for selecting arc modes
local recorder_row_1 = 1    -- First row for recorders
local recorder_row_2 = 2    -- Second row for recorders
local number_of_rows = 16   -- Number of rows on the grid




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

function init_grid_rows()
  local rows = utils.check_grid_device(grid_device)
  if rows == 8 then
    control_row = 7
    semitone_row = 8
    state_row = 6
    VOICES = 4
    number_of_rows = 8
  elseif rows == 16 then
    control_row = 15
    semitone_row = 16
    state_row = 14
    VOICES = 8
    number_of_rows = 16
  end
end

function init()
  init_grid_rows()
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
    local action_type = nil
    if y == control_row and x > 5 and z == 1 then
      action_type = 'control' -- Use a specific action type for the control row
    elseif y == semitone_row and alt then
      print("semitone row")
      action_type = 'octaves'
    elseif y == semitone_row then
      action_type = 'semitone'
    else
      action_type = 'grid'
    end

    table.insert(grid_pattern_banks[record_bank], { time_delta, action_type, x, y, z, selected_voice })
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

local function playback_grid_event(event)
  local delta, eventType, x, y, z, voice = table.unpack(event)

  if eventType == 'grid' then
    grid_key(x, y, z, true)
  elseif eventType == 'control' then
    -- Handle control actions based on the recorded voice and action
    local original_voice = selected_voice
    selected_voice = voice
    print("direction", params:get(selected_voice .. "direction"))
    if y == control_row then
      if x == 1 then
        local hold = params:get(selected_voice .. "hold")
        params:set(selected_voice .. "hold", hold == 0 and 1 or 0)
      elseif x == 2 then
        local granular = params:get(selected_voice .. "granular")
        params:set(selected_voice .. "granular", granular == 0 and 1 or 0)
      elseif x == 3 then
        local mute = params:get(selected_voice .. "mute")
        params:set(selected_voice .. "mute", mute == 0 and 1 or 0)
      elseif x == 5 then
        local record = params:get(selected_voice .. "record")
        params:set(selected_voice .. "record", record == 0 and 1 or 0)
      elseif x == 7 then
        local direction = params:get(selected_voice .. "direction") * -1
        params:set(selected_voice .. "direction", direction)
      else
        local index = x - 8
        if index >= 1 and index <= #speed_display_values then
          local speed_value = speed_display_values[index]
          params:set(selected_voice .. "speed", speed_value)
        end
      end
    end
    selected_voice = original_voice
  elseif eventType == 'semitone' then
    local original_voice = selected_voice
    selected_voice = voice
    local semitone_value
    if x > 9 then
      semitone_value = x - 9
    elseif x == 9 or x == 8 then
      semitone_value = 0
    else
      semitone_value = x - 8
    end

    params:set(selected_voice .. "semitones", semitone_value)
    selected_voice = original_voice
  elseif eventType == 'octaves' then
    local original_voice = selected_voice
    selected_voice = voice
    local octave_value
    if x > 9 then
      octave_value = x - 9
    elseif x == 9 or x == 8 then
      octave_value = 0
    else
      octave_value = x - 8
    end
    params:set(selected_voice .. "octaves", octave_value)
    selected_voice = original_voice
  end
end


local function pattern_next(n)
  local grid_bank = grid_pattern_banks[n]
  local arc_bank = arc_pattern_banks[n]
  local pos = pattern_positions[n]

  local grid_event = grid_bank and grid_bank[pos]
  local arc_event = arc_bank and arc_bank[pos]

  if grid_event then
    playback_grid_event(grid_event)
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

  -- Indicator for alt mode in top right corner
  grid_ctl:led_level_set(16, top_row, alt and 15 or 8)

  -- Low brightness for loop area
  local loop_brightness = 3

  for i = 1, VOICES do
    local voice_level = 1
    if gates[i] > 0 then
      voice_level = 4
    end
    if i == selected_voice then
      voice_level = math.floor(swell)
    end

    -- Set voice indicators on top rows
    if i <= 4 then
      grid_ctl:led_level_set(i, voices_start_row - 2, voice_level)
    else
      grid_ctl:led_level_set(i - 4, voices_start_row - 1, voice_level)
    end

    -- Loop area display: only if loop is on for this voice
    if params:get(i .. "loop_on") == 1 then
      local loop_start = params:get(i .. "loop_start") * 16 + 1
      local loop_end = params:get(i .. "loop_end") * 16 + 1
      local loop_row = voices_start_row - 1 + i

      -- Illuminate loop area
      for col = math.floor(loop_start), math.floor(loop_end) do
        grid_ctl:led_level_set(col, loop_row, loop_brightness)
      end
    end
  end

  -- Recorder state and LED updates
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
    local row = (i <= 9) and recorder_row_1 or recorder_row_2
    local col = ((i - 1) % 9) + 6
    grid_ctl:led_level_set(col, row, level)
  end

  -- Arc selection indicator
  if selected_arc == 1 then
    grid_ctl:led_level_set(16, arc_selection_row, 1)
  elseif selected_arc == 2 then
    grid_ctl:led_level_set(16, arc_selection_row, 9)
  elseif selected_arc == 3 then
    grid_ctl:led_level_set(16, arc_selection_row, 15)
  end

  -- Blink indicator for recording bank
  if record_bank > 0 then
    local row = (record_bank <= 9) and recorder_row_1 or recorder_row_2
    local col = ((record_bank - 1) % 9) + 6
    grid_ctl:led_level_set(col, row, 12 * blink)
  end

  -- Voice level display
  for i = 1, VOICES do
    if voice_levels[i] > 0 then
      grid_voc:led_level_row(1, i + voices_start_row - 1, display_voice(positions[i], 16))
    end
  end

  -- Semitone and octave row display
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
    grid_ctl:led_level_set(col, semitone_row, level)
  end
  if value < 0 and value > -8 then
    grid_ctl:led_level_set(value + 8, semitone_row, 15)
  elseif value > 0 and value < 8 then
    grid_ctl:led_level_set(value + 9, semitone_row, 15)
  elseif value == 0 then
    grid_ctl:led_level_set(8, semitone_row, 15)
    grid_ctl:led_level_set(9, semitone_row, 15)
  end

  -- Speed display in control row
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
    grid_ctl:led_level_set(col, control_row, level)
  end
  if math.abs(speed) < 100 then
    grid_ctl:led_level_set(13, control_row, 1)
  end
  grid_ctl:led_level_set(9, control_row, 1)

  -- Direction, hold, granular, mute, record indicators in control row
  local direction = params:get(selected_voice .. "direction") >= 0 and 1 or -1
  grid_ctl:led_level_set(7, control_row, direction == -1 and 15 or 8)

  local hold = params:get(selected_voice .. "hold")
  local granular = params:get(selected_voice .. "granular")
  local mute = params:get(selected_voice .. "mute")
  local record = params:get(selected_voice .. "record")
  grid_ctl:led_level_set(1, control_row, hold == 0 and 12 or 5)
  grid_ctl:led_level_set(2, control_row, granular == 0 and 12 or 5)
  grid_ctl:led_level_set(3, control_row, mute == 1 and 12 or 5)
  grid_ctl:led_level_set(5, control_row, record == 1 and 15 or 2)

  -- Render and refresh the grid
  local buf = grid_ctl | grid_voc
  buf:render(grid_device)
  grid_device:refresh()
end

-- Table to store the keys pressed in each row for loop detection
local loop_keys = {}

function grid_key(x, y, z, skip_record)
  -- Check if we're within the voice rows (for loop functionality)
  if y >= voices_start_row and y < control_row then
    local voice = y - (voices_start_row - 1)

    -- Handle key press (z == 1)
    if z == 1 then
      -- Initialize loop_keys for the voice if needed
      if not loop_keys[voice] then
        loop_keys[voice] = {}
      end

      -- Add key position to loop_keys table
      table.insert(loop_keys[voice], x)

      -- If exactly two keys are pressed and held simultaneously
      if #loop_keys[voice] == 2 then
        -- Sort keys to determine start and end
        table.sort(loop_keys[voice])
        local start_key, end_key = loop_keys[voice][1] - 1, loop_keys[voice][2] - 1

        -- Set loop points
        params:set(voice .. "loop_start", start_key / 16)
        params:set(voice .. "loop_end", end_key / 16)
        params:set(voice .. "loop_on", 1)
      end
    elseif z == 0 then
      -- Handle key release
      for i, pos in ipairs(loop_keys[voice] or {}) do
        if pos == x then
          table.remove(loop_keys[voice], i)
          break
        end
      end

      -- Clear loop if fewer than two keys are pressed
      if #loop_keys[voice] < 2 then
        params:set(voice .. "loop_on", 0)
      end
    end
  end

  -- Original behavior: Record grid events if not skipped
  if (y >= voices_start_row and y <= number_of_rows) and not skip_record then
    record_grid_event(x, y, z)
  end

  -- Original behavior for voice triggering and position setting
  if z == 1 then
    if y >= voices_start_row and y < control_row then
      local voice = y - (voices_start_row - 1)
      local new_position = (x - 1) / 16

      -- If alt is pressed and voice is playing, stop it
      if alt and gates[voice] > 0 then
        stop_voice(voice)
      else
        -- Set the position and start the voice
        positions[voice] = new_position
        params:set(voice .. "position", new_position)
        start_voice(voice)
      end
    elseif y == semitone_row then
      -- Handle semitone adjustments
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
    elseif y == control_row then
      -- Handle control adjustments
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
      elseif x == 5 then
        -- Toggle record on/off
        local record = params:get(selected_voice .. "record")
        params:set(selected_voice .. "record", record == 0 and 1 or 0)
      elseif x == 7 then
        -- Toggle direction (forward/reverse)
        local direction = params:get(selected_voice .. "direction")
        params:set(selected_voice .. "direction", direction == 1 and -1 or 1)
      else
        -- Speed control
        local index = x - 8
        if index >= 1 and index <= #speed_display_values then
          local speed_value = speed_display_values[index]
          local direction = params:get(selected_voice .. "speed") > 0 and 1 or -1
          params:set(selected_voice .. "speed", speed_value * direction)
        end
      end
    else
      -- Topbar and arc selection handling
      topbar_key(x, y, z)
    end
  else
    if y >= voices_start_row and y < control_row then
      -- Stop voice if hold is not active
      local voice = y - (voices_start_row - 1)
      if params:get(voice .. "hold") == 0 then
        stop_voice(voice)
      end
    end

    -- Release alt mode if necessary
    if x == 16 and y == top_row then
      alt = false
    end
  end

  -- Refresh screen for any updates
  redraw()
end

function topbar_key(x, y, z)
  if y == top_row or y == arc_selection_row then
    if x == 16 and y == top_row then
      -- alt
      alt = z == 1
    elseif x == 16 and y == arc_selection_row then
      -- Toggle arc screen mode
      selected_arc = selected_arc + 1
      if selected_arc > 3 then selected_arc = 1 end
    elseif x >= 6 and x <= 14 then
      -- record handler
      local recorder = (x - 6) + 9 * (y - 1) + 1
      record_handler(recorder)
    elseif x <= (VOICES <= 4 and 4 or 8) then
      -- stop, only if alt is not pressed
      if alt then
        local voice = x + 4 * (y - 1)
        -- toggle hold for voice
        local hold = params:get(voice .. "hold")
        params:set(voice .. "hold", hold == 0 and 1 or 0)
      else
        -- adjust voice selection depending on the number of voices
        if VOICES <= 4 then
          selected_voice = x
        else
          selected_voice = x + 4 * (y - 1)
        end
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
    phase_poll.time = 0.03
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

--INIT PARAMS
function init_params()
  init_sample_params()
  init_buffers_for_voice()
  params:add_separator("FX")
  init_saturation_params()
  init_delay_params()
  init_reverb_params()
  init_filterbank_params()
  init_voice_params()
  init_global_and_hidden_params()
end

function init_sample_params()
  params:add_separator("SAMPLES")
  params:add_group("SAMPLES", VOICES)

  for v = 1, VOICES do
    params:add_file(v .. "sample", v .. " Sample")
    params:set_action(v .. "sample", function(file) engine.read(v, file) end)
  end
end

function init_buffers_for_voice()
  params:add_group("SELECT BUFFER", VOICES)

  for v = 1, VOICES do
    params:add_number(v .. "selected_buffer", v .. " buffer", 1, VOICES, v)
    params:set_action(v .. "selected_buffer", function(value) engine.set_buffer_for_voice(v, value) end)
  end
end

function init_saturation_params()
  params:add_group("SATURATION", 9)

  params:add_taper("saturation_depth", "Saturation Depth", 1, 32, 32, 0)
  params:set_action("saturation_depth", function(value) engine.saturation_depth(value) end)

  params:add_taper("saturation_rate", "Saturation Rate", 1, 48000, 48000, 0)
  params:set_action("saturation_rate", function(value) engine.saturation_rate(value) end)

  params:add_taper('crossover', 'Crossover', 50, 20000, 1400, 0)
  params:set_action('crossover', function(value) engine.saturation_crossover(value) end)

  params:add_taper('dist', 'Distortian', 1, 500, 15, 0)
  params:set_action('dist', function(value) engine.saturation_dist(value) end)

  params:add_taper('low bias', 'Low Bias', 0.01, 1, 0.04, 0)
  params:set_action('low bias', function(value) engine.saturation_lowbias(value) end)

  params:add_taper('high bias', 'High Bias', 0.01, 1, 0.12, 0)
  params:set_action('high bias', function(value) engine.saturation_highbias(value) end)

  params:add_taper('hiss', 'Hiss', 0, 1, 0, 0)
  params:set_action('hiss', function(value) engine.saturation_hiss(value) end)

  params:add_taper('cutoff', 'Cutoff', 20, 20000, 11500, 0)
  params:set_action('cutoff', function(value) engine.saturation_cutoff(value) end)

  params:add_taper('output_volume', 'Output Volume', 0, 1, 1, 0)
  params:set_action('output_volume', function(value) engine.saturation_volume(value) end)
end

function init_delay_params()
  params:add_group("DELAY", 9)

  params:add_taper('delay_time', 'Delay Time', 0.001, 2, 0.2, 0)
  params:set_action('delay_time', function(value) engine.delay_delay(value) end)

  params:add_taper('delay_feedback', 'Delay Feedback', 0.1, 10, 1, 0)
  params:set_action('delay_feedback', function(value) engine.delay_time(value) end)

  params:add_taper('delay_mix', 'Delay Mix', 0, 1, 1, 0)
  params:set_action('delay_mix', function(value) engine.delay_mix(value) end)

  params:add_taper('delay_lpf', 'Delay Low-pass Filter', 20, 20000, 20000, 0)
  params:set_action('delay_lpf', function(value) engine.delay_lpf(value) end)

  params:add_taper('delay_hpf', 'Delay High-pass Filter', 20, 20000, 20, 0)
  params:set_action('delay_hpf', function(value) engine.delay_hpf(value) end)

  params:add_taper('delay_w_rate', 'Delay Warble Rate', 0.1, 10, 1, 0)
  params:set_action('delay_w_rate', function(value) engine.delay_w_rate(value) end)

  params:add_taper('delay_w_depth', 'Delay Warble Depth', 0, 1, 0, 0)
  params:set_action('delay_w_depth', function(value) engine.delay_w_depth(value / 100) end)

  params:add_taper('delay_rotate', 'Delay Rotate', 0, 1, 0.5, 0)
  params:set_action('delay_rotate', function(value) engine.delay_rotate(value) end)

  params:add_taper('delay_max_del', 'Max Delay Time', 0.0, 10, 1, 0)
  params:set_action('delay_max_del', function(value) engine.delay_max_del(value) end)
end

function init_reverb_params()
  params:add_group("REVERB", 5)

  params:add_taper("reverb_mix", "Reverb Mix", 0, 100, 100, 0, "%")
  params:set_action("reverb_mix", function(value) engine.reverb_mix(value / 100) end)

  params:add_taper("reverb_time", "Reverb Time", 0.1, 15, 4, 0, "s")
  params:set_action("reverb_time", function(value) engine.reverb_time(value) end)

  params:add_taper("reverb_lpf", "Reverb LPF", 20, 20000, 20000, 0, "hz")
  params:set_action("reverb_lpf", function(value) engine.reverb_lpf(value) end)

  params:add_taper("reverb_hpf", "Reverb HPF", 20, 20000, 150, 0, "hz")
  params:set_action("reverb_hpf", function(value) engine.reverb_hpf(value) end)

  params:add_taper("reverb_srate", "Reverb Rate", 0.1, 10, 1, 0, "s")
  params:set_action("reverb_srate", function(value) engine.reverb_srate(value) end)
end

function init_filterbank_params()
  params:add_group("FILTERBANK", 14)

  params:add_taper("filterbank_amp", "Filterbank Amp", 0, 1, 1, 0, "")
  params:set_action("filterbank_amp", function(value) engine.filterbank_amp(value) end)

  params:add_taper("filterbank_gate", "Filterbank Gate", 0, 1, 1, 0, "")
  params:set_action("filterbank_gate", function(value) engine.filterbank_gate(value) end)

  params:add_taper("filterbank_spread", "Filterbank Spread", 0, 1, 1, 0, "")
  params:set_action("filterbank_spread", function(value) engine.filterbank_spread(value) end)

  params:add_taper("filterbank_q", "Filterbank Q", 0.0001, 1, 0.1, 0, "")
  params:set_action("filterbank_q", function(value) engine.filterbank_q(value) end)

  params:add_taper("filterbank_modRate", "Filterbank Modulation Rate", 0.1, 10, 0.2, 0, "")
  params:set_action("filterbank_modRate", function(value) engine.filterbank_modRate(value) end)

  params:add_taper("filterbank_depth", "Filterbank Depth", 0, 1, 0.5, 0, "")
  params:set_action("filterbank_depth", function(value) engine.filterbank_depth(value) end)

  params:add_taper("filterbank_qModRate", "Filterbank Q Modulation Rate", 0.1, 10, 0.1, 0, "")
  params:set_action("filterbank_qModRate", function(value) engine.filterbank_qModRate(value) end)

  params:add_taper("filterbank_qModDepth", "Filterbank Q Modulation Depth", 0, 1, 0.01, 0, "")
  params:set_action("filterbank_qModDepth", function(value) engine.filterbank_qModDepth(value) end)

  params:add_taper("filterbank_panModRate", "Filterbank Pan Modulation Rate", 0.1, 10, 0.4, 0, "")
  params:set_action("filterbank_panModRate", function(value) engine.filterbank_panModRate(value) end)

  params:add_taper("filterbank_panModDepth", "Filterbank Pan Modulation Depth", 0, 1, 1, 0, "")
  params:set_action("filterbank_panModDepth", function(value) engine.filterbank_panModDepth(value) end)

  params:add_taper("filterbank_wet", "Filterbank Wet Level", 0, 1, 1, 0, "")
  params:set_action("filterbank_wet", function(value) engine.filterbank_wet(value) end)

  params:add_taper("filterbank_reverb", "Filterbank Reverb Send", 0, 1, 0, 0, "")
  params:set_action("filterbank_reverb", function(value) engine.filterbank_reverb_level(value) end)

  params:add_taper("filterbank_delay", "Filterbank Delay Send", 0, 1, 0, 0, "")
  params:set_action("filterbank_delay", function(value) engine.filterbank_delay_level(value) end)

  params:add_taper("filterbank_saturation", "Filterbank Saturation Send", 0, 1, 0, 0, "")
  params:set_action("filterbank_saturation", function(value) engine.filterbank_saturation_level(value) end)
end

function init_global_and_hidden_params()
  params:add_separator("")
  params:add_separator('header', 'ARC + General')

  params:add_control("arc_sens_1", "Arc Sensitivity 1", controlspec.new(0.01, 2, 'lin', 0.01, 0.05))
  params:add_control("arc_sens_2", "Arc Sensitivity 2", controlspec.new(0.01, 2, 'lin', 0.01, 0.05))
  params:add_control("arc_sens_3", "Arc Sensitivity 3", controlspec.new(0.01, 2, 'lin', 0.01, 0.05))
  params:add_control("arc_sens_4", "Arc Sensitivity 4", controlspec.new(0.01, 2, 'lin', 0.01, 0.05))

  -- Hidden params
  for v = 1, VOICES do
    params:add_number(v .. "semitones_precise", v .. ": semitones_precise", min_semitones, max_semitones, 0)
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

-- INIT BASIC VOICE PARAMS
function init_voice_params()
  for v = 1, VOICES do
    params:add_separator("VOICE " .. v)
    params:add_group("AUDIO", 36)

    init_playback_control_params(v)
    init_level_and_send_params(v)
    init_basic_voice_params(v)
    init_granular_params(v)
    init_env_and_lfo_params(v)
  end
end

function init_basic_voice_params(v)
  params:add_separator("PITCH/PLAYBACK")

  params:add_number(v .. "semitones", "Semitones", min_semitones, max_semitones, 0)
  params:set_action(v .. "semitones", function(value) engine.semitones(v, math.floor(value + 0.5)) end)

  params:add_number(v .. "octaves", "Octaves", min_octaves, max_octaves, 0)
  params:set_action(v .. "octaves", function(value) engine.octaves(v, math.floor(value + 0.5)) end)

  params:add_taper(v .. "glide", "Glide", 0, 1, 0.001, 0)
  params:set_action(v .. "glide", function(value) engine.lagtime(v, value) end)

  params:add {
    type = "control",
    id = v .. "finetune",
    name = "Finetune",
    controlspec = controlspec.new(0, 4, "lin", 0.001, 1, "", 0.001),
    action = function(value) engine.finetune(v, value) end
  }

  params:add_taper(v .. "speed", "Speed", min_speed, max_speed, 100, 0, "%")
  params:set_action(v .. "speed", function(value)
    local actual_speed = util.clamp(value, min_speed, max_speed)
    engine.speed(v, actual_speed / 100)
  end)

  params:add_number(v .. "direction", "Direction", -1, 1, 1)
  params:set_action(v .. "direction", function(value) engine.direction(v, value) end)

  params:add {
    type = "control",
    id = v .. "position",
    name = "Position",
    controlspec = controlspec.new(0, 1, "lin", 0, 0, ""),
    action = function(value)
      local actual_position = util.clamp(value, 0, 1)
      positions[v] = actual_position
      if gates[v] > 0 then
        engine.seek(v, actual_position)
      end
    end
  }

  params:add_binary(v .. "clicky", "Clicky", "toggle", 0)
  params:set_action(v .. "clicky", function(value) engine.clicky(v, value) end)
end

function init_playback_control_params(v)
  params:add_separator("PLAYBACK CONTROL")

  params:add_binary(v .. "play_stop", "Play/Stop", "toggle", 0)
  params:set_action(v .. "play_stop", function(value)
    if value == 1 then start_voice(v, positions[v]) else stop_voice(v) end
  end)

  params:add_binary(v .. "record", "Record", "toggle", 0)
  params:set_action(v .. "record", function(value)
    params:set(v .. "granular", 1)
    engine.record(v, value)
  end)

  params:add_binary(v .. "mute", "Mute", "toggle", 1)
  params:set_action(v .. "mute", function(value) engine.mute(v, value) end)

  params:add_binary(v .. "granular", "Granular/Buffer", "toggle", 0)
  params:set_action(v .. "granular", function(value) engine.useBufRd(v, value) end)

  params:add_separator("BUFFER LENGTH")

  params:add_taper(v .. "buffer_length", "Buffer Length", 0.1, 60, 5, 0.1)

  params:add_binary(v .. "update_buffer_length", "Update Buffer Length")
  params:set_action(v .. "update_buffer_length", function()
    engine.buffer_length(v, params:get(v .. "buffer_length"))
  end)

  params:add_binary(v .. "save_buffer", "Save Buffer")
  params:set_action(v .. "save_buffer", function()
    local timestamp = os.date("%Y%m%d%H%M%S")
    local filepath = '/home/we/dust/audio/MSG/' .. timestamp .. 'buffer_' .. v .. '.wav'
    engine.save_buffer(v, filepath)
    params:set(v .. "sample", filepath)
  end)

  params:add_separator("LOOPING")

  params:add_binary(v .. "loop_on", "Loop On", "toggle", 0)
  params:set_action(v .. "loop_on", function(value)
    if value == 0 then
      engine.loop_start(v, 0)
      engine.loop_end(v, 1)
    else
      engine.loop_start(v, params:get(v .. "loop_start"))
      engine.loop_end(v, params:get(v .. "loop_end"))
    end
  end)

  params:add_taper(v .. "loop_start", "Loop Start", 0, 1, 0, 0)
  params:set_action(v .. "loop_start", function(value) engine.loop_start(v, value) end)

  params:add_taper(v .. "loop_end", "Loop End", 0, 1, 1, 0)
  params:set_action(v .. "loop_end", function(value) engine.loop_end(v, value) end)
end

function init_level_and_send_params(v)
  params:add_separator("LEVELS/FX/SENDS")

  params:add_taper(v .. "volume", "Volume", min_volume, max_volume, 0, 0, "dB")
  params:set_action(v .. "volume", function(value) engine.volume(v, math.pow(10, value / 20)) end)

  params:add_taper(v .. "filter", "Filter", 0, 1, 0.5, 0)
  params:set_action(v .. "filter", function(value) engine.filter(v, value) end)

  params:add_taper(v .. "pan", "Pan", -1, 1, 0, 0)
  params:set_action(v .. "pan", function(value) engine.pan(v, value) end)

  params:add_taper(v .. "bit_depth", "Bit Depth", 1, 24, 24, 0)
  params:set_action(v .. "bit_depth", function(value) engine.bitDepth(v, value) end)

  params:add_taper(v .. "sample_rate", "Sample Rate", 1, 48000, 48000, 0)
  params:set_action(v .. "sample_rate", function(value) engine.sampleRate(v, value) end)

  params:add_taper(v .. "reduction_mix", "Reduction Mix", 0, 1, 0, 0)
  params:set_action(v .. "reduction_mix", function(value) engine.reductionMix(v, value) end)

  params:add_taper(v .. "tremolo_depth", "Tremolo Depth", 0, 1, 0, 0)
  params:set_action(v .. "tremolo_depth", function(value) engine.tremoloDepth(v, value) end)

  params:add_taper(v .. "tremolo_rate", "Tremolo Rate", 0, 20, 0, 0)
  params:set_action(v .. "tremolo_rate", function(value) engine.tremoloRate(v, value) end)

  params:add_taper(v .. "wobble", "Wobble", 0, 1, 0, 0)
  params:set_action(v .. "wobble", function(value) engine.wobble(v, value) end)

  params:add_taper(v .. "saturation", "Saturation Send", min_saturation_send, max_saturation_send, min_delay_send, 0,
    "dB")
  params:set_action(v .. "saturation", function(value) engine.saturation(v, math.pow(10, value / 20)) end)

  params:add_taper(v .. "delay", "Delay Send", min_delay_send, max_delay_send, min_delay_send, 0, "dB")
  params:set_action(v .. "delay", function(value) engine.delay(v, math.pow(10, value / 20)) end)

  params:add_taper(v .. "reverb", "Reverb Send", min_reverb_send, max_reverb_send, min_delay_send, 0, "dB")
  params:set_action(v .. "reverb", function(value) engine.reverb(v, math.pow(10, value / 20)) end)

  params:add_taper(v .. "filterbank", "Filterbank Send", min_filterbank_send, max_filterbank_send, min_delay_send, 0,
    "dB")
  params:set_action(v .. "filterbank", function(value) engine.filterbank(v, math.pow(10, value / 20)) end)
end

function init_granular_params(v)
  params:add_group("GRANULAR", 4)

  params:add_taper(v .. "jitter", "Jitter", min_jitter, max_jitter, 0, 5, "ms")
  params:set_action(v .. "jitter", function(value) engine.jitter(v, value / 1000) end)

  params:add_taper(v .. "size", "Grain Size", min_size, max_size, 100, 5, "ms")
  params:set_action(v .. "size", function(value) engine.size(v, value / 1000) end)

  params:add_taper(v .. "density", "Density", min_density, max_density, 20, 6, "hz")
  params:set_action(v .. "density", function(value) engine.density(v, value) end)

  params:add_taper(v .. "spread", "Spread", 0, 100, 0, 0, "%")
  params:set_action(v .. "spread", function(value) engine.spread(v, value / 100) end)
end

function init_env_and_lfo_params(v)
  params:add_group("ENVELOPE", 5)

  params:add_taper(v .. "envscale", "Attack / Decay", 0, 9000, 1000, 0, "ms")
  params:set_action(v .. "envscale", function(value) engine.envscale(v, value / 1000) end)

  params:add_taper(v .. "attack", "Attack", 0, 10, 1, 0)
  params:set_action(v .. "attack", function(value) engine.attack(v, value) end)

  params:add_taper(v .. "sustain", "Sustain", 0, 10, 1, 0)
  params:set_action(v .. "sustain", function(value) engine.sustain(v, value) end)

  params:add_taper(v .. "release", "Release", 0, 10, 1, 0)
  params:set_action(v .. "release", function(value) engine.release(v, value) end)

  params:add_binary(v .. "hold", "Hold", "toggle", 1)

  for lfo_num = 1, 4 do
    local lfo_id = v .. "_lfo" .. lfo_num
    params:add_group("LFO " .. lfo_num, 5)

    params:add_taper(lfo_id .. "_rate", "LFO Rate", 0.001, 20, 0.5, 0, "Sec")
    params:set_action(lfo_id .. "_rate", function(value)
      lfos[v][lfo_num]:set('period', value)
    end)

    params:add_taper(lfo_id .. "_depth", "LFO Depth", 0, 1, 0.5, 0)
    params:set_action(lfo_id .. "_depth", function(value)
      lfos[v][lfo_num]:set('depth', value)
    end)

    params:add_binary(lfo_id .. "_enable", "LFO Enable", "toggle", 0)
    params:set_action(lfo_id .. "_enable", function(value)
      if value == 1 then lfos[v][lfo_num]:start() else lfos[v][lfo_num]:stop() end
    end)

    add_lfo_target_param(v, lfo_num)

    params:add_taper(lfo_id .. "_offset", "LFO Offset", -1, 1, 0, 0)
    params:set_action(lfo_id .. "_offset", function(value)
      lfos[v][lfo_num]:set('offset', value)
    end)
  end
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
    if screen_mode_b then
      screen_mode = util.clamp(screen_mode + d, 1, total_screens)
    else
      selected_param[screen_mode] = util.clamp(selected_param[screen_mode] + d, 1, #get_param_list(screen_mode))
    end
    screen_mode = util.clamp(screen_mode + d, 1, total_screens)
  elseif n == 2 then
    selected_param[screen_mode] = util.clamp(selected_param[screen_mode] + d, 1, #get_param_list(screen_mode))
  elseif n == 3 then
    local param_list = get_param_list(screen_mode)
    params:delta(param_list[selected_param[screen_mode]], d)
  end
  redraw()
end

function get_param_list(screen_mode)
  if screen_mode == 1 and screen_mode_b then
    return { selected_voice .. "buffer_length", selected_voice .. "update_buffer_length", selected_voice .. "save_buffer" }
  elseif screen_mode == 1 then
    return { selected_voice .. "volume", selected_voice .. "pan", selected_voice .. "filterbank", selected_voice ..
    "saturation",
      selected_voice .. "reverb", selected_voice .. "delay" }
  elseif screen_mode == 2 then
    return filterbank_params
  elseif screen_mode == 3 then
    return saturation_params
  elseif screen_mode == 4 then
    return delay_params
  elseif screen_mode == 5 then
    return reverb_params
  else
    return {}
  end
end

-- Define variables for buffer update and save states
local updating_buffer = false
local saving_buffer = false

function key(n, z)
  if screen_mode == 1 and screen_mode_b then
    if n == 2 and z == 1 then
      screen_mode_b = false -- Switch back to screen 1a
    elseif n == 3 and z == 1 then
      local selected_param_id = selected_param[screen_mode]
      if selected_param_id == 2 then
        updating_buffer = true
        engine.buffer_length(selected_voice, params:get(selected_voice .. "buffer_length"))
        clock.run(function()
          clock.sleep(1)
          updating_buffer = false
          redraw()
        end)
      elseif selected_param_id == 3 then
        saving_buffer = true
        local timestamp = os.date("%Y%m%d%H%M%S")
        local filepath = '/home/we/dust/audio/MSG/' .. timestamp .. 'buffer_' .. selected_voice .. '.wav'
        print(filepath)
        engine.save_buffer(selected_voice, filepath)
        params:set(selected_voice .. "sample", filepath)
        clock.run(function()
          clock.sleep(1)
          saving_buffer = false
          redraw()
        end)
      end
    end
  else
    if n == 2 and z == 1 then
      screen_mode_b = not screen_mode_b -- Toggle between screen 1a and screen 1b
    elseif n == 1 and z == 1 then
      screen_mode = util.clamp(screen_mode + z, 1, total_screens)
    elseif n == 3 and z == 1 then
      local param_list = get_param_list(screen_mode)
      params:delta(param_list[selected_param[screen_mode]], z)
    end
  end
  redraw()
end

function enc(n, d)
  if screen_mode == 1 and screen_mode_b then
    if n == 2 then
      selected_param[screen_mode] = util.clamp(selected_param[screen_mode] + d, 1, #get_param_list(screen_mode))
    elseif n == 3 then
      local param_list = get_param_list(screen_mode)
      params:delta(param_list[selected_param[screen_mode]], d)
    end
  else
    if n == 1 then
      screen_mode = util.clamp(screen_mode + d, 1, total_screens)
    elseif n == 2 then
      selected_param[screen_mode] = util.clamp(selected_param[screen_mode] + d, 1, #get_param_list(screen_mode))
    elseif n == 3 then
      local param_list = get_param_list(screen_mode)
      params:delta(param_list[selected_param[screen_mode]], d)
    end
  end
  redraw()
end

function redraw()
  screen.clear()

  if screen_mode == 1 then
    if screen_mode_b then
      redraw_screen_1B()
    else
      redraw_screen_1()
    end
  elseif screen_mode == 2 then
    redraw_screen_2()
  elseif screen_mode == 3 then
    redraw_screen_3()
  elseif screen_mode == 4 then
    redraw_screen_4()
  elseif screen_mode == 5 then
    redraw_screen_5()
  end

  screen.update()
end

function redraw_screen_1()
  local track_number_x = 0
  local track_number_y = 20
  screen.move(track_number_x, track_number_y)
  screen.level(gates[selected_voice] > 0 and 15 or 2)
  screen.font_size(24)
  screen.text(string.format(selected_voice))
  screen.font_size(8)

  if params:get(selected_voice .. "hold") == 0 then
    local underline_start_x = track_number_x
    local underline_end_x = track_number_x + 20
    local underline_y = track_number_y + 4
    screen.move(underline_start_x, underline_y)
    screen.line(underline_end_x, underline_y)
    screen.close()
    screen.stroke()
  end

  local hold_state_y = track_number_y + 20

  local mode_y = hold_state_y
  screen.level(15)
  if params:get(selected_voice .. "granular") == 0 then
    for i = 1, 10 do
      local x = track_number_x + math.random(0, 10)
      local y = mode_y + math.random(-10, 10)
      screen.pixel(x, y)
    end
    screen.fill()
  end

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

  local record_state_x = mute_state_x + mute_box_size + 10
  local record_state_y = mute_state_y + 2
  local record_circle_radius = 3
  screen.move(record_state_x, record_state_y)
  if params:get(selected_voice .. "record") == 1 then
    screen.level(15)
    screen.circle(record_state_x, record_state_y, record_circle_radius)
    screen.fill()
  else
    screen.level(2)
    screen.circle(record_state_x, record_state_y, record_circle_radius)
    screen.fill()
  end

  local param_list = get_param_list(1)
  for i, param in ipairs(param_list) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[1] and 15 or 2)
    -- filer out the voice number from the param name
    local param_name = string.sub(param, 2)
    screen.text(param_name .. ": " .. string.format("%.2f", params:get(param)))
  end
end

function redraw_screen_1B()
  local track_number_x = 0
  local track_number_y = 20
  screen.move(track_number_x, track_number_y)
  screen.level(gates[selected_voice] > 0 and 15 or 2)
  screen.font_size(24)
  screen.text(string.format(selected_voice))
  screen.font_size(8)

  if params:get(selected_voice .. "hold") == 0 then
    local underline_start_x = track_number_x
    local underline_end_x = track_number_x + 20
    local underline_y = track_number_y + 4
    screen.move(underline_start_x, underline_y)
    screen.line(underline_end_x, underline_y)
    screen.close()
    screen.stroke()
  end

  local hold_state_y = track_number_y + 20

  local mode_y = hold_state_y
  screen.level(15)
  if params:get(selected_voice .. "granular") == 0 then
    for i = 1, 10 do
      local x = track_number_x + math.random(0, 10)
      local y = mode_y + math.random(-10, 10)
      screen.pixel(x, y)
    end
    screen.fill()
  end

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

  local record_state_x = mute_state_x + mute_box_size + 10
  local record_state_y = mute_state_y + 2
  local record_circle_radius = 3
  screen.move(record_state_x, record_state_y)
  if params:get(selected_voice .. "record") == 1 then
    screen.level(15)
    screen.circle(record_state_x, record_state_y, record_circle_radius)
    screen.fill()
  else
    screen.level(2)
    screen.circle(record_state_x, record_state_y, record_circle_radius)
    screen.fill()
  end

  local param_list = get_param_list(1)
  for i, param in ipairs(param_list) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[1] and 15 or 2)
    local param_name = string.sub(param, 2)
    screen.text(param_name .. ": " .. string.format("%.2f", params:get(param)))
  end

  -- Add indicators for buffer updates and saves
  if updating_buffer then
    screen.move(90, 40)
    screen.level(15)
    screen.text("Updating...")
  elseif saving_buffer then
    screen.move(90, 40)
    screen.level(15)
    screen.text("Saving...")
  end
end

function redraw_screen_2()
  screen.move(0, 20)
  screen.level(15)
  screen.font_size(24)
  screen.text("FB")
  screen.font_size(8)

  for i, param in ipairs(filterbank_params) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[2] and 15 or 2)
    -- remove 'filterbank_' from the param name
    param_name = string.sub(param, 12)
    screen.text(param_name .. ": " .. string.format("%.2f", params:get(param)))
  end
end

function redraw_screen_3()
  screen.move(0, 20)
  screen.level(15)
  screen.font_size(24)
  screen.text("ST")
  screen.font_size(8)

  for i, param in ipairs(saturation_params) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[3] and 15 or 2)
    screen.text(param .. ": " .. string.format("%.2f", params:get(param)))
  end
end

function redraw_screen_4()
  screen.move(0, 20)
  screen.level(15)
  screen.font_size(24)
  screen.text("DL")
  screen.font_size(8)

  for i, param in ipairs(delay_params) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[4] and 15 or 2)
    -- remove 'delay_' from the param name
    param_name = string.sub(param, 7)
    screen.text(param_name .. ": " .. string.format("%.2f", params:get(param)))
  end
end

function redraw_screen_5()
  screen.move(0, 20)
  screen.level(15)
  screen.font_size(24)
  screen.text("RE")
  screen.font_size(8)

  for i, param in ipairs(reverb_params) do
    local y = 0 + i * 10
    screen.move(35, y)
    screen.level(i == selected_param[5] and 15 or 2)
    -- remove 'reverb_' from the param name
    param_name = string.sub(param, 8)
    screen.text(param_name .. ": " .. string.format("%.2f", params:get(param)))
  end
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
