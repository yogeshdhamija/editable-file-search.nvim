# editable-file-search.nvim

Fuzzy file search in a plain, editable Neovim buffer. Type a query and the results update as you go, as in fzf; then narrow them with ordinary editing (`dd`, `:g/test/d`, `:v/lua/d`) or `:Narrow {words}`, undo with `u`, and open one with `<CR>`. The search buffer is listed and in the jumplist, so you can open a result, look, and `CTRL-O` back to the search as you left it.

```
Query (Note: NARROWED): init
Results: 2 left of 9 matches among 4,210 files in ~/Stuff   u undoes · editing the query starts over
.config/nvim/init.vim
.vim/plugged/nvim-nio/tests/init.vim
```

See `:help editable-file-search` once installed, or the `doc/` directory.

Requires Neovim and [ripgrep](https://github.com/BurntSushi/ripgrep).

To install:
- Using [vim-plug](https://github.com/junegunn/vim-plug): `Plug 'yogeshdhamija/editable-file-search.nvim'`

Tests: `test/run.sh`.
