local utils = require("mdxsnap.utils")
local macos = require("mdxsnap.clipboard.macos")
local wayland = require("mdxsnap.clipboard.wayland")
local x11 = require("mdxsnap.clipboard.x11")
local windows = require("mdxsnap.clipboard.windows")
local M = {}

function M.fetch_image_path_from_clipboard()
  local os_type = utils.get_os_type()

  if os_type == "mac" then
    local image_path, is_temp, error_msg
    image_path, is_temp, error_msg = macos.fetch_image_path_from_clipboard_macos()
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
      return wayland.fetch_image_path_from_clipboard_wayland()
    else -- X11 or other (non-Wayland Linux)
      return x11.fetch_image_path_from_clipboard_x11()
    end
  elseif os_type == "windows" then
    return windows.fetch_image_path_from_clipboard_windows()
  else
    return nil, false, "Unsupported OS for clipboard access."
  end
end

return M