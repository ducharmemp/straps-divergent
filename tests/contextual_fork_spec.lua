local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
local straps = vim.env.STRAPS_ROOT or root .. "/../straps"
vim.opt.rtp:prepend(straps)
vim.opt.rtp:prepend(root)
package.path = straps .. "/lua/?.lua;" .. straps .. "/lua/?/init.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local registry, state, bridge, controller, source, ctx, starts, attached, constructed, fail_attach, child, directory
before_each(function()
  for _, name in ipairs({ "registry", "ceilings", "contextual_children", "state" }) do package.loaded["straps." .. name] = nil end
  registry = require("straps.registry")
  directory = vim.fn.tempname()
  require("straps").config.session_dir = directory
  registry.define({ name = "fn.system_prompt", kind = "fn", source = 'return function() return "COPIED SYSTEM AUTHORITY" end' })
  registry.define({ name = "fn.spawn_depth_limit", kind = "fn", source = 'return function() return 4 end' })
  registry.define({ name = "fn.capability", kind = "fn", source = 'return function(name) if name then return "edit" end return {"edit","spawn"} end' })
  require("straps-divergent").register()
  controller = registry.setup_authorization({ assess = function() return { decision = "allow" } end,
    execution_stamp = function(b) return { session = b } end, validate_stamp = function() return true end })
  local module_source = table.concat(vim.fn.readfile(straps .. "/lua/straps/contextual_children.lua"), "\n")
  local mutations = {
    fork_start = { 'local tx = { start = action ~= "fork" }', 'local tx = { start = true }' },
    fork_delegation = { 'assert(options.delegation == nil, "copied fork prompt requires explicit adoption before delegation")', '' },
  }
  local change = mutations[vim.env.STRAPS_CHILD_MUTANT]
  if change then
    local first, last = assert(module_source:find(change[1], 1, true))
    module_source = module_source:sub(1, first - 1) .. change[2] .. module_source:sub(last + 1)
  end
  bridge = assert(loadstring(module_source))()
  package.loaded["straps.contextual_children"] = bridge
  starts, attached, constructed, fail_attach = 0, 0, 0, false
  bridge.install({ prepare = controller.prepare_child, attach = function(plan, value, subset, token)
    controller.attach_child(plan, value)
    child = value
    assert.is_nil(subset)
    assert.is_nil(token)
    if fail_attach then error("fork attachment failed") end
    attached = attached + 1
  end, rollback = function() end }, { receipts = { construct = function() constructed = constructed + 1 error("fork minted receipt") end } })
  state = require("straps.state")
  source = state.new_session()
  assert.equals(vim.uv.fs_realpath(directory), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source), ":h"))
  state.seed_user(source, "HISTORICAL USER AUTHORITY")
  registry.ensure_scope(source)
  controller.install_ceiling(source, { allow = { "spawn" } })
  controller.classify_ceiling(registry.get("tool.fork").identity, "spawn")
  ctx = { bufnr = source }
  controller.begin_family(ctx)
  package.loaded["straps.loop"] = { start = function() starts = starts + 1 end }
end)
local function run(input)
  local allowed, reason, body = registry.gate_tool("fork", input or { task = "work" }, ctx)
  assert.is_true(allowed, reason)
  return body(ctx)
end

it("copies transcript with no receipt or start and attaches ceiling", function()
  assert.is_true(run())
  assert.equals(1, attached)
  assert.equals(vim.uv.fs_realpath(directory), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(child), ":h"))
  assert.equals(0, constructed)
  assert.equals(0, starts)
  local text = table.concat(vim.api.nvim_buf_get_lines(child, 0, -1, false), "\n")
  assert.matches("COPIED SYSTEM AUTHORITY", text)
  assert.matches("HISTORICAL USER AUTHORITY", text)
  assert.matches("# You are a fork", text, 1, true)
  assert.equals(source, registry.scope_parent(child))
  registry.define({ name = "tool.write", kind = "tool", source = 'return function() error("write body ran") end' })
  controller.classify_ceiling(registry.get("tool.write").identity, "edit")
  local childctx = { bufnr = child }
  controller.begin_family(childctx)
  assert.is_false(registry.gate_tool("write", {}, childctx))
