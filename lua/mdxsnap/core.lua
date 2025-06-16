local config_module = require("mdxsnap.config")
local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local clipboard = require("mdxsnap.clipboard")
local editor_utils = require("mdxsnap.editor_utils")

local M = {}

-- Main Function
M.paste_image = function(desired_filename_stem)
  local opts = config_module.options
  local buf_nr = vim.api.nvim_get_current_buf()
  local buf_path_raw = vim.api.nvim_buf_get_name(buf_nr)

  if buf_path_raw == "" then vim.notify("Current buffer has no name.", vim.log.levels.ERROR); return end
  local buf_path, expand_err = utils.expand_shell_vars_in_path(buf_path_raw)
  if not buf_path then vim.notify("Error expanding buffer path: " .. (expand_err or "unknown"), vim.log.levels.ERROR); return end

  local filetype_raw = vim.bo[buf_nr].filetype
  local filetype = string.lower(string.gsub(filetype_raw, "^%s*(.-)%s*$", "%1")) -- Trim and lowercase
  local buf_filename = vim.api.nvim_buf_get_name(buf_nr)
  local file_ext = string.lower(vim.fn.fnamemodify(buf_filename, ":e"))

  if not (filetype == "mdx" or filetype == "markdown" or file_ext == "mdx" or file_ext == "md") then
    vim.notify("Command only for MDX/Markdown files. Detected filetype: '" .. filetype_raw .. "' (processed as: '" .. filetype .. "'), Extension: '" .. file_ext .. "'", vim.log.levels.WARN); return
  end
  local filename_stem = vim.fn.fnamemodify(buf_path, ":t:r")

  local image_path, is_temp, clip_err
  image_path, is_temp, clip_err = clipboard.fetch_image_path_from_clipboard()

  if not image_path then
    vim.notify(clip_err or "Failed to get image/path from clipboard.", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(image_path) == 0 then
    vim.notify("Obtained clipboard image path is not a readable file: " .. image_path, vim.log.levels.ERROR)
    if is_temp then fs_utils.cleanup_tmp_file(image_path) end
    return
  end

  local ext
  if is_temp then
    ext = ".png" -- Assuming temp files from clipboard (macos tiff->png, linux mime) are png
  else
    local ext_match = image_path:match("%.([^%./\\]+)$")
    if not ext_match then
      vim.notify("Cannot determine image extension from path: " .. image_path, vim.log.levels.ERROR)
      if is_temp then fs_utils.cleanup_tmp_file(image_path) end
      return
    end
    ext = "." .. ext_match:lower()
  end

  local paste_config, config_err = editor_utils.determine_active_paste_config(buf_path, opts)
  if not paste_config then
    vim.notify(config_err or "Failed to get active paste configuration.", vim.log.levels.ERROR)
    if is_temp then fs_utils.cleanup_tmp_file(image_path) end
    return
  end

  local base_path, base_err = fs_utils.build_final_paste_base_path(paste_config)
  if not base_path then
    vim.notify(base_err, vim.log.levels.ERROR)
    if is_temp then fs_utils.cleanup_tmp_file(image_path) end
    return
  end

  local target_dir, dir_err = fs_utils.ensure_target_directory_exists(base_path, filename_stem)
  if not target_dir then
    vim.notify(dir_err, vim.log.levels.ERROR)
    if is_temp then fs_utils.cleanup_tmp_file(image_path) end
    return
  end

  local new_path, new_filename, copy_err
  new_path, new_filename, copy_err = fs_utils.copy_image_file(image_path, target_dir, ext, desired_filename_stem)

  if is_temp then
    fs_utils.cleanup_tmp_file(image_path)
  end

  if not new_path then
    vim.notify(copy_err or "Failed to copy image to final destination.", vim.log.levels.ERROR)
    return
  end

  if filetype == "mdx" or file_ext == "mdx" then
    editor_utils.ensure_imports_are_present(buf_nr, paste_config.customImports or opts.customImports)
  end

  local text_to_insert = editor_utils.format_image_reference_text(
    new_path,
    new_filename,
    paste_config.customTextFormat or opts.customTextFormat,
    paste_config.project_root,
    paste_config.type,
    desired_filename_stem
  )

  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_lines(buf_nr, cursor_pos[1] - 1, cursor_pos[1] - 1, false, { text_to_insert })

  vim.notify("Image pasted: " .. new_path, vim.log.levels.INFO)
end

return M