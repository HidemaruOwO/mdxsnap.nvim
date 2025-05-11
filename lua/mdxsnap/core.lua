local config_module = require("mdxsnap.config")
local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local clipboard = require("mdxsnap.clipboard")
local editor_utils = require("mdxsnap.editor_utils")

local M = {}

-- Main Function
M.paste_image = function()
  local opts = config_module.options
  local current_bufnr = vim.api.nvim_get_current_buf()
  local current_buf_path_raw = vim.api.nvim_buf_get_name(current_bufnr)

  if current_buf_path_raw == "" then vim.notify("Current buffer has no name.", vim.log.levels.ERROR); return end
  local current_buf_path, err_exp_buf = utils.expand_shell_vars_in_path(current_buf_path_raw)
  if not current_buf_path then vim.notify("Error expanding buffer path: " .. (err_exp_buf or "unknown"), vim.log.levels.ERROR); return end

  local current_filetype = vim.bo[current_bufnr].filetype
  if current_filetype ~= "mdx" and current_filetype ~= "markdown" then
    vim.notify("Command only for MDX/Markdown files.", vim.log.levels.WARN); return
  end
  local mdx_filename_no_ext = vim.fn.fnamemodify(current_buf_path, ":t:r")

  local clipboard_image_path, is_temporary_clipboard_file, err_cb
  clipboard_image_path, is_temporary_clipboard_file, err_cb = clipboard.fetch_image_path_from_clipboard()

  if not clipboard_image_path then
    vim.notify(err_cb or "Failed to get image/path from clipboard.", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(clipboard_image_path) == 0 then
    vim.notify("Obtained clipboard image path is not a readable file: " .. clipboard_image_path, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then fs_utils.cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local original_extension
  if is_temporary_clipboard_file then
    original_extension = ".png" -- Assuming temp files from clipboard (macos tiff->png, linux mime) are png
  else
    local ext_match = clipboard_image_path:match("%.([^%./\\]+)$")
    if not ext_match then
      vim.notify("Cannot determine image extension from path: " .. clipboard_image_path, vim.log.levels.ERROR)
      if is_temporary_clipboard_file then fs_utils.cleanup_tmp_file(clipboard_image_path) end
      return
    end
    original_extension = "." .. ext_match:lower()
  end

  local active_paste_config, err_active_conf = editor_utils.determine_active_paste_config(current_buf_path, opts)
  if not active_paste_config then
    vim.notify(err_active_conf or "Failed to get active paste configuration.", vim.log.levels.ERROR)
    if is_temporary_clipboard_file then fs_utils.cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local resolved_paste_base, err_resolve_base = fs_utils.build_final_paste_base_path(active_paste_config)
  if not resolved_paste_base then
    vim.notify(err_resolve_base, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then fs_utils.cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local target_image_dir, err_mkdir_target = fs_utils.ensure_target_directory_exists(resolved_paste_base, mdx_filename_no_ext)
  if not target_image_dir then
    vim.notify(err_mkdir_target, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then fs_utils.cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local new_image_full_path, new_filename_only, err_copy_img
  new_image_full_path, new_filename_only, err_copy_img = fs_utils.copy_image_file(clipboard_image_path, target_image_dir, original_extension)

  if is_temporary_clipboard_file then
    fs_utils.cleanup_tmp_file(clipboard_image_path)
  end

  if not new_image_full_path then
    vim.notify(err_copy_img or "Failed to copy image to final destination.", vim.log.levels.ERROR)
    return
  end

  if current_filetype == "mdx" then
    editor_utils.ensure_imports_are_present(current_bufnr, opts.customImports)
  end

  local text_to_insert = editor_utils.format_image_reference_text(
    new_image_full_path,
    new_filename_only,
    opts.customTextFormat,
    active_paste_config.project_root,
    active_paste_config.type
  )

  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_lines(current_bufnr, cursor_pos[1] - 1, cursor_pos[1] - 1, false, { text_to_insert })

  vim.notify("Image pasted: " .. new_image_full_path, vim.log.levels.INFO)
end

return M