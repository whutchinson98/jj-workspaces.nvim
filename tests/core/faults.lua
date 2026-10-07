-- Additional public-API fault tests. Fault injection intercepts only vim.system;
-- successful commands still run real jj against the suite's owned fixture.
return function(h)
  local ws, repo, base = h.ws, h.repo, h.base
  local real_system = vim.system

  local function fake(options, callback, stdout, code, stderr)
    vim.schedule(function()
      if stdout then
        options.stdout(nil, stdout)
      end
      if stderr then
        options.stderr(nil, stderr)
      end
      callback({ code = code or 0, signal = 0 })
    end)
    return { kill = function() end }
  end

  local function intercept(predicate, replacement)
    vim.system = function(argv, options, callback)
      if predicate(argv) then
        return replacement(argv, options, callback)
      end
      return real_system(argv, options, callback)
    end
  end

  local function contains(argv, value)
    return vim.tbl_contains(argv, value)
  end

  h.test('malformed and overflowing inventory are errors, never empty inventories', function()
    for _, output in ipairs({ '{bad JSON}\n', '{}\n', '', string.rep('x', 1048577) }) do
      intercept(function(argv)
        return contains(argv, 'list')
      end, function(_, options, callback)
        return fake(options, callback, output)
      end)
      local result = h.request('list')
      h.failure(result, 'invalid_output')
      vim.system = real_system
    end
  end)

  h.test('spawn failures and old versions finish asynchronously and release the lock', function()
    vim.system = function()
      error('injected spawn failure')
    end
    h.failure(h.request('switch', 'default'), 'dependency')
    vim.system = real_system
    intercept(function(argv)
      return contains(argv, '--version')
    end, function(_, options, callback)
      return fake(options, callback, 'jj 0.43.0\n')
    end)
    h.failure(h.request('list'), 'unsupported')
    vim.system = real_system
    h.success(h.request('list'))
  end)

  h.test('actual timed-out subprocess is killed and reaped before completion', function()
    local executable = base .. '/slow jj'
    -- env launches Neovim directly, not a shell. The child runs only this owned
    -- Lua fixture, and exercises the real vim.system timeout/kill/reap path.
    h.write(executable, '#!/usr/bin/env -S nvim --headless --clean -l\nvim.uv.sleep(10000)\n')
    assert(vim.uv.fs_chmod(executable, 448))
    h.configure({ jj_command = executable, operation_timeout_ms = 100 })
    local start = vim.uv.hrtime()
    h.failure(h.request('list'), 'timeout')
    assert((vim.uv.hrtime() - start) / 1e6 < 3000, 'termination was not bounded')
    h.configure()
    h.success(h.request('list'))
  end)

  h.test('failed parent selection reports a verified source snapshot without creating', function()
    h.write(repo .. '/snapshot-on-failure.txt', 'source disk change\n')
    local result =
      h.request('create', nil, { name = 'no-multi-parent', revision = 'all()', switch = false })
    h.eq(result.status, 'partial', vim.inspect(result))
    h.eq(result.error.code, 'invalid_argument')
    h.eq(result.data.created, false)
    h.eq(result.data.source_snapshot, true)
    assert(not vim.uv.fs_stat(base .. '/no-multi-parent'))
  end)

  h.test('failed add reconciles remnants without a Create event or cleanup', function()
    local events = {}
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
    end)
    intercept(function(argv)
      return contains(argv, 'add')
    end, function(argv, options, callback)
      -- This is a real jj failure mode: read-only add registers a workspace but
      -- cannot initialize it. Inject the bad flag only in the test fixture.
      table.insert(argv, 2, '--ignore-working-copy')
      return real_system(argv, options, callback)
    end)
    local result = h.request('create', nil, { name = 'incomplete-add', switch = false })
    vim.system = real_system
    off()
    assert(result.status == 'unknown' or result.status == 'partial', vim.inspect(result))
    h.eq(result.data.created, false)
    assert(result.data.observed_workspace)
    assert(result.data.destination_exists)
    h.eq(events, {})
    assert(vim.uv.fs_stat(base .. '/incomplete-add/.jj'))
    h.success(h.request('list'))
  end)

  h.test('interrupted add cannot claim success from another actor registration', function()
    local events = {}
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
    end)
    h.configure({ operation_timeout_ms = 2000 })
    intercept(function(argv)
      return contains(argv, 'add')
    end, function(_, _, callback)
      -- No mutation occurred, but the runner cannot know that from a killed job.
      return {
        kill = function()
          vim.schedule(function()
            callback({ code = 137, signal = 9 })
          end)
        end,
      }
    end)
    local result = h.request('create', nil, { name = 'interrupted', switch = false })
    vim.system = real_system
    off()
    h.eq(result.status, 'unknown', vim.inspect(result))
    h.eq(result.error.code, 'timeout')
    h.eq(result.data.created, false)
    h.eq(events, {})
    h.configure()
    h.success(h.request('list'))
  end)

  h.test(
    'callback exceptions release lock; listener changes affect later dispatches only',
    function()
      local calls, off_second = {}, nil
      local off_first = ws.on_change(function()
        calls[#calls + 1] = 'first'
        off_second()
      end)
      off_second = ws.on_change(function()
        calls[#calls + 1] = 'second'
      end)
      local completed
      ws.create({ name = 'listener-order', switch = false }, function(result)
        completed = result
        error('intentional completion exception')
      end)
      assert(vim.wait(30000, function()
        return completed ~= nil
      end, 5))
      h.eq(completed.status, 'success')
      h.eq(calls, { 'first', 'second' })
      assert(#completed.warnings > 0)
      h.success(h.request('forget', 'listener-order'))
      h.eq(calls, { 'first', 'second', 'first' })
      off_first()
      off_second()
    end
  )

  h.test('mutations are busy immediately while read-only calls remain independent', function()
    local created, busy, listed
    ws.create({ name = 'overlap', switch = false }, function(result)
      created = result
    end)
    ws.forget('overlap', nil, function(result)
      busy = result
    end)
    ws.list(nil, function(result)
      listed = result
    end)
    assert(vim.wait(30000, function()
      return created and busy and listed
    end, 5))
    h.success(created)
    h.failure(busy, 'busy')
    h.success(listed)
    h.success(h.request('forget', 'overlap'))
  end)

  h.test('failed forget reconciles absence without claiming a success event', function()
    h.success(h.request('create', nil, { name = 'uncertain-forget', switch = false }))
    local events = {}
    local off = ws.on_change(function(event)
      events[#events + 1] = event.kind
    end)
    intercept(function(argv)
      return contains(argv, 'forget')
    end, function(argv, options, callback)
      return real_system(argv, options, function(result)
        result.code = 1
        callback(result)
      end)
    end)
    local result = h.request('forget', 'uncertain-forget')
    vim.system = real_system
    off()
    h.eq(result.status, 'partial', vim.inspect(result))
    h.eq(result.data.forgotten, true)
    h.eq(result.data.files_deleted, false)
    h.eq(events, {})
    assert(vim.uv.fs_stat(base .. '/uncertain-forget/.jj'))
  end)

  h.test('in-flight config is immutable and setup resets unspecified settings', function()
    h.configure({ update_on_change = false })
    local result
    ws.create({ name = 'snapshot-config', switch = false }, function(value)
      result = value
    end)
    h.configure({ jj_command = base .. '/nonexistent' })
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    h.eq(result.status, 'success', vim.inspect(result))
    h.failure(h.request('list'), 'dependency')
    h.configure()
    h.success(h.request('forget', 'snapshot-config'))
    local configuration = require('jj-workspaces.config')
    ws.setup({ notify = false, log_level = 'off' })
    h.eq(configuration.snapshot().update_on_change, true)
    h.configure()
  end)

  h.test('log precedence, invalid fallback, rotation and JSON records', function()
    local configuration = require('jj-workspaces.config')
    vim.env.JJ_WORKSPACES_LOG = 'DEBUG'
    h.configure({ log_level = 'off' })
    h.eq(configuration.snapshot().log_level, 'debug')
    vim.env.JJ_WORKSPACES_LOG = 'bogus'
    h.configure({ log_level = 'off' })
    h.eq(configuration.snapshot().log_level, 'warn')
    vim.env.JJ_WORKSPACES_LOG = nil
    vim.g.jj_workspaces_log_level = 'fatal'
    ws.setup({ notify = false })
    h.eq(configuration.snapshot().log_level, 'error')
    vim.g.jj_workspaces_log_level = nil
    -- Redirect stdpath only for this test; never modify existing user logs.
    local stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(kind)
      if kind == 'cache' then
        return base .. '/cache'
      end
      return stdpath(kind)
    end
    local ok, err = pcall(function()
      h.write(base .. '/cache/jj-workspaces.log', string.rep('x', 1048576))
      h.configure({ log_level = 'info' })
      h.success(h.request('list'))
      assert(vim.uv.fs_stat(base .. '/cache/jj-workspaces.log.1'))
      local text = h.read(base .. '/cache/jj-workspaces.log')
      local record = vim.json.decode(text)
      h.eq(record.operation, 'list')
      h.eq(record.severity, 'info')
      assert(record.operation_id)
    end)
    vim.fn.stdpath = stdpath
    h.configure()
    assert(ok, err)
  end)

  vim.system = real_system
end
