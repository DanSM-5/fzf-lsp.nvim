local vim, fn, api, g = vim, vim.fn, vim.api, vim.g

-- TODO: can these colors come from colorscheme?
-- Used only in DocumentSymbol/WorkspaceSymbol using pretty
local kind_to_color = {
  ["Class"] = "blue",
  ["Constant"] = "lightpurple",
  ["Field"] = "yellow",
  ["Interface"] = "yellow",
  ["Function"] = "green",
  ["Method"] = "green",
  ["Module"] = "magenta",
  ["Property"] = "yellow",
  ["Struct"] = "red",
  ["Variable"] = "cyan",
  ["Object"] = "red",
  ["String"] = "blackbg}%{yellow",
  ["Array"] = "green",
  ["Branch"] = "whitebg}%{magenta",
  ["Boolean"] = "blue",
  ["Color"] = "redbg}%{white",
  ["Constructor"] = "yellowbg}%{blue",
  ["Enum"] = "blue",
  ["EnumMember"] = "whitebg}%{blue",
  ["Event"] = "green",
  ["File"] = "orange",
  ["Folder"] = "yellow",
  ["Key"] = "lightgreen",
  ["Keyword"] = "lightred",
  ["Namespace"] = "turquoise",
  ["Number"] = "blue",
  ["Null"] = "turquoise",
  ["Operator"] = "magenta",
  ["Package"] = "whitealbg}%{black",
  ["Reference"] = "magenta",
  ["Snippet"] = "green",
  ["Text"] = "yellow",
  ["TypeParameter"] = "magentabg}%{white",
  ["Unit"] = "black",
  ["Value"] = "white",
}

local methods = {
  prepareCallHierarchy = "textDocument/prepareCallHierarchy",
  incomingCalls = "callHierarchy/incomingCalls",
  outgoingCalls = "callHierarchy/outgoingCalls",
  codeAction = "textDocument/codeAction",
  definition = "textDocument/definition",
  declaration = "textDocument/declaration",
  typeDefinition = "textDocument/typeDefinition",
  implementation = "textDocument/implementation",
  references = "textDocument/references",
  documentSymbol = "textDocument/documentSymbol",
  workspaceSymbol = "workspace/symbol",
  resolveCodeAction = "codeAction/resolve",
  completion = "textDocument/completion",
}

local M = {}

-- platform detection {{{
local is_windows = vim.env.OS == "Windows_NT"
-- }}}

-- binary paths {{{
local __file = debug.getinfo(1, "S").source:match("@(.*)$")
assert(__file ~= nil)
local bin_dir = fn.fnamemodify(__file, ":p:h:h") .. "/bin"
local preview_command = ""
if is_windows then
  bin_dir = fn.substitute(bin_dir, "\\", "/", "g") -- Ensure use of forward slash
  preview_command = "powershell.exe -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "
    .. bin_dir
    .. "/preview.ps1"
else
  preview_command = bin_dir .. "/preview.sh"
end
local bin = { preview = preview_command }
-- }}}

---@class fzf_lsp.CommonOpts
---@field data? any User defined data that can be recover in the sync if a callback was provided
---@field timeout? integer Timeout to wait. It is possible to use global g:fzf_lsp_timeout. Only valid for sync execution
---@field sync? boolean Whether to run the request synchronously
---@field bufnr? integer Buffer to apply diagnostics call
---@field severity? integer Buffer to apply diagnostics call
---@field severity_limit? integer Buffer to apply diagnostics call
---@field query? string Query for document symbols call
---@field fzf_opts? string[] Override options for fzf command

---@class fzf_lsp.HandlerContext: lsp.HandlerContext
---@field opts fzf_lsp.CommonOpts Injected opts on the lsp.HandlerContext object

---@class fzf_lsp.fzf_locations_data
---@field locs vim.quickfix.entry[] parsed location data
---@field infile boolean if it is present on current file
---@field results? any|any[] lsp results data
---@field ctx? fzf_lsp.HandlerContext lsp context handler
---@field config? table lsp request config
---@field diagnostics? vim.Diagnostic[] diagnostics information

---@alias fzf_lsp.action_callback fun(args: {
---locations: vim.quickfix.entry[];
---data: fzf_lsp.fzf_locations_data;
---action_type: string;
---})

---@class fzf_lsp.InjectedCodeAction: lsp.CodeAction
---@field client_id integer the client_id that provided the code action

---@alias fzf_lsp.LspHandler fun(
---bang: 0|1,
---err: lsp.ResponseError,
---result: lsp.Location[]|lsp.LocationLink[]|lsp.DocumentSymbol[]|lsp.SymbolInformation[]|lsp.WorkspaceSymbol[]|lsp.CodeAction[]|(lsp.CompletionItem[]|lsp.CompletionList)[],
---ctx: fzf_lsp.HandlerContext,
---config: table?)

---@alias fzf_lsp.LspMethodCall fun(bang: 0|1, opts: fzf_lsp.CommonOpts)
---@alias fzf_lsp.RequestCall fun(opts?: fzf_lsp.CommonOpts)

---@alias fzf_lsp.completion.on_choice fun(idx: number, line: string)

---@class fzf_lsp.completion.data
---@field results lsp.CompletionItem[]
---@field ctx lsp.HandlerContext
---@field config table
---@field on_choice fzf_lsp.completion.on_choice

