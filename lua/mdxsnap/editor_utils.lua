local utils = require("mdxsnap.utils")
local fs_utils = require("mdxsnap.fs_utils")
local config_module = require("mdxsnap.config") -- Added config_module require

local M = {}

function M.determine_active_paste_config(current_buf_path, opts)
  local project_root_abs_path, err_root = fs_utils.find_project_root_path(current_buf_path)
  if not project_root_abs_path then return nil, err_root end
  local project_root_name = vim.fn.fnamemodify(project_root_abs_path, ":t")

  local active_path_str = opts.DefaultPastePath
  local active_type = opts.DefaultPastePathType
  local active_custom_imports = opts.customImports
  local active_custom_text_format = opts.customTextFormat

  if opts.ProjectOverrides and #opts.ProjectOverrides > 0 then
    for _, rule in ipairs(opts.ProjectOverrides) do
      local rule_match_value, err_expand_match = utils.expand_shell_vars_in_path(rule.matchValue)
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
        active_path_str = rule.PastePath or active_path_str
        active_type = rule.PastePathType or active_type
        active_custom_imports = rule.customImports or active_custom_imports
        active_custom_text_format = rule.customTextFormat or active_custom_text_format
        vim.notify("Using project override: matchType=" .. rule.matchType .. ", value=" .. rule_match_value, vim.log.levels.INFO)
        break
      end
      ::continue::
    end
  end

  local expanded_active_path, err_expand_active = utils.expand_shell_vars_in_path(active_path_str)
  if not expanded_active_path then
    return nil, "Error expanding active PastePath: " .. (err_expand_active or "unknown error")
  end

  return {
    path = expanded_active_path,
    type = active_type,
    project_root = project_root_abs_path,
    customImports = active_custom_imports,
    customTextFormat = active_custom_text_format,
  }
end

function M.ensure_imports_are_present(bufnr, custom_imports)
  if not custom_imports or #custom_imports == 0 then return end -- No imports to check

  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last_import_line_idx = -1

  for _, imp_config in ipairs(custom_imports) do
    local import_exists = false
    for line_idx, line_content in ipairs(current_lines) do
      if imp_config.checkRegex and line_content:find(imp_config.checkRegex) then
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
      current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) -- Refresh lines
      if last_import_line_idx <= insert_at_idx then
          last_import_line_idx = insert_at_idx
      end
    end
  end
end

function M.format_image_reference_text(new_image_full_path, new_filename_only, custom_text_format, project_root_abs_path, active_paste_path_type, desired_filename_stem)
  local image_path_for_text = utils.normalize_slashes(new_image_full_path)

  if active_paste_path_type == "relative" and project_root_abs_path then
    local normalized_project_root = utils.normalize_slashes(project_root_abs_path .. "/")
    if image_path_for_text:find(normalized_project_root, 1, true) == 1 then
      local rel_path = image_path_for_text:sub(#normalized_project_root + 1)
      if rel_path ~= "" and rel_path:sub(1,1) ~= "/" then
        rel_path = "/" .. rel_path
      elseif rel_path == "" then
        rel_path = "/" .. new_filename_only
        if image_path_for_text:sub(#normalized_project_root + 1) ~= new_filename_only then
            local original_sub_path = image_path_for_text:sub(#normalized_project_root + 1)
            if original_sub_path ~= "" and original_sub_path:sub(1,1) ~= "/" then
                rel_path = "/" .. original_sub_path
            elseif original_sub_path == "" then
                 rel_path = "/"
            else
                rel_path = original_sub_path
            end
        end
      end
      image_path_for_text = utils.normalize_slashes(rel_path)
    end
  end

  local alt_text
  if desired_filename_stem and desired_filename_stem ~= "" then
    alt_text = desired_filename_stem
  else
    alt_text = utils.extract_filename_stem(new_filename_only)
  end
  local text_to_insert
  local s_count = 0
  for _ in string.gmatch(custom_text_format, "%%s") do s_count = s_count + 1 end

  if s_count == 1 then text_to_insert = string.format(custom_text_format, image_path_for_text)
  elseif s_count >= 2 then text_to_insert = string.format(custom_text_format, alt_text, image_path_for_text)
  else text_to_insert = image_path_for_text
  end
  return text_to_insert
end

return M