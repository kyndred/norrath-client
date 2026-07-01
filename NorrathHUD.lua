-----------------------------------------------------------------------------
-- Norrath HUD  --  Mudlet package  (v5: fog-of-war Map panel)
--
-- A Geyser HUD fed entirely by the server's GMCP. Each panel is a draggable,
-- resizable, self-persisting Adjustable.Container with a titled frame.
--
--   gmcp.Char.Vitals   -> HP / MN / MV / TP gauges (gradient, overlaid text)
--   gmcp.Char.Base     -> name / level header
--   gmcp.Group.Members -> party rows (HP + TP) + live x/y/z/room/zone (Map overlay)
--   gmcp.Char.Target   -> target HP bar (hidden when no target)
--   gmcp.Char.Enemies  -> clickable enemy list (click to attack)
--   gmcp.Char.Pets     -> clickable pet list (click to select) + command row
--   gmcp.Char.Abilities-> clickable spell / weaponskill buttons
--   gmcp.Room.Map      -> the character's revealed-room memory (fog of war) +
--                         current vision radius; drives the Map panel below
--
-- Map panel: draws only rooms the character has ever seen (server-enforced
-- fog of war via `char.room_memory`); rooms within current vision radius are
-- "fresh" (live marker data), rooms outside it are dimmed/dashed (last-known
-- cached snapshot). Click a room you've physically entered to auto-walk
-- there (`travelto <id>`); rooms you've only seen at a distance are shown
-- but not clickable. Mouseover any room for its metadata via the native Qt
-- tooltip. Party members in the same zone are overlaid as small dots.
--
-- Right-click any panel's title bar for its toggle menu (Show Mana, Show
-- Numbers, etc.) -- see `defaultCfg()` below for the full toggle set. Type
-- `ui` or `ui help` in game for the client-side command suite (refresh,
-- reset, show/hide, toggle <panel>, dev reload).
-----------------------------------------------------------------------------

NorrathHUD = NorrathHUD or {}
local H = NorrathHUD

local ADJ = (Adjustable and Adjustable.Container) and true or false
local Container = ADJ and Adjustable.Container or Geyser.Container

-- ---------------------------------------------------------------------------
-- theme
-- ---------------------------------------------------------------------------
local FONT = "'Avenir Next','Segoe UI','Helvetica Neue',sans-serif"
local PANEL_BG = "background-color: rgba(15,17,23,238); border:1px solid #262c3a; border-radius:10px;"
local TITLE_FG = "#8ea0bf"

local function grad(light, dark)
  return "qlineargradient(x1:0,y1:0,x2:0,y2:1, stop:0 " .. light .. ", stop:1 " .. dark .. ")"
end

-- (light, dark) gradient pairs for the vitals.
local GRAD = {
  hp_hi = { "#34d399", "#059669" },
  hp_md = { "#fbbf24", "#d97706" },
  hp_lo = { "#f87171", "#dc2626" },
  mn    = { "#60a5fa", "#2563eb" },
  mv    = { "#a3e635", "#4d7c0f" },
  tp    = { "#2dd4bf", "#0d9488" },
  tp_rdy = { "#fbbf24", "#f59e0b" },
}

local function hpGrad(cur, mx)
  local f = (tonumber(cur) or 0) / math.max(1, tonumber(mx) or 1)
  if f > 0.5 then return GRAD.hp_hi elseif f > 0.25 then return GRAD.hp_md else return GRAD.hp_lo end
end

-- Button style with a hover highlight (Qt stylesheet on the QLabel).
local function btnStyle(accent)
  accent = accent or "#3b82f6"
  return "QLabel{ background-color:#171b26; color:#e5e7eb; border:1px solid #2b3140;" ..
         " border-radius:6px; padding:2px 6px; font-family:" .. FONT .. "; font-size:10pt;" ..
         " qproperty-alignment:'AlignLeft|AlignVCenter'; }" ..
         " QLabel:hover{ background-color:#232a3a; border-color:" .. accent .. "; color:#ffffff; }"
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
function H.gmcp(path)
  local t = gmcp
  for part in string.gmatch(path, "[^.]+") do
    if type(t) ~= "table" then return nil end
    t = t[part]
  end
  return t
end

local function num(v, d)
  v = tonumber(v)
  if v == nil then return d or 0 end
  return v
end

-- Fraction cur/max, clamped to a sane denominator.
local function frac(cur, max)
  return num(cur) / math.max(1, num(max, 1))
end

