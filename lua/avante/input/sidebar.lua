local api = vim.api
local Config = require("avante.config")
local FileRefs = require("avante.input.file_refs")
local Completion = require("avante.input.completion")

---@class avante.input.SidebarInput
---Markdown-aware sidebar input container
local M = {}

---Setup markdown treesitter and render-markdown integration for a buffer
---@param bufnr integer
function M.setup_markdown(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Enable markdown treesitter parser
  local has_ts, _ = pcall(require, "nvim-treesitter.parsers")
  if has_ts then
    vim.treesitter.start(bufnr, "markdown")
  end

  -- Signal to render-markdown.nvim that this buffer should be rendered
  vim.b[bufnr].avante_markdown_enabled = true
  vim.b[bufnr].render_markdown_config = {
    enabled = true,
    file_types = { "AvantePromptInput", "AvanteInput" },
  }
end

---Create input container options with markdown support
---This function returns the base_win_options and buf_options needed for nui
---@param sidebar avante.Sidebar
---@return table base_win_options
---@return table buf_options
function M.get_container_options(sidebar)
  local base_win_options = {
    number = false,
    relativenumber = false,
    foldenable = false,
    foldcolumn = "0",
    cursorline = true,
  }

  local buf_options = {
    swapfile = false,
    buftype = "nofile",
  }

  return base_win_options, buf_options
end

---Configure the input buffer after mounting
---@param sidebar avante.Sidebar
function M.configure_input_buffer(sidebar)
  local bufnr = sidebar.containers.input.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  api.nvim_set_option_value("filetype", "AvanteInput", { buf = bufnr })

  if Config.input.enable_markdown then
    M.setup_markdown(bufnr)
    Completion.setup_buffer_completion(bufnr)
    vim.bo[bufnr].syntax = "avante_input"
  end
end

---Setup input autocmds for the markdown-enabled input
---@param sidebar avante.Sidebar
---@param augroup integer
function M.setup_autocmds(sidebar, augroup)
  local bufnr = sidebar.containers.input.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  -- Place sign at first line (reused from original sidebar)
  local function place_sign_at_first_line()
    local group = "avante_input_prompt_group"
    vim.fn.sign_unplace(group, { buffer = bufnr })
    vim.fn.sign_place(0, group, "AvanteInputPromptSign", bufnr, { lnum = 1 })
  end

  -- Text changed autocmd
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      place_sign_at_first_line()
      if Config.input.enable_markdown then
        FileRefs.highlight_file_references(bufnr)
      end
    end,
  })

  -- Insert enter autocmd (placeholder for future completion setup)
  api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    buffer = bufnr,
    once = true,
    desc = "Setup the completion of helpers in the input buffer",
    callback = function() end,
  })

  -- BufEnter autocmd for starting insert mode
  api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      if Config.windows.ask.start_insert then vim.cmd("noautocmd startinsert!") end
    end,
  })
end

---Get the size configuration for the input container
---@param sidebar avante.Sidebar
---@return table size
function M.get_size(sidebar)
  if sidebar:get_layout() == "vertical" then
    return {
      height = Config.windows.input.height,
    }
  end

  local selected_code_container_height = sidebar:get_selected_code_container_height()

  return {
    width = "40%",
    height = math.max(1, api.nvim_win_get_height(sidebar.containers.result.winid) - selected_code_container_height),
  }
end

---Get the position for the input container
---@param sidebar avante.Sidebar
---@return string position
function M.get_position(sidebar)
  if sidebar:get_layout() == "vertical" then return "bottom" end
  return "right"
end

return M
