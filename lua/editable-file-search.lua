-- Location: lua/editable-file-search.lua
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>

-- The search is a plain modifiable scratch buffer. Line 1 is the query, and
-- every line below it is a result: a path relative to the directory searched.
-- Both are ordinary text, so anything that edits text works on them.
--
-- The file list comes from a command and some flags, run in the background
-- so that a big directory never holds up the editor. Until the list is in,
-- the results say Loading…, and the query can be typed meanwhile; then the
-- results are written in one go, never part of them at a time (see
-- list_files and loaded). :CHANGEFLAGS lists the files again with other
-- flags, in the same buffer, and starts the results and undo over (see
-- M.change_flags).
--
-- Changing line 1 runs the query over the whole file list again and redraws
-- the results: the first PAGE of them, which :MORE adds to, so that a query
-- matching most of a big list writes no more than that (see match.lua for
-- the matching). Nothing else is ever redrawn, so the results can be
-- whittled down by hand -- dd, :g/foo/d, :v/foo/d, :NARROW -- and stay that
-- way until the query changes. Line 1 itself can be emptied but not deleted:
-- deleting it puts it back (see M.sync). Undo and redo are taken as they
-- come: they put back text that was right at the time, narrowing included.
--
-- The labels ("Query:", the command, the result counts, the rule under them)
-- are extmarks, not text, so they can't be edited, deleted or yanked, or read
-- back as a path.

local match = require('editable-file-search.match')

local M = {}

local scheme = 'filesearch://'
local ns = vim.api.nvim_create_namespace('editable-file-search')
local match_ns = vim.api.nvim_create_namespace('editable-file-search-match')

-- Results are written a page at a time
local PAGE = 1000

-- The part of the command :CHANGEFLAGS leaves alone. --files has rg list the
-- files rather than search them.
local default_command = { 'rg', '--files', '--no-messages' }

-- The flags :CHANGEFLAGS asks about, in this order, and whether a new search
-- starts with them: hidden files in, but not the inside of .git, which
-- --hidden would otherwise let in too. Symlinks aren't followed: one out of
-- the directory can lead anywhere -- Wine's z: leads to / -- and the listing
-- then goes on until it hits MAX_LISTING.
local default_prompts = {
  { flag = '--hidden', default = true },
  { flag = '--glob=!.git/', default = true },
  { flag = '--no-ignore', default = false },
  { flag = '--follow', default = false },
}

-- The most output listing the files can come to, and the listing is stopped
-- past it. Without it, a listing with no end in sight would be kept in
-- memory until there was none left. Paths average around a hundred bytes:
-- this is room for a couple of million, twice a big home directory, while a
-- search over even that many already takes a good part of a second a key.
local MAX_LISTING = 256 * 1024 * 1024

-- Keyed by buffer number:
--   root     the directory searched; results are relative to it
--   command, flags  what lists the files, as lists of words
--   list     every file under root, sorted (see match.lua); nil while listing
--   job      the listing under way, if any (see list_files)
--   query    the query the results were last drawn for
--   result   the matches for that query (see match.search); nil while listing
--   seq_last, seq_cur  the undo state as of the last sync, to tell undo from edits
--   query_deleted  'operator' or 'command' once a change has deleted line 1,
--                  until the next sync puts it back
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

local function fail(err)
  vim.notify('editable-file-search: ' .. err, vim.log.levels.ERROR)
end

local function echo(msg)
  vim.api.nvim_echo({ { msg } }, false, {})
end

local function kill(job)
  if job.process then
    -- Gone already, if it was only being sorted
    pcall(job.process.kill, job.process, 15)
  end
end

-- Stops the listing under way, if any. Whatever it was still to call back
-- with finds st.job changed, and is dropped.
local function stop(st)
  if st.job then
    kill(st.job)
  end
  st.job = nil
end

