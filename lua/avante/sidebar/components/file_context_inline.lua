local api = vim.api

local Config = require("avante.config")
local FileRefs = require("avante.input.file_refs")
local ReferenceLinks = require("avante.input.reference_links")
local SidebarInput = require("avante.input.sidebar")

local function render_markdown(bufnr)
  local ok, render_markdown_api = pcall(require, "render-markdown")
  if not ok then return end
  pcall(render_markdown_api.render, { buf = bufnr, event = "AvanteSidebarInput" })
end

local function get_input_bufnr(sidebar)
  if not sidebar.containers.input then return nil end
  local bufnr = sidebar.containers.input.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return nil end
  return bufnr
end

local function append_paths(sidebar, paths)
  local bufnr = get_input_bufnr(sidebar)
  if not bufnr then return end
  ReferenceLinks.append_paths_to_buffer(bufnr, paths)
end

local function remove_paths(sidebar, paths)
  local bufnr = get_input_bufnr(sidebar)
  if not bufnr then return end
  ReferenceLinks.remove_paths_from_buffer(bufnr, paths)
end

local M = {
  id = "inline",
  container_order = {
    "result",
    "selected_code",
    "todos",
    "input",
  },
}

function M:initialize(sidebar) sidebar.file_selector:reset() end

function M:cleanup(sidebar)
  if sidebar.file_selector then sidebar.file_selector:off("update") end
end

function M:get_selected_filepaths(sidebar, request)
  if type(request) == "string" then return ReferenceLinks.extract_paths(request) end
  local bufnr = get_input_bufnr(sidebar)
  if not bufnr then return {} end
  return ReferenceLinks.extract_paths_from_buffer(bufnr)
end

function M:get_selected_filepaths_mode() return "links_only" end

function M:add_file(sidebar, filepath) append_paths(sidebar, { filepath }) end

function M:remove_file(sidebar, filepath) remove_paths(sidebar, { filepath }) end

function M:add_current_buffer(sidebar)
  local current_buf = api.nvim_get_current_buf()
  local filepath = api.nvim_buf_get_name(current_buf)
  if filepath and filepath ~= "" then
    self:add_file(sidebar, filepath)
    return true
  end
  return false
end

function M:add_buffer_files(sidebar)
  local paths = {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted then
      local filepath = api.nvim_buf_get_name(bufnr)
      if filepath ~= "" then table.insert(paths, filepath) end
    end
  end
  append_paths(sidebar, paths)
end

function M:add_quickfix_files(sidebar)
  local paths = vim
    .iter(vim.fn.getqflist({ items = 0 }).items)
    :filter(function(item) return item.bufnr ~= 0 end)
    :map(function(item) return api.nvim_buf_get_name(item.bufnr) end)
    :filter(function(path) return path and path ~= "" end)
    :totable()
  append_paths(sidebar, paths)
end

function M:get_height() return 0 end

function M:adjust_layout() end

function M:create_container() end

function M:close_hint() end

function M:show_hint() end

function M:configure_input_buffer(sidebar)
  SidebarInput.configure_input_buffer(sidebar)

  local bufnr = get_input_bufnr(sidebar)
  if bufnr and Config.input.enable_markdown then render_markdown(bufnr) end
end

function M:on_input_changed(sidebar)
  local bufnr = get_input_bufnr(sidebar)
  if not bufnr then return end
  if Config.input.enable_markdown then
    FileRefs.highlight_file_references(bufnr)
    render_markdown(bufnr)
  end
end

return M
