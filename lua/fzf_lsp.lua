local vim, fn, api, g = vim, vim.fn, vim.api, vim.g

local M = {}

-- binary paths {{{
local __file = debug.getinfo(1, "S").source:match("@(.*)$")
assert(__file ~= nil)
local bin_dir = fn.fnamemodify(__file, ":p:h:h") .. "/bin"
local bin = { preview = (bin_dir .. "/preview.sh") }
-- }}}

-- utility functions {{{
local function partial(func, arg)
  return (function(...)
    return func(arg, ...)
  end)
end

local function perror(err)
  print("ERROR: " .. tostring(err))
end
-- }}}

-- LSP utility {{{
local function extract_result(results_lsp)
  if results_lsp then
    local results = {}
    for _, server_results in pairs(results_lsp) do
      if server_results.result then
        vim.list_extend(results, server_results.result)
      end
    end

    return results
  end
end

local function call_sync(method, params, opts, handler)
  params = params or {}
  opts = opts or {}
  local results_lsp, err = vim.lsp.buf_request_sync(
    0, method, params, opts.timeout or g.fzf_lsp_timeout
  )

  handler(err, method, extract_result(results_lsp), nil, nil)
end

local function check_capabilities(feature, client_id)
  local clients = vim.lsp.buf_get_clients(client_id or 0)

  local supported_client = false
  for _, client in pairs(clients) do
    supported_client = client.resolved_capabilities[feature]
    if supported_client then goto continue end
  end

  ::continue::
  if supported_client then
    return true
  else
    if #clients == 0 then
      print("LSP: no client attached")
    else
      print("LSP: server does not support " .. feature)
    end
    return false
  end
end

local function code_action_execute(action)
  if action.edit or type(action.command) == "table" then
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit)
    end
    if type(action.command) == "table" then
      vim.lsp.buf.execute_command(action.command)
    end
  else
    vim.lsp.buf.execute_command(action)
  end
end

local function lines_from_locations(locations, include_filename)
  local fnamemodify = (function (filename)
    if include_filename then
      return fn.fnamemodify(filename, ":~:.") .. ":"
    else
      return ""
    end
  end)

  local lines = {}
  for _, loc in ipairs(locations) do
    table.insert(lines, (
        fnamemodify(loc['filename'])
        .. loc["lnum"]
        .. ":"
        .. loc["col"]
        .. ": "
        .. vim.trim(loc["text"])
    ))
  end

  return lines
end

local function location_handler(err, _, locations, _, bufnr, error_message)
  if err ~= nil then
    perror(err)
    return
  end

  if not locations or vim.tbl_isempty(locations) then
    print(error_message)
    return
  end

  if vim.tbl_islist(locations) then
    if #locations == 1 then
      vim.lsp.util.jump_to_location(locations[1])

      return
    end
  else
    vim.lsp.util.jump_to_location(locations)
  end

  return lines_from_locations(
    vim.lsp.util.locations_to_items(locations, bufnr), true
  )
end

local function call_hierarchy_handler(direction, err, _, result, _, _, error_message)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print(error_message)
    return
  end

  local items = {}
  for _, call_hierarchy_call in pairs(result) do
    local call_hierarchy_item = call_hierarchy_call[direction]
    for _, range in pairs(call_hierarchy_call.fromRanges) do
      table.insert(items, {
        filename = assert(vim.uri_to_fname(call_hierarchy_item.uri)),
        text = call_hierarchy_item.name,
        lnum = range.start.line + 1,
        col = range.start.character + 1,
      })
    end
  end

  return lines_from_locations(items, true)
end

local call_hierarchy_handler_from = partial(call_hierarchy_handler, "from")
local call_hierarchy_handler_to = partial(call_hierarchy_handler, "to")
-- }}}

