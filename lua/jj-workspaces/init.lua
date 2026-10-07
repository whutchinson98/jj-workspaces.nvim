local backend = require('jj-workspaces.backend')
local config = require('jj-workspaces.config')
local editor = require('jj-workspaces.editor')
local log = require('jj-workspaces.log')
local path = require('jj-workspaces.path')
local runner = require('jj-workspaces.runner')
local M = {}
local sequence = 0
local mutation_lock
local listeners = {}

function M.setup(options)
  config.setup(options)
end

function M.on_change(callback)
  assert(type(callback) == 'function', 'jj-workspaces: listener must be a function')
  local entry = { callback = callback }
  listeners[#listeners + 1] = entry
  return function()
    for index, listener in ipairs(listeners) do
      if listener == entry then
        table.remove(listeners, index)
        break
      end
    end
  end
end

local function emit(op, kind, context, workspace, extra)
  local event = vim.tbl_extend('force', {
    operation_id = op.id,
    kind = kind,
    repository = context.repository,
    workspace = vim.deepcopy(workspace),
    warnings = vim.deepcopy(op.warnings),
  }, extra or {})
  local snapshot = {}
  for _, entry in ipairs(listeners) do
    snapshot[#snapshot + 1] = entry.callback
  end
  for _, callback in ipairs(snapshot) do
    local ok, err = pcall(callback, vim.deepcopy(event))
    if not ok then
      local warning = 'Lifecycle listener failed: ' .. log.bound(err)
      op.warnings[#op.warnings + 1] = warning
      log.write(op, 'warn', warning)
    end
  end
end

local function switch_to(op, context, target)
  op.stage = 'switching'
  backend.guard(context)
  backend.guard({ root = target.path, repository = context.repository })
  local changed, err = editor.switch(op, context, target)
  if changed then
    emit(op, 'switch', context, target, {
      previous = { name = context.name, path = context.root },
      scope = op.opts.scope or op.config.cwd_scope,
    })
  end
  return changed, err
end

local handlers = {}

function handlers.discover(op)
  local context = backend.discover(op, op.cwd)
  backend.guard(context)
  editor.stable(op)
  op.data = context
  return 'success'
end

function handlers.list(op)
  local context = backend.discover(op, op.cwd)
  backend.guard(context)
  editor.stable(op)
  op.data = context.workspaces
  return 'success'
end

function handlers.switch(op)
  local context = backend.discover(op, op.cwd)
  local target = backend.target(op, context, op.name)
  backend.guard(context)
  editor.stable(op)
  op.data = { workspace = target, scope = op.opts.scope or op.config.cwd_scope, root = target.path }
  if context.name == target.name then
    return 'noop'
  end
  local changed, err = switch_to(op, context, target)
  if not changed then
    return 'error', err
  end
  return err and 'partial' or 'success', err
end

local function snapshot_changed(op, before, after)
  local old = backend.find(before.workspaces, before.name)
  local new = backend.find(after.workspaces, before.name)
  if old and new and old.commit_id ~= new.commit_id then
    op.data.source_snapshot = true
    op.failure_status = 'partial'
    op.warnings[#op.warnings + 1] =
      'Source working-copy commit changed during revision resolution (jj may have snapshotted disk files)'
  end
end

function handlers.create(op)
  local context = backend.discover(op, op.cwd)
  if not context.name then
    runner.raise('unavailable', 'Current workspace name cannot be validated', 'validating')
  end
  local destination = backend.destination(op, context)
  op.data =
    { created = false, switched = false, workspace = { name = op.opts.name, path = destination } }
  editor.stable(op)
  editor.clean_source(context)
  if op.opts.switch ~= false then
    editor.plan(op, context, op.data.workspace)
  end
  op.stage = 'validating'
  backend.guard(context)
  -- Revision resolution intentionally allows jj to snapshot the source disk.
  op.failure_status = 'unknown'
  local parent, parent_error = backend.parent(op, context.root, op.opts.revision or '@', false)
  local fresh = backend.revalidate(op, context)
  op.failure_status = nil
  snapshot_changed(op, context, fresh)
  if parent_error then
    return op.failure_status or (parent_error.code == 'timeout' and 'unknown' or 'error'),
      parent_error
  end
  op.data.parent_revision = parent
  local rechecked = backend.destination(op, fresh)
  if rechecked ~= destination then
    runner.raise('context_changed', 'Creation destination changed', 'validating')
  end
  editor.stable(op)
  editor.clean_source(fresh)
  if op.opts.switch ~= false then
    editor.plan(op, fresh, op.data.workspace)
  end
  op.stage = 'creating'
  backend.guard(fresh)
  op.failure_status = 'unknown'
  local _, add_error = runner.run(op, fresh.root, {
    'workspace',
    'add',
    '--name=' .. op.opts.name,
    '--revision',
    parent,
    '--sparse-patterns=copy',
    '--',
    destination,
  }, false)
  local after = backend.revalidate(op, fresh)
  local record = backend.find(after.workspaces, op.opts.name)
  op.data.observed_workspace = record and vim.deepcopy(record) or nil
  op.data.destination_exists = vim.uv.fs_lstat(destination) ~= nil
  if add_error then
    op.warnings[#op.warnings + 1] =
      'Creation was not confirmed; inspect jj workspace list and the destination manually. No cleanup was attempted.'
    return op.data.source_snapshot and 'partial' or 'unknown', add_error
  end
  if not record or not record.path or path.real(record.path) ~= path.real(destination) then
    runner.raise(
      'invalid_output',
      'Add returned success but its registration could not be verified',
      'creating'
    )
  end
  local target = backend.target(op, after, op.opts.name)
  local actual_parent, verify_error = backend.parent(op, target.path, target.commit_id .. '-', true)
  if verify_error then
    error(verify_error, 0)
  end
  if actual_parent ~= parent then
    runner.raise(
      'invalid_output',
      'Created workspace parent does not match the pinned revision',
      'creating'
    )
  end
  op.data.created = true
  op.data.workspace = target
  op.failure_status = 'partial'
  emit(op, 'create', context, target, { parent_revision = parent })
  if op.opts.switch == false then
    return 'success'
  end
  -- Hooks can change editor or repository state; revalidate after Create too.
  target = backend.target(op, after, op.opts.name)
  local changed, switch_error = switch_to(op, context, target)
  op.data.switched = changed
  return switch_error and 'partial' or 'success', switch_error
end

function handlers.forget(op)
  local context = backend.discover(op, op.cwd)
  local target = backend.find(context.workspaces, op.name)
  if not target then
    runner.raise('invalid_argument', 'Unknown workspace name: ' .. op.name, 'validating')
  end
  editor.forget_guard(op, context, target)
  local fresh = backend.revalidate(op, context)
  local current = backend.find(fresh.workspaces, op.name)
  if not current or current.path ~= target.path then
    runner.raise('context_changed', 'Target registration changed', 'validating')
  end
  target = current
  if target.path then
    target = backend.target(op, fresh, op.name)
  else
    op.warnings[#op.warnings + 1] =
      'Workspace path is unavailable; its on-disk/editor state cannot be inspected'
  end
  editor.forget_guard(op, fresh, target)
  backend.guard(fresh)
  if target.path then
    backend.guard({ root = target.path, repository = fresh.repository })
  end
  op.data = { workspace = target, files_deleted = false }
  op.stage = 'forgetting'
  op.failure_status = 'unknown'
  local _, err = runner.run(op, fresh.root, { 'workspace', 'forget', '--', op.name }, true)
  local records = backend.inventory(op, fresh.root)
  local absent = backend.find(records, op.name) == nil
  op.data.forgotten = absent
  if err then
    if absent then
      return 'partial', err
    end
    return err.code == 'timeout' and 'unknown' or 'error', err
  end
  if not absent then
    runner.raise('invalid_output', 'Forget returned success but registration remains', 'forgetting')
  end
  emit(op, 'forget', context, target)
  return 'success'
end

local option_keys = {
  discover = { cwd = true },
  list = { cwd = true },
  switch = { cwd = true, scope = true },
  create = { cwd = true, scope = true, name = true, path = true, revision = true, switch = true },
  forget = { cwd = true },
}

local function validate(op)
  if type(op.opts) ~= 'table' then
    runner.raise('invalid_argument', 'Options must be a table', 'validating')
  end
  for key in pairs(op.opts) do
    if not option_keys[op.kind][key] then
      runner.raise('invalid_argument', 'Unknown option: ' .. tostring(key), 'validating')
    end
  end
  if op.callback ~= nil and type(op.callback) ~= 'function' then
    runner.raise('invalid_argument', 'Completion callback must be a function', 'validating')
  end
  if op.opts.cwd ~= nil and not path.absolute(op.opts.cwd) then
    runner.raise('invalid_argument', 'cwd must be an absolute directory', 'validating')
  end
  if op.opts.scope ~= nil and not config.scope(op.opts.scope) then
    runner.raise('invalid_argument', 'Invalid cwd scope', 'validating')
  end
  if (op.kind == 'switch' or op.kind == 'forget') and not path.valid(op.name) then
    runner.raise('invalid_argument', 'Workspace name must be nonempty and NUL-free', 'validating')
  end
  if op.kind == 'create' then
    if not path.valid(op.opts.name) then
      runner.raise('invalid_argument', 'Workspace name is required', 'validating')
    end
    for _, key in ipairs({ 'path', 'revision' }) do
      if op.opts[key] ~= nil and not path.valid(op.opts[key]) then
        runner.raise('invalid_argument', key .. ' must be nonempty and NUL-free', 'validating')
      end
    end
    if op.opts.switch ~= nil and type(op.opts.switch) ~= 'boolean' then
      runner.raise('invalid_argument', 'switch must be boolean', 'validating')
    end
  end
end

local function start(kind, name, opts, callback)
  sequence = sequence + 1
  local options = opts == nil and {} or opts
  local copy_error
  if type(options) == 'table' then
    local ok, copy = pcall(vim.deepcopy, options)
    if ok then
      options = copy
    else
      options = {}
      copy_error = 'Options contain an unsupported value'
    end
  end
  local op = {
    id = 'op-' .. sequence,
    kind = kind,
    name = name,
    opts = options,
    callback = callback,
    config = config.snapshot(),
    editor = editor.capture(),
    stage = 'validating',
    warnings = {},
    data = {},
  }
  op.cwd = type(op.opts) == 'table' and op.opts.cwd or nil
  op.cwd = op.cwd or op.editor.cwd
  local mutation = kind == 'create' or kind == 'switch' or kind == 'forget'
  local busy = mutation and mutation_lock ~= nil
  if mutation and not busy then
    mutation_lock = op.id
  end
  local done = false
  local function finish(status, err)
    if done then
      return
    end
    done = true
    op.stage = 'complete'
    local result = {
      id = op.id,
      operation = kind,
      status = status,
      data = op.data,
      error = err,
      warnings = op.warnings,
    }
    -- Completion and notification code must never strand the mutation lock.
    local ok, finish_error = pcall(function()
      log.write(
        op,
        err and 'error' or 'info',
        err and (err.message .. '\n' .. (err.stderr or '')) or status
      )
      if op.config.notify and err then
        local message = 'jj-workspaces: ' .. status .. ': ' .. err.message
        if err.stderr and err.stderr ~= '' then
          message = message .. '\n' .. err.stderr
        end
        pcall(vim.notify, log.bound(message, 2048), vim.log.levels.ERROR)
      end
      if type(callback) == 'function' then
        local callback_ok, callback_error = pcall(callback, result)
        if not callback_ok then
          local warning = 'Completion callback failed: ' .. log.bound(callback_error)
          op.warnings[#op.warnings + 1] = warning
          log.write(op, 'warn', warning)
        end
      end
    end)
    if mutation_lock == op.id then
      mutation_lock = nil
    end
    if not ok then
      log.write(op, 'error', 'Completion delivery failed: ' .. tostring(finish_error))
    end
  end
  local thread = coroutine.create(function()
    if copy_error then
      runner.raise('invalid_argument', copy_error, 'validating')
    end
    validate(op)
    if busy then
      runner.raise('busy', 'Another workspace mutation or switch is in progress', 'validating')
    end
    if op.config.log_warning then
      op.warnings[#op.warnings + 1] = op.config.log_warning
      log.write(op, 'warn', op.config.log_warning)
    end
    return handlers[kind](op)
  end)
  op.resume = function(...)
    if done then
      return
    end
    local ok, status, err = coroutine.resume(thread, ...)
    if not ok then
      local failure = status
      if type(failure) ~= 'table' or not failure.code then
        failure = runner.error('editor_failed', tostring(failure), op.stage)
      end
      finish(op.failure_status or 'error', failure)
    elseif coroutine.status(thread) == 'dead' then
      finish(status, err)
    end
  end
  vim.schedule(op.resume)
  return op.id
end

function M.discover(opts, callback)
  return start('discover', nil, opts, callback)
end

function M.list(opts, callback)
  return start('list', nil, opts, callback)
end

function M.create(opts, callback)
  return start('create', nil, opts, callback)
end

function M.switch(name, opts, callback)
  return start('switch', name, opts, callback)
end

function M.forget(name, opts, callback)
  return start('forget', name, opts, callback)
end

return M
