local api = vim.api
local Utils = require("avante.utils")

---@class avante.input.ReferenceLinks
local M = {}

---@param path string
---@return string
function M.to_absolute_path(path)
  local abs = Utils.to_absolute_path(path)
  return vim.fs.normalize(abs)
end

---@param abs_path string
---@return string
function M.to_markdown_link(abs_path)
  local normalized = M.to_absolute_path(abs_path)
  local display = Utils.uniform_path(normalized)
  if display == "" then display = normalized end
  return string.format("[%s](file://%s)", display, normalized)
end

---@param paths string[]
---@return string[]
function M.normalize_paths(paths)
  local normalized = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    if type(path) == "string" and path ~= "" then
      local abs = M.to_absolute_path(path)
      if not seen[abs] then
        seen[abs] = true
        table.insert(normalized, abs)
      end
    end
  end
  return normalized
end

---@param content string
---@return string[]
function M.extract_paths(content)
  local refs = Utils.parse_file_references(content or "")
  local paths = {}
  local seen = {}
  for _, ref in ipairs(refs) do
    if ref.path and ref.path ~= "" then
      local abs = M.to_absolute_path(ref.path)
      if not seen[abs] then
        seen[abs] = true
        table.insert(paths, abs)
      end
    end
  end
  return paths
end

---@param bufnr integer
---@return string[]
function M.extract_paths_from_buffer(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return {} end
  local content = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  return M.extract_paths(content)
end

---@param bufnr integer
---@param paths string[]
function M.append_paths_to_buffer(bufnr, paths)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local existing = M.extract_paths(table.concat(lines, "\n"))
  local seen = {}
  for _, path in ipairs(existing) do
    seen[path] = true
  end

  local to_add = {}
  for _, path in ipairs(M.normalize_paths(paths)) do
    if not seen[path] then
      seen[path] = true
      table.insert(to_add, M.to_markdown_link(path))
    end
  end
  if #to_add == 0 then return end

  if #lines == 1 and lines[1] == "" then
    lines = to_add
  else
    if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
    vim.list_extend(lines, to_add)
  end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

---@param bufnr integer
---@param paths string[]
function M.remove_paths_from_buffer(bufnr, paths)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end
  local path_set = {}
  for _, path in ipairs(M.normalize_paths(paths)) do
    path_set[path] = true
  end
  if vim.tbl_isempty(path_set) then return end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local updated = {}

  for _, line in ipairs(lines) do
    local current = line
    for path, _ in pairs(path_set) do
      local pattern = "%[[^%]]+%]%(" .. vim.pesc("file://" .. path) .. "%)"
      current = current:gsub(pattern, "")
    end
    current = current:gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    table.insert(updated, current)
  end

  api.nvim_buf_set_lines(bufnr, 0, -1, false, updated)
end

return M
