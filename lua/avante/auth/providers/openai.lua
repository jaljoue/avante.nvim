local Utils = require("avante.utils")
local Config = require("avante.config")
local Providers = require("avante.providers")
local Path = require("plenary.path")
local pkce = require("avante.auth.pkce")
local AuthStore = require("avante.auth.store")
local OAuthServer = require("avante.auth.oauth_server")
local OAuthUI = require("avante.ui.oauth")
local curl = require("plenary.curl")

---@class OpenAIAuthToken
---@field access_token string
---@field refresh_token string
---@field expires_at integer
---@field account_id string|nil

---@class AvanteAuthProvider
local M = {}

local auth_issuer = "https://auth.openai.com"
local auth_endpoint = auth_issuer .. "/oauth/authorize"
local token_endpoint = auth_issuer .. "/oauth/token"
local client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
local device_usercode_endpoint = auth_issuer .. "/api/accounts/deviceauth/usercode"
local device_token_endpoint = auth_issuer .. "/api/accounts/deviceauth/token"
local lockfile_path = vim.fn.stdpath("data") .. "/avante/openai-timer.lock"
local refresh_skew_sec = 120
local refresh_check_interval_ms = 60000
local manager_check_interval_ms = 30000
local default_expires_in_sec = 3600

---@private
---@class AvanteOpenAIState
---@field openai_token OpenAIAuthToken?
M.state = {
  openai_token = nil,
}

M.api_key_name = "OPENAI_API_KEY"
M._is_setup = false
M._refresh_timer = nil
M._manager_check_timer = nil
M._file_watcher = nil
M._refresh_in_flight = false
M._provider = nil

local function is_valid_token(token)
  return token ~= nil
    and type(token.access_token) == "string"
    and type(token.refresh_token) == "string"
    and type(token.expires_at) == "number"
    and token.access_token ~= ""
    and token.refresh_token ~= ""
end

local function base64url_decode(data)
  if not data or data == "" then return nil end
  local padded = data:gsub("-", "+"):gsub("_", "/")
  local pad = #padded % 4
  if pad == 2 then
    padded = padded .. "=="
  elseif pad == 3 then
    padded = padded .. "="
  elseif pad ~= 0 then
    return nil
  end
  local ok, decoded = pcall(vim.base64.decode, padded)
  if not ok then return nil end
  return decoded
end

local function parse_jwt_claims(token)
  local parts = vim.split(token, ".", { plain = true })
  if #parts ~= 3 then return nil end
  local decoded = base64url_decode(parts[2])
  if not decoded then return nil end
  local ok, claims = pcall(vim.json.decode, decoded)
  if ok and type(claims) == "table" then return claims end
  return nil
end

local function extract_account_id_from_claims(claims)
  if type(claims) ~= "table" then return nil end
  if claims.chatgpt_account_id then return claims.chatgpt_account_id end
  local auth_claims = claims["https://api.openai.com/auth"]
  if auth_claims and auth_claims.chatgpt_account_id then return auth_claims.chatgpt_account_id end
  if type(claims.organizations) == "table" and claims.organizations[1] and claims.organizations[1].id then
    return claims.organizations[1].id
  end
  return nil
end

local function extract_account_id(tokens)
  if tokens.id_token then
    local claims = parse_jwt_claims(tokens.id_token)
    local account_id = extract_account_id_from_claims(claims)
    if account_id then return account_id end
  end

  if tokens.access_token then
    local claims = parse_jwt_claims(tokens.access_token)
    return extract_account_id_from_claims(claims)
  end

  return nil
end

local function is_process_running(pid) return vim.uv.kill(pid, 0) == 0 end

local function read_lock_pid()
  local ok, content = pcall(function() return Path:new(lockfile_path):read() end)
  if not ok then return nil end
  return tonumber(content)
end

local function try_acquire_timer_lock()
  local existing_pid = read_lock_pid()
  if existing_pid == vim.fn.getpid() then return true end
  if existing_pid and is_process_running(existing_pid) then return false end

  local parent = Path:new(lockfile_path):parent()
  if not parent:exists() then parent:mkdir({ parents = true }) end

  local tmp_lockfile = lockfile_path .. ".tmp." .. vim.fn.getpid()
  Path:new(tmp_lockfile):write(tostring(vim.fn.getpid()), "w")

  if not os.rename(tmp_lockfile, lockfile_path) then
    os.remove(tmp_lockfile)
    return false
  end

  -- os.rename is atomic, but two processes can both rename after the stale
  -- check; only the one whose pid ended up in the lockfile owns it.
  return read_lock_pid() == vim.fn.getpid()
end

