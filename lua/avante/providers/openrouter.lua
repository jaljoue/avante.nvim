local Utils = require("avante.utils")
local Providers = require("avante.providers")
local OpenAI = require("avante.providers.openai")

---@class AvanteProviderFunctor
local M = {
  endpoint = "https://openrouter.ai/api/v1",
  model = "openrouter/auto",
  api_key_name = "OPENROUTER_API_KEY",
  model_list_requires_api_key = false,
  model_list_cacheable = false,
}

setmetatable(M, { __index = OpenAI })

local DEFAULT_MODEL_LIST = {
  output_modalities = { "text" },
  supported_parameters = { "tools" },
  sort = "most-popular",
  cache_ttl = 3600,
  initial_count = 40,
}

local CACHE_VERSION = 1

local function model_list_config(provider_conf)
  return vim.tbl_deep_extend("force", DEFAULT_MODEL_LIST, provider_conf.model_list or {})
end

local function list_value(value)
  if type(value) == "table" then return table.concat(value, ",") end
  if value == nil then return nil end
  return tostring(value)
end

local function query_settings(provider_conf)
  local model_list = model_list_config(provider_conf)
  return {
    output_modalities = list_value(model_list.output_modalities),
    supported_parameters = list_value(model_list.supported_parameters),
    sort = model_list.sort,
  }
end

local function cache_key(provider_conf)
  local query = query_settings(provider_conf)
  return table.concat({
    provider_conf.endpoint or "",
    query.output_modalities or "",
    query.supported_parameters or "",
    query.sort or "",
  }, "\n")
end

local function encode_query_value(value)
  if vim.uri_encode then return vim.uri_encode(value, "rfc3986") end
  return tostring(value):gsub("([^%w%-_%.~])", function(char) return string.format("%%%02X", string.byte(char)) end)
end

local function models_url(provider_conf)
  local query = query_settings(provider_conf)
  local params = {}
  for _, key in ipairs({ "output_modalities", "supported_parameters", "sort" }) do
    local value = query[key]
    if value and value ~= "" then table.insert(params, key .. "=" .. encode_query_value(value)) end
  end
  local url = Utils.url_join(provider_conf.endpoint, "/models/user")
  if #params == 0 then return url end
  return url .. "?" .. table.concat(params, "&")
end

local function file_cache_path()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "avante", "openrouter_models.json")
end

local function is_fresh(payload, ttl)
  if type(payload) ~= "table" or type(payload.fetched_at) ~= "number" then return false end
  return os.time() - payload.fetched_at < ttl
end

local function read_file_cache()
  local path = file_cache_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then return nil end
  local decode_ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(payload) ~= "table" then return nil end
  if payload.cache_version ~= CACHE_VERSION then return nil end
  return payload
end

local function write_file_cache(payload)
  local path = file_cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, encoded = pcall(vim.json.encode, payload)
  if ok then vim.fn.writefile({ encoded }, path) end
end

local function take(models, count)
  if type(count) ~= "number" or count <= 0 or #models <= count then return models end
  return vim.list_slice(models, 1, count)
end

local function seed_models(provider_conf)
  local models = {}
  local seen = {}
  local function add_model(model_id)
    if type(model_id) ~= "string" or model_id == "" or seen[model_id] then return end
    seen[model_id] = true
    table.insert(models, {
      id = model_id,
      name = model_id,
      display_name = model_id,
      version = "",
    })
  end
  add_model(provider_conf.model)
  for _, model_id in ipairs(provider_conf.model_names or {}) do
    add_model(model_id)
  end
  return models
end

