local Completion = require("avante.input.completion")

---@class blink.cmp.Source
local Source = {}
Source.__index = Source

function Source.new(_, _)
  local self = setmetatable({}, Source)
  return self
end

function Source:enabled() return vim.bo.filetype == "AvanteInput" end

function Source:get_trigger_characters() return { "@" } end

---@param context blink.cmp.Context
function Source:should_show_items(context, _)
  return context.mode ~= "cmdline" and context.trigger and context.trigger.initial_character == "@"
end

---@param context blink.cmp.Context
---@param callback fun(response?: blink.cmp.CompletionResponse)
function Source:get_completions(context, callback)
  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local before = line:sub(1, col)

  local start, prefix = Completion.find_at_token(before)
  if not start or prefix == nil then
    callback({ is_incomplete_backward = false, is_incomplete_forward = false, items = {} })
    return
  end

  local kinds = require("blink.cmp.types").CompletionItemKind

  local items = vim.tbl_map(function(item)
    return {
      label = item.label,
      kind = item.kind == "Folder" and kinds.Folder or kinds.File,
      documentation = item.documentation,
      textEdit = {
        newText = item.insertText,
        range = {
          start = { line = row, character = start - 1 },
          ["end"] = { line = row, character = col },
        },
      },
    }
  end, Completion.get_at_completions(prefix))

  callback({
    is_incomplete_backward = false,
    is_incomplete_forward = false,
    items = items,
  })
end

return Source
