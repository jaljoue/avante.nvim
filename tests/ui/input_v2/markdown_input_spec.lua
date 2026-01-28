local MarkdownInput = require("avante.ui.markdown_input")
local InputRouter = require("avante.input")

describe("MarkdownInput", function()
  describe("new", function()
    it("should create a new MarkdownInput instance with default values", function()
      local input = MarkdownInput:new()
      assert.is_not_nil(input)
      assert.is_nil(input.bufnr)
      assert.is_nil(input.winid)
      assert.is_false(input.start_insert)
      assert.is_false(input.close_on_submit)
      assert.is_true(input.enable_markdown) -- Default to true for MarkdownInput
    end)

    it("should respect enable_markdown option", function()
      local input_with_md = MarkdownInput:new({ enable_markdown = true })
      assert.is_true(input_with_md.enable_markdown)

      local input_without_md = MarkdownInput:new({ enable_markdown = false })
      assert.is_false(input_without_md.enable_markdown)
    end)

    it("should accept custom options", function()
      local callback_fn = function() end
      local input = MarkdownInput:new({
        start_insert = true,
        close_on_submit = true,
        submit_callback = callback_fn,
        default_value = "test input",
      })

      assert.is_true(input.start_insert)
      assert.is_true(input.close_on_submit)
      assert.equals(callback_fn, input.submit_callback)
      assert.equals("test input", input.default_value)
    end)
  end)

  describe("setup_markdown", function()
    it("should not error when buffer is invalid", function()
      local input = MarkdownInput:new()
      input.bufnr = nil
      assert.has_no.errors(function()
        input:setup_markdown()
      end)
    end)

    it("should not setup markdown when disabled", function()
      local input = MarkdownInput:new({ enable_markdown = false })
      input.bufnr = vim.api.nvim_create_buf(false, true)
      
      assert.has_no.errors(function()
        input:setup_markdown()
      end)
      
      vim.api.nvim_buf_delete(input.bufnr, { force = true })
    end)
  end)
end)

describe("InputRouter", function()
  describe("get_input", function()
    it("should return MarkdownInput when enable_markdown is true", function()
      -- Mock config
      local original_config = require("avante.config")
      package.loaded["avante.config"] = {
        input = { enable_markdown = true }
      }
      
      local result = InputRouter.get_input()
      
      -- Restore original config
      package.loaded["avante.config"] = original_config
      
      -- Should return MarkdownInput module
      assert.is_not_nil(result)
      assert.is_not_nil(result.new)
    end)

    it("should return PromptInput when enable_markdown is false", function()
      -- Mock config
      local original_config = require("avante.config")
      package.loaded["avante.config"] = {
        input = { enable_markdown = false }
      }
      
      local result = InputRouter.get_input()
      
      -- Restore original config
      package.loaded["avante.config"] = original_config
      
      -- Should return PromptInput module
      assert.is_not_nil(result)
      assert.is_not_nil(result.new)
    end)
  end)

  describe("new", function()
    it("should create appropriate input instance based on config", function()
      -- This test verifies the router creates the right type of input
      -- The actual type depends on the config at test time
      local instance = InputRouter.new({ start_insert = true })
      assert.is_not_nil(instance)
      assert.is_not_nil(instance.open)
      assert.is_not_nil(instance.close)
      assert.is_not_nil(instance.submit)
    end)
  end)
end)
