describe("Sidebar V2", function()
  local original_sidebar
  local original_core
  local original_inline
  local original_pane
  local original_sidebar_v2

  before_each(function()
    original_sidebar = package.loaded["avante.sidebar"]
    original_core = package.preload["avante.sidebar.core"]
    original_inline = package.preload["avante.sidebar.components.file_context_inline"]
    original_pane = package.preload["avante.sidebar.components.file_context_pane"]
    original_sidebar_v2 = require("avante.config").experimental.sidebar_v2

    package.loaded["avante.sidebar"] = nil
    package.preload["avante.sidebar.core"] = function()
      return {
        create = function(file_context)
          return {
            file_context = file_context,
            add_selected_file = function() end,
            remove_selected_file = function() end,
            add_buffer_files = function() end,
            add_quickfix_files = function() end,
            add_current_buffer_file = function() end,
            get_selected_files_container_height = function(self)
              if not self.file_context or not self.file_context.get_height then return 0 end
              return self.file_context:get_height(self)
            end,
          }
        end,
      }
    end
    package.preload["avante.sidebar.components.file_context_inline"] = function()
      return {
        id = "inline",
        get_height = function() return 0 end,
      }
    end
    package.preload["avante.sidebar.components.file_context_pane"] = function()
      return {
        id = "pane",
        get_height = function() return 1 end,
      }
    end
  end)

  after_each(function()
    package.loaded["avante.sidebar"] = original_sidebar
    package.preload["avante.sidebar.core"] = original_core
    package.preload["avante.sidebar.components.file_context_inline"] = original_inline
    package.preload["avante.sidebar.components.file_context_pane"] = original_pane
    require("avante.config").experimental.sidebar_v2 = original_sidebar_v2
  end)

  it("should expose the shared file-context API", function()
    require("avante.config").experimental.sidebar_v2 = true
    local SidebarV2 = require("avante.sidebar").get_sidebar_class()
    assert.is_function(SidebarV2.add_selected_file)
    assert.is_function(SidebarV2.remove_selected_file)
    assert.is_function(SidebarV2.add_buffer_files)
    assert.is_function(SidebarV2.add_quickfix_files)
    assert.is_function(SidebarV2.add_current_buffer_file)
    assert.equals("inline", SidebarV2.file_context.id)
  end)

  it("should not allocate selected files container height", function()
    require("avante.config").experimental.sidebar_v2 = true
    local SidebarV2 = require("avante.sidebar").get_sidebar_class()
    local height = SidebarV2.get_selected_files_container_height({})
    assert.equals(0, height)
  end)
end)
