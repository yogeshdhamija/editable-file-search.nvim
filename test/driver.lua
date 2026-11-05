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
-- nothing in it is expanded on the way to :edit. .ignore leaves out
-- ignored.txt, and itself, so that only --no-ignore lists either.
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
  'ignored.txt',
}
for _, f in ipairs(fixtures) do
  vim.fn.mkdir(vim.fs.dirname(work .. '/' .. f), 'p')
  vim.fn.writefile({ f }, work .. '/' .. f)
end
vim.fn.writefile({ '.ignore', 'ignored.txt' }, work .. '/.ignore')
local all = {
  '.hidden/notes.txt',
  'README.md',
  'doc/finder.txt',
  'lua/finder.lua',
  'lua/init.lua',
  'plugin/init.vim',
  'we#ird %name.txt',
}
local default_command = 'rg --files --no-messages --hidden --glob=!.git/ --follow'
-- {list} with {extra} added, sorted, as a file list is
local function plus(list, extra)
  local out = vim.list_extend(vim.deepcopy(list), extra)
  table.sort(out)
  return out
end

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
-- one piece. From Normal mode: :FILESEARCH leaves Insert mode on, and a
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
-- The labels, as displayed: where the inline one before the query is, its
-- text, then the virtual lines under it: Results, then Command, which is drawn
-- above Results but comes last here so the indexes above it stay put.
local function labels()
  return lua([[
    local ns = vim.api.nvim_get_namespaces()['editable-file-search']
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    if #marks ~= 1 then return { 'extmarks: ' .. #marks } end
    local d = marks[1][4]
    local function text(chunks)
      return table.concat(vim.tbl_map(function(c) return c[1] end, chunks))
    end
    return { marks[1][2], marks[1][3], text(d.virt_text), text(d.virt_lines[2]), text(d.virt_lines[1]) }
  ]])
end
local function matches(q, list)
  return lua('return vim.fn.matchfuzzy(...)', list or all, q)
end
local function without(list, pattern)
  return vim.tbl_filter(function(f)
    return not f:find(pattern)
  end, list)
end
-- The Command line, as it reads with these flags
local function command_label(cmd)
  return 'Command: ' .. cmd .. '   change with :CHANGEFLAGS'
end
local function reset()
  type('<Esc>')
  ex('silent! %bwipeout!')
end

describe(':FILESEARCH opens a listed search buffer in this window')
reset()
ex('edit README.md')
local wins = call('nvim_eval', "winnr('$')")
ex('FILESEARCH')
is(name(), 'filesearch://1' .. work, 'it is named after the directory searched, numbered')
is(call('nvim_eval', "winnr('$')"), wins, 'no new window was opened')
is(call('nvim_eval', '&buftype'), 'nofile', "'buftype' is nofile")
is(call('nvim_eval', '&buflisted'), 1, 'it is listed')
is(call('nvim_eval', '&bufhidden'), 'hide', "'bufhidden' is hide, so jumps back to it survive")
is(lines(), vim.list_extend({ '' }, all), 'line 1 is an empty query, then every file, sorted; .git is left out')
is(mode(), 'i', 'it starts in Insert mode, on the query')
is(labels(), { 0, 0, 'Query: ', 'Results: all 7 files in ' .. vim.fn.fnamemodify(work, ':~')
  .. '   <CR> opens · :NARROW {text} narrows fuzzily',
  'Command: ' .. default_command .. '   change with :CHANGEFLAGS' }, 'the labels read as a fresh search')
is(lua([[
  local ns = vim.api.nvim_get_namespaces()['editable-file-search']
  local d = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1][4]
  return vim.tbl_map(function(chunks)
    return vim.tbl_map(function(c) return c[2] end, chunks)
  end, { d.virt_text, d.virt_lines[1], d.virt_lines[2], d.virt_lines[3] })
]]), {
  { 'FileSearchLabel' },
  { 'FileSearchLabel', 'FileSearchText', 'FileSearchSummary' },
  { 'FileSearchLabel', 'FileSearchText', 'FileSearchSummary' },
  { 'FileSearchSeparator' },
}, 'the prefixes are highlighted apart from the text after them, and a rule is under it all')

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
ex('FILESEARCH fi')
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

