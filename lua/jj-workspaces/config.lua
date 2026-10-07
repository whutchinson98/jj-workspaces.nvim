local path = require('jj-workspaces.path')
local M = {}
local current
local levels = { trace = true, debug = true, info = true, warn = true, error = true, off = true }
local defaults = {
  jj_command = 'jj',
  cwd_scope = 'global',
  update_on_change = true,
  missing_file = 'directory',
  clearjumps_on_change = true,
  operation_timeout_ms = 30000,
  notify = true,
}
local allowed = vim.tbl_extend('force', defaults, { workspace_directory = true, log_level = true })

local function scope(value)
  return value == 'global' or value == 'tab' or value == 'window'
end
M.scope = scope

function M.build(input)
  if input == nil then
    input = {}
  end
  assert(type(input) == 'table', 'jj-workspaces: setup expects a table')
  for key in pairs(input) do
    assert(allowed[key] ~= nil, 'jj-workspaces: unknown configuration key: ' .. tostring(key))
  end
  local config = vim.tbl_extend('force', vim.deepcopy(defaults), vim.deepcopy(input))
  assert(
    path.valid(config.jj_command)
      and (path.absolute(config.jj_command) or not config.jj_command:find('[/\\%s]')),
    'jj-workspaces: jj_command must be an executable name or absolute path'
  )
  assert(scope(config.cwd_scope), 'jj-workspaces: invalid cwd_scope')
  for _, key in ipairs({ 'update_on_change', 'clearjumps_on_change', 'notify' }) do
    assert(type(config[key]) == 'boolean', 'jj-workspaces: ' .. key .. ' must be boolean')
  end
  assert(
    config.missing_file == 'directory'
      or config.missing_file == 'keep'
      or type(config.missing_file) == 'function',
    'jj-workspaces: invalid missing_file'
  )
  local timeout = config.operation_timeout_ms
  assert(
    type(timeout) == 'number' and timeout > 0 and timeout < math.huge and timeout % 1 == 0,
    'jj-workspaces: operation_timeout_ms must be a positive finite integer'
  )
  if config.workspace_directory ~= nil then
    assert(
      path.absolute(config.workspace_directory),
      'jj-workspaces: workspace_directory must be absolute'
    )
    local stat = vim.uv.fs_stat(config.workspace_directory)
    assert(
      stat and stat.type == 'directory',
      'jj-workspaces: workspace_directory must be an existing directory'
    )
  end
  assert(
    config.log_level == nil or type(config.log_level) == 'string',
    'jj-workspaces: log_level must be a string'
  )
  local env = vim.env.JJ_WORKSPACES_LOG
  local level = (env and env ~= '' and env)
    or config.log_level
    or vim.g.jj_workspaces_log_level
    or 'warn'
  level = type(level) == 'string' and level:lower() or ''
  if level == 'fatal' then
    level = 'error'
  end
  if not levels[level] then
    config.log_warning = 'Invalid log level; using warn'
    level = 'warn'
  end
  config.log_level = level
  return config
end

function M.setup(input)
  local next_config = M.build(input)
  current = next_config
end

function M.snapshot()
  if not current then
    current = M.build({})
  end
  local copy = vim.deepcopy(current)
  current.log_warning = nil
  return copy
end

return M
