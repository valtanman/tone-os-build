# Third-party software / 外部ソフトについて

This repository does not contain or redistribute any of the following. The build script downloads them **from the official sources onto your machine**; you are responsible for accepting their licenses and terms.
このリポジトリは、以下を含みも再配布もしません。ビルドスクリプトが、**公式の配布元からあなたのPCへ取得**します。各ライセンス・規約への同意は、ビルドする人の責任です。

| Software / ソフト | Source / 取得元 | Terms / 規約 |
|---|---|---|
| Ubuntu 24.04 base system and packages (KDE Plasma, Calamares, fcitx5-mozc, fonts, ClamAV, ufw, …) | Ubuntu archive mirrors (`debootstrap`, `apt`) | Each package's own license (mostly free software, e.g. GPL). Ubuntu trademarks: this project is *based on* Ubuntu and is not affiliated with Canonical |
| Google Chrome | Google's apt repository (`dl.google.com`) | Google Chrome Terms of Service. **Not bundled in this repo** |
| Steam (`steam-installer`) | Ubuntu archive (multiverse) | Valve's Steam Subscriber Agreement (shown when Steam is first run) |
| LibreOffice | The Document Foundation (`download.documentfoundation.org`) or the LibreOffice PPA | MPL 2.0 |
| Flatpak / Flathub | `dl.flathub.org` | Each application's own license |
| Proprietary GPU drivers and firmware (for example NVIDIA, via `ubuntu-drivers`) | Ubuntu archive | Each vendor's license; installed on the target PC when needed |

If you redistribute an ISO that you built, **you** are responsible for complying with the licenses above (for example, offering the corresponding source for GPL software, and the terms of Chrome and Steam). Checking each vendor's current terms before redistribution is strongly recommended.
ビルドしたISOを再配布する場合は、上記のライセンス(GPLソフトのソース提供、Chrome・Steam の規約など)を守る責任は**再配布する人**にあります。再配布の前に、各社の最新の規約を確認してください。
