-- Optional end-to-end check, enabled by JJ_WORKSPACES_REAL_CORE=1 in run.lua.
return function(options)
  local api = vim.api
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local source = options.fixture .. '/e2e-source'
  local target = options.fixture .. '/e2e-created'
  local previous_core = package.loaded['jj-workspaces']
  package.loaded['jj-workspaces'] = nil
  local core = require('jj-workspaces')
  options.restore_revisions()
  local original_input, original_select = vim.ui.input, vim.ui.select

  local function command(cwd, argv)
    local result = vim.system(argv, { cwd = cwd, text = true }):wait(10000)
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout)
  end

  local function wait_for(predicate, message)
    assert(vim.wait(15000, predicate, 10), message or 'end-to-end operation timed out')
  end

  local function find_picker()
    local picker
    wait_for(function()
      local ok, value = pcall(action_state.get_current_picker, api.nvim_get_current_buf())
      if ok and value and value.manager and value.manager:num_results() > 0 then
        picker = value
        return true
      end
      return false
    end, 'end-to-end picker did not render')
    return picker
  end

  local function select_name(picker, name)
    for index = 1, picker.manager:num_results() do
      picker:set_selection(picker:get_row(index))
      if picker:get_selection().value.name == name then
        return
      end
    end
    error('Workspace not found: ' .. name)
  end

  local ok, err = xpcall(function()
    command(options.fixture, { 'jj', 'git', 'init', '--no-colocate', source })
    command(source, { 'jj', 'config', 'set', '--repo', 'user.name', 'Telescope Test' })
    command(source, { 'jj', 'config', 'set', '--repo', 'user.email', 'telescope@example.invalid' })
    api.nvim_set_current_dir(source)
    vim.cmd('enew!')
    local origin = api.nvim_get_current_win()
    local buffer = api.nvim_get_current_buf()
    core.setup({ notify = false, update_on_change = false, cwd_scope = 'window' })
    local result
    local function completed(value)
      result = value
    end
    vim.ui.input = function(opts, callback)
      if opts.prompt == 'Workspace name: ' then
        vim.schedule(function()
          callback('e2e-created')
        end)
      else
        vim.schedule(function()
          callback('')
        end)
      end
    end
    options.record_cancel(options.extension.create_workspace({ on_complete = completed }))
    local picker = find_picker()
    picker:set_selection(picker:get_row(1))
    assert(picker:get_selection().value.revision == '@')
    -- The picker query must not snapshot this file; literal @ must capture it
    -- later, when the core create operation resolves its parent.
    vim.fn.writefile({ 'content written after picker loaded' }, source .. '/after-picker.txt')
    actions.select_default(picker.prompt_bufnr)
    wait_for(function()
      return result ~= nil
    end)
    assert(result.status == 'success', vim.inspect(result))
    assert(result.data.created and result.data.switched, vim.inspect(result))
    assert(api.nvim_get_current_win() == origin)
    assert(api.nvim_win_get_buf(origin) == buffer)
    assert(vim.fn.getcwd() == target, vim.fn.getcwd())
    assert(
      vim.fn.readfile(target .. '/after-picker.txt')[1] == 'content written after picker loaded'
    )
    local created_id = command(
      target,
      { 'jj', '--ignore-working-copy', 'log', '--no-graph', '-r', '@', '-T', 'commit_id' }
    )
    local parent = command(
      target,
      { 'jj', '--ignore-working-copy', 'log', '--no-graph', '-r', '@-', '-T', 'commit_id' }
    )
    assert(created_id ~= parent)
    result = nil
    options.record_cancel(options.extension.workspaces({ on_complete = completed }))
    picker = find_picker()
    select_name(picker, 'default')
    actions.select_default(picker.prompt_bufnr)
    wait_for(function()
      return result ~= nil
    end)
    assert(result.status == 'success', vim.inspect(result))
    assert(vim.fn.getcwd() == source)

    -- Keep ignored/untracked content and metadata as well as the workspace tree.
    vim.fn.writefile({ 'keep this dirty file' }, target .. '/keep.txt')
    result = nil
    vim.ui.select = function(items, opts, callback)
      assert(items[1] == 'Cancel')
      assert(opts.prompt:find('Files will remain on disk', 1, true))
      vim.schedule(function()
        callback(items[2], 2)
      end)
    end
    options.record_cancel(options.extension.workspaces({ on_complete = completed }))
    picker = find_picker()
    select_name(picker, 'e2e-created')
    for _, mapping in ipairs(api.nvim_buf_get_keymap(picker.prompt_bufnr, 'n')) do
      if mapping.lhs:lower() == '<c-d>' then
        if mapping.callback then
          mapping.callback()
        else
          local callback_id = assert(mapping.rhs:match('execute_keymap%((%d+)%)'))
          require('telescope.mappings').execute_keymap(tonumber(callback_id))
        end
        break
      end
    end
    wait_for(function()
      return result ~= nil
    end)
    assert(result.status == 'success', vim.inspect(result))
    assert(result.data.files_deleted == false)
    wait_for(function()
      return picker.manager:num_results() == 1
    end, 'forget did not refresh real inventory')
    assert(vim.fn.readfile(target .. '/keep.txt')[1] == 'keep this dirty file')
    assert(vim.uv.fs_stat(target .. '/.jj'))
    assert(vim.fn.getcwd() == source)
    actions.close(picker.prompt_bufnr)
  end, debug.traceback)
  package.loaded['jj-workspaces'] = previous_core
  vim.ui.input, vim.ui.select = original_input, original_select
  assert(ok, err)
end
