local log = require('jj-workspaces.log')
local M = {}

function M.error(code, message, stage, extra)
  return vim.tbl_extend(
    'force',
    { code = code, message = log.bound(message), stage = stage },
    extra or {}
  )
end

function M.raise(code, message, stage)
  error(M.error(code, message, stage), 0)
end

-- The operation coroutine is resumed only on the main loop. Streams are always
-- drained, even after their retained diagnostic/output limits have been reached.
function M.run(op, cwd, args, readonly)
  local argv = {
    op.config.jj_command,
    '--no-pager',
    '--color=never',
    '--config',
    'snapshot.auto-update-stale=false',
  }
  if readonly then
    argv[#argv + 1] = '--ignore-working-copy'
  end
  vim.list_extend(argv, args)
  log.write(op, 'debug', 'Running jj: ' .. op.stage)
  local streams = {
    stdout = { chunks = {}, size = 0, limit = 1048576 },
    stderr = { chunks = {}, size = 0, limit = 65536 },
  }
  local function collect(which)
    return function(err, data)
      local stream = streams[which]
      if err then
        stream.failure = tostring(err)
      end
      if data then
        local available = math.max(0, stream.limit - stream.size)
        if available > 0 then
          stream.chunks[#stream.chunks + 1] = data:sub(1, available)
        end
        stream.size = stream.size + #data
      end
    end
  end
  local timed_out = false
  local timer = vim.uv.new_timer()
  local process
  local ok, spawn_error = pcall(function()
    process = vim.system(
      argv,
      { cwd = cwd, stdin = false, stdout = collect('stdout'), stderr = collect('stderr') },
      function(result)
        timer:stop()
        timer:close()
        vim.schedule(function()
          result.stdout = table.concat(streams.stdout.chunks)
          result.stderr = table.concat(streams.stderr.chunks)
          local err
          if timed_out then
            err =
              M.error('timeout', 'jj timed out; inspect workspace state before retrying', op.stage)
          elseif streams.stdout.size > streams.stdout.limit then
            err = M.error(
              'invalid_output',
              'jj stdout exceeded 1 MiB; output was not accepted',
              op.stage
            )
          elseif streams.stdout.failure or streams.stderr.failure then
            err = M.error('command_failed', 'Failed reading jj output', op.stage)
          elseif result.code ~= 0 then
            err = M.error('command_failed', 'jj command failed', op.stage)
          end
          if err then
            err.exit_code = result.code
            err.stderr = log.bound(result.stderr)
          end
          op.resume(result, err)
        end)
      end
    )
  end)
  if not ok then
    timer:close()
    return nil, M.error('dependency', 'Unable to start jj: ' .. tostring(spawn_error), op.stage)
  end
  timer:start(op.config.operation_timeout_ms, 0, function()
    timed_out = true
    -- SIGKILL avoids an unbounded grace period; vim.system reaps before on_exit.
    pcall(process.kill, process, 9)
  end)
  return coroutine.yield()
end

function M.checked(op, cwd, args, readonly)
  local result, err = M.run(op, cwd, args, readonly)
  if err then
    error(err, 0)
  end
  return result.stdout
end

function M.json_lines(text, stage)
  local records = {}
  for line in text:gmatch('[^\n]+') do
    local ok, record = pcall(vim.json.decode, line)
    if not ok then
      M.raise('invalid_output', 'Invalid jj JSON output', stage)
    end
    records[#records + 1] = record
  end
  return records
end

return M
