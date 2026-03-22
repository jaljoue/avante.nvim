local api = vim.api
local Utils = require("avante.utils")

---@class avante.input.FileRefs
---Handles file reference extmarks and visual feedback in input buffers
local M = {}

M.ns_id = api.nvim_create_namespace("avante_file_references")

---@class avante.FileRefExtmark
---@field bufnr integer
---@field line integer
---@field col integer
---@field end_col integer
---@field ref avante.ParsedFileReference

---Clear all file reference extmarks in a buffer
---@param bufnr integer
function M.clear_extmarks(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, M.ns_id, 0, -1)
end

---Add an extmark for a file reference
---@param bufnr integer
---@param line integer 0-indexed line number
---@param col integer 0-indexed column
---@param end_col integer end column
---@param ref avante.ParsedFileReference
function M.add_file_ref_extmark(bufnr, line, col, end_col, ref)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Choose icon based on type
  local icon = ref.type == "directory" and " " or " "
  local hl_group = ref.type == "directory" and "AvanteDirectoryRef" or "AvanteFileRef"

  -- Create virtual text with icon
  local virt_text = { { icon .. " " .. ref.path, hl_group } }

  api.nvim_buf_set_extmark(bufnr, M.ns_id, line, col, {
    end_col = end_col,
    hl_group = hl_group,
    virt_text = virt_text,
    virt_text_pos = "inline",
    priority = 100,
  })
end

---Highlight all file references in a buffer
---@param bufnr integer
function M.highlight_file_references(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Clear existing highlights
  M.clear_extmarks(bufnr)

  -- Get buffer content
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Parse file references
  local refs = Utils.parse_file_references(content)

  -- Track positions for each reference
  local line_num = 0
  local line_start = 0

  for line_idx, line in ipairs(lines) do
    -- Find @file: or @dir: mentions in this line
    for pos, ref_type, path in line:gmatch("()@(%w+):([^%s%]]+)") do
      if ref_type == "file" or ref_type == "dir" then
        local col = pos - 1 -- 0-indexed
        local end_col = col + 1 + #ref_type + 1 + #path -- @ + type + : + path
        M.add_file_ref_extmark(bufnr, line_idx - 1, col, end_col, {
          type = ref_type == "dir" and "directory" or "file",
          uri = "file://" .. path,
          path = path,
        })
      end
    end

    -- Find markdown links [name](file:///path) in this line
    for pos, display, path in line:gmatch("()%[([^%]]+)%]%(file://([^)]+)%)") do
      local col = pos - 1
      local end_col = col + 1 + #display + 2 + 7 + #path + 1 -- [ + display + ](file:// + path + )
      M.add_file_ref_extmark(bufnr, line_idx - 1, col, end_col, {
        type = "file",
        uri = "file://" .. path,
        display_name = display,
        path = path,
      })
    end
  end
end

---Get file references at cursor position
---@param bufnr integer
---@param line integer
---@param col integer
---@return avante.ParsedFileReference | nil
function M.get_ref_at_cursor(bufnr, line, col)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return nil end

  local content = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""

  -- Check for @file: or @dir: at cursor
  for ref_type, path in content:gmatch("@(%w+):([^%s%]]+)") do
    if ref_type == "file" or ref_type == "dir" then
      -- Check if cursor is within this reference
      local start_pos = content:find("@" .. ref_type .. ":" .. path)
      if start_pos then
        local end_pos = start_pos + 1 + #ref_type + 1 + #path
        if col >= start_pos - 1 and col < end_pos then
          return {
            type = ref_type == "dir" and "directory" or "file",
            uri = "file://" .. path,
            path = path,
          }
        end
      end
    end
  end

  return nil
end

---Setup autocommand to highlight file references on text change
---@param bufnr integer
---@param augroup integer
function M.setup_highlight_autocmd(bufnr, augroup)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.highlight_file_references(bufnr)
    end,
  })

  -- Initial highlight
  M.highlight_file_references(bufnr)
end

return M
