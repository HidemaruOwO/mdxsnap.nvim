local config = require("mdxsnap.config")

local M = {}

-- Export setup function for standard Neovim plugin pattern
M.setup = function(user_options)
  config.setup(user_options)
end

-- Export core functionality for backwards compatibility
M.paste_image = function(desired_filename_stem)
  local core = require("mdxsnap.core")
  core.paste_image(desired_filename_stem)
end

-- Export config for backwards compatibility
M.config = config

-- Export options for direct access
M.options = config.options

return M