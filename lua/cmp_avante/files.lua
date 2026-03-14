local Completion = require("avante.input.completion")

---@class FilesSource : cmp.Source
local FilesSource = {}
FilesSource.__index = FilesSource

function FilesSource:new()
  local instance = setmetatable({}, FilesSource)
  return instance
end

function FilesSource:is_available() return vim.bo.filetype == "AvanteInput" end

function FilesSource.get_position_encoding_kind() return "utf-8" end

function FilesSource:get_trigger_characters() return { "@" } end

function FilesSource:get_keyword_pattern() return [[\%(@\|#\|/\)\k*]] end

---@param params cmp.SourceCompletionApiParams
function FilesSource:complete(params, callback)
  local trigger_character
  if params.completion_context.triggerKind == 1 then
    trigger_character = string.match(params.context.cursor_before_line, "%s*(@)%S*$")
  elseif params.completion_context.triggerKind == 2 then
    trigger_character = params.completion_context.triggerCharacter
  end
  if not trigger_character or trigger_character ~= "@" then return callback({ items = {}, isIncomplete = false }) end

  local prefix = params.context.cursor_before_line:match("@([^%s]*)$")
  if prefix == nil then return callback({ items = {}, isIncomplete = false }) end

  local kind = require("cmp").lsp.CompletionItemKind
  local items = Completion.get_at_completions(prefix)

  callback({
    items = vim.tbl_map(function(item)
      return {
        label = item.label,
        kind = item.kind == "Folder" and kind.Folder or kind.File,
        detail = item.kind,
        documentation = item.documentation,
        insertText = item.insertText,
        filterText = item.rel_path,
      }
    end, items),
    isIncomplete = false,
  })
end

return FilesSource
