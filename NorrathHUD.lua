-----------------------------------------------------------------------------
-- Norrath HUD  --  Mudlet package  (v9: Map exit connectors -- draw passages
-- between rooms so a real link reads distinctly from mere grid adjacency)
--
-- A Geyser HUD fed entirely by the server's GMCP. Each panel is a draggable,
-- resizable, self-persisting Adjustable.Container with a titled frame.
--
--   gmcp.Char.Vitals   -> HP / MN / MV / TP gauges + full-width TNL bar
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
  xp    = { "#c084fc", "#7c3aed" },
}

local function hpGrad(cur, mx)
  local f = (tonumber(cur) or 0) / math.max(1, tonumber(mx) or 1)
  if f > 0.5 then return GRAD.hp_hi elseif f > 0.25 then return GRAD.hp_md else return GRAD.hp_lo end
end

-- Scale helpers -- one `cfg.scale` knob resizes the whole HUD (fonts AND
-- geometry) so it reads well at any resolution / DPI. `S` scales a pixel size,
-- `PT` scales a font point-size (as a string for stylesheets). Both read
-- H.cfg.scale live, defaulting to 1 before config loads.
-- Per-panel scale: each window has its own size/font multiplier (set via
-- `ui scale <panel> <n>` or its right-click Bigger/Smaller menu). `H.curScale`
-- is the scale of the panel currently being laid out; panel()/each updater set
-- it on entry, and S()/PT() read it.
local PANEL_KEYS = { "vitals", "party", "target", "enemies", "pets", "abilities", "map" }
local NAME2KEY = {
  nhVitals = "vitals", nhParty = "party", nhTarget = "target",
  nhEnemies = "enemies", nhPets = "pets", nhAbil = "abilities", nhMap = "map",
}
local function uiScale() return tonumber(H.curScale) or 1 end
local function S(v) return math.max(1, math.floor(v * uiScale() + 0.5)) end
local function PT(base) return tostring(math.max(6, math.floor(base * uiScale() + 0.5))) end
local function useScale(key) H.curScale = (H.cfg and H.cfg.pscale and H.cfg.pscale[key]) or 1 end

-- Button style with a hover highlight (Qt stylesheet on the QLabel).
local function btnStyle(accent)
  accent = accent or "#3b82f6"
  return "QLabel{ background-color:#171b26; color:#e5e7eb; border:1px solid #2b3140;" ..
         " border-radius:6px; padding:2px 6px; font-family:" .. FONT .. "; font-size:" .. PT(10) .. "pt;" ..
         " qproperty-alignment:'AlignLeft|AlignVCenter'; }" ..
         " QLabel:hover{ background-color:#232a3a; border-color:" .. accent .. "; color:#ffffff; }"
end

-- "#rrggbb" -> "rgba(r,g,b,a)" so fills can be translucent in Qt stylesheets.
local function rgba(hex, a)
  local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
  if not r then return hex end
  return string.format("rgba(%d,%d,%d,%d)", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), a)
end

-- Enemy row style: the label's own background doubles as an HP bar. Two hard
-- gradient stops fill the left `f` fraction with the hp-tier color and leave
-- the rest the normal button background.
local function enemyRowBarStyle(f)
  f = math.max(0, math.min(1, tonumber(f) or 0))
  local fill = rgba(hpGrad(f, 1)[2], 170)
  local empty = "#171b26"
  local bg
  if f >= 0.995 then
    bg = fill
  elseif f <= 0.005 then
    bg = empty
  else
    local at = string.format("%.3f", f)
    local after = string.format("%.3f", math.min(1, f + 0.001))
    bg = "qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 " .. fill .. ", stop:" .. at .. " " .. fill ..
         ", stop:" .. after .. " " .. empty .. ", stop:1 " .. empty .. ")"
  end
  return "QLabel{ background-color:" .. bg .. "; color:#f1f5f9; border:1px solid #2b3140;" ..
         " border-radius:6px; padding:2px 6px; font-family:" .. FONT .. "; font-size:" .. PT(10) .. "pt;" ..
         " qproperty-alignment:'AlignLeft|AlignVCenter'; }" ..
         " QLabel:hover{ border-color:#f87171; color:#ffffff; }"
end

-- Con-colour hexes keyed by the server's con label (mirrors the CON_TABLE in
-- world/eq/colors.py: |x trivial, |g green, |c lt blue, |B dk blue, |w even,
-- |y yellow, |r red, |R deadly).
local CON_HEX = {
  trivial = "#9ca3af", green = "#4ade80", ["light blue"] = "#67e8f9",
  ["dark blue"] = "#60a5fa", even = "#f1f5f9", yellow = "#facc15",
  red = "#ef4444", deadly = "#ff3b3b",
}

