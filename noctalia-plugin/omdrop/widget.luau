-- Bar glyph: an Apple mark that turns amber when omdrop asked to be visible
-- and the radio declined, and red when omdrop itself is unhappy. Only this
-- file draws in the bar, so it stays one control tall and cheap to reconcile.

local snapshot = nil

noctalia.state.watch("status", function(value)
  snapshot = value
end)

local IDLE = "on_surface/0.4"
local UNKNOWN = "on_surface/0.55"
local DECLINED = "#f59e0b"
local BROKEN = "#ef4444"

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function appearance(s)
  if type(s) ~= "table" then return "loader-2", IDLE end
  if s.ok == false then return "alert-triangle", BROKEN end
  if s.receiving ~= true then return "brand-apple", IDLE end
  if s.visibleKnown ~= true then return "brand-apple", UNKNOWN end
  if s.visible ~= true then return "brand-apple", DECLINED end
  return "brand-apple", "primary"
end

local function tooltip(s)
  if type(s) ~= "table" then return "AirDrop: waiting for omdrop" end
  if s.ok == false then return "AirDrop: " .. (s.error or "omdrop is not answering") end
  if s.receiving ~= true then return "AirDrop: not receiving, click to open" end

  local lines = { "AirDrop: receiving" }
  if s.visible == true then
    table.insert(lines, "visible to nearby Apple devices")
  elseif s.visibleKnown == true then
    table.insert(lines, "not visible: " .. (s.reason or "the radio declined"))
  else
    table.insert(lines, "radio state unknown")
  end
  if tonumber(s.remaining) then
    table.insert(lines, clock(s.remaining) .. " left")
  elseif s.mode == "forever" then
    table.insert(lines, "no time limit")
  end
  return table.concat(lines, " - ")
end

function update()
  -- The service owns the polling cadence; this only redraws.
  noctalia.setUpdateInterval(1000)

  local s = snapshot
  local glyph, color = appearance(s)
  local children = { ui.glyph({ name = glyph, size = 15, color = color }) }

  if type(s) == "table" and s.ok ~= false and s.receiving == true
    and noctalia.getConfig("show_remaining") == true and tonumber(s.remaining) then
    table.insert(children, ui.label({ text = clock(s.remaining), fontSize = 10, color = color }))
  end

  barWidget.setTooltip(tooltip(s))
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
end

function onClick()
  noctalia.togglePanel("me/omdrop:panel")
end