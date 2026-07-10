local Popup = require("nui.popup")
local NuiText = require("nui.text")
local event = require("nui.utils.autocmd").event

local M = {}

local ns = vim.api.nvim_create_namespace("avante_model_selector")

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

local function set_buf_lines(bufnr, lines, filetype)
  vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
  if filetype then vim.api.nvim_set_option_value("filetype", filetype, { buf = bufnr }) end
end

local function truncate(text, width)
  text = tostring(text or "")
  if width <= 1 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local result = text
  local chars = vim.fn.strchars(text)
  for length = chars, 0, -1 do
    result = vim.fn.strcharpart(text, 0, length)
    if vim.fn.strdisplaywidth(result .. "…") <= width then break end
  end
  return result .. "…"
end

local function normalized(text) return tostring(text or ""):lower() end

local function filtered_items(items, query)
  if query == "" then return vim.deepcopy(items) end
  local needle = normalized(query)
  return vim
    .iter(items)
    :filter(function(item)
      return normalized(item.title):find(needle, 1, true) ~= nil or normalized(item.id):find(needle, 1, true) ~= nil
    end)
    :totable()
end

local function open_popup(opts)
  local popup = Popup(vim.tbl_deep_extend("force", {
    enter = opts.enter or false,
    focusable = true,
    border = {
      style = "rounded",
      text = opts.title and { top = NuiText(" " .. opts.title .. " ", "FloatTitle"), top_align = "center" } or nil,
    },
    buf_options = {
      buftype = "nofile",
      filetype = opts.filetype,
      modifiable = false,
      readonly = true,
    },
    win_options = {
      cursorline = opts.cursorline or false,
      wrap = opts.wrap or false,
      winblend = 0,
      winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder",
    },
  }, opts.popup or {}))
  popup:mount()
  return popup
end

