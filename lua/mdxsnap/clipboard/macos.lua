local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

-- Helper function to get file path using AppleScript file URL methods
local function get_file_path_via_applescript()
  local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/applescript/get_file_url_from_clipboard.applescript"
  
  local is_ok, file_result = pcall(vim.fn.system, "osascript '" .. script_path .. "'")
  if is_ok and vim.v.shell_error == 0 and file_result and not file_result:match("^error:") then
    return file_result:gsub("[\r\n]", "")
  end
  return nil
end

-- Helper function to process pbpaste result and attempt various methods
local function process_pbpaste_result(pbpaste_result)
  if not pbpaste_result or pbpaste_result == "" then return nil end
  
  local expanded_path, _ = utils.expand_shell_vars_in_path(pbpaste_result)
  if not expanded_path then return nil end
  
  -- Try direct file path validation first
  local validated_path = clipboard_utils.validate_image_path(expanded_path)
  if validated_path then
    return validated_path
  end
  
  -- If pbpaste result is just a filename (no slashes) and not readable,
  -- try to get full path using AppleScript
  if not expanded_path:match("/") then
    local applescript_path = get_file_path_via_applescript()
    if applescript_path then
      return clipboard_utils.validate_image_path(applescript_path)
    end
  end
  
  return nil
end

local function save_clipboard_image(target_path_base)
  local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/applescript/save_image_from_clipboard.applescript"
  local is_ok, result = pcall(vim.fn.system, "osascript '" .. script_path .. "' '" .. target_path_base .. "'")

  if not is_ok or vim.v.shell_error ~= 0 then
    return nil, "osascript execution failed: " .. tostring(result)
  end

  local trimmed = (result or ""):gsub("[\r\n]", "")
  if trimmed == "" then
    return nil, "AppleScript returned empty result"
  end

  if trimmed:match("^error") then
    return nil, "AppleScript reported error: " .. trimmed
  end

  return utils.normalize_slashes(trimmed), nil

end

function M.fetch_image_path_from_clipboard_macos()
  -- Attempt 1: Use pbpaste to get a potential file path
  local paste_cmd = "pbpaste"
  local paste_handle = io.popen(paste_cmd)
  
  if paste_handle then
    local paste_result = paste_handle:read("*a")
    paste_handle:close()
    paste_result = paste_result:gsub("[\r\n]", "")
    
    local image_path = process_pbpaste_result(paste_result)
    if image_path then
      return image_path, false, nil -- path, is_temporary=false, error_message
    end
  end

  -- Attempt 2: AppleScript (ObjC bridge) to get raw image data and save with original type
  local tmp_dir = fs_utils.get_tmp_dir()
  if not tmp_dir then return nil, false, "Could not get/create mdxsnap temp directory." end

  local timestamp = tostring(vim.loop.now())
  local target_base = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp)

  local saved_path, save_err = save_clipboard_image(target_base)
  if not saved_path then
    return nil, false, save_err or "Failed to save clipboard image via AppleScript."
  end

  if vim.fn.filereadable(saved_path) == 0 or vim.fn.getfsize(saved_path) == 0 then
    fs_utils.cleanup_tmp_file(saved_path)
    return nil, false, "Image file was not created or is empty after AppleScript save"
  end

  return saved_path, true, nil
end

return M
