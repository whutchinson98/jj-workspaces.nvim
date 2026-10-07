local path = require('jj-workspaces.path')
local runner = require('jj-workspaces.runner')
local M = {}
local inventory_template =
  [[ '{"name":' ++ json(name) ++ ',"path":' ++ json(root) ++ ',"commit_id":' ++ json(target.commit_id()) ++ "}\n" ]]

function M.inventory(op, root)
  local text =
    runner.checked(op, root, { 'workspace', 'list', '--template', inventory_template }, true)
  local records = runner.json_lines(text, op.stage)
  local names = {}
  for _, record in ipairs(records) do
    if
      type(record) ~= 'table'
      or not path.valid(record.name)
      or not path.valid(record.commit_id)
      or not record.commit_id:match('^[0-9a-f]+$')
      or names[record.name]
      or (record.path ~= vim.NIL and not path.absolute(record.path))
    then
      runner.raise('invalid_output', 'Invalid workspace inventory record', op.stage)
    end
    names[record.name] = true
    if record.path == vim.NIL then
      record.path = nil
    end
  end
  if #records == 0 then
    runner.raise('invalid_output', 'jj returned an empty workspace inventory', op.stage)
  end
  return records
end

function M.find(records, name)
  for _, record in ipairs(records) do
    if record.name == name then
      return record
    end
  end
end

function M.discover(op, cwd)
  op.stage = 'discovering'
  local boundary, reason = path.boundary(cwd)
  if not boundary then
    runner.raise('not_repository', reason, op.stage)
  end
  if not op.version_checked then
    if vim.fn.has('nvim-0.11') ~= 1 then
      runner.raise('dependency', 'Neovim 0.11 or newer is required', op.stage)
    end
    local version = runner.checked(op, boundary, { '--version' }, true)
    local major, minor = version:match('jj (%d+)%.(%d+)')
    if not major or (tonumber(major) == 0 and tonumber(minor) < 44) then
      runner.raise(
        'unsupported',
        'jj 0.44 or newer with JSON workspace templates is required',
        op.stage
      )
    end
    op.version_checked = true
  end
  local root = runner.checked(op, cwd, { 'workspace', 'root' }, true):gsub('\n$', '')
  if not path.absolute(root) then
    runner.raise('invalid_output', 'jj returned an invalid workspace root', op.stage)
  end
  local canonical = path.real(root)
  if not canonical or canonical ~= boundary then
    runner.raise(
      'not_repository',
      'jj root does not match the nearest workspace boundary',
      op.stage
    )
  end
  local repository = path.repository(root)
  if not repository then
    runner.raise('unsupported', 'Unsupported or broken .jj/repo metadata layout', op.stage)
  end
  local records = M.inventory(op, root)
  local name
  for _, record in ipairs(records) do
    if record.path and path.real(record.path) == canonical then
      if name then
        runner.raise('invalid_output', 'Ambiguous current workspace identity', op.stage)
      end
      name = record.name
      record.current = true
    end
  end
  return { repository = repository, root = root, name = name, workspaces = records }
end

function M.target(op, context, name)
  local target = M.find(context.workspaces, name)
  if not target then
    runner.raise('invalid_argument', 'Unknown workspace name: ' .. name, 'validating')
  end
  if not target.path or not path.real(target.path) then
    runner.raise('unavailable', 'Workspace path is unavailable: ' .. name, 'validating')
  end
  local verified = M.discover(op, target.path)
  if
    verified.repository ~= context.repository
    or verified.name ~= name
    or path.real(verified.root) ~= path.real(target.path)
  then
    runner.raise('unavailable', 'Target workspace identity has changed', 'validating')
  end
  return M.find(verified.workspaces, name)
end

-- Check disk identity again without yielding immediately before side effects.
function M.guard(context)
  local root = path.real(context.root)
  local boundary = path.boundary(context.root)
  if not root or boundary ~= root or path.repository(context.root) ~= context.repository then
    runner.raise(
      'context_changed',
      'Workspace metadata or directory identity changed',
      'validating'
    )
  end
end

function M.revalidate(op, context)
  local fresh = M.discover(op, context.root)
  if fresh.repository ~= context.repository or fresh.name ~= context.name then
    runner.raise('context_changed', 'Source workspace identity changed', 'validating')
  end
  return fresh
end

function M.destination(op, context)
  local opts = op.opts
  local destination = opts.path
  if not destination then
    if opts.name == '.' or opts.name == '..' or opts.name:find('[/\\]') then
      runner.raise(
        'invalid_argument',
        'A complex workspace name requires an explicit path',
        'validating'
      )
    end
    destination =
      path.join(op.config.workspace_directory or vim.fs.dirname(context.root), opts.name)
  else
    destination = path.join(context.root, destination)
  end
  if vim.uv.fs_lstat(destination) then
    runner.raise('invalid_argument', 'Creation destination already exists', 'validating')
  end
  local parent = path.real(vim.fs.dirname(destination))
  local stat = parent and vim.uv.fs_stat(parent)
  if not stat or stat.type ~= 'directory' then
    runner.raise(
      'invalid_argument',
      'Destination parent directory must already exist',
      'validating'
    )
  end
  local canonical = path.join(parent, vim.fs.basename(destination))
  if path.boundary(parent) then
    runner.raise(
      'invalid_argument',
      'Destination must not be nested inside a jj workspace',
      'validating'
    )
  end
  for _, record in ipairs(context.workspaces) do
    local root = record.path and path.real(record.path)
    if root and path.within(canonical, root) then
      runner.raise(
        'invalid_argument',
        'Destination must not be inside a registered workspace',
        'validating'
      )
    end
  end
  if
    path.within(canonical, context.repository)
    or canonical:find('/.jj/', 1, true)
    or canonical:sub(-4) == '/.jj'
    or canonical:find('/.git/', 1, true)
    or canonical:sub(-5) == '/.git'
  then
    runner.raise(
      'invalid_argument',
      'Destination must not be inside repository metadata',
      'validating'
    )
  end
  if M.find(context.workspaces, opts.name) then
    runner.raise('invalid_argument', 'Workspace name is already registered', 'validating')
  end
  for _, record in ipairs(context.workspaces) do
    if record.path and path.join(context.root, record.path) == destination then
      runner.raise('invalid_argument', 'Destination path is already registered', 'validating')
    end
  end
  return destination
end

function M.parent(op, root, revision, readonly)
  local text, err = runner.run(
    op,
    root,
    { 'log', '--no-graph', '--revisions=' .. revision, '--template', [[json(commit_id) ++ "\n"]] },
    readonly
  )
  if err then
    return nil, err
  end
  local ok, ids = pcall(runner.json_lines, text.stdout, op.stage)
  if not ok then
    return nil, ids
  end
  if #ids ~= 1 or not path.valid(ids[1]) or not ids[1]:match('^[0-9a-f]+$') then
    return nil,
      runner.error('invalid_argument', 'Revision must resolve to exactly one commit', op.stage)
  end
  return ids[1]
end

return M
