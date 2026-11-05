-- Location: lua/editable-file-search.lua
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>

-- The search is a plain modifiable scratch buffer. Line 1 is the query, and
-- every line below it is a result: a path relative to the directory searched.
-- Both are ordinary text, so anything that edits text works on them.
--
-- Changing line 1 runs the query over the whole file list again and redraws
-- the results. Nothing else is ever redrawn, so the results can be whittled
-- down by hand -- dd, :g/foo/d, :v/foo/d, :NARROW -- and stay that way until
-- the query changes. Undo and redo are taken as they come: they put back text
-- that was right at the time, narrowing included (see M.sync).
--
-- The file list comes from a command and some flags. :CHANGEFLAGS lists the
-- files again with other flags, in the same buffer, and starts the results
-- and undo over (see M.change_flags).
--
-- The labels ("Query:", the command, the result counts, the rule under them)
-- are extmarks, not text, so they can't be edited, deleted or yanked, or read
-- back as a path.

local M = {}

local scheme = 'filesearch://'
local ns = vim.api.nvim_create_namespace('editable-file-search')
local match_ns = vim.api.nvim_create_namespace('editable-file-search-match')

-- The part of the command :CHANGEFLAGS leaves alone. --files has rg list the
-- files rather than search them.
local default_command = { 'rg', '--files', '--no-messages' }

-- The flags :CHANGEFLAGS asks about, in this order, and whether a new search
-- starts with them: hidden files and symlinks in, but not the inside of .git,
-- which --hidden would otherwise let in too.
local default_prompts = {
  { flag = '--hidden', default = true },
  { flag = '--glob=!.git/', default = true },
  { flag = '--no-ignore', default = false },
  { flag = '--follow', default = true },
}

-- Keyed by buffer number:
--   root     the directory searched; results are relative to it
--   command, flags  what listed the files, as lists of words
--   files    every file under root, sorted
--   query    the query the results were last drawn for
--   matches  the results that query gives, before any narrowing
--   seq_last, seq_cur  the undo state as of the last sync, to tell undo from edits
local state = {}

-- A command or a flag is a list of words, taken as they are, or a string,
-- split into words at whitespace. It's run without a shell, so there is no
-- quoting: a word with a space in it needs the list.
local function words(value)
  if type(value) == 'string' then
    return vim.split(value, '%s+', { trimempty = true })
  end
  return vim.deepcopy(value or {})
end

local function command()
  return words(vim.g.editable_file_search_command or default_command)
end

-- From Vimscript, a default can come as 1 or 0 as well as v:true or v:false
local function prompts()
  local list = {}
  for _, prompt in ipairs(vim.g.editable_file_search_flag_prompts or default_prompts) do
    local flag = words(prompt.flag)
    if #flag > 0 then
      table.insert(list, { flag = flag, default = prompt.default == true or prompt.default == 1 })
    end
  end
  return list
end

-- A flag can be more than one word, -g !.git/ say. Having it means having
-- its words together and in order, as whole words: --no-ignore-vcs doesn't
-- count as --no-ignore.
local function at(flags, flag, i)
  for j = 1, #flag do
    if flags[i + j - 1] ~= flag[j] then
      return false
    end
  end
  return #flag > 0
end

local function has(flags, flag)
  for i = 1, #flags do
    if at(flags, flag, i) then
      return true
    end
  end
  return false
end

local function with(flags, flag)
  if has(flags, flag) then
    return flags
  end
  return vim.list_extend(vim.deepcopy(flags), flag)
end

-- Every time it appears
local function without(flags, flag)
  local kept, i = {}, 1
  while i <= #flags do
    if at(flags, flag, i) then
      i = i + #flag
    else
      table.insert(kept, flags[i])
      i = i + 1
    end
  end
  return kept
end

