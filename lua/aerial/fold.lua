local config = require("aerial.config")
local data = require("aerial.data")
local util = require("aerial.util")
local M = {}

---@param bufnr nil|integer
M.add_fold_mappings = function(bufnr)
  bufnr = bufnr or 0
  if config.manage_folds(bufnr) and config.link_folds_to_tree then
    local aerial = require("aerial")
    vim.keymap.set("n", "za", aerial.tree_toggle, { buffer = bufnr, desc = "[aerial] toggle fold" })
    vim.keymap.set("n", "zA", function()
      aerial.tree_toggle({ recurse = true })
    end, { buffer = bufnr, desc = "[aerial] toggle fold recursively" })
    vim.keymap.set("n", "zo", aerial.tree_open, { buffer = bufnr, desc = "[aerial] open fold" })
    vim.keymap.set("n", "zO", function()
      aerial.tree_open({ recurse = true })
    end, { buffer = bufnr, desc = "[aerial] open fold recursively" })
    vim.keymap.set("n", "zc", aerial.tree_close, { buffer = bufnr, desc = "[aerial] close fold" })
    vim.keymap.set("n", "zC", function()
      aerial.tree_close({ recurse = true })
    end, { buffer = bufnr, desc = "[aerial] close fold recursively" })
    vim.keymap.set(
      "n",
      "zM",
      aerial.tree_close_all,
      { buffer = bufnr, desc = "[aerial] close all folds" }
    )
    vim.keymap.set(
      "n",
      "zR",
      aerial.tree_open_all,
      { buffer = bufnr, desc = "[aerial] open all folds" }
    )
    vim.keymap.set("n", "zx", aerial.sync_folds, { buffer = bufnr, desc = "[aerial] sync folds" })
    vim.keymap.set("n", "zX", aerial.sync_folds, { buffer = bufnr, desc = "[aerial] sync folds" })
  end
end

local fold_cache = {}

local function compute_folds(bufnr)
  local bufdata = data.get_or_create(bufnr)
  local fold_levels = {}
  local line_no = 1

  local function add_no_symbol_fold_level()
    local levelstr
    if vim.api.nvim_buf_get_lines(bufnr, line_no - 1, line_no, true)[1] == "" then
      levelstr = "-1"
    else
      levelstr = "0"
    end
    fold_levels[line_no] = levelstr
    line_no = line_no + 1
  end

  for _, item in bufdata:iter({ skip_hidden = false }) do
    while item.lnum > line_no do
      add_no_symbol_fold_level()
    end
    fold_levels[item.lnum] = string.format(">%d", item.level + 1)
    for lnum = item.lnum + 1, item.end_lnum, 1 do
      fold_levels[lnum] = string.format("%d", item.level + 1)
    end
    line_no = math.max(line_no, item.end_lnum + 1)
  end
  local num_buf_lines = vim.api.nvim_buf_line_count(bufnr)
  while line_no <= num_buf_lines do
    add_no_symbol_fold_level()
  end

  fold_cache[bufnr] = fold_levels
  return fold_levels
end

M.foldexpr = function()
  if util.is_aerial_buffer() then
    return "0"
  end
  if not data.has_symbols(0) then
    return "0"
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cache = fold_cache[bufnr]
  -- Precompute the folds for all lines of the file. We only want to iterate
  -- through the symbols once, and foldexpr() is called on each line number.
  if not cache then
    cache = compute_folds(bufnr)
  end
  local lnum = vim.v.lnum
  -- Clear the cache after calling foldexpr on all lines
  if lnum == vim.api.nvim_buf_line_count(bufnr) then
    fold_cache[bufnr] = nil
  end
  return cache[lnum]
end

