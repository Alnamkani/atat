local M = {}

M.enabled = true
M.busy = false
M.panelOpen = false

M.config = {
  models = {
    { label = "haiku", value = "haiku" },
    { label = "sonnet", value = "sonnet" },
    { label = "opus", value = "opus" },
  },
  defaultModel = "sonnet",
  cacheDir = os.getenv("HOME") .. "/.cache/atat",
  toggleMods = { "alt", "shift" },
  toggleKey = "a",
  pasteDelayMs = 250,
  restoreDelayMs = 350,
  formatRule = "Return ONLY the text to insert. No preamble, no explanation, no markdown fences.",
}

local REPOST_MARK = 0xA7A7

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
    local ev = pendingAt
    pendingAt = nil
    ev:setProperty(hs.eventtap.event.properties.eventSourceUserData, REPOST_MARK)
    ev:post()
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
local currentTask = nil
local queryGen = 0

os.execute("/bin/mkdir -p '" .. M.config.cacheDir .. "'")
os.execute("/usr/bin/find '" .. M.config.cacheDir .. "' -name 'shot-*.png' -mtime +1 -delete 2>/dev/null")

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
  for i, m in ipairs(M.config.models) do
    if m.value == M.config.defaultModel then
      modelIdx = i
      return m.value
    end
  end
  modelIdx = 1
  return M.config.models[1].value
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

local function utf8Backspace(s)
  if #s == 0 then
    return s
  end
  local i = #s
  while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do
    i = i - 1
  end
  return s:sub(1, i - 1)
end

local PANEL_W = 640
local PANEL_PAD_X = 30
local PANEL_PAD_TOP = 22
local PANEL_PAD_BOTTOM = 34
local PANEL_MIN_H = 148
local PANEL_MAX_H = 380

