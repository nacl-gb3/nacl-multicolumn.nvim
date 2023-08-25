local M = {}

local MULTICOLUMN_DIR = vim.fn.stdpath('state') .. '/multicolumn'
local ENABLED_FILE = MULTICOLUMN_DIR .. '/is-enabled'

local enabled = false
local got_highlight = false
local bg_color = nil
local fg_color = nil

local config = {
  start = 'enabled', -- enabled, disabled, remember
  base_set = {
    scope = 'window', -- file, window, line
    rulers = {}, -- { int, int, ... }
    to_line_end = false,
    full_column = false,
    always_on = false,
    bg_color = nil,
    fg_color = nil,
  },
  sets = {
    default = {
      rulers = { 81 },
    },
  },
  max_lines = 6000, -- 0 (disabled) OR int
  exclude_floating = true,
  exclude_ft = { 'markdown', 'help', 'netrw' },
}

local function get_hl_value(group, attr)
  return vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID(group)), attr .. '#')
end

local function is_floating(win)
  local cfg = vim.api.nvim_win_get_config(win)
  if cfg.relative > '' or cfg.external then return true end
  return false
end

local function clear_colorcolum(win)
  if vim.wo[win].colorcolumn then vim.wo[win].colorcolumn = nil end
end

local function buffer_disabled(win)
  if config.exclude_floating and is_floating(win) then
    return true
  elseif vim.tbl_contains(config.exclude_ft, vim.bo.filetype) then
    return true
  end
  return false
end

local function get_exceeded(ruleset, buf, win)
  local lines = nil

  if ruleset.scope == 'file' then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  elseif ruleset.scope == 'window' then
    local first = vim.fn.line('w0', win)
    local last = vim.fn.line('w$', win)
    lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  else -- config.cope == 'line'
    local cur_line = vim.fn.line('.', win)
    lines = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)
  end

  local col = vim.fn.min(ruleset.rulers)
  for _, line in pairs(lines) do
    local ok, cells = pcall(vim.fn.strdisplaywidth, line)
    if not ok then return false end
    if col <= cells then return true end
  end

  return false
end

local function update_colorcolumn(ruleset, buf, win)
  local state = ruleset.always_on or get_exceeded(ruleset, buf, win)
  local rulers = table.concat(ruleset.rulers, ',')

  if (state ~= vim.b.prev_state) or (rulers ~= vim.b.prev_rulers) then
    vim.b.prev_state = state
    vim.b.prev_rulers = rulers

    if state then
      vim.wo[win].colorcolumn = rulers
    else
      vim.wo[win].colorcolumn = nil
    end
  end
end

local function update_matches(ruleset)
  vim.fn.clearmatches()

  local line_prefix = ''
  if ruleset.scope == 'line' then
    line_prefix = '\\%' .. vim.fn.line('.') .. 'l'
  end

  if ruleset.to_line_end then
    vim.fn.matchadd(
      'ColorColumn',
      line_prefix .. '\\%' .. vim.fn.min(ruleset.rulers) .. 'v[^\n].*$'
    )
  else
    for _, v in pairs(ruleset.rulers) do
      vim.fn.matchadd('ColorColumn', line_prefix .. '\\%' .. v .. 'v[^\n]')
    end
  end
end

local function update(buf, win)
  local ruleset = {}

  if type(config.sets[vim.bo.filetype]) == 'function' then
    local ok, result = pcall(config.sets[vim.bo.filetype], buf, win)
    if ok and result ~= nil then
      ruleset = vim.tbl_extend('keep', result, config.base_set)
    else
      return true
    end
  elseif config.sets[vim.bo.filetype] ~= nil then
    ruleset = config.sets[vim.bo.filetype]
  else
    ruleset = config.sets.default
  end

  if
    ruleset.scope == 'file'
    and (config.max_lines ~= 0)
    and (vim.api.nvim_buf_line_count(buf) > config.max_lines)
  then
    return true -- DYK returning true in an autocmd callback deletes it?
  end

  if got_highlight then
    vim.api.nvim_set_hl(0, 'ColorColumn', {
      bg = ruleset.bg_color or bg_color or '',
      fg = ruleset.fg_color or fg_color or '',
    })
  end

  if ruleset.full_column or ruleset.always_on then
    update_colorcolumn(ruleset, buf, win)
  end

  if (not ruleset.full_column) or ruleset.to_line_end then
    update_matches(ruleset)
  end
