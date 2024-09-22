local api = vim.api
local success, indent_mod = pcall(require, 'hlchunk.mods.indent')

local config = require('treesitter-context.config')

local augroup = api.nvim_create_augroup
local command = api.nvim_create_user_command

local enabled = false

--- @type table<integer, Range4[]>
local all_contexts = {}

--- @generic F: function
--- @param f F
--- @param ms? number
--- @return F
local function throttle(f, ms)
  ms = ms or 200
  local timer = assert(vim.loop.new_timer())
  local waiting = 0
  return function()
    if timer:is_active() then
      waiting = waiting + 1
      return
    end
    waiting = 0
    f() -- first call, execute immediately
    timer:start(ms, 0, function()
      if waiting > 1 then
        vim.schedule(f) -- only execute if there are calls waiting
      end
    end)
  end
end

--- @param winid integer
--- @param fast boolean?
local function close(winid, fast)
  require('treesitter-context.render').close(winid, fast)
end

local function close_all()
  local window_contexts = require('treesitter-context.render').get_window_contexts()
  for winid, _ in pairs(window_contexts) do
    close(winid)
  end
end

--- @param bufnr integer
--- @param winid integer
--- @param ctx_ranges Range4[]
--- @param ctx_lines string[]
local function open(bufnr, winid, ctx_ranges, ctx_lines)
  require('treesitter-context.render').open(bufnr, winid, ctx_ranges, ctx_lines)
end

---@param bufnr integer
---@param winid integer
---@return Range4[]?, string[]?
local function get_context(bufnr, winid, height)
  return require('treesitter-context.context').get(bufnr, winid, height)
end

local attached = {} --- @type table<integer,true>

---@param bufnr integer
---@param winid integer
local function can_open(bufnr, winid)
  if (not api.nvim_win_is_valid(winid)) or (not vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  if vim.w[winid].gitsigns_preview then
    return false
  end

  if vim.b[bufnr].ts_parse_over == true then
    return true
  end

  if vim.b[bufnr].telescope == true then
    return true
  end

  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].filetype == '' then
    return false
  end

  if vim.bo[bufnr].buftype ~= '' then
    return false
  end

  if vim.wo[winid].previewwindow then
    return false
  end

  if vim.fn.getcmdtype() ~= '' then
    return false
  end

  if api.nvim_win_get_height(winid) < config.min_window_height then
    return false
  end

  return true
end

local update = throttle(function()
  vim.defer_fn(function()
    pcall(_G.update_indent, true)
  end, 100)
  local bufnr = api.nvim_get_current_buf()
  local winid = api.nvim_get_current_win()

  local active_win_view = vim.fn.winsaveview()
  local mode = vim.fn.mode()
  if mode ~= 'n' and active_win_view.leftcol == 0 then
    return
  end

  if vim.g.type_star then
    return
  end

  if not can_open(bufnr, winid) then
    close(winid)
    return
  end

  local context, context_lines = get_context(bufnr, winid)
  all_contexts[bufnr] = context

  if not context or #context == 0 then
    close(winid)
    return
  end

  assert(context_lines)

  open(bufnr, winid, context, context_lines)
end)

local function update_at_resize()
  local event = vim.api.nvim_get_vvar('event')
  local window_ids = event.windows
  for stored_winid, window_context in
    pairs(require('treesitter-context.render').get_window_contexts())
  do
    for _, window_id in pairs(window_ids) do
      if stored_winid == window_id then
        local bufnr = window_context.bufnr
        close(stored_winid)

        if not can_open(bufnr, stored_winid) then
          return
        end

        local context, context_lines = get_context(bufnr, stored_winid)
        all_contexts[bufnr] = context
        if not context or #context == 0 then
          return
        end
        open(bufnr, stored_winid, context, context_lines)
      end
    end
  end
end

local M = {
  config = config,
}

function M.has_buf_active(bufnr)
  for stored_winid, value in pairs(require('treesitter-context.render').get_window_contexts()) do
    if bufnr == value.bufnr then
      return true
    end
  end
  return false
end

function M.close_cur_win()
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local window_ctx = require('treesitter-context.render').get_window_contexts()[winid]
  if window_ctx then
    if window_ctx.bufnr ~= bufnr then
      close(winid, true)
    end
  end
end

function M.close_stored_win(winid)
  for stored_winid, _ in pairs(require('treesitter-context.render').get_window_contexts()) do
    if winid == stored_winid then
      close(stored_winid, true)
    end
  end
end

-- do not close window, it cuase too many reopen so filckers
M.context_hlslens_force_update = function(bufnr, winid)
  bufnr = bufnr or api.nvim_get_current_buf()
  winid = winid or api.nvim_get_current_win()

  local active_win_view = vim.fn.winsaveview()
  local mode = vim.fn.mode()
  if mode == 'i' and active_win_view.leftcol == 0 and vim.bo.filetype ~= 'TelescopePrompt' then
    return
  end

  local context, context_lines = get_context(bufnr, winid)
  all_contexts[bufnr] = context

  if not can_open(bufnr, winid) then
    close(winid)
    return
  end
  if not context or #context == 0 then
    close(winid)
    return
  end

  assert(context_lines)

  open(bufnr, winid, context, context_lines)
end

