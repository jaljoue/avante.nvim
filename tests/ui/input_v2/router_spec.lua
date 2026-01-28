local InputRouter = require("avante.input")

describe("Input Router", function()
  describe("module structure", function()
    it("should export get_input function", function()
      assert.is_function(InputRouter.get_input)
    end)

    it("should export new function", function()
      assert.is_function(InputRouter.new)
    end)

    it("should export get_sidebar_input function", function()
      assert.is_function(InputRouter.get_sidebar_input)
    end)
  end)

  describe("configuration integration", function()
    it("should respect enable_markdown configuration", function()
      -- Store original config
      local Config = require("avante.config")
      local original_value = Config.input.enable_markdown

      -- Test with markdown enabled
      Config.input.enable_markdown = true
      local InputWithMd = InputRouter.get_input()
      assert.is_not_nil(InputWithMd)

      -- Test with markdown disabled
      Config.input.enable_markdown = false
      local InputWithoutMd = InputRouter.get_input()
      assert.is_not_nil(InputWithoutMd)

      -- Restore original config
      Config.input.enable_markdown = original_value
    end)
  end)

  describe("input instance creation", function()
    it("should create input with callbacks", function()
      local submit_called = false
      local cancel_called = false

      local input = InputRouter.new({
        submit_callback = function(input_text)
          submit_called = true
          assert.is_string(input_text)
        end,
        cancel_callback = function()
          cancel_called = true
        end,
        start_insert = true,
        close_on_submit = false,
      })

      assert.is_not_nil(input)
      assert.is_function(input.submit_callback)
      assert.is_function(input.cancel_callback)
      assert.is_true(input.start_insert)
      assert.is_false(input.close_on_submit)
    end)

    it("should create input with default options", function()
      local input = InputRouter.new()

      assert.is_not_nil(input)
      assert.is_false(input.start_insert)
      assert.is_false(input.close_on_submit)
    end)
  end)

  describe("get_sidebar_input", function()
    it("should return the sidebar input module", function()
      local sidebar_input = InputRouter.get_sidebar_input()
      assert.is_not_nil(sidebar_input)
      assert.is_table(sidebar_input)
      assert.is_function(sidebar_input.setup_markdown)
      assert.is_function(sidebar_input.get_container_options)
    end)
  end)
end)
