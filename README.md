# fzf-lsp.nvim

![Show document symbols](https://raw.githubusercontent.com/gfanto/fzf-lsp.nvim/main/.github/images/example.gif)

Forked from [gfanto/fzf-lsp.nvim](https://github.com/gfanto/fzf-lsp.nvim). This fork addresses some issues with the
original project and adds some small features

- Windows support using a powershell script to handle preview
- Call hierarchy (incoming/outgoing) fix
- Update deprecated vim api functions
- Remove dependency on plenary.nvim
- Methods are async by default (and can be called synchronously by props)
- You can set actions using VimL callbacks or lua callbacks

## For who is this plugin

It is for anyone using the builtin `fzf` plugin within the [fzf](https://github.com/junegunn/fzf) repository.

All this plugin does is to provide functions that integrate the `fzf` plugin with neovim's lsp functionality, so you can
use all your familiar tools/configurations in place.

# Installation

## Vim Plug

[vim-plug](https://github.com/junegunn/vim-plug).

```vim
Plug 'DanSM-5/fzf-lsp.nvim'
```

## Other methods

The plugin can be installed with any package manager or manually by cloning into `pack/**/{opt,start}/<name>` and then add
`:packadd! <name>` to your init file.

For manual cloning refer to `:h packpath`, `:h packadd` and `:h stdpath()`

## Requirements

* Neovim 0.10+
* `fzf` installed in addition to use this plugin. See <https://github.com/junegunn/fzf/blob/master/README-VIM.md#installation>.
* `bat` (Optional) installed for the preview. See <https://github.com/sharkdp/bat>.

## Features

This is an extension for fzf that give you the ability to search for symbols
using the neovim builtin lsp.

## Commands and settings

If you have [fzf.vim](https://github.com/junegunn/fzf.vim) installed,
this plugin will respect your `g:fzf_command_prefix` setting.

#### Settings:

In general fzf-lsp.vim will respect your fzf.vim settings, alternatively you can override a specific settings with the fzf-lsp.vim equivalent:
* `g:fzf_lsp_action`: the equivalent of `g:fzf_action`, it's a dictionary containing all the actions that fzf will do in case of specific input
  - You can use VimL funcrefs or lua functions. All functions will have the following signature

```lua
---@class fzf_lsp.fzf_locations_data
---@field locs vim.quickfix.entry[] parsed location data
---@field infile boolean if it is present on current file
---@field results? any|any[] lsp results data
---@field ctx? lsp.HandlerContext lsp context handler
---@field config? table lsp request config
---@field diagnostics? vim.Diagnostic[] diagnostics information

---@alias fzf_lsp.action_callback fun(args: {
---locations: vim.quickfix.entry[];
---data: fzf_lsp.fzf_locations_data;
---action_type: string;
---})

-- locations: list of selected entries from fzf
-- data: context data used to generate the list
-- action_type: string that can be used to identify the type of call. Same as prompt in fzf minus the ">" symbol
```

* `g:fzf_lsp_layout`: the equivalent of `g:fzf_layout`, dictionary with the fzf_window layout
* `g:fzf_lsp_colors`: the equivalent of `g:fzf_colors`, it's a string that will be passed to fzf to set colors
* `g:fzf_lsp_preview_window`: the equivalent of `g:fzf_preview_window`, it's a list containing the preview windows position and key bindings
* `f:fzf_lsp_command_prefix`: the equivalent of `g:fzf_command_prefix`, it's the prefix applied to all commands

fzf-lsp.vim only settings:
* `g:fzf_lsp_timeout`: integer value, number of milliseconds after command calls will go to timeout
* `g:fzf_lsp_width`: integer value, max width per line, used to truncate the current line
* `g:fzf_lsp_pretty`: boolean value, select the line format, default is false
    (at the moment since the value is process by lua it cannot be used as a
    standard vim boolean value, but it must be either `v:true` or `v:false`)

#### Commands:

*** Commands accepts and respect the ! if given ***

- Call `:Definitions` to show the definition for the symbols under the cursor
- Call `:Declarations` to show the declaration for the symbols under the cursor\*
- Call `:TypeDefinitions` to show the type definition for the symbols under the cursor\*
- Call `:Implementations` to show the implementation for the symbols under the cursor\*
- Call `:References` to show the references for the symbol under the cursor
- Call `:DocumentSymbols` to show all the symbols in the current buffer
- Call `:WorkspaceSymbols` to show all the symbols in the workspace, you can optionally pass the query as argument to the command
- Call `:IncomingCalls` to show the incoming calls
- Call `:OutgoingCalls` to show the outgoing calls
- Call `:CodeActions` to show the list of available code actions
- Call `:RangeCodeActions` to show the list of available code actions in the visual selection
- Call `:Diagnostics` to show all the available diagnostic informations in the current buffer, you can optionally pass the desired severity level as first argument or the severity limit level as second argument
- Call `:DiagnosticsAll` to show all the available diagnostic informations in all the opened buffers, you can optionally pass the desired severity level as first argument or the severity limit level as second argument

**Note(\*)**: this methods may not be implemented in your language server, especially textDocument/declaration (`Declarations`) it's usually not implemented in favour of textDocument/definition (`Definitions`).

### Functions

Commands are just wrappers to the following function, each function take one optional parameter: a dictionary containing the options.

- `require('fzf_lsp').code_action_call`
- `require('fzf_lsp').range_code_action_call`
- `require('fzf_lsp').definition_call`
- `require('fzf_lsp').declaration_call`
- `require('fzf_lsp').type_definition_call`
- `require('fzf_lsp').implementation_call`
- `require('fzf_lsp').references_call`
- `require('fzf_lsp').document_symbol_call`
- `require('fzf_lsp').workspace_symbol_call`
    * options:
        * query
- `require('fzf_lsp').incoming_calls_call`
- `require('fzf_lsp').outgoing_calls_call`
- `require('fzf_lsp').diagnostic_call`
    * options:
        * bufnr: the buffer number, default on current buffer
        * severity: the minimum severity level
        * severity_limit: the maximum severity level

### Handlers

Functions and commands are async by default. You can request a sync call by providing a `sync`
flag in the opts object.

```lua
require('fzf_lsp').definition_call({ sync = true })
```

To setup global handlers for you you can use the provided `setup` function, keeping in mind that this will replace all your handlers:

```lua
require('fzf_lsp').setup()
```

> [!WARNING]
> Since neovim 0.11 this only takes effect for server-to-client calls and not client-to-server.
> For client-to-server you will need to call the fzf_lsp function directly.

or you can manually setup your handlers. The provided handlers are:
```lua
vim.lsp.handlers["textDocument/codeAction"] = require('fzf_lsp').code_action_handler
vim.lsp.handlers["textDocument/definition"] = require('fzf_lsp').definition_handler
vim.lsp.handlers["textDocument/declaration"] = require('fzf_lsp').declaration_handler
vim.lsp.handlers["textDocument/typeDefinition"] = require('fzf_lsp').type_definition_handler
vim.lsp.handlers["textDocument/implementation"] = require('fzf_lsp').implementation_handler
vim.lsp.handlers["textDocument/references"] = require('fzf_lsp').references_handler
vim.lsp.handlers["textDocument/documentSymbol"] = require('fzf_lsp').document_symbol_handler
vim.lsp.handlers["workspace/symbol"] = require('fzf_lsp').workspace_symbol_handler
vim.lsp.handlers["callHierarchy/incomingCalls"] = require('fzf_lsp').incoming_calls_handler
vim.lsp.handlers["callHierarchy/outgoingCalls"] = require('fzf_lsp').outgoing_calls_handler
```

##### Setup options

The `setup` function optionally takes a table for configuration.
Available options:
* `override_ui_select`: boolean option to override the vim.ui.select function (only for neovim 0.6+)
