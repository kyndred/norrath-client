-----------------------------------------------------------------------------
-- Norrath Cutscene  --  Mudlet package  (v1)
--
-- A letterboxed, full-window overlay for cinematic moments: spell effects,
-- summon animations, boss intros, level-up flourishes, title cards. Driven
-- entirely by the server over GMCP (`Client.Cutscene`), with a local demo
-- suite (`cut test`) so it can be exercised with no server round-trip.
--
-- What it can play (the real Mudlet envelope):
--   * ASCII / ANSI animations  -> frame-cycled into a MiniConsole (native, the
--                                 primary path for spell FX / summons)
--   * image sequences          -> Label background images, local file or a
--                                 downloaded URL, cycled as frames
--   * text title cards         -> big centered caption
--   * sound                    -> playSoundFile per shot
--   * video                    -> Mudlet cannot embed video; a `video` shot
--                                 opens the URL in the system browser instead
--
-- GMCP contract -- server sends `Client.Cutscene` = {
--   id="meteor", title="Meteor", skippable=true, dim=0.82,
--   shots = { <shot>, <shot>, ... } }
-- where each <shot> is one of:
--   { kind="ascii", frames={"..line1\n..line2", ...}, frame_ms=120, loops=1,
--     markup="hex"|"cecho"|"decho"|"plain", color="#ff8844",
--     caption="A meteor screams down", sfx="meteor.wav" }
--   { kind="image", images={path_or_url, ...}, frame_ms=100, caption=... }
--   { kind="text",  text="C H A P T E R  I", ms=1600, color="#e8e8e8" }
--   { kind="video", url="https://...", caption="opening in your browser" }
-- Server may also send `Client.CutsceneStop` = {} to abort a playing scene.
--
-- Player commands (client-side): type `cut` or `cut help`.
-----------------------------------------------------------------------------

NorrathCutscene = NorrathCutscene or {}
local C = NorrathCutscene

-- Sane state even if a build ever aborts partway: skip/finish must never
-- arithmetic on nil or leave the overlay unclosable.
C.token = C.token or 0
C.playing = C.playing or false

-- ---------------------------------------------------------------------------
-- theme
-- ---------------------------------------------------------------------------
local FONT_MONO = "'Menlo','DejaVu Sans Mono','Consolas',monospace"
local FONT_UI = "'Avenir Next','Segoe UI','Helvetica Neue',sans-serif"

-- Generation-suffixed names so hot-reloads don't collide with live Geyser
-- objects (Geyser keeps a per-profile name registry).
local function nm(base) return base .. "__c" .. tostring(C.gen or 0) end

local function num(v, d)
  v = tonumber(v)
  if v == nil then return d or 0 end
  return v
end