describe(':NARROW keeps only the results matching more words, in their order')
type('<Esc>')
ex('FILESEARCH')
type('<Esc>')
ex('NARROW lua')
local narrowed = vim.tbl_filter(function(f)
  return #lua('return vim.fn.matchfuzzy({...}, "lua")', f) == 1
end, all)
is(results(), narrowed, 'results not matching "lua" are gone, the rest keep their order')
is(query(), '', 'the query is untouched')
is(labels()[3], 'Query (Note: NARROWED): ', 'the query is marked narrowed')
ex('NARROW init')
is(results(), { 'lua/init.lua' }, 'a second :NARROW narrows further')
type('u')
is(results(), narrowed, 'u undoes one :NARROW at a time')
type('u')
is(results(), all, 'and then the other')
is(labels()[3], 'Query: ', 'and the mark goes away')

describe('<CR> opens the file under the cursor, and CTRL-O comes back')
ex('FILESEARCH init')
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
ex('FILESEARCH')
type('finder')
type('<CR>')
is(name(), work .. '/' .. matches('finder')[1], 'Insert-mode <CR> on the query opened the top result')
is(mode(), 'n', 'and left Insert mode')
type('<C-o>')
type('gg<CR>')
is(name(), work .. '/' .. matches('finder')[1], 'so does Normal-mode <CR>')

describe('each :FILESEARCH is a search of its own')
ex('FILESEARCH')
local first = call('nvim_get_current_buf')
local first_name = name()
type('lua<Esc>')
type('jdd')
local before = lines()
ex('FILESEARCH')
ok(call('nvim_get_current_buf') ~= first, 'a new buffer, not the last one again')
ok(name() ~= first_name, 'with a name of its own  [' .. name() .. ']')
is(lines(), vim.list_extend({ '' }, all), 'starting from an empty query')
is(call('nvim_buf_get_lines', first, 0, -1, false), before, 'the last search is left as it was, narrowing and all')
is(call('nvim_get_option_value', 'buflisted', { buf = first }), true, 'and still listed')
type('<Esc><C-o>')
is(call('nvim_get_current_buf'), first, 'CTRL-O goes back to it')
is(labels()[3], 'Query (Note: NARROWED): ', 'still marked narrowed')

describe('searches side by side')
ex('FILESEARCH')
type('lua<Esc>')
local left = call('nvim_get_current_buf')
ex('belowright vsplit')
ex('FILESEARCH')
type('finder<Esc>')
ok(call('nvim_get_current_buf') ~= left, 'a search in a new split is one of its own')
is(results(), matches('finder'), 'with its own query and results')
is(call('nvim_buf_get_lines', left, 0, -1, false), vim.list_extend({ 'lua' }, matches('lua')),
  'while the other keeps its own')
ex('only')

describe('open() takes a query from Lua, whatever is in it')
type('<Esc>')
lua([[require('editable-file-search').open('lua\ninit')]])
is(query(), 'lua init', 'lines are joined into one query')
is(results(), matches('lua init'), 'and searched')
is(mode(), 'i', 'in Insert mode')
type('<Esc>u')
is(lines(), vim.list_extend({ '' }, all), 'u takes the query back')
lua([[require('editable-file-search').open('a|b"c')]])
is(query(), 'a|b"c', 'a | or " is kept, not taken as the end of a command')

describe(':CHANGEFLAGS {flags} adds flags, and starts the same search over')
ex('FILESEARCH')
type('txt<Esc>')
type('jdd')
local buf = call('nvim_get_current_buf')
local search_name = name()
ex('CHANGEFLAGS --no-ignore')
local unignored = plus(all, { '.ignore', 'ignored.txt' })
is(call('nvim_get_current_buf'), buf, 'in the same buffer')
is(name(), search_name, 'by the same name')
is(labels()[5], command_label(default_command .. ' --no-ignore'), 'the Command line shows the flag added')
is(query(), 'txt', 'the query is kept')
is(results(), matches('txt', unignored), 'and matched against the new file list')
is(labels()[3], 'Query: ', 'the narrowing is gone')
ok(labels()[4]:find('among 9 files'), 'the summary counts the new file list  [' .. labels()[4] .. ']')
type('u')
is(results(), matches('txt', unignored), 'u has nothing to take back: undo starts over')
is(call('nvim_eval', 'len(undotree().entries)'), 0, 'with no undo left at all')
type('ggAx')
is(results(), matches('txtx', unignored), 'editing the query searches the new file list')
type('<Esc>u')
is(results(), matches('txt', unignored), 'and undoes as usual')
ex('CHANGEFLAGS --hidden --no-ignore')
is(labels()[5], command_label(default_command .. ' --no-ignore'), 'flags already there are not added again')

