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

  -- Attempt 2: AppleScript to get raw image data (PNG then TIFF)
  local tmp_dir = fs_utils.get_tmp_dir()
  if not tmp_dir then return nil, "Could not get/create mdxsnap temp directory.", false end

  local timestamp = tostring(vim.loop.now())
  local png_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".png")

  local png_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/applescript/save_png_from_clipboard.applescript"
  
  local is_ok, result = pcall(vim.fn.system, "osascript '" .. png_script .. "' '" .. png_path .. "'")
  if is_ok and vim.v.shell_error == 0 and not result:match("^error:") then
    if vim.fn.filereadable(png_path) == 1 and vim.fn.getfsize(png_path) > 0 then
      return png_path, true, nil
    end
    fs_utils.cleanup_tmp_file(png_path)
  end

  local tiff_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".tiff")
  local tiff_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/applescript/save_tiff_from_clipboard.applescript"
  
  is_ok, result = pcall(vim.fn.system, "osascript '" .. tiff_script .. "' '" .. tiff_path .. "'")
  if not is_ok or vim.v.shell_error ~= 0 or result:match("^error:") then
    fs_utils.cleanup_tmp_file(tiff_path)
    return nil, "Failed to save clipboard image as TIFF (fallback). Error: " .. tostring(result), false
  end

  if vim.fn.filereadable(tiff_path) == 0 then
    return nil, "TIFF file was not created (clipboard might not contain image data)", false
  end

  local sips_cmd = string.format("sips -s format png \"%s\" --out \"%s\"", tiff_path, png_path)
  is_ok, result = pcall(vim.fn.system, sips_cmd)
  fs_utils.cleanup_tmp_file(tiff_path)

  if not is_ok or vim.v.shell_error ~= 0 then
    fs_utils.cleanup_tmp_file(png_path)
    return nil, "Failed to convert TIFF to PNG. Error: " .. tostring(result), false
  end

  if vim.fn.filereadable(png_path) == 0 or vim.fn.getfsize(png_path) == 0 then
    fs_utils.cleanup_tmp_file(png_path)
    return nil, "PNG file was not created or is empty after conversion", false
  end

  return png_path, true, nil
end

return M