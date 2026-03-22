local api = vim.api

local Config = require("avante.config")
local Utils = require("avante.utils")

local M = {}

function M:get_layout()
  local position = Config.windows.position
  if position == "smart" then
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines * 3
    if editor_width > editor_height then
      position = "right"
    else
      position = "bottom"
    end
  end
  return vim.tbl_contains({ "left", "right" }, position) and "vertical" or "horizontal"
end

function M:get_split_candidate(container_name)
  local container_order = self:get_container_order()
  local start_index = 0
  for i, name in ipairs(container_order) do
    if name == container_name then
      start_index = i
      break
    end
  end

  if start_index > 1 then
    for i = start_index - 1, 1, -1 do
      local container = self.containers[container_order[i]]
      if Utils.is_valid_container(container, true) then return container.winid end
    end
  end
  return nil
end

function M:switch_window_focus(direction)
  local current_winid = api.nvim_get_current_win()
  local current_index = nil
  local ordered_winids = {}

  for _, name in ipairs(self:get_container_order()) do
    local container = self.containers[name]
    if container and container.winid then
      table.insert(ordered_winids, container.winid)
      if container.winid == current_winid then current_index = #ordered_winids end
    end
  end

  if current_index and #ordered_winids > 1 then
    local next_index
    if direction == "next" then
      next_index = (current_index % #ordered_winids) + 1
    elseif direction == "previous" then
      next_index = current_index - 1
      if next_index < 1 then next_index = #ordered_winids end
    else
      error("Invalid 'direction' parameter: " .. direction)
    end

    api.nvim_set_current_win(ordered_winids[next_index])
  end
end

function M:setup_window_navigation(container)
  local buf = api.nvim_win_get_buf(container.winid)
  Utils.safe_keymap_set(
    { "n", "i" },
    Config.mappings.sidebar.switch_windows,
    function() self:switch_window_focus("next") end,
    { buffer = buf, noremap = true, silent = true, nowait = true }
  )
  Utils.safe_keymap_set(
    { "n", "i" },
    Config.mappings.sidebar.reverse_switch_windows,
    function() self:switch_window_focus("previous") end,
    { buffer = buf, noremap = true, silent = true, nowait = true }
  )
end

function M:resize()
  for _, container in pairs(self.containers) do
    if container.winid and api.nvim_win_is_valid(container.winid) then
      if self.is_in_full_view then
        api.nvim_win_set_width(container.winid, vim.o.columns - 1)
      else
        api.nvim_win_set_width(container.winid, Config.get_window_width())
      end
    end
  end
  self:render_result()
  self:render_input()
  self:render_selected_code()
  vim.defer_fn(function() vim.cmd("AvanteRefresh") end, 200)
end

function M:get_selected_files_container_height()
  if not self.file_context or not self.file_context.get_height then return 0 end
  return self.file_context:get_height(self)
end

function M:get_result_container_height()
  local todos_container_height = self:get_todos_container_height()
  local selected_code_container_height = self:get_selected_code_container_height()
  local selected_files_container_height = self:get_selected_files_container_height()

  if self:get_layout() == "horizontal" then return math.floor(Config.windows.height / 100 * vim.o.lines) end

  return math.max(
    1,
    api.nvim_get_option_value("lines", {})
      - selected_files_container_height
      - selected_code_container_height
      - todos_container_height
      - Config.windows.input.height
  )
end

function M:get_result_container_width()
  if self:get_layout() == "vertical" then return math.floor(Config.windows.width / 100 * vim.o.columns) end

  return math.max(1, api.nvim_win_get_width(self.code.winid))
end

function M:adjust_result_container_layout()
  local width = self:get_result_container_width()
  local height = self:get_result_container_height()

  if self.is_in_full_view then width = vim.o.columns - 1 end

  api.nvim_win_set_width(self.containers.result.winid, width)
  api.nvim_win_set_height(self.containers.result.winid, height)
end

function M:adjust_selected_files_container_layout()
  if self.file_context and self.file_context.adjust_layout then self.file_context:adjust_layout(self) end
end

function M:adjust_selected_code_container_layout()
  if not Utils.is_valid_container(self.containers.selected_code, true) then return end
  api.nvim_win_set_height(self.containers.selected_code.winid, self:get_selected_code_container_height())
end

function M:adjust_todos_container_layout()
  if not Utils.is_valid_container(self.containers.todos, true) then return end
  api.nvim_win_set_height(self.containers.todos.winid, self:get_todos_container_height())
end

function M:adjust_layout()
  self:adjust_result_container_layout()
  self:adjust_todos_container_layout()
  self:adjust_selected_code_container_layout()
  self:adjust_selected_files_container_layout()
end

return M