-- Status-symbol prefix for an enemy row, coloured like the room listing:
-- red # megaboss, gold * boss/named, red ! aggressive, yellow + links.
local function enemyMarkers(flags)
  if type(flags) ~= "table" then return "" end
  local out = ""
  if flags.megaboss then out = out .. "<span style='color:#ff3b3b;font-weight:bold'>#</span>" end
  if flags.boss then out = out .. "<span style='color:#fbbf24;font-weight:bold'>*</span>" end
  if flags.aggro then out = out .. "<span style='color:#ef4444;font-weight:bold'>!</span>" end
  if flags.link then out = out .. "<span style='color:#facc15;font-weight:bold'>+</span>" end
  if out ~= "" then out = out .. " " end
  return out
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
  -- Store the UNSCALED base size; the live size is base * this panel's scale,
  -- applied here and re-applied by resetPositions() so `ui scale` resizes it.
  useScale(NAME2KEY[name])
  H.panelDefaults[name] = { x = x, y = y, w = w, h = h }
  local o = { name = nm(name), x = x, y = y, width = S(w), height = S(h) }
  if ADJ then
    o.titleText = title
    o.titleTxtColor = TITLE_FG
    o.adjLabelstyle = PANEL_BG
    o.buttonFontSize = tonumber(PT(9))
    o.padding = 6
  end
  local ok, c = pcall(function() return Container:new(o) end)
  if not ok then c = Geyser.Container:new({ name = nm(name), x = x, y = y, width = S(w), height = S(h) }) end
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
  -- Re-apply the scaled font each refresh so `ui scale` takes effect live.
  pcall(function()
    g.text:setStyleSheet("color:#f8fafc; font-weight:bold; font-family:" .. FONT ..
      "; font-size:" .. PT(9) .. "pt;")
  end)
end

-- Content width/height of a panel from its LIVE pixel size, so children reflow
-- when the panel is dragged-resized or the client runs at a different
-- resolution (instead of staying pinned to hardcoded pixel widths).
local PANEL_PAD = 8
function H.cw(c)
  local w = 0
  if c then pcall(function() w = c:get_width() end) end
  if not w or w <= 0 then w = (c and c.width) or 300 end
  return math.max(60, math.floor(w) - 2 * PANEL_PAD)
end
function H.ch(c)
  local h = 0
  if c then pcall(function() h = c:get_height() end) end
  if not h or h <= 0 then h = (c and c.height) or 120 end
  return math.max(30, math.floor(h) - (H.top or 26) - 8)
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
  l:setStyleSheet("background-color:#12151d; border:1px solid #262c3a; border-radius:6px;" ..
    " qproperty-alignment:'AlignCenter';")
end
-- TP as a single inline line ("TP 0") so it sits flush alongside the HP/MN/MV
-- bars at the same height, instead of a taller stacked block.
local function tpNumberHTML(tp)
  local col = tp >= 100 and "#fbbf24" or "#2dd4bf"
  return "<center><span style='color:#8ea0bf; font-size:" .. PT(8) .. "pt'>TP </span>" ..
    "<span style='color:" .. col .. "; font-weight:bold; font-size:" .. PT(11) .. "pt'>" .. tp .. "</span></center>"
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
    scale = 1.0,                                    -- legacy global (migrated into pscale below)
    pscale = { vitals = 1, party = 1, target = 1,   -- per-panel size/font multipliers
               enemies = 1, pets = 1, abilities = 1, map = 1 },
    v_mn = true, v_mv = true, v_tp = true, v_xp = true, -- which vitals gauges show
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
  local savedPscale = t.pscale                     -- capture before the default merge
  local d = defaultCfg()
  for k, v in pairs(d) do if t[k] == nil then t[k] = v end end
  -- Per-panel scale. If the saved config predates it (no pscale), seed every
  -- panel from the legacy global `scale` so an old global setting carries over.
  if type(savedPscale) ~= "table" then
    local legacy = tonumber(t.scale) or 1
    t.pscale = {}
    for _, k in ipairs(PANEL_KEYS) do t.pscale[k] = legacy end
  else
    for _, k in ipairs(PANEL_KEYS) do
      if t.pscale[k] == nil then t.pscale[k] = 1 end  -- fill any newly-added panel
    end
  end
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

