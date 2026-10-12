-- Polls the omdrop CLI and publishes one snapshot to plugin state. The bar
-- widget and the panel both render from `status`, so there is a single source
-- of truth and neither entry has to spawn a process itself.
--
-- `omdrop status --json` and `omdrop doctor --json` are both unprivileged --
-- only `on`/`off` cross into pkexec -- so polling them can never raise an
-- auth prompt. Everything privileged lives behind a button in the panel.

local inFlight = false
local blockers = nil

local function resolveBin()
  local configured = noctalia.getConfig("omdrop_bin")
  if type(configured) ~= "string" or configured == "" then configured = "omdrop" end
  if noctalia.commandExists(configured) then return configured end
  -- Home Manager links the CLI here. That directory is on the session PATH,
  -- but resolve it explicitly so the panel still works from a shell that has
  -- not reloaded its profile.
  local linked = noctalia.expandPath("~/.local/bin/omdrop")
  if noctalia.fileExists(linked) then return linked end
  return configured
end

local function decode(text)
  local value = noctalia.json.decode(noctalia.string.trim(text or ""))
  if type(value) ~= "table" then return nil end
  return value
end

local function fail(message)
  noctalia.state.set("status", { ok = false, error = message })
end

-- A second process spawn, so only pay for it while the window is closed: while
-- we are receiving there are no blockers left to report.
local function pollDoctor(bin)
  local started = noctalia.runAsync({ bin, "doctor", "--json" }, function(res)
    if res.timedOut or res.exitCode ~= 0 then
      blockers = nil
      return
    end
    local data = decode(res.stdout)
    if type(data) ~= "table" or type(data.missing) ~= "table" then
      blockers = nil
      return
    end
    blockers = data.missing
  end, 20000)
  if not started then blockers = nil end
end

local function publish(raw)
  noctalia.state.set("status", {
    ok = true,
    receiving = raw.receiving == true,
    -- nil means "the radio half is not installed": omdrop genuinely does not
    -- know, and the bar must not draw that as "visible".
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
    missing = blockers,
  })
end

local function poll(bin)
  local started = noctalia.runAsync({ bin, "status", "--json" }, function(res)
    inFlight = false
    if res.timedOut then
      fail("omdrop status did not answer in time")
      return
    end
    if res.exitCode ~= 0 then
      local message = noctalia.string.trim(res.stderr or "")
      if message == "" then message = "omdrop exited with status " .. tostring(res.exitCode) end
      fail(message)
      return
    end
    local raw = decode(res.stdout)
    if raw == nil then
      fail("could not read omdrop's status output")
      return
    end
    publish(raw)
    if raw.receiving ~= true then pollDoctor(bin) end
  end, 20000)
  if not started then
    inFlight = false
    fail("could not run omdrop")
  end
end

function update()
  local snapshot = noctalia.state.get("status")
  local receiving = type(snapshot) == "table" and snapshot.receiving == true
  -- Poll hard for a while after the panel runs a command, so a turn-on shows up
  -- at once instead of at the end of the idle interval.
  local urgent = (tonumber(noctalia.state.get("urgent_until")) or 0) > noctalia.nowMs()
  local seconds = noctalia.getConfig("idle_interval")
  if receiving or urgent then seconds = noctalia.getConfig("active_interval") end
  noctalia.setUpdateInterval(seconds * 1000)

  local bin = resolveBin()
  noctalia.state.set("bin", bin)
  if inFlight then return end
  inFlight = true
  poll(bin)
end