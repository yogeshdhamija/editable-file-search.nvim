-- Location: lua/editable-file-search/match.lua
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>

-- The file list and the fuzzy matching over it, made fast enough to run on
-- every key typed into the query, even for hundreds of thousands of files.
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

-- A run of characters counts for more than the same characters each at the
-- start of a word: for lib, lib/x.so before lua/images/back.png.
local MATCH = 1
local AFTER_SLASH = 3
local WORD_START = 2
local CONSECUTIVE = 5
-- Longer paths than this tie on length
local MAX_LENGTH = 1023

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
local function match_word(p, s, e, w, wl, out)
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

local function words_of(query)
  local words = {}
  for word in query:lower():gmatch('%S+') do
    words[#words + 1] = word
  end
  return words
end

-- Sorts the lines of {stdout} and joins them up, each ended by a newline;
-- and lowercases that too. Run in a thread of its own (vim.uv.new_work), as
-- it takes a moment for a big list, so it must use nothing from outside it:
-- luv takes only the function's code across. Returns the text, the lowercased
-- text, and how many lines.
function M.sort_lines(stdout)
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

-- Sorts n slots stably by key[slot], each in [0, nkeys)
local function counting_sort(order, n, key, nkeys)
  local count = ffi.new('int32_t[?]', nkeys + 1)
  for i = 0, n - 1 do
    local k = key[order[i]] + 1
    count[k] = count[k] + 1
  end
  for k = 1, nkeys do
    count[k] = count[k] + count[k - 1]
  end
  local sorted = ffi.new('int32_t[?]', n)
  for i = 0, n - 1 do
    local slot = order[i]
    local k = key[slot]
    sorted[count[k]] = slot
    count[k] = count[k] + 1
  end
  return sorted
end

-- The paths found, best first: highest score, then shortest, then as they
-- were found, which is list order. Two stable sorts, the last by the key
-- that counts most.
local function rank(list, found, scores, n, best)
  local starts = list.starts
  local length = ffi.new('int32_t[?]', n)
  local worse = ffi.new('int32_t[?]', n)
  local order = ffi.new('int32_t[?]', n)
  for slot = 0, n - 1 do
    local i = found[slot]
    length[slot] = math.min(starts[i + 1] - starts[i] - 1, MAX_LENGTH)
    worse[slot] = best - scores[slot]
    order[slot] = slot
  end
  order = counting_sort(order, n, length, MAX_LENGTH + 1)
  order = counting_sort(order, n, worse, best + 1)
  local ranked = ffi.new('int32_t[?]', n)
  for r = 0, n - 1 do
    ranked[r] = found[order[r]]
  end
  return ranked
end

-- Searches the list for {query}. The result says how many paths matched
-- (count) and, through M.ranked, which, best first. A query of no words
-- matches every path, in list order.
--
-- With {prev}, the result of the search before, only the paths that matched
-- it are searched, if {query} goes on from its query: typing on only takes
-- paths away, as every word of the old query is the start of one of the new.
function M.search(list, query, prev)
  local result = { list = list, query = query }
  local words = words_of(query)
  if #words == 0 then
    result.count = list.n
    return result
  end
  local ptrs, lens = {}, {}
  for i, word in ipairs(words) do
    ptrs[i], lens[i] = ffi.cast('const uint8_t *', word), #word
  end
  local nwords = #words

  local from, nfrom = nil, list.n
  if prev and prev.found and prev.list == list and query:sub(1, #prev.query) == prev.query then
    from, nfrom = prev.found, prev.count
  end
  local found = ffi.new('int32_t[?]', nfrom)
  local scores = ffi.new('int32_t[?]', nfrom)
  local p, starts = list.p, list.starts
  local n, best = 0, 0
  for c = 0, nfrom - 1 do
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
  result.found, result.count = found, n
  result.ranking = rank(list, found, scores, n, best)
  return result
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
  for _, word in ipairs(words_of(query)) do
    if match_word(p, 0, #lower, ffi.cast('const uint8_t *', word), #word, out) < 0 then
      return nil
    end
  end
  table.sort(out)
  return out
end

return M