-- TNL bar text: "TNL 12345 (63%)" -- the number is xp still owed to ding, not
-- xp-into-level, honoring the same label / numbers / percent toggles.
local function tnlText(tnl, pct, showLbl, showNum, showPct)
  local parts = {}
  if showLbl then parts[#parts + 1] = "TNL" end
  if showNum then parts[#parts + 1] = num(tnl) end
  if showPct then parts[#parts + 1] = "(" .. num(pct) .. "%)" end
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

-- Right-click Bigger/Smaller menu items that scale ONE panel by +/-0.1.
local function scaleMenuItems(key)
  local function bump(delta)
    return function()
      local cur = (H.cfg.pscale and H.cfg.pscale[key]) or 1
      H.command("scale " .. key .. " " .. string.format("%.2f", cur + delta))
    end
  end
  return { { "Bigger  (scale +)", bump(0.1) }, { "Smaller (scale -)", bump(-0.1) } }
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
    -- You-are-here: brightest, most saturated cell on the panel + a thick 3px
    -- ring so it reads instantly against every other marker colour.
    border, bg = "#5ff7ff", "#0b566b"
  elseif room.named then
    border, bg = "#fbbf24", (room.entered and "#42340e" or "#241d0b")
  elseif room.zoneexit then
    border, bg = "#f87171", (room.entered and "#421616" or "#241111")
  elseif room.vendor then
    border, bg = "#60a5fa", (room.entered and "#122845" or "#0d1b2c")
  elseif room.camp then
    border, bg = "#fb923c", (room.entered and "#42260e" or "#24190a")
  elseif room.safe then
    border, bg = "#34d399", (room.entered and "#0f3227" or "#0b1f19")
  else
    -- Plain rooms: entered ("your trail") is noticeably lighter than a room
    -- only glimpsed from afar, so your walked path stands out on the grid.
    border = room.entered and "#556072" or "#2b3242"
    bg = room.entered and "#1c2230" or "#12151d"
  end
  local width = isCenter and "3px" or "2px"
  local style = "border-style:solid;"
  if not isCenter and (not room.entered or not room.fresh) then style = "border-style:dashed;" end
  return "QLabel{ background-color:" .. bg .. "; border:" .. width .. " " .. style ..
    " border-color:" .. border .. "; border-radius:4px; }"
end

-- Small center-aligned glyph for a room cell. Each glyph is tinted to match
-- its marker colour so the panel reads as one coherent colour scheme; the
-- player's own cell gets a bold, oversized, bright-cyan diamond.
local function glyphSpan(colour, html, big)
  local size = big and (" font-size:" .. PT(14) .. "pt;") or ""
  return "<span style='color:" .. colour .. "; font-weight:bold;" .. size .. "'>" .. html .. "</span>"
end
local function cellGlyph(room, isCenter)
  if isCenter then return glyphSpan("#7ffaff", "&#9670;", true) end -- ◆ : you are here
  if room.named then return glyphSpan("#fcd34d", "&#9733;") end     -- ★ : named/rare mob seen here
  if room.zoneexit then return glyphSpan("#fca5a5", "&#8593;") end  -- ↑ : zone exit
  if room.vendor then return glyphSpan("#93c5fd", "$") end          -- $ : vendor
  if room.camp then return glyphSpan("#fdba74", "&#9679;") end      -- ● : ordinary creatures
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

-- Colour of exit connectors on the map. Muted slate so the room cells and
-- marker glyphs stay the focus, but bright enough to read against the panel.
local LINK_COLOUR = "#6b7688"

-- Draw every exit connector for the rooms currently placed on the map. Each
-- edge is derived from a room's `exits` (dir -> destination id): if the
-- destination is also on screen we drop a thin bar (cardinal) or a diagonal
-- box-drawing glyph (ne/nw/se/sw) into the gap between the two cells, so a real
-- passage is visually distinct from two rooms that merely sit next to each
-- other on the grid. Pairs are de-duped so a two-way exit draws one line.
-- `pos` maps room id -> { x, y } top-left; `cell`/`step` are the current cell
-- size and cell+gap stride (both already UI-scaled).
function H.drawMapLinks(rm, pos, cell, step)
  local t = math.max(2, math.floor(cell / 8))  -- connector thickness, scales
  local half = cell / 2
  local seen = {}
  local k = 0
  for _, r in ipairs(rm.rooms) do
    local a = pos[r.id]
    if a and type(r.exits) == "table" then
      for _, destId in pairs(r.exits) do
        local b = pos[destId]
        if b and destId ~= r.id then
          local key = (r.id < destId) and (r.id .. "-" .. destId) or (destId .. "-" .. r.id)
          if not seen[key] then
            seen[key] = true
            local ddx, ddy = b.x - a.x, b.y - a.y
            k = k + 1
            if ddy == 0 and ddx ~= 0 then          -- east/west
              local left = math.min(a.x, b.x)
              local l = H.poolLabel(H.mapLinkPool, k, H.cMap,
                left + cell, a.y + half - math.floor(t / 2), math.abs(ddx) - cell, t)
              l:setStyleSheet("QLabel{ background-color:" .. LINK_COLOUR .. "; border-radius:1px; }")
              l:echo("")
            elseif ddx == 0 and ddy ~= 0 then      -- north/south
              local top = math.min(a.y, b.y)
              local l = H.poolLabel(H.mapLinkPool, k, H.cMap,
                a.x + half - math.floor(t / 2), top + cell, t, math.abs(ddy) - cell)
              l:setStyleSheet("QLabel{ background-color:" .. LINK_COLOUR .. "; border-radius:1px; }")
              l:echo("")
            else                                   -- diagonal
              -- Box-drawing glyph centered on the midpoint of the two cells.
              -- Same sign on both deltas => top-left<->bottom-right (\), else /.
              local glyph = ((ddx > 0) == (ddy > 0)) and "&#9586;" or "&#9585;"
              local mx = (a.x + b.x) / 2 + half
              local my = (a.y + b.y) / 2 + half
              local d = step
              local fs = tostring(math.max(6, math.floor(step * 0.9)))
              local l = H.poolLabel(H.mapLinkPool, k, H.cMap,
                mx - d / 2, my - d / 2, d, d)
              l:setStyleSheet("QLabel{ background-color:transparent; color:" .. LINK_COLOUR ..
                "; font-size:" .. fs .. "pt; qproperty-alignment:'AlignCenter'; }")
              l:echo(glyph)
            end
          end
        end
      end
    end
  end
  hideFrom(H.mapLinkPool, k + 1)
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

  -- Vitals: horizontal HP / MN / MV bars + TP as a number (FFXI-style), then a
  -- full-width TNL (experience-to-next-level) bar spanning the panel below them.
  H.cVitals = panel("nhVitals", "2%", "3%", 566, ADJ and 92 or 70, "Vitals")
  H.header = Geyser.Label:new({ name = nm("nhHeader"), x = 8, y = top, width = 550, height = 15 }, H.cVitals)
  H.header:setStyleSheet("color:#e2e8f0; font-weight:bold; font-family:" .. FONT ..
    "; font-size:10pt; qproperty-alignment:'AlignLeft|AlignVCenter';")
  H.gHP = gauge("nhHP", H.cVitals, 8, top + 18, 170, 22)
  H.gMN = gauge("nhMN", H.cVitals, 184, top + 18, 170, 22)
  H.gMV = gauge("nhMV", H.cVitals, 360, top + 18, 132, 22)
  H.tpNum = Geyser.Label:new({ name = nm("nhTP"), x = 498, y = top + 16, width = 60, height = 26 }, H.cVitals)
  tpNumberStyle(H.tpNum)
  -- TNL bar: its own full-width row under the HP/MN/MV/TP row.
  H.gXP = gauge("nhXP", H.cVitals, 8, top + 44, 550, 16)
  addMenu(H.cVitals, {
    { chk("v_mn", "Show Mana"), toggler("v_mn", H.updateVitals) },
    { chk("v_mv", "Show Movement"), toggler("v_mv", H.updateVitals) },
    { chk("v_tp", "Show TP"), toggler("v_tp", H.updateVitals) },
    { chk("v_xp", "Show TNL"), toggler("v_xp", H.updateVitals) },
    { chk("v_num", "Show Numbers"), toggler("v_num", H.updateVitals) },
    { chk("v_pct", "Show Percent"), toggler("v_pct", H.updateVitals) },
    { chk("v_lbl", "Show Labels"), toggler("v_lbl", H.updateVitals) },
  })
  addMenu(H.cVitals, scaleMenuItems("vitals"))

  H.cTarget = panel("nhTarget", "2%", "20%", 566, ADJ and 52 or 30, "Target")
  H.gTarget = gauge("nhTgt", H.cTarget, 8, top, 550, 22)
  addMenu(H.cTarget, {
    { chk("t_num", "Show Numbers"), toggler("t_num", H.updateTarget) },
    { chk("t_pct", "Show Percent"), toggler("t_pct", H.updateTarget) },
    { chk("t_lbl", "Show Labels"), toggler("t_lbl", H.updateTarget) },
  })
  addMenu(H.cTarget, scaleMenuItems("target"))

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
  addMenu(H.cParty, scaleMenuItems("party"))

  H.cEnemies = panel("nhEnemies", "77%", "3%", 272, 250, "Enemies")
  H.enemiesTop = top
  H.enemyPool = { prefix = "nhEnemy" }
  addMenu(H.cEnemies, {
    { chk("e_pct", "Show HP%"), toggler("e_pct", H.updateEnemies) },
    { chk("e_compact", "Compact"), toggler("e_compact", H.updateEnemies) },
  })
  addMenu(H.cEnemies, scaleMenuItems("enemies"))

  H.cPets = panel("nhPets", "77%", "44%", 272, 230, "Pets")
  H.petsTop = top
  H.petPool = { prefix = "nhPet" }
  H.petCmdPool = { prefix = "nhPetCmd" }
  addMenu(H.cPets, {
    { chk("pt_pct", "Show HP%"), toggler("pt_pct", H.updatePets) },
    { chk("pt_compact", "Compact"), toggler("pt_compact", H.updatePets) },
  })
  addMenu(H.cPets, scaleMenuItems("pets"))

  H.cAbil = panel("nhAbil", "58%", "3%", 208, 340, "Abilities")
  H.abilTop = top
  H.abilPool = { prefix = "nhAbil" }
  addMenu(H.cAbil, {
    { chk("a_compact", "Compact"), toggler("a_compact", H.updateAbilities) },
  })
  addMenu(H.cAbil, scaleMenuItems("abilities"))

  -- Map: fog-of-war grid of every room the character has ever seen, centered
  -- on their current room. Cell pool + a separate small-dot pool for party
  -- member overlays.
  H.cMap = panel("nhMap", "2%", "57%", 600, 280, "Map")
  H.mapTop = top
  -- Wider gap than a hairline: the empty space between cells is where exit
  -- connectors ("- | / \" on the ASCII map) are drawn, so it needs to be big
  -- enough to read. Smaller cells keep roughly the same rooms-on-screen count.
  H.mapCell = 22
  H.mapGap = 10
  H.mapContentW = 600 - 16
  H.mapContentH = 280 - top - 10
  H.mapPool = { prefix = "nhMapCell" }
  H.mapLinkPool = { prefix = "nhMapLink" }
  H.mapPartyPool = { prefix = "nhMapParty" }
  addMenu(H.cMap, scaleMenuItems("map"))

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
  useScale("vitals")
  local v = H.gmcp("Char.Vitals") or {}
  local b = H.gmcp("Char.Base") or {}
  pcall(function()
    H.header:setStyleSheet("color:#e2e8f0; font-weight:bold; font-family:" .. FONT ..
      "; font-size:" .. PT(10) .. "pt; qproperty-alignment:'AlignLeft|AlignVCenter';")
  end)
  H.header:resize(H.cw(H.cVitals), S(15))
  H.header:echo((b.name or "?") .. "  &#183;  Lvl " .. tostring(b.level or 0) ..
    (b.class and ("  &#183;  " .. tostring(b.class)) or ""))
  setGauge(H.gHP, v.hp, v.maxhp,
    gaugeText("HP", v.hp, v.maxhp, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), hpGrad(v.hp, v.maxhp))
  setGauge(H.gMN, v.mana, v.maxmana,
    gaugeText("MN", v.mana, v.maxmana, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), GRAD.mn)
  setGauge(H.gMV, v.movement, v.maxmove,
    gaugeText("MV", v.movement, v.maxmove, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), GRAD.mv)
  H.tpNum:echo(tpNumberHTML(num(v.tp)))
  setGauge(H.gXP, v.xp, v.maxxp,
    tnlText(v.tnl, v.xp_pct, H.cfg.v_lbl, H.cfg.v_num, H.cfg.v_pct), GRAD.xp)

  local gy, gh = H.top + S(18), S(22)
  layoutRow(8, H.cw(H.cVitals), 6, {
    { widget = H.gHP, weight = 170, visible = true, y = gy, height = gh },
    { widget = H.gMN, weight = 170, visible = H.cfg.v_mn and num(v.maxmana) > 0, y = gy, height = gh },
    { widget = H.gMV, weight = 132, visible = H.cfg.v_mv, y = gy, height = gh },
    -- TP sits inline with the bars: same y and height as the gauges.
    { widget = H.tpNum, weight = 64, visible = H.cfg.v_tp, y = gy, height = gh },
  })
  -- TNL spans the full content width on its own row just below the gauges.
  if H.cfg.v_xp then
    H.gXP:show()
    H.gXP:move(8, gy + gh + S(4))
    H.gXP:resize(H.cw(H.cVitals), S(16))
  else
    H.gXP:hide()
  end
end

function H.updateTarget()
  if not H.built then return end
  if H.winVisible.target == false then H.cTarget:hide(); return end
  local t = H.gmcp("Char.Target") or {}
  if t.active then
    H.cTarget:show()
    useScale("target")
    H.gTarget:move(8, H.top)
    H.gTarget:resize(H.cw(H.cTarget), S(22))
    setGauge(H.gTarget, t.hp, t.maxhp, targetText(t), hpGrad(t.hp, t.maxhp))
  else
    H.cTarget:hide()
  end
end

function H.updateParty()
  if not H.built then return end
  if H.winVisible.party == false then H.cParty:hide(); return end
  H.cParty:show()
  useScale("party")
  local members = H.gmcp("Group.Members")
  if type(members) ~= "table" then members = {} end
  local rowH, gap = S(28), S(4)
  local nameW = S(96)
  local gaugesX = 6 + nameW + 4
  local gaugesW = math.max(60, H.cw(H.cParty) - nameW - 10)
  local gh = math.max(8, rowH - S(6))
  local i = 0
  for _, m in ipairs(members) do
    i = i + 1
    local y = H.partyTop + (i - 1) * (rowH + gap)

    -- Name / class block (left, fixed width).
    local nameLbl = H.poolLabel(H.pName, i, H.cParty, 6, y, nameW, rowH)
    nameLbl:setStyleSheet("background-color:#141824; border:1px solid #262c3a; border-radius:5px;" ..
      " padding-left:5px; qproperty-alignment:'AlignLeft|AlignVCenter';")
    nameLbl:echo(string.format(
      "<b style='font-size:%spt'>%s%s</b><br><span style='color:#8ea0bf; font-size:%spt'>Lv%s %s</span>",
      PT(9), m["self"] and "&#9670; " or "", tostring(m.name or "?"),
      PT(7), tostring(m.level or 0), tostring(m.class or "")))

    -- HP / MP / TP repack dynamically into the remaining (live) width.
    local hp = H.poolGauge(H.pHP, i, H.cParty, gaugesX, y + S(3), 150, gh)
    setGauge(hp, m.hp, m.maxhp,
      gaugeText("HP", m.hp, m.maxhp, H.cfg.p_lbl, H.cfg.p_num, H.cfg.p_pct), hpGrad(m.hp, m.maxhp))

    local mp = H.poolGauge(H.pMP, i, H.cParty, gaugesX, y + S(3), 150, gh)
    if num(m.maxmana) > 0 then
      setGauge(mp, m.mana, m.maxmana,
        gaugeText("MP", m.mana, m.maxmana, H.cfg.p_lbl, H.cfg.p_num, H.cfg.p_pct), GRAD.mn)
    end

    local tp = H.poolLabel(H.pTP, i, H.cParty, gaugesX, y, 56, rowH)
    tpNumberStyle(tp)
    tp:echo(tpNumberHTML(num(m.tp)))

    layoutRow(gaugesX, gaugesW, S(4), {
      { widget = hp, weight = 150, visible = true, y = y + S(3), height = gh },
      { widget = mp, weight = 150, visible = H.cfg.p_mp and num(m.maxmana) > 0, y = y + S(3), height = gh },
      { widget = tp, weight = 56, visible = H.cfg.p_tp, y = y + S(3), height = gh },
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
  useScale("enemies")
  local e = H.gmcp("Char.Enemies") or {}
  local foes = e.enemies or {}
  local rowH = S(H.cfg.e_compact and 22 or 26)
  local gap = S(H.cfg.e_compact and 2 or 4)
  local rowW = H.cw(H.cEnemies)
  local y, i = H.enemiesTop, 0
  for _, foe in ipairs(foes) do
    i = i + 1
    local l = H.poolLabel(H.enemyPool, i, H.cEnemies, 8, y, rowW, rowH)
    l:setStyleSheet(enemyRowBarStyle(frac(foe.hp, foe.maxhp)))
    local dot = foe.target and "<span style='color:#f87171'>&#9654;</span> " or ""
    local pctTxt = ""
    if H.cfg.e_pct then
      pctTxt = "   <span style='color:" .. hpGrad(foe.hp, foe.maxhp)[1] .. "'>" ..
        tostring(foe.hp_percent or 0) .. "%</span>"
    end
    local conColor = CON_HEX[tostring(foe.con or "")] or "#f1f5f9"
    local nameTxt = "<span style='color:" .. conColor .. "'>" .. tostring(foe.name or "?") .. "</span>"
    l:echo(dot .. enemyMarkers(foe.flags) .. nameTxt .. pctTxt)
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
  useScale("pets")
  local p = H.gmcp("Char.Pets") or {}
  local pets = p.pets or {}
  local rowH = S(H.cfg.pt_compact and 22 or 26)
  local gap = S(H.cfg.pt_compact and 2 or 4)
  local rowW = H.cw(H.cPets)
  local y, i = H.petsTop, 0
  for _, pet in ipairs(pets) do
    i = i + 1
    local l = H.poolLabel(H.petPool, i, H.cPets, 8, y, rowW, rowH)
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
  local bw, bh, step = S(40), S(24), S(43)
  local x = 8
  for j, c in ipairs(PET_CMDS) do
    local b = H.poolLabel(H.petCmdPool, j, H.cPets, x, y + S(4), bw, bh)
    b:setStyleSheet(btnStyle("#22c55e"):gsub("AlignLeft", "AlignHCenter"))
    b:echo(c[1])
    b:setClickCallback(function() send(c[2]) end)
    x = x + step
  end
  hideFrom(H.petCmdPool, #PET_CMDS + 1)
end

function H.updateAbilities()
  if not H.built then return end
  if H.winVisible.abilities == false then H.cAbil:hide(); return end
  H.cAbil:show()
  useScale("abilities")
  local a = H.gmcp("Char.Abilities") or {}
  local rows = {}
  for _, s in ipairs(a.spells or {}) do rows[#rows + 1] = { s.name or s.cmd, s.cmd, "#38bdf8" } end
  for _, s in ipairs(a.weaponskills or {}) do rows[#rows + 1] = { s.name or s.cmd, s.cmd, "#fbbf24" } end
  local rowH = S(H.cfg.a_compact and 22 or 26)
  local gap = S(H.cfg.a_compact and 2 or 4)
  local rowW = H.cw(H.cAbil)
  local y, i = H.abilTop, 0
  for _, r in ipairs(rows) do
    i = i + 1
    local l = H.poolLabel(H.abilPool, i, H.cAbil, 8, y, rowW, rowH)
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
  useScale("map")

  local rm = H.gmcp("Room.Map")
  if type(rm) ~= "table" or type(rm.rooms) ~= "table" or #rm.rooms == 0 then
    hideFrom(H.mapPool, 1)
    hideFrom(H.mapLinkPool, 1)
    hideFrom(H.mapPartyPool, 1)
    return
  end

  local cell, gap = S(H.mapCell), H.mapGap
  local step = cell + gap
  local cols = math.max(1, math.floor(H.cw(H.cMap) / step))
  local rows = math.max(1, math.floor(H.ch(H.cMap) / step))
  local centerCol, centerRow = math.floor(cols / 2), math.floor(rows / 2)

  local center = nil
  for _, r in ipairs(rm.rooms) do
    if r.id == rm.center then center = r; break end
  end
  center = center or { x = 0, y = 0, z = rm.z }

  -- Pass 1: place every visible room on the grid (positions only). Links are
  -- drawn next so the cells, created last, sit on top of them.
  H.mapCellPos = {}
  local placed = {}
  for _, r in ipairs(rm.rooms) do
    if (r.z or 0) == (rm.z or 0) then
      local dx = (r.x or 0) - (center.x or 0)
      local dy = (r.y or 0) - (center.y or 0)
      local col = centerCol + dx
      local row = centerRow - dy -- north (+y) is up on screen
      if col >= 0 and col < cols and row >= 0 and row < rows then
        local x = 8 + col * step
        local y = H.mapTop + row * step
        H.mapCellPos[r.id] = { x = x, y = y }
        placed[#placed + 1] = r
      end
    end
  end

  -- Exit connectors between placed rooms (drawn under the cells).
  H.drawMapLinks(rm, H.mapCellPos, cell, step)

  -- Pass 2: the room cells themselves.
  local i = 0
  for _, r in ipairs(placed) do
    local pos = H.mapCellPos[r.id]
    i = i + 1
    local isCenter = (r.id == rm.center)
    local l = H.poolLabel(H.mapPool, i, H.cMap, pos.x, pos.y, cell, cell)
    l:setStyleSheet(roomCellStyle(r, isCenter))
    l:echo("<center>" .. cellGlyph(r, isCenter) .. "</center>")
    l:setToolTip(mapTooltipHtml(r))
    local rid, entered = r.id, r.entered
    l:setClickCallback(function()
      if entered then send("travelto " .. tostring(rid))
      else cecho("<red>[Map] You haven't been there.\n") end
    end)
  end
  hideFrom(H.mapPool, i + 1)

  -- Party overlay: small dots for same-zone group members (self is already
  -- the centered you-are-here diamond, so skip it here).
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

-- Re-flow a panel's children when the user drag-resizes it. Mudlet's
-- Adjustable.Container emits no per-instance resize event, so we poll each
-- panel's live pixel size on a light timer and re-run only the updaters whose
-- panel actually changed (children are positioned from the panel's live width,
-- so re-running relays them out at the new size).
function H.startResizeWatch()
  if H.resizeTimer then pcall(killTimer, H.resizeTimer) end
  H.lastSize = {}
  local function tick()
    if not H.built then return end
    for k, c in pairs(H.windows or {}) do
      if c and H.winVisible[k] ~= false then
        local w, h = 0, 0
        pcall(function() w = c:get_width(); h = c:get_height() end)
        local prev = H.lastSize[k]
        if not prev then
          H.lastSize[k] = { w = w, h = h }          -- first sight: initial layout already ran
        elseif prev.w ~= w or prev.h ~= h then
          H.lastSize[k] = { w = w, h = h }
          local fn = H.updaters[k]
          if fn then pcall(fn) end
        end
      end
    end
  end
  local function loop()
    tick()
    H.resizeTimer = tempTimer(0.4, loop)
  end
  loop()
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
      useScale(key)
      pcall(function() c:move(d.x, d.y) end)
      pcall(function() c:resize(S(d.w), S(d.h)) end)
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
  "  ui scale <n>       - size EVERY panel (e.g. 1.25; try 0.8-1.6)",
  "  ui scale <win> <n> - size ONE panel: vitals/party/target/enemies/pets/abilities/map",
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
  elseif cmd == "scale" or cmd == "font" or cmd == "size" then
    -- Forms: "ui scale <n>" (every panel) or "ui scale <panel> <n>" (one panel).
    local a1, a2 = arg:match("^(%S*)%s*(%S*)$")
    local panelKey, val
    if a2 ~= "" then panelKey = string.lower(a1); val = tonumber(a2) else val = tonumber(a1) end
    if not val then
      local parts = {}
      for _, k in ipairs(PANEL_KEYS) do parts[#parts + 1] = k .. "=" .. tostring(H.cfg.pscale[k] or 1) end
      cecho("<cyan>[Norrath HUD] per-panel scale: " .. table.concat(parts, "  ") .. "\n")
      cecho("<cyan>  Usage: |wui scale <n>|n (all) or |wui scale <panel> <n>|n -- panels: " ..
        table.concat(PANEL_KEYS, ", ") .. ".\n")
      return
    end
    val = math.max(0.5, math.min(3.0, val))
    if panelKey and panelKey ~= "" then
      local valid = false
      for _, k in ipairs(PANEL_KEYS) do if k == panelKey then valid = true end end
      if not valid then
        cecho("<red>[Norrath HUD] no panel '" .. panelKey .. "'. Panels: " ..
          table.concat(PANEL_KEYS, ", ") .. ".\n")
        return
      end
      H.cfg.pscale[panelKey] = val
      cecho("<green>[Norrath HUD] " .. panelKey .. " scale = " .. val .. ".\n")
    else
      for _, k in ipairs(PANEL_KEYS) do H.cfg.pscale[k] = val end
      cecho("<green>[Norrath HUD] all panels scale = " .. val .. ".\n")
    end
    H.saveCfg()
    H.resetPositions()
    H.refreshAll()
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
-- Main-window / resolution change: reflow everything to the new geometry.
on("sysWindowResizeEvent", function() H.refreshAll() end)

-- ---------------------------------------------------------------------------
-- Companion-package auto-install
--
-- Mudlet's built-in Client.GUI handshake only carries ONE package (this HUD).
-- The server therefore also advertises its sibling packages over GMCP
-- `Client.Packages` = { packages = { {name, version, url}, ... } } -- the
-- fishing widget, the cutscene overlay -- and the HUD installs/upgrades
-- them: anything missing, or whose advertised version differs from the one
-- recorded in the HUD config, is (re)installed from the public mirror.
-- One attempt per package per session, so a failed download can't loop.
-- ---------------------------------------------------------------------------
function H.syncPackages()
  local data = gmcp and gmcp.Client and gmcp.Client.Packages
  if not data or type(data.packages) ~= "table" then return end
  H.pkgTried = H.pkgTried or {}
  H.cfg.pkgVersions = H.cfg.pkgVersions or {}
  local installed = {}
  for _, name in ipairs(getPackages and getPackages() or {}) do
    installed[name] = true
  end
  for _, pkg in ipairs(data.packages) do
    local name = pkg.name
    local version = tostring(pkg.version or "1")
    local url = pkg.url
    if name and url and not H.pkgTried[name] then
      local have = H.cfg.pkgVersions[name]
      if not installed[name] or have ~= version then
        H.pkgTried[name] = true
        if installed[name] then pcall(uninstallPackage, name) end
        cecho("<cyan>[Norrath HUD] installing companion package " .. name ..
          " v" .. version .. "...\n")
        local ok = pcall(installPackage, url)
        if ok then
          H.cfg.pkgVersions[name] = version
          H.saveCfg()
        else
          cecho("<red>[Norrath HUD] could not install " .. name ..
            " -- grab it by hand via the in-game 'client' command.\n")
        end
      end
    end
  end
end
on("gmcp.Client.Packages", function() H.syncPackages() end)

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
H.startResizeWatch()  -- reflow children when a panel is drag-resized
cecho("<green>[Norrath HUD]<reset> v9 loaded (map now draws exit connectors between rooms + per-panel scale). Right-click a panel -> Bigger/Smaller, or 'ui help'.\n")