-- Lists the files under st.root with st.command and st.flags, in the
-- background, and calls done(list), or done(nil, why) if the command failed,
-- once it has them. Not if listed again, or unloaded, by then: st.job is the
-- listing that counts.
local function list_files(buf, st, done)
  stop(st)
  local job = {}
  st.job = job
  local function finish(err, text, lower, n)
    -- Called back outside the main loop, where buffers can't be changed
    vim.schedule(function()
      if st.job == job and state[buf] == st then
        st.job = nil
        done(not err and match.list(text, lower, n) or nil, err)
      end
    end)
  end

  -- The output is kept here, not by vim.system, which would keep all of it
  --   until the command was gone, stopped or not, and then join it into one
  --   string: past 2 GB, more than LuaJIT can hold, and that brings nvim
  --   down. Here it's dropped as soon as the listing is stopped, or comes to
  --   more than MAX_LISTING, which stops it.
  local chunks, size, failed = {}, 0, nil
  local function read(err, data)
    if st.job ~= job or failed then
      chunks = nil
    elseif err or (data and size + #data > MAX_LISTING) then
      failed = err or ('too many files: stopped listing them at %d MB of paths.'
        .. ' Following symlinks (--follow) can lead out of the directory'):format(MAX_LISTING / 2 ^ 20)
      chunks = nil
      kill(job)
    elseif data then
      chunks[#chunks + 1], size = data, size + #data
    end
  end

  local argv = vim.list_extend(vim.deepcopy(st.command), st.flags)
  -- vim.system throws, rather than returning an error, when argv[1] isn't
  --   installed. text is for stderr; stdout's \r\n are left to sort_lines.
  local ok, process = pcall(vim.system, argv, { cwd = st.root, text = true, stdout = read }, function(result)
    if st.job ~= job then
      return
    elseif failed then
      return finish(failed)
    end
    local stdout = table.concat(chunks)
    chunks = nil
    -- Failed only if it listed nothing and says why: rg exits 1 when there
    --   are no files at all, and 2 when it listed what it could but couldn't
    --   read some directory -- which --no-messages keeps quiet about
    local err = vim.trim(result.stderr or '')
    if result.code ~= 0 and not stdout:find('[^\n]') and err ~= '' then
      return finish(err)
    end
    -- Sorted because rg walks the tree in parallel, so its order changes
    --   from run to run, and ties in the ranking go by list order. Sorting
    --   a big list takes a moment, so that is done in a thread of its own.
    vim.uv.new_work(match.sort_lines, function(text, lower, n)
      finish(nil, text, lower, n)
    end):queue(stdout)
  end)
  if not ok then
    finish('could not run ' .. tostring(argv[1]) .. ': ' .. process)
  else
    job.process = process
  end
end

local function searching(query)
  return query:find('%S') ~= nil
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

-- The results ranked from..to, as lines
local function page(result, from, to)
  local lines = {}
  for r = from, math.min(to, result.count) do
    lines[#lines + 1] = match.ranked(result, r)
  end
  return lines
end

-- A change made with 'undolevels' at -1 clears undo (:help clear-undo)
local function without_undo(buf, fn)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  fn()
  vim.bo[buf].undolevels = undolevels
end

local function count(n)
  return (tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

local function plural(n, one, many)
  return count(n) .. ' ' .. (n == 1 and one or many)
end

-- Whether the results are anything other than the first pages of what the
-- query gives -- however they got that way: :NARROW, dd, :g/foo/d, a paste,
-- or undoing back to any of those. The first pages are whole ones, but for
-- the last, which has what is left.
local function narrowed(st, shown)
  local n, total = #shown, st.result.count
  if n ~= total and (n == 0 or n > total or n % PAGE ~= 0) then
    return true
  end
  for r = 1, n do
    if shown[r] ~= match.ranked(st.result, r) then
      return true
    end
  end
  return false
end

local function summary(st, shown, cut)
  local n, total = #shown, st.result.count
  local files = plural(st.list.n, 'file', 'files') .. ' in ' .. vim.fn.fnamemodify(st.root, ':~')
  local from
  if not searching(st.query) then
    from = 'all ' .. files
  elseif total == 0 then
    from = 'no matches among ' .. files
  else
    from = plural(total, 'match', 'matches') .. ' among ' .. files
  end
  if cut then
    return count(n) .. ' left of ' .. from, '   u undoes · editing the query starts over'
  elseif n < total then
    return 'first ' .. count(n) .. ' of ' .. from, '   :MORE shows more · <CR> opens · :NARROW {text} narrows fuzzily'
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

-- Redraws the labels from what the buffer says now.
local function decorate(buf)
  local st = state[buf]
  local label, text, hint = { { 'Query: ', 'FileSearchLabel' } }, 'Loading…', ''
  if st.list then
    local shown = results(buf)
    local cut = narrowed(st, shown)
    if cut then
      label = { { 'Query', 'FileSearchLabel' }, { ' (Note: NARROWED)', 'FileSearchNarrowed' }, { ': ', 'FileSearchLabel' } }
    end
    text, hint = summary(st, shown, cut)
  end
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

-- Puts back line 1 after a change deleted it, reading {text}. A buffer always
-- has a line, so deleting every line leaves one empty line, which is then all
-- there is of the query line.
local function restore_query(buf, text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local everything = #lines == 1 and lines[1] == ''
  if not (everything and text == '') then
    vim.api.nvim_buf_set_lines(buf, 0, everything and 1 or 0, false, { text })
  end
end

-- Brings the results and labels in line with the text, after any change.
--
-- Line 1 can't be deleted, only emptied. Deleted with an operator -- dd, dj,
-- dG, Vd -- it comes back empty, as cc would leave it: the cursor was on the
-- query, and taking it away means clearing it. Deleted by an Ex command --
-- :g/test/d, :v/lua/d -- it comes back as it was, since those are for
-- narrowing the results, and catch the query only because it doesn't happen
-- to match. Anything deleted along with it stays deleted.
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
--
-- While the files are still being listed, there are no results to redraw:
-- the query is only taken note of, for when they are in.
function M.sync(buf)
  local st = state[buf]
  if not st then
    return
  end
  local tree = vim.fn.undotree(buf)
  local undoing = tree.seq_last == st.seq_last and tree.seq_cur ~= st.seq_cur
  -- Undo and redo delete line 1 too, putting back text from before it was
  --   there; that is theirs to do
  local deleted = st.query_deleted
  st.query_deleted = nil
  if deleted and not undoing then
    restore_query(buf, deleted == 'operator' and '' or st.query)
    if deleted == 'operator' and vim.api.nvim_get_current_buf() == buf then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end
  end
  local query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
  if query ~= st.query then
    st.query = query
    if st.list then
      st.result = match.search(st.list, query, st.result)
      if not undoing then
        -- Written even when it comes out the same: nvim doesn't redraw lines
        --   it sees as unchanged, so they'd keep the old query's highlights
        vim.api.nvim_buf_set_lines(buf, 1, -1, false, page(st.result, 1, PAGE))
      end
    end
  end
  remember_undo_state(buf)
  decorate(buf)
end

-- Writes the results once the file list is in, for whatever the query is by
-- then, and starts undo there.
--
-- For a new search ({fresh}), undo starts from the empty query and every
-- file, as if the list had been there all along, with whatever query was
-- typed or given meanwhile as one change on top: so u takes it back, as it
-- would have had it been typed with the list in. For :CHANGEFLAGS, undo
-- starts over at the results (see M.change_flags).
local function loaded(buf, st, list, fresh)
  M.sync(buf)
  st.list = list
  st.result = match.search(list, st.query)
  local lines = page(st.result, 1, PAGE)
  if fresh and searching(st.query) then
    -- Line 1 is written over, which takes the cursor of any window on it to
    --   its start; each is put back where it was
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
    without_undo(buf, function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ '' }, page(match.search(list, ''), 1, PAGE)))
    end)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ st.query }, lines))
    for win, cursor in pairs(cursors) do
      pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end
  else
    without_undo(buf, function()
      vim.api.nvim_buf_set_lines(buf, 1, -1, false, lines)
    end)
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
    echo('No file under cursor')
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
  set_results(buf, vim.tbl_filter(function(line)
    return match.positions(line, text) ~= nil
  end, results(buf)))
  M.sync(buf)
