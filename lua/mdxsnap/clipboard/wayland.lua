local clipboard_utils = require("mdxsnap.clipboard.utils")
local M = {}

function M.fetch_image_path_from_clipboard_wayland()
  if not vim.fn.executable("wl-paste") then
    return nil, false, "Wayland environment detected, but wl-paste command not found."
  end

  -- Try to get image data first
  local list_cmd = "wl-paste --list-types"
  local types_handle = io.popen(list_cmd)
  local types_str = ""
  if types_handle then
    types_str = types_handle:read("*a")
    types_handle:close()
  end

  local mime_map = clipboard_utils.get_image_mime_map()
  local selected_mime = nil
  local selected_ext = nil

  -- Check for preferred MIME types first
  local preferred_mimes = clipboard_utils.get_preferred_mimes()
  for _, mime in ipairs(preferred_mimes) do
      if types_str:find(mime, 1, true) and mime_map[mime] then
          selected_mime = mime
          selected_ext = mime_map[mime]
          break
      end
  end
  
  -- If no preferred MIME type found, check all available
  if not selected_mime then
      for mime_type, extension in pairs(mime_map) do
          if types_str:find(mime_type, 1, true) then
              selected_mime = mime_type
              selected_ext = extension
              break
          end
      end
  end

  -- Try to save image data if found
  if selected_mime and selected_ext then
    local tmp_path = clipboard_utils.save_image_to_tmp_file(selected_mime, selected_ext, "wl-paste --type %s > '%s'")
    if tmp_path then
      return tmp_path, true, nil
    end
  end

  -- Fall back to text content
  local text_cmd = "wl-paste -n"
  local text_handle = io.popen(text_cmd)
  local text_result = ""
  if text_handle then
    text_result = text_handle:read("*a")
    text_handle:close()
    text_result = text_result:gsub("[\r\n]", "")
  end

  if text_result ~= "" then
    return clipboard_utils.process_clipboard_text(text_result, "Wayland")
  end
  
  return nil, false, "Wayland: wl-paste -n did not yield usable text from clipboard."
end

return M