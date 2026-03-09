<p align="center">
    <img src="./assets/copper-lion.jpg" alt="copper lion" height="300" />
    <br>
    <i>
        <sub>
            Photo by <a href="https://unsplash.com/@oriento?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText">五玄土 ORIENTO</a> on <a href="https://unsplash.com/photos/blue-and-green-ceramic-figurine-7I2VOwneLH0?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText">Unsplash</a>
        </sub>
    </i>
</p>

# <p align="center">🦁 Copper</p>

<p align="center">
    <b>A unified runtime and package manager.</b><br>
    <i>Consolidate your version managers into a single binary.</i>
</p>

---

## Why?

I built copper to solve two specific problems in my own workflow:

1.  **Tool Fatigue:** I loved using `fnm` for Node, but I didn't want to install and configure a separate version manager for every language (Go, Python, Zig, etc). copper brings that "auto-switch on `cd`" experience to all your runtimes.
2.  **Update Lag:** General package managers like Homebrew are excellent, but they often lag behind on fast-moving binaries like Zig. copper fetches packages directly from the source or official mirrors, so you get updates the moment they are released.

With copper, I was able to remove `fnm` entirely and stop using `brew` for language runtimes. It effectively functions as a universal package manager for your dev tools.

## Supported Packages

Copper supports both language runtimes and standalone tools.

