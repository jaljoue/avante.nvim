local Utils = require("avante.utils")
local Providers = require("avante.providers")
local Config = require("avante.config")
local Selector = require("avante.ui.selector")

---@class avante.ModelSelector
local M = {}

M.list_models_invoked = {}
M.list_models_returned = {}

local list_models_cached_result = {}

local function model_item_id(provider_name, model_id) return provider_name .. "::" .. model_id end

local function provider_cache_key(provider_name, provider_cfg)
  if provider_cfg.model_list then
    return provider_name
      .. "::"
      .. tostring(provider_cfg.endpoint or "")
      .. "::"
      .. vim.inspect(provider_cfg.model_list)
  end
  return provider_cfg.endpoint or provider_name
end

local function is_private_endpoint(endpoint)
  if type(endpoint) ~= "string" then return false end
  local host = endpoint:match("^https?://([^/:]+)")
  if not host then return false end
  host = host:lower()
  if host == "localhost" or host == "127.0.0.1" or host == "::1" then return true end
  if host:match("^192%.168%.") or host:match("^10%.") then return true end
  local second_octet = tonumber(host:match("^172%.(%d+)%."))
  return second_octet ~= nil and second_octet >= 16 and second_octet <= 31
end

local function should_list_remote_models(provider_name, provider_cfg)
  if provider_cfg.disable_model_list == true then return false end
  if provider_cfg.model_list == false then return false end
  if provider_name ~= Config.provider and provider_cfg.always_list_models ~= true then return false end
  if is_private_endpoint(provider_cfg.endpoint) and provider_cfg.model_list == nil then return false end
  return true
end

---@brief Lists models available for a single provider
--- Calls provider's list_models and caches result
---@param provider_name string
---@param provider_cfg table
---@return table
local function create_model_entries(provider_name, provider_cfg)
  local res = {}
  if provider_cfg.list_models then
    local models
    local cache_key = provider_cache_key(provider_name, provider_cfg)
    if type(provider_cfg.list_models) == "function" then
      if should_list_remote_models(provider_name, provider_cfg) then
        if M.list_models_invoked[cache_key] then return {} end
        M.list_models_invoked[cache_key] = true
        local should_cache_result = provider_cfg.model_list_cacheable ~= false
        local cached_result = should_cache_result and list_models_cached_result[cache_key] or nil
        if cached_result then
          models = cached_result
        else
          models = provider_cfg:list_models()
          if should_cache_result then list_models_cached_result[cache_key] = models end
        end
      end
    else
      if M.list_models_returned[provider_cfg.list_models] then return {} end
      M.list_models_returned[provider_cfg.list_models] = true
      models = provider_cfg.list_models
    end
    if models then
      -- If list_models is defined, use it to create entries
      res = vim
        .iter(models)
        :map(
          function(model)
            local entry = vim.deepcopy(model)
            entry.name = model.name or model.id
            entry.display_name = model.display_name or model.name or model.id
            entry.provider_name = provider_name
            entry.model = model.id
            entry.item_id = model_item_id(provider_name, model.id)
            return entry
          end
        )
        :totable()
    end
  end
  if provider_cfg.model then
    local seen = vim.iter(res):find(function(item) return item.model == provider_cfg.model end)
    if not seen then
      table.insert(res, {
        name = provider_cfg.display_name or (provider_name .. "/" .. provider_cfg.model),
        display_name = provider_cfg.display_name or (provider_name .. "/" .. provider_cfg.model),
        provider_name = provider_name,
        model = provider_cfg.model,
        item_id = model_item_id(provider_name, provider_cfg.model),
      })
    end
  end
  if provider_cfg.model_names then
    for _, model_name in ipairs(provider_cfg.model_names) do
      local seen = vim.iter(res):find(function(item) return item.model == model_name end)
      if not seen then
        table.insert(res, {
          name = provider_cfg.display_name or (provider_name .. "/" .. model_name),
          display_name = provider_cfg.display_name or (provider_name .. "/" .. model_name),
          provider_name = provider_name,
          model = model_name,
          item_id = model_item_id(provider_name, model_name),
        })
      end
    end
  end
  return res
end

local function list_text(title, values)
  if type(values) ~= "table" then return nil end
  local filtered = vim
    .iter(values)
    :filter(function(value) return type(value) == "string" and value ~= "" end)
    :totable()
  if #filtered == 0 then return nil end
  return title .. ": " .. table.concat(filtered, ", ")
end

local function scalar_text(value)
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then return tostring(value) end
  return nil
end

local function pricing_per_million(value)
  local number = tonumber(value)
  if number == nil then return "n/a" end
  if number < 0 then return "router" end
  if number == 0 then return "free" end
  local text = string.format("%.6f", number * 1000000):gsub("0+$", ""):gsub("%.$", "")
  return "$" .. text
end

local function pricing_preview(pricing)
  if type(pricing) ~= "table" then return nil end
  return "Pricing: "
    .. pricing_per_million(pricing.prompt or pricing.input)
    .. "/"
    .. pricing_per_million(pricing.completion or pricing.output)
    .. " per 1M tokens"
