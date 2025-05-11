local M = {}

-- Normalizes path slashes (both / and \ to a single /)
function M.normalize_slashes(path)
  if not path then return nil end
  return path:gsub("[/\\]+", "/")
end

function M.url_decode(str)
  if not str then return nil end
  str = str:gsub("+", " ") -- '+' to space first
  str = str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return str
end

function M.get_os_type()
  local uname = vim.loop.os_uname()
  if uname then
    if uname.sysname == "Windows_NT" then return "windows"
    elseif uname.sysname == "Darwin" then return "mac"
    elseif uname.sysname == "Linux" then return "linux"
    elseif uname.sysname:match("BSD$") then return "linux" -- Treat BSD variants as 'linux' for this plugin's purpose
    end
  end
  -- Fallback to vim.fn.has if os_uname is not conclusive or available
  if vim.fn.has("win32") or vim.fn.has("win64") then return "windows"
  elseif vim.fn.has("macunix") then return "mac"
  elseif vim.fn.has("unix") then return "linux"
  end
  return "unknown"
end

function M.expand_shell_vars_in_path(path_str)
  if path_str == nil then return nil, "Path string is nil" end
  return vim.fn.expand(path_str)
end

function M.extract_filename_stem(filepath)
  if not filepath then return "" end
  local basename = filepath:match("([^/\\]+)%..*$") or filepath:match("([^/\\]+)$")
  return basename or ""
end

return M