-- The words after :CHANGEFLAGS, as flags: a word starting with -, and the
-- words after it that don't, which are its values. -g !.git/ --hidden is two.
local function split_flags(args)
  local flags = {}
  for _, word in ipairs(args) do
    if #flags == 0 or vim.startswith(word, '-') then
      table.insert(flags, { word })
    else
      table.insert(flags[#flags], word)
    end
  end
  return flags
end

local function default_flags()
  local flags = {}
  for _, prompt in ipairs(prompts()) do
    if prompt.default then
      flags = with(flags, prompt.flag)
    end
  end
  return flags
end

local function find_buffer(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
end

-- Every search is a buffer of its own, named filesearch://<n><directory>,
-- where n tells apart searches of the same directory. Taken numbers are
-- skipped: those of searches still around, hidden or unloaded (:bdelete)
-- included, so that no new search lands in an old one's buffer.
local function new_name(root)
  local n = 1
  while find_buffer(scheme .. n .. root) do
    n = n + 1
  end
  return scheme .. n .. root
end

-- The directory a search buffer is named after. The directory is absolute,
-- so it can't start with a digit. Names from before searches were numbered
-- have no n, and read the same way.
local function root_of(buf)
  local root = vim.api.nvim_buf_get_name(buf):sub(#scheme + 1):gsub('^%d+', '', 1)
  return root ~= '' and vim.fs.normalize(root) or vim.fn.getcwd()
end

-- Every file under root, as the command and flags list them, sorted. If the
-- command fails, nil and why.
local function list_files(root, cmd, flags)
  local argv = vim.list_extend(vim.deepcopy(cmd), flags)
  -- vim.system throws, rather than returning an error, when argv[1] isn't installed
  local ok, result = pcall(function()
    return vim.system(argv, { cwd = root, text = true }):wait()
  end)
  if not ok then
    return nil, 'could not run ' .. tostring(argv[1]) .. ': ' .. result
  end
  local files = vim.split(result.stdout or '', '\n', { trimempty = true })
  -- Failed only if it listed nothing and says why: rg exits 1 when there are
  --   no files at all, and 2 when it listed what it could but couldn't read
  --   some directory -- which --no-messages keeps quiet about
  local err = vim.trim(result.stderr or '')
  if result.code ~= 0 and #files == 0 and err ~= '' then
    return nil, err
  end
  -- rg walks the tree in parallel, so its order changes from run to run.
  --   matchfuzzy breaks ties in list order, so this keeps those stable too.
  table.sort(files)
  return files
end

local function fail(err)
  vim.notify('editable-file-search: ' .. err, vim.log.levels.ERROR)
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
  return from, '   <CR> opens · :NARROW {text} narrows fuzzily'
end

-- The command as it was run. A word with a space in it is quoted, or it would
-- read as more than one.
local function command_line(st)
  return table.concat(vim.tbl_map(function(word)
    return (word == '' or word:find('%s')) and vim.fn.shellescape(word) or word
  end, vim.list_extend(vim.deepcopy(st.command), st.flags)), ' ')
end

-- Redraws the labels from what the buffer says now. The results count as
-- narrowed whenever they are not exactly what the query gives -- however they
-- got that way: :NARROW, dd, :g/foo/d, a paste, or undoing back to any of those.
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
    virt_lines = {
      {
        { 'Command: ', 'FileSearchLabel' },
        { command_line(st), 'FileSearchText' },
        { '   change with :CHANGEFLAGS', 'FileSearchSummary' },
      },
      { { 'Results: ', 'FileSearchLabel' }, { text, 'FileSearchText' }, { hint, 'FileSearchSummary' } },
      -- A rule under it all, so the results read as apart from the header.
      --   As wide as the screen, which no window is wider than: a virtual
      --   line is cut off at the window's edge, so it fits every window the
      --   buffer is in, whatever their widths
      { { ('─'):rep(vim.o.columns), 'FileSearchSeparator' } },
    },
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

-- Keeps only the results that fuzzy-match {text}, in the order they were in.
function M.narrow(buf, text)
  M.sync(buf)
  local shown = results(buf)
  local keep = {}
  for _, line in ipairs(vim.fn.matchfuzzy(shown, text)) do
    keep[line] = true
  end
  set_results(buf, vim.tbl_filter(function(line)
    return keep[line] ~= nil
  end, shown))
  M.sync(buf)
end

-- Asks about each flag prompt in turn: always all of them, in the same order,
-- so that the answers can be typed ahead from memory, yyny say. y adds the
-- flag, n takes it out, and Enter leaves it as it is. Returns the flags the
-- answers make, or nil if cancelled.
local function ask(flags)
  local list = prompts()
  for i, prompt in ipairs(list) do
    local on = has(flags, prompt.flag)
    local question = ('(%d/%d) %s? %s '):format(i, #list, table.concat(prompt.flag, ' '), on and '[Y/n]' or '[y/N]')
    vim.api.nvim_echo({ { question, 'Question' } }, false, {})
    local answer
    repeat
      -- CTRL-C can come as an interrupt rather than a key
      local ok, key = pcall(vim.fn.getcharstr)
      if not ok or key == '\27' or key == '\3' then
        vim.api.nvim_echo({ { '' } }, false, {})
        return nil
      elseif key == 'y' or key == 'Y' then
        answer = true
      elseif key == 'n' or key == 'N' then
        answer = false
      elseif key == '\r' or key == '\n' then
        answer = on
      end
    until answer ~= nil
    flags = answer and with(flags, prompt.flag) or without(flags, prompt.flag)
  end
  vim.api.nvim_echo({ { '' } }, false, {})
  return flags
end

-- Lists the files again with other flags, for :CHANGEFLAGS: with bang,
-- exactly {args}; else {args} added to the flags there are, any already there
-- skipped; or, with no {args}, whatever the answers to the flag prompts make
-- them. With the same flags, it lists the files again all the same.
--
-- It is the same search still, in the same buffer, so the jumplist, marks and
-- the alternate file all still lead to it. But the query is matched afresh
-- against the new file list, narrowing gone, and undo starts over too: every
-- step of it is text from the old list, which matching against the new one
-- would no longer agree with.
function M.change_flags(buf, args, bang)
  local st = state[buf]
  if not st then
    return
  end
  local flags
  if bang then
    flags = vim.deepcopy(args)
  elseif #args > 0 then
    flags = st.flags
    for _, flag in ipairs(split_flags(args)) do
      flags = with(flags, flag)
    end
  else
    flags = ask(st.flags)
    if not flags then
      return
    end
  end

  M.sync(buf)
  local cmd = command()
  local files, err = list_files(st.root, cmd, flags)
  if not files then
    fail(err)
    return
  end
  st.command, st.flags, st.files = cmd, flags, files
  st.matches = match(files, st.query)
  -- A change made with 'undolevels' at -1 clears undo (:help clear-undo)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 1, -1, false, st.matches)
  vim.bo[buf].undolevels = undolevels
  remember_undo_state(buf)
  decorate(buf)
end

-- Sets up a buffer named filesearch://<n><dir> as a search of <dir>. Called
-- on BufReadCmd, so this is also what rebuilds one restored from a session.
function M.setup(buf)
  local root = root_of(buf)

  -- 'bufhidden' is hide rather than wipe because wiping drops a buffer's
  --   jumplist entries, and coming back with CTRL-O is the point
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = true
  -- So gf, CTRL-W f and friends find results even after a :cd
  vim.bo[buf].path = (root:gsub('[, \\]', '\\%0'))

  -- A search restored from a session starts with the default flags too: the
  --   name only says what directory it was of
  local cmd, flags = command(), default_flags()
  local files, err = list_files(root, cmd, flags)
  if not files then
    fail(err)
    files = {}
  end
  state[buf] = { root = root, command = cmd, flags = flags, files = files, query = '', matches = files }

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
  -- The rule under the header is as wide as the screen was when drawn
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      decorate(buf)
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
  -- All capitals, so that a short abbreviation is less likely to be
  --   ambiguous (:help user-cmd-ambiguous)
  vim.api.nvim_buf_create_user_command(buf, 'NARROW', function(opts)
    M.narrow(buf, opts.args)
  end, { nargs = '+', desc = 'Keep only the results that fuzzy-match {text}' })
  vim.api.nvim_buf_create_user_command(buf, 'CHANGEFLAGS', function(opts)
    M.change_flags(buf, opts.fargs, opts.bang)
  end, { nargs = '*', bang = true, desc = 'List the files again with other flags' })

  vim.bo[buf].filetype = 'filesearch'
  remember_undo_state(buf)
  decorate(buf)
end

-- Starts a new search of the cwd in this window, prefilled with {query}.
--
-- Each search is a buffer of its own, with its own file list, listed fresh.
-- Earlier searches are left as they were, so several can be open at once.
function M.open(query)
  -- A line of the buffer can't hold a newline, so a query of several lines
  --   (a Visual selection, say) is joined into one
  query = (query or ''):gsub('\n', ' ')
  -- :edit, unlike nvim_win_set_buf, records the jump, so CTRL-O goes back to
  --   whatever was here before
  vim.cmd('edit ' .. vim.fn.fnameescape(new_name(vim.fn.getcwd())))
  local buf = vim.api.nvim_get_current_buf()
  -- Reading the new name set it up already, unless autocommands were off
  if not state[buf] then
    M.setup(buf)
  end

  -- An ordinary change, as if typed, so u takes it back to the empty query
  if query ~= '' then
    local st = state[buf]
    st.query = query
    st.matches = match(st.files, query)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ query }, st.matches))
    remember_undo_state(buf)
    decorate(buf)
  end

  vim.api.nvim_win_set_cursor(0, { 1, #query })
  vim.cmd('startinsert!')
end

vim.api.nvim_set_decoration_provider(match_ns, {
  -- Dims the directory of each visible result, and highlights where it
  -- matched the query. Worked out per redraw for just the lines on screen:
  -- marking every match up front would mean one extmark per matched character
  -- across the whole file list.
  on_win = function(_, _, buf, toprow, botrow)
    local st = state[buf]
    if not st then
      return false
    end
    local first = math.max(toprow, 1)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, botrow + 1, false)) do
      local row = first + i - 1
      -- Up to and including the last slash
      local slash = line:match('^.*()/')
      if slash then
        vim.api.nvim_buf_set_extmark(buf, match_ns, row, 0, {
          end_col = slash,
          hl_group = 'FileSearchDirectory',
          -- Under the match highlights, which take the default of 4096
          priority = 4000,
          ephemeral = true,
        })
      end
      if searching(st.query) then
        -- matchfuzzypos drops non-matches, so one line at a time keeps rows straight
        local hit = vim.fn.matchfuzzypos({ line }, st.query)[2][1] or {}
        for _, char in ipairs(hit) do
          vim.api.nvim_buf_set_extmark(buf, match_ns, row, vim.fn.byteidx(line, char), {
            end_col = vim.fn.byteidx(line, char + 1),
            hl_group = 'FileSearchMatch',
            ephemeral = true,
          })
        end
      end
    end
    return false
  end,
})

return M
