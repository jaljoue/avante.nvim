local api = vim.api
local fn = vim.fn

local Split = require("nui.split")

local Config = require("avante.config")
local PromptLogger = require("avante.utils.promptLogger")
local SidebarInput = require("avante.input.sidebar")
local Utils = require("avante.utils")
local Win = require("avante.sidebar.win")

local M = {}

function M:close_input_hint()
  if self.input_hint_window and api.nvim_win_is_valid(self.input_hint_window) then
    local buf = api.nvim_win_get_buf(self.input_hint_window)
    if self.input_hint_ns then api.nvim_buf_clear_namespace(buf, self.input_hint_ns, 0, -1) end
    api.nvim_win_close(self.input_hint_window, true)
    api.nvim_buf_delete(buf, { force = true })
    self.input_hint_window = nil
  end
end

function M:get_input_float_window_row()
  local win_height = api.nvim_win_get_height(self.containers.input.winid)
  local winline = Utils.winline(self.containers.input.winid)
  if winline >= win_height - 1 then return 0 end
  return winline
end

function M:show_input_hint()
  self:close_input_hint()

  local hint_text = (fn.mode() ~= "i" and Config.mappings.submit.normal or Config.mappings.submit.insert) .. ": submit"
  if Config.behaviour.enable_token_counting then
    local input_value = table.concat(api.nvim_buf_get_lines(self.containers.input.bufnr, 0, -1, false), "\n")
    if self.token_count == nil then self:initialize_token_count() end
    local tokens = self.token_count + Utils.tokens.calculate_tokens(input_value)
    hint_text = "Tokens: " .. tostring(tokens) .. "; " .. hint_text
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { hint_text })
  api.nvim_buf_set_extmark(buf, self.input_hint_ns, 0, 0, { hl_group = "AvantePopupHint", end_col = #hint_text })

  local win_width = api.nvim_win_get_width(self.containers.input.winid)
  local width = #hint_text

  self.input_hint_window = api.nvim_open_win(buf, false, {
    relative = "win",
    win = self.containers.input.winid,
    width = width,
    height = 1,
    row = self:get_input_float_window_row(),
    col = math.max(win_width - width, 0),
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 100,
  })
end

function M:get_input_bufnr()
  if not self.containers.input then return nil end
  local bufnr = self.containers.input.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return nil end
  return bufnr
end

function M:initialize_token_count()
  if Config.behaviour.enable_token_counting then self:get_generate_prompts_options("") end
end

function M:create_input_container()
  if self.containers.input then self.containers.input:unmount() end
  if not self.code.bufnr or not api.nvim_buf_is_valid(self.code.bufnr) then return end
  if self.chat_history == nil then self:reload_chat_history() end

  local base_win_options, buf_options = SidebarInput.get_container_options(self)

  self.containers.input = Split({
    enter = false,
    relative = {
      type = "win",
      winid = self.containers.result.winid,
    },
    buf_options = vim.tbl_deep_extend("force", Win.get_buf_options(), buf_options, {
      modifiable = true,
    }),
    win_options = vim.tbl_deep_extend(
      "force",
      Win.get_base_win_options(),
      base_win_options,
      { signcolumn = "yes", wrap = Config.windows.wrap }
    ),
    position = SidebarInput.get_position(self),
    size = SidebarInput.get_size(self),
  })

  local function on_submit() self:submit_input() end

  self.containers.input:mount()
  PromptLogger.init()

  local function place_sign_at_first_line(bufnr)
    local group = "avante_input_prompt_group"
    fn.sign_unplace(group, { buffer = bufnr })
    fn.sign_place(0, group, "AvanteInputPromptSign", bufnr, { lnum = 1 })
  end

  place_sign_at_first_line(self.containers.input.bufnr)

  if Utils.in_visual_mode() then
    local esc_key = api.nvim_replace_termcodes("<Esc>", true, false, true)
    api.nvim_feedkeys(esc_key, "n", false)
  end

  self:setup_window_navigation(self.containers.input)
  self.containers.input:map("n", Config.mappings.submit.normal, on_submit)
  self.containers.input:map("i", Config.mappings.submit.insert, on_submit)
  if Config.prompt_logger.next_prompt.normal then
    self.containers.input:map("n", Config.prompt_logger.next_prompt.normal, PromptLogger.on_log_retrieve(-1))
  end
  if Config.prompt_logger.next_prompt.insert then
    self.containers.input:map("i", Config.prompt_logger.next_prompt.insert, PromptLogger.on_log_retrieve(-1))
  end
  if Config.prompt_logger.prev_prompt.normal then
    self.containers.input:map("n", Config.prompt_logger.prev_prompt.normal, PromptLogger.on_log_retrieve(1))
  end
  if Config.prompt_logger.prev_prompt.insert then
    self.containers.input:map("i", Config.prompt_logger.prev_prompt.insert, PromptLogger.on_log_retrieve(1))
  end

  if Config.mappings.sidebar.close_from_input ~= nil then
    if Config.mappings.sidebar.close_from_input.normal ~= nil then
      self.containers.input:map("n", Config.mappings.sidebar.close_from_input.normal, function() self:shutdown() end)
    end
    if Config.mappings.sidebar.close_from_input.insert ~= nil then
      self.containers.input:map("i", Config.mappings.sidebar.close_from_input.insert, function() self:shutdown() end)
    end
  end

  if Config.mappings.sidebar.toggle_code_window_from_input ~= nil then
    if Config.mappings.sidebar.toggle_code_window_from_input.normal ~= nil then
      self.containers.input:map(
        "n",
        Config.mappings.sidebar.toggle_code_window_from_input.normal,
        function() self:toggle_code_window() end
      )
    end
    if Config.mappings.sidebar.toggle_code_window_from_input.insert ~= nil then
      self.containers.input:map(
        "i",
        Config.mappings.sidebar.toggle_code_window_from_input.insert,
        function() self:toggle_code_window() end
      )
    end
  end

  api.nvim_set_option_value("filetype", "AvanteInput", { buf = self.containers.input.bufnr })
  if self.file_context and self.file_context.configure_input_buffer then
    self.file_context:configure_input_buffer(self)
  end

  api.nvim_create_autocmd("InsertEnter", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    once = true,
    desc = "Setup the completion of helpers in the input buffer",
    callback = function() end,
  })

  local debounced_show_input_hint = Utils.debounce(function()
    if api.nvim_win_is_valid(self.containers.input.winid) then self:show_input_hint() end
  end, 200)
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      debounced_show_input_hint()
      place_sign_at_first_line(self.containers.input.bufnr)
      if self.file_context and self.file_context.on_input_changed then
        self.file_context:on_input_changed(self)
      end
    end,
  })

  api.nvim_create_autocmd("QuitPre", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function() self:close_input_hint() end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.containers.input.winid),
    callback = function() self:close_input_hint() end,
  })

  api.nvim_create_autocmd("BufEnter", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      if Config.windows.ask.start_insert then vim.cmd("noautocmd startinsert!") end
    end,
  })

  api.nvim_create_autocmd("BufLeave", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function()
      vim.cmd("noautocmd stopinsert")
      self:close_input_hint()
    end,
  })

  api.nvim_create_autocmd("ModeChanged", {
    group = self.augroup,
    buffer = self.containers.input.bufnr,
    callback = function() self:show_input_hint() end,
  })

  api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      local cur_win = api.nvim_get_current_win()
      if self.containers.input and cur_win == self.containers.input.winid then
        self:show_input_hint()
      else
        self:close_input_hint()
      end
    end,
  })
end

function M:set_input_value(value)
  if not self.containers.input or not value then return end
  api.nvim_buf_set_lines(self.containers.input.bufnr, 0, -1, false, vim.split(value, "\n"))
end

function M:get_input_value()
  if not self.containers.input then return "" end
  local lines = api.nvim_buf_get_lines(self.containers.input.bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

return M