-- ---------------------------------------------------------------------------
-- build (runs once per hot-reload generation)
-- ---------------------------------------------------------------------------
function C.build()
  if C.built then return end

  -- Root overlay: covers the whole window, hidden until a scene plays. A
  -- click anywhere on it skips (if the scene is skippable).
  C.root = Geyser.Container:new({
    name = nm("ncRoot"), x = 0, y = 0, width = "100%", height = "100%",
  })

  -- Dim backdrop (its own Label so we can tune opacity per scene).
  C.backdrop = Geyser.Label:new({
    name = nm("ncBackdrop"), x = 0, y = 0, width = "100%", height = "100%",
  }, C.root)
  C.backdrop:setStyleSheet("background-color: rgba(4,5,9,210);")
  C.backdrop:setClickCallback(function() C.skip() end)

  -- Letterbox bars (top + bottom cinematic black bars).
  C.barTop = Geyser.Label:new({
    name = nm("ncBarTop"), x = 0, y = 0, width = "100%", height = "9%" }, C.root)
  C.barTop:setStyleSheet("background-color:#000000;")
  C.barTop:setClickCallback(function() C.skip() end)
  C.barBot = Geyser.Label:new({
    name = nm("ncBarBot"), x = 0, y = "91%", width = "100%", height = "9%" }, C.root)
  C.barBot:setStyleSheet("background-color:#000000;")
  C.barBot:setClickCallback(function() C.skip() end)

  -- Title (top bar) + skip hint (top-right).
  C.title = Geyser.Label:new({
    name = nm("ncTitle"), x = "4%", y = 0, width = "70%", height = "9%" }, C.root)
  C.title:setStyleSheet("background-color:transparent; color:#dfe6f5; font-family:" ..
    FONT_UI .. "; font-size:13pt; font-weight:bold; qproperty-alignment:'AlignLeft|AlignVCenter';")
  C.title:setClickCallback(function() C.skip() end)
  C.hint = Geyser.Label:new({
    name = nm("ncHint"), x = "70%", y = 0, width = "26%", height = "9%" }, C.root)
  C.hint:setStyleSheet("background-color:transparent; color:#7c8aa8; font-family:" ..
    FONT_UI .. "; font-size:10pt; qproperty-alignment:'AlignRight|AlignVCenter';")
  C.hint:echo("click / esc / 'cut skip' to skip &#9654;")
  C.hint:setClickCallback(function() C.skip() end)

  -- Stage: the ASCII MiniConsole and the image Label share the same central
  -- rectangle; only one is shown per shot.
  C.stage = Geyser.Container:new({
    name = nm("ncStage"), x = "8%", y = "12%", width = "84%", height = "70%" }, C.root)

  C.console = Geyser.MiniConsole:new({
    name = nm("ncConsole"), x = 0, y = 0, width = "100%", height = "100%" }, C.stage)
  pcall(function() C.console:setColor(6, 7, 12) end)
  pcall(function() C.console:setFontSize(12) end)
  pcall(function() C.console:setFont("Menlo") end)
  pcall(function() C.console:enableAutoWrap() end)

  C.image = Geyser.Label:new({
    name = nm("ncImage"), x = 0, y = 0, width = "100%", height = "100%" }, C.stage)
  C.image:setStyleSheet("background-color:transparent;")
  C.image:setClickCallback(function() C.skip() end)

  -- Click-to-skip over the stage. Geyser.MiniConsole has no setClickCallback
  -- (calling it crashes the whole build on stock Mudlet), so a transparent
  -- Label sits on top of the console/image and catches clicks instead.
  C.clickGuard = Geyser.Label:new({
    name = nm("ncClickGuard"), x = 0, y = 0, width = "100%", height = "100%" }, C.stage)
  C.clickGuard:setStyleSheet("background-color:transparent;")
  C.clickGuard:setClickCallback(function() C.skip() end)

  -- Caption bar (over the bottom letterbox).
  C.caption = Geyser.Label:new({
    name = nm("ncCaption"), x = "8%", y = "91%", width = "84%", height = "9%" }, C.root)
  C.caption:setStyleSheet("background-color:transparent; color:#e6ecf7; font-family:" ..
    FONT_UI .. "; font-size:12pt; qproperty-alignment:'AlignCenter';")
  C.caption:setClickCallback(function() C.skip() end)

  C.root:hide()
  C.playing = false
  C.token = 0
  C.built = true
end