local function optional_scalar(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then return value end
  return nil
end

local function optional_table(value)
  if type(value) == "table" then return value end
  return nil
end

local function compact_number(value)
  if value == nil then return "unknown" end
  if type(value) ~= "number" then return tostring(value) end
  if value >= 1000000 and value % 1000000 == 0 then return string.format("%dM", value / 1000000) end
  if value >= 1000 and value % 1000 == 0 then return string.format("%dK", value / 1000) end
  return tostring(value)
end

local function trim_decimal(value)
  local text = string.format("%.6f", value)
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function pricing_per_million(value)
  local number = tonumber(value)
  if number == nil then return "n/a" end
  if number < 0 then return "router" end
  if number == 0 then return "free" end
  return "$" .. trim_decimal(number * 1000000)
end

local function pricing_pair(pricing)
  pricing = pricing or {}
  return pricing_per_million(pricing.prompt or pricing.input)
    .. "/"
    .. pricing_per_million(pricing.completion or pricing.output)
end

local function format_display_name(model)
  local title_name = type(model.name) == "string" and model.name or model.id
  local context = model.context_length
  if context == nil and type(model.top_provider) == "table" then context = model.top_provider.context_length end
  return string.format(
    "openrouter - %s - %s - %s ctx - %s per 1M",
    title_name,
    model.id,
    compact_number(context),
    pricing_pair(model.pricing)
  )
end

local function parse_models(body)
  local models = {}
  for _, model in ipairs(body.data or {}) do
    if type(model) == "table" and type(model.id) == "string" then
      local top_provider = type(model.top_provider) == "table" and model.top_provider or nil
      local context_length = model.context_length or (top_provider and top_provider.context_length)
      table.insert(models, {
        id = model.id,
        name = model.id,
        display_name = format_display_name(model),
        version = tostring(model.created or ""),
        canonical_slug = optional_scalar(model.canonical_slug),
        description = optional_scalar(model.description),
        context_length = type(model.context_length) == "number" and model.context_length or nil,
        architecture = optional_table(model.architecture),
        pricing = optional_table(model.pricing),
        top_provider = optional_table(model.top_provider),
        supported_parameters = optional_table(model.supported_parameters),
        default_parameters = optional_table(model.default_parameters),
        expiration_date = optional_scalar(model.expiration_date),
        benchmarks = optional_table(model.benchmarks),
        sort_key = optional_scalar(model.sort_key),
        max_input_tokens = context_length,
        max_output_tokens = top_provider and top_provider.max_completion_tokens,
      })
    end
  end
  return models
end

local function request_opts(self, provider_conf, on_success, on_error)
  local headers = {
    ["Accept"] = "application/json",
  }

  local api_key = nil
  if type(self.parse_api_key) == "function" then
    local ok, parsed_key = pcall(self.parse_api_key)
    if ok then api_key = parsed_key end
  end
  if type(api_key) == "string" and api_key ~= "" then headers["Authorization"] = "Bearer " .. api_key end

  return {
    headers = Utils.tbl_override(headers, self.extra_headers),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    timeout = provider_conf.timeout,
    callback = on_success,
    on_error = on_error,
  }
end

local function parse_response(response)
  if response.status ~= 200 then
    return nil, "Failed to fetch OpenRouter models: " .. (response.body or response.status)
  end

  local ok, body = pcall(vim.json.decode, response.body)
  if not ok or type(body) ~= "table" or type(body.data) ~= "table" then
    return nil, "Failed to parse OpenRouter model list response"
  end

  return parse_models(body), nil
end

local function update_cache(self, key, models)
  local payload = {
    cache_version = CACHE_VERSION,
    cache_key = key,
    fetched_at = os.time(),
    models = models,
  }
  self._model_list_cache = payload
  write_file_cache(payload)
end

local function start_background_fetch(self, provider_conf, key)
  self._model_list_fetching = self._model_list_fetching or {}
  if self._model_list_fetching[key] then return end
  self._model_list_fetching[key] = true

  local function finish()
    self._model_list_fetching[key] = nil
  end

  local function handle_response(response)
    vim.schedule(function()
      finish()
      local models, err = parse_response(response)
      if not models then
        Utils.warn(err)
        return
      end
      update_cache(self, key, models)
      Utils.info("OpenRouter model cache refreshed")
    end)
  end

  local function handle_error(err)
    vim.schedule(function()
      finish()
      Utils.warn("Failed to fetch OpenRouter models: " .. vim.inspect(err))
    end)
  end

  local curl = require("plenary.curl")
  local ok, err = pcall(function()
    curl.get(models_url(provider_conf), request_opts(self, provider_conf, handle_response, handle_error))
  end)
  if not ok then
    finish()
    Utils.warn("Failed to start OpenRouter model fetch: " .. err)
  end
end

---Asking OpenRouter to list available models
---@return AvanteProviderModelList
function M:list_models()
  local provider_conf = Providers.parse_config(self)
  if not provider_conf.endpoint then
    Utils.error("OpenRouter provider requires endpoint configuration")
    return {}
  end

  local model_list = model_list_config(provider_conf)
  local ttl = model_list.cache_ttl or DEFAULT_MODEL_LIST.cache_ttl
  local key = cache_key(provider_conf)

  if self._model_list_cache and self._model_list_cache.cache_key == key and is_fresh(self._model_list_cache, ttl) then
    return self._model_list_cache.models
  end

  local file_cache = read_file_cache()
  if
    file_cache
    and file_cache.cache_key == key
    and is_fresh(file_cache, ttl)
    and type(file_cache.models) == "table"
  then
    self._model_list_cache = file_cache
    return file_cache.models
  end

  start_background_fetch(self, provider_conf, key)

  if file_cache and file_cache.cache_key == key and type(file_cache.models) == "table" then
    self._model_list_cache = file_cache
    return take(file_cache.models, model_list.initial_count)
  end

  return seed_models(provider_conf)
end

return M
