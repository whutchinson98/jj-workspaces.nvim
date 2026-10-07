local path = require('jj-workspaces.path')
local runner = require('jj-workspaces.runner')
local M = {}

function M.capture()
  local win = vim.api.nvim_get_current_win()
  return {
    win = win,
    tab = vim.api.nvim_win_get_tabpage(win),
    buf = vim.api.nvim_win_get_buf(win),
    cwd = path.effective_cwd(win),
  }
end

function M.stable(op)
  local editor = op.editor
  if
    not vim.api.nvim_win_is_valid(editor.win)
    or not vim.api.nvim_tabpage_is_valid(editor.tab)
    or vim.api.nvim_win_get_tabpage(editor.win) ~= editor.tab
    or vim.api.nvim_win_get_buf(editor.win) ~= editor.buf
    or path.effective_cwd(editor.win) ~= editor.cwd
  then
    runner.raise('context_changed', 'Invoking window, buffer, or cwd changed', 'validating')
  end
end

local function buffer_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil
  end
  return path.real(name)
    or path.join(path.real(vim.fs.dirname(name)) or vim.fs.dirname(name), vim.fs.basename(name))
end

function M.modified_under(root)
  root = path.real(root)
  if not root then
    return nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local filename = buffer_path(buf)
      if filename and path.within(filename, root) then
        return buf
      end
    end
  end
end

function M.clean_source(context)
  if M.modified_under(context.root) then
    runner.raise(
      'modified_buffer',
      'Save or discard modified source buffers before creating a workspace',
      'validating'
    )
  end
end

local function existing_buffer(filename)
  local canonical = path.real(filename)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name == filename or (canonical and name ~= '' and path.real(name) == canonical) then
      return buf
    end
  end
end

function M.plan(op, source, target)
  local buf = op.editor.buf
  local plan = { action = 'keep' }
  if not op.config.update_on_change or vim.bo[buf].buftype ~= '' then
    return plan
  end
  local filename = vim.api.nvim_buf_get_name(buf)
  local reason = 'unnamed'
  if filename ~= '' then
    local canonical = buffer_path(buf)
    local root = path.real(source.root)
    if not canonical or not root or not path.within(canonical, root) then
      return plan
    end
    local relative = canonical:sub(#root + 2)
    local destination = path.join(target.path, relative)
    local real = path.real(destination)
    local target_root = path.real(target.path)
    local stat = real and vim.uv.fs_stat(real)
    reason = 'missing'
    if real and target_root and not path.within(real, target_root) then
      reason = 'outside_target'
    elseif stat and stat.type == 'file' then
      if vim.fn.filereadable(destination) == 1 then
        plan = { action = 'file', path = destination, buf = existing_buffer(destination) }
      else
        reason = 'inaccessible'
      end
    end
  end
  if plan.action == 'keep' and op.config.missing_file ~= 'keep' then
    plan = { action = 'fallback', reason = reason, path = target.path }
    if op.config.missing_file == 'directory' then
      plan.buf = existing_buffer(target.path)
    end
  end
  if plan.buf == buf then
    return { action = 'keep' }
  end
  M.safe_plan(op, plan)
  return plan
end

function M.safe_plan(op, plan)
  if plan.action == 'keep' then
    return
  end
  -- Autocmds may have loaded a destination buffer since preflight.
  if plan.path then
    plan.buf = existing_buffer(plan.path)
  end
  if vim.bo[op.editor.buf].modified or (plan.buf and vim.bo[plan.buf].modified) then
    runner.raise(
      'modified_buffer',
      'Buffer replacement would hide or reuse unsaved edits',
      'validating'
    )
  end
end

local function command(win, cmd, args)
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_cmd({ cmd = cmd, args = args or {}, magic = { file = false, bar = false } }, {})
  end)
end

function M.switch(op, source, target)
  M.stable(op)
  local plan = M.plan(op, source, target)
  local scope = op.opts.scope or op.config.cwd_scope
  local commands = { global = 'cd', tab = 'tcd', window = 'lcd' }
  local ok, err = pcall(command, op.editor.win, commands[scope], { target.path })
  if not ok then
    -- DirChanged autocmds can throw after the cwd was already changed.
    if path.real(path.effective_cwd(op.editor.win)) ~= path.real(target.path) then
      return false, runner.error('editor_failed', tostring(err), 'switching')
    end
    op.warnings[#op.warnings + 1] = 'Cwd changed but its autocmd failed: ' .. tostring(err)
  end
  local partial = not ok
  local buffer_ok, buffer_error = pcall(function()
    if
      not vim.api.nvim_win_is_valid(op.editor.win)
      or vim.api.nvim_win_get_buf(op.editor.win) ~= op.editor.buf
      or path.real(path.effective_cwd(op.editor.win)) ~= path.real(target.path)
      or path.repository(target.path) ~= source.repository
    then
      runner.raise('context_changed', 'Editor context changed during cwd autocmds', 'switching')
    end
    M.safe_plan(op, plan)
    if plan.action == 'file' then
      local real = path.real(plan.path)
      local root = path.real(target.path)
      if
        not real
        or not root
        or not path.within(real, root)
        or vim.fn.filereadable(plan.path) ~= 1
      then
        runner.raise('unavailable', 'Counterpart file changed during switch', 'switching')
      end
    end
    if plan.action == 'fallback' and type(op.config.missing_file) == 'function' then
      vim.api.nvim_win_call(op.editor.win, function()
        op.config.missing_file({
          source = { name = source.name, path = source.root },
          target = vim.deepcopy(target),
          window = op.editor.win,
          reason = plan.reason,
        })
      end)
    elseif plan.action ~= 'keep' then
      if plan.buf and vim.api.nvim_buf_is_valid(plan.buf) then
        vim.api.nvim_win_set_buf(op.editor.win, plan.buf)
      else
        command(op.editor.win, 'edit', { plan.path })
      end
    end
  end)
  if not buffer_ok then
    partial = true
    op.warnings[#op.warnings + 1] = 'Buffer handling failed: '
      .. (type(buffer_error) == 'table' and buffer_error.message or tostring(buffer_error))
  end
  if op.config.clearjumps_on_change then
    local jump_ok, jump_error = pcall(command, op.editor.win, 'clearjumps')
    if not jump_ok then
      partial = true
      op.warnings[#op.warnings + 1] = 'Jump cleanup failed: ' .. tostring(jump_error)
    end
  end
  if partial then
    return true,
      runner.error('editor_failed', 'Cwd changed, but editor handling was incomplete', 'switching')
  end
  return true
end

function M.forget_guard(op, context, target)
  M.stable(op)
  if not context.name then
    runner.raise('unavailable', 'Current workspace name cannot be validated', 'validating')
  end
  if context.name == target.name then
    runner.raise('invalid_argument', 'Cannot forget the current workspace', 'validating')
  end
  if not target.path then
    return
  end
  local root = path.real(target.path)
  if M.modified_under(target.path) then
    runner.raise('modified_buffer', 'Target workspace has modified loaded buffers', 'validating')
  end
  if root then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cwd = path.effective_cwd(win)
      local boundary = cwd and path.boundary(cwd)
      if boundary == root then
        runner.raise(
          'invalid_argument',
          'Target workspace is active in an editor window',
          'validating'
        )
      end
    end
  end
end

return M
