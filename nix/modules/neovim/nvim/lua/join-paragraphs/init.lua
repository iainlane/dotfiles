local api = vim.api
local fn = vim.fn

--- Determines if the start and end positions from a visual selection need to be
--- swapped to ensure start_pos represents the visually earlier position.
---@param start_pos table Result of vim.fn.getpos('v') {bufnum, lnum, col, off}
---@param end_pos table Result of vim.fn.getpos('.') {bufnum, lnum, col, off}
---@return boolean true if positions should be swapped.
local function should_swap(start_pos, end_pos)
  if start_pos[2] > end_pos[2] then
    return true
  end

  if start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3] then
    return true
  end

  return false
end

--- Safely get the content of a specific line number.
---@param lnum integer The 1-based line number to get.
---@return string? The content of the line, or nil if invalid or error.
local function getline_safe(lnum)
  if lnum <= 0 then
    return nil
  end

  local buf = api.nvim_get_current_buf()

  local ok, lines = pcall(api.nvim_buf_get_lines, buf, lnum - 1, lnum, false)
  if ok and lines and #lines > 0 then
    return lines[1]
  end

  return nil
end

local function error_msg(msg, title)
  vim.notify(msg, vim.log.levels.ERROR, { title = title or "Join Paragraphs" })
end

local function warn_msg(msg, title)
  vim.notify(msg, vim.log.levels.WARN, { title = title or "Join Paragraphs" })
end

