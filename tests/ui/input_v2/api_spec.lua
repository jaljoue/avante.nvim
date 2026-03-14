local Api = require("avante.api")

describe("API compatibility for sidebar v2", function()
  local original_avante

  before_each(function()
    original_avante = package.loaded["avante"]
  end)

  after_each(function()
    package.loaded["avante"] = original_avante
  end)

  it("should route add_selected_file to inline reference method when available", function()
    local called
    local sidebar = {
      is_open = function() return true end,
      add_selected_file_reference = function(_, path)
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

  it("should route add_buffer_files to inline reference method when available", function()
    local called = false
    local sidebar = {
      is_open = function() return true end,
      add_buffer_file_references = function()
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
