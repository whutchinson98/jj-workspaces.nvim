local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local config = require('telescope.config').values
local entry_display = require('telescope.pickers.entry_display')
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local utils = require('telescope.utils')
local context = require('telescope._extensions.jj_workspaces.context')
local revisions = require('telescope._extensions.jj_workspaces.revisions')

local M = {}
local api = vim.api
-- Only replacement ownership is shared. Drafts, requests and confirmations belong
-- to their invocation, and submitted mutations always retain their completion.
local active_flow

local function successful(result)
  return result.status == 'success' or result.status == 'noop'
end

local function report(result)
  if successful(result) then
    return
  end
  local message = result.status
    .. ': '
    .. ((result.error and result.error.message) or 'Operation did not complete')
  if result.error and result.error.code then
    message = result.error.code .. ': ' .. message
  end
  if result.operation == 'create' and result.data and result.data.created then
    local workspace = result.data.workspace or result.data
    message = message
      .. '. Workspace "'
      .. tostring(workspace.name or '[unknown name]')
      .. '" at '
      .. tostring(workspace.path or '[unknown path]')
      .. ' already exists; inspect it and switch later, do not create it again'
  elseif result.status == 'partial' or result.status == 'unknown' then
    message = message .. '. Inspect jj state before retrying; no cleanup or retry was performed'
  end
  context.notify(message, vim.log.levels.ERROR)
end