--- Execute `:global ... join` command on a calculated range. Handles
--- adding/removing a temporary blank line at the end if needed, preserving any
--- existing user mark that might collide with the temporary mark, using the
--- nvim_buf_*_mark Lua APIs.
---@param start_line integer The 1-based starting line number for the :global command range.
---@param end_line integer The 1-based ending line number for the :global command range.
---@return boolean success True if the command executed without pcall error, false otherwise.
local function perform_join_on_range(start_line, end_line)
  local buf = api.nvim_get_current_buf()
  local buf_last_line = api.nvim_buf_line_count(buf)

  -- Validate and clamp the range
  if not (start_line and end_line and start_line > 0 and end_line > 0) then
    error_msg(
      string.format("Invalid range passed (nil or zero): start=%s, end=%s", tostring(start_line), tostring(end_line))
    )
    return false
  end

  if start_line > end_line then
    -- Allow joining a single line (start == end), but not reversed range.
    -- This can happen if marks '[ and '] are the same line after paste/read.
    if start_line ~= end_line then
      error_msg(string.format("Invalid range passed (start > end): %d, %d", start_line, end_line))
      return false
    end
  end

  if start_line <= 0 then
    start_line = 1
  end

  if end_line > buf_last_line then
    end_line = buf_last_line
  end

  if start_line > end_line then
    error_msg(string.format("Range became invalid after clamping: start %d > end %d", start_line, end_line))
    return false
  end

  -- Handle single line case - nothing to join
  if start_line == end_line then
    -- warn_msg("Range is only a single line, nothing to join.", "Join Paragraphs")
    -- Decided against warning, as single-line paste/read is valid.
    return true -- Technically successful, just no work done.
  end

  local view = fn.winsaveview()

  local temp_mark_char = "Z"
  local original_mark_pos = nil
  local ok_get, mark_info = pcall(api.nvim_buf_get_mark, buf, temp_mark_char)
  if ok_get and mark_info and mark_info[1] > 0 then
    original_mark_pos = mark_info
  end

  local last_line_in_range = getline_safe(end_line) or ""
  local added_blank = false
  local ok_join = true

  -- Check if we need to add a temporary blank line
  if last_line_in_range:match("%S") then
    -- Add temporary blank line after our range
    local ok_add, err_add = pcall(api.nvim_buf_set_lines, buf, end_line, end_line, false, { "" })
    if not ok_add then
      error_msg("Failed to add temporary blank line: " .. tostring(err_add))
      fn.winrestview(view)
      return false
    end

    -- Mark the blank line we just added
    local ok_mark, err_mark = pcall(api.nvim_buf_set_mark, buf, temp_mark_char, end_line + 1, 0, {})
    if not ok_mark then
      local ok_cleanup, _ = pcall(api.nvim_buf_set_lines, buf, end_line, end_line + 1, false, {})
      if not ok_cleanup then
        error_msg("Failed to clean up after mark setting failure")
      end
      error_msg("Failed to set temporary mark: " .. tostring(err_mark))
      fn.winrestview(view)
      return false
    end

    added_blank = true

    -- Run the join command on the original range. Use end_line - 1 because the
    -- join logic (`.,/^\s*$/-1`) stops before a blank line. Since we added one,
    -- we need to make sure the global command still considers the *original*
    -- last line.
    local range_prefix = string.format("%d,%d", start_line, end_line)
    local cmd = string.format([[ %sglobal /\v^./ .,/\v^\s*$/-1 join ]], range_prefix)
    local ok, err_join = pcall(api.nvim_command, "silent! " .. cmd)
    ok_join = ok

    if not ok_join then
      error_msg("Join command failed: " .. tostring(err_join))
    end
  else
    -- No need for a temporary line, run the command on the whole range
    local range_prefix = string.format("%d,%d", start_line, end_line)
    local cmd = string.format([[ %sglobal /\v^./ .,/\v^\s*$/-1 join ]], range_prefix)
    local ok, err_join = pcall(api.nvim_command, "silent! " .. cmd)
    ok_join = ok

    if not ok_join then
      error_msg("Join command failed: " .. tostring(err_join))
    end
  end

  -- Clean up: remove the temporary blank line using our mark
  if added_blank then
    local ok_get_after, mark_pos_after = pcall(api.nvim_buf_get_mark, buf, temp_mark_char)
    if ok_get_after and mark_pos_after and mark_pos_after[1] > 0 then
      local mark_line = mark_pos_after[1]
      local line_content = getline_safe(mark_line)
      if line_content and line_content:match("^%s*$") then
        local ok_del, err_del = pcall(api.nvim_buf_set_lines, buf, mark_line - 1, mark_line, false, {})
        if not ok_del then
          warn_msg("Failed to remove temporary blank line: " .. tostring(err_del))
        end
      end
    else
      warn_msg("Could not find temporary mark after join")
    end
  end

  -- Restore original mark if it existed
  if original_mark_pos then
    local ok_restore, err_restore =
      pcall(api.nvim_buf_set_mark, buf, temp_mark_char, original_mark_pos[1], original_mark_pos[2], {})
    if not ok_restore then
      warn_msg("Failed to restore original mark: " .. tostring(err_restore))
    end
  elseif added_blank then
    -- Delete our temporary mark if we created one and no original existed
    local ok_del_mark, err_del_mark = pcall(api.nvim_buf_del_mark, buf, temp_mark_char)
    if not ok_del_mark then
      warn_msg("Failed to delete temporary mark: " .. tostring(err_del_mark))
    end
  end

  fn.winrestview(view)
  return ok_join
end

---@class Range
---@field start_line integer Start line of the range.
---@field end_line integer End line of the range.

