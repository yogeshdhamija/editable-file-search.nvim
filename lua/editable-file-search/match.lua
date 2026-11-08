-- Location: lua/editable-file-search/match.lua
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>

-- The file list and the fuzzy matching over it, made fast enough to run on
-- every key typed into the query, even for hundreds of thousands of files;
-- and, for more than that, able to run in a thread of its own (see
-- M.search_async), so that typing never waits on it.
--
-- A list is held as one string, every path in it ended by a newline, plus a
-- lowercased copy and where each path starts. Matching walks the bytes of the
-- lowercased copy in place: no string per path, and nothing copied to
-- Vimscript and back, as matchfuzzy() would need on every key. Its scoring
-- is simpler than matchfuzzy()'s too, which scores every way a path could
-- match to find the best.
--
-- A query is words, split at whitespace. A path matches if each word's
-- characters appear in it in order, the words in any order. Case is ignored
-- (ASCII only). Each matched character scores a point, and more for being at
-- the start of the path or right after a /, at the start of a word, or right
-- after the character matched before it. Paths rank by score, then the
-- shorter first, then in list order.

local ffi = require('ffi')

local M = {}

-- Builds the matching. A function rather than the module's own code, so that
-- the same code can run in a worker thread, which gets it as bytecode
-- (string.dump): so it must use nothing from outside itself.
local function core()
  local ffi = require('ffi')
  local C = {}

  -- A run of characters counts for more than the same characters each at
  -- the start of a word: for lib, lib/x.so before lua/images/back.png.
  local MATCH = 1
  local AFTER_SLASH = 3
  local WORD_START = 2
  local CONSECUTIVE = 5
  -- Longer paths than this tie on length
  local MAX_LENGTH = 1023
  -- How many paths a search goes through between looking whether it has been
  -- cancelled
  local BLOCK = 8192

  -- The bonus for matching right after a byte: after a /, or after anything
  -- that isn't a letter or digit, which starts a word. Bytes of non-ASCII
  -- characters count as letters.
  local bonus_after = ffi.new('uint8_t[256]')
  for c = 0, 255 do
    local word = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c >= 128
    bonus_after[c] = c == 47 and AFTER_SLASH or (word and 0 or WORD_START)
  end

  -- Matches the word w[0, wl) in p[s, e), and scores it; -1 if it isn't
  -- there. Of all the places it could match, this takes the last one, found
  -- from the end backwards, and then as tight as it goes, forwards from where
  -- that starts: so a word in the file name wins over the same word in a
  -- directory, and its characters run together where they can. With {out},
  -- adds where each character matched to it, counted from s.
  function C.match_word(p, s, e, w, wl, out)
    local j, k = wl - 1, e - 1
    while k >= s do
      if p[k] == w[j] then
        if j == 0 then
          break
        end
        j = j - 1
      end
      k = k - 1
    end
    if k < s then
      return -1
    end
    local score, last = 0, -2
    j = 0
    while j < wl do
      if p[k] == w[j] then
        local bonus = k == s and AFTER_SLASH or bonus_after[p[k - 1]]
        if k == last + 1 then
          bonus = bonus + CONSECUTIVE
        end
        score = score + MATCH + bonus
        if out then
          out[#out + 1] = k - s
        end
        last = k
        j = j + 1
      end
      k = k + 1
    end
    return score
  end
  local match_word = C.match_word

  function C.words(query)
    local words = {}
    for word in query:lower():gmatch('%S+') do
      words[#words + 1] = word
    end
    return words
  end

  -- Puts the n paths found in ranking order, best first: highest score, then
  -- shortest, then as they were found, which is list order. Two stable
  -- counting sorts, the last by the key that counts most: by length into
  -- {scratch}, then by score into {ranking}, which then takes the paths in
  -- place of where they were found.
  local function rank(starts, found, scores, n, best, scratch, ranking)
    local count = ffi.new('int32_t[?]', MAX_LENGTH + 2)
    for slot = 0, n - 1 do
      local i = found[slot]
      local k = math.min(starts[i + 1] - starts[i] - 1, MAX_LENGTH) + 1
      count[k] = count[k] + 1
    end
    for k = 1, MAX_LENGTH + 1 do
      count[k] = count[k] + count[k - 1]
    end
    for slot = 0, n - 1 do
      local i = found[slot]
      local k = math.min(starts[i + 1] - starts[i] - 1, MAX_LENGTH)
      scratch[count[k]] = slot
      count[k] = count[k] + 1
    end
    count = ffi.new('int32_t[?]', best + 2)
    for r = 0, n - 1 do
      local k = best - scores[scratch[r]] + 1
      count[k] = count[k] + 1
    end
    for k = 1, best + 1 do
      count[k] = count[k] + count[k - 1]
    end
    for r = 0, n - 1 do
      local slot = scratch[r]
      local k = best - scores[slot]
      ranking[count[k]] = slot
      count[k] = count[k] + 1
    end
    for r = 0, n - 1 do
      ranking[r] = found[ranking[r]]
    end
  end

  -- Searches paths from[0, nfrom) of the list -- or the first nfrom, without
  -- {from} -- in the lowercased text {p}, with path i at starts[i]. Writes the
  -- paths that match to found[], in list order, and the same best first to
  -- ranking[]: room for nfrom in each. Returns how many matched, or -1 if
  -- cancel[0] was set first.
  function C.search(p, starts, from, nfrom, query, found, ranking, cancel)
    local words = C.words(query)
    local ptrs, lens = {}, {}
    for i, word in ipairs(words) do
      ptrs[i], lens[i] = ffi.cast('const uint8_t *', word), #word
    end
    local nwords = #words
    local scores = ffi.new('int32_t[?]', nfrom)
    local n, best = 0, 0
    for block = 0, nfrom - 1, BLOCK do
      if cancel[0] ~= 0 then
        return -1
      end
      for c = block, math.min(block + BLOCK, nfrom) - 1 do
        local i = from and from[c] or c
        local s, e = starts[i], starts[i + 1] - 1
        local total = 0
        for w = 1, nwords do
          local score = match_word(p, s, e, ptrs[w], lens[w], nil)
          if score < 0 then
            total = -1
            break
          end
          total = total + score
        end
        if total >= 0 then
          found[n], scores[n] = i, total
          n = n + 1
          best = math.max(best, total)
        end
      end
    end
    rank(starts, found, scores, n, best, ffi.new('int32_t[?]', n), ranking)
    return n
  end

  return C
end

local C = core()
local code = string.dump(core)

-- Sorts the lines of {stdout} and joins them up, each ended by a newline;
-- and lowercases that too. Run in a thread of its own (vim.uv.new_work), as
-- it takes a moment for a big list, so it must use nothing from outside it:
-- luv takes only the function's code across. Returns the text, the lowercased
-- text, and how many lines.
function M.sort_lines(stdout)
  -- On Windows, a command may end its lines with \r\n
  if stdout:find('\r', 1, true) then
    stdout = stdout:gsub('\r\n', '\n')
  end
  -- find, as gmatch takes four times as long
  local lines, n, pos = {}, 0, 1
  while pos <= #stdout do
    local newline = stdout:find('\n', pos, true) or #stdout + 1
    if newline > pos then
      n = n + 1
      lines[n] = stdout:sub(pos, newline - 1)
    end
    pos = newline + 1
  end
  table.sort(lines)
  local text = n > 0 and table.concat(lines, '\n') .. '\n' or ''
  return text, text:lower(), n
end

-- A list from what sort_lines returns.
function M.list(text, lower, n)
  local starts = ffi.new('int32_t[?]', n + 1)
  local p = ffi.cast('const uint8_t *', text)
  local i = 1
  for pos = 0, #text - 1 do
    if p[pos] == 10 then
      starts[i] = pos + 1
      i = i + 1
    end
  end
  -- The pointer into lower is good for as long as lower is kept
  return { n = n, text = text, lower = lower, p = ffi.cast('const uint8_t *', lower), starts = starts }
end

function M.empty()
  return M.list('', '', 0)
end

-- Path i of the list, counted from 0
function M.path(list, i)
  return list.text:sub(list.starts[i] + 1, list.starts[i + 1] - 1)
end

local function words(query)
  return C.words(query)
end

-- A search for {query} goes through the paths {prev} found, if it is the
-- result of a search before whose query {query} goes on from: typing on only
-- takes paths away, as every word of the old query is the start of one of
-- the new. Else through every path. Returns them and how many, or nil and
-- how many for every path.
local function candidates(list, query, prev)
  if prev and prev.found and prev.list == list and query:sub(1, #prev.query) == prev.query then
    return prev.found, prev.count
  end
  return nil, list.n
end

-- How many paths a search for {query} would go through (see M.search)
function M.cost(list, query, prev)
  if #words(query) == 0 then
    return 0
  end
  local _, n = candidates(list, query, prev)
  return n
end

-- A result: how many paths matched (count) and, through M.ranked, which,
-- best first. A query of no words matches every path, in list order.
local function result(list, query, found, ranking, count)
  return { list = list, query = query, found = found, ranking = ranking, count = count }
end

local never = ffi.new('int32_t[1]')

-- Searches the list for {query}, here and now (see candidates for {prev}).
function M.search(list, query, prev)
  if #words(query) == 0 then
    return result(list, query, nil, nil, list.n)
  end
  local from, nfrom = candidates(list, query, prev)
  local found = ffi.new('int32_t[?]', nfrom)
  local ranking = ffi.new('int32_t[?]', nfrom)
  local n = C.search(list.p, list.starts, from, nfrom, query, found, ranking, never)
  return result(list, query, found, ranking, n)
end

-- Runs in a worker thread. luv takes only strings and numbers across, and no
-- more than 9 of them, so what the search reads and writes comes as the
-- address of an array of SLOTS: the list's lowercased text and starts, the
-- paths to search (0 for all) and how many, the arrays for what it finds,
-- and the cancel flag. The matching comes as bytecode, loaded once per
-- thread. Returns {id} and how many paths matched, -1 if cancelled, or -2
-- and why if it failed.
local function work(bytecode, id, query, delay, slots)
  local ok, n = pcall(function()
    local ffi = require('ffi')
    local loaded = _G.editable_file_search_match
    if not loaded or loaded.bytecode ~= bytecode then
      loaded = { bytecode = bytecode, C = loadstring(bytecode)() }
      _G.editable_file_search_match = loaded
    end
    if delay > 0 then
      vim.uv.sleep(delay)
    end
    local s = ffi.cast('const uint64_t *', slots)
    local function at(ctype, i)
      return s[i] ~= 0 and ffi.cast(ctype, s[i]) or nil
    end
    return loaded.C.search(at('const uint8_t *', 0), at('const int32_t *', 1), at('const int32_t *', 2),
      tonumber(s[3]), query, at('int32_t *', 4), at('int32_t *', 5), at('const int32_t *', 6))
  end)
  if not ok then
    return id, -2, tostring(n)
  end
  return id, n
end

local SLOTS = 7

local function address(pointer)
  return pointer and ffi.cast('uint64_t', ffi.cast('uintptr_t', pointer)) or 0
end

-- Searches still running, by id. Each keeps what its thread reads and writes
-- alive until the thread is done with it, cancelled or not.
local running, last_id = {}, 0
local worker

-- Searches the list for {query} in a worker thread (see candidates for
-- {prev}), and calls done(result) back on the main loop, where buffers can
-- be changed -- unless cancelled first. {delay}, in ms, holds it up first:
-- for tests. Returns a function that cancels it.
--
-- If the thread fails, the error is shown and the search is done here
-- instead, so that it still comes back.
function M.search_async(list, query, prev, done, delay)
  local from, nfrom = candidates(list, query, prev)
  last_id = last_id + 1
  local search = {
    list = list,
    query = query,
    prev = prev,
    found = ffi.new('int32_t[?]', nfrom),
    ranking = ffi.new('int32_t[?]', nfrom),
    cancel = ffi.new('int32_t[1]'),
    done = done,
  }
  search.slots = ffi.new('uint64_t[?]', SLOTS, {
    address(list.p),
    address(list.starts),
    address(from),
    nfrom,
    address(search.found),
    address(search.ranking),
    address(search.cancel),
  })
  running[last_id] = search
  worker = worker
    or vim.uv.new_work(work, function(id, n, err)
      local s = running[id]
      running[id] = nil
      vim.schedule(function()
        if s.cancel[0] ~= 0 then
          return
        elseif n == -2 then
          vim.notify('editable-file-search: searching in the background failed: ' .. err, vim.log.levels.ERROR)
          s.done(M.search(s.list, s.query, s.prev))
        elseif n >= 0 then
          s.done(result(s.list, s.query, s.found, s.ranking, n))
        end
      end)
    end)
  worker:queue(code, last_id, query, delay or 0, tonumber(ffi.cast('uintptr_t', search.slots)))
  return function()
    search.cancel[0] = 1
  end
end

-- The r-th best path of a result, counted from 1
function M.ranked(result, r)
  return M.path(result.list, result.ranking and result.ranking[r - 1] or r - 1)
end

-- Where {line} matches {query}, as byte offsets, in order; nil if it doesn't
-- match. The same matching as M.search, for one line.
function M.positions(line, query)
  local lower = line:lower()
  local p = ffi.cast('const uint8_t *', lower)
  local out = {}
  for _, word in ipairs(words(query)) do
    if C.match_word(p, 0, #lower, ffi.cast('const uint8_t *', word), #word, out) < 0 then
      return nil
    end
  end
  table.sort(out)
  return out
end

return M
