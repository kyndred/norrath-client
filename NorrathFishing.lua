-----------------------------------------------------------------------------
-- Norrath Fishing  --  Mudlet package  (v1)
--
-- The fishing-minigame widget. Entirely server-driven over GMCP
-- (`Client.Fishing`): the server owns all game state and pushes it at least
-- once a second while you fish; this package renders it (animated ASCII
-- water, bobber, fish and jump arcs), shows the line-durability + distance
-- gauges, flashes full-widget alerts ("IT JUMPED -- STOP REELING!"), and --
-- while fishing mode is active ONLY -- binds hotkeys:
--
--     w        reel            a / d    give line left / right
--     space    cast / hook     1-5      pick a spot      esc  stop
--
-- Every key press just sends the hidden `+fishkey <k>` command; text-client
-- players type the same thing by hand. The keys are created on the first
-- `active=true` payload and KILLED on every exit path: an `active=false`
-- payload, a 15s GMCP-silence watchdog (the server heartbeats each second
-- while you fish), disconnect, package hot-reload, and the local `fishing
-- stop` alias. Your W key can never be left stolen.
--
-- ASCII animation: 2-3 frame flipbooks composed in layers (static shore ->
-- phase-shifted water -> sprite at a fixed anchor), so every loop keeps
-- temporal continuity: same canvas size, one small delta per frame, one
-- glyph palette per object. Fish sprites come in three authored sizes keyed
-- to the server's `heft` reveal; rare (`glint`) fish render gold.
--
-- Player commands (client-side): type `fishing help`.
-----------------------------------------------------------------------------

NorrathFishing = NorrathFishing or {}
local F = NorrathFishing

local FONT_UI = "'Avenir Next','Segoe UI','Helvetica Neue',sans-serif"

-- Generation-suffixed names so hot-reloads never collide in Geyser's registry.
local function nm(base) return base .. "__f" .. tostring(F.gen or 0) end

local function num(v, d)
  v = tonumber(v)
  if v == nil then return d or 0 end
  return v
end

-- ---------------------------------------------------------------------------
-- canvas geometry (characters)
-- ---------------------------------------------------------------------------
local COLS = 52
local ROWS = 14
local WATERLINE = 7          -- row the water surface sits on (1-based)

-- ---------------------------------------------------------------------------
-- sprite library
-- Continuity rules: every frame set shares its sibling's dimensions; each
-- object keeps one glyph palette across all its loops; animation is one
-- small delta per frame (waves shift phase one cell, the bobber changes
-- glyph in place -- anchors never move).
-- ---------------------------------------------------------------------------

-- Water surface: one row, phase-shifted per animation tick.
local WAVE = "~   ~    ~   ~     ~    ~   ~    ~     ~   ~    ~   ~    ~ "

-- Bobber states (drawn AT the anchor column on/around the waterline).
--   idle: bobs in place;  nibble: quick dip;  under: yanked below + splash.
local BOBBER = {
  idle   = { "o", "o" },       -- glyph row alternates surface/half-sunk below
  nibble = { "o", "," },
  under  = { "!", "!" },
}

-- Fish sprites by size (heft 1-2 small, 3 medium, 4-5 huge), facing left
-- (toward open water). Two swim frames each -- tail flick only, same width.
local FISH = {
  small = {
    { "<><" },
    { "<><" },
  },
  medium = {
    { "<'((((>{" },
    { "<'((((>}" },
  },
  huge = {
    { " _______    ",
      "<'(((((((>=<" },
    { " _______    ",
      "<'(((((((>~<" },
  },
}

-- Jump arc (3 beats): breach -> airborne -> splash. Drawn above the
-- waterline at the fish's anchor; same box every frame.
local JUMP = {
  small = {
    { "        ", "  <>\\   ", " _/~~\\_ " },
    { "  <>< ! ", "        ", " ~    ~ " },
    { "        ", "   \\<>  ", " _/~~\\_ " },
  },
  medium = {
    { "          ", "  <'(((\\  ", " _/~~~~\\_ " },
    { " <'((((>{ ", "          ", " ~ ~  ~ ~ " },
    { "          ", "  \\(((('> ", " _/~~~~\\_ " },
  },
  huge = {
    { "            ", "  <'((((((\\ ", " _/~~~~~~\\_ " },
    { " <'(((((((>=", "            ", " ~  ~  ~  ~ " },
    { "            ", " \\((((((('> ", " _/~~~~~~\\_ " },
  },
}

