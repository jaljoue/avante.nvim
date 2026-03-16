local Config = require("avante.config")
local Highlights = require("avante.highlights")

local M = {}

function M.get_buf_options()
  return {
    modifiable = false,
    swapfile = false,
    buftype = "nofile",
  }
end

function M.get_base_win_options()
  return {
    winfixbuf = true,
    spell = false,
    signcolumn = "no",
    foldcolumn = "0",
    number = false,
    relativenumber = false,
    winfixwidth = true,
    list = false,
    linebreak = true,
    breakindent = true,
    wrap = false,
    cursorline = false,
    fillchars = "eob: ",
    winhighlight = "CursorLine:Normal,CursorColumn:Normal,WinSeparator:"
      .. Highlights.AVANTE_SIDEBAR_WIN_SEPARATOR
      .. ",Normal:"
      .. Highlights.AVANTE_SIDEBAR_NORMAL,
    winbar = "",
    statusline = vim.o.laststatus == 0 and " " or "",
  }
end

function M.get_result_buf_options()
  return vim.tbl_deep_extend("force", M.get_buf_options(), {
    modifiable = false,
    swapfile = false,
    buftype = "nofile",
    bufhidden = "wipe",
    filetype = "Avante",
  })
end

function M.get_result_win_options()
  return vim.tbl_deep_extend("force", M.get_base_win_options(), {
    wrap = Config.windows.wrap,
    fillchars = Config.windows.fillchars,
  })
end

return M
