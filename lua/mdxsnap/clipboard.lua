local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local M = {}

local function fetch_image_path_from_clipboard_macos()
  -- Attempt 1: Use pbpaste to get a potential file path
  local cmd_pbpaste_check = "pbpaste"
  local handle_pbpaste_check = io.popen(cmd_pbpaste_check)
  if handle_pbpaste_check then
    local result_pbpaste_check = handle_pbpaste_check:read("*a")
    handle_pbpaste_check:close()
    result_pbpaste_check = result_pbpaste_check:gsub("[\r\n]", "")

    if result_pbpaste_check ~= "" then
      local expanded_path_pb_check, _ = utils.expand_shell_vars_in_path(result_pbpaste_check)
      if expanded_path_pb_check then
        if vim.fn.filereadable(expanded_path_pb_check) == 1 then
          local ext_match_pb = expanded_path_pb_check:match("%.([^%./\\]+)$")
          if ext_match_pb and ({png = true, jpg = true, jpeg = true, gif = true, webp = true, tiff = true})[ext_match_pb:lower()] then
            return expanded_path_pb_check, false, nil -- path, is_temporary=false, error_message
          end
        else
          -- If pbpaste result is just a filename (no slashes) and not readable (likely not in cwd),
          -- try to get full path using AppleScript for 'file URL' or 'fss'.
          if not expanded_path_pb_check:match("/") then
            local get_furl_script = [[
              try
                  return POSIX path of (the clipboard as «class furl»)
              on error err_msg_furl number err_num_furl
                  try
                      return POSIX path of (the clipboard as "public.file-url")
                  on error err_msg_public number err_num_public
                      try
                          set clipboard_text to (the clipboard as text)
                          if clipboard_text starts with "/" then
                              return clipboard_text
                          else
                              return "error:furl_public_text_failed:" & err_num_furl & ":" & err_msg_furl & ";" & err_num_public & ":" & err_msg_public
                          end if
                      on error err_msg_text number err_num_text
                          return "error:all_attempts_failed:" & err_num_furl & ":" & err_msg_furl & ";" & err_num_public & ":" & err_msg_public & ";" & err_num_text & ":" & err_msg_text
                      end try
                  end try
              end try
            ]]
            local as_ok, as_furl_result = pcall(vim.fn.system, "osascript -e '" .. get_furl_script:gsub("'", "'\\''") .. "'")
            if as_ok and vim.v.shell_error == 0 and as_furl_result and not as_furl_result:match("^error:") then
              local full_path_from_as = as_furl_result:gsub("[\r\n]", "")
              if vim.fn.filereadable(full_path_from_as) == 1 then
                local ext_match_as = full_path_from_as:match("%.([^%./\\]+)$")
                if ext_match_as and ({png = true, jpg = true, jpeg = true, gif = true, webp = true, tiff = true})[ext_match_as:lower()] then
                  return full_path_from_as, false, nil
                end
              end
            end
          end
        end
      end
    end
  end

  -- Attempt 2: AppleScript to get raw image data (PNG then TIFF)
  local tmp_dir = fs_utils.get_tmp_dir()
  if not tmp_dir then return nil, "Could not get/create mdxsnap temp directory.", false end

  local timestamp = tostring(vim.loop.now())
  local tmp_png_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".png")

  local png_script = string.format([[
    try
      set png_data to (the clipboard as «class PNGf»)
      set png_file to open for access POSIX file "%s" with write permission
      write png_data to png_file
      close access png_file
      return "success"
    on error err_msg number err_num
      try
        close access png_file
      end try
      return "error:" & err_msg & ":" & err_num
    end try
  ]], tmp_png_path)

  local system_ok, system_result = pcall(vim.fn.system, "osascript -e '" .. png_script .. "'")
  if system_ok and vim.v.shell_error == 0 and not system_result:match("^error:") then
    if vim.fn.filereadable(tmp_png_path) == 1 and vim.fn.getfsize(tmp_png_path) > 0 then
      return tmp_png_path, true, nil
    end
    fs_utils.cleanup_tmp_file(tmp_png_path)
  end

  local tmp_tiff_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".tiff")
  local tiff_script = string.format([[
    try
      set tiff_data to (the clipboard as «class TIFF»)
      set tiff_file to open for access POSIX file "%s" with write permission
      write tiff_data to tiff_file
      close access tiff_file
      return "success"
    on error err_msg number err_num
      try
        close access tiff_file
      end try
      return "error:" & err_msg & ":" & err_num
    end try
  ]], tmp_tiff_path)

  system_ok, system_result = pcall(vim.fn.system, "osascript -e '" .. tiff_script .. "'")
  if not system_ok or vim.v.shell_error ~= 0 or system_result:match("^error:") then
    fs_utils.cleanup_tmp_file(tmp_tiff_path)
    return nil, "Failed to save clipboard image as TIFF (fallback). Error: " .. tostring(system_result), false
  end

  if vim.fn.filereadable(tmp_tiff_path) == 0 then
    return nil, "TIFF file was not created (clipboard might not contain image data)", false
  end

  local sips_cmd = string.format("sips -s format png \"%s\" --out \"%s\"", tmp_tiff_path, tmp_png_path)
  system_ok, system_result = pcall(vim.fn.system, sips_cmd)
  fs_utils.cleanup_tmp_file(tmp_tiff_path)

  if not system_ok or vim.v.shell_error ~= 0 then
    fs_utils.cleanup_tmp_file(tmp_png_path)
    return nil, "Failed to convert TIFF to PNG. Error: " .. tostring(system_result), false
  end

  if vim.fn.filereadable(tmp_png_path) == 0 or vim.fn.getfsize(tmp_png_path) == 0 then
    fs_utils.cleanup_tmp_file(tmp_png_path)
    return nil, "PNG file was not created or is empty after conversion", false
  end

  return tmp_png_path, true, nil
