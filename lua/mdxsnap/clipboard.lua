local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local M = {}

local function fetch_image_path_from_clipboard_macos()
  local tmp_dir = fs_utils.get_tmp_dir()
  if not tmp_dir then return nil, "Could not get/create mdxsnap temp directory.", false end

  local timestamp = tostring(vim.loop.now()) -- Use Lua's tostring
  local tmp_tiff_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".tiff")
  local tmp_png_path = utils.normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".png")

  local osascript_cmd = string.format(
    "osascript -e 'tell app \"System Events\" to write (the clipboard as «class TIFF») to (open for access POSIX file \"%s\" with write permission)'",
    tmp_tiff_path
  )

  local system_ok, system_result_or_err = pcall(vim.fn.system, osascript_cmd)
  local osascript_output = ""
  if system_ok then
    osascript_output = system_result_or_err
  else
    fs_utils.cleanup_tmp_file(tmp_tiff_path)
    return nil, "Error executing osascript command: " .. tostring(system_result_or_err), false
  end

  if vim.v.shell_error ~= 0 then
    fs_utils.cleanup_tmp_file(tmp_tiff_path)
    return nil, "Failed to save clipboard image as TIFF using osascript. Shell error: " .. vim.v.shell_error .. ". Output: " .. osascript_output, false
  end

  if vim.fn.filereadable(tmp_tiff_path) == 0 then
    return nil, "osascript ran, but TIFF file was not created (clipboard might not contain image data): " .. tmp_tiff_path, false
  end

  local sips_cmd = string.format(
    "sips -s format png \"%s\" --out \"%s\"",
    tmp_tiff_path, tmp_png_path
  )
  system_ok, system_result_or_err = pcall(vim.fn.system, sips_cmd)
  local sips_output = ""
  if system_ok then
    sips_output = system_result_or_err
  else
    fs_utils.cleanup_tmp_file(tmp_tiff_path)
    fs_utils.cleanup_tmp_file(tmp_png_path)
    return nil, "Error executing sips command: " .. tostring(system_result_or_err), false
  end
  fs_utils.cleanup_tmp_file(tmp_tiff_path)

  if vim.v.shell_error ~= 0 then
    fs_utils.cleanup_tmp_file(tmp_png_path)
    return nil, "Failed to convert TIFF to PNG using sips. Shell error: " .. vim.v.shell_error .. ". Output: " .. sips_output, false
  end

  if vim.fn.filereadable(tmp_png_path) == 0 then
    return nil, "sips ran, but PNG file was not created: " .. tmp_png_path, false
  end

  return tmp_png_path, true, nil -- path, is_temporary, error_message (nil on success)
end

function M.fetch_image_path_from_clipboard()
  local os_type = utils.get_os_type()

  if os_type == "mac" then
    local raw_image_path, is_temp, err_macos
    raw_image_path, is_temp, err_macos = fetch_image_path_from_clipboard_macos()
    if raw_image_path then
      return raw_image_path, is_temp, err_macos
    else
      vim.notify("macOS: Failed to get raw image from clipboard (" .. (err_macos or "unknown reason") .. "), falling back to pbpaste (text path).", vim.log.levels.INFO)
      local cmd_pbpaste = "pbpaste"
      local handle_pbpaste = io.popen(cmd_pbpaste)
      if not handle_pbpaste then return nil, false, "macOS: Failed to execute pbpaste." end
      local result_pbpaste = handle_pbpaste:read("*a")
      handle_pbpaste:close()
      result_pbpaste = result_pbpaste:gsub("[\r\n]", "")
      if result_pbpaste == "" then return nil, false, "macOS: Clipboard (pbpaste) is empty or does not contain text." end
      
      local expanded_path_pb, err_expand_pb = utils.expand_shell_vars_in_path(result_pbpaste)
      if not expanded_path_pb then
        return nil, false, "macOS: Failed to expand path from pbpaste: " .. (err_expand_pb or "unknown")
      end
      
      if vim.fn.filereadable(expanded_path_pb) == 1 then
        return expanded_path_pb, false, nil
      else
        return nil, false, "macOS: Path from pbpaste is not a readable file: " .. expanded_path_pb
      end
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
    local cmd_win = "powershell -command \"Get-Clipboard -Format Text -Raw\""
    local handle_win = io.popen(cmd_win)
    if not handle_win then return nil, false, "Windows: Failed to execute PowerShell Get-Clipboard." end
    local result_win = handle_win:read("*a")
    local close_success, _, close_code = handle_win:close()
    result_win = result_win:gsub("[\r\n]", "")

    if result_win == "" then
        local err_detail_win = "Windows: PowerShell Get-Clipboard returned no text (clipboard might be empty)"
        if not close_success or (close_code and close_code ~= 0) then
            err_detail_win = err_detail_win .. " or PowerShell command failed [code: " .. tostring(close_code) .. "]"
        end
        return nil, false, err_detail_win .. "."
    end

    local final_path_candidate_win = result_win
    if final_path_candidate_win:match("^file:///") then
        final_path_candidate_win = final_path_candidate_win:sub(9)
        final_path_candidate_win = utils.url_decode(final_path_candidate_win)
        if not final_path_candidate_win then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard."
        end
    elseif final_path_candidate_win:match("^file://") then
         final_path_candidate_win = final_path_candidate_win:sub(8)
         final_path_candidate_win = utils.url_decode(final_path_candidate_win)
         if not final_path_candidate_win then
            return nil, false, "Windows: Failed to URL decode file URI from clipboard."
        end
    end

    local expanded_path_win, err_expand_win = utils.expand_shell_vars_in_path(final_path_candidate_win)
    if not expanded_path_win then
        return nil, false, "Windows: Failed to expand clipboard text path: " .. (err_expand_win or "unknown error")
    end
    
    if vim.fn.filereadable(expanded_path_win) == 1 then
        return expanded_path_win, false, nil
    else
        return nil, false, "Windows: Clipboard text (path candidate) '" .. expanded_path_win .. "' is not a readable file."
    end
  else
    return nil, false, "Unsupported OS for clipboard access."
  end
end

return M