local Config = require("avante.config")

local M = {}

---@return avante.Sidebar
function M.get_sidebar_class()
  if Config.experimental and Config.experimental.sidebar_v2 then return require("avante.sidebar_v2") end
  return require("avante.sidebar")
end

return M