-- utility functions {{{

local wait_result_reason = { timeout = -1, interrupted = -2, error = -3 }

local strdisplaywidth = (function()
  local fallback = function(str, col)
    str = tostring(str)
    if vim.in_fast_event() then
      return #str - (col or 0)
    end
    return vim.fn.strdisplaywidth(str, col)
  end

  if jit then
    local ffi = require("ffi")
    ffi.cdef([[
      typedef unsigned char char_u;
      int linetabsize_col(int startcol, char_u *s);
    ]])

    local ffi_func = function(str, col)
      str = tostring(str)
      local startcol = col or 0
      local s = ffi.new("char[?]", #str + 1)
      ffi.copy(s, str)
      return ffi.C.linetabsize_col(startcol, s) - startcol
    end

    -- vim.print(pcall(ffi_func, "hello"))
    local ok = pcall(ffi_func, "hello")
    if ok then
      return ffi_func
    else
      return fallback
    end
  else
    return fallback
  end
end)()

local function align_str(string, width, right_justify)
  local str_len = strdisplaywidth(string)
  return right_justify and string.rep(" ", width - str_len) .. string or string .. string.rep(" ", width - str_len)
end

local strcharpart = (function()
  local fallback = function(str, nchar, charlen)
    if vim.in_fast_event() then
      return str:sub(nchar + 1, charlen)
    end
    return vim.fn.strcharpart(str, nchar, charlen)
  end

  if jit then
    local ffi = require("ffi")
    ffi.cdef([[
      typedef unsigned char char_u;
      int utf_ptr2len(const char_u *const p);
    ]])

    local function utf_ptr2len(str)
      local c_str = ffi.new("char[?]", #str + 1)
      ffi.copy(c_str, str)
      return ffi.C.utf_ptr2len(c_str)
    end

    local ok = pcall(utf_ptr2len, "🔭")
    if not ok then
      return fallback
    end

    return function(str, nchar, charlen)
      local nbyte = 0
      if nchar > 0 then
        while nchar > 0 and nbyte < #str do
          nbyte = nbyte + utf_ptr2len(str:sub(nbyte + 1))
          nchar = nchar - 1
        end
      else
        nbyte = nchar
      end

      local len = 0
      if charlen then
        while charlen > 0 and nbyte + len < #str do
          local off = nbyte + len
          if off < 0 then
            len = len + 1
          else
            len = len + utf_ptr2len(str:sub(off + 1))
          end
          charlen = charlen - 1
        end
      else
        len = #str - nbyte
      end

      if nbyte < 0 then
        len = len + nbyte
        nbyte = 0
      elseif nbyte > #str then
        nbyte = #str
      end
      if len < 0 then
        len = 0
      elseif nbyte + len > #str then
        len = #str - nbyte
      end

      return str:sub(nbyte + 1, nbyte + len)
    end
  else
    return fallback
  end
end)()

local function _truncate(str, len, dots, direction)
  if strdisplaywidth(str) <= len then
    return str
  end
  local start = direction > 0 and 0 or str:len()
  local current = 0
  local result = ""
  local len_of_dots = strdisplaywidth(dots)
  local concat = function(a, b, dir)
    if dir > 0 then
      return a .. b
    else
      return b .. a
    end
  end
  while true do
    local part = strcharpart(str, start, 1)
    current = current + strdisplaywidth(part)
    if (current + len_of_dots) > len then
      result = concat(result, dots, direction)
      break
    end
    result = concat(result, part, direction)
    start = start + direction
  end
  return result
end

local truncate = function(str, len, dots, direction)
  str = tostring(str) -- We need to make sure its an actually a string and not a number
  dots = dots or "…"
  direction = direction or 1
  if direction ~= 0 then
    return _truncate(str, len, dots, direction)
  else
    if strdisplaywidth(str) <= len then
      return str
    end
    local len1 = math.floor((len + strdisplaywidth(dots)) / 2)
    local s1 = _truncate(str, len1, dots, 1)
    local len2 = len - strdisplaywidth(s1) + strdisplaywidth(dots)
    local s2 = _truncate(str, len2, dots, -1)
    return s1 .. s2:sub(dots:len() + 1)
  end
end

local function partial(func, ...)
  local bound_args = { ... }
  local n_bound = select("#", ...) -- Count of bound arguments, including nils
  return function(...)
    local new_args = { ... }
    local n_new = select("#", ...) -- Count of new arguments, including nils
    local args = {}
    -- Copy bound arguments, preserving nils
    for i = 1, n_bound do
      args[i] = bound_args[i]
    end
    -- Append new arguments, preserving nils
    for i = 1, n_new do
      args[n_bound + i] = new_args[i]
    end
    return func(unpack(args, 1, n_bound + n_new))
  end
end

---Notify error on lsp request
---@param err string|lsp.ResponseError
local function perror(err)
  if type(err) == "string" then
    vim.notify("ERROR: " .. tostring(err), vim.log.levels.WARN)
    return
  end

  vim.notify("ERROR: " .. tostring(err.message), vim.log.levels.WARN)
end

local function fnamemodify(filename, include_filename)
  if include_filename and filename ~= nil then
    return fn.fnamemodify(filename, ":~:.") .. ":"
  else
    return ""
  end
end

local function colored_kind(kind)
  local width = 10 -- max lenght of listed kinds
  if kind == nil then
    return string.rep(" ", width)
  end

  local color = kind_to_color[kind] or "white"
  local escape = "%{bright}%{" .. color .. "}"
  local kindlen = #kind
  local padding = width > kindlen and string.rep(" ", width - kindlen) or ""
  local ansi = require("fzf_lsp.ansicolors")
  return align_str(
    string.format("%s%s%s%s", ansi.noReset(escape), truncate(kind or "", width), ansi.noReset("%{reset}"), padding),
    width
  )
end
-- }}}

-- LSP utility {{{

---Get diagnostics for the given line
---@param line? integer? line number to get diagnostics from (0-based index) or nil for current
---@return vim.Diagnostic[]
local function get_diagnostics_data(line)
  local lnum = line or vim.api.nvim_win_get_cursor(0)[1] - 1
  local diagnostics = vim.diagnostic.get(0, { lnum = lnum })
  if #diagnostics == 0 then
    return {}
  end

  return vim.tbl_map(function(d)
    return d.user_data.lsp
  end, diagnostics)
end

---Get diagnostics of the given range
---@param range lsp.Range
local function get_diagnostics_range(range)
  -- add 1 to avoid loop starting of 0
  local r_start = range.start.line + 1
  local r_end = range["end"].line + 1
  ---@type vim.Diagnostic[]
  local diagnostics = {}
  for i = r_start, r_end, 1 do
    local ok, diag = pcall(get_diagnostics_data, i)
    if ok then
      vim.list_extend(diagnostics, diag)
    end
  end

  return diagnostics
end

--- Flattens the result of buf_request_sync/buf_request_all
--- and injects client_id on each item to allow use to get the client later
--- if needed like for code_actions
---@param results_lsp table<integer, { err?: (lsp.ResponseError)?; error?: (lsp.ResponseError)?; result: table|any[]; context?: lsp.HandlerContext }>?
---@return lsp.Location[]|lsp.LocationLink[]|lsp.DocumentSymbol[]|lsp.SymbolInformation[]|lsp.WorkspaceSymbol[]|lsp.CodeAction[]
local function extract_result(results_lsp)
  if results_lsp then
    local results = {}
    for client_id, response in pairs(results_lsp) do
      if response.result then
        ---@type any[]
        local res = vim.isarray(response.result) and response.result or { response.result }
        for _, result in pairs(res) do
          result.client_id = client_id
          table.insert(results, result)
        end
      end
    end

    return results
  end

  return {}
end

---Call lsp method
---@param method vim.lsp.protocol.Method.ClientToServer.Request LSP method name.
---@param params any params for the lsp method following the spec
---@param opts fzf_lsp.CommonOpts options for the method
---@param handler lsp.Handler handler function
---@param client vim.lsp.Client
local function call_lsp_method(method, params, opts, handler, client)
  params = params or {}
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  -- Sync request
  if opts.sync then
    local results_lsp, err_msg = vim.lsp.buf_request_sync(bufnr, method, params, opts.timeout or g.fzf_lsp_timeout)

    local ctx = {
      method = method,
      bufnr = bufnr,
      client_id = results_lsp and next(results_lsp) or (client.id or nil),
      opts = opts,
    }

    local err = nil
    if results_lsp then
      local _, first_v = next(results_lsp)
      ---@diagnostic disable-next-line: undefined-field
      err = first_v and (first_v.error or first_v.err) or nil
    elseif type(err_msg) == "string" then
      err = {
        message = err_msg,
        code = wait_result_reason[err_msg],
      }
    end

    return handler(err, extract_result(results_lsp), ctx, nil)
  end

  -- Async request
  vim.lsp.buf_request_all(bufnr, method, params, function(results, context, config)
    local err = nil
    if results then
      local _, first_v = next(results)
      err = first_v and first_v.err or nil
    end
    ---@diagnostic disable-next-line: inject-field
    context.opts = opts
    handler(err, extract_result(results), context, config)
  end)

  -- single client version
  -- client:request(method, params, function (err, result, context, config)
  --   local results = {}
  --   for _, res in pairs(result) do
  --     res.client_id = client.id
  --     table.insert(results, result)
  --   end
  --
  --   handler(err, results, context, config)
  -- end, bufnr)
end

---Check if any lsp client supports the given method
---@param provider string Method to check in the available lsps
---@param bufnr? integer Buffer from where to requests lsps
---@return vim.lsp.Client? Client that supports the method
local function find_client_with_provider(provider, bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr or 0 })

  if #clients == 0 then
    vim.notify("[fzf_lsp] No client attached", vim.log.levels.INFO)
    return
  end

  for _, client in pairs(clients) do
    if client:supports_method(provider, bufnr) then
      return client
    end
  end

  vim.notify("[fzf_lsp] no server supports " .. provider, vim.log.levels.INFO)
end

---Execute code action
---@param action lsp.CodeAction
---@param client vim.lsp.Client
---@param bufnr? integer bufnr from lsp response context
local function code_action_execute(action, client, bufnr)
  local offset_encoding = client.offset_encoding

  -- Ref: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeAction
  --
  -- > /**
  -- > * A command this code action executes. If a code action
  -- > * provides an edit and a command, first the edit is
  -- > * executed and then the command.
  -- > */
  -- > command?: Command;
  --
  -- So first execute the edit, then the command

  if action.edit or type(action.command) == "table" then
    -- First execute the action
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, offset_encoding)
    end

    -- Then the command
    if type(action.command) == "table" then
      -- Previous method (deprecated)
      -- vim.lsp.buf.execute_command(action.command)
      --
      -- What client:exec_cmd does
      --
      -- --- @type lsp.ExecuteCommandParams
      -- local params = {
      --   command = cmdname,
      --   arguments = command.arguments,
      -- }
      -- client:request('workspace/executeCommand', params, nil, bufnr)

      client:exec_cmd(action.command, { bufnr = bufnr }, function(err, result, context, config)
        -- Does result matter here?
        if err then
          vim.notify(("Error on command for action %s"):format(action.title), vim.log.levels.ERROR)
        end
      end)
    end
  else
    -- Previous method (deprecated)
    -- vim.lsp.buf.execute_command(action)
    client:exec_cmd(action --[[@as lsp.Command]])
  end
end

---@type fzf_lsp.JoinLocFunc
local function joinloc_raw(loc, idx, include_filename)
  return string.format(
    "%d %s%d:%d: %s",
    idx,
    fnamemodify(loc["filename"], include_filename),
    loc["lnum"],
    loc["col"],
    vim.trim(loc["text"])
  )
end

---@type fzf_lsp.JoinLocFunc
local function joinloc_pretty(loc, idx, include_filename)
  local width = g.fzf_lsp_width
  local text = vim.trim(loc["text"]:gsub("%b[]", ""))

  return string.format(
    "%d \x01 %s %s%s\x01 %s%d:%d:",
    idx,
    align_str(truncate(text, width), width),
    colored_kind(loc["kind"]),
    string.rep(" ", 50),
    fnamemodify(loc["filename"], include_filename),
    loc["lnum"],
    loc["col"]
  )
end

---@alias fzf_lsp.JoinDiaFunc fun(entry: vim.quickfix.entry, idx: integer, include_filename: boolean): string
---@alias fzf_lsp.JoinLocFunc fun(loc: vim.quickfix.entry, idx: integer, include_filename: boolean): string
---@alias fzf_lsp.ExtLocFunc fun(line: string, idx: integer, data: fzf_lsp.fzf_locations_data, include_filename: boolean): vim.quickfix.entry

---@type fzf_lsp.JoinDiaFunc
local function joindiag_raw(e, idx, include_filename)
  return string.format(
    "%d %s%d:%d: %s: %s",
    idx,
    fnamemodify(e["filename"], include_filename),
    e["lnum"],
    e["col"],
    e["type"],
    e["text"]:gsub("%s", " ")
  )
end

---@type fzf_lsp.JoinDiaFunc
local function joindiag_pretty(e, idx, include_filename)
  return string.format(
    "%d \x01 %s: %s\x01 %s%d:%d:",
    idx,
    e["type"],
    e["text"]:gsub("%s", " "),
    fnamemodify(e["filename"], include_filename),
    e["lnum"],
    e["col"]
  )
end

---Get lines to display in fzf
---@param locations vim.quickfix.entry[] List of locations in quickfix format
---@param include_filename boolean whether or not to include the filename
---@return string[] list List of lines to show in fzf
local function lines_from_locations(locations, include_filename)
  local joinfn = g.fzf_lsp_pretty and joinloc_pretty or joinloc_raw

  local lines = {}
  for idx, loc in ipairs(locations) do
    table.insert(lines, joinfn(loc, idx, include_filename))
  end

  return lines
end

---Get lines to display in fzf
---@param lines string[] List of locations in quickfix format
---@param data fzf_lsp.fzf_locations_data Context data
---@return vim.quickfix.entry[] list quickfix information
local function locations_from_lines(lines, data)
  -- local is_diag = data.diagnostics ~= nil
  ---@type vim.quickfix.entry[]
  local src = data.locs or {}
  local locations = {}

  for _, line in ipairs(lines) do
    local idx = assert(tonumber(vim.split(line, " ")[1]), "Could not recover index")
    locations[#locations + 1] = assert(src[idx], "Missing item from source")
  end

  return locations
end

---Convert completions into a readable format for fzf
---@param completions lsp.CompletionItem[]
---@return string[]
local function lines_from_completions(completions)
  local lbl_template = "%d. %s%s"
  local detail_template = "- %s"
  ---@type string[]
  local items = {}
  for i, c in ipairs(completions) do
    local label = c.labelDetails or c.label
    local detail = c.detail and detail_template:format(c.detail) or ""
    items[#items + 1] = lbl_template:format(i, label, detail)
  end

  return items
end

---Check the response and allow the user to choose one option for the
---call hierarchy request
---@param call_hierarchy_items lsp.CallHierarchyItem[]
---@return lsp.CallHierarchyItem|nil item from the call hierarchy response
local function pick_call_hierarchy_item(call_hierarchy_items)
  if not call_hierarchy_items then
    return
  end
  if #call_hierarchy_items == 1 then
    return call_hierarchy_items[1]
  end
  local items = {}
  for i, item in ipairs(call_hierarchy_items) do
    local entry = item.detail or item.name
    table.insert(items, string.format("%d. %s", i, entry))
  end
  local choice = vim.fn.inputlist(items)
  if choice < 1 or choice > #items then
    return
  end
  return call_hierarchy_items[choice]
end

---Request call hierarchy request
---@param method "callHierarchy/incomingCalls"|"callHierarchy/outgoingCalls"
---@param handler lsp.Handler
---@param err lsp.ResponseError?
---@param result lsp.CallHierarchyItem[]
---@param ctx fzf_lsp.HandlerContext
---@param _config? table
local function prepare_call_hierarchy_handler(method, handler, err, result, ctx, _config)
  if err then
    vim.notify(err.message, vim.log.levels.WARN)
    return
  end
  local call_hierarchy_item = pick_call_hierarchy_item(result)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client then
    vim.notify(
      string.format("Client with id=%d disappeared during call hierarchy request", ctx.client_id),
      vim.log.levels.WARN
    )
    return
  end

  local opts = ctx.opts or {}

  -- Sync request
  if opts.sync then
    local results, err_msg =
      client:request_sync(method, { item = call_hierarchy_item }, opts.timeout or g.fzf_lsp_timeout, ctx.bufnr)

    ---@type fzf_lsp.HandlerContext
    local context = {
      method = method,
      bufnr = ctx.bufnr,
      client_id = client.id,
      opts = opts,
    }

    local error = nil
    local lsp_result = nil

    if results then
      error = results.err
      lsp_result = results.result
    elseif type(error) == "string" then
      error = { code = wait_result_reason[err_msg], message = err_msg }
    end

    return handler(err, lsp_result, context)
  end

  -- Async request
  client:request(method, { item = call_hierarchy_item }, function(err, result, context, config)
    ---@diagnostic disable-next-line: inject-field
    context.opts = opts
    handler(err, result, context, config)
  end, ctx.bufnr)
end

---Location handler for lsp methods
---@param err? lsp.ResponseError
---@param locations lsp.Location|lsp.LocationLink|lsp.Location[]|lsp.LocationLink[]
---@param ctx lsp.HandlerContext
---@param _ table?
---@param error_message string message to show on error
---@return vim.quickfix.entry[]|nil
local function location_handler(err, locations, ctx, _, error_message)
  if err ~= nil then
    perror(err)
    return
  end

  if not locations or vim.tbl_isempty(locations) then
    vim.notify(error_message, vim.log.levels.INFO)
    return
  end

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client then
    return
  end

  if vim.islist(locations) then
    if #locations == 1 then
      -- Single location. Focus and return
      vim.lsp.util.show_document(locations[1], client.offset_encoding, { focus = true })

      return
    end
  else
    -- Single location. Focus and return
    vim.lsp.util.show_document(locations, client.offset_encoding, { focus = true })
    return
  end

  return vim.lsp.util.locations_to_items(locations, client.offset_encoding)
end

---Handler for call hierarchy methods
---@param direction "to"|"from"
---@param err? lsp.ResponseError
---@param result lsp.CallHierarchyIncomingCall[]|lsp.CallHierarchyOutgoingCall[]
---@param ctx lsp.HandlerContext
---@param _ table?
---@param error_message string message to show on error
---@return vim.quickfix.entry[]|nil
local function call_hierarchy_handler(direction, err, result, ctx, _, error_message)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    vim.notify(error_message, vim.log.levels.INFO)
    return
  end

  ---@type vim.lsp.Client?
  local client = (ctx and ctx.client_id ~= nil) and vim.lsp.get_client_by_id(ctx.client_id)
    or vim.lsp.get_clients({ bufnr = 0 })[1]

  local encoding = "utf-16"
  if client ~= nil then
    encoding = client.offset_encoding
  end

  ---@type vim.quickfix.entry[]
  local items = {}
  for _, call_hierarchy_call in pairs(result) do
    ---@type lsp.CallHierarchyItem
    local call_hierarchy_item = call_hierarchy_call[direction]
    -- TODO: explore how to use .fromRanges
    -- for _, range in pairs(call_hierarchy_call.fromRanges) do
    local range = assert(call_hierarchy_item.selectionRange)
    local uri = assert(call_hierarchy_item.uri)
    local filename = assert(vim.uri_to_fname(uri))
    local bufnr = assert(vim.uri_to_bufnr(uri))
    -- Ensure buffer is loaded to get content
    vim.fn.bufload(bufnr)

    -- vim.print("range:", range)
    -- vim.print("buff:", bufnr)
    -- vim.print("filename:", filename)
    local sline = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, false)[1]
    local eline = vim.api.nvim_buf_get_lines(bufnr, range["end"].line, range["end"].line + 1, false)[1]
    local col = vim.str_byteindex(sline, encoding, range.start.character, false) + 1
    local end_col = vim.str_byteindex(eline, encoding, range["end"].character, false) + 1

    table.insert(items, {
      bufnr = bufnr,
      filename = filename,
      lnum = range.start.line + 1,
      end_lnum = range["end"].line + 1,
      col = col,
      end_col = end_col,
      text = call_hierarchy_item.name,
      user_data = {
        item = call_hierarchy_item,
        direction = direction,
      },

      -- Non-used props
      -- module = ...,
      -- pattern = ...,
      -- vcol = ...,
      -- type = ...,
      -- valid = ...,
    } --[[@as vim.quickfix.entry]])
  end

  return items
end

---Handler for snippets completion request
---comment
---@param err? lsp.ResponseError
---@param completions (lsp.CompletionList|lsp.CompletionItem[])[]
---@param ctx lsp.HandlerContext
---@param _ table?
---@param error_message string message to show on error
---@return lsp.CompletionItem[]|nil
local function snippets_completion_handler(err, completions, ctx, _, error_message)
  if err then
    perror(err)
    return
  end

  if not completions or vim.tbl_isempty(completions) then
    vim.notify(error_message, vim.log.levels.INFO)
    return
  end

  ---@type lsp.CompletionItem[]
  local filtered = vim.iter(completions)
    :map(function(entry)
      ---@cast entry lsp.CompletionItem[]|lsp.CompletionList
      return entry.items and entry.items or entry
    end)
    :flatten(1)
    :filter(function(c)
      ---@cast c lsp.CompletionItem
      -- 15 is 'snippet' kind for completions
      return c.kind == 15
    end)
    :totable()

  if #filtered == 0 then
    vim.notify(error_message, vim.log.levels.INFO)
    return
  end

  return filtered
end

local call_hierarchy_handler_from = partial(call_hierarchy_handler, "from")
local call_hierarchy_handler_to = partial(call_hierarchy_handler, "to")
---@type fun(handler: lsp.Handler, err: lsp.ResponseError?, result: lsp.CallHierarchyIncomingCall[], ctx: lsp.HandlerContext)
local prepare_call_hierarchy_handler_from = partial(prepare_call_hierarchy_handler, methods.incomingCalls)
---@type fun(handler: lsp.Handler, err: lsp.ResponseError, result: lsp.CallHierarchyOutgoingCall[], ctx: lsp.HandlerContext)
local prepare_call_hierarchy_handler_to = partial(prepare_call_hierarchy_handler, methods.outgoingCalls)

-- }}}

-- FZF functions {{{
local function fzf_wrap(name, opts, bang)
  name = name or ""
  opts = opts or {}
  bang = bang or 0

  if g.fzf_lsp_layout then
    opts = vim.tbl_extend("keep", opts, g.fzf_lsp_layout)
  end

  if g.fzf_lsp_colors then
    vim.list_extend(opts.options, { "--color", g.fzf_lsp_colors })
  end

  local sink_fn = opts["sink*"] or opts["sink"]
  if sink_fn ~= nil then
    opts["sink"] = nil
    opts["sink*"] = 0
  else
    -- if no sink function is given i automatically put the actions
    if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
      vim.list_extend(opts.options, { "--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",") })
    end
  end
  local wrapped = fn["fzf#wrap"](name, opts, bang)
  wrapped["sink*"] = sink_fn

  return wrapped
end

local function fzf_run(...)
  return fn["fzf#run"](...)
end

---Jump to the given location
---@param location vim.quickfix.entry
---@param data fzf_lsp.fzf_locations_data
local function jump_to_location(location, data)
  local uri = vim.uri_from_fname(location.filename)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr) -- ensure buffer is loaded into memory or buffer will be empty

  ---@type vim.lsp.Client?
  local client = (data.ctx and data.ctx.client_id ~= nil) and vim.lsp.get_client_by_id(data.ctx.client_id)
    or vim.lsp.get_clients({ bufnr = 0 })[1]

  local encoding = "utf-16"
  if client ~= nil then
    encoding = client.offset_encoding
  end

  -- Convert back a quickfix entry style to lsp.Location
  local start_line = location.lnum - 1
  local end_line = location.end_lnum - 1
  local start_line_content = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, false)[1] or ""
  local end_line_content = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
  local start_col = vim.str_utfindex(start_line_content, encoding, location.col - 1, false)
  local end_col = vim.str_utfindex(end_line_content, encoding, location.end_col - 1, false)
  --    ^
  -- Samples
  -- if "e" is col "line 918 and col 9" and pos "line 917 and col 8", then
  -- from col to lsp.character
  -- =vim.str_utfindex(vim.api.nvim_buf_get_lines(31, 918, 919, false)[1], "utf-16", 9 - 1, false)
  -- from lsp.character to col
  -- =vim.str_byteindex(vim.api.nvim_buf_get_lines(31, 918, 919, false)[1], "utf-16", 8, false) + 1

  -- Load buffer and jump to it
  -- local uri = vim.uri_from_fname(vim.fn.fnamemodify("nvimw", ":p"))
  -- local bufnr = vim.uri_to_bufnr(uri)
  -- =vim.fn.bufload(<bufnr>)
  -- =vim.lsp.util.show_document({ uri = uri, range = { ["start"] = { line = 3, character = 0 }, ["end"] = { line = 3, character = 8 } } }, "utf-16", { focus = true })

  ---@type lsp.Location
  local lspLocation = {
    uri = uri,
    range = {
      ["start"] = { line = start_line, character = start_col },
      ["end"] = { line = end_line, character = end_col },
    },
  }

  vim.lsp.util.show_document(lspLocation, encoding, { focus = true })
end

---Common sync function for fzf
---@param data fzf_lsp.fzf_locations_data Context data for sink
---@param title string title of the fzf call which can be used to identify the call
---@param lines string[] response from selection in fzf
local function common_sink(data, title, lines)
  local action
  local key
  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    key = table.remove(lines, 1)
    action = g.fzf_lsp_action[key]
  end

  local locations = locations_from_lines(lines, data)
  if action == nil and #lines > 1 then
    vim.fn.setqflist({}, " ", {
      title = title or "Language Server",
      items = locations,
    })
    api.nvim_command("copen")
    api.nvim_command("wincmd p")

    return
  end

  action = action or "e"

  -- Jump to location if edit action
  if action == "e" or action == "edit" then
    for _, loc in ipairs(locations) do
      jump_to_location(loc, data)
      api.nvim_command("normal! zv")
    end
    return
  end

  -- Action is command
  -- Due to limitations we pass the filename only
  if type(action) == "string" and vim.fn.exists(":" .. action) > 0 then
    for _, loc in ipairs(locations) do
      local err = api.nvim_command(action .. " " .. loc["filename"])
      if err ~= nil then
        api.nvim_command("echoerr " .. err)
      end
    end
    return
  end

  -- Action is lua function
  if key ~= nil and type(action) == "function" then
    local ok, err = pcall(function()
      action({ locatios = locations, data = data, action_type = title })
    end)

    if not ok and err ~= nil then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  -- Action may be a VimL funcref
  if key ~= nil and action == vim.NIL then
    -- Sample hack
    -- _G.test_f = {
    --   foo = function() return "from lua" end
    -- }
    -- vim.cmd([[
    --   func! s:Foo(arg) abort
    --     echo a:arg
    --   endf
    --   let g:foo = { "a": function("s:Foo") }
    --   call g:foo.a(v:lua.test_f.foo())
    -- ]])

    --- HACK:
    --- build temporary global functions
    --- it should not clash with anything... I hope
    _G._fzf_lsp_args_data = function()
      return { location = locations, data = data, action_type = title }
    end
    _G._fzf_lsp_args_key = function()
      return key
    end

    local ok, err = pcall(function()
      vim.cmd([[
        " The global functions are able to send back data to VimL 😄
        call g:fzf_lsp_action[v:lua._fzf_lsp_args_key()](v:lua._fzf_lsp_args_data())
      ]])
    end)

    if not ok and err ~= nil then
      vim.notify(err, vim.log.levels.ERROR)
    end

    -- cleanup
    _G._fzf_lsp_args_data = nil
    _G._fzf_lsp_args_key = nil
    return
  end

  -- legacy pre fix for https://github.com/gfanto/fzf-lsp.nvim/pull/40
  -- This should be unreachable
  vim.notify("[fzf_lsp] using legacy handler for actions")
  for _, loc in ipairs(locations) do
    local edit_infile = (
      (data.infile or fn.expand("%:~:.") == loc["filename"]) and (action == "e" or action == "edit")
    )
    -- if i'm editing the same file i'm in, i can just move the cursor
    if not edit_infile then
      -- otherwise i can start executing the actions
      local err = api.nvim_command(action .. " " .. loc["filename"])
      if err ~= nil then
        api.nvim_command("echoerr " .. err)
      end
    end

    fn.cursor(loc["lnum"], loc["col"])
    api.nvim_command("normal! zvzz")
  end
end

---Common sync function for fzf
---@param data fzf_lsp.completion.data Context data for sink
---@param title string title of the fzf call which can be used to identify the call
---@param lines string[] response from selection in fzf
local function completion_sink(data, title, lines)
  -- Remove first entry as that is for an expect key
  -- TODO: handle expected key?
  -- table.remove(lines, 1)

  for _, line in ipairs(lines) do
    local idx = tonumber(line:match("(%d+)[.]")) -- e.g. "1. Some action"

    pcall(data.on_choice, idx, line)
  end
end

local function fzf_ui_select(items, opts, on_choice)
  local prompt = opts.prompt or "Select one of:"
  local format_item = opts.format_item or tostring

  local source = {}
  for i, item in pairs(items) do
    table.insert(source, string.format("%d: %s", i, format_item(item)))
  end

  local function sink_fn(lines)
    local _, line = next(lines)
    local choice = -1
    for i, s in pairs(source) do
      if s == line then
        choice = i
        goto continue
      end
    end

    ::continue::
    if choice < 1 then
      on_choice(nil, nil)
    else
      on_choice(items[choice], choice)
    end
  end

  fzf_run(fzf_wrap("fzf_lsp_choice", {
    source = source,
    sink = sink_fn,
    options = {
      "--prompt",
      prompt .. " ",
      "--ansi",
    },
  }, 0))
end

---Get common fzf options
---@param opts { prompt?: string; header?: string }
---@return { options: string[]; name: string }
local function get_fzf_opts(opts)
  opts = opts or {}
  local prompt = opts.prompt or ""
  local header = opts.header or ""

  local options = {
    "--cycle",
    "--ansi",
    "--bind",
    "ctrl-a:select-all,ctrl-d:deselect-all",
    "--bind",
    "alt-up:preview-page-up,alt-down:preview-page-down",
    "--bind",
    "alt-a:select-all,alt-d:deselect-all",
    "--bind",
    "alt-f:first",
    "--bind",
    "alt-l:last",
    "--bind",
    "alt-a:select-all",
    "--bind",
    "alt-d:deselect-all",
    "--bind",
    "ctrl-l:change-preview-window(down|hidden|)",
  }
  local name = "fzf_lsp"
  if string.len(prompt) > 0 then
    table.insert(options, "--prompt")
    table.insert(options, prompt .. "> ")
    name = name .. "_" .. prompt
  end
  if string.len(header) > 0 then
    table.insert(options, "--header")
    table.insert(options, header)
  end

  -- Use powershell to execute fzf
  if is_windows then
    table.insert(options, "--with-shell")
    table.insert(options, "powershell.exe -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -Command")
  end

  return {
    options = options,
    name = name,
  }
end

---Show fzf with the list of locations
---@param bang 0|1 fzf fullscreen option. 1 for fullscreen, default 0.
---@param header string header to show in fzf `--header`
---@param prompt string prompt to show in fzf `--prompt`
---@param source string[] lines to show in fzf
---@param data fzf_lsp.fzf_locations_data
local function fzf_locations(bang, header, prompt, source, data)
  local preview_cmd
  if g.fzf_lsp_pretty then
    preview_cmd = (data.infile and (bin.preview .. " " .. fn.expand("%") .. ":{-1}") or (bin.preview .. " {-1}"))
  else
    preview_cmd = (data.infile and (bin.preview .. " " .. fn.expand("%") .. ":{2..}") or (bin.preview .. " {2..}"))
  end

  local fzf_opts = get_fzf_opts({ header = header, prompt = prompt })
  local name = fzf_opts.name
  local options = fzf_opts.options

  vim.list_extend(options { "--multi", "--with-nth", "2.." })

  if g.fzf_lsp_pretty then
    vim.list_extend(options, { "--delimiter", "\x01 ", "--nth", "1" })
  end

  if g.fzf_lsp_action and not vim.tbl_isempty(g.fzf_lsp_action) then
    vim.list_extend(options, { "--expect", table.concat(vim.tbl_keys(g.fzf_lsp_action), ",") })
  end

  if g.fzf_lsp_preview_window then
    if #g.fzf_lsp_preview_window == 0 then
      g.fzf_lsp_preview_window = { "hidden" }
    end

    vim.list_extend(options, { "--preview-window", g.fzf_lsp_preview_window[1] })
    if #g.fzf_lsp_preview_window > 1 then
      local preview_bindings = {}
      for i = 2, #g.fzf_lsp_preview_window, 1 do
        table.insert(preview_bindings, g.fzf_lsp_preview_window[i] .. ":toggle-preview")
      end
      vim.list_extend(options, { "--bind", table.concat(preview_bindings, ",") })
    end
  end

  vim.list_extend(options, { "--preview", preview_cmd })

  -- Allow to override flags passed to fzf command
  if g.fzf_lsp_override_opts and vim.islist(g.fzf_lsp_override_opts) and #g.fzf_lsp_override_opts > 0 then
    vim.list_extend(options, g.fzf_lsp_override_opts)
  end

  if data.ctx and data.ctx.opts and vim.islist(data.ctx.opts.fzf_opts) and #data.ctx.opts.fzf_opts > 0 then
    vim.list_extend(options, data.ctx.opts.fzf_opts)
  end

  fzf_run(fzf_wrap(name, {
    source = source,
    sink = partial(common_sink, data, prompt),
    options = options,
  }, bang))
end

---Show code actions in fzf
---@param bang 0|1
---@param header string string to show as header in fzf
---@param prompt string string to show as prompt in fzf
---@param actions fzf_lsp.InjectedCodeAction[]
---@param bufnr? integer bufnr from lsp response context
local function fzf_code_actions(bang, header, prompt, actions, bufnr)
  local lines = {}
  for i, a in ipairs(actions) do
    lines[i] = i .. ". " .. a["title"]
  end

  local sink_fn = function(source)
    local _, line = next(source)
    if not line then
      return
    end
    local idx = tonumber(line:match("(%d+)[.]")) -- e.g. "1. Some action"
    local action = actions[idx]
    local client = vim.lsp.get_client_by_id(action.client_id) -- This requires the custom injected property from extract_result

    -- About codeAction/resolve
    -- > The request is sent from the client to the server to resolve additional
    -- > information for a given code action.
    -- > This is usually used to compute the edit property of a code action to avoid
    -- > its unnecessary computation during the textDocument/codeAction request.
    -- Ref: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeAction_resolve

    -- TODO: should it use this directly? if there is a client back,
    -- it must have a resolveProvider
    -- vim.lsp.get_clients({ id = action.client_id, method = vim.lsp.protocol.Methods.codeAction_resolve })

    if
      not action.edit
      and client
      and type(client.server_capabilities.codeActionProvider) == "table"
      and client.server_capabilities.codeActionProvider.resolveProvider
    then
      -- TODO: should we use below instead of hardcoded string?
      -- May affect old nvim version so better to wait a bit e.g. nvim-0.14
      -- vim.lsp.protocol.Methods.textDocument_codeAction

      ---@param resolved_err lsp.ResponseError|nil
      ---@param resolved_action lsp.CodeAction|nil
      client:request(methods.resolveCodeAction, action, function(resolved_err, resolved_action)
        if resolved_err then
          vim.notify(resolved_err.code .. ": " .. resolved_err.message, vim.log.levels.ERROR)
          return
        end
        if resolved_action then
          code_action_execute(resolved_action, client, bufnr)
        else
          code_action_execute(action, client, bufnr)
        end
      end)
    else
      if not client then
        return
      end
      code_action_execute(action, client, bufnr)
    end
  end

  local opts = { "--ansi" }
  if string.len(prompt) > 0 then
    table.insert(opts, "--prompt")
    table.insert(opts, prompt .. "> ")
  end
  if string.len(header) > 0 then
    table.insert(opts, "--header")
    table.insert(opts, header)
  end
  fzf_run(fzf_wrap("fzf_lsp_code_actions", {
    source = lines,
    sink = sink_fn,
    options = opts,
  }, bang))
end

---Show completions from lsp sources
---@param bang 0|1
---@param header string string to show as header in fzf
---@param prompt string string to show as prompt in fzf
---@param items string[] items to display in fzf
---@param data fzf_lsp.completion.data
local function fzf_completions(bang, header, prompt, items, data)
  local fzf_opts = get_fzf_opts({ header = header, prompt = prompt })
  local options = fzf_opts.options
  local name = fzf_opts.name

  -- vim.list_extend(options, { '--no-multi' }, start?, finish?)
  table.insert(options, '--no-multi')

  fzf_run(fzf_wrap(name, {
    source = items,
    sink = partial(completion_sink, data, prompt),
    options = options,
  }, bang))
end
-- }}}

-- LSP reponse handlers {{{

---@type fzf_lsp.LspHandler
local function code_action_handler(bang, err, result, ctx, _)
  ---@cast result fzf_lsp.InjectedCodeAction
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    vim.notify("Code Action not available", vim.log.levels.INFO)
    return
  end

  local bufnr = ctx.bufnr
  fzf_code_actions(bang, "", "Code Actions", result, bufnr)
end

---@type fzf_lsp.LspHandler
local function snippets_handler(bang, err, result, ctx, config)
  local completions = snippets_completion_handler(err, result, ctx, config, "No snippets provided by client")
  if completions and not vim.tbl_isempty(completions) then
    local lines = lines_from_completions(completions)
    ---@type fzf_lsp.completion.data
    local data = {
      results = completions,
      ctx = ctx,
      config = config,
      on_choice = vim.schedule_wrap(function(idx, _)
        local snippet = completions[idx]

        if snippet.textEdit then
          vim.snippet.expand(snippet.textEdit.newText)
        elseif snippet.insertText then
          vim.snippet.expand(snippet.insertText)
        end
      end),
    }
    fzf_completions(bang, "", "Snippets", lines, data)
  end
end
local function definition_handler(bang, err, result, ctx, config)
  local locs = location_handler(err, result, ctx, config, "Definition not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
    fzf_locations(bang, "", "Definitions", lines, data)
  end
end

---@type fzf_lsp.LspHandler
local function declaration_handler(bang, err, result, ctx, config)
  local locs = location_handler(err, result, ctx, config, "Declaration not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, infile = false }
    fzf_locations(bang, "", "Declarations", lines, data)
  end
end

---@type fzf_lsp.LspHandler
local function type_definition_handler(bang, err, result, ctx, config)
  local locs = location_handler(err, result, ctx, config, "Type Definition not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
    fzf_locations(bang, "", "Type Definitions", lines, data)
  end
end

---@type fzf_lsp.LspHandler
local function implementation_handler(bang, err, result, ctx, config)
  local locs = location_handler(err, result, ctx, config, "Implementation not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
    fzf_locations(bang, "", "Implementations", lines, data)
  end
end

---@type fzf_lsp.LspHandler
local function references_handler(bang, err, result, ctx, config)
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    vim.notify("References not found", vim.log.levels.INFO)
    return
  end

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  ---@type string
  local encoding = ""

  if not client then
    vim.notify("Could not find the client with id: " .. ctx.client_id, vim.log.levels.WARN)
    -- Default to utf-16 if there is no client?
    encoding = "utf-16"
  else
    encoding = client.offset_encoding
  end

  local locs = vim.lsp.util.locations_to_items(result, encoding)
  local lines = lines_from_locations(locs, true)

  local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
  fzf_locations(bang, "", "References", lines, data)
end

---@type fzf_lsp.LspHandler
local function document_symbol_handler(bang, err, result, ctx, config)
  ---@cast result lsp.DocumentSymbol[]
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    vim.notify("Document Symbol not found", vim.log.levels.INFO)
    return
  end

  ---@type string
  local encoding = ""
  local client = vim.lsp.get_client_by_id(ctx.client_id)

  if not client then
    vim.notify("Could not find the client with id: " .. ctx.client_id, vim.log.levels.WARN)
    -- Default to utf-16 if there is no client?
    encoding = "utf-16"
  else
    encoding = client.offset_encoding
  end

  local locs = vim.lsp.util.symbols_to_items(result, ctx.bufnr or 0, encoding)
  local lines = lines_from_locations(locs, false)
  local data = { results = result, ctx = ctx, config = config, locs = locs, infile = true }
  fzf_locations(bang, "", "Document Symbols", lines, data)
end

---@type fzf_lsp.LspHandler
local function workspace_symbol_handler(bang, err, result, ctx, config)
  ---@cast result lsp.WorkspaceSymbol[]
  if err ~= nil then
    perror(err)
    return
  end

  if not result or vim.tbl_isempty(result) then
    vim.notify("Workspace Symbol not found", vim.log.levels.INFO)
    return
  end

  ---@type string
  local encoding = ""
  local client = vim.lsp.get_client_by_id(ctx.client_id)

  if not client then
    vim.notify("Could not find the client with id: " .. ctx.client_id, vim.log.levels.WARN)
    -- Default to utf-16 if there is no client?
    encoding = "utf-16"
  else
    encoding = client.offset_encoding
  end

  local locs = vim.lsp.util.symbols_to_items(result, ctx.bufnr or 0, encoding)
  local lines = lines_from_locations(locs, true)
  local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
  fzf_locations(bang, "", "Workspace Symbols", lines, data)
end

---@type fzf_lsp.LspHandler
local function incoming_calls_handler(bang, err, result, ctx, config)
  ---@cast result lsp.CallHierarchyIncomingCall[]
  local locs = call_hierarchy_handler_from(err, result, ctx, config, "Incoming calls not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
    fzf_locations(bang, "", "Incoming Calls", lines, data)
  end
end

---@type fzf_lsp.LspHandler
local function outgoing_calls_handler(bang, err, result, ctx, config)
  ---@cast result lsp.CallHierarchyOutgoingCall[]
  local locs = call_hierarchy_handler_to(err, result, ctx, config, "Outgoing calls not found")
  if locs and not vim.tbl_isempty(locs) then
    local lines = lines_from_locations(locs, true)
    local data = { results = result, ctx = ctx, config = config, locs = locs, infile = false }
    fzf_locations(bang, "", "Outgoing Calls", lines, data)
  end
end
-- }}}

---notify there are no clients available
---@param method string
local function notify_no_clients(method)
  vim.notify(string.format('No lsp client available for "%s" method', method), vim.log.levels.WARN)
end

-- COMMANDS {{{

---@type fzf_lsp.LspMethodCall
function M.snippets(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.completion)
  -- vim.lsp.completion.enable()
  if not client then
    notify_no_clients(methods.completion)
    return
  end

  -- Ref: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion
  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.completion, params, opts, partial(snippets_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.definition(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.definition)
  if not client then
    notify_no_clients(methods.definition)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.definition, params, opts, partial(definition_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.declaration(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.declaration)
  if not client then
    notify_no_clients(methods.declaration)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.declaration, params, opts, partial(declaration_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.type_definition(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.typeDefinition)
  if not client then
    notify_no_clients(methods.typeDefinition)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.typeDefinition, params, opts, partial(type_definition_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.implementation(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.implementation)
  if not client then
    notify_no_clients(methods.implementation)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.implementation, params, opts, partial(implementation_handler, bang), client)
end

-- TODO: Use somthing like vim.tbl_extend to avoid the inject-field warning

---@type fzf_lsp.LspMethodCall
function M.references(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.references)
  if not client then
    notify_no_clients(methods.references)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  ---@diagnostic disable-next-line: inject-field
  params.context = { includeDeclaration = true }
  call_lsp_method(methods.references, params, opts, partial(references_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.document_symbol(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.documentSymbol)
  if not client then
    notify_no_clients(methods.documentSymbol)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_position_params(0, encoding)
  call_lsp_method(methods.documentSymbol, params, opts, partial(document_symbol_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.workspace_symbol(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.workspaceSymbol)
  if not client then
    notify_no_clients(methods.workspaceSymbol)
    return
  end

  local params = { query = opts.query or "" }
  call_lsp_method(methods.workspaceSymbol, params, opts, partial(workspace_symbol_handler, bang), client)
end

---Call lsp method
---@param opts fzf_lsp.CommonOpts options for the method
---@param handler fun(err: lsp.ResponseError?, result: lsp.CallHierarchyIncomingCall[]|lsp.CallHierarchyOutgoingCall[]?, ctx: lsp.HandlerContext, config?: table)
---@param client vim.lsp.Client
local function prepare_call_method(opts, handler, client)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  local encoding = client.offset_encoding
  ---@type lsp.CallHierarchyPrepareParams
  local params = vim.lsp.util.make_position_params(0, encoding) --[[@as lsp.CallHierarchyPrepareParams]]

  -- Sync request
  if opts.sync then
    local results, error =
      client:request_sync(methods.prepareCallHierarchy, params, opts.timeout or g.fzf_lsp_timeout, bufnr)

    ---@type fzf_lsp.HandlerContext
    local ctx = {
      method = methods.prepareCallHierarchy,
      bufnr = bufnr,
      client_id = client.id,
      opts = opts,
    }

    local err = nil
    local result = nil

    if results then
      err = results.err
      result = results.result
    elseif type(error) == "string" then
      err = { code = wait_result_reason[error], message = error }
    end

    return handler(err, result, ctx)
  end

  -- Async request
  client:request(methods.prepareCallHierarchy, params, function(err, results, ctx, _config)
    ---@diagnostic disable-next-line: inject-field
    ctx.opts = opts

    handler(err, results, ctx)
  end, bufnr)
end

---@type fzf_lsp.LspMethodCall
function M.incoming_calls(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.prepareCallHierarchy)
  if not client then
    notify_no_clients(methods.prepareCallHierarchy)
    return
  end

  -- NOTE: Need to build a secondary handler because calls require to requests

  ---@type lsp.Handler
  local next_handler = partial(incoming_calls_handler, bang)
  prepare_call_method(opts, partial(prepare_call_hierarchy_handler_from, next_handler), client)
end

---@type fzf_lsp.LspMethodCall
function M.outgoing_calls(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.prepareCallHierarchy)
  if not client then
    notify_no_clients(methods.prepareCallHierarchy)
    return
  end

  -- NOTE: Need to build a secondary handler because calls require to requests

  local next_handler = partial(outgoing_calls_handler, bang)
  prepare_call_method(opts, partial(prepare_call_hierarchy_handler_to, next_handler), client)
end

---@type fzf_lsp.LspMethodCall
function M.code_action(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.codeAction)
  if not client then
    notify_no_clients(methods.codeAction)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_range_params(0, encoding)
  local ok, diag = pcall(get_diagnostics_data)
  local diagnostics = ok and diag or {}
  ---@diagnostic disable-next-line: inject-field
  params.context = {
    diagnostics = diagnostics,
  }
  call_lsp_method(methods.codeAction, params, opts, partial(code_action_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.range_code_action(bang, opts)
  opts = opts or {}
  local client = find_client_with_provider(methods.codeAction)
  if not client then
    notify_no_clients(methods.codeAction)
    return
  end

  local encoding = client.offset_encoding
  local params = vim.lsp.util.make_given_range_params(nil, nil, 0, encoding)
  local ok, diag = pcall(get_diagnostics_range, params.range)
  local diagnostics = ok and diag or {}
  ---@diagnostic disable-next-line: inject-field
  params.context = {
    diagnostics = diagnostics,
  }
  call_lsp_method(methods.codeAction, params, opts, partial(code_action_handler, bang), client)
end

---@type fzf_lsp.LspMethodCall
function M.diagnostic(bang, opts)
  opts = opts or {}

  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local show_all = bufnr == "*"
  bufnr = (type(bufnr) == "string" and not show_all) and tonumber(bufnr) or bufnr

  local buffer_diags ---@type vim.Diagnostic[]
  if show_all then
    buffer_diags = vim.diagnostic.get(nil)
  else
    buffer_diags = vim.diagnostic.get(bufnr)
  end

  local severity = opts.severity
  local severity_limit = opts.severity_limit

  ---@type vim.quickfix.entry[]
  local items = {}
  for _, diag in ipairs(buffer_diags) do
    if severity then
      if not diag.severity then
        goto continue
      end

      if severity ~= diag.severity then
        goto continue
      end
    elseif severity_limit then
      if not diag.severity then
        goto continue
      end

      if severity_limit < diag.severity then
        goto continue
      end
    end

    table.insert(items, {
      bufnr = diag.bufnr,
      filename = vim.api.nvim_buf_get_name(diag.bufnr),
      -- module = ...,
      lnum = diag.lnum + 1,
      end_lnum = diag.end_lnum + 1,
      -- pattern = ...,
      col = diag.col + 1,
      -- vcol = ...,
      end_col = diag.end_col + 1,
      -- nr = ...,
      text = diag.message,
      type = vim.lsp.protocol.DiagnosticSeverity[diag.severity or vim.lsp.protocol.DiagnosticSeverity.Error],
      -- valid = ...,
      user_data = diag,
    } --[[@as vim.quickfix.entry]])
    ::continue::
  end

  table.sort(items, function(a, b)
    return a.lnum < b.lnum
  end)

  ---@JoinDiaFunc
  local joinfn = g.fzf_lsp_pretty and joindiag_pretty or joindiag_raw

  local entries = {}
  for i, e in ipairs(items) do
    entries[i] = joinfn(e, i, show_all)
  end

  if vim.tbl_isempty(entries) then
    vim.notify("Empty diagnostic", vim.log.levels.INFO)
    return
  end

  local data = { infile = not show_all, diagnostics = buffer_diags, locs = items }
  fzf_locations(bang, "", "Diagnostics", entries, data)
end

-- }}}

-- LSP FUNCTIONS {{{
---@type fzf_lsp.RequestCall
M.code_action_call = partial(M.code_action, 0)
---@type fzf_lsp.RequestCall
M.range_code_action_call = partial(M.range_code_action, 0)
---@type fzf_lsp.RequestCall
M.definition_call = partial(M.definition, 0)
---@type fzf_lsp.RequestCall
M.declaration_call = partial(M.declaration, 0)
---@type fzf_lsp.RequestCall
M.type_definition_call = partial(M.type_definition, 0)
---@type fzf_lsp.RequestCall
M.implementation_call = partial(M.implementation, 0)
---@type fzf_lsp.RequestCall
M.references_call = partial(M.references, 0)
---@type fzf_lsp.RequestCall
M.document_symbol_call = partial(M.document_symbol, 0)
---@type fzf_lsp.RequestCall
M.workspace_symbol_call = partial(M.workspace_symbol, 0)
---@type fzf_lsp.RequestCall
M.incoming_calls_call = partial(M.incoming_calls, 0)
---@type fzf_lsp.RequestCall
M.outgoing_calls_call = partial(M.outgoing_calls, 0)
---@type fzf_lsp.RequestCall
M.diagnostic_call = partial(M.diagnostic, 0)
---@type fzf_lsp.RequestCall
M.snippets_call = partial(M.snippets, 0)
-- }}}

-- LSP HANDLERS {{{

local function mk_handler(f)
  return function(...)
    -- End support for neovim 0.10 or below
    -- TODO: How should the deprecation be handled? e.g. add vim.deprecate()
    f(...)
  end
end

---@type lsp.Handler
M.code_action_handler = mk_handler(partial(code_action_handler, 0))
---@type lsp.Handler
M.definition_handler = mk_handler(partial(definition_handler, 0))
---@type lsp.Handler
M.declaration_handler = mk_handler(partial(declaration_handler, 0))
---@type lsp.Handler
M.type_definition_handler = mk_handler(partial(type_definition_handler, 0))
---@type lsp.Handler
M.implementation_handler = mk_handler(partial(implementation_handler, 0))
---@type lsp.Handler
M.references_handler = mk_handler(partial(references_handler, 0))
---@type lsp.Handler
M.document_symbol_handler = mk_handler(partial(document_symbol_handler, 0))
---@type lsp.Handler
M.workspace_symbol_handler = mk_handler(partial(workspace_symbol_handler, 0))
---@type lsp.Handler
M.incoming_calls_handler = mk_handler(partial(incoming_calls_handler, 0))
---@type lsp.Handler
M.outgoing_calls_handler = mk_handler(partial(outgoing_calls_handler, 0))
---@type lsp.Handler
M.snippets_completion_handler = mk_handler(partial(snippets_completion_handler, 0))
-- }}}

-- Lua SETUP {{{
M.setup = function(opts)
  opts = opts or {
    override_ui_select = true,
  }

  local function setup_nvim_0_6()
    if opts.override_ui_select then
      vim.ui.select = fzf_ui_select
    end
  end

  if vim.version()["major"] >= 0 and vim.version()["minor"] >= 6 then
    setup_nvim_0_6()
  end

  vim.lsp.handlers[methods.codeAction] = M.code_action_handler
  vim.lsp.handlers[methods.definition] = M.definition_handler
  vim.lsp.handlers[methods.declaration] = M.declaration_handler
  vim.lsp.handlers[methods.typeDefinition] = M.type_definition_handler
  vim.lsp.handlers[methods.implementation] = M.implementation_handler
  vim.lsp.handlers[methods.references] = M.references_handler
  vim.lsp.handlers[methods.documentSymbol] = M.document_symbol_handler
  vim.lsp.handlers[methods.workspaceSymbol] = M.workspace_symbol_handler
  vim.lsp.handlers[methods.incomingCalls] = M.incoming_calls_handler
  vim.lsp.handlers[methods.outgoingCalls] = M.outgoing_calls_handler
end
-- }}}

return M
