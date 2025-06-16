local utils = require("mdxsnap.utils")
local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_windows()
  -- Attempt to get image directly using PowerShell
  local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scripts/powershell/save_clipboard_image_as_png.ps1"
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
  
  -- Handle Windows-specific file URI formats
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
end

return M