end

-- Adds {pages} more pages of results at the end, for :MORE: the ones after
-- the last page with any result still showing. So results taken out of the
-- pages shown stay out, while a page taken out whole comes back, being, as
-- far as the text says, a page not yet shown.
function M.more(buf, pages)
  M.sync(buf)
  local st = state[buf]
  if not st then
    return
  end
  if not st.list then
    echo('Still listing the files')
    return
  end
  local wanted, left = {}, 0
  for _, line in ipairs(results(buf)) do
    if not wanted[line] then
      wanted[line], left = true, left + 1
    end
  end
  -- The furthest down the ranking of the results shown
  local last = 0
  for r = 1, st.result.count do
    if left == 0 then
      break
    end
    local line = match.ranked(st.result, r)
    if wanted[line] then
      wanted[line], left, last = nil, left - 1, r
    end
  end
  local from = math.ceil(last / PAGE) * PAGE + 1
  if from > st.result.count then
    echo('No more results')
    return
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, page(st.result, from, from + pages * PAGE - 1))
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
        echo('')
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
  echo('')
  return flags
end

-- Lists the files again with other flags, for :CHANGEFLAGS: with bang,
-- exactly {args}; else {args} added to the flags there are, any already there
-- skipped; or, with no {args}, whatever the answers to the flag prompts make
-- them. With the same flags, it lists the files again all the same.
--
-- It is the same search still, in the same buffer, so the jumplist, marks and
-- the alternate file all still lead to it. But it starts over as a new search
-- does: the results go at once, Loading… until the new list is in, and are
-- then written for the query as it is by then, narrowing gone. Undo starts
-- over too, from when the results go: every step of it before is text from
-- the old list, which matching against the new one would no longer agree
-- with. If the command fails, the search goes back to the files it had.
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
  local was = { command = st.command, flags = st.flags, list = st.list }
  st.command, st.flags, st.list, st.result = command(), flags, nil, nil
  without_undo(buf, function()
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, {})
  end)
  remember_undo_state(buf)
  decorate(buf)
  list_files(buf, st, function(list, err)
    if not list then
      fail(err)
      -- If it had any: the flags were changed while it was still listing
      if was.list then
        st.command, st.flags, list = was.command, was.flags, was.list
      else
        list = match.empty()
      end
    end
    loaded(buf, st, list, false)
  end)
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

  if state[buf] then
    stop(state[buf])
  end
  -- A search restored from a session starts with the default flags too: the
  --   name only says what directory it was of
  local st = { root = root, command = command(), flags = default_flags(), query = '' }
  state[buf] = st

  -- Kept out of undo: the first text isn't an edit, and u should never be
  --   able to empty the buffer
  without_undo(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  end)

  -- Notes when line 1 is deleted, for M.sync to put back. TextChanged comes
  --   too late to tell: by then the first result has moved up into its place,
  --   which reads the same as the query edited to say that path. on_lines
  --   comes with each change, and says which lines went: here, a run of lines
  --   from the top with nothing in their place. It can't change the buffer
  --   itself, so it only takes note.
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, _, new_last)
      -- Set up afresh since, or unloaded
      if state[buf] ~= st then
        return true
      end
      if first == 0 and new_last == 0 then
        -- An operator is still under way while it deletes; an Ex command isn't
        local operator = st.query_deleted == 'operator' or vim.fn.state('o') ~= ''
        st.query_deleted = operator and 'operator' or 'command'
      end
    end,
  })

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
      stop(st)
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
  vim.api.nvim_buf_create_user_command(buf, 'MORE', function(opts)
    M.more(buf, opts.count)
  end, { count = 1, desc = 'Show [count] more pages of results' })
  vim.api.nvim_buf_create_user_command(buf, 'CHANGEFLAGS', function(opts)
    M.change_flags(buf, opts.fargs, opts.bang)
  end, { nargs = '*', bang = true, desc = 'List the files again with other flags' })

  vim.bo[buf].filetype = 'filesearch'
  remember_undo_state(buf)
  decorate(buf)

  list_files(buf, st, function(list, err)
    if not list then
      fail(err)
    end
    loaded(buf, st, list or match.empty(), true)
  end)
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

  -- An ordinary change, as if typed, so u takes it back to the empty query.
  --   Searched once the file list is in (see loaded).
  if query ~= '' then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { query })
    M.sync(buf)
  end

  vim.api.nvim_win_set_cursor(0, { 1, #query })
  vim.cmd('startinsert!')
end

vim.api.nvim_set_decoration_provider(match_ns, {
  -- Dims the directory of each visible result, and highlights where it
  -- matched the query. Worked out per redraw for just the lines on screen:
  -- marking every match up front would mean an extmark per matched character
  -- across every result.
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
      if st.list and searching(st.query) then
        -- A highlight for each run of matched bytes
        local hits = match.positions(line, st.query) or {}
        local j = 1
        while j <= #hits do
          local k = j
          while hits[k + 1] and hits[k + 1] <= hits[k] + 1 do
            k = k + 1
          end
          vim.api.nvim_buf_set_extmark(buf, match_ns, row, hits[j], {
            end_col = hits[k] + 1,
            hl_group = 'FileSearchMatch',
            ephemeral = true,
          })
          j = k + 1
        end
      end
    end
    return false
  end,
})

return M
