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
  local current_time_ms = vim.loop.now()
  if not current_time_ms then current_time_ms = 0 end
  if not clipboard_path then clipboard_path = "" end

  local time_str
  local conversion_ok, conversion_err = pcall(function() time_str = tostring(current_time_ms) end)
  if not conversion_ok then
    vim.notify("Error converting time to string (using Lua tostring). Time was: " .. vim.inspect(current_time_ms) .. ". Error: " .. tostring(conversion_err), vim.log.levels.ERROR)
    time_str = "0"
  elseif not time_str then
    vim.notify("Lua tostring returned nil for time: " .. vim.inspect(current_time_ms), vim.log.levels.ERROR)
    time_str = "0"
  end

  if type(clipboard_path) ~= "string" then
    vim.notify("clipboard_path is not a string: " .. vim.inspect(clipboard_path) .. " (type: " .. type(clipboard_path) .. ")", vim.log.levels.WARN)
    local cb_conversion_ok, cb_path_str_err = pcall(function() clipboard_path = tostring(clipboard_path) end)
    if not cb_conversion_ok then
        vim.notify("Failed to convert clipboard_path to string (using Lua tostring): " .. tostring(cb_path_str_err), vim.log.levels.ERROR)
        clipboard_path = ""
    elseif clipboard_path == nil then
        vim.notify("Lua tostring returned nil for clipboard_path.", vim.log.levels.ERROR)
        clipboard_path = ""
    end
  end

  local seed_string = time_str .. clipboard_path

  local hashed_string
  local hash_ok, hash_err = pcall(function() hashed_string = vim.fn.sha256(seed_string) end)
  if not hash_ok then
    vim.notify("Error during sha256 calculation. Seed was: '" .. seed_string .. "'. Error: " .. tostring(hash_err), vim.log.levels.ERROR)
    local fallback_seed = tostring(os.time()) .. "fallback"
    hashed_string = vim.fn.sha256(fallback_seed)
  elseif not hashed_string then
     vim.notify("vim.fn.sha256 returned nil for seed: '" .. seed_string .. "'", vim.log.levels.ERROR)
     local fallback_seed = tostring(os.time()) .. "fallback_nil"
     hashed_string = vim.fn.sha256(fallback_seed)
  end

  if not hashed_string then
    vim.notify("hashed_string became nil even after fallback. Using fixed random string.", vim.log.levels.ERROR)
    hashed_string = "abcdef1234567890"
  end

  local random_string = vim.fn.strcharpart(hashed_string, 0, 8)
  local new_filename = random_string .. original_extension
  local new_image_full_path = utils.normalize_slashes(target_dir .. "/" .. new_filename)
  new_image_full_path = utils.normalize_slashes(vim.fn.fnamemodify(new_image_full_path, ":p"))

  local copy_cmd
  local os_type_copy = utils.get_os_type()
  if os_type_copy == "mac" or os_type_copy == "linux" then
    copy_cmd = string.format("cp '%s' '%s'", clipboard_path, new_image_full_path)
  elseif os_type_copy == "windows" then
    copy_cmd = string.format("copy \"%s\" \"%s\"", clipboard_path:gsub("/", "\\"), new_image_full_path:gsub("/", "\\"))
  else
    return nil, nil, "Unsupported OS for file copy."
  end

  vim.fn.system(copy_cmd)
  if vim.v.shell_error ~= 0 then
    return nil, nil, "Failed to copy image. Cmd: " .. copy_cmd .. " Err: " .. vim.v.shell_error
  end
  return new_image_full_path, new_filename
end

return M