local Split = require("nui.split")

local Config = require("avante.config")
local Utils = require("avante.utils")
local Win = require("avante.sidebar.win")

local M = {}

function M:get_selected_code_container_height()
  if not self.code.selection then return 0 end

  local count = Utils.count_lines(self.code.selection.content)
  if Config.windows.sidebar_header.enabled then count = count + 1 end
  return math.min(count, 5)
end

function M:create_selected_code_container()
  if self.containers.selected_code ~= nil then
    self.containers.selected_code:unmount()
    self.containers.selected_code = nil
  end

  local height = self:get_selected_code_container_height()
  if self.code.selection == nil then return end

  self.containers.selected_code = Split({
    enter = false,
    relative = {
      type = "win",
      winid = self:get_split_candidate("selected_code"),
    },
    buf_options = vim.tbl_deep_extend("force", Win.get_buf_options(), { filetype = "AvanteSelectedCode" }),
    win_options = vim.tbl_deep_extend("force", Win.get_base_win_options(), {}),
    size = {
      height = height,
    },
    position = "bottom",
  })
  self.containers.selected_code:mount()
  self:adjust_layout()
  self:setup_window_navigation(self.containers.selected_code)
end

return M
