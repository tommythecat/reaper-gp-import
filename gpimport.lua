-- @description Guitar Pro file importer 
-- @version 0.1.0
-- @author tommythecat
-- @about A script for parsing and mapping Guitar Pro (.gp) arrangements cleanly to midi tracks

-- ---------------------------------------------------------------------------

-- Imports Guitar Pro files (.gp, GP7/GP8 format) as MIDI tracks
-- No external dependencies - uses Windows PowerShell for unzipping only
-- Supports multiple tracks, tempo changes, time sig changes, ties, drums
--
-- Install: Actions > Show action list > New action > Load ReaScript
--          Browse to this file, then assign a shortcut or toolbar button

-- ---------------------------------------------------------------------------
-- MIDI note durations (ticks at 960 PPQ)
-- ---------------------------------------------------------------------------

local RHYTHM_TICKS = {
  Whole   = 3840,
  Half    = 1920,
  Quarter = 960,
  Eighth  = 480,
  ["16th"]  = 240,
  ["32nd"]  = 120,
  ["64th"]  = 60,
}

local DYNAMIC_VEL = {
  PPP=16, PP=32, P=48, MP=64, MF=80, F=96, FF=112, FFF=127
}

local TICKS_PER_BEAT = 960

-- ---------------------------------------------------------------------------
-- MIDI writer
-- ---------------------------------------------------------------------------

