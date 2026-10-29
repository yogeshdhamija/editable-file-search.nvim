-- Run by run.sh with `nvim -l`. This nvim is only the driver: it starts a
-- second, headless nvim with the plugin loaded and plays a user over its RPC
-- socket, one key at a time with a pause after each.
--
-- The pauses are the point. TextChanged and TextChangedI, which the whole
-- plugin hangs off, only fire once nvim has drained its typeahead and is back
-- waiting for a key, and undo blocks break the same way. Keys sent in one go,
-- or a `dd` run from a script, would skip both, and tests driven like that
-- would pass while testing nothing.

local root = assert(os.getenv('EFS_ROOT'), 'run me through test/run.sh')

local pass, fail = 0, 0
local function out(s)
  io.stdout:write(s .. '\n')
end
local function describe(name)
  out('')
  out(name)
end
local function ok(cond, msg)
  if cond then
    pass = pass + 1
    out('  ok    ' .. msg)
  else
    fail = fail + 1
    out('  FAIL  ' .. msg)
  end
end
local function is(got, want, msg)
  if vim.deep_equal(got, want) then
    ok(true, msg)
  else
    ok(false, msg .. '  [got ' .. vim.inspect(got) .. ', want ' .. vim.inspect(want) .. ']')
  end
end

-- Fixtures. .git/ is there to check it is left out; the odd name to check that
-- nothing in it is expanded on the way to :edit.
local work = vim.fn.tempname()
local fixtures = {
  'README.md',
  'lua/init.lua',
  'lua/finder.lua',
  'plugin/init.vim',
  'doc/finder.txt',
  '.hidden/notes.txt',
  'we#ird %name.txt',
  '.git/HEAD',
}
for _, f in ipairs(fixtures) do
  vim.fn.mkdir(vim.fs.dirname(work .. '/' .. f), 'p')
  vim.fn.writefile({ f }, work .. '/' .. f)
end
local all = {
  '.hidden/notes.txt',
  'README.md',
  'doc/finder.txt',
  'lua/finder.lua',
  'lua/init.lua',
  'plugin/init.vim',
  'we#ird %name.txt',
}

local sock = work .. '/nvim.sock'
local job = vim.fn.jobstart({
  'nvim', '--clean', '--headless', '-n', '-i', 'NONE', '--listen', sock,
  '--cmd', 'set rtp^=' .. vim.fn.fnameescape(root),
  '-c', 'set noswapfile hidden',
}, { cwd = work, stdin = 'null' })
assert(vim.wait(5000, function() return vim.uv.fs_stat(sock) ~= nil end), 'nvim under test never started')
local ch = vim.fn.sockconnect('pipe', sock, { rpc = true })

local function call(fn, ...)
  return vim.rpcrequest(ch, fn, ...)
end
local function lua(code, ...)
  return call('nvim_exec_lua', code, { ... })
end
local function settle()
  vim.wait(60)
end
-- Keys are sent one at a time, a <...> key counting as one.
local function type(keys)
  local i = 1
  while i <= #keys do
    local key = keys:match('^<[%w%-]+>', i)
    if key then
      i = i + #key
    else
      key = keys:sub(i, i) == '<' and '<lt>' or keys:sub(i, i)
      i = i + 1
    end
    call('nvim_input', key)
    settle()
  end
end
-- A command line has no events to wait on between its keys, so it goes in
-- one piece. From Normal mode: :FileSearch leaves Insert mode on, and a
-- command typed there would land in the query.
local function ex(cmd)
  call('nvim_input', '<Esc>')
  settle()
  call('nvim_input', ':' .. cmd:gsub('<', '<lt>') .. '<CR>')
  settle()
end

local function lines()
  return call('nvim_buf_get_lines', 0, 0, -1, false)
end
local function results()
  return call('nvim_buf_get_lines', 0, 1, -1, false)
end
local function query()
  return lines()[1]
end
local function mode()
  return call('nvim_get_mode').mode
end
local function name()
  return call('nvim_buf_get_name', 0)
end
-- The labels, as displayed: the inline one before the query, then the
-- virtual line under it.
local function labels()
  return lua([[
    local ns = vim.api.nvim_get_namespaces()['editable-file-search']
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    if #marks ~= 1 then return { 'extmarks: ' .. #marks } end
    local d = marks[1][4]
    local function text(chunks)
      return table.concat(vim.tbl_map(function(c) return c[1] end, chunks))
    end
    return { marks[1][2], marks[1][3], text(d.virt_text), text(d.virt_lines[1]) }
  ]])