-- FZF functions {{{
local function fzf_wrap(name, opts, bang)
  name = name or ""
  opts = opts or {}
  bang = bang or 0

  if g.fzf_lsp_layout then
    opts = vim.tbl_extend('keep', opts, g.fzf_lsp_layout)
  end

  if g.fzf_lsp_colors then
    vim.list_extend(opts.options, {"--color", g.fzf_lsp_colors})
  end

  local sink_fn = opts["sink*"] or opts["sink"]
  if sink_fn ~= nil then
    opts["sink"] = nil; opts["sink*"] = 0
  else
    -- if no sink function is given i automatically put the actions
    if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
      vim.list_extend(
        opts.options, {"--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",")}
      )
    end
  end
  local wrapped = fn["fzf#wrap"](name, opts, bang)
  wrapped["sink*"] = sink_fn

  return wrapped
end

local function fzf_run(...)
  return fn["fzf#run"](...)
end

local function common_sink(infile, lines)
  local action
  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    local key = table.remove(lines, 1)
    action = g.fzf_lsp_action[key] or "edit"
  else
    action = 'edit'
  end

  for _, l in ipairs(lines) do
    local path, lnum, col

    if infile then
      path = fn.expand("%")
      lnum, col = l:match("([^:]*):([^:]*)")
    else
      path, lnum, col = l:match("([^:]*):([^:]*):([^:]*)")
    end

    if ((action ~= "edit" and action ~= "e") or
        (not infile and fn.expand("%:~:.") ~= path)) then
      local err = api.nvim_command(action .. " " .. path)
      if err ~= nil then
        api.nvim_command("echoerr " .. err)
      end
    end

    fn.cursor(lnum, col)
  end

  api.nvim_command("normal! zz")
end

local function fzf_locations(bang, prompt, header, source, infile)
  local preview_cmd = (infile and
    (bin.preview .. " " .. fn.expand("%") .. ":{}") or
    (bin.preview .. " {}")
  )
  local options = {
    "--prompt", prompt .. ">",
    "--header", header,
    "--ansi",
    "--multi",
    '--bind', 'ctrl-a:select-all,ctrl-d:deselect-all',
  }

  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    vim.list_extend(
      options, {"--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",")}
    )
  end

  if g.fzf_lsp_preview then
    vim.list_extend(options, {"--preview", preview_cmd})
  end

  fzf_run(fzf_wrap("fzf_lsp", {
    source = source,
    sink = partial(common_sink, infile),
    options = options,
  }, bang))
end

local function fzf_code_actions(bang, prompt, header, actions)
  local lines = {}
  for i, a in ipairs(actions) do
    a["idx"] = i
    lines[i] = a["idx"] .. ". " .. a["title"]
  end

  local sink_fn = (function(source)
    local _, line = next(source)
    local idx = tonumber(line:match("(%d+)[.]"))
    code_action_execute(actions[idx])
  end)

  fzf_run(fzf_wrap("fzf_lsp", {
      source = lines,
      sink = sink_fn,
      options = {
        "--prompt", prompt .. ">",
        "--header", header,
        "--ansi",
      }
  }, bang))
end
-- }}}

-- LSP reponse handlers {{{
local function code_action_handler(bang, err, _, result, _, _)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("Code Action not available")
    return
  end

  for i, a in ipairs(result) do
    a.idx = i
  end

  fzf_code_actions(bang, "", "Code Actions", result)
end

local function definition_handler(bang, err, method, result, client_id, bufnr)
  local results = location_handler(
    err, method, result, client_id, bufnr, "Definition not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Definitions", results, false)
  end
end

local function declaration_handler(bang, err, method, result, client_id, bufnr)
  local results = location_handler(
    err, method, result, client_id, bufnr, "Declaration not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Declarations", results, false)
  end
end

local function type_definition_handler(bang, err, method, result, client_id, bufnr)
  local results = location_handler(
    err, method, result, client_id, bufnr, "Type Definition not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Type Definitions", results, false)
  end
end

local function implementation_handler(bang, err, method, result, client_id, bufnr)
  local results = location_handler(
    err, method, result, client_id, bufnr, "Implementation not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Implementations", results, false)
  end
end

local function references_handler(bang, err, _, result, _, bufnr)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("References not found")
    return
  end

  local lines = lines_from_locations(
    vim.lsp.util.locations_to_items(result, bufnr), true
  )
  fzf_locations(bang, "", "References", lines, false)
end

local function document_symbol_handler(bang, err, _, result, _, bufnr)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("Document Symbol not found")
    return
  end

  local lines = lines_from_locations(
    vim.lsp.util.symbols_to_items(result, bufnr), false
  )
  fzf_locations(bang, "", "Document Symbols", lines, true)
end

local function workspace_symbol_handler(bang, err, _, result, _, bufnr)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    print("Workspace Symbol not found")
    return
  end

  local lines = lines_from_locations(
    vim.lsp.util.symbols_to_items(result, bufnr), true
  )
  fzf_locations(bang, "", "Workspace Symbols", lines, false)
end

local function incoming_calls_handler(bang, err, method, result, client_id, bufnr)
  local results = call_hierarchy_handler_from(
    err, method, result, client_id, bufnr, "Incoming calls not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Incoming Calls", results, false)
  end
end

local function outgoing_calls_handler(bang, err, method, result, client_id, bufnr)
  local results = call_hierarchy_handler_to(
    err, method, result, client_id, bufnr, "Outgoing calls not found"
  )
  if results and not vim.tbl_isempty(results) then
    fzf_locations(bang, "", "Outgoing Calls", results, false)
  end
end
-- }}}

-- COMMANDS {{{
function M.definition(bang, opts)
  if not check_capabilities("goto_definition") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/definition", params, opts, partial(definition_handler, bang)
  )
end

function M.declaration(bang, opts)
  if not check_capabilities("declaration") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/declaration", params, opts, partial(declaration_handler, bang)
  )
end

function M.type_definition(bang, opts)
  if not check_capabilities("type_definition") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/typeDefinition", params, opts, partial(type_definition_handler, bang)
  )
end

function M.implementation(bang, opts)
  if not check_capabilities("implementation") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/implementation", params, opts, partial(implementation_handler, bang)
  )
end

function M.references(bang, opts)
  if not check_capabilities("find_references") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }
  call_sync(
    "textDocument/references", params, opts, partial(references_handler, bang)
  )
