local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_x11()
  if not vim.fn.executable("xclip") then
    return nil, false, "X11 environment: xclip command not found."
  end

  -- Get available clipboard targets
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

  local target_map = clipboard_utils.get_image_mime_map()
  local selected_target = nil
  local selected_ext = nil

  -- Find available image targets
  if not is_cmd_failed and targets_content ~= "" then
      local preferred_targets = clipboard_utils.get_preferred_mimes()
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

  -- Try to save image data if found
  if selected_target and selected_ext then
    local tmp_path = clipboard_utils.save_image_to_tmp_file(selected_target, selected_ext, "xclip -selection clipboard -t %s -o > '%s'")
    if tmp_path then
      return tmp_path, true, nil
    else
      local failure_reason = "unknown reason"
      if vim.v.shell_error ~= 0 then
        failure_reason = "xclip command failed with shell_error: " .. vim.v.shell_error
      end
      vim.notify("X11: Could not get temporary directory for image target. Falling back to text.", vim.log.levels.WARN)
      return nil, false, "X11: Found image target '" .. selected_target .. "' but failed to retrieve/save image data: " .. failure_reason
    end
  end

  -- Fall back to text content
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
  
  return clipboard_utils.process_clipboard_text(text_result, "X11")
end

return M