local SidebarFactory = require("avante.sidebar_factory")

describe("SidebarFactory", function()
  local original_sidebar_preload
  local original_sidebar_v2_preload

  before_each(function()
    original_sidebar_preload = package.preload["avante.sidebar"]
    original_sidebar_v2_preload = package.preload["avante.sidebar_v2"]
    package.loaded["avante.sidebar"] = nil
    package.loaded["avante.sidebar_v2"] = nil
    package.preload["avante.sidebar"] = function() return { name = "v1" } end
    package.preload["avante.sidebar_v2"] = function() return { name = "v2" } end
  end)

  after_each(function()
    package.preload["avante.sidebar"] = original_sidebar_preload
    package.preload["avante.sidebar_v2"] = original_sidebar_v2_preload
    package.loaded["avante.sidebar"] = nil
    package.loaded["avante.sidebar_v2"] = nil
  end)

  it("should return sidebar v1 by default", function()
    local Config = require("avante.config")
    local original = Config.experimental.sidebar_v2
    Config.experimental.sidebar_v2 = false

    local Sidebar = SidebarFactory.get_sidebar_class()
    assert.equals("v1", Sidebar.name)

    Config.experimental.sidebar_v2 = original
  end)

  it("should return sidebar v2 when enabled", function()
    local Config = require("avante.config")
    local original = Config.experimental.sidebar_v2
    Config.experimental.sidebar_v2 = true

    local Sidebar = SidebarFactory.get_sidebar_class()
    assert.equals("v2", Sidebar.name)

    Config.experimental.sidebar_v2 = original
  end)
end)
