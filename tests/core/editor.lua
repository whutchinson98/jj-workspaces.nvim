return function(h)
  local ws, repo, base = h.ws, h.repo, h.base
  local target = base .. '/editor-target'
  h.configure()
  h.cd(repo)
  h.edit(repo .. '/file.txt')
  h.success(h.request('create', nil, { name = 'editor-target', switch = false }))

  h.test('tab scope targets captured window in another tab without stealing focus', function()
    local origin = vim.api.nvim_get_current_win()
    local result
    ws.switch('editor-target', { scope = 'tab' }, function(value)
      result = value
    end)
    vim.cmd('tabnew')
    local other = vim.api.nvim_get_current_win()
    h.cd(base, 'lcd')
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    h.success(result)
    h.eq(vim.api.nvim_get_current_win(), other)
    h.eq(vim.fn.getcwd(), base)
    local numbers = vim.fn.win_id2tabwin(origin)
    h.eq(vim.fn.getcwd(numbers[2], numbers[1]), target)
    vim.cmd('tabclose!')
    h.eq(vim.api.nvim_get_current_win(), origin)
    h.success(h.request('switch', 'default'))
  end)

  h.test('closed windows and changed buffers prevent delayed switches', function()
    vim.cmd('vsplit')
    local win = vim.api.nvim_get_current_win()
    local result
    ws.switch('editor-target', nil, function(value)
      result = value
    end)
    vim.api.nvim_win_close(win, true)
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    h.failure(result, 'context_changed')
    result = nil
    ws.switch('editor-target', nil, function(value)
      result = value
    end)
    vim.cmd('enew')
    assert(vim.wait(30000, function()
      return result ~= nil
    end, 5))
    h.failure(result, 'context_changed')
    h.eq(vim.fn.getcwd(), repo)
  end)

  h.test('DirChanged buffer races do not hide unsaved data and report partial', function()
    h.edit(repo .. '/file.txt')
    local buf = vim.api.nvim_get_current_buf()
    local autocmd = vim.api.nvim_create_autocmd('DirChanged', {
      once = true,
      callback = function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'late unsaved edit' })
      end,
    })
    local result = h.request('switch', 'editor-target')
    pcall(vim.api.nvim_del_autocmd, autocmd)
    h.eq(result.status, 'partial', vim.inspect(result))
    h.eq(vim.fn.getcwd(), target)
    h.eq(vim.api.nvim_get_current_buf(), buf)
    h.eq(vim.bo[buf].modified, true)
    h.eq(h.read(repo .. '/file.txt'), 'source contents\n')
    vim.bo[buf].modified = false
    h.success(h.request('switch', 'default'))
  end)

  h.test('a destination loaded and modified by DirChanged is not entered', function()
    h.edit(repo .. '/file.txt')
    local target_file = target .. '/file.txt'
    local previous = vim.fn.bufnr(target_file)
    if previous ~= -1 then
      vim.api.nvim_buf_delete(previous, { force = true })
    end
    local source = vim.api.nvim_get_current_buf()
    local destination
    vim.api.nvim_create_autocmd('DirChanged', {
      once = true,
      callback = function()
        destination = vim.fn.bufadd(target_file)
        vim.fn.bufload(destination)
        vim.api.nvim_buf_set_lines(destination, 0, -1, false, { 'late target edit' })
      end,
    })
    local result = h.request('switch', 'editor-target')
    h.eq(result.status, 'partial', vim.inspect(result))
    h.eq(vim.api.nvim_get_current_buf(), source)
    h.eq(vim.bo[destination].modified, true)
    vim.bo[destination].modified = false
    h.success(h.request('switch', 'default'))
  end)

  h.test('disabled jump cleanup leaves the invoking jumplist alone', function()
    h.configure({ update_on_change = false, clearjumps_on_change = false })
    h.seed_jumps()
    local jumps = vim.fn.getjumplist()[1]
    assert(#jumps > 0)
    h.success(h.request('switch', 'editor-target'))
    h.eq(vim.fn.getjumplist()[1], jumps)
    h.success(h.request('switch', 'default'))
    h.configure()
  end)

  h.test('symlink escape and similar-prefix file buffers are retained', function()
    local outside = repo .. '-other/file.txt'
    h.write(outside, 'outside\n')
    assert(vim.uv.fs_symlink(outside, repo .. '/escape.txt'))
    h.edit(repo .. '/escape.txt')
    local buf = vim.api.nvim_get_current_buf()
    h.success(h.request('switch', 'editor-target'))
    h.eq(vim.api.nvim_get_current_buf(), buf)
    h.success(h.request('switch', 'default'))
    h.edit(outside)
    buf = vim.api.nvim_get_current_buf()
    h.success(h.request('switch', 'editor-target'))
    h.eq(vim.api.nvim_get_current_buf(), buf)
    h.success(h.request('switch', 'default'))
  end)

  h.test(
    'special buffers stay put; default directory fallback is usable without plugins',
    function()
      vim.cmd('enew')
      vim.bo.buftype = 'nofile'
      local buf = vim.api.nvim_get_current_buf()
      h.success(h.request('switch', 'editor-target'))
      h.eq(vim.api.nvim_get_current_buf(), buf)
      h.success(h.request('switch', 'default'))
      vim.cmd('enew')
      h.configure({ missing_file = 'directory' })
      h.success(h.request('switch', 'editor-target'))
      h.eq(vim.api.nvim_buf_get_name(0):gsub('/$', ''), target)
      h.configure()
      h.success(h.request('switch', 'default'))
    end
  )

  h.test(
    'stale workspace discovery/switch never repairs; mutation disables user auto-repair',
    function()
      local state = {}
      for name, kind in vim.fs.dir(target .. '/.jj/working_copy') do
        if kind == 'file' then
          state[name] = h.read(target .. '/.jj/working_copy/' .. name)
        end
      end
      assert(next(state))
      h.jj(repo, { 'describe', '-r', '"editor-target"@', '-m', 'changed from another workspace' })
      local context = h.success(h.request('discover', nil, { cwd = target }))
      h.eq(context.name, 'editor-target')
      h.success(h.request('switch', 'editor-target'))
      for name, contents in pairs(state) do
        h.eq(h.read(target .. '/.jj/working_copy/' .. name), contents)
      end
      h.write(
        vim.env.JJ_CONFIG,
        '[user]\nname="Core Test"\nemail="core@example.invalid"\n[snapshot]\nauto-update-stale=true\n'
      )
      local result = h.request('create', nil, { name = 'must-not-repair', switch = false })
      h.eq(result.status, 'error', vim.inspect(result))
      h.eq(result.error.code, 'command_failed')
      for name, contents in pairs(state) do
        h.eq(h.read(target .. '/.jj/working_copy/' .. name), contents)
      end
      h.success(h.request('switch', 'default'))
    end
  )

  h.test('moved current workspace has unknown name and cannot create/forget', function()
    local moved = base .. '/moved-editor'
    assert(vim.uv.fs_rename(target, moved))
    local context = h.success(h.request('discover', nil, { cwd = moved }))
    h.eq(context.root, moved)
    h.eq(context.name, nil)
    h.failure(
      h.request('create', nil, { name = 'unknown-source', cwd = moved, switch = false }),
      'unavailable'
    )
    h.failure(h.request('forget', 'default', { cwd = moved }), 'unavailable')
  end)
end