--- Calculate the expanded paragraph range based on visual selection.
---@return Range? {start_line: integer, end_line: integer} or nil if error
local function calculate_expanded_visual_range()
  local buf = api.nvim_get_current_buf()
  local buf_last_line = api.nvim_buf_line_count(buf)

  local start_pos = fn.getpos("v")
  local end_pos = fn.getpos(".")

  if should_swap(start_pos, end_pos) then
    start_pos, end_pos = end_pos, start_pos
  end

  local initial_start_line = start_pos[2]
  local initial_end_line = end_pos[2]

  if not (initial_start_line > 0 and initial_end_line > 0) then
    error_msg(
      string.format(
        "Invalid initial visual range from getpos: start=%s, end=%s",
        tostring(initial_start_line),
        tostring(initial_end_line)
      )
    )
    return nil
  end
  if initial_start_line > initial_end_line then
    initial_start_line, initial_end_line = initial_end_line, initial_start_line
  end

  local start_line = 1
  -- Go up from the start of the visual selection to find the preceding blank
  -- line or buffer start

  -- Save cursor for search
  local original_cursor_search = fn.getpos(".")

  -- Move cursor temporarily for search context
  fn.setpos(".", { 0, initial_start_line, 1, 0 })

  -- Search backwards ('b') from current line ('') non-wrapping ('W')
  local prev_blank_pos = fn.searchpos("^\\s*$", "bnW")
  fn.setpos(".", original_cursor_search) -- Restore cursor

  local prev_blank_line = prev_blank_pos[1]

  -- Default to starting from the top
  start_line = 1

  if prev_blank_line > 0 then
    start_line = prev_blank_line + 1
  end

  -- Ensure the found start_line is not blank itself, if so, find the next non-blank
  local current_start_content = getline_safe(start_line)
  while current_start_content ~= nil and not current_start_content:match("%S") do
    start_line = start_line + 1
    current_start_content = getline_safe(start_line)
    if start_line > buf_last_line then
      error_msg("Could not find start of paragraph.", "Join Paragraphs Visual")
      return nil
    end
  end

  -- Go down from the end of the visual selection to find the next blank line or buffer end
  local end_line = buf_last_line
  fn.setpos(".", { 0, initial_end_line, 1, 0 }) -- Move cursor temporarily for search context
  local next_blank_pos = fn.searchpos("^\\s*$", "nW") -- Search forwards ('') from current line ('') non-wrapping ('W')
  fn.setpos(".", original_cursor_search) -- Restore cursor
  local next_blank_line = next_blank_pos[1]

  if next_blank_line > 0 then
    end_line = next_blank_line - 1
  else -- No succeeding blank line found, end at the last line
    end_line = buf_last_line
  end

  -- Ensure the found end_line is not blank itself (unless it's the same as start_line)
  -- If it is blank, move up one line.
  local current_end_content = getline_safe(end_line)
  if current_end_content ~= nil and not current_end_content:match("%S") and end_line > start_line then
    end_line = end_line - 1
  end

  if start_line <= 0 then
    start_line = 1
  end
  if end_line < start_line then
    end_line = start_line
  end

  return { start_line = start_line, end_line = end_line }
end

--- Join whole buffer
local function action_normal()
  local buf_last_line = api.nvim_buf_line_count(0)
  if buf_last_line == 0 then
    warn_msg("Buffer is empty, nothing to join.")
    return
  end
  perform_join_on_range(1, buf_last_line)
end

--- Join paragraphs in visual mode. The selected range will be expanded to
--- encompass entire paragraphs covered by selection.
local function action_visual()
  local range = calculate_expanded_visual_range()
  if range then
    perform_join_on_range(range.start_line, range.end_line)
  end
  -- Exit visual mode after the action if still in it
  if fn.mode(true):find("^[vV]") then
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end
end

--- Join paragraphs in a specified range.
---@param line1 integer Start line of the range.
---@param line2 integer End line of the range.
local function action_range(line1, line2)
  perform_join_on_range(line1, line2)
end

--- Performs a paste operation (normal or visual replace) and then joins
--- paragraphs within the pasted range.
---@param mode string 'n' for normal mode paste, 'v' for visual mode replace paste
local function action_paste_and_join(mode)
  local title = "Paste and Join"

  -- Get the register specified by the user.
  local register_char = vim.v.register == "" and '"' or vim.v.register
  local command = string.format('normal! "%sp"', register_char)

  -- Execute the paste command
  local ok_paste, err_paste = pcall(vim.cmd, command)
  if not ok_paste then
    error_msg("Paste operation failed: " .. tostring(err_paste), title)
    return
  end

  -- Get the range of the pasted text using marks set by Vim. vim.fn.line
  -- returns 0 if the mark is not set
  local start_line = fn.line("'[")
  local end_line = fn.line("']")

  if start_line <= 0 or end_line <= 0 then
    warn_msg("Could not determine pasted range (marks '[ or '] not set). No join performed.", title)
    return
  end

  -- Perform the join on the pasted range
  if start_line <= end_line then
    perform_join_on_range(start_line, end_line)
  else
    warn_msg(
      string.format("Pasted range marks seem reversed ('[=%d > ']=%d). No join performed.", start_line, end_line),
      title
    )
  end
end

--- Reads a file below the current line and then joins paragraphs within the
--- read range.
---@param filename string The path to the file to read.
local function action_read_and_join(filename)
  local title = "Read and Join"
  if not filename or filename == "" then
    error_msg("No filename provided.", title)
    return
  end

  local escaped_filename = fn.fnameescape(filename)

  -- Execute the read command
  local ok_read, err_read = pcall(vim.cmd, "read " .. escaped_filename)
  if not ok_read then
    error_msg("Read command failed: " .. tostring(err_read), title)
    return
  end

  -- Get the range of the read text using marks set by Vim
  local start_line = fn.line("'[")
  local end_line = fn.line("']")

  if start_line <= 0 or end_line <= 0 then
    warn_msg("Could not determine read range (marks '[ or '] not set). No join performed.", title)
    return
  end

  -- Perform the join on the read range
  if start_line <= end_line then
    perform_join_on_range(start_line, end_line)
  else
    warn_msg(
      string.format("Read range marks seem reversed ('[=%d > ']=%d). No join performed.", start_line, end_line),
      title
    )
  end
end

local M = {}

---@class (exact) KeyMaps
---@field join_paragraphs string Keymap for joining paragraphs (e.g., "<Leader>jj").
---@field paste_join string Keymap for paste-and-join (e.g.,

---@class (exact) Options
---@field keymaps? KeyMaps Keymap configuration. Set to `nil` to disable keymap creation

---@type Options
M.defaults = {
  keymaps = {
    -- Default keymap for joining paragraphs
    join_paragraphs = "<Leader>jj",
    -- Default keymap for paste-and-join
    paste_join = "<Leader>jp",
  },
}

--- Install the keymaps and create the user commands.
---@param opts? Options User configuration options. Merged with defaults.
function M.setup(opts)
  -- Merge user options with defaults
  ---@type Options
  local config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  api.nvim_create_user_command("JoinParagraphs", function(args)
    if args.range == 0 then
      action_normal()
    else
      action_range(args.line1, args.line2)
    end
  end, {
    range = true,
    nargs = 0,
    desc = "Join paragraphs (whole buffer if no range, exact range if specified)",
  })

  api.nvim_create_user_command("Rj", function(args)
    if #args.fargs ~= 1 then
      error_msg("Usage: :Rj <filename>", "Read and Join")
      return
    end

    action_read_and_join(args.fargs[1])
  end, {
    nargs = 1,
    complete = "file", -- Provide file completion
    desc = "Read file content below cursor and Join paragraphs",
  })

  if not config.keymaps then
    return
  end

  vim.keymap.set(
    "n",
    config.keymaps.join_paragraphs,
    action_normal,
    { noremap = true, silent = true, desc = "Join all paragraphs" }
  )
  vim.keymap.set(
    "v",
    config.keymaps.join_paragraphs,
    action_visual,
    { noremap = true, silent = true, desc = "Join paragraph(s) in selection (expanded)" }
  )

  vim.keymap.set("n", config.keymaps.paste_join, function()
    action_paste_and_join("n")
  end, { noremap = true, silent = true, desc = "Paste and Join paragraphs" })
  vim.keymap.set("v", config.keymaps.paste_join, function()
    action_paste_and_join("v")
  end, { noremap = true, silent = true, desc = "Paste (replace) and Join paragraphs" })
end

return M
