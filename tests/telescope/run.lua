-- Run from the repository root. Dependencies are optional environment paths,
-- but required for this suite: it exercises real Telescope, not a picker mock.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local telescope_dir = vim.env.TELESCOPE_DIR
local plenary_dir = vim.env.PLENARY_DIR
if telescope_dir then
  vim.opt.runtimepath:append(telescope_dir)
end
if plenary_dir then
  vim.opt.runtimepath:append(plenary_dir)
end
if not pcall(require, 'telescope') or not pcall(require, 'plenary') then
  io.stderr:write(
    'Set TELESCOPE_DIR and PLENARY_DIR to installed telescope.nvim and plenary.nvim directories.\n'
  )
  vim.cmd('cquit 1')
end

vim.o.swapfile = false
vim.o.hidden = true
vim.o.lines = 40
vim.o.columns = 140
local api = vim.api
local actions = require('telescope.actions')
local state = require('telescope.actions.state')
local context = require('telescope._extensions.jj_workspaces.context')
local revision_query = require('telescope._extensions.jj_workspaces.revisions')
local tests = {}
local notifications, requests, confirmations, inputs, completions
local cancel_flow, picker, origin, original_buffer
local original_notify, original_input, original_select = vim.notify, vim.ui.input, vim.ui.select
local original_revision_load = revision_query.load
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. '/source', 'p')
vim.fn.mkdir(fixture .. '/feature', 'p')
local source = fixture .. '/source'
local feature = fixture .. '/feature'
local id = string.rep('a', 40)
local inventory
local discovery
local core = {}

local function equal(expected, actual)
  assert(
    vim.deep_equal(expected, actual),
    'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual)
  )
end

local function wait_for(predicate, message)
  assert(vim.wait(2000, predicate, 5), message or 'timed out')
end