---@param opts {
---  title: string,
---  items: avante.ui.SelectorItem[],
---  default_item_id?: string,
---  on_select: fun(ids: string[]|nil),
---  get_preview_content?: fun(item_id: string): (string, string),
---}
function M.open(opts)
  local items = opts.items or {}
  if #items == 0 then
    opts.on_select(nil)
    return
  end

  local provider_opts = opts.provider_opts or {}
  local previous_win = vim.api.nvim_get_current_win()
  local width_ratio = provider_opts.width or 0.88
  local height_ratio = provider_opts.height or 0.78
  local list_ratio = provider_opts.list_width or 0.46
  local width = math.max(80, math.floor(vim.o.columns * width_ratio))
  local height = math.max(18, math.floor(vim.o.lines * height_ratio))
  width = math.min(width, vim.o.columns - 4)
  height = math.min(height, vim.o.lines - 4)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local input_height = 3
  local body_height = height - input_height
  local max_list_width = math.max(24, width - 24)
  local list_width = clamp(math.floor(width * list_ratio), 24, max_list_width)
  local preview_width = math.max(20, width - list_width - 1)

  local state = {
    query = "",
    selected = 1,
    top = 1,
    closed = false,
    filtered = vim.deepcopy(items),
  }

  for index, item in ipairs(state.filtered) do
    if item.id == opts.default_item_id then
      state.selected = index
      break
    end
  end

  local list_popup = open_popup({
    title = opts.title or "Avante Models",
    filetype = "AvanteModelSelector",
    cursorline = false,
    popup = {
      relative = "editor",
      position = { row = row, col = col },
      size = { width = list_width, height = body_height },
    },
  })

  local preview_popup = open_popup({
    title = "Details",
    filetype = "markdown",
    wrap = true,
    popup = {
      relative = "editor",
      position = { row = row, col = col + list_width + 1 },
      size = { width = preview_width, height = body_height },
    },
  })

  local input_popup = open_popup({
    title = "Filter",
    filetype = "AvanteModelSelectorFilter",
    enter = true,
    popup = {
      relative = "editor",
      position = { row = row + body_height, col = col },
      size = { width = width, height = input_height },
    },
  })

  local function close(selected_ids)
    if state.closed then return end
    state.closed = true
    for _, popup in ipairs({ list_popup, preview_popup, input_popup }) do
      if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
        pcall(vim.api.nvim_set_option_value, "modified", false, { buf = popup.bufnr })
      end
    end
    pcall(list_popup.unmount, list_popup)
    pcall(preview_popup.unmount, preview_popup)
    pcall(input_popup.unmount, input_popup)
    if vim.api.nvim_win_is_valid(previous_win) then pcall(vim.api.nvim_set_current_win, previous_win) end
    opts.on_select(selected_ids)
  end

  local function selected_item() return state.filtered[state.selected] end

  local function render_preview()
    local item = selected_item()
    if not item or not opts.get_preview_content then
      set_buf_lines(preview_popup.bufnr, { "No model selected." }, "markdown")
      return
    end
    local content, filetype = opts.get_preview_content(item.id)
    local lines = vim.split(content or item.title or "", "\n", { plain = true })
    set_buf_lines(preview_popup.bufnr, lines, filetype or "markdown")
    if vim.api.nvim_win_is_valid(preview_popup.winid) then
      pcall(vim.api.nvim_win_set_cursor, preview_popup.winid, { 1, 0 })
    end
  end

  local function render_list()
    local visible_height = math.max(1, body_height - 2)
    state.selected = clamp(state.selected, 1, math.max(#state.filtered, 1))
    if state.selected < state.top then state.top = state.selected end
    if state.selected >= state.top + visible_height then state.top = state.selected - visible_height + 1 end
    state.top = clamp(state.top, 1, math.max(#state.filtered, 1))

    local lines = {}
    if #state.filtered == 0 then
      lines = { "  No matching models" }
    else
      for index = state.top, math.min(#state.filtered, state.top + visible_height - 1) do
        local item = state.filtered[index]
        local prefix = index == state.selected and "› " or "  "
        table.insert(lines, prefix .. truncate(item.title, list_width - 4))
      end
    end

    local status = string.format(
      "  %d / %d%s",
      math.min(#state.filtered, state.selected),
      #state.filtered,
      state.query ~= "" and ("  filter: " .. state.query) or ""
    )
    table.insert(lines, "")
    table.insert(lines, truncate(status, list_width - 2))

    set_buf_lines(list_popup.bufnr, lines, "AvanteModelSelector")
    vim.api.nvim_buf_clear_namespace(list_popup.bufnr, ns, 0, -1)
    if #state.filtered > 0 then
      local selected_line = state.selected - state.top
      if selected_line >= 0 and selected_line < visible_height then
        vim.api.nvim_buf_set_extmark(list_popup.bufnr, ns, selected_line, 0, {
          line_hl_group = "Visual",
        })
      end
    end
  end

  local function render()
    render_list()
    render_preview()
  end

  local function update_query()
    local lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, 1, false)
    state.query = lines[1] or ""
    state.filtered = filtered_items(items, state.query)
    state.selected = 1
    state.top = 1
    render()
  end

  local function move(delta)
    if #state.filtered == 0 then return end
    state.selected = clamp(state.selected + delta, 1, #state.filtered)
    render()
  end

  local function choose()
    local item = selected_item()
    if item then close({ item.id }) end
  end

  local function scroll_preview(delta)
    if not vim.api.nvim_win_is_valid(preview_popup.winid) then return end
    vim.api.nvim_win_call(preview_popup.winid, function()
      vim.cmd("normal! " .. tostring(math.abs(delta)) .. (delta > 0 and "\\<C-E>" or "\\<C-Y>"))
    end)
  end

  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = input_popup.bufnr, nowait = true, silent = true })
  end

  map({ "n", "i" }, "<Esc>", function() close(nil) end)
  map({ "n", "i" }, "<C-c>", function() close(nil) end)
  map("n", "q", function() close(nil) end)
  map({ "n", "i" }, "<CR>", choose)
  map({ "n", "i" }, "<Down>", function() move(1) end)
  map({ "n", "i" }, "<C-n>", function() move(1) end)
  map({ "n", "i" }, "<Up>", function() move(-1) end)
  map({ "n", "i" }, "<C-p>", function() move(-1) end)
  map({ "n", "i" }, "<PageDown>", function() move(body_height - 3) end)
  map({ "n", "i" }, "<PageUp>", function() move(-(body_height - 3)) end)
  map({ "n", "i" }, "<C-d>", function() scroll_preview(8) end)
  map({ "n", "i" }, "<C-u>", function() scroll_preview(-8) end)

  input_popup:on(event.BufLeave, function()
    if not state.closed then vim.schedule(function() close(nil) end) end
  end)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input_popup.bufnr,
    callback = update_query,
  })

  set_buf_lines(input_popup.bufnr, { "" }, "AvanteModelSelectorFilter")
  vim.api.nvim_set_option_value("modifiable", true, { buf = input_popup.bufnr })
  vim.api.nvim_set_option_value("readonly", false, { buf = input_popup.bufnr })
  render()
  vim.api.nvim_set_current_win(input_popup.winid)
  vim.cmd("startinsert")
end

return M
