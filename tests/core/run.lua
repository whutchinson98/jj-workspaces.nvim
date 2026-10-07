-- Run from the repository: nvim --headless --clean -l tests/core/run.lua
local project = vim.fn.getcwd()
vim.opt.runtimepath:prepend(project)
local uv = vim.uv
local base = vim.fn.tempname() .. '-jj-workspaces-core'
assert(uv.fs_mkdir(base, 448), 'fixture directory must be newly owned')
local original_system = vim.system
local original_cwd = vim.fn.getcwd()
local passed = 0
local ws
local repo = base .. '/source space'
local target = base .. '/target "quoted" | literal'

local function eq(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    (message or 'values differ')
      .. '\nexpected: '
      .. vim.inspect(expected)
      .. '\nactual: '
      .. vim.inspect(actual)
  )
end

local function write(filename, content)
  vim.fn.mkdir(vim.fs.dirname(filename), 'p')
  local fd = assert(uv.fs_open(filename, 'w', 384))
  assert(uv.fs_write(fd, content, 0))
  uv.fs_close(fd)
end

local function read(filename)
  local fd = assert(uv.fs_open(filename, 'r', 0))
  local data = assert(uv.fs_read(fd, assert(uv.fs_fstat(fd)).size, 0))
  uv.fs_close(fd)
  return data
end

local function tree(directory)
  local contents = {}
  local function visit(current, relative)
    for name, kind in vim.fs.dir(current) do
      local filename = current .. '/' .. name
      local key = relative .. name
      if kind == 'directory' then
        contents[key] = 'directory'
        visit(filename, key .. '/')
      elseif kind == 'link' then
        contents[key] = { link = assert(uv.fs_readlink(filename)) }
      else
        contents[key] = { data = read(filename) }
      end
    end
  end
  visit(directory, '')
  return contents
end

local function jj(cwd, args)
  local argv =
    { 'jj', '--no-pager', '--color=never', '--config', 'snapshot.auto-update-stale=false' }
  vim.list_extend(argv, args)
  local result = original_system(argv, { cwd = cwd, text = true }):wait(20000)
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function cd(directory, scope)
  vim.api.nvim_cmd(
    { cmd = scope or 'cd', args = { directory }, magic = { file = false, bar = false } },
    {}
  )
end

local function edit(filename)
  vim.api.nvim_cmd({ cmd = 'edit', args = { filename }, magic = { file = false, bar = false } }, {})
end

