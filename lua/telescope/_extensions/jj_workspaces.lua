local ok, telescope = pcall(require, 'telescope')
if not ok then
  error(
    'jj_workspaces requires telescope.nvim and plenary.nvim; install them before loading the extension'
  )
end

local loaded, extension = pcall(require, 'telescope._extensions.jj_workspaces.pickers')
if not loaded then
  error(
    'Could not load jj_workspaces Telescope extension (requires Telescope and Plenary): '
      .. tostring(extension)
  )
end

return telescope.register_extension({ exports = extension })
