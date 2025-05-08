local config_module = require("mdxsnap.config")
local M = {}

-- Helper Functions
local function get_os_type()
  if vim.fn.has("macunix") then return "mac"
  elseif vim.fn.has("unix") then return "linux"
  elseif vim.fn.has("win32") or vim.fn.has("win64") then return "windows"
  end
  return "unknown"
end

local function expand_shell_vars_in_path(path_str)
  if path_str == nil then return nil, "Path string is nil" end
  return vim.fn.expand(path_str)
end

local function find_project_root_path(start_path)
  local current_path, err = expand_shell_vars_in_path(vim.fn.fnamemodify(start_path, ":h"))
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
  return expand_shell_vars_in_path(vim.fn.getcwd())
end

local function fetch_image_path_from_clipboard()
  local os_type = get_os_type()
  local cmd
  if os_type == "mac" then cmd = "pbpaste"
  elseif os_type == "linux" then
    if vim.fn.executable("wl-paste") then cmd = "wl-paste -n"
    elseif vim.fn.executable("xclip") then cmd = "xclip -selection clipboard -o"
    else return nil, "Clipboard tool (wl-paste or xclip) not found."
    end
  elseif os_type == "windows" then cmd = "powershell -command \"Get-Clipboard -Format Text -Raw\""
  else return nil, "Unsupported OS for clipboard access."
  end

  local handle = io.popen(cmd)
  if not handle then return nil, "Failed to execute clipboard command: " .. cmd end
  local result = handle:read("*a")
  handle:close()
  result = result:gsub("[\r\n]", "")
  if result == "" then return nil, "Clipboard is empty or does not contain text." end
  return expand_shell_vars_in_path(result)
end

local function extract_filename_stem(filepath)
  local basename = filepath:match("([^/\\]+)%..*$") or filepath:match("([^/\\]+)$")
  return basename
end

local function determine_active_paste_config(current_buf_path, opts)
  local project_root_abs_path, err_root = find_project_root_path(current_buf_path)
  if not project_root_abs_path then return nil, err_root end
  local project_root_name = vim.fn.fnamemodify(project_root_abs_path, ":t")

  local active_path_str = opts.DefaultPastePath
  local active_type = opts.DefaultPastePathType

  if opts.ProjectOverrides and #opts.ProjectOverrides > 0 then
    for _, rule in ipairs(opts.ProjectOverrides) do
      local rule_match_value, err_expand_match = expand_shell_vars_in_path(rule.matchValue)
      if not rule_match_value then
        vim.notify("Error expanding override rule matchValue: " .. (err_expand_match or "unknown"), vim.log.levels.WARN)
        goto continue
      end

      local matched = false
      if rule.matchType == "projectName" and project_root_name == rule_match_value then
        matched = true
      elseif rule.matchType == "projectPath" and project_root_abs_path == rule_match_value then
        matched = true
      end

      if matched then
        active_path_str = rule.PastePath
        active_type = rule.PastePathType
        vim.notify("Using project override: matchType=" .. rule.matchType .. ", value=" .. rule_match_value, vim.log.levels.INFO)
        break
      end
      ::continue::
    end
  end

  local expanded_active_path, err_expand_active = expand_shell_vars_in_path(active_path_str)
  if not expanded_active_path then
    return nil, "Error expanding active PastePath: " .. (err_expand_active or "unknown error")
  end

  return {
    path = expanded_active_path,
    type = active_type,
    project_root = project_root_abs_path,
  }
end

local function build_final_paste_base_path(paste_config)
  local active_paste_path = paste_config.path
  local active_paste_path_type = paste_config.type
  local project_root_abs_path = paste_config.project_root
  local resolved_base

  if active_paste_path_type == "relative" then
    if not project_root_abs_path then return nil, "Cannot resolve relative path: project root not found." end
    resolved_base = project_root_abs_path .. "/" .. active_paste_path
  elseif active_paste_path_type == "absolute" then
    resolved_base = active_paste_path
  else
    return nil, "Invalid PastePathType: " .. tostring(active_paste_path_type)
  end

  if not resolved_base or resolved_base == "" then return nil, "Resolved PastePath is empty." end
  return vim.fn.fnamemodify(resolved_base, ":p"):gsub("\\", "/")
end

