-- editable-file-search.nvim - fuzzy file search as a plain, editable buffer
-- Maintainer: Yogesh Dhamija <yogeshdhamija@outlook.com>
-- Version 0.1

if vim.g.loaded_editable_file_search then
  return
end
vim.g.loaded_editable_file_search = 1

vim.api.nvim_create_user_command('FileSearch', function(opts)
  require('editable-file-search').open(opts.args)
end, { nargs = '*', bar = true, desc = 'Fuzzy-search files under the cwd in an editable buffer' })

local group = vim.api.nvim_create_augroup('EditableFileSearch', {})

-- Every search buffer is named filesearch://<directory searched>, and is
-- built by reading that name, the way oil.nvim builds oil:// buffers. That is
-- what makes it survive :mksession: the session restores the name with :badd,
-- and entering the buffer reads it here into a working search again, rather
-- than an empty buffer pretending to be a file.
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = 'filesearch://*',
  callback = function(ev)
    require('editable-file-search').setup(ev.buf)
  end,
})

local function set_highlights()
  vim.api.nvim_set_hl(0, 'FileSearchLabel', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'FileSearchNarrowed', { link = 'WarningMsg', default = true })
  vim.api.nvim_set_hl(0, 'FileSearchSummary', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'FileSearchMatch', { link = 'Special', default = true })
end
set_highlights()
-- :colorscheme starts with :highlight clear, which takes default links with it
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