-- Landed flop (on the "deck" bottom rows) and line-snap recoil.
local FLOP = {
  { "  <>< ", " _____" },
  { "  ><> ", " _____" },
}
local SNAP = {
  "   ~~~\\_",
  "  ~~~~_/",
}

-- ---------------------------------------------------------------------------
-- build (once per hot-reload generation)
-- ---------------------------------------------------------------------------
function F.build()
  if F.built then return end

  F.root = Geyser.Container:new({
    name = nm("nfRoot"), x = "14%", y = "12%", width = "72%", height = "72%",
  })

  F.backdrop = Geyser.Label:new({
    name = nm("nfBackdrop"), x = 0, y = 0, width = "100%", height = "100%",
  }, F.root)
  F.backdrop:setStyleSheet(
    "background-color: rgba(5,10,18,235); border: 2px solid #1d3a5f; border-radius: 8px;")

  F.header = Geyser.Label:new({
    name = nm("nfHeader"), x = "3%", y = "1%", width = "70%", height = "9%" }, F.root)
  F.header:setStyleSheet("background-color:transparent; color:#bfe3ff; font-family:" ..
    FONT_UI .. "; font-size:13pt; font-weight:bold; qproperty-alignment:'AlignLeft|AlignVCenter';")

  F.hint = Geyser.Label:new({
    name = nm("nfHint"), x = "60%", y = "1%", width = "37%", height = "9%" }, F.root)
  F.hint:setStyleSheet("background-color:transparent; color:#5f7ba3; font-family:" ..
    FONT_UI .. "; font-size:9pt; qproperty-alignment:'AlignRight|AlignVCenter';")
  F.hint:echo("esc / 'fish' to stop")

  -- The animated stage.
  F.console = Geyser.MiniConsole:new({
    name = nm("nfConsole"), x = "3%", y = "11%", width = "94%", height = "56%" }, F.root)
  pcall(function() F.console:setColor(6, 10, 18) end)
  pcall(function() F.console:setFontSize(11) end)
  pcall(function() F.console:setFont("Menlo") end)

  -- Gauges: line durability + landing progress.
  F.lineGauge = Geyser.Gauge:new({
    name = nm("nfLine"), x = "3%", y = "69%", width = "45%", height = "7%" }, F.root)
  F.lineGauge.front:setStyleSheet("background-color:#3fbf5f; border-radius:4px;")
  F.lineGauge.back:setStyleSheet("background-color:#20242e; border-radius:4px;")
  F.lineGauge:setText("line")

  F.distGauge = Geyser.Gauge:new({
    name = nm("nfDist"), x = "52%", y = "69%", width = "45%", height = "7%" }, F.root)
  F.distGauge.front:setStyleSheet("background-color:#3f8fbf; border-radius:4px;")
  F.distGauge.back:setStyleSheet("background-color:#20242e; border-radius:4px;")
  F.distGauge:setText("distance")

  -- Key legend footer.
  F.legend = Geyser.Label:new({
    name = nm("nfLegend"), x = "3%", y = "78%", width = "94%", height = "19%" }, F.root)
  F.legend:setStyleSheet("background-color:transparent; color:#7c8aa8; font-family:" ..
    FONT_UI .. "; font-size:10pt; qproperty-alignment:'AlignCenter|AlignTop';")

  -- Full-stage alert layer (jump / big-hook / rare-hook), hidden until fired.
  F.alert = Geyser.Label:new({
    name = nm("nfAlert"), x = "5%", y = "22%", width = "90%", height = "36%" }, F.root)
  F.alert:hide()

  F.root:hide()
  F.built = true
end

-- ---------------------------------------------------------------------------
-- hotkeys -- created ONLY while fishing; killed on every exit path
-- ---------------------------------------------------------------------------
local function sendKey(k)
  send("+fishkey " .. k, false)
end

-- Mudlet key-name spellings vary a little across versions; try candidates.
local function bindKey(names, code)
  for _, name in ipairs(names) do
    local ok, id = pcall(tempKey, name, code)
    if ok and id then return id end
  end
  return nil
end