local function ensure_target_directory_exists(base_path, mdx_filename_no_ext)
  local image_subdir = base_path .. "/" .. mdx_filename_no_ext
  if vim.fn.isdirectory(image_subdir) == 0 then
    vim.fn.mkdir(image_subdir, "p")
    if vim.fn.isdirectory(image_subdir) == 0 then
      return nil, "Failed to create directory: " .. image_subdir
    end
  end
  return image_subdir
end

local function copy_image_file(clipboard_path, target_dir, original_extension)
  local current_time_ms = vim.loop.now()
  if not current_time_ms then current_time_ms = 0 end
  if not clipboard_path then clipboard_path = "" end

  local time_str
  -- Try Lua's native tostring first for current_time_ms
  local conversion_ok, conversion_err = pcall(function() time_str = tostring(current_time_ms) end)
  if not conversion_ok then
    vim.notify("Error converting time to string (using Lua tostring). Time was: " .. vim.inspect(current_time_ms) .. ". Error: " .. tostring(conversion_err), vim.log.levels.ERROR)
    time_str = "0" -- Fallback
  elseif not time_str then
    vim.notify("Lua tostring returned nil for time: " .. vim.inspect(current_time_ms), vim.log.levels.ERROR)
    time_str = "0" -- Fallback
  end

  -- Ensure clipboard_path is a string
  if type(clipboard_path) ~= "string" then
    vim.notify("clipboard_path is not a string: " .. vim.inspect(clipboard_path) .. " (type: " .. type(clipboard_path) .. ")", vim.log.levels.WARN)
    local cb_conversion_ok, cb_path_str_err = pcall(function() clipboard_path = tostring(clipboard_path) end) -- Use Lua's tostring
    if not cb_conversion_ok then
        vim.notify("Failed to convert clipboard_path to string (using Lua tostring): " .. tostring(cb_path_str_err), vim.log.levels.ERROR)
        clipboard_path = "" -- Fallback
    elseif clipboard_path == nil then
        vim.notify("Lua tostring returned nil for clipboard_path.", vim.log.levels.ERROR)
        clipboard_path = "" -- Fallback
    end
  end

  local seed_string = time_str .. clipboard_path
  -- For debugging:
  -- vim.notify("Seed string for SHA256: '" .. seed_string .. "' (type: " .. type(seed_string) .. ")", vim.log.levels.DEBUG)

  local hashed_string
  local hash_ok, hash_err = pcall(function() hashed_string = vim.fn.sha256(seed_string) end)
  if not hash_ok then
    vim.notify("Error during sha256 calculation. Seed was: '" .. seed_string .. "'. Error: " .. tostring(hash_err), vim.log.levels.ERROR)
    local fallback_seed = tostring(os.time()) .. "fallback" -- Use Lua's tostring
    hashed_string = vim.fn.sha256(fallback_seed)
  elseif not hashed_string then
     vim.notify("vim.fn.sha256 returned nil for seed: '" .. seed_string .. "'", vim.log.levels.ERROR)
     local fallback_seed = tostring(os.time()) .. "fallback_nil" -- Use Lua's tostring
     hashed_string = vim.fn.sha256(fallback_seed)
  end

  -- Ensure hashed_string is not nil before strcharpart
  if not hashed_string then
    vim.notify("hashed_string became nil even after fallback. Using fixed random string.", vim.log.levels.ERROR)
    hashed_string = "abcdef1234567890" -- Absolute fallback
  end

  local random_string = vim.fn.strcharpart(hashed_string, 0, 8)
  local new_filename = random_string .. original_extension
  local new_image_full_path = target_dir .. "/" .. new_filename
  new_image_full_path = vim.fn.fnamemodify(new_image_full_path, ":p"):gsub("\\", "/")

  local copy_cmd
  local os_type = get_os_type()
  if os_type == "mac" or os_type == "linux" then
    copy_cmd = string.format("cp '%s' '%s'", clipboard_path, new_image_full_path)
  elseif os_type == "windows" then
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

