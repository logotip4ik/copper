# <p align="center">Copper</p>

Tool for installing runtimes and compilers.

## Why

Don't want to install different CLIs every time you need to manage node or zig or any other package?
Than this is for you, it's like `homebrew` or `apt`, it installs packages right from the source (or
mirror).

As for me - I used [fnm](https://github.com/Schniz/fnm) for managing node. It is great, but I use
exactly _fnm_ very rarely and very limited amount of its features. `homebrew` was "my go" to for
managing zig, but it is not fast enough to brought updates. Some version could be out for days yet
`brew` would still miss it.

With copper I managed to remove fnm and `zig` from `homebrew`, maybe with your package config you
could save on yet another "version manager".

## List of supported packages:

- zig
- node

> It can and will be expanded, these are two tools I needed...

## Usage

## Setup

1. Download and place `copper` exe somewhere in your path
2. add `eval "$(copper shell zsh)"` to your `.zshrc`

Because we patch `$PATH` to include new packages, you may need to refresh your shell to start using
installed package. This is needed only first time package installation (we will notify you when
refresh needed)

### copper help

```sh
copper - utility to handle installation of packages. Currently it can
install only zig and node packages. Some examples of execution:

  copper list-remote|remote node 22          - list all node 22.*.* versions which are available for installation on your machine. You can also omit `22` to see all available versions.
  copper add|install node 22                 - fetch most recent node with matches 22.*.* version.
  copper list-installed|installed node       - show installed node versions (you can also provide version to narrow log down)
  copper remove|uninstall|delete node 22.*.* - remove node version 22.*.* if is installed.
  copper use node 24                         - change default node version to 24.*.*

To provide installed packages, copper needs to patch "$PATH" - do so call in your shell:

  copper shell zsh - currently only zsh is supported

You can also interact with copper store via:

  copper store dir|cache-dir|clear-cache|remove-cache|delete-cache
```

## Limitations

`copper` doesn't support version change per session. That means - if you change default used node
version it will affect all other sessions. It's fine for me so... PRs welcomed!
