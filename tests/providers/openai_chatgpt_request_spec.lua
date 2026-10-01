---@diagnostic disable: duplicate-set-field
local busted = require("plenary.busted")
local Config = require("avante.config")
Config.setup({})

busted.describe("openai provider with ChatGPT sign in", function()
  local openai
  local Providers
  local OpenAIAuth
  local original_parse_config
  local original_get_headers

  local function curl_args(token)
    OpenAIAuth.state = { openai_token = token }
    return openai:parse_curl_args({
      system_prompt = "system prompt",
      messages = { { role = "user", content = "hi" } },
    })
  end

  busted.before_each(function()
    Providers = require("avante.providers")
    OpenAIAuth = require("avante.auth.providers.openai")
    openai = require("avante.providers.openai")
    original_parse_config = Providers.parse_config
    original_get_headers = OpenAIAuth.get_headers
    Providers.parse_config = function()
      return {
        auth_type = "chatgpt",
        model = "gpt-5.5",
        endpoint = "https://example.com/v1",
        support_previous_response_id = true,
      }, {
        temperature = 0.75,
        max_completion_tokens = 16384,
        reasoning_effort = "medium",
        prompt_cache_retention = "24h",
      }
    end
    OpenAIAuth.get_headers = function() return { Authorization = "Bearer token" } end
  end)

  busted.after_each(function()
    Providers.parse_config = original_parse_config
    OpenAIAuth.get_headers = original_get_headers
    OpenAIAuth.state = { openai_token = nil }
  end)

  busted.it("sends Sign in with ChatGPT tokens to the OpenAI Responses API", function()
    local args = curl_args({ access_token = "a", refresh_token = "r", expires_at = 0, client_id = "oaiapp_issued" })

    assert.equals("https://api.openai.com/v1/responses", args.url)
    assert.is_false(args.body.store)
    assert.is_nil(args.body.temperature)
    assert.is_nil(args.body.max_output_tokens)
    assert.is_nil(args.body.prompt_cache_retention)
    assert.is_nil(args.body.instructions)
    assert.equals("developer", args.body.input[1].role)
    assert.equals("system prompt", args.body.input[1].content)
  end)

  busted.it("keeps device code tokens on the Codex backend", function()
    local args = curl_args({ access_token = "a", refresh_token = "r", expires_at = 0, account_id = "acct" })

    assert.equals("https://chatgpt.com/backend-api/codex/responses", args.url)
    assert.equals("system prompt", args.body.instructions)
    assert.equals("user", args.body.input[1].role)
  end)
end)

busted.describe("ChatGPT usage limit", function()
  local openai = require("avante.providers.openai")
  local usage_limit_error = {
    code = "subscription_sharing_usage_limit_exceeded",
    message = "Usage limit reached.",
    type = "rate_limit_error",
  }

  busted.it("recognizes the usage limit in an HTTP error body", function()
    local message = openai:get_usage_limit_error(vim.json.encode({ error = usage_limit_error }))

    assert.equals(
      "subscription_sharing_usage_limit_exceeded: Usage limit reached.\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage",
      message
    )
  end)

  busted.it("ignores other errors", function()
    assert.is_nil(openai:get_usage_limit_error(vim.json.encode({ error = { code = "rate_limit_exceeded" } })))
    assert.is_nil(openai:get_usage_limit_error("not json"))
    assert.is_nil(openai:get_usage_limit_error(nil))
  end)

  busted.it("stops when the stream fails with the usage limit", function()
    local stop_opts
    openai:parse_response(
      {},
      vim.json.encode({
        type = "response.failed",
        response = { id = "resp_failed", status = "failed", error = usage_limit_error },
      }),
      "response.failed",
      { on_stop = function(o) stop_opts = o end }
    )

    assert.equals("error", stop_opts.reason)
    assert.is_true(stop_opts.error:find("Check your ChatGPT usage", 1, true) ~= nil)
  end)

  busted.describe("HTTP 429 responses", function()
    local curl = require("plenary.curl")
    local Utils = require("avante.utils")
    local original_post
    local original_error

    local function request(body)
      curl.post = function(_, opts)
        opts.callback({ status = 429, headers = {}, body = body })
        return {}
      end
      local stop_opts
      require("avante.llm").curl({
        provider = {
          parse_curl_args = function() return { url = "https://api.openai.com/v1/responses", headers = {}, body = {} } end,
          is_disable_stream = function() return false end,
          parse_response = function() end,
          get_usage_limit_error = openai.get_usage_limit_error,
        },
        prompt_opts = {},
        handler_opts = { on_stop = function(o) stop_opts = o end },
      })
      vim.wait(1000, function() return stop_opts ~= nil end)
      return stop_opts
    end

    busted.before_each(function()
      original_post = curl.post
      original_error = Utils.error
      Utils.error = function() end
    end)

    busted.after_each(function()
      curl.post = original_post
      Utils.error = original_error
    end)

    busted.it("stops instead of retrying when the usage limit is reached", function()
      local stop_opts = request(vim.json.encode({ error = usage_limit_error }))

      assert.equals("error", stop_opts.reason)
      assert.is_true(stop_opts.error:find("Check your ChatGPT usage", 1, true) ~= nil)
    end)

    busted.it("still retries other rate limits", function()
      local stop_opts = request(vim.json.encode({ error = { code = "rate_limit_exceeded" } }))

      assert.equals("rate_limit", stop_opts.reason)
    end)
  end)
end)
