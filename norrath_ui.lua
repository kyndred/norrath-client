--[[  Norrath UI  --  MudForge plugin
      ------------------------------------------------------------------------
      Adds the pieces MudForge's built-in widgets don't cover for Norrath:

        * TP gauge        (Tactical Points 0-300, our signature resource)
        * Target bar      (current combat target's HP)
        * Pets window     (click a pet to select it; command buttons below)
        * Enemies window  (click an enemy to target/attack it)
        * Abilities       (buttons for your castable spells + weaponskills)

      The native Status Bar (HP/mana/movement + name/level), Map, Group and
      Chat widgets are fed directly by the server over standard GMCP, so leave
      those turned on -- this plugin only adds the extras above.

      Built on the canvas API (clear/drawRect/drawText + click hit-testing);
      each widget redraws itself whenever its GMCP package updates.

      Install: paste into MudForge's plugin editor and enable. Hot-reloadable.
]]--

plugin = {
  name = "Norrath UI",
  author = "Norrath",
  version = "1.7",
  description = "TP gauge, target bar, clickable pet/enemy windows, and spell/weaponskill buttons for Norrath.",
}

print("Norrath UI loading...")

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local FONT = "12px monospace"
local BG = "#14161c"
local TRACK = "#2a2f3a"
local DIM = "#6b7280"

local function frac(cur, mx)
  local c = tonumber(cur) or 0
  local m = tonumber(mx) or 0
  if m <= 0 then m = 1 end
  local f = c / m
  if f < 0 then return 0 elseif f > 1 then return 1 else return f end
end

local function hpcolor(cur, mx)
  local f = frac(cur, mx)
  if f > 0.5 then return "#4ade80" elseif f > 0.25 then return "#facc15" else return "#f87171" end
end

-- Always return a table for a GMCP package. Prefer data handed to a callback;
-- otherwise fetch it. getGMCPData() can return JS undefined before any data
-- has arrived, which Lua's `or {}` doesn't catch -- the type() guard does.
local function pkgData(passed, pkg)
  if type(passed) == "table" then return passed end
  local d = getGMCPData(pkg)
  if type(d) == "table" then return d end
  return {}
end

-- ---------------------------------------------------------------------------
-- widget records: { id, boxes = {clickable regions}, render = fn }
-- ---------------------------------------------------------------------------
local created = {}  -- ids of widgets we made, so we can tear them down cleanly

local function destroyAll()
  if type(destroyWidget) == "function" then
    for _, id in ipairs(created) do
      pcall(destroyWidget, id)
    end
  end
  created = {}
end

local function makeWidget(title, x, y, w, h)
  local rec = { boxes = {}, x = x, y = y, w = w, h = h, settingsOpen = false }
  rec.id = createWidget({ type = "canvas", title = title, x = x, y = y, width = w, height = h })
  table.insert(created, rec.id)
  registerWidgetEvent(rec.id, "click", function(d)
    if type(d) ~= "table" then return end
    for _, b in ipairs(rec.boxes) do
      if d.x >= b.x and d.x <= b.x + b.w and d.y >= b.y and d.y <= b.y + b.h then
        -- A box either runs a Lua callback (UI action) or sends a MUD command.
        if type(b.fn) == "function" then b.fn() else send(b.cmd) end
        return
      end
    end
  end)
  registerWidgetEvent(rec.id, "resize", function(d)
    if type(d) == "table" then
      if d.width then rec.w = d.width end
      if d.height then rec.h = d.height end
    end
    -- Guard on type(): the resize event can fire before init() has assigned
    -- rec.render (e.g. during the resizeWidget() call above).
    if type(rec.render) == "function" then rec.render() end
  end)
  return rec
end

-- Draw a labelled progress bar on the active widget. Returns next Y.
local function drawBar(x, y, w, cur, mx, color, label)
  drawRect(x, y, w, 12, TRACK)
  drawRect(x, y, math.floor(w * frac(cur, mx)), 12, color)
  if label then drawText(label, x, y - 3, "#e5e7eb") end
  return y + 18
end

-- Register + draw a button; records its hit-box on rec. Returns next X.
local function button(rec, x, y, w, h, label, cmd, color)
  drawRect(x, y, w, h, color or "#334155", "#475569")
  drawText(label, x + 6, y + math.floor(h / 2) + 4, "#e5e7eb")
  table.insert(rec.boxes, { x = x, y = y, w = w, h = h, cmd = cmd })
  return x + w + 6
end

-- ---------------------------------------------------------------------------
-- config  (persisted across sessions via saveTable/loadTable)
-- ---------------------------------------------------------------------------
local CFG_KEY = "norrath_ui_config"
local cfg

local function defaultCfg()
  return {
    vitals = { mn = true, mv = true, tp = true, header = true,
               labels = true, numbers = true, percent = true, side = false },
    party  = { mn = false, mv = false, tp = true,
               labels = true, numbers = true, percent = true },
  }
end

local function loadCfg()
  local c = loadTable(CFG_KEY)
  if type(c) ~= "table" then c = {} end
  -- Merge in any missing keys from defaults (forward-compatible).
  local d = defaultCfg()
  for section, opts in pairs(d) do
    if type(c[section]) ~= "table" then c[section] = {} end
    for k, val in pairs(opts) do
      if c[section][k] == nil then c[section][k] = val end
    end
  end
  return c
end

local function saveCfg()
  if type(saveTable) == "function" then saveTable(CFG_KEY, cfg) end
end

-- A small "cfg" button top-right; click toggles the widget's settings overlay.
local function drawGear(rec)
  local bw, bh = 26, 14
  local x = (rec.w or 260) - bw - 2
  drawRect(x, 2, bw, bh, "#1f2937", "#374151")
  drawText("cfg", x + 4, 12, "#94a3b8")
  table.insert(rec.boxes, { x = x, y = 2, w = bw, h = bh, fn = function()
    rec.settingsOpen = not rec.settingsOpen
    if rec.render then rec.render() end
  end })
end

-- Render a toggle list for cfg[section] using spec = { {key,label}, ... }.
local function renderSettings(rec, section, spec)
  setActiveWidget(rec.id)
  setFont("monospace", 12)
  clear(BG)
  drawText("Settings", 8, 14, "#e5e7eb")
  local y = 24
  for _, opt in ipairs(spec) do
    local on = cfg[section][opt.key]
    drawText(opt.label, 8, y + 12, "#e5e7eb")
    local bx = (rec.w or 260) - 46
    drawRect(bx, y, 38, 16, on and "#166534" or "#3f3f46", "#52525b")
    drawText(on and "ON" or "OFF", bx + 6, y + 12, "#e5e7eb")
    table.insert(rec.boxes, { x = bx, y = y, w = 38, h = 16, fn = function()
      cfg[section][opt.key] = not cfg[section][opt.key]
      saveCfg()
      if rec.render then rec.render() end
    end })
    y = y + 20
  end
  drawRect(8, y + 4, 60, 18, "#334155", "#475569")
  drawText("Done", 18, y + 16, "#e5e7eb")
  table.insert(rec.boxes, { x = 8, y = y + 4, w = 60, h = 18, fn = function()
    rec.settingsOpen = false
    if rec.render then rec.render() end
  end })
end

local VITALS_SPEC = {
  { key = "header", label = "Character info" },
  { key = "mn", label = "Show Mana" },
  { key = "mv", label = "Show Movement" },
  { key = "tp", label = "Show TP" },
  { key = "labels", label = "Show Labels" },
  { key = "numbers", label = "Show Numbers" },
  { key = "percent", label = "Show Percent" },
  { key = "side", label = "Side-by-Side" },
}
local PARTY_SPEC = {
  { key = "mn", label = "Show Mana" },
  { key = "mv", label = "Show Movement" },
  { key = "tp", label = "Show TP" },
  { key = "labels", label = "Show Labels" },
  { key = "numbers", label = "Show Numbers" },
  { key = "percent", label = "Show Percent" },
}

local wVitals, wParty, wTarget, wPets, wEnemies, wAbil

-- A labelled gauge row honoring cfg flags (labels / numbers / percent).
-- Returns next Y (stacked) -- callers handle side-by-side placement.
local function gaugeRow(x, y, w, label, cur, mx, color, c)
  local lw = c.labels and 30 or 0
  local bx = x + lw
  local bw = w - lw
  drawRect(bx, y, bw, 14, TRACK)
  drawRect(bx, y, math.floor(bw * frac(cur, mx)), 14, color)
  if c.labels then drawText(label, x, y + 11, "#e5e7eb") end
  local txt = ""
  if c.numbers then txt = tostring(cur) .. "/" .. tostring(mx) end
  if c.percent then
    local pctv = math.floor(frac(cur, mx) * 100 + 0.5)
    txt = txt .. (txt ~= "" and " " or "") .. "(" .. pctv .. "%)"
  end
  if txt ~= "" then drawText(txt, bx + 6, y + 11, "#0b0f14") end
  return y + 18
end

-- Place a list of gauges {label,cur,max,color} either stacked or 2-up.
local function layoutGauges(x, y, w, gauges, c)
  if c.side then
    local colW = math.floor((w - 6) / 2)
    for i, g in ipairs(gauges) do
      local col = (i % 2 == 1) and x or (x + colW + 6)
      gaugeRow(col, y, colW, g[1], g[2], g[3], g[4], c)
      if i % 2 == 0 then y = y + 18 end
    end
    if #gauges % 2 == 1 then y = y + 18 end
    return y
  end
  for _, g in ipairs(gauges) do
    y = gaugeRow(x, y, w, g[1], g[2], g[3], g[4], c)
  end
  return y
end

-- ---------------------------------------------------------------------------
-- Vitals panel  (Char.Vitals + Char.Base)  -- our own HP / MN / MV / TP row
-- stack, TP included. Hide MudForge's native Status widget and use this.
-- ---------------------------------------------------------------------------
local function renderVitals(_)
  wVitals.boxes = {}
  if wVitals.settingsOpen then
    renderSettings(wVitals, "vitals", VITALS_SPEC)
    drawGear(wVitals)
    return
  end
  local v = pkgData(nil, "Char.Vitals")
  local b = pkgData(nil, "Char.Base")
  local c = cfg.vitals
  setActiveWidget(wVitals.id)
  setFont("monospace", 12)
  clear(BG)
  local y = 6
  if c.header then
    drawText(tostring(b.name or "?") .. "  (Lvl " .. tostring(b.level or 0) .. ")", 8, 15, "#e5e7eb")
    y = 24
  end
  local W = (wVitals.w or 300) - 16
  local gauges = { { "HP", tonumber(v.hp) or 0, tonumber(v.maxhp) or 1, hpcolor(v.hp, v.maxhp) } }
  if c.mn and (tonumber(v.maxmana) or 0) > 0 then
    gauges[#gauges + 1] = { "MN", tonumber(v.mana) or 0, tonumber(v.maxmana) or 1, "#3b82f6" }
  end
  if c.mv then
    gauges[#gauges + 1] = { "MV", tonumber(v.movement) or 0, tonumber(v.maxmove) or 1, "#22c55e" }
  end
  if c.tp then
    local tp = tonumber(v.tp) or 0
    gauges[#gauges + 1] = { "TP", tp, tonumber(v.maxtp) or 300, tp >= 100 and "#fbbf24" or "#4ade80" }
  end
  layoutGauges(8, y, W, gauges, c)
  drawGear(wVitals)
end

-- ---------------------------------------------------------------------------
-- Party panel  (Group.Members array)  -- per-member HP + TP, TP included.
-- ---------------------------------------------------------------------------
local function renderParty(m)
  wParty.boxes = {}
  if wParty.settingsOpen then
    renderSettings(wParty, "party", PARTY_SPEC)
    drawGear(wParty)
    return
  end
  local members = m
  if type(members) ~= "table" then members = getGMCPData("Group.Members") end
  if type(members) ~= "table" then members = {} end
  local c = cfg.party
  setActiveWidget(wParty.id)
  setFont("monospace", 11)
  clear(BG)
  if #members == 0 then
    drawText("(solo)", 8, 16, DIM)
    drawGear(wParty)
    return
  end
  local W = (wParty.w or 260) - 16
  local y = 6
  for _, mm in ipairs(members) do
    local tag = tostring(mm.name or "?") .. " L" .. tostring(mm.level or 0)
    if mm["self"] then tag = "* " .. tag end
    drawText(tag, 8, y + 10, "#e5e7eb")
    y = y + 13
    local gauges = { { "HP", tonumber(mm.hp) or 0, tonumber(mm.maxhp) or 1, hpcolor(mm.hp, mm.maxhp) } }
    if c.mn and (tonumber(mm.maxmana) or 0) > 0 then
      gauges[#gauges + 1] = { "MN", tonumber(mm.mana) or 0, tonumber(mm.maxmana) or 1, "#3b82f6" }
    end
    if c.mv then
      gauges[#gauges + 1] = { "MV", tonumber(mm.movement) or 0, tonumber(mm.maxmove) or 1, "#22c55e" }
    end
    if c.tp then
      local tp = tonumber(mm.tp) or 0
      gauges[#gauges + 1] = { "TP", tp, tonumber(mm.maxtp) or 300, tp >= 100 and "#fbbf24" or "#4ade80" }
    end
    for _, g in ipairs(gauges) do
      y = gaugeRow(8, y, W, g[1], g[2], g[3], g[4], c)
    end
    y = y + 4
  end
  drawGear(wParty)
end

-- ---------------------------------------------------------------------------
-- Target bar  (Char.Target)
-- ---------------------------------------------------------------------------
local function renderTarget(t)
  local tg = pkgData(t, "Char.Target")
  setActiveWidget(wTarget.id)
  setFont("monospace", 12)
  clear(BG)
  if tg.active then
    local col = hpcolor(tg.hp, tg.maxhp)
    drawText(tostring(tg.name or "?"), 8, 16, col)
    drawBar(8, 30, 200, tg.hp, tg.maxhp, col, nil)
    drawText((tg.hp_percent or 0) .. "%", 8, 62, col)
  else
    drawText("(no target)", 8, 20, DIM)
  end
end

-- ---------------------------------------------------------------------------
-- Pets window  (Char.Pets)  -- click a pet to select; command row below
-- ---------------------------------------------------------------------------
local PET_CMDS = {
  { "Atk", "pet attack" }, { "Back", "pet back" }, { "Guard", "pet guard" },
  { "Foll", "pet follow" }, { "Aggr", "pet aggressive" }, { "Pass", "pet passive" },
}

local function renderPets(p)
  local pets = pkgData(p, "Char.Pets").pets or {}
  wPets.boxes = {}
  setActiveWidget(wPets.id)
  setFont("monospace", 12)
  clear(BG)
  if #pets == 0 then
    drawText("(no pets)", 8, 20, DIM)
    return
  end
  local y = 8
  for _, pet in ipairs(pets) do
    local col = hpcolor(pet.hp, pet.maxhp)
    local mark = pet.active and "> " or "  "
    drawText(mark .. tostring(pet.name or "?") .. " L" .. (pet.level or 0) ..
             " [" .. tostring(pet.mode or "") .. "]", 8, y + 12, col)
    drawBar(8, y + 20, 240, pet.hp, pet.maxhp, col, nil)
    -- Whole row is a "select this pet" click target.
    table.insert(wPets.boxes, { x = 4, y = y, w = 250, h = 34,
      cmd = pet.cmd or ("pet select " .. tostring(pet.name or "")) })
    y = y + 40
  end
  -- Command row acts on the currently selected pet (server-side).
  local x = 6
  for _, c in ipairs(PET_CMDS) do
    x = button(wPets, x, y, 38, 20, c[1], c[2])
    if x > 210 then
      x = 6
      y = y + 24
    end
  end
end

-- ---------------------------------------------------------------------------
-- Enemies window  (Char.Enemies)  -- click to target/attack
-- ---------------------------------------------------------------------------
local function renderEnemies(e)
  local foes = pkgData(e, "Char.Enemies").enemies or {}
  wEnemies.boxes = {}
  setActiveWidget(wEnemies.id)
  setFont("monospace", 12)
  clear(BG)
  if #foes == 0 then
    drawText("(no enemies here)", 8, 20, DIM)
    return
  end
  local y = 8
  for _, foe in ipairs(foes) do
    local col = hpcolor(foe.hp, foe.maxhp)
    local mark = foe.target and "> " or "  "
    drawText(mark .. tostring(foe.name or "?") .. "  " .. (foe.hp_percent or 0) .. "%", 8, y + 12, col)
    drawBar(8, y + 20, 240, foe.hp, foe.maxhp, col, nil)
    table.insert(wEnemies.boxes, { x = 4, y = y, w = 250, h = 34,
      cmd = foe.cmd or ("attack " .. tostring(foe.name or "")) })
    y = y + 40
  end
end

-- ---------------------------------------------------------------------------
-- Abilities  (Char.Abilities)  -- spell + weaponskill buttons
-- ---------------------------------------------------------------------------
local function renderAbilities(a)
  local data = pkgData(a, "Char.Abilities")
  local spells = data.spells or {}
  local ws = data.weaponskills or {}
  wAbil.boxes = {}
  setActiveWidget(wAbil.id)
  setFont("monospace", 12)
  clear(BG)
  local y = 8
  local function group(label, list, color)
    if #list == 0 then return end
    drawText(label, 8, y + 12, color)
    y = y + 20
    for _, s in ipairs(list) do
      button(wAbil, 8, y, 200, 20, tostring(s.name or s.cmd), s.cmd, "#1f2937")
      y = y + 24
    end
  end
  group("-- Spells --", spells, "#38bdf8")
  group("-- Weaponskills --", ws, "#fbbf24")
  if #spells == 0 and #ws == 0 then drawText("(no abilities)", 8, 20, DIM) end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------
function cleanup()
  destroyAll()
end

function init()
  -- Tear down any widgets from a previous load so re-installing / reconnecting
  -- doesn't stack duplicate panels on top of each other.
  destroyAll()

  -- Load saved config (or defaults) before the first paint.
  cfg = loadCfg()

  wVitals = makeWidget("Vitals", 20, 20, 300, 210)
  wParty = makeWidget("Party", 20, 240, 264, 210)
  wTarget = makeWidget("Target", 20, 460, 264, 78)
  wPets = makeWidget("Pets", 294, 20, 262, 260)
  wEnemies = makeWidget("Enemies", 566, 20, 262, 260)
  wAbil = makeWidget("Abilities", 294, 292, 220, 300)

  wVitals.render = renderVitals
  wParty.render = renderParty
  wTarget.render = renderTarget
  wPets.render = renderPets
  wEnemies.render = renderEnemies
  wAbil.render = renderAbilities

  -- Force each widget to its intended spot/size AFTER render fns are wired up
  -- (some builds ignore createWidget's x/y/size and stack them all together).
  for _, rec in ipairs({ wVitals, wParty, wTarget, wPets, wEnemies, wAbil }) do
    if type(moveWidget) == "function" then pcall(moveWidget, rec.id, rec.x, rec.y) end
    if type(resizeWidget) == "function" then pcall(resizeWidget, rec.id, rec.w, rec.h) end
  end

  onGMCPUpdate("Char.Vitals", renderVitals)
  onGMCPUpdate("Char.Base", renderVitals)
  onGMCPUpdate("Group.Members", renderParty)
  onGMCPUpdate("Char.Target", renderTarget)
  onGMCPUpdate("Char.Pets", renderPets)
  onGMCPUpdate("Char.Enemies", renderEnemies)
  onGMCPUpdate("Char.Abilities", renderAbilities)

  renderVitals()
  renderParty()
  renderTarget()
  renderPets()
  renderEnemies()
  renderAbilities()

  utilprint("$G[" .. plugin.name .. " v" .. plugin.version .. "]$W by " ..
            plugin.author .. " - Installed!")
end
