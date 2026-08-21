local M = {}

M.enabled = true
M.busy = false
M.panelOpen = false

M.config = {
  models = {
    { label = "Haiku (fast)", value = "haiku" },
    { label = "Sonnet", value = "sonnet" },
    { label = "Opus (deepest)", value = "opus" },
  },
  cacheDir = os.getenv("HOME") .. "/.cache/atat",
  toggleMods = { "alt", "shift" },
  toggleKey = "a",
  pasteDelayMs = 250,
  restoreDelayMs = 350,
  formatRule = "Return ONLY the text to insert. No preamble, no explanation, no markdown fences.",
}

local function findClaude()
  local candidates = {
    "/opt/homebrew/bin/claude",
    os.getenv("HOME") .. "/.local/bin/claude",
    "/usr/local/bin/claude",
    "/usr/bin/claude",
  }
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then
      f:close()
      return p
    end
  end
  return nil
end

M.claudePath = findClaude()

local pendingAt = nil
local pendingTimer = nil
local draft = ""

local function flushPending()
  if pendingAt then
    pendingAt:post()
    pendingAt = nil
  end
  if pendingTimer then
    pendingTimer:stop()
    pendingTimer = nil
  end
end
local modelIdx = 1
local savedBundleID = nil
local savedClipboard = nil
local currentShotPath = nil
local webView = nil
local thinkingAlert = nil

os.execute("/bin/mkdir -p '" .. M.config.cacheDir .. "'")

M.logError = function(context, err)
  local line = string.format("[%s] %s: %s\n%s\n\n",
    os.date("%Y-%m-%d %H:%M:%S"), tostring(context), tostring(err), debug.traceback())
  local f = io.open(M.config.cacheDir .. "/error.log", "a")
  if f then
    f:write(line)
    f:close()
  end
  hs.alert.show("at-at error (" .. context .. "): " .. tostring(err), {}, nil, 8)
end

local function selectedModel()
  local saved = hs.settings.get("atat.model")
  for i, m in ipairs(M.config.models) do
    if m.value == saved then
      modelIdx = i
      return m.value
    end
  end
  modelIdx = 1
  return M.config.models[1].value
end

local function rememberModel(value)
  hs.settings.set("atat.model", value)
end

local function captureScreenshot()
  local path = M.config.cacheDir .. "/shot-" .. tostring(os.time()) .. ".png"
  local win = hs.window.frontmostWindow()
  local ok
  if win and win:id() then
    ok = os.execute("/usr/sbin/screencapture -x -o -l " .. win:id() .. " '" .. path .. "' 2>/dev/null")
  elseif win then
    local f = win:screen():frame()
    ok = os.execute(string.format(
      "/usr/sbin/screencapture -x -o -R%d,%d,%d,%d '%s' 2>/dev/null",
      math.floor(f.x), math.floor(f.y), math.floor(f.w), math.floor(f.h), path))
  else
    ok = os.execute("/usr/sbin/screencapture -x -m '" .. path .. "' 2>/dev/null")
  end
  if ok and hs.fs.attributes(path) ~= nil then
    return path
  end
  return nil
end