local function request(operation, name, opts, callback)
  local entry = {
    operation = operation,
    name = name,
    opts = vim.deepcopy(opts),
    callback = callback,
    win = api.nvim_get_current_win(),
    buf = api.nvim_get_current_buf(),
    tab = api.nvim_get_current_tabpage(),
    cwd = vim.fn.getcwd(),
  }
  requests[#requests + 1] = entry
  return 'test-' .. #requests
end

for _, operation in ipairs({ 'discover', 'list', 'create' }) do
  core[operation] = function(opts, callback)
    return request(operation, nil, opts, callback)
  end
end
for _, operation in ipairs({ 'switch', 'forget' }) do
  core[operation] = function(name, opts, callback)
    return request(operation, name, opts, callback)
  end
end
package.loaded['jj-workspaces'] = core
require('telescope').setup({
  defaults = { initial_mode = 'normal', sorting_strategy = 'ascending' },
})
require('telescope').load_extension('jj_workspaces')
local extension = require('telescope').extensions.jj_workspaces

local function respond(index, status, data, message)
  local entry = assert(requests[index], 'missing request ' .. index)
  local result = {
    id = 'test-' .. index,
    operation = entry.operation,
    status = status or 'success',
    data = data,
    warnings = {},
    error = message and { code = 'test_error', message = message },
  }
  vim.schedule(function()
    entry.callback(result)
  end)
  vim.wait(30, function()
    return false
  end, 5)
end

local function has_message(text)
  for _, message in ipairs(notifications) do
    if message:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function reset()
  if cancel_flow then
    cancel_flow()
    cancel_flow = nil
  end
  vim.cmd('stopinsert')
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  api.nvim_set_current_dir(source)
  vim.cmd('enew!')
  origin = api.nvim_get_current_win()
  original_buffer = api.nvim_get_current_buf()
  notifications, requests, confirmations, inputs, completions = {}, {}, {}, {}, {}
  inventory = {
    { name = 'default', path = source, commit_id = id, current = true },
    { name = 'feature spaces', path = feature, commit_id = string.rep('b', 40) },
    { name = 'gone', commit_id = string.rep('c', 40) },
  }
  discovery =
    { repository = fixture .. '/repo', root = source, name = 'default', workspaces = inventory }
  vim.notify = function(message)
    notifications[#notifications + 1] = message
  end
  vim.ui.select = function(items, opts, callback)
    confirmations[#confirmations + 1] = { items = items, opts = opts, callback = callback }
  end
  vim.ui.input = function(opts, callback)
    inputs[#inputs + 1] = { opts = opts, callback = callback }
  end
  revision_query.load = function(_, _, callback)
    vim.schedule(function()
      callback({
        { revision = '@', label = 'Current workspace (@; snapshot at creation)' },
        { revision = id, label = 'aaaaaaaaaaaa bookmark description' },
      })
    end)
    return function() end
  end
  picker = nil
end

local function opened(count)
  wait_for(function()
    local ok, value = pcall(state.get_current_picker, api.nvim_get_current_buf())
    if ok and value and value.manager and value.manager:num_results() == count then
      picker = value
      return true
    end
    return false
  end, 'picker did not open/render')
  equal(original_buffer, api.nvim_win_get_buf(origin))
  equal(source, context.cwd(origin))
end

local function open_list(opts)
  cancel_flow = extension.workspaces(opts or {})
  equal('discover', requests[1].operation)
  respond(1, 'success', discovery)
  opened(#inventory)
end

local function open_create(opts)
  cancel_flow = extension.create_workspace(opts or {})
  respond(1, 'success', discovery)
  opened(2)
end

local function select(index)
  picker:set_selection(picker:get_row(index))
end

local function key(mode, lhs)
  for _, mapping in ipairs(api.nvim_buf_get_keymap(picker.prompt_bufnr, mode)) do
    if mapping.lhs:lower() == lhs:lower() then
      if mapping.callback then
        mapping.callback()
      else
        local callback_id =
          assert(mapping.rhs:match('execute_keymap%((%d+)%)'), vim.inspect(mapping))
        require('telescope.mappings').execute_keymap(tonumber(callback_id))
      end
      return
    end
  end
  error('Missing ' .. mode .. ' mapping ' .. lhs)
end

local function enter()
  actions.select_default(picker.prompt_bufnr)
end

local function confirm()
  local prompt = confirmations[#confirmations]
  prompt.callback(prompt.items[2], 2)
end

local function assert_origin(entry)
  equal(origin, entry.win)
  equal(original_buffer, entry.buf)
  equal(source, entry.cwd)
  assert(entry.buf ~= picker.prompt_bufnr, 'operation captured Telescope prompt')
end

local function test(name, callback)
  tests[#tests + 1] = { name = name, callback = callback }
end

test('optional exports, searchable exact identities and unavailable entries', function()
  local exports = vim.tbl_keys(extension)
  table.sort(exports)
  equal({ 'create_workspace', 'workspaces' }, exports)
  inventory[2].name = 'unicodé\tname'
  inventory[2].path = feature .. '\npath'
  open_list({ path_display = { 'tail' } })
  select(2)
  local entry = picker:get_selection()
  assert(entry.ordinal:find('\\x09', 1, true))
  assert(entry.ordinal:find('\\x0a', 1, true))
  assert(entry.ordinal:find(inventory[2].commit_id, 1, true))
  equal(inventory[2], entry.value)
  select(3)
  enter()
  equal(1, #requests)
  assert(has_message('unavailable'))
  local display = picker:get_selection():display()
  assert(display:find('[unavailable]', 1, true))
end)

test('switch captures origin and closes picker after repository revalidation', function()
  open_list({
    cwd = source,
    scope = 'window',
    on_complete = function(result)
      completions[#completions + 1] = result
    end,
  })
  select(2)
  key('n', '<CR>')
  enter() -- duplicate while validation is pending
  equal(2, #requests)
  equal('discover', requests[2].operation)
  assert_origin(requests[2])
  respond(2, 'success', discovery)
  equal(3, #requests)
  equal('switch', requests[3].operation)
  equal('feature spaces', requests[3].name)
  equal({ cwd = source, scope = 'window' }, requests[3].opts)
  assert_origin(requests[3])
  assert(not api.nvim_buf_is_valid(picker.prompt_bufnr))
  respond(3, 'error', {}, 'switch failed')
  equal(1, #completions)
  assert(has_message('switch failed'))
  equal(origin, api.nvim_get_current_win())
end)

test('current selection reaches core no-op, current forget is blocked', function()
  open_list()
  select(1)
  key('i', '<C-d>')
  equal(0, #confirmations)
  key('i', '<CR>')
  respond(2, 'success', discovery)
  equal('default', requests[3].name)
  respond(3, 'noop', {})
  equal(source, context.cwd(origin))
end)

test('no selection and empty inventory are distinct', function()
  open_list()
  picker:reset_prompt('no-match-at-all')
  wait_for(function()
    return picker.manager:num_results() == 0
  end)
  enter()
  key('n', '<C-d>')
  equal(1, #requests)
  equal(0, #confirmations)
  assert(has_message('No workspace selected'))
  cancel_flow()
  reset()
  inventory = {}
  discovery.workspaces = inventory
  cancel_flow = extension.workspaces()
  respond(1, 'success', discovery)
  assert(has_message('no registered workspaces'))
  equal(origin, api.nvim_get_current_win())
end)

test('caller mappings run last, return false and options remain untouched', function()
  local invoked, custom = 0, 0
  local opts = {
    layout_config = { width = 0.8 },
    cwd = source,
    attach_mappings = function(_, map)
      invoked = invoked + 1
      map('n', '<C-d>', function()
        custom = custom + 1
      end)
      return false
    end,
  }
  local snapshot = vim.deepcopy(opts)
  open_list(opts)
  equal(1, invoked)
  key('n', '<C-d>')
  equal(1, custom)
  equal(0, #confirmations)
  equal(snapshot, opts)
  for _, mapping in ipairs(api.nvim_buf_get_keymap(picker.prompt_bufnr, 'n')) do
    assert(mapping.lhs ~= '<CR>', 'false must omit Telescope default mappings')
  end
end)

test('forget cancellation and confirmation are exact, single and captured', function()
  open_list()
  select(2)
  key('i', '<C-d>')
  key('n', '<C-d>')
  equal(1, #confirmations)
  equal('Cancel', confirmations[1].items[1])
  assert(confirmations[1].opts.prompt:find('Files will remain on disk', 1, true))
  confirmations[1].callback('yes')
  equal(1, #requests)
  key('n', '<C-d>')
  select(3)
  confirm()
  confirm() -- late duplicate from UI provider
  equal(2, #requests)
  respond(2, 'success', discovery)
  equal('forget', requests[3].operation)
  equal('feature spaces', requests[3].name)
  equal({ cwd = source }, requests[3].opts)
  assert_origin(requests[3])
  assert(api.nvim_buf_is_valid(picker.prompt_bufnr))
  respond(3, 'success', { files_deleted = false })
  equal('list', requests[4].operation)
  key('n', '<C-d>')
  equal(2, #confirmations)
  local fresh = { inventory[1], inventory[3] }
  respond(4, 'success', fresh)
  wait_for(function()
    return picker.manager:num_results() == 2
  end)
end)

test('unavailable forget warns, Cancel/nil do not submit', function()
  open_list()
  select(3)
  key('n', '<C-d>')
  assert(confirmations[1].opts.prompt:find('[unavailable]', 1, true))
  assert(confirmations[1].opts.prompt:find('could not be inspected', 1, true))
  confirmations[1].callback(nil)
  key('n', '<C-d>')
  confirmations[2].callback('Cancel', 1)
  equal(1, #requests)
end)

test('closed picker ignores pending confirmation and validation', function()
  open_list()
  select(2)
  key('n', '<C-d>')
  actions.close(picker.prompt_bufnr)
  confirm()
  equal(1, #requests)
  reset()
  open_list()
  select(2)
  enter()
  actions.close(picker.prompt_bufnr)
  respond(2, 'success', discovery)
  equal(2, #requests)
end)

test('submitted forget reports after closing and never refreshes or reopens', function()
  open_list({
    on_complete = function(result)
      completions[#completions + 1] = result
    end,
  })
  select(2)
  key('n', '<C-d>')
  confirm()
  respond(2, 'success', discovery)
  actions.close(picker.prompt_bufnr)
  respond(3, 'unknown', {}, 'interrupted')
  equal(3, #requests)
  equal(1, #completions)
  assert(has_message('Inspect jj state'))
  equal(origin, api.nvim_get_current_win())
end)

test('forget refresh preserves search, reports stale inventory and blocks actions', function()
  open_list()
  picker:reset_prompt('feature')
  wait_for(function()
    return picker.manager:num_results() == 1
  end)
  key('n', '<C-d>')
  confirm()
  respond(2, 'success', discovery)
  respond(3, 'success', { files_deleted = false })
  respond(4, 'error', {}, 'inventory query failed')
  equal('feature', state.get_current_line())
  assert(has_message('inventory is stale'))
  key('n', '<C-d>')
  equal(1, #confirmations)
  equal(4, #requests)
end)

test('changed origin buffer, cwd, window and repository prevent mutation', function()
  for _, change in ipairs({ 'buffer', 'cwd', 'window', 'repository' }) do
    reset()
    if change == 'window' then
      api.nvim_open_win(api.nvim_create_buf(true, false), false, { split = 'right' })
    end
    open_list()
    select(2)
    enter()
    if change == 'buffer' then
      api.nvim_win_set_buf(origin, api.nvim_create_buf(true, false))
    elseif change == 'cwd' then
      api.nvim_win_call(origin, function()
        vim.cmd.lcd(feature)
      end)
    elseif change == 'window' then
      api.nvim_win_close(origin, true)
    else
      discovery.repository = 'different-repository'
    end
    respond(2, 'success', discovery)
    equal(2, #requests)
    assert(has_message('context_changed'))
  end
end)

test('pending discovery replacement ignores old callbacks', function()
  local first_cancel = extension.workspaces()
  cancel_flow = extension.workspaces()
  respond(1, 'success', discovery)
  equal(origin, api.nvim_get_current_win())
  respond(2, 'success', discovery)
  opened(3)
  first_cancel()
  assert(api.nvim_buf_is_valid(picker.prompt_bufnr))
end)

test('loading does not steal focus and outside-repository errors stay visible', function()
  cancel_flow = extension.workspaces()
  vim.cmd('vsplit')
  local other = api.nvim_get_current_win()
  respond(1, 'success', discovery)
  equal(other, api.nvim_get_current_win())
  assert(has_message('lost focus'))
  reset()
  cancel_flow = extension.workspaces()
  respond(1, 'error', {}, 'not a jj repository')
  assert(has_message('not a jj repository'))
end)

test('creation @ is literal; empty destination is omitted and submitted once', function()
  open_create({
    on_complete = function(result)
      completions[#completions + 1] = result
    end,
  })
  select(1)
  enter()
  equal(1, #inputs)
  inputs[1].callback('new name')
  equal(2, #inputs)
  assert(inputs[2].opts.prompt:find('core-configured default', 1, true))
  inputs[2].callback('')
  inputs[2].callback('should-not-be-used')
  equal(2, #requests)
  respond(2, 'success', discovery)
  equal('create', requests[3].operation)
  equal({ cwd = source, name = 'new name', revision = '@', switch = true }, requests[3].opts)
  assert_origin(requests[3])
  respond(3, 'partial', { created = true, name = 'new name', path = feature }, 'switch failed')
  equal(1, #completions)
  assert(has_message('already exists'))
end)

test('non-current revision stays pinned, independent name and path', function()
  open_create()
  select(2)
  key('i', '<CR>')
  inputs[1].callback('independent')
  inputs[2].callback('../directory with spaces')
  respond(2, 'success', discovery)
  equal(id, requests[3].opts.revision)
  equal('../directory with spaces', requests[3].opts.path)
end)

test('typed Ctrl-R overrides selected candidate; empty text is rejected', function()
  open_create()
  key('i', '<C-r>')
  equal(0, #inputs)
  picker:reset_prompt('bookmark')
  wait_for(function()
    return picker.manager:num_results() == 1
  end)
  key('n', '<C-r>')
  inputs[1].callback('typed')
  inputs[2].callback('/explicit/path')
  respond(2, 'success', discovery)
  equal('bookmark', requests[3].opts.revision)
end)

test('Enter without candidate accepts nonempty revision expression', function()
  open_create()
  picker:reset_prompt('root()')
  wait_for(function()
    return picker.manager:num_results() == 0
  end)
  enter()
  inputs[1].callback('root-child')
  inputs[2].callback('')
  respond(2, 'success', discovery)
  equal('root()', requests[3].opts.revision)
end)

test('creation cancellation at all stages and duplicate callbacks are inert', function()
  for _, stage in ipairs({ 'picker', 'name', 'path' }) do
    reset()
    open_create()
    if stage == 'picker' then
      actions.close(picker.prompt_bufnr)
    else
      enter()
      if stage == 'path' then
        inputs[1].callback('cancelled')
      end
      local prompt = inputs[#inputs]
      prompt.callback(nil)
      prompt.callback('late response')
    end
    equal(1, #requests)
  end
end)

test('empty name retries asynchronously; replaced prompt callbacks are inert', function()
  open_create()
  enter()
  inputs[1].callback('')
  wait_for(function()
    return #inputs == 2
  end)
  inputs[1].callback('late')
  equal(2, #inputs)
  inputs[2].callback('valid')
  equal(3, #inputs)
  cancel_flow = extension.workspaces()
  inputs[3].callback('')
  equal(2, #requests)
  equal('discover', requests[2].operation)
end)

test('changed origin during creation prompts causes no mutation', function()
  open_create()
  enter()
  api.nvim_win_set_buf(origin, api.nvim_create_buf(true, false))
  inputs[1].callback('late')
  equal(1, #requests)
  assert(has_message('context_changed'))
end)

test('throwing user callbacks and UI providers cannot strand confirmations', function()
  open_list({
    on_complete = function()
      error('user completion failure')
    end,
  })
  select(2)
  local ui = vim.ui.select
  vim.ui.select = function()
    error('UI failure')
  end
  key('n', '<C-d>')
  assert(has_message('Confirmation failed'))
  vim.ui.select = ui
  key('n', '<C-d>')
  confirm()
  respond(2, 'success', discovery)
  respond(3, 'error', {}, 'blocked by core')
  assert(has_message('on_complete failed'))
  key('n', '<C-d>')
  equal(2, #confirmations)
end)

test('force/deletion options are rejected and prompt origins never reach core', function()
  extension.workspaces({ force = false })
  equal(0, #requests)
  open_list()
  extension.workspaces()
  equal(1, #requests)
  assert(has_message('not a prompt buffer'))
end)

local function run_command(cwd, argv)
  local result = vim.system(argv, { cwd = cwd, text = true }):wait(10000)
  equal(0, result.code)
  return result.stdout
end

test('real jj query returns bounded JSON candidates without snapshotting', function()
  local repo = fixture .. '/revision-repo'
  run_command(fixture, { 'jj', 'git', 'init', '--no-colocate', repo })
  local command =
    { 'jj', '--ignore-working-copy', 'log', '--no-graph', '-r', '@', '-T', 'commit_id' }
  local before = run_command(repo, command)
  vim.fn.writefile({ 'unsnapshotted' }, repo .. '/dirty.txt')
  local candidates, failure, done
  original_revision_load(repo, {}, function(value, err)
    candidates, failure, done = value, err, true
  end)
  wait_for(function()
    return done
  end, 'real jj query timed out')
  assert(not failure, failure)
  equal('@', candidates[1].revision)
  equal(before, candidates[2].revision)
  equal(before, run_command(repo, command))
  assert(#candidates <= 101)
end)

test(
  'revision dependency failures are asynchronous and cancellation suppresses callbacks',
  function()
    local done, failure = false, nil
    original_revision_load(source, { jj_command = fixture .. '/missing-jj' }, function(_, err)
      done, failure = true, err
    end)
    assert(not done, 'query completion must be asynchronous')
    wait_for(function()
      return done
    end)
    assert(failure:find('Cannot start', 1, true))
    done = false
    local stop = original_revision_load(
      source,
      { jj_command = fixture .. '/missing-jj' },
      function()
        done = true
      end
    )
    stop()
    vim.wait(30, function()
      return false
    end, 5)
    assert(not done)
  end
)

test('closed refresh and replaced creation-query callbacks never reopen a picker', function()
  open_list()
  select(2)
  key('n', '<C-d>')
  confirm()
  respond(2, 'success', discovery)
  respond(3, 'success', { files_deleted = false })
  actions.close(picker.prompt_bufnr)
  respond(4, 'success', inventory)
  equal(origin, api.nvim_get_current_win())
  reset()
  local old_callback, stopped
  revision_query.load = function(_, _, callback)
    old_callback = callback
    return function()
      stopped = true
    end
  end
  cancel_flow = extension.create_workspace()
  respond(1, 'success', discovery)
  cancel_flow = extension.workspaces()
  assert(stopped)
  old_callback({ { revision = '@', label = 'stale' } })
  equal(origin, api.nvim_get_current_win())
  respond(2, 'success', discovery)
  opened(3)
end)

test('partial forget refreshes but never retries; target path replacement is rejected', function()
  open_list()
  select(2)
  key('n', '<C-d>')
  confirm()
  respond(2, 'success', discovery)
  respond(3, 'partial', {}, 'uncertain registry')
  equal('list', requests[4].operation)
  respond(4, 'success', inventory)
  equal(4, #requests)
  select(2)
  key('n', '<C-d>')
  confirm()
  discovery.workspaces[2].path = source .. '/replacement'
  respond(5, 'success', discovery)
  equal(5, #requests)
  assert(has_message('registration changed'))
end)

test('throwing attach_mappings cancels and cleans up the real picker', function()
  cancel_flow = extension.workspaces({
    attach_mappings = function()
      error('mapping failure')
    end,
  })
  respond(1, 'success', discovery)
  assert(has_message('attach_mappings failed'))
  equal(origin, api.nvim_get_current_win())
  equal(1, #requests)
end)

test('query parser rejects capability/JSON/overflow failures and uses safe argv', function()
  local system = vim.system
  local cases = {
    { output = 'not-json\n', expected = 'Invalid JSON' },
    { output = '', expected = 'no commits' },
    { output = string.rep('x', 1024 * 1024 + 1), expected = 'output limit' },
    { output = '', code = 124, expected = 'exit 124' },
  }
  local ok, err = xpcall(function()
    for _, case in ipairs(cases) do
      local done, failure
      vim.system = function(argv, opts, callback)
        equal('/fake/jj with spaces', argv[1])
        equal('--ignore-working-copy', argv[4])
        equal(source, opts.cwd)
        assert(vim.tbl_contains(argv, 'latest(@ | bookmarks(), 100)'))
        opts.stdout(nil, case.output)
        callback({ code = case.code or 0 })
        return { kill = function() end }
      end
      original_revision_load(source, { jj_command = '/fake/jj with spaces' }, function(_, message)
        done, failure = true, message
      end)
      assert(not done)
      wait_for(function()
        return done
      end)
      assert(failure:find(case.expected, 1, true), failure)
    end
  end, debug.traceback)
  vim.system = system
  assert(ok, err)
end)

if vim.env.JJ_WORKSPACES_REAL_CORE == '1' then
  test('real core/jj create, switch and file-preserving forget', function()
    dofile(root .. '/tests/telescope/core.lua')({
      fixture = fixture,
      extension = extension,
      original_core = core,
      restore_revisions = function()
        revision_query.load = original_revision_load
      end,
      record_cancel = function(value)
        cancel_flow = value
      end,
    })
  end)
end

local failures = 0
for _, item in ipairs(tests) do
  local ok, err = xpcall(function()
    reset()
    item.callback()
  end, debug.traceback)
  if ok then
    print('PASS ' .. item.name)
  else
    failures = failures + 1
    io.stderr:write('FAIL ' .. item.name .. '\n' .. tostring(err) .. '\n')
  end
end
if cancel_flow then
  pcall(cancel_flow)
end
vim.notify, vim.ui.input, vim.ui.select = original_notify, original_input, original_select
revision_query.load = original_revision_load
api.nvim_set_current_dir(root)
vim.fn.delete(fixture, 'rf')
print(string.format('Telescope integration: %d passed, %d failed', #tests - failures, failures))
if failures > 0 then
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
