---
title: Install Plinth standalone compiler
permalink: /how-to/install/
---
`uplc-ghc`, the
[Plinth standalone compiler]({% link explanation/standalone-compiler.md %}),
is distributed as a custom tool named `plinth` for
[ghcup](https://www.haskell.org/ghcup/), the standard installer for Haskell
toolchains. Installing it via ghcup, as described here, is the recommended way
to get it. To work on the compiler itself, or when no binary distribution
covers your platform, [build it from source]({% link how-to/build.md %})
instead.

## Install via ghcup

You need ghcup 0.2.1.0 or newer (check with `ghcup --version`). Add the Plinth
release channel, then install and activate the tool:

```console
$ ghcup config add-release-channel https://raw.githubusercontent.com/input-output-hk/ghc-plinth/ghcup-channel/ghcup-plinth.yaml
$ ghcup install plinth 9.6.169.2
$ ghcup set plinth 9.6.169.2
```

`ghcup install` downloads the binary distribution for your platform and
installs it under ghcup's own directory; `ghcup set` then links `uplc-ghc` and
`uplc-ghc-pkg` (the compiler's own `ghc-pkg`) into ghcup's `bin` directory
(`~/.ghcup/bin` by default), which is already on `PATH` for ghcup users.
Verify with:

```console
$ uplc-ghc --version
```

Installing `plinth` does not affect any GHC installed by ghcup: only
`uplc-*` binaries are put on `PATH`, so your regular `ghc` is left untouched.

## Supported platforms

Binary distributions are published for:

- Linux, x86_64 and aarch64 (glibc, and musl/Alpine)
- macOS, Apple Silicon
- Windows, x86_64

List the available versions with `ghcup list -t plinth`.

Once installed, head over to
[Use uplc-ghc in a project]({% link how-to/use.md %}).