local function complete(flow, result)
  report(result)
  for _, warning in ipairs(result.warnings or {}) do
    context.notify(
      type(warning) == 'table' and (warning.message or vim.inspect(warning)) or warning
    )
  end
  if flow.options.on_complete then
    local ok, err = pcall(flow.options.on_complete, result)
    if not ok then
      context.notify('on_complete failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function live_picker(flow)
  return flow.alive
    and flow.phase == 'picker'
    and flow.prompt
    and api.nvim_buf_is_valid(flow.prompt)
    and api.nvim_buf_is_loaded(flow.prompt)
    and flow.picker
    and api.nvim_win_is_valid(flow.picker.prompt_win)
end

local function cancel(flow)
  flow.alive = false
  flow.generation = flow.generation + 1
  flow.prompt_token = flow.prompt_token + 1
  flow.pending = false
  if flow.cancel_query then
    flow.cancel_query()
    flow.cancel_query = nil
  end
  if active_flow == flow then
    active_flow = nil
  end
end

local function close_picker(flow)
  if
    not flow.prompt
    or not api.nvim_buf_is_valid(flow.prompt)
    or not api.nvim_buf_is_loaded(flow.prompt)
    or not flow.picker
    or not flow.picker.prompt_win
    or not api.nvim_win_is_valid(flow.picker.prompt_win)
  then
    return
  end
  -- actions.close restores focus. Use it only while this picker has focus.
  local close = pickers.on_close_prompt
  if api.nvim_get_current_buf() == flow.prompt then
    close = actions.close
  end
  local ok, err = pcall(close, flow.prompt)
  if not ok then
    cancel(flow)
    context.notify('Cannot close Telescope picker: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function valid(flow)
  if not flow.alive then
    return false
  end
  if not context.valid(flow.origin) then
    context.notify('context_changed: originating window, tab, buffer, or cwd changed')
    cancel(flow)
    return false
  end
  return true
end

local function invoke(flow, callback)
  if not valid(flow) then
    return false
  end
  local ok, err = context.call(flow.origin, callback)
  if not ok then
    flow.busy = false
    flow.pending = false
    flow.generation = flow.generation + 1
    context.notify(err, vim.log.levels.ERROR)
  end
  return ok
end

local function start(options)
  local opts = vim.deepcopy(options or {})
  if opts.force ~= nil or opts.delete_files ~= nil or opts.confirm_telescope_deletions ~= nil then
    context.notify(
      'Forgetting always confirms and keeps files; force/deletion options are not supported'
    )
    return
  end
  local origin, err = context.capture()
  if not origin then
    context.notify(err)
    return
  end
  local ok, core = pcall(require, 'jj-workspaces')
  if not ok then
    context.notify('Cannot load jj-workspaces core: ' .. tostring(core), vim.log.levels.ERROR)
    return
  end
  if active_flow then
    local previous = active_flow
    cancel(previous)
    close_picker(previous)
  end
  local flow = {
    alive = true,
    phase = 'loading',
    generation = 0,
    prompt_token = 0,
    origin = origin,
    cwd = opts.cwd or origin.cwd,
    options = opts,
    core = core,
  }
  active_flow = flow
  return flow
end

local function discover(flow, callback)
  flow.generation = flow.generation + 1
  local generation = flow.generation
  invoke(flow, function()
    flow.core.discover({ cwd = flow.cwd }, function(result)
      if not flow.alive or flow.generation ~= generation then
        return
      end
      if not successful(result) then
        report(result)
        flow.busy = false
        if flow.phase ~= 'picker' then
          cancel(flow)
        end
        return
      end
      if valid(flow) then
        callback(result.data)
      end
    end)
  end)
end

local function revalidate(flow, workspace, callback)
  discover(flow, function(data)
    if
      not vim.deep_equal(data.repository, flow.discovery.repository)
      or data.root ~= flow.discovery.root
      or data.name ~= flow.discovery.name
    then
      context.notify('context_changed: source repository/workspace identity changed')
      cancel(flow)
      return
    end
    if workspace then
      local found
      for _, record in ipairs(data.workspaces or {}) do
        if record.name == workspace.name and record.path == workspace.path then
          found = true
          break
        end
      end
      if not found then
        flow.busy = false
        flow.stale = true
        context.notify('Workspace registration changed; reopen the picker for fresh inventory')
        return
      end
    end
    callback()
  end)
end

local function telescope_options(flow)
  local opts = vim.deepcopy(flow.options)
  for _, key in ipairs({
    'cwd',
    'scope',
    'on_complete',
    'jj_command',
    'revision_timeout_ms',
    'name',
    'path',
    'revision',
    'switch',
    'attach_mappings',
  }) do
    opts[key] = nil
  end
  -- Resuming a cached picker would reuse expired origin and confirmation tokens.
  opts.cache_picker = false
  opts.previewer = false
  return opts
end

local function attach(flow, defaults)
  return function(prompt, map)
    flow.prompt = prompt
    flow.phase = 'picker'
    api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete', 'BufHidden' }, {
      buffer = prompt,
      once = true,
      callback = function()
        if flow.phase == 'picker' then
          cancel(flow)
        end
      end,
    })
    defaults(prompt, map)
    local custom = flow.options.attach_mappings
    if custom then
      local ok, result = pcall(custom, prompt, map)
      if not ok then
        cancel(flow)
        vim.schedule(function()
          close_picker(flow)
          context.notify('attach_mappings failed: ' .. tostring(result), vim.log.levels.ERROR)
        end)
        return false
      end
      return result
    end
    return true
  end
end