-- Repeats and checks expiry each tick instead of firing once, so the timer
-- re-arms itself after every refresh without depending on the manager check.
local function setup_timer()
  if M._refresh_timer then return end

  M._refresh_timer = vim.uv.new_timer()
  if not M._refresh_timer then return end

  M._refresh_timer:start(
    refresh_check_interval_ms,
    refresh_check_interval_ms,
    vim.schedule_wrap(function()
      if not M._is_setup or not M.state.openai_token then return end
      local expires_at = M.state.openai_token.expires_at
      if not expires_at or expires_at - math.floor(os.time()) > refresh_skew_sec then return end
      M.refresh_token(true, true)
    end)
  )
end

local function start_manager_check_timer()
  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
  end

  M._manager_check_timer = vim.uv.new_timer()
  M._manager_check_timer:start(
    manager_check_interval_ms,
    manager_check_interval_ms,
    vim.schedule_wrap(function()
      if not M._refresh_timer and try_acquire_timer_lock() then setup_timer() end
    end)
  )
end

local function setup_file_watcher()
  if M._file_watcher then return end

  AuthStore.watch(function(data)
    if data and data.openai then
      M.state.openai_token = data.openai
    else
      M.state.openai_token = nil
    end
  end)

  M._file_watcher = true
end

local function setup_token_management(provider)
  local timer_lock_acquired = try_acquire_timer_lock()
  if timer_lock_acquired then
    setup_timer()
  else
    vim.schedule(function()
      if M._is_setup then M.refresh_token(true, false) end
    end)
  end

  setup_file_watcher()
  start_manager_check_timer()
  require("avante.tokenizers").setup((provider and provider.tokenizer_id) or "gpt-4o")
  vim.g.avante_login = true
end

local function encode_form(params)
  local parts = {}
  for key, value in pairs(params) do
    table.insert(parts, string.format("%s=%s", vim.uri_encode(key), vim.uri_encode(tostring(value))))
  end
  return table.concat(parts, "&")
end

local function request_tokens(body)
  local response = curl.post(token_endpoint, {
    body = encode_form(body),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
  })

  if response.status >= 400 then return nil, string.format("HTTP %d: %s", response.status, response.body) end

  local ok, tokens = pcall(vim.json.decode, response.body)
  if not ok then return nil, "Failed to decode token response" end

  return tokens
end

local function generate_pkce()
  local verifier, verifier_err = pkce.generate_verifier()
  if not verifier then return nil, "Failed to generate PKCE verifier: " .. (verifier_err or "Unknown error") end

  local challenge, challenge_err = pkce.generate_challenge(verifier)
  if not challenge then return nil, "Failed to generate PKCE challenge: " .. (challenge_err or "Unknown error") end

  return { verifier = verifier, challenge = challenge }, nil
end

local function request_device_code()
  local response = curl.post(device_usercode_endpoint, {
    body = string.format('{"client_id":"%s"}', client_id),
    headers = { ["Content-Type"] = "application/json" },
  })

  if response.status >= 400 then return nil, "HTTP " .. response.status end

  local ok, data = pcall(vim.json.decode, response.body)
  if not ok then return nil, "Failed to decode response" end

  return {
    device_auth_id = data.device_auth_id,
    user_code = data.user_code,
    verification_uri = auth_issuer .. "/codex/device",
    interval = data.interval or 5,
  }
end

local function poll_for_token(device_auth_id, user_code, interval, expires_in, on_success, on_error)
  local timer = vim.uv.new_timer()
  if not timer then on_error("Failed to create timer") return end

  local start_time = os.time()

  timer:start(interval * 1000, interval * 1000, vim.schedule_wrap(function()
    if os.time() - start_time >= expires_in then
      timer:stop()
      timer:close()
      on_error("Device code expired")
      return
    end

    local response = curl.post(device_token_endpoint, {
      body = string.format('{"device_auth_id":"%s","user_code":"%s"}', device_auth_id, user_code),
      headers = { ["Content-Type"] = "application/json" },
    })

    if response.status >= 400 then
      if response.body:match("authorization_pending") then return end
      timer:stop()
      timer:close()
      on_error("Authentication failed")
      return
    end

    timer:stop()
    timer:close()

    local ok, tokens = pcall(vim.json.decode, response.body)
    if ok then
      on_success(tokens)
    else
      on_error("Failed to parse tokens")
    end
  end))

  return function()
    timer:stop()
    timer:close()
  end
end