end

function M.document_symbol(bang, opts)
  if not check_capabilities("document_symbol") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "textDocument/documentSymbol", params, opts, partial(document_symbol_handler, bang)
  )
end

function M.workspace_symbol(bang, opts)
  if not check_capabilities("workspace_symbol") then
    return
  end

  local params = {query = opts.query or ''}
  call_sync(
    "workspace/symbol", params, opts, partial(workspace_symbol_handler, bang)
  )
end

function M.incoming_calls(bang, opts)
  if not check_capabilities("call_hierarchy") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "callHierarchy/incomingCalls", params, opts, partial(incoming_calls_handler, bang)
  )
end

function M.outgoing_calls(bang, opts)
  if not check_capabilities("call_hierarchy") then
    return
  end

  local params = vim.lsp.util.make_position_params()
  call_sync(
    "callHierarchy/outgoingCalls", params, opts, partial(outgoing_calls_handler, bang)
  )
end

function M.code_action(bang, opts)
  if not check_capabilities("code_action") then
    return
  end

  local params = vim.lsp.util.make_range_params()
  params.context = {
    diagnostics = vim.lsp.diagnostic.get_line_diagnostics()
  }
  call_sync(
    "textDocument/codeAction", params, opts, partial(code_action_handler, bang)
  )
end

function M.range_code_action(bang, opts)
  if not check_capabilities("code_action") then
    return
  end

  local params = vim.lsp.util.make_given_range_params()
  params.context = {
    diagnostics = vim.lsp.diagnostic.get_line_diagnostics()
  }
  call_sync(
    "textDocument/codeAction", params, opts, partial(code_action_handler, bang)
  )
end

