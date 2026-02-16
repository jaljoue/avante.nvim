local FileRefs = require("avante.input.file_refs")
local Utils = require("avante.utils")

describe("FileRefs", function()
  describe("parse_file_references", function()
    it("should parse @file: syntax", function()
      local content = "Check @file:src/main.lua for the implementation"
      local refs = Utils.parse_file_references(content)

      assert.equals(1, #refs)
      assert.equals("file", refs[1].type)
      assert.equals("file://src/main.lua", refs[1].uri)
      assert.equals("src/main.lua", refs[1].path)
    end)

    it("should parse @dir: syntax", function()
      local content = "Look in @dir:src/utils for helper functions"
      local refs = Utils.parse_file_references(content)

      assert.equals(1, #refs)
      assert.equals("directory", refs[1].type)
      assert.equals("file://src/utils", refs[1].uri)
      assert.equals("src/utils", refs[1].path)
    end)

    it("should parse markdown file links", function()
      local content = "See [Main File](file:///home/user/project/src/main.lua) for details"
      local refs = Utils.parse_file_references(content)

      assert.equals(1, #refs)
      assert.equals("file", refs[1].type)
      assert.equals("file:///home/user/project/src/main.lua", refs[1].uri)
      assert.equals("/home/user/project/src/main.lua", refs[1].path)
      assert.equals("Main File", refs[1].display_name)
    end)

    it("should parse multiple references in one content", function()
      local content = [[
Check @file:src/main.lua and @dir:src/utils
Also see [Config](file:///home/user/.config/file.toml)
      ]]
      local refs = Utils.parse_file_references(content)

      assert.equals(3, #refs)
      assert.equals("file", refs[1].type)
      assert.equals("directory", refs[2].type)
      assert.equals("file", refs[3].type)
    end)

    it("should return empty table for no references", function()
      local content = "This is just plain text without any references"
      local refs = Utils.parse_file_references(content)

      assert.equals(0, #refs)
    end)
  end)

  describe("validate_file_uri", function()
    it("should validate existing file", function()
      -- Create a temporary file
      local tmpfile = vim.fn.tempname()
      local f = io.open(tmpfile, "w")
      if f then
        f:write("test content")
        f:close()
      end

      local uri = "file://" .. tmpfile
      local valid, err = Utils.validate_file_uri(uri)

      assert.is_true(valid)
      assert.is_nil(err)

      -- Cleanup
      os.remove(tmpfile)
    end)

    it("should return error for non-existent file", function()
      local uri = "file:///non/existent/path/file.txt"
      local valid, err = Utils.validate_file_uri(uri)

      assert.is_false(valid)
      assert.is_not_nil(err)
      assert.is_true(err:match("not found") ~= nil)
    end)

    it("should validate directory", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")

      local uri = "file://" .. tmpdir
      local valid, err = Utils.validate_file_uri(uri)

      assert.is_true(valid)
      assert.is_nil(err)

      -- Cleanup
      vim.fn.delete(tmpdir, "rf")
    end)
  end)

  describe("module functions", function()
    it("should export clear_extmarks function", function()
      assert.is_function(FileRefs.clear_extmarks)
    end)

    it("should export add_file_ref_extmark function", function()
      assert.is_function(FileRefs.add_file_ref_extmark)
    end)

    it("should export highlight_file_references function", function()
      assert.is_function(FileRefs.highlight_file_references)
    end)

    it("should export get_ref_at_cursor function", function()
      assert.is_function(FileRefs.get_ref_at_cursor)
    end)

    it("should export setup_highlight_autocmd function", function()
      assert.is_function(FileRefs.setup_highlight_autocmd)
    end)

    it("should have a namespace id", function()
      assert.is_number(FileRefs.ns_id)
    end)
  end)

  describe("highlight_file_references", function()
    it("should not error with invalid buffer", function()
      assert.has_no.errors(function()
        FileRefs.highlight_file_references(nil)
        FileRefs.highlight_file_references(-1)
      end)
    end)

    it("should highlight references in buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "Check @file:src/main.lua for details",
        "Look in @dir:src/utils for more",
      })

      assert.has_no.errors(function()
        FileRefs.highlight_file_references(bufnr)
      end)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("get_ref_at_cursor", function()
    it("should find @file: reference at cursor", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "Check @file:src/main.lua for details",
      })

      -- Cursor at position 7 (on @file:)
      local ref = FileRefs.get_ref_at_cursor(bufnr, 0, 7)

      assert.is_not_nil(ref)
      assert.equals("file", ref.type)
      assert.equals("src/main.lua", ref.path)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("should return nil when cursor not on reference", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "Check this line without references",
      })

      local ref = FileRefs.get_ref_at_cursor(bufnr, 0, 5)

      assert.is_nil(ref)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
