<p align="center">
    <img src="./assets/copper-lion.jpg" alt="copper lion" height="300" />
    <br>
    <i>
        <sub>
            Photo by <a href="https://unsplash.com/@oriento?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText">五玄土 ORIENTO</a> on <a href="https://unsplash.com/photos/blue-and-green-ceramic-figurine-7I2VOwneLH0?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText">Unsplash</a>
        </sub>
    </i>
</p>

# <p align="center">Copper</p>

<p align="center">
    Tool for managing runtimes/packages and their versions.<br>
    <i>I guess at this point you can call it a package manager.</i>
</p>

## Why

Don't want to install different CLIs every time you need to manage node or zig or any other package?
Than this is for you, it's like `homebrew` or `apt`, it installs packages right from the source (or
mirror).

As for me - I used [fnm](https://github.com/Schniz/fnm) for managing node. It is great, but I use
exactly _fnm_ very rarely and very limited amount of its features. `homebrew` was my "go to" for
managing zig, but it is not fast enough to brought updates. Some version could be out for days yet
`brew` would still miss it.

With copper I managed to remove fnm and `zig` from `homebrew`, maybe with your package config you
could save on yet another "version manager".

## List of supported packages:

- [go](https://go.dev/)
- [jq](https://github.com/jqlang/jq)
- [fd](https://github.com/sharkdp/fd)
- [jj](https://github.com/jj-vcs/jj)
- [bun](http://bun.sh/)
- [zig](https://ziglang.org)
- [nrz](https://github.com/logotip4ik/nrz)
- [fzf](https://github.com/junegunn/fzf)
- [git](https://github.com/git/git)
- [dufs](https://github.com/sigoden/dufs)
- [skhd](https://github.com/koekeishiya/skhd)
- [btop](https://github.com/aristocratos/btop)
- [just](https://github.com/casey/just)
- [node](https://nodejs.org/)
- [neovim](https://github.com/neovim/neovim)
- [zoxide](https://github.com/ajeetdsouza/zoxide)
- [python](https://www.python.org/)
- [ziglay](https://github.com/logotip4ik/ziglay)
- [trippy](https://github.com/fujiapple852/trippy)
- [ripgrep](https://github.com/BurntSushi/ripgrep/)
- [lazygit](https://github.com/jesseduffield/lazygit)
- [try-cli](https://github.com/tobi/try-cli)
- [tailspin](https://github.com/bensadeh/tailspin)
- [hyperfine](https://github.com/sharkdp/hyperfine)
- [git-delta](https://github.com/dandavison/delta)
- [television](https://github.com/alexpasmantier/television)
- [claude-code](https://code.claude.com)
- [mongodb-database-tools](https://www.mongodb.com/try/download/database-tools)

## Installation

Don't believe me, manually check what you are running in your bash.

```sh
curl -fsSL https://raw.githubusercontent.com/logotip4ik/copper/master/install.sh | bash
```

## Usage

```sh
copper add zig 0.15
```

### Setup

1. Download and place `copper` exe somewhere in your path
2. add:
    - zsh (\~/.zshrc): `eval "$(copper shell zsh)"`
    - bash (\~/.bashrc or \~/.bash_profile): `eval "$(copper shell bash)"`
    - fish (\~/.config/fish/config.fish): `copper shell fish | source`
    - PowerShell (\~/.config/powershell/profile.ps1 or $PROFILE): `Invoke-Expression (&copper shell pwsh)`

Copper should support Windows in theory, but I can't verify it, use on your own risk.

### copper help

```
copper - utility to handle installation of packages. Some examples of execution:

  copper list-remote|remote node 22          - list all node 22.*.* versions which are available for installation on your machine. You can also omit `22` to see all available versions.
  copper add|install node 22                 - fetch most recent node with matches 22.*.* version.
  copper list-installed|installed node       - show installed node versions (you can also provide version to narrow log down)
  copper remove|uninstall|delete node 22.*.* - remove node version 22.*.* if is installed.
  copper use node 24                         - change default node version to 24.*.*
  copper update node                         - update default node installation to latest available version

To provide installed packages, copper needs to patch "$PATH" - do so call in your shell:

  copper shell zsh|bash|fish|pwsh

  Copper will add a hook for current cwd change, which will check current dir for trigger
  files, like .nvmrc, .python-version etc (if you have installed supported configs). This
  allows to dynamically change working version of config without user input (like fnm does)

You can also interact with copper store via:

  copper store dir|cache-dir|clear-cache|remove-cache|delete-cache

Update copper with

  copper update-self
```

## Limitations

`copper` doesn't support version change per session. That means - if you change default used node
version it will affect all other sessions. It's fine for me so... PRs welcomed!