function M.diagnostic(bang, opts)
  opts = opts or {}

  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local buffer_diags = vim.lsp.diagnostic.get(bufnr)

  local severity = opts.severity
  local severity_limit = opts.severity_limit

  local items = {}
  local insert_diag = function(diag)
    if severity then
      if not diag.severity then
        return
      end

      if severity ~= diag.severity then
        return
      end
    elseif severity_limit then
      if not diag.severity then
        return
      end

      if severity_limit < diag.severity then
        return
      end
    end

    local pos = diag.range.start
    local row = pos.line
    local col = vim.lsp.util.character_offset(bufnr, row, pos.character)

    table.insert(items, {
      lnum = row + 1,
      col = col + 1,
      text = diag.message,
      type = vim.lsp.protocol.DiagnosticSeverity[diag.severity or
        vim.lsp.protocol.DiagnosticSeverity.Error]
    })
  end

  for _, diag in ipairs(buffer_diags) do
    insert_diag(diag)
  end

  table.sort(items, function(a, b) return a.lnum < b.lnum end)

  local entries = {}
  for i, e in ipairs(items) do
    entries[i] = (
      e["lnum"]
      .. ':'
      .. e["col"]
      .. ':'
      .. e["type"]
      .. ': '
      .. e["text"]:gsub("%s", " ")
    )
  end

  if vim.tbl_isempty(entries) then
    print("Empty diagnostic")
    return
  end

  fzf_locations(bang, "", "Diagnostics", entries, true)
end
-- }}}

-- LSP FUNCTIONS {{{
M.code_action_call = partial(M.code_action, 0)
M.range_code_action_call = partial(M.range_code_action, 0)
M.definition_call = partial(M.definition, 0)
M.declaration_call = partial(M.declaration, 0)
M.type_definition_call = partial(M.type_definition, 0)
M.implementation_call = partial(M.implementation, 0)
M.references_call = partial(M.references, 0)
M.document_symbol_call = partial(M.document_symbol, 0)
M.workspace_symbol_call = partial(M.workspace_symbol, 0)
M.incoming_calls_call = partial(M.incoming_calls, 0)
M.outgoing_calls_call = partial(M.outgoing_calls, 0)
M.diagnostic_call = partial(M.diagnostic, 0)
-- }}}

-- LSP HANDLERS {{{
M.code_action_handler = partial(code_action_handler, 0)
M.definition_handler = partial(definition_handler, 0)
M.declaration_handler = partial(declaration_handler, 0)
M.type_definition_handler = partial(type_definition_handler, 0)
M.implementation_handler = partial(implementation_handler, 0)
M.references_handler = partial(references_handler, 0)
M.document_symbol_handler = partial(document_symbol_handler, 0)
M.workspace_symbol_handler = partial(workspace_symbol_handler, 0)
M.incoming_calls_handler = partial(incoming_calls_handler, 0)
M.outgoing_calls_handler = partial(outgoing_calls_handler, 0)
-- }}}

-- Lua SETUP {{{
M.setup = function(opts)
  opts = opts or {}

  vim.lsp.handlers["textDocument/codeAction"] = M.code_action_handler
  vim.lsp.handlers["textDocument/definition"] = M.definition_handler
  vim.lsp.handlers["textDocument/declaration"] = M.declaration_handler
  vim.lsp.handlers["textDocument/typeDefinition"] = M.type_definition_handler
  vim.lsp.handlers["textDocument/implementation"] = M.implementation_handler
  vim.lsp.handlers["textDocument/references"] = M.references_handler
  vim.lsp.handlers["textDocument/documentSymbol"] = M.document_symbol_handler
  vim.lsp.handlers["workspace/symbol"] = M.workspace_symbol_handler
  vim.lsp.handlers["callHierarchy/incomingCalls"] = M.ingoing_calls_handler
  vim.lsp.handlers["callHierarchy/outgoingCalls"] = M.outgoing_calls_handler
end
-- }}}

return M
