local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local M = {}

-- Helper function to check if file extension is a supported image format
local function is_supported_image_extension(file_path)
  if not file_path then return false end
  local ext_match = file_path:match("%.([^%./\\]+)$")
  return ext_match and ({png = true, jpg = true, jpeg = true, gif = true, webp = true, tiff = true})[ext_match:lower()]
end

-- Helper function to validate and check if path is a readable image file
local function validate_image_path(file_path)
  if not file_path then return nil end
  if vim.fn.filereadable(file_path) == 1 and is_supported_image_extension(file_path) then
    return file_path
  end
  return nil
end

-- Helper function to get file path using AppleScript file URL methods
local function get_file_path_via_applescript()
  local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scripts/applescript/get_file_url_from_clipboard.applescript"
  
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
  local validated_path = validate_image_path(expanded_path)
  if validated_path then
    return validated_path
  end
  
  -- If pbpaste result is just a filename (no slashes) and not readable,
  -- try to get full path using AppleScript
  if not expanded_path:match("/") then
    local applescript_path = get_file_path_via_applescript()
    if applescript_path then
      return validate_image_path(applescript_path)
    end
  end
  
  return nil
end

local function fetch_image_path_from_clipboard_macos()
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

  local png_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scripts/applescript/save_png_from_clipboard.applescript"
  
  local is_ok, result = pcall(vim.fn.system, "osascript '" .. png_script .. "' '" .. png_path .. "'")
  if is_ok and vim.v.shell_error == 0 and not result:match("^error:") then
    if vim.fn.filereadable(png_path) == 1 and vim.fn.getfsize(png_path) > 0 then
      return png_path, true, nil
    end
    fs_utils.cleanup_tmp_file(png_path)
  end

  local tiff_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".tiff")
  local tiff_script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scripts/applescript/save_tiff_from_clipboard.applescript"
  
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