M.context_force_update = function(bufnr, winid, close_all)
  bufnr = bufnr or api.nvim_get_current_buf()
  winid = winid or api.nvim_get_current_win()

  local active_win_view = vim.fn.winsaveview()
  local mode = vim.fn.mode()
  if mode == 'i' and active_win_view.leftcol == 0 and vim.bo.filetype ~= 'TelescopePrompt' then
    return
  end
  vim.defer_fn(function()
    pcall(_G.update_indent, true, winid) -- hlchunk
  end, 100)

  if not can_open(bufnr, winid) then
    close(winid)
    return
  end

  -- conflict with trouble
  if not close_all then
    close(winid)
  end

  local context, context_lines = get_context(bufnr, winid)
  all_contexts[bufnr] = context

  if close_all then
    local window_contexts = require('treesitter-context.render').get_window_contexts()
    for stored_winid, _ in pairs(window_contexts) do
      close(stored_winid)
    end
  end

  if not context or #context == 0 then
    close(winid)
    return
  end

  assert(context_lines)

  open(bufnr, winid, context, context_lines)
end

M.update_virt = throttle(function()
  local bufnr = api.nvim_get_current_buf()
  local winid = api.nvim_get_current_win()
  local mode = vim.fn.mode()
  if mode ~= 'n' then
    return
  end
  if not can_open(bufnr, winid) then
    close(winid)
    return
  end

  local context, context_lines = get_context(bufnr, winid)
  all_contexts[bufnr] = context

  if not context or #context == 0 then
    close(winid)
    return
  end

  assert(context_lines)

  open(bufnr, winid, context, context_lines)
end)

function M.close_all()
  local window_contexts = require('treesitter-context.render').get_window_contexts()
  for winid, _ in pairs(window_contexts) do
    close(winid)
  end
end
local group = augroup('treesitter_context_update', {})

---@param event string|string[]
---@param callback fun(args: table)
---@param opts? vim.api.keyset.create_autocmd
local function autocmd(event, callback, opts)
  opts = opts or {}
  opts.callback = callback
  opts.group = group
  api.nvim_create_autocmd(event, opts)
end

function M.enable()
  local cbuf = api.nvim_get_current_buf()

  attached[cbuf] = true

  autocmd({ 'WinScrolled', 'BufEnter', 'BufWinEnter', 'VimResized' }, function()
    vim.defer_fn(update, 20)
  end)

  autocmd({ 'BufEnter' }, M.close_cur_win)

  autocmd({ 'WinResized' }, update_at_resize)

  autocmd('BufReadPost', function(args)
    attached[args.buf] = nil
    if not config.on_attach or config.on_attach(args.buf) ~= false then
      attached[args.buf] = true
    end
  end)

  autocmd('BufDelete', function(args)
    attached[args.buf] = nil
  end)
  autocmd('CursorMoved', function()
    if vim.g.gd or vim.g.type_o then
      return
    end
    vim.schedule(update)
  end)
  autocmd('OptionSet', function(args)
    if args.match == 'number' or args.match == 'relativenumber' then
      update()
    end
  end)

  autocmd({ 'WinClosed' }, function(args)
    local winid = tonumber(args.match)
    M.close_stored_win(winid)
  end)

  autocmd('User', close_all, { pattern = 'SessionSavePre' })
  autocmd('User', update, { pattern = 'SessionSavePost' })

  update()
  enabled = true
end

function M.disable()
  augroup('treesitter_context_update', {})
  attached = {}
  close_all()
  enabled = false
end

function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.enabled()
  return enabled
end

local function init()
  command('TSContextEnable', M.enable, {})
  command('TSContextDisable', M.disable, {})
  command('TSContextToggle', M.toggle, {})

  api.nvim_set_hl(0, 'TreesitterContext', { link = 'NormalFloat', default = true })
  api.nvim_set_hl(0, 'TreesitterContextLineNumber', { link = 'LineNr', default = true })
  api.nvim_set_hl(0, 'TreesitterContextBottom', { link = 'NONE', default = true })
  api.nvim_set_hl(
    0,
    'TreesitterContextLineNumberBottom',
    { link = 'TreesitterContextBottom', default = true }
  )
  api.nvim_set_hl(0, 'TreesitterContextSeparator', { link = 'FloatBorder', default = true })
end

local did_init = false

---@param options? TSContext.UserConfig
function M.setup(options)
  if options then
    config.update(options)
  end

  if config.enable then
    M.enable()
  else
    M.disable()
  end

  if not did_init then
    init()
    did_init = true
  end
end

---@param depth integer? default 1
function M.go_to_context(depth)
  depth = depth or 1
  local d = depth
  local line = api.nvim_win_get_cursor(0)[1]
  local context = nil
  local bufnr = api.nvim_get_current_buf()
  local contexts = all_contexts[bufnr] or {}

  for idx = #contexts, 1, -1 do
    local c = contexts[idx]
    if d == 0 then
      break
    end
    if c[1] + 1 < line then
      context = c
      d = d - 1
    end
  end
  if depth == 0 then
    context = contexts[1]
  end
  if context == nil then
    return
  end

  vim.cmd([[ normal! m' ]]) -- add current cursor position to the jump list

  local a, col = vim.fn.getline(context[1] + 1):find('^%s*')
  api.nvim_win_set_cursor(0, { context[1] + 1, col })
end

return M
