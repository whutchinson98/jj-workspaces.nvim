local M = {}
local uv = vim.uv

function M.valid(value)
  return type(value) == 'string' and value ~= '' and not value:find('\0', 1, true)
end

function M.absolute(value)
  return M.valid(value) and (value:sub(1, 1) == '/' or value:match('^%a:[/\\]') ~= nil)
end

function M.join(base, value)
  if M.absolute(value) then
    return value
  end
  return vim.fs.normalize(base .. '/' .. value, { expand_env = false })
end

function M.real(value)
  return value and uv.fs_realpath(value) or nil
end

function M.within(value, root)
  local prefix = root:gsub('/$', '') .. '/'
  return value == root or value:sub(1, #prefix) == prefix
end

function M.boundary(cwd)
  local current = M.real(cwd)
  if not current or not uv.fs_stat(current) or uv.fs_stat(current).type ~= 'directory' then
    return nil, 'Context directory is unavailable'
  end
  while current do
    if vim.fs.basename(current) == '.jj' or vim.fs.basename(current) == '.git' then
      return nil, 'Metadata directories are not workspace contexts'
    end
    if uv.fs_lstat(current .. '/.jj') then
      return current
    end
    if uv.fs_lstat(current .. '/.git') then
      return nil, 'A nested Git-only repository is a discovery boundary'
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end
  return nil, 'Not in a jj workspace'
end

function M.repository(root)
  local location = root .. '/.jj/repo'
  local stat = uv.fs_stat(location)
  if not stat then
    return nil
  end
  if stat.type == 'file' then
    if stat.size > 65536 then
      return nil
    end
    local fd = uv.fs_open(location, 'r', 0)
    if not fd then
      return nil
    end
    local contents = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not M.valid(contents) then
      return nil
    end
    -- jj pointer files contain the path itself, not a newline-delimited record.
    location = M.join(root .. '/.jj', contents)
  elseif stat.type ~= 'directory' then
    return nil
  end
  local canonical = M.real(location)
  local target = canonical and uv.fs_stat(canonical)
  return target and target.type == 'directory' and canonical or nil
end

function M.effective_cwd(win)
  local numbers = vim.fn.win_id2tabwin(win)
  if numbers[1] == 0 then
    return nil
  end
  return vim.fn.getcwd(numbers[2], numbers[1])
end

return M
