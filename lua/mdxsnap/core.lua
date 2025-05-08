local config_module = require("mdxsnap.config")
local M = {}

-- Helper Functions

-- Normalizes path slashes (both / and \ to a single /)
local function normalize_slashes(path)
  if not path then return nil end
  return path:gsub("[/\\]+", "/")
end

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

local function get_tmp_dir()
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

local function cleanup_tmp_file(filepath)
  if filepath and vim.fn.filereadable(filepath) == 1 then
    local ok, err = pcall(vim.fn.delete, filepath)
    if not ok then
      vim.notify("Failed to clean up temp file: " .. filepath .. " Error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

local function fetch_image_path_from_clipboard_macos()
  local tmp_dir = get_tmp_dir()
  if not tmp_dir then return nil, "Could not get/create mdxsnap temp directory.", false end

  local timestamp = tostring(vim.loop.now()) -- Use Lua's tostring
  local tmp_tiff_path = normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".tiff")
  local tmp_png_path = normalize_slashes(tmp_dir .. "/clip_" .. timestamp .. ".png")


  local osascript_cmd = string.format(
    "osascript -e 'tell app \"System Events\" to write (the clipboard as «class TIFF») to (open for access POSIX file \"%s\" with write permission)'",
    tmp_tiff_path
  )

  local system_ok, system_result_or_err = pcall(vim.fn.system, osascript_cmd)
  local osascript_output = ""
  if system_ok then
    osascript_output = system_result_or_err
  else
    cleanup_tmp_file(tmp_tiff_path)
    return nil, "Error executing osascript command: " .. tostring(system_result_or_err), false
  end

  if vim.v.shell_error ~= 0 then
    cleanup_tmp_file(tmp_tiff_path)
    return nil, "Failed to save clipboard image as TIFF using osascript. Shell error: " .. vim.v.shell_error .. ". Output: " .. osascript_output, false
  end

  if vim.fn.filereadable(tmp_tiff_path) == 0 then
    return nil, "osascript ran, but TIFF file was not created (clipboard might not contain image data): " .. tmp_tiff_path, false
  end

  local sips_cmd = string.format(
    "sips -s format png \"%s\" --out \"%s\"",
    tmp_tiff_path, tmp_png_path
  )
  system_ok, system_result_or_err = pcall(vim.fn.system, sips_cmd)
  local sips_output = ""
  if system_ok then
    sips_output = system_result_or_err
  else
    cleanup_tmp_file(tmp_tiff_path)
    cleanup_tmp_file(tmp_png_path)
    return nil, "Error executing sips command: " .. tostring(system_result_or_err), false
  end
  cleanup_tmp_file(tmp_tiff_path)

  if vim.v.shell_error ~= 0 then
    cleanup_tmp_file(tmp_png_path)
    return nil, "Failed to convert TIFF to PNG using sips. Shell error: " .. vim.v.shell_error .. ". Output: " .. sips_output, false
  end

  if vim.fn.filereadable(tmp_png_path) == 0 then
    return nil, "sips ran, but PNG file was not created: " .. tmp_png_path, false
  end

  return tmp_png_path, true -- path, is_temporary
end


local function fetch_image_path_from_clipboard()
  local os_type = get_os_type()
  -- local is_temp_file = false -- This variable is set within the branches

  if os_type == "mac" then
    local raw_image_path, is_temp, err_macos
    -- fetch_image_path_from_clipboard_macos should return 3 values: path, is_temp_flag, error_msg
    raw_image_path, is_temp, err_macos = fetch_image_path_from_clipboard_macos()
    if raw_image_path then
      return raw_image_path, is_temp
    else
      vim.notify("Failed to get raw image from clipboard (" .. (err_macos or "unknown reason") .. "), falling back to pbpaste (text path).", vim.log.levels.WARN)
      local cmd_pbpaste = "pbpaste"
      local handle_pbpaste = io.popen(cmd_pbpaste)
      if not handle_pbpaste then return nil, "Failed to execute pbpaste.", false end
      local result_pbpaste = handle_pbpaste:read("*a")
      handle_pbpaste:close()
      result_pbpaste = result_pbpaste:gsub("[\r\n]", "")
      if result_pbpaste == "" then return nil, "Clipboard (pbpaste) is empty or does not contain text.", false end
      
      local expanded_path_pb, err_expand_pb = expand_shell_vars_in_path(result_pbpaste)
      if not expanded_path_pb then return nil, err_expand_pb, false end
      return expanded_path_pb, false
    end
  elseif os_type == "linux" then
    local cmd_linux
    if vim.fn.executable("wl-paste") then cmd_linux = "wl-paste -n"
    elseif vim.fn.executable("xclip") then cmd_linux = "xclip -selection clipboard -o"
    else return nil, "Clipboard tool (wl-paste or xclip) not found.", false
    end
    local handle_linux = io.popen(cmd_linux)
    if not handle_linux then return nil, "Failed to execute clipboard command: " .. cmd_linux, false end
    local result_linux = handle_linux:read("*a")
    handle_linux:close()
    result_linux = result_linux:gsub("[\r\n]", "")
    if result_linux == "" then return nil, "Clipboard is empty or does not contain text.", false end
    local expanded_path_linux, err_expand_linux = expand_shell_vars_in_path(result_linux)
    if not expanded_path_linux then return nil, err_expand_linux, false end
    return expanded_path_linux, false
  elseif os_type == "windows" then
    local cmd_win = "powershell -command \"Get-Clipboard -Format Text -Raw\""
    local handle_win = io.popen(cmd_win)
    if not handle_win then return nil, "Failed to execute clipboard command: " .. cmd_win, false end
    local result_win = handle_win:read("*a")
    handle_win:close()
    result_win = result_win:gsub("[\r\n]", "")
    if result_win == "" then return nil, "Clipboard is empty or does not contain text.", false end
    local expanded_path_win, err_expand_win = expand_shell_vars_in_path(result_win)
    if not expanded_path_win then return nil, err_expand_win, false end
    return expanded_path_win, false
  else
    return nil, "Unsupported OS for clipboard access.", false
  end
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
    local clean_active_path = active_paste_path:gsub("^[/\\]+", "")
    resolved_base = project_root_abs_path .. "/" .. clean_active_path
  elseif active_paste_path_type == "absolute" then
    resolved_base = active_paste_path
  else
    return nil, "Invalid PastePathType: " .. tostring(active_paste_path_type)
  end

  if not resolved_base or resolved_base == "" then return nil, "Resolved PastePath is empty." end
  return normalize_slashes(vim.fn.fnamemodify(resolved_base, ":p"))
