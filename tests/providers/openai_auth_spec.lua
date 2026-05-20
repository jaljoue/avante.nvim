---@diagnostic disable: duplicate-set-field
local busted = require("plenary.busted")
local async = require("plenary.async.tests")
local async_util = require("plenary.async")

local function create_mock_token_data(expired)
  local now = os.time()
  return {
    access_token = "mock_access_token_123",
    refresh_token = "mock_refresh_token_456",
    expires_at = expired and (now - 3600) or (now + 1800),
    account_id = "acct_123",
  }
end

local function create_mock_token_response()
  return {
    access_token = "mock_access_token_abcdef123456",
    refresh_token = "mock_refresh_token_xyz789",
    expires_in = 1800,
    token_type = "Bearer",
  }
end

local function base64url(data)
  return vim.base64.encode(data):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function jwt_with_claims(claims)
  return table.concat({
    base64url(vim.json.encode({ alg = "none" })),
    base64url(vim.json.encode(claims)),
    "sig",
  }, ".")
end

busted.describe("openai auth provider", function()
  local openai_auth
  local curl

  busted.before_each(function()
    package.loaded["avante.auth.providers.openai"] = nil
    package.loaded["plenary.curl"] = nil
    package.loaded["avante.auth.store"] = {
      update = function() end,
      read = function() return nil end,
      watch = function() end,
      path = function() return "" end,
    }
    package.loaded["avante.auth.oauth_server"] = {
      start = function() return { redirect_uri = "http://localhost:1455/auth/callback" } end,
      wait_for_callback = function() end,
      stop = function() end,
    }
    package.loaded["avante.ui.oauth"] = {
      show_auth_url = function() end,
    }
    openai_auth = require("avante.auth.providers.openai")
    curl = require("plenary.curl")
  end)

  async.it("stores tokens with account id from JWT claims", function()
    openai_auth.state = { openai_token = nil }
    local response = create_mock_token_response()
    response.access_token = jwt_with_claims({ chatgpt_account_id = "acct_from_claims" })

    openai_auth.store_tokens(response)
    async_util.util.sleep(100)

    assert.equals(response.access_token, openai_auth.state.openai_token.access_token)
    assert.equals(response.refresh_token, openai_auth.state.openai_token.refresh_token)
    assert.equals("acct_from_claims", openai_auth.state.openai_token.account_id)
    assert.is_number(openai_auth.state.openai_token.expires_at)
  end)

  async.it("preserves refresh token when refresh response omits it", function()
    openai_auth.state = { openai_token = create_mock_token_data(false) }

    openai_auth.store_tokens({
      access_token = "new_access_token",
      expires_in = 1800,
    })
    async_util.util.sleep(100)

    assert.equals("new_access_token", openai_auth.state.openai_token.access_token)
    assert.equals("mock_refresh_token_456", openai_auth.state.openai_token.refresh_token)
  end)

  busted.it("exits refresh early when no token exists", function()
    openai_auth.state = { openai_token = nil }
    assert.is_false(openai_auth.refresh_token(false, false))
  end)

  busted.it("skips refresh when token is not expired and not forced", function()
    openai_auth.state = { openai_token = create_mock_token_data(false) }
    assert.is_false(openai_auth.refresh_token(false, false))
  end)

  async.it("posts form encoded refresh request when forced", function()
    openai_auth.state = { openai_token = create_mock_token_data(false) }

    local captured_body
    local original_post = curl.post
    curl.post = function(_, opts)
      captured_body = opts.body
      return {
        status = 200,
        body = vim.json.encode(create_mock_token_response()),
      }
    end

    openai_auth.refresh_token(false, true)
    async_util.util.sleep(100)
    curl.post = original_post

    assert.is_true(captured_body:match("grant_type=refresh_token") ~= nil)
    assert.is_true(captured_body:match("refresh_token=mock_refresh_token_456") ~= nil)
  end)

  async.it("constructs OAuth URL with PKCE and codex parameters", function()
    local captured_url
    package.loaded["avante.ui.oauth"] = {
      show_auth_url = function(opts) captured_url = opts.auth_url end,
    }
    package.loaded["avante.auth.providers.openai"] = nil
    openai_auth = require("avante.auth.providers.openai")

    openai_auth.authenticate()
    async_util.util.sleep(100)

    assert.is_true(captured_url:match("^https://auth.openai.com/oauth/authorize") ~= nil)
    assert.is_true(captured_url:match("client_id=") ~= nil)
    assert.is_true(captured_url:match("response_type=code") ~= nil)
    assert.is_true(captured_url:match("redirect_uri=") ~= nil)
    assert.is_true(captured_url:match("scope=") ~= nil)
    assert.is_true(captured_url:match("code_challenge=") ~= nil)
    assert.is_true(captured_url:match("code_challenge_method=S256") ~= nil)
    assert.is_true(captured_url:match("state=") ~= nil)
    assert.is_true(captured_url:match("originator=avante") ~= nil)
  end)

  busted.it("returns API bearer headers in API mode", function()
    local headers = openai_auth.get_headers({ auth_type = "api", api_key_name = "OPENAI_API_KEY" }, {
      parse_api_key = function() return "api-key" end,
    })

    assert.equals("Bearer api-key", headers.Authorization)
  end)

  busted.it("returns Codex OAuth headers in codex mode", function()
    openai_auth._is_setup = true
    openai_auth.state = { openai_token = create_mock_token_data(false) }

    local headers = openai_auth.get_headers({ auth_type = "codex" }, {
      parse_api_key = function() return nil end,
    })

    assert.equals("Bearer mock_access_token_123", headers.Authorization)
    assert.equals("avante_nvim", headers.originator)
    assert.equals("acct_123", headers["ChatGPT-Account-Id"])
  end)

  busted.it("sets api key name in API setup mode", function()
    local Providers = require("avante.providers")
    local Config = require("avante.config")
    Config.provider = "openai"
    Providers.openai = { auth_type = "api" }
    package.loaded["avante.tokenizers"] = { setup = function() end }

    local provider = { tokenizer_id = "gpt-4o" }
    openai_auth.authenticate = function() end
    openai_auth.setup(provider)

    assert.equals("OPENAI_API_KEY", openai_auth.api_key_name)
    assert.equals("OPENAI_API_KEY", provider.api_key_name)
  end)

  async.it("clears api key name in Codex setup mode", function()
    local Providers = require("avante.providers")
    local Config = require("avante.config")
    Config.provider = "openai"
    Providers.openai = { auth_type = "codex" }
    package.loaded["avante.tokenizers"] = { setup = function() end }
    local original_notify = vim.notify
    vim.notify = function() end

    local provider = { tokenizer_id = "gpt-4o" }
    openai_auth.setup(provider)
    async_util.util.sleep(100)

    vim.notify = original_notify

    assert.equals("", openai_auth.api_key_name)
    assert.equals("", provider.api_key_name)
  end)

  busted.it("does not treat chatgpt auth type as OAuth mode", function()
    assert.is_false(openai_auth.is_oauth({ auth_type = "chatgpt" }))
  end)
end)
