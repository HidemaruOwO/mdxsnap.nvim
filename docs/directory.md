# Directory Structure and Lua Modules

This document provides a brief overview of the Lua modules within the `lua/mdxsnap/` directory.

## `lua/mdxsnap/core.lua`

*   **Contains**: The main logic that orchestrates the image pasting workflow by coordinating calls to other specialized modules. It houses the primary `paste_image` function.

## `lua/mdxsnap/utils.lua`

*   **Contains**: General-purpose utility functions. These include helpers for path normalization, OS type detection, URL decoding, and string manipulation for filenames.

## `lua/mdxsnap/fs_utils.lua`

*   **Contains**: Functions related to file system operations. This involves tasks like finding the project root, managing temporary directories, copying image files, and ensuring necessary target directories exist.

## `lua/mdxsnap/clipboard.lua`

*   **Contains**: OS-specific logic for accessing the system clipboard. Its primary role is to fetch image data or file paths from the clipboard across different platforms (macOS, Linux, Windows).

## `lua/mdxsnap/editor_utils.lua`

*   **Contains**: Utilities specific to editor interactions and MDX/Markdown file processing. This includes determining active configurations, managing import statements, and formatting the text that references the pasted image.