local function show(flow, definition)
  if not valid(flow) then
    return
  end
  if api.nvim_get_current_win() ~= flow.origin.win then
    context.notify('Origin lost focus while loading; picker was not opened')
    cancel(flow)
    return
  end
  local ok, err = pcall(function()
    flow.picker = pickers.new(telescope_options(flow), definition)
    flow.picker:find()
  end)
  if not ok then
    cancel(flow)
    close_picker(flow)
    context.notify('Cannot open Telescope picker: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function available(workspace)
  return type(workspace.path) == 'string' and workspace.path ~= ''
end

local function current(flow, workspace)
  return workspace.name == flow.discovery.name and workspace.path == flow.discovery.root
end

local function workspace_finder(flow, workspaces)
  local width = 4
  for _, workspace in ipairs(workspaces) do
    width = math.max(width, vim.fn.strdisplaywidth(context.clean(workspace.name)))
  end
  local display = entry_display.create({
    separator = '  ',
    items = { { width = 1 }, { width = math.min(width, 30) }, { width = 12 }, { remaining = true } },
  })
  return finders.new_table({
    results = workspaces,
    entry_maker = function(workspace)
      local name = context.clean(workspace.name)
      local path = '[unavailable]'
      if available(workspace) then
        path = context.clean(utils.transform_path(flow.options, workspace.path))
      end
      local id = context.clean(workspace.commit_id)
      return {
        value = workspace,
        ordinal = name .. ' ' .. context.clean(workspace.path) .. ' ' .. id,
        display = function()
          return display({ current(flow, workspace) and '*' or ' ', name, id:sub(1, 12), path })
        end,
      }
    end,
  })
end

local function selected(flow)
  if not live_picker(flow) or not valid(flow) or flow.busy or flow.pending then
    return
  end
  if flow.stale then
    context.notify('Inventory is stale; reopen the picker before acting')
    return
  end
  local entry = flow.picker:get_selection()
  if not entry then
    context.notify('No workspace selected')
    return
  end
  return vim.deepcopy(entry.value)
end

local function refresh(flow)
  if not live_picker(flow) or not valid(flow) then
    return
  end
  flow.generation = flow.generation + 1
  local generation = flow.generation
  flow.busy = true
  invoke(flow, function()
    flow.core.list({ cwd = flow.cwd }, function(result)
      if not live_picker(flow) or flow.generation ~= generation or not valid(flow) then
        return
      end
      flow.busy = false
      if not successful(result) then
        flow.stale = true
        context.notify(
          'Forget completed, but refresh failed; inventory is stale. Reopen the picker'
        )
        report(result)
        return
      end
      flow.stale = false
      -- Telescope's row strategy clamps to a nearby surviving row. Refresh keeps
      -- prompt text intact and never restores a removed selection by name.
      flow.picker.selection_strategy = 'row'
      flow.picker:refresh(workspace_finder(flow, result.data), { reset_prompt = false })
    end)
  end)
end

local function switch_workspace(flow)
  local workspace = selected(flow)
  if not workspace then
    return
  end
  if not available(workspace) then
    context.notify(
      'Workspace path is unavailable; cannot switch (metadata-only forget remains available)'
    )
    return
  end
  flow.busy = true
  revalidate(flow, workspace, function()
    flow.phase = 'submitting'
    close_picker(flow)
    invoke(flow, function()
      flow.core.switch(
        workspace.name,
        { cwd = flow.cwd, scope = flow.options.scope },
        function(result)
          complete(flow, result)
        end
      )
    end)
    cancel(flow)
  end)
end

local function forget_workspace(flow)
  local workspace = selected(flow)
  if not workspace then
    return
  end
  if current(flow, workspace) then
    context.notify('Cannot forget the current workspace; leave it first')
    return
  end
  flow.pending = true
  flow.prompt_token = flow.prompt_token + 1
  local token = flow.prompt_token
  local affirmative = 'Forget workspace (keep files)'
  local location = available(workspace) and context.clean(workspace.path) or '[unavailable]'
  local prompt = 'Forget workspace "'
    .. context.clean(workspace.name)
    .. '" at '
    .. location
    .. '? Files will remain on disk. Registration is removed; further jj use may require explicit recovery.'
  if not available(workspace) then
    prompt = prompt .. ' Its on-disk/editor state could not be inspected.'
  end
  local ok, err = pcall(
    vim.ui.select,
    { 'Cancel', affirmative },
    { prompt = prompt },
    function(choice)
      if not live_picker(flow) or token ~= flow.prompt_token then
        return
      end
      flow.prompt_token = flow.prompt_token + 1
      flow.pending = false
      if choice ~= affirmative or not valid(flow) then
        return
      end
      flow.busy = true
      revalidate(flow, workspace, function()
        invoke(flow, function()
          flow.core.forget(workspace.name, { cwd = flow.cwd }, function(result)
            complete(flow, result)
            if not live_picker(flow) then
              return
            end
            flow.busy = false
            if successful(result) or result.status == 'partial' or result.status == 'unknown' then
              refresh(flow)
            end
          end)
        end)
      end)
    end
  )
  if not ok then
    flow.pending = false
    flow.prompt_token = flow.prompt_token + 1
    context.notify('Confirmation failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.workspaces(opts)
  local flow = start(opts)
  if not flow then
    return
  end
  discover(flow, function(data)
    flow.discovery = vim.deepcopy(data)
    if #data.workspaces == 0 then
      context.notify('Repository has no registered workspaces', vim.log.levels.INFO)
      cancel(flow)
      return
    end
    show(flow, {
      prompt_title = 'jj workspaces | Enter: switch | Ctrl-D: forget (keep files)',
      finder = workspace_finder(flow, data.workspaces),
      sorter = config.generic_sorter(flow.options),
      attach_mappings = attach(flow, function(_, map)
        actions.select_default:replace(function()
          switch_workspace(flow)
        end)
        for _, mode in ipairs({ 'i', 'n' }) do
          map(mode, '<C-d>', function()
            forget_workspace(flow)
          end, { desc = 'Forget workspace (keep files)' })
        end
      end),
    })
  end)
  return function()
    cancel(flow)
    close_picker(flow)
  end
end

local function input(flow, options, callback)
  if not valid(flow) then
    return
  end
  flow.prompt_token = flow.prompt_token + 1
  local token = flow.prompt_token
  local ok, err = pcall(vim.ui.input, options, function(value)
    if not flow.alive or token ~= flow.prompt_token then
      return
    end
    flow.prompt_token = flow.prompt_token + 1
    if value == nil then
      cancel(flow)
    elseif valid(flow) then
      callback(value)
    end
  end)
  if not ok then
    cancel(flow)
    context.notify('Input prompt failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function create_prompts(flow, revision)
  flow.phase = 'prompts'
  close_picker(flow)
  local function ask_name()
    input(flow, { prompt = 'Workspace name: ' }, function(name)
      if name == '' then
        context.notify('Workspace name must not be empty')
        vim.schedule(ask_name)
        return
      end
      input(flow, {
        prompt = 'Workspace directory (empty = core-configured default; relative = source root): ',
        default = '',
        completion = 'dir',
      }, function(path)
        flow.busy = true
        revalidate(flow, nil, function()
          invoke(flow, function()
            local options = {
              cwd = flow.cwd,
              name = name,
              revision = revision,
              switch = true,
              scope = flow.options.scope,
            }
            if path ~= '' then
              options.path = path
            end
            flow.core.create(options, function(result)
              complete(flow, result)
            end)
          end)
          cancel(flow)
        end)
      end)
    end)
  end
  ask_name()
end

local function choose_revision(flow, typed)
  if not live_picker(flow) or flow.busy or not valid(flow) then
    return
  end
  local entry = flow.picker:get_selection()
  local revision
  if not typed and entry then
    revision = entry.value.revision
  else
    revision = action_state.get_current_line()
    if not revision or revision:match('^%s*$') then
      context.notify('Enter a revision expression; Ctrl-R uses the prompt text')
      return
    end
  end
  flow.busy = true
  create_prompts(flow, revision)
end

function M.create_workspace(opts)
  local flow = start(opts)
  if not flow then
    return
  end
  discover(flow, function(data)
    flow.discovery = vim.deepcopy(data)
    flow.cancel_query = revisions.load(data.root, flow.options, function(candidates, err)
      flow.cancel_query = nil
      if not valid(flow) then
        return
      end
      if err then
        context.notify(err, vim.log.levels.ERROR)
        cancel(flow)
        return
      end
      show(flow, {
        prompt_title = 'jj parent | Enter: choose | Ctrl-R: use typed revision',
        finder = finders.new_table({
          results = candidates,
          entry_maker = function(candidate)
            return {
              value = candidate,
              ordinal = context.clean(candidate.revision .. ' ' .. candidate.label),
              display = context.clean(candidate.label),
            }
          end,
        }),
        sorter = config.generic_sorter(flow.options),
        attach_mappings = attach(flow, function(_, map)
          actions.select_default:replace(function()
            choose_revision(flow, false)
          end)
          for _, mode in ipairs({ 'i', 'n' }) do
            map(mode, '<C-r>', function()
              choose_revision(flow, true)
            end, { desc = 'Use typed jj revision expression' })
          end
        end),
      })
    end)
  end)
  return function()
    cancel(flow)
    close_picker(flow)
  end
end

return M