end

local function benchmark_preview(benchmarks)
  if type(benchmarks) ~= "table" then return nil end
  local parts = {}
  for key, value in pairs(benchmarks) do
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      table.insert(parts, tostring(key) .. ": " .. tostring(value))
    end
  end
  table.sort(parts)
  if #parts == 0 then
    for key, _ in pairs(benchmarks) do
      table.insert(parts, tostring(key))
    end
    table.sort(parts)
  end
  if #parts == 0 then return nil end
  return "Benchmarks: " .. table.concat(parts, ", ")
end

local function openrouter_preview(model)
  local lines = {
    "# " .. (model.display_name or model.name),
    "",
    "- Model ID: `" .. model.model .. "`",
  }

  local function add(line)
    if line and line ~= "" then table.insert(lines, line) end
  end

  local canonical_slug = scalar_text(model.canonical_slug)
  add(canonical_slug and "- Canonical slug: `" .. canonical_slug .. "`" or nil)
  local description = scalar_text(model.description)
  add(description and "\n" .. description or nil)
  local context_length = model.context_length or model.max_input_tokens
  add(context_length and "\n- Context length: " .. tostring(context_length) or nil)
  add(
    model.max_output_tokens and "- Max completion tokens: " .. tostring(model.max_output_tokens) or nil
  )
  if type(model.architecture) == "table" then
    add(list_text("- Input modalities", model.architecture.input_modalities))
    add(list_text("- Output modalities", model.architecture.output_modalities))
  end
  add(list_text("- Supported parameters", model.supported_parameters))
  local pricing = pricing_preview(model.pricing)
  add(pricing and "- " .. pricing or nil)
  local expiration_date = scalar_text(model.expiration_date)
  add(expiration_date and "- Expiration date: " .. expiration_date or nil)
  local benchmarks = benchmark_preview(model.benchmarks)
  add(benchmarks and "- " .. benchmarks or nil)

  return table.concat(lines, "\n")
end

local function preview_content(model)
  if model.provider_name == "openrouter" then return openrouter_preview(model), "markdown" end
  return model.name, "markdown"
end

function M.open()
  M.list_models_invoked = {}
  M.list_models_returned = {}
  local models = {}

  Utils.info("listing models")

  -- Collect models from providers
  for provider_name, _ in pairs(Config.providers) do
    local provider_cfg = Providers[provider_name]
    if provider_cfg.hide_in_model_selector then goto continue end
    if not provider_cfg.is_env_set() and provider_cfg.model_list_requires_api_key ~= false then goto continue end
    local entries = create_model_entries(provider_name, provider_cfg)
    models = vim.list_extend(models, entries)
    ::continue::
  end

  -- Sort models by name for stable display
  table.sort(models, function(a, b) return (a.name or "") < (b.name or "") end)

  if #models == 0 then
    Utils.warn("No models available in config")
    return
  end

  local items = vim
    .iter(models)
    :map(function(item)
      return {
        id = item.item_id,
        title = item.display_name,
      }
    end)
    :totable()

  local current_provider = Config.providers[Config.provider]
  local current_model = current_provider and current_provider.model
  local default_item = vim.iter(models):find(
    function(item) return item.model == current_model and item.provider_name == Config.provider end
  )

  local function on_select(item_ids)
    if not item_ids then return end
    local choice = vim.iter(models):find(function(item) return item.item_id == item_ids[1] end)
    if not choice then return end

    -- Switch provider if needed
    if choice.provider_name ~= Config.provider then require("avante.providers").refresh(choice.provider_name) end

    -- Update config with new model
    Config.override({
      providers = {
        [choice.provider_name] = vim.tbl_deep_extend(
          "force",
          Config.get_provider_config(choice.provider_name),
          { model = choice.model }
        ),
      },
    })

    local provider_cfg = Providers[choice.provider_name]
    if provider_cfg then provider_cfg.model = choice.model end

    if Config.windows.sidebar_header.include_model then
      local sidebar = require("avante").get()
      if sidebar and sidebar:is_open() then sidebar:render_result() end
    else
      Utils.info("Switched to model: " .. choice.name)
    end

    -- Persist last used provider and model
    Config.save_last_model(choice.model, choice.provider_name)
  end

  local selector_opts = {
    title = "Select Avante Model",
    items = items,
    default_item_id = default_item and default_item.item_id or nil,
    provider_opts = Config.model_selector and Config.model_selector.provider_opts or {},
    on_select = on_select,
    get_preview_content = function(item_id)
      local model = vim.iter(models):find(function(item) return item.item_id == item_id end)
      if not model then return "", "markdown" end
      return preview_content(model)
    end,
  }

  if Config.model_selector and Config.model_selector.provider == "nui" then
    require("avante.ui.model_selector").open(selector_opts)
    return
  end

  local selector = Selector:new(vim.tbl_extend("force", selector_opts, {
    provider = Config.selector.provider,
    provider_opts = Config.selector.provider_opts,
  }))

  selector:open()
end

return M
