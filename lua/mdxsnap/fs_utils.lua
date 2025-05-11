local utils = require("mdxsnap.utils")
local M = {}

function M.find_project_root_path(start_path)
  local current_path, err = utils.expand_shell_vars_in_path(vim.fn.fnamemodify(start_path, ":h"))
  if not current_path then return nil, err end

  local markers = { ".git", ".project", "_darcs", ".hg", ".bzr", ".svn" }
  for _ = 1, 64 do
    for _, marker in ipairs(markers) do
      if vim.fn.isdirectory(current_path .. "/" .. marker) == 1 or vim.fn.filereadable(current_path .. "/" .. marker) == 1 then
        return current_path
      end
    end
    local parent = vim.fn.fnamemodify(current_path, ":h")
    if parent == current_path then break end
    current_path = parent
  end
  return utils.expand_shell_vars_in_path(vim.fn.getcwd())
end

function M.get_tmp_dir()
  local data_path = vim.fn.stdpath("data")
  local tmp_dir = data_path .. "/mdxsnap_tmp"
  if vim.fn.isdirectory(tmp_dir) == 0 then
    vim.fn.mkdir(tmp_dir, "p")
    if vim.fn.isdirectory(tmp_dir) == 0 then
      vim.notify("Failed to create mdxsnap temp directory: " .. tmp_dir, vim.log.levels.ERROR)
      return nil -- Indicate failure
    end
  end
  return tmp_dir
end

function M.cleanup_tmp_file(filepath)
  if filepath and vim.fn.filereadable(filepath) == 1 then
    local ok, err = pcall(vim.fn.delete, filepath)
    if not ok then
      vim.notify("Failed to clean up temp file: " .. filepath .. " Error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

function M.build_final_paste_base_path(paste_config)
  local active_paste_path = paste_config.path
  local active_paste_path_type = paste_config.type
  local project_root_abs_path = paste_config.project_root
  local resolved_base

  if active_paste_path_type == "relative" then
    if not project_root_abs_path then return nil, "Cannot resolve relative path: project root not found." end
    local clean_active_path = active_paste_path:gsub("^[/\\]+", "")
    resolved_base = project_root_abs_path .. "/" .. clean_active_path
  elseif active_paste_path_type == "absolute" then
    resolved_base = active_paste_path
  else
    return nil, "Invalid PastePathType: " .. tostring(active_paste_path_type)
  end

  if not resolved_base or resolved_base == "" then return nil, "Resolved PastePath is empty." end
  return utils.normalize_slashes(vim.fn.fnamemodify(resolved_base, ":p"))
end

function M.ensure_target_directory_exists(base_path, mdx_filename_no_ext)
  local clean_mdx_filename = mdx_filename_no_ext:gsub("^[/\\]+", "")
  local image_subdir = utils.normalize_slashes(base_path .. "/" .. clean_mdx_filename)
  if vim.fn.isdirectory(image_subdir) == 0 then
    vim.fn.mkdir(image_subdir, "p")
    if vim.fn.isdirectory(image_subdir) == 0 then
      return nil, "Failed to create directory: " .. image_subdir
    end
  end
  return image_subdir
end

function M.copy_image_file(clipboard_path, target_dir, original_extension)
  if not clipboard_path or clipboard_path == "" then
    return nil, nil, "Invalid clipboard path (empty or nil)"
  end

  -- Generate unique filename
  local current_time_ms = vim.loop.now() or os.time() * 1000
  local time_str = tostring(current_time_ms)
  
  -- Generate hash for filename
  local hashed_string = vim.fn.sha256(time_str .. clipboard_path)
  if not hashed_string then
    hashed_string = vim.fn.sha256(tostring(os.time()) .. clipboard_path)
  end
  if not hashed_string then
    hashed_string = "fallback" .. tostring(os.time())
  end

  -- Create destination path
  local random_string = vim.fn.strcharpart(hashed_string, 0, 8)
  local new_filename = random_string .. original_extension
  local new_image_full_path = utils.normalize_slashes(target_dir .. "/" .. new_filename)
  new_image_full_path = utils.normalize_slashes(vim.fn.fnamemodify(new_image_full_path, ":p"))

  -- Copy file using Lua I/O
  local source_file, err_source = io.open(clipboard_path, "rb")
  if not source_file then
    return nil, nil, "Failed to open source file: " .. tostring(err_source)
  end

  local dest_file, err_dest = io.open(new_image_full_path, "wb")
  if not dest_file then
    source_file:close()
    return nil, nil, "Failed to create destination file: " .. tostring(err_dest)
  end

  local success = true
  local error_msg
  local chunk_size = 8192 -- 8KB chunks for efficient copying

  while true do
    local chunk = source_file:read(chunk_size)
    if not chunk then break end -- EOF

    local ok = dest_file:write(chunk)
    if not ok then
      success = false
      error_msg = "Failed to write chunk to destination file"
      break
    end
  end

  -- Clean up
  source_file:close()
  dest_file:flush() -- Ensure all data is written
  dest_file:close()

  -- Handle errors
  if not success then
    pcall(vim.fn.delete, new_image_full_path) -- Try to clean up failed copy
    return nil, nil, error_msg
  end

  -- Verify copy was successful
  if vim.fn.filereadable(new_image_full_path) ~= 1 then
    return nil, nil, "Copied file is not readable: " .. new_image_full_path
  end

  if vim.fn.getfsize(new_image_full_path) <= 0 then
    pcall(vim.fn.delete, new_image_full_path)
    return nil, nil, "Copied file is empty"
  end

  return new_image_full_path, new_filename
end

return M