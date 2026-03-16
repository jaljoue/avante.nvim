local Api = require("avante.api")

describe("API compatibility for sidebar v2", function()
  local original_avante

  before_each(function()
    original_avante = package.loaded["avante"]
  end)

  after_each(function()
    package.loaded["avante"] = original_avante
  end)

  it("should route add_selected_file to the shared sidebar method", function()
    local called
    local sidebar = {
      is_open = function() return true end,
      add_selected_file = function(_, path)
        called = path
      end,
    }

    package.loaded["avante"] = {
      get = function() return sidebar end,
      api = true,
    }

    Api.add_selected_file("lua/avante/init.lua")

    assert.equals("lua/avante/init.lua", called)
  end)

  it("should route add_buffer_files to the shared sidebar method", function()
    local called = false
    local sidebar = {
      is_open = function() return true end,
      add_buffer_files = function()
        called = true
      end,
    }

    package.loaded["avante"] = {
      get = function() return sidebar end,
      api = true,
    }

    Api.add_buffer_files()

    assert.is_true(called)
  end)
end)
