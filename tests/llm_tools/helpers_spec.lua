local LlmToolHelpers = require("avante.llm_tools.helpers")
local Utils = require("avante.utils")
local Config = require("avante.config")
local stub = require("luassert.stub")

describe("has_permission_to_access", function()
  local test_dir = "/tmp/test_llm_tools_helpers"

  before_each(function()
    os.execute("mkdir -p " .. test_dir)
    -- create .gitignore file with test.idx file
    os.execute("rm " .. test_dir .. "/.gitignore 2>/dev/null")
    local gitignore_file = io.open(test_dir .. "/.gitignore", "w")
    if gitignore_file then
      gitignore_file:write("test.txt\n")
      gitignore_file:write("data\n")
      gitignore_file:close()
    end
    stub(Utils, "get_project_root", function() return test_dir end)
  end)

  after_each(function() os.execute("rm -rf " .. test_dir) end)

  it("Basic ignored and not ignored", function()
    local abs_path
    abs_path = test_dir .. "/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/test1.txt"
    assert.is_true(LlmToolHelpers.has_permission_to_access(abs_path))
  end)

  it("Ignore files inside directories", function()
    local abs_path
    abs_path = test_dir .. "/data/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/data/test1.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))
  end)

  it("Do not ignore files with just similar paths", function()
    local abs_path
    abs_path = test_dir .. "/data_test/test.txt"
    assert.is_false(LlmToolHelpers.has_permission_to_access(abs_path))

    abs_path = test_dir .. "/data_test/test1.txt"
    assert.is_true(LlmToolHelpers.has_permission_to_access(abs_path))
  end)
end)

describe("confirm", function()
  local original_avante_module

  before_each(function()
    Config.setup()
    original_avante_module = package.loaded["avante"]
  end)

  after_each(function() package.loaded["avante"] = original_avante_module end)

  it("auto-approves non-edit tools when global auto-approve is enabled", function()
    Config.behaviour.auto_approve_tool_permissions = true
    Config.behaviour.enable_fastapply = false

    local approved = nil
    LlmToolHelpers.confirm("confirm read", function(ok) approved = ok end, nil, {}, "read")

    vim.wait(100, function() return approved ~= nil end)
    assert.is_true(approved)
  end)

  it("requires explicit confirmation for edit/diff when fastapply is disabled", function()
    Config.behaviour.auto_approve_tool_permissions = true
    Config.behaviour.enable_fastapply = false
    Config.behaviour.confirmation_ui_style = "inline_buttons"

    local sidebar = {
      scroll = false,
      permission_button_options = nil,
      permission_handler = nil,
      _history_cache_invalidated = false,
      update_content = function() end,
    }
    package.loaded["avante"] = {
      get = function() return sidebar end,
    }

    local approved = nil
    LlmToolHelpers.confirm("confirm edit", function(ok) approved = ok end, nil, {}, "replace_in_file")

    assert.is_nil(approved)
    assert.is_not_nil(sidebar.permission_handler)

    sidebar.permission_handler("allow_once")

    vim.wait(100, function() return approved ~= nil end)
    assert.is_true(approved)
  end)

  it("allows explicit per-tool auto-approval for edit/diff", function()
    Config.behaviour.auto_approve_tool_permissions = { "replace_in_file" }
    Config.behaviour.enable_fastapply = false

    local approved = nil
    LlmToolHelpers.confirm("confirm edit", function(ok) approved = ok end, nil, {}, "replace_in_file")

    vim.wait(100, function() return approved ~= nil end)
    assert.is_true(approved)
  end)
end)
