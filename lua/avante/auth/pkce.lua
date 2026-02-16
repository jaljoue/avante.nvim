local M = {}

---Return OS name when possible (e.g. "Darwin", "Linux").
---@return string|nil
local function get_os_name()
  local uname = vim.uv.os_uname()
  if uname and uname.sysname then return uname.sysname end

  if type(jit) == "table" and jit.os then return jit.os end

  return nil
end

local function is_macos()
  local os_name = get_os_name()
  return os_name == "Darwin" or os_name == "OSX"
end

local function load_commoncrypto(ffi)
  local candidates = { "CommonCrypto", "/usr/lib/system/libcommonCrypto.dylib" }
  for _, path in ipairs(candidates) do
    local ok2, lib2 = pcall(ffi.load, path)
    if ok2 then return lib2, nil end
  end

  return nil, "Failed to load CommonCrypto"
end

local function commoncrypto_random_bytes(ffi, n)
  local lib, lib_err = load_commoncrypto(ffi)
  if not lib then return nil, lib_err end

  local cdef_ok = pcall(
    ffi.cdef,
    [[
      typedef int32_t CCRNGStatus;
      CCRNGStatus CCRandomGenerateBytes(void *bytes, size_t count);
    ]]
  )
  if not cdef_ok then
    return nil, "Failed to define CommonCrypto CCRandomGenerateBytes"
  end

  local buf = ffi.new("unsigned char[?]", n)
  if lib.CCRandomGenerateBytes(buf, n) == 0 then
    return ffi.string(buf, n), nil
  end

  return nil, "CommonCrypto CCRandomGenerateBytes failed"
end

local function commoncrypto_sha256(ffi, data)
  local lib, lib_err = load_commoncrypto(ffi)
  if not lib then return nil, lib_err end

  local cdef_ok = pcall(
    ffi.cdef,
    [[
      unsigned char *CC_SHA256(const void *data, size_t len, unsigned char *md);
    ]]
  )
  if not cdef_ok then
    return nil, "Failed to define CommonCrypto CC_SHA256"
  end

  local digest = ffi.new("unsigned char[32]")
  lib.CC_SHA256(data, #data, digest)
  return ffi.string(digest, 32), nil
end

---Load OpenSSL's crypto library.
---@param ffi any
---@return any|nil lib
---@return string|nil error
local function load_openssl_crypto(ffi)
  local lib_ok, lib = pcall(ffi.load, "crypto")
  if lib_ok then return lib, nil end
  return nil, "Failed to load OpenSSL crypto library - please install OpenSSL"
end

---Generates a random N number of bytes using crypto lib over ffi, falling back to urandom
---@param n integer number of bytes to generate
---@return string|nil bytes string of bytes generated, or nil if all methods fail
---@return string|nil error error message if generation failed
local function get_random_bytes(n)
  local ok, ffi = pcall(require, "ffi")
  if ok then
    local commoncrypto_err
    if is_macos() then
      local bytes, cc_err = commoncrypto_random_bytes(ffi, n)
      if bytes then return bytes, nil end
      commoncrypto_err = cc_err
    end

    local lib, lib_err = load_openssl_crypto(ffi)
    if lib then
      local cdef_ok = pcall(
        ffi.cdef,
        [[
        int RAND_bytes(unsigned char *buf, int num);
      ]]
      )
      if cdef_ok then
        local buf = ffi.new("unsigned char[?]", n)
        if lib.RAND_bytes(buf, n) == 1 then return ffi.string(buf, n), nil end
      end
      return nil, "OpenSSL RAND_bytes failed - OpenSSL may not be properly installed"
    end

    return nil, lib_err or commoncrypto_err or "Failed to load OpenSSL crypto library - please install OpenSSL"
  end

  -- Fallback
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(n)
    f:close()
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
  local ok, ffi = pcall(require, "ffi")
  if ok then
    local commoncrypto_err
    if is_macos() then
      local digest, cc_err = commoncrypto_sha256(ffi, verifier)
      if digest then return base64url_encode(digest), nil end
      commoncrypto_err = cc_err
    end

    local lib, lib_err = load_openssl_crypto(ffi)
    if lib then
      local cdef_ok = pcall(
        ffi.cdef,
        [[
        typedef unsigned char SHA256_DIGEST[32];
        void SHA256(const unsigned char *d, size_t n, SHA256_DIGEST md);
      ]]
      )
      if cdef_ok then
        local digest = ffi.new("SHA256_DIGEST")
        lib.SHA256(verifier, #verifier, digest)
        return base64url_encode(ffi.string(digest, 32)), nil
      end
      return nil, "Failed to define SHA256 function - OpenSSL may not be properly configured"
    end

    return nil, lib_err or commoncrypto_err or "Failed to load OpenSSL crypto library - please install OpenSSL"
  end

  return nil, "FFI not available - LuaJIT is required for PKCE authentication"
end

return M
