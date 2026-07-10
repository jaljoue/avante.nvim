describe("openrouter provider", function()
  local curl
  local original_get
  local original_stdpath
  local cache_root

  local function cache_key(endpoint)
    return table.concat({ endpoint or "https://openrouter.ai/api/v1", "text", "tools", "most-popular" }, "\n")
  end

  local function cache_path()
    return vim.fs.joinpath(cache_root, "avante", "openrouter_models.json")
  end

  local function write_cache(payload)
    payload.cache_version = payload.cache_version or 1
    vim.fn.mkdir(vim.fs.dirname(cache_path()), "p")
    vim.fn.writefile({ vim.json.encode(payload) }, cache_path())
  end

  local function fixture_body()
    return vim.json.encode({
      data = {
        {
          id = "openai/gpt-4o",
          name = "GPT-4o",
          created = 1715367049,
          canonical_slug = "openai/gpt-4o",
          description = "Fast multimodal model.",
          context_length = 128000,
          architecture = {
            input_modalities = { "text", "image" },
            output_modalities = { "text" },
          },
          pricing = {
            prompt = "0.0000025",
            completion = "0.00001",
          },
          top_provider = {
            context_length = 127000,
            max_completion_tokens = 16384,
          },
          supported_parameters = { "tools", "temperature" },
          default_parameters = {
            temperature = 0.7,
          },
          expiration_date = "2027-01-01",
          benchmarks = {
            mmlu = 88.7,
          },
          sort_key = "001",
        },
        {
          id = 12,
          name = "missing string id",
        },
        {
          id = "free/model",
          name = "Free Model",
          context_length = 1000000,
          pricing = {
            prompt = "0",
            completion = "0",
          },
          top_provider = {
            max_completion_tokens = 4096,
          },
        },
        {
          id = "router/model",
          name = "Router Priced Model",
          context_length = 64000,
          pricing = {
            prompt = "-1",
            completion = "-1",
          },
        },
        {
          id = "nulls/model",
          name = "Null Metadata Model",
          canonical_slug = vim.NIL,
          description = vim.NIL,
          expiration_date = vim.NIL,
          pricing = {
            prompt = "0",
            completion = "0",
          },
        },
      },
    })
  end

  local function fresh_provider()
    package.loaded["avante.providers.openrouter"] = nil
    local provider = require("avante.providers.openrouter")
    provider._model_list_cache = nil
    provider._model_list_fetching = nil
    provider.parse_api_key = nil
    return provider
  end

  local function wait_for_cache(provider)
    assert.truthy(vim.wait(1000, function()
      return provider._model_list_cache and provider._model_list_cache.models
    end))
  end

  local function stub_async_success(assert_request)
    curl.get = function(url, opts)
      if assert_request then assert_request(url, opts) end
      vim.schedule(function() opts.callback({ status = 200, body = fixture_body() }) end)
    end
  end

  before_each(function()
    curl = require("plenary.curl")
    original_get = curl.get
    original_stdpath = vim.fn.stdpath
    cache_root = vim.fn.tempname()
    vim.fn.stdpath = function(name)
      if name == "cache" then return cache_root end
      return original_stdpath(name)
    end
  end)

  after_each(function()
    curl.get = original_get
    vim.fn.stdpath = original_stdpath
    vim.fs.rm(cache_root, { recursive = true, force = true })
    package.loaded["avante.providers.openrouter"] = nil
  end)

  it("builds /models URL with expected query parameters", function()
    local captured_url
    local captured_opts
    stub_async_success(function(url, opts)
      captured_url = url
      captured_opts = opts
    end)

    local provider = fresh_provider()
    local initial_models = provider:list_models()

    assert.are.same(
      "https://openrouter.ai/api/v1/models?output_modalities=text&supported_parameters=tools&sort=most-popular",
      captured_url
    )
    assert.are.same("application/json", captured_opts.headers["Accept"])
    assert.is_nil(captured_opts.headers["Authorization"])
    assert.are.same("openrouter/auto", initial_models[1].id)
  end)

  it("parses representative OpenRouter model payload into AvanteProviderModel", function()
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()
    local model = models[1]

    assert.are.same("openai/gpt-4o", model.id)
    assert.are.same("openai/gpt-4o", model.name)
    assert.are.same("1715367049", model.version)
    assert.are.same("openai/gpt-4o", model.canonical_slug)
    assert.are.same("Fast multimodal model.", model.description)
    assert.are.same(128000, model.context_length)
    assert.are.same(128000, model.max_input_tokens)
    assert.are.same(16384, model.max_output_tokens)
    assert.are.same({ "tools", "temperature" }, model.supported_parameters)
    assert.are.same("001", model.sort_key)
  end)

  it("drops malformed entries without string id", function()
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.are.same(4, #models)
    assert.is_nil(vim.iter(models):find(function(model) return model.name == "missing string id" end))
  end)

  it("formats context and pricing correctly, including free and router pricing", function()
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.truthy(models[1].display_name:find("128K ctx", 1, true))
    assert.truthy(models[1].display_name:find("$2.5/$10 per 1M", 1, true))
    assert.truthy(models[2].display_name:find("1M ctx", 1, true))
    assert.truthy(models[2].display_name:find("free/free per 1M", 1, true))
    assert.truthy(models[3].display_name:find("router/router per 1M", 1, true))
  end)

  it("uses fresh in-memory cache without calling curl.get", function()
    local calls = 0
    local provider = fresh_provider()
    curl.get = function(_, opts)
      calls = calls + 1
      vim.schedule(function() opts.callback({ status = 200, body = fixture_body() }) end)
    end
    provider:list_models()
    wait_for_cache(provider)
    local first = provider:list_models()
    local second = provider:list_models()

    assert.are.same(1, calls)
    assert.are.same(first, second)
  end)

  it("reads fresh file cache on a new provider load without calling curl.get", function()
    write_cache({
      cache_key = cache_key(),
      fetched_at = os.time(),
      models = {
        {
          id = "cached/model",
          name = "cached/model",
          display_name = "Cached Model",
          version = "",
        },
      },
    })
    curl.get = function() error("curl.get should not be called") end

    local provider = fresh_provider()
    local models = provider:list_models()

    assert.are.same("cached/model", models[1].id)
  end)

  it("writes file cache after successful mocked fetch", function()
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)

    local payload = vim.json.decode(table.concat(vim.fn.readfile(cache_path()), "\n"))
    assert.are.same(1, payload.cache_version)
    assert.are.same(cache_key(), payload.cache_key)
    assert.are.same("openai/gpt-4o", payload.models[1].id)
  end)

  it("falls back to matching file cache when mocked fetch fails", function()
    write_cache({
      cache_key = cache_key(),
      fetched_at = 1,
      models = {
        {
          id = "stale/model",
          name = "stale/model",
          display_name = "Stale Model",
          version = "",
        },
      },
    })
    curl.get = function(_, opts)
      vim.schedule(function() opts.callback({ status = 500, body = "server error" }) end)
    end

    local provider = fresh_provider()
    local models = provider:list_models()

    assert.are.same("stale/model", models[1].id)
  end)

  it("returns a bounded stale file cache subset while refreshing in the background", function()
    write_cache({
      cache_key = cache_key(),
      fetched_at = 1,
      models = {
        {
          id = "stale/model-1",
          name = "stale/model-1",
          display_name = "Stale Model 1",
          version = "",
        },
        {
          id = "stale/model-2",
          name = "stale/model-2",
          display_name = "Stale Model 2",
          version = "",
        },
      },
    })
    stub_async_success()

    local provider = fresh_provider()
    provider.model_list = {
      initial_count = 1,
    }
    local models = provider:list_models()

    assert.are.same(1, #models)
    assert.are.same("stale/model-1", models[1].id)
    wait_for_cache(provider)
    assert.are.same("openai/gpt-4o", provider._model_list_cache.models[1].id)
  end)

  it("ignores file cache when cache key differs", function()
    write_cache({
      cache_key = "different",
      fetched_at = os.time(),
      models = {
        {
          id = "cached/model",
          name = "cached/model",
          display_name = "Cached Model",
          version = "",
        },
      },
    })
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.are.same("openai/gpt-4o", models[1].id)
  end)

  it("ignores unversioned file cache payloads", function()
    vim.fn.mkdir(vim.fs.dirname(cache_path()), "p")
    vim.fn.writefile({
      vim.json.encode({
        cache_key = cache_key(),
        fetched_at = os.time(),
        models = {
          {
            id = "old/model",
            name = "old/model",
            display_name = "Old Model",
            version = "",
          },
        },
      }),
    }, cache_path())
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.are.same("openai/gpt-4o", models[1].id)
  end)

  it("does not require OPENROUTER_API_KEY for model listing", function()
    stub_async_success(function(_, opts)
      assert.is_nil(opts.headers["Authorization"])
    end)

    local provider = fresh_provider()
    provider.parse_api_key = function() return nil end
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.are.same(4, #models)
  end)

  it("includes bearer auth for model listing when an API key is available", function()
    stub_async_success(function(_, opts)
      assert.are.same("Bearer test-key", opts.headers["Authorization"])
    end)

    local provider = fresh_provider()
    provider.parse_api_key = function() return "test-key" end
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()

    assert.are.same(4, #models)
  end)

  it("normalizes JSON null metadata fields to nil", function()
    stub_async_success()

    local provider = fresh_provider()
    provider:list_models()
    wait_for_cache(provider)
    local models = provider:list_models()
    local model = vim.iter(models):find(function(item) return item.id == "nulls/model" end)

    assert.not_nil(model)
    assert.is_nil(model.canonical_slug)
    assert.is_nil(model.description)
    assert.is_nil(model.expiration_date)
  end)
end)
