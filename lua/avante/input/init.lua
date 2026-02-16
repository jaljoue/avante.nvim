---@class avante.input.Router
---Input router module that routes to legacy or markdown input based on config
local M = {}

---Get the appropriate input component based on config
---@return table input_component
function M.get_input()
  local config = require("avante.config")
  if (config.input or {}).enable_markdown then
    return require("avante.ui.markdown_input")
  else
    return require("avante.ui.prompt_input") -- Legacy
  end
end

---Create a new input instance based on config
---@param opts? avante.ui.PromptInputOptions
---@return table input_instance
function M.new(opts)
  local Input = M.get_input()
  return Input:new(opts)
end

---Get the sidebar input module for markdown-enabled sidebar containers
---@return table sidebar_input_module
function M.get_sidebar_input()
  return require("avante.input.sidebar")
end

return M