### Runtimes
| Package | Description |
| :--- | :--- |
| **[node](https://nodejs.org/)** | JavaScript runtime (supports `.nvmrc`) |
| **[go](https://go.dev/)** | The Go programming language (supports `go.mod` and `.go-version`) |
| **[python](https://www.python.org/)** | Python language runtime (supports `.python-version`)|
| **[rust](https://www.rust-lang.org/)** | Systems programming language |
| **[zig](https://ziglang.org)** | General-purpose programming language |
| **[bun](http://bun.sh/)** | Fast all-in-one JavaScript runtime |
| **[cyber](https://github.com/fubark/cyber)** | Fast, efficient scripting language |

### CLI Tools
| Package | Description | Package | Description |
| :--- | :--- | :--- | :--- |
| **[neovim](https://github.com/neovim/neovim)**        | Vim-based text editor                                  | **[lazygit](https://github.com/jesseduffield/lazygit)**       | Terminal UI for git                     |
| **[helix](https://helix-editor.com)**                 | Modal editor inspired by Kakoune & Vim (built in Rust) | **[tree-sitter](https://github.com/tree-sitter/tree-sitter)** | Incremental parsing system & CLI        |
| **[ripgrep](https://github.com/BurntSushi/ripgrep)**  | Blazing-fast line-oriented search tool                 | **[fd](https://github.com/sharkdp/fd)**                       | Simple, fast alternative to `find`      |
| **[fzf](https://github.com/junegunn/fzf)**            | Interactive command-line fuzzy finder                  | **[zoxide](https://github.com/ajeetdsouza/zoxide)**           | Smarter `cd` that learns your habits    |
| **[opencode](https://github.com/anomalyco/opencode)** | The open source coding agent.                          | **[just](https://github.com/casey/just)**                     | Modern command runner (Makefile alt)    |
| **[btop](https://github.com/aristocratos/btop)**      | Beautiful resource monitor                             | **[dufs](https://github.com/sigoden/dufs)**                   | Fast static file server                 |
| **[git](https://github.com/git/git)**                 | The stupid content tracker                             | **[jj](https://github.com/jj-vcs/jj)**                        | Git-compatible VCS with modern workflow |

<details>
<summary><b>View all supported tools</b></summary>
<br>
    
- [go](https://go.dev/)
- [jq](https://github.com/jqlang/jq)
- [fd](https://github.com/sharkdp/fd)
- [jj](https://github.com/jj-vcs/jj)
- [zf](https://github.com/natecraddock/zf)
- [ty](https://github.com/astral-sh/ty)
- [bun](http://bun.sh/)
- [zig](https://ziglang.org)
- [nrz](https://github.com/logotip4ik/nrz)
- [fzf](https://github.com/junegunn/fzf)
- [rtk](https://github.com/rtk-ai/rtk)
- [git](https://github.com/git/git)
- [dufs](https://github.com/sigoden/dufs)
- [skhd](https://github.com/koekeishiya/skhd)
- [skim](https://github.com/skim-rs/skim)
- [rust](https://www.rust-lang.org/)
- [btop](https://github.com/aristocratos/btop)
- [rain](https://github.com/cenkalti/rain)
- [just](https://github.com/casey/just)
- [dust](https://github.com/bootandy/dust)
- [node](https://nodejs.org/)
- [ouch](https://github.com/ouch-org/ouch)
- [cyber](https://github.com/fubark/cyber)
- [helix](https://helix-editor.com)
- [fresh](https://github.com/sinelaw/fresh)
- [gogcli](https://github.com/steipete/gogcli)
- [neovim](https://github.com/neovim/neovim)
- [wrkflw](https://github.com/bahdotsh/wrkflw)
- [zoxide](https://github.com/ajeetdsouza/zoxide)
- [python](https://www.python.org/)
- [ziglay](https://github.com/logotip4ik/ziglay)
- [samply](https://github.com/mstange/samply)
- [trippy](https://github.com/fujiapple852/trippy)
- [ripgrep](https://github.com/BurntSushi/ripgrep/)
- [lazygit](https://github.com/jesseduffield/lazygit)
- [try-cli](https://github.com/tobi/try-cli)
- [opencode](https://github.com/anomalyco/opencode)
- [tailspin](https://github.com/bensadeh/tailspin)
- [hyperfine](https://github.com/sharkdp/hyperfine)
- [fastfetch](https://github.com/fastfetch-cli/fastfetch)
- [git-delta](https://github.com/dandavison/delta)
- [television](https://github.com/alexpasmantier/television)
- [claude-code](https://code.claude.com)
- [tree-sitter](https://github.com/tree-sitter/tree-sitter)
- [mongodb-database-tools](https://www.mongodb.com/try/download/database-tools)

</details>

## Installation

### Quick Install
To install the binary automatically:

```sh
curl -fsSL https://raw.githubusercontent.com/logotip4ik/copper/master/install.sh | bash
```

*Prefer not to pipe curl to bash? You can download the binary manually from the [Releases page](https://github.com/logotip4ik/copper/releases).*

## Setup

1.  Ensure the `copper` binary is in your `$PATH`.
2.  Initialize the shell hook to enable auto-switching capabilities:

| Shell | Add to Config |
| :--- | :--- |
| **Zsh** (`~/.zshrc`) | `eval "$(copper shell zsh)"` |
| **Bash** (`~/.bashrc`) | `eval "$(copper shell bash)"` |
| **Fish** (`config.fish`) | `copper shell fish \| source` |
| **PowerShell** (`$PROFILE`) | `Invoke-Expression (&copper shell pwsh)` |

> *Note: Windows support is theoretical...*

## Usage

**Basic Command Structure:**
```sh
copper <action> <package> [version]
```

### Common Actions

| Action | Command | Description |
| :--- | :--- | :--- |
| **Install** | `copper add node 22` | Fetches the latest Node 22.* version. |
| **List** | `copper list-remote zig` | Shows available versions for installation. |
| **Use** | `copper use node 24` | Sets the default global version. |
| **Check** | `copper installed` | Lists all packages currently managed by copper. |
| **Update** | `copper update-self` | Updates the copper binary itself. |

### Auto-Switching

Copper hooks into your directory changes. If you `cd` into a folder with a config file (e.g., `.nvmrc`, `.python-version`), copper will automatically update current default runtime to the specified version.

## Limitations

*Global state* - copper currently does not support per-session versioning. If you change the default version in one terminal tab, it affects all other sessions. This works fine for personal development machines, but PRs are welcome if you need session isolation.
