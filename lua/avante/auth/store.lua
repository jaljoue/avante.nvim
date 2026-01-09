local Utils = require("avante.utils")
local Path = require("plenary.path")

local M = {}

local auth_path = vim.fn.stdpath("data") .. "/avante/auth.json"
local legacy_claude_path = vim.fn.stdpath("data") .. "/avante/claude-auth.json"
local lockfile_path = vim.fn.stdpath("data") .. "/avante/auth.lock"

local callbacks = {}

local function is_process_running(pid)
  local result = vim.uv.kill(pid, 0)
  if result ~= nil and result == 0 then
    return true
  else
    return false
  end
end

local function try_acquire_lock()
  local lockfile = Path:new(lockfile_path)
  local tmp_lockfile = lockfile_path .. ".tmp." .. vim.fn.getpid()

  Path:new(tmp_lockfile):write(tostring(vim.fn.getpid()), "w")

  if lockfile:exists() then
    local content = lockfile:read()
    local pid = tonumber(content)
    if pid and is_process_running(pid) then
      os.remove(tmp_lockfile)
      return false
    end
  end

  local success = os.rename(tmp_lockfile, lockfile_path)
  if not success then
    os.remove(tmp_lockfile)
    return false
  end

  return true
end

local function release_lock()
  local lockfile = Path:new(lockfile_path)
  if lockfile:exists() then
    local content = lockfile:read()
    local pid = tonumber(content)
    if pid and pid == vim.fn.getpid() then lockfile:rm() end
  end
end

local function ensure_parent_dir()
  local parent = Path:new(auth_path):parent()
  if not parent:exists() then parent:mkdir({ parents = true }) end
end

local function safe_decode(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if ok and type(data) == "table" then return data end
  return nil
end

local function write_json(data)
  ensure_parent_dir()

  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    Utils.error("Failed to encode auth data: " .. tostring(json_str), { once = true, title = "Avante" })
    return false
  end

  local tmp_path = auth_path .. ".tmp." .. vim.fn.getpid()
  local file, open_err = io.open(tmp_path, "w")
  if not file then
    Utils.error("Failed to save auth file: " .. tostring(open_err), { once = true, title = "Avante" })
    return false
  end

  local write_ok, write_err = pcall(file.write, file, json_str)
  file:close()

  if not write_ok then
    Utils.error("Failed to write auth file: " .. tostring(write_err), { once = true, title = "Avante" })
    return false
  end

  local rename_ok = os.rename(tmp_path, auth_path)
  if not rename_ok then
    Utils.error("Failed to replace auth file", { once = true, title = "Avante" })
    return false
  end

  if vim.fn.has("unix") == 1 then
    local chmod_ok = vim.loop.fs_chmod(auth_path, 384)
    if not chmod_ok then Utils.warn("Failed to set auth file permissions", { once = true, title = "Avante" }) end
  end

  return true
end

local function with_lock(fn, attempts)
  attempts = attempts or 0
  if try_acquire_lock() then
    local ok, result = pcall(fn)
    release_lock()
    if not ok then
      Utils.warn("Failed to update auth file: " .. tostring(result), { once = true, title = "Avante" })
      return nil
    end
    return result
  end

  if attempts < 5 then
    vim.defer_fn(function()
      with_lock(fn, attempts + 1)
    end, 50)
  end
end

function M.path() return auth_path end

function M.read()
  local auth_file = Path:new(auth_path)
  if auth_file:exists() then
    local data = safe_decode(auth_file:read())
    if data then
      local legacy = Path:new(legacy_claude_path)
      if legacy:exists() then pcall(legacy.rm, legacy) end
      return data
    end

    Utils.warn("Auth file is corrupted, re-authentication required", { once = true, title = "Avante" })
    pcall(auth_file.rm, auth_file)
    return nil
  end

  local legacy = Path:new(legacy_claude_path)
  if legacy:exists() then
    local token = safe_decode(legacy:read())
    if token then
      local data = { claude = token }
      write_json(data)
      pcall(legacy.rm, legacy)
      return data
    end

    Utils.warn("Claude auth file is corrupted, re-authentication required", { once = true, title = "Avante" })
    pcall(legacy.rm, legacy)
  end

  return nil
end

function M.write_all(data)
  data = data or {}
  return with_lock(function()
    return write_json(data)
  end)
end

function M.update(provider, token)
  return with_lock(function()
    local data = M.read() or {}
    data[provider] = token
    return write_json(data)
  end)
end

function M.watch(callback)
  if type(callback) == "function" then table.insert(callbacks, callback) end

  if M._watcher then return end

  local auth_file = Path:new(auth_path)
  if not auth_file:exists() then M.write_all({}) end

  M._watcher = vim.uv.new_fs_event()
  M._watcher:start(
    auth_path,
    {},
    vim.schedule_wrap(function()
      local data = M.read()
      for _, cb in ipairs(callbacks) do
        cb(data)
      end
    end)
  )
end

function M.cleanup()
  if M._watcher then
    ---@diagnostic disable-next-line: param-type-mismatch
    M._watcher:stop()
    M._watcher = nil
  end
end

return M