local function seed_jumps()
  local original = vim.api.nvim_get_current_buf()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(scratch)
  vim.api.nvim_buf_set_lines(
    scratch,
    0,
    -1,
    false,
    { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' }
  )
  vim.cmd('normal! gg')
  vim.cmd('normal! 5G')
  vim.cmd('normal! 10G')
  vim.api.nvim_set_current_buf(original)
  assert(#vim.fn.getjumplist()[1] > 0, 'expected populated jumplist')
end

local function request(kind, name, opts)
  local result, count, returned = nil, 0, false
  local function callback(value)
    assert(returned, 'callback ran inline')
    assert(not vim.in_fast_event(), 'callback ran in fast event')
    count = count + 1
    result = value
  end
  local id
  if kind == 'switch' or kind == 'forget' then
    id = ws[kind](name, opts, callback)
  else
    id = ws[kind](opts, callback)
  end
  returned = true
  assert(type(id) == 'string')
  assert(
    vim.wait(30000, function()
      return result ~= nil
    end, 5),
    'operation did not complete: ' .. kind
  )
  vim.wait(10, function()
    return false
  end, 5)
  eq(count, 1, 'exactly once')
  eq(result.id, id)
  eq(result.operation, kind)
  assert(type(result.warnings) == 'table')
  return result
end

local function success(result)
  eq(result.status, 'success', vim.inspect(result))
  return result.data
end

local function failure(result, code)
  eq(result.status, 'error', vim.inspect(result))
  eq(result.error.code, code, vim.inspect(result))
  return result
end

local function test(name, fn)
  fn()
  passed = passed + 1
  print('ok ' .. passed .. ' - ' .. name)
end

local function configure(extra)
  ws.setup(
    vim.tbl_extend(
      'force',
      { notify = false, log_level = 'off', missing_file = 'keep' },
      extra or {}
    )
  )
end

local function main()
  vim.env.JJ_CONFIG = base .. '/config.toml'
  vim.env.JJ_WORKSPACES_LOG = nil
  write(vim.env.JJ_CONFIG, '[user]\nname="Core Test"\nemail="core@example.invalid"\n')
  test('require is side-effect free', function()
    cd(base)
    vim.system = function()
      error('spawn during require')
    end
    ws = require('jj-workspaces')
    vim.system = original_system
    eq(vim.fn.getcwd(), base)
    assert(package.loaded.telescope == nil and package.loaded.plenary == nil)
    configure()
  end)
  jj(base, { 'git', 'init', '--no-colocate', repo })
  write(repo .. '/file.txt', 'source contents\n')
  vim.fn.mkdir(repo .. '/src/deep', 'p')
  cd(repo .. '/src/deep')

  test('discover and list are real read-only API calls', function()
    local before =
      jj(repo, { 'log', '--ignore-working-copy', '--no-graph', '-r', '@', '-T', 'commit_id' })
    local context = success(request('discover'))
    eq(context.root, repo)
    eq(context.name, 'default')
    eq(context.repository, assert(uv.fs_realpath(repo .. '/.jj/repo')))
    eq(#context.workspaces, 1)
    eq(context.workspaces[1].current, true)
    eq(success(request('list'))[1].name, 'default')
    eq(
      jj(repo, { 'log', '--ignore-working-copy', '--no-graph', '-r', '@', '-T', 'commit_id' }),
      before
    )
  end)

  test('configuration is validated atomically and requests validate asynchronously', function()
    for _, options in ipairs({
      false,
      'invalid',
      { autopush = true },
      { cwd_scope = 'bad' },
      { notify = 'no' },
      { operation_timeout_ms = 0 },
      { operation_timeout_ms = 0 / 0 },
      { log_level = 2 },
      { workspace_directory = 'relative' },
      { workspace_directory = base .. '/missing-base' },
      { jj_command = 'jj --flag' },
      { missing_file = false },
    }) do
      assert(not pcall(ws.setup, options), vim.inspect(options))
    end
    success(request('list'))
    failure(request('list', nil, { cwd = 'relative' }), 'invalid_argument')
    failure(request('list', nil, false), 'invalid_argument')
    local unsupported = uv.new_timer()
    failure(request('list', nil, { cwd = unsupported }), 'invalid_argument')
    unsupported:close()
    failure(request('forget', 'x', { force = true }), 'invalid_argument')
    failure(request('switch', 'x', { scope = 'invalid' }), 'invalid_argument')
    failure(request('create', nil, { name = 'x', revision = '' }), 'invalid_argument')
    configure({ jj_command = base .. '/missing executable' })
    failure(request('list'), 'dependency')
    configure()
  end)

  test('nested Git boundaries, metadata, broken jj, and independent repositories', function()
    vim.fn.mkdir(repo .. '/nested-git/.git', 'p')
    failure(request('discover', nil, { cwd = repo .. '/nested-git' }), 'not_repository')
    write(repo .. '/pointer-git/.git', 'gitdir: nowhere\n')
    failure(request('discover', nil, { cwd = repo .. '/pointer-git' }), 'not_repository')
    failure(request('discover', nil, { cwd = repo .. '/.jj' }), 'not_repository')
    failure(request('discover', nil, { cwd = base }), 'not_repository')
    vim.fn.mkdir(repo .. '/broken/.jj', 'p')
    eq(request('discover', nil, { cwd = repo .. '/broken' }).status, 'error')
    local nested = repo .. '/nested-jj'
    jj(repo, { 'git', 'init', '--colocate', nested })
    local found = success(request('discover', nil, { cwd = nested }))
    eq(found.root, nested)
    assert(found.repository ~= uv.fs_realpath(repo .. '/.jj/repo'))
    eq(found.name, 'default')
    eq(vim.fn.getcwd(), repo .. '/src/deep')
  end)

  test(
    'create pins a single parent, uses independent path/name, and emits before callback',
    function()
      -- Remove fixture-only broken markers from the source snapshot by ignoring them.
      write(repo .. '/.gitignore', 'nested-git/\npointer-git/\nbroken/\nnested-jj/\n')
      local order = {}
      local off = ws.on_change(function(event)
        order[#order + 1] = event.kind
        eq(event.workspace.name, 'feature name')
        assert(event.parent_revision)
      end)
      local created =
        success(request('create', nil, { name = 'feature name', path = target, switch = false }))
      off()
      eq(order, { 'create' })
      eq(created.created, true)
      eq(created.switched, false)
      eq(created.workspace.path, target)
      eq(
        jj(target, { 'log', '--ignore-working-copy', '--no-graph', '-r', '@-', '-T', 'commit_id' }),
        created.parent_revision
      )
      assert(created.workspace.commit_id ~= created.parent_revision)
      eq(read(target .. '/file.txt'), 'source contents\n')
      eq(vim.fn.getcwd(), repo .. '/src/deep')
      eq(jj(repo, { 'bookmark', 'list', '--ignore-working-copy' }), '')
      eq(jj(repo, { 'git', 'remote', 'list' }), '')
      local linked = success(request('discover', nil, { cwd = target }))
      eq(linked.repository, uv.fs_realpath(repo .. '/.jj/repo'))
      eq(linked.name, 'feature name')
    end
  )

  test('creation rejects occupied, nested, duplicate, invalid and multiple parents', function()
    failure(request('create', nil, { name = 'feature name', switch = false }), 'invalid_argument')
    failure(
      request('create', nil, { name = 'nested', path = 'new', switch = false }),
      'invalid_argument'
    )
    failure(
      request('create', nil, { name = 'occupied', path = target, switch = false }),
      'invalid_argument'
    )
    failure(request('create', nil, { name = '../unsafe', switch = false }), 'invalid_argument')
    failure(
      request(
        'create',
        nil,
        { name = 'missing-parent', path = base .. '/absent/child', switch = false }
      ),
      'invalid_argument'
    )
    failure(
      request('create', nil, { name = 'multi', revision = 'all()', switch = false }),
      'invalid_argument'
    )
    failure(
      request('create', nil, { name = 'invalid', revision = 'no-such-bookmark', switch = false }),
      'command_failed'
    )
    eq(#success(request('list')), 2)
    assert(not uv.fs_stat(base .. '/multi'))
  end)

  test('same workspace is a no-op preserving subdirectory and buffer', function()
    edit(repo .. '/file.txt')
    local buf = vim.api.nvim_get_current_buf()
    eq(request('switch', 'default').status, 'noop')
    eq(vim.fn.getcwd(), repo .. '/src/deep')
    eq(vim.api.nvim_get_current_buf(), buf)
  end)

  test('modified source and destination buffers block before cwd changes', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved source' })
    failure(request('switch', 'feature name'), 'modified_buffer')
    failure(request('create', nil, { name = 'dirty-source', switch = false }), 'modified_buffer')
    eq(vim.fn.getcwd(), repo .. '/src/deep')
    eq(read(repo .. '/file.txt'), 'source contents\n')
    vim.bo.modified = false
    local destination = vim.fn.bufadd(target .. '/file.txt')
    vim.fn.bufload(destination)
    vim.api.nvim_buf_set_lines(destination, 0, -1, false, { 'unsaved destination' })
    failure(request('switch', 'feature name'), 'modified_buffer')
    vim.bo[destination].modified = false
  end)

  test(
    'switch continuity, scoped jumps, literal Ex paths, protected hooks and busy lock',
    function()
      local origin = vim.api.nvim_get_current_win()
      vim.cmd('vsplit')
      local other = vim.api.nvim_get_current_win()
      seed_jumps()
      local other_jumps = vim.fn.getjumplist()[1]
      vim.api.nvim_set_current_win(origin)
      seed_jumps()
      local events, nested, completed = {}, nil, false
      local off1 = ws.on_change(function(event)
        events[#events + 1] = event.kind
        event.workspace.name = 'tampered'
        ws.switch('default', nil, function(result)
          nested = result
        end)
        error('intentional listener failure')
      end)
      local off2 = ws.on_change(function(event)
        eq(event.workspace.name, 'feature name')
        eq(vim.fn.getjumplist()[1], {})
        events[#events + 1] = 'second'
      end)
      ws.switch('feature name', { scope = 'window' }, function(result)
        eq(result.status, 'success')
        eq(#result.warnings, 1)
        events[#events + 1] = 'callback'
        completed = true
      end)
      assert(vim.wait(30000, function()
        return completed and nested ~= nil
      end, 5))
      eq(nested.error.code, 'busy')
      eq(events, { 'switch', 'second', 'callback' })
      eq(vim.fn.getcwd(), target)
      eq(vim.api.nvim_buf_get_name(0), target .. '/file.txt')
      vim.api.nvim_win_call(other, function()
        eq(vim.fn.getjumplist()[1], other_jumps)
      end)
      off1()
      off1()
      off2()
      vim.api.nvim_win_close(other, true)
      success(request('switch', 'default', { scope = 'global' }))
      eq(vim.fn.getcwd(), repo)
    end
  )

  test('context changes reject late actions and read-only requests overlap', function()
    local results = {}
    local a = ws.list(nil, function(result)
      results[1] = result
    end)
    local b = ws.discover(nil, function(result)
      results[2] = result
    end)
    assert(a ~= b)
    assert(vim.wait(30000, function()
      return results[1] and results[2]
    end, 5))
    eq(results[1].status, 'success')
    eq(results[2].status, 'success')
    local result
    ws.switch('feature name', nil, function(value)
      result = value
    end)
    cd(repo .. '/src/deep')
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    failure(result, 'context_changed')
    eq(vim.fn.getcwd(), repo .. '/src/deep')
    cd(repo)
  end)

  test(
    'disabled continuity retains unsaved source; keep fallback and external buffers are safe',
    function()
      configure({ update_on_change = false })
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].modified = true
      success(request('switch', 'feature name'))
      eq(vim.api.nvim_get_current_buf(), buf)
      eq(vim.bo[buf].modified, true)
      success(request('switch', 'default'))
      vim.bo[buf].modified = false
      configure()
      write(base .. '/outside.txt', 'outside\n')
      edit(base .. '/outside.txt')
      buf = vim.api.nvim_get_current_buf()
      vim.bo.modified = true
      success(request('switch', 'feature name'))
      eq(vim.api.nvim_get_current_buf(), buf)
      success(request('switch', 'default'))
      vim.bo.modified = false
      edit(repo .. '/missing.txt')
      buf = vim.api.nvim_get_current_buf()
      vim.bo.modified = true
      success(request('switch', 'feature name'))
      eq(vim.api.nvim_get_current_buf(), buf)
      success(request('switch', 'default'))
      vim.bo.modified = false
    end
  )

  test('root-relative creation and create/switch/callback ordering', function()
    configure()
    cd(repo .. '/src/deep')
    local events, result = {}, nil
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
    end)
    local id = ws.create({ name = 'relative', path = '../relative-destination' }, function(value)
      events[#events + 1] = 'callback'
      result = value
    end)
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    eq(result.id, id)
    eq(success(result).workspace.path, base .. '/relative-destination')
    eq(events, { 'create', 'switch', 'callback' })
    off()
    success(request('switch', 'default'))
  end)

  test('successful creation with failed switch reports partial and only Create', function()
    local events = {}
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
      if event.kind == 'create' then
        cd(repo .. '/src/deep')
      end
    end)
    local result = request('create', nil, { name = 'partial' })
    eq(result.status, 'partial', vim.inspect(result))
    eq(result.data.created, true)
    eq(result.data.switched, false)
    eq(result.error.code, 'context_changed')
    eq(events, { 'create' })
    assert(uv.fs_stat(base .. '/partial/.jj'))
    off()
    cd(repo)
  end)

  test('buffer fallback failure is partial, still clears jumps and emits Switch', function()
    configure({
      missing_file = function()
        error('fallback failure')
      end,
    })
    local seen = false
    local off = ws.on_change(function(event)
      if event.kind == 'switch' then
        seen = true
        eq(vim.fn.getjumplist()[1], {})
      end
    end)
    local result = request('switch', 'feature name')
    eq(result.status, 'partial')
    eq(result.error.code, 'editor_failed')
    eq(vim.fn.getcwd(), target)
    assert(seen)
    off()
    configure()
    success(request('switch', 'default'))
  end)

  test(
    'forget refuses current, another-window-active, modified targets and unsupported force',
    function()
      failure(request('forget', 'default'), 'invalid_argument')
      failure(request('forget', 'unknown'), 'invalid_argument')
      local origin = vim.api.nvim_get_current_win()
      vim.cmd('vsplit')
      local other = vim.api.nvim_get_current_win()
      cd(target, 'lcd')
      vim.api.nvim_set_current_win(origin)
      failure(request('forget', 'feature name'), 'invalid_argument')
      vim.api.nvim_win_close(other, true)
      local buf = vim.fn.bufadd(target .. '/dirty.txt')
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved target' })
      failure(request('forget', 'feature name'), 'modified_buffer')
      vim.bo[buf].modified = false
    end
  )

  test('forget changes metadata only, preserves files and does not snapshot source', function()
    write(target .. '/untracked.txt', 'must survive\n')
    write(repo .. '/not-snapshotted.txt', 'disk only\n')
    local before =
      jj(repo, { 'log', '--ignore-working-copy', '--no-graph', '-r', '@', '-T', 'commit_id' })
    local metadata = read(target .. '/.jj/repo')
    local files_before = tree(target)
    local events = {}
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
    end)
    local data = success(request('forget', 'feature name'))
    off()
    eq(data.files_deleted, false)
    eq(data.workspace.name, 'feature name')
    assert(data.workspace.commit_id)
    eq(events, { 'forget' })
    eq(read(target .. '/untracked.txt'), 'must survive\n')
    eq(read(target .. '/.jj/repo'), metadata)
    eq(tree(target), files_before, 'forget must preserve every target file and directory')
    eq(
      jj(repo, { 'log', '--ignore-working-copy', '--no-graph', '-r', '@', '-T', 'commit_id' }),
      before
    )
    assert(uv.fs_stat(target .. '/file.txt'))
  end)

  test('moved paths remain visible and can be forgotten without guessing a directory', function()
    assert(uv.fs_rename(base .. '/relative-destination', base .. '/moved-relative'))
    local records = success(request('list'))
    local found
    for _, record in ipairs(records) do
      if record.name == 'relative' then
        found = record
      end
    end
    assert(found and found.path == nil)
    failure(request('switch', 'relative'), 'unavailable')
    local result = request('forget', 'relative')
    eq(success(result).workspace.path, nil)
    assert(#result.warnings > 0)
    assert(uv.fs_stat(base .. '/moved-relative/.jj'))
  end)

  test('configured creation base and literal environment/tilde path components', function()
    vim.fn.mkdir(base .. '/configured', 'p')
    configure({ workspace_directory = base .. '/configured' })
    local data = success(request('create', nil, { name = 'configured', switch = false }))
    eq(data.workspace.path, base .. '/configured/configured')
    local literal = base .. '/$HOME ~ literal'
    data = success(request('create', nil, { name = 'literal', path = literal, switch = false }))
    eq(data.workspace.path, literal)
    configure()
  end)

  test('replaced workspace directories are rejected, symlink contexts share identity', function()
    assert(uv.fs_symlink(repo, base .. '/source-link', { dir = true }))
    local context = success(request('discover', nil, { cwd = base .. '/source-link' }))
    eq(context.name, 'default')
    assert(uv.fs_rename(base .. '/partial', base .. '/saved-partial'))
    jj(base, { 'git', 'init', '--no-colocate', base .. '/partial' })
    failure(request('switch', 'partial'), 'unavailable')
    failure(request('forget', 'partial'), 'unavailable')
    failure(
      request('create', nil, { name = 'symlink-nested', path = base .. '/source-link/nested-new' }),
      'invalid_argument'
    )
  end)

  test('names and paths containing newlines are not split or trimmed', function()
    local literal_path = base .. '/newline\npath\n'
    local data = success(
      request('create', nil, { name = 'newline\nname', path = literal_path, switch = false })
    )
    eq(data.workspace.path, literal_path)
    local context = success(request('discover', nil, { cwd = literal_path }))
    eq(context.root, literal_path)
    eq(context.name, 'newline\nname')
    success(request('switch', 'newline\nname'))
    eq(vim.fn.getcwd(), literal_path)
    success(request('switch', 'default'))
    success(request('forget', 'newline\nname'))
    success(
      request('create', nil, { name = '--help', path = base .. '/dash-name', switch = false })
    )
    success(request('switch', '--help'))
    success(request('switch', 'default'))
    success(request('forget', '--help'))
  end)

  test(
    'default is not privileged when inactive, and override selects only repository context',
    function()
      local independent = base .. '/independent'
      jj(base, { 'git', 'init', '--no-colocate', independent })
      local cwd = vim.fn.getcwd()
      local data = success(
        request('create', nil, { cwd = independent, name = 'independent-child', switch = false })
      )
      eq(vim.fn.getcwd(), cwd)
      success(request('switch', 'independent-child', { cwd = independent }))
      eq(vim.fn.getcwd(), data.workspace.path)
      local forgotten = success(request('forget', 'default'))
      eq(forgotten.workspace.path, independent)
      eq(forgotten.files_deleted, false)
      assert(uv.fs_stat(independent .. '/.jj/repo'))
      cd(repo)
    end
  )

  local helpers = {
    ws = ws,
    repo = repo,
    base = base,
    eq = eq,
    write = write,
    read = read,
    jj = jj,
    cd = cd,
    edit = edit,
    seed_jumps = seed_jumps,
    request = request,
    success = success,
    failure = failure,
    test = test,
    configure = configure,
  }
  dofile(project .. '/tests/core/editor.lua')(helpers)
  dofile(project .. '/tests/core/faults.lua')(helpers)
end

local ok, err = xpcall(main, debug.traceback)
vim.system = original_system
-- Only this suite's unique directory is removed; never delete any project path.
pcall(vim.cmd, 'silent! tabonly!')
pcall(vim.cmd, 'silent! only!')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
pcall(cd, original_cwd)
assert(base:find('-jj-workspaces-core', 1, true))
vim.fn.delete(base, 'rf')
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
else
  print('PASS: ' .. passed .. ' core integration tests')
  vim.cmd('qa!')
end
