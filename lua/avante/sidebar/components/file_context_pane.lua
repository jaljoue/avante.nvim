local api = vim.api

local Split = require("nui.split")
local event = require("nui.utils.autocmd").event
local PPath = require("plenary.path")

local Config = require("avante.config")
local Highlights = require("avante.highlights")
local Utils = require("avante.utils")

local M = {
  id = "pane",
  container_order = {
    "result",
    "selected_code",
    "selected_files",
    "todos",
    "input",
  },
}

function M:initialize(sidebar)
  sidebar.file_selector:reset()

  if not Config.behaviour.auto_add_current_file then return end

  local buf_path = api.nvim_buf_get_name(sidebar.code.bufnr)
  local filepath = Utils.file.is_in_project(buf_path) and Utils.relative_path(buf_path) or buf_path
  Utils.debug("Sidebar:initialize adding buffer to file selector", buf_path)

  local stat = vim.uv.fs_stat(filepath)
  if stat == nil or stat.type == "file" then sidebar.file_selector:add_selected_file(filepath) end
end

function M:cleanup(sidebar)
  if sidebar.file_selector then sidebar.file_selector:off("update") end
  if sidebar.containers.selected_files then
    sidebar.containers.selected_files:unmount()
    sidebar.containers.selected_files = nil
  end
end

function M:get_selected_filepaths(sidebar) return sidebar.file_selector:get_selected_filepaths() end

function M:get_selected_filepaths_mode() return "preload_contents" end

function M:add_file(sidebar, filepath) return sidebar.file_selector:add_selected_file(filepath) end

function M:remove_file(sidebar, filepath) return sidebar.file_selector:remove_selected_file(filepath) end

function M:add_current_buffer(sidebar) return sidebar.file_selector:add_current_buffer() end

function M:add_buffer_files(sidebar) return sidebar.file_selector:add_buffer_files() end

function M:add_quickfix_files(sidebar) return sidebar.file_selector:add_quickfix_files() end

