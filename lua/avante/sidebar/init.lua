local Config = require("avante.config")
local Core = require("avante.sidebar.core")
local FileContextInline = require("avante.sidebar.components.file_context_inline")
local FileContextPane = require("avante.sidebar.components.file_context_pane")

local M = {}
local classes = {}

local function get_configured_mode()
  if Config.experimental and Config.experimental.sidebar_v2 then return "inline" end
  return "pane"
end

---@return avante.Sidebar
function M.get_sidebar_class()
  local mode = get_configured_mode()
  if not classes[mode] then
    classes[mode] = Core.create(mode == "inline" and FileContextInline or FileContextPane)
  end
  return classes[mode]
end

return M
