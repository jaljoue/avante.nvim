local api = vim.api

local Split = require("nui.split")

local Config = require("avante.config")
local Highlights = require("avante.highlights")
local Path = require("avante.path")
local Utils = require("avante.utils")
local Win = require("avante.sidebar.win")

local M = {}

function M:get_todos_container_height()
  local history = Path.history.load(self.code.bufnr)
  if #history.todos == 0 then return 0 end
  return 3
end

function M:create_todos_container()
  local history = Path.history.load(self.code.bufnr)
  if #history.todos == 0 then
    if self.containers.todos and Utils.is_valid_container(self.containers.todos) then
      self.containers.todos:unmount()
    end
    self.containers.todos = nil
    self:adjust_layout()
    return
  end

  local safe_height = math.min(3, math.max(1, vim.o.lines - 5))

  if not Utils.is_valid_container(self.containers.todos, true) then
    self.containers.todos = Split({
      enter = false,
      relative = {
        type = "win",
        winid = self:get_split_candidate("todos"),
      },
      buf_options = vim.tbl_deep_extend("force", Win.get_buf_options(), {
        modifiable = false,
        swapfile = false,
        buftype = "nofile",
        bufhidden = "wipe",
        filetype = "AvanteTodos",
      }),
      win_options = vim.tbl_deep_extend("force", Win.get_base_win_options(), {
        fillchars = Config.windows.fillchars,
      }),
      position = "bottom",
      size = {
        height = safe_height,
      },
    })

    local ok, err = pcall(function()
      self.containers.todos:mount()
      self:setup_window_navigation(self.containers.todos)
    end)
    if not ok then
      Utils.debug("Failed to create todos container:", err)
      self.containers.todos = nil
      return
    end
  end

  local done_count = 0
  local total_count = #history.todos
  local focused_idx = 1
  local todos_content_lines = {}

  for idx, todo in ipairs(history.todos) do
    local status_content = "[ ]"
    if todo.status == "done" then
      done_count = done_count + 1
      status_content = "[x]"
    end
    if todo.status == "doing" then status_content = "[-]" end
    local line = string.format("%s %d. %s", status_content, idx, todo.content)
    if todo.status == "cancelled" then line = "~~" .. line .. "~~" end
    if todo.status ~= "todo" then focused_idx = idx + 1 end
    table.insert(todos_content_lines, line)
  end

  if focused_idx > #todos_content_lines then focused_idx = #todos_content_lines end

  local todos_buf = api.nvim_win_get_buf(self.containers.todos.winid)
  Utils.unlock_buf(todos_buf)
  api.nvim_buf_set_lines(todos_buf, 0, -1, false, todos_content_lines)
  pcall(function() api.nvim_win_set_cursor(self.containers.todos.winid, { focused_idx, 0 }) end)
  Utils.lock_buf(todos_buf)
  self:render_header(
    self.containers.todos.winid,
    todos_buf,
    Utils.icon(" ") .. "Todos" .. " (" .. done_count .. "/" .. total_count .. ")",
    Highlights.SUBTITLE,
    Highlights.REVERSED_SUBTITLE
  )

  local ok, err = pcall(function() self:adjust_layout() end)
  if not ok then Utils.debug("Failed to adjust layout after todos creation:", err) end
end

return M