-- Generation-suffixed name so hot-reloads don't collide with existing Geyser
-- objects (Geyser keeps a name registry for the profile's lifetime).
local function nm(base) return base .. "__g" .. tostring(H.gen or 0) end

H.containers = H.containers or {}
H.panelDefaults = H.panelDefaults or {}

local function panel(name, x, y, w, h, title)
  H.panelDefaults[name] = { x = x, y = y, w = w, h = h }
  local o = { name = nm(name), x = x, y = y, width = w, height = h }
  if ADJ then
    o.titleText = title
    o.titleTxtColor = TITLE_FG
    o.adjLabelstyle = PANEL_BG
    o.buttonFontSize = 9
    o.padding = 6
  end
  local ok, c = pcall(function() return Container:new(o) end)
  if not ok then c = Geyser.Container:new({ name = nm(name), x = x, y = y, width = w, height = h }) end
  H.containers[#H.containers + 1] = c
  return c
end

local function gauge(name, parent, x, y, w, h)
  local g = Geyser.Gauge:new({ name = nm(name), x = x, y = y, width = w, height = h }, parent)
  g.text:setStyleSheet("color:#f8fafc; font-weight:bold; font-family:" .. FONT .. "; font-size:9pt;")
  return g
end

local function setGauge(g, cur, max, label, pair)
  g:setValue(num(cur), num(max, 1), "<center>" .. label .. "</center>")
  g.front:setStyleSheet("background-color:" .. grad(pair[1], pair[2]) .. "; border-radius:5px;")
  g.back:setStyleSheet("background-color:#20262f; border:1px solid #2b3140; border-radius:5px;")
end

-- Lazy pool of Geyser.Labels reused across refreshes.
function H.poolLabel(pool, i, parent, x, y, w, h)
  pool[i] = pool[i] or Geyser.Label:new(
    { name = nm(pool.prefix .. "_" .. i), x = x, y = y, width = w, height = h }, parent)
  local l = pool[i]
  l:move(x, y); l:resize(w, h); l:show()
  return l
end

function H.poolGauge(pool, i, parent, x, y, w, h)
  pool[i] = pool[i] or gauge(pool.prefix .. "_" .. i, parent, x, y, w, h)
  local g = pool[i]
  g:move(x, y); g:resize(w, h); g:show()
  return g
end

local function hideFrom(pool, fromIndex)
  local i = fromIndex
  while pool[i] do pool[i]:hide(); i = i + 1 end
end

-- A compact TP "number" style block (label, not a bar).
local function tpNumberStyle(l)
  l:setStyleSheet("background-color:#12151d; border:1px solid #262c3a; border-radius:6px;")
end
local function tpNumberHTML(tp)
  local col = tp >= 100 and "#fbbf24" or "#2dd4bf"
  return "<center><span style='color:#8ea0bf; font-size:8pt'>TP</span><br>" ..
    "<span style='color:" .. col .. "; font-weight:bold; font-size:15pt'>" .. tp .. "</span></center>"
end

-- Positions/sizes a horizontal row of widgets, hiding any marked !visible and
-- redistributing the freed width proportionally among the ones that remain.
-- items: { { widget=<Geyser obj>, weight=<number>, visible=<bool>, y=<num>, height=<num> }, ... }
local function layoutRow(x0, totalW, gap, items)
  local visible = {}
  local weightSum = 0
  for _, it in ipairs(items) do
    if it.visible then
      visible[#visible + 1] = it
      weightSum = weightSum + it.weight
    else
      it.widget:hide()
    end
  end
  local n = #visible
  if n == 0 then return end
  local avail = totalW - (n - 1) * gap
  local widths, sumW = {}, 0
  for i, it in ipairs(visible) do
    widths[i] = math.floor(avail * it.weight / weightSum)
    sumW = sumW + widths[i]
  end
  widths[n] = widths[n] + (avail - sumW) -- rounding remainder goes to the last item
  local x = x0
  for i, it in ipairs(visible) do
    it.widget:show()
    it.widget:move(x, it.y)
    it.widget:resize(widths[i], it.height)
    x = x + widths[i] + gap
  end
end

-- ---------------------------------------------------------------------------
-- config (persisted per profile; toggled from each panel's right-click menu)
-- ---------------------------------------------------------------------------
local CFG_PATH = getMudletHomeDir() .. "/NorrathHUD_cfg.lua"

local function defaultCfg()
  return {
    v_mn = true, v_mv = true, v_tp = true,          -- which vitals gauges show
    v_num = true, v_pct = false, v_lbl = true,      -- vitals gauge text content
    p_mp = true, p_tp = true, p_num = true, p_pct = false, p_lbl = true, -- party
    t_num = true, t_pct = false, t_lbl = true,      -- target
    e_pct = true, e_compact = false,                -- enemies
    pt_pct = false, pt_compact = false,             -- pets
    a_compact = false,                              -- abilities
  }
end

local function loadCfg()
  local t = {}
  if table.load then pcall(function() table.load(CFG_PATH, t) end) end
  local d = defaultCfg()
  for k, v in pairs(d) do if t[k] == nil then t[k] = v end end
  return t
end

function H.saveCfg()
  if table.save then pcall(function() table.save(CFG_PATH, H.cfg) end) end
end

-- Overlay text for a gauge, honoring the label / numbers / percent toggles.
local function gaugeText(short, cur, max, showLbl, showNum, showPct)
  local parts = {}
  if showLbl then parts[#parts + 1] = short end
  if showNum then parts[#parts + 1] = num(cur) .. "/" .. num(max, 1) end
  if showPct then parts[#parts + 1] = "(" .. math.floor(frac(cur, max) * 100) .. "%)" end
  return table.concat(parts, "  ")
end

-- Target bar text: name always shown, then optional "HP 123/456 (75%)" bits.
local function targetText(t)
  local bits = {}
  if H.cfg.t_lbl then bits[#bits + 1] = "HP" end
  if H.cfg.t_num then bits[#bits + 1] = num(t.hp) .. "/" .. num(t.maxhp, 1) end
  if H.cfg.t_pct then bits[#bits + 1] = "(" .. tostring(t.hp_percent or 0) .. "%)" end
  local name = tostring(t.name or "?")
  if #bits > 0 then return name .. "   " .. table.concat(bits, " ") end
  return name
end

-- Add custom right-click menu entries to an Adjustable.Container (no-op if the
-- API isn't present). Each item is { "Label", function() ... end }. Note:
-- Mudlet's Adjustable.Container has no documented way to remove/replace a
-- custom menu item once added, so we only call this once per container per
-- build() (a fresh container each hot-reload generation) -- the leading
-- [x]/[ ] glyph reflects config state as of that build, and stays accurate
-- until the next toggle-triggered panel update or a full `ui reload`/reset.
local function addMenu(container, items)
  if not (container and container.newCustomItem) then return end
  for _, it in ipairs(items) do
    pcall(function() container:newCustomItem(it[1], it[2]) end)
  end
end

local function toggler(key, updateFn)
  return function()
    H.cfg[key] = not H.cfg[key]
    H.saveCfg()
    updateFn()
  end
end

-- Leading checkbox glyph for a menu item label, reflecting current cfg state.
local function chk(key, label)
  return (H.cfg[key] and "[x] " or "[ ] ") .. label
end

-- ---------------------------------------------------------------------------
-- map panel helpers (fog-of-war grid cell styling / tooltip / glyph)
-- ---------------------------------------------------------------------------
-- QLabel stylesheet for one room cell. Priority: player > named > zone exit >
-- vendor > camp > safe > plain. Rooms never entered (only seen at range) are
-- rendered with a dimmer palette and a dashed border regardless of marker;
-- rooms whose data is "stale" (outside the current vision radius, served
-- from the cached room_memory snapshot) also get a dashed border.
local function roomCellStyle(room, isCenter)
  local border, bg
  if isCenter then
    border, bg = "#22d3ee", "#0e3a44"
  elseif room.named then
    border, bg = "#fbbf24", (room.entered and "#3a2e0d" or "#201a0a")
  elseif room.zoneexit then
    border, bg = "#f87171", (room.entered and "#3a1414" or "#201010")
  elseif room.vendor then
    border, bg = "#60a5fa", (room.entered and "#0f2138" or "#0b1826")
  elseif room.camp then
    border, bg = "#fb923c", (room.entered and "#3a220d" or "#201609")
  elseif room.safe then
    border, bg = "#34d399", (room.entered and "#0d2a20" or "#0a1c16")
  else
    border = room.entered and "#3b4252" or "#262c3a"
    bg = room.entered and "#171b26" or "#12151d"
  end
  local style = "border-style:solid;"
  if not isCenter and (not room.entered or not room.fresh) then style = "border-style:dashed;" end
  return "QLabel{ background-color:" .. bg .. "; border:2px " .. style ..
    " border-color:" .. border .. "; border-radius:4px; }"
end

-- Small center-aligned glyph for a room cell.
local function cellGlyph(room, isCenter)
  if isCenter then return "@" end
  if room.named then return "&#9733;" end     -- star: named/rare mob seen here
  if room.zoneexit then return "&#8593;" end   -- up-arrow: zone exit
  if room.vendor then return "$" end
  if room.camp then return "&#9679;" end       -- dot: ordinary creatures
  return ""
end

-- Native Qt tooltip content (Geyser.Label:setToolTip) for a room cell.
local function mapTooltipHtml(room)
  local lines = { "<b>" .. tostring(room.name or ("Room " .. tostring(room.id))) .. "</b>" }
  local bits = {}
  if room.terrain and room.terrain ~= "" then bits[#bits + 1] = tostring(room.terrain) end
  if room.safe then bits[#bits + 1] = "safe" end
  if room.camp then bits[#bits + 1] = "camp" end
  if room.named then bits[#bits + 1] = "named!" end
  if room.vendor then bits[#bits + 1] = "vendor" end
  if room.zoneexit then bits[#bits + 1] = "zone exit" end
  if #bits > 0 then lines[#lines + 1] = table.concat(bits, " &#183; ") end
  lines[#lines + 1] = room.entered and "visited" or "seen, not visited (can't travel here)"
  if not room.fresh then lines[#lines + 1] = "last known -- out of sight" end
  return table.concat(lines, "<br>")
end

-- ---------------------------------------------------------------------------
-- build (runs once per hot-reload generation)
-- ---------------------------------------------------------------------------
H.windowBaseName = {
  vitals = "nhVitals", party = "nhParty", target = "nhTarget",
  enemies = "nhEnemies", pets = "nhPets", abilities = "nhAbil", map = "nhMap",
}

function H.build()
  if H.built then return end
  H.cfg = loadCfg()
  local top = ADJ and 26 or 4  -- leave room for the panel's title bar
  H.top = top

  -- Vitals: horizontal HP / MN / MV bars + TP as a number (FFXI-style).
  H.cVitals = panel("nhVitals", "2%", "3%", 566, ADJ and 68 or 46, "Vitals")
  H.header = Geyser.Label:new({ name = nm("nhHeader"), x = 8, y = top, width = 550, height = 15 }, H.cVitals)
  H.header:setStyleSheet("color:#e2e8f0; font-weight:bold; font-family:" .. FONT ..
    "; font-size:10pt; qproperty-alignment:'AlignLeft|AlignVCenter';")
  H.gHP = gauge("nhHP", H.cVitals, 8, top + 18, 170, 22)
  H.gMN = gauge("nhMN", H.cVitals, 184, top + 18, 170, 22)
  H.gMV = gauge("nhMV", H.cVitals, 360, top + 18, 132, 22)
  H.tpNum = Geyser.Label:new({ name = nm("nhTP"), x = 498, y = top + 16, width = 60, height = 26 }, H.cVitals)
  tpNumberStyle(H.tpNum)
  addMenu(H.cVitals, {
    { chk("v_mn", "Show Mana"), toggler("v_mn", H.updateVitals) },
    { chk("v_mv", "Show Movement"), toggler("v_mv", H.updateVitals) },
    { chk("v_tp", "Show TP"), toggler("v_tp", H.updateVitals) },
    { chk("v_num", "Show Numbers"), toggler("v_num", H.updateVitals) },
    { chk("v_pct", "Show Percent"), toggler("v_pct", H.updateVitals) },
    { chk("v_lbl", "Show Labels"), toggler("v_lbl", H.updateVitals) },
  })

  H.cTarget = panel("nhTarget", "2%", "20%", 566, ADJ and 52 or 30, "Target")
  H.gTarget = gauge("nhTgt", H.cTarget, 8, top, 550, 22)
  addMenu(H.cTarget, {
    { chk("t_num", "Show Numbers"), toggler("t_num", H.updateTarget) },
    { chk("t_pct", "Show Percent"), toggler("t_pct", H.updateTarget) },
    { chk("t_lbl", "Show Labels"), toggler("t_lbl", H.updateTarget) },
  })

  -- Party: FFXI-style rows -- name/class + HP bar + MP bar + TP number.
  H.cParty = panel("nhParty", "2%", "32%", 474, 210, "Party")
  H.partyTop = top
  H.pName = { prefix = "nhPName" }
  H.pHP = { prefix = "nhPHP" }
  H.pMP = { prefix = "nhPMP" }
  H.pTP = { prefix = "nhPTP" }
  addMenu(H.cParty, {
    { chk("p_mp", "Show Mana"), toggler("p_mp", H.updateParty) },
    { chk("p_tp", "Show TP"), toggler("p_tp", H.updateParty) },
    { chk("p_num", "Show Numbers"), toggler("p_num", H.updateParty) },
    { chk("p_pct", "Show Percent"), toggler("p_pct", H.updateParty) },
    { chk("p_lbl", "Show Labels"), toggler("p_lbl", H.updateParty) },
  })

  H.cEnemies = panel("nhEnemies", "77%", "3%", 272, 250, "Enemies")
  H.enemiesTop = top
  H.enemyPool = { prefix = "nhEnemy" }
  addMenu(H.cEnemies, {
    { chk("e_pct", "Show HP%"), toggler("e_pct", H.updateEnemies) },
    { chk("e_compact", "Compact"), toggler("e_compact", H.updateEnemies) },
  })

  H.cPets = panel("nhPets", "77%", "44%", 272, 230, "Pets")
  H.petsTop = top
  H.petPool = { prefix = "nhPet" }
  H.petCmdPool = { prefix = "nhPetCmd" }
  addMenu(H.cPets, {
    { chk("pt_pct", "Show HP%"), toggler("pt_pct", H.updatePets) },
    { chk("pt_compact", "Compact"), toggler("pt_compact", H.updatePets) },
  })

  H.cAbil = panel("nhAbil", "58%", "3%", 208, 340, "Abilities")
  H.abilTop = top
  H.abilPool = { prefix = "nhAbil" }
  addMenu(H.cAbil, {
    { chk("a_compact", "Compact"), toggler("a_compact", H.updateAbilities) },
  })

  -- Map: fog-of-war grid of every room the character has ever seen, centered
  -- on their current room. Cell pool + a separate small-dot pool for party
  -- member overlays.
  H.cMap = panel("nhMap", "2%", "57%", 600, 280, "Map")
  H.mapTop = top
  H.mapCell = 26
  H.mapGap = 2
  H.mapContentW = 600 - 16
  H.mapContentH = 280 - top - 10
  H.mapPool = { prefix = "nhMapCell" }
  H.mapPartyPool = { prefix = "nhMapParty" }

  H.windows = {
    vitals = H.cVitals, party = H.cParty, target = H.cTarget,
    enemies = H.cEnemies, pets = H.cPets, abilities = H.cAbil, map = H.cMap,
  }
  H.winVisible = H.winVisible or {}
  for k in pairs(H.windows) do
    if H.winVisible[k] == nil then H.winVisible[k] = true end
  end

  H.built = true
end

-- ---------------------------------------------------------------------------
-- updates
-- ---------------------------------------------------------------------------
function H.updateVitals()
  if not H.built then return end
  if H.winVisible.vitals == false then H.cVitals:hide(); return end
  H.cVitals:show()
  local v = H.gmcp("Char.Vitals") or {}
  local b = H.gmcp("Char.Base") or {}
  H.header:echo((b.name or "?") .. "  &#183;  Lvl " .. tostring(b.level or 0) ..
    (b.class and ("  &#183;  " .. tostring(b.class)) or ""))
  setGauge(H.gHP, v.hp, v.maxhp,
    gaugeText("HP", v.hp, v.maxhp, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), hpGrad(v.hp, v.maxhp))
  setGauge(H.gMN, v.mana, v.maxmana,
    gaugeText("MN", v.mana, v.maxmana, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), GRAD.mn)
  setGauge(H.gMV, v.movement, v.maxmove,
    gaugeText("MV", v.movement, v.maxmove, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), GRAD.mv)
  H.tpNum:echo(tpNumberHTML(num(v.tp)))

  layoutRow(8, 550, 6, {
    { widget = H.gHP, weight = 170, visible = true, y = H.top + 18, height = 22 },
    { widget = H.gMN, weight = 170, visible = H.cfg.v_mn and num(v.maxmana) > 0, y = H.top + 18, height = 22 },
    { widget = H.gMV, weight = 132, visible = H.cfg.v_mv, y = H.top + 18, height = 22 },
    { widget = H.tpNum, weight = 60, visible = H.cfg.v_tp, y = H.top + 16, height = 26 },
  })
end

function H.updateTarget()
  if not H.built then return end
  if H.winVisible.target == false then H.cTarget:hide(); return end
  local t = H.gmcp("Char.Target") or {}
  if t.active then
    H.cTarget:show()
    setGauge(H.gTarget, t.hp, t.maxhp, targetText(t), hpGrad(t.hp, t.maxhp))
  else
    H.cTarget:hide()
  end
end

function H.updateParty()
  if not H.built then return end
  if H.winVisible.party == false then H.cParty:hide(); return end
  H.cParty:show()
  local members = H.gmcp("Group.Members")
  if type(members) ~= "table" then members = {} end
  local rowH, gap = 28, 4
  local i = 0
  for _, m in ipairs(members) do
    i = i + 1
    local y = H.partyTop + (i - 1) * (rowH + gap)

    -- Name / class block (left, fixed width).
    local nameLbl = H.poolLabel(H.pName, i, H.cParty, 6, y, 92, rowH)
    nameLbl:setStyleSheet("background-color:#141824; border:1px solid #262c3a; border-radius:5px;" ..
      " padding-left:5px; qproperty-alignment:'AlignLeft|AlignVCenter';")
    nameLbl:echo(string.format("<b>%s%s</b><br><span style='color:#8ea0bf; font-size:7pt'>Lv%s %s</span>",
      m["self"] and "&#9670; " or "", tostring(m.name or "?"), tostring(m.level or 0),
      tostring(m.class or "")))

    -- HP / MP / TP repack dynamically into the remaining width.
    local hp = H.poolGauge(H.pHP, i, H.cParty, 102, y + 3, 150, rowH - 6)
    setGauge(hp, m.hp, m.maxhp,
      gaugeText("HP", m.hp, m.maxhp, H.cfg.p_lbl, H.cfg.p_num, H.cfg.p_pct), hpGrad(m.hp, m.maxhp))

    local mp = H.poolGauge(H.pMP, i, H.cParty, 256, y + 3, 150, rowH - 6)
    if num(m.maxmana) > 0 then
      setGauge(mp, m.mana, m.maxmana,
        gaugeText("MP", m.mana, m.maxmana, H.cfg.p_lbl, H.cfg.p_num, H.cfg.p_pct), GRAD.mn)
    end

    local tp = H.poolLabel(H.pTP, i, H.cParty, 410, y, 56, rowH)
    tpNumberStyle(tp)
    tp:echo(tpNumberHTML(num(m.tp)))

    layoutRow(102, 364, 4, {
      { widget = hp, weight = 150, visible = true, y = y + 3, height = rowH - 6 },
      { widget = mp, weight = 150, visible = H.cfg.p_mp and num(m.maxmana) > 0, y = y + 3, height = rowH - 6 },
      { widget = tp, weight = 56, visible = H.cfg.p_tp, y = y, height = rowH },
    })
  end
  hideFrom(H.pName, i + 1)
  hideFrom(H.pHP, i + 1)
  hideFrom(H.pMP, i + 1)
  hideFrom(H.pTP, i + 1)
end

function H.updateEnemies()
  if not H.built then return end
  if H.winVisible.enemies == false then H.cEnemies:hide(); return end
  H.cEnemies:show()
  local e = H.gmcp("Char.Enemies") or {}
  local foes = e.enemies or {}
  local rowH = H.cfg.e_compact and 22 or 26
  local gap = H.cfg.e_compact and 2 or 4
  local y, i = H.enemiesTop, 0
  for _, foe in ipairs(foes) do
    i = i + 1
    local l = H.poolLabel(H.enemyPool, i, H.cEnemies, 8, y, 256, rowH)
    l:setStyleSheet(btnStyle("#f87171"))
    local dot = foe.target and "<span style='color:#f87171'>&#9654;</span> " or ""
    local pctTxt = ""
    if H.cfg.e_pct then
      pctTxt = "   <span style='color:" .. hpGrad(foe.hp, foe.maxhp)[1] .. "'>" ..
        tostring(foe.hp_percent or 0) .. "%</span>"
    end
    l:echo(dot .. tostring(foe.name or "?") .. pctTxt)
    local cmd = foe.cmd or ("attack " .. tostring(foe.name or ""))
    l:setClickCallback(function() send(cmd) end)
    y = y + rowH + gap
  end
  hideFrom(H.enemyPool, i + 1)
end

local PET_CMDS = {
  { "Atk", "pet attack" }, { "Back", "pet back" }, { "Guard", "pet guard" },
  { "Foll", "pet follow" }, { "Aggr", "pet aggressive" }, { "Pass", "pet passive" },
}

function H.updatePets()
  if not H.built then return end
  if H.winVisible.pets == false then H.cPets:hide(); return end
  H.cPets:show()
  local p = H.gmcp("Char.Pets") or {}
  local pets = p.pets or {}
  local rowH = H.cfg.pt_compact and 22 or 26
  local gap = H.cfg.pt_compact and 2 or 4
  local y, i = H.petsTop, 0
  for _, pet in ipairs(pets) do
    i = i + 1
    local l = H.poolLabel(H.petPool, i, H.cPets, 8, y, 256, rowH)
    l:setStyleSheet(btnStyle("#a78bfa"))
    local dot = pet.active and "<span style='color:#a78bfa'>&#9654;</span> " or ""
    local pctTxt = ""
    if H.cfg.pt_pct then
      pctTxt = " (" .. math.floor(frac(pet.hp, pet.maxhp) * 100) .. "%)"
    end
    l:echo(dot .. tostring(pet.name or "?") .. " L" .. tostring(pet.level or 0) ..
      "  <span style='color:" .. hpGrad(pet.hp, pet.maxhp)[1] .. "'>" ..
      num(pet.hp) .. "/" .. num(pet.maxhp, 1) .. pctTxt .. "</span> [" .. tostring(pet.mode or "") .. "]")
    local cmd = pet.cmd or ("pet select " .. tostring(pet.name or ""))
    l:setClickCallback(function() send(cmd) end)
    y = y + rowH + gap
  end
  hideFrom(H.petPool, i + 1)
  local x = 8
  for j, c in ipairs(PET_CMDS) do
    local b = H.poolLabel(H.petCmdPool, j, H.cPets, x, y + 4, 40, 24)
    b:setStyleSheet(btnStyle("#22c55e"):gsub("AlignLeft", "AlignHCenter"))
    b:echo(c[1])
    b:setClickCallback(function() send(c[2]) end)
    x = x + 43
  end
  hideFrom(H.petCmdPool, #PET_CMDS + 1)
end

function H.updateAbilities()
  if not H.built then return end
  if H.winVisible.abilities == false then H.cAbil:hide(); return end
  H.cAbil:show()
  local a = H.gmcp("Char.Abilities") or {}
  local rows = {}
  for _, s in ipairs(a.spells or {}) do rows[#rows + 1] = { s.name or s.cmd, s.cmd, "#38bdf8" } end
  for _, s in ipairs(a.weaponskills or {}) do rows[#rows + 1] = { s.name or s.cmd, s.cmd, "#fbbf24" } end
  local rowH = H.cfg.a_compact and 22 or 26
  local gap = H.cfg.a_compact and 2 or 4
  local y, i = H.abilTop, 0
  for _, r in ipairs(rows) do
    i = i + 1
    local l = H.poolLabel(H.abilPool, i, H.cAbil, 8, y, 192, rowH)
    l:setStyleSheet(btnStyle(r[3]))
    l:echo("<span style='color:" .. r[3] .. "'>&#9670;</span> " .. tostring(r[1]))
    local cmd = r[2]
    l:setClickCallback(function() send(cmd) end)
    y = y + rowH + gap
  end
  hideFrom(H.abilPool, i + 1)
end

function H.updateMap()
  if not H.built then return end
  if H.winVisible.map == false then H.cMap:hide(); return end
  H.cMap:show()

  local rm = H.gmcp("Room.Map")
  if type(rm) ~= "table" or type(rm.rooms) ~= "table" or #rm.rooms == 0 then
    hideFrom(H.mapPool, 1)
    hideFrom(H.mapPartyPool, 1)
    return
  end

  local cell, gap = H.mapCell, H.mapGap
  local step = cell + gap
  local cols = math.max(1, math.floor(H.mapContentW / step))
  local rows = math.max(1, math.floor(H.mapContentH / step))
  local centerCol, centerRow = math.floor(cols / 2), math.floor(rows / 2)

  local center = nil
  for _, r in ipairs(rm.rooms) do
    if r.id == rm.center then center = r; break end
  end
  center = center or { x = 0, y = 0, z = rm.z }

  H.mapCellPos = {}
  local i = 0
  for _, r in ipairs(rm.rooms) do
    if (r.z or 0) == (rm.z or 0) then
      local dx = (r.x or 0) - (center.x or 0)
      local dy = (r.y or 0) - (center.y or 0)
      local col = centerCol + dx
      local row = centerRow - dy -- north (+y) is up on screen
      if col >= 0 and col < cols and row >= 0 and row < rows then
        i = i + 1
        local x = 8 + col * step
        local y = H.mapTop + row * step
        local isCenter = (r.id == rm.center)
        local l = H.poolLabel(H.mapPool, i, H.cMap, x, y, cell, cell)
        l:setStyleSheet(roomCellStyle(r, isCenter))
        l:echo("<center>" .. cellGlyph(r, isCenter) .. "</center>")
        l:setToolTip(mapTooltipHtml(r))
        local rid, entered = r.id, r.entered
        l:setClickCallback(function()
          if entered then send("travelto " .. tostring(rid))
          else cecho("<red>[Map] You haven't been there.\n") end
        end)
        H.mapCellPos[r.id] = { x = x, y = y }
      end
    end
  end
  hideFrom(H.mapPool, i + 1)

  -- Party overlay: small dots for same-zone group members (self is already
  -- the centered "@" cell, so skip it here).
  local members = H.gmcp("Group.Members")
  if type(members) ~= "table" then members = {} end
  local j = 0
  for _, m in ipairs(members) do
    if not m["self"] and m.room and H.mapCellPos[m.room] then
      j = j + 1
      local pos = H.mapCellPos[m.room]
      local pl = H.poolLabel(H.mapPartyPool, j, H.cMap, pos.x + cell - 10, pos.y - 2, 12, 12)
      pl:setStyleSheet("QLabel{ background-color:#a78bfa; border:1px solid #0b0d13; border-radius:6px; }")
      pl:echo("")
      pl:setToolTip(tostring(m.name or "?"))
    end
  end
  hideFrom(H.mapPartyPool, j + 1)
end

H.updaters = {
  vitals = H.updateVitals, party = H.updateParty, target = H.updateTarget,
  enemies = H.updateEnemies, pets = H.updatePets, abilities = H.updateAbilities,
  map = H.updateMap,
}

function H.refreshAll()
  for _, fn in pairs(H.updaters) do fn() end
end

-- ---------------------------------------------------------------------------
-- panel visibility / positions (used by the `ui` command suite below)
-- ---------------------------------------------------------------------------
function H.showAll()
  for k in pairs(H.windows) do H.winVisible[k] = true end
  H.refreshAll()
end

function H.hideAll()
  for k, c in pairs(H.windows) do
    H.winVisible[k] = false
    if c then c:hide() end
  end
end

function H.toggleWindow(name)
  name = string.lower(tostring(name or ""))
  if not H.windows[name] then return false end
  H.winVisible[name] = not H.winVisible[name]
  if H.winVisible[name] then
    local fn = H.updaters[name]
    if fn then fn() end
  else
    H.windows[name]:hide()
  end
  return true
end

function H.resetPositions()
  for key, c in pairs(H.windows) do
    local base = H.windowBaseName[key]
    local d = base and H.panelDefaults[base]
    if c and d then
      pcall(function() c:move(d.x, d.y) end)
      pcall(function() c:resize(d.w, d.h) end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- `ui` / `hud` command suite (client-side)
-- ---------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local HELP_LINES = {
  "<b>Norrath HUD commands</b> (type 'ui' or 'hud'):",
  "  ui / ui help    - show this help",
  "  ui reload [path]- dev: hot-reload from your working-copy .lua (set path once)",
  "  update ui       - same as 'ui reload' (hot-reload from your working copy)",
  "  ui refresh      - refresh all panels from current GMCP state",
  "  ui reset        - reset config + panel positions to defaults",
  "  ui show|showall - show every panel",
  "  ui close|hide   - hide every panel",
  "  ui toggle <win> - toggle one panel: vitals, party, target, enemies, pets, abilities, map",
}

function H.command(rest)
  rest = trim(rest)
  local cmd, arg = rest:match("^(%S*)%s*(.-)$")
  cmd = string.lower(cmd or "")
  arg = trim(arg)

  if cmd == "" or cmd == "help" then
    for _, line in ipairs(HELP_LINES) do cecho("<cyan>" .. line .. "\n") end
  elseif cmd == "reload" then
    -- Dev hot-reload is opt-in and machine-local: point it at your working-copy
    -- .lua with `ui reload <path>` once (persists in NorrathHUD.devPath for the
    -- session); thereafter `ui reload` / `update ui` re-dofile it. No personal
    -- path ships in the distributed package.
    if arg ~= "" then H.devPath = arg end
    if not H.devPath then
      cecho("<yellow>[Norrath HUD] dev reload is opt-in -- run 'ui reload <path-to-NorrathHUD.lua>' "
        .. "once to set your working copy, then 'ui reload' / 'update ui' will hot-reload it.\n")
      return
    end
    local ok, err = pcall(dofile, H.devPath)
    if not ok then
      cecho("<red>[Norrath HUD] reload failed: " .. tostring(err) .. "\n")
    end
  elseif cmd == "refresh" then
    H.refreshAll()
    cecho("<green>[Norrath HUD] refreshed.\n")
  elseif cmd == "reset" then
    H.cfg = defaultCfg()
    H.saveCfg()
    H.resetPositions()
    H.showAll()
    cecho("<green>[Norrath HUD] reset to defaults.\n")
  elseif cmd == "show" or cmd == "showall" then
    H.showAll()
    cecho("<green>[Norrath HUD] all panels shown.\n")
  elseif cmd == "close" or cmd == "hide" then
    H.hideAll()
    cecho("<green>[Norrath HUD] all panels hidden.\n")
  elseif cmd == "toggle" then
    if arg == "" or not H.toggleWindow(arg) then
      cecho("<red>[Norrath HUD] usage: ui toggle <vitals|party|target|enemies|pets|abilities|map>\n")
    end
  else
    cecho("<red>[Norrath HUD] unknown subcommand '" .. cmd .. "'. Try 'ui help'.\n")
  end
end

-- ---------------------------------------------------------------------------
-- events (reload-safe)
-- ---------------------------------------------------------------------------
if H.handlers then
  for _, id in ipairs(H.handlers) do pcall(killAnonymousEventHandler, id) end
end
H.handlers = {}
local function on(ev, fn) H.handlers[#H.handlers + 1] = registerAnonymousEventHandler(ev, fn) end

on("sysConnectionEvent", function() H.refreshAll() end)
on("gmcp.Char.Vitals", function() H.updateVitals() end)
on("gmcp.Char.Base", function() H.updateVitals() end)
on("gmcp.Group.Members", function() H.updateParty(); H.updateMap() end)
on("gmcp.Char.Target", function() H.updateTarget() end)
on("gmcp.Char.Enemies", function() H.updateEnemies() end)
on("gmcp.Char.Pets", function() H.updatePets() end)
on("gmcp.Char.Abilities", function() H.updateAbilities() end)
on("gmcp.Room.Map", function() H.updateMap() end)

-- `ui` / `hud` alias, reload-safe (kill any alias from a previous generation).
if H.aliasIds then
  for _, id in ipairs(H.aliasIds) do pcall(killAlias, id) end
end
H.aliasIds = {}
H.aliasIds[#H.aliasIds + 1] =
  tempAlias("^\\s*(ui|hud)\\b\\s*(.*)$", [[NorrathHUD.command(matches[3])]])
-- `update ui` / `update hud`: friendly alias for `ui reload` -- re-runs
-- `dofile` on the working-copy NorrathHUD.lua to hot-reload the HUD.
H.aliasIds[#H.aliasIds + 1] =
  tempAlias("^\\s*update\\s+(ui|hud)\\s*$", [[NorrathHUD.command("reload")]])

-- Hot-reload: hide the previous generation's panels, bump the generation so new
-- widget names don't collide, then rebuild fresh.
if H.containers then
  for _, c in ipairs(H.containers) do pcall(function() c:hide() end) end
end
H.containers = {}
H.gen = (H.gen or 0) + 1
H.built = false
H.build()
H.refreshAll()
cecho("<green>[Norrath HUD]<reset> v5 loaded (Map panel added). Right-click a panel to configure it, or type 'ui help'.\n")
