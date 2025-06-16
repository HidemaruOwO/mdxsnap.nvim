local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local config_module = require("mdxsnap.config") -- Added config_module require

local M = {}

function M.determine_active_paste_config(buf_path, opts)
  local project_root, root_err = fs_utils.find_project_root_path(buf_path)
  if not project_root then return nil, root_err end
  local root_name = vim.fn.fnamemodify(project_root, ":t")

  local paste_path = opts.DefaultPastePath
  local path_type = opts.DefaultPastePathType
  local imports = opts.customImports
  local text_format = opts.customTextFormat

  if opts.ProjectOverrides and #opts.ProjectOverrides > 0 then
    for _, rule in ipairs(opts.ProjectOverrides) do
      local match_value, expand_err = utils.expand_shell_vars_in_path(rule.matchValue)
      if not match_value then
        vim.notify("Error expanding override rule matchValue: " .. (expand_err or "unknown"), vim.log.levels.WARN)
        goto continue
      end

      local is_matched = false
      if rule.matchType == "projectName" and root_name == match_value then
        is_matched = true
      elseif rule.matchType == "projectPath" and project_root == match_value then
        is_matched = true
      end

      if is_matched then
        paste_path = rule.PastePath or paste_path
        path_type = rule.PastePathType or path_type
        imports = rule.customImports or imports
        text_format = rule.customTextFormat or text_format
        vim.notify("Using project override: matchType=" .. rule.matchType .. ", value=" .. match_value, vim.log.levels.INFO)
        break
      end
      ::continue::
    end
  end

  local expanded_path, expand_err = utils.expand_shell_vars_in_path(paste_path)
  if not expanded_path then
    return nil, "Error expanding active PastePath: " .. (expand_err or "unknown error")
  end

  return {
    path = expanded_path,
    type = path_type,
    project_root = project_root,
    customImports = imports,
    customTextFormat = text_format,
  }
end

function M.ensure_imports_are_present(buf_nr, imports)
  if not imports or #imports == 0 then return end -- No imports to check

  local lines = vim.api.nvim_buf_get_lines(buf_nr, 0, -1, false)
  local import_line_idx = -1

  for _, import_cfg in ipairs(imports) do
    local exists = false
    for line_idx, line_text in ipairs(lines) do
      if import_cfg.checkRegex and line_text:find(import_cfg.checkRegex) then
        exists = true
        if (line_idx - 1) > import_line_idx then
          import_line_idx = line_idx - 1
        end
        break
      end
    end

    if not exists then
      local insert_idx = 0
      if import_line_idx ~= -1 then
        insert_idx = import_line_idx + 1
      else
        local in_frontmatter, frontmatter_end = false, -1
        for line_idx, line_text in ipairs(lines) do
          if line_text:match("^---$") then
            if not in_frontmatter then in_frontmatter = true
            else frontmatter_end = line_idx -1; break
            end
          end
        end
        if frontmatter_end ~= -1 then insert_idx = frontmatter_end + 1 end
      end
      vim.api.nvim_buf_set_lines(buf_nr, insert_idx, insert_idx, false, {import_cfg.line})
      lines = vim.api.nvim_buf_get_lines(buf_nr, 0, -1, false) -- Refresh lines
      if import_line_idx <= insert_idx then
          import_line_idx = insert_idx
      end
    end
  end
end

function M.format_image_reference_text(full_path, filename, text_format, project_root, path_type, desired_stem)
  local display_path = utils.normalize_slashes(full_path)

  if path_type == "relative" and project_root then
    local norm_root = utils.normalize_slashes(project_root .. "/")
    if display_path:find(norm_root, 1, true) == 1 then
      local rel_path = display_path:sub(#norm_root + 1)
      if rel_path ~= "" and rel_path:sub(1,1) ~= "/" then
        rel_path = "/" .. rel_path
      elseif rel_path == "" then
        rel_path = "/" .. filename
        if display_path:sub(#norm_root + 1) ~= filename then
            local sub_path = display_path:sub(#norm_root + 1)
            if sub_path ~= "" and sub_path:sub(1,1) ~= "/" then
                rel_path = "/" .. sub_path
            elseif sub_path == "" then
                 rel_path = "/"
            else
                rel_path = sub_path
            end
        end
      end
      display_path = utils.normalize_slashes(rel_path)
    end
  end

  local alt_text
  if desired_stem and desired_stem ~= "" then
    alt_text = desired_stem
  else
    alt_text = utils.extract_filename_stem(filename)
  end
  local text_to_insert
  local placeholder_count = 0
  for _ in string.gmatch(text_format, "%%s") do placeholder_count = placeholder_count + 1 end

  if placeholder_count == 1 then text_to_insert = string.format(text_format, display_path)
  elseif placeholder_count >= 2 then text_to_insert = string.format(text_format, alt_text, display_path)
  else text_to_insert = display_path
  end
  return text_to_insert
end

return M