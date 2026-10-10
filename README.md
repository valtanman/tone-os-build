# TONE OS – build script

[日本語はこちら → README.ja.md](README.ja.md)

A single script that **builds the TONE OS ISO** from scratch: Ubuntu 24.04 (noble) base, KDE Plasma desktop, Japanese-only UI, amd64.
This repository contains **only the build script**. **No ISO is distributed here.** Everything is downloaded from the official sources when *you* run the build (see [THIRD_PARTY.md](THIRD_PARTY.md)).

> ## ⚠ Status: pre-release / not yet verified end-to-end
> The unit tests of the generated files pass, but the **full ISO build of this public edition has not been completed yet**.
> Please treat it as experimental. Reports are welcome (see *Feedback*).

> ## ⚠ Read before running
> - The script is long (about 6,000 lines) and **runs as root** (`sudo`). **Read it first**, and try it in a virtual machine or on a spare PC.
> - It formats nothing on your disks by itself, but it creates large working folders and mounts/unmounts images. Make a backup first.
> - No warranty (MIT License).

## Requirements

- Host: Ubuntu 24.04 or a derivative (the author builds on Zorin OS 18), **amd64**
- Internet connection
- **35 GB or more free space** in the work folder (default `/home/TOSE`)
- Time: the author's environment needs roughly 30 minutes (depends on your network and CPU)

## Usage

```bash
sudo bash build-tone-os.sh
```

- Output (ISO, user manual PDF, source zip): `/home/TOSE/out`
- During the build, a few optional file pickers may appear (start page `index.html`, start/stop sounds, wallpaper pack). **Cancel them to use the defaults.**
- Environment variables are listed at the top of the script (for example `MAX_ATTEMPTS`, `KEEP_WORK=1`).

## Before you build: set your own update server

This public edition has **no update server configured**. The update source and the wallpaper source are set to the placeholder `https://updates.example.invalid/tos/`.
To use the built-in signed update system, host your own server and change these values (search for `updates.example.invalid` in the script), or leave them as they are (updates simply will not be found).

## Differences from the author's private edition

This edition has the AI assistant parts removed, the personal e-mail address replaced by a disposable contact, and the author's own server addresses replaced by placeholders. It is generated automatically from the private script.

## Feedback

Please open an Issue. For security problems, see [SECURITY.md](SECURITY.md).

## License

MIT (see `LICENSE`). Copyright (c) 2026 TONE (Seiji Okamoto / valtanman).
Software that the script downloads has its own licenses and terms; see [THIRD_PARTY.md](THIRD_PARTY.md).