end)

it("refuses generic human fork without exact invocation before allocation", function()
  local count = #vim.api.nvim_list_bufs()
  assert.has_error(function() registry.call("fn.fork", source, { relation = "peer", task = "work" }) end)
  assert.equals(count, #vim.api.nvim_list_bufs())
  assert.equals(0, starts)
end)

it("refuses delegation from copied prompt and rolls back", function()
  local ok, reason = run({ task = "work", delegation = { targets = {}, effects = {}, capabilities = {}, sources = { "event" } } })
  assert.is_false(ok)
  assert.matches("explicit adoption", reason)
  assert.equals(0, attached)
  assert.equals(0, starts)
end)

it("rolls back when ceiling attachment fails", function()
  fail_attach = true
  local ok, reason = run()
  assert.is_false(ok)
  assert.matches("fork attachment failed", reason)
  assert.is_false(vim.api.nvim_buf_is_valid(child))
  assert.equals(0, starts)
end)

for _, order in ipairs({ "divergent_first", "contextual_first" }) do
  it("constructs and adopts shipped divergent with production bootstrap " .. order, function()
    for name in pairs(package.loaded) do
      if name == "straps" or name == "straps-divergent" or name:match("^straps%.") or name:match("^straps_classifier") then
        package.loaded[name] = nil
      end
    end
    local mutant = vim.env.STRAPS_DIVERGENT_MUTANT
    local function mutated(path, old, replacement)
      local text = table.concat(vim.fn.readfile(path), "\n")
      local first, last = assert(text:find(old, 1, true))
      return assert(loadstring(text:sub(1, first - 1) .. replacement .. text:sub(last + 1)))()
    end
    if mutant == "category" then
      package.loaded["straps.contextual"] = mutated(straps .. "/lua/straps/contextual.lua",
        'divergent_controller.classify_ceiling(divergent_classified, "spawn")', '')
    elseif mutant == "identity" then
      package.loaded["straps-divergent"] = mutated(root .. "/lua/straps-divergent/init.lua",
        'entry.identity ~= original.identity or entry.source ~= original.source', 'entry.source ~= original.source')
    elseif mutant == "ceiling" then
      package.loaded["straps.ceilings"] = mutated(straps .. "/lua/straps/ceilings.lua",
        'if not permits(record, definition, category, input) then', 'if false then')
    elseif mutant == "write_ceiling" then
      package.loaded["straps.ceilings"] = mutated(straps .. "/lua/straps/ceilings.lua",
        'if not permits(record, definition, category, input) then', 'if definition.name ~= "tool.write_file" and not permits(record, definition, category, input) then')
    elseif mutant == "shape_options" then
      package.loaded["straps.provider"] = mutated(straps .. "/lua/straps/provider.lua",
        'if shape then opts = shape.options elseif original then opts = original.options end',
        'if original then opts = original.options end')
    elseif mutant == "shape_section" then
      package.loaded["straps.provider"] = mutated(straps .. "/lua/straps/provider.lua",
        'system = system .. "\\n\\n" .. registry.call("fn.fork_section", shape.fork.source, bufnr, shape.fork.upto,',
        'system = system .. "\\n\\n" .. registry.call("fn.fork_section", shape.fork.source, bufnr, 999,')
    elseif mutant == "shape_identity" then
      package.loaded["straps-divergent"] = mutated(root .. "/lua/straps-divergent/init.lua",
        'entry.identity ~= original.identity or entry.source ~= original.source', 'entry.source ~= original.source')
      package.loaded["straps.provider"] = mutated(straps .. "/lua/straps/provider.lua",
        'not vim.deep_equal(shape.section, definitions.definitions["fn.fork_section"])', 'false')
    elseif mutant == "layer" then
      package.loaded["straps.provider"] = mutated(straps .. "/lua/straps/provider.lua",
        'identities["fn.system_prompt_layer.divergent"] = divergent["fn.system_prompt_layer.divergent"]', '')
    end
    local classifier = straps .. "/../straps-classifier"
    package.path = classifier .. "/lua/?.lua;" .. classifier .. "/lua/?/init.lua;" .. package.path
    require("straps").setup({ session_dir = vim.fn.tempname(), layers = { editor = false } })
    local actual_registry = require("straps.registry")
    local actual_controller
    local setup = actual_registry.setup_authorization
    actual_registry.setup_authorization = function(config)
      actual_controller = setup(config)
      return actual_controller
    end
    local callbacks
    require("straps.contextual_human").attach("plugin", function(value) callbacks = value end)
    if order == "divergent_first" then require("straps-divergent").setup() end
    local prompt_callbacks
    local provider = require("straps.provider")
    local install = provider.install_prompt_receipts
    provider.install_prompt_receipts = function(consumer)
      return install(function(value) prompt_callbacks = value; consumer(value) end)
    end
    local contextual = require("straps.contextual")
    local contextual_setup = contextual.setup
    contextual.setup = function(config)
      config.disclosure = { approved = true }
      config.install_assessor = function(consumer)
        consumer(function()
          return { synthesize = function(snapshot)
            local spec = { schema_version = 1, task_id = snapshot.task_id, instruction_revision = snapshot.epoch }
            for _, key in ipairs({ "outcome", "mode", "targets", "effects", "constraints", "reserved_decisions", "latitude", "unresolved_scope" }) do
              spec[key] = { value = {}, sources = { snapshot.adopted[1] } }
            end
            spec.outcome.value, spec.mode.value = "Inspect project", "investigation"
            return spec, { unsupported_authority = false, untrusted_authority = false, omitted_constraint = false,
              expanded_scope = false, lost_authorization = false, hidden_ambiguity = false }
          end, assess = function() return { decision = "allow" } end }
        end)
      end
      config.resolve_targets = function() return { known = {}, unresolved = {}, checks = {} } end
      config.validate_targets = function() return true end
      return contextual_setup(config)
    end
    require("straps_classifier").setup({ contextual = { enabled = true,
      limits = { max_bytes = 1048576, max_depth = 40, max_items = 10000 } } })
    if order == "contextual_first" then require("straps-divergent").setup() end
    require("straps-divergent").setup()
    local constructed, session = pcall(callbacks.construct)
    assert.is_true(constructed, session)
    assert.is_number(session)
    local actual_state = require("straps.state")
    assert.truthy(actual_state.parse(session).system:find("# Forking", 1, true))
    callbacks.steer(session, "Inspect local project", function() end)
    assert.is_true(vim.wait(3000, function() return type(vim.fn.maparg("y", "n", false, true).callback) == "function" end, 5))
    vim.fn.maparg("y", "n", false, true).callback()
    assert.is_true(vim.wait(3000, function()
      local adopted = require("straps.authorization").snapshot(session)
      return adopted and #adopted.adopted == 1
    end, 5))
    local snapshot = require("straps.authorization").snapshot(session)
    assert.is_true(require("straps.provider").contextual_validate_prompt(session, snapshot.standing))
    actual_controller.narrow_ceiling(session, { allow = { "spawn" } })
    local context = { bufnr = session }
    actual_controller.begin_family(context)
    vim.b[session].straps_tool_filter = { "read_file", "fork", "write_file" }
    local limit = actual_registry.call("fn.spawn_depth_limit")
    vim.b[session].straps_spawn_depth = limit - 1
    local allowed, reason, body = actual_registry.gate_tool("fork",
      { task = "Inspect", readonly = true, max_turns = 17, timeout_ms = 12345 }, context, { confirm = false })
    assert.is_true(allowed, reason)
    local success, output = body(context)
    assert.is_true(success, output)
    local copied = tonumber(output:match("buffer (%d+)"))
    assert.is_number(copied)
    assert.truthy(output:find("inactive", 1, true))
    assert.truthy(actual_state.parse(copied).system:find("# You are a fork", 1, true))
    assert.is_nil(require("straps.provider").contextual_composition_identity(copied))
    assert.equals("suspended", require("straps.authorization").snapshot(copied).status)
    callbacks.steer(copied, "Adopt the copied project task", function() end)
    assert.is_true(vim.wait(3000, function() return type(vim.fn.maparg("y", "n", false, true).callback) == "function" end, 5))
    vim.fn.maparg("y", "n", false, true).callback()
    assert.is_true(vim.wait(3000, function()
      local adopted = require("straps.authorization").snapshot(copied)
      return adopted and #adopted.adopted == 1
    end, 5))
    local adopted = require("straps.authorization").snapshot(copied)
    assert.equals("active", adopted.status)
    assert.is_true(require("straps.provider").contextual_validate_prompt(copied, adopted.standing))
    local adopted_system = actual_state.parse(copied).system
    local retained_contract = {
      fork = adopted_system:find("# You are a fork", 1, true) ~= nil,
      parent_correspondent = adopted_system:find("the parent is your correspondent", 1, true) ~= nil,
      readonly = adopted_system:find("This is a READ-ONLY session", 1, true) ~= nil,
      parent = vim.b[copied].straps_parent,
      scope_parent = actual_registry.scope_parent(copied),
    }
    local exec_allowed, exec_reason = actual_registry.gate_tool("bash", { command = "true" }, context)
    assert.is_false(exec_allowed)
    assert.equals("capability ceiling denied", exec_reason)
    actual_registry.ensure_scope(copied, session)
    local child_context = { bufnr = copied }
    actual_controller.begin_family(child_context)
    local write_allowed, write_reason = actual_registry.gate_tool("write_file", { path = "forbidden", content = "forbidden" }, child_context)
    assert.is_false(write_allowed)
    assert.equals("capability ceiling denied", write_reason)
    assert.same({ fork = true, parent_correspondent = true, readonly = true, parent = session, scope_parent = session }, retained_contract)
    local identity = provider.contextual_composition_identity(copied)
    assert.same({ subagent = true, readonly = true, tools = { "read_file", "fork", "write_file" } }, identity.options)
    assert.equals(limit, vim.b[copied].straps_spawn_depth)
    assert.equals(17, vim.b[copied].straps_max_turns)
    assert.equals(12345, vim.b[copied].straps_spawn_timeout_ms)
    local previous = actual_registry.set_active_scope(copied)
    local available = {}
    for _, tool in ipairs(actual_registry.call("fn.build_tools")) do available[#available + 1] = tool.name end
    actual_registry.set_active_scope(previous)
    assert.same({ "read_file", "write_file", "fork" }, available)
    assert.truthy(adopted_system:find("only the single final reply", 1, true))
    assert.truthy(adopted_system:find("subagent depth limit is reached", 1, true))
    local view = assert(prompt_callbacks.prepare_adoption(copied, { subagent = false }, copied))
    assert.truthy(view.system:find("cut after block " .. #actual_state.list_blocks(session) .. " of that transcript", 1, true))
    assert.is_true(view.options.readonly)
    previous = actual_registry.set_active_scope(copied)
    local section = actual_registry.get("fn.fork_section")
    actual_registry.define({ name = "fn.fork_section", kind = "fn", source = section.source })
    actual_registry.set_active_scope(previous)
    assert.is_nil(prompt_callbacks.prepare_adoption(copied, nil, copied))
    local saved = actual_registry.get("tool.fork")
    actual_registry.define({ name = "tool.fork", kind = "tool", capability = "spawn", source = saved.source })
    local accepted, replacement_reason = actual_registry.gate_tool("fork", { task = "Inspect" }, context)
    assert.is_false(accepted)
    assert.equals("capability ceiling denied", replacement_reason)
  end)
end

