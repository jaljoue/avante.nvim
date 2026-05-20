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
local lockfile_path = vim.fn.stdpath("data") .. "/avante/openai-timer.lock"

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

local function is_process_running(pid)
  local result = vim.uv.kill(pid, 0)
  if result ~= nil and result == 0 then
    return true
  else
    return false
  end
end

local function try_acquire_timer_lock()
  local lockfile = Path:new(lockfile_path)
  local tmp_lockfile = lockfile_path .. ".tmp." .. vim.fn.getpid()

  Path:new(tmp_lockfile):write(tostring(vim.fn.getpid()), "w")

  if lockfile:exists() then
    local content = lockfile:read()
    local pid = tonumber(content)
    if pid and is_process_running(pid) then
      os.remove(tmp_lockfile)
      return false
    end
  end

  local success = os.rename(tmp_lockfile, lockfile_path)
  if not success then
    os.remove(tmp_lockfile)
    return false
  end

  return true
end

local function setup_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
  end

  local now = math.floor(os.time())
  local expires_at = M.state.openai_token and M.state.openai_token.expires_at or now
  local time_until_expiry = math.max(0, expires_at - now)
  local initial_interval = math.max(0, (time_until_expiry - 120) * 1000)
  local repeat_interval = 0

  M._refresh_timer = vim.uv.new_timer()
  M._refresh_timer:start(
    initial_interval,
    repeat_interval,
    vim.schedule_wrap(function()
      if M._is_setup then M.refresh_token(true, true) end
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
    30000,
    30000,
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
  require("avante.tokenizers").setup(provider.tokenizer_id or "gpt-4o")
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

---@param provider AvanteProviderFunctor
function M.setup(provider)
  if not M.state then M.state = { openai_token = nil } end

  local provider_conf = Providers[Config.provider]
  local auth_type = provider_conf.auth_type

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

  if token and not is_valid_token(token) then
    Utils.warn("OpenAI token data is corrupted or invalid, re-authenticating...", { title = "Avante" })
    AuthStore.update("openai", nil)
  end

  M.authenticate()
  setup_token_management(provider)
end

function M.authenticate()
  local verifier, verifier_err = pkce.generate_verifier()
  if not verifier then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE verifier: " .. (verifier_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local challenge, challenge_err = pkce.generate_challenge(verifier)
  if not challenge then
    vim.schedule(
      function()
        vim.notify("Failed to generate PKCE challenge: " .. (challenge_err or "Unknown error"), vim.log.levels.ERROR)
      end
    )
    return
  end

  local state, state_err = pkce.generate_verifier()
  if not state then
    vim.schedule(
      function() vim.notify("Failed to generate PKCE state: " .. (state_err or "Unknown error"), vim.log.levels.ERROR) end
    )
    return
  end

  local function build_auth_url(redirect_uri)
    return string.format(
      "%s?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&code_challenge=%s&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=%s&originator=avante",
      auth_endpoint,
      client_id,
      vim.uri_encode(redirect_uri),
      vim.uri_encode("openid profile email offline_access"),
      challenge,
      state
    )
  end

  local function parse_manual_code(input)
    if not input then return nil, "Authorization input is empty" end
    local value = vim.trim(input)
    if value == "" then return nil, "Authorization input is empty" end

    local code, input_state
    if value:match("^https?://") then
      code = value:match("[?&]code=([^&]+)")
      input_state = value:match("[?&]state=([^&]+)")
      if code then code = vim.uri_decode(code) end
      if input_state then input_state = vim.uri_decode(input_state) end
    elseif value:find("#", 1, true) then
      local splits = vim.split(value, "#")
      code = splits[1]
      input_state = splits[2]
    else
      code = value
    end

    if not code or code == "" then return nil, "Failed to parse authorization code" end
    if input_state and input_state ~= "" and input_state ~= state then
      return nil, "State mismatch - potential CSRF attack"
    end

    return code
  end

  local function exchange_code(code, redirect_uri)
    local tokens, err = request_tokens({
      grant_type = "authorization_code",
      code = code,
      redirect_uri = redirect_uri,
      client_id = client_id,
      code_verifier = verifier,
    })

    if not tokens then
      vim.schedule(function() vim.notify("Failed to exchange code: " .. tostring(err), vim.log.levels.ERROR) end)
      return
    end

    M.store_tokens(tokens)
    vim.schedule(function() vim.notify("✓ Authentication successful!", vim.log.levels.INFO) end)
    M._is_setup = true
  end

  local function prompt_manual_input(auth_url)
    local Input = require("avante.ui.input")
    local input_config = Config.input or {}
    local input = Input:new({
      provider = input_config.provider,
      title = "Enter Auth Code or Callback URL: ",
      default = "",
      conceal = false,
      provider_opts = input_config.provider_opts,
      on_submit = function(raw)
        local code, parse_err = parse_manual_code(raw)
        if not code then
          vim.schedule(function() vim.notify(parse_err, vim.log.levels.ERROR) end)
          return
        end
        exchange_code(code, "http://localhost:1455/auth/callback")
      end,
    })
    input:open()
    if auth_url then
      vim.schedule(
        function() vim.notify("Open the copied URL, then paste the callback URL or code here.", vim.log.levels.INFO) end
      )
    end
  end

  vim.schedule(function()
    OAuthUI.show_auth_url({
      provider_name = "OpenAI Codex",
      auth_url = build_auth_url("http://localhost:1455/auth/callback"),
      on_open = function(ctx)
        local server_info = OAuthServer.start()
        if not server_info then
          vim.notify("Failed to start OAuth server", vim.log.levels.ERROR)
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

        local browser_url = build_auth_url(server_info.redirect_uri)
        local ok, err = pcall(vim.ui.open, browser_url)
        if ok then
          vim.notify("Opened OpenAI login URL in browser", vim.log.levels.INFO)
          ctx.close()
        else
          OAuthServer.stop()
          vim.fn.setreg("+", browser_url)
          vim.notify(
            "Could not open browser (" .. tostring(err) .. "). URL copied to clipboard for manual flow.",
            vim.log.levels.WARN
          )
          ctx.close()
          prompt_manual_input(browser_url)
        end
      end,
      on_copy = function(ctx)
        ctx.close()
        prompt_manual_input(ctx.copy_url)
      end,
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
    expires_at = os.time() + (tokens.expires_in or 3600),
    account_id = account_id,
  }

  M.state.openai_token = json

  vim.schedule(function() AuthStore.update("openai", json) end)
end

---@param async boolean|nil
---@param force boolean|nil
---@return boolean|nil
function M.refresh_token(async, force)
  if not M.state or not M.state.openai_token then return false end
  async = async == nil and true or async
  force = force or false

  if
    not force
    and M.state.openai_token
    and M.state.openai_token.expires_at
    and M.state.openai_token.expires_at > math.floor(os.time())
  then
    return false
  end

  if not M.state.openai_token.refresh_token then return false end

  local body = {
    grant_type = "refresh_token",
    refresh_token = M.state.openai_token.refresh_token,
    client_id = client_id,
  }

  local function handle_response(response)
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
  else
    local response = curl.post(token_endpoint, curl_opts)
    return handle_response(response)
  end
end

function M.cleanup()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer:close()
    M._refresh_timer = nil

    local lockfile = Path:new(lockfile_path)
    if lockfile:exists() then
      local content = lockfile:read()
      local pid = tonumber(content)
      if pid and pid == vim.fn.getpid() then lockfile:rm() end
    end
  end

  if M._manager_check_timer then
    M._manager_check_timer:stop()
    M._manager_check_timer:close()
    M._manager_check_timer = nil
  end

  if M._file_watcher then M._file_watcher = nil end

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
      Utils.error("OpenAI Codex authentication required. Please login and try again.")
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
