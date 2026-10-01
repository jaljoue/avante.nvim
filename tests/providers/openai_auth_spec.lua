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

local function parse_query(url)
  local params = {}
  local query = url:match("%?(.*)$") or url
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("([^=]+)=?(.*)")
    params[vim.uri_decode(key)] = vim.uri_decode(value)
  end
  return params
end

local function create_mock_chatgpt_token_data()
  return {
    access_token = "chatgpt_access_token",
    refresh_token = "chatgpt_refresh_token",
    expires_at = os.time() + 1800,
    client_id = "oaiapp_existing",
    scopes = { "openid", "chatgpt.tokens.use.direct" },
  }
end

local chatgpt_scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

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
  local data_dir = vim.fn.tempname()
  local original_stdpath = vim.fn.stdpath

  busted.before_each(function()
    vim.fn.delete(data_dir, "rf")
    vim.fn.stdpath = function(what)
      if what == "data" then return data_dir end
      return original_stdpath(what)
    end
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
      select_method = function(opts)
        -- Simulate a session without an attached UI: the headless-marked
        -- method should be the one that runs.
        for _, method in ipairs(opts.methods or {}) do
          if method.headless then
            method.run({ provider_name = opts.provider_name, close = function() end })
            return true
          end
        end
        return false
      end,
    }
    package.loaded["avante.auth.pkce"] = {
      generate_verifier = function() return "test_verifier", nil end,
      generate_challenge = function(v) return "test_challenge", nil end,
      random_bytes = function(n) return string.rep("\171", n) end,
    }
    openai_auth = require("avante.auth.providers.openai")
    curl = require("plenary.curl")
  end)

  busted.after_each(function()
    vim.fn.stdpath = original_stdpath
    vim.fn.delete(data_dir, "rf")
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

  busted.it("returns API bearer headers in API mode", function()
    local headers = openai_auth.get_headers({ auth_type = "api", api_key_name = "OPENAI_API_KEY" }, {
      parse_api_key = function() return "api-key" end,
    })

    assert.equals("Bearer api-key", headers.Authorization)
  end)

  busted.it("returns Codex backend headers for device code tokens", function()
    openai_auth._is_setup = true
    openai_auth.state = { openai_token = create_mock_token_data(false) }

    local headers = openai_auth.get_headers({ auth_type = "chatgpt" }, {
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

  async.it("clears api key name in ChatGPT setup mode", function()
    local Providers = require("avante.providers")
    local Config = require("avante.config")
    Config.provider = "openai"
    Providers.openai = { auth_type = "chatgpt" }
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

  busted.describe("Sign in with ChatGPT", function()
    local callback
    local opened_url
    local posts
    local original_open
    local original_post
    local original_notify

    busted.before_each(function()
      callback = nil
      opened_url = nil
      posts = {}
      original_open = vim.ui.open
      original_post = curl.post
      original_notify = vim.notify
      vim.notify = function() end
      vim.ui.open = function(url) opened_url = url end
      curl.post = function(url, opts)
        table.insert(posts, { url = url, body = parse_query(opts.body) })
        return {
          status = 200,
          body = vim.json.encode({
            access_token = "chatgpt_access_token",
            refresh_token = "chatgpt_refresh_token",
            id_token = "id_token",
            expires_in = 3600,
            scope = chatgpt_scope,
          }),
        }
      end
      package.loaded["avante.auth.oauth_server"] = {
        start = function() return { redirect_uri = "http://127.0.0.1:1455/auth/callback" } end,
        wait_for_callback = function(state, on_success, on_error)
          callback = { state = state, on_success = on_success, on_error = on_error }
        end,
        stop = function() end,
      }
      package.loaded["avante.ui.oauth"] = {
        show_auth_url = function() end,
        select_method = function(opts)
          for _, method in ipairs(opts.methods) do
            if method.id == "browser" then method.run({ close = function() end }) end
          end
          return true
        end,
      }
      package.loaded["avante.auth.providers.openai"] = nil
      openai_auth = require("avante.auth.providers.openai")
      openai_auth.state = { openai_token = nil }
    end)

    busted.after_each(function()
      vim.ui.open = original_open
      curl.post = original_post
      vim.notify = original_notify
    end)

    async.it("registers a dynamic client for this installation", function()
      openai_auth.authenticate()
      async_util.util.sleep(100)

      local params = parse_query(opened_url)
      assert.is_true(opened_url:match("^https://auth.openai.com/api/accounts/authorize%?") ~= nil)
      assert.equals("dynamic_agent_client", params.client_id)
      assert.equals("Avante", params.agent_name_hint)
      assert.equals("urn:uuid:abababab-abab-4bab-abab-abababababab", params.ext_agent_host_id)
      assert.equals("http://127.0.0.1:1455/auth/callback", params.redirect_uri)
      assert.equals("https://api.openai.com/v1", params.resource)
      assert.equals(chatgpt_scope, params.scope)
      assert.equals("test_challenge", params.code_challenge)
      assert.equals("S256", params.code_challenge_method)
      assert.equals(callback.state, params.state)
      assert.is_not_nil(params.nonce)
      assert.is_nil(params.originator)
    end)

    async.it("reuses the stored device ID across logins", function()
      openai_auth.authenticate()
      async_util.util.sleep(100)
      local first = parse_query(opened_url).ext_agent_host_id

      package.loaded["avante.auth.pkce"].random_bytes = function(n) return string.rep("\1", n) end
      openai_auth.authenticate()
      async_util.util.sleep(100)

      assert.equals(first, parse_query(opened_url).ext_agent_host_id)
    end)

    async.it("exchanges the code with the issued client ID and stores it", function()
      openai_auth.authenticate()
      async_util.util.sleep(100)
      callback.on_success("authorization-code", { code = "authorization-code", client_id = "oaiapp_issued" })
      async_util.util.sleep(100)

      assert.equals(1, #posts)
      assert.equals("https://auth.openai.com/api/accounts/oauth/token", posts[1].url)
      assert.equals("authorization_code", posts[1].body.grant_type)
      assert.equals("oaiapp_issued", posts[1].body.client_id)
      assert.equals("authorization-code", posts[1].body.code)
      assert.equals("test_verifier", posts[1].body.code_verifier)
      assert.equals("http://127.0.0.1:1455/auth/callback", posts[1].body.redirect_uri)
      assert.equals("https://api.openai.com/v1", posts[1].body.resource)

      local token = openai_auth.get_token()
      assert.equals("chatgpt_access_token", token.access_token)
      assert.equals("oaiapp_issued", token.client_id)
      assert.is_true(vim.tbl_contains(token.scopes, "chatgpt.tokens.use.direct"))
      assert.is_nil(token.account_id)
      assert.is_false(openai_auth.uses_codex_backend())
    end)

    async.it("rejects a callback without an issued client ID", function()
      openai_auth.authenticate()
      async_util.util.sleep(100)
      callback.on_success("authorization-code", { code = "authorization-code" })
      async_util.util.sleep(100)

      assert.equals(0, #posts)
      assert.is_nil(openai_auth.get_token())
    end)

    async.it("rejects a grant without direct token use", function()
      curl.post = function()
        return {
          status = 200,
          body = vim.json.encode({
            access_token = "a",
            refresh_token = "r",
            id_token = "i",
            expires_in = 3600,
            scope = "openid profile email offline_access",
          }),
        }
      end
      openai_auth.authenticate()
      async_util.util.sleep(100)
      callback.on_success("authorization-code", { client_id = "oaiapp_issued" })
      async_util.util.sleep(100)

      assert.is_nil(openai_auth.get_token())
    end)

    async.it("refreshes with the token's issued client ID", function()
      openai_auth.state = { openai_token = create_mock_chatgpt_token_data() }

      assert.is_true(openai_auth.refresh_token(false, true))
      async_util.util.sleep(100)

      assert.equals("https://auth.openai.com/api/accounts/oauth/token", posts[1].url)
      assert.equals("refresh_token", posts[1].body.grant_type)
      assert.equals("oaiapp_existing", posts[1].body.client_id)
      assert.equals("chatgpt_refresh_token", posts[1].body.refresh_token)
      assert.equals("https://api.openai.com/v1", posts[1].body.resource)
      assert.equals("oaiapp_existing", openai_auth.get_token().client_id)
    end)

    async.it("requires refresh responses to rotate the refresh token", function()
      openai_auth.state = { openai_token = create_mock_chatgpt_token_data() }
      curl.post = function()
        return {
          status = 200,
          body = vim.json.encode({ access_token = "a", expires_in = 3600, scope = chatgpt_scope }),
        }
      end

      assert.is_false(openai_auth.refresh_token(false, true))
      async_util.util.sleep(100)
      assert.equals("chatgpt_access_token", openai_auth.get_token().access_token)
    end)

    busted.it("sends only a bearer token to the OpenAI API", function()
      openai_auth._is_setup = true
      openai_auth.state = { openai_token = create_mock_chatgpt_token_data() }

      local headers = openai_auth.get_headers({ auth_type = "chatgpt" }, {})

      assert.equals("Bearer chatgpt_access_token", headers.Authorization)
      assert.is_nil(headers.originator)
      assert.is_nil(headers["ChatGPT-Account-Id"])
    end)
  end)

  busted.it("keeps device code tokens on the Codex backend", function()
    openai_auth.state = { openai_token = create_mock_token_data(false) }
    assert.is_true(openai_auth.uses_codex_backend())
  end)

  busted.it("treats only the chatgpt auth type as OAuth mode", function()
    assert.is_true(openai_auth.is_oauth({ auth_type = "chatgpt" }))
    assert.is_false(openai_auth.is_oauth({ auth_type = "codex" }))
  end)

  async.it("authenticates via device code in headless session", function()
    local run_device_code_called = false
    local show_auth_url_called = false

    package.loaded["avante.ui.oauth"] = {
      show_auth_url = function(opts)
        show_auth_url_called = true
        return true
      end,
      select_method = function(opts)
        for _, method in ipairs(opts.methods or {}) do
          if method.headless then
            method.run({ provider_name = opts.provider_name, close = function() end })
            return true
          end
        end
        return false
      end,
    }

    openai_auth.authenticate()
    async_util.util.sleep(100)

    assert.is_true(show_auth_url_called)
  end)

  busted.it("includes device_code auth method", function()
    local methods_table = {}
    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice) end_choice(nil) end

    local mock_oauth = {
      show_auth_url = function() end,
      select_method = function(opts)
        methods_table = opts.methods or {}
        return true
      end,
    }
    package.loaded["avante.ui.oauth"] = mock_oauth
    package.loaded["avante.auth.providers.openai"] = nil
    openai_auth = require("avante.auth.providers.openai")

    openai_auth.authenticate()

    vim.ui.select = original_select

    local found_device_code = false
    for _, method in ipairs(methods_table) do
      if method.id == "device_code" and method.headless then
        found_device_code = true
        break
      end
    end
    assert.is_true(found_device_code)
  end)
end)
