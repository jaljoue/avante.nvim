local M = {}

local function copy_url(url)
  local copied = pcall(vim.fn.setreg, "+", url)
  if not copied then copied = pcall(vim.fn.setreg, "*", url) end
  return copied
end

local function notify_fallback(provider_name, copy_target, reason)
  copy_url(copy_target)
  vim.notify(
    string.format(
      "%s login URL copied to clipboard (%s). Open it in your browser:\n%s",
      provider_name,
      reason,
      copy_target
    ),
    vim.log.levels.WARN
  )
end

local function run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
  if not opts.on_copy then return end
  opts.on_copy({
    provider_name = provider_name,
    auth_url = auth_url,
    open_url = open_url,
    copy_url = copy_target,
    close = function() end,
  })
end

---@param opts { provider_name?: string, auth_url: string, open_url?: string, copy_url?: string, disable_open?: boolean, on_open?: fun(ctx: { provider_name: string, auth_url: string, open_url: string, copy_url: string, close: fun() }), on_copy?: fun(ctx: { provider_name: string, auth_url: string, open_url: string, copy_url: string, close: fun() }), on_close?: fun() }
---@return boolean
function M.show_auth_url(opts)
  opts = opts or {}
  local provider_name = opts.provider_name or "Provider"
  local auth_url = opts.auth_url
  local open_url = opts.open_url or auth_url
  local copy_target = opts.copy_url or auth_url
  local disable_open = opts.disable_open == true

  if type(auth_url) ~= "string" or auth_url == "" then
    vim.notify("OAuth URL is missing", vim.log.levels.ERROR)
    return false
  end

  if #vim.api.nvim_list_uis() == 0 then
    notify_fallback(provider_name, copy_target, "headless session")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    notify_fallback(provider_name, copy_target, "nui unavailable")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
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
    notify_fallback(provider_name, copy_target, "failed to create popup")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  local function close_popup()
    if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then popup:unmount() end
    if opts.on_close then opts.on_close() end
  end

  local function open_action()
    if opts.on_open then
      opts.on_open({
        provider_name = provider_name,
        auth_url = auth_url,
        open_url = open_url,
        copy_url = copy_target,
        close = close_popup,
      })
      return
    end

    local ok, err = pcall(vim.ui.open, open_url)
    if ok then
      vim.notify(string.format("Opened %s login URL in browser", provider_name), vim.log.levels.INFO)
    else
      copy_url(copy_target)
      vim.notify(
        string.format("Could not open browser (%s). URL copied to clipboard.", tostring(err)),
        vim.log.levels.WARN
      )
    end
    close_popup()
  end

  local function copy_action()
    local copied = copy_url(copy_target)
    if copied then
      vim.notify(string.format("Copied %s login URL to clipboard", provider_name), vim.log.levels.INFO)
    else
      vim.notify(string.format("Failed to copy %s login URL", provider_name), vim.log.levels.ERROR)
    end

    if opts.on_copy then
      opts.on_copy({
        provider_name = provider_name,
        auth_url = auth_url,
        open_url = open_url,
        copy_url = copy_target,
        close = close_popup,
      })
      return
    end

    close_popup()
  end

  local lines = {
    "",
    string.format("  Authenticate %s", provider_name),
    "",
    "  Choose an action:",
  }
  if not disable_open then table.insert(lines, "    [Enter]/[o] Open in browser") end
  vim.list_extend(lines, {
    "    [c]/[y] Copy URL and continue manually",
    "    [q]/[Esc] Close",
    "",
    "  Auth URL:",
    "  " .. auth_url,
  })

  local preloaded = false
  if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
    preloaded = pcall(vim.api.nvim_buf_set_lines, popup.bufnr, 0, -1, false, lines)
  end

  local ok_mount = pcall(function() popup:mount() end)
  if not ok_mount then
    notify_fallback(provider_name, copy_target, "failed to mount popup")
    run_copy_callback(opts, provider_name, auth_url, open_url, copy_target)
    return false
  end

  if not preloaded then
    local ok_set = pcall(vim.api.nvim_buf_set_lines, popup.bufnr, 0, -1, false, lines)
    if not ok_set then
      local modifiable = vim.bo[popup.bufnr].modifiable
      vim.bo[popup.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
      vim.bo[popup.bufnr].modifiable = modifiable
    end
  end

  if not disable_open then
    popup:map("n", "<CR>", open_action, { noremap = true, silent = true })
    popup:map("n", "o", open_action, { noremap = true, silent = true })
    popup:map("n", "O", open_action, { noremap = true, silent = true })
  end
  popup:map("n", "c", copy_action, { noremap = true, silent = true })
  popup:map("n", "C", copy_action, { noremap = true, silent = true })
  popup:map("n", "y", copy_action, { noremap = true, silent = true })
  popup:map("n", "Y", copy_action, { noremap = true, silent = true })
  popup:map("n", "q", close_popup, { noremap = true, silent = true })
  popup:map("n", "<Esc>", close_popup, { noremap = true, silent = true })

  return true
end

---@class AvanteOAuthMethodContext
---@field provider_name string
---@field close fun()

---@class AvanteOAuthMethod
---@field id string unique method id, e.g. "browser", "headless", "api_key"
---@field label string text shown in the method picker
---@field run fun(ctx: AvanteOAuthMethodContext) starts the login flow
---@field headless? boolean works without a local browser; auto-selected when no UI is attached

---Shows a picker of the login methods a provider supports and runs the chosen
---one. With a single method (or no attached UI, which prefers the first method
---marked headless) it runs directly without showing a picker.
---@param opts { provider_name?: string, methods: AvanteOAuthMethod[], on_close?: fun() }
---@return boolean
function M.select_method(opts)
  opts = opts or {}
  local provider_name = opts.provider_name or "Provider"
  local methods = opts.methods or {}

  if #methods == 0 then
    vim.notify(string.format("No login methods available for %s", provider_name), vim.log.levels.ERROR)
    if opts.on_close then opts.on_close() end
    return false
  end

  local function run(method)
    method.run({
      provider_name = provider_name,
      close = function()
        if opts.on_close then opts.on_close() end
      end,
    })
  end

  if #vim.api.nvim_list_uis() == 0 then
    local fallback = methods[1]
    for _, method in ipairs(methods) do
      if method.headless then
        fallback = method
        break
      end
    end
    run(fallback)
    return true
  end

  if #methods == 1 then
    run(methods[1])
    return true
  end

  vim.ui.select(methods, {
    prompt = "Select auth method",
    format_item = function(method) return method.label end,
  }, function(method)
    if not method then
      if opts.on_close then opts.on_close() end
      return
    end
    run(method)
  end)

  return true
end

return M