describe(':CHANGEFLAGS! {flags} makes them the only flags')
ex('FILESEARCH')
type('<Esc>')
ex('CHANGEFLAGS!')
is(labels()[5], command_label('rg --files --no-messages'), 'with none, there are none')
is(results(), without(all, '^%.hidden/'), 'so hidden files are left out')
ex('CHANGEFLAGS! --hidden')
is(labels()[5], command_label('rg --files --no-messages --hidden'), 'with one, only that')
is(results(), plus(all, { '.git/HEAD' }), 'so .git is listed too')
ex('CHANGEFLAGS -g !.git/')
is(labels()[5], command_label('rg --files --no-messages --hidden -g !.git/'), 'a flag of two words is added')
is(results(), all, 'and leaves .git out again')
ex('CHANGEFLAGS -g !.git/ -g !lua/')
is(labels()[5], command_label('rg --files --no-messages --hidden -g !.git/ -g !lua/'),
  'of two flags of two words each, the one already there is skipped')
is(results(), without(all, '^lua/'), 'and the other added')

describe(':CHANGEFLAGS with nothing after it asks about every flag, in turn')
ex('CHANGEFLAGS! --hidden -g !lua/')
ex('CHANGEFLAGS')
type('yyny')
is(labels()[5], command_label('rg --files --no-messages --hidden -g !lua/ --glob=!.git/ --follow'),
  'y adds a flag, or keeps it; n leaves it out; flags not asked about are kept')
ex('CHANGEFLAGS')
type('nnyn')
is(labels()[5], command_label('rg --files --no-messages -g !lua/ --no-ignore'), 'n takes a flag out')
is(results(), without(without(plus(all, { 'ignored.txt' }), '^lua/'), '^%.hidden/'),
  'and the files listed follow: ignored ones in, but hidden ones (.ignore too) out')
ex('CHANGEFLAGS')
type('<CR><CR><CR><CR>')
is(labels()[5], command_label('rg --files --no-messages -g !lua/ --no-ignore'), 'Enter leaves each as it is')
ex('CHANGEFLAGS')
type('yy<Esc>')
is(labels()[5], command_label('rg --files --no-messages -g !lua/ --no-ignore'),
  'Esc cancels, answers given so far and all')
is(mode(), 'n', 'back in Normal mode')

describe(':CHANGEFLAGS from Insert mode on the query, with CTRL-O')
ex('FILESEARCH')
type('ignored')
type('<C-o>:CHANGEFLAGS --no-ignore<CR>')
is(mode(), 'i', 'leaves Insert mode on')
is(query(), 'ignored', 'with the query as it was')
is(results(), matches('ignored', unignored), 'and its results from the new file list')

describe('flags the command rejects change nothing')
type('<Esc>')
local was = { labels()[5], results() }
ex('CHANGEFLAGS --bogus')
is({ labels()[5], results() }, was, 'the flags and results are as they were')
ok(call('nvim_get_vvar', 'errmsg'):find('unrecognized flag %-%-bogus'),
  'and rg says why  [' .. call('nvim_get_vvar', 'errmsg') .. ']')
call('nvim_set_vvar', 'errmsg', '')

describe('the command and the flag prompts can be set')
ex([[let g:editable_file_search_command = 'rg --files']])
ex([[let g:editable_file_search_flag_prompts = [{'flag': '-g !lua/', 'default': v:true}, {'flag': ['--hidden'], 'default': 0}] ]])
ex('FILESEARCH')
type('<Esc>')
is(labels()[5], command_label('rg --files -g !lua/'), 'a command as a string; flags as prompts give them, by default')
is(results(), without(without(all, '^lua/'), '^%.hidden/'), 'which are what list the files')
ex('CHANGEFLAGS')
type('ny')
is(labels()[5], command_label('rg --files --hidden'), 'the prompts are the ones set, and only as many as there are')
ex('unlet g:editable_file_search_command g:editable_file_search_flag_prompts')

describe('the file list is refreshed each time')
vim.fn.writefile({ 'new' }, work .. '/brand-new.txt')
ex('FILESEARCH brand')
is(results(), { 'brand-new.txt' }, 'a file created since shows up')
vim.fn.delete(work .. '/brand-new.txt')

describe('results are found relative to the directory searched, not the cwd')
ex('FILESEARCH weird')
type('<Esc>')
ex('cd lua')
type('j<CR>')
is(name(), work .. '/we#ird %name.txt', 'a name with # and % in it opened as is, after a :cd')
ex('cd ..')

describe('a search of another directory')
ex('FILESEARCH')
local top = call('nvim_get_current_buf')
type('<Esc>')
ex('cd lua')
ex('FILESEARCH')
ok(call('nvim_get_current_buf') ~= top, 'gets its own buffer')
is(name(), 'filesearch://1' .. work .. '/lua', 'named after it, and numbered on its own')
is(results(), { 'finder.lua', 'init.lua' }, 'with its own files')
type('<Esc>')
ex('cd ..')

