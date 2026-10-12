-- The AirDrop panel. Everything privileged happens here, behind a button:
-- `on`, `off` and `visibility` cross into pkexec, so the panel asks for them
-- explicitly instead of letting a poller raise auth dialogs unprompted.

local snapshot = nil
local peers = nil
local busy = false
local duration = noctalia.getConfig("duration")
local audience = "everyone"

local DURATIONS = { "1m", "3m", "5m", "10m", "30m", "once", "forever" }
local DURATION_LABELS = {
  "1 minute",
  "3 minutes",
  "5 minutes",
  "10 minutes",
  "30 minutes",
  "Until the transfer is done",
  "No limit",
}
local AUDIENCES = { "everyone", "contacts" }
local AUDIENCE_LABELS = { "Everyone nearby", "Known senders only" }

local IDLE = "on_surface/0.6"
local FAINT = "on_surface/0.4"
local DECLINED = "#f59e0b"
local BROKEN = "#ef4444"

local function bin()
  return noctalia.state.get("bin") or "omdrop"
end

local function decode(text)
  local value = noctalia.json.decode(noctalia.string.trim(text or ""))
  if type(value) ~= "table" then return nil end
  return value
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then return i end
  end
  return 1
end

local function durationLabel(value)
  return DURATION_LABELS[indexOf(DURATIONS, value)]
end

local function headline()
  local s = snapshot
  if type(s) ~= "table" then return "Waiting for omdrop", FAINT end
  if s.ok == false then return s.error or "omdrop is not answering", BROKEN end
  if s.receiving ~= true then return "Not receiving", IDLE end
  if s.visible == true then return "Receiving", "primary" end
  if s.visibleKnown == true then return "Receiving, but not visible", DECLINED end
  return "Receiving", IDLE
end

local function detail()
  local s = snapshot
  if type(s) ~= "table" or s.ok == false then return "" end
  if s.receiving ~= true then
    return "Apple devices cannot see this machine right now."
  end
  if s.visibleKnown == true and s.visible ~= true then
    return s.reason or "The radio did not come up."
  end
  if tonumber(s.remaining) then
    return clock(s.remaining) .. " left in this window."
  end
  if s.mode == "forever" then return "No time limit on this window." end
  return "Visible to nearby Apple devices."
end