local prev_fdm = "_aerial_prev_foldmethod"
local prev_fde = "_aerial_prev_foldexpr"
M.restore_foldmethod = function()
  local ok, prev_foldmethod = pcall(vim.api.nvim_win_get_var, 0, prev_fdm)
  if ok and prev_foldmethod then
    vim.api.nvim_win_del_var(0, prev_fdm)
    vim.wo.foldmethod = prev_foldmethod
  end
  local ok2, prev_foldexpr = pcall(vim.api.nvim_win_get_var, 0, prev_fde)
  if ok2 and prev_foldexpr then
    vim.api.nvim_win_del_var(0, prev_fde)
    vim.wo.foldexpr = prev_foldexpr
  end
end

M.maybe_set_foldmethod = function(bufnr)
  local manage_folds = config.manage_folds(bufnr)
  if not manage_folds then
    return
  end
  if not data.has_symbols(bufnr) then
    return
  end
  local winids
  if bufnr then
    winids = util.get_fixed_wins(bufnr)
  else
    winids = { vim.api.nvim_get_current_win() }
  end
  for _, winid in ipairs(winids) do
    local fdm = vim.api.nvim_win_get_option(winid, "foldmethod")
    local fde = vim.api.nvim_win_get_option(winid, "foldexpr")
    if
      not util.is_managing_folds(winid)
      and (manage_folds == true or (manage_folds == "auto" and fdm == "manual"))
    then
      vim.api.nvim_win_set_var(winid, prev_fdm, fdm)
      vim.api.nvim_win_set_var(winid, prev_fde, fde)
      vim.api.nvim_win_set_option(winid, "foldmethod", "expr")
      vim.api.nvim_win_set_option(winid, "foldexpr", "v:lua.aerial_foldexpr()")
      if config.link_folds_to_tree then
        local fdl = vim.api.nvim_win_get_option(winid, "foldlevel")
        require("aerial").tree_set_collapse_level(bufnr, fdl)
      elseif config.link_tree_to_folds then
        vim.api.nvim_win_set_option(winid, "foldlevel", 99)
      end
    end
  end
end

M.sync_tree_folds = function(winid)
  if not util.is_managing_folds(winid) then
    return
  end
  util.go_win_no_au(winid)
  local view = vim.fn.winsaveview()
  vim.cmd("normal! zxzR")
  local bufdata = data.get_or_create(0)
  local items = {}
  for _, item in bufdata:iter({ skip_hidden = false }) do
    table.insert(items, item)
  end
  table.sort(items, function(a, b)
    return a.level > b.level
  end)
  for _, item in ipairs(items) do
    if bufdata:is_collapsed(item) then
      vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
      vim.cmd("normal! zc")
    end
  end

  vim.fn.winrestview(view)
end

---@param winid integer
---@param action "open"|"close"|"toggle"
---@param lnum integer
---@param recurse boolean
local function win_do_action(winid, action, lnum, recurse)
  util.go_win_no_au(winid)
  if vim.fn.foldlevel(lnum) == 0 then
    M.sync_tree_folds(winid)
  end
  if vim.fn.foldlevel(lnum) == 0 then
    return
  end
  local view = vim.fn.winsaveview()
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local key
  if action == "open" then
    key = "o"
  elseif action == "close" then
    key = "c"
  elseif action == "toggle" then
    key = "a"
  end
  if key and recurse then
    key = string.upper(key)
  end
  if key then
    vim.cmd("normal! z" .. key)
  end
  vim.fn.winrestview(view)
end

---@param action "open"|"close"|"toggle"
---@param lnum integer
---@param opts { recurse?: boolean }?
M.fold_action = function(action, lnum, opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    recurse = false,
  })
  local my_winid = vim.api.nvim_get_current_win()
  local wins
  local bufnr, _ = util.get_buffers()
  wins = util.get_fixed_wins(bufnr)
  for _, winid in ipairs(wins) do
    if util.is_managing_folds(winid) then
      win_do_action(winid, action, lnum, opts.recurse)
    end
  end
  util.go_win_no_au(my_winid)
end

return M
