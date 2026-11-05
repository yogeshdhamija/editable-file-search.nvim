# editable-file-search.nvim

Fuzzy file search in a plain, editable Neovim buffer. Type a query and the results update as you go, as in fzf; then narrow them with ordinary editing (`dd`, `:g/test/d`, `:v/lua/d`) or `:NARROW {text}`, undo with `u`, and open one with `<CR>`. The file list comes from `rg`, listed in the background so that even a huge directory never freezes the editor, and results come a page of 1,000 at a time (`:MORE` for the next). `:CHANGEFLAGS` lists the files again with other flags: hidden files, ignored files, `.git`, or anything else rg takes. Each search is a buffer of its own, listed and in the jumplist, so you can keep several open at once, or open a result, look, and `CTRL-O` back to the search as you left it.

```
Query (Note: NARROWED): init
Command: rg --files --no-messages --hidden --glob=!.git/ --follow   change with :CHANGEFLAGS
Results: 2 left of 9 matches among 4,210 files in ~/Stuff   u undoes · editing the query starts over
────────────────────────────────────────────────────────────────────────────────────────────────────
.config/nvim/init.vim
.vim/plugged/nvim-nio/tests/init.vim
```

See `:help editable-file-search` once installed, or the `doc/` directory.

Requires Neovim and [ripgrep](https://github.com/BurntSushi/ripgrep).

To install:
- Using [vim-plug](https://github.com/junegunn/vim-plug): `Plug 'yogeshdhamija/editable-file-search.nvim'`

Tests: `test/run.sh`.
