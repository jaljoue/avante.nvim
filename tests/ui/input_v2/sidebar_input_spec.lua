local SidebarInput = require("avante.input.sidebar")

describe("SidebarInput", function()
  describe("module structure", function()
    it("should export setup_markdown function", function()
      assert.is_function(SidebarInput.setup_markdown)
    end)

    it("should export get_container_options function", function()
      assert.is_function(SidebarInput.get_container_options)
    end)

    it("should export configure_input_buffer function", function()
      assert.is_function(SidebarInput.configure_input_buffer)
    end)

    it("should export setup_autocmds function", function()
      assert.is_function(SidebarInput.setup_autocmds)
    end)

    it("should export get_size function", function()
      assert.is_function(SidebarInput.get_size)
    end)

    it("should export get_position function", function()
      assert.is_function(SidebarInput.get_position)
    end)
  end)

  describe("setup_markdown", function()
    it("should not error with invalid buffer", function()
      assert.has_no.errors(function()
        SidebarInput.setup_markdown(nil)
        SidebarInput.setup_markdown(-1)
      end)
    end)

    it("should setup markdown on valid buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      
      assert.has_no.errors(function()
        SidebarInput.setup_markdown(bufnr)
      end)

      -- Check that buffer variables were set
      assert.is_true(vim.b[bufnr].avante_markdown_enabled)
      assert.is_table(vim.b[bufnr].render_markdown_config)
      assert.is_true(vim.b[bufnr].render_markdown_config.enabled)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("get_container_options", function()
    it("should return win_options and buf_options", function()
      -- Mock sidebar object
      local sidebar = {}
      
      local win_opts, buf_opts = SidebarInput.get_container_options(sidebar)
      
      assert.is_table(win_opts)
      assert.is_table(buf_opts)
      
      -- Check expected win_options
      assert.is_false(win_opts.number)
      assert.is_false(win_opts.relativenumber)
      assert.is_false(win_opts.foldenable)
      assert.equals("0", win_opts.foldcolumn)
      assert.is_true(win_opts.cursorline)
      
      -- Check expected buf_options
      assert.is_false(buf_opts.swapfile)
      assert.equals("nofile", buf_opts.buftype)
    end)
  end)

  describe("configure_input_buffer", function()
    it("should not error with invalid buffer", function()
      -- Mock sidebar with invalid container
      local sidebar = {
        containers = { input = { bufnr = nil } }
      }
      
      assert.has_no.errors(function()
        SidebarInput.configure_input_buffer(sidebar)
      end)
    end)

    it("should set filetype on valid buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local sidebar = {
        containers = { input = { bufnr = bufnr } }
      }
      
      SidebarInput.configure_input_buffer(sidebar)
      
      local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
      assert.equals("AvanteInput", filetype)
      
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("get_position", function()
    it("should return bottom for vertical layout", function()
      local sidebar = {
        get_layout = function() return "vertical" end
      }
      
      local position = SidebarInput.get_position(sidebar)
      assert.equals("bottom", position)
    end)

    it("should return right for horizontal layout", function()
      local sidebar = {
        get_layout = function() return "horizontal" end
      }
      
      local position = SidebarInput.get_position(sidebar)
      assert.equals("right", position)
    end)
  end)

  describe("get_size", function()
    it("should return height for vertical layout", function()
      local Config = require("avante.config")
      local sidebar = {
        get_layout = function() return "vertical" end
      }
      
      local size = SidebarInput.get_size(sidebar)
      
      assert.is_table(size)
      assert.equals(Config.windows.input.height, size.height)
      assert.is_nil(size.width)
    end)

    it("should return width and height for horizontal layout", function()
      local sidebar = {
        get_layout = function() return "horizontal" end,
        containers = {
          result = { winid = vim.api.nvim_get_current_win() }
        },
        get_selected_code_container_height = function() return 5 end
      }
      
      local size = SidebarInput.get_size(sidebar)
      
      assert.is_table(size)
      assert.equals("40%", size.width)
      assert.is_number(size.height)
      assert.is_true(size.height > 0)
    end)
  end)
end)