function M:get_height(sidebar)
  local selected_filepaths = sidebar.file_selector:get_selected_filepaths()
  return math.min(Config.windows.selected_files.height, #selected_filepaths + 1)
end

function M:adjust_layout(sidebar)
  if not Utils.is_valid_container(sidebar.containers.selected_files, true) then return end
  api.nvim_win_set_height(sidebar.containers.selected_files.winid, self:get_height(sidebar))
end

function M:close_hint(sidebar)
  if sidebar.containers.selected_files and api.nvim_win_is_valid(sidebar.containers.selected_files.winid) then
    pcall(api.nvim_buf_clear_namespace, sidebar.containers.selected_files.bufnr, sidebar.selected_files_hint_ns, 0, -1)
  end
end

function M:show_hint(sidebar)
  self:close_hint(sidebar)

  local cursor_pos = api.nvim_win_get_cursor(sidebar.containers.selected_files.winid)
  local line_number = cursor_pos[1]
  local col_number = cursor_pos[2]

  local selected_filepaths = sidebar.file_selector:get_selected_filepaths()
  local hint
  if #selected_filepaths == 0 then
    hint = string.format(" [%s: add] ", Config.mappings.sidebar.add_file)
  else
    hint =
      string.format(" [%s: delete, %s: add] ", Config.mappings.sidebar.remove_file, Config.mappings.sidebar.add_file)
  end

  api.nvim_buf_set_extmark(
    sidebar.containers.selected_files.bufnr,
    sidebar.selected_files_hint_ns,
    line_number - 1,
    col_number,
    {
      virt_text = { { hint, "AvanteInlineHint" } },
      virt_text_pos = "right_align",
      hl_group = "AvanteInlineHint",
      priority = sidebar.priority,
    }
  )
end

function M:create_container(sidebar, opts)
  local buf_options = opts.buf_options
  local base_win_options = opts.base_win_options

  if sidebar.containers.selected_files then sidebar.containers.selected_files:unmount() end

  local selected_filepaths = sidebar.file_selector:get_selected_filepaths()
  if #selected_filepaths == 0 then
    sidebar.file_selector:off("update")
    sidebar.file_selector:on("update", function() sidebar:create_selected_files_container() end)
    return
  end

  sidebar.containers.selected_files = Split({
    enter = false,
    relative = {
      type = "win",
      winid = sidebar:get_split_candidate("selected_files"),
    },
    buf_options = vim.tbl_deep_extend("force", buf_options, {
      modifiable = false,
      swapfile = false,
      buftype = "nofile",
      bufhidden = "wipe",
      filetype = "AvanteSelectedFiles",
    }),
    win_options = vim.tbl_deep_extend("force", base_win_options, {
      fillchars = Config.windows.fillchars,
    }),
    position = "bottom",
    size = {
      height = 2,
    },
  })
  sidebar.containers.selected_files:mount()

  local function render()
    local selected_filepaths_ = sidebar.file_selector:get_selected_filepaths()
    if #selected_filepaths_ == 0 then
      if Utils.is_valid_container(sidebar.containers.selected_files) then sidebar.containers.selected_files:unmount() end
      return
    end

    if not Utils.is_valid_container(sidebar.containers.selected_files, true) then
      sidebar:create_selected_files_container()
      if not Utils.is_valid_container(sidebar.containers.selected_files, true) then
        Utils.warn("Failed to create or find selected files container window.")
        return
      end
    end

    local lines_to_set = {}
    local highlights_to_apply = {}
    local project_path = Utils.root.get()

    for i, filepath in ipairs(selected_filepaths_) do
      local icon, hl = Utils.file.get_file_icon(filepath)
      local renderpath = PPath:new(filepath):normalize(project_path)
      table.insert(lines_to_set, string.format("%s %s", icon, renderpath))
      if hl and hl ~= "" then table.insert(highlights_to_apply, { line_nr = i, icon = icon, hl = hl }) end
    end

    local selected_files_count = #lines_to_set
    local selected_files_buf = api.nvim_win_get_buf(sidebar.containers.selected_files.winid)
    Utils.unlock_buf(selected_files_buf)
    api.nvim_buf_clear_namespace(selected_files_buf, sidebar.selected_files_icon_ns, 0, -1)
    api.nvim_buf_set_lines(selected_files_buf, 0, -1, true, lines_to_set)

    for _, highlight_info in ipairs(highlights_to_apply) do
      local line_idx = highlight_info.line_nr - 1
      local icon_bytes = #highlight_info.icon
      pcall(api.nvim_buf_set_extmark, selected_files_buf, sidebar.selected_files_icon_ns, line_idx, 0, {
        end_col = icon_bytes,
        hl_group = highlight_info.hl,
        priority = sidebar.priority,
      })
    end

    Utils.lock_buf(selected_files_buf)
    api.nvim_win_set_height(sidebar.containers.selected_files.winid, self:get_height(sidebar))
    sidebar:render_header(
      sidebar.containers.selected_files.winid,
      selected_files_buf,
      string.format(
        "%sSelected (%d file%s)",
        Utils.icon(" "),
        selected_files_count,
        selected_files_count > 1 and "s" or ""
      ),
      Highlights.SUBTITLE,
      Highlights.REVERSED_SUBTITLE
    )
    sidebar:adjust_layout()
  end

  sidebar.file_selector:on("update", render)

  local function remove_file(line_number) sidebar.file_selector:remove_selected_filepaths_with_index(line_number) end

  sidebar.containers.selected_files:map("n", Config.mappings.sidebar.remove_file, function()
    local line_number = api.nvim_win_get_cursor(sidebar.containers.selected_files.winid)[1]
    remove_file(line_number)
  end, { noremap = true, silent = true })

  sidebar.containers.selected_files:map("x", Config.mappings.sidebar.remove_file, function()
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local start_line = math.min(vim.fn.line("v"), vim.fn.line("."))
    local end_line = math.max(vim.fn.line("v"), vim.fn.line("."))
    for _ = start_line, end_line do
      remove_file(start_line)
    end
  end, { noremap = true, silent = true })

  sidebar.containers.selected_files:map(
    "n",
    Config.mappings.sidebar.add_file,
    function() sidebar.file_selector:open() end,
    { noremap = true, silent = true }
  )

  sidebar.containers.selected_files:on({ event.CursorMoved }, function() self:show_hint(sidebar) end, {})
  sidebar.containers.selected_files:on(event.BufLeave, function() self:close_hint(sidebar) end, {})

  sidebar:setup_window_navigation(sidebar.containers.selected_files)

  render()
end

function M:configure_input_buffer() end

function M:on_input_changed() end

return M