end
local function matches(q)
  return lua('return vim.fn.matchfuzzy(...)', all, q)
end
local function reset()
  type('<Esc>')
  ex('silent! %bwipeout!')
end

describe(':FileSearch opens a listed search buffer in this window')
reset()
ex('edit README.md')
local wins = call('nvim_eval', "winnr('$')")
ex('FileSearch')
is(name(), 'filesearch://' .. work, 'it is named after the directory searched')
is(call('nvim_eval', "winnr('$')"), wins, 'no new window was opened')
is(call('nvim_eval', '&buftype'), 'nofile', "'buftype' is nofile")
is(call('nvim_eval', '&buflisted'), 1, 'it is listed')
is(call('nvim_eval', '&bufhidden'), 'hide', "'bufhidden' is hide, so jumps back to it survive")
is(lines(), vim.list_extend({ '' }, all), 'line 1 is an empty query, then every file, sorted; .git is left out')
is(mode(), 'i', 'it starts in Insert mode, on the query')
is(labels(), { 0, 0, 'Query: ', 'Results: all 7 files in ' .. vim.fn.fnamemodify(work, ':~')
  .. '   <CR> opens · :Narrow {words} narrows' }, 'the labels read as a fresh search')

describe('typing a query searches as you go')
type('in')
is(results(), matches('in'), 'after two keys the results match "in"')
type('it')
is(query(), 'init', 'the query is what was typed')
is(results(), matches('init'), 'and the results follow it')
is(labels()[3], 'Query: ', 'not narrowed')
ok(labels()[4]:find('^Results: 2 matches among 7 files'), 'the summary counts the matches  [' .. labels()[4] .. ']')

describe('one u takes back an Insert-mode query along with its results')
type('<Esc>')
type('u')
is(lines(), vim.list_extend({ '' }, all), 'back to the empty query and every file')
is(labels()[3], 'Query: ', 'and not marked narrowed')
type('<C-r>')
is(query(), 'init', 'CTRL-R redoes the query...')
is(results(), matches('init'), '...with its results')

describe('a Normal-mode edit to the query searches again, and undoes in one step')
type('gg$x')
is(query(), 'ini', 'x on the query edits it')
is(results(), matches('ini'), 'and the results follow')
type('u')
is(query(), 'init', 'u puts the query back...')
is(results(), matches('init'), '...and its results, in the same step')

describe('the label stays in front of the query')
type('ggIx')
is(query(), 'xinit', 'text typed at the start of the query...')
is({ labels()[1], labels()[2] }, { 0, 0 }, '...goes after the label, which stays at column 0')
type('<BS>')
is(results(), matches('init'), 'deleting it searches again')