end

function M.fetch_image_path_from_clipboard()
  local os_type = utils.get_os_type()

  if os_type == "mac" then
    local raw_image_path, is_temp, err_macos
    raw_image_path, is_temp, err_macos = fetch_image_path_from_clipboard_macos()
    if raw_image_path then
      return raw_image_path, is_temp, err_macos
    else
      -- If all attempts within fetch_image_path_from_clipboard_macos failed
      vim.notify("macOS: All attempts to get image/path from clipboard failed. Last error: " .. (err_macos or "unknown reason"), vim.log.levels.WARN)
      return nil, false, "macOS: Failed to get image or path from clipboard. " .. (err_macos or "")
    end
  elseif os_type == "linux" then
    local is_wayland = vim.env.WAYLAND_DISPLAY ~= nil

    if is_wayland then
      if vim.fn.executable("wl-paste") then
        local list_types_cmd = "wl-paste --list-types"
        local types_handle = io.popen(list_types_cmd)
        local available_types_str = ""
        if types_handle then
          available_types_str = types_handle:read("*a")
          types_handle:close()
        end

        local image_mime_map = {
          ["image/png"] = ".png",
          ["image/jpeg"] = ".jpg",
          ["image/gif"] = ".gif",
          ["image/webp"] = ".webp",
        }
        local selected_mime_type = nil
        local selected_extension = nil

        local preferred_order = {"image/png", "image/jpeg", "image/webp", "image/gif"}
        for _, preferred_mime in ipairs(preferred_order) do
            if available_types_str:find(preferred_mime, 1, true) and image_mime_map[preferred_mime] then
                selected_mime_type = preferred_mime
                selected_extension = image_mime_map[preferred_mime]
                break
            end
        end
        if not selected_mime_type then
            for mime_type, extension in pairs(image_mime_map) do
                if available_types_str:find(mime_type, 1, true) then
                    selected_mime_type = mime_type
                    selected_extension = extension
                    break
                end
            end
        end

        if selected_mime_type and selected_extension then
          local tmp_dir_img = fs_utils.get_tmp_dir()
          if tmp_dir_img then
            local timestamp_img = tostring(vim.loop.now())
            local tmp_image_path = utils.normalize_slashes(tmp_dir_img .. "/clip_" .. timestamp_img .. selected_extension)
            local paste_img_cmd = string.format("wl-paste --type %s > '%s'", selected_mime_type, tmp_image_path)
            vim.fn.system(paste_img_cmd)
            if vim.v.shell_error == 0 and vim.fn.filereadable(tmp_image_path) == 1 and vim.fn.getfsize(tmp_image_path) > 0 then
              return tmp_image_path, true, nil
            else
              fs_utils.cleanup_tmp_file(tmp_image_path)
            end
          end
        end

        local cmd_text = "wl-paste -n"
        local text_handle = io.popen(cmd_text)
        local result_text = ""
        if text_handle then
          result_text = text_handle:read("*a")
          text_handle:close()
          result_text = result_text:gsub("[\r\n]", "")
        end

        if result_text ~= "" then
          local final_path_candidate = result_text
          if final_path_candidate:match("^file://") then
            final_path_candidate = final_path_candidate:sub(8)
            final_path_candidate = utils.url_decode(final_path_candidate)
            if not final_path_candidate then
               return nil, false, "Wayland: Failed to URL decode file URI from clipboard."
            end
          elseif final_path_candidate:match("<[a-zA-Z%s\"'=/%;:%-_%.%?#&]+>") and not final_path_candidate:match("%.[a-zA-Z0-9]+$") then
            return nil, false, "Wayland: Clipboard text via wl-paste -n appears to be HTML/XML, not a file path."
          end

          local expanded_path, err_expand = utils.expand_shell_vars_in_path(final_path_candidate)
          if expanded_path then
            if vim.fn.filereadable(expanded_path) == 1 then
                 return expanded_path, false, nil
            else
                return nil, false, "Wayland: Clipboard text (path candidate) is not a readable file: " .. expanded_path
            end
          else
            return nil, false, "Wayland: Failed to expand clipboard text (path candidate): " .. (err_expand or "unknown error")
          end
        end
        return nil, false, "Wayland: wl-paste -n did not yield usable text from clipboard."
      else
        return nil, false, "Wayland environment detected, but wl-paste command not found."
      end
    else -- X11 or other (non-Wayland Linux)
      if vim.fn.executable("xclip") then
        local list_targets_cmd = "xclip -selection clipboard -t TARGETS -o"
        local targets_handle = io.popen(list_targets_cmd)
        local available_targets_content = ""
        local targets_cmd_failed = false

        if targets_handle then
          available_targets_content = targets_handle:read("*a")
          local close_success, reason, code = targets_handle:close()
          if not close_success or (reason == "exit" and code ~= 0) then
            vim.notify(string.format("X11: 'xclip -t TARGETS -o' command failed or returned non-zero. Status: %s, Code: %s. Output was: %s",
                                     tostring(reason), tostring(code), available_targets_content), vim.log.levels.WARN)
            targets_cmd_failed = true
            available_targets_content = ""
          end
        else
          vim.notify("X11: Failed to execute 'xclip -t TARGETS -o' (io.popen failed). Cannot determine available image types.", vim.log.levels.WARN)
          targets_cmd_failed = true
        end

        local image_target_map = {
          ["image/png"] = ".png",
          ["image/jpeg"] = ".jpg",
          ["image/gif"] = ".gif",
          ["image/webp"] = ".webp",
        }
        local selected_target = nil
        local selected_extension = nil

        if not targets_cmd_failed and available_targets_content ~= "" then
            local preferred_targets_x11 = {"image/png", "image/jpeg", "image/webp", "image/gif"}
            local found_flag = false
            for line in available_targets_content:gmatch("([^\n]+)") do
                local trimmed_line = line:match("^%s*(.-)%s*$")
                for _, target_to_check in ipairs(preferred_targets_x11) do
                    if trimmed_line == target_to_check and image_target_map[target_to_check] then
                        selected_target = target_to_check
                        selected_extension = image_target_map[target_to_check]
                        found_flag = true
                        break
                    end
                end
                if found_flag then
                    break
                end
            end
        end

        if selected_target and selected_extension then
          local tmp_dir_img_x11 = fs_utils.get_tmp_dir()
          if tmp_dir_img_x11 then
            local timestamp_img_x11 = tostring(vim.loop.now())
            local tmp_image_path_x11 = utils.normalize_slashes(tmp_dir_img_x11 .. "/clip_" .. timestamp_img_x11 .. selected_extension)
            local paste_img_cmd_x11 = string.format("xclip -selection clipboard -t %s -o > '%s'", selected_target, tmp_image_path_x11)
            vim.fn.system(paste_img_cmd_x11)
            if vim.v.shell_error == 0 and vim.fn.filereadable(tmp_image_path_x11) == 1 and vim.fn.getfsize(tmp_image_path_x11) > 0 then
              return tmp_image_path_x11, true, nil
            else
              local failure_reason = "unknown reason"
              if vim.v.shell_error ~= 0 then
                failure_reason = "xclip command failed with shell_error: " .. vim.v.shell_error
              elseif vim.fn.filereadable(tmp_image_path_x11) == 0 then
                failure_reason = "temporary image file was not created or not readable: " .. tmp_image_path_x11
              elseif vim.fn.getfsize(tmp_image_path_x11) <= 0 then
                failure_reason = "temporary image file was empty."
              end
              fs_utils.cleanup_tmp_file(tmp_image_path_x11)
              return nil, false, "X11: Found image target '" .. selected_target .. "' but failed to retrieve/save image data: " .. failure_reason
            end
          else
             vim.notify("X11: Could not get temporary directory for image target. Falling back to text.", vim.log.levels.WARN)
          end
        end

        local cmd_x11_text = "xclip -selection clipboard -o"
        local handle_x11 = io.popen(cmd_x11_text)

        if not handle_x11 then
          return nil, false, "X11: Failed to execute xclip command for text (io.popen failed)."
        end

        local result_x11 = handle_x11:read("*a")
        local close_success, close_reason, close_code = handle_x11:close()
        result_x11 = result_x11:gsub("[\r\n]", "")

        if result_x11 == "" then
          local err_detail = "X11: xclip did not return any text. Clipboard might be empty, or contain non-text data (e.g., image data that could not be processed via TARGETS)"
          if not close_success or (close_reason == "exit" and close_code ~= 0) or close_reason == "signal" then
             err_detail = err_detail .. ". xclip (text mode) might also have encountered an error [status: " .. tostring(close_reason) .. " code: " .. tostring(close_code) .. "]"
          end
          err_detail = err_detail .. "."
          return nil, false, err_detail
        end
        
        local final_path_candidate_x11 = result_x11
        if final_path_candidate_x11:match("^file://") then
          final_path_candidate_x11 = final_path_candidate_x11:sub(8)
          final_path_candidate_x11 = utils.url_decode(final_path_candidate_x11)
          if not final_path_candidate_x11 then
             return nil, false, "X11: Failed to URL decode file URI from clipboard."
          end
        end

        local expanded_path, err_expand = utils.expand_shell_vars_in_path(final_path_candidate_x11)
        if expanded_path then
          if vim.fn.filereadable(expanded_path) == 1 then
            return expanded_path, false, nil
          else
            return nil, false, "X11: Clipboard text (path candidate) '" .. expanded_path .. "' is not a readable file."
          end
        else
          return nil, false, "X11: Failed to expand clipboard text path: " .. (err_expand or "unknown error")
        end
      else
        return nil, false, "X11 environment: xclip command not found."
      end
    end
  elseif os_type == "windows" then
    -- Attempt to get image directly using PowerShell
    local ps_script = [[
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$image = [System.Windows.Forms.Clipboard]::GetImage()
if ($image -ne $null) {
    $timestamp = Get-Date -Format "yyyyMMddHHmmssfff"
    $tempDir = [System.IO.Path]::GetTempPath()
    $fileName = "mdxsnap_clip_" + $timestamp + ".png"
    $filePath = [System.IO.Path]::Combine($tempDir, $fileName)
    try {
        $image.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output $filePath
    } catch {
        Write-Output "ErrorSavingImage"
    }
} else {
    Write-Output "NoImage"
}
]]
    local cmd_get_image_win = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command \"" .. ps_script:gsub("\"", "\\\"") .. "\""
    
    local image_path_handle = io.popen(cmd_get_image_win)
    local image_path_result = ""
    if image_path_handle then
      image_path_result = image_path_handle:read("*a")
      image_path_handle:close()
      image_path_result = image_path_result:gsub("[\r\n]", "")
    else
      vim.notify("Windows: Failed to execute PowerShell for image extraction (io.popen failed).", vim.log.levels.WARN)
    end

    if image_path_result ~= "" and image_path_result ~= "NoImage" and image_path_result ~= "ErrorSavingImage" then
      if vim.fn.filereadable(image_path_result) == 1 then
        return image_path_result, true, nil -- path, is_temporary, error_message
      else
        vim.notify("Windows: PowerShell reported image saved to '" .. image_path_result .. "', but file is not readable.", vim.log.levels.WARN)
      end
    elseif image_path_result == "ErrorSavingImage" then
        vim.notify("Windows: PowerShell script encountered an error while saving the image.", vim.log.levels.WARN)
    end
    -- If image extraction failed or no image, fall back to text-based clipboard
    vim.notify("Windows: No image found in clipboard via PowerShell or error occurred, trying text.", vim.log.levels.INFO)

    local cmd_win_text = "powershell -ExecutionPolicy Bypass -NoProfile -NonInteractive -Command \"Get-Clipboard -Format Text -Raw\""
    local handle_win_text = io.popen(cmd_win_text)
    if not handle_win_text then return nil, false, "Windows: Failed to execute PowerShell Get-Clipboard (text fallback)." end
    local result_win_text = handle_win_text:read("*a")
    local close_success_text, _, close_code_text = handle_win_text:close()
    result_win_text = result_win_text:gsub("[\r\n]", "")

    if result_win_text == "" then
        local err_detail_win_text = "Windows: PowerShell Get-Clipboard (text fallback) returned no text (clipboard might be empty)"
        if not close_success_text or (close_code_text and close_code_text ~= 0) then
            err_detail_win_text = err_detail_win_text .. " or PowerShell command failed [code: " .. tostring(close_code_text) .. "]"
        end
        return nil, false, err_detail_win_text .. "."
    end

    local final_path_candidate_win_text = result_win_text
    if final_path_candidate_win_text:match("^file:///") then
        final_path_candidate_win_text = final_path_candidate_win_text:sub(9)
        final_path_candidate_win_text = utils.url_decode(final_path_candidate_win_text)
        if not final_path_candidate_win_text then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard (text fallback)."
        end
    elseif final_path_candidate_win_text:match("^file://") then
         final_path_candidate_win_text = final_path_candidate_win_text:sub(8)
         final_path_candidate_win_text = utils.url_decode(final_path_candidate_win_text)
         if not final_path_candidate_win_text then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard (text fallback)."
        end
    end

    local expanded_path_win_text, err_expand_win_text = utils.expand_shell_vars_in_path(final_path_candidate_win_text)
    if not expanded_path_win_text then
        return nil, false, "Windows: Failed to expand clipboard text path (text fallback): " .. (err_expand_win_text or "unknown error")
    end
    
    if vim.fn.filereadable(expanded_path_win_text) == 1 then
        return expanded_path_win_text, false, nil
    else
        return nil, false, "Windows: Clipboard text (path candidate, fallback) '" .. expanded_path_win_text .. "' is not a readable file."
    end
  else
    return nil, false, "Unsupported OS for clipboard access."
  end
end

return M