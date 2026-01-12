local Utils = require("avante.utils")

local M = {}

local uv = vim.uv or vim.loop

local PORT = 1455
local server
local pending

local HTML_SUCCESS = [[<!doctype html>
<html>
  <head>
    <title>Avante - Authorization Successful</title>
    <style>
      body {
        font-family:
          system-ui,
          -apple-system,
          sans-serif;
        display: flex;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
        background: #131010;
        color: #f1ecec;
      }
      .container {
        text-align: center;
        padding: 2rem;
      }
      h1 {
        color: #f1ecec;
        margin-bottom: 1rem;
      }
      p {
        color: #b7b1b1;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>Authorization Successful</h1>
      <p>You can close this window and return to Avante.</p>
    </div>
    <script>
      setTimeout(() => window.close(), 2000)
    </script>
  </body>
</html>]]

local function html_error(error)
  return string.format(
    [[<!doctype html>
<html>
  <head>
    <title>Avante - Authorization Failed</title>
    <style>
      body {
        font-family:
          system-ui,
          -apple-system,
          sans-serif;
        display: flex;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
        background: #131010;
        color: #f1ecec;
      }
      .container {
        text-align: center;
        padding: 2rem;
      }
      h1 {
        color: #fc533a;
        margin-bottom: 1rem;
      }
      p {
        color: #b7b1b1;
      }
      .error {
        color: #ff917b;
        font-family: monospace;
        margin-top: 1rem;
        padding: 1rem;
        background: #3c140d;
        border-radius: 0.5rem;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>Authorization Failed</h1>
      <p>An error occurred during authorization.</p>
      <div class="error">%s</div>
    </div>
  </body>
</html>]],
    error
  )
end

local function parse_query(query)
  local params = {}
  if not query or query == "" then return params end
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("([^=]+)=?(.*)")
    if key then
      params[vim.uri_decode(key)] = vim.uri_decode(value or "")
    end
  end
  return params
end

local function respond(client, status, body)
  local reason = status == 200 and "OK" or "Bad Request"
  local response = table.concat({
    string.format("HTTP/1.1 %d %s", status, reason),
    "Content-Type: text/html",
    "Content-Length: " .. tostring(#body),
    "Connection: close",
    "",
    body,
  }, "\r\n")

  client:write(response, function()
    if client and not client:is_closing() then client:close() end
  end)
end

local function handle_request(client, request)
  local request_line = request:match("^([^\r\n]+)")
  if not request_line then
    respond(client, 400, html_error("Malformed request"))
    return
  end

  local method, target = request_line:match("^(%S+)%s+(%S+)")
  if method ~= "GET" or not target then
    respond(client, 400, html_error("Invalid request"))
    return
  end

  local path, query = target:match("^([^?]+)%??(.*)$")
  local params = parse_query(query)

  if path == "/auth/callback" then
    local code = params.code
    local state = params.state
    local err = params.error
    local err_description = params.error_description

    if err then
      local error_msg = err_description or err
      if pending and pending.on_error then vim.schedule(function() pending.on_error(error_msg) end) end
      pending = nil
      respond(client, 400, html_error(error_msg))
      return
    end

    if not code then
      local error_msg = "Missing authorization code"
      if pending and pending.on_error then vim.schedule(function() pending.on_error(error_msg) end) end
      pending = nil
      respond(client, 400, html_error(error_msg))
      return
    end

    if not pending or state ~= pending.state then
      local error_msg = "Invalid state - potential CSRF attack"
      if pending and pending.on_error then vim.schedule(function() pending.on_error(error_msg) end) end
      pending = nil
      respond(client, 400, html_error(error_msg))
      return
    end

    local on_success = pending.on_success
    pending = nil
    if on_success then vim.schedule(function() on_success(code) end) end

    respond(client, 200, HTML_SUCCESS)
    return
  end

  if path == "/cancel" then
    if pending and pending.on_error then vim.schedule(function() pending.on_error("Login cancelled") end) end
    pending = nil
    respond(client, 200, "Login cancelled")
    return
  end

  respond(client, 404, html_error("Not found"))
end

local function on_connection(err)
  if err then
    Utils.error("OAuth server error: " .. tostring(err), { once = true, title = "Avante" })
    return
  end

  if not server then return end

  local client = uv.new_tcp()
  if not client then return end
  server:accept(client)

  local buffer = ""
  client:read_start(function(read_err, chunk)
    if read_err then
      if client and not client:is_closing() then client:close() end
      return
    end

    if not chunk then
      if client and not client:is_closing() then client:close() end
      return
    end

    buffer = buffer .. chunk
    if buffer:find("\r\n\r\n", 1, true) then
      client:read_stop()
      handle_request(client, buffer)
    end
  end)
end

function M.start()
  if server then return { port = PORT, redirect_uri = "http://localhost:" .. PORT .. "/auth/callback" } end

  server = uv.new_tcp()
  if not server then return nil end
  server:bind("127.0.0.1", PORT)
  server:listen(128, on_connection)

  return { port = PORT, redirect_uri = "http://localhost:" .. PORT .. "/auth/callback" }
end

function M.stop()
  if server then
    server:close()
    server = nil
  end
  pending = nil
end

function M.wait_for_callback(state, on_success, on_error)
  if pending then
    if on_error then on_error("OAuth callback already pending") end
    return
  end

  local timeout = uv.new_timer()
  if not timeout then return end
  timeout:start(5 * 60 * 1000, 0, function()
    timeout:stop()
    timeout:close()
    if pending then
      local error_msg = "OAuth callback timeout - authorization took too long"
      if pending.on_error then vim.schedule(function() pending.on_error(error_msg) end) end
      pending = nil
    end
  end)

  pending = {
    state = state,
    on_success = function(code)
      if timeout then
        timeout:stop()
        timeout:close()
      end
      if on_success then on_success(code) end
    end,
    on_error = function(error_msg)
      if timeout then
        timeout:stop()
        timeout:close()
      end
      if on_error then on_error(error_msg) end
    end,
  }
end

return M