local function vlq(value)
  -- Encode integer as MIDI variable-length quantity, return as string of bytes
  local bytes = {}
  bytes[1] = value & 0x7F
  value = value >> 7
  while value > 0 do
    table.insert(bytes, 1, (value & 0x7F) | 0x80)
    value = value >> 7
  end
  local result = {}
  for _, b in ipairs(bytes) do
    result[#result+1] = string.char(b)
  end
  return table.concat(result)
end

local function uint16be(v)
  return string.char((v >> 8) & 0xFF, v & 0xFF)
end

local function uint32be(v)
  return string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
end

local function build_tempo_track(tempo_events, time_sig_events)
  -- tempo_events:   list of {tick, bpm}
  -- time_sig_events: list of {tick, num, den}
  local events = {}

  -- Track name meta
  local name = "Master"
  events[#events+1] = {tick=0, data="\xFF\x03" .. vlq(#name) .. name}

  for _, te in ipairs(tempo_events) do
    local us = math.floor(60000000 / te.bpm)
    local b1 = (us >> 16) & 0xFF
    local b2 = (us >> 8)  & 0xFF
    local b3 = us & 0xFF
    events[#events+1] = {tick=te.tick, pri=0,
      data="\xFF\x51\x03" .. string.char(b1, b2, b3)}
  end

  for _, ts in ipairs(time_sig_events) do
    local dexp = math.floor(math.log(ts.den) / math.log(2) + 0.5)
    events[#events+1] = {tick=ts.tick, pri=1,
      data="\xFF\x58\x04" .. string.char(ts.num, dexp, 24, 8)}
  end

  table.sort(events, function(a,b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    return (a.pri or 9) < (b.pri or 9)
  end)

  local parts = {}
  local last = 0
  for _, ev in ipairs(events) do
    parts[#parts+1] = vlq(ev.tick - last) .. ev.data
    last = ev.tick
  end
  parts[#parts+1] = "\x00\xFF\x2F\x00"  -- end of track

  local payload = table.concat(parts)
  return "MTrk" .. uint32be(#payload) .. payload
end

local function build_note_track(events, track_name, program, channel)
  -- events: list of {tick, type="on"|"off", pitch, vel}
  -- Sort: offs before ons at same tick
  table.sort(events, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    local pa = (a.type == "off") and 0 or 1
    local pb = (b.type == "off") and 0 or 1
    return pa < pb
  end)

  local parts = {}

  -- Track name meta
  local nb = track_name or "Track"
  parts[#parts+1] = "\x00\xFF\x03" .. vlq(#nb) .. nb

  -- Program change (skip drums on ch 9)
  if channel ~= 9 then
    parts[#parts+1] = "\x00" .. string.char(0xC0 | channel, program & 0x7F)
  end

  local last = 0
  for _, ev in ipairs(events) do
    local delta = ev.tick - last
    last = ev.tick
    if ev.type == "on" then
      parts[#parts+1] = vlq(delta) ..
        string.char(0x90 | channel, ev.pitch & 0x7F, ev.vel & 0x7F)
    else
      parts[#parts+1] = vlq(delta) ..
        string.char(0x80 | channel, ev.pitch & 0x7F, 0)
    end
  end

  parts[#parts+1] = "\x00\xFF\x2F\x00"  -- end of track

  local payload = table.concat(parts)
  return "MTrk" .. uint32be(#payload) .. payload
end

local function assemble_midi(tempo_track, note_tracks)
  local n = 1 + #note_tracks
  local header = "MThd" .. uint32be(6) .. uint16be(1) .. uint16be(n) .. uint16be(TICKS_PER_BEAT)
  local parts = {header, tempo_track}
  for _, t in ipairs(note_tracks) do
    parts[#parts+1] = t
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- GPIF XML parser
-- ---------------------------------------------------------------------------

local function get_attr(s, name)
  -- Extract attribute value from a tag string, e.g. get_attr('<Note id="3">', "id") -> "3"
  local v = s:match('%s' .. name .. '%s*=%s*"([^"]*)"')
  if not v then v = s:match('^<[%w:]+%s+' .. name .. '%s*=%s*"([^"]*)"') end
  return v
end

local function tag_name(s)
  return s:match("^</?([%w:]+)") or ""
end

local function split_tokens(line)
  -- Split a line into tags and text segments
  local tokens = {}
  local pos = 1
  while pos <= #line do
    local ts, te, tag = line:find("(<[^>]+>)", pos)
    if ts then
      if ts > pos then
        local text = line:sub(pos, ts-1):match("^%s*(.-)%s*$")
        if text ~= "" then tokens[#tokens+1] = {type="text", val=text} end
      end
      tokens[#tokens+1] = {type="tag", val=tag}
      pos = te + 1
    else
      local text = line:sub(pos):match("^%s*(.-)%s*$")
      if text ~= "" then tokens[#tokens+1] = {type="text", val=text} end
      break
    end
  end
  return tokens
end

local function parse_gpif(xml_text)
  local rhythms    = {}   -- id -> ticks
  local notes      = {}   -- id -> {midi, muted, tie_origin, tie_dest}
  local beats      = {}   -- id -> {rhythm_ref, note_ids, vel}
  local voices     = {}   -- id -> [beat_id, ...]
  local bars       = {}   -- id -> [voice_id, ...]
  local masterbars = {}   -- list of {bar_ids, time_sig}
  local tracks     = {}   -- list of {name, program, channel}
  local tempo_map  = {}   -- bar_idx -> bpm
  local title      = ""
  local artist     = ""

  -- Parser state
  local stack = {}   -- tag path as list
  local cur = {
    rhythm_id  = nil,
    note_id    = nil,
    beat_id    = nil,
    voice_id   = nil,
    bar_id     = nil,
    prop_name  = nil,
    auto_type  = nil,
    auto_bar   = nil,
  }

  local function path()
    return table.concat(stack, "/")
  end

  local function apply_text(text)
    local p = path()

    -- Rhythms
    if p == "GPIF/Rhythms/Rhythm/NoteValue" then
      rhythms[cur.rhythm_id].nv = text

    -- Notes
    elseif p == "GPIF/Notes/Note/Properties/Property/Number"
        and cur.prop_name == "Midi" then
      notes[cur.note_id].midi = tonumber(text)

    -- Beats
    elseif p == "GPIF/Beats/Beat/Notes" then
      local ids = {}
      for id in text:gmatch("%-?%d+") do
        local n = tonumber(id)
        if n and n >= 0 then ids[#ids+1] = n end
      end
      beats[cur.beat_id].note_ids = ids
    elseif p == "GPIF/Beats/Beat/Dynamic" then
      beats[cur.beat_id].vel = DYNAMIC_VEL[text] or 80

    -- Voices
    elseif p == "GPIF/Voices/Voice/Beats" then
      local ids = {}
      for id in text:gmatch("%-?%d+") do
        local n = tonumber(id)
        if n and n >= 0 then ids[#ids+1] = n end
      end
      voices[cur.voice_id] = ids

    -- Bars
    elseif p == "GPIF/Bars/Bar/Voices" then
      local ids = {}
      for id in text:gmatch("%-?%d+") do
        local n = tonumber(id)  -- keep -1 (empty voice slots)
        if n then ids[#ids+1] = n end
      end
      bars[cur.bar_id] = ids

    -- MasterBars
    elseif p == "GPIF/MasterBars/MasterBar/Bars" then
      local ids = {}
      for id in text:gmatch("%-?%d+") do
        ids[#ids+1] = tonumber(id)
      end
      masterbars[#masterbars].bar_ids = ids
    elseif p == "GPIF/MasterBars/MasterBar/Time" then
      masterbars[#masterbars].time = text

    -- Tracks
    elseif p == "GPIF/Tracks/Track/Name" then
      tracks[#tracks].name = text
    elseif p == "GPIF/Tracks/Track/Sounds/Sound/MIDI/Program" then
      tracks[#tracks].program = tonumber(text) or 0
    elseif p == "GPIF/Tracks/Track/MidiConnection/PrimaryChannel" then
      tracks[#tracks].channel = tonumber(text)

    -- Tempo automations
    elseif p == "GPIF/MasterTrack/Automations/Automation/Type" then
      cur.auto_type = text
    elseif p == "GPIF/MasterTrack/Automations/Automation/Bar" then
      cur.auto_bar = tonumber(text)
    elseif p == "GPIF/MasterTrack/Automations/Automation/Value" then
      if cur.auto_type == "Tempo" and cur.auto_bar then
        local bpm = tonumber(text:match("^%d+"))
        if bpm then tempo_map[cur.auto_bar] = bpm end
      end

    -- Score metadata
    elseif p == "GPIF/Score/Title" then
      title = text
    elseif p == "GPIF/Score/Artist" then
      artist = text
    end
  end

  local function on_open(tag_str)
    local tname = tag_name(tag_str)
    stack[#stack+1] = tname
    local p = path()

    if p == "GPIF/Rhythms/Rhythm" then
      cur.rhythm_id = tonumber(get_attr(tag_str, "id"))
      rhythms[cur.rhythm_id] = {nv="Quarter", dots=0, tup_num=1, tup_den=1}

    elseif p == "GPIF/Rhythms/Rhythm/AugmentationDot" then
      rhythms[cur.rhythm_id].dots = tonumber(get_attr(tag_str, "count")) or 0

    elseif p == "GPIF/Rhythms/Rhythm/PrimaryTuplet" then
      rhythms[cur.rhythm_id].tup_num = tonumber(get_attr(tag_str, "num")) or 1
      rhythms[cur.rhythm_id].tup_den = tonumber(get_attr(tag_str, "den")) or 1

    elseif p == "GPIF/Notes/Note" then
      cur.note_id = tonumber(get_attr(tag_str, "id"))
      notes[cur.note_id] = {midi=nil, muted=false, tie_origin=false, tie_dest=false}

    elseif p == "GPIF/Notes/Note/Tie" then
      notes[cur.note_id].tie_origin = (get_attr(tag_str, "origin") == "true")
      notes[cur.note_id].tie_dest   = (get_attr(tag_str, "destination") == "true")

    elseif p == "GPIF/Notes/Note/Properties/Property" then
      cur.prop_name = get_attr(tag_str, "name")

    elseif p == "GPIF/Notes/Note/Properties/Property/Muted"
        and cur.prop_name == "Muted" then
      notes[cur.note_id].muted = true

    elseif p == "GPIF/Beats/Beat" then
      cur.beat_id = tonumber(get_attr(tag_str, "id"))
      beats[cur.beat_id] = {rhythm_ref=0, note_ids={}, vel=80}

    elseif p == "GPIF/Beats/Beat/Rhythm" then
      beats[cur.beat_id].rhythm_ref = tonumber(get_attr(tag_str, "ref")) or 0

    elseif p == "GPIF/Voices/Voice" then
      cur.voice_id = tonumber(get_attr(tag_str, "id"))
      voices[cur.voice_id] = {}

    elseif p == "GPIF/Bars/Bar" then
      cur.bar_id = tonumber(get_attr(tag_str, "id"))
      bars[cur.bar_id] = {}

    elseif p == "GPIF/MasterBars/MasterBar" then
      masterbars[#masterbars+1] = {bar_ids={}, time="4/4"}

    elseif p == "GPIF/Tracks/Track" then
      tracks[#tracks+1] = {name="Track " .. get_attr(tag_str,"id"), program=0, channel=nil}
    end
  end

  local function on_close(tag_str)
    local p = path()

    if p == "GPIF/Rhythms/Rhythm" then
      local r = rhythms[cur.rhythm_id]
      local base = RHYTHM_TICKS[r.nv] or TICKS_PER_BEAT
      local ticks = base
      local add   = base // 2
      for _ = 1, r.dots do
        ticks = ticks + add
        add   = add // 2
      end
      -- Apply tuplet (e.g. triplet: 3 notes in space of 2)
      if r.tup_num ~= r.tup_den then
        ticks = math.floor(ticks * r.tup_den / r.tup_num)
      end
      rhythms[cur.rhythm_id] = ticks
    end

    stack[#stack] = nil
  end

  -- Main parse loop
  for line in xml_text:gmatch("([^\n]*)\n?") do
    local stripped = line:match("^%s*(.-)%s*$")
    if stripped == "" or stripped:sub(1,2) == "<?" or stripped:sub(1,4) == "<!--" then
      goto continue
    end

    -- CDATA: apply content to current path
    local cdata = stripped:match("^<!%[CDATA%[(.-)%]%]>$")
    if cdata then
      local text = cdata:match("^%s*(.-)%s*$")
      if text ~= "" then apply_text(text) end
      goto continue
    end

    -- Self-closing tags (e.g. <Accidental/>, <Tie origin="true" destination="false"/>)
    -- These won't have a matching close, handle inline
    if stripped:match("/>%s*$") and not stripped:match("^</") then
      local tname = tag_name(stripped)
      -- Temporary push/pop to handle as if open+close
      stack[#stack+1] = tname
      local p = path()
      if p == "GPIF/Notes/Note/Tie" then
        notes[cur.note_id].tie_origin = (get_attr(stripped, "origin") == "true")
        notes[cur.note_id].tie_dest   = (get_attr(stripped, "destination") == "true")
      elseif p == "GPIF/Rhythms/Rhythm/AugmentationDot" then
        rhythms[cur.rhythm_id].dots = tonumber(get_attr(stripped, "count")) or 0
      elseif p == "GPIF/Rhythms/Rhythm/PrimaryTuplet" then
        rhythms[cur.rhythm_id].tup_num = tonumber(get_attr(stripped, "num")) or 1
        rhythms[cur.rhythm_id].tup_den = tonumber(get_attr(stripped, "den")) or 1
      elseif p == "GPIF/Beats/Beat/Rhythm" then
        beats[cur.beat_id].rhythm_ref = tonumber(get_attr(stripped, "ref")) or 0
      end
      stack[#stack] = nil
      goto continue
    end

    -- Normal tags and text
    local tokens = split_tokens(stripped)
    for _, tok in ipairs(tokens) do
      if tok.type == "tag" then
        if tok.val:sub(1,2) == "</" then
          on_close(tok.val)
        else
          on_open(tok.val)
        end
      elseif tok.type == "text" then
        apply_text(tok.val)
      end
    end

    ::continue::
  end

  return {
    rhythms    = rhythms,
    notes      = notes,
    beats      = beats,
    voices     = voices,
    bars       = bars,
    masterbars = masterbars,
    tracks     = tracks,
    tempo_map  = tempo_map,
    title      = title,
    artist     = artist,
  }
end

-- ---------------------------------------------------------------------------
-- GP to MIDI conversion
-- ---------------------------------------------------------------------------

local function gp_to_midi(xml_text)
  local gp = parse_gpif(xml_text)

  -- Pre-compute bar start ticks
  local bar_start_ticks = {}
  local tick = 0
  for _, mb in ipairs(gp.masterbars) do
    bar_start_ticks[#bar_start_ticks+1] = tick
    local num, den = mb.time:match("^(%d+)/(%d+)$")
    num, den = tonumber(num) or 4, tonumber(den) or 4
    tick = tick + (3840 // den) * num
  end

  -- Tempo track
  local tempo_events = {}
  for bar_idx, bpm in pairs(gp.tempo_map) do
    local t = bar_start_ticks[bar_idx + 1]  -- Lua 1-indexed, bar_idx is 0-indexed
    if t then
      tempo_events[#tempo_events+1] = {tick=t, bpm=bpm}
    end
  end
  -- Ensure there's a tempo at tick 0
  local has_zero = false
  for _, te in ipairs(tempo_events) do
    if te.tick == 0 then has_zero = true; break end
  end
  if not has_zero then
    table.insert(tempo_events, 1, {tick=0, bpm=120})
  end
  table.sort(tempo_events, function(a,b) return a.tick < b.tick end)

  local time_sig_events = {}
  local prev_ts = nil
  for mb_idx, mb in ipairs(gp.masterbars) do
    if mb.time ~= prev_ts then
      local num, den = mb.time:match("^(%d+)/(%d+)$")
      time_sig_events[#time_sig_events+1] = {
        tick = bar_start_ticks[mb_idx],
        num  = tonumber(num) or 4,
        den  = tonumber(den) or 4,
      }
      prev_ts = mb.time
    end
  end

  local tempo_track = build_tempo_track(tempo_events, time_sig_events)

  -- Assign MIDI channels (0-8 for pitched, 9 for drums, 10-15 for overflow)
  local avail_channels = {}
  for c = 0, 15 do if c ~= 9 then avail_channels[#avail_channels+1] = c end end
  local chan_idx = 0

  -- Build one MIDI track per GP track
  local note_tracks = {}
  for track_idx, tinfo in ipairs(gp.tracks) do
    local is_drum = (tinfo.channel == 9)
    local channel
    if is_drum then
      channel = 9
    else
      channel = avail_channels[(chan_idx % #avail_channels) + 1]
      chan_idx = chan_idx + 1
    end

    local events     = {}
    local open_notes = {}   -- pitch -> true (currently held open for ties)

    for mb_idx, mb in ipairs(gp.masterbars) do
      local bar_id = mb.bar_ids[track_idx]
      if not bar_id then goto next_bar end

      local voice_ids = gp.bars[bar_id]
      if not voice_ids or #voice_ids == 0 then goto next_bar end

      local voice_id = voice_ids[1]   -- use voice 0 only
      if voice_id < 0 then goto next_bar end

      local beat_ids = gp.voices[voice_id]
      if not beat_ids then goto next_bar end

      local abs_tick = bar_start_ticks[mb_idx]

      for _, beat_id in ipairs(beat_ids) do
        local beat = gp.beats[beat_id]
        if not beat then goto next_beat end

        local dur = gp.rhythms[beat.rhythm_ref] or TICKS_PER_BEAT
        local vel = beat.vel

        for _, nid in ipairs(beat.note_ids) do
          local n = gp.notes[nid]
          if not n then goto next_note end

          local pitch = n.midi
          if not pitch or n.muted then goto next_note end
          pitch = math.max(0, math.min(127, pitch))

          if n.tie_dest then
            -- Continuation of a tie: note is already open, do nothing
          else
            -- Close any previous note on this pitch
            if open_notes[pitch] then
              events[#events+1] = {tick=abs_tick, type="off", pitch=pitch, vel=0}
              open_notes[pitch] = nil
            end
            -- Open the note
            events[#events+1] = {tick=abs_tick, type="on", pitch=pitch, vel=vel}
            open_notes[pitch] = true
          end

          if not n.tie_origin then
            -- Note ends at close of this beat
            if open_notes[pitch] then
              events[#events+1] = {tick=abs_tick+dur, type="off", pitch=pitch, vel=0}
              open_notes[pitch] = nil
            end
          end

          ::next_note::
        end

        abs_tick = abs_tick + dur
        ::next_beat::
      end

      ::next_bar::
    end

    -- Close any notes still open (safety net)
    local final_tick = (bar_start_ticks[#bar_start_ticks] or 0) + TICKS_PER_BEAT
    for pitch in pairs(open_notes) do
      events[#events+1] = {tick=final_tick, type="off", pitch=pitch, vel=0}
    end

    note_tracks[#note_tracks+1] = build_note_track(
      events, tinfo.name, tinfo.program, channel
    )
  end

  return assemble_midi(tempo_track, note_tracks),
         gp.title,
         gp.artist,
         #gp.tracks
end

-- ---------------------------------------------------------------------------
-- PowerShell unzip helper
-- ---------------------------------------------------------------------------

local function extract_gpif_via_powershell(gp_path, out_path)
  -- Escape paths for PowerShell (double up single quotes)
  local gp_esc  = gp_path:gsub("'", "''")
  local out_esc = out_path:gsub("'", "''")

  local ps_cmd = string.format(
    "Add-Type -Assembly System.IO.Compression.FileSystem; " ..
    "$z = [System.IO.Compression.ZipFile]::OpenRead('%s'); " ..
    "$e = $z.Entries | Where-Object { $_.FullName -eq 'Content/score.gpif' }; " ..
    "[System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, '%s', $true); " ..
    "$z.Dispose()",
    gp_esc, out_esc
  )

  local cmd = 'powershell -NoProfile -NonInteractive -Command "' ..
              ps_cmd:gsub('"', '\\"') .. '"'

  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
  -- File picker
  local ret, gp_path = reaper.GetUserFileNameForRead("", "Select Guitar Pro file (.gp)", "gp")
  if not ret or gp_path == "" then return end

  -- Check it looks like a zip (GP7/GP8)
  local f = io.open(gp_path, "rb")
  if not f then
    reaper.ShowMessageBox("Could not open file:\n" .. gp_path, "GP Import", 0)
    return
  end
  local magic = f:read(2)
  f:close()

  if magic ~= "PK" then
    reaper.ShowMessageBox(
      "This does not appear to be a GP7/GP8 file.\n\n" ..
      "Older GP5 binary files are not supported.\n" ..
      "Check file uses the GP7/GP8 format (.gp).",
      "GP Import - Unsupported Format", 0)
    return
  end

  -- Extract score.gpif to temp file via PowerShell
  local tempdir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
  local guid = tostring(math.random(1000000,9999999))
  local tmp_xml = tempdir .. "\\reaper_gp_import_" .. guid .. ".gpif"
  local tmp_mid = tempdir .. "\\reaper_gp_import_" .. guid .. ".mid"

  local ok = extract_gpif_via_powershell(gp_path, tmp_xml)
  if not ok then
    reaper.ShowMessageBox(
      "Failed to extract the Guitar Pro file.\n" ..
      "Please ensure PowerShell is available on your system.",
      "GP Import - Error", 0)
    return
  end

  -- Read XML
  local xf = io.open(tmp_xml, "r")
  if not xf then
    reaper.ShowMessageBox("Failed to read extracted XML.", "GP Import - Error", 0)
    os.remove(tmp_xml)
    return
  end
  local xml_text = xf:read("*a")
  xf:close()
  os.remove(tmp_xml)

  -- Convert to MIDI
  local midi_bytes, title, artist, n_tracks = gp_to_midi(xml_text)
  if not midi_bytes then
    reaper.ShowMessageBox("Conversion failed.", "GP Import - Error", 0)
    return
  end

  -- Write MIDI to temp file
  local mf = io.open(tmp_mid, "wb")
  if not mf then
    reaper.ShowMessageBox("Failed to write temporary MIDI file.", "GP Import - Error", 0)
    return
  end
  mf:write(midi_bytes)
  mf:close()

  -- Import into REAPER (mode 9 = expand multi-track MIDI into separate tracks)
  reaper.InsertMedia(tmp_mid, 9)

  os.remove(tmp_mid)

  -- Done
  local song_name = ""
  if artist ~= "" and title ~= "" then
    song_name = artist .. " - " .. title
  elseif title ~= "" then
    song_name = title
  else
    song_name = gp_path:match("([^/\\]+)$") or gp_path
  end

  reaper.ShowMessageBox(
    "Imported: " .. song_name .. "\n" .. n_tracks .. " tracks",
    "GP Import - Done", 0)
end

main()
