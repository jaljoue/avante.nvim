local busted = require("plenary.busted")

busted.describe("oauth ui", function()
  local OAuthUI

  busted.before_each(function()
    package.loaded["avante.ui.oauth"] = nil
    OAuthUI = require("avante.ui.oauth")
  end)

  busted.it("returns false and notifies when no methods are given", function()
    local notified
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end

    local ok = OAuthUI.select_method({ provider_name = "Test", methods = {} })

    vim.notify = original_notify

    assert.is_false(ok)
    assert.equals(vim.log.levels.ERROR, notified.level)
  end)

  busted.it("runs the only method directly without showing a picker", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function() return { { fake = true } } end

    local original_select = vim.ui.select
    local select_called = false
    vim.ui.select = function() select_called = true end

    local ran_with
    OAuthUI.select_method({
      provider_name = "Test",
      methods = {
        { id = "browser", label = "Test (browser)", run = function(ctx) ran_with = ctx end },
      },
    })

    vim.ui.select = original_select
    vim.api.nvim_list_uis = original_uis

    assert.is_false(select_called)
    assert.equals("Test", ran_with.provider_name)
    assert.is_function(ran_with.close)
  end)

  busted.it("auto-selects the headless method when no UI is attached", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function() return {} end

    local ran_id
    OAuthUI.select_method({
      provider_name = "Test",
      methods = {
        { id = "browser", label = "Test (browser)", run = function() ran_id = "browser" end },
        { id = "headless", label = "Test (headless)", headless = true, run = function() ran_id = "headless" end },
      },
    })

    vim.api.nvim_list_uis = original_uis

    assert.equals("headless", ran_id)
  end)

  busted.it("shows a picker and runs the chosen method", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function() return { { fake = true } } end

    local original_select = vim.ui.select
    local picker
    vim.ui.select = function(items, select_opts, on_choice)
      picker = { prompt = select_opts.prompt, labels = vim.tbl_map(select_opts.format_item, items) }
      on_choice(items[2])
    end

    local ran_id, closed
    local ok = OAuthUI.select_method({
      provider_name = "Test",
      on_close = function() closed = true end,
      methods = {
        { id = "browser", label = "Test (browser)", run = function() ran_id = "browser" end },
        {
          id = "headless",
          label = "Test (headless)",
          run = function(ctx)
            ran_id = "headless"
            ctx.close()
          end,
        },
      },
    })

    vim.ui.select = original_select
    vim.api.nvim_list_uis = original_uis

    assert.is_true(ok)
    assert.equals("Select auth method", picker.prompt)
    assert.same({ "Test (browser)", "Test (headless)" }, picker.labels)
    assert.equals("headless", ran_id)
    assert.is_true(closed)
  end)

  busted.it("calls on_close when the picker is dismissed", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function() return { { fake = true } } end

    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice) on_choice(nil) end

    local closed = false
    OAuthUI.select_method({
      provider_name = "Test",
      on_close = function() closed = true end,
      methods = {
        { id = "browser", label = "Test (browser)", run = function() end },
        { id = "headless", label = "Test (headless)", run = function() end },
      },
    })

    vim.ui.select = original_select
    vim.api.nvim_list_uis = original_uis

    assert.is_true(closed)
  end)
end)
