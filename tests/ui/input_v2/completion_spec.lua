local Completion = require("avante.input.completion")

describe("Input Completion", function()
  it("should find @ token boundaries", function()
    local start, prefix = Completion.find_at_token("Please check @lua/av")
    assert.is_number(start)
    assert.equals("lua/av", prefix)
  end)

  it("should return markdown-link insert text for files", function()
    local items = Completion.get_at_completions("lua/avante/input/completion")
    assert.is_true(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "lua/avante/input/completion.lua" then
        found = true
        assert.is_true(item.insertText:find("%[lua/avante/input/completion.lua%]", 1, false) ~= nil)
        assert.is_true(item.insertText:find("(file://", 1, true) ~= nil)
        break
      end
    end

    assert.is_true(found)
  end)

  it("should include directory entries", function()
    local items = Completion.get_at_completions("lua/avante/input")
    local has_dir = false
    for _, item in ipairs(items) do
      if item.kind == "Folder" then
        has_dir = true
        assert.is_true(item.insertText:find("(file://", 1, true) ~= nil)
        break
      end
    end
    assert.is_true(has_dir)
  end)
end)