end

local function ensure_target_directory_exists(base_path, mdx_filename_no_ext)
  local clean_mdx_filename = mdx_filename_no_ext:gsub("^[/\\]+", "")
  local image_subdir = normalize_slashes(base_path .. "/" .. clean_mdx_filename)
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
  local new_image_full_path = normalize_slashes(target_dir .. "/" .. new_filename)
  new_image_full_path = normalize_slashes(vim.fn.fnamemodify(new_image_full_path, ":p"))

  local copy_cmd
  local os_type_copy = get_os_type()
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
  local image_path_for_text = normalize_slashes(new_image_full_path)

  if active_paste_path_type == "relative" and project_root_abs_path then
    local normalized_project_root = normalize_slashes(project_root_abs_path .. "/")
    if image_path_for_text:find(normalized_project_root, 1, true) == 1 then
      local rel_path = image_path_for_text:sub(#normalized_project_root + 1)
      if rel_path ~= "" and rel_path:sub(1,1) ~= "/" then
        rel_path = "/" .. rel_path
      elseif rel_path == "" then
         -- This case implies the image is at the project root, so the path should be like "/image.png"
         -- However, our structure usually puts it in subdirs. If it truly is at root,
         -- and new_image_full_path was "/image.png", then sub() would be empty.
         -- For safety, ensure it starts with a slash if it's meant to be root-relative.
         -- This logic might need refinement based on how DefaultPastePath can be empty.
         -- If DefaultPastePath is empty, image_subdir becomes base_path .. "/" .. mdx_filename_no_ext
         -- and new_image_full_path becomes target_dir .. "/" .. new_filename
         -- If target_dir is project_root, then rel_path would be "mdx_filename_no_ext/new_filename"
         -- So, adding a leading slash is generally correct for project-relative paths.
        rel_path = "/" .. new_filename_only -- Fallback to ensure it's a valid path segment
        if image_path_for_text:sub(#normalized_project_root + 1) ~= new_filename_only then
            -- If the original rel_path was more complex, try to preserve it with a leading slash
            local original_sub_path = image_path_for_text:sub(#normalized_project_root + 1)
            if original_sub_path ~= "" and original_sub_path:sub(1,1) ~= "/" then
                rel_path = "/" .. original_sub_path
            elseif original_sub_path == "" then
                 rel_path = "/" -- Should not happen if image is in a sub-folder of project root
            else
                rel_path = original_sub_path
            end
        end
      end
      image_path_for_text = normalize_slashes(rel_path)
    end
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

  local clipboard_image_path, is_temporary_clipboard_file, err_cb
  clipboard_image_path, is_temporary_clipboard_file, err_cb = fetch_image_path_from_clipboard()

  if not clipboard_image_path then
    vim.notify(err_cb or "Failed to get image/path from clipboard.", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(clipboard_image_path) == 0 then
    vim.notify("Obtained clipboard image path is not a readable file: " .. clipboard_image_path, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local original_extension
  if is_temporary_clipboard_file then
    original_extension = ".png"
  else
    local ext_match = clipboard_image_path:match("%.([^%./\\]+)$")
    if not ext_match then
      vim.notify("Cannot determine image extension from path: " .. clipboard_image_path, vim.log.levels.ERROR)
      return
    end
    original_extension = "." .. ext_match:lower()
  end

  local active_paste_config, err_active_conf = determine_active_paste_config(current_buf_path, opts)
  if not active_paste_config then
    vim.notify(err_active_conf or "Failed to get active paste configuration.", vim.log.levels.ERROR)
    if is_temporary_clipboard_file then cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local resolved_paste_base, err_resolve_base = build_final_paste_base_path(active_paste_config)
  if not resolved_paste_base then
    vim.notify(err_resolve_base, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local target_image_dir, err_mkdir_target = ensure_target_directory_exists(resolved_paste_base, mdx_filename_no_ext)
  if not target_image_dir then
    vim.notify(err_mkdir_target, vim.log.levels.ERROR)
    if is_temporary_clipboard_file then cleanup_tmp_file(clipboard_image_path) end
    return
  end

  local new_image_full_path, new_filename_only, err_copy_img
  new_image_full_path, new_filename_only, err_copy_img = copy_image_file(clipboard_image_path, target_image_dir, original_extension)

  if is_temporary_clipboard_file then
    cleanup_tmp_file(clipboard_image_path)
  end

  if not new_image_full_path then
    vim.notify(err_copy_img or "Failed to copy image to final destination.", vim.log.levels.ERROR)
    return
  end

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