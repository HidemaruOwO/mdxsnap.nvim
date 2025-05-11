local core = require("mdxsnap.core")
local config = require("mdxsnap.config")

vim.api.nvim_create_user_command("PasteImage", function()
	core.paste_image()
end, {
	nargs = 0,
	desc = "Paste image from clipboard and insert into MDX/Markdown (mdxsnap)",
})

vim.defer_fn(function()
	local current_default_path = vim.fn.expand(config.options.DefaultPastePath)
	local current_default_type = config.options.DefaultPastePathType

	if
		current_default_path == vim.fn.expand("mdxsnaps_data/images/posts")
		and current_default_type == "relative"
		and (not config.options.ProjectOverrides or #config.options.ProjectOverrides == 0)
	then
		-- vim.notify(
		--   "mdxsnap: Using default configuration. Consider setting up project-specific paths in your config.",
		--   vim.log.levels.INFO,
		--   { title = "mdxsnap" }
		-- )
	end
end, 100)