---@param provider AvanteProviderFunctor
function M.setup(provider)
  -- Inherited providers (e.g. openrouter via __inherited_from = "openai") reuse
  -- the openai functor's setup; OpenAI auth only applies when openai is selected.
  if Config.provider ~= "openai" then return end

  if not M.state then M.state = { openai_token = nil } end

  local provider_conf = Providers[Config.provider]
  local auth_type = provider_conf and provider_conf.auth_type

  if auth_type == "codex" then
    M.api_key_name = ""
    provider.api_key_name = ""
  else
    M.api_key_name = "OPENAI_API_KEY"
    provider.api_key_name = "OPENAI_API_KEY"
    require("avante.tokenizers").setup(provider.tokenizer_id or "gpt-4o")
    vim.g.avante_login = true
    M._is_setup = true
    return
  end

  local data = AuthStore.read()
  local token = data and data.openai
  if token and is_valid_token(token) then
    M.state.openai_token = token
    setup_token_management(provider)
    M._is_setup = true
    return
  end

  -- No auth flow starts on launch; the user logs in explicitly via :AvanteLogin.
  M._provider = provider

  if token then
    Utils.warn(
      "OpenAI token data is corrupted or invalid. Run :AvanteLogin to re-authenticate.",
      { once = true, title = "Avante" }
    )
    AuthStore.update("openai", nil)
    return
  end

  Utils.info("OpenAI Codex login required. Run :AvanteLogin to authenticate.", { once = true, title = "Avante" })
end

function M.authenticate()
  local pair, pair_err = generate_pkce()
  if not pair then
    vim.schedule(function() vim.notify(pair_err, vim.log.levels.ERROR) end)
    return
  end

  local state, state_err = pkce.generate_verifier()
  if not state then
    vim.schedule(
      function() vim.notify("Failed to generate PKCE state: " .. (state_err or "Unknown error"), vim.log.levels.ERROR) end
    )
    return
  end

  local function build_auth_url(auth_redirect_uri)
    return string.format(
      "%s?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&code_challenge=%s&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=%s&originator=avante",
      auth_endpoint,
      client_id,
      vim.uri_encode(auth_redirect_uri),
      vim.uri_encode("openid profile email offline_access"),
      pair.challenge,
      state
    )
  end

  local function exchange_code(code, exchange_redirect_uri)
    local tokens, err = request_tokens({
      grant_type = "authorization_code",
      code = code,
      redirect_uri = exchange_redirect_uri,
      client_id = client_id,
      code_verifier = pair.verifier,
    })

    if not tokens then
      vim.schedule(function() vim.notify("Failed to exchange code: " .. tostring(err), vim.log.levels.ERROR) end)
      return
    end

    M.store_tokens(tokens)
    M._is_setup = true
    setup_token_management(M._provider)
    vim.schedule(function() vim.notify("✓ Authentication successful!", vim.log.levels.INFO) end)
  end

  local function run_device_code(close)
    OAuthServer.stop()

    local device_code, err = request_device_code()
    if not device_code then
      vim.schedule(function() vim.notify("Failed to request device code: " .. tostring(err), vim.log.levels.ERROR) end)
      if close then close() end
      return
    end

    local function on_success(code_resp)
      -- The device poll endpoint returns an authorization code plus a
      -- server-generated PKCE pair, which must be exchanged at the regular
      -- token endpoint using the device callback redirect URI.
      local redirect_uri = auth_issuer .. "/deviceauth/callback"
      local tokens, exchange_err = request_tokens({
        grant_type = "authorization_code",
        code = code_resp.authorization_code,
        redirect_uri = redirect_uri,
        client_id = client_id,
        code_verifier = code_resp.code_verifier,
      })

      if not tokens then
        vim.schedule(
          function() vim.notify("Failed to exchange device code: " .. tostring(exchange_err), vim.log.levels.ERROR) end
        )
        return
      end

      M.store_tokens(tokens)
      M._is_setup = true
      setup_token_management(M._provider)
      vim.schedule(function()
        vim.notify("✓ Authentication successful!", vim.log.levels.INFO)
      end)
    end

    local function on_error(error_msg)
      vim.schedule(function()
        vim.notify("Authentication failed: " .. tostring(error_msg), vim.log.levels.ERROR)
      end)
    end

    local cancel_poll = poll_for_token(device_code.device_auth_id, device_code.user_code, device_code.interval, 900, on_success, on_error)

    OAuthUI.show_auth_url({
      provider_name = "OpenAI Codex",
      auth_url = device_code.verification_uri,
      user_code = device_code.user_code,
      disable_open = true,
      keep_open = true,
      on_close = function()
        cancel_poll()
        if close then close() end
      end,
    })
  end

  local function run_browser(close)
    local server_info = OAuthServer.start()
    if not server_info then
      vim.notify("Failed to start OAuth callback server, falling back to device code auth", vim.log.levels.WARN)
      run_device_code(close)
      return
    end

    OAuthServer.wait_for_callback(state, function(code)
      exchange_code(code, server_info.redirect_uri)
      OAuthServer.stop()
    end, function(error_msg)
      OAuthServer.stop()
      vim.schedule(
        function() vim.notify("Authentication failed: " .. tostring(error_msg), vim.log.levels.ERROR) end
      )
    end)

    local auth_url = build_auth_url(server_info.redirect_uri)
    local ok, err = pcall(vim.ui.open, auth_url)
    if ok then
      vim.notify("Opened OpenAI login URL in browser", vim.log.levels.INFO)
    else
      OAuthServer.stop()
      vim.notify(
        "Could not open browser (" .. tostring(err) .. "). Falling back to device code auth.",
        vim.log.levels.WARN
      )
      run_device_code(close)
    end
  end

  vim.schedule(function()
    OAuthUI.select_method({
      provider_name = "OpenAI Codex",
      methods = {
        {
          id = "browser",
          label = "OpenAI (browser)",
          run = function(ctx) run_browser(ctx.close) end,
        },
        {
          id = "device_code",
          label = "OpenAI (remote)",
          headless = true,
          run = function(ctx) run_device_code(ctx.close) end,
        },
      },
    })
  end)