end

local function reload()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- HACK: del_augroup and clear_autocmds will error(?) if group or
  -- autocmd don't exist, respectively, so just create an empty one
  vim.api.nvim_create_augroup('MulticolumnUpdate', {})
  for _, fwin in pairs(vim.api.nvim_list_wins()) do
    clear_colorcolum(fwin)
    vim.fn.clearmatches(fwin)
  end
  for _, fbuf in pairs(vim.api.nvim_list_bufs()) do
    vim.b[fbuf].prev_state = nil
  end

  -- HACK: ft might not be set fast enough? unsure, but force reloading fixes it
  if vim.bo.filetype == '' then
    vim.api.nvim_create_autocmd('Filetype', {
      group = vim.api.nvim_create_augroup('MulticolumnHackReload', {}),
      callback = reload,
      once = true,
    })
  end

  if buffer_disabled(win) then return end

  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'WinScrolled' },
    {
      group = vim.api.nvim_create_augroup('MulticolumnUpdate', {}),
      buffer = buf,
      callback = function()
        return update(buf, win)
      end,
    }
  )

  update(buf, win)
end

local function fix_set(set)
  -- Some configs imply others. Fixing nonsensical stuff early on helps simplify
  -- code later by reducing the amount of cases that must be handled.
  if set.always_on then
    set.full_column = true -- Implied when always_on
    if set.scope == 'file' then
      set.scope = 'window' -- Needn't scope file if column is always on
    end
  end
  if set.scope == 'file' and not set.full_column then
    set.scope = 'window' -- Needn't scope file if not even drawing full column
  end
  return set
end

local function build_config(opts)
  local cfg = vim.tbl_deep_extend('force', config, opts)
  for k, _ in pairs(cfg.sets) do
    if not (type(cfg.sets[k]) == 'function') then
      cfg.sets[k] = fix_set(vim.tbl_extend('keep', cfg.sets[k], cfg.base_set))
    end
  end
  return cfg
end

local function save_enabled_state()
  if vim.fn.isdirectory(MULTICOLUMN_DIR) ~= 0 then
    if vim.fn.filereadable(ENABLED_FILE) ~= 0 then
      vim.fn.delete(ENABLED_FILE)
    end
  else
    vim.fn.mkdir(MULTICOLUMN_DIR, 'p')
  end

  if enabled then
    local f = io.open(ENABLED_FILE, 'w')
    if f ~= nil then
      f:write('')
      f:close()
    end
  end
end

M.enable = function()
  if enabled then return end
  enabled = true

  -- Give theme plugins some time to set the default highlight
  vim.defer_fn(function()
    bg_color = get_hl_value('ColorColumn', 'bg')
    fg_color = get_hl_value('ColorColumn', 'fg')
    got_highlight = true
  end, 100)

  reload()
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = vim.api.nvim_create_augroup('MulticolumnReload', {}),
    callback = reload,
  })
end

M.disable = function()
  if not enabled then return end
  enabled = false

  vim.api.nvim_del_augroup_by_name('MulticolumnReload')
  vim.api.nvim_del_augroup_by_name('MulticolumnUpdate')

  vim.api.nvim_set_hl(0, 'ColorColumn', {
    bg = bg_color,
    fg = fg_color,
  })

  for _, win in pairs(vim.api.nvim_list_wins()) do
    vim.fn.clearmatches(win)
    vim.wo[win].colorcolumn = nil
  end
end

M.toggle = function()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

M.setup = function(opts)
  config = build_config(opts or {})

  local start_enabled = false
  if config.start == 'remember' then
    if vim.fn.isdirectory(MULTICOLUMN_DIR) ~= 0 then
      start_enabled = vim.fn.filereadable(ENABLED_FILE) ~= 0
    else
      start_enabled = true
    end
    vim.api.nvim_create_autocmd('VimLeave', { callback = save_enabled_state })
  else
    start_enabled = (config.start == 'enabled')
  end

  if start_enabled then M.enable() end

  vim.api.nvim_create_user_command('MulticolumnEnable', M.enable, {})
  vim.api.nvim_create_user_command('MulticolumnDisable', M.disable, {})
  vim.api.nvim_create_user_command('MulticolumnToggle', M.toggle, {})
end

return M
