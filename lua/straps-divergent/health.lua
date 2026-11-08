local M = {}

function M.check()
  vim.health.start("straps-divergent")
  local ok, registry = pcall(require, "straps.registry")
  if not ok then
    vim.health.error("Straps is missing from runtimepath")
    return
  end
  if registry.get("fn.system_prompt") then vim.health.ok("Straps setup() has run")
  else vim.health.error("Run Straps setup() before divergent setup()") end
  if registry.get("tool.fork") then vim.health.ok("fork registered")
  else vim.health.warn("fork is not registered; run divergent setup()") end
end

return M