-- ---------------------------------------------------------------------------
-- rendering helpers
-- ---------------------------------------------------------------------------
-- Center a multi-line frame inside the console's current column/row grid so
-- ASCII art sits mid-stage instead of hugging the top-left.
local function centerBlock(frame)
  local cols = 80
  local rows = 24
  pcall(function() cols = getColumnCount(nm("ncConsole")) or cols end)
  pcall(function() rows = getRowCount(nm("ncConsole")) or rows end)

  local lines = {}
  local widest = 0
  for line in (tostring(frame) .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    -- crude visible-width: strip Mudlet/decho color tags for measurement
    local vis = line:gsub("<[^>]->", ""):gsub("#%x%x%x%x%x%x", ""):gsub("#%d+,%d+,%d+", "")
    if #vis > widest then widest = #vis end
  end
  local padL = math.max(0, math.floor((cols - widest) / 2))
  local padT = math.max(0, math.floor((rows - #lines) / 2))
  local pad = string.rep(" ", padL)
  local out = {}
  for _ = 1, padT do out[#out + 1] = "" end
  for _, l in ipairs(lines) do out[#out + 1] = pad .. l end
  return table.concat(out, "\n")
end

-- Paint one ASCII/ANSI frame into the console using the shot's markup mode.
local function paintAscii(shot, frame)
  C.console:clear()
  local body = centerBlock(frame)
  local markup = shot.markup or "hex"
  if markup == "cecho" then
    C.console:cecho(body .. "\n")
  elseif markup == "decho" then
    C.console:decho(body .. "\n")
  elseif markup == "plain" then
    C.console:echo(body .. "\n")
  else -- "hex": wrap the whole frame in one hex color
    local col = shot.color or "#dfe6f5"
    C.console:hecho(col .. body .. "\n")
  end
end

-- Resolve an image reference to a local file path, downloading URLs first.
local function showImage(ref, cb)
  ref = tostring(ref or "")
  if ref:match("^https?://") then
    local dir = getMudletHomeDir() .. "/norrath_cutscene_cache"
    -- Mudlet bundles LuaFileSystem as the global `lfs`; make the cache dir.
    pcall(function() if lfs and lfs.mkdir then lfs.mkdir(dir) end end)
    local fname = dir .. "/" .. (ref:gsub("[^%w%.]", "_"))
    -- If already cached, use it; otherwise download then show.
    local f = io.open(fname, "rb")
    if f then f:close(); C.image:setBackgroundImage(fname); if cb then cb() end; return end
    local handlerId
    handlerId = registerAnonymousEventHandler("sysDownloadDone", function(_, path)
      if path == fname then
        pcall(function() C.image:setBackgroundImage(fname) end)
        if cb then cb() end
        killAnonymousEventHandler(handlerId)
      end
    end)
    downloadFile(fname, ref)
  else
    pcall(function() C.image:setBackgroundImage(ref) end)
    if cb then cb() end
  end
end

local function playSfx(sfx)
  if not sfx or sfx == "" then return end
  pcall(function() playSoundFile({ name = "norrath_cutscene", file = sfx }) end)
end

-- ---------------------------------------------------------------------------
-- playback engine (single active timer, cancellable via a monotonically
-- increasing token -- a new scene or a skip bumps the token so any queued
-- step from the previous run becomes a no-op)
-- ---------------------------------------------------------------------------
local function stepDone(token)
  return C.token ~= token
end

-- Play one shot, then call `next()`. Uses tempTimer for frame pacing.
local function playShot(shot, token, next)
  if stepDone(token) then return end
  shot = shot or {}
  local kind = shot.kind or "ascii"

  C.caption:echo(shot.caption or "")
  playSfx(shot.sfx)

  if kind == "text" then
    C.console:hide(); C.image:hide()
    C.title:echo(C.sceneTitle or "")
    -- big centered title card via the caption/stage: reuse the console area
    C.console:show(); C.console:clear()
    local col = shot.color or "#f2f5fb"
    C.console:hecho("\n\n\n" .. col .. centerBlock(tostring(shot.text or "")) .. "\n")
    tempTimer(num(shot.ms, 1500) / 1000, function()
      if stepDone(token) then return end
      next()
    end)
    return
  end

  if kind == "video" then
    C.console:show(); C.image:hide(); C.console:clear()
    local url = tostring(shot.url or "")
    C.console:hecho("#9fb2d6\n\n\n" .. centerBlock("[ video cutscene ]\n" ..
      (url ~= "" and "opening in your browser..." or "(no url)")) .. "\n")
    if url ~= "" then pcall(function() openWebPage(url) end) end
    tempTimer(num(shot.ms, 2500) / 1000, function()
      if stepDone(token) then return end
      next()
    end)
    return
  end

  if kind == "image" then
    C.console:hide(); C.image:show()
    local imgs = shot.images or {}
    if type(imgs) ~= "table" or #imgs == 0 then next(); return end
    local frameMs = num(shot.frame_ms, 120)
    local loops = num(shot.loops, 1)
    local totalFrames = #imgs * math.max(1, loops)
    local fi = 0
    local function tick()
      if stepDone(token) then return end
      fi = fi + 1
      if fi > totalFrames then next(); return end
      local ref = imgs[((fi - 1) % #imgs) + 1]
      showImage(ref)
      tempTimer(frameMs / 1000, tick)
    end
    tick()
    return
  end

  -- default: ascii
  C.image:hide(); C.console:show()
  local frames = shot.frames or {}
  if type(frames) ~= "table" or #frames == 0 then next(); return end
  local frameMs = num(shot.frame_ms, 120)
  local loops = num(shot.loops, 1)
  local totalFrames = #frames * math.max(1, loops)
  local fi = 0
  local function tick()
    if stepDone(token) then return end
    fi = fi + 1
    if fi > totalFrames then next(); return end
    paintAscii(shot, frames[((fi - 1) % #frames) + 1])
    tempTimer(frameMs / 1000, tick)
  end
  tick()
end

-- Play a whole cutscene payload.
function C.play(scene)
  if not C.built then C.build() end
  scene = scene or {}
  C.token = C.token + 1
  local token = C.token
  C.playing = true
  C.skippable = (scene.skippable ~= false)
  C.sceneTitle = tostring(scene.title or "")

  -- backdrop opacity (dim: 0..1 -> alpha)
  local dim = num(scene.dim, 0.82)
  local alpha = math.floor(math.max(0, math.min(1, dim)) * 255)
  C.backdrop:setStyleSheet("background-color: rgba(4,5,9," .. alpha .. ");")

  C.title:echo(C.sceneTitle)
  C.hint:echo(C.skippable and "click / esc / 'cut skip' to skip &#9654;" or "")
  C.caption:echo("")
  C.console:clear()
  C.root:show()
  pcall(function() C.root:raiseAll() end)

  local shots = scene.shots or {}
  if type(shots) ~= "table" or #shots == 0 then C.finish(); return end

  local i = 0
  local function nextShot()
    if stepDone(token) then return end
    i = i + 1
    if i > #shots then C.finish(); return end
    playShot(shots[i], token, nextShot)
  end
  nextShot()
end

function C.finish()
  C.token = (C.token or 0) + 1 -- invalidate any pending step
  C.playing = false
  if C.root then C.root:hide() end
  raiseEvent("norrathCutsceneDone")
end

function C.skip()
  if not C.playing then return end
  if not C.skippable then return end
  C.finish()
  -- Let the server know (so a server-driven scene can advance/continue).
  pcall(function() if sendGMCP then sendGMCP("Client.CutsceneSkip {}") end end)
end

-- ---------------------------------------------------------------------------
-- local demo scenes (client-side, no server needed) -- `cut test [key]`
-- ---------------------------------------------------------------------------
local function meteorFrames()
  local sky = [[
                    .
                   / \
                  /   \
                 ( *** )
                  \   /
                   \ /
                    '
]]
  local mid = [[


                  \\|//
                 --*O*--
                  //|\\


]]
  local hit = [[

              \   :   /
           `.  \  :  /  .'
        -- --==  BOOM  ==-- --
           .'  /  :  \  `.
              /   :   \

]]
  return { sky, mid, hit, mid, hit }
end

C.demos = {
  meteor = {
    id = "meteor", title = "Meteor", dim = 0.85,
    shots = {
      { kind = "text", text = "T H E   S K Y   B U R N S", ms = 1200, color = "#ffd27f" },
      { kind = "ascii", frames = meteorFrames(), frame_ms = 130, loops = 2,
        markup = "hex", color = "#ff8a4c", caption = "A meteor screams down from the heavens!" },
    },
  },
  summon = {
    id = "summon", title = "Summoning", dim = 0.9,
    shots = {
      { kind = "ascii", frame_ms = 120, loops = 3, markup = "hex", color = "#a78bfa",
        caption = "The circle blazes... something answers.",
        frames = {
          "\n      .  *  .\n    *   ( )   *\n      '  *  '\n",
          "\n     * ( O ) *\n    (   \\|/   )\n     * ( O ) *\n",
          "\n    *  \\ | /  *\n   -- (  @  ) --\n    *  / | \\  *\n",
          "\n     * ( O ) *\n    (   /|\\   )\n     * ( O ) *\n",
        } },
    },
  },
  levelup = {
    id = "levelup", title = "", dim = 0.6,
    shots = {
      { kind = "ascii", frame_ms = 110, loops = 2, markup = "hex", color = "#fde047",
        caption = "You have gained a level!",
        frames = {
          "\n        *\n     .  |  .\n   -- LEVEL --\n     '  |  '\n        *\n",
          "\n    *   |   *\n  .   \\ | /   .\n  --  * UP *  --\n  '   / | \\   '\n    *   |   *\n",
        } },
    },
  },
}

-- ---------------------------------------------------------------------------
-- `cut` / `cutscene` command suite (client-side)
-- ---------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local HELP = {
  "<b>Norrath Cutscene commands</b> (type 'cut' or 'cutscene'):",
  "  cut / cut help     - show this help",
  "  cut test [name]    - play a local demo: meteor, summon, levelup",
  "  cut skip           - skip the current cutscene",
  "  cut reload [path]  - dev: hot-reload from your working-copy .lua (set path once)",
}

function C.command(rest)
  local sub, arg = trim(rest):match("^(%S*)%s*(.-)$")
  sub = string.lower(sub or "")
  arg = trim(arg)
  if sub == "" or sub == "help" then
    for _, l in ipairs(HELP) do cecho("<cyan>" .. l .. "\n") end
  elseif sub == "test" or sub == "demo" then
    local key = arg ~= "" and arg or "meteor"
    local d = C.demos[key]
    if d then C.play(d) else
      cecho("<red>[Cutscene] no demo '" .. key .. "'. Try: meteor, summon, levelup\n")
    end
  elseif sub == "skip" or sub == "stop" then
    C.playing = true; C.skippable = true; C.finish()
    cecho("<green>[Cutscene] skipped.\n")
  elseif sub == "reload" then
    -- Dev hot-reload is opt-in and machine-local: `cut reload <path>` once sets
    -- C.devPath (session-persistent); no personal path ships in the package.
    if arg ~= "" then C.devPath = arg end
    if not C.devPath then
      cecho("<yellow>[Cutscene] dev reload is opt-in -- run 'cut reload <path-to-NorrathCutscene.lua>' "
        .. "once, then 'cut reload' / 'update cut' will hot-reload it.\n")
      return
    end
    local ok, err = pcall(dofile, C.devPath)
    if not ok then cecho("<red>[Cutscene] reload failed: " .. tostring(err) .. "\n") end
  else
    cecho("<red>[Cutscene] unknown subcommand '" .. sub .. "'. Try 'cut help'.\n")
  end
end

-- ---------------------------------------------------------------------------
-- events + aliases (reload-safe)
-- ---------------------------------------------------------------------------
if C.handlers then
  for _, id in ipairs(C.handlers) do pcall(killAnonymousEventHandler, id) end
end
C.handlers = {}
local function on(ev, fn) C.handlers[#C.handlers + 1] = registerAnonymousEventHandler(ev, fn) end

on("gmcp.Client.Cutscene", function() C.play(NorrathCutscene.gmcp and NorrathCutscene.gmcp() or gmcp.Client.Cutscene) end)
on("gmcp.Client.CutsceneStop", function() C.playing = true; C.skippable = true; C.finish() end)

if C.aliasIds then
  for _, id in ipairs(C.aliasIds) do pcall(killAlias, id) end
end
C.aliasIds = {}
C.aliasIds[#C.aliasIds + 1] =
  tempAlias("^\\s*(cut|cutscene)\\b\\s*(.*)$", [[NorrathCutscene.command(matches[3])]])
C.aliasIds[#C.aliasIds + 1] =
  tempAlias("^\\s*update\\s+(cut|cutscene)\\s*$", [[NorrathCutscene.command("reload")]])

-- The skip hint promises Esc; bind it. skip() no-ops unless a scene is
-- actually playing, so grabbing the key is otherwise harmless.
if C.escKeyId then pcall(killKey, C.escKeyId) end
pcall(function()
  C.escKeyId = tempKey(mudlet.key.Escape, [[NorrathCutscene.skip()]])
end)

-- Read the live GMCP table (fresh each event).
function C.gmcp() return gmcp and gmcp.Client and gmcp.Client.Cutscene or nil end

-- Hot-reload: hide the previous generation's overlay, bump the generation so
-- new widget names don't collide, then rebuild fresh.
if C.root then pcall(function() C.root:hide() end) end
C.gen = (C.gen or 0) + 1
C.built = false
-- Guarded build: widgets are visible the moment they are created and only
-- hidden at the end of build(), so an error partway through would otherwise
-- strand a black, unclosable overlay over the whole window (seen live when
-- MiniConsole:setClickCallback didn't exist). On failure, hide whatever got
-- built and say so instead.
local buildOk, buildErr = pcall(C.build)
if buildOk then
  cecho("<green>[Norrath Cutscene]<reset> v2 loaded. Try 'cut test meteor', or 'cut help'.\n")
else
  if C.root then pcall(function() C.root:hide() end) end
  cecho("<red>[Norrath Cutscene] failed to build the overlay: " ..
    tostring(buildErr) .. " -- cutscenes disabled.\n")
end
