local Utils = require("avante.utils")

local M = {}

M.completion_items = {}

---Get file completions for @file: prefix
---@param base_path string
---@return { label: string, insertText: string, kind: string }[]
function M.get_file_completions(base_path)
  local project_root = Utils.get_project_root()
  local search_dir = project_root

  if base_path and base_path ~= "" then
    local potential_dir = Utils.join_paths(project_root, base_path)
    if vim.fn.isdirectory(potential_dir) == 1 then
      search_dir = potential_dir
    else
      local parent = vim.fn.fnamemodify(potential_dir, ":h")
      if vim.fn.isdirectory(parent) == 1 then search_dir = parent end
    end
  end

  local items = {}
  local files = Utils.scan_directory({ directory = search_dir, add_dirs = false })

  for _, filepath in ipairs(files) do
    local rel_path = Utils.make_relative_path(filepath, project_root)
    local filename = vim.fn.fnamemodify(filepath, ":t")
    table.insert(items, {
      label = rel_path,
      insertText = rel_path,
      kind = "File",
      documentation = filepath,
    })
  end

  table.sort(items, function(a, b) return a.label < b.label end)
  return items
end

---Get directory completions for @dir: prefix
---@param base_path string
---@return { label: string, insertText: string, kind: string }[]
function M.get_directory_completions(base_path)
  local project_root = Utils.get_project_root()
  local search_dir = project_root

  if base_path and base_path ~= "" then
    local potential_dir = Utils.join_paths(project_root, base_path)
    if vim.fn.isdirectory(potential_dir) == 1 then
      search_dir = potential_dir
    else
      local parent = vim.fn.fnamemodify(potential_dir, ":h")
      if vim.fn.isdirectory(parent) == 1 then search_dir = parent end
    end
  end

  local items = {}
  local all_entries = Utils.scan_directory({ directory = search_dir, add_dirs = true })

  for _, entry in ipairs(all_entries) do
    if vim.fn.isdirectory(entry) == 1 then
      local rel_path = Utils.make_relative_path(entry, project_root)
      table.insert(items, {
        label = rel_path .. "/",
        insertText = rel_path,
        kind = "Folder",
        documentation = entry,
      })
    end
  end

  table.sort(items, function(a, b) return a.label < b.label end)
  return items
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

    local start = before:find("@file:$") or before:find("@dir:$")
    if start then return start end

    start = before:find("@file:[^[:space:]*$") or before:find("@dir:[^[:space:]*$")
    if start then
      local prefix = before:match("@file:([^[:space:]*$)") or before:match("@dir:([^[:space:]*$)")
      return start + (prefix and #prefix + 1 or 0)
    end

    return -1
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)

  if before:match("@file:[^[:space:]*$") then
    local base_path = before:match("@file:([^[:space:]*$)") or ""
    local items = M.get_file_completions(base_path)
    return vim.tbl_map(function(item)
      return {
        word = item.insertText,
        abbr = item.label,
        menu = "file",
        info = item.documentation,
        kind = item.kind,
        icase = 1,
        dup = 0,
      }
    end, items)
  end

  if before:match("@dir:[^[:space:]*$") then
    local base_path = before:match("@dir:([^[:space:]*$)") or ""
    local items = M.get_directory_completions(base_path)
    return vim.tbl_map(function(item)
      return {
        word = item.insertText,
        abbr = item.label,
        menu = "dir",
        info = item.documentation,
        kind = item.kind,
        icase = 1,
        dup = 0,
      }
    end, items)
  end

  return {}
end

return M