local function ensure_imports_are_present(bufnr, custom_imports)
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last_import_line_idx = -1

  for _, imp_config in ipairs(custom_imports) do
    local import_exists = false
    for line_idx, line_content in ipairs(current_lines) do
      if line_content:find(imp_config.checkRegex) then
        import_exists = true
        if (line_idx - 1) > last_import_line_idx then
          last_import_line_idx = line_idx - 1
        end
        break
      end
    end

    if not import_exists then
      local insert_at_idx = 0
      if last_import_line_idx ~= -1 then
        insert_at_idx = last_import_line_idx + 1
      else
        local in_frontmatter, frontmatter_end_idx = false, -1
        for line_idx, line_content in ipairs(current_lines) do
          if line_content:match("^---$") then
            if not in_frontmatter then in_frontmatter = true
            else frontmatter_end_idx = line_idx -1; break
            end
          end
        end
        if frontmatter_end_idx ~= -1 then insert_at_idx = frontmatter_end_idx + 1 end
      end
      vim.api.nvim_buf_set_lines(bufnr, insert_at_idx, insert_at_idx, false, {imp_config.line})
      current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if last_import_line_idx <= insert_at_idx then
          last_import_line_idx = insert_at_idx
      end
    end
  end
end

local function format_image_reference_text(new_image_full_path, new_filename_only, custom_text_format, project_root_abs_path, active_paste_path_type)
  local image_path_for_text = new_image_full_path
  if active_paste_path_type == "relative" and project_root_abs_path and new_image_full_path:find(project_root_abs_path, 1, true) == 1 then
    local rel_path = new_image_full_path:sub(#project_root_abs_path + 1)
    if rel_path:sub(1,1) ~= "/" then rel_path = "/" .. rel_path end
    image_path_for_text = rel_path
  end

  local alt_text = extract_filename_stem(new_filename_only)
  local text_to_insert
  local s_count = 0
  for _ in string.gmatch(custom_text_format, "%%s") do s_count = s_count + 1 end

  if s_count == 1 then text_to_insert = string.format(custom_text_format, image_path_for_text)
  elseif s_count >= 2 then text_to_insert = string.format(custom_text_format, alt_text, image_path_for_text)
  else text_to_insert = image_path_for_text
  end
  return text_to_insert
end

-- Main Function
M.paste_image = function()
  local opts = config_module.options
  local current_bufnr = vim.api.nvim_get_current_buf()
  local current_buf_path_raw = vim.api.nvim_buf_get_name(current_bufnr)

  if current_buf_path_raw == "" then vim.notify("Current buffer has no name.", vim.log.levels.ERROR); return end
  local current_buf_path, err_exp_buf = expand_shell_vars_in_path(current_buf_path_raw)
  if not current_buf_path then vim.notify("Error expanding buffer path: " .. (err_exp_buf or "unknown"), vim.log.levels.ERROR); return end

  local current_filetype = vim.bo[current_bufnr].filetype
  if current_filetype ~= "mdx" and current_filetype ~= "markdown" then
    vim.notify("Command only for MDX/Markdown files.", vim.log.levels.WARN); return
  end
  local mdx_filename_no_ext = vim.fn.fnamemodify(current_buf_path, ":t:r")

  local clipboard_path, err_cb = fetch_image_path_from_clipboard()
  if not clipboard_path then vim.notify(err_cb, vim.log.levels.ERROR); return end
  if not vim.fn.filereadable(clipboard_path) then
    vim.notify("Clipboard content is not a readable file: " .. clipboard_path, vim.log.levels.ERROR); return
  end

  local original_extension = clipboard_path:match("%.([^%.]+)$")
  if not original_extension then
    vim.notify("Cannot determine image extension: " .. clipboard_path, vim.log.levels.ERROR); return
  end
  original_extension = "." .. original_extension:lower()

  local active_paste_config, err_conf = determine_active_paste_config(current_buf_path, opts)
  if not active_paste_config then
    vim.notify(err_conf or "Failed to get active paste configuration.", vim.log.levels.ERROR); return
  end

  local resolved_paste_base, err_resolve = build_final_paste_base_path(active_paste_config)
  if not resolved_paste_base then vim.notify(err_resolve, vim.log.levels.ERROR); return end

  local target_image_dir, err_mkdir = ensure_target_directory_exists(resolved_paste_base, mdx_filename_no_ext)
  if not target_image_dir then vim.notify(err_mkdir, vim.log.levels.ERROR); return end

  local new_image_full_path, new_filename_only, err_copy
  new_image_full_path, new_filename_only, err_copy = copy_image_file(clipboard_path, target_image_dir, original_extension)
  if not new_image_full_path then vim.notify(err_copy, vim.log.levels.ERROR); return end

  ensure_imports_are_present(current_bufnr, opts.customImports)

  local text_to_insert = format_image_reference_text(
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