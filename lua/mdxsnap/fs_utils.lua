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
    local parent_path = vim.fn.fnamemodify(current_path, ":h")
    if parent_path == current_path then break end
    current_path = parent_path
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

function M.cleanup_tmp_file(file_path)
  if file_path and vim.fn.filereadable(file_path) == 1 then
    local is_ok, err = pcall(vim.fn.delete, file_path)
    if not is_ok then
      vim.notify("Failed to clean up temp file: " .. file_path .. " Error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

function M.build_final_paste_base_path(paste_config)
  local paste_path = paste_config.path
  local path_type = paste_config.type
  local project_root = paste_config.project_root
  local resolved_path

  if path_type == "relative" then
    if not project_root then return nil, "Cannot resolve relative path: project root not found." end
    local clean_path = paste_path:gsub("^[/\\]+", "")
    resolved_path = project_root .. "/" .. clean_path
  elseif path_type == "absolute" then
    resolved_path = paste_path
  else
    return nil, "Invalid PastePathType: " .. tostring(path_type)
  end

  if not resolved_path or resolved_path == "" then return nil, "Resolved PastePath is empty." end
  return utils.normalize_slashes(vim.fn.fnamemodify(resolved_path, ":p"))
end

function M.ensure_target_directory_exists(base_path, filename_stem)
  local clean_filename = filename_stem:gsub("^[/\\]+", "")
  local target_dir = utils.normalize_slashes(base_path .. "/" .. clean_filename)
  if vim.fn.isdirectory(target_dir) == 0 then
    vim.fn.mkdir(target_dir, "p")
    if vim.fn.isdirectory(target_dir) == 0 then
      return nil, "Failed to create directory: " .. target_dir
    end
  end
  return target_dir
end

function M.copy_image_file(source_path, target_dir, file_ext, desired_stem)
  if not source_path or source_path == "" then
    return nil, nil, "Invalid source path (empty or nil)"
  end

  local filename
  if desired_stem and desired_stem ~= "" then
    filename = desired_stem .. file_ext
  else
    -- Generate unique filename
    local time_ms = vim.loop.now() or os.time() * 1000
    local time_str = tostring(time_ms)

    -- Generate hash for filename
    local hash = vim.fn.sha256(time_str .. source_path)
    if not hash then
      hash = vim.fn.sha256(tostring(os.time()) .. source_path)
    end
    if not hash then
      hash = "fallback" .. tostring(os.time())
    end
    local random_str = vim.fn.strcharpart(hash, 0, 8)
    filename = random_str .. file_ext
  end

  local full_path = utils.normalize_slashes(target_dir .. "/" .. filename)
  full_path = utils.normalize_slashes(vim.fn.fnamemodify(full_path, ":p"))

  -- Copy file using Lua I/O
  local src_file, src_err = io.open(source_path, "rb")
  if not src_file then
    return nil, nil, "Failed to open source file: " .. tostring(src_err)
  end

  local dst_file, dst_err = io.open(full_path, "wb")
  if not dst_file then
    src_file:close()
    return nil, nil, "Failed to create destination file: " .. tostring(dst_err)
  end

  local is_success = true
  local error_msg
  local chunk_size = 8192 -- 8KB chunks for efficient copying

  while true do
    local chunk = src_file:read(chunk_size)
    if not chunk then break end -- EOF

    local is_ok = dst_file:write(chunk)
    if not is_ok then
      is_success = false
      error_msg = "Failed to write chunk to destination file"
      break
    end
  end

  -- Clean up
  src_file:close()
  dst_file:flush() -- Ensure all data is written
  dst_file:close()

  -- Handle errors
  if not is_success then
    pcall(vim.fn.delete, full_path) -- Try to clean up failed copy
    return nil, nil, error_msg
  end

  -- Verify copy was successful
  if vim.fn.filereadable(full_path) ~= 1 then
    return nil, nil, "Copied file is not readable: " .. full_path
  end

  if vim.fn.getfsize(full_path) <= 0 then
    pcall(vim.fn.delete, full_path)
    return nil, nil, "Copied file is empty"
  end

  return full_path, filename
end

return M