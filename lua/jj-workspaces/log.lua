local M = {}
local ranks = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, off = 6 }
local disabled = false

function M.bound(message, limit)
  message = tostring(message)
  limit = limit or 16384
  if #message > limit then
    local marker = ' [truncated]'
    return message:sub(1, limit - #marker) .. marker
  end
  return message
end

function M.write(op, severity, message)
  if disabled or ranks[severity] < ranks[op.config.log_level] then
    return
  end
  local ok = pcall(function()
    local filename = vim.fn.stdpath('cache') .. '/jj-workspaces.log'
    local record = vim.json.encode({
      timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
      severity = severity,
      operation_id = op.id,
      operation = op.kind,
      stage = op.stage,
      message = M.bound(message),
    }) .. '\n'
    vim.fn.mkdir(vim.fs.dirname(filename), 'p', 448)
    local stat = vim.uv.fs_stat(filename)
    if stat and stat.size + #record > 1048576 then
      vim.uv.fs_unlink(filename .. '.1')
      assert(vim.uv.fs_rename(filename, filename .. '.1'))
    end
    local fd = assert(vim.uv.fs_open(filename, 'a', 384))
    local written = vim.uv.fs_write(fd, record, -1)
    vim.uv.fs_close(fd)
    assert(written == #record)
  end)
  if not ok then
    disabled = true
    if op.config.notify then
      pcall(
        vim.notify,
        'jj-workspaces: file logging disabled after an I/O error',
        vim.log.levels.WARN
      )
    end
  end
end

return M