describe('deleting results narrows them, until the query changes')
type('<Esc>gg')
ex('FileSearch fi')
local fi = matches('fi')
ok(#fi >= 2, 'the query "fi" matches more than one file  [' .. #fi .. ']')
type('<Esc>jdd')
is(results(), vim.list_slice(fi, 2), 'dd removed the first result')
is(labels()[3], 'Query (Note: NARROWED): ', 'the query is marked narrowed')
ok(labels()[4]:find('^Results: ' .. (#fi - 1) .. ' left of ' .. #fi .. ' matches among 7 files'),
  'the summary says how far  [' .. labels()[4] .. ']')
type('u')
is(results(), fi, 'u brings the result back')
is(labels()[3], 'Query: ', 'and the mark goes away')
type('<C-r>')
is(labels()[3], 'Query (Note: NARROWED): ', 'CTRL-R narrows again')
type('ggA<BS>')
is(results(), matches('f'), 'editing the query starts over from every file')
is(labels()[3], 'Query: ', 'and is no longer narrowed')
type('<Esc>u')
is(query(), 'fi', 'u puts the query back...')
is(results(), vim.list_slice(fi, 2), '...with the results as they were narrowed, not searched afresh')
is(labels()[3], 'Query (Note: NARROWED): ', 'and marked narrowed again')

describe(':Narrow keeps only the results matching more words, in their order')
type('<Esc>')
ex('FileSearch')
type('<Esc>')
ex('Narrow lua')
local narrowed = vim.tbl_filter(function(f)
  return #lua('return vim.fn.matchfuzzy({...}, "lua")', f) == 1
end, all)
is(results(), narrowed, 'results not matching "lua" are gone, the rest keep their order')
is(query(), '', 'the query is untouched')
is(labels()[3], 'Query (Note: NARROWED): ', 'the query is marked narrowed')
ex('Narrow init')
is(results(), { 'lua/init.lua' }, 'a second :Narrow narrows further')
type('u')
is(results(), narrowed, 'u undoes one :Narrow at a time')
type('u')
is(results(), all, 'and then the other')
is(labels()[3], 'Query: ', 'and the mark goes away')

describe('<CR> opens the file under the cursor, and CTRL-O comes back')
ex('FileSearch init')
type('<Esc>')
local res = results()
type('3G')
local search = call('nvim_get_current_buf')
type('<CR>')
is(name(), work .. '/' .. res[2], '<CR> opened the file on the cursor line')
is(call('nvim_eval', "winnr('$')"), wins, 'in the same window')
type('<C-o>')
is(call('nvim_get_current_buf'), search, 'CTRL-O goes back to the search')
is(call('nvim_eval', "line('.')"), 3, 'with the cursor where it was')
is(results(), res, 'and the results as they were')
type('<C-i>')
is(name(), work .. '/' .. res[2], 'CTRL-I goes forward to the file again')

describe('<CR> on the query line opens the top result, from either mode')
ex('FileSearch')
type('finder')
type('<CR>')
is(name(), work .. '/' .. matches('finder')[1], 'Insert-mode <CR> on the query opened the top result')
is(mode(), 'n', 'and left Insert mode')
type('<C-o>')
type('gg<CR>')
is(name(), work .. '/' .. matches('finder')[1], 'so does Normal-mode <CR>')

describe(':FileSearch reuses the search buffer, and u brings back the old search')
ex('edit README.md')
ex('FileSearch')
local first = call('nvim_get_current_buf')
type('lua<Esc>')
type('jdd')
local before = lines()
ex('edit README.md')
ex('FileSearch')
is(call('nvim_get_current_buf'), first, 'the same buffer, not a second one')
is(lines(), vim.list_extend({ '' }, all), 'starting over from an empty query')
type('<Esc>u')
is(lines(), before, 'u brings back the old search, narrowing and all')
is(labels()[3], 'Query (Note: NARROWED): ', 'still marked narrowed')

describe('the file list is refreshed each time')
vim.fn.writefile({ 'new' }, work .. '/brand-new.txt')
ex('FileSearch brand')
is(results(), { 'brand-new.txt' }, 'a file created since shows up')
vim.fn.delete(work .. '/brand-new.txt')

describe('results are found relative to the directory searched, not the cwd')
ex('FileSearch weird')
type('<Esc>')
ex('cd lua')
type('j<CR>')
is(name(), work .. '/we#ird %name.txt', 'a name with # and % in it opened as is, after a :cd')
ex('cd ..')

describe('one search per directory')
ex('FileSearch')
local top = call('nvim_get_current_buf')
type('<Esc>')
ex('cd lua')
ex('FileSearch')
ok(call('nvim_get_current_buf') ~= top, 'another directory gets its own buffer')
is(name(), 'filesearch://' .. work .. '/lua', 'named after it')
is(results(), { 'finder.lua', 'init.lua' }, 'with its own files')
type('<Esc>')
ex('cd ..')

describe('a search restored from a session works')
reset()
ex('FileSearch init')
type('<Esc>')
ex('edit README.md')
-- Outside the directory searched, or it would turn up in the results
local session = vim.fn.tempname()
ex('mksession! ' .. vim.fn.fnameescape(session))
ex('silent! %bwipeout!')
ex('source ' .. vim.fn.fnameescape(session))
ex('execute "buffer" bufnr("filesearch://")')
is(name(), 'filesearch://' .. work, 'the buffer came back')
is(lines(), vim.list_extend({ '' }, all), 'as a working search, not an empty file')
is(call('nvim_eval', '&buftype'), 'nofile', 'set up again')
type('ggAinit')
is(results(), matches('init'), 'and it searches')
type('<Esc>')

describe('closing it with :bdelete and opening it again')
ex('edit README.md')
ex('bdelete filesearch://' .. vim.fn.fnameescape(work))
ex('FileSearch lua')
is(results(), matches('lua'), 'it searches again')

describe('no errors along the way')
is(call('nvim_get_vvar', 'errmsg'), '', 'v:errmsg is empty')

vim.fn.jobstop(job)
vim.fn.delete(work, 'rf')
vim.fn.delete(session)
out('')
out(pass .. ' passed, ' .. fail .. ' failed')
os.exit(fail == 0 and 0 or 1)
