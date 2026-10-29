-- Location: lua/editable-file-search.lua
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>

-- The search is a plain modifiable scratch buffer. Line 1 is the query, and
-- every line below it is a result: a path relative to the directory searched.
-- Both are ordinary text, so anything that edits text works on them.
--
-- Changing line 1 runs the query over the whole file list again and redraws
-- the results. Nothing else is ever redrawn, so the results can be whittled
-- down by hand -- dd, :g/foo/d, :v/foo/d, :Narrow -- and stay that way until
-- the query changes. Undo and redo are taken as they come: they put back text
-- that was right at the time, narrowing included (see M.sync).
--
-- The labels ("Query:", the result counts) are extmarks, not text, so they
-- can't be deleted or yanked, or read back as a path.

local M = {}

local scheme = 'filesearch://'
local ns = vim.api.nvim_create_namespace('editable-file-search')
local match_ns = vim.api.nvim_create_namespace('editable-file-search-match')

-- Hidden files and symlinks in, but not the inside of .git, which --hidden
-- would otherwise let in too.
local default_command = { 'rg', '--files', '--hidden', '--follow', '--no-messages', '--glob=!.git/' }

-- Keyed by buffer number:
--   root     the directory searched; results are relative to it
--   files    every file under root, sorted
--   query    the query the results were last drawn for
--   matches  the results that query gives, before any narrowing
--   seq_last, seq_cur  the undo state as of the last sync, to tell undo from edits
local state = {}

local function find_buffer(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
end

local function list_files(root)
  local cmd = vim.g.editable_file_search_command or default_command
  -- vim.system throws, rather than returning an error, when cmd[1] isn't installed
  local ok, result = pcall(function()
    return vim.system(cmd, { cwd = root, text = true }):wait()
  end)
  if not ok then
    vim.notify('editable-file-search: could not run ' .. cmd[1] .. ': ' .. result, vim.log.levels.ERROR)
    return {}
  end
  local files = vim.split(result.stdout or '', '\n', { trimempty = true })
  -- rg walks the tree in parallel, so its order changes from run to run.
  --   matchfuzzy breaks ties in list order, so this keeps those stable too.
  table.sort(files)
  return files
end

local function searching(query)
  return query:find('%S') ~= nil
end

local function match(files, query)
  if not searching(query) then
    return files
  end
  return vim.fn.matchfuzzy(files, query)
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function results(buf)
  return vim.api.nvim_buf_get_lines(buf, 1, -1, false)
end

-- Writes the results without touching line 1. Skipped when nothing would
-- change, so that it never adds an empty step to undo.
local function set_results(buf, lines)
  if not same(results(buf), lines) then
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, lines)
  end
end

