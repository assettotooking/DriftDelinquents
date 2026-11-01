--[[
  MAP TIMER  -  CSP online script for AssettoServer
  Shows a countdown until the map ends, a server name, a custom background,
  and plays a sound when the warning time (default 2 minutes) is reached.

  MOVE / RESIZE (each player, in game)
  Hover the panel with the mouse cursor, then:
    - Hold left mouse button and drag      -> move the panel
    - Mouse wheel, or drag the bottom-right corner -> make it bigger / smaller
    - Double-click                          -> reset to the default position/size
  POS_X / POS_Y / SCALE below are only the defaults for players who haven't
  moved it yet (and what double-click resets to).

  HOW TO ADD IT
  1. Host this file somewhere with a direct link (e.g. your server's wwwroot
     folder -> http://<ip>:<http port>/static/map_timer.lua, or a Pastebin raw link).
  2. In your server's cfg/csp_extra_options.ini add:

       [SCRIPT_MAPTIMER]
       SCRIPT = "https://your-link/map_timer.lua"
       SERVER_NAME = "My Server Name"
       SOUND_URL = "https://your-link/warning.mp3"
       SOUND_VOLUME = 0.4
       WARNING_SECONDS = 120
       MAP_DURATION_MINUTES = 0
       BACKGROUND_URL = ""
       SHOW_TOAST = 1
       POS_X = 0.5
       POS_Y = 0.03
       SCALE = 1.0
       BG_DARKEN = 0.45

     Every setting is optional. Anything you leave out uses the default
     written in the config table below.

  SETTINGS
  SERVER_NAME           Text shown at the top of the panel. Empty = real server name.
  SOUND_URL             Link to the warning sound (mp3 / ogg / wav). This is the
                        sound that plays at WARNING_SECONDS. You can paste:
                          - a direct link to the file, or
                          - a normal Google Drive share link (the file must be set
                            to "Anyone with the link"), or
                          - a normal Dropbox share link.
                        Drive and Dropbox share links are converted to direct
                        download links automatically.
  SOUND_VOLUME          0.0 - 1.0
  WARNING_SECONDS       When the countdown reaches this, the sound plays (120 = 2 min).
  MAP_DURATION_MINUTES  0 = use the session length from the server.
                        Above 0 = use this many minutes instead (counted from the
                        start of the session, so everyone sees the same time).
  BACKGROUND_URL        Direct link to a PNG/JPG for the panel background. Leave
                        empty to use background.png from ASSETS_URL, or a plain
                        dark panel.
  ASSETS_URL            (Optional) Direct link to a .zip containing background.png
                        (and optionally a sound named SOUND_FILE, only used when
                        SOUND_URL is empty). Must be a direct download link.
  SOUND_FILE            File name of the sound inside the zip (zip mode only).
  SHOW_TOAST            1 = also show a pop-up message at the warning time.
  POS_X / POS_Y         Default panel position as a fraction of the screen
                        (X = centre of the panel, Y = top edge).
  SCALE                 Default size of the panel.
  BG_DARKEN             0 - 1, how much the background image is darkened so the
                        text stays readable.
]]

local cfg = ac.configValues({
  SERVER_NAME = '',
  MAP_DURATION_MINUTES = 0,
  WARNING_SECONDS = 30,
  BACKGROUND_URL = '',
  SOUND_URL = 'https://github.com/assettotooking/DriftDelinquents/raw/refs/heads/main/halo-reach-30-seconds-remain.mp3',
  ASSETS_URL = '',
  SOUND_FILE = 'halo-reach-30-seconds-remain.mp3',
  SOUND_VOLUME = 0.3,
  SHOW_TOAST = true,
  FONT = 'Segoe UI',
  POS_X = 0.95,
  POS_Y = 0.02,
  SCALE = 0.90,
  BG_DARKEN = 0.45,
  ACCENT_COLOR = rgbm(0.55, 0.15, 0.85, 1),
})

local sim = ac.getSim()

local BASE_W, BASE_H = 380, 138
local MIN_SCALE, MAX_SCALE = 0.4, 3.0

local state = {
  remaining = nil, -- seconds left, nil when unknown
  total = nil,     -- total map length in seconds, nil when unknown
  last = nil,      -- remaining value of the previous frame
}

local soundEvent = nil
local assetsFolder = nil
local drawUICalled = false
local fallbackTimer = 0

---------------------------------------------------------------------------
-- Saved position / size (stored on the player's PC)
---------------------------------------------------------------------------

-- No more permanent saving. Position/size only last for the current session.
local live = { posX = cfg.POS_X, posY = cfg.POS_Y, scale = cfg.SCALE }
local saveTimer = 0          -- kept only so the rest of the code doesn’t explode
local dragging, resizing = false, false

local function savePosition()
  -- intentionally empty – we don’t want to remember your shitty placement
end

local function resetPosition()
  live.posX, live.posY, live.scale = cfg.POS_X, cfg.POS_Y, cfg.SCALE
end

---------------------------------------------------------------------------
-- Warning sound (downloaded from SOUND_URL)
---------------------------------------------------------------------------

-- Turns normal share links into direct download links.
local function directLink(url)
  if not url or url == '' then return url end

  -- Google Drive: /file/d/<id>/view, /open?id=<id>, /uc?id=<id>
  local id = url:match('drive%.google%.com/file/d/([%w_%-]+)')
          or url:match('drive%.google%.com/open%?id=([%w_%-]+)')
          or url:match('drive%.google%.com/uc%?[^%s]-id=([%w_%-]+)')
  if id then
    return 'https://drive.google.com/uc?export=download&id=' .. id
  end

  -- Dropbox: make sure it ends up as dl=1
  if url:find('dropbox.com', 1, true) then
    if url:find('dl=0', 1, true) then
      url = (url:gsub('dl=0', 'dl=1'))
    elseif not url:find('dl=1', 1, true) then
      url = url .. (url:find('?', 1, true) and '&' or '?') .. 'dl=1'
    end
  end

  return url
end

-- Builds the audio event from a file path or from raw downloaded data.
local function createSoundEvent(params)
  local ok, ev = pcall(ac.AudioEvent.fromFile, params, false)
  if ok and ev then
    soundEvent = ev
    ac.log('[MapTimer] warning sound loaded')
    return true
  end
  ac.warn('[MapTimer] could not load sound: ' .. tostring(ev))
  return false
end

local function loadSoundFromUrl(url)
  -- Fallback: plain download, save to the CSP cache folder, load from there.
  local function viaFile()
    web.get(url, function(err, response)
      local body = response and response.body
      if err or not body or #body == 0 then
        ac.warn('[MapTimer] could not download sound: ' .. tostring(err))
        return
      end
      local path = ac.getFolder(ac.FolderID.ExtCache) .. '/map_timer_warning.mp3'
      io.save(path, body)
      createSoundEvent({ filename = path, use3D = false, loop = false })
    end)
  end

  -- Preferred: let CSP download the sound and hand over the data directly.
  local ok, err = pcall(function()
    web.loadRemoteSound(url, function(downloadErr, data)
      if downloadErr or not data then
        ac.warn('[MapTimer] sound download failed (' .. tostring(downloadErr) .. '), trying fallback')
        pcall(viaFile)
        return
      end
      local created = createSoundEvent({
        stream = { name = 'map_timer_warning.mp3', data = data, size = #data },
        use3D = false, loop = false,
      })
      if not created then pcall(viaFile) end
    end)
  end)

  if not ok then
    ac.warn('[MapTimer] loadRemoteSound unavailable (' .. tostring(err) .. '), trying fallback')
    pcall(viaFile)
  end
end

---------------------------------------------------------------------------
-- Assets (optional zip with background, and sound if SOUND_URL is empty)
---------------------------------------------------------------------------

local function loadAssets()
  local url = cfg.ASSETS_URL
  if not url or url == '' then return end

  local ok, err = pcall(function()
    web.loadRemoteAssets(url, function(downloadErr, folder)
      if downloadErr or not folder then
        ac.warn('[MapTimer] could not download assets: ' .. tostring(downloadErr))
        return
      end
      assetsFolder = folder

      -- zip sound is only used when no SOUND_URL is set
      if cfg.SOUND_URL and cfg.SOUND_URL ~= '' then return end

      local soundPath = folder .. '/' .. cfg.SOUND_FILE
      if not io.fileExists(soundPath) then
        ac.warn('[MapTimer] sound file not found in zip: ' .. cfg.SOUND_FILE)
        return
      end
      createSoundEvent({ filename = soundPath, use3D = false, loop = false })
    end)
  end)

  if not ok then ac.warn('[MapTimer] asset loading failed: ' .. tostring(err)) end
end

if cfg.SOUND_URL and cfg.SOUND_URL ~= '' then
  loadSoundFromUrl(directLink(cfg.SOUND_URL))
end
loadAssets()

local function playWarning()
  if soundEvent then
    pcall(function()
      soundEvent.volume = cfg.SOUND_VOLUME
      soundEvent:start()
    end)
  else
    ac.warn('[MapTimer] warning time reached but the sound is not loaded')
  end
  if cfg.SHOW_TOAST then
    pcall(function()
      local mins = math.floor(cfg.WARNING_SECONDS / 60)
      local text = mins >= 1 and ('Map switches in ' .. mins .. (mins == 1 and ' minute' or ' minutes'))
        or ('Map switches in ' .. cfg.WARNING_SECONDS .. ' seconds')
      ui.toast(ui.Icons.Warning, text)
    end)
  end
end

---------------------------------------------------------------------------
-- Time keeping
---------------------------------------------------------------------------

local function getTotalSeconds()
  local manual = tonumber(cfg.MAP_DURATION_MINUTES) or 0
  if manual > 0 then return manual * 60 end

  local ok, mins = pcall(function()
    return ac.getSession(sim.currentSessionIndex).durationMinutes
  end)
  if ok and mins and mins > 0 then return mins * 60 end
  return nil
end

local function formatTime(seconds)
  seconds = math.max(0, math.ceil(seconds))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
  return string.format('%02d:%02d', m, s)
end

local function tick()
  local total = getTotalSeconds()
  state.total = total
  if not total then
    state.remaining = nil
    state.last = nil
    return
  end

  local elapsed = math.max(0, (sim.currentSessionTime or 0) / 1000)
  local remaining = math.max(0, total - elapsed)
  local threshold = cfg.WARNING_SECONDS

  -- Only play when the countdown actually crosses the threshold, so players who
  -- join with less than 2 minutes left don't get the sound the moment they load in.
  if state.last and state.last > threshold and remaining <= threshold and remaining > 0 then
    playWarning()
  end

  state.last = remaining
  state.remaining = remaining
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function textCentered(text, fontSize, y, color, width)
  local size = ui.measureDWriteText(text, fontSize)
  ui.dwriteDrawText(text, fontSize, vec2((width - size.x) / 2, y), color)
end

local function drawBackground(size)
  -- solid base so the panel is readable even if the image is missing or still loading
  ui.drawRectFilled(vec2(0, 0), size, rgbm(0.05, 0.05, 0.08, 0.0))

  local source = nil
  if cfg.BACKGROUND_URL and cfg.BACKGROUND_URL ~= '' then
    source = cfg.BACKGROUND_URL
  elseif assetsFolder and io.fileExists(assetsFolder .. '/background.png') then
    source = assetsFolder .. '/background.png'
  end

  if source then
    -- "cover" fit: fill the panel and crop the overflow instead of stretching
    local uv1, uv2 = vec2(0, 0), vec2(1, 1)
    local okSize, imgSize = pcall(ui.imageSize, source)
    if okSize and imgSize and imgSize.x > 0 and imgSize.y > 0 then
      local panelAspect = size.x / size.y
      local imgAspect = imgSize.x / imgSize.y
      if imgAspect > panelAspect then
        local w = panelAspect / imgAspect
        uv1.x, uv2.x = (1 - w) / 2, 1 - (1 - w) / 2
      else
        local h = imgAspect / panelAspect
        uv1.y, uv2.y = (1 - h) / 2, 1 - (1 - h) / 2
      end
    end
    ui.drawImage(source, vec2(0, 0), size, rgbm.colors.white, uv1, uv2)
    ui.drawRectFilled(vec2(0, 0), size, rgbm(0, 0, 0, cfg.BG_DARKEN))
  end
end

-- Mouse handling for moving / resizing. Called from inside the panel's window.
local function handleMouse(size, screen, hovered)
  local s = live.scale
  local gripSize = 20 * s
  local gripP1 = vec2(size.x - gripSize, size.y - gripSize)

  local overGrip = false
  if hovered and not dragging and not resizing then
    local okGrip, res = pcall(ui.rectHovered, gripP1, size)
    overGrip = okGrip and res or false
  end

  if hovered and not dragging and not resizing then
    if ui.mouseDoubleClicked(ui.MouseButton.Left) then
      resetPosition()
      return overGrip
    end
    if ui.mouseClicked(ui.MouseButton.Left) then
      if overGrip then resizing = true else dragging = true end
    end

    local wheel = ui.mouseWheel()
    if wheel ~= 0 then
      live.scale = math.clamp(live.scale * (1.08 ^ wheel), MIN_SCALE, MAX_SCALE)
      saveTimer = 0.6
    end
  end

  if dragging or resizing then
    if ui.mouseDown(ui.MouseButton.Left) then
      local delta = ui.mouseDelta()
      if dragging then
        live.posX = live.posX + delta.x / screen.x
        live.posY = live.posY + delta.y / screen.y
      else
        -- panel is centred horizontally, so double the change to keep the corner under the cursor
        live.scale = math.clamp(live.scale + 2 * delta.x / BASE_W, MIN_SCALE, MAX_SCALE)
      end
    else
      dragging, resizing = false, false
      savePosition()
    end
  end

  return overGrip
end

local function drawHoverOverlay(size, accent, overGrip)
  local s = live.scale

  -- outline
  ui.drawRect(vec2(1, 1), size - 1, accent)

  -- help strip along the bottom
  local stripH = 20 * s
  ui.drawRectFilled(vec2(0, size.y - stripH), size, rgbm(0, 0, 0, 0.7))
  textCentered('Drag: move   |   Scroll / corner: size   |   Double-click: reset',
    10 * s, size.y - stripH + 4 * s, rgbm(0.9, 0.9, 0.9, 1), size.x)

  -- resize grip in the bottom-right corner
  local c = (overGrip or resizing) and rgbm.colors.white or accent
  local g = 14 * s
  local x2, y2 = size.x - 4 * s, size.y - 4 * s
  ui.drawLine(vec2(x2 - g, y2), vec2(x2, y2 - g), c, 2)
  ui.drawLine(vec2(x2 - g * 0.5, y2), vec2(x2, y2 - g * 0.5), c, 2)
end

local function drawPanel()
  local screen = ac.getUI().windowSize
  local s = live.scale
  local size = vec2(BASE_W * s, BASE_H * s)

  -- keep the panel fully on screen
  local halfFrac = math.min(size.x / 2 / screen.x, 0.5)
  live.posX = math.clamp(live.posX, halfFrac, 1 - halfFrac)
  live.posY = math.clamp(live.posY, 0, math.max(0, 1 - size.y / screen.y))
  local pos = vec2(screen.x * live.posX - size.x / 2, screen.y * live.posY)

  ui.transparentWindow('mapTimerPanel', pos, size, true, true, function()
    ui.pushDWriteFont(cfg.FONT)

    drawBackground(size)

    local accent = cfg.ACCENT_COLOR
    local remaining = state.remaining
    local inWarning = remaining ~= nil and remaining <= cfg.WARNING_SECONDS
    local ended = remaining ~= nil and remaining <= 0

    -- server name
    local name = cfg.SERVER_NAME
    if not name or name == '' then
      local okName, serverName = pcall(ac.getServerName)
      name = (okName and serverName and serverName ~= '') and serverName or 'SERVER'
    end
    textCentered(string.upper(name), 19 * s, 8 * s, rgbm.colors.white, size.x)

    -- accent line
    ui.drawRectFilled(vec2(size.x * 0.25, 34 * s), vec2(size.x * 0.75, 36 * s), accent)

    -- label
    local label = ended and 'MAP SWITCHING' or 'MAP SWITCHES IN'
    textCentered(label, 12 * s, 42 * s, rgbm(0.85, 0.85, 0.85, 1), size.x)

    -- timer (pulses red once the warning time is reached)
    local timerColor = rgbm.colors.white
    if inWarning then
      local pulse = 0.55 + 0.45 * math.sin(os.clock() * 6)
      timerColor = rgbm(1, 0.25 + 0.2 * (1 - pulse), 0.2, 1)
    end
    local timerText = remaining and formatTime(remaining) or '--:--'
    textCentered(timerText, 52 * s, 56 * s, timerColor, size.x)

    -- progress bar
    local barY1, barY2 = size.y - 9 * s, size.y - 4 * s
    local barX1, barX2 = 12 * s, size.x - 12 * s
    ui.drawRectFilled(vec2(barX1, barY1), vec2(barX2, barY2), rgbm(1, 1, 1, 0.15))
    if remaining and state.total and state.total > 0 then
      local fraction = math.clamp(remaining / state.total, 0, 1)
      ui.drawRectFilled(vec2(barX1, barY1),
        vec2(barX1 + (barX2 - barX1) * fraction, barY2),
        inWarning and rgbm(1, 0.25, 0.2, 1) or accent)
    end

    -- mouse: move / resize / reset
    local hovered = ui.windowHovered()
    local overGrip = handleMouse(size, screen, hovered)
    if hovered or dragging or resizing then
      drawHoverOverlay(size, accent, overGrip)
    end

    ui.popDWriteFont()
  end)
end

---------------------------------------------------------------------------
-- CSP callbacks
---------------------------------------------------------------------------

function script.drawUI(dt)
  drawUICalled = true
  drawPanel()
end

function script.update(dt)
  tick()

  -- save a moment after the player stops scrolling to resize
  if saveTimer > 0 and not dragging and not resizing then
    saveTimer = saveTimer - dt
    if saveTimer <= 0 then savePosition() end
  end

  -- Safety net: if this CSP build never calls script.drawUI, draw from update instead.
  if not drawUICalled then
    fallbackTimer = fallbackTimer + dt
    if fallbackTimer > 2 then drawPanel() end
  end
end