function F.makeKeys()
  if F.keyIds then return end
  F.keyIds = {}
  local binds = {
    { { "w" }, [[NorrathFishing.key("w")]] },
    { { "a" }, [[NorrathFishing.key("a")]] },
    { { "d" }, [[NorrathFishing.key("d")]] },
    { { "space", "Space" }, [[NorrathFishing.key("space")]] },
    { { "escape", "Escape", "esc" }, [[NorrathFishing.key("esc")]] },
    { { "1" }, [[NorrathFishing.key("1")]] },
    { { "2" }, [[NorrathFishing.key("2")]] },
    { { "3" }, [[NorrathFishing.key("3")]] },
    { { "4" }, [[NorrathFishing.key("4")]] },
    { { "5" }, [[NorrathFishing.key("5")]] },
  }
  for _, b in ipairs(binds) do
    local id = bindKey(b[1], b[2])
    if id then F.keyIds[#F.keyIds + 1] = id end
  end
end

function F.key(k) sendKey(k) end

function F.killKeys()
  if not F.keyIds then return end
  for _, id in ipairs(F.keyIds) do pcall(killKey, id) end
  F.keyIds = nil
end

-- ---------------------------------------------------------------------------
-- teardown -- THE single local exit path
-- ---------------------------------------------------------------------------
function F.teardown(reason)
  F.killKeys()
  if F.watchdog then pcall(killTimer, F.watchdog); F.watchdog = nil end
  if F.animTimer then pcall(killTimer, F.animTimer); F.animTimer = nil end
  if F.alertTimer then pcall(killTimer, F.alertTimer); F.alertTimer = nil end
  F.active = false
  F.state = nil
  if F.alert then F.alert:hide() end
  if F.root then F.root:hide() end
  if reason and reason ~= "" then
    cecho("<cyan>[Fishing] " .. reason .. "\n")
  end
end

-- Watchdog: the server pushes at least once a second while fishing; if the
-- feed goes silent (reload, crash, dropped link), free the keys and hide.
function F.armWatchdog()
  if F.watchdog then pcall(killTimer, F.watchdog) end
  F.watchdog = tempTimer(15, function()
    F.watchdog = nil
    if F.active then F.teardown("lost the server -- packing up (keys freed).") end
  end)
end

-- ---------------------------------------------------------------------------
-- stage rendering (layered canvas, ~3 fps flipbook)
-- ---------------------------------------------------------------------------
local function blank()
  local rows = {}
  for r = 1, ROWS do rows[r] = string.rep(" ", COLS) end
  return rows
end

-- Stamp `text` onto row `r` starting at col `c` (1-based), clipped.
local function stamp(rows, r, c, text)
  if r < 1 or r > ROWS or not text then return end
  local row = rows[r]
  if c < 1 then text = text:sub(2 - c); c = 1 end
  if text == "" then return end
  local avail = COLS - c + 1
  if #text > avail then text = text:sub(1, avail) end
  rows[r] = row:sub(1, c - 1) .. text .. row:sub(c + #text)
end

local function waterRow(phase)
  local off = (phase % 4) + 1
  return (WAVE .. WAVE):sub(off, off + COLS - 1)
end

local function fishSize(heft)
  if (heft or 1) >= 4 then return "huge" end
  if (heft or 1) == 3 then return "medium" end
  return "small"
end

local function mirror(s)
  -- Flip a fish sprite line horizontally (crude but consistent).
  local flipped = s:reverse()
  flipped = flipped:gsub("[<>%(%){}%[%]/\\]", {
    ["<"] = ">", [">"] = "<", ["("] = ")", [")"] = "(",
    ["{"] = "}", ["}"] = "{", ["["] = "]", ["]"] = "[",
    ["/"] = "\\", ["\\"] = "/",
  })
  return flipped
end

-- Compose and paint the stage for the current state + animation phase.
function F.render()
  if not F.state or not F.active then return end
  local st = F.state
  local phase = F.phase or 0
  local rows = blank()

  -- Layer 1: sky line + boat/shore (static, right edge).
  stamp(rows, WATERLINE - 1, COLS - 7, "\\____/")   -- your hull, right side
  -- Layer 2: water (phase-shifted flipbook rows).
  stamp(rows, WATERLINE, 1, waterRow(phase))
  stamp(rows, WATERLINE + 3, 1, waterRow(phase + 2))
  stamp(rows, WATERLINE + 6, 1, waterRow(phase + 1))

  local color = "#7fd4ff"

  if st.state == "spot" then
    -- Numbered spot markers across the water at fixed anchors.
    local spots = st.spots or {}
    local n = math.max(1, #spots)
    for i, s in ipairs(spots) do
      local c = math.floor(COLS * i / (n + 1))
      local sel = (st.selected or 0) + 1 == i
      stamp(rows, WATERLINE - 2, c - 1, sel and (">" .. i .. "<") or (" " .. i .. " "))
      stamp(rows, WATERLINE + 1, c, "|")
    end
    local sel = spots[(st.selected or 0) + 1]
    stamp(rows, ROWS - 1, 2, sel and ("> " .. (sel.name or "") .. " -- " .. (sel.hint or "")) or "")
    stamp(rows, ROWS, 2, "[1-5] choose spot   [space] cast")
  elseif st.state == "waiting" then
    local bob = st.bobber or {}
    local anchor = math.floor(COLS / 2)
    local set = bob.nibble and BOBBER.nibble or BOBBER.idle
    local glyph = set[(phase % 2) + 1]
    local dipped = bob.nibble or (not bob.nibble and (phase % 2) == 1)
    stamp(rows, WATERLINE + (dipped and 1 or 0) - 1, anchor, glyph)
    if bob.nibble then stamp(rows, WATERLINE, anchor - 2, "( ) )") end
    -- line from hull to bobber
    stamp(rows, WATERLINE - 2, anchor + 2, string.rep("_", math.max(0, COLS - 9 - anchor)))
    stamp(rows, ROWS, 2, "[space] quick reel-in    ...watch the bobber...")
    if st.chum then stamp(rows, ROWS - 1, 2, "the water BOILS with chummed fish") end
  elseif st.state == "bite" then
    local anchor = math.floor(COLS / 2)
    stamp(rows, WATERLINE + 1, anchor - 1, "!o!")
    stamp(rows, WATERLINE, anchor - 3, ")  (  ) (")
    stamp(rows, math.floor(ROWS / 2), math.floor(COLS / 2) - 8, "S T R I K E !")
    stamp(rows, ROWS, 2, "[SPACE] SET THE HOOK!")
    color = "#ffd27f"
  elseif st.state == "fight" and st.fight then
    local f = st.fight
    local size = fishSize(f.heft)
    -- distance maps the fish's anchor: far left (open water) -> hull right.
    local frac = math.min(1, math.max(0, num(f.distance, 50) / 160))
    local anchor = math.max(3, math.floor((COLS - 16) * (1 - frac)) + 3)
    if f.jump then
      local arc = JUMP[size]
      local frame = arc[(phase % #arc) + 1]
      for i, line in ipairs(frame) do
        stamp(rows, WATERLINE - #frame + i, anchor, line)
      end
      color = "#ff6b6b"
    else
      local swim = FISH[size]
      local frame = swim[(phase % #swim) + 1]
      for i, line in ipairs(frame) do
        local text = line
        if f.pull == "right" then text = mirror(line) end
        stamp(rows, WATERLINE + 1 + i, anchor, text)
      end
      if f.pull == "left" then
        stamp(rows, WATERLINE + 1, anchor - 3, "<<<")
      elseif f.pull == "right" then
        stamp(rows, WATERLINE + 1, anchor + 10, ">>>")
      end
    end
    -- taut line from hull toward the fish
    stamp(rows, WATERLINE - 1, anchor + 4, string.rep("-", math.max(0, COLS - 12 - anchor)) .. "\\")
    stamp(rows, ROWS, 2, "[w] reel   [a]/[d] give line WITH the pull   don't reel a JUMP")
    if f.glint then color = "#ffd700" end
  end

  -- One-shot result beat (landed flop / snap recoil) rides on top briefly.
  if F.resultShow and F.resultShow.until_phase >= phase then
    local res = F.resultShow.result
    if res.outcome == "landed" then
      local flop = FLOP[(phase % 2) + 1]
      stamp(rows, ROWS - 3, COLS - 12, flop[1])
      stamp(rows, ROWS - 2, COLS - 12, flop[2])
      stamp(rows, math.floor(ROWS / 2), 4,
        "LANDED: " .. tostring(res.name or "") .. "  (" .. tostring(res.size or "?") .. " lbs)")
      if res.new_species then
        stamp(rows, math.floor(ROWS / 2) + 1, 4, "* NEW SPECIES RECORDED *")
      end
      color = res.rare and "#ffd700" or "#7dff9a"
    elseif res.outcome == "snapped" then
      stamp(rows, WATERLINE - 2, math.floor(COLS / 2), SNAP[(phase % 2) + 1])
      stamp(rows, math.floor(ROWS / 2), math.floor(COLS / 2) - 6, "* S N A P *")
      color = "#ff6b6b"
    end
  else
    F.resultShow = nil
  end

  F.console:clear()
  F.console:hecho(color .. table.concat(rows, "\n") .. "\n")
end

function F.animate()
  if not F.active then return end
  F.phase = (F.phase or 0) + 1
  pcall(F.render)
  F.animTimer = tempTimer(0.35, F.animate)
end

-- ---------------------------------------------------------------------------
-- alerts (full-widget flash)
-- ---------------------------------------------------------------------------
local ALERT_STYLES = {
  jump = "background-color: rgba(120,10,10,235); color:#ffe3e3; border: 3px solid #ff5252;",
  hooked_big = "background-color: rgba(110,70,0,235); color:#fff3d6; border: 3px solid #ffb742;",
  hooked_rare = "background-color: rgba(90,75,0,235); color:#fffbe0; border: 3px solid #ffd700;",
}

function F.showAlert(alert)
  if not F.alert then return end
  local style = ALERT_STYLES[alert.kind or "jump"] or ALERT_STYLES.jump
  F.alert:setStyleSheet(style .. " font-family:" .. FONT_UI ..
    "; font-size:20pt; font-weight:bold; border-radius:10px; qproperty-alignment:'AlignCenter'; qproperty-wordWrap:true;")
  F.alert:echo(tostring(alert.text or ""))
  F.alert:show()
  pcall(function() F.alert:raiseAll() end)
  if F.alertTimer then pcall(killTimer, F.alertTimer) end
  F.alertTimer = tempTimer(num(alert.ms, 2000) / 1000, function()
    F.alertTimer = nil
    if F.alert then F.alert:hide() end
  end)
end

-- ---------------------------------------------------------------------------
-- GMCP intake
-- ---------------------------------------------------------------------------
function F.onGmcp(payload)
  payload = payload or (gmcp and gmcp.Client and gmcp.Client.Fishing) or nil
  if not payload then return end

  if not payload.active then
    if F.active then F.teardown() end
    return
  end

  if not F.built then F.build() end
  local wasActive = F.active
  F.active = true
  F.state = payload
  F.armWatchdog()

  if not wasActive then
    F.makeKeys()
    F.phase = 0
    F.root:show()
    pcall(function() F.root:raiseAll() end)
    if not F.animTimer then F.animate() end
  end

  F.header:echo("Fishing -- " .. tostring(payload.water_name or payload.water or ""))

  -- Gauges.
  if payload.state == "fight" and payload.fight then
    local f = payload.fight
    local hp, mx = num(f.line_hp, 0), math.max(1, num(f.line_max, 100))
    F.lineGauge:setValue(hp, mx, "line " .. hp .. "/" .. mx)
    local frac = hp / mx
    local color = frac > 0.5 and "#3fbf5f" or (frac > 0.25 and "#d9a53f" or "#d94040")
    local thick = (num(f.heft, 1) >= 4) and " border: 2px solid #ff5252;" or ""
    F.lineGauge.front:setStyleSheet("background-color:" .. color .. "; border-radius:4px;" .. thick)
    local dist = num(f.distance, 0)
    F.distGauge:setValue(math.max(0, 160 - dist), 160, "distance " .. dist)
    F.distGauge:show(); F.lineGauge:show()
  else
    F.lineGauge:setValue(100, 100, "line ready")
    F.lineGauge.front:setStyleSheet("background-color:#2e4d6b; border-radius:4px;")
    F.distGauge:setValue(0, 160, "")
  end

  -- Key legend from the server (source of truth).
  local keys = payload.keys or {}
  local order = { "space", "w", "a", "d", "1-5", "esc" }
  local parts = {}
  for _, k in ipairs(order) do
    if keys[k] then parts[#parts + 1] = "<b>" .. k .. "</b> " .. keys[k] end
  end
  F.legend:echo(table.concat(parts, "   &#183;   "))

  -- One-shots.
  if payload.alert then F.showAlert(payload.alert) end
  if payload.result then
    F.resultShow = { result = payload.result, until_phase = (F.phase or 0) + 8 }
  end

  pcall(F.render)
end

-- ---------------------------------------------------------------------------
-- `fishing` command suite (client-side)
-- ---------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local HELP = {
  "<b>Norrath Fishing package</b> (type 'fishing <sub>'):",
  "  fishing help          - this help",
  "  fishing stop          - local teardown (also frees the hotkeys)",
  "  fishing test          - render a local demo state (no server needed)",
  "  fishing reload [path] - dev: hot-reload from a working-copy .lua",
  "The game itself: say <b>fish</b> in promising water. While fishing:",
  "  w reel   a/d give line   space cast/hook   1-5 spot   esc stop",
}

function F.command(rest)
  local sub, arg = trim(rest):match("^(%S*)%s*(.-)$")
  sub = string.lower(sub or "")
  arg = trim(arg)
  if sub == "" or sub == "help" then
    for _, l in ipairs(HELP) do cecho("<cyan>" .. l .. "\n") end
  elseif sub == "stop" then
    F.teardown("stopped locally.")
  elseif sub == "test" or sub == "demo" then
    if not F.built then F.build() end
    F.onGmcp({
      active = true, seq = 1, state = "fight", water = "saltwater",
      water_name = "The Demo Sea",
      fight = { line_hp = 62, line_max = 100, distance = 74, pull = "left",
                jump = false, heft = tonumber(arg) or 4, glint = arg == "gold",
                hint = "demo" },
      keys = { space = "cast/hook", w = "reel", a = "give left", d = "give right",
               ["1-5"] = "spot", esc = "stop" },
      alert = { kind = "hooked_big", text = "SOMETHING HUGE TAKES THE HOOK -- BRACE YOURSELF!", ms = 1800 },
    })
    cecho("<green>[Fishing] demo state shown ('fishing stop' to clear; arg: 1-5 heft or 'gold').\n")
  elseif sub == "reload" then
    if arg ~= "" then F.devPath = arg end
    if not F.devPath then
      cecho("<yellow>[Fishing] dev reload is opt-in -- 'fishing reload <path-to-NorrathFishing.lua>' once.\n")
      return
    end
    local ok, err = pcall(dofile, F.devPath)
    if not ok then cecho("<red>[Fishing] reload failed: " .. tostring(err) .. "\n") end
  else
    cecho("<red>[Fishing] unknown subcommand '" .. sub .. "'. Try 'fishing help'.\n")
  end
end

-- ---------------------------------------------------------------------------
-- events + aliases (reload-safe)
-- ---------------------------------------------------------------------------
if F.handlers then
  for _, id in ipairs(F.handlers) do pcall(killAnonymousEventHandler, id) end
end
F.handlers = {}
local function on(ev, fn) F.handlers[#F.handlers + 1] = registerAnonymousEventHandler(ev, fn) end

on("gmcp.Client.Fishing", function() F.onGmcp() end)
on("sysDisconnectionEvent", function() F.teardown() end)

if F.aliasIds then
  for _, id in ipairs(F.aliasIds) do pcall(killAlias, id) end
end
F.aliasIds = {}
F.aliasIds[#F.aliasIds + 1] =
  tempAlias("^\\s*fishing\\s+(help|stop|test|demo|reload)\\b\\s*(.*)$",
    [[NorrathFishing.command(matches[2] .. " " .. (matches[3] or ""))]])
F.aliasIds[#F.aliasIds + 1] =
  tempAlias("^\\s*update\\s+fishing\\s*$", [[NorrathFishing.command("reload")]])

-- Hot-reload preamble: free the previous generation's keys/timers/overlay
-- BEFORE bumping the generation, so nothing of the old build lingers.
F.teardown()
if F.root then pcall(function() F.root:hide() end) end
F.gen = (F.gen or 0) + 1
F.built = false
F.build()
cecho("<green>[Norrath Fishing]<reset> v1 loaded. Say 'fish' at promising water; 'fishing help' for keys.\n")
