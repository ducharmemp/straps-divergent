local M = {}

local FORK_SRC = [==[
return function(source, opts)
  opts = opts or {}
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")

  if type(source) ~= "number" or not vim.api.nvim_buf_is_valid(source) then
    error("fn.fork: source must be a valid buffer number", 0)
  end
  local is_session
  pcall(function() is_session = vim.b[source].straps_session end)
  if is_session ~= true then
    error(("fn.fork: buffer %d is not a straps session"):format(source), 0)
  end
  local relation = opts.relation or "child"
  if relation ~= "child" and relation ~= "peer" then
    error("fn.fork: relation must be \"child\" or \"peer\"", 0)
  end
  local start = opts.start ~= false
  local task = opts.task
  if task ~= nil and type(task) ~= "string" then
    error("fn.fork: task must be a string", 0)
  end
  if start and (task == nil or task == "") then
    error("fn.fork: task must be a non-empty string when the fork is started", 0)
  end

  local blocks = state.list_blocks(source)
  if #blocks == 0 then
    error(("fn.fork: buffer %d has no transcript blocks"):format(source), 0)
  end
  if not (blocks[1].kind == "system") then
    error("fn.fork: the source transcript does not start with a system block", 0)
  end
  local upto = opts.upto
  if upto == nil then
    upto = #blocks
  else
    upto = math.floor(tonumber(upto) or 0)
    if upto < 1 or upto > #blocks then
      error(("fn.fork: upto must be a block number between 1 and %d (got %s)")
        :format(#blocks, tostring(opts.upto)), 0)
    end
    if blocks[upto].kind == "system" then
      error("fn.fork: upto must leave at least one message block after the system block", 0)
    end
  end
  local lines = vim.api.nvim_buf_get_lines(source, 0, blocks[upto].last_lnum, false)

  local depth = 0
  pcall(function() depth = tonumber(vim.b[source].straps_spawn_depth) or 0 end)
  local child_depth = relation == "child" and (depth + 1) or depth

  local child = state.new_session()
  registry.ensure_scope(child, source)
  vim.api.nvim_buf_set_lines(child, 0, -1, false, lines)

  local cblocks = state.list_blocks(child)
  local sys = cblocks[1]
  local at = sys.marker_lnum
  for lnum = sys.last_lnum, sys.first_lnum, -1 do
    local l = vim.api.nvim_buf_get_lines(child, lnum - 1, lnum, false)[1] or ""
    if l:match("%S") then
      at = lnum
      break
    end
  end
  local section = registry.call("fn.fork_section", source, child, upto,
    { relation = relation, depth = child_depth })
  local ins = { "" }
  for _, l in ipairs(vim.split(section, "\n", { plain = true })) do
    ins[#ins + 1] = state.escape_line(l)
  end
  vim.api.nvim_buf_set_lines(child, at, at, false, ins)

  cblocks = state.list_blocks(child)
  local paired = {}
  for _, b in ipairs(cblocks) do
    if b.kind == "tool_result" and b.attrs and b.attrs.id then
      paired[b.attrs.id] = true
    end
  end
  local first_orphan
  for i, b in ipairs(cblocks) do
    if b.kind == "tool_use" and b.attrs and b.attrs.id and not paired[b.attrs.id] then
      first_orphan = i
      break
    end
  end
  local trailing = first_orphan ~= nil
  for i = first_orphan or (#cblocks + 1), #cblocks do
    if cblocks[i].kind ~= "tool_use" and cblocks[i].kind ~= "tool_result" then
      trailing = false
    end
  end
  local claimable = relation == "child"
  for i = upto + 1, #blocks do
    if blocks[i].kind ~= "tool_use" and blocks[i].kind ~= "tool_result" then
      claimable = false
    end
  end
  if trailing then
    for i = first_orphan, #cblocks do
      local b = cblocks[i]
      local id = b.attrs and b.attrs.id
      if b.kind == "tool_use" and id and not paired[id] then
        paired[id] = true
        if claimable and b.attrs.name == "fork" then
          claimable = false
          state.append(child, "tool_result", { id = id, is_error = false },
            ("this transcript is the fork (buffer %d) that this call created;"
              .. " the source session (buffer %d) continues separately"):format(child, source))
        else
          state.append(child, "tool_result", { id = id, is_error = true },
            ("[straps] not run in this fork: check the source session (buffer %d)"
              .. " for this call's outcome"):format(source))
        end
      end
    end
  end

  if task ~= nil and task ~= "" then
    if state.last_user_text(child) == "" then
      state.seed_user(child, task)
    else
      state.append(child, "user", nil, task)
    end
  else
    state.ensure_trailing_user(child)
  end

  vim.b[child].straps_spawn_depth = child_depth
  do
    local inherited
    pcall(function() inherited = vim.b[source].straps_max_turns end)
    local cap = tonumber(opts.max_turns) or (relation == "child" and 24) or tonumber(inherited)
    if cap then vim.b[child].straps_max_turns = math.floor(cap) end
  end
  do
    local filter, pp, pm, pom, pe
    pcall(function()
      filter = vim.b[source].straps_tool_filter
      pp = vim.b[source].straps_provider
      pm = vim.b[source].straps_model
      pom = vim.b[source].straps_openai_model
      pe = vim.b[source].straps_effort
    end)
    if type(filter) == "table" and #filter > 0 then
      vim.b[child].straps_tool_filter = filter
    end
    local provider = opts.provider or pp
    local model = opts.model or ((provider == "openai") and pom or pm)
    local effort = opts.effort or pe
    if type(provider) == "string" and provider ~= "" then vim.b[child].straps_provider = provider end
    if type(model) == "string" and model ~= "" then
      if provider == "openai" then vim.b[child].straps_openai_model = model else vim.b[child].straps_model = model end
    end
    if type(effort) == "string" and effort ~= "" then vim.b[child].straps_effort = effort end
  end
  if relation == "child" then
    vim.b[child].straps_parent = source
    vim.b[child].straps_task = state.utf8_cut(
      ((task or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")), 80)
    vim.b[child].straps_spawn_timeout_ms = tonumber(opts.timeout_ms) or 600000
    vim.b[child].straps_spawn_started_ms = vim.uv.now()
  end
  for key in pairs(registry.granted(source)) do
    registry.grant(child, key)
  end

  if type(opts.split) == "string" and opts.split ~= "" then
    local prev = vim.api.nvim_get_current_win()
    local ok, err = pcall(require("straps.ui").show_session, child, opts.split)
    if not ok then
      pcall(vim.notify, "straps-divergent: could not open the fork window: " .. tostring(err),
        vim.log.levels.WARN)
    end
    if opts.focus == false then
      pcall(vim.api.nvim_set_current_win, prev)
    end
  end
  if start then
    loop.start(child)
  end
  return child
end
]==]

local FORK_SECTION_SRC = [==[
return function(source, child, upto, opts)
  opts = opts or {}
  local parts = { ("# You are a fork\n\nThis session (buffer %d) is a fork of session buffer %d,"
    .. " cut after block %d of that transcript. The conversation below this prompt is a"
    .. " verbatim copy of the source up to that point. A tool result marked \"not run in"
    .. " this fork\" belongs to a call this fork did not run; the source session holds its"
    .. " outcome, if any. The last user message is the instruction for this fork.")
    :format(child, source, upto) }
  if opts.relation == "peer" then
    parts[#parts + 1] = "The user forked this session by hand with :StrapsFork. No agent is"
      .. " waiting on your reply: the user is your correspondent, as in the source session,"
      .. " and ask_user is available even where the prompt above says otherwise. The source"
      .. " session continues separately; nothing you do here changes its transcript."
  else
    parts[#parts + 1] = "The source session is your parent: it created this fork with the fork"
      .. " tool and sees NONE of this transcript beyond the point it forked, only the single"
      .. " final reply you end with. Make that reply complete and self-contained, follow any"
      .. " answer format the task specifies, and never end on a promise of more work. If the"
      .. " task cannot be completed, say so plainly in the reply. You have no ask_user tool:"
      .. " the parent is your correspondent. When the task is ambiguous, state"
      .. " the assumption you took in your reply, or report a blocker with"
      .. " send_message{to=\"parent\"}. Guidance above that says to use ask_user does not"
      .. " apply to you."
  end
  local limit = require("straps.registry").try_call("fn.spawn_depth_limit") or 1
  if (tonumber(opts.depth) or 0) >= limit then
    parts[#parts + 1] = "spawn and fork are unavailable in this session (the subagent depth"
      .. " limit is reached): do the work yourself."
  end
  return table.concat(parts, "\n\n")
end
]==]

local TOOL_FORK_SRC = [==[
return function(input, ctx)
  local task = input.task
  if type(task) ~= "string" or task == "" then
    error("fork: task must be a non-empty string", 0)
  end
  local registry = require("straps.registry")
  local depth = 0
  pcall(function() depth = tonumber(vim.b[ctx.bufnr].straps_spawn_depth) or 0 end)
  local max_depth = registry.try_call("fn.spawn_depth_limit") or 1
  if depth >= max_depth then
    return "fork: refused — subagent depth limit (" .. max_depth
      .. ") reached; do this work yourself"
  end
  local child = registry.call("fn.fork", ctx.bufnr, {
    relation = "child",
    task = task,
    upto = input.upto,
    max_turns = input.max_turns,
    timeout_ms = input.timeout_ms,
    model = input.model,
    effort = input.effort,
    split = input.show and "botright vsplit" or nil,
    focus = false,
  })
  local name = vim.api.nvim_buf_get_name(child)
  local where = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("buffer " .. child)
  return ("fork started — buffer %d, transcript: %s\n"
    .. "it holds a copy of this conversation plus your task; collect its answer with"
    .. " spawn_wait{ buffers = { %d } }"):format(child, where, child)
end
]==]

local PROMPT_LAYER_SRC = [==[
return function()
  return [[# Forking

- fork copies THIS conversation into a new session and runs a task there, in
  parallel; spawn starts a child with an empty context. Fork when the child
  needs what this transcript already holds (the files you read, the design you
  settled); spawn when a clean context serves the task better. Each request
  the fork makes resends the copied transcript as input tokens.
- fork returns a buffer handle at once, like spawn; collect its reply with
  spawn_wait. The fork sees only the transcript up to the fork call (upto cuts
  it earlier); tool calls after that point in this session run only here.
  fork stays listed at the subagent depth limit and refuses there.
- The user can fork a session by hand with :StrapsFork; such a fork is a peer
  and sends you no notice.]]
end
]==]

local function split_cmd_of(smods)
  if smods and type(smods.tab) == "number" and smods.tab > 0 then
    return "tab split"
  end
  local prefix = smods and smods.split ~= "" and smods.split or ""
  local verb = smods and smods.vertical and "vsplit" or "split"
  return (prefix ~= "" and (prefix .. " ") or "") .. verb
end
local function parse_fork_args(args)
  local padded = " " .. args .. " "
  local s, e = padded:find("%s%-%-%s")
  local head, instruction
  if s then
    head = padded:sub(1, s)
    instruction = vim.trim(padded:sub(e))
    if instruction == "" then instruction = nil end
  else
    head = padded
  end
  local upto
  for tok in head:gmatch("%S+") do
    if upto ~= nil or not tok:match("^%d+$") then
      return nil, nil, "usage: :StrapsFork[!] [upto] [-- instruction]"
    end
    upto = tonumber(tok)
  end
  return upto, instruction
end

local function fork_command(opts)
  local ui = require("straps.ui")
  local loop = require("straps.loop")
  local registry = require("straps.registry")
  local source = ui.resolve_session(vim.api.nvim_get_current_buf())
  if not source then
    vim.notify("straps-divergent: run :StrapsFork on a straps session buffer", vim.log.levels.ERROR)
    return
  end
  local function refuse_running()
    if not loop.running(source) then return false end
    vim.notify("straps-divergent: the source session has a run active; :StrapsStop it first",
      vim.log.levels.ERROR)
    return true
  end
  if refuse_running() then return end
  local upto, instruction, err = parse_fork_args(opts.args)
  if err then
    vim.notify("straps-divergent: " .. err, vim.log.levels.ERROR)
    return
  end
  local function go(task)
    if refuse_running() then return end
    local ok, res = pcall(registry.call, "fn.fork", source, {
      relation = "peer",
      task = task,
      upto = upto,
      start = not opts.bang,
      split = split_cmd_of(opts.smods),
    })
    if not ok then
      vim.notify("straps-divergent: " .. tostring(res), vim.log.levels.ERROR)
    end
  end
  if instruction or opts.bang then
    go(instruction)
    return
  end
  vim.ui.input({ prompt = "fork instruction: " }, function(txt)
    if txt and txt ~= "" then
      go(txt)
    end
  end)
end

function M.register()
  local registry = require("straps.registry")
  if registry.get("fn.system_prompt") == nil then
    error("straps-divergent: call require(\"straps\").setup() before require(\"straps-divergent\").setup()", 0)
  end
  local define = registry.define_default

  define({
    name = "fn.fork",
    kind = "fn",
    doc = "fn.fork(source_bufnr, opts) -> child_bufnr. Create a new session whose"
      .. " transcript is a verbatim copy of source up to block opts.upto (default:"
      .. " every block), with a '# You are a fork' section (fn.fork_section) appended"
      .. " to the copied system block, a tool_result for every unpaired tool_use in the"
      .. " copy, and opts.task as the trailing user block. opts.relation 'child'"
      .. " (default) sets straps_parent so the source collects the reply with"
      .. " spawn_wait; 'peer' leaves the fork independent. Copies the source's grants,"
      .. " tool filter and provider/model/effort (opts.provider/model/effort override),"
      .. " and chains the fork's registry scope under the source. opts.start = false"
      .. " leaves the fork idle; opts.split opens it with that split command (focus ="
      .. " false restores the previous window); max_turns, timeout_ms as for spawn.",
    source = FORK_SRC,
  })

  define({
    name = "fn.fork_section",
    kind = "fn",
    doc = "fn.fork_section(source, child, upto, { relation, depth }) -> string. The"
      .. " '# You are a fork' section fn.fork appends to the copied system block:"
      .. " names the source buffer and cut point, explains the synthetic tool results,"
      .. " and for a child relation restates the subagent contract (the parent sees"
      .. " only the final reply; no ask_user; send_message{to=\"parent\"} for blockers;"
      .. " spawn/fork unavailable at the depth limit). A peer relation says the user"
      .. " forked by hand and remains the correspondent. Redefine to change the wording.",
    source = FORK_SECTION_SRC,
  })

  define({
    name = "tool.fork",
    kind = "tool",
    capability = "spawn",
    doc = "Fork THIS conversation: start a subagent whose transcript is a verbatim copy"
      .. " of this session up to now (or up to block `upto`), followed by `task` as its"
      .. " instruction. Unlike spawn, the fork already knows everything this session"
      .. " knows, so the task can refer to files, findings and decisions above without"
      .. " restating them. Returns at once with the fork's buffer handle; collect its"
      .. " final reply with spawn_wait, exactly as for spawn, and a [straps] notice"
      .. " arrives when it finishes. The fork holds this session's permissions and"
      .. " session-scoped tools, counts against the subagent depth limit, and loses"
      .. " ask_user (the parent is its correspondent). Tool calls issued after the fork"
      .. " call in this turn run only here; the fork sees them as 'not run in this"
      .. " fork'. Parameters: task (required); upto (optional): a block number from"
      .. " transcript_excise's listing, the fork sees blocks 1..upto (2 or more; 1 is the"
      .. " system block); show (optional): open the fork's transcript in a split;"
      .. " max_turns (default 24); timeout_ms (default 600000, enforced by spawn_wait);"
      .. " model, effort (optional): override the inherited model/effort.",
    input_schema = {
      type = "object",
      properties = {
        task = { type = "string", description = "The fork's instruction; it may refer to anything in this conversation." },
        upto = { type = "integer", description = "Copy blocks 1..upto only (block numbers as transcript_excise lists them); default: the whole transcript." },
        show = { type = "boolean", description = "Open the fork's transcript buffer in a split." },
        max_turns = { type = "integer", description = "Fork turn budget (default 24)." },
        timeout_ms = { type = "integer", description = "Wall-clock cap in milliseconds (default 600000), enforced by spawn_wait." },
        model = { type = "string", description = "Model id for the fork (default: this session's model)." },
        effort = { type = "string", description = "Extended-thinking effort name for the fork (default: this session's effort)." },
      },
      required = { "task" },
    },
    source = TOOL_FORK_SRC,
  })

  define({
    name = "fn.system_prompt_layer.divergent",
    kind = "fn",
    doc = "Prompt section for straps-divergent: when to fork rather than spawn, how a"
      .. " fork's transcript is cut, and that :StrapsFork makes a peer.",
    source = PROMPT_LAYER_SRC,
  })

  vim.api.nvim_create_user_command("StrapsFork", fork_command, {
    nargs = "*",
    bang = true,
    desc = "straps-divergent: fork this session into a new peer session"
      .. " ([upto] cuts the copy; `-- text` is the instruction; ! leaves it idle;"
      .. " :vertical for a vsplit)",
  })
end

function M.setup()
  M.register()
  return M
end

return M
