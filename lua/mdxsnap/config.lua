local M = {}

M.options = {
  -- Base directory for saving images
  -- When PastePathType is "relative", this is relative to project root
  -- When PastePathType is "absolute", this is used as-is
  DefaultPastePath = "mdxsnaps_data/images/posts",
  DefaultPastePathType = "relative", -- "relative" or "absolute"

  -- Override default settings for specific projects
  -- Rules are evaluated in order, first match is used
  ProjectOverrides = {
    -- Example: Override by project directory name
    -- {
    --   matchType = "projectName",
    --   matchValue = "my-blog",
    --   PastePath = "public/images",
    --   PastePathType = "relative",
    --   customImports = {
    --     { line = 'import { SpecificImage } from "@/components/SpecificImage";', checkRegex = "SpecificImage" },
    --   },
    --   customTextFormat = "<SpecificImage src=\"%s\" alt=\"%s\" />",
    -- },
    -- Example: Override by project full path
    -- {
    --   matchType = "projectPath",
    --   matchValue = "~/projects/portfolio", -- Supports shell vars (~, $HOME)
    --   PastePath = "/var/www/portfolio/images",
    --   PastePathType = "absolute",
    --   customTextFormat = "![Portfolio Image: %s](%s)",
    -- },
  },

  -- Import statements to ensure in MDX files
  -- These are added if not already present
  customImports = {
  --  {
  --    line = 'import { Image } from "astro:assets";',
  --    checkRegex = 'astro:assets',
  --  },
  },

  -- Text format for image references
  -- Use %s for placeholders:
  -- One %s: Replaced with image path
  -- Two %s: First is alt text (filename stem), second is path
  customTextFormat = "![%s](%s)", -- Markdown format
}

M.setup = function(user_options)
  if user_options and user_options.ProjectOverrides then
    M.options.ProjectOverrides = user_options.ProjectOverrides
    user_options.ProjectOverrides = nil
  end
  M.options = vim.tbl_deep_extend("force", M.options, user_options or {})
end

return M