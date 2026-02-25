local M = {}
local uv = vim.uv

-- Generates sha256 bytes with vim.fn
local function sha256_bytes(data)
  -- vim.fn.sha256 returns hex string (64 chars)
  local hex = vim.fn.sha256(data)
  -- vim.text.hexdecode returns raw bytes
  return vim.text.hexdecode(hex)
end

local function windows_random_bytes(n)
  local ps = [[
    $bytes = New-Object byte[] (]] .. n .. [[);
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes);
    [Convert]::ToBase64String($bytes)
  ]]

  local result = vim.system({ "powershell", "-NoProfile", "-Command", ps }):wait()
  if result.code ~= 0 then
    return nil, result.stderr
  end

  local decoded = vim.base64.decode(vim.trim(result.stdout))
  if not decoded or #decoded ~= n then
    return nil, "failed to decode bytes"
  end

  return decoded, nil
end

---Generates a random N number of bytes using crypto lib over ffi, falling back to urandom
---@param n integer number of bytes to generate
---@return string|nil bytes string of bytes generated, or nil if all methods fail
---@return string|nil error error message if generation failed
local function get_random_bytes(n)
  if type(uv.random) == "function" then
    local ok, err_or_bytes, maybe_bytes = pcall(uv.random, n)
    if ok then
      if type(err_or_bytes) == "string" and maybe_bytes == nil then
        if #err_or_bytes == n then
          return err_or_bytes

        end
      else
        local err = err_or_bytes
        local bytes = maybe_bytes
        if err == 0 and type(bytes) == "string" and #bytes == n then
          return bytes
        end
      end
    end
  end

  -- Fallback
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(n)
    f:close()
    return bytes, nil
  end

  local bytes, err = windows_random_bytes(n)
  if err ~= nil or #bytes ~= n then
    return nil, err or "Failed to generate random bytes using powershell"
  elseif #bytes == n then
    return bytes, nil
  end

  return nil, "FFI not available and /dev/urandom is not accessible - cannot generate secure random bytes"
end

--- URL-safe base64
--- @param data string value to base64 encode
--- @return string base64String base64 encoded string
local function base64url_encode(data)
  local b64 = vim.base64.encode(data)
  local b64_string, _ = b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
  return b64_string
end

-- Generate code_verifier (43-128 characters)
--- @return string|nil verifier String representing pkce verifier or nil if generation fails
--- @return string|nil error error message if generation failed
function M.generate_verifier()
  local bytes, err = get_random_bytes(32) -- 256 bits
  if bytes then return base64url_encode(bytes), nil end

  return nil, err or "Failed to generate random bytes"
end

-- Generate code_challenge (S256 method)
---@return string|nil challenge String representing pkce challenge or nil if generation fails
---@return string|nil error error message if generation failed
function M.generate_challenge(verifier)
  return base64url_encode(sha256_bytes(verifier)), nil
end

return M