function M.fetch_image_path_from_clipboard()
  local os_type = utils.get_os_type()

  if os_type == "mac" then
    local image_path, is_temp, error_msg
    image_path, is_temp, error_msg = fetch_image_path_from_clipboard_macos()
    if image_path then
      return image_path, is_temp, error_msg
    else
      -- If all attempts within fetch_image_path_from_clipboard_macos failed
      vim.notify("macOS: All attempts to get image/path from clipboard failed. Last error: " .. (error_msg or "unknown reason"), vim.log.levels.WARN)
      return nil, false, "macOS: Failed to get image or path from clipboard. " .. (error_msg or "")
    end
  elseif os_type == "linux" then
    local is_wayland = vim.env.WAYLAND_DISPLAY ~= nil

    if is_wayland then
      if vim.fn.executable("wl-paste") then
        local list_cmd = "wl-paste --list-types"
        local types_handle = io.popen(list_cmd)
        local types_str = ""
        if types_handle then
          types_str = types_handle:read("*a")
          types_handle:close()
        end

        local mime_map = {
          ["image/png"] = ".png",
          ["image/jpeg"] = ".jpg",
          ["image/gif"] = ".gif",
          ["image/webp"] = ".webp",
        }
        local selected_mime = nil
        local selected_ext = nil

        local preferred_mimes = {"image/png", "image/jpeg", "image/webp", "image/gif"}
        for _, mime in ipairs(preferred_mimes) do
            if types_str:find(mime, 1, true) and mime_map[mime] then
                selected_mime = mime
                selected_ext = mime_map[mime]
                break
            end
        end
        if not selected_mime then
            for mime_type, extension in pairs(mime_map) do
                if types_str:find(mime_type, 1, true) then
                    selected_mime = mime_type
                    selected_ext = extension
                    break
                end
            end
        end

        if selected_mime and selected_ext then
          local tmp_dir = fs_utils.get_tmp_dir()
          if tmp_dir then
            local timestamp = tostring(vim.loop.now())
            local tmp_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. selected_ext)
            local paste_cmd = string.format("wl-paste --type %s > '%s'", selected_mime, tmp_path)
            vim.fn.system(paste_cmd)
            if vim.v.shell_error == 0 and vim.fn.filereadable(tmp_path) == 1 and vim.fn.getfsize(tmp_path) > 0 then
              return tmp_path, true, nil
            else
              fs_utils.cleanup_tmp_file(tmp_path)
            end
          end
        end

        local text_cmd = "wl-paste -n"
        local text_handle = io.popen(text_cmd)
        local text_result = ""
        if text_handle then
          text_result = text_handle:read("*a")
          text_handle:close()
          text_result = text_result:gsub("[\r\n]", "")
        end

        if text_result ~= "" then
          local path_candidate = text_result
          if path_candidate:match("^file://") then
            path_candidate = path_candidate:sub(8)
            path_candidate = utils.url_decode(path_candidate)
            if not path_candidate then
               return nil, false, "Wayland: Failed to URL decode file URI from clipboard."
            end
          elseif path_candidate:match("<[a-zA-Z%s\"'=/%;:%-_%.%?#&]+>") and not path_candidate:match("%.[a-zA-Z0-9]+$") then
            return nil, false, "Wayland: Clipboard text via wl-paste -n appears to be HTML/XML, not a file path."
          end

          local expanded_path, expand_err = utils.expand_shell_vars_in_path(path_candidate)
          if expanded_path then
            if vim.fn.filereadable(expanded_path) == 1 then
                 return expanded_path, false, nil
            else
                return nil, false, "Wayland: Clipboard text (path candidate) is not a readable file: " .. expanded_path
            end
          else
            return nil, false, "Wayland: Failed to expand clipboard text (path candidate): " .. (expand_err or "unknown error")
          end
        end
        return nil, false, "Wayland: wl-paste -n did not yield usable text from clipboard."
      else
        return nil, false, "Wayland environment detected, but wl-paste command not found."
      end
    else -- X11 or other (non-Wayland Linux)
      if vim.fn.executable("xclip") then
        local targets_cmd = "xclip -selection clipboard -t TARGETS -o"
        local targets_handle = io.popen(targets_cmd)
        local targets_content = ""
        local is_cmd_failed = false

        if targets_handle then
          targets_content = targets_handle:read("*a")
          local is_close_ok, reason, code = targets_handle:close()
          if not is_close_ok or (reason == "exit" and code ~= 0) then
            vim.notify(string.format("X11: 'xclip -t TARGETS -o' command failed or returned non-zero. Status: %s, Code: %s. Output was: %s",
                                     tostring(reason), tostring(code), targets_content), vim.log.levels.WARN)
            is_cmd_failed = true
            targets_content = ""
          end
        else
          vim.notify("X11: Failed to execute 'xclip -t TARGETS -o' (io.popen failed). Cannot determine available image types.", vim.log.levels.WARN)
          is_cmd_failed = true
        end

        local target_map = {
          ["image/png"] = ".png",
          ["image/jpeg"] = ".jpg",
          ["image/gif"] = ".gif",
          ["image/webp"] = ".webp",
        }
        local selected_target = nil
        local selected_ext = nil

        if not is_cmd_failed and targets_content ~= "" then
            local preferred_targets = {"image/png", "image/jpeg", "image/webp", "image/gif"}
            local is_found = false
            for line in targets_content:gmatch("([^\n]+)") do
                local trimmed = line:match("^%s*(.-)%s*$")
                for _, target in ipairs(preferred_targets) do
                    if trimmed == target and target_map[target] then
                        selected_target = target
                        selected_ext = target_map[target]
                        is_found = true
                        break
                    end
                end
                if is_found then
                    break
                end
            end
        end

        if selected_target and selected_ext then
          local tmp_dir = fs_utils.get_tmp_dir()
          if tmp_dir then
            local timestamp = tostring(vim.loop.now())
            local tmp_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. selected_ext)
            local paste_cmd = string.format("xclip -selection clipboard -t %s -o > '%s'", selected_target, tmp_path)
            vim.fn.system(paste_cmd)
            if vim.v.shell_error == 0 and vim.fn.filereadable(tmp_path) == 1 and vim.fn.getfsize(tmp_path) > 0 then
              return tmp_path, true, nil
            else
              local failure_reason = "unknown reason"
              if vim.v.shell_error ~= 0 then
                failure_reason = "xclip command failed with shell_error: " .. vim.v.shell_error
              elseif vim.fn.filereadable(tmp_path) == 0 then
                failure_reason = "temporary image file was not created or not readable: " .. tmp_path
              elseif vim.fn.getfsize(tmp_path) <= 0 then
                failure_reason = "temporary image file was empty."
              end
              fs_utils.cleanup_tmp_file(tmp_path)
              return nil, false, "X11: Found image target '" .. selected_target .. "' but failed to retrieve/save image data: " .. failure_reason
            end
          else
             vim.notify("X11: Could not get temporary directory for image target. Falling back to text.", vim.log.levels.WARN)
          end
        end

        local text_cmd = "xclip -selection clipboard -o"
        local text_handle = io.popen(text_cmd)

        if not text_handle then
          return nil, false, "X11: Failed to execute xclip command for text (io.popen failed)."
        end

        local text_result = text_handle:read("*a")
        local is_close_ok, close_reason, close_code = text_handle:close()
        text_result = text_result:gsub("[\r\n]", "")

        if text_result == "" then
          local error_detail = "X11: xclip did not return any text. Clipboard might be empty, or contain non-text data (e.g., image data that could not be processed via TARGETS)"
          if not is_close_ok or (close_reason == "exit" and close_code ~= 0) or close_reason == "signal" then
             error_detail = error_detail .. ". xclip (text mode) might also have encountered an error [status: " .. tostring(close_reason) .. " code: " .. tostring(close_code) .. "]"
          end
          error_detail = error_detail .. "."
          return nil, false, error_detail
        end
        
        local path_candidate = text_result
        if path_candidate:match("^file://") then
          path_candidate = path_candidate:sub(8)
          path_candidate = utils.url_decode(path_candidate)
          if not path_candidate then
             return nil, false, "X11: Failed to URL decode file URI from clipboard."
          end
        end

        local expanded_path, expand_err = utils.expand_shell_vars_in_path(path_candidate)
        if expanded_path then
          if vim.fn.filereadable(expanded_path) == 1 then
            return expanded_path, false, nil
          else
            return nil, false, "X11: Clipboard text (path candidate) '" .. expanded_path .. "' is not a readable file."
          end
        else
          return nil, false, "X11: Failed to expand clipboard text path: " .. (expand_err or "unknown error")
        end
      else
        return nil, false, "X11 environment: xclip command not found."
      end
    end
  elseif os_type == "windows" then
    -- Attempt to get image directly using PowerShell
    local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scripts/powershell/save_clipboard_image_as_png.ps1"
    local image_cmd = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -File \"" .. script_path .. "\""
    
    local image_handle = io.popen(image_cmd)
    local image_result = ""
    if image_handle then
      image_result = image_handle:read("*a")
      image_handle:close()
      image_result = image_result:gsub("[\r\n]", "")
    else
      vim.notify("Windows: Failed to execute PowerShell for image extraction (io.popen failed).", vim.log.levels.WARN)
    end

    if image_result ~= "" and image_result ~= "NoImage" and image_result ~= "ErrorSavingImage" then
      if vim.fn.filereadable(image_result) == 1 then
        return image_result, true, nil -- path, is_temporary, error_message
      else
        vim.notify("Windows: PowerShell reported image saved to '" .. image_result .. "', but file is not readable.", vim.log.levels.WARN)
      end
    elseif image_result == "ErrorSavingImage" then
        vim.notify("Windows: PowerShell script encountered an error while saving the image.", vim.log.levels.WARN)
    end
    -- If image extraction failed or no image, fall back to text-based clipboard
    vim.notify("Windows: No image found in clipboard via PowerShell or error occurred, trying text.", vim.log.levels.INFO)

    local text_cmd = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command \"Get-Clipboard -Format Text -Raw\""
    local text_handle = io.popen(text_cmd)
    if not text_handle then return nil, false, "Windows: Failed to execute PowerShell Get-Clipboard (text fallback)." end
    local text_result = text_handle:read("*a")
    local is_close_ok, _, close_code = text_handle:close()
    text_result = text_result:gsub("[\r\n]", "")

    if text_result == "" then
        local error_detail = "Windows: PowerShell Get-Clipboard (text fallback) returned no text (clipboard might be empty)"
        if not is_close_ok or (close_code and close_code ~= 0) then
            error_detail = error_detail .. " or PowerShell command failed [code: " .. tostring(close_code) .. "]"
        end
        return nil, false, error_detail .. "."
    end

    local path_candidate = text_result
    if path_candidate:match("^file:///") then
        path_candidate = path_candidate:sub(9)
        path_candidate = utils.url_decode(path_candidate)
        if not path_candidate then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard (text fallback)."
        end
    elseif path_candidate:match("^file://") then
         path_candidate = path_candidate:sub(8)
         path_candidate = utils.url_decode(path_candidate)
         if not path_candidate then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard (text fallback)."
        end
    end

    local expanded_path, expand_err = utils.expand_shell_vars_in_path(path_candidate)
    if not expanded_path then
        return nil, false, "Windows: Failed to expand clipboard text path (text fallback): " .. (expand_err or "unknown error")
    end
    
    if vim.fn.filereadable(expanded_path) == 1 then
        return expanded_path, false, nil
    else
        return nil, false, "Windows: Clipboard text (path candidate, fallback) '" .. expanded_path .. "' is not a readable file."
    end
  else
    return nil, false, "Unsupported OS for clipboard access."
  end
end

return M