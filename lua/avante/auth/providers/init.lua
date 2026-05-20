local M = {}

function M.get(provider_name)
  local ok, mod = pcall(require, "avante.auth.providers." .. provider_name)
  if ok then return mod end
  return nil
end

return M