local function count(n)
  return (tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

local function plural(n, one, many)
  return count(n) .. ' ' .. (n == 1 and one or many)
end

local function summary(st, shown, narrowed)
  local files = plural(#st.files, 'file', 'files') .. ' in ' .. vim.fn.fnamemodify(st.root, ':~')
  local from
  if not searching(st.query) then
    from = 'all ' .. files
  elseif #st.matches == 0 then
    from = 'no matches among ' .. files
  else
    from = plural(#st.matches, 'match', 'matches') .. ' among ' .. files
  end
  if narrowed then
    return count(shown) .. ' left of ' .. from, '   u undoes · editing the query starts over'
  end
  return from, '   <CR> opens · :Narrow {words} narrows'
end

-- Redraws the labels from what the buffer says now. The results count as
-- narrowed whenever they are not exactly what the query gives -- however they
-- got that way: :Narrow, dd, :g/foo/d, a paste, or undoing back to any of those.
local function decorate(buf)
  local st = state[buf]
  local shown = results(buf)
  local narrowed = not same(shown, st.matches)
  local label = narrowed
      and { { 'Query', 'FileSearchLabel' }, { ' (Note: NARROWED)', 'FileSearchNarrowed' }, { ': ', 'FileSearchLabel' } }
    or { { 'Query: ', 'FileSearchLabel' } }
  local text, hint = summary(st, #shown, narrowed)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = label,
    virt_text_pos = 'inline',
    -- Text typed at the start of the query goes after the label, not before it
    right_gravity = false,
    virt_lines = { { { 'Results: ' .. text, 'FileSearchLabel' }, { hint, 'FileSearchSummary' } } },
  })
  -- 'nofile' already keeps it from blocking :quit, but :bdelete through
  --   mini.bufremove asks to save anything 'modified'
  vim.bo[buf].modified = false
end

local function remember_undo_state(buf)
  local tree = vim.fn.undotree(buf)
  state[buf].seq_last, state[buf].seq_cur = tree.seq_last, tree.seq_cur
end

-- Brings the results and labels in line with the text, after any change.
--
-- A new edit to line 1 redraws the results for the new query. Undo and redo
-- don't, even when they change line 1: they restore the results that went
-- with that query at the time, which may have been narrowed since, and
-- redrawing them would throw that away -- and, being a new change, would cut
-- off redo as well. The two are told apart by the undo tree: an edit adds an
-- undo entry, or (typing on in Insert mode) extends the newest one, but undo
-- and redo only move seq_cur along the existing entries.
--
-- The redraw needs no :undojoin to share an undo step with the edit that
-- caused it. TextChanged runs before nvim waits for the next key, and waiting
-- for a key is where undo steps are cut, so one u takes back both anyway.
function M.sync(buf)
  local st = state[buf]
  if not st then
    return
  end
  local query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  local tree = vim.fn.undotree(buf)
  local undoing = tree.seq_last == st.seq_last and tree.seq_cur ~= st.seq_cur
  if query ~= st.query then
    st.query = query
    st.matches = match(st.files, query)
    if not undoing then
      -- Written even when it comes out the same: nvim doesn't redraw lines
      --   it sees as unchanged, so they'd keep the old query's highlights
      vim.api.nvim_buf_set_lines(buf, 1, -1, false, st.matches)
    end
  end
  remember_undo_state(buf)
  decorate(buf)
end

-- Opens the file named on the cursor line in this window. From the query
-- line, that is the top result.
function M.open_under_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local st = state[buf]
  if not st then
    return
  end
  -- Typed ahead fast enough, the query can be changed with no TextChanged
  --   between it and this, leaving the results a query behind
  M.sync(buf)
  local row = math.max(vim.api.nvim_win_get_cursor(0)[1], 2)
  local line = vim.trim(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or '')
  if line == '' then
    vim.api.nvim_echo({ { 'No file under cursor' } }, false, {})
    return
  end
  -- Relative to the directory searched, not the cwd, which may have moved
  --   since. Lines typed or pasted in as absolute paths are taken as they are.
  --   Not expand(), which would also act on any %, # or * in the name.
  local path = line
  if vim.startswith(path, '~/') then
    path = vim.env.HOME .. path:sub(2)
  elseif not vim.startswith(path, '/') then
    path = st.root .. '/' .. path
  end
  -- :edit, unlike nvim_win_set_buf, records the jump, so CTRL-O comes back here
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

-- Keeps only the results that fuzzy-match {words}, in the order they were in.
function M.narrow(buf, words)
  M.sync(buf)
  local shown = results(buf)
  local keep = {}
  for _, line in ipairs(vim.fn.matchfuzzy(shown, words)) do
    keep[line] = true
  end
  set_results(buf, vim.tbl_filter(function(line)
    return keep[line] ~= nil
  end, shown))
  M.sync(buf)
end

-- Sets up a buffer named filesearch://<dir> as a search of <dir>. Called on
-- BufReadCmd, so this is also what rebuilds one restored from a session.
function M.setup(buf)
  local root = vim.api.nvim_buf_get_name(buf):sub(#scheme + 1)
  root = root ~= '' and vim.fs.normalize(root) or vim.fn.getcwd()

  -- 'bufhidden' is hide rather than wipe because wiping drops a buffer's
  --   jumplist entries, and coming back with CTRL-O is the point
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = true
  -- So gf, CTRL-W f and friends find results even after a :cd
  vim.bo[buf].path = (root:gsub('[, \\]', '\\%0'))

  local files = list_files(root)
  state[buf] = { root = root, files = files, query = '', matches = files }

  -- Kept out of undo: the first text isn't an edit, and u should never be
  --   able to empty the buffer
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ '' }, files))
  vim.bo[buf].undolevels = undolevels

  local group = vim.api.nvim_create_augroup('EditableFileSearch' .. buf, {})
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      M.sync(buf)
    end,
  })
  -- Unloading (:bdelete) empties the buffer; entering it again reads it, and
  --   so sets it up, afresh
  vim.api.nvim_create_autocmd('BufUnload', {
    group = group,
    buffer = buf,
    callback = function()
      state[buf] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })

  vim.keymap.set('n', '<CR>', M.open_under_cursor, { buffer = buf, desc = 'Open file under cursor' })
  -- On the query line, Enter opens the top result, as in fzf. Anywhere else
  --   it's an ordinary Enter.
  vim.keymap.set('i', '<CR>', function()
    if vim.api.nvim_win_get_cursor(0)[1] == 1 then
      return '<Esc><Cmd>lua require("editable-file-search").open_under_cursor()<CR>'
    end
    return '<CR>'
  end, { buffer = buf, expr = true, desc = 'Open top result from the query line' })
  vim.api.nvim_buf_create_user_command(buf, 'Narrow', function(opts)
    M.narrow(buf, opts.args)
  end, { nargs = '+', desc = 'Keep only the results that fuzzy-match {words}' })

  vim.bo[buf].filetype = 'filesearch'
  remember_undo_state(buf)
  decorate(buf)
