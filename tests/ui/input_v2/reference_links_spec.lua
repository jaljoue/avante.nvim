local ReferenceLinks = require("avante.input.reference_links")

describe("ReferenceLinks", function()
  it("should create markdown link from a path", function()
    local abs = vim.fs.normalize(vim.fn.getcwd() .. "/lua/avante/init.lua")
    local md = ReferenceLinks.to_markdown_link(abs)

    assert.is_true(md:find("%[lua/avante/init.lua%]", 1, false) ~= nil)
    assert.is_true(md:find("(file://", 1, true) ~= nil)
  end)

  it("should extract unique paths from markdown links", function()
    local path = vim.fs.normalize(vim.fn.getcwd() .. "/lua/avante/init.lua")
    local content = string.format("See [init](file://%s) and [init2](file://%s)", path, path)
    local refs = ReferenceLinks.extract_paths(content)

    assert.equals(1, #refs)
    assert.equals(path, refs[1])
  end)

  it("should append and remove links in buffers", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local path = vim.fs.normalize(vim.fn.getcwd() .. "/lua/avante/init.lua")

    ReferenceLinks.append_paths_to_buffer(bufnr, { path })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_true(#lines >= 1)
    assert.is_true(table.concat(lines, "\n"):find("file://" .. path, 1, true) ~= nil)

    ReferenceLinks.remove_paths_from_buffer(bufnr, { path })
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_false(table.concat(lines, "\n"):find("file://" .. path, 1, true) ~= nil)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