end

---@param tokens table
function M.store_tokens(tokens)
  if not M.state then M.state = { openai_token = nil } end

  local account_id = extract_account_id(tokens)
  local refresh_token = tokens.refresh_token or (M.state.openai_token and M.state.openai_token.refresh_token)
  local json = {
    access_token = tokens.access_token,
    refresh_token = refresh_token,
    expires_at = os.time() + (tokens.expires_in or default_expires_in_sec),
    account_id = account_id,
  }

  M.state.openai_token = json

  vim.schedule(function() AuthStore.update("openai", json) end)
end

---@param async boolean|nil
---@param force boolean|nil
---@return boolean
function M.refresh_token(async, force)
  if not M.state or not M.state.openai_token then return false end
  async = async == nil and true or async
  force = force or false

  local token = M.state.openai_token
  if not force and token.expires_at and token.expires_at - math.floor(os.time()) > refresh_skew_sec then
    return false
  end

  if not token.refresh_token then return false end
  if M._refresh_in_flight then return false end
  M._refresh_in_flight = true

  local body = {
    grant_type = "refresh_token",
    refresh_token = token.refresh_token,
    client_id = client_id,
  }

  local function handle_response(response)
    M._refresh_in_flight = false

    if response.status >= 400 then
      vim.schedule(
        function()
          vim.notify(
            string.format("[%s]Failed to refresh access token: %s", response.status, response.body),
            vim.log.levels.ERROR
          )
        end
      )
      return false
    end

    local ok, tokens = pcall(vim.json.decode, response.body)
    if ok then
      M.store_tokens(tokens)
      return true
    end

    return false
  end

  local curl_opts = {
    body = encode_form(body),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
  }

  if async then
    curl.post(
      token_endpoint,
      vim.tbl_deep_extend("force", {
        callback = handle_response,
      }, curl_opts)
    )
    return true
  end

  return handle_response(curl.post(token_endpoint, curl_opts))
end

function M.cleanup()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil
  end

  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
    M._manager_check_timer = nil
  end

  M._file_watcher = nil

  local pid = read_lock_pid()
  if pid and pid == vim.fn.getpid() then
    pcall(function() Path:new(lockfile_path):rm() end)
  end

  OAuthServer.stop()
end

function M.get_token() return M.state and M.state.openai_token or nil end

---@param provider_conf table
---@return boolean
function M.is_oauth(provider_conf) return provider_conf.auth_type == "codex" end

---@param provider_conf table
---@param provider AvanteProviderFunctor
---@return table<string,string>|nil
function M.get_headers(provider_conf, provider)
  if M.is_oauth(provider_conf) then
    if not M._is_setup then M.setup(provider) end
    if not M.state or not M.state.openai_token then
      Utils.error("OpenAI Codex authentication required. Run :AvanteLogin to login, then try again.")
      return nil
    end

    M.refresh_token(false, false)
    local token = M.state.openai_token
    if not token or not token.access_token then
      Utils.error("OpenAI Codex access token unavailable. Please re-authenticate.")
      return nil
    end

    local headers = {
      ["Authorization"] = "Bearer " .. token.access_token,
      ["User-Agent"] = Utils.get_user_agent_string(),
      originator = "avante_nvim",
    }
    if token.account_id and token.account_id ~= "" then headers["ChatGPT-Account-Id"] = token.account_id end
    return headers
  end

  if Providers.env.require_api_key(provider_conf) then
    local api_key = provider.parse_api_key()
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return nil
    end
    return {
      ["Authorization"] = "Bearer " .. api_key,
    }
  end

  return {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() M.cleanup() end,
})

return M