end

-- Starts a fresh search of the cwd in this window, prefilled with {query}.
--
-- There is one search buffer per directory. If this one already exists it is
-- reused, its file list refreshed, and the old search replaced -- as an
-- ordinary change, so u brings the old search back.
function M.open(query)
  query = query or ''
  local name = scheme .. vim.fn.getcwd()
  local buf = find_buffer(name)
  local existing = buf ~= nil and state[buf] ~= nil
  if buf == nil then
    vim.cmd('edit ' .. vim.fn.fnameescape(name))
  elseif buf ~= vim.api.nvim_get_current_buf() then
    -- Not loaded (restored from a session, say), :buffer reads it in again
    vim.cmd('buffer ' .. buf)
  end
  buf = vim.api.nvim_get_current_buf()
  if not state[buf] then
    M.setup(buf)
  end
  local st = state[buf]
  if existing then
    -- A new buffer listed them just now
    st.files = list_files(st.root)
  end

  st.query = query
  st.matches = match(st.files, query)
  local lines = vim.list_extend({ query }, st.matches)
  if not same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  remember_undo_state(buf)
  decorate(buf)

  vim.api.nvim_win_set_cursor(0, { 1, #query })
  vim.cmd('startinsert!')
end

vim.api.nvim_set_decoration_provider(match_ns, {
  -- Highlights where each visible result matched the query. Worked out per
  -- redraw for just the lines on screen: marking every match up front would
  -- mean one extmark per matched character across the whole file list.
  on_win = function(_, _, buf, toprow, botrow)
    local st = state[buf]
    if not st or not searching(st.query) then
      return false
    end
    local first = math.max(toprow, 1)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, botrow + 1, false)) do
      -- matchfuzzypos drops non-matches, so one line at a time keeps rows straight
      local hit = vim.fn.matchfuzzypos({ line }, st.query)[2][1] or {}
      for _, char in ipairs(hit) do
        vim.api.nvim_buf_set_extmark(buf, match_ns, first + i - 1, vim.fn.byteidx(line, char), {
          end_col = vim.fn.byteidx(line, char + 1),
          hl_group = 'FileSearchMatch',
          ephemeral = true,
        })
      end
    end
    return false
  end,
})

return M