local function peersSummary()
  if type(peers) ~= "table" then return "..." end
  if #peers == 0 then return "none seen yet" end
  local first = peers[1]
  local label = type(first) == "table" and first.name or nil
  if label == nil or label == "" then
    return string.format("%d nearby", #peers)
  end
  return string.format("%d nearby, e.g. %s", #peers, label)
end

local function refreshPeers()
  local started = noctalia.runAsync({ bin(), "peers", "--json" }, function(res)
    -- Exit 1 with `[]` simply means the window is closed.
    if res.timedOut or res.exitCode ~= 0 then
      peers = nil
    else
      peers = decode(res.stdout) or {}
    end
    render()
  end, 20000)
  if not started then render() end
end

-- The service only wakes on its own timer, which is up to idle_interval away.
-- After an action the panel reads status itself so the bar and this window
-- update at once instead of after the next poll.
local function refresh()
  local started = noctalia.runAsync({ bin(), "status", "--json" }, function(res)
    if res.timedOut or res.exitCode ~= 0 then
      render()
      return
    end
    local raw = decode(res.stdout)
    if raw == nil then
      render()
      return
    end
    local previous = snapshot
    noctalia.state.set("status", {
      ok = true,
      receiving = raw.receiving == true,
      visible = raw.visible == true,
      visibleKnown = raw.visible ~= nil,
      remaining = tonumber(raw.remaining),
      name = raw.name,
      dir = raw.dir,
      mode = raw.mode or "",
      reason = raw.reason,
      rx_proven = raw.rx_proven == true,
      visibility = raw.visibility or "everyone",
      senders = tonumber(raw.senders) or 0,
      missing = type(previous) == "table" and previous.missing or nil,
    })
    render()
  end, 20000)
  if not started then render() end
  refreshPeers()
end

local function act(args, doneMessage)
  if busy then return end
  busy = true
  render()
  -- Keep the service polling fast for a moment so it agrees with what we are
  -- about to see.
  noctalia.state.set("urgent_until", noctalia.nowMs() + noctalia.getConfig("action_grace_ms"))

  local argv = { bin() }
  for _, value in args do table.insert(argv, value) end

  local started = noctalia.runAsync(argv, function(res)
    busy = false
    if res.timedOut then
      noctalia.notifyError("AirDrop", "omdrop did not finish. If a password prompt appeared, it timed out.")
    elseif res.exitCode ~= 0 then
      local message = noctalia.string.trim(res.stderr or "")
      if message == "" then message = "omdrop exited with status " .. tostring(res.exitCode) end
      noctalia.notifyError("AirDrop", message)
    elseif doneMessage then
      noctalia.notify("AirDrop", doneMessage)
    end
    refresh()
  end, 60000)

  if not started then
    busy = false
    noctalia.notifyError("AirDrop", "could not run omdrop")
    render()
  end
end

local function toggle()
  local s = snapshot
  if type(s) == "table" and s.ok ~= false and s.receiving == true then
    act({ "off" }, "Stopped receiving")
    return
  end
  local args = { "on" }
  if audience == "contacts" then table.insert(args, "-c") end
  table.insert(args, duration)
  act(args, "Receiving for " .. durationLabel(duration))
end

local function row(label, value)
  return ui.row({ justify = "space_between", gap = 12 }, {
    ui.label({ text = label, fontSize = 11, color = FAINT }),
    ui.label({ text = value, fontSize = 11, maxWidth = 230, textAlign = "right" }),
  })
end

local function render()
  local s = snapshot
  local title, color = headline()
  local receiving = type(s) == "table" and s.ok ~= false and s.receiving == true

  local body = {}

  table.insert(body, ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = color }))
  local subtitle = detail()
  if subtitle ~= "" then
    table.insert(body, ui.label({ text = subtitle, fontSize = 11, color = FAINT }))
  end

  -- Whatever omdrop's doctor says is missing, said in its own words.
  local missing = type(s) == "table" and s.ok ~= false and s.missing or nil
  if type(missing) == "table" and #missing > 0 then
    local notices = {}
    for _, item in ipairs(missing) do
      if type(item) == "table" and type(item.say) == "string" then
        table.insert(notices, ui.label({ text = item.say, fontSize = 11, color = DECLINED }))
      end
    end
    if #notices > 0 then
      table.insert(body, ui.column({
        gap = 4,
        padding = 10,
        radius = 8,
        border = "on_surface/0.15",
        borderWidth = 1,
      }, notices))
    end
  end

  table.insert(body, ui.button({
    text = busy and "Working..."
      or receiving and "Stop receiving"
      or "Receive for " .. durationLabel(duration),
    variant = receiving and "destructive" or "primary",
    enabled = not busy,
    onClick = toggle,
  }))

  table.insert(body, ui.row({ gap = 10, align = "center" }, {
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = "Window", fontSize = 11, color = FAINT }),
      ui.select({
        options = DURATION_LABELS,
        selectedIndex = indexOf(DURATIONS, duration),
        controlSize = "sm",
        onChange = function(index)
          local picked = tonumber(index)
          if picked == nil then return end
          duration = DURATIONS[picked + 1] or duration
          render()
        end,
      }),
    }),
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = "Who can send", fontSize = 11, color = FAINT }),
      ui.select({
        options = AUDIENCE_LABELS,
        selectedIndex = indexOf(AUDIENCES, audience),
        enabled = not busy,
        controlSize = "sm",
        onChange = function(index)
          local picked = tonumber(index)
          if picked == nil then return end
          local mode = AUDIENCES[picked + 1]
          if mode == nil or mode == audience then return end
          audience = mode
          -- omdrop restarts the receiver for this, so say so before doing it.
          act({ "visibility", mode }, "Now accepting " .. AUDIENCE_LABELS[picked + 1]:lower())
        end,
      }),
    }),
  }))

  if audience == "contacts" then
    table.insert(body, ui.label({
      text = string.format(
        "Known senders only, %d listed. Changing this restarts the window.",
        type(s) == "table" and (tonumber(s.senders) or 0) or 0
      ),
      fontSize = 10,
      color = FAINT,
    }))
  end

  table.insert(body, ui.separator({ spacing = 10 }))

  local known = type(s) == "table" and s.ok ~= false
  table.insert(body, row("This machine appears as", known and (s.name or "unnamed") or "unknown"))
  table.insert(body, row("Incoming files land in", known and (s.dir or "unknown") or "unknown"))
  table.insert(body, row("Nearby peers", receiving and peersSummary() or "window closed"))

  table.insert(body, ui.row({ gap = 8 }, {
    ui.button({
      text = "Send files",
      glyph = "send",
      variant = "outline",
      flexGrow = 1,
      onClick = function() noctalia.runInTerminal("omdrop send --pick") end,
    }),
    ui.button({
      text = "Open folder",
      glyph = "folder-open",
      variant = "outline",
      flexGrow = 1,
      enabled = not busy,
      onClick = function() noctalia.runInTerminal("xdg-open " .. (known and s.dir or "")) end,
    }),
    ui.button({
      text = "Recheck",
      glyph = "refresh",
      variant = "ghost",
      tooltip = "Ask omdrop what it still needs",
      enabled = not busy,
      onClick = function()
        -- The service polls the doctor itself while the window is closed; this
        -- only makes it happen now rather than at the next idle tick.
        noctalia.state.set("urgent_until", noctalia.nowMs() + noctalia.getConfig("action_grace_ms"))
        refresh()
      end,
    }),
  }))

  table.insert(body, ui.button({
    text = "Plugin settings",
    glyph = "settings",
    variant = "ghost",
    onClick = function() noctalia.openSettings() end,
  }))

  panel.render(ui.column({ gap = 12, padding = 18 }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.glyph({ name = "brand-apple", size = 18, color = color }),
      ui.label({ text = "AirDrop", fontWeight = "bold" }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        tooltip = "Close",
        onClick = function() panel.close() end,
      }),
    }),
    table.unpack(body),
  }))
end

-- Declared last: it calls render, which has to exist first.
noctalia.state.watch("status", function(value)
  snapshot = value
  if type(value) == "table" and type(value.visibility) == "string" then
    audience = value.visibility
  end
  render()
end)

function onOpen()
  snapshot = noctalia.state.get("status")
  render()
  refresh()
end