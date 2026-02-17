local M = {}

local function copy_url(url)
  local copied = pcall(vim.fn.setreg, "+", url)
  if not copied then copied = pcall(vim.fn.setreg, "*", url) end
  return copied
end

local function notify_fallback(provider_name, auth_url, reason)
  copy_url(auth_url)
  vim.notify(
    string.format(
      "%s login URL copied to clipboard (%s). Open it in your browser:\n%s",
      provider_name,
      reason,
      auth_url
    ),
    vim.log.levels.WARN
  )
end

---@param opts { provider_name: string, auth_url: string }
---@return boolean
function M.show_auth_url(opts)
  opts = opts or {}
  local provider_name = opts.provider_name or "Provider"
  local auth_url = opts.auth_url

  if type(auth_url) ~= "string" or auth_url == "" then
    vim.notify("OAuth URL is missing", vim.log.levels.ERROR)
    return false
  end

  if #vim.api.nvim_list_uis() == 0 then
    notify_fallback(provider_name, auth_url, "headless session")
    return false
  end

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    notify_fallback(provider_name, auth_url, "nui unavailable")
    return false
  end

  local width = math.min(math.max(math.floor(vim.o.columns * 0.8), 70), 120)
  local height = math.min(math.max(math.floor(vim.o.lines * 0.4), 10), 16)

  local ok_create, popup = pcall(Popup, {
    position = "50%",
    size = {
      width = width,
      height = height,
    },
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = string.format(" %s OAuth ", provider_name),
        top_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      buftype = "nofile",
      filetype = "AvanteOAuth",
    },
    win_options = {
      wrap = true,
      linebreak = true,
      winfixbuf = true,
    },
  })
  if not ok_create then
    notify_fallback(provider_name, auth_url, "failed to create popup")
    return false
  end

  local function close_popup()
    if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then popup:unmount() end
  end

  local function open_url()
    local ok, err = pcall(vim.ui.open, auth_url)
    if ok then
      vim.notify(string.format("Opened %s login URL in browser", provider_name), vim.log.levels.INFO)
    else
      copy_url(auth_url)
      vim.notify(
        string.format("Could not open browser (%s). URL copied to clipboard.", tostring(err)),
        vim.log.levels.WARN
      )
    end
    close_popup()
  end

  local function copy_and_close()
    local copied = copy_url(auth_url)
    if copied then
      vim.notify(string.format("Copied %s login URL to clipboard", provider_name), vim.log.levels.INFO)
    else
      vim.notify(string.format("Failed to copy %s login URL", provider_name), vim.log.levels.ERROR)
    end
    close_popup()
  end

  local ok_mount = pcall(function() popup:mount() end)
  if not ok_mount then
    notify_fallback(provider_name, auth_url, "failed to mount popup")
    return false
  end

  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, {
    "",
    string.format("  Authenticate %s", provider_name),
    "",
    "  Choose an action:",
    "    [Enter]/[o] Open in browser",
    "    [c]/[y] Copy URL to clipboard",
    "    [q]/[Esc] Close",
    "",
    "  Auth URL:",
    "  " .. auth_url,
  })

  popup:map("n", "<CR>", open_url, { noremap = true, silent = true })
  popup:map("n", "o", open_url, { noremap = true, silent = true })
  popup:map("n", "O", open_url, { noremap = true, silent = true })
  popup:map("n", "c", copy_and_close, { noremap = true, silent = true })
  popup:map("n", "C", copy_and_close, { noremap = true, silent = true })
  popup:map("n", "y", copy_and_close, { noremap = true, silent = true })
  popup:map("n", "Y", copy_and_close, { noremap = true, silent = true })
  popup:map("n", "q", close_popup, { noremap = true, silent = true })
  popup:map("n", "<Esc>", close_popup, { noremap = true, silent = true })

  return true
end

return M
