local M = {}

local template = '"[" ++ json(commit_id) ++ "," ++ json(description.first_line())'
  .. ' ++ "," ++ json(bookmarks.map(|b| b.name())) ++ "]\\n"'

-- This query is extension-owned: core configuration is deliberately not inspected.
-- A separate executable option supports users whose jj is not on PATH.
function M.load(root, opts, callback)
  local command = opts.jj_command or 'jj'
  local timeout = opts.revision_timeout_ms or 30000
  local cancelled = false
  local process
  local stdout, stderr = {}, {}
  local sizes = { stdout = 0, stderr = 0 }
  local failure

  local function stream(kind, limit, chunks)
    return function(err, data)
      if err then
        failure = 'Revision query stream failed: ' .. tostring(err)
      end
      if not data then
        return
      end
      sizes[kind] = sizes[kind] + #data
      if sizes[kind] <= limit then
        chunks[#chunks + 1] = data
      else
        failure = 'Revision query exceeded the ' .. kind .. ' output limit'
      end
    end
  end

  local function complete(result)
    vim.schedule(function()
      if cancelled then
        return
      end
      if failure then
        callback(nil, failure)
        return
      end
      if result.code ~= 0 then
        callback(
          nil,
          'Read-only jj revision query failed (exit '
            .. tostring(result.code)
            .. '). Check jj/template capabilities and jj_command: '
            .. table.concat(stderr)
        )
        return
      end
      local candidates = {
        { revision = '@', label = 'Current workspace (@; snapshot at creation)' },
      }
      local seen = {}
      local count = 0
      for line in table.concat(stdout):gmatch('[^\r\n]+') do
        local ok, record = pcall(vim.json.decode, line)
        if
          not ok
          or type(record) ~= 'table'
          or type(record[1]) ~= 'string'
          or not record[1]:match('^[0-9a-f]+$')
          or #record[1] < 32
          or type(record[2]) ~= 'string'
          or type(record[3]) ~= 'table'
        then
          callback(
            nil,
            'Invalid JSON revision output from jj; required template capabilities are unavailable'
          )
          return
        end
        for _, bookmark in ipairs(record[3]) do
          if type(bookmark) ~= 'string' then
            callback(nil, 'Invalid bookmark in jj revision output')
            return
          end
        end
        if not seen[record[1]] then
          seen[record[1]] = true
          count = count + 1
          if count > 100 then
            callback(nil, 'Revision query returned more than 100 distinct commits')
            return
          end
          candidates[#candidates + 1] = {
            revision = record[1],
            label = record[1]:sub(1, 12)
              .. '  '
              .. table.concat(record[3], ', ')
              .. '  '
              .. record[2],
          }
        end
      end
      if count == 0 then
        callback(nil, 'Read-only jj revision query returned no commits (expected at least @)')
        return
      end
      callback(candidates)
    end)
  end

  local ok, err = pcall(function()
    assert(
      type(command) == 'string' and command ~= '' and not command:find('%z'),
      'invalid jj_command'
    )
    assert(
      type(timeout) == 'number' and timeout > 0 and timeout < math.huge and timeout % 1 == 0,
      'revision_timeout_ms must be a positive integer'
    )
    process = vim.system({
      command,
      '--no-pager',
      '--color=never',
      '--ignore-working-copy',
      'log',
      '--no-graph',
      '--limit',
      '100',
      '--revisions',
      'latest(@ | bookmarks(), 100)',
      '--template',
      template,
    }, {
      cwd = root,
      timeout = timeout,
      stdout = stream('stdout', 1024 * 1024, stdout),
      stderr = stream('stderr', 64 * 1024, stderr),
    }, complete)
  end)
  if not ok then
    failure = 'Cannot start read-only jj revision query: ' .. tostring(err)
    complete({ code = -1 })
  end

  return function()
    cancelled = true
    if process then
      pcall(process.kill, process, 9)
    end
  end
end

return M