describe('a search restored from a session works')
reset()
ex('FILESEARCH init')
type('<Esc>')
ex('CHANGEFLAGS --no-ignore')
ex('edit README.md')
-- Outside the directory searched, or it would turn up in the results
local session = vim.fn.tempname()
ex('mksession! ' .. vim.fn.fnameescape(session))
ex('silent! %bwipeout!')
ex('source ' .. vim.fn.fnameescape(session))
ex('execute "buffer" bufnr("filesearch://")')
is(name(), 'filesearch://1' .. work, 'the buffer came back')
is(lines(), vim.list_extend({ '' }, all), 'as a working search, not an empty file')
is(call('nvim_eval', '&buftype'), 'nofile', 'set up again')
is(labels()[5], command_label(default_command), 'with the default flags, not the ones it had')
type('ggAinit')
is(results(), matches('init'), 'and it searches')
ex('FILESEARCH')
is(name(), 'filesearch://2' .. work, 'a new search takes the next number, not the restored one')
type('<Esc>')

describe('closing one with :bdelete')
ex('edit README.md')
ex('bdelete ' .. vim.fn.fnameescape('filesearch://1' .. work))
ex('FILESEARCH lua')
is(name(), 'filesearch://3' .. work, 'a new search does not land in the closed one')
is(results(), matches('lua'), 'and it searches')
ex('buffer ' .. vim.fn.fnameescape('filesearch://1' .. work))
is(lines(), vim.list_extend({ '' }, all), 'the closed one, entered again, is a fresh search')

describe('a search named before searches were numbered still works')
ex('edit ' .. vim.fn.fnameescape('filesearch://' .. work))
is(lines(), vim.list_extend({ '' }, all), 'as a search of that directory')
type('ggAinit')
is(results(), matches('init'), 'and it searches')
type('<Esc>')

describe('directories are dimmed, and matched characters highlighted over them')
-- Colors no colorscheme has, to tell on screen which group drew a cell
lua([[
  vim.api.nvim_set_hl(0, 'FileSearchDirectory', { fg = 1 })
  vim.api.nvim_set_hl(0, 'FileSearchMatch', { fg = 2 })
]])
-- A cell of the screen, as its text and the color it is drawn in. Row 0 is
-- the query; 1 and 2 the Command and Results lines, 3 the rule under them;
-- the results start at 4.
local function cell(row, col)
  return lua([[
    vim.cmd('redraw')
    local cell = vim.api.nvim__inspect_cell(1, ...)
    return { cell[1], cell[2].foreground or 0 }
  ]], row, col)
end
local function color(row, col)
  return cell(row, col)[2]
end
ex('FILESEARCH')
type('<Esc>')
is({ color(4, 0), color(4, 7), color(4, 8) }, { 1, 1, 0 },
  'a directory is dimmed up to its last slash, and the file name is not')
is(color(5, 0), 0, 'a result with no directory is not dimmed at all')
ex('FILESEARCH luainit')
type('<Esc>')
is(results(), { 'lua/init.lua' }, 'the one result')
is({ color(4, 0), color(4, 3), color(4, 4), color(4, 8) }, { 2, 1, 2, 0 },
  'matched characters show over the dimming, in the directory and out of it')
lua([[
  vim.api.nvim_set_hl(0, 'FileSearchDirectory', { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'FileSearchMatch', { link = 'Special' })
]])

describe('a rule sets the header apart from the results, in windows of any width')
local columns = call('nvim_get_option_value', 'columns', {})
is({ cell(3, 0)[1], cell(3, columns - 1)[1] }, { '─', '─' }, 'it runs across the window, edge to edge')
ex('vsplit')
local half = call('nvim_win_get_width', 0)
is({ cell(3, half - 1)[1], cell(3, half)[1], cell(3, half + 1)[1] }, { '─', '│', '─' },
  'side by side, it fills each window, up to the split between them')
ex('only')
ex('set columns=' .. (columns + 20))
is({ cell(3, columns + 19)[1], cell(4, 0)[1] }, { '─', 'l' }, 'redrawn wider when the screen is, still one line')
ex('set columns=' .. columns)

describe('no errors along the way')
is(call('nvim_get_vvar', 'errmsg'), '', 'v:errmsg is empty')

vim.fn.jobstop(job)
vim.fn.delete(work, 'rf')
vim.fn.delete(session)
out('')
out(pass .. ' passed, ' .. fail .. ' failed')
os.exit(fail == 0 and 0 or 1)