local function panelHtml()
  local segs = {}
  for i, m in ipairs(M.config.models) do
    segs[#segs + 1] = string.format('<span id="seg%d">%s</span>', i, m.label)
  end
  return [[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { background: transparent; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    padding: ]] .. PANEL_PAD_TOP .. "px " .. PANEL_PAD_X .. "px " .. PANEL_PAD_BOTTOM .. [[px;
    -webkit-user-select: none;
    overflow: hidden;
  }
  #card {
    background: linear-gradient(180deg, rgba(42, 42, 48, 0.97), rgba(26, 26, 30, 0.97));
    border: 1px solid rgba(255, 255, 255, 0.10);
    border-radius: 16px;
    box-shadow: 0 0 0 0.5px rgba(0, 0, 0, 0.65),
                0 18px 50px rgba(0, 0, 0, 0.55),
                inset 0 1px 0 rgba(255, 255, 255, 0.06);
    padding: 15px 18px 11px;
    color: #ececf0;
    animation: pop 0.18s cubic-bezier(0.2, 0.9, 0.3, 1.15);
  }
  @keyframes pop { from { opacity: 0; transform: translateY(6px) scale(0.985); } }
  .top { display: flex; gap: 12px; align-items: flex-start; }
  .sigil {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 17px; font-weight: 700; letter-spacing: -0.5px;
    color: #d97757; padding-top: 2px;
  }
  #card.thinking .sigil { animation: pulse 1.1s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity: 0.3; } }
  .line {
    flex: 1; font-size: 16px; line-height: 1.45; min-height: 47px;
    white-space: pre-wrap; word-break: break-word;
  }
  .line.empty { color: #75757e; }
  #card.thinking .line { color: #8b8b93; }
  .cursor {
    display: inline-block; width: 2px; height: 1.1em; margin-left: 1px;
    background: #d97757; vertical-align: -0.15em;
    animation: blink 1.1s steps(1) infinite;
  }
  @keyframes blink { 50% { opacity: 0; } }
  #card.thinking .cursor { animation: pulse 1.1s ease-in-out infinite; }
  .row {
    display: flex; align-items: center; gap: 10px;
    margin-top: 10px; padding-top: 10px;
    border-top: 1px solid rgba(255, 255, 255, 0.07);
  }
  .chip {
    display: inline-flex; align-items: center; gap: 6px;
    font-size: 11px; color: #8b8b93;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 7px; padding: 3px 9px;
  }
  .chip .dot { width: 6px; height: 6px; border-radius: 50%; background: #565660; }
  .chip.ok { color: #c8cbc8; }
  .chip.ok .dot { background: #7ec97e; box-shadow: 0 0 6px rgba(126, 201, 126, 0.7); }
  .seg {
    display: flex; gap: 1px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: 7px; padding: 2px;
  }
  .seg span {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px; padding: 2px 9px; border-radius: 5px; color: #8b8b93;
  }
  .seg span.on { background: #d97757; color: #1b1b1e; font-weight: 600; }
  .spacer { flex: 1; }
  .hint { font-size: 11px; color: #68686f; }
  .hint b { font-weight: 500; color: #8b8b93; }
  @media (prefers-reduced-motion: reduce) {
    #card, .cursor, #card.thinking .sigil { animation: none; }
  }
</style>
</head>
<body>
  <div id="card">
    <div class="top">
      <span class="sigil">@@</span>
      <div id="txt" class="line empty"></div>
    </div>
    <div class="row">
      <span id="shot" class="chip"><span class="dot"></span><span id="shotlbl">no screenshot</span></span>
      <div class="seg">]] .. table.concat(segs) .. [[</div>
      <span class="spacer"></span>
      <span id="hint" class="hint"></span>
    </div>
  </div>
<script>
  const card = document.getElementById('card');
  const txt = document.getElementById('txt');
  const hint = document.getElementById('hint');
  const PHRASE = "Ask about what you see\u2026";
  const IDLE_HINT = '<b>\u21e5</b> model \u00b7 <b>\u23ce</b> send \u00b7 <b>esc</b>';
  hint.innerHTML = IDLE_HINT;
  function upd(t) {
    if (t.length === 0) {
      txt.className = "line empty";
      txt.textContent = PHRASE;
    } else {
      txt.className = "line";
      txt.textContent = t;
    }
    const c = document.createElement("span");
    c.className = "cursor";
    txt.appendChild(c);
    return document.body.offsetHeight;
  }
  function shot(ok) {
    document.getElementById('shot').className = ok ? "chip ok" : "chip";
    document.getElementById('shotlbl').textContent = ok ? "screen attached" : "no screenshot";
  }
  function model(idx) {
    document.querySelectorAll('.seg span').forEach((el, i) => {
      el.className = (i === idx - 1) ? "on" : "";
    });
  }
  function think(on) {
    card.classList.toggle('thinking', on);
    hint.innerHTML = on ? 'thinking \u00b7 <b>esc</b> cancel' : IDLE_HINT;
  }
</script>
</body>
</html>]]
end

local function syncHeight()
  if not webView then
    return
  end
  webView:evaluateJavaScript("document.body.offsetHeight", function(h)
    if type(h) ~= "number" or not webView then
      return
    end
    local newH = math.min(PANEL_MAX_H, math.max(PANEL_MIN_H, math.floor(h)))
    local f = webView:frame()
    if math.abs(f.h - newH) > 2 then
      f.h = newH
      webView:frame(f)
    end
  end)
end

local function updateUI()
  if webView then
    local ok, err = pcall(function()
      webView:evaluateJavaScript("upd(" .. jsStr(draft) .. ")")
      syncHeight()
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
  if webView then
    pcall(function()
      webView:evaluateJavaScript("model(" .. modelIdx .. ")")
    end)
  end
end

local function caretBounds()
  local ok, bounds = pcall(function()
    local focused = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    if not focused then
      return nil
    end
    local range = focused:attributeValue("AXSelectedTextRange")
    if not range or not range.location then
      return nil
    end
    if range.length == 0 and range.location > 0 then
      range = { location = range.location - 1, length = 1 }
    end
    local b = focused:parameterizedAttributeValue("AXBoundsForRange", range)
    if b and b.x and b.h and b.h > 0 and not (b.x == 0 and b.y == 0) then
      return b
    end
    return nil
  end)
  if ok then
    return bounds
  end
  return nil
end

local function screenForPoint(p)
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:frame()
    if p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h then
      return s
    end
  end
  return hs.screen.mainScreen()
end

local function panelRect()
  local caret = caretBounds()
  if not caret then
    local frame = hs.screen.mainScreen():frame()
    return {
      x = frame.x + (frame.w - PANEL_W) / 2,
      y = math.min(frame.y + frame.h * 0.60, frame.y + frame.h - PANEL_MAX_H - 20),
      w = PANEL_W,
      h = PANEL_MIN_H,
    }
  end
  local frame = screenForPoint({ x = caret.x, y = caret.y }):frame()
  local x = caret.x - PANEL_PAD_X - 14
  x = math.max(frame.x - PANEL_PAD_X + 8, math.min(x, frame.x + frame.w - PANEL_W + PANEL_PAD_X - 8))
  local y = caret.y + caret.h + 8 - PANEL_PAD_TOP
  if y + PANEL_MAX_H > frame.y + frame.h then
    y = caret.y - PANEL_MIN_H - 8 + PANEL_PAD_BOTTOM
  end
  y = math.max(frame.y, y)
  return { x = x, y = y, w = PANEL_W, h = PANEL_MIN_H }
end

local function showPanel()
  selectedModel()
  draft = ""

  local shot = nil
  if M.screenshotEnabled ~= false then
    shot = captureScreenshot()
  end
  currentShotPath = shot

  local rect = panelRect()

  webView = hs.webview.new(rect)
  webView:windowStyle({ "borderless", "nonactivating" })
  webView:transparent(true)
  webView:shadow(false)
  webView:level(hs.drawing.windowLevels.floating)
  webView:behaviorAsLabels({ "canJoinAllSpaces", "transient" })
  webView:darkMode(true)
  webView:html(panelHtml())
  webView:show()

  hs.timer.doAfter(0.05, function()
    if webView then
      pcall(function()
        webView:evaluateJavaScript(
          "shot(" .. tostring(shot ~= nil) .. ");" ..
          "model(" .. modelIdx .. ");" ..
          "upd(\"\")")
        syncHeight()
      end)
    end
  end)

  M.panelOpen = true
end

function M.cancelPrompt()
  queryGen = queryGen + 1
  if currentTask then
    pcall(function() currentTask:terminate() end)
    currentTask = nil
  end
  M.busy = false
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
    M.cancelPrompt()
    return
  end
  if not M.claudePath then
    M.cancelPrompt()
    hs.alert.show("at-at: claude binary not found")
    return
  end

  M.busy = true
  queryGen = queryGen + 1
  local gen = queryGen
  local shotPath = currentShotPath

  if webView then
    pcall(function() webView:evaluateJavaScript("think(true)") end)
  end

  local fullPrompt = prompt
  if shotPath then
    fullPrompt = fullPrompt .. "\n\n[Context: a screenshot of the user's screen at trigger time is saved at "
      .. shotPath .. ". Read it with your Read tool if it helps answer.]"
  end

  local args = {
    "-p", fullPrompt,
    "--model", M.config.models[modelIdx].value,
    "--append-system-prompt", M.config.formatRule,
    "--allowedTools", "Read",
    "--add-dir", M.config.cacheDir,
  }

  local function finish(code, stdout, stderr)
    if shotPath then
      os.remove(shotPath)
    end
    if gen ~= queryGen then
      return
    end
    currentTask = nil
    M.busy = false
    currentShotPath = nil
    closePanel()
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

  currentTask = hs.task.new(M.claudePath, finish, args)
  currentTask:setWorkingDirectory(M.config.cacheDir)
  currentTask:start()
end

keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if not M.enabled then
    return false
  end
  if e:getProperty(hs.eventtap.event.properties.eventSourceUserData) == REPOST_MARK then
    return false
  end

  if M.panelOpen then
    local flags = e:getFlags()
    local chars = e:getCharacters() or ""
    local code = e:getKeyCode()

    if code == hs.keycodes.map.escape then
      M.cancelPrompt()
      return true
    end
    if M.busy then
      return false
    end
    if code == hs.keycodes.map["return"] or code == hs.keycodes.map.padenter then
      local ok, err = pcall(M.runQuery, draft)
      if not ok then
        M.logError("runQuery", err)
        M.cancelPrompt()
      end
      return true
    end
    if flags.cmd or flags.ctrl then
      M.cancelPrompt()
      return false
    end
    if code == hs.keycodes.map.tab then
      cycleModel(flags.shift and -1 or 1)
      return true
    end
    if code == hs.keycodes.map.delete then
      draft = utf8Backspace(draft)
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
    pendingAt = e:copy()
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
