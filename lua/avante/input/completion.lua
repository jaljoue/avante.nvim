local Utils = require("avante.utils")
local ReferenceLinks = require("avante.input.reference_links")

local M = {}

M.completion_items = {}

local function get_entries(base_path)
  local project_root = Utils.get_project_root()
  local prefix = (base_path or ""):gsub("^%./", "")
  local entries = Utils.scan_directory({ directory = project_root, add_dirs = true })

  local filtered = {}
  for _, entry in ipairs(entries) do
    local rel_path = Utils.make_relative_path(entry, project_root)
    if prefix == "" or vim.startswith(rel_path, prefix) then
      table.insert(filtered, {
        abs_path = entry,
        rel_path = rel_path,
        is_dir = vim.fn.isdirectory(entry) == 1,
      })
    end
  end

  table.sort(filtered, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.rel_path < b.rel_path
  end)

  return filtered
end

---Get file completions for an @ prefix
---@param base_path string
---@return { label: string, insertText: string, kind: string, documentation: string, abs_path: string, rel_path: string }[]
function M.get_file_completions(base_path)
  local entries = get_entries(base_path)
  local items = {}

  for _, entry in ipairs(entries) do
    if not entry.is_dir then
      table.insert(items, {
        label = entry.rel_path,
        insertText = ReferenceLinks.to_markdown_link(entry.abs_path),
        kind = "File",
        documentation = entry.abs_path,
        abs_path = entry.abs_path,
        rel_path = entry.rel_path,
      })
    end
  end

  return items
end

---Get directory completions for an @ prefix
---@param base_path string
---@return { label: string, insertText: string, kind: string, documentation: string, abs_path: string, rel_path: string }[]
function M.get_directory_completions(base_path)
  local entries = get_entries(base_path)
  local items = {}

  for _, entry in ipairs(entries) do
    if entry.is_dir then
      table.insert(items, {
        label = entry.rel_path .. "/",
        insertText = ReferenceLinks.to_markdown_link(entry.abs_path),
        kind = "Folder",
        documentation = entry.abs_path,
        abs_path = entry.abs_path,
        rel_path = entry.rel_path,
      })
    end
  end

  return items
end

---@param base_path string
---@param opts? { include_files?: boolean, include_dirs?: boolean, limit?: integer }
---@return { label: string, insertText: string, kind: string, documentation: string, abs_path: string, rel_path: string }[]
function M.get_at_completions(base_path, opts)
  opts = opts or {}
  local include_files = opts.include_files ~= false
  local include_dirs = opts.include_dirs ~= false
  local limit = opts.limit or 200

  local items = {}
  if include_dirs then vim.list_extend(items, M.get_directory_completions(base_path)) end
  if include_files then vim.list_extend(items, M.get_file_completions(base_path)) end

  table.sort(items, function(a, b) return a.label < b.label end)

  if #items > limit then items = vim.list_slice(items, 1, limit) end
  return items
end

---@param before string
---@return integer | nil, string | nil
function M.find_at_token(before)
  local start = before:match(".*()@[^%s]*$")
  if not start then return nil, nil end
  local prefix = before:match("@([^%s]*)$") or ""
  return start, prefix
end

---Setup completion for a buffer
---@param bufnr integer
function M.setup_buffer_completion(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.bo[bufnr].omnifunc = "v:lua.require'avante.input.completion'.complete"
end

---Omni-complete function
---@param findstart integer
---@param base string
---@return integer | { word: string, abbr: string, menu: string, info: string, kind: string, icase: number, dup: number }[]
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    local start = M.find_at_token(before)
    if start then return start end

    return -1
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local _, prefix = M.find_at_token(before)
  if not prefix then return {} end

  local items = M.get_at_completions(prefix)
  return vim.tbl_map(function(item)
    return {
      word = item.insertText,
      abbr = item.label,
      menu = item.kind == "Folder" and "dir" or "file",
      info = item.documentation,
      kind = item.kind,
      icase = 1,
      dup = 0,
    }
  end, items)
end

return M