local function jsStr(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
  return '"' .. s .. '"'
end

local function panelHtml()
  return [[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    background: rgba(28, 28, 32, 0.94);
    color: #eee;
    padding: 14px;
  }
  .line { font-size: 15px; min-height: 44px; word-break: break-word; white-space: pre-wrap; }
  .line.empty { opacity: 0.4; }
  .cursor { display: inline-block; width: 2px; height: 16px; background: #d97757;
            vertical-align: text-bottom; animation: blink 1s steps(1) infinite; }
  @keyframes blink { 50% { opacity: 0; } }
  .row { display: flex; align-items: center; gap: 10px; margin-top: 10px; }
  #mdl { font-size: 12px; color: #d97757; font-weight: 600; }
  .badge { font-size: 11px; opacity: 0.55; }
  .badge.ok { opacity: 0.95; color: #7ec97e; }
  .spacer { flex: 1; }
  .hint { font-size: 11px; opacity: 0.45; }
</style>
</head>
<body>
  <div id="txt" class="line empty"></div>
  <div class="row">
    <span id="mdl"></span>
    <span id="shot" class="badge">no screenshot</span>
    <span class="spacer"></span>
    <span class="hint">&#8984;&#9166;/&#9166; send &#183; tab model &#183; esc cancel</span>
  </div>
<script>
  const txt = document.getElementById('txt');
  const PHRASE = "Type your prompt…";
  function upd(t) {
    if (t.length === 0) {
      txt.textContent = PHRASE;
      txt.className = "line empty";
      txt.innerHTML = PHRASE + ' <span class="cursor"></span>';
    } else {
      txt.className = "line";
      txt.textContent = t;
      const c = document.createElement("span");
      c.className = "cursor";
      txt.appendChild(c);
    }
  }
  function shot(ok) {
    const el = document.getElementById('shot');
    el.textContent = ok ? "screenshot attached" : "no screenshot";
    el.className = ok ? "badge ok" : "badge";
  }
</script>
</body>
</html>]]
end

local function updateUI()
  if webView then
    local ok, err = pcall(function()
      webView:evaluateJavaScript("upd(" .. jsStr(draft) .. ")")
    end)
    if not ok then
      M.logError("updateUI", err)
    end
  end
end

local function closePanel()
  if webView then
    pcall(function() webView:hide() end)
    pcall(function() webView:delete() end)
    webView = nil
  end
  M.panelOpen = false
end

local function cycleModel(dir)
  modelIdx = ((modelIdx - 1 + dir) % #M.config.models) + 1
  rememberModel(M.config.models[modelIdx].value)
  if webView then
    pcall(function()
      webView:evaluateJavaScript("document.getElementById('mdl').textContent=" ..
        jsStr(M.config.models[modelIdx].label))
    end)
  end
end

local function showPanel()
  selectedModel()
  draft = ""

  local shot = nil
  if M.screenshotEnabled ~= false then
    shot = captureScreenshot()
  end
  currentShotPath = shot

  local frame = hs.screen.mainScreen():frame()
  local w, h = 560, 120
  local rect = { x = frame.x + (frame.w - w) / 2, y = frame.y + frame.h * 0.62, w = w, h = h }

  webView = hs.webview.new(rect)
  webView:level(hs.drawing.windowLevels.floating)
  webView:darkMode(true)
  webView:html(panelHtml())
  webView:show()

  hs.timer.doAfter(0.05, function()
    if webView then
      pcall(function()
        webView:evaluateJavaScript(
          "shot(" .. tostring(shot ~= nil) .. ");" ..
          "document.getElementById('mdl').textContent=" .. jsStr(M.config.models[modelIdx].label) .. ";" ..
          "upd(" .. jsStr("") .. ")")
      end)
    end
  end)

  M.panelOpen = true
end

function M.cancelPrompt()
  closePanel()
  draft = ""
  currentShotPath = nil
end

function M.runQuery(prompt)
  if M.busy then
    return
  end
  prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return
  end
  if not M.claudePath then
    hs.alert.show("at-at: claude binary not found")
    return
  end

  M.busy = true
  thinkingAlert = hs.alert.show("at-at: thinking…", {}, hs.screen.mainScreen(), 3600)

  local fullPrompt = prompt
  if currentShotPath then
    fullPrompt = fullPrompt .. "\n\n[Context: a screenshot of the user's screen at trigger time is saved at "
      .. currentShotPath .. ". Read it with your Read tool if it helps answer.]"
  end

  local args = {
    "-p", fullPrompt,
    "--model", M.config.models[modelIdx].value,
    "--append-system-prompt", M.config.formatRule,
    "--allowedTools", "Read",
    "--add-dir", M.config.cacheDir,
  }

  local function finish(code, stdout, stderr)
    if thinkingAlert then
      hs.alert.closeSpecific(thinkingAlert)
      thinkingAlert = nil
    end
    M.busy = false
    currentShotPath = nil
    if code ~= 0 then
      hs.alert.show("at-at failed: " .. ((stderr ~= "" and stderr) or stdout):sub(1, 160))
      return
    end
    stdout = stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if stdout == "" then
      hs.alert.show("at-at: empty response")
      return
    end
    savedClipboard = hs.pasteboard.getContents()
    hs.pasteboard.setContents(stdout)
    hs.timer.doAfter(M.config.pasteDelayMs / 1000, function()
      local app = savedBundleID and hs.application.get(savedBundleID) or nil
      if app then
        app:activate()
      end
      hs.timer.doAfter(0.2, function()
        hs.eventtap.keyStroke({ "cmd" }, "v")
        hs.timer.doAfter(M.config.restoreDelayMs / 1000, function()
          if savedClipboard then
            hs.pasteboard.setContents(savedClipboard)
            savedClipboard = nil
          end
        end)
      end)
    end)
  end

  local task = hs.task.new(M.claudePath, finish, args)
  task:setWorkingDirectory(M.config.cacheDir)
  task:start()
end

keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if not M.enabled then
    return false
  end

  if M.panelOpen then
    local flags = e:getFlags()
    local chars = e:getCharacters() or ""
    local code = e:getKeyCode()

    if flags.cmd or flags.ctrl then
      M.cancelPrompt()
      return false
    end
    if code == hs.keycodes.map.escape then
      M.cancelPrompt()
      return true
    end
    if code == hs.keycodes.map.tab then
      cycleModel(flags.shift and -1 or 1)
      return true
    end
    if code == hs.keycodes.map["return"] or code == hs.keycodes.map.padenter then
      local q = draft
      closePanel()
      local ok, err = pcall(M.runQuery, q)
      if not ok then
        M.logError("runQuery", err)
      end
      return true
    end
    if code == hs.keycodes.map.delete then
      draft = draft:sub(1, -2)
      updateUI()
      return true
    end
    if flags.alt then
      return true
    end
    if #chars > 0 then
      draft = draft .. chars
      updateUI()
      return true
    end
    return true
  end

  local flags = e:getFlags()
  if flags.cmd or flags.ctrl then
    flushPending()
    return false
  end
  if M.busy then
    flushPending()
    return false
  end
  local chars = e:getCharacters()
  if not chars or #chars ~= 1 then
    if chars == "" then
      flushPending()
    end
    return false
  end
  if chars == "@" then
    if pendingAt then
      pendingAt = nil
      if pendingTimer then
        pendingTimer:stop()
        pendingTimer = nil
      end
      savedBundleID = hs.application.frontmostApplication():bundleID()
      local ok, err = pcall(showPanel)
      if not ok then
        M.logError("showPanel", err)
      end
      return true
    end
    pendingAt = e
    pendingTimer = hs.timer.doAfter(0.15, flushPending)
    return true
  end
  flushPending()
  return false
end)

mouseTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
  if M.panelOpen then
    flushPending()
    M.cancelPrompt()
    return true
  end
  return false
end)

appWatcher = hs.application.watcher.new(function(_, event)
  if event == hs.application.watcher.activated then
    flushPending()
  end
end)

hs.hotkey.bind(M.config.toggleMods, M.config.toggleKey, function()
  M.enabled = not M.enabled
  if M.enabled then
    keyTap:start()
  else
    keyTap:stop()
  end
  hs.alert.show("at-at: " .. (M.enabled and "on" or "off"))
end)

keyTap:start()
mouseTap:start()
appWatcher:start()

return M
