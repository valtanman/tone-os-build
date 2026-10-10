#!/usr/bin/env bash
# ============================================================
# TONE OS ビルドスクリプト 【公開版】(AI関連の部品を取り除いた版)
# build-tone-os.sh から make-public-edition.py で自動生成。
# ============================================================
# =====================================================================
#  TONE OS ISO 完全自動ビルドスクリプト 版 1.0.0 (amd64 / Ubuntu 24.04 / KDE / 日本語専用)
#  作業OS: Zorin OS 18.1 Pro   実行: sudo bash build-tone-os.sh
#  すべての作業・出力: /home/TOSE  (ISO/説明書PDF/ソースZip は /home/TOSE/out)
#  環境変数: MAX_ATTEMPTS=検証の最大回数(8)  KEEP_WORK=1で作業用rootfsを残す  LO_VER=LibreOffice版(PPAが使えないときのTDF公式版。26.8.0)
#           TONE_EFI_ID=EFIの起動名(既定 ubuntu。共存用に TONE へ変える場合は、Secure Boot 起動を検証してから)  SKIP_INSTALL_TEST=1
#  版の規則: 主.副.修正(MyStartpageと同じ)。更新のたびに TONE_VER・HELP・更新履歴・ISO名・ビルドログ・更新目録を同時に更新し、エミュレートで検証する
# =====================================================================
set -Eeuo pipefail
umask 022

# --- ダブルクリックで起動できるようにする ------------------------------------
SELF=$(readlink -f "$0")
if [ ! -t 1 ] && [ -z "${TONE_IN_TERM:-}" ]; then
  # 端末が無い(ファイルマネージャーからのダブルクリック): 端末を開いて、自分自身をやり直す
  CMD="TONE_IN_TERM=1 bash '$SELF'; echo; read -r -p 'Enterキーで閉じます…' _"
  for t in x-terminal-emulator gnome-terminal kgx konsole xfce4-terminal mate-terminal lxterminal xterm; do
    command -v "$t" >/dev/null 2>&1 || continue
    case "$t" in
      gnome-terminal|kgx) exec "$t" -- bash -c "$CMD" ;;
      xfce4-terminal|mate-terminal) exec "$t" -x bash -c "$CMD" ;;
      *) exec "$t" -e bash -c "$CMD" ;;
    esac
  done
  command -v zenity >/dev/null 2>&1 && zenity --error --text="端末(ターミナル)が見つかりませんでした。\nターミナルを開いて  sudo bash '$SELF'  を実行してください。"
  exit 1
fi
if [ "$(id -u)" != 0 ]; then
  echo "TONE OS のビルドには管理者権限が必要です。パスワードを入力してください。"
  exec sudo -E TONE_IN_TERM=1 bash "$SELF" "$@"
fi

TONE_VER=1.0.0            # ← TONE OS の版(主.副.修正)。ここを変えると、画面表示・説明書・履歴・ISO名・ログが連動する
TONE_EFI_ID=${TONE_EFI_ID:-ubuntu}
BASE=/home/TOSE
WORK=$BASE/work
SRC=$BASE/src
OUT=$BASE/out
LOGDIR=$BASE/logs
IMP=$BASE/imports
ROOTFS=$WORK/rootfs
ISODIR=$WORK/iso
TS=$(date +%Y%m%d-%H%M%S)
LOG=$LOGDIR/build-$TONE_VER-$TS.log
ISO=$OUT/TONE_OS-$TONE_VER-$TS.iso
MIRROR=${MIRROR:-http://jp.archive.ubuntu.com/ubuntu}
LO_VER=${LO_VER:-26.8.0}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-8}
REAL_USER=${SUDO_USER:-root}

[ "$(id -u)" = 0 ] || { echo "管理者権限で実行してください"; exit 1; }
mkdir -p "$WORK" "$SRC/overlay" "$OUT" "$LOGDIR" "$IMP"
# ログ出力(プロセス置換を使わず名前付きパイプで実装: /dev/fd が無い環境でも動く)
PIPE=$(mktemp -u /tmp/tone-log.XXXXXX); mkfifo "$PIPE"
tee -a "$LOG" < "$PIPE" &
exec > "$PIPE" 2>&1
rm -f "$PIPE"
START_TS=$(date +%s)
notify() { # $1=タイトル $2=本文 (デスクトップ通知。失敗しても無視)
  local uid; uid=$(id -u "$REAL_USER" 2>/dev/null) || return 0
  sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    notify-send -u normal "$1" "$2" >/dev/null 2>&1 || true
}
trap 'echo "[$(date +%T)] ★エラー: 行 $LINENO で失敗しました (ログ: $LOG)"; notify "TONE OS ビルド失敗" "行 $LINENO で停止しました。ログを確認してください。"' ERR

log()  { echo "[$(date +%F' '%T)] $*"; }
step() { echo; echo "================ [$(date +%T)] $* ================"; }

# ---------------------------------------------------------------- 0. 事前確認
step "0. 事前確認"
log "TONE OS 版 $TONE_VER のビルドを開始します"
log "作業フォルダ: $BASE / ログ: $LOG / 実行ユーザー: $REAL_USER"
avail=$(df --output=avail -BG "$BASE" | tail -1 | tr -dc 0-9)
[ "${avail:-0}" -ge 35 ] || { log "空き容量不足(35GB以上必要・インストール検証用を含む): ${avail}GB"; exit 1; }
exec 8>"$BASE/.build.lock"; flock -n 8 || { log "別のビルドが実行中です"; exit 1; }
curl -fsI --max-time 20 "$MIRROR/dists/noble/Release" >/dev/null 2>&1 || { log "ミラーに接続できません($MIRROR)。ネット接続を確認してください"; exit 1; }
[ "$(dpkg --print-architecture)" = amd64 ] || { log "amd64環境が必要です"; exit 1; }

# ---------------------------------------------------------------- 1. ホスト準備
step "1. ホスト環境の準備"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools \
  zenity unzip zip curl imagemagick sox libsox-fmt-all python3 python3-reportlab fonts-noto-cjk fonts-dejavu-core \
  qemu-system-x86 ovmf ca-certificates gnupg shellcheck libnotify-bin rsync gdisk dosfstools e2fsprogs fonts-ipafont-gothic \
  openssl btrfs-progs

# ---------------------------------------------------------------- 2. 取り込み窓
step "2. ファイル取り込み窓"
pick() { # $1=タイトル $2=フィルタ
  local uid; uid=$(id -u "$REAL_USER")
  sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-/home/$REAL_USER/.Xauthority}" \
    XDG_RUNTIME_DIR="/run/user/$uid" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    zenity --file-selection --title="$1" ${2:+--file-filter="$2"} 2>/dev/null || true
}
INDEX_SRC=$(pick "【1/3】スタートページ index.html を選択" "HTML | *.html *.htm")
SND_START=$(pick "【2/3】起動音を選択 (wav/mp3/ogg)"       "音声 | *.wav *.mp3 *.ogg *.WAV *.MP3 *.OGG")
SND_OFF=$(pick   "【3/3】終了音(ログオフ)を選択 (wav/mp3/ogg)" "音声 | *.wav *.mp3 *.ogg *.WAV *.MP3 *.OGG")
WP_SRC=""
for c in "$IMP/TONE-wallpapers.zip" "$BASE/TONE-wallpapers.zip" "/home/$REAL_USER/TONE-wallpapers.zip" "/home/$REAL_USER/ダウンロード/TONE-wallpapers.zip" "/home/$REAL_USER/Downloads/TONE-wallpapers.zip"; do [ -f "$c" ] && { WP_SRC=$c; break; }; done
[ -n "$WP_SRC" ] || WP_SRC=$(pick "【追加】壁紙パック TONE-wallpapers.zip を選択(無ければキャンセル → 仮の壁紙)" "ZIP | *.zip")
for v in INDEX_SRC SND_START SND_OFF WP_SRC; do log "$v = ${!v:-(未選択: 標準を使用)}"; done

rm -rf "$IMP"/*; mkdir -p "$IMP/sounds"
[ -n "$INDEX_SRC" ] && cp -f "$INDEX_SRC" "$IMP/index.html"
[ -n "$SND_START" ] && cp -f "$SND_START" "$IMP/sounds/startup.${SND_START##*.}"
[ -n "$SND_OFF"   ] && cp -f "$SND_OFF"   "$IMP/sounds/logoff.${SND_OFF##*.}"

# ---------------------------------------------------------------- 3. ソース生成
step "3. ソースコード(overlay)生成"
rm -rf "$SRC/overlay"; mkdir -p "$SRC/overlay"
W() { mkdir -p "$(dirname "$SRC/overlay/$1")"; cat > "$SRC/overlay/$1"; chmod "${2:-644}" "$SRC/overlay/$1"; }

WB() { mkdir -p "$(dirname "$SRC/overlay/$1")"; base64 -d > "$SRC/overlay/$1"; chmod "${2:-644}" "$SRC/overlay/$1"; }
# --- 自動更新 -------------------------------------------------------
W etc/apt/apt.conf.d/20tone-auto-upgrades <<'__E__'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
__E__
W etc/apt/apt.conf.d/51tone-unattended <<'__E__'
Unattended-Upgrade::Origins-Pattern { "origin=*"; };
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
Dpkg::Options { "--force-confold"; "--force-confdef"; };
__E__
W etc/apt/apt.conf.d/99tone-chrome <<'__E__'
DPkg::Post-Invoke { "/usr/local/bin/tone-fix-chrome || true"; "/usr/local/bin/tone-brand || true"; };
__E__
W usr/local/bin/tone-chrome 755 <<'__E__'
#!/bin/bash
# Chromeの起動ラッパー: URLが指定されていない起動では必ずスタートページ(index.html)を開く。
# (アップデートで管理設定や起動設定が変わっても、スタートページが表示される)
has_url=0
for a in "$@"; do case "$a" in -*) ;; *) has_url=1;; esac; done
args=("$@")
[ "$has_url" = 0 ] && args+=("file:///usr/share/tone-os/index.html")
exec /usr/bin/google-chrome-stable --password-store=basic "${args[@]}"
__E__
W usr/local/bin/tone-fix-chrome 755 <<'__E__'
#!/bin/bash
# Chromeのインストール/アップデートの度に実行(apt Post-Invoke・自動更新後)。
# 起動アイコンを起動ラッパーへ向け、スタートページの管理設定と index.html を元に戻す。
f=/usr/share/applications/google-chrome.desktop
if [ -f "$f" ] && ! grep -q 'tone-chrome' "$f"; then
  sed -i 's|^Exec=/usr/bin/google-chrome-stable --password-store=basic|Exec=/usr/bin/google-chrome-stable|; s|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/tone-chrome|' "$f"
fi
POL=/etc/opt/chrome/policies/managed/tone.json; M=/usr/share/tone-os/chrome-policy/tone.json
if [ -f "$M" ]; then mkdir -p "$(dirname "$POL")"; cmp -s "$M" "$POL" || cp -f "$M" "$POL"; chmod 644 "$POL"; fi
[ -s /usr/share/tone-os/index.html ] || { [ -f /usr/share/tone-os/index.html.master ] && cp -f /usr/share/tone-os/index.html.master /usr/share/tone-os/index.html; }
exit 0
__E__
W usr/local/bin/tone-notify 755 <<'__E__'
#!/bin/bash
# 使い方: tone-notify "タイトル" "本文" [normal|critical]  ログイン中の全ユーザーへ、確実にデスクトップ通知を出す
for uid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $2}' | sort -u); do
  [ "$uid" -ge 1000 ] 2>/dev/null || continue
  u=$(id -nu "$uid" 2>/dev/null) || continue
  b="/run/user/$uid/bus"; [ -S "$b" ] || continue
  sudo -u "$u" env DBUS_SESSION_BUS_ADDRESS="unix:path=$b" notify-send -u "${3:-normal}" -a "TONE OS" -i system-software-update "$1" "$2" >/dev/null 2>&1 || true
done
exit 0
__E__
W usr/local/bin/tone-update-all 755 <<'__E__'
#!/bin/bash
# OSコア・周辺・Flatpak・Snap・LibreOffice・外部リポジトリアプリ(Chrome等)をまとめて更新し、結果を通知する
exec 9>/run/tone-update.lock; flock -n 9 || exit 0
mkdir -p /var/log/tone-os; L=/var/log/tone-os/update.log
N=/usr/local/bin/tone-notify
nm-online -q -t 120 >/dev/null 2>&1 || true
if ! { ping -c1 -W3 archive.ubuntu.com >/dev/null 2>&1 || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }; then
  $N "TONE OS 更新チェック" "ネットワークに接続できないため、更新チェックは次回(3時間後)に行います。" normal; exit 0
fi
$N "TONE OS 更新チェック" "更新を確認しています…" normal
export DEBIAN_FRONTEND=noninteractive
run() { "$@" >>"$L" 2>&1; }
echo "=== $(date) 更新開始 ===" >>"$L"
run apt-get update
n_apt=$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst')
k_old=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
run apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef dist-upgrade
k_new=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
[ "$k_old" = "$k_new" ] || run /usr/local/bin/tone-kernel-sync   # 新しいカーネルが入ったら、ヘッダー/DKMS/initramfs/GRUB/ドライバーの整合を自動で取る
run apt-get -y autoremove
n_fp=0
if command -v flatpak >/dev/null; then
  run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  n_fp=$(flatpak remote-ls --updates 2>/dev/null | wc -l)
  run flatpak update -y --noninteractive; run flatpak uninstall --unused -y --noninteractive
fi
n_snap=0
if command -v snap >/dev/null; then
  run snap set system refresh.timer=00:00~24:00/8     # Snap自身の確認も3時間毎(1日8回)
  n_snap=$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l)
  run snap refresh
fi
run /usr/local/bin/tone-lo-update
run /usr/local/bin/tone-fix-chrome
echo "=== $(date) 更新完了 (apt $n_apt / flatpak $n_fp / snap $n_snap) ===" >>"$L"
total=$((n_apt + n_fp + n_snap))
newest=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's#.*/vmlinuz-##')
if [ -f /var/run/reboot-required ]; then
  $N "TONE OS: 再起動で更新が完全に反映されます" "新しいカーネルなどが入りました(最新: $newest / 実行中: $(uname -r))。時間のあるときに再起動してください。" critical
elif [ "$total" -gt 0 ]; then
  $N "TONE OS 更新完了" "更新を適用しました(OS・アプリ $n_apt 件 / Flatpak $n_fp 件 / Snap $n_snap 件)。Chromeの更新は、次回の起動から反映されます。" critical
else
  $N "TONE OS 更新チェック" "すべて最新の状態です。次の確認は3時間後です。" normal
fi
exit 0
__E__

# --- 時刻(NTP) -------------------------------------------------------
W etc/chrony/chrony.conf <<'__E__'
server ntp.nict.jp iburst minpoll 6 maxpoll 9
makestep 1.0 -1
rtcsync
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
__E__
W usr/local/bin/tone-ntp-sync 755 <<'__E__'
#!/bin/bash
chronyc -a 'burst 4/4' >/dev/null 2>&1; sleep 10; chronyc -a makestep >/dev/null 2>&1; exit 0
__E__
W etc/systemd/system/tone-ntp.service <<'__E__'
[Unit]
Description=TONE OS NTP時刻同期(ntp.nict.jp)
After=chrony.service network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tone-ntp-sync
__E__
W etc/systemd/system/tone-ntp.timer <<'__E__'
[Unit]
Description=15分毎の時刻調整
[Timer]
OnBootSec=1min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
__E__
W etc/systemd/system/tone-update.service <<'__E__'
[Unit]
Description=TONE OS 全体自動アップデート
ConditionKernelCommandLine=!tone.test
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tone-update-all
__E__
W etc/systemd/system/tone-update.timer <<'__E__'
[Unit]
Description=TONE OS 自動アップデート(起動1分後と3時間毎)
[Timer]
OnBootSec=1min
OnUnitActiveSec=3h
Persistent=true
[Install]
WantedBy=timers.target
__E__

# --- セキュリティ ----------------------------------------------------
W usr/local/bin/tone-boot-scan 755 <<'__E__'
#!/bin/bash
grep -q boot=casper /proc/cmdline && exit 0
mkdir -p /var/log/tone-os /var/lib/tone-os
L=/var/log/tone-os/boot-scan.log; rm -f /var/lib/tone-os/last-scan-infected
systemctl is-active --quiet clamav-freshclam || freshclam >>"$L" 2>&1 || true
{ echo "=== $(date) 起動時スキャン ==="
  clamscan -ri --max-filesize=100M --max-scansize=300M /home /tmp /var/tmp /opt /usr/local; echo "rc=$?"; } >>"$L" 2>&1
grep -q 'Infected files: [1-9]' "$L" && tail -n 40 "$L" | grep -q 'Infected files: [1-9]' && touch /var/lib/tone-os/last-scan-infected
chmod 644 /var/lib/tone-os/* 2>/dev/null; exit 0
__E__
W etc/systemd/system/tone-boot-scan.service <<'__E__'
[Unit]
Description=TONE OS 起動時ウイルスチェック
ConditionKernelCommandLine=!tone.test
After=network-online.target clamav-freshclam.service
[Service]
Type=simple
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/bin/tone-boot-scan
[Install]
WantedBy=multi-user.target
__E__
W usr/local/bin/tone-scan-notify 755 <<'__E__'
#!/bin/bash
sleep 20
[ -e /var/lib/tone-os/last-scan-infected ] && notify-send -u critical "TONE OS セキュリティ" "起動時チェックで脅威が見つかりました。/var/log/tone-os/boot-scan.log をご確認ください。"
exit 0
__E__
W etc/xdg/autostart/tone-scan-notify.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS ウイルスチェック通知
Exec=/usr/local/bin/tone-scan-notify
NoDisplay=true
__E__
W usr/local/bin/tone-safe-install 755 <<'__E__'
#!/bin/bash
# 外部アプリ(.deb)のインストール: ウイルススキャン→警告表示→ユーザー判断でインストール(パスワード不要)
f=$(readlink -f "$1"); n=$(basename "$f")
[ -f "$f" ] || { zenity --error --text="ファイルが見つかりません。"; exit 1; }
notify-send "TONE OS" "「$n」をウイルススキャン中です…"
res=$(clamscan --no-summary "$f" 2>&1); rc=$?
if [ $rc -eq 2 ]; then sudo -n freshclam >/dev/null 2>&1; res=$(clamscan --no-summary "$f" 2>&1); rc=$?; fi
if [ $rc -eq 0 ]; then
  zenity --question --width=420 --title="外部アプリのインストール" --ok-label="インストールする" --cancel-label="やめる" \
    --text="「$n」のウイルススキャン結果: 脅威は検出されませんでした。\n\n外部から入手したアプリです。インストールしますか?" || exit 0
elif [ $rc -eq 1 ]; then
  zenity --question --width=460 --title="⚠ 警告: 脅威を検出" --ok-label="危険を承知でインストール" --cancel-label="やめる(推奨)" \
    --text="「$n」から脅威が検出されました。\n\n$res\n\n通常はインストールしないでください。" || exit 0
else
  zenity --question --width=460 --title="⚠ 警告: スキャンできませんでした" --ok-label="インストールする" --cancel-label="やめる" \
    --text="ウイルススキャンを完了できませんでした。\n\n$res\n\nインストールしますか?" || exit 0
fi
mkdir -p "$HOME/.cache/tone-os"; IL="$HOME/.cache/tone-os/install.log"
( echo "# インストール中…"; sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y "$f" >"$IL" 2>&1; echo $? >"$IL.rc" ) | \
  zenity --progress --pulsate --auto-close --no-cancel --title="インストール" 2>/dev/null
if [ "$(cat "$IL.rc" 2>/dev/null)" = 0 ]; then notify-send "TONE OS" "「$n」をインストールしました。"
else zenity --text-info --title="インストールに失敗しました" --filename="$IL" --width=600 --height=400; fi
__E__
W usr/share/applications/tone-safe-install.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=安全にインストール(ウイルススキャン付き)
Exec=/usr/local/bin/tone-safe-install %f
MimeType=application/vnd.debian.binary-package;
NoDisplay=true
__E__
W etc/xdg/mimeapps.list <<'__E__'
[Default Applications]
application/vnd.debian.binary-package=tone-safe-install.desktop
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
text/html=google-chrome.desktop
__E__

# --- パスワード要求の排除 --------------------------------------------
W etc/sudoers.d/90-tone-nopasswd 440 <<'__E__'
%sudo ALL=(ALL:ALL) NOPASSWD: ALL
__E__
W etc/polkit-1/rules.d/49-tone-nopasswd.rules <<'__E__'
polkit.addRule(function(action, subject) {
    if (subject.local && subject.active && subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
__E__
W etc/skel/.config/kwalletrc <<'__E__'
[Wallet]
Enabled=false
First Use=false
__E__
W etc/skel/.config/kscreenlockerrc <<'__E__'
[Daemon]
Autolock=false
LockOnResume=false
__E__

# --- 日本語入力・ロケール ---------------------------------------------
W etc/default/locale <<'__E__'
LANG=ja_JP.UTF-8
LANGUAGE=ja:en
LC_ALL=ja_JP.UTF-8
__E__
W etc/default/keyboard <<'__E__'
XKBMODEL="jp106"
XKBLAYOUT="jp"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
__E__
W etc/environment.d/90-tone-ime.conf <<'__E__'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
__E__
W etc/skel/.config/fcitx5/profile <<'__E__'
[Groups/0]
Name=Default
Default Layout=jp
DefaultIM=mozc

[Groups/0/Items/0]
Name=keyboard-jp
Layout=

[Groups/0/Items/1]
Name=mozc
Layout=

[GroupOrder]
0=Default
__E__
W etc/skel/.config/fcitx5/config <<'__E__'
[Hotkey/TriggerKeys]
0=Zenkaku_Hankaku
1=Control+space
2=Hangul

[Behavior]
ActiveByDefault=False
__E__
W etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5 -d
__E__

# --- デザイン(ダーク+グリーン)・ユーザーフォルダ --------------------
W etc/skel/.config/kdeglobals <<'__E__'
[General]
ColorScheme=BreezeDark
AccentColor=0,200,120

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
__E__
W etc/skel/.config/user-dirs.dirs <<'__E__'
XDG_DESKTOP_DIR="$HOME/デスクトップ"
XDG_DOWNLOAD_DIR="$HOME/ダウンロード"
XDG_DOCUMENTS_DIR="$HOME/ドキュメント"
XDG_MUSIC_DIR="$HOME/ミュージック"
XDG_PICTURES_DIR="$HOME/ピクチャ"
XDG_VIDEOS_DIR="$HOME/ビデオ"
__E__
W etc/xdg/user-dirs.conf <<'__E__'
enabled=False
__E__
W etc/sddm.conf.d/tone.conf <<'__E__'
[Theme]
Current=breeze
[General]
InputMethod=
__E__

# --- Chrome / スタートページ -------------------------------------------
W etc/opt/chrome/policies/managed/tone.json <<'__E__'
{
  "HomepageLocation": "file:///usr/share/tone-os/index.html",
  "HomepageIsNewTabPage": false,
  "ShowHomeButton": true,
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["file:///usr/share/tone-os/index.html"],
  "BrowserSignin": 1,
  "SyncDisabled": false,
  "PasswordManagerEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false
}
__E__
W opt/google/chrome/initial_preferences <<'__E__'
{
  "distribution": {
    "make_chrome_default": false,
    "suppress_first_run_default_browser_prompt": true,
    "show_welcome_page": false,
    "skip_first_run_ui": false
  },
  "sync_promo": { "show_on_first_run_allowed": true }
}
__E__
if [ -f "$IMP/index.html" ]; then
  mkdir -p "$SRC/overlay/usr/share/tone-os"; cp -f "$IMP/index.html" "$SRC/overlay/usr/share/tone-os/index.html"; log "index.html を取り込みました"
else
W usr/share/tone-os/index.html <<'__E__'
<!doctype html><html lang="ja"><meta charset="utf-8"><title>TONE OS</title>
<body style="margin:0;background:#050b08;color:#fff;font-family:'Noto Sans CJK JP',sans-serif;text-align:center;padding-top:18vh">
<h1 style="font-size:64px;letter-spacing:.1em">TONE OS</h1><p style="color:#35d08a">ようこそ。ToneInternetService.</p>
<p><a style="color:#35d08a" href="https://www.google.com/">検索を始める</a></p>
<p style="position:fixed;bottom:12px;width:100%;font-size:12px;color:#9aa">開発者：valtanman　連絡先：toneappbildman@appmail.uk　ToneInternetService. 《PC-OpenCafe.　IoT&amp;Digital Software Development Department.》</p></body></html>
__E__
fi

# ===================================================================
# --- スタートページ(index.html)更新窓 -------------------------------------
W usr/local/bin/tone-index-apply 755 <<'__E__'
#!/bin/bash
# (管理者権限) 選ばれた新しい index.html で、スタートページとそのバックアップ(マスター)を上書きする
set -e
src=$1; D=/usr/share/tone-os
[ -s "$src" ] || { echo "ファイルが空です" >&2; exit 1; }
[ -f "$D/index.html" ] && cp -f "$D/index.html" "$D/index.html.prev"
install -m 644 "$src" "$D/index.html"
install -m 644 "$src" "$D/index.html.master"
exit 0
__E__
W usr/local/bin/tone-index-update 755 <<'__E__'
#!/bin/bash
# スタートページ更新窓: 新しい index.html を選び、「更新」を押すと上書きされる
f=$(zenity --file-selection --title="新しい index.html を選んでください" --file-filter="HTML | *.html *.htm") || exit 0
[ -s "$f" ] || { zenity --error --text="選ばれたファイルが空、または読み込めません。"; exit 1; }
zenity --question --width=460 --title="スタートページの更新" --ok-label="更新" --cancel-label="キャンセル" \
  --text="次のファイルで、スタートページを上書きします。\n\n$f\n\nよろしいですか?" || exit 0
if sudo -n /usr/local/bin/tone-index-apply "$f"; then
  zenity --info --width=420 --title="スタートページの更新" --text="更新しました。\nChromeを開き直すと、新しいスタートページが表示されます。\n(元のファイルは index.html.prev に保管されています)"
else
  zenity --error --text="更新に失敗しました。"
fi
__E__
W usr/share/applications/tone-index-update.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=スタートページの更新(index.html)
Icon=document-edit
Exec=/usr/local/bin/tone-index-update
Categories=Settings;
__E__

# --- 壁紙スライドショー(KDE標準のスライドショー機能を使用) ---------------------
W usr/local/bin/tone-wallpaper 755 <<'__E__'
#!/usr/bin/env python3
# TONE OS 壁紙スライドショー。ユーザーの操作でサーバーのフォルダから壁紙を読み込み、KDE Plasmaのスライドショーに設定する。
# サービス開始前は機能ロック。サーバーに「サービス開始の通知.txt」が置かれ、それを読み込むと機能が解除される。
import os, sys, json, random, subprocess, urllib.request, urllib.parse
from html.parser import HTMLParser

BASE = os.environ.get("TONE_WALLPAPER_BASE", "https://updates.example.invalid/tos/wallpeper/")
if not BASE.endswith("/"): BASE += "/"
NOTICE = "サービス開始の通知.txt"
HOME = os.environ.get("HOME", os.path.expanduser("~"))
CFG_DIR = os.path.join(HOME, ".config", "tone-os")
CFG = os.path.join(CFG_DIR, "wallpaper.json")
NOTICE_FILE = os.path.join(CFG_DIR, "wallpaper-notice.txt")
PIC_DIR = os.path.join(HOME, "ピクチャ", "TONE壁紙")
INTERVALS = [("5分", 300), ("15分", 900), ("60分", 3600), ("120分", 7200), ("6時間", 21600), ("更新選択なし", 0)]
EXTS = (".jpg", ".jpeg", ".png", ".webp", ".bmp")

def load_cfg():
    try:
        with open(CFG, encoding="utf-8") as f: return json.load(f)
    except Exception:
        return {"unlocked": False, "interval": 3600}

def save_cfg(c):
    os.makedirs(CFG_DIR, exist_ok=True)
    with open(CFG, "w", encoding="utf-8") as f: json.dump(c, f, ensure_ascii=False)

def http_get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "TONE-OS-Wallpaper/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r: return r.read()

def decode(b):
    for enc in ("utf-8-sig", "cp932", "euc-jp"):
        try: return b.decode(enc)
        except Exception: pass
    return b.decode("utf-8", "replace")

def notify(title, body, action=False):
    cmd = ["notify-send", "-a", "TONE OS", "-u", "critical", "-i", "preferences-desktop-wallpaper"]
    if action: cmd += ["-A", "read=通知を読む", "-w"]
    try:
        r = subprocess.run(cmd + [title, body], capture_output=True, text=True, timeout=900)
        if action and "read" in (r.stdout or ""): subprocess.Popen([sys.argv[0], "--notice"])
    except Exception:
        pass

def check_notice():
    """サーバーの『サービス開始の通知.txt』を読み込む。戻り値: (見つかった, 今回はじめて解除された)"""
    try:
        data = http_get(BASE + urllib.parse.quote(NOTICE))
    except Exception:
        return False, False
    os.makedirs(CFG_DIR, exist_ok=True)
    with open(NOTICE_FILE, "w", encoding="utf-8") as f: f.write(decode(data))
    c = load_cfg(); newly = not c.get("unlocked")
    c["unlocked"] = True; save_cfg(c)
    return True, newly

class _Links(HTMLParser):
    def __init__(self): super().__init__(); self.links = []
    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for k, v in attrs:
                if k == "href" and v: self.links.append(v)

def list_images():
    p = _Links(); p.feed(decode(http_get(BASE)))
    out, seen = [], set()
    for h in p.links:
        url = urllib.parse.urljoin(BASE, h.split("?")[0].split("#")[0])
        if not url.startswith(BASE): continue
        name = os.path.basename(urllib.parse.unquote(url))
        if name and name.lower().endswith(EXTS) and name not in seen:
            seen.add(name); out.append((name, url))
    return out

def sync(progress=None):
    imgs = list_images()
    if not imgs: raise RuntimeError("サーバーのフォルダに壁紙が見つかりませんでした。")
    os.makedirs(PIC_DIR, exist_ok=True); want = set()
    for i, (name, url) in enumerate(imgs[:300]):
        want.add(name); dst = os.path.join(PIC_DIR, name)
        if progress: progress(i + 1, min(len(imgs), 300), name)
        if os.path.exists(dst) and os.path.getsize(dst) > 0: continue
        data = http_get(url, 60)
        if len(data) > 40 * 1024 * 1024: want.discard(name); continue
        with open(dst + ".part", "wb") as f: f.write(data)
        os.replace(dst + ".part", dst)
    for f in os.listdir(PIC_DIR):     # サーバーから無くなった壁紙は片付ける
        if f.lower().endswith(EXTS) and f not in want:
            try: os.remove(os.path.join(PIC_DIR, f))
            except OSError: pass
    return len(want)

def plasma_script(js):
    for cmd in (["busctl", "--user", "call", "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", "s", js],
                ["qdbus", "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", js],
                ["qdbus-qt5", "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", js]):
        try:
            if subprocess.run(cmd, capture_output=True, timeout=30).returncode == 0: return True
        except Exception:
            pass
    return False

def apply_interval(interval):
    """KDE Plasma標準のスライドショーへ設定。0(更新選択なし)は壁紙1枚を固定表示。"""
    imgs = sorted(f for f in os.listdir(PIC_DIR) if f.lower().endswith(EXTS)) if os.path.isdir(PIC_DIR) else []
    if not imgs: return False
    q = lambda v: json.dumps(v, ensure_ascii=False)
    if interval > 0:
        js = ('var all = desktops(); for (var i = 0; i < all.length; i++) { var d = all[i];'
              ' d.wallpaperPlugin = "org.kde.slideshow"; d.currentConfigGroup = ["Wallpaper","org.kde.slideshow","General"];'
              ' d.writeConfig("SlidePaths", %s); d.writeConfig("SlideInterval", %d); d.writeConfig("SlideshowMode", 0); }'
              % (q(PIC_DIR), interval))
    else:
        one = "file://" + os.path.join(PIC_DIR, random.choice(imgs))
        js = ('var all = desktops(); for (var i = 0; i < all.length; i++) { var d = all[i];'
              ' d.wallpaperPlugin = "org.kde.image"; d.currentConfigGroup = ["Wallpaper","org.kde.image","General"];'
              ' d.writeConfig("Image", %s); }' % q(one))
    return plasma_script(js)

# ---------------- 画面 ----------------
def gui(notice_only=False):
    from PyQt5.QtWidgets import (QApplication, QWidget, QVBoxLayout, QLabel, QComboBox, QPushButton,
                                 QMessageBox, QPlainTextEdit, QDialog)
    from PyQt5.QtCore import Qt
    app = QApplication(sys.argv)

    def show_notice(parent=None):
        d = QDialog(parent); d.setWindowTitle("サービス開始の通知"); d.resize(640, 420)
        lay = QVBoxLayout(d); t = QPlainTextEdit(); t.setReadOnly(True)
        try:
            with open(NOTICE_FILE, encoding="utf-8") as f: t.setPlainText(f.read())
        except Exception:
            t.setPlainText("通知文書はまだ読み込まれていません。")
        b = QPushButton("閉じる"); b.clicked.connect(d.accept); lay.addWidget(t); lay.addWidget(b); d.exec_()

    if notice_only:
        show_notice(); return 0

    c0 = load_cfg()
    if not c0.get("unlocked"): check_notice()      # 開くたびに、サービス開始の通知を確認する
    w = QWidget(); w.setWindowTitle("壁紙スライドショー - TONE OS"); w.resize(560, 360)
    lay = QVBoxLayout(w)
    title = QLabel("<h2>壁紙スライドショー</h2>"); status = QLabel(); status.setWordWrap(True); prog = QLabel("")
    combo = QComboBox()
    for name, sec in INTERVALS: combo.addItem(name, sec)
    cur = load_cfg().get("interval", 3600)
    combo.setCurrentIndex(next((i for i, (_, s) in enumerate(INTERVALS) if s == cur), 2))
    b_sync = QPushButton("壁紙をインターネットから読み込んで適用"); b_apply = QPushButton("更新間隔を変えて適用")
    b_notice = QPushButton("サービス開始の通知を読む"); b_check = QPushButton("サービス開始を確認する")
    for x in (title, status, QLabel("スライドショーの更新間隔:"), combo, b_sync, b_apply, b_notice, b_check, prog): lay.addWidget(x)

    def refresh():
        c = load_cfg(); on = bool(c.get("unlocked"))
        status.setText("サービスをご利用いただけます。" if on else
                       "この機能は、サービス開始(2027年1月以降の予定)までご利用いただけません。\nサービスが始まると、OSの通知でお知らせします。")
        for b in (b_sync, b_apply, combo): b.setEnabled(on)
        b_notice.setEnabled(os.path.exists(NOTICE_FILE)); b_check.setVisible(not on)
    def do_check():
        found, newly = check_notice(); refresh()
        QMessageBox.information(w, "確認結果", "サービス開始の通知を読み込みました。機能が解除されました。" if found else "まだサービスは始まっていません。")
        if found: show_notice(w)
    def do_sync():
        try:
            def pg(i, n, name): prog.setText("読み込み中 %d/%d: %s" % (i, n, name)); QApplication.processEvents()
            n = sync(pg); c = load_cfg(); c["interval"] = combo.currentData(); save_cfg(c)
            ok = apply_interval(combo.currentData())
            prog.setText("%d枚の壁紙を読み込みました。" % n + ("" if ok else "(Plasmaへの反映に失敗しました。デスクトップ上で再度お試しください)"))
        except Exception as e:
            QMessageBox.warning(w, "読み込めませんでした", str(e)); prog.setText("")
    def do_apply():
        c = load_cfg(); c["interval"] = combo.currentData(); save_cfg(c)
        ok = apply_interval(combo.currentData())
        QMessageBox.information(w, "壁紙", "適用しました。" if ok else "先に「壁紙をインターネットから読み込んで適用」を実行してください。")
    b_sync.clicked.connect(do_sync); b_apply.clicked.connect(do_apply)
    b_notice.clicked.connect(lambda: show_notice(w)); b_check.clicked.connect(do_check)
    refresh(); w.show(); return app.exec_()

def main():
    a = sys.argv[1:]
    if "--watch" in a:                 # 定期確認(ユーザーのタイマーから起動)
        if load_cfg().get("unlocked"): return 0
        found, newly = check_notice()
        if found and newly:
            notify("壁紙スライドショーのサービスが始まりました", "「壁紙スライドショー」から壁紙を読み込めます。通知文書も読めます。", True)
        return 0
    if "--sync" in a:
        c = load_cfg()
        if not c.get("unlocked"): print("サービス開始前です"); return 2
        print("%d枚" % sync()); apply_interval(c.get("interval", 3600)); return 0
    if "--notice" in a: return gui(True) or 0
    return gui() or 0

if __name__ == "__main__":
    sys.exit(main())
__E__
W usr/share/applications/tone-wallpaper.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=壁紙スライドショー
Icon=preferences-desktop-wallpaper
Exec=/usr/local/bin/tone-wallpaper
Categories=Settings;
__E__
W etc/systemd/user/tone-wallpaper-watch.service <<'__E__'
[Unit]
Description=壁紙スライドショーのサービス開始を確認
ConditionKernelCommandLine=!boot=casper
ConditionKernelCommandLine=!tone.test
[Service]
Type=simple
ExecStart=/usr/local/bin/tone-wallpaper --watch
__E__
W etc/systemd/user/tone-wallpaper-watch.timer <<'__E__'
[Unit]
Description=壁紙スライドショーのサービス開始確認(6時間毎)
[Timer]
OnStartupSec=3min
OnUnitActiveSec=6h
[Install]
WantedBy=timers.target
__E__

# --- ウイルス対策: 定義更新間隔の選択 / アイドル時の簡易スキャン / 5日毎のフルスキャン ---
W etc/tone-os/av.conf <<'__E__'
FRESHCLAM_HOURS=3
__E__
W usr/local/bin/tone-freshclam 755 <<'__E__'
#!/bin/bash
# ウイルス定義ファイルの更新(OS起動1分後と、設定した間隔毎)
exec 9>/run/tone-freshclam.lock; flock -n 9 || exit 0
mkdir -p /var/log/tone-os
{ echo "=== $(date) ウイルス定義更新 ==="; freshclam --quiet; echo "rc=$?"; } >>/var/log/tone-os/freshclam.log 2>&1
clamdscan --reload >/dev/null 2>&1 || true
exit 0
__E__
W etc/systemd/system/tone-freshclam.service <<'__E__'
[Unit]
Description=TONE OS ウイルス定義ファイルの更新
ConditionKernelCommandLine=!tone.test
ConditionKernelCommandLine=!boot=casper
After=network-online.target
[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/bin/tone-freshclam
__E__
W etc/systemd/system/tone-freshclam.timer <<'__E__'
[Unit]
Description=ウイルス定義の更新(OS起動1分後、以降は設定した間隔・既定3時間)
[Timer]
OnBootSec=1min
OnUnitActiveSec=3h
[Install]
WantedBy=timers.target
__E__
W usr/local/bin/tone-av-interval 755 <<'__E__'
#!/bin/bash
# (管理者権限) ウイルス定義の更新間隔を 2 / 3 / 5 / 12 時間から設定する。最初の更新は常に起動1分後。
h=$1
case "$h" in 2|3|5|12) ;; *) echo "2, 3, 5, 12 のいずれかを指定してください" >&2; exit 2;; esac
D=${TONE_SYSTEMD_DIR:-/etc/systemd/system}; C=${TONE_AVCONF:-/etc/tone-os/av.conf}
mkdir -p "$(dirname "$C")" "$D/tone-freshclam.timer.d"
echo "FRESHCLAM_HOURS=$h" > "$C"
printf '[Timer]\nOnUnitActiveSec=\nOnUnitActiveSec=%sh\n' "$h" > "$D/tone-freshclam.timer.d/interval.conf"
if [ -z "$TONE_SYSTEMD_DIR" ]; then systemctl daemon-reload; systemctl restart tone-freshclam.timer; fi
exit 0
__E__
W usr/local/bin/tone-av-settings 755 <<'__E__'
#!/bin/bash
# ウイルス定義ファイルの更新間隔を選ぶ窓
cur=$(grep -oE '[0-9]+' /etc/tone-os/av.conf 2>/dev/null | head -1); cur=${cur:-3}
on() { [ "$cur" = "$1" ] && echo TRUE || echo FALSE; }
sel=$(zenity --list --radiolist --width=460 --height=360 --title="ウイルス定義ファイルの更新間隔" \
  --text="OS起動の1分後に最初の更新を行い、その後は選んだ間隔で更新します。\n(既定: 3時間)" \
  --column="選択" --column="h" --column="更新間隔" --hide-column=2 --print-column=2 \
  "$(on 2)" 2 "2時間ごと" "$(on 3)" 3 "3時間ごと(既定)" "$(on 5)" 5 "5時間ごと" "$(on 12)" 12 "12時間ごと") || exit 0
[ -n "$sel" ] || exit 0
if sudo -n /usr/local/bin/tone-av-interval "$sel"; then zenity --info --text="更新間隔を「${sel}時間ごと」に設定しました。"
else zenity --error --text="設定に失敗しました。"; fi
__E__
W usr/share/applications/tone-av-settings.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=ウイルス対策の設定(定義の更新間隔)
Icon=security-high
Exec=/usr/local/bin/tone-av-settings
Categories=Settings;
__E__
W usr/local/bin/tone-av-idle 755 <<'__E__'
#!/bin/bash
# アイドル時の簡易スキャン: 無操作が10分以上続き、前回から6時間以上たっていたら、最近1週間に変更したファイルを検査する
grep -q boot=casper /proc/cmdline && [ -z "$TONE_AV_TEST" ] && exit 0
S="${TONE_STATE_DIR:-$HOME/.local/state/tone-os}"; mkdir -p "$S"
STAMP="$S/quick-scan-last"; LOGF="$S/quick-scan.log"
IDLE_MIN=${TONE_IDLE_MIN:-10}; EVERY_H=${TONE_QUICK_H:-6}; TICK=${TONE_TICK:-300}
idle_ms() { xprintidle 2>/dev/null || echo 0; }
while sleep "$TICK"; do
  now=$(date +%s); last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ $((now - last)) -ge $((EVERY_H * 3600)) ] || continue
  [ "$(idle_ms)" -ge $((IDLE_MIN * 60000)) ] || continue
  DIRS=(); for d in "$HOME/ダウンロード" "$HOME/ドキュメント" "$HOME/デスクトップ" "$HOME/ピクチャ" /tmp; do [ -d "$d" ] && DIRS+=("$d"); done
  list=$(mktemp); find "${DIRS[@]}" -xdev -type f -mtime -7 -size -50M 2>/dev/null > "$list"
  rc=0; if [ -s "$list" ]; then nice -n 19 ionice -c3 clamscan -i --no-summary --file-list="$list" >"$LOGF" 2>&1; rc=$?; fi
  rm -f "$list"; echo "$now" > "$STAMP"
  [ "$rc" -eq 1 ] && notify-send -u critical -a "TONE OS" -i security-low "簡易スキャン: 脅威を検出しました" "$(head -5 "$LOGF")"
done
__E__
W etc/xdg/autostart/tone-av-idle.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS アイドル時の簡易スキャン
Exec=/usr/local/bin/tone-av-idle
NoDisplay=true
__E__
W usr/local/bin/tone-av-full 755 <<'__E__'
#!/bin/bash
# フルスキャン: 5日に1回、PCが無操作(アイドル)のときに実施する。6日たっても実施できていなければ通知し、7日で操作中でも低優先度で実施する。
grep -q boot=casper /proc/cmdline && [ -z "$TONE_AV_TEST" ] && exit 0
ST=${TONE_STATE:-/var/lib/tone-os}; LG=${TONE_LOGDIR:-/var/log/tone-os}; mkdir -p "$ST" "$LG"
exec 9>"$ST/av-full.lock"; flock -n 9 || exit 0
NOTIFY=${TONE_NOTIFY:-/usr/local/bin/tone-notify}; CLAM=${TONE_CLAMSCAN:-clamscan}; SCANPATH=${TONE_SCAN_PATH:-/}
now=$(date +%s); last=$(cat "$ST/av-full-last" 2>/dev/null || echo 0)
first=$(cat "$ST/av-full-first" 2>/dev/null) || { first=$now; echo "$now" > "$ST/av-full-first"; }
if [ "$last" -gt 0 ]; then base=$last; [ $((now - last)) -ge $((5*86400)) ] || exit 0; else base=$first; fi
overdue=$((now - base))
idle() {
  local sid t busy=0
  for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    t=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
    case "$t" in x11|wayland) [ "$(loginctl show-session "$sid" -p IdleHint --value 2>/dev/null)" = yes ] || busy=1;; esac
  done
  [ "$busy" = 0 ]
}
if [ -z "$TONE_FORCE" ] && ! idle && [ "$overdue" -lt $((7*86400)) ]; then
  if [ "$overdue" -ge $((6*86400)) ] && [ $((now - $(cat "$ST/av-full-notified" 2>/dev/null || echo 0))) -ge 86400 ]; then
    "$NOTIFY" "TONE OS: フルスキャンを実施できていません" "前回のフルスキャンから6日以上たっています。パソコンを操作しない時間に自動で実施します。" critical
    echo "$now" > "$ST/av-full-notified"
  fi
  exit 0
fi
L=$LG/full-scan.log
echo "=== $(date) フルスキャン開始 ===" >>"$L"
nice -n 19 ionice -c3 "$CLAM" -ri --max-filesize=200M --max-scansize=500M \
  --exclude-dir='^/proc' --exclude-dir='^/sys' --exclude-dir='^/dev' --exclude-dir='^/run' \
  --exclude-dir='^/var/lib/clamav' --exclude-dir='^/var/lib/snapd' "$SCANPATH" >>"$L" 2>&1
rc=$?; echo "rc=$rc" >>"$L"
if [ "$rc" -le 1 ]; then
  echo "$(date +%s)" > "$ST/av-full-last"
  if [ "$rc" -eq 1 ]; then touch "$ST/last-fullscan-infected"; "$NOTIFY" "TONE OS: フルスキャンで脅威を検出しました" "詳細: $L" critical
  else "$NOTIFY" "TONE OS: フルスキャンが完了しました" "脅威は見つかりませんでした。次回は5日後です。" normal; fi
else
  "$NOTIFY" "TONE OS: フルスキャンを完了できませんでした" "エラーが発生しました。詳細: $L (次の機会に再実行します)" critical
fi
exit 0
__E__
W etc/systemd/system/tone-av-full.service <<'__E__'
[Unit]
Description=TONE OS フルスキャン(5日毎・アイドル時)
ConditionKernelCommandLine=!tone.test
ConditionKernelCommandLine=!boot=casper
[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/bin/tone-av-full
__E__
W etc/systemd/system/tone-av-full.timer <<'__E__'
[Unit]
Description=フルスキャンの実施確認(起動10分後と30分毎)
[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
__E__

# --- 新しいカーネルとの整合(ヘッダー・DKMS・initramfs・GRUB・専用ドライバーを自動調整) ---
W usr/local/bin/tone-kernel-sync 755 <<'__E__'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
L=/var/log/tone-os/kernel-sync.log; mkdir -p /var/log/tone-os /var/lib/tone-os
{
  echo "=== $(date) カーネル整合 ==="
  newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)
  [ -n "$newest" ] || exit 0
  apt-get install -y linux-headers-generic-hwe-24.04 "linux-headers-$newest" || apt-get install -y "linux-headers-$newest" || true
  command -v dkms >/dev/null && dkms autoinstall -k "$newest" || true
  update-initramfs -u -k "$newest" || true
  update-grub || true
  rm -f /var/lib/tone-os/drivers-done        # NVIDIA等の専用ドライバーを、次回起動時に新カーネル向けに再確認する
  echo "newest=$newest running=$(uname -r)"
} >>"$L" 2>&1
exit 0
__E__

# --- KDE Plasma のスタートメニューボタンを、アイコンではなく「Start」にする ---------
convert -size 128x128 xc:none -fill '#1f8f5f' -draw "roundrectangle 2,36 125,92 14,14" \
        -fill white -font DejaVu-Sans-Bold -pointsize 38 -gravity center -annotate +0+0 'Start' \
        "$SRC/overlay/usr/share/tone-os/start-button.png"
W usr/local/bin/tone-first-login 755 <<'__E__'
#!/bin/bash
# 初回ログイン時に1回だけ、パネルのスタートメニューのボタンを「Start」の表示に変える
grep -q boot=casper /proc/cmdline && [ -z "$TONE_FL_TEST" ] && exit 0
M="$HOME/.config/tone-os/start-button-done"; [ -f "$M" ] && exit 0
for i in $(seq 1 60); do busctl --user status org.kde.plasmashell >/dev/null 2>&1 && break; sleep 3; done
sleep 10
IMG=/usr/share/tone-os/start-button.png
JS='var ps = panels(); for (var i = 0; i < ps.length; i++) { var ws = ps[i].widgets(); for (var j = 0; j < ws.length; j++) { var w = ws[j];'
JS="$JS if (w.type == \"org.kde.plasma.kickoff\" || w.type == \"org.kde.plasma.kicker\" || w.type == \"org.kde.plasma.kickerdash\") {"
JS="$JS w.currentConfigGroup = [\"General\"]; w.writeConfig(\"icon\", \"$IMG\"); w.writeConfig(\"useCustomButtonImage\", true); w.writeConfig(\"customButtonImage\", \"$IMG\"); w.reloadConfig(); } } }"
if busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s "$JS" >/dev/null 2>&1 \
   || qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$JS" >/dev/null 2>&1; then
  mkdir -p "$(dirname "$M")"; touch "$M"
fi
exit 0
__E__
W etc/xdg/autostart/tone-first-login.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS 初回ログイン設定
Exec=/usr/local/bin/tone-first-login
NoDisplay=true
__E__
# ===================================================================
# ===================================================================
W etc/systemd/system/tone-heartbeat.service <<'__E__'
[Unit]
Description=TONE OS 動作の鼓動(フリーズや異常終了の検出用)
ConditionKernelCommandLine=!boot=casper
ConditionKernelCommandLine=!tone.test
[Service]
Type=simple
ExecStart=/bin/sh -c 'while :; do date +%s > /var/lib/tone-os/heartbeat; sleep 15; done'
ExecStop=/bin/sh -c 'date +%s > /var/lib/tone-os/clean-shutdown; sync'
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
__E__
# ===================================================================
# ===================================================================
# --- 開発者表記(開発者パネル・丸いアイコン 約2.5cm) -------------------------------
WB usr/share/tone-os/developer-icon.png <<'__E__'
iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAYAAABS3GwHAACAAElEQVR42uz9dZwc15X3j7/vLWrumelhnhGMmBlty5bMHHOYYUOb3SQbcNDhTeJsOLETO2Zm
y7Yki5mZYUbDPM1dVff3R/WMlN19nt/Ss8k+z7der5ZGParq21Xn3nvO53zO5wj+v+NfPe6991527twp3v/+93PDDTcIIYS66Ndqz549KKWM0tLSSCgUKtB1
Peo4TpHjOFVSykpd1yuEEBVCiBJN0wqVUlGpaUHXdX2AITRpHjtyBtt2mDh5FMp2syhlS01LO44TV0oNua7bC3Qppdpd121zHOe8EOK8pmm96XRqIJVO9rX1
DQ4CuTmTJwOIkQEqJV544QX1+9//npkzZ6qvf/3rf+lb+ld5iP/8Jf7nH/feey8DAwNMnjxZ3HXXXfh8PgDR09Oj7r//fr785S+LEydOIIQIxWKxGr/fXy+l
rNc0rUFKWQVUCiHKhBAxIIwQphACUAzfYuH9LFAKhGBgMM4XP/eP5HIO3//x5ygoCINSCCFQ3on58/DeUwrXdXPAkOu6PUqpDiFodVzV6rruKdd2zmaz2dM9
8Z5mDIbqi+v51re/pT75yU8Si8WGBzN8KPLX/X/9+H/6Dtx7770IIcSnPvUpnnjiCR599FH27NnDU089xYQJE8xQOOzPZrM1Psuapuv6NE3TJ+m6VgXEgEIp
pfXPjUgphQLUsL3ljVcCKEilMti2zZZNe/nal3+J49h86asfZsllszANHZ/PQkg5cq5QF+xWAeqfmbIAlHKzKPqAHtd1zzuOcyibze7OZDJ7TdM8OxiPJ3ce
OJC9ccWKf+02qP+XJ8L/k99ceUYlAH72s5/xyU9+EoAjR46EysrKqjRNa9J1fa6maXOlpo2XUkYU+ABNIRAoRH615l8xHs9GPStVwLAND/QP8pMf/JED+08y
0J+gt2cQ13WIRIPEYhHGTajnM3/3HkpKY951LjJ2IQQuCnd44Grkg0Ap5PBYvA9zgIzrukOO4xxxHGdrNpfb6tj2kZ6e3paPfvQTQ2+99TpKKXbt2kV5eTlr
1qxR73znO//Sj+a//dD/0gP47zjyBo8QQnz7299GKSWUUkpKyfLly33d3d1jfX7/HF3T5kopZ0gpx0opA56NCaFE/goX/vhXPsSzv6GhBG+v2oamSy67fB6W
ZSLwLFI3dELhACeONyPQkFIipcbAQJKB/iFmzZmIaVkXHCcFmXSWNau3kU5nWHrZHKKFERQKIUCOfPRFk1AIBEgFfiFlQJOyTDeMJYZpplzHOREMBna9+OKz
W3t7e7f19fUd2bd/fyoSjXLPPffIe+65R134Nv9vuEj/V0+Ai1f64X8/+eSTtLe3m5qmlfn9/iV1dXVX6ro+XUhZK4UIgrd6X7AEBQohxfC/YXAwzub1u6it
q2DCxNEXfolg7+6jfPvrvwWguLiQ2XMnMzyIQNDPhz56O6lElqefXIWmaYDn5tx6xwo+8am7CEdCI5+MEuzdc5Rvf+03JJMphJBcd9OlCC4Y/+lTLRw+dIpZ
cyZSmt85lMiHHBd2ISGkCBiaMQXFFKXUbaZpNgcCwT233HLLysHE4Nr29va2Xbt2pa+++uqRezY87f9vngj/106Af278QgjOnz9fctVVV002DP0aTdOXa7re
APiFt9APn8iw/aRTGSyfiRACcdHa+PxTb/K9b/+e2XMn8f1//FvKK0tGVu1wOEB5RQm2bePz+4ZP8X7pQjDop7yiBOWCYzu4ysVxHEpLiwiGAkA+EFYCAYTC
AWIlBZgDOuFw4M++Y3//EP/0k0d5/ZWNvOcDN/C3X3gv0gui8+MR2Dkb3dBHYhAhBEKIgBCiSWpyrGEa1/l8vmbHtt9YuHDhK20dHXu/e999nW1tbe6TTz4p
AKGU+r92EvxfNQGU+jPwBNu26Whvk5Y/0DCUSFxuaNoKXdcXSSmLhx1od/iEPDozfOzecYhnnnqD2fOmcM11S9F1LY/jKCyfRSQSIhIJITXtwm6hFBMmjeY7
P/gkCmgaV++9L4bNEWzHoa21i3A4wOVXzkMph9df2cipUy3Yto2lmSOzVgloGt/Ad37waVKpDBMmNlzw+wEpBeFwkGAogD9gXThPKRSCPbsO8/KLb7Nw0XQu
uXQOmiZRw7HL8H0SBHRdazJ0vck0zbt9fv+m++67b2UqlXrzxIkTJxoa6l1N04VSiieeeII77rjjf+ED/n/HX+xQSg379UIpJd58803R1tZm9vX1TUgk4l/N
ZrM7bceJO66jHOUq182/lFKO4yjHveg911XpdEZ94ys/V3Vll6ubr/ukam/rUrbrqlz+1T8wpLZt3adOn2pRtm0rx3G91z+7jvdy8i9XKaWUbTtq967DauP6
XSqVSqtUKq3Wrtmutmzao+ycrZTrKtdVynW96zn5c938z7Z7YbyO66q21i61ZdMe1dXZO/Ke7boqncupv//MD1VNyTL17ju/oNrbupRSfz425b2Tv56T/zxX
2baTyOZye+KJoW92d3dOPnb8uHX29FkBiPvvv3/4Pv+lH/t/yfE/fl978sknAcSoUaMoKipSmqYFgsHgeL/ff5tpmjdJKesBQ4mLvnD+2XV29PD26m3UNVQx
a84khBRIPNjyjdc38tCDLzJv/hQ+8JFb8fl9I64FgPav3k1vlXddl1zOJpvNkc3kyGSy5HI2uZyNbdvYtnMhMM97X0IINE1D0zUMQ8c0dQzDwLQMLNNEN3Wk
lBcQpn9mfxfcnmFgSPH046/z6EOvcOmyOXzwI+8gGPKPjHOgf5DDB09RXlFCbX3FhV1hGMb1vovtus45O5t7IZlMPpnNZg8IIeLl5eUXNqn/4a7R/8jR/3NX
59lnn2XcuCZZWlo+IxgMvMMwjBulpo0WfxbM5d18IXBdF+W6PPTgC3z3m79l0pQx/OqBb1BcUjByUdd16e8bJBQKYloGKm9zQlwwMAGkkml6e/rp7uqju3uA
3p4BOjt76O7qZ2BgiKGBFPGhFMlUmmw2QyaTIZfN4boKKSRCSoTw3BJN1zB0Dcuy8Ad8BAIWkWiIwqIIseJCSsuKiMUKKC6OUlxSSCxWgD/gy49r+FG6KCUA
geM4dLZ3U1AQJhQOer91Fa7r8MhDr3D/jx5h3oLJ3PfDzxCKBPPGMBw45xN4AoRCOY5zJpfLvZBKpZ5saWnZPnHiRMcL4i+c9D9xMvyPiwH+WXCrjh07pi1e
vHhMIBC427KsdwgpRwkp9OE5IvCCTQUYhu7h5AIQksKigrxhxTB0bRh48QxKSopiBd41hGdM2WyOwcE4p0+d59jRM5w60UzLuXY6O/oZHEqQSWdRSqHrAn/A
R7QgTDQaobK6mHAkSCgUwOc3MU0Dw9AYNiDHcbFzNpl0hkQyTXwoyeBggsHBOM3n2jl08ASpZAbHASEkPksnWhCitDxGVXUp9Q2VjB1XT31DFdFoCMsy0XUd
KTSqqssuvm/5nyGdzhBPJOnrG8R13YuMX+QhVnFxMk/out4gpfY3pmle6/f5nunv73/41OnTR2fPmmVzYaH5H7cj/M8aLfCTn/xEeAkbTcXjAzWhUPjmcDj0
fl3XJ7gobRiPH3YwBvqHePxPL+PYLnfcczUlJYUoBS4exn72TCuFRRHv/WF3BM/o06k0Pd39tDR3cGD/CfbuPsaJ4+fo7OzBdRxC4QClZcXU1VVQU1tOVU0p
lZUlFJcUUlgYwR/woUlvldc06SEwUoy4PRcegfJ2GKVQys2v0grX9RCiZDLNQP8Q3V19tLV203q+k5Zz7Zw71057WxeDA3GQglisgFGjqpk2YzxTpzdRU1tO
cUkhfr9vJEM9/Ik9PQNs3rCH+vpKJkwaDXIEIaK/d4CDB05QU1dBbW3FyEnDa4cCx3Gco6lk8o+ZTOaJ0tLScxdNsP9Rk+CvfqR/vnIpIYRQO3bsCJZXlF9Z
WFD4fsuylmmaZsLFzBtw8+dt2rSHj73v6+i6wf2/+iKLl8wcuaY7ct0LAFAmk+Pc6RYOHjzJnp2HObj/JG2tPQCUlccYPaaGMWNrqauvoLK6lPLyYgqKIuj5
HQQPU83D8CpveMMr6zAviD/PIKuLqBMjVIrhjUpeSHjlsX0hwLYd+vsGaWvrprWlk9OnWzhy+DSnTrTQ1dmPQFBRVcKUaWOZNr2J8RMbqauvxDRNEJ4r5F1f
/NnEcF2XP/z2OX79i6dZsGgqX/v2xygoiAwPc4TmIRAo17Ud216bTqd/F4/HX96yZUu8rKxMLl68WAHqySef5LbbbvtLm9D/9vif4gIJIYTasmWLHg6Hm8aM
Gf3xQCB4s6brpRcb1YhfNPyAFNTUVrBwyXSEgqqq0j+/aP6VzeXo7Oxl2+a9bFi/h717jtLT3UcoFGDCxNFcec1ipkwbQ2VlKYVFEYJBP1KKkbhgxCjyK6jH
z/FWccdxcF1vVVeuyk/MvJ+tRkhyIxNHSM/NkVIgNYmmgOHdgwvxh6ZrxEqKiJUUMXlqE8p1iceTI5PiwN7j7Nx5mPVrd/PaSxspLAozcfIo5syfxJx5Uyiv
KMY0TdTIx3v3DAXZbI5UKkd/fxzbduBid2jkPiuklLpmmst0XZ9qGMblc+fO/Xk6nT4wYcIE+09/+pOYNWsW/Itw/a/r+KvdAe69914ymYyYOXMmt956q9q0
aVPR6NGjbw6FQp+2LGu8kMOMMe9LdHf1sXPHQeobqhjTVI8UYmSFT8STKKUIBf3eiponqHV393Ps8BneXr2NDet2097eRbQwzNRpTcybP4WZsydQWVWGz2eO
+OsX7xbDLM1UOkN8MMHQUIJEIk1/3l3p7u6nr3eA/r448aEEyWSaTCaLbds4rusFHEIgpUDTJIahYVkmAb+fUDhANBKioDBMrDhKrLiAgkJv8oXCAcKREH6/
5XGERhCl4d3Fiyuy6Swd7d3s2nmYLZv2s3vXYTo7e4gVRViweAaXr5jPxEmjKS4uRMoLnKWe7n42bdxDfUMlkyaPGWaojiSXc9kslmWOPKv8bqdyudzxeDx+
/8mTJ5+cO3du9ze+8Q2+8pWvwF+xW/RXOSqlFFu2bBGtra3illtuUWfOnJoejRZ+JhgMXm/oesS9aNNWecf0Nz9/kl/c/xSLlk7j69/6GCVlRRdW6BHXQeA6
Di3n2tm6eR9vvbGdgwdOYBg606aPZf7CKUyd3kRDYw2mZXj/3/XoZ1J6q6NSisHBOOebO2hp7qD5XBtnzpzn/PlOD/kZjJNOZ7CzORzXQbkOijwbVHiJNADN
iGD4ikAz8t/ZQ6YUCuW6oFyUq8B1kFJh6BKfpREMGBQVh6msLKWuoZLa2nKqasqprSknWhDxdpDh+8LwJPWM9uTJFvbsPszmDXvZseMg2UyOKVObWH7lAuYt
mEJNbcVIsix/8ojTr5S3e617ewdvr9rGlVctZN6Cad5OOPzdEDi2HU8mk6/F4/EfVVVVbVNqhL/6V4kU/VW5QMMIz4oVK1i5cqV66pnHQufOnb2xpKT0M6Zp
ThNSCpWnKsBFFAPA0HWkBrou89wcMbJxSwG5nMOZky28+tI6Vq/aRuv5HqqqS7jtjiu45LLZNIyqIhoNA+AOnwcoV5FMp2k738mh/Sc4dOA0J0+20Nbaw1Ai
R86RIA2kYeFk0ziZXnRNYPmHfX5t2MPxDFqYGGYM3SpEGD6QeffGs1xAoTy8Nh8UOyjHxrVzZLMZ4v0JWjrOs2fvGVAOpqERjYaoqi5lzJg6JkxsYNIUz13z
+S0vgy1AtwzGTWhk/IRGrrluKadPtbB+7U7WrNrBj3/4J6qqSrl02SyuvGYR9Q1VaIbuOWcXBQjJoRR/evBF1ry1g4H+OBMnjx65Z/mRIzQZCoZCt1o+a1xn
Z+fPdu7c+dTMmTP7jx8/LjZu3MiTTz6p/prigr+a6bhmzRocxxE+n4/q+mo10DPQUFZe9ploJPpOw7IKLvbxHce54JLgBbPxoQQH9x2jtraCqurykeRSJpPl
2NGzvPziWl57aT0DA3GmTBvD1dcuZumlsyguLcLQ9QtBpxDYtkNXVy9nTreyc/sBdu44xMkTLQwOptB0P/5QAf5IMYYvgtQthKZjJ7oY6j6IYw/+WaJKiOGR
G+h6IbpVjNQsz7KkBlIgNA2Q3o6RT4gNU/KUq0DZ3k7i2LhOFhzb2zGU4/3sONh2DidnI1FEowHqG6uYNmMs02eOp76+ktKyGLqhe+5Snj7t2A69vQNs2rCb
la9tZs+uYwQCJpdfOY9rrlvC2KZ6LMvCVZ4z6dgOD//hRZ57ejXX3biUd7/vhhFXaKQG4kJIg+M4Q8lE8rF4PP6D6urqky+88AIlJSVkMhl16aWX/qVNzns+
f+kB/POk1ic/+UH9fe/72Py6uvovRKPR5Sq/hArh3dyd2w+yZtV2Llk2m1mzJ3oFJxdBdCMP13E4eaKZ117ZwCsvbqC3p59Zs8dz7Y2XMG/BFIqKCxh+XjIf
YA4NJTh04ATbtx1kx7aDHDt2hsF4Ek3XsfwWPp8P0wpiGGF0XwwhfSAkTnaIePdRctkeFA5/FvcpiZR+TF85ulnkre7K8VwVTcMRGo4L0QI/1VWF2Lai+Xwf
2Zx3HaUczzVycrhODmXnwMmhcC/UJeC5VgIFjoudy5LOpMlms/j9Jg0NlUyfNZ45cycxeepYCguj+dIBL6ARAgb64+zYdoCXnn+bjet3EQwFuPraxVx7wyWM
bar3UC4U2axNe1sXseJCQqGAt0sNlyHkH4K4CI4A4aSSybd7enq+u2HDhnV33XVX7qJf/sVdor/op/9zxuYjjzzinzZt2u01NdWfD4XCY727c2EPTqXS/N2n
f8hrL2/imusX8c37PkG0cBiiyyMrrqK7q48Xn13DS8+vo72th5lzxnPLbcuYMWsChUXRi3Kdgmw2R9v5Tjau382G9Xs4cvgM/YNxhBQYloZm6Pmg2UUKgSZ1
dD2I6S9BM0Lg2KSH2shlh3CdDMp1vQwvEpAIYaJbBQgj6PliYqTsEUdBQSzE4oVNLJo/hmjYAgTb9pzliWd2kErnQDm4roPr2Cgni5vzJoCQatjqEG5+H1Te
hEC5gHdeNusl2BwnRzDkZ/z4RhYvncHiS2ZSU1OOaRlcDCAPDAyxa/shnnx8JZs37qG8opibbr2CG2++jJLSIi8WuvgZ5l/JZJrVb2xGCLh02VxvclxEzshm
sqf7+/t/0N7e/vBTTz4Z//Z99/1V0Cn+KibAL3/7WzVh/PiS2qqqT5SXl3/KsqzoMMJy8Sht2+HXv3iS559exc3vuJz3ffBmLJ81As0MDsRZu3o7D//hJU6d
aGPajLHcctvlLLl0JsGgHxAo4e0QgwMJDh06yRuvbmDjhj10dPYjdQ3Dp6MZ2kWcmzwpQDne7oJA13z4gpVoehA7l0IaPoSSuIk45Byk0PI+vQRNQ0mJKwFd
ghDYjksk6mPBgjFcuWIqpsiy7o31rH1lLZXV5Xzg7z/MEy/tZ83ao2gaOK6NcrxXNpVizOgyqqqKWLduH1IocIcDZjc/KVxwbS74I/maYscll3VwXIfSsigL
Fk3hiivnM358A5GCUD7m8G53IpFiw7qdPP3Em+zdfYJRo6t553uuYfHSmUSioZFlyUUhFKxds53PfuL7GIbBd3/4KZYtn4frDkNm3lbrKjU4ODDwy1Qq9WOl
VMepU6dER0cHt912218MKv2LTICL3Z6dO3dSUlLS4PP7v1RQUHCHruuB4YENb9EXU4ATyRStLR1UVpaOrDKuo9i39ygP/+El1ry5jcqqEu585zWsuGoBJaVF
I7uDQBAfSrB1y35efWU9WzbtpW8wjuW3MH0GYhiqyePhQgik1MD1Vl+Ug0BgmgX4gpUI3YeMFqJHYrgDAzitrZCzEULmMX2B0jWUpqF0iZKeuzZpciU3XT+T
0iKLdSs38NKTr9HV3cWyFUvYs3E7n/jyx8kGyvnpz99ACHDd4RjAwclmKIj6CAQMzrd2IUbQogvoEfldYDjFZbveRDANAyE0hLcik06lCIQMps8azfIrFzB/
wTQKiiLefVcKTZN0d/ez6o2tPPHISlpaOllyyQzufOeVTJnahNS1EU7Unl2H+YfP3U8mnePeb32YS5bNuWj9v6g81HXTyUTy2Y6Ojm/+7Gc/O3b//ff/RRGi
//ZP3LFjBx0dHWLWrFns2bNHzJgxY0o4HP6OYRjLhBDGsNH39Q6wYd1OGkfVMGHS6Hz97YWJMKyg0NPTz4vPreGRh15lcGCI62+4hHfcuYIxTfVcrMyQTKbY
vnU/zz69mh07DjOYiGNYBsawC+A6gIsQ2girUwC6GcLJJlG5BCDQjRCWvww9UIhRVIZWUAh+HyqZwj5+CgYHkUik0ECTYBi4hk5OKIJhk6uumsTll43nyJ79
PPhPj3L6WCv+sI8PffbdzF44k5/e+z2mz5rK1Euv4GvfeR4757kzynFxnRw4No6Tw3VzSAESF5+uSKZdHMcdcYu8r+ThWaXlRVg+i872QVzbRRtOFijIZbJk
kkNg2kya2sg7bl/OwsXTPfLcRUm9UydbeP6Z1Tz/zBoMQ+Mdd1zOLbevoLS0CFd5Cb+jh0+TSWeZMGk0Ab/voso6daFATYBylZNJp9e1t7d/4fiJEzuvXLFi
JCn/3z0JtP/8Jf59x69//WsxZnQ9W7fs1WbPmbk0FA791NCNpUKIPxvL7371DN/55u85e+Y88xdOJRIJXgD181SAA/uO8f37/sBzT61hzNhaPv+l93HbPVdR
Wl40EtymUhl2bD/Az3/6OA8+8DLHT7WAKTH9JpomRlY7ofKrJ97Pwy/XToGTASHRzCiGVYxmRTELytFCEYTfj7IshN+HZhiIZAaZsdGEhtQNMH3YQlJdF+XD
H7qEKeNLeOjnD/PgLx/HjJVTUl/NXe+5nkkzJuMoxbkjJ+jt6GXKvJls2n6STMZGu0Brza/soOVzFGMrTa6fF+FES4JUNp9RFhLHdgmFA9xx9zI+/NHruerq
2ZRXxDh9qoNUIodA4ihB2AhSHiwmpyRnznWwds02jh05Qyjsp7i4ANM0EAKKYlFmz5nEpCmjOHWqmReeW8P+vcepqCympKwI0zQoK4tRVV2WD5gvrFWO42Lb
Dlr+fSmENHSjIRAIzC0siJ7ee2T/6drKGhUMBkUul/s3WtJ/zfHflge4mNPT3tWrzZo7/WqUuA/ERHURbjC8Avj8Fn6/D9PMJ4ryqL6QkvhgnBeeXcNDD75C
OpPhfR++gVtvu4LS8lgeNvQSXgcPnuTZp95k1Vs7GEgksQImvoiFytMSLrg7HqzoGdcIpDHC5xHCQDeL0PQgUg9ghkuQZsA7N4/jI0GWxpCZHOrkOYQSKGHg
Ipgxq4o77phFf9d5vvjpX9PenmDxPfcw0NvP5PoCxk8ZR1t7D6VlhcRKY+zdsgdDF0QjAQb700hNer72cFwhvPFpUiOZgd0nkqRzwzQMRc52Gd1Uzd33XM6Y
UeU8+6eXaG0+z7s+cgf3vHsZv/n5StKpHJqAsOHHQiPoi6AHg+TcDFu3nmLvnl+z5NKp3PKOZUyaPAbd0NF0ydwFUxg1poZnnniTRx56hc996ke8673X8Y47
V1BYGPGYpWI4T6MYHEjw2J9eoae7n7vfeQ0NjdX5Bw2WZU0pKor9JBAIfrn5XPPzzz//gn3FFZcL/ht3gv+WHeAitEd0dXXpoWDw+qGB5A/u/8nD43JZh9Fj
a/+MyAbQOKqa6TOaWHH1IqprK/LwoeLcmVZ+8qM/8ejDr1NXX8Hnv/Rerr1+KdGC8Ijf3tMzwKMPvcRPf/wIW7YexNEFVtAEFLpuEC0oIJ1KeYgNnk/s+fd5
KDEf/KJchDTRrWKEtBBCwwwUYQQLEYbuBZeOjdAkSnqJLKdvANU/hIuGrQuWXT2eu+6azfYNm/jOV36CKIxx8999mu6Obkq1NFdfu5TTp1tZ/cYWqusqcNIp
9m7by1W3XsWRE520tg6g5ZEXcdEOMEyuG0o6tHTlcJXmBZ0SLrt8Bh/9+A1k4v384Cv/xJZ1u8im0xw9cIRb77mG1tZBzpzswdRN/JqJA+RQuALQNaxgCIXB
4UNn2LRhF0ODQ9Q1VBIIBkBAMBhgytQmJk8dw4nj53j1pY2cO9NGw6gqiooKvPuSX/8P7D/BN7/yS7ZtOURZWRHTZ47LLxjenZaaFjMNY7Zh6G2FRZEjoVDY
3bgR8fvff43/DjW7/64dYNi2jVis6BaluG/dnt31zzyxinOn2pk9dzJFsejFJewUxqJeIKW8B+NkbTau28XPfvIozec6uPX2y3nXe6+nsqo0T1eAXNZm08bd
/PGBF9mx6zDSMvAXevCj43oQoWPbxIeGEEqhaQGElLi5xJ8Ncjj1L4WJ5isGYaJc0H0RdF/EY03mcuAopLC8YHf4oQf9OKEAwra56bbprLhyIo888ARP/OFF
5l6/gsV338GezXtJnj7Cuz56G/F4kl3bDnNw/ykWXTqb4rJi7JyNUA4V5UUI0Zx3azSkkOA6qDzdwXW8nUczNHLZHIVFYW69bRGXXjKF1597k0f/8DzSH2XK
/Cm878O38M2//TabVm/k2uvnsH97M3ZOMeS4Hs4gNTQh0JSDUAItYGAFQyTiA/zut6+wYcNu3v2+G1h6yWwsv4Vu6sxbMJWGxioefehVnnr8LU6dauHjn7qd
pZfORjcNFIra2goWL53JyRMtNI6qQeYXCobzNigQst7n930fge9sy/lHFy2qyqYT/z3F+P9HdwClFF/72teGbUtfvXrrravf2vbtt1dta3jlxY30dsXp6x2k
ra2LE8fPkclkqagqRcuzKoepxNl0lqceX8n3v/MgrnL5uy+8hzvvudrD9PPBcOv5Tv7w+xf45S+e4XRLJ1Y0iGYZHtlMN5CagWtn80klhWlG0XQ/rp0BN4v8
M3UdhdQsdH8pQui4joNphTH8hQhNx1UOwtCRhuHtBIYOysXNZnAyWQwc3nHrdJYvH8/Pf/Jrnn5mJdd9+L0svv1mzp5o48jK17jr9ssJhiMMDKXRDJOK6nKq
asqIRPxsXr2JBUvnkjZC7D/chi4EmuXDKCrEzaTBcTxSX57yYdsu4ydU87GPX0dNZYR/+t7vWPnmVubeeB3+cIhJTVXMvWQOfT3dbH57M9fevILutiTdzQl8
uokmJBqSqG4wORik3grgIEkqMAwfgUCYttYe1r+9la7OburqKyksjIBShMJBps8YR11jBdu3HuT1VzYAiqamBgzTIBTyM2feZC5dNpspU8eiGZ4UzAirME8V
klJGNE2f4Q9YPV/4XOrAm6tfVOPHT/JAif+DhNL/YxPgYrenufmcFggFrh/oG/rej77zYMOaVTsZ6EsgNR3bdjhy6DQb1+8iUhBk/oJpSF2OsBp7ewb4zS+f
4be/eobxE+r58r0fZulls73qLuHx17du3scPvvsHXl+5BVuTmCHfCHwqAM0MYAUKsVNxNKFj+QrRdD/KzeFkE3joz0WDlyaGrwQwsLMpDDOE7ougXIWjbIxI
BGlZoGlIy8BF4WQyuNkcUuV4xzWTuOKSMfzoOz/jjdWbuPUzn2D8JZfS3jbEthde5Ip5Y5g8YyJHDp9m+7YDWJZBSWkBRbEI0XCAdW+uY8z40WixMvacHUSz
/MiCCLIwispkUckkmtRQCDRDY9nlk/ngB1Zw/vQpvv21f2TINrj2I+8lVl3JkfUbuPbGpQjLRyxWwFsvvEHj2DrGjm9i//YWdGlgCB0NSa3PpMmyKNQ0bFcw
kFNIV2BInWAoglKSPTsPsXvnQUpKCqipKUdqEt3QGTW6hkmTR3PyRDPPPPUmfX0DjB/fSDgcxO/3UVgYQRtR0Bhe/gUHDhxj1/ZDAPh8VnTdml0z33vPl1tf
fXnv4TnXvMu1O98So5pm0tbW9j9rAnzta18TAFv37JZVFZXXWKb1w1hJYWMkEuTwoVOkUzkEAikEuqlz9XWL+PDHbyNaFB1RWTtz6jw//sFDvPzCeq6/cSl/
94X30jSuwWNXCklPdz+PPPQSP/7RI5xu7sAsCCDzJC4vOJWAQDMsDDOAm0lj+iJolqevk00O4OQyaDJ/GwQgNHRfCQgdOxNHN/zoVhjXtkEKfEWlyGH1NtNb
/V3HYViZ8MbLRrN8QR0/+d4vWbt+F3f/w2epnTGHlpZBju/YQTjRyq23X01razcvvrCG40dbaDnbxp5dB9F1jYmTR7Nu5VqihVEqx49nV8sQIhxCBgMoXfNc
tqE4uaxLQVGYd75zMVdcOpFnH32Wn//sIUbNW8Dyd94OQmPbyjWUBgWLLl/Ivv0nKa0opbe9jWP7j3PFDZdx7Gg3A70ZdF1DRyMoBRFdkHEVHVkHx5X40fGj
Ywod0/QRLiigr2+I9Wt3kkgkaRhVmU8yQml5jJlzJpJMpnju6VWcOX2eMU11xIoLhs3+wt/5eO2F51bzvW89wJo3d7B5415ef2VTpL8vNVMK1dzbuunYnGt9
bucLb9POD/5nTIAnn3ySz3zmM5w7e1Y8/cILYsHcuUujkciPNCmbpBSMHdfAof0nOX703IiiWkFBiL/57B1MmDQKlUdiDuw7zn3f+A27dx3j/R+6kQ9/7DZi
xQWeyyMlx4+e4Uff/yNPPvEGOSEwI35GeGeeU+tRDwCJhiYNNGmimT4QOk4mgZ4doDjkI5UbhqEl0iwALYCdjqPpJoavAMfOoLAJlteiB0O4Ai+zK8EVyvNr
Ncmls6u4cUkjv//5H3ht5Qbe9aXP0jBjJs3nBhjs6ePkmte59YYlBCIREsksmZxDQayAYDiI6wqkBtNmjGfX5h0opZhz6UJ2n+0jh0BoXmLNVYp0/xBV5WE+
9uErqK3w84/f+SdWr97B5e+6iymLF9Lb3kVvWycHN23i5lsvB8Pigd88TXllOWMaq1n10iqWXXsJCcfgyJEetHxMkVGKAVvRY7vEXYEuNEw0TKFhSR1DStAE
M+dOIFoQ5vVXN3LyxDnqGiooLinExXOJZs+ZhN9vsvLVzezfe4LG0VWUVRRf4B6NFNwLIpEg27cepOVsN63nuz10StMKhJBThRs+Hj+eOxXre4laKpn9jh9x
6NBTf70T4L3vfS//8A//wObNm8WLzz7PJYsXTamrr/tpwO+f7n1hSXwowbNPvUVzczvFxWFc5ZBKp5m3YApNTfUIBNu3HeAbX/0lZ8+08Zm/eyd33n01/oBv
RNFh88Y93Pf137B1+0GscADN53FohBw2fPlnJWJCWOiGH6mbCM0AV5EZ7CVqulQXhegcynh6gkYIaUZws2lAYAZi4LrkMnECZTWYBcW4UuBKidB1MDSErmFL
yaQxRbxrRROvPvkSj/7pRW7+zEdoWriQs2d6cZXk+IZ1jC4ULFg6n/b2XlpbOqiprWDchAYmTGxkwuRR1DVUU1AY4syxU/R29XHFDVew83Qfg2l3BDmxXZfx
9YV85O4FZAY7+Oo/fJv2oRw3fPTDFFeW09PcilAup48cIyiyXH3Tcs639rBn91FC4QALFs9gz/rt+P1+6sePZvuuVpStkHmYOu1CFi+TLRmGVvM7taahaxpZ
x0UJSTAY4MTRs2zcuIvi4ii1dZVIKbEsgylTmyguKeDN1zezeeNeaurKqKmtyE8ANaLjW1gUJZez2bp5Xz5/IPPPjJiQ2qS47ds1UHvJ+eLpk8SLL36Au+7a
xv79J/46J8DHP/5xcrmcOHbypBo9dsyoWbNm/bg4VrxUjHDePRmRgwdPMG/hFD79d+9k5qzxZLMZJk5qZNToWtav3ck37/01iUSKL9/7Ia65fimGoSGEIJVM
8cJzq/nBdx6kubUDfzTgGaKUSE3Lw28iz3AUSKERKSqlsKQSxxGARAqJymXJJfpJZx06h3KejIg00KwClK1wczaGL4KmWdjpQayCIqyKWrJCUlwaJhDxkXAE
ms/A0TRKYz4+eO0Eju/cxY9/8DuWv+8uZlx9JSdO9JDOKJK9PbRuXsPtt12J1Ayeffo13nxtPSePn+XE0VOcPdNCd2c3KJeq2nLifYMc2neYq25azr7WIdoH
s5Bf/ZdMKOGdy8dxYOsWvvalHxBpHMfy97wLZdsMdnQilDf+o9t3ceVViyiuKCObsWlqaqSkrJjKmlKSPb3s23GAq265gr17WxnsTaPhoiHQ8JJswxUV5NcR
TYp8maYgm8uRyWUxDI2S4ig9XX2sfGMDuq4xdkwdluVV0I1tqqO2rpw1b21l1ZtbqKwqpXFUjZc+GV6hBBw7coYNa3eNrFhCeYiaYzvl0YLgmKuuLNzy3W9P
7+7o+olobo5x9uy2/zKb/S+DQS3L4m//9m/F4OCgeuWVV0qampq+VFZevuwi7RgQgsKiKF/8ygew/D40KZgwcRSXXDYbIQRrVm3lvm8+QCDg4x++8gHmL5qe
X9VhYCDOQw++wGOPvE7aTuMPG17Jo/QIZ0LXwR1mQnrBcVlVFUuuuZpAMMimN7bQcb7T49bkbJSSkMf2ATTdD67EMCR+fyG2q6GyaaxIISXTZ5B2BemBOAnb
QZMSaepofhNTh9svG43q7+DHP/gVky9fzJwbr6a5uZ90MofUTU7u3MnkcVWUV1fQ1tqN0DTqR3u7XSpt03+6nUw6gxC7GTu+nuqGKgaGBhjo7qEoZOGqITQJ
l08u4bqpZbz42LP88YHnmHTF1Uy+ZDGJrk6cZAJNSKQmOH/6HKWFISZPn8D55g5ef20jpmlSVFxIcWmEqQtnsvaNDQz1djO6IUrL4XbQNVB5DpPydgTlOJ6N
6t4CJDTQDImp5f+7cBBC0thQS1t7B7/5+dP0dA3woY/eSrQgjNAkl14+B9My+N59v+db9/4K5bosv3KhVwch4OzpVp55chWuA1JTea/V240WLp3KjbdcumjC
pIZ7tYD/Mw89tKLdg43u/y+DR/9LJsDFtOaHH3k4MG78uE9UV1XfrhuGd30vtzcS+ASDAdxhxQQFPp+PdW/v4L6v/55wJMgXv/I+Zsya4EGYQtDb28/9P36E
F59/G2mAYUlQ5H1vCzSJiwDp5p1zUI6LZfkoLi/GTmXRhIZumOC4YDtIYeRHL5HSQEofju0QKAhh+UP0dvQghaJ4yhRCDbUYqRRGyEcimSaXyBAMh9D8JpdN
LmZyhZ9vfPGn6EUxrvrwu+joTjM4kEZqGunBQVItJ1n4vmvJZHIEg35uu+MaMpksyVSagYEEPT39DPQP0dPVQzqVpagkRjadpfl0M8WRWkypuHpaOVdMiPHg
L37LM8+vYf7NdzBq2iQG2toQuYxXA+065LIOzcdOcvVV8wiEgvQPnCWRyhJP2Zxt7iIUDXLL9QsJBgIc2XOIiRNGseb5LWQdA90IAnlSoHKZc9kYcBUHtp9D
+SSuXyIsgSZtfNIjfKdtgQPUVFUTDIZ46dn1DA4k+ORn7yJWUoiSgoVLZnCv3+S+r/+W733rAYQQ3iRAsfLVjRzafxpNF/j9Bpm0jeM4+AIG97z3GhYtmq45
jnNjNptt7ujo+EZZWVkC/utyBP9pF+hi43/ve9+r3XrLrXfW1NTca5pWWOEpI7Sd7yQRTxIalua76BBCsG7tDr5176+JREN89ZsfYfqM8XkmpqClpYPvffsB
Xn5pLaZfohnyQvWWZiF8nkCt1DQcV1FfW8nohmpaW7vJprNIYdLV0kVne5/HcMjmyA0N5ZE4iZAaQpogdYSU5HKKbMYrPPGXV1A4eSLKlEifhhny4Qv5kFKi
+QwaKwK8c0kDbz77Givf2Mo7v/ZZRKiY1pYhQKBrJmd3baPKSnHZsoWcOtXCm6+upfnseQYH47iOSyjkp7qmnPETGpk2YwKhcADTMti8ZhPlleWMnjSOkrDB
8vExfvXTn/PUi6uYf9M9lNTWMtTejqZctOEuNFKj+fgZ7KE+brjlKjK2SzgUZOrUsYwf30D9qGoi0RA1tRU0nzxJZ2cnS5cvYu0bm4kP9SJw8JkBr55BuUye
W0u4MMi5Uz2kTEmnodMmLXqFRUqaBH2CkAkZV2CjEQoFKYhG2LXjEIcPnWT8xIaRXE1VVSkTJo1i29ZDvPXGViqriqlvqKK/f5DqmjJuuGUpd7/rGgJBH3t2
HcbnM7jh1suorCgB0HVdnyKE6Dpy5MjegYEB96677hJf//rXefbZZ/9T9vtfmQlWn/zkJxdUVVV90bKsAvB494eOnOT7334Aw9D58tc/TF191cXmz/Yt+/j2
vb8mELD4h69+gMlTxo5MjLOnW/nefQ+wft1OfEEDoQ1TpEdmD2gGSsujPUKjuy/hlS4aFqFIEcn+pEcOcz2im51Jg6vQNCP/HiC84EtKiaYbHhXYFyTS0IjS
BV6xCSDFheyya3PZpFIGzjfzyEPPs+yu66gaO4aDh7u9gNV2aTlygP1vvcq1l83A9Fm0t7Zz9uRZgoEgJw+fxnYchBQEIyEiBVGCIR8Tp4xm6vQJVNRUcL7l
PLfVx2go0Pn1j3/Jy69tZPaVd6L7AnSfO0c4aHnfX3kxlp3NcerAIW68finSMFj5+no627spLY9RWlpMcVkxBUUFpLI2jRNH8/rTr+E6WSpqCunp6gJsLN1P
yCxAk5J1Lx3AMA1cBboDelaRRpCTBgO2QUdGY5Rfo8yXYSgDWdfF9AeZPmUsxw4f5Ztf/RWf//L7GTuuHhRMmdrEP3z1/Xzra7/lvm/+DtMyueLKhVyxYsHI
82wcVUNfbz87th0k4LNGbAEIW5b1d1VVVSdisdgbK1euFK+88sp/2mj/UzvA8Or/7ne+U5WWlTU0NjZ+NxqNzh0WWxJSsG3zPv74u+dpa+9h8SUzqa2tyCcB
Bfv3H+ebX/0Vtm3zla9/lJlzJnmyfELS0tzOfd/8HRs37sEX1PJ6ORdQTgChW+CPgG6AriN0g6zjkkplsUw/FVU1lJYUkcrkiCczKFeRHejHSWdwXY9MJqSO
kGZ+FzGRmglCEigpJTq6HhkwPGDiIv0h23WZUBFkxYRifva9XzNgK27+zAdp70oTT9i4qTRHN6znxLbNZIaGGOzpZcGimcSKCykuK6K8qoxYScxzo3SDXNZm
cCDO2VOtDPT3MXPOFLraOznf3MKCRXP53f2/5YUXVjPpkuvQfAHS/b1Yho6ueXIqUggMU+f0oWPoToqbbr+G3t4BNm/aQ39/nO6uQZpbOjl+7ByHDp2kqrqM
WDTI2lfeZs6SuSQSOQ7vO4XUXBwnQ9AKYBkesqZc5U18KdBQ5KQkq+soIXCUoD8rKLIUxX5FypY4Lhi6ZHJ9lGNHzrBlx2GmTGsilpeZLK8opr6hgvVv72DD
ul00jW+gqqpsxKZ8fpPJU8cydXoTY8bWjpAhAYSUBVKImvb29s2apvX09vaKd7/73fzxj3/8758AF7s+nV2dodmzZn+5pLT0duFVg4wUpUcKQhiGxsxZE7j8
yoVYPgsh4OTxc3znm7+nq6uPr3z9w8xfOD1PrpScPX2e+77xezZt3oc/pI9wRi705JIXJkAgAqYJhgW6gdB1pNQI+INUVVUSDvoYiKdJZR2cbJZUdzfjxlUx
f/44OtoHyOYEUjeRug9pBRCGiTAsrMICjFDAozrIYZqx990tzeXu+XUc27aDPzz0FDd+5sP4y6ro6EyQGhji4KrVdJ8+Q2FpGQXFJZw6cpxo2Me0WROJxqIU
xKLUjqqmcWwdjePqqR9VS0VtGaUVxYSjQUaPqkU5LtvWbufk0ZO8+NIqxsy+HBkIkxkaQNc9qUVdk2hSouuSTDLFsZ17uOnmK6iurUQ3dMY0NVA/qobS8hgF
BWECwSBD8RTRghBjR1WxYdVaxk+dQLSgmC3r96FJ4dUZSIVl+jy3UihsoXAVuEhsCSlNxyXPghWSjCOpCymkUGQdQdZWRCzBhJoCDh09z7adx5gwqZHi4sIR
d6iuoYq3Vm5mz66jTJo8itKyfHcbIBTyU1tX4Ql3Da89+cVP1/UaIHDkyJF1SqnskiVL+NrX/uPEuf+QC2QYBkII8fzzzwtN01m69NKbY7Hid41w+odV/oDS
smI+83fvyddfeDtDZ3s3P/nhQ5w+eZ7Pf+k9LFoya0Q389zZNu775u/YsvkA/rCJEMNt4S6SFcz/JIREaTroOkhP/gMpUI4iEA4TDPrRdImua5imQao/h207
zF0wjltuWcypE130H+vGkAbSCiJ8nkyJ1CU5RzHU1Y9fglUUQmgaUngNLmY2FFBmKX782AuMmjmTuunTaW4ZItE3wP433ybZ209hZRVKOWimQWFVFa+98jZz
Fs6gqLiAV55/k+7OXmLFRYSjQYqKiyguiTF6VJVHHQj4qK6vYWBggGcefY2mpVeghwpIDcaR0vU6y7je33bOxjV0ju3Zz5i6MqbOnMCp080c3H+MwlghxSUx
xoyu8ZicUpJKZTBNAysQoKC8kOaz55g6awGWz8DO5tCkoD/ZT8q18fujuLqJIzTqqsrIphTpnItwXAxTQ9cldg4Stk5X2qHKr0jlXOJZQeegS3GpwbJZo1i5
7STf+ebv+dK9H2TUmBqUo1i8eAaf+/x7+f59f+DH33+Ye7/1UapqyhnW9bugqsGFQpp8jj8YDN7Z2Ni445e//OXvFi5c6Km3/AeD4v/QDvDYY4/x5S9/WSxd
ulQlk8np9fX13wkEAvXkmeoj4xgu5LhoXMmhFD/78cO8uXITH/ub27np1su9bVwKerv7+c43f8eGLcfxh8KA7alBCJV3gS7W01RIKwihPDVZ8xJgQkqEJqkq
KaGksABdk94OkLFJ9g1gDyXo7Bxi395zHD/ZhaskwvQhgyGixSH8YR9ZpedXfok0dKSheZRkpQjoiltn13B0+26ef24NN3z2Q2SNCB3NnexftZb0QJxQYZHH
2nQdUC6BUJDmU2fwWwaz5k4mlUiwd8dBhvqGaG/u5PSxsxw7dIrD+4+zb89BooVh6hpq2LNzHwkCFI8eTzqV9IxDuV6uT5NomkDXNQZ6emg9vJ/b77mBgsIo
q9/azKkTzXR19HDsyCmOHDrBsWNnaGvrIpvOEomGKC2LcXTXfhKDSSbPnMbGt/eRSWVAKMZMaMAM6nT09JATgqySFFYV05dVDNkCW2oURSzKoyYDcRtT86jY
5T6HrC1IZhW5nE0sKAn7dQKmydbdxzl2/Byz50wkGgkhpKBxdA2WZfD8M6vp7u5j9pyJf9bpRlxkOBfRKISUwtR1fdSYMWN2RaPR5mEL+4/sAvLffQbwsY99
TEybNk29+dZbscrKys/4/f5p+aJOchlPZSGdyfJnq7YCJ2fzxKOv8OxTb3LbnVfyjjtXoOs6IBgYiPNPP32MTdvPUd40FyNQ6GVn89eVUiOU1+QEkFJDSIHp
N7ACFlKXSAnoGobPRzgcRNc1bEeRs5WXHrAVum7S2ZFi27bTZLIKqZtgmJSUhfjcRxfydx9ZSLQogGaaSEP3CskTWbLxDNlEhvFlQYoteOaxVxm/aA6VY8fQ
db6Hw+s3kxgYIlBYiBIuSigEDigb02dRVlfPqpUbOH7kJFOnNXHVdYuZOG0MY8c3UN9YQ1l5CZFwmN7OQXZs2YtlGTSOrSebTZNNpTylOOWilMqv/DlyuRx2
LsuR7dtZsmQWtY01uK7LtOnjmbNgKnWjqikujSE1jYH+IU6faOHVl9ezedMeDEOnoqKKgZ4BpJQEwmGGNR6GBodIDiVQbhYnl8FVcPh4N72JHJrPi5cKwzp1
xQamEPh1jbStMZCW6MJLmmUdSTIrEEpQEPQxqrqEXVsP8cPv/ZHu7n6EEOi6zq13LOf2u5fzyotv89CDL5BJZ/PP/QJdIpPJ0t7a5f3OW/vQDWN8YWHhZ0+c
OFEmPLm9/1DXmn+3C7RmzRpc1+HY0VN6U1PTTQUFBTcMy3TmcjZPPv46Lz2/hptvu4Jb3rF8pLeWUoq3V2/nj79/icVLZ/H+D9+Kz2+hUKQSKR74zTO8unIv
pePmgWaix3tw0+aIyoGhaZSVRGluyZFVLpqu4zgOjeWFBGNRdh0+61GoBZimQdDvQ9ck2ZyDz29hu4pBKdE0E6npIKTn1hgWrmkSDFuUFoeJp3NohoamFJrh
5Std28HOgiUlU+uKOL7/CMdPtfCuD97F0GCGEzv2kBiKEyyJ4ToK6Xr+MJ4KCspxKCor5VjLGV54+lU+9bn3MW/hNE/EAUEm55BKZkgkU/R095Ozs2RzWRrG
1uNkV2NnMwjDYFh1Wrlg51yUX3Du6HHKIhaXLF9CS0s7XZ29lJeXMGOm13I1l8vR2ztIb9+g16gjmWLKtCaE65LJZEknU54EjN+PkhqKLM3NbV43GsNC+PwI
y4/SDS/hqEl0NGJhjboynd1HwdAg50jiWY2I4aJJj1yezroon8BvGMQiQRqqS9i8di+/iT3N33zmLkLhAJZl8N4P3MSZM608/IeXqGuo5LobLmXYplzX4fVX
NvDEo69zxZXzuOtd12EYXtbf5/ddVVhYeMfGjRt/Adj/kcX83+UCKaWor68XDQ2N+PzW+IqKih/5fL7q4ZmXSKT4xU8fY93a3fj9JksumZXX2JQcP3KGb33t
N0SjYb74lQ9SW+ehQY7j8sQjr/DAg68Rqp2Gr6gcJcAXDqO5aXKpARQKXZc0VMfoG0yRyznevJAaaQz6U1kyuRzDsYLfNKmOFeEzDZRSDMUzuC6k+odw01kP
8dF1dNNE81noAT9JGw6e7mHL/jb64ja66ZUAyryUiaugpjTAVTMqePBnD0NhAQtvv44d6/Zy+thp/EWF+fLJYcEq1xOtyr80zZuYB3btYuLE0YwaU0dHezfr
V28hmUhjGBqRghDV1aXU1JShS4lhGKx/exMYUSyfH3AZhsN0TZKOx+k7c5y7330T0aJCXnlxNbt3HODY0ZMcPXySlnNtDA0OoUtBRUUxY5vqGDumlmjI4uk/
PM0LjzzHde+4mrKaela/uY9MIomrsgipUFLib2zCX1uHa4NSEqmbGJqOhsu0epcpdZLdR9MoJVGuwsLBrzmkcw7JVI50OktpSMdvaiQzDhnbwdQ1du46jqZL
Jk8dg9QkwaCfUaOr2bnjEBvX7Wbq9CYqKooBRTqV4eE/vsSrL20gm82y/MqF+ANWPhEqDF3qozVNW/+Vr3ylTSkl7r77bh599NH/+glwMerz9po1gTFjx34l
FAqt4IKHg2EaBPwWoZCfG29e5ikzSEFv9wDf/84DnD3dxhe/8gFmzp440tZn1crN/OgHj2CWjidS2eA1apCgWxZlMYvMYBfpdAbTkEwcVUzvUI501pPsRkgy
ukXa9dAjXTdQrovfNKgsimHqOkIIkpkchmGQ6B0kl8ygmwaGz0S3LDSf98Iw6Es6xDMumqkTKw7iC5jkHJC65+NeMbMSc7CD3z/wOFd88E4yGGxZswM9EvLG
zbD2lYtUDsJ182WMnmSJPxAkOZSgvbmFJZfNw+ezWP/2Vg7tO8WhAyfZunkfWzbvZfv2A2TSGaZMaeLwviO0dQwQKioeqXyTeVjy/KH9XLZkOkuWL2ZoKE5n
Rzf+gA/DtLBtl8HBJOfOdLB39wEKC0JMnDiavu5efvWT3/Dyc8/zng/ew4pbbuDZ53Zy/Ggbws14CnTKxaobjVldx+CpczjpHLovgG6amFJQoA9y1RzFlDE6
zWfidPXLvPijiyEcUlkPis6ks1QVmoQDJiCIJzO4roPj2GzdepDSihhjx9UjgNLSGBWVJbyxcisnT7QwZ94kwuEAWh7AUMrl6muXMGVak7c75eNBTdMKDcMI
NDY2rl60aFFmzJgx4t+DCv2bJ8BFlV0KKa+PFRV9TtO00HDQK/K0hdFja7nsinke6QlPa/7hP7zA88+s4gMfuYXrb7wUIQWalBzcf5zvfvsBkloZBbXjLujg
5wPe/o4WUgMdaFIQ8pvMm1xFV3+WoWQOpSSuZkAghJAauqETiYRJpTOYmk5VrBi/qWPoGhnbRWo68b5Bsqksht/nGb5l4QsHQTeQlum9b3lQqs9vIqXEdUFI
SUFY59bFdbz29Muc6uhj4TtvYcvavSSyLtLQwHWRwnN9PC7NsEZPXmEChdQEkYJCjh04SlFRmFlzpjBuwigmTRnLmPH1lJTGsCyLZDLLwOAgs+dMIjGUYMum
vRSWVY0U62u6RvuZk1REde56360kU2kc22HM2HpGja6jvrGamtpyyspjlJbHmD1rEkuWzub0sdP89Nv3s2/XTr7wpc+x5JpreOzp7WzcfAopQGXTKDuLFo4S
GD+Z+Llm7L4EZihEcbGPaQ0+Fo2HFbNyTJseI1AYpD48QIkvS0lYENAdkmmXeNImk/Gq72qLfUR9BrqUpNM5ugbigEsmnWH33mNMmNBIdW05rnKprilDCMGL
z61FSpg2Yxy6oVPXWM1ly+d7xfnaCI1uWMtVaJpW7ff7T/n9/v3l5eXMmjXr3zwB/k0xwPDq/+STT6rx48dX19fXf0DX9QvdJkZkhD02ptQ0XOVRXrdv2cef
/uB1W7zlHcvR8sSq9rYufnH/E3QMWZSMm+r5l2K4dZDHa0kN9aJcG103KCv0M3lMlMNnejnVpuNKF2XkM4Wuh/EP9g0gXIWTc5DSo+8KCaGAj0TGQbdM9IBn
/MLQUZok59q4QqAZOhiGl/DVJUPJHIauoesajusyqaEQmU6wYf12pqy4lLb2Qdo7B/EFfTjZzIhUiZQedx/HqxO+OCeCAisYoKS2jqcfe5U586d4FGIBlqVT
U1OCpk3EVZ7si2UaTJwyFkM+j51Oo/v9uELR29nOUMcZPvKFj5LO2Dz1+KvkbIdIJEi0IERRrICCSJjGhkpisQICfh/b1m3ntz/8PQO93Xzlvi8y7ZJL+NUf
17F7+xkM8l1o8oC7XliMQpLpHsCyQmi6hcBAuTqalPgD0qurUIqCkKI8aDPYq9GbgXTGJZu1yeUcDKHQpUQTAgNPqiWVzlBVWkhlLMy2w2f4+f1PUFFVSk1t
OQK4+R2Xs3/fMR7908uMn9TI8isXopTCNHX+JcjprcdCiphlWR88f/785srKylP8O2DRf1cQnEgk9JKSklv8fv9lF/e4cvKaL/+8i0hHWzc//+mjBIN+Pv7J
OymKRXHzwddDD7zA9r1tlE5cgjSH/VuV189XOOk4IttHrMCipiTCVZc0MWVGAzknDcqmuV+QwCKpNDI2uLbtTTrNQOUFoizT+3oBHyhNJ1IQxs7Y+MM+4sks
jvKaaSupKCkNUVJZTDabo6U9PpJhRYJlwJxxpZw+dpjeeJbLZs/g0PF2rGgEzc0h86oSuutgCoVhSIQ0cDWFnVU4WU+kCry+X2W1NRzd2cUjDzzDP3zjE/T1
9vLQQy+RztoUFkWorCijpCxGTU0Z9Q3VNI2p4fxAPyXRAuLxAVpP7OfG6y+lYcwourt6qKqrIplIMTSUoOV8D8eOnsPv07jzrutwcjaPPPIkz/7hOdxUmr/9
xqeZffky/umRTew/3oOu6yjHwVUOSmg4CEx/ECk0DM3nZcYdjYEBjb0pyfFzGut3udztpJk2OseLr9rsOxoki07WtUlmM6SSXltYvwV+Q0MiSKVztPUOoZQi
mUwhpENFSZjD+0/wwG+e43NfeA+BgI+CwjAf+tg7OHzoBD//6aOMG99AbV3lv2hkPmxk+R4QSjf0hcFQ6Pb9R478cPK4cf/mgPj/rwt0se8fixWOjsWKv2cY
RoXCk8t+e/U2nnr8NSKREGXlxSNtf3I5m9//5llWvbGFj33qTi5dNndErOqN1zbw29++RqRxFlY0hpBqxNgECl2CGmwjKoeoK4swbUwRS5dOIlIUIsQQIpsF
3Y9hBXDRyNgKx8UTrxISx4GSgii1ZYWELB2pSZQQ5LI2OcehvrGU7r4Ejqs8WFXoWJEQRtDCQZB1yQfAGi6CyiKLSyYV88xDz+EUFDJmyQLOnO0m1dtD/7kz
xDvaSff0ku7rJdXXR6q/D5XLEPJbRMIBLNPIG3++OYauEYxE2bNlN3U1xcycOQ7lOMQTWYbiKTo6Bzh0+AznzrUwb8EM0okku3ceJVJWwdlDe5g4torrb7me
zs5ulHIYN66B8eMbGD+ugdGja2ga18DCRTOwDJ3f//yPvPHcWyTjfdz+7lu54X138dhrB9h1qBNdCtxMBl/QjxkK4AoNV9OxauvxFRSiZ3KonIuuW2jSwNB0
TCmxsxpRv6DQp1i7DpTye62VclkS6STBqEUimaLQLxlXEcSQgtaeOKc7+wHIOS6ZbA5D17FMi/0Hz1JSWsD4CY24SlEUi+L3Wbzy4jpy2Rxz503Ow+XeceL4
OZ56/HWymRyVVSUIjzkpdU3WaLAqGAh0CSH+TbHA/3YCXKzh+daqVVpjY+OnAoHADXj1DKK7q48ffvcBnnlyFYahccmyuV4gKCVbNu3l/n98hAWLp/Phj92O
z28hpeDokdN8/zsPkvHVEaoYhcBF0y7wDIQUOPFeBs8dJDGYoKcvy6mWIeIDQ4wuN3htQzvPbR7gZFuO1u40g0NZHEeBpiM0HYWksiRCyGdRFi2gMGgRDpog
JTnHob1zgJ6BJGgaTs4eyTAqTUcGAqRzLlKTSM0rc3RclzlNhdSGHH7788eZfs1lDGUdDm/eQaqzHb9lUBCLUVRcRKy4iFAkgq4bOLZNJp1DuS7BgI9QyI9u
eMG0Y7sYlp9M1uHgzl0suWQmkyc1MmFcPXPnTGDenInMnj2BMaNqKY5FCfh9bFi7je7uPoJ6hne//y56+wd44okXOHr0DCeOn6WlpZ1UIklDYzUNDZX0dvZy
//d+ReexHgKmTs3ocj79jc+zek8ba7c3E/SZ+A2NQNBHuMjjU2WzORzdwldWjpu1yfUNoiMxNBOfYSKVQHM91nlBSCPs1zl73EVTnmSL9EFnfz/RogB9fUPU
RA1Glfixcy6Hm3voS6ZBQigSRAFZ2yUcihD0F7Jt514mTRlNRWUxAqivr6K1tZO3Vm5lTFMdo0bXjiiA/O5XT/Ozf3yE9vZOFi6aQTgSQIGSUiuUQmb3HTiw
5rnnnlNz585lxYoVnDx58n9p4/+WRJhYv26dmjh+/PRAIHirEhgqbzahUICp08YxdmwdTeMavGIKIejq7OPhB1/C77f40EffQTQaAmBwIMHvf/MMLT2Cgprx
XJDl9rjlmgDSCRLnj+KmEgil4TiCoYRiy+5OduztYc/JDH0JSSoDdg6UDWQVwlbDniyOUnQODNE1kEAgKAiZFBf6iUT8OMrFDPipqC3HVQ5SExQUBnCzaYQC
y5QYusDQBFIoSqMGc8YWs+7NjbR1d9PZ2cfZQyeoaahiwtwZ1E+YQGFhIU4iTsepUzQfOkj36TPkBhOYUkO5On39aVLpHIUFYcrKCvEFfOQcl5Laelo6kzzy
xxcRUpDLJNm8YSfHj5wmnUxTGAmB61BbV0FFaZCec4d5xx3XU1ZeiqHpTJ8+0WtjKuB8SyeDg3GCAYv9uw7yw6//HCMVYc6kWQzZfXzosx+hZVDx9pYzRAN+
CkM+CgsCRGMRdMvAdhxyCoTlw01ncAaH8OkSTepIJTB10F0bmcui2zaDvQ6drWA6Ep8SFPkMKsvDpDMZDh9sJpvKUB4yMZSkuXOI1r6hEX2jwaEE6WwOlCQc
LKapfhyZQcVvfvUkfb2DIATBkJ/3ffBmCgrC/OmPr9DW2jmC/IwaXUNFZTGlZUUYppEXuhcCpTTLsm4cM2rU3I9//OPu3r17+exnP/sf3wEaGxvF1q1bKSkp
8dXX1/+NaVnXChBedkdgmSYTJ49m6WWzmL9wOoah4bouL73wNs88tYoPfvQWLrt87ogUxovPrebRx9dSPHouZiDsFWMLz/A16aEQ8eaD5AY6MKQXcA2v0I4r
KCkKc7w1Rf9gDlfhVTAJbYQCgaGB0EhkHdIOBP0+qoojuK4ikc7R3jtIxrYJhfy0nDmPch2P3WnbOI4iUBjF5/eErjRNYGpw7axKwtl+fnDfz5AFRTRduoho
TTW6z0LaNl1HjnJozSraDu1HJQaJ+jUiPg2VGqTv/Hl62zqxbQWaD1cJwpEAvoAP23GxHbBCEfZu2cG4cTU0NFaxcd0uNmw6yMFDZ1i/cTeu6zBl0ij6+gao
rG1g1rxZdHd3I6RiVGMVTU31jB9Xz5TJjUybOpaDuw/yu588RkVsDFcuXM6ba55l4VXzufT6G3jk5f2kMhAO+gAXV4Hjurgu2I5Cmj7MYBgn5xAwXRpLg/R1
59AQuFkH6Tge1KnAcMDMCVQcTCFx0jn2nTxHVveeV8RQzBsVQzku24+30p/JXgQIePTzYKCAirIGTM0iEoiya88+QlE/k6d6lPiioiiaLnnx2TVEoyEvgScF
o8fUMmfeZK64ciEleRLdcIc/KWShECJ5/MSJtZMmTsyNGjVK/O/coP9lEPz666+jaRqXX3656u7unmyY5o1CCKmUpwev8Kq5wpEg4UiIYbZG87l2HnnoVaZM
G8tV1yzON12DUydaeOjBlwjExhAKl6Bcd3geeY3WMkmS54+S62tFKigKBci5LkOZjMfndxQdPWkSiRyO4ylDCCHz3SDzLUtdRbgwjOH3k8u6tA8m6BpMUhEL
4bouTfUxkqkEbZ1DCOVi5BGeXDaHsHRcx0Zq+R7prmJqbZQJpRbfu/enxE2T6z//CVLSYqBnEHtgkKOvv8nQmbPMnT+DKTOnUddQS119GdGIDycTp6/5LEcP
nmD9hv0cPXyARGUtmWwJZVUFFJdGkb0JhGHQ117OA795jp/86qvc9a4bOHumk8FEhpbzHQT8FnYux9wFc6hoT9LV2c0bb6zDzuXQNEW0IMjyK+ZTVVXK+tWb
efShlxnVMIulcy7h/LED5PQkt99zB7uOdtDZkyAUCHrti1zPBck6LrarULqJpUvsrAPCJmAoRlWYnDsO5FX1EAqP3uTiDkEqJzHwGvz1JgfpTcWJVhbBgE1T
1KAwYNIbz5B2PQN1HRfTH8AfKUQiKCsox29FcHM2xdESRpWP5bGHXmXe/CmMG98IKFZctZD1a3fx+COvs3DJdJrGN2JYJtOmjxtpzpHHgkaIc7quX19RXv44
sIE8ReJ/hQj9L12goqIiTNMUR44c8fn9/lsNw2gc8YmGldsYLmv0OCrZbI4nHn2d7q5+7nrn1SNBcSaT5eE/PE9nr6CsejyaAt1VaI6DzGXw6S7Z7tNkus+h
C9ClIJ5KkUimsHMuds4llc5ysrmfwXga5Xq6QHKYpjz8RRxFJOKnpKwYzbJI2oojbb0MJDI4jksqmWOgP0F//5AX5Goyn0DzINh0IjVy7cKgzpKJZax7fTWb
tx/kms99AidSSE9fgmRfP1uffAI50Msn/vZjvP9j72f27CnodpIDGzfy9tMvsPPNt8n0drFozmju/cJtfOiOueQ6T3L2yAk62wcxLINYWZhg2KJ63ASOnejj
yT+9RjQWY8L4WsaOreayK+awYP4UXNf1pBfzD3LMmAZq6qoxfQEa6muIFUZ55bm3+N1vn6Wsfiq1oyYRRGPr7reZv3QBofJK9hw8j89noOteRV1WQdJVJB1F
ygUbhaMcBDbKcQnoNg2lWYTKkEpnsZ0sjpvDdjJUVgUJ6xKZdhCOQ2+ynxN9bSRyGc6eOk/YTjOlthDbdYm7klBJGYUlZfjDUSJFpUQKiigvrSYSKkQoPCVt
JRhTMxqVMnj4wRdJpdIoBcUlhdx5z1Ukk2ke/9OrZNIZT4XvomYew6oVw/whKWW1aVl3tLW1+RkR1v7XeUL/6g4wjPw4jqO6uroaLcu6ZdjGFIruzn5MyyAc
CTGM/ksh2Lv7CK++tI6ll85g3oKpuK6nmbN18z7eXrOf2oZ5FAZDpNNZXFeQy6ZIDrUiMwbZnhZ0HDS0EVnEyppSquoq8PktEsk0qWSKnJagpz9NLmcjNd2r
4NIATWIaBkP9SRwtgen3URDxM2A7NPfHqSkKk7MVhmVSXh4jEU+RSKSRUqKQKE3Ddlxcx0VKycTaKGYmzhMPv8SMm6+hYNQojh09j7Jz7Hv5RaJujg9+5KOM
baqn9cgBtr36Ml0Hd8NgDwaul7Ax/QTLy5m8cBaLL59PWeHl/Pi3b3LmsMQfmkisIkxphY5h6GQmTeHZJ95k1vwpTJjQyMqXX6O7Z4jS8iKuvmqR1+ookyWV
TDB2bBXhcADT8AiCr7/0Fs8+u4a6CbOoqBlFYSBEf1cb54fO8anrPsmRU530x7Me2mP5sF0XkZFousRyvAYbUjlojovfhFBUY9E4nSmjFEumSPadUKQygkza
wXUV6USaAldDUzCUTtKe7kcph5ChUVoSZM6oCH5TkrZdujIKYfkIWT5CFKNpGpZuErLCCLQ83Ox1tzENnRlN09i6YQcb1+/mihXzcV2X2XMncenls3nj9c1c
esVcll46O69C7S3G2XSWdDpLOBIc4V8ahnG9LvUHHNvZrenaxZ0l/vcT4Be/+AUAvT29nO85L+or6m+VUtYOrz57dx/lH7//ICUlRXzhqx+iON9sLp5I8vST
b5BJp7ntzhWeWpjymi4/9fhKTLOSkqIqVNrGcASuq0gOdZLtb6WvYwCpHHSpjSisLV0+j+tvvYxAwCugcRyXnO2Qs126e4fYvecUu/ac4nzrAEYwTLi8BKVJ
NNNCaRd2B1cImvsShHwm4aBFYTRER89A3s+XCFxcJVC6TiDoQ9c1DEMypjzEllWr6cu6XHXNFXT1JpBC0rpnN+nTp/jwxz5KY2Uph95ezabHH6SBbiaV+giM
q8JOpXCHBsk6OboHzrD+kRMc2XWAez5yOx9551K+/YuVtJ2NESuPEg6bGLqGUnUMdLTyh189xdd/+DkmTxnNyZNtVFaX47gumaxNNptj27a99Pf2ctNNyxgz
tpanHnmBN97YwZjp8wmEI3SeOca5zo0MdbTgt/yMahrD1qN9SMMkEAygWya2Y+NK5bUodhTKdnAdhe66lFg6o0s1Zo7RKAxnmN4UIJtTnG5z6cqk0AT0dQ8R
NUOklEN7eoCMm2NceTnRoEVBGCIBBwdFT8ajT2tSwyss81xWnx5El15rK+mFcB7b1XUpj5VR2l7BU4+/wdTpTRSXFOHzW9x25wpWv7WZp59YydRpTUSiIVAe
/+yXP32UI0fO8PFP3cn0mRNwlas0KSt8Qf/tmzdv2rto8WJ3eGH/567QvwiCv/jFL9Lc3CyampqUk3MaI5HIl6WU1cP+1trVW3ns4dfp7Rlg+ZULiMUKEEKw
fesBfvmzx7j62iXcfNtyRF724tWX1/LCs9sYPWoulmYhHOWJN2QTDPScxEl1o+F4aIOQHq+8opj3fexm9m7dwU++/k+8+vRKVr+8hj1b99DR0kI4aDJj2miu
umoO4yfU4i+MkDUtMo7rKahpHjXacVS+kYRHRisImSil6O2Nk05nvZ4ACJAaWjBIJFaAGfBTEjGZ1xjh4Z8/hNVQz9hLFtDR2ktuMM6+559l8eRJXLFkIef2
7+LtP/yCpcUDTJ9cw9h3fZwJ7/4bymcvJNF6hlxPG5GAQWlY5+ypZo6f6eLyFfPJZnLs3n+OisY6IoVBTJ+B6dPR/WH2b99LwFAsuXwWg919FBREiBSE6OpL
kc44DMUzjBpVS9PYGh5/+GnWrj/AmJkLSKYSHNmxHifRRbTQwFYZuts7KI4VsvCSubT3p8m5GqYmEcpBOC7SVWiui6YUphCUFATo709xti1JT1+GoqDFQy/2
cfRsjmzKRjgOKpfBLyUhTaPHTjJgpwloJmNi5UQsE58OUlekgLYUJG1wbBfbcXFchSYNAr4wumZ4E0ITXg40PzkkgsJQmF0HDhCJ+Zk0aTRKKWKxKL09g7z6
0jomTB7DqDzVprOjmx9974/s2XWUMU21TJ0+DkAghdQ0GfEFAmt//POfdy5dtOhfrRn4FzvAggULRmZJOBi+QpPaOEaAJsHCxTN4z/tvoKSskNq6ShCQSmV4
9sk38fl93HjLMkzTwFWKtrYunnrsTWKFDYR8EVzH8bqdaJBI9ZBJtIGbRUl9hEvk4tESpBTs3LaHY8dOsuzqK6msqyAxMMC50y1seXsLjuswccoEll1zGXdf
PZXWgSzrdp1i/6ku0jYYujZSNihchWlJXOG1DAqH/CSTGVwhQSqEYaKHgmimpzVUGvWR6uvhxNkzTF4yn4GeIXJ9cYZOn8GMp5g7cwb2QA87Xn6WhcVDjC83
CF92I9VX3I7QNfxl9VQtPUL8yE5cIKQLZtcF2XZkP5tXbeaKS+ewYcdZ2s52UFYTQ9Ml0ZiFg6SvexoP/+llps8eR1VdGdu27CdWWoDrKpqb2ygpjjB5Qg0P
//ERdu4+w4R5Sxns7efU/q1cc90lXHPT1fj9Ft3n21nz0hs8+eAjTJ01jflTalm9rRmpPBxfAKYu0U2NZCKDa7vEB1JIJZBK0dppc+68IJ21CJrgZjOkc0mU
k0NpGgNumoTKIYSkKhIjaoRRZJBKYTsu3RmXZE5gWTpFsRBFpRFKyguIxSKEQkGvXxleMnWwO8XJfe0MdCaRCqKBMKMrGnjmiVUsWjyD6ppydEPnhpsv462V
m3nmiZUsWDCVYChAcUkRd737Gg4dOMHsuZOQeQExlEJKOTYSDq+49wtfOPTVz3/+3xYDiLz1nzt3rrS0tHSFECLo9aT1uOh19VV85u/fjabJkWbVB/cfZ/26
nVx/86WMm9CYb6wsePWltZw708+MqQuQrsozhfKts9QQUuTwWxpVhUHOdCVxNRPN0OjuGqCra4CrbljO6pfWs2fHXsoaaph56WIsUyJyKfpaW9i/dR+//c6v
KKup4Jo7ruHOZbOZNWGQlVtPcb4nganrGJpEEzAQz5BK5QjoAr9PxzR0cF0cATIYQA/5veSXEEQCOr0dHQylMoTKSulp7yPT00/PsZNUl5TQUF3O2Z1biA6e
ZNEUnbSCcEU1wjC8KjDXRU90E9VtbAE5VxCQMLlM48jGLcy6bDETRpVyoLmNbHYc4ZCJi6SorIC6KeNobz7HL372GN/+7ieYM2cc2bz7M7qxkmjE5I+//xN7
Dp1h/JwlJFMJTu7bxvvedwN3vOtGzh4+yesPPkfP+VaUpiN6Btm9ZhM3/s0UduxuI5N08GkaWV2nsNBPbWWUrTvOkEOgS0Eia5NzFdms4nyn1+pJSIehbALH
yWJIDXRJEpscLqXhKPWxUkxNw3EMr1hHCEoaipnWVEFlTQzDkLgqx2BfHx3nWzh7pIP4YBxDNyipKKFp6jiqG5vY/PJxepuHkALGVNVxdMtRXnhuFR/75F2g
YNSYWq6+fimPPvQqO3ccYumls/H5LO559/Vk0hmCocAFVMhjaVqGri/v7Ox8QghxXin1LzhCf+YCXUR7UFLK+ZZl/a0QIvDPImQ0TfOCR+VRHn77y6dpa+3h
k5+5m+raMgSCs2da+cmPHibgb6S4qBaUg+XTkcpFUw52tofBRA8lhUFuuWERRkEB/QMJ0lmHbM7Fdhwuv3IBRw8c5cjBE5w+fhqkRiQWwwj4Ka+tYvHlc1i4
ZAqDXd089/AL7N+2lynj61i2ZDIA3QNJNCkxDY8iIZA4OYWdtSmI+Dz9HyXQwyGMYADDNEHTaCj140v0snLlWsZcuoREb5Kh1m7ajxxmVGkB86ZP5NDq1xhv
NjNuSi3+5XeS7TqLFBrKzhDf9grpdU/jF1l04aJLgRQQ9ml09SSoHD8Z1/Szc/85qsaNIlQU9Bitpo4/5EcLFLB70y5Cfo1Lli0gPpRhIJHFZ0ge/N3DHD7Z
yYS5S9EMnYNbN7JsyUQ+8pFb2bduE49/7bsYp/Ywud5H44RScokMnee6mL50LtLw03l+iHGjizGRpAYz9HQN4WQVUoEhwU5nvdJIR2GnFcmEQzoZJ5dNI6XA
Z1oYmoHtugQ1kwnF1YQMH9KAcFWQmrnVTFwxjtpxpWTTg+zbupOXHnmRpx98ijdeeoO92/fRfPI8XR09tJ7rYsMbG3j96VdZ8Y7LCJghWo/3IlAYmiBnZ9lx
YD9z50+huLgQTZMUFIRYu3onvb2DLLlkBoZhIDX5Z+oRimF0UCCEKHVdd/N3vvOdYwcOHBCdnZ388pe//N+iQOLcuXNWcXHxVZqmFal8x0GR79F18QyTUnJw
/wk2rt/N0stmMXHyKK//FvDGyg20t6WZPGkMruPpTqqsi2VIfKakozODaRlcdfvVTFoyjbG5LPNPd/OLnz7J4ECanduPce1Ng1x69RJ27T5EoKCQt197EwXM
WzqbuKFxMpmhKBrk9g/dwJLl03j896/w/b+/j2tuu5ar77mJuooo6/c2M5TIeRPA8Ziids6lsizKYH8c23HRDYmme5lf2/UKOiyfASJHum8AN6OR7B8kHR8k
WBdDZVPo8U4aakIYBSG0YJjUuhfp3/AiWjAEgz0UVZQjSusZOHWGdNohlVPYSlLmdxjs6KC0pAo3nSSVyHjdXzQdwzLwBWDs5Ab6OxfxzNMbmD5rFmVlRWRS
bTz2pyc4fLKTifOXEi6McvbwQWIByd3vuJzzBw/xwj/+nEmFDnUlFeR6zlNR6eNDf38VD//8Ld74w5+4/tOfortlkP7zCa9bZNZjnfqEwBaQSeewszlwQddN
+gaz9PX14uYyXpbcMLFMH47rYmk6o8MVRHQ/4doANXPLKRxdQFvbeVa++Bpb1m6jo7mLaCzMmAmjufldN1FaVY4vHMFRGolkhsN79tP+YjuRaASf6SfR04em
vDI6x3GoK6/k8M4TrHx9I6NG1yKkYMzYOi5ZNpvXXt7A3t1HWbBoutf05GIiphD5HQAlhQwbunFtS0vLKiBtWdafoUHahYX9AuktlUpVhkKhrwkpSlHguoqO
9m5Psi4vVgRg5xwe+9Nr7Nt3nE//7T3U1FYgBLQ0d/CL+x9H6nWUFtd76mUKsBUhv0E0pNHa1sz46XXcdPtyfvb9n/L8k89x3U1Xk8zaHDncTCbrIqRk+dXz
WbdqLbovihkIcWzPPsIFhRSXFRMI+ognc/QOpikuLeDyK6dRWBzm9Uff5NS+EyxaPI2mMVU0tw0Qj+fAdrAzOXAceroHyaQyHhoU8KP7LHRdwxWCopDBmJjB
yhfewF9QTLiomN5z7fS1nKa+pICJ9RV079/IpLGSaDBJ7vBW9J5O/KTw5Qbx+8C0JJqbxiCH3/KyyqaukUi5aBWjMWLlrN18kJIxYyiuiuHkcuzftAM3l6O2
oZJYeRknT3RwbPcexjQ18IffP8qeQ2cZN3cp0eIiApbOke3bufKSqVwydzxP3v97qqwct33jy9SsuJlUbyedGzdQWGTSuGQybz6yikkL5xIrLqflyABkQLqK
goiFrnnP0nVs4qkUQkqcTI7u9k7SyQTKdSkIhohFi3BcRcCwqIuUUFdTTNOKOhouq6K9r5Unfvk4z/76GVpOnmXyrHHc/M7ruPr2q5gwbyrRslKy6PT0pzhy
+CQvPvE0G1euZbC3m89+/dOUFtZwcNU5ZA4ELo7KoXRFIpPi+OmzzF80jcLCKFJ6u8ArL61DCOUR5TQNhKcmkUqkicdT+CwTIT21ZCFEYcbOvfiTn/60NxGP
i5tuuokXX3wR+FcSYel0Wvh8vqWaptUNq7Bt3bSXD7/nq/zD535Md1ffiMbnmdPnWfXmFubOm8TESaNHkhNbNu6huSVBacVYL1mhpEekApJ9aXrahvAHgixY
Oouj+w6z8+19DJ1PsHX1JuYvnIIvYCGlzp5dJ8jmBIuXzmegq4P6MePwR2OseektDu09zuBgEtMyUbpFc4/N+T649PpL+MrPP43KDPGrz/+QXNt5br50HEUB
nWQ87aVAXRc3Z4OjPATCdZCOjcTFEIqhVI5QcYy68hpOrtuOk0whNYGQkkR8CFwXn2WAH7RyEyvsEgxLAkUWvpgPM6qjEUdzhwhEJeEig8Iig+KoxDK8csZs
Oo3reo35cBz2rN2IMdRPy5597Ht7E41VUS6/7UoOnu3j7/7m2xw+1sWE+cuwgiGCfot4fz9aLsUlC6Zy7vAJEscOsPz2qyibu5ySifNpWHw5BRE/Q7v201Ad
oLEhzJ43VlNWFiJsGGhZiZaTFIUDlBb6Cfo0HOXthsqx6W7rIB1PogO1hYVMqq7FNCxioSgT62uYvaKJeR+cTDY8yAPf+xU/+ez3iXd38q5P3sS3fvNFbv/o
7RTW19A2kOZcay9tHf20tw+wfcM2nnzwIXq6E2iGwQ13XsOs2XM5tPIc7qDCJwy0PDPYVg7lFeV0dwyxYe0uz7tQirHj6lmwaCqr39rKiRMX+kzEh5J895u/
5QPv/DLr3t6Rb5eslKZpFQG/7/J77/2qeNe73sWdd945Yu8SvGqv97///eJnP/sZBw4cMC2fdSUQJC+2fOpkM0ePnOPg/hMMDSRQeVx+w7pddHZ0c/V1i/EH
fQg8FefXX91MQVEjgUDY6+SuhCff53h4r51zKa0soWlCPW+9vIZxM6Zy5a3XsXnVVkqKo4wa5VU/9fcMsX/fKS676hI05aBLSXljPVklWP3KG5w4cs5TgbMM
TJ/FQEbjTEuSkuoKPvndD1DbWMSvv/SPDJ4+yU2Xj6Oq2I9yHVw7h5NvcuczNAylELkcwnXRUcQTadKuxpwls+g4cYLT23fhDwTwByP09vbjui7+cJS4bUOR
gazwIUMSEdQQIQ0Z1BEhAxk2EEENAhJ9TDVWaYSUIwiGInR19iB9FoaucXDjdkQ8zh1338gHPnAbMUuy/a23GVVTyCU3X4MqqKJp3mLSqQQndu+i+dgJ+jrb
KY0FqCor5MiO3UwoFgT7z5LtPkOu8xjZAxuJWBCw07hD/TTNqOL8wYOYPpdQ0IewBUJJWs/0I3I5qqvDOLi4eT0k0jkKfUEmlNUyqaKeVNbFZ1hMmlzL0run
UjeniDcef56fffYH9Le28P6/v4m//d77mLh4Kp0Jh8Onu+jojeM4kEo7tLb28tbLK3nr5Tcpq5tENFZOrCTAbe++nTPbuuk+PoRQkMykSWYy2MrBwcXv91Fe
UsZrr2ykp3cAIQQ+v8WVVy9koH+Qt1dvJ2d7JbLxeJLtWw+wZ+dR9u05iuM4wwCm3zTM5b3dPX6/34/f7x9RkNAAHn/8cZYtWyYaGhpULBabGAqFPi6lLBF4
FU6xWAHhSIDLl89n1txJaJpGfCjJT3/0ENGCEO9+/42E853FN2/YzVNPrKemfiaW4QPH9QousgkMNKTw9OVHTS1h1LhiHv7NY0y7ZCEz503ljZdeZdaC6ZiB
IPv2nMJVAt3QWHLZTHav30k6C8HCQmzXoeXMKeJDQ1TW1lEUC+P3W+ia1/w5Ec9REDGZNm80LcfP8cbjbzJj3iQmzxjLyVNt9PclcBwXx1FUVRQiNa+oxzA8
sSdwGV0exhns5a2X36a/o4tAJEwgGKL77GlmTW0iKG0y/aeonhZGhE1UMoMQCuHTwdIQlo7QFa7Phzt2CbKunKGuTk61mNTOWcy6XcfZtu8ofZ3nObhlC4sX
z6F+VD2bN2xnwsTRREJ+Duza53WN1Px0NJ/BxKGsrIyu1jbi/T2Mqixk/rSx7H7tVaYXp4gONeMc30Z226vk9m2i6JJLCZbF0PU02WCYPRvPMuuaKxnolgx2
Z3FwEW4WzU3TMZSkczBFfCCJaQsai8qpLyin0BdhMGuTFYLJc+qYe+0Y+rvP8+h3f8fpvYe58u5LeMeHryJWU87ZjgznuzNkbIWm6WhSMBTPcupUK6899TzH
D52iYfJMSiqqOb5nEx/+xD00Vk9g7ytnsDOKcKXF+MtqiDWE6e7tZzCdwlYuPp+fo8dOUddQztimOlAQCPrZuf0gx46cZsVVi/EHLPw+i0gkSFlZEdfffCnl
5SX5oAAEQpdS37h58/aWxsa6kZyABCgrK+Oxxx6joaGBUDg8RwpZd0GEVlFdU8ZH/+ZObr5tOZZlIoVg396jHD18ikuXzc1zfjxS2cpXN2L6SgkGopBvmpzL
DZBOtY2UTQI0jq7g2IHjDAymKaqsJFIao3FMI68/t5JZs8dRWlGE0iSnznSSTOeYv2wWXeebMXUfaDrF1XUc2LOX3Vt30dM9OKL+ZvkslGbQ2pUBafC+z9/G
+EnVPHLfrxGDPVy1bCIBS+LkHMI+A8tV2IkMpmtj5NJodoaaQouysMGG1VuoHjeWuokTOLNvH52nT9LW2cOew8cpHT+Jvr4onR02otiPGBuDYgsV0iFkQEiD
AKiqOuTsW6CijDM9NiUTZpAz/Rw9eY5rl03hCx+8mttuvIzVr77Bnm276ejooqurhznzprJ82XzirWc5f3gfleUxJkybTEl5OTV11fS0t1FREiPZP4ieGqC6
RCMaUYQGjxFOHKc0JgjGWzHjXZgkMXSbTDZDNpNBtwRKgouLIR3sbI7ewSyaZhEOhakrqaSmqJxQMIira5hBiwVXNTHnyga2r1zNA//wE2LFAT71049x6W2X
MpDROd6SJmlrWD4r3yBD0D+Y4cihUzz7h0dpPd9F3cSplFbVcu7oYaZNGsWyKy/n2OZWUoM2vpjBjJsaUbE4pU0+Flw/BStkInUdyx8kEi7gjdc25DlCitLS
Ii67Yj6nTrWwY/sBBALD0Lnh5mV86WsfZsLE0SMBsVejImp9fmvusmVL/szllwAHDx4UkydP5uDBgyFd0+YKIYIX9W5HAbouR0hwruvy9qqt+PwWc+dP8VTT
hFfssmf3SUpK6xFKeEkVoXAyXrbXw9nB9JlU1xdz4shx9EAQMximpy/OZddexs6tO3GzKRYt8aqA4kNZmpu7mTp7CpnEELmsg9R0ApEo0Vg529Zv5tTxFpLx
DJZpYug6hqkjDYveIdCsAPf8/Z2UlUd48vu/ozxicOmScRga+HQNHTCUwgR0O4fpZpg9ppQju/azc+dBFt91C+MWLyEcK6Z/cIBI/RjWbNzDABql4+Zz5K04
Q/0uoqYQNbYcVRlFxYKoWBC3qhhZKSD7Imd3bKGnr5jqGXPZceA0lqHxsfdezbIZNXzqfdfyrrtv4LVnX6G+tpxZs6ewddMuzpw6w/IVS5m9cDZSg/07tuO3
dHo7ztHX00bAMskMJbBkjnBM4i81sKrDGFUR/DVhrK6jWB0nMAv9ZDNZLNPEtCyyOU/vU+GgSccrDVUaoKE7OmHNc2eRkkChxYIbxzFhTimv/PZx3nzoWS6/
fRF3f+kOIiWFnGuO05eU+AJ+An4Tn6khpaCnN8X+PUd54eEnSKYc6sZNxBcKYaezJDtbuOO9tzDYnqXt+ADogvpZZXTH2/ns+z/Htz7/XWLlYRrG11BQVowr
NErKKjmw/zT79x7z6q6lYN68KRQURHh71TZytj0iqW9a5kiB1TA6JIQwNSnnHDtxonDEsAGplGLixIlU1dWpyqqqaqlpM4bR1IuA1XzbIe+frec72b71IFOm
NjFufGM+8wZbNu2lsycF0kDZXvcQsglUuhdT8/j9rguBkEkoanLy1CkiZTGkrtPR2Uvt2NGUlZSy6pVVLL9yNhWVMRwXDuw/Q6y0hEiRj8TQID5fANd1Kamp
JRHPsGPDdlpaekB5AWYk5Ke2rpLiyhqyrkdxeMdnbyUz1M8rv3qUmVNqmDm1llzGoa8/hSnAEh4toDigU1Fg8eZLq4mNHUPp5Im0NLcyMNjH6KtvZNo7308v
fp54ZhXhcZMIxuaw4+FO2o+lcGMFyLHVyHG1iHF1MLaOrN/g8Ms72P/qIOUTl9Cecnhj1RZWrJhLZZEPJzWIlenmlqvncOdd1/H8Yy+wdeMOOtu7OXOiGQDT
sjBNg4JohD1b1xELKebOmEgynsJN20hNIYp0ZMwHBRYUmFDsRy8NopcEkWVRutsGiJaUYPrDxIeyOPD/o+q9oyS7ynPv3z6pcujqnKcn5zySRqOcIyCBSCYY
bBA2hmsc7vV1uPa1sX392eCAs8FgMgghlHOOM5qcU+dc3V05nbT398epbnCv1UuzRrO661Tt8L7P+wSk8NB0Sc1XNByfSsXB9AwsEZgaWEmdvfeupW99nB/8
v3/n7Fvv8PHffS83f3A/1arLTLaOJwzCYZOwZa44VufydU6cuMCj3/sBDVvSt24DUkEi2crEmZPsvWID23Zu5/w7MzgeRDtD9O/I8MiPHyGWTLIwU+LCyfN0
9rWRy1WRCsKxGLW6x+uvH8X3A5e8dRsG2bNvK8eOXmBibKa50FlpipsM7mXdMELTdrdmWvrnF7NqGflcQYE2rl2LoesbdE3boJRCCahUakyMz+A47i/sA8HJ
ExeZm13i+puuIBoNo5RiIZvjjdeOIvUw5XqZRqOKUBKvvoTwbAzNwNB0kBBPhHCdBlPTs6Q7AzcA15PkyjZ3f/Bu3nrxbZxqmZtv3YVuaIyPLxJLxBlc20Mp
v0AkGkfJwB0u09vLqSMnOX74LHPzBXRDI5mME4nGiKeSxNu68aRFz6oOPvCl+zj1+jsceeplbr15K71dCcKGRkjXsADNl3RnEuTnlzhz4iJbb7yWYsVm/Px5
ujatZ/P1+4mnkmy9/R4OnZ3m6995Fmv9djpX38aphyWHvjXD8Gs5pk6WmTyc5+xjU7z2TxOMv9vGqn33sKjC/Pt/Pcaadb3ccetuUC562MCwFFo9y503buNT
n36Ah7/7M0xN4/4P3R1g3FLS3tFBYXGe7haT3/r8x9g01MviQgGBhtRMVGy59LIgZkLChPYI+p7VePEEl45O07V+A45jBNQHzcNXDhJJ2ZM0PNA8nRYzilA6
Vtxk7z3rSHfq/ODP/plydobP/unH2HFgE4uLNuWaQjcNImGTUOjn38WKy9kzozz6/e9Sd3y6163Hlz6hSBwhoZqb5t4H7mJhvM7CZA1hCTZc3c3M/ASH3zjK
Lz34Sdo6exg+P0bfYDtSKXwATSeRzvD2m8eZnVkAgpP++hv2kFsocvL4xSZFP1jYSioK+SIN222K5xW6rq3WNG1LZ1sHp06d4vTp0ysbQIyNjYV0Xb9SaFoE
oF6z+a9v/Iwvfu4vePKxV5ZtI2k0bI4cOksiEWf//u2BokvTGL40wfkLU4RjLTTcGoXqErVqDrdRAE2gCz3IsBKCVGuYWq1KMVsmmW5DSoVh6OSKNTbu3kZP
bxdPP/QM+/dvYvXqTpYWy5QqNqvXrKJSyBONxQGB53lEk0mkJnj7pdcYGZnDabhBqaUEKBFQpsMt2DXJpr2ruf7+K3j+ez/DLixxzfUbiYaNIIldCXRP0RKP
UCrkqdYbdAz2kZtdoF6tsOOW6+jrjNGR1Oga6mfnXe/l4LkZ/vIffsxFJ0Tv9fcRbr2N7PA6Rg92MH6km/Lidto3vpee6+7g6FSef/jWIyRaEvzKJ+8iqjez
hS0TLAvN1PHtCjfduIfPfO6XeP3Ft3j0oWf4h7/9Z04cOsSxt96kLaHzhQc/SCbksaq3jYXFAhghNLOFnB+GhIUyNQjpEDFRq3rQ9u5k5EKJ8XGb7TffQDFf
x/E9fM1HCYkrFQ0FKEFbKEpEN9FDGjtvGyLTZfKzr/4nvl3kE//nY/RvWEWpZhFt66FvaID2thbCIY1wSCccNrFdycjIHM/89KfUqg79azYFaj4lSbd1MHf5
Ejt3bmDTtq1cOjyP50JLb5TeTWme/MlTbNy8gU07d5Bob2VqcoZkMoIVCczJfKVoaW1janKBC+dHm+ZYsGffFtLpBIcPnqVara8ULgffPsH//p2/5Xv/9Ri1
WgOUUpoQZsgK7R8bH4tEIhERj8eDDZDNZlUymYzoun7VssqgmC/z2suHOXLoNG+8egTf99E0jex8jqNHzrNl62q6etoDOZ3rc/Cdk1RqilA4hlQ+ZafEXGma
slNDqmCOvJwzkcpEcBo29apDJJHEl02ukYKqK3nPR+/ltRdeJz8/x6237sL3JFOTOQZXDaLsBmErjK4beK6H53kkWtsYG7nMuRNnyeVruI63khaJkgjDpG4b
2FWXmz50LZnWEC985xHWrOlgaE0HGmCgofsQ0jU8x0ZKiW7oVHN5rLBF12AvITzW9MTZu7GNtZuG2HX7PWS9KH/1z4/wlW8+w0vDJUbD/eS6dlDo28VUYpBX
h/P8/Tee5Js/eY61W7bxq5/+MImIFcwhaLLSdANlhBFWmGq9yv5rd3LrXTfyzf/4IccOX+SN555H2WUefPDDtMYklu6yZfMglWqN+YpD58B6Tp938Tu7IZ1E
JROonj7Epi1UvSivfO8Eg3uuoX/zdqbGC/hC0iB4j2wpcKRBRDfJhEMIDTbu76JnTZSffvXrVHJzPPC7D9DR20HDi5DoHCTd2kY0FieZSmFZJqYeBGNMTBd4
4WfPMjM2y8C6rWiGgVISKxTG0EyWZoZ5z4fuoDBrszBZBQvW7+tm+NJF3n7zILe/707KDZdEW4b5mUVc28YKW7i+j1SSSDSKEiZvv3U8oLFIRVt7hi3bVnPi
2Hnm5xZXzJNfeOYtnnz0NX760PNk55YgcNAVuqFfaVmh2H9987/U0NCQMH72s5+JL33pSxw8eLBf1/VNIggJJNOW4kMfvZOu7jbuve/G4FQFxkanmZnO8sGP
3EY4HCSmVyp13j14hlAkFWhzlY+vFA0RKI20Zq1lIDA0iMVMPM9H+gIzEkX6MpBG6oKlXJmNOzazbe9WvvGP3+D3/vz32bS5n6nJBbZtHCBkaAgFphnCbtRR
SmGEw2iGxcmDh9l/7V4G+lsJhxtNP83ArlAJg0JO0tWX5q5P3cr3/t9PmTxzgS07BsjO5HBs0BE4DY9wKIT0HGoLOYTrYRomlmEiGzWScZM9m9rZ1R3i3Zii
LxVmemyCqdFRHn/mEDW7GojtNR2nWieZiLNl52Y+8b57Wbd2iFDEx5c2Cr1Jx9ZQGHjCxBUWImSyVKzw2uvvsuu6m2hpa+OZhx4ikUiQTEYxNYnQJAOD3fT1
tvHmu+e4/4adnHjiNKeOFtm2vxNDBxltoVTUePafX2d2KcGnfv9B8gWP+bkyUkhs3yemK6TSkVIjbVoYEga2pVm7J8MT//Jtps6d4Zf/9JN09nZQqetEM50B
X6rpUKeUQtcEriuZnKnw8pMvc+KdI/Rt2IQZjiClj1KKZKqN2bER+npSbN29g5OvZKk7Huv2tNHaZ/G3v/lN9uzdSdfQIGOzJUKxKLmFArVKjXAshASEUOiG
INPaxvGjl6iUq7RkUoTDFvuv2cnrrx7j0oVxhlb3IaXiwPV7OHd2mCuv3kFbe7rJENLQdX2NaVirP/frv7b0e7//exjvfe97xZ133olt2zs1TUsopZQAYVkG
933gFu59342BjE4pXNflyLtnCIdDbNu+rmkdqBgbnWFyKk8y3YNSgSe+9Hx8JVGGRgkNW0lMTWBpemBYpWyEEOiG2dQzK4TQcH3JYqHCBz/9AP/7f/wBrz77
MvfeexUnjo3S1tVGNGZh1210wwoGHSLQpMZbMkyNTTN8cYyNm/oIhcqBx2XIako2Ja40KBUkW67axvodx3j1R0/wiT/7HXr6MkxcXsLQBaVChfb1GWIxk6kz
50i09yGkxK03MHQPnwq1JZ++rjY6bt3IWKvHwuoIc6V1XJwuMT45x/zCIrZjM3n2CB/+5fex59r91GyJJyUNLDxd4GkuaAow8AjhYGILA6woTz38LPmqYOc1
O5ibmKSrfxWzs0VmsiXSgyk8v44eEtx661V86xtPcWnzarZcfyfDr71MbWKMtp4w9cYi77w8x4VxxQf+6A9J9qzi7TfGAIXt+0h81q6CuQVBuGERETqpdpMd
1/Vy5OlnOfnSq/zS//oAA2u7KRRswi2tmFZoRUMhBLiugy9hsehy9N0zPP/4E6S6ugknE/iyeahpBuFIggujr/OZX70b19aYGiuQ6Yuw/dpeHv/pz8guzPPg
bz/I/FIJKSWmZVGp1bAdm2gsjNAD8wOBpLW9nYnLF7l4YZwr929H0zS2bltHLBbh4NsnueGmfeiGzvU37mXX7o1EImFCEbNpXIzShRYNh63dqVTisGVZaEII
NTw8jGEYO4HwsnRSNL29jaYV9TLv/8i7Zxlc1U1X97JZq+Lou2fxCJFobQc/8K+PxUOs3dgT0CswmHeDQZHZ7ANWfgcBMrSs1hFCY7FQJtPVwS998sP89HuP
YNDgwLWbiMWixKNhaqUyhhkoipCBfXk4Gsfz4Nyxs8xnS7iepFgqks/nKOTzKCGwIhFqVYHQLa69/wCT5y4wceY8azf2YJoQMjUKS2XSrSm27drEhTcPkoqG
0IXG4uQsjqcoLuVYmhhn/vxp7JkxOmI+m3o0dvYZtGdiSCtCJN1KvV6hVCkyPjGJlB7RWAQMg5rUqYowNS1CjTBVwlRUiIoycYTFUqHG268do7t/EE03kFKS
TKUQRoRLwzM4RoS6ClHzDbbs2sTO3ev54UPPcrlqsubG9xHJXMPMVD+PPV7g0EWPu/7HF9lwzbUcPTtHseqi6+BKH4RgfklQtQ2ihoZhKLZd3UthepjXf/AI
Nz9wNZv3b6JQ8Gm4AsM0f46rC4HnetiOQ82WjI0t8uxPHsNTOqnOTnzPCzaKVMQTLTQqFSKayxVXX8HouRyu57Pv1iFmZsZ46LsP8+FPfggtEqdStVFCQ1gW
nvSRvo8VtoLoK91EaAaxVAIlDI68ewZo5kF3tTK0poejR841Za6Bv2yqJUko3DxgRWDOoBRhwzB2Pfroo0xPTyut+UNiuq5vJagClqPoVkTGSoGGxuzMAsOX
xtm8ZYiWTBIA1/E4cfwisUw70WRyRZnvuT6NuoP0g4Fzzq1TdmuYQuDVg35CIHA9H9n0jVy2tlBozCzkueXeW9mwfQP/+nf/RmtrhFRLglgiTLVUwjLDgb26
9PGlj9A0QvEYw+cuMzYyQ6XmoJTAcX18X5LMtJLItOBJjWrOYfWONfSsbuOtx56lrT1Ka0cM3YBGtc7ifIm77rubxtIic5cu09nbxdnX38HH4uJ0lfGZCoWZ
RSrT07jlCrVynYmFKrPFBotLC1TLRfLz05iGxZOPPM+pg0dpbU0Qi0eo+5BzDIoyQklFKMkQZd+k6htUXdDCUW6//zbGzp1hengEXdeDfsdzaXiSOhYVZVFR
JrZmct+H76CjI8Xf/v0P+PN/foK/f+QIX3nkGEeyPp/48h+z7Y67effcApMLNZJJaEsHPH7dEGRrFmUPlGazamuaTIfGY//0LQY2dHDNA9dRrmgU6xpSA8eu
NU9/8DyXer2K5yvmFuq89vxrDF8YprV7ACkVUvlBf6MUqXQHCxOj7LlyMx2dPVw+Nc+mvZ3E0pKv/c2/cMWBvey7dj9zCyUQ4CqFZ1grGdLCNIJsBDMwLTbC
UVLtHZw8eZl63QagpSXJ1m1rmZyYYXJidmXYuuwZIX4euSSaZrobt2/fntm1a1fQBLe2tw7oht7bTGdq+reIJvYvVuq982dHqFZrbNi4CrN5IszMZBkZniGe
zmBGQ2i6IBo2WdXXRnYqt2IZ7kqf+XoRDQ2n5mIYBqZhYDdcfKHj2F7zFgBdFzQcn1LD5VO/9gnmZmb47r9+FyE04qkY9WoFwwgC1HzfR8nAdtCMhclms1w4
O8zCUhUlNBR6EO7m+1jhEELTqRRddAH7btnO+cMnyc9lGVjThq5LTFMwfmmKDds2cuDGK3n36ecIhSzmLg9z6chxbCvDWyMOr1x2eGvY5tVzZZ44VeHNKZ/h
iWmU75OdHOXKa67g6puup1HxeOx7TzB6+gztbUk006RU9ynYGiU/TNkPU5Umdd/AlhoNT7Hr2iv42IMfJDc1zuVT5yguLbL/ul3sOXAFFVejqkKUVYiKsggl
EsSiFqFUK3asnVBLK+uG2mjt6WLNzp0cu7TI6FwFH4XbsClUbRwlCYU0IjEDKRTJjBNyqwMAAIAASURBVMWWvT0cfvp5CrNT3PLxGxDCYqmo0K0wiZYMDbtK
qTBPpZynUi7g+x7lisvZ0yO8+fyrhBJJlFB4ntu8mQOY2jAsyvPTHDhwFYuzdVo6I6zf0cY3/ulbNBoNPvqpjzKfq+JJhS8VvtKoe8F6W3bn00MmeiiMHo6g
hSNkujuZmMgyOT4LgGEabNi8GtdxOXtmeGXzaCvrl5XbCwG6rne1trYOZrNZpV28fFFFI9FVQCsq2AJHDp3hL/7vv68w8JZvgnNnR4hGI6xa3YdUEqEJRoYn
WVwsIn0v8HIPGQjhI6VPKGRgaNrKC8k5ZTx8nJqHFQoRjVjUa3V8zcRxPDwvcGTQAqtHlvJBKfQbv/3rPPvIs7z0xIu0tKZxnQZWKIKm6UGMJ0EfoJkmtu9w
+fxFsotlHC/QsvlSUK3VAYVpWdTrimq+wZrdq7EsxaVjJ+jubyOaMAlFdBzHwXN9Blb3Y9t1SoU8rR1dvPvYk0ydO0dFWZwvmbw5A6/NCo4v+py5OEIxn6de
KpCMWVxzx81ccd1+Mq2tLM6V+PpXvsHo6TP0dqexQibVhk/FhpqvY/sGjtRxfIHtQaXhsGH3Vn71S59G1+Gu+2/jgU8+gBmN0ZA6NUJUpYkyw4yPTHD4+Dn6
d2znivvexwcf/AjX3rAbpcDzJeVGMMPxPY9i1Wa2IvGERNMUUigMS7BlZy+NfJa3H36a695/LT3rB5nPunjCIN2aIZVuR9MNqvUqtUYNTyocF2bny7z5/Kvk
ciUiqSS+H6S8KwJZYiSWpJxbIpaQbNu7jYZts//W1Tz9xBO8+NxLfP63HsS3QhQrDYQIDISlZlGzHXRLw7RMPKXQQ1YQzRSJIIWOUjqFQpXh4clAAiklQ6t7
SSTjnD87wnKiqAJOn7rMN//jEYYvTfzifLc1FAoNzc9n0davXY9pmKsEIgMC3/f54fee4t//+WG+/Z+PkWsy8BoNh4sXxunu7aCvvyvQDyi4fHGCuu1iV0uA
wopF8TyPsfG5wHBqOdNXQb5RZskpU6u4RKIREm1R8oUcrhHCcSV2w/m5AXBzereYK7HnwBU88OkP8B///B+MXBhB0xThcCjYAEo2/YmCfsSKxpgZn2Qpm6dS
dYIPA0Hd8cjny0g/OGXySx6Z1hTrtg9w8o2jWJZFpjOJpkMiFSWWiHD2xDm23Hw9q3buItneg64bvPaj7/LO4z/mxFuvcOroIU6++yYn33md3PwcjXIZHYd7
Pno/oUiU/lUDrFo3gBWyGB+d5at/+vccfvUNerpSdHRmAEHD9mi4ElsqHAmeCkrAhu3T1tPJ9qt2cd2t1yKFhisVti+ou4K6p6EadR77yVNk8w1aB1ahRSJY
lkY+X6WtvZNYIoHrNfF+1yFve1Q8GUCFmobjSzq6Yqxdm+H1Hz9ONGFw1XuuoVwyqDgWQtNRSlCtlrEdP3C3w8BXkM3VOfbuWY6+fjjo/TQNqdSKHBZ04slW
5idG2LRpNV19nazd0sHxIwf59n98l1/7zc/Qt24tM/MFEIFDnef5+GaISrVMNBnCCoVoeBLNMoNvXSc/t0QxW8R2fC5eGMNvCrD6+rvoH+ji0sVxyuUgHD2/
VOJf/uFH/OX//Qb/8a8/wXHcZd1Li9DFUGdnB9pXvvJVQ9O0IU0T1vJQa9eeTWzeOsT2neuIRiMIIcjO55ianGfN2n5aMkmUCibF58+PBnhyvYJj14i3ZtCN
IFJ0ORg1WKQSZQoKmkOl6hCORMl0trA0O4urh/CFRrVi43nN+COl6GpP0dvdjlSS937ovRy47gDvvH0QISWmaTYt2QnqzeakLhyLUVjMMz8zR7XWwJcKzw++
K3UH2/VRQlAuSjwbNu5bx8LEJJ5do60zg9IUqdYE2Zl5Jqfm2Xb7TcTaWikXC1QaVbbf9R661m3AtesU5qfJTU/hlIuUsvNkJ0e55b676R7ox23YhEImu/dv
x/YbtKUylObL/NOf/yvf/tq3KMzP092ZoiMTx9QEnu0F0LBqmo0JyBer6JaFMAxsz8fzwXYlDdslYUjeeOpZXj94CisRw5UKv14jpuqcOz3O5l07cDWDesMB
GYTqOb7ClcGcx9cESlds3tJNdmyMk6+/ybUf2I8VjbC4FMxOzJBFoVRgKZ/Hw0AJE4lOzZaMTy7x4hPPUfNczGioydUPptZKKXTTIhKJUy3Mc9V1VxCNRThz
8iRf/Zu/574PvYcDN1/H+MxisGmkwnV8XF+hjBClXI6W1gSRaIS67aOZOpqhU1osUprPB+YKusnF82OUi5UAak3GWLt+kNmZReZmFwPRv2XS299Oe2eGzs7W
lVtBCKFpQl/1xMtPhI33v//+lKZpvcvLVWhw/wO3sv/ATtraW4hGwyuBFqVijbXrBgO7QxT5XJGxsWk008D3HJxGlda+VVQX09TyOYQQWKEQaDooxQc+egPz
l6sszddxbMlAXy9Hzp3G13R0M0y9VqFSDnJsBYKWRJxkMobr2JSLZT75uY+jgJ/+4EVyc1MYptW87ljuXjBCJmXHZn5qllrNCbjiiialQIFUSMB2Fbmcz8Cm
QXTlMTsyQaq/HzOkkWlPc+HYGVQ4TNfGIeanjzM9dokNt9zIlgMH0IsFYjjY5RLlxTzjF0epFktkp2ZYXFhkcM0qLE3hOw67923jlSdfRJY8elId1O0GL/7o
BQ6/dpRtV+9kx/5dDG1YS2syTcl28Hwf1UxBKVdqROMJlAjABqnAFIJEGI49/zz/9Z0fsevKaxkbnaZSqdAeF1w8dpL5gsODt13PxFwBgSJkQMXzUUAyFcG2
oeH59LSG6O6M8+Q//oC27gRbr9vG0lyDasOgtTNKpi1BrlzFR0cTRqDpEBrFcoMzx85x7tQpIulWpJLBQSTVzw+iaAyv0SBuaFx5YB/HDh3jy//3y1x9zVXc
/9EPML1QwPY8JIG2xHFcJDpKNynPLbBusAMtFKLhBtkT5WyRwlQO5UkQEssKMzExRy5XJJGKoYRg/YZVPPvUW8xMZ9m4aTXxRJTP/voD3HXPdQwMdmOY+opD
nK5rvVvXbU0byWSyRQjR84v5vuFIiNVr+lesD4UQTE8t4Lk+a9f1B42EppPLlcjOFzCtCEop6sUCqkeS6u7CrlaQjkOiNU332iGmzo9w8fw09YpOqC6ZnSoy
tHYI/yevU6/ViEbiNIp5cksVUuko0pBUaw0SicBWXDd0GjWHX/nCpzGtED/4ryfQE63oho70VVOn7AeDL8NkaS5LtVLHcfzAeGl5AxCYZSE0KnmP/jXtpNuT
jJ66wNUb1xOOWSTTSZayi4QzGTxNY3F2Hi0SYu3VVyOcBhsGkly9oYNaucTwyDSreuKcOjGB9BRH3zjE5h2bSVgGmufQ2dnCdTddwdM/eJH2eBorrJMIhakW
bV7/yYs899NnaR/o4rq7buLaO2/BCIfxfQlKUCnXiCfjuL4fzEw8l+zwCO889SLPP/USIhbmmltuZP4Hj6B8j4tH3+XiW6/w6S/8BpH2DkZPTBCPmfS0pjlU
qOJ5kkxLjFzBoVxyGRxspZ5b4OSrb3P/r9+OFYoxn62jhcMk4lFs18dTGkI3kQT+SsrzmJ3Jc/ydd3E9RSIcCvrBldAiHSF0Yok0i7MzbNg8wPjoBF/566+y
e/cePvuFB5nLl6k07GXPQlzXw3VcVCiOIxWV2QUGDlxD1fap1z0KU0VyE3NI20OoIBUjZIZYWpxnaanA0Jpg+LV23QCowCk7ONAVbW0ttLe3NBvjZZQRBKIn
Hku1aKZlpoDOX0SOlOLnV7EKUk0mJ2YJhU36B7tXANLZ2QUq1cZKeIFdrVBeyhOKx0l3daDpGrVCgVJ2ASMU5sjRcUYm5snaVUbHs6zZtIZoSJGbmkJFk7ie
pFSsUi03QEF2oRCkiQhBNBbDdX3KlTof/fSH+OznP4QszVPP5YPTqWnWK4TADIUp5QqUS1UatoPbNID1VTCMkijQBPWKjxQm7QMdzAxPEI2FCccj6KZGvVZD
mCaVhqKwkCMUj2OEQvj1BiEzKL0isSjpdIzujijdnXHSrRlK+SIXz17EsgzihgS7yu13XUdLZxrPcTCFho5GPBShr7WdgWQbjek8P/7ad/n+176FU66iCw3p
B8+aTCWCXuv4ab71V//AP/6vv+bYC0eJiSibNm2ld7AP6blcOvg6bz33Au/9pQ9z/Xvu5PT4IhXbp1J3GZ7IgYBoxGRhsUqxahOL6Qz0pXjziRcwI7Dlyg3M
T9s0bEEoZOJ6PvlyAx8tOKWba6FUqjM+PMmls+eIJFOowNaN5YQfTdfRjTChSIrCwhS1WoWvfeWf2b9/P1/8nS+yVK5RLNdZZmNKKWnUXXxPIsMxSqUyTiVP
72AvS/kalVyd6lIV126iS0qBr7B0k3rNYXJibsW0obevk1g8wvjYbEDgVAqFDByw1S/K5kFoWoeuaWnN9/0WoYnWYOEH9WFgNCpX/nGtWmdyYo6WTJL29pYm
FiyZmpjD84KHBoXv2dSLJQzlsWrLEOmOVjQBhdl57GqVwTVdbN7eS01zGZ3N0TPYR193K5MnT+FHE0jNxLFdlhZKOK5HqVJnYnKBej0I3Q40uXWWCmXu/uA9
/Mlf/0+6khaV+dmA89OEbg3TpFQoUcyXqNWdAF5rKsB8pfCbrtSO7VOveXSt6mJxNgueTygSwfeDZyoXCtiuj2xqiH3bwXdcqg2X0WyJbKGGY7sgPRJxAytk
Eo3HOH3kBLbrEzYUwmvQ39fGHfffTL5WxtQ0TE1DVyCkIiQMupOtrG7r4ugzb/LY13+Eb7t4nsRzPNpaW3j72Zf4zz/7KsOvHafLStDf1onSBAduugZdKJxa
Ba2+xKr+Hu687z2cnykwsVgNcHVfUrNdEjGLlmQYYeqgK3o6E4RxOfjCa2y7ZgNmyGRuuorSNDwFhYqN4wcSas+XQbCHLynk65w7cZrcUo5QLBa8kcv5xQo0
XScUTWBaIbKTYxx6511uuvUGHvziZ6jaDqVKPXADb65Gxw6CRHwlUPEk2ckJrIjHqnWDjI0vsTCVx6kG2Q1B6GBQxhqaBlJjfHwGz/MBRbolQaY1zdTEPLVq
feU1LaNC/MIAVkAGKds1gegViOTyYp+ZznL40GmKxerKYKpSrTMznaWjo4VQOBhSeJ7H1FQWoekrzDzfC5LFi4tlEDqrdqwn1pLCCIUJxRNEMymibSminWmy
NY9C2WHLro1Mnz2K6ytEPIX0FIsLZfK5GlJCoVhldGSW6al5Gg27qTDzyS4U2Hblbv78a/+HHTtWUZqZQboegiDaqFQqUciVAqsPz8f1/aY9X3ADKIIP1ik2
6O7NUCkUKC7mMUMGpUqFzr4u8tOT1IoFYqkkdqmCrNt4riS7WCa7VGN8fIGxkSlySyU818e0DNp7OpmfmSW7VEZpOpGwjlOvcOd9NzK4fRWVWpmkodMRMtiU
TLAnk+GKtgxXd3Zz49AaTj37Gs/+6FF818c0Tc4dOsbz//JDBomzqaOPTCRGsZSne10Pew/sYW5qGisS47Nf/CUa5TJzM3MIQ8dTKnCUBlb3Z7j3xi0M9qYR
widiwdqhNi4fP0N+IctV129jYbZGuRLkEAdokwyEMr5c2QCNukN+ocjZY8fRQ2E0Q2/OTDVAQ2g6uhFCN0wuHnmT1rTF//mr3+Ojn/4QjutgN+wVWHw5L61a
sXFdH2lYEI0xdfwEAx2dtHd3cerYJLVCA+n6zQ3QFBUqhSkEMctienIB1w1mSKZp0NmZYWYmS7lcXSlp6jWbi+fGyDUT6puJSlFd1/s1Tdd7hBAmSrG4kOev
/vwbfO5X/pQffe/plZKiWqmzkF2ivaMFXQ/C8DzPZ252EcOygucHlPTxnTq+47MwsUQ4HqV30xqibW0kWtPUbcX4VJFIIkZVWIzNVThw81W4+Vnyo+OYmQ58
X1GvNZiZWsJxfHwZoDeFcg3b84KcMU3Dk4qJ6QXMlha+9Me/xXveeyvOYg6nUkNpULdrVEtlXNfD9/xmPldwWjV7YaSEar5BKhXDthsszS1ghcPM5wps2rGR
qO4zfvAQHUMD4PhU5+axInEWFxscO3SBx3/8HG+9fZGjp+Z4990LTI+PkV/MUs7nmJmeo0IEpRkozyMZ0fjoZ++jFpUkUdze3cetPf1c39fHNX39XNvby12r
V3PX2vW89tPHefvFNzh39BRHvvsIexPt9MZaCAsdx7XJ2gVuve82DCvE2RPniWS66F03RCYTYezSMB3pKGggm+IQTWvGtyIxdMikwwx0Jjj+1mFau1NketuZ
nWzgSdEsd8CVgZ+/9NWKMXGl3GBuapa5yXmiyRbUMk0AgRA6phWhUalw7uAL9LS6fOXfv8yt99yK5/skU0m6OlsxNLFSstRrLpVyIyBDRhPYrmLm3Bl2793O
fLbK2OUFotEQuqahLSt0pWqGciuSVpiFbAHf85uNrU5HZ4bcYoFatdH0BxL87OEXefDTf8Lf/c23KeRKy0MxzTCMXk3TtO7lxsBuOMxOLbC0UGJiYi5oKDVB
vdagVKrS3p4OHJWFwPN8ckulgB34C9WV59pomkajYjM/sogZCdPW0046FiEdNohZOoYGdt3j0KFhegZWsaqjjclDbxGOpcC08D2P3EKBhYUCjqdoOB4N28d2
/GaiiQoWMIJsrkTFV7z/sx/hfR97D045R62Yx/d86tUqUgbXo2c7vPTEy4xeHEMg8HwfiaJasgmHLaTwWZpfJBKNMpcvkGjLcPXVV3L60UcJ6ZLuVYOcfelN
lDDJTszz1lMvIkJxOjdsQ0+0kOnuorOvO3CPiER467kXuDQ6R8ENIYVBo15jy7ZV/NIXPsiwm8eRHulYjLAVImRaRCyDdMjg5sEB3tOziof/4esMP/osd7d1
ckNfD6uiMcKazsjSNHtu3seeq69gbnaBS+dGGNqykVA0Qnd3C/NTs4REkHCjmqk5k9kCL71zhvHZRfSQTkdbHKdS5ezx02zdM4TrCJYKLugCn6BsCvB1LSgZ
pcRxfMplm7GLIziOTygaXfnYBUFoSnl+nsbiGB/7pVv58l//AavWDNKo26TSKSKRwIlvmfLiez75XHUF+iXZwsLICI3cLAdu2c/I8ALlpRq4fjOgg5/fAijC
CqKGEdzyjhOABLpGZ1cb1WZipiY0aDIYRoZnOX70AoVC+Renwz0G0L3c+fb0dvCl//lJjh4+y6137G9KywSlUgXXcWnvzKxweKqVGsViBd0wmt11wOb03Ab1
SpF4MkMlV8Oue6RaEySbSYme9HE9RXV2gWPDee6+cR233nsj3/nui7i33EM42UapVMCTiumxLJFoiFg8EpQvKlj4QhfNPwcpj3XboVxz2H3b9VRcyTM/foRq
o4ZjB45m0vd59enXePult1j14IdxXR/PD5Lc6xUHsLAiBoWlHBvjISqeYjJX5IOf+hAHXz/CiZ/+jMEdezj0zEscfeJZKouzdPb0MrBpC53tSa68ZTuRsMHk
9CJjE1kunh3m7JFTPPztn1C//3auuWIDXSEDx/e58Y4DKDSe+Prj3BsKsaGnC096zXEdCM3k/q07SEeTtEeirE2lqdcbbO4wOHV2ioHd6/j4gx9HCoNDr7/D
3GyWjZEQEUsQC4WJhCLousAwBEpqCCXwtRCVeg1NN9Etk77uDLm5eYpzi2zdfQNLcw6OG3iD+gp8qbArdYqFeXoGe9F0Ddf1qZZqjF4YxgiFEJqGJoMJfK1U
xKtW2H/VNn71Nz7O9t1bKRbKlBaLdPa2Yxg65UKZhWwu+Bx9SSFfo1axQYEMRdGjaS6+9TP6W1voHRjkldePI6WGdAOvVbHcACtJGEVESVxNY65UplSokMmk
0HSNjq4WfN8lnys0m13BBz96J7phsmPXenp6O5qoFSihug0B7TSZn5qmcfU1O9l/YMcKjARQLJSRUpHJpFc8QUvFMrVaA92M/jyfSRMo36WUmwHlE0+1Y1cd
Fht5zM4kpqFTLVRp1Bp4lQr1msup01NcfcPVPPSdxxk99Bbbr7iG6uwk0rMpFatMjWcZXNuDZelIgibWMAKGqmwaJSlEEHXk+2zau4t6zeOVJx/FtW2EUtiV
BvmlPLe/71YGVw/SqNaD3F5f0qg7qLpGJGJRzOWxTA0jHGIiV+LKtYN8/nc/x1/8wV8zKXTW7NjM8VdeJdWWpv/Ga6jXGnRneljXkyHWEiediNLa3UF3fzeR
cJRjbx/loW//jLnpK7nn3usYGoyjScHNd19PpjXDy994gtJ4g32DfRiGjmaGqXmSpXKdLZ1dhAKXb0KWxUuTZ3GGUvz6//4NwskMr79ykOeeeZmWjh6Ovvgi
A+Y28ktV9t+5BheBpmsYukBJgdKClEwpBKYGbekYJ94eJhI1ae/rYWzERm/qPVQTJFhaKvBvf/uf3P9L7+XKa/biOTalQonsbJZQNIouNBzXobyYpacrwYd/
/RPc9b470E2LudlFlARTE5SKZarVGsVCBccN/HuqNZvFhRK+DPQQWqqNWrHE2OF3+Nj7r6NalUyO5GjNJKiWawgVHJxIhakgLRSWlJhCYNdscvkig6oXXdPI
ZFKAIN/MJAbYtn0927avX6lSli0+NaG1Gbqut6yUcv8tdSn4klIG14YGqXSiWVcFf2c7LuFwUBIZhhE8kFJI2aCUm0RJl3i6E1RQMvmuR3FuHqdSBU3DMAze
fvsy1193Nwdu2svLLzzJ7p1Xkkl3sjA3BhoszCwRjYXp7GnF9xWeBFMGUaYKFcCaMrgNIKBv9w4N0dHVF0BrzTyxW++9hWg0zOkT53DrDVb39YDnoVwP15bE
oha5xTwmOqFwGNtXXJpfYt/NB/jNep2//at/pG7XSbUm0S1BpLWF0nSWxVKNM2OLDFaqREyFZWj0ruphY7HK4nyOUqnE00++wNz8PB//5fvZtnkAqWDvgV30
9HXxw3/4HuNnTnDPlq3MVaqMKUlqqIdIKkZxZh5G5rk4PcnlNPz67/0GLV1dnDh2jp987xE612xi11W7GQzn+NG//ZD+VUOs3rSO+WIZoWuYCHyh8AWgGUil
CFsCQ0nOHjlF72ArETNMpdpAM8wV2ruUipbWDO3dbfzsocfYsGktAo2l+UUq5Qp6LEY5u4CJx/vffzP3f/QeWns6yZVqKK+GaegYTTSpVArymN3mDe66HvNz
Reo1F6EJlBXCSndw6Z23sKoVrrnhAOdOTlNeqBBJRRCeg3IdNBG4eEQ9n3hT36ELiee4QbJk87BOJRMYhkEhX0b6slnFLPPFWNnkwaOKFg1ILUNDzeZgJaWF
ZvBcuVRB13Vi8cjKDyoUKgF5TdfRDI2unvZg0sbyJnAp5afJL0yg3ApX7etFyDLVQh6hAntCwxBMzZQ4dHSCez9wD6gSF955nZ62fiw9EhjZOj7TI7Pkc+UA
tXE86nbwbTtBYoznB4iCkgrT0NB10DSdkBVC+v4KonLyyGm++S/fZnpiGt/z8FwXz/epVxzisTD5xRzKlURDFrpusFRrMJ7Lce+H7uaP//J/05gbZXHsIvnp
KWqNKrGONsbHs1yaK3FypsKlgkdVCmxf0tbbQao1TWtnOxt27GZkZI7/+NcfceLMOAgN35cUyxWMzjSPTF/mq6+/wrgluOLB93H9Z9/LNR+/k7t/9+PMrkry
5PwI93/iw3T19ZOdX+JnP3yClp5VrNu+jc6uFNfduIutW/tZu3kDmZ4OZotVDEOg66AbBMa/hhZk9EYshO8xem6Ytev7qVQ8XC9YKKK5OEqlEr7nc9+H38ve
K/fQqNtUynUW5xaolys08jl2bB/iy3/3e3z6t34FFUswOZenbnsB7745N5CqueilwvUVrieZmy+Sz1WQUuJ7EhHNYDs+p556imtv3EtHdw9H3rgEnkd5KY9y
6ijfAccm4TRI0RRcqcBWUvo+hUJ55WQPR0NYIYtiMRBErVROapkx8HOjFF3Xk5qmabFgLiDIzuU4/O4ZbNtd2S1SKWpVG8M0CIWslZuhUqkhlQZaEP48Ozsf
UGGRzYlssIsatTz5xUmOHznB9ORUgEg0kTOFwEykeO3dKTJdvbz3vrt497VnqS/l6WkdYBmSqFcbjF+cpFIMmibH9mjYLrbj4bpNEpUnkX7Q8AaqzODJXcdF
Sh/Hdjh9/AybN29g964dgWLN81C+T73UIBkLUy5VcBoO8ZCJQJGOmPRn0pw5eppXnnmZVEuaNds3EI9HefOHP2ApO01dCi5dmmEyW2aupqg4QSmmmQaJZIxk
IoFpWqzdsp3pqSX+459/yPlLs7z5xhGeefJV1mzZyAc+88tc8Byq0qMllUAJga7rhC2DxVKRWFs3r752hJHhCY6+c5SzJy8QsiyU06BcrlOqe6xZ00WtUsF1
PWTzPdB0hdAkQpdBFJFQtCTClHN5lhYW6F/dQy5nN71eaZ7+kicfeZInfvokra0t3HbXzUSiESrFGkvzWcyIxXX33sav/N7naV2ziuHpBYq1OkLXQBP4zVvZ
kzJIofQCPYYvFQuLZaanl3BdH9/zUVoIK9XB5bffpLY4yt3338GlM7MsTBUxjAD3V77ElJKM9ElKH215ONvUHGiwAnkqGUCh4XCQKSd/gZrhOC7Hj50nm83/
ontERFNKhoPBls+Pvv80f/R7/8DIyNQveKso6g0b0zAxjJ9zKWrVBlLo+MLAUwLHl/hK4iuPNQMxLDNAD4QQ2LbNwYPnyRfKSDykECg9jDLieL7OpZESbx6e
4oFP3U8qY/DqC4/SHm+lLdGJdCXKF5RyFcYvTVGrNnBdF7sZjGbbLo7j4Toeju0FvP+QRbqtlbFLI+Sy+WAW4Hpce+M13PmeO5memmXk8mgAqfmSWqlBMhah
Wq5Qr9WJWiZhXbGpp51zh07wJ7/9ZUpK40N//vvc+b/+J/s/8cu0dg/w7qNPcvCZZxgfmeLyxWkWFoo4jh8gJoUymq5jO1V0XdHS2cLqrZuZnMzyd3/9dZ56
4g12XrmX9qHVrN23h83XXcc7Zy5SWiii6zrC0CkUy1y4PMFVd91Dz8aN/OyhJ3jxqVfpHhqiWipx/NXXOf3uaS4NL9GwA3mopgmEkAhNoemK/nSU9piFEBJN
k6TCFmPnL+FpNTLpOMV8Iwipa8KMIdOgs72dF55+kYvnLuF7Ho4dYPj5pSV61q1h7Z5d5KoN5paKeMGd3+TyB4IWWypqnqTu+XhK4CPIF6uMjc5RrzZwbQe3
4RKOteGV6xx5/Mdce+1uVq9bwzsvnkf5y72dwlCSjFIkRUCslEikkPjNaY6GoFq1V4ZxhhEc1PW6/fPBrqYxNZnlj37/a3z/20/8ImwaNiqVmlmpNJidXuCZ
J95ifCzLY4+8QsiySCZjxONRbNvFMI3mDCA4KeyGjdQMXD2CkBJNKaT06W2L8sm71vDKkTlePbYUzBI0gqgiAb7yUIaGFkngKxPVDFB74c0pdm7r5Ve++HH+
7Pf+mnVrNrFlyx7sRoVCtYDQBYX5Akoqetf2ooeMlQmfbI7UfddHSYkVMlm/fTNvPPkcpw6fIBq7ikjEIhqJMnLpMt//7ve44cp9rGptQUqPWr1BPBLFqVSo
FCuEO9L0pOM0lgp89S/+jg03Xc31n/44E9Pz7My4XDe0i6NDnbz+4mFOvfkmh59/mn233I4VMvAdD+m6FOaznDp+mNbOJDe+9270cJiRi1OEwmHeePxnbNmy
FhkKk+loIWT7DG7dzIvvHGXk0gSdGwaQUjI1NU+h6tLS1cnOHUNcPnSQ8dEZ7vjER1m1cYiJ8+d57ZkXeIUi7vws/es3EdJ1OhNRxgsVBIKuVJylSoOlio2l
QTxkcObYaVKRELrUqJVthBlCoPA9l3qtzvU3XE2lXMGuNUAqvIaDU3eo1WtooRi+F8DROnpAN5dNpzkp0ZRYocpbhg4KSoUKly9OUynVkb6P63hEw2lSsQxv
vfQ0opbj45/5fU4fmWDs4gIs57tJaFWSCB6eUgEIgsJTARgiRfD5O7azUt4Yho4VMmnUG3ieT6Vco1Kt8fwzb3P5wjT1yutcdfUO+vo7SaXiwvjr//dN6/yZ
McqlBovZIpYV5pEfv8w7b5ygrSPFF3/7Y3i+j2FoAVLQfDjHcYPT34yiyQBSFEgajsfEXJlq3W3SF5ZVOcEbI3UTT9MwrBBKhILr3oSliuKnz4/wK/fv5477
buKpJ77HQPcgm/o3cWr4BFWnitCgMF9A+pLOVd2Eo1YgvJfBhNf3/GYZBK0dbQyuW8uxg0cYGBqgu7eLcMhkdnqGDatXs3vrNnzPBeXjSUnUMFGeQ7VcZs36
fgSCH3ztv9DTaa765Y9wdGKGHq/EVVt7iYXCdMQtHMdFN0OcfPVlRk4co7Oni+GzY8xNDJOdGmbbrk3c84F7CcfjlGo2HZ1psu3ttPf04iowImE621so1xwy
HW3o6SQnjp5m9417CUUt5ucWUEaEcDRCJGxx2x37OXtmlFq9jhk2uPKW/WzZ2MeT3/0JI6dGsQsNHv/+w9zywHsp2Q4LNYczszl8GdS/ybBFzBBcOH2Oga42
nKqPtANqsa7BxMQMbx8+xXvffxfvfd+dAYfKcXEaLq7t4Hse0VQk0NlqQXkcLEoBfvA+imbZbGkGvlSUilUun5ugXKihJLi2g64sulsHWRof5+grT/LxX34f
mUwnj/3XC/ieDKjaQEYpWpWkQUAP9xW4KDy1fAMENHjP9VZKc13X0A0dx3EZG5nia3/3PebnckE2sx4iO1/gD373H0il42zbsUZofX2djI1NMz2VXbE4rNdd
zp+bxHV9YtEIdsNu5rkuq1sCLa8nwNMtPCOE0iyEbrJU9nnszVlOXC4j5fLY2cAIRRGJbmhbj5sZohFOISMJZCQGoTBYFsdHKrx5Ns+nfu1TDAx18JOf/ieW
0tgysJWwHgJfoflQyhaYujBOORd0+r4nm8kvPq4jcR2Jphv0rlpFo9HgzNET2LUGTr3Bjs2bueeO26nU6pSr1Z9TIuoOjuvQqFdJmCEOPf8Wj/3oKWpVyTOP
vkhxbg49HOHUZJWzk0VmCnX6BtroX93Hpj1XUs3nOXvwbQ6//Czlwgx3fuB2Pv25j7BpTTfxaGAZaOiBd2WsJUM4lSYUCWMZGsl4iEgsQqqvhxNnz1NYKKBr
GkvZPJoVxTB0fKnYtnMjqwZSjF4aoVisYeqCW2/ey5/8+RfYvmMdGztbee2hRzjyyhusbWtBF2D7wYmJBu3JGOX5JSamx1m9uptaxUb5LvgeuB7JWJTx4Une
efMwnuei/IAMVCvXKebyFAt5Ui0tWGEjoL8pkH7ACrA9ScPxqTU86g0Px/Mp5itcOjtBfqGMa7vUKzVkXbKqfQ0RPczzP/sua9Z28J4P3svbL55ndryAZmh4
SmJJSbtyUUgaaNgo6ijqSuEg8Qgsd0DhNQ890QRxNAG27RKNRUEJzp4eoVyuoQkNgc78bJ6xsWna2jNon/7M+/nM596PFdIBCVpQyuzet4E//rNfo7evC78Z
Hv1zMlHQLCnl4wkNwgl8I4TSTHQjwkLRx/EFQhhAFC3UylXX7SXZvx6Z6EDFUigrjDR00HWEboCm47rw5BtTjBc1/teXfxdPL/HQI98iYcXY2reNiBYGX6Er
jXqhyuT5cRYm57EbDr6nmqnyPo7j4fsKy7ToH1zNudNnKC7m8BouuiaYnZvnRz95jJmZuSCNRHqUynUcT2KELH763Yf5+t/+O3d85C7e80s3YM5c5Oi3f8DB
J15hfKbEyFyVxZKDUopMJkaiJY0ZMrEL09x6xzV86gu/wm23H2B1d5pwc37hOg71UgXXtvF8n1g6jWnpREI6lhUEQqS6e5iazzI1PosQOvNziyDMFaMvK5Hi
5ht3sjA1wcxUFttXFOoeXUODfOzX7me6VGBdV5onfvAQYbdBRzwSnJQCIobGUFsLJw6doL5Yoqe9nXKpjvBcpG2zOL9APBzmfffeTDoWxW+4ICXVUpWlbJ7X
XnoJrBCdvT2YphaUQb7Edn3qDY9azaZWa1Cv23iepJgrc/HUGLlsgUa9QbFQpl5qMNi6mo50N6+98DiF4gSf/+0HWZit89YL50FrTp6VIiZ9THyWhEZBCEpC
UEPhIHCVwFHBTbACcwqxkg0WXEg+XV2t/MGfPMgVV20NGAHNasQKmXz6V+/nM597AC0cDjG4qhfd0LEdm0ajjuM2aMnE6e5pR0AweOIX8FRYEaH4uoEeTwb+
lMIA3QQRQjMzmPEBjPRq9FQf+UaIugwWuxIaiGW3aS2YKmoaOoJqWfLo61OoVBf/689/m9niZX74yNdJhRJsH9hO0oojfIUhBarusjg2z/zwNJVcCX+Z9+N6
KOmj6YKunl48TzJyeRinbuPZNpViiQ2rB+huz+DYDTQUVduhWmuwMJ3ltWdf5cCt17Dtmt3s2LGeL/7GA3zpCw+weOECT37np+Tmc9TKdWoVG0MISrlFIhHB
R375/WzZsZlkPIpSksVKndlSmUq1Qb1co7BYwG3YOPU66bY2TF0glIfnB/6V0WSKmutz4fww9YbDfHYJTTepVm18JbGVwVXX7KU7bTA1Ms3CUpWRbIUjI0t0
rllFy2ALhUoVrVbi9OGTdKcTKxb3q1pT+IUST/34MXauHiAajtCoB2ox6di8+PIbPPfCK6xfPcCObRuRno/TcMktFjn0+lssLRTYs/86ugfb0bRAoNNoODRq
DRp1G6fh4NkuypeUl8oMnxpncS5PtdygUq7jNXzWtK9mVecQx468ycF3nuPX/8en6R9czZMPHaFe85EEC1sCISEpC51FTacqNBpC4AoNF3CUIpZOIUwDXzUP
56b6cJnOvwyLtrW3kG5J4HoOtl3DcRtouqCvv5NYLBLkVczPLeG5Ltdev5MPfPgW2jtSTIxNk8sV0XQN0zT/m6BgeVMIoaGat4IeiiG1EMKIYyQGMFvWoqf7
ELEMnhVnLK/hCBOMJntUE81w5MA1whQaEU3DkorFvM/Dr03Rvm4Tv/Onv8no/Cm+9/C/EtZD7BzaTSacxlACEw1Tgp0vszQ+Q34mi1uvBykwvo9mGEQiETo6
url88TKNeh231qC/q4Mrd29FQyJdF0ODYrlGtVjj8W/+mJnRaZ577DW+/KWv8Nd/8A2ef/woPR1dfPqzHyI/O8dLjz5HYbFCYbFCveJQzC2SSkaIhi3Ki0tI
x6VQcZjOVVnIVSksligu5MlnC9QqVaTn09LejhAKX3rYbrABQuEweiTE2bMXWMoWmJubx1eScrlBw/bwpCDT08uVu4fIz88yMTrPQqFOtuIwX5Vs3DrE9GKe
7tY4oxeGyUQjmEJgaYK+VJLXn3+FytI099yxh2rVaUKBEl0IVvV2c+TICcbHJvFsB89xKBeqnDl6mvOnL7D9qqtZtX6QeCqG53i4toPTsHFsF8/xgjLUkyzN
5Bk7M05+oUi9alOrNlCuZEPHWjYPbOHipdM8+sS3ed9HbueWu2/l2UeOMT1eRDMCrbEnNHwhqGk6s5pJTWg4AlwhcAV4gKskxUqJums3IV99hZe0bIxrWSa6
plMslJmcmCXTGuf+D97IDTfvxvc9pibnUEopw/N8d9+VW0N/9ZUvcdXVOwhHQnzgQ7cxMTZDMhFDKUUoZAYP6KuVX2KaRmB/LnR00wIzAh7o8Ta0cBpFMHpH
N5CmTsEF3RToy3RU30dTEk0FCTIZ3aA9HGKqXEWvu0wtuXz/9Wk+dM1u/vTv/5i//L3/j3///lf42H2fZc/6fQxPnWe+MIPrO2hC4Dk+9VyRRqmCFQ2jhwPj
LF3T6Onu49zp4xRzBayWGMpzEJ6D5tYBF2EaDI9Oc9O1GzhzfhI9keaDH7mBhhnhxReO891/e5TJsUWuu3kft95zKz/85k9oa+sj3dFNrWoH9W21hFurU8ot
kUyncFwPDB27UqecrzB1cZxauc706Ai6ZWJYYRqOx1KpRtkJhOS6rhONpZiammdidJr5hSw1P0mt7lJpuDhSYosQu3ev5ZV3X2VqdA49FKKlqwU75CHMCLbr
0t6eYi6bxVKKsKGhA8p1efvFN9m0ppNUMszYVBWlh3FdH7tWZfPaNYSiicC2pu5Q9yTTs4sceuMgQ5u20L9mkEQ6GuD3qjk4aH6WQmh4jkN+NkcxW8JzfJQX
YP2ahE1d69kysJnL4xf47sP/zIFbd/OJBz/GK8+d5/DBSYQe9DiuAAfwhWBeaHjNhldrYrQy8DtG4mPXy2iaH7hGNPOqVbM093xJOBJCoUimYnzm1x6gu7ud
zVvX4DguB98+SVt7C1JJZSil7C1b18Y3bV2DaPqpbN+5nu071xPktwX2gp7nrVgRoiAcDiGEQrNCFCs2FiaxljZEKIrfFAhhmGCaKCMQs7BcrzkOuuugexLd
D2i3qUSEgajFfLGKrLpIw2YqbPLwoTneu28Tf/EvX+bv/vzv+bcf/Q0P3PYJNq/fRibWwtjcZSp2GV1oGApc26NeLyK1YEFpUpFJJolaMaYnZmhLrcOp19E8
B82tYZmK2bki2dwi9997LcOT86zduZY91+1kqeqR7urh8Ydf5ulHnsUww6xav4ae/lWcPXaSbVcmKBYrRKJxLlzMMnJ5lJ54nInj54h1dyOFoFGtUVosUMxX
mZ2e4+LpY6zZvY9K3aNYcZhdquIJHd/xkX5AQ5mdXeTQ28coLlWoC0m9alOu2OQrDratSLa3ETPqFJfyjF/UyefLiN4ki5fnCYUsrJCFX5EYgLFs9KQUlWqF
npRCejau46KHTAqlOi+8eZID+/cxNNiP1HRKhQqlhsdbr76BFYkzuG4dyXQM5Suk9IKF37zBPV9SKRTJz+dolBvB5y6DQWRYC7Gpew3rutdx7tIp/uuxf2HX
1Rv5/O98jiNHZnj5xcv4QgR9pwIb8BBITeCpJry9UnU0NRwQIH8EdAhfSkIhY3m6GwzdPJ9IOAwIQuEQd95zHcveVqGQyc23XRUwgj3X1nzfr6jg6+dGWMtF
VJPgFomGV6Z3y0hQLBpGA5RuQjiOlupAxFP4hhFcY4aJtAyUqYOhI4xmwIZtk1Y2+9ZmCLkuhhcgOwlNpyeko/sKQwJlG7lYYWK2xo/enqGR7uEv/vHPufE9
+/n+o//Oz576EQkrya6hKxhsGSQmLMJKI4ZBHJOwq6BmozkuUcOkLdPK9OQs0pN4DQfftsEPhjwvvX2CNf1pMskQtg25WoMnn3oLx5FEIgZ7r95NS3s7777x
LguzZXoH1pBfyLE4v0i9WieebCGR6uCJh5+jnF8kXl+gcu4EpXNnaUyM4xbzjI2McPzQO9j1BoYZolZ3yS5UqLtBiFy5bNOoNSjkCuQKBR7+0c9o2BpOpUq9
WiGfr5Or2IzOVyl5YSzdZ/rcCWq5PKXZPGcPneH55w5RqPo8+9IpRi+NUVhcoicVpzMewa1WmJvLkiuWkbaD9D081yERi5BOxrg8OoFru7gNl0bD4/y5i4yP
TzG4fiOxZAwhNJyGh+/IAHBwJOVchZnhaWaHZ6jma0g3OPmV75MyY1y5agfbBjdx6sJhvv7QV9m6bzW/+0e/xdkzSzz97CU8w8JVAhcdWwjs5umvljtZESQM
6bq/ImTylcQIhZrKtcCBItKM7l2m6buOTzQWWXGKXuZDaL+YHxDMkGoGqJIQAn2ZAKct84LEyiQtHo8EEKHtrBDlEokYugDPtFBmFBGO4QPKlQi9ydjUgywq
oQFCoXsulm0jHIepS4vgNrtyBeuTEXZkIrwzYbDkB0a6fsPFL8KCgEffneOm7e185nc/z45d2/j3r/0nJ755mPdd90F2bNxJV6qbiflLFKs5PCCsWXgiQKlN
BZ2tbRw7dZJa1cZEQ1MK31e8c+osUwtZPnv/rYyMLVJ1FLe//zZefvkg46OzZDo6CIctVq/fxJkj71JYypFMtyCVpFKqEE1miEdSxGItTM9m+eFP32bj6jYy
SQulGRRqPhOzReZyJVr71xBJ5qmWChiGweRUnkg8SqPhsbRYYWl2DiVNBrZeRb1aJBNPMTNyhuLCHPPzAwjLwApbeFJRLLnMnDtDfWmRRKqV4mIWXTjsvPta
9u1dx2OPvMS3/+k/+Y3/89sgBP/x/32NcnaGBSNDtVwFH5TwEbrPdVduw1EGSA9PQa5Y5cjhd+kfXEu6tRXN0GnU7MDuRgsUedVylWqhgud4AV9fEiiMlKA7
3s7eoR2k4wlefvsZHnn2h9x87zV87rcf5PjReX72yEmMZAoR8ki3d1BcqmCXqviaCAhs/JyLtmtLinvv6uObPzjHhct5wMPxHXyhAuc/IYjGIyt0Dtf1sG2H
RCLanIr/PNlINcU7Td6H8qUsG75U+eXTXghBtVqnXm+QyaQRAjShEY9HcR2XcqmycjMkU3FMA5xQCBFL4Asd15doXkBIU4aG0gRSQCosiWg+9UKQSi5cKJRr
tMViDGUSrG6JcHVvnPawzkc2tnEmX2dOKMaExImZRBMmytB57XKBmWKdAzdcy19v28D3/v27PPTEt3j37Dpu2XcHm/u2s1icY2ZpkkqjhEALHIoltCaSSN9j
YmKS1d3tzC8VOHb2NHML89y9bzPRcIwn3rjE3HyBUqHK6rWrOHXkLPuub6GwVMG0IlihKAuzWboHBlEo0u19JFo6uHj8HRbmZhjcuofFiVFOjJbAAN9zMawo
qdYONq3bRby1lYXJESaHz9MoFTFaWjl5ciropYCxE2eIJTJEUu2E4xnMkEFbrczk2dO0Da3BlhqxRJjF6jyz00VisRTdfWsDyxfP5oGP3cG1125iZmKMWCLO
6cOn0KSikM9x+M03ePAjB3jsmaNMzeYJRdM4vhfwuXSNkBUI8T0Mzp09h1IavQODmCED37WpuQ4AnuPQqNn4bjD81HwQSgRGtsJkdWaQ7f2bsd0633n0Gxw/
f4hPfP5D3P3B9/D2G+M8+vBR9EQSy9SQPsRbwmQX89S9gJhoaCCUWqn7XXTqvoFUEte3QdlIv7FSpQhNJ5WKr7ACGg0bx3FJpeJN7UqwkWq1YJZlhcxAXCMU
CpU3gIXlHZLPlfiXf/whZ06P8IXf/AhX7t+OEIJUKo6UPvl8qen8FVCjw4ZGVdMgFMbzPZQMLA11XQQbQIArJemYS0tIMVISzReloQsdz/NpNBrU6wLPsfCF
TrHaIO+4VMI64dYI/QNx9m9sZTRXZ6TQYLTqkj09x57+FL/+R7/Frffcwrf/7Tv80+N/w96BK7h5/21sXb2TbG6WbHGWmlNFokhGwvR1dfLiay9zOBahWi2S
ioa5bd9O1g908PapGY6em6OtNc2545fYcuV2psfeobNzmrn5MpoWIhxNUK/WqJQqVEoFpi6fp7D0BktzU3QPrcMMRdENg017D6BZFp7rEYrHaO1qo62nhUgs
xMzlDIX5OQ498yw7b7yBeKYdp9Hg0uHDLE5N0bN2A4l0mEg4isCnsmQxN7HI0WcfZf3+awjHolx++w0isTSmXkPTAtRk300HSPf089W//T6Xzp9loK2DSq7M
y0++CIZGPV9kx6oWXo2bnBqZ5+odrdiuD/hIPJTjIS2DQq3C6OVRhobWE45F8H2PatFF+gHpUPkB3UEXInB3VyAktERa2dy1kZ50B2dGTvGjZ76Nlvb5g6/8
Llt27ebRh07w1mujKN0inIywrAkePjdOudSgpydJV1eC48cmkX4w+RUGnL1Q4uy5I1TrFcDHk0GwSDP7BMs0mxqA4KtcrOA6DumWBJoIKPNnzwzzT3//fYbW
9PGrD36AVDpIGFJSLRooNRec/hrZbI6XX3iX4eFp9l2xmSuu2h6c9ulgN+WWiiveOumWBLGQzpLXQBk6vvJRusA0NdCDRkaJgL8fC9tkYnBZDyN1HaHrmGGd
moKLxToXSw085XN1b4KfTJcohEwy/XHaViVIpSw602EqUjJZswMRhO/z1tgSowsm+zZs5k//8S858vpbPPSth/mXh/+OLYPbuXLblawbXE+lXiJfzrGUX6Rc
KtAWDdPT1kJyVQ99nRlak1Hmyw0eefUkPb19REIhLl2YonNoA7WKw9jlOSItHbS293Dx5FGULzl3/CClxXlG5TEi8Qz967YSz7SxMDVGurWVlkwrtufSsqGb
7lVtdLQn6EiHiFgGMx0p7Hqdg8+9wOsPP0QslcZ3fOxajWvvvh1XSmYmJ2jt6GRxZppoIkprdxfVapljzzyKUtDaOcANd9zG3OmDHDl5lqEt20h39vLQd35K
pZDlY7/6Ma65ajtjZy/zr//vH2htT9Co13BrLjuGunnsrRG2r1+LZli4UiKR+MpFi6a4cP40hhaiu7s7QNfqTtNQTIICXREsfhH8Nx1Jsrp9iMFMP4V8nu88
8Q3evvwa1914Fb/yhV/BNNN845/eYGykRDgWQYub6JaOkj5CE0gvoDfHYwb9PUlOnlD4QjbzhIKa33VcHN+jbrso0bwlCHQL4WiETGsq8BZViqWlAlIGtpdC
EyipeOO1ozz79Dv09LRx593XBs6GUqEUc4ZSanaZL93d08b9D9zMyROXuPqancEuU5JEIkYoZLGQzeP7El0PyqKWRJSxehWtCVGhi+ZEDuSyilmHdNSjLe7j
izCeriFNA1NKDAVKBeHWkw2fYdvDS4ZoH0yR7o9hmhoF2+P5y4vYvgqmftLHRKE0mCnVeerkGKszUXZedSV/dc2VvPnc6zz1yNP85xNfpzXeSnumnXqtwvjs
GFI4bFqzirBlBL6iwmI23+CtY6eQVpwNW3Zy8sxpanaDpQUbx1XE0u2kO3s48farzI2cpV5I0dnTSqa1g571ewjFktj1gFJh1yt0D/YSag4VMz0ttHWnSEU0
NnVHaUuGmUpZNOpbMEIhxs9fpFoskkhnyM5NY0VM9l+3n/HLY5w4dJQNO7eiPEmlXOSqO+6iVCqhBLS0t7GmM0Yon+S1g0WSbZ2cPHiE/NwcH/rMh1i7sZ+y
7bFULLPvwEb2XbGGv/nKdxieyrNxoIun3hnlnVMjXLNnM64X8PaFpVG3PS5fuEx//xBhywwETr4K+oVl772mMVXUirK6o5/1vWuQrsfr777I0+88SaTV4H/+
8f/g+ltu4p03xnn+ycMszFeIJiysRAI9HsKXgS9TwC4I3MAvXcpy4eJsE+8RyMCKC0/62J5DKuKwd4PFxSmPbCFw9/alIh6PkUonAuq+L8lm8ximQUvLitEJ
e/dt4bob9jAw0EVnZ+vKPAulpg3P86aVUq4QWMlkjE/96n3U6w3SLUmWHzsWi5BKJZibXQiQoKaaqzUTR1XKwb8LGoYgFK3pX7EcVNCXslmdtpEqiaNrmGET
w/XRm65zUioKUjLpSuJ9MVK9UXRDrfz+ku2vfACaCtwnpOdiNoU1I3N5ZrOLDGRibL/pAFfddDVjF0d45ZlX+el3H6U71c6eHVtpOFVsp4EvDAzLYnRmkdMX
hzGicfbtuxJHGcwsLNI9uJ5SoYbn+dQqZY4+9m3WrGrl/33tj2jtbCXdkuFLn/lDwt3d6L6gUsxhyQgIaNRKRAydkudhlyoo2QJKUbNtNCUYbNOprUthWRtY
u3kQ35MYhsmJd09w4eQRbrznWq64bjfJTIq2tlae+fHP2LFvF9ffsBOpHHzpglsnUq9RSZhYkRC1ep1Lp4+zZ/+VJDKtNGzJ0nyW1198g9/5wl08/cxBRkaW
OHRmhnv3b+LAltU8/uZ5wqEI2zevxRACIxrn4vAUnuvR0dEOvkT3g1M+4No3T1wjRH9LL6vbBjEMjXeOvMErR16iJiu85xO3ce8H7qVhW3zn60c4fngC1/ZA
uLjoxKKhJlVBBgCKH0zuhVAIXSB8rUlyDtAd5Xs4rkPCavD596ZIJzW+9azLfMEGIfA9SSaTIhoJN63yJfNzi0QiYWKxSJMsB7v2bOavvvKbAU0+nVh2PJSu
788YSqkZhSqDapUKrLBBKJxcwfuVUsTiETq72shmC/i+xBLBJLizIw1zRYTygyEFoLTAWUDXFGHDpy9RZ09vmcGWOuva48zkE7hCoJkWVtNNAN+nEjIYMwTh
lhCmEbxBAWQVTIvXd8TJFmvkKy7S8ZB1ByU9dKHQhE/DdTk3UWF0do7+9jQbB3v5/B9+gb5VvXzrH7/NQjFPJpnC9SSLxSKzcwuU6y69qzaydt16IvEYU1Nj
VGp1egbWkS+WmZ4YplFd5P0fuZePfeajaKkYNcehRQ+sI2fiJomOAXKTY3iOS6ylnZnpi+zbu5d0JER5eoFKbyvRUJyxpTqlWp1U1MDUFXs2tFH1BPmqiwDC
1i5GL1zgwukL7L/pAPFEmFJuiVKxxHvefwd7tw+gCZeZmSkqBQff9lG+ixWJMT81TiQSI5HuolJuEAqbHDt0mnVrujFDOm+/eZZVbV0cuTDH3g2rWdffyb5N
dV47fJrJ+Rw7tm6gJ9HO8KURert6iFphfF9haAEMrmkaEStEd6KdvpZelA/vnnuHl468iBNucPPtN/D+j99HvLWbw0fmePmJEyzN5FGyqUhLxEl0ZQIPWdcl
HjO46qq1vPHaWRayQVomUjZDfZtbQKqmFqHG/VeHKJWr/OUPslQcA71Zafi+oqurdcXz0/d9ZmcWaMkkicYiQenWzLro6GxdGZYRMFbr0vcnDdM0l5RUOaFr
rWJFOylXPIFQEItF6ent4NSJS9QbQW6TYRr09XWgH5wC3wUtsCeUIvCWaYlKbl5V5tZ1S2zuqGIKj9+5I8uxccXx8QSXpg2UhERIEAlZ2ICdMMhENHQhV9yl
pVRoCqIahDQwNdBCJibgVRVOpYrSJUoEjEDXlYzOLjIxv8DGgW7u+eh7yHRkePzhJzgzehklIRwLU6rXacn0snnvlZimxWJ2luHhUTbtuJqW/vWcef5hdu/b
xOd/+3Nsu2In44UcwyNZlNC5bmiIA9fv498efp3OfVejxeO4rk2ipZPC/DjDl05z5RVXc3likYmT4/ibB2i0xyk5YFV8opZGb0sAFqAFgo22zhSrN67nwpmL
7D5wBaZpcv7iGVrb0gwNthGxFKVyBeU1aFQamI7H4kKJUChOvVykq3cQp+GTmy+jCZgZn2HvLRsZG1ukWHK4bv9uXnv7OO+enWHfpn62rOrB1E2OXZ7g8eff
JH3kIpWqw5X7rg7yGRBoSpAOxRjq7KIr2U6pUOGNY6/yxrl38MIeN3/gBu657y7SPQOcHitz/PA4M5cL1MoehqmhhSJEMjHMRBglghNd0yRSCiYnFymXakGd
/ovDrqYKTPoS27Fpibp0pS2+82KOfM3CNINJsNbE7Pv6OzEMA01oTb1xjs6u9v8m31VKoTU3gmA540/ldV3PGvV6vWhZ1ryAdeoXHHKVVGhGUNJEoyH6B7p4
47VjLGRztLamMAyDwVU9WO4b2HYdFY03d5hACSi6Bm9OxrAdl9ZInY644N3xBEenEizWQihLw7F91q9Ls6Y3xltnFkglDDQlkZ5ASIGmgY6PBE6O59E0MLTA
88aKBhTqiutRyefBUGgGSD0wo5YKzo1P4Th19lyziyuu3UdhqQhAOBxm+NwwP/n2Ixx6/Rmqjk1ucYFVQ1vpXbeFd155gt4ugz/68h8Q78nw7tQIBccFI4SP
xlytwa6rdmF+82FKxUWSGzZQOHYYI2XQu24H584dZ6ivgw2rVnN2ZJHzhQqpvg5ae1tJpmNEohpFu4aha0gpsesu+fkyLZkMpw4d5MKpywhdZ/jcJdasXU25
VOXy8CjVapX8UpX50Twbkh6XRpbIZPooFXP0rt6M77vMTeYo5cuBX44McXk8h+sJWrt72bTJ5o2TZ8gkU6RjYdozKbav7sf2JXNLZbK1CoVCnmQ8Sciy6Eq1
0N/aSqPR4KnXnuWt00exWkLc+fHbuOXOm8n09HNstMRPn5tkbsnBlEHghtUSwrIiWPEwQicIzvAC7ZjQBI2Gy7sHL1Kv2c3mNVh2UgaiGt/38BwHp1Gjr0My
ueAwldMxdIFsyiJ9qdA1ncFVPZhGQIUoFsosLhbYuWtDswRq5s4hmmYO/80icR6lCkapViokU8mZ5f7GczxeeeldxsamueOuaxgY6EaIYKc5jsfE+CwbNw0B
0NPbTsrwma8UIRIP+qMAnMVWgpl6lKcvm6xqcdjSXufHxztxVRQLhaGDYSomZqp4tkt7MoSugQFETIOa7SG0oPE19SDgzKs4OI6DqQnCiTBayCSWTuJUarh2
NTgVmmQo9EAMPjm3wGJuidZ0nEwiRsg0CCuDTVds5E/2/SELMwucP3OB1196k9HLk4yfeokD+zbysc98lHBblKNjF6ihoRlB/aoEjBSLXDPUz9X7t/LCS0+z
9QOfpHjhHNJ3SGba0dbu4NkXDnLjdVXW9q9hcr7B0oUxcuNzxNIJoskoVthE08DzFHbdQzoNhs+cJBpP8crTr6AJnalLI7QkWzh4eAJdUzi2S6NYZ0eHycmj
J7g8mSWaMqiWClSLefo3bKGaX2RuaoJSyebcsI10JFKa5KqCvvVbuTy1wNMHz3LTnk2ELQMfQd22WdPXTjIa5fzZ42TnZunu6GAxFObFhQXOjY0Q607y8d/4
CLffdzt6NMn5qQqPvjDBbN5D+WAJgaY8jJBOy2ArQgUuIIFYRaFpCmRAVSiXKth1G63ZyIqmok8pHyV9PNdGNzQMAzpSGqMLPi4msUgIx64G0K/rEY2FGRzq
RWjBQTIxPku1UmXV6l4sy0LKwLzt1ZcO09qW5qqrt2NZZrO8VzONajVvvPDaC8VPPvDJ6eU4scmJOf7ub77N8OVJ7IbD57/4UYSm6Opuw7IMxkangxpKStIt
KTqSYeaKS2jtvc3FL1YYokIDXzMYyyfwXYO6NInoEh2BjiIZ1clEDDQVGMYKpUiEdDqSYS7PlPE1gWUKvHKd4sQilbkimiexDEEoESY11E6kPUk0HKFUrwYe
klIh9Cb/RRMYeiDaXyqUKVdKmDqYBkwtTJJOtNCSzrD35iu4/u7rqebLaJpBur2FueIiZ2dGcZGYTUsRuRxc4bhMNWze+6H38NLn/w/VxRm69l9J/tBh4rpO
srMbzRS88MZxetvH6OkbxAwlg4FRTafqOlRE8KGh6dRrFSaHL9Ax2MNNH30/l46f4uLxMxy441bOvH0IhUFLRzfSceiPSiYuneWtExf57G/+KqFoGIBnHn+Z
o6+Ms+GK60n1rkWfGKXSsBAqidIsFgpVOvvb2bznat59/RWeO3SGPZvX0N7dC7kCi6UK4VCEtb1dlOou+UKRWTvLxbHLDG0b4g//8vdYt2snx4YLnJuYJlv0
8KUgHjLwHb+Z6RWUc/g+0vdQykc0OTs0sZ16vYZda2BoTV8nAVIEhDYpfaTnIT038DOSLulUhIsLdaRmokfiCKEhpY1TLTHY00FbW2plNjU6OoOm6fT2dbA8
Gn7ysdf467/8Ft3drXzla/+TrdvXBv2ClDOjExMF48GPP+jWarXRQGsgrGg0TFd3G7mlIm1t6RUn3+6edlpaEoyPzqxcJamWFP3dGU5PzqNLD6npK/zzZWde
hSBvhxEqCKuTMkCITE3RHgqRMoPrCy8YgVdKDpWKG/REQqMwuUTh0jROsY4GmKaOp+t4ZRe7YNO7d4ioYdE12MN0NkupWkU3gzBtiULpGhoahgjqwEBWDY4r
mc8tMptfRBgW8ViceCyOpulcGJ6m5tr4qGY+rSAZDlHywG76D13M5blm0zo++IE7+e5TP2H/r/4mtfFJ3EYdKxYj1dGNLz0uHX+Tcq1B3RVghDCsMJphBjWx
kviey9L8PLtvvIGr33MnobDB5n07ae1op3+wD9mo8fLjTxNLp1CezyFVobiU5bf/4Hf55S/+KnXPQwjBtbdeyw++8SOefeknpLs2IjSNeq1KKtNBOJFheHiU
WMcAeqyFLftv4uKpd3n1+AX6e/KsGVrDqrVrcB3JwWPvgC7oSbcjXJ079t7GL//GJ+hYvZZH3p5hfNFFExoGAsvQA9uZZt4YTZsS6bko3wsa22XZom3TqFWR
rkQoaItCpSEp2QGSFwpHcF0Hz3WCn+l4ID2skEGxAcLQqdZqzbAV8ByXnp420i2JFYHK2Mg0iWSgY5FSNnMsgpI5FDYxLWNZLyBdzx276qqr6sbc3AzxeGIM
yIPq7Opu4//+xW+wuJBn46bVKz6K7R0Z+gc6GRudppAv0ZJJkUjGWLd+kBdOHSLcqOCE4wRpFD/n7wkBM5UQRc2kmckKSEwliAOGBOmDarL/NKGQXrBxChNZ
cucn0VyJQLFpVx89/S288fxFDEPHqzj4C1XibTHSkSjz5PBsGTRxJsQtieuJwIUCDaHBYGeKYqVMueEiDD14vUpQqlcpNKqg65iGga4HdG8hFYYu6E8mGSlV
qDoSQ9Mpuz7nChU+9Csf4fjRC5x58gk6125j8dBbtEYsGnad7MQ5PvSBm+kY3EDWUURiJoahYWgapqERCRv4vuTIO8c5f36M/PQMPWsGcB0HHYVXypPLzrDn
2j2s37yeerlCi+5y7K23qdcaFKs13hmdwlWKNe0ZPv+HX+SWu2/ku//5A148epqwrtOzegP9m3Zy8s0XGLlwnsH1W0lk2unoGaJWXqARUrx98Rhaw0AzDNJ9
SX7rd77Itt3bAmqLGWK65PHtVyZZqkJE6FRHZimOzxDrzNCypq8JUftIFSBTyvOaiTw+nuNQLZWwGw0sK4Rnuwhf0hV1yXo+uZLEly6Nag3HsfE8B98Pgv1M
QwMEjh9QHpZRouYCYXBVD/F4FARUKzVGRqbp7mmju7udZQbse+67ie7eDlrbUqxbN9AU7KuCL/3RqbkpjO7uXrLZ7GgkEl0SQnSCYmCgm4GB7pVBglIQDlus
WTfAk4++ytTUPC2ZFJoQrFs/SNR9hXAlT8i0cEVgyrqMIOnAQkVQ0TRMESA6ypdYSsP0wLQITis/iPBRuobQNRqLJYrDs2huwOLThaBRsSlla1hCR/lg6DpR
V8esw/RwllK5GrxHniRmCLb2wckxhesYIAXpSAin7lOvK1xPQygNXWmBaZQAy5AIPTDdbUIF9KZbaInGmSzkqTg+um7hNzkoM9UGWzNp9u7bwcSb5zB1cH2X
WinH5KVzXLGpmw2bt3LoXJa1u9awam0noZCOqcHq7gypWIhiqc6WLUM8/+RrHHz6WW778H3Y1QZescDRE0dJJsN86tc/RippMjU6SsyuELYXGLkwgusERlR1
1+XUzAIT4SLrNq7nz/7uT7nyocf5z3/6PpNj5xnasRvPdzj6wlPMTQyTSsZYu6mfT33299m5bwdTE9OMj06gGzrbdm1DS3Xy+mgR21PkKkXmaz7CjGLoHvlz
U5QujOO7Lk7ZJtaawoqFghNX+WjKp9GoU6tWqFdKOLaLZYUxzDDlQgEcH8tXDHXrKN9meMJBagrPDRa+9F2k74Gmo+mKpmPjLxjaSvA9LMNk7boBDKPpSzWz
wPTkPFfu30YyFV85hOPJKDfcfMXPAdDAmmSp3miM9nX1YSilxMnz5ydTqdSMqRmbm8Kyn5ONfu6SyIZNQ/zwe08zOjzFjp0b8aVk9doBWuMh7MIS8UQaVymk
bgTUappjcyWQUqBDIAyXEFWCqNBoS4SpeR51O6iHpRL4DZ/K9BI4AdylAZauMTOaQxU0Bts6cTybZDxKXA8jbYXyA0sUQwjwwZQuXUmPszJEw9GQOpRxyOfq
KF2gm3rwugggv4iu2NGjKDk+lwtGcFs1k+1bYyEmi4HvjU5guR0MiDSUppFOx4lELToGu5h9N9LkqXhEojFyFQ+7alNfKuAPtOCbFiioNhqk4+HA/7Jhc/u9
15NfynHi5ddZt24t2fEJpsfH+fTnP8rmjf0szU9jyAZurUKtVsMIZVYsYRSBNXjZcTk6McNQJsV9v/QBent7+Je//09eunAY6bps27OWe+6/nR17dtA92E9N
mZyeLKDH+lh91Ro8pTi9WOf86SmKtaCE8IWibzBDW2uSS8fnKU0tIn2FppsBfFN3SbeGKNVcKrU6lXyewlIuACvCESLxFG6tzuLcJMr32b6mhd0bQ1xzIMHW
2QqWtsjhixUW6i7Sd5C+ExTQQYb7imdpwMwMQkV8zyWdirN6TR9SSoSmMTE+SyFfZsPGVf8tG3jZxWSZ7CwA1/fmF/KL4/Z0RRgAvm6UPc8/YxjGTT+PiW9i
pmLZckiwadMQoZDJqZOXuPPe6zAMnf6BLtas7uHUVJZoTx+uUqB8RHNhLSdvCz0oRbSQiYUiKgWWVDgVB1dKlgsnx1PUlsrYxVrQ0DY3wPIIHhRd6RZ0Pfgf
vvSp2R6FRg1PSiwLwiGfoU6brozHYEYymtVwPJ18wUc3NDQdDEugeQK9uTF9Q6PaENTcAAL2RfCaxhayuF41+HuCoDiEQFMavhRUXMngmn6K336E6bMXicQT
4DboXrWeI8fP0dG/kXA4xPxYlpCp6BxqJxwPM2rXWVjMEzKNICOr7rL/qh089P0nWYjEGL08wup1PbS1Rpm4dIFSocB8to5Z9Tl5aZqb3n81Step2UF4Xks0
TEssxMxSnqlcAddx2HHgCv5hx2aGL1zCCoUYXLsaaYSZXqzy4ukFZnM2ZTtI0FQSfCXwl0NYZBAsKITCLdTJ1X3cmosZDdMoVpoB6BoWgq6IpFGv4eQddGXS
1t6F50uqlSqFmXkq+RwgiUeiSFuQW2jgNKJUKg4L+ToNx8b3HXzfRvouSugITSHVcqrjSqoLmnRxGnVWbVzP0Oq+oGqQivPnRlFKsnHz0H+HPBEIoZaHXyoQ
efnnX33ppaXL50cwALFlcIBGo3EMQg0QEYB6rcGJ4xeIRsNs2bYOTYOOrlYGh7o5dfIiucUiHZ0thCNhtu9Yx9HTr2E6dbC05ovWfkFHLxAKDBRao4bwfSKx
VjQf3JqHMgLatESCVDQKVaQTJMCLX+Bw67pB0amSredojSXQlKChPLJOgUK9Sigi2b5asnHIpa/TJWy6XLtLsmZBcH4iyuUZA9/TUEFyRDCF1jXMcNCvXF4M
eixLk4F/KRpSCQp1j7pvIYUByiBInxe0WAYxXZBpb8PyGhz8/tdp7eglHk/S1jtALdrOkXePs2XXPirFKhPn56jO58i0h4mlItQioWCAY0uKJQ8lNLyGw/jI
FAvZLDv2bmP4whRCutRdjVLFZ+r8CFU3xNXXHWCyUMH2gh6lWq4ialVMGYSBLCwVKOQKtCWTZAbXUHMU71zKMbNUo1ST+EoDFQRP6EohJfiewvdkU/zUvFU9
n/GlCrph4Tckfs1G03SEUhhCw3R90qJOUjbIVhxcz6Faq1EuF2nUa3h+EGwnlUJTgnxR8eJojpjlcnmqyvHLVXzhIr2A5iGlh9IkQpmB4ZbvBxQzQFcSTdZB
+mzfsYFEMoZSUCqWOXn8Au0daQZX9axUO5MTc5SKZdauHyQUtpbxmYbrecc/8+kHVTgUEgaglFLUarXj0Wi0rGlaVABvv3WCL//xf5BMRfmrr36JdesHCYct
du7axEM/epaZmQW6etpQUrH3ii1873sv4VeKmC0hfAkIvckIbSr2fYnuuZjKx0IjLMCUgE/gXiwUawaSrFmV4rmlPOMTTT6gDGixmhFsAlf4TJUXyLsVQpaJ
o/lUZZA07jmC0XHI5QSbVyt2bNQ4c8ngwqRF2db/22ki/cCjx9A0oqYkbLo0XdebwRACT+m46Cw2dKQeQuomSur46LRHQ+zrSjN55gL/35/+I+mBNdx+y72c
ePUtirksxcU5DN3k9MgcDceld2ADum7gLSnKVZtwxMeyGgihI5VGqVLj3ImTOK5Boj1FNJlmdGSKUCxDvW5Tr9lMj45y6tA7fOJTDzC0fg2vXpwMNjP8/8y9
dZyc53W3f90PDc8s82pBzEy2wJIsWWZmJ4YwO9AkbZomDrRpmoadpE4cJ445jplkySC0mGklrZaZhmce/v3xzCp++3uh7Zu+7f352DJod0cz97mfc5/zPdcX
Na8TymSw/Qp5n+x5I5sOnYlhsvYYKV0mZ0mYtsBxpIIa0sa2ve65abvohoNhebhIUcBGOqaN5Xh9G5E3UXG9AoHlEFI0fHmLiDApC7h0j/OV0lnMvIHrgCTG
gcmCiOYnoKoMYtPTbzCacBGKi2OaOK6F61i4rgVCw8UD67q2J3cRroNkZ5HsPAGfn0VLZlzgAA0NjtJyup2LVswjHA7huA7DQ2N85xsP0dnRx+e/fBfrL7sI
EMJxnZyhGwdTyZRbUlyMArg+n0+4rttpWVaLqqqVIEinsySTaSzbIpvxXP1UVWHx0lk88dirHDvSwrz5UxGFi3BDfRnDQ0OURku8bEXyBiWE5ImUpkyI4nMs
zp8bRlEVhOsgOwIsgSoEsuwS0mSKQhqahxdDFhKmYzLvoklMnlXN63865M0mOw6JfAZHB1mTUHwSquw5lY8kBENxmVzWpbzI5fCZAEMJH4oiUAtsX1d43rlF
QYeioIEmufg0zeP32A6mK7CFhiF86CKAJQIg1IJy1etZzCuLcGLXfn74g4dpWryIxnnzOLS/lSkXXYqVGEayDeKDA6hBP11dHbSdP4+saAQCEcKhKIFgAJ9P
Q1FV8vkMXWdaiMZKqGluZGx0lFCkiKP7D9Pd2U8+b2Dk8oSjEVatWsaZg4fZtWUbcy9eRi7XTTqbw583iCYMrIxBLhJAl2RMR0F3ZLKWhO4ILNvFML2/bNvL
jU3TIRRUcXDQDa/87ClAPSiWY9g4pk1e11k0owJR7OPUoR5UWSKqyCjJNFEFsiELn+ugQQGY6HV13cKvEoKSQBhNUrBcm/P9WeIZE2v80us647dPQkXlGHoW
R0/h2gGEk0eYOSSRwczrVNfUMn1G8wW/r9Mn20jEkyy/aC4+n0cwScRTnD3TwcDAKP29QziOi5DAsa3zrmOfm1BfTzgcRhm/LudyuVw0Gt2taepKIRArVy3g
K1+7l1AowLQZEwv3CZem5jrqaqvYv+cEt9x+OT6fSjgcZPHS6fzx+b2U1jcgKT7PMRCBkGxkxwE9j21ZyIUGiaUbSFLYY3FJLrIkOH5yjHMdCfoGc95jzxXI
kszIQAp/UCl0CwW25ZWXhCy8QW3TRlYlVAkc1/MAy+oKA8NgGqJwgrg4pkATUByWKI0ahP0WQrjIqDTVT2BgeJiReAZb0shKYfJSBFvyeU8x1yvVGq5LUyyA
m0rxix//DqWigfkbr+DkoTNoQiY9NoiVSlJZU4NpGsxfvgTbzJJPJzHyWcx8juRYklQ8wdjoEHo+h2WbWE6egd4O4mOD5PQsuXyGpknTqayvoaSyjPKqSoLh
IDHZQO9o4aEf/pT7Q0HmT5/G/lMdmJaD4brkbYlEXiZdgBabCHQb8rpFLOijNKpxsj1NZ0+GSEDBp0mURANoksOolQMHHMvBNW1s3cLWLZy8hZUzGe6MYyc9
zIlPhpBjUSmnqCzVcLI6km5g6l4za1zU5g2uW4RVjeJAkJxj4bgObQM5bNfBKfw7Ba9hCZdcvB9wEK6BZeQRVgpMCyE75HWT2XMmeapO16M+7919jKKiKFOm
NXraItuhvqGaz3zhdvp6Blm3YTmyLLngYtjOXlwyrusK13Wd8QBwm5ub84lEYo/junkJAsUlMW65feMFHtC4aXZlZSkLFs1gx7bD9PcP0dRYi6ypLF46k2f/
+C75xCj+WDmu7N0DJMcbbO7vHEWybDRcHMMmk8viqp7jDKaLzy8wcUmmbNSgH1ORPQCWT9DfPsZA9xiBmA/HsrANF0kdnxsVOHYBBa56CBBsMEyF9h6BYUhI
eOXYsCqoKoaSkIGqeLQ1XIGwbIZ6+goXSo0sReREBAutYAPqXQwt16W5OMCMIj8vPvYsHR29+FIuv/vmD4iVllFcVkFRKEhpYy3J0WEqKqLU1BXzyjObuezK
DdQ31NJ+ro1ps6aSyeQ9wrbrkElnefH3TzI2EGfqgsVksmmO799JTXMDV915I8n4CKl4gtZTLUiOw+JJVazS4KEfPsh3fvaPlMXCdMaz4PORRSbhyKQNh9Li
ABNKQhxuHaW6JIimqJztSODagoqSMKZhks+ZtJwdvTBkEg1rGI7LWErHzlu4ho1k2ZQG/PR3JLEyWapjMk2lCo1VglmzfZQ3RghFUqztH+NUr0ZPXKUvbjMQ
d8ka3uYuCYYIqn6Gk4PkjXwBb+7d+xzXk7sjPNqzY+oeLE04yK6Fa+kIx8URoCoaF6+Yi9/vKzgVpTly+Ayz5kyhqrrsQgNM86lcd8M6r0PtuRoJcE3Lst6r
qq7OvfLKK0JV1QvFF7ra23Ad+7RjO2fHT3vHsQunrsO4UC4Q9LNoyUxSqSz7dh+/wGJpaq6jtraYsf5+ZNtCmCaaqqDKArXAelRdB8mycU2LeCpB3tBxLRcM
m6pSP0VhFUVy8Yd8yAEFIbvIssCvqZQUhVl3+SxKy0MF7gw4hoOVt8BycW2vGiAKAxaOJdHaJcjnJVQB1RGJqZUuNSEdPzqSU+ASAa5tkxxJYOQtsk6IrBvC
chXvYmiDU0gf6iM+5hb7efo3j/Pos6+x4ZMfZ9aa1VTX1WKlE7Ts28HJ3Ts4unMnuVSa2uZmhKowe94Mli6fxVB3J6cPHqIk6uPtV19Dz8WZMaeZ5HA/Q919
TJ8zj5KKMiprqmmePJ2Wg0fo6+giGvLRdbaFSVObmTx9Mr5oGWdaB2hv62JseJSy4ggpV6FXCTAs+cjYEnlbMJQwGUnoKEioQsIwHPK2QjZjomcNfKpKOBRA
khUMw/FcWxwX17TJpw0s3cY1HIKyQnkkhOy6BBSZxmIf0xtUps7UKJkSQYSDBMrCNM6IsGB2gEWzYkxtKCIW8qMg8MsqNdFybMelZ6QP0zI88wox3q9yC1as
3h6TCn0kWTgENAnb9iTTum5TV1fJzFkTL1Q5jx4+w0D/KEsvmkNRUfRC6dMtmGQjxr0EXGzbaXcd93gqmXJ/9rOfuV/5yleQH3jgAW6++WZxquWk8Psj+aKi
6DxZluf92SGsoKiTxgtRnhxh+7sHyWbyrF67CFmRCYYCdHb0cHDfKYpLqwogUm9ITHJcMCwk20XYXnnNtAzCsp+I7KVL2bThicLGkeeWgZnNXehHBIRKaiDL
8EACy3Qu3PRLSkPYloOet3BtL5UqQChQhCCsCSYUCWqLbAKqSTgqAx5IVxqvVOHNHeTdAElC5FyfR7gQEq7rTSipsmBFYwnbXnid3z76Cms+9HECpTWcO9zC
rEWLiRTFCPg1ps1sQk+PcOboEY7vP0x/zyATJk6kqLiYiqpSlq9cSDQSpKu9i6XL52Hk8jz2099RWlTGtHnTCIR9BAIS4ZCf4e5eBvoHWbxqJQ3NjaRTOQ7t
PsDLz7+GicSUunJaTrWxcvVSXNVH90gew5bQTc9cMZ21aa6JEdI0znal6enPkc+aBAIBbFdidCRDOp7xnNdVBU1TSadNMsk8dt4Cy8G1XOy8RS6RRbJsajQf
wbxEvN+mr9UgO5ylot6l52yG55432HrUYP/pFK3dGS8NllxKfCGaymvpSwzROtz159TItjAtA59qs3FFJQgYGs17MnFcwn6bRdNi7G8ZxbQVcnmLS9Yt5apr
ViPJEo7t8uRjr9PfN8Ld911NZVXpBWjXuEMk4wJNzxl0y+Dg8BOVlRX5u+66i0984hPeHWDmzJnupk2viquvvi6VyWT2KIpyKxDwaqfQ0daDY9s0N9cjyxL1
DdXMXzSNndsOcfZMB3PmTEGSBcsvmsfzf9pKOjFGtKQcLNPbibZzAZ3h2V0KTMehPzNKqRZGVRQkHXwIzxBNBjUSQcoZ5NI5bNsmmzfwxxVqQsVk/QY5y0B3
LYoiQXIpg2jQT2lVmNH+BEGfQsAvEw1IlIQcgn4d2bZwbJNgrUqgyI/RkUa4rnfiSV7FJ20p5ISDqVoFxbmLLHklwoZSPwHbYPuWXSRHkux69gUc0yUYDHLm
YB6/X2PSjEksXDCZQ2GJBYumY9su+3cc4JU/PM1bL0RonjaJyTMm0dhYzZJVqwiEIjz64O/IxJNctHE21VVgWjmvrh8IkZ8zmZ079/Dc759GCDh64CCq6mPp
urU0NlVRJZIc39/Coz//Hfd+8eMMjOQ515PGtvBoD8gcPJX03CJlHwG/hhA2o6NpDAvCoSC2ppFNpMkl8p4QzXZwLBvX9N6bSECloT5Kqi9NhSVoCPhRBTiu
iWEKWs/qNHRYnDpt0zkKaRMs13NnNE2PMN00oQZbWPSlBr1Tv4BVd1wbwzSYWgsfvb6SgaTgR4+0cKItjeNaVBV71aBc3gLJj+bzs/yiuQQCXue5t2eQA3tP
MXvOJCZPaRhvE9HTPYDjutTWVXiB4KXvpmEae5uaGkZ5X4FeARgYGODOO+8uEBpye30+rVMIMRUhaDnZzle/+EMsy+Yb3/kEy5bPRZFlVl+ykFdf2sqe944x
a/ZkcGH2vKlMm95Ay7keosXFYP8ZROS5sRR+rOtdd+JmhsF8kppQMcKVUM1CTVoGx1XwR4pJOArZXA7XcbBsi6Kgn5JoEKG46JZJZsQg5qrUTyhj4oxKWt5r
JeCTCfjAp9lomuVhC1xPoei4DsFIAFm5YEwKjiBtqozpLlknh664uKEQalDgylASUphbFeWtP73CUDLHTZ//KOdOdmAkk+iZJP2tx8mm07Qe8dN2spna2gou
vuQiqmvKCWgyJcVFDA+PcvjAcd780wmy2TzRaIxYKMhQWxsXL5/K1DodVXRhyd5AuCsLpIlBhgebee+N15F8IZZffgUXrV3OYE87ecPgbDLL+hvW8aufPsW6
U2toqKznRFsC15VRZAXhSgzGLXI5nYBPJhpUyWZMgoEQct4km8zgui7BgB/b5yOXNXAtC58qk0/rRH2CW66dTFVJiC2PHqMsJfAJCQfP+SVhWaRNk64ei84B
nZSexyoYJQrAdhzqS8opjkQ4P9SNFgoSyAfI5AqWRq5DPp9DkyTe29OC4wvwVx+ewo8eaWH/yUEWTm+geyCBYUtYls2Uqc0sXjKrQCsXHD54iv6+IT74oasu
2HedPNHKN772IIZu8J3vfZbZcz13SMdxu7L53J5RK0vQ+HOnWAH41a9+RWdnJ5MnTxZXXHHFqWAodMSnqVNxXTLpDMNDcfJ5k6HB0fEdzNz5U5nQUMm7b+/l
musuobyimGgkyLpLl3D48FMY+Ry+gDft4OKJyoQrkJxxMz4J24XuzCgBRaNUhAvNDoEwXWQkVMeHzydhEvAqSHjwSFd2UGUJv99HUcAHhCBh0bevi2JNQVYd
NMVBli0QHkbDcb1B7NGeNInhHHahRAsuOUtmMCuRNW10x0WX8Ip5soriE0wsDZHs6+XJx1/kors/QHjCNGypFNnIINs6PmGiZ5MM9PTQ3dZBz7lWutt7WLZ6
KZX1dSxcPBvDdmmaMZPtb+3gnZdep7+3B622giXz6pnZ4BBwBnANL2X0DgiH6qDMzKlV2LZEa3s7pmWD4icSjSJjUTKxmU3vvkdvzyCnj51k5Q3TCKoqwwkL
PZ9DUXzkMnkCPo1sysBIG4SDfrLJPIqAiliEfDbPyGianG5gWS6lxUFqKiKcj/dhGRbvbT5LejhDmaHgC0awHAfTtRkxc4zZeUzXoWfQZmRMx7QsbNf7zFVV
JhIIURaN0jXcy/nBHgLBMAXij0d7sHSWzY1RFEiTyEk89/JZ7rjax2duaWbv0SgVRSq/e7kNzecnl3ZYs24JFRUluLgkk1m2vrufopIQS5bOvgDT6usbpu18
H65jMzw8duGst2zrRP/A0NEdmzaJkqoqVFX9cwB885vf9LphIHL5vJ7L5zb5NO0qBMFZcybzV399D6lkhuUXzcUjxjkUFUdYt34ZDz/0J44dPcu6DctwXZfV
axfz9BObGR3sp7y6FoHApyqosoZl2CDkQjPKkxRkbJPzySE0WSGGH9cGSRbIQsLVbRRbIYDXGgcvjZJ0b+jF9oFQXGTZS1WE5aD4HVTZRpIsHFfHsUyQ7IJv
FlimZxghafKF+dARXSaZczBdFwtwhUC4AstyiAQEE4oDPPOzJwnU1BKuquXdPzxD/6nDZEaHcB0LTZNRFAnVp6GpKlY6x55Nb3Fkx17mr1jCof0nOXuqha6O
DnKJFHXlpUxfNJXqco2KYhO/pqObFHibXlB6cnAoLVGoa67HEXB06xby6QxrrlyPo6d57tHnsQyDa25Yx9ZNm1i54RKm1kVpb+/FMEHVXFQE8cE4pcUxclmT
xGCSqvIoRt4g3jeKokiUBAJkXImMkSXZNUzyfD/lJX6mTSnl6L5Ogq5LrLQYV9gYls2omWHUzmMX2A3xpE0ma+E4Do4nNSAWDVBZFCU+lqSlv4OsZWK6oBv6
hcKJaZjMnVLJZcsa6e9NES0u5qdPnmXdwiqqSn08s6WDgYSD5UJlZRnrNywvjHlInG/tZveuI6xbv4zyipILn+WCBdP5xKdvRghYtHiWdwUQQjdNc/O0SRMz
82Z+wWsFFfRCCv9qBfx+d2x09J1wMNSlqsrUYNDPdTd65STPI8y7ZCiqxOo1i3nqidd59aV3uWjlfHw+laqqci67YjmP/HaTp8oTMiFfiIsvnsLOba04RsE0
DK+ujhCkbIvW1DBN4VKiit9zNxcejkO2PfGc5HqqUeGOH+peEAgNXBVsyUVVHWTJRg1JaNEgij8Msut1GG0Dy/S0Jo4oUAdch7wtMZRyyGRNXFlGKNK4GArb
9pwiZT3L7q37oLiSZx/4e4zEEM1TG5EnTGKkfwhNC1FSUU4+l8fI53DDFtUlEbLxETr376TFlsEfpqaqkcDEMH4F5LISslE/g5rNmOuBbKXCpct1BZYrYbsK
OVUlWqcypaSSoopyzh47zh/b2snn8kyeO5MFVyym2BpguP0877y8mXW33ca23X3k0jZmNkcsGiTgUxnoHaKmrBQQjPaNUFYcoa68hMHBMRKpURzXJSSr3p1A
N4hoMnWlQVKlEUpVH1FZIafrpIwsWcdCwisLO67N2IhBPmMjXLuQWTvkU1lcv4wcFeR6bRwXMvmsx/gsCPhcSeHdPX1ctaKUlQtrONVlcLq9k037h3Fdr0ej
KD7yGZfr1y+jsbHmgh3uljd3oRsGG664GL9fK6hRobSsiHs/fL23uRUZcIVt2f35vL45Gom6/3q/XwgAD0/iuMLj9PXbtv2mqipTvP/liTG8hgUXzJSbmuu4
aMV8dmw7QOvZTmbPmYyQBWsvXcqrL+9kdGSESKyIoWGDrdsOkc+AT44gC8XbYsIDB0kIkoZBW2qUKn+EiOxHRUJ2vakhBU9aAR5I1xPXeVagtmnjKhAuD1E1
OUZRbZhASRBfKOBNG9m2x8CXPXyfns2iZ1IkhgYwdJ1YSRUhN0jPUJLzncOk8g5yIc1zC070tm0jSYI9r7xMw/QJfPobn6WmsQ5FkkgOj7D5hTdpnjqFqppq
9JzuoT70BOrYaexcijErSnu2jKwpyObzjPT3EpLCCKWYtOV49knCm0twCt7MruPgmhZCQLi0iFi1RlFFKZUVZZw/eoL20SFSiQTxsQxqUTELVy1l99YDrL32
ChqrQgz0jqIqEpmxFNFoCDnoZ2RgiNqyEkLhMCP9YwQ0lfJohKJAgHQmg5E3kX1+yv1Bgqag43CS6mgxsmWQzGQwbRPhk1ANgWk5yMJFliUGBzPkDAupIHdX
hKA4oJHWEwxn3Au6MNcFG6/m7woXSVFpH0ixdUcf1sJi1iyuYMvufrpGHFRPpYNhCWLFEdZfthyfX8O2HXr6BtiyaReLl8xi5oyJFybCXNdzJZVkqZD5eJ0e
y7LelqCrICly3q8Wld8fDdFolHfffZcrrrjC1HXdVRT5SiE8cVyhIlqo0Xrf3OfzmhFb3tyL3+9j6fI5gKCoOEJ/7xAH95/CFwxh2RaJZBZnPKoltcDDlJCE
hCRkJCFju5DSDXKmd5mybRfDdNBtC1t1EEGBFJJwVTCx0W2LUF2A6RuaaVpWi1ai0nr2HNtfe5fXn3qF1x9/kTefeoV3X9jM/i27OHvwNMmxNNGKSqqamimu
rsV1JbJDg0xqrmXq1HpcYCiRw5ZUXFlGNx0m1RYza3oju3e8x6L1lzBp/jzvzZMgFotg5HL0dHTRNLkBAMOyyJlgp0exEj3kMjnG8grJvDc6mM+ksW2v82lb
lqfEtAWm6WIaNmZeJzMygpHN4I9G8YeCBEJ+olEf9ZEUDWUykViMcy3nOXXwMLI/Qv30aZw7epKG5gkUVdRw+PAgsgDHtHDyBpWxMD5gbHAMzYGw6ieTTJOI
JxCWRURTifl9RFSFICBbBqaeJp2Ok89msE0TVZOoqC0mFU+jm3n8PplYzMfwaALDcXAcBxmHgCozmE7ROhQnmcp76lI8CKPhWDhOnts2TsAwdNr6EsQ0me6u
YUIRhahf5WDLGLIsIYRMNu+wavVCbr51PZqmIoTgpRffYfOmXdz34etZsGhGQRLt4drHrQveh/XJ5PO575WUlBwb38YPPPDA//8JAPDFL36RG2+8kXvuuUd8
73vfO6xp2k5Jkq9yXa9+mUplOXjgJCXFMabPakZVJJYsm8OChdN5Z8s+rr52NVOnN6FpKusvW8Zrr2wjnYwTDEcBB93M4jp5HFsn6C9GkYL4fBq2JXAdL/e2
gJRlkTPTqC7U1cWYNLuKxhkVlFZHUFRP/mDqNqZu44/KdLW28tqP3+T4tv3oZppoSYCq+lKmzCgiECwHV6BnTeL9nWx75iCbH32SyvoaAuEQZ46cwpEkIqVl
rLv1alZduY6qqhJ2nhxkTLcZ1h2OtI+xfFozkZIY/pJqhoYz1FSGsSyXeDoJQkXXbbrausnrLqm0QTKRxozniKRzSCKPq0aRFT+yohEOBJGMHNaoV67TJbkg
GvSeWOnEGLaRp6KhESF5l0bXyhO1eqj2DUKDhK9mNtHJczl/7ATn9uyk/+xZJMfm3KmzLLpsOj7ZxTUdFEmgOA76WJyKSBgt4Gd4aAS/6ifs8+HKCq5jkUsk
PQCuoSPZNrLroErgkyQUWUGRXMxcnoG2PlzTQHJs0skcibiFEDaqIhHSfEypCXKqe5TeoWSBzgyWO442d5Ekm0sXF3PtujKmTQxysm2A3lGdmliIn/zhFBUl
UY8J5QpsRxAMBbnq6pXEYhFP6zU8xpuv72Lq1CaWXzy/IN12OXu6jb6+IebOn+aNSY7X/i1rTz6vH/z+9/+W73znO/86A/r/3wGeffZZ91vf+paoqqrqz2Qy
m2RZXue6bkAgeOPV7fzT3/+WCU01/OMPv8iUKY3EYhGuvHol3/67X7P1nf1MmtyAEDB95kRWrJzHiy+9RyAULtB4PRf1dH4M3cjgV2M4VjGKHEQIb05WEZ4E
WaguS9Y0sHztJPK5OCf27aXrlQ7ioyMIByLRKJX11fR397L/ze3UN5dy1T2rmbJwCjW1xSh+FVvScPGeMLIsIbk2w31jvP6bZzi/bz/ZARC6xeR5i6htbmLr
ky/RcuA4t3zuXjYuaeT1A730JAyyho2e1zENCz1vMTqQQOg5VBkyo3HS8RyS7DFFezp68IWK8AVCSKaPUKgJWfWhScX4LYXE6AhDHZ0IxyAQ8Hu+CZKEJCtY
pkkqlcYXCFJeW4dj2eQTCYKRIMHsIBE6sDRBLjYJf3QKUxo0JkxupNxezpO/eYbdh1q4+bYrL0g/wCUkCyKyhM91cNJpijUFNxggkcmTzOeRhEwwqFFaHCIX
d7EME0UWqIAiXBThzUuEIyrVk0rpPtWHZXgnvSK7Hugq7KOsIkYikeZsX5KzwwnP9WXcvE7y7o6mbTGxWuWSxeU89eIxbr9pIasWVXPyxCCVZcWMZfrpjWfQ
VBVJkklnDC5ZO4+ly2ZfOOXf23mEc2e6+dinbqKyqhSENw323W89xIljZ/n0/Xdwz4evL8wDYFqW9WZlZWWXJ4X48+X3fxkAAH/3d39HNDqFM2d2bFZVtUWS
pHkAhmmhGxbZTB7LtC/kRRevWsC0GY1sem0Xl228iAmN1Wg+lRtuXs9bb+0jl04SjkWR3qer0c08up4nn00SCZXi90VxHT+u4kcSLus2TmbZynpef/JPbHv9
LTRFpqKmlFhJGFVTGRvq58yR43Sc7UBVFKYumc28NcsIlZSTyDoYGRckFVn2Nj/CxR9QaTl0gJKiMa76+U2osknfuVbeer6Fs0eTrLnqEg7uOMDPvvz3fOjv
PsdVSyfw1NY2RuJ55EkxKsvL6TpxhqKiMtpHxlCxkFyb0cFBVL+PoF8jFAxx/PAhps6/mPKyJuKpMYZ7+xnoO0h6bAzLsJA0zYOIjSYvaOAtI4dAMG3exZRV
12DqCU84NzhARMkSig5hqzpxfzOGvwGfohJSHUIxiWIlxp23r6b1fC9NUycyOppDzxlE/T4iikRUESh4IFrX0on5BLYpk85bZPM6TdOLuOnOObz+6EE6jmeQ
FM/MRyqMobjYIDvEKgL0nwPhOAT8GhW15XS0dKBndbp7hulLJRkxDHTAkQUoqufvOz4f7LpUlalYlsXL23tZuaSJD988nWdli1gsQDDgxxGe55fleu4uN9+6
nlA46FXrhuO89soOSspirFu/9ALoSs8bjAzHyaTzZNK5P/uFOe7ZdCazafNbb71vJoz/cwAAbjJ5Rpw6ff5cKBJ8JRgIzHJx5WuuWysikRBlpUVMmlx/gehV
XBLj5ts28MDXf8Xrr+3gwx+7EQTMnD2JK69awdNPv00kFkOWZM+cGpeA5kdVZJLxBKaRRJE0fFoMRS5i8vQaFi6r5+lfPcrON97i1o/dxOTZ073LjQxCqJ43
mbDBSnG+pZv9O4+y9QsPUj9lGhdvXMvkmZNQFa/kKkneQIah27Qf2sPKK5qonHEVjp6muNSicZLEq4+cY9PTz7Dm2ms5cfQEP/7a3/OZb32FjQtr2HKgG0Mo
rF6/kl/+4FEUWaO0phJhGwz39xAsitIwoZbcyCjlpcWUl1dyYNubaFqAbDaFg4svGCJcVEYkGkPWtAtmbo5t4zgWRibFSNd5Os+fpriqiVj5RFIjbTiZFPme
QVKGgVFeR17UEbQlgmaGsDWGz82Sirs0NtcwbXoFe3buYcMNd1AcVVEtCGkSmuRtY6ng14BtEdEkDFOQA3JZnbHhDKblFNhOTgFvI2M5DjIQj2fZ+8ZxcB1s
AZbh0tsxCIpEaWUxx9t7GDR1XJ+CGtSQfCqW7XgWr6aNbTq4kiCnm5THZFRV4tCRPtYsrOaKNRPZf3AQ3aCQ+wuyKZ0rr17FkqWzsR0bWZLZ895RDu47wX0f
uZ7qGg994rrQ0FjNV752H+1tvVx2+QqEEK5AOHkjv6mjre3EpWvX/tni9F8t+V//hwceeIBvfvObAKKkOOzGk4khvz94hSRJRX6/JqZNa2JCQ03BmGx8blhQ
XBLl2NEW3tt5hItXLijQ42Qqq8rYt/sYyXie6tIgGxYUkUnb6LpAFmDk8wgccA1sK42eH2HBkgamTq3h4W/9nOXTpxIJ13B8Xxcth3s4fbiXk4c7OX24jXMn
uxkYSBIsKmHByrnMWdDMUH8f21/fTjqZZdK0JqIxD4YqCYGZ12nd/QazlkQJVSwCSnGNc2jyCJOaNQZb+3jppaPMXjQPM5vh8J4jXH7tpQwldWRZZlJ9Kds2
bcXULdLpNIl4nGhFOY0zpyFrClYmjcgbRIqqaTl+GMMwqZw0nZKaBqLllQQiESRFKeibCiN+sowsq2jBMLGSCtKjQ7Se2U+spJ6aSbNx9BRkhtFtjXSwCccf
RRE2USeB382hixCGFManygSFzTubD3H1bZeTSdukR/KEfYo3J61IuJriVd4sz9zCdlxMx2VsKMPxvZ0kRnO4qsDWJMyAD39VlOlLa0maFsmsjo1TsCoCw3FI
G3lM4eKENXpyOdyiMP6KCL7igAcXcGxs2/QM8wrOL7Kb5/KLSukZTJJLG6QyNg89d5aWjgyOK5BkGV23iZUU8fkvfYAJjdWAy/BIgh987xGCIT+f+OxtlJXF
Ljh5SZJEQ1MNc+dNJRwJAgjXdfrSqfTXm5qauqUCqeRfpz/An9Wg719CCHK5nOvYrjB066xpGC/8j1/qvi+gvMZYeUUxV197CcNDcZ5/dgu27eA4LpOnNnLT
revRsxmEZVMWUAkBbt67bKkCJNdBuBbCNTDySVwnDxKoLjQMGgS6XYJKBcXhakqLaigvrqck1kBAqyUXj3H2SIq3Xz7LyWMJ5i1dwh0fuY74YB//8v1/oeXY
aXyq98Frfh9CKyY+2IGb24qb34lwBkCR8AUtLlkdYlqzRmtnO44JfafbSQ0NUlse4dj5EaoaJ7B09QIikSCrr7ycBZdewtRF81H9voIpuIyQFHBlaitrmDS5
nvToEIoSQNOCSELxKl6S4m18RUGRFVTNh98fQJZVVMXPnFmT6Tm1lQO73kQumQwlMxk2YgwNpUmPJMiOJcmksow5EeJ2mLNtg7zx9lESCZ2xoQH6O7uYMaWU
sF/yfLGEwPJpWEEfjl9GqBKWcDFcGyE7SKpEVlYYDfnpL47QU1ZMR2kUZXYV6+5aQHThBMaqy7Eaq3HKi0kLQUq4JFzIh/2c7BvGKC+iZGYjSkTDETaWbWJb
Bq5t4pdNSoM2snAYjtt0D2b56DUTaazUkCWFeEagOzJCVhFCQTfh8itXMnvOlIJlkuDN13dy/OgZrrnuEq8fUBC6XbA8Gpfse0Ro1zDMV01TP64oyv/y9P+f
PgHGV1dXF396/jnuu/deK5vOJBRVuVQSUtE4bRcEum5iGCaapuA6LpVVpZw8cZ73dhxi7ryp1NVXIhDU1VVy/PgZzrcOMjjgko7rVFUUc9nll9DT2UUunUYW
3izupYuLqa2JUTtlGru3vkd4JM7C2nqG/BEcRSKbyzE8OsTQ8ACjo0MkkmNkMmnyOZNE3KK3M0Uu7zJv8SxisSCbnn+TsbEEDc0NhKJRhroGSfUeZtJ0HcwO
BHlcTEQuTShv0NXjsuq2mzl1vI324+0svWwVofIK3js5SFE0wMzJ1Wx++Q2KymsJlJVgmLqXXggwUhkwBR2tnfhUi7/69ufIxEdpOXIaxR/BF4oUqj2eWlEq
bH5ZVkgMDpIb7uemOzfy5W//FRevXsrpI3s4uGM7ofLJFFU3Yul5cpkUEo4XdL4wbec6GR2JM2fpApoayjh7tIVQtIyps6fT2jKCa4PlUzH8qpf+ODaGbjCU
ypO1HCwhyAY1ksVB0tEg+YCGrsrYqkTWMGntHuVkxwjJXAYpIKHbBhk9RxKLJA4pXNySEKGKMKn4MI6pY+s6lp7HMXUMPcctl5TziRsaaO9J0taXojYiM6nC
R1lxhLcPjtE75iArqmcKnrOon1DF5790F+XlxQhJov18D//8j49QVVvOJz97O9FoGIFAzxvYto2qKoVAAFyB67p9+Xz+gbKy8rPvP9T/XQFw5MgRfvTDH4n9
+/eLWFFsNBKO1MmyvHScE5FMpPj1r/7Elk3vUd9QTXFxhEDARyQS4rVXt2MYJkuXzcHnUwkEAxQVh3lny14UGwJCYORzDA8NEh8dxXVtFEkQUAU3bWzAMQ0i
NZNxBOx7Zy9rKyvQ5QAHuzs4136WrJHFF1KJloQJRX0IBUw7TzaXIJtNMzgwRtvZPkLhGDNnTOLU4eOcOHqapimNlFZUcGLrbmobTEJFkrf5XR03mUHOOZw8
maNs5iqWXbaco3uO4NgSF61bSltfmnQmzyXLJnNw+352b99JWXUNvoC/4P5qkxoe4ezxE/T39ZFO6kTDAT71158gElA4sCf/KAAAUUVJREFUvvcg8bEk/nAM
1RdEUjRUzYeezjDS3kZNeZDP/fWH2HDTVRzqyRMoreCaKy/BJ0x2vfUqmYxOUUkN4FkVyZqKaVqMjYyxaOUySstLqa8vJjvUR19/jmVrV3DyxACGkLAjAWxF
wnEdLNOkeyjJSNbAUhQykSDp4jBGUMORPeM8hIPsOui6QU9fnFwygZUeJT48wGh8lKywyMk20aooIqaRw9NcmXoWRYBtmtiGgWkYSI7B+rkxokqGqY1FbDvQ
S1lEYd/pBM/uGKN9GITiQ9L8OEIll83yyU/dwKrVCwEwTZPHHn2FbVsP8Nn772Lh4hmAV/l56JfPsmfXEaZMayQcDl4AsZmW9eTw0Mjvi4qKzP/d5v/fBgDA
o48+SktLi6iurjIVRUlomnYJiBIh4PTp83zvO79l/94T1NZVMG/BNFwcqmvKGegf5a039zB1WiPNk+oBh+rqcvr6Bti/7wRFgQCubRMfi3v5uSwjFxCM59qT
HD85SKi4iMUrl7Dtnd2I0SQDo0MMBvxMnzebSTOm0Dy9ieZpDTTPnMjUOVOYMX86sxbOYMrMiVTUlGBYBqdPnqezc5jJUyYjY7Nvx14mzpyMawdo3bmbhoky
GjpuOg9JAzsvcfyUS2jyKhpnNlJeEeKPv3mOSdMn0zy1ERwbe3SAN559jWkzGzl14DDtp07TfvoU54+dpPNcG7olmLV0FaoSwMyOcvmtVzBr4Rxmz5vMYFcH
LceOYRheR324qx3NSHLDLev45Jfvo2LKNF49NMju82laenMITeO6q1YwZ84Utr35Ksf27/NIFq6DZbmkUxlKq8upqq3CdRz86Ix0ttHVl2HFZWs4crofQ9Ug
qOIIrw4/OJKid2AMW1HRiyLkY0FsTfKSYcfC0XM4uTRCz4KZRXMN/MLCyKaIFkWYOHMSI8k4ecciLznoBbd7I59FOCaRYMArGes6TVV+KsIu1UUauw70sGxR
FalUDke3QAlwvFeg+IIIzYekqSSGh1lx8Qw+9smb8fl9CElw5FALP/vREyxaMpMPfeTGCwbt72zZy4//+TFOnmhj/sJpNDbVjje+OjOZ9HfLK8taJOFJC9/f
+Pp3BcA3v/lNpk+fTnFxiTh//nx/LBarVhRlKSAUWRYdHT0EAhpXX7uGCQ0eSc6nqdTUVrBr+2FOnTzPxSsXEAoHUTSF2toKdu0+zMhwnKJgAFku1MAlySNB
C8jpFrrpMDQQZ9XG1fijAf7w/OvEfQEWXXIpgXCAQMxHaW0Mf9RHqChIKBYgFAsSLY1QVlnGhEkTmL1wJnMXzSRUFOTs+R4sW1AUi3DswDEmz59LNunj3PYj
xISB33BwdMHhIxkGrBk0r1xPKpmjaWoF7afPcuC9Y2y8Zi2hkIadzbD9zXfYeP2lzFu1jEhpKcWV5VTU11PTNIWGKdNQNR8nDuziqhvWUdY0kVf2dFFdX8PV
16xmxrQJjPR1YqRGWLNmPvd/7WMsXruCliGLV/f30TVmg6RgOBI9w2mmVAUIKg5vvP4useoZVBYFUISFkFTi8TiBcAxFVTHyeXxOnqN7DuFoMeatvIgDLcNY
ioqsSCC5JDI52ruHyZo2bkkUOxLwnLRdByufw0ynsDMZXD2Ha+ZwjRyuqSNhYRo5fAGVWEmM0UQCwwXh10CR8PsVbD2LY+bJZbPkcjp+1+SjNzRw4+pqwirs
OZUklbK4dnU9YQXaRyV6cxqK34fk85FOjFEchL/52ocv8H6SiTQ//sFjDAyM8KWv3kvzxDqvvi8J8rpB65lOGpqqufb6tRQVRRBCOIZhPN7Scvbhutq68To9
/+EAeH9FqKKiwkmlUj2apl4qhCgPBP0sXT6HS9cvZ+p0bxh53Ji4uNhz7Xvt5e2omsz8BdNBQElJlEDAx7vbD6Ag4dc0r4UtFVI4ySvV+f0xsIrwB/ysumIZ
O97ZSTBcQf3EKRi2RawiQqQ0iKwqqD4VRSk0umTh/SpJKIpMtCjMlGlNzF88i3DMTyKRJZPMcvrwSaYtW4oancjB93rpaE1z4qRJd2Yis677IIGSUvJ5C9t2
aWgo4pWnttAwqZm5C2ciCdj00hts3bwNSfMTKC2ltLYGRdVIjcZJjY0RCvgZ6u2jsrKYRSsWs/3ECLtPjzKSNpkyvZnrrl/HFdeuZd6KZbQn4I0DfRxsS5K1
JBBeV9hxXSrDEssmRvndg7/hVKfBgmWr8et9BKIxAuEYel5H1w1UzUcuncVKJdm8eTuXXXcl/rJaDp4ZQVa8nsPAUJyevrg3VxsLIUJ+Dz2Sz6OnUljpNBg6
wjERtolwTO+JZxmYeg7wkIeDA4PYAlxNo6apDtcxkYWNkc3g6Hlc28QnDKJynoawS3wsxbJl9bS2pXhxV5JIJARqmB2tFrrkQ1I1TNMgP9jLhz98DRsvX3kB
ZPXKi1t5+olN3HLbZVx5zapCPwfApbyilItXzGf9xouoqa0Y17K1ZTKpv25oaOiRJBn+J42vf70U/g9LCMGOHTvcfD4vhcPhszNmzHgkGAx81xUosaKIKCqK
XjAiuBBVssTlV61k147DPP3468ybP42LVy3AsW0uu/xijhw+w6vPvks4GPAw2a5TEDAJ/L4iQoFqHFthpNcjkAlZUFFRU9B6CGRVQZIlFFVGUWSkAs9HCAkh
eUGgaSqyJHBMg4AqWLp0NrNmT6a9tYc97+5hy0tvs/Gmy1j9yW/Q39mDYRiU1Nfjj0axDANFU8nqDqmsQiDo4+2XtlBWWc5jDz+GK+X4/N/cw4gZZCxnIzkW
tmmgqSpKUBAIBZg2bxE7tr7HrffdRF1ZiPZ+g0PnUpzpTNJUGSQcVOge7qN/TMdGRlJlTwQnOUiKx9Evj/iQHZNj+1uoa16OpCewbBvXFaiKoKa6go62dnrP
S0QjEXbseY+SqgZWrF/NO8dHMZBQJcFYIkMmb9DYUILmk0npFl1DGdJjaSxDRzi29z6Pg2cdEwf7AqrE47x6vQTZw3ggqSqDA0NYRhas/AUXSTOf4/Y1JRSr
JiOjOq/tGmLe3BqmTynlpf06j+9IoWgqjqSh+LyxxWRfN5dcPIubb74MWfH6AKdOnOfRR15i4uR6brh5HT6f1zsZH8uVJM/U0Ts5XVwX2zCMR1OpzImSkrJ/
0+b/NwUAwNGjR1EUxf3IRz5iDvT3/VHT1MsUVV03Pjc87sIxvlyguCTKPR++js998u/59a/+SNPEOqqry/AH/Xz44zfScrqdvvPDNFeWUVweZXRoFEUJEQ03
ICQflukQLi4iOZYglc1QXlGJLMm4ljesP+5FcIG+iGeTKUkyjmnS1XKagTPHyYz0gWMh+8NEKxtpmDuPG+65gdaWdtpazlHRWM/EJQsvnKaWaWFaNtlkDuGY
/Pwfnma0O00+e4rvffHbNE2v5Rv/+DmIVKDFXWpcb/QvHc/S0dLFSO8I+UyGkooqDm5P0XK8hbLK6diWi6LK5AyHEx1Zr4yH8KylCo0lV7JBchGOV0KWJZ/n
nGJDwB/AtTIga/gDQSLhIMGARtA3ia7Wdvbt2YvpWPzdP/01Q3mJI20J1IAfG/AHVYqLSwn6JRzbon84zljfIKZpFayoPEtbxrGW7niXQkYSLh7l3zOwtl0X
GYFUsHKXKKBNbNtrNpogXJurV1Zw6ESKP+0a47l3+7l0cQ1lxWP052QcSUaSJWRVIdnbS0NFiM/efxdFpTEvIBJpfv/wC/T1DvH337+Duvqq96EOvdeL6xQa
sR7fyLatPTk99wQqBv+Lru9/OAA++clP4rqu+5Of/ETcf//9HfFk/DdhRZ2LEGXjcKLEWIrXX9uBz6ey4fKL8Qd8zJ0/lQ/cczW/+OlTPPPkG3zqs3cgKxK1
tRV87JM38+2/e4ihVI7SyjIUJUAoXINQAjhI2JJAVv3oeU9eHAgG8OacHQzD8gwrChtlvMgrSxJdx0/Q8s7LBKVOqptrqJkzDVWF7MgxBlp3smXnizStvIl5
6zdQP6mBfC6Hkc9jmxau46WNW158myN7j3LxqoUk0wblU6dzyaVTWXrRLCZMriWeF/SPWWiKhGV5gyCqplBUGiMxlMSxXdJjo+SyGVKJFKEql3xex7FVVNnz
2HWcgvSZQvdVgJC9XF3YLqZtk0rmsO0YoaAfI5MCv4xQVALhAH6fhiQE5cUR5q+Yzs9bjnPF7ddQ2dzE7zedwXRl/IqMcG18IRVVchHCZWAwQWtrP2bBucUV
npTY0+IJb3xUFp4vghAFzHnhWBOF3yjJuJbJlIn19Pd0MZgYxcrpXspkw9kug+GhPBOrNWoqQryxJ008OUzelZEUGUmSkBQZI51CzSf51P0fZOq0Ru9nufDq
y9t4c9N73HzbBlatWXSB/7P5jV0kEmkuv3IlpeVFUJgtwCWe1/O/ueUbd55766dv/E81P/9XAQCwZcsWioqKOHb4GCNjI69qqrbBp/nuocCBPrDvBD/6p8cQ
uJSWFrFi1QIUWeLGWzZw9PAZnnrsDebNn8YlaxfjIlixagF33XMlv/zpM6jtPmrKa5G1CLYzjsP1HF7G9R7YHltS4GLpZkGr72lMbEegaRpt+/dz/OVfs3wV
zFgxnWDdnaBNwkWHlAZjec4fT7L5xd8RLCmnef48tICLZVq4uGiayt5tB3n75a3UNzRyaNdxMtkMdSXVnDidAN9Z1JIKhC+ET5PQDQvdcbBtB8tyyKYyDHX3
0NfRSX97G00Ta5g1bybFdaXICE62j3G+N0Mi/Wcj6AutG8k7YYXkbULTtFEkH5qmUlZZTNvgIJTVovh8F8b5TNOiMSjRdeo4wZJirr3lWrYd7qFnKE8kGrwg
ZlMk77KXyeQ509pLXs/j02Q0VaBIhQEVSfaaZsgFUzkPp2BbBb8G10tFJ9dHiOsu8VSejvNt5FIJYorN9BkRTrYm6E66jKZg+5EUF80OMaMxyKk9Jm8fTyGr
nj+CpMi4lkWmt4sP3raWDRtXeCQHBEePtPDwQ88xe/ZkPnD31Wiat0WPHT3DP373EbJZg2AwwPU3rcMFJCHQTeONgcHBF9766Rv/1u18YUn/1t+4fv16ysvL
3c6eTn74Tz9MZ9KZnzi2c7bAUidWFKGkJEo0FvIc+go4ivKKYj7+qVspLY3xi589Teu5biRJICsyt9x+GVffsIru0WFsyY8sKQVXP8mzwrEdAsEAqqJg5nWv
BAboORMjb3rwVMuD6A52dHLs5UdYf32AhZfV4PfncYweHLMPJ3cSJ9cBsmDizCBTJuU5vWsHpmVjGFZhyFphqG+E1595k5vuuJIlKxcyYdIkHNtidKifkopm
Du4b4rcPvsTR/adIJzLoukU2rdPT1s+7L77Jy798lK5N72IeOwmJONZokkd/9Gs2/eEpyu1Bbr64ks/fOoP1i8uJhiQM08YoAGkdy/Uod5aLaToEFVg2vZJD
7+3nyIGTpEa6sC0dzRdEyDKWA35JELGTbNp7iJvuuQVD9rPneJ93fDgeVzOVTJNIpBkcTXLsVAej8RSRkExJsUZtCXx8dYCr5/tRJBshuZTGBOVFXkFBkkFW
QSgCSYFwQCYWVMC2wDYZHhgmPjzKqqlhPn/HZO6+rA6fAqYt0xP3sfecztyJMQKajKaqyLLkFSmES7yzg0uWz+CD91yH5vN0/gMDIzz40ydxbJePf+ZW6id4
MgghXEKhIMWlEWJFQaKx8IWD0bad9nQm++OmxuZ4Yau6/9Y9Df+HKtC/Xk888QSPP/44V1xxhRjqHxr2+X22oiirwdVKy4qZPWcy6zYsY87cKQUtuIeprqwq
IxwJ8PILWxkdjbNo8Uz8fg1VVZg2vZnTLec5c7aTomg5slBQNQXHdiku9TN7cT07X3qX4mA5VfUNpHJpr5LhVwiFfUgIFEXm4CuvMLH8LEs2VBdceQwwWnH1
44jcUYSb8mgFukG8O03HUIzGxcuxHS93dSyHP/72eaLhAJddt5o3XnmXpokTyaXStBw9iiRJlFTUoBsKbef6aGvtoe1UG7vf3MrbL7xAvLuX5uoqLnLgkmiQ
4JypLLx8NdlsiuP7j/Lmk69w+L19uPkMFy+ZyLwZ1cRTOfqHszgFY+hxdmfesKkuVtmwoIIHv/sgOSeMZeQY6Gxj3HTIMAysVJwjB/ez43grazasoaapmT3H
ujEsz2d5cHCUEyc76ewZobN7hGQqQySkEo34sG2HxXUujRGT0liAnlGdnlGL9fM0lk33c/hsHtv1vHojPpvp1SrJrE3nUA49b2LmdcqCJhU+ixnVfvo6h1k4
o4QzrWMYtkRteZjdJ1Koio+zA57hhVfyhnh3D1Nri/jK1z5EbW0FLpDL5Pj1L//I5jfe4+OfupnLr1x5gf3pulBSGmPO3CmsXrOIxUtnFbq/5PP5/PeHB4ee
Ly8vcyikPv+7sue/Xv/mFOhfr4bmBrunp+eZErlklaaptyiqzPxF0zzysjOuR+VCEGy4/GJOnTzP009soqGxhg9/zGtqVFaV8ZnP3cbffvVnHD1zgMWzl1Fb
G6WzfZSx4SRCUqmfUM9wXz/zfT4kZBzDJTWSJVYaQlFkMok0ic4WZm5QEfksrub3hujdHMLKeOOUroyb02FUR0+6RMrKcVwX27KRZZnD+45x8sgJvvS3H2Pz
qzspryhj2eo5ZFJJ4sMjHN25Cd/BCFoohqYGMXUD3SdR2VyBaJpMzJW58RN30va7pwidOE15aSkrb7yWoArCNnnjX35L15H9bH7oId5+7kVu++SHuPuyFaxf
YmHYDrphM5bS6RvO0j6QIaDYSEIQjgQJ5XzMWbacc0cP0t7axrmWU2iKgiIJJjaWcslF83jrtbdYdfkGVMkhnsyBbWBbBiUlIXTDxnJshOtDkTyLUVPP0VAs
c+BMknCJREOpxsHzSTBVZtSoBESOgTQ0lrhcubCIA61ZklnT0+a4NvlsjsWzIqyaEqOzLc6mHYPUlWqsmBFh29EksgSn+hzaxtK4surh6CWJsZ5eyvzw+S/d
xaRJEy7c41556V3++NQmNlx+EdfdeOmfjTGgQIuD2XOnePLsgumeZdubc7nc45YnMf43X3z/rwKgsKFdQNTW1g6Njo78UFEiMyVJmukZc4/f1l1viL0QAIGg
n3s/fD093UP84ZFXmDChiiuuXoXrusycPZkvfuVu/u5vfsHxM0cQznwkIZFJZhkeSDJz2WxeeegVXNMmoAZJmWn0jMnoQApVU7EMAwmHgAMMp6HYxVPZjTMx
DNysBXGd1Bh0DQSZcPlib17YccjrFq8/t4l5i2bR2T7A+XM93P+1+6itr8a1V3DwvfeY6goWIsik4iTJsKu6kfoHPsMn187ihT6dbd/6JW8+/waTUgkU2yBa
XkYgEsHSdWSfRtgf4vqyIHUbpvHa8Q5+87VvsPSqa1i4YinBYJBgKEhF0MfsqQGCi8tQAn6KogHmLJ7Fzp88xsTp05k6Zx6qKiFJFnMXz6OytpIiVeeZ3/+O
0qJqgn6NlfMnsPNIJ0NjWVxcaipDNNUWMaWhnLxusmXXGc53jqJiUxpSOJa10CWTomI/WCbZlE7YlZHyceZXh7liURG7WrIcbs97nsb5PLJrI2yLfNZgRnMR
SibF82mLTXuHuGV1Oapt0pGwEZInDpRkGaEopIdHCFg5Pv/Fj7Jk6RxvyEUIdu86zC9/9gwzZ0/ik5+5jVjB4mh871Bw53Rdx5vyBWzLPptOp/5Z0dze6dOn
/7suvn+RJ8B4PLzzzrv7Lr103U/C4cgPJURoPBJdF/btOcq5sx1ctGI+jU11VNWU8+n7b+dvv/pzHvzJM5RXlLB0+Vxs22H5xfP54lfu5nvfepi23jNMbZiG
aVj0d40yb9Uinn7wKdrPnqV64mTSIxkcyyE+mEaWvTnVQFkDbT1jFJU5uKlRhCp7AeA6HifQdHEslfd2p3FqNlLW2ISRy6NqKqeOnCQ+lEJtjvHetpNMaKon
EPCh5y16OvsYOHeO5YEgc30qCaANmZqGJvoo4qftOk5rD/PqKhh+6V1ulwyEpuCPhYhGAuQKHgmmIyP3ZCgOjnBDfTHTy6NsP7Kdt3bvJG8rDGU869RAOEx5
TSX1U5qpmVjPnnd2UV1VS2qgnxN7t1Nc4T19Dr2bZeZFF3FqtI9orIQzx0/wm58+xHW3XMeCGcs53z2KYdpUl0coj2qcPd5CqChI9dXz+cFv3sHNu4QDCnnD
wczmKY7JOHqO+JiDT/i4doFGSVmMV/clONZlghDouQyzG3w4luDE+RRGViU3mqWxNkAkqLH3VI7ZE/JMqIzxxvHEhckuSVHIp9K4qTif/uxtrFu/DNuxkSSJ
U8db+fEP/kAwGOAz99/JhIYawKO77dpxmLr6ShYvnVUgkjBe9czl9fzPd+7YuXPRokWSKBLO+GzKv3f9u+4A4+v9HeIZM2aI/v6ec4FAsEpRlPmu60pCCAYH
Rvj2N37JM09txnEdliydjSLLlJeVUFNbzqY33uPI4dPMmTuFisoSHNdm0uQJRKMB3t26G9eGsD+MbZvMXTqFsy2nOHHkOIsWrCBr6ORNwzPM0E1kRSZSWs6J
3ccoDVoUhVRkw0XogCVjWwojww5btsbpkRcx8/IbQVaxTAtZkji0+yjJkSyzF85izsJZKKrGmdPnwVV4+/k36d25lwafn77aCrSNa8hOnEB2KEFd3sU41cmM
kWHqk4M0nWvhquIAjuNyQvMxff1KZFlFyDLn3jtIVXKE+qoKsvtbKbdtFk6fwMIptSyYMQFRFGXpLdcyaXIdoqudoa072P76m+xraUHPmSQGurnxjg187Esf
we8Ps+2NtyhraGDqwjmsXbuYaZMr2fLiFl569hXGegeor4hSrMHxXXv5/YO/47cP/oHz59q4/pbLOdrSTyYeZ/XMIPtPDOO6DpGgYP+pIcr8Wa5cVU4mr/C7
tzOc7TPBtomqOtcsCXLrylICKuw62EdTuYbIp6mpC3Oq06C13+ZUt8G+czlGMgJJ1ZBVDT2dIT88yIfvu4pb77gcRfHuA53tffz9Aw9x/lwXX/rru1m5epHn
YWc7PPrbF/nJPz/BqVPnWbJsFsWlRd4dTuAYhvH0yOjI9yvLK3O/efg37n333ce8efP+QwHwH34CvC8VIhiUE/l89geyLE2SFWWt63olxdKyYkKhEKFgwIPl
Fh5pyy+ey2fuv41/+Pav+ftv/Qvf/d7nqGuoAldw/U3rMU2bh372At5gkkVP5yjXfOAGvvnxr3Pq+AGmzFzEub42HMvBsQQjfXHCsRBFc69n84EtTGyPU10h
I4RNKmPQP+LQn4oQnLSG2SvX4igq+Zxn+mGbFguXz0GRFTraWxkZ6qGmtgbFH2PP2wfY9frrlJQU4d+4hnnXradx+iRs0+CJXzxGd8tBajQ/KT1HcVsLN1dE
MF2XJCbDp1vpONPGtLkzyFkOSjCANZzCFi5azsY4PYp5dhShKYwYNs7ylSy7fB0HHnmMy3JxtPoIe2c3c+3K1Zxr7aK+rpjrPnADp08OYtpRwtEYLgblE2oY
dQzq5y3i6/OncmT3fnZtPcyv9+5BOBLRkiJsVyJrOCTiSXDdguWQi6YIHMdCQkLP5akKZLl2eR3Csdh8IMH5ftBkF1PXuXZtKUW+DMdP9dBQV47q5MC2ONeV
p2JiCRMmxNh9agjdlsjnJYTqGSXmkglyw4Pcd++V3PnBqzyndlwG+kf4wfd+y8EDJ/nM/Xey/rKLLwzRCyEIhwMEAhrRaBhN0xg3vrYsa08un/uHCfUTRu+9
916hKIr777n0/sUCYDwIduzY4c6fP18Eg8GzY/H4P4RCwSZJkpqKSqJ84ct303qum9lzJuMP+ArdT6+hcvlVKxkaHOWXP3+KH37/93zlbz9MVU0ZipC48Zb1
WKbNw796kbyeY+sbMW7/6Bo23LSRzS+8wIT6SdSX1dKb6AMLXMslPZbBV1RN5cW3MjrWy1BygFwugyNrhBpqmDxpMpHycmzHw47AOHhaoCoKS1fOJz6cpLO1
j97OOBKCLa88R7SsmPU33sz8tQsprytDkgRSMMy9X7iP1pNnGR4Y5OQb77LSZ+EIH6+gIF+5glWL51A7oRqERNAnU1Jfje6CSOaQhYqqgmkaKIZDNmejlFei
+MNYpTW0d8WpMvP4V2xg5Z23ksuksfUs/UM5ervjKLKGXwth5b1LqYugJ2ETC4ZYeNkGLrl6HflUBtAYHM7w+O834/OFaJ7USE53GRhIIBwbnybQVPBrgpKA
zQfWVNPSOkx9jUTQZ+HoFrYMYcVk0ZQIT7zYSlnMx9LlfsojEFBdklmXd3f0owWi3nsjSZ73siSTS6XIjgxy7z1XcdfdV+Pze/zO0dEkv/rZ02x/Zz933XM1
t9yxEUXzJgxdBLIiccPN62maVE9NdTl19ZWFEVKnJ5PJ/ENpSenpH/3oR+KRRx75D+X9f7EAAGhtbeXNN99kzpw5oqa6euvMWTO/HwqF/xGINjTW0thUd8Fc
gwIRzDQsNE3lzruvIplM8+Qf3iBaFOGzX7iTsrIifD6V2+68HNux+PUvn+ett3NMnFnDLR+5nTOHT/Pcs7/j9g98kuqiSk51niaTT+ML+5EUQUVFGZGyJiL1
Uyn3KyiaiqTJCBz0bN5rNEGBDAe26ZDKW+TSefScQdAfwgm4vPHcM4wND7Fi1QbSY2O07DnAcE8l5XVVRMtKCYaDTJ0zjew7I9R1thE2dZ4jyuK//QxzVi0h
EAxg2aDrOmcPn6bv8EnKfSqOKnBME9t1yZoOkgN5B9KGzVg8R/nMGewrrqB5qIfkgRO0nu3CHwximC7ZpM7oQArHdDwUvNDIZ3QcYeMLamRNhc5hh1BAIRoo
pbe1kz89toVMTkX1SVyyfiXnO4bp7xujWDOwsNFUi3AwSDigsfPwAHtOjTBvXhGxgImVyyIUmaISh2hQMDySIeJTKA+rrJlfTGlE49iZHLv3jOIL6ciydmHM
M5NKkhkd4oMfuIJ7PnQ9waAfgGQywyO/foGXnt/GNTes48Mfu4lQKIihGx7gtpDKFxVHWbNuqUeS9lrR6Xxe/+e+3r43/6P5/n9KANx9992888477pEjR8TG
jRutRCLxmKpqjT6f9jkX11+4tBS6ti66bvLLnz/JhAk13HjLej7x6dswDIsXnn0XRZX59OfuoKg4iqop3PnBq/EHfPzyp3/kkYdforz6A3zm25/n25/8Ok89
8UuWrbqcVCJNrDzMwpUzGIuPcvJwK6JLJhYrIhTyFKNIEorq9RfG2fOO40GojJyBnjNwXRdVVUmODLP7tdfJtZxmeVkJddu2UCLZqJpKQlXoC4exSkqRohHM
RJJoTzdLzSw7FI2Zn/8IC9atKGhTHAa7+tjxhxfIvPkuS4TJxICKbXhdbNN2SBguo65NxoXhjj56uwbRfH7MKdPo6e5G6+5nqKOX2mkTcWyb4d4xcgkTQ8+R
TiUZGxyht7WHUHHEs5pCINDQdZ3924+w7bXtqFqMvq5zzJo1kfnLF/OrP+wil8zjC+RIGwZ+zaYkprGnJcnbR5Noio/RMYOaYgnJTOPYCpINmmKjSg5GzuKd
t9pZt7yJwaE8r2wdQCg+DMurOQgkMok0RjbFRz5yPR+45xqCIT+uC5lklof/5U889dgbrNuwhM994S6KSmK8+fpO9uw+wmfuv4tYLOQ1QqWCMbwndTB0Pf9I
JpN6eMbMGUZh6/1fn/5/kQAAWLNmDa7ruo7jiHA4nBkdHf2xJEn1qqre6gr3wkVbVmSO7zvJH5/cRGNTDavXLKKyqoxPf+52bNvhhWffQYDXOS4vQtEUbr51
I5FImJ/84HF+9pMn+OrX7+UL3/sK//j5BzjfdpyFay4lnY/j9ytcdvUKFi6bxaE9Jzl19DwjIyNEQzECWgin4EsgCo6UFwyIXRdZUrBNkyP7dnF6904axlLc
HosxUbYJa54hiKaAorg4ZpJ8t6eH9/s1RNDHK1mX0ntvZ9bqi0mldXw+hZ4Trbz344dpOnuGxWEfASFj2wXrV9sla9qkLZdO3SGsqIydbuPE9tMUlURx/KV0
5gSynaXjcBtCjWHkdUY642iKj/6uDixHZ7SnnVd/d4ZIaSk1TRMoqy7HxaXzXBs957oxdAPDaGX2vCl8/m8/y8FjPezefQbJNTFyeXKGSVWxSjigMDDqOcY4
tsHwsMHimVECch7dVNCzNgFXZ1p9AE328/a+QdLb+j2qnqkgywqupCAQJOMJBA6f/PTN3HTL+oKVEaSSGR759XM8+shLrLt0KV/8ygcpryghmUzz3B83s3vX
ES66eD7rL7vIK4/+uazvmqb56tjY2Pdra+uSjA8+/gU2P/wHq0D/s/XAAw/wwAMP0NjYKKKl0bSiKCdUVZ0jy3JjKpVh/57j7N97nBeef5tzZ7rIZHRyOZ2x
sSRCCC5Zu4SRkTjP/fFNUqk0s+ZMJhwOIkkSU6Y2MqGhks2bdnD0SAu333MtAx3dDHQMESmr4PiJExw/dIoTh0/jug4z501h2pyJBCMhhkfHiI+kCaj+grjL
BVegSDJBX4DiSBH5RJo3X3mGoZEeZi+ax6Rsio0RleKg4rkn2l7zCBcUSSKgKvhVhV7L5VVHInLXzSy9bqNnOI1E64mzvPe9n7NqoJv5MT+yZWKbNtgujmmR
Myz6chZjpkuf5VLrC9FvWIi6KQS0KJlkCvvMKRzdpDdSiaIVkx3LIBxQZZX9e7YycUY9f/NPX2XOwhkokkN/WwfnT56m9cQpMqNxKsuLmbtwCrffdwN3fPgO
WtriPPTwOyQSSYSj45hZlswIUhGGvKmw49AQlg2uYzN3UoDlc0vYvKuPRNqmNOSysDnA7OmlyJKfd/f2MzhmkdMFiuJDUlSEJDM6OoZfE3z+C3dx4y0b0Hya
Bz9Opnn4X/7EIw+/wMUr5vPlr32ITCbH/n3HeXvLHra+fZBsVieeSJLP6wwOjlJcEiMQ8GGa1u5kMvmlqqrqs3/pzQ9/oSfA+9c999zjAuLx1x47s37JZV8p
isUe6u8bnvtP33uEllPtKIqKIivk8xZPPrYJy3yFdZct4bv/+Dm+9NV7AJfn/rgFPW/w+b+6h6rqMlzXZc26pYRCAf7ll08yODRKZW01m599h8rJU5k8eQot
p04z0J6is2U7rz2zlaqGCibPnMTMeTMY7Egy3DNEUPgoL61EEgJFFph6nvYzp3lzywvUTW7gurs/QyDsZ/+Z02Blabcc9rkqI5qGY9kEDAu/JUARpPwBck11
TNq4mumL55BMZVBVjZHWLvZ8/0E2DvYwqTiAncmB4+BaFpZpkzNNRvMWOUvQrducMWyEZpPM5Ui3HCOi+TDSGZKuQwTPpaXIH8ZxTRzXoeXkEQZ7znPv/V9F
8YfQwsVc/8Fb0DQZWfZYo6qmIoRMXrcYHMnw8B92sG37KbK5PLLQcaw8lpFlqG+E9UtK+NO7CRLJrIdnkSyKwz6KiwM01fho6xyluriYzTu66RrJkcwpJNIm
iub3GlySjCtkhodHqaqO8YUv380la5Z4zVAhGBtJ8C8PPs2Tj7/GipXz+do3PkplVSnf+86vefqJTSiKgkBGURT2vHecHdsOUVNXxj//+K+Izpt2KpVKffXl
l18+vmDBAjF//nz3L5n//8UD4ELnDtw7r7hLHDt17IAsib+e0FD9o/u/9MGpP/iHR+jpGvYGW/DM9+YunMK9H76eYMiHkAJ88av3EAj4eO6Pb2Hb8Nkv3ElD
Yw22bbNo6SxKyj6OpiksWXcxOzZv4+TuHTROmeH5zzo2murHMi3OHurk9JF21my4DFVWOH14P1MaJiLncvT1dNPV30Zvdzs9gx1cctXlfPD+jyKEw/Zf/4HZ
8THOyrBz8hTKLr2UKl+QfF7HMnRM20RRFGrLiiivrsAX8JGMp1E0BdfOsvdXf2Bp+3kmxfzo6ZynNixoagzTIm04nM8ZdAmVQz6Vg6kkh/UctY31aAPn6Os8
Qy6fQ8+lwbKQ9m/nfMcZkAS2ZZJOJ7jh7uuZs3QBP/3xM+zacYLK6lIqq0opLYsRDIVwhWAsnqK3d4yevgSZrIkQDq6ZwbBySMLGtg16BpKEi8o40zaAZZrI
OIQ0BzNncP78KMvnlfHOrm7qK6roG8mx80iccDCArPq8ORBJwrQdxsZGmTm7ifu/eJc3G15Algz0DfHQL57lxefe4bLLV/C5L36A2rpyHMfltjsvp6dnkPd2
HC14P4AsKZTXFPOZz93O1GlNrZlM5m/OnDmz67777nMB95133uEvefr/xQNgPAi8z9x1Z0+f7Rzcf2Bz06SJX19+0dzvr16zuPH3v30ZVVUKdpYuN968gXkL
pnlDLq5LcUmUz3z+LsLhEI/9/jWSyTRf+srdTJnWhO3YTJw4wXuD66r5+i++w5vPvsGezXsYHY4jKwFCRSUEwlGKYxFqGhrQ0yk2vfYCw90d9J85gaLIhEvD
2MJmoPM806dPYvWqpfS8t4vE1t3MPdcGisx7E5uZ/dEPovkjDHSMIiQNJVaM6lPQAgqqX8Y0bSwrh1AkfK7EsVc203DwILMiPnJ5A4nxiyGAy5jh8A4y7pXr
abh4KQ3+MJMPHWfL0y8SLCvjts/eRV1zPdlMlvhwHNtxkATEx8bQc3kURaVxykSaZkxi0xu72bPrBC7Q2zNMZ+ewd88RMq4k4UoeeVtRZBTJRTh56itsGip8
nO/NcKbLpmcgQzytM5pIF7T8CtGQiu24vLi5jSuumsHa+cU0VIXYd2LYc5SUZAqDAaSzOnnD5rLLl/GRT9xEY2MtjmsjSTKd7b386J/+wNZ3DnD9TWv5xKdv
pay8GMexQcCUqU3cesfl7N9zAsOwkCTv/Vy6fDYbNl7UbdnmA73dva92d3fb+/btY8mSJX/prfqfEwDj68CBA/T397P2kkvsjr7OF4rD5UpX58D3HduuCxWF
ME2T0dEEA/1D2JYNEhc06EVFYT72qVuIREM89Is/8lef/wFf+dsPs3jp7IIvgLelGqY0ceun72LjHVfTdbadve/u5syJswz2tWDlHPrbTmI7BjMXTueyb3+M
4rJiwrEIg70D/P77v2J5SYw1lkngwYeQEgkmyDJ9wTCd8+ez8J5b8EfCnD/Sw1DbmFc2tb0drWgKalBBC6loQZVgLEjHyTbyr73NAk0hrxueJRSe5ZGiyIy4
gi2lFdR/4oMs3rCC1FiS80daKMumubw0wrETp3jkgZ9z+Yduor+/lzNHzxApjnLLR+5g7XUb6O3uZ3QkwchIggd/9BR7dh3DNh08nwVQZc9yysUGYSEkgeVI
mCb4VJs7r6plQjk01Go8t7mbk20pMlkXoUlMbghxvHUEWbiUFwVwJYl39w4zdfIon757IS9tamc4YSPJHpLSQSKRyBAMh/j4p27k1tsvJxwN4rgOAomTx1v5
3rcf4sTxc3zg3mv4yMduJhwJXpjqcgvDTAP9I6RSacLhEP6An9GRJH19w32JROrvFJ/71PQZ063pM6Z7p8d/0vpPC4BFixZdEM098Yff2y2HR5/t7kn5r7pu
9QNXXbOqPh5P8fyzm72RP8dBLri/gDfaGAj4uPODVxErCvOzH/6Br335x3z2Cx/g8itX4vf7KDj/kc3mOHLsDNl0jrW3XMWdVWUkR+P0d/WRiicpKS+leeYk
QpEwPp/GO69u4Rff/iENA8N8ZtIEKnWXI8k0x+onYExqpnjebFZdtBAQtB3vYaQzjioULMvyPnzHwcqaWFmD3ChIisyYOkbX25tYNJJi1KcgCwef5KJJAp/k
wWTfUgNUffguFm5YzYG3dnL+t0/Q0NtLcy6DLkv4p9dzIlzCIz98iIVrFnHptWvZvXk3P/zKP/DdR37Ant1H+cPDz2PbErbt4QDHxTGW6WA7oKgypuWwclGI
+uowT78+Qs50WbegiHnTQ/zzQ3v49D1z0DQZ17UpCvixEjorF5Tw5o4hMrpOc42P3oEUqRz87o/nqC4L0NWfRcgaQlYwLYinM0yfOYmPfvxm1q5fVkDaOFim
w64dh/jpDx9naHCEz37xA9x48waP2TOeuwvPCdSjPcOiJTO55rq11NZX8sar23vffWvPt++46f7HPvrZddadt38E/sKX3v9nAeD9WT1dXCwWIx6PW3NnXvbE
F75yFzXVld9yHLdu+cVzPYKDqhTGe71hcMMw8fk0fD6Va69fS2VFKT/4x0f4/ncfob93mLvuudqjCwiX8vJSZs2eyh+feo3fPfw8VVWlzJ87hQkN1YQjEdo6
exnLZFi2YhFv/OllfvXDn1KjRambUM+pkTSBYAhdUhhraGDDZz6Cz6+RGkvReaqXka44xeEiBru76Ww7x9x5F6H6gyCBZVkYludB1rl7OxPOnqdY0hjNe6ey
VJDwhjUYckySly5n+YLZjAzHGezqp7ark8V+hZfD5USvXM+s5YuIdfYxtXcON9xzHUf2tjJ91graTzzJgXf3MmHaZAQSjmV6HrmuN8humxaNlQqxmI/j5/O4
ls28aeXMnhblxc09WKbNioVNHD42wGjCobQkhM83RlATVJcEefbFM9xy/RSWzwlzrCXB5NoAj7/ejpAUkjmXsfY0iqKAUEjnbFwhc8PNG7j3Q9fT0FTLuEQh
l9F5/tnN/PahFwmFA3zzu59mxaoFaJqK67oevaIwFDPueXDZxhWsvmQxFRUlyLLcN3XqhG/v3b33d5u3PmmFw2HuuuOj/2kn//j6i5VB/3drzZo1nDp1Sjz7
3O/sB771teN63uxVFGVhKBwoCgT9hZqvwLJsXnzuHX7/8ItEokHq6quQZYnG5loWLZlFd/cAL/zpXXq6+2lurqWoOIqQBEVFUeYvnElFRSm7dh3h7c17OXnk
LId2HyWTyXLtzRt5761tPPTzB7nrvg/yyb/7AsWLF9MZLebI2Q5mKBL53gE6FBUtXMKZfe2kB3KURkvoOdfC9q0vMBrv5uyJQ7SdPcHoUA/5bApXN+k7fYSK
tjYWRUuRbLBsF9MF0xHkHcjZgqNIRNevo6iqAtux0fMm1sEjRFJp2pcvZe0XPoYWjtDb1cuajRfT3d7Lrs3nCIdK6T5zjpLyKDOWzmbnu/vIZXMX/M1cy2DZ
nGJuvKyO9atrOH4mQe+wTlWxxOJJEbr70sybFOGy5RVsPTBINuNw2dIqUskcgwMZpjcV8+K7HfhViatW1jC/Mcre4yMcPJNEUxRkSSArCqYlyORdGic18Nkv
3Mk9911XMKbzUpruzkF+/uPH+f3DLzJn7hT+9oGPsXTZHO8phcuhg6d46MFnGBtLMmnyBE8MB2g+hZD3dOjOZrNflxX30Y98/C4D4G/+5m/+rzQ+/60C4Ny5
c7z99tt861vfEu+8vd3xB/2nNU3rkmV5rhCiVBT8whLxFN994Ne8+/Z+LMvgknVLvNMHKCsvZsHCaYDLqy9tY9++4xQVRWhorEESHgplytRGll80F1VTOXO2
m3RG58OfvBXFsXnwuz/kypuu48a7b8NEwnAk6mZMQq+u5PDBE0zNZHjveCtDdpSAiBDxhzj43jvsP/A2N3zkRu767D1MXTiFyoZSbCVL/0g77edP0tnZQjKT
JeE4xMJFxCLFaP4Qqj+Ezx9CkxQ6JQl7wlTSCYtMQseyHZJHTtCYytIejhGdN4tcNo8/FEIoGts2HUbKh/GpGm2nT1A/uZqm2VN4Z9Mustk8CBfTyLNiQSmL
5tby4tutXDS3kqG4zcm2FK5pMbUmTDwDPcMZmuv9nDw3TMCnYeUMGqtCTK6LsffEKB2DeVraUvT0pjnZlmL38TEQ3gALriCdc/CHIlxz/Vq+8KUPsPyiud4G
9txQ2bntEP/43d+wY/tBbrplPfd/6YNMnOQVKlxcTN3klz9/iqcf30R7Ww/rNywjGgsXrIwEruO25vP5r2cymSdLS8utnNeVdz2Du//89Z+aAr1/FQa53WAw
KEYHRq3W/tbna8prMsFA8B8URZkzPjSzbPksUskU8xfO9L5m3MvacaisKuMTn7mV5om1PPjTJ/n6V3/CHR+8itvuuJLKqlJcXBoaa/nM/XeyZPkctr69lwlN
dbz0m8eprKhh0erVdHQO4rhg6iau7VA3YwrtF1/E4SeeI2pncFJZ1CLBS68+QjY/zGf//n6mzp/Jnh17iMbCLL9yJZfHrkLPG+QyWfLZPD3nu9j50ts8+d4h
SvNQo0WJ+QIEFZWScAzZyhPzF0NaZnB4DKHaZJwAI2mXXO8Iw/0jRIrCKKpCW2svYwM5amJlWIZFSk8SKYuRTKTJ5fOeBNzQWTKziCVza3n8tfN0D+SIp23q
qoLIkqA4FqR90OW57YPohsGlKypYs6CYvmGZF7b1UhrTCPlkjpxLoKo+TNtk9+k0rguqooAryOU9j4BFS+dw973XsmTpbIJBvzcwL0nEx5I89+wWfvvr5/H5
NP7m6x/l8qtWEgwFsB37wsyuosrMmTeFfXuOs2jJTA9XX0hsbMs+ref1v+4Z7nn1U/d9ynpt02sEAtp/as7/XxYA4yuTybiAmDFphn382PFNtXW1I6FQ6B8V
RVnh92vyJz93O3fdfTUlZUWezeX7UTCuiz/g57obL2XipAn86sGn+M2v/sSh/af5xGduY+GiGUiahKqprFi5gCVLZ5PPZDl3uIUJ0+eQy4DQdU+Lo1ukx/LE
+zNIchUD4SKCqTHOnNrP9l2vMHH+BL711z9CUn385iePsW/bPhRVIhjyE474iZVEqKipoLahjqmzpvGpf/oyvW1d7Nmyk45T5+kZioNlkxsbZHhglCnHDzB7
3gqKKioxnDzJYJQhE+L9o5ze3UZNUx3BqMpA3yia5Ef1KYwODpOzU8xYOIOO7n5S6TSObbF8VjErlzTy5Jtd9IzYIGl0jJqUVwRQJYeG6iiDKQlbhJBUH1t2
jnHj2iqOnRugc8Cgc0DHxcGnKshIyLJCUPKsqdJ5G9MSNE+cwO13XM7GK1dSWhpjHInvOA5Hj5zhd79+kV07jrD0oll89JM3M3vOZI8u4doXZAzjwrjrb1rP
ilULiUbDhKNBcHFs296TTqe/OjY4tnPq1KnOVddehab9v938/yUB8P45glmzZzk/+clP9t1+++0fj0ajf6eq6vXBoM8fCgf+h8KXuFBJL3wIrsOsOZP41j98
luf+uJkn//AaX/3ij7np1vVcd9M66uo8+aymqRg5CceFdNxg4HwK09Qx8ha5lI6ZtQgoQSqi1bSEwxzqPUduxObm++7g6tuup+v8AM89+iI97YNUlk5Ekrzq
SXYszfnzpzGtgwhJIhSLMGvhXJatWMaaW66mvLzYkxk5DgPdA+x9Zzc739nBS8/9mtLyWhomTUWXBLLfT9CG3FCOMSnNCBajiTiK5OXf51uPM6GpjurGep5/
eSvZbIr1SytZMLOGp7f00Dloo/p86IZN97DNukVRSiNQWxVhx4kcshZEwWH/OYMjrZ0YpoUkaQhh42J7BA7JQ9AYpkPecKmsrWbj5Rdx7XVraJ5YB7jYrufQ
0t83zCsvbePpJ97ENC0+8okbuOnW9RSXxMY9uRh/ZP/Zk8hF0xTq6isK9q+uYRjGq+l0+pupVOp489RmF3Dvv//+v3iT679lAIwHAXjNsilTplBRUXE6mUx+
AehSNfXjrutExwfqx/0uW89189wf32TqtGY2XnkxsixRWuqZIs9bMJ0/PPIKv3v4FXbvOsbtH9jIJWuXEAz68QX8TF4wld1vH2TK1AWoWgTLkAiIEGG/zWB/
F+8e2E7r0FkWXLGKD3z6XiY0N7PlxV1sfWUf+ayBTw0AjseedwRZI4UrbFTNhyMcUqkM297Zw873TlBcUkJdfS3FxSUEAj5mzWpmzc1XsO6mjXSf62D327vZ
u207fR2ddKTzBNQQE80cZbEIlgWSLWFZec6dOkJH20k+97376ekb5vD+A1y3uoqGulKe3NzDYEKgaCqukJB9PrqHbMpiftYtKEJWfJwfyqH4gh7xWZIxLQVJ
NT30oSshXA9JaeQdLEtQVVPFpZct4eprV9PcXIfqU3Ecr6llZPPs2LaHx37/MkcPn2PBohnc95HrWLJs9oUqj207bN60i+NHz3L9zZdeuAcIITz2keMiEGnd
0H87OjL6T3V1dd3l5eXi/fvhv2Qv/pf9ZOCZZ55heHhYzJkzh0i56lYVTwgHg8G7fVrgS5IsNQoK5sq2zc9+9Di/+OkzTGio5OE/fIfGpuoLFykhIJXKXoCp
9nQPsmr1Am69cyPzF06nvaWV737hmwx3JJg8aQ4Bf5D42Aj9A51Yao7JsyZz1e3XMnPBXLrbBnn9qe2cPd7hvUHSnw2Ybccinu4jkR28APU1HRMXCSH7cNUA
Sy9aSk/3GAMDca/EK8uUlUaYNbuJZRfNZsKESnyawvnT59i7dQ/nDp1mrHcM4SgEQhFCsSiJ+AjDY73c+vHbWX/zlTz7yO8IZFqxJR/PvjtC1lBRVRVHkhGq
H1fWKC5S+Pq91dTIGR583WHHGRvh2Li2iWPp2JZR4H5amHoePZdDVWQam2u5dP0yNl5xMQ3NNaiKcuE0N02L48fO8dTjr/PmGzspLSviltsu48ZbNlBSEisw
Q70yaE/3AB+++5u0nGrnI5+4gS9++W5kRfbeJ8C2nR7d0H+Yy+d+U15annrfNvh/nvb8twkA4MIpoWk+0XbuPAkjoVaVVq0JBUNfUVRlleu4suu6vPCnt/jR
Dx6leWId//Sjv6KisgQY7yz++Xu1nuvkuT++zSsvbUOWBRuvuIgbb1mP4ji8/cImTh87ST6vEy6KMH3uTBZctIiJ0ydz5GgLf3pqM+eP9uB3NfyaWqDO2Ti4
mHaeRGaATH6sQAiUcIWXHrhCICQfki/CZVeup/X8IB3tAwUftXH8eBYhDMorosyZN4U5c6cyeUojxUVR+jt6aT11lnOnz9HX303AH2T9NRtZtmIuHYe3cWzX
Dg6eTbP9aBIbDUku4AnVIGgB75+FYH6zSm2RzLbTAt2WcC0L17ZxLBNLz5JNjaFn0wT9CrNmT2LdpUtZfclCJjTWFowEHSQh4TgOba3dvPrKNl587h1SKQ9H
eNOtlzFtRqP35xo3pC5sobHRBH/z5Z9y4lgrn/zsLdx820aPoiiEY1n27lwu972RkZHNzc3N+vhHD/+1p/+fX/1/g1W4Fogzp88wZdoUN5FITNZ82ldUVb1N
ElIom81x9kwn0WiIhqZaj3hSqDSM55vjT4R8XufI4Rae+MOrbHtnP7X1Fdz1watZe+lS/B5QCZ/fh68wpWTbNseOtvDKS9vYt/skg70jKMiEVRWfInAxSOuj
GFaO8RuJ56b45+4msgZqFEmNoqoBhCiU8VzQVBnHypJJj2EaOq5r4/eplFXEmDypljuvWcSkqc24gVIQCkKSkM1hzu/bzuYth9h2LEXfqGckghA4kgT+MEIL
4QoJt6C89P78EpqqeW6OhomRTaOnkmBlqSwPsWjJTNasW8Ls2ZMpKy8et9dCkgSW5dDbM8BrL2/n9Vd30tc3wpKlM7jtrsuZv2A6oZAf23H4854V7/s7dHUO
EB9LMnHSBELhALbj5EzTeNYwjH8oihWdfp+S87/01H//+u/xKgrrmWeeIZvNisWLFzN9xnS3u7u7qChWdKvf7/+MJIsZkpCFW7DGHH//BIJcNs/Q0CilZUUE
gz4uiLUyWXbvPMLTT7zO0cMtVFaXsfGKlay5dAkTJ9ZfQG5T4BiZhsXIcJx9e4+zY/tBjhw6zWDfEEY+gyI5+DWpwOUZH+8s0LElBWQ/Qo0glDCSrCJRYLa7
IHCwjTSWkQaswo9zcGwb0zSYXudn7cIqqqtKCESiDI3lOXKyhyNn4gylVYSsemRsScJVfeAPgy8wzoS/wF+yLcszusjmsPM5FEwqSiNMnzaBZRfNZumy2VRU
lhbydqfgLydh6Cat57p4a/NuXn91J6MjCWbPmcyNt1zKxSvmE4mEcIUnPdHzBsNDY5SWFREolEXHnwTj/RzXdbBs50w+l/9FMpV4rLamduQb3/iGKDS2/tts
fvhvFgAA7zslBCC+9KUv8bWv/c3SYDD0JUVRLhNChC6c+cKbL37q8dd47tm3WLdhKR/66I34/VrBidRLkZLxDLt2HOTlF9/l4L4WYrEIK1fPZ82lS5g7f6r3
AeP59grJ27SGYdLR0cfxY2c4eriFE8fO0d3VTyadQTgWquKiKiCrMrLiQ8h+hBLAlXwI5MITQHj6JsfGMlM4VgaBU6iRuBdAT7bjosgSIZ+M60DWEFiOiiwr
HiFNVkD1gT+EFAgjVM2TWNsmpq5j5LLo6RS2niWoCurrypkzdzLz5k9j5qyJTJhQfSHYxx3XBYJMJsuxo2d5a/Nu3t6yh2QizbLlc7niqlUsu3guJSWx/+Ez
sUyLxx59hZeef5trrl/D7R+4Ep+mFp6DhYPEIWc7zpZsNvuDZ956a9d1N9zgVDiOiyS53/zmN/9d2ML/F+u/XQCMr/GUCOAnP/k5N998Q0UsGrvV59M+K8ly
s+tl3gwPj/FX9/8zb2/Zy/xF0/jVw9+gqrLkQhV1/I4hCa95c+RwC6+8uI3du47huC5z5k7ikrWLuGjFPO909GkXTnfv6wT5wqnX2zvEyROtHDt6lnNnOhgY
GCGXyeIiUFStQD/WkBUfkqR6B7QLwrGxrTSuk0fCvvD9oYBFFwIXgeNICBQkWUVI3pihK2ug+RCaD0dIOKaJpecxc1lsI4smuZSWhGlurmPW7EnMmTuZCQ01
VFSWEgj4C7KJP5/ShmEyMhznvZ2H2bJ5Nwf2n8SxbZYun8O1169l4eKZlJTEvNfnXniIIYCRkQSf/tjfs2v7YVasnscPf/ZlyiuKL2wjx3Hadd34RSKTfuLA
3oO9kasuZwCQwb3lv9Gp//713/NVFdb7gwBgsG9Q0fzaXH/A/2lVVa8WghLLsnnlpa08/+wW1l66lDs+cCWKKgPSBYEdjAM3vDxZ13XOnG7nzTfeY+f2w3R1
9VFUHGbp8jlcsnYx06c3F4JB9UYoCy/CqwR5Yr1MJkdnZx/nznTSeq6Lrs5eenuHiI+myOUsDMvGtrxau5eQOUhYBXTk+zyW33eRdFxwXdmzSaKg6ZckZEWg
qTKhoJ/iojBVVaXU1pXT2FhN88Q66huqiUYj+Pwaiix7sxXCk5dLQsI0bUaGx2g918W2dw+yc8dheroHKCsvYvmKuVx51UpmzprsdXoLgSn9f+1de2xc1Zn/
nfuYufPwjB3b4/gxjk0ch7zIizTpQhIBSYA8CBFLSlnaUopUaZFoq0h0VWVRu12xkO2WqFTpFqWoauuiRZRqkxJCAs5CcBoS52k7L9vxc2yPHXvec+fOvfd8
+8e9d+xY7G5baZsE+ElXmtHcO/fcc8/5Xuc7388iDJjsNxBM3cSbbxzCwQPH8ODmu7DtkXVWXxPiup5/J5vNvmKa/FR5ebk+9TXeTCbPdNy8LbMxzSQCAOrq
6QqEysofcruUb0iSuBqAmE6r8PoUiHamodPpF9qvYmT4GpbfOQ/FJYEpko3BNE1EBqM4eaIdR94/gTOnLyKTVlFXV40VKxdi+Yr5mL+gAZVV5YX8F6JJreK0
jzFA0/KYmEhibHQCE+NJJOIpxOJJxGNJpJIZpNM5qGquwK3MbTIIAHY9HRGSZK1iexQ3/H4PAkEfSkoCKCn2I1gSQGlZMUKhUpSUBuF2y1O4yq04PLOLjwFW
0d/oyDiuXO5F2/kunPy4A92dg5BdEhYtbsCatcuw7M75qKuvhigL1uwDAMaQTGZw6kQHZlaWYf6C2YWeZwA4J2TSKnx+DwRBMHVdP67ltddGrw291VB/e2Kq
owvc+CjP/4Wbu3XTMFUj1NTU4ezZ1npFUb6sKO6viKI0h5PpsKhBYAJ6eyL43nM/RdeVATzzrUfxla8/5LAq2claDtk4QzKRRl/vED4+3oYPmk+g83I/OAeq
qkOYt+A2LF7SiDuWzEF1zUx4PG7ILhmCYDOoELeqH8OhbGIFk4NzDl03oOsGDN2AYVqawWY2gWNnCLa0l0S7hIt9ONxpzsSdzKtH4Tmde+RyGiKDozh35hLO
nrmEjvZuRAajEEUJjY2zsOae5Vi5ahHq6q1MWgDgxO1+cNrD8Jtf/QE/+XETGufOwgu7voVZ9VWF+1qaUOCmaV7Vdb0pl8s1vd70evcz//xPtLetDd8oL7+p
Jf503JCV4L8UjDEcOXKEOOds3763UFZWdvXShUsvhapC+xSX8qTL7domMMwCIBAI2ayGWCyBTCaLdCqL68NHzGYHYTBhwh/wYNHiRixY2IAvPfYAeq5GcLq1
A2dOX8bZ05fRfPgkZJeIyuoyzGmsxYKFDWhsnIXyUAmCQT98fi/cbpetJWjKAGeQZRGyLIJgbeRxVrc/Wf5MmkeAlU5BdnRlqh2fTmeRSmYwMZ5Ab88QOtq7
cfHCVfT1DiGTziIQ9KGhsRYPPHgXVqxciMa5dSgKWOXkp+4rF5hQmFycEcAtjq5UMoOxsQlkMlmnsBMYY8SJ+vV8br+W014bSg61L5i1wPjuc9/Ff776KraG
Qnj6Rg+SP3dM3egG/CWYbhbltByOfviRdOeK5asURfmSLMlbBEEIG7rJjrWcwUD/MO65byVqwhUF7gJOHB1t3ZgYj2PZivnw+72FynWO0+yE/Qb6h9HVNYiL
F66io70T3V0DSMRTEEURM0qDCNdWIlxbiZqaEEIVM1BcXITi4iIEg0XwF3mheNxwu2WIkjglx4kKpb6vexF25mte05HN5pBOZZCIpxGPpxCPp3BtLIbBwSgG
+kYxPDSGWCwJQzdRFPAhXDsT8+bX4fb59bhtdg1m1VXB5/fY080KHwuMgTEBqqqh7dwVFBV5MXdefSFlAQwYGhzDgf0fIlxbgXvXrYLLJRPnfEjX9bdzudx/
dHd3tyxctDDf5G6C23TjCfGJmzLC86fglpwAU2GH9tiOHTuwa9cuGhsbK1IUZbGiKI+5XK7NkiTVACRaApkKA7CnexA7nv1XRCKj2PEPX8Pfbt9g05IJkwIa
k6udzCrMing8hYnxOCKDo+i80o/urn4MDoxidDSOVDIDXdfBQHArMvx+HwJBPwJBP4oCPvh9Xni8Ctxu27yxE9GIc2uHWd5ATs0jnckimcwgEU8hkUghlcxY
VSlsMo9A0I+KijLU1VdjTmMYsxvCqK4OoWRGAMXFRZDt/Bwi7pQVnMyrsv2fg29/hJde+CXKy4vx0o+/bZFTF2q3MjAIYIyZnJvD+bz2Tl7XfqtmtdMAkjNn
ziz4Y7eSufNJuKVMoE+Ck13a1tbGDMNgVVVV6fPnz7dwzk9VV1e/5vf7trtcrk0Am80E5nEEcDKZwehYDMlkBhPjyQIxnDPgdd2SwIGgH2BW/BwCQ8mMAEpL
g5jTWIfVa++EYVj2fSqZwcjwNQwOjGBoaAxjoxOITSQtcyKdxdhoHFpOQ143YOj6JMOlzX0rCIAky3C53VAUN7xeN/xFPlRVh1Bc7EdpWRAVM0tRXVOBquoQ
SkoCcLlkyLIEURQLc7YQ6wesDS1JFYrXDZcsFRbuiBOi0XFcG4uDc450Omt3JpxIWY7Ar+Y07R01q74RjY60nzvXqnZ29uH555//1Ax++5E/HZhqFkUiEbS1
tbF169ZRf1+fEAgG53k8ng2yLG8QRXElYyyoaXl26OAxGouOswc2rUZVdbl1MWPIqXn8/nfvo+XoWTz65fVYvXb5NJ7awkC53ul1tIzds9zk0LQ8cqqGXC6P
XE6DpunQ8zoM07QrO9vhSpFBlmUoihsejxuKx5oIiuKCKIq2T2G3oRCN4o5TWghXOpEqAPhjy1k0/fptfPFvFuOR7evhVmT7GQWMDF/Dgf1HUVZWTPdvvJu5
3TKIKGkYRqtuGO9qqvrulc7O9hUrVvDDhw+zRYsWkd/vQ3FxyS0R3fkcADty5AjTNI0REZqamsRoNFodi8e3ZLLZn2t5rcs0TdU0TTJNkwzDINM0iXNOvT0R
enjjtykcup+e/fsXKJfTyDANMk3rHC2fp6HIKE1MJMi53jomzykc3D6mfeackwPO+eRv087lfLJ9uqGTbuhkGLr13TQoNpGggf4RyuVyZBh64f66rtNz3/k3
qg1toC33P0M9VwfJMA0yjDzphj61jTk9r/eoqvqLRCKxbSQaDe9rbpYOtbSAiNiU40a/z/8X/HU2Xt4gbNq0CS0tLUxVVbZp0yby+/2pj062Xinyed/Pa9p+
InQSSGeMyQJjXgiCxGAV8Y2OXKNkMs02br4bdyxuLEg8Bob3Dh3Hzudewflzl7Fk6VwUBXzWDW3nOatqiMdS8HiVQsrw1IQ9IkLP1QjefecYzp6+DJdbRnFJ
kZ1NQwX3mDGLcHB83EqtdrtchbAtE4DRkQn8yw/34tU9b2JGWRCNc2fZzbB8lmQijeHhcdy9dhmtWbuMud2yo7E0TnzAMIyP1Jz675l05od5Pf96JBLpuK2+
Pjm3vp5mh8PXmTq3ooP7OWzY6QAFacY5Z7t27WJExPr6+vyxWGxVNpt9NpfL/Tafz180TVNLJNK8u3uAVEuycsMwuGGaZJqcXnrhNaqv2kgrlzxGp1s7iIgs
ycsNiseTtPtHv6KvPvY9eu/QH6/TBoZpSej2tk7avm0HzZv9MM2r30ZbH3yWTrV2kMntc7huaxyTmt/7mJ58fCe9sruJkok0cc7JME0iIjp35hKtWvo41YTW
0fd37iloCdM0OOcmz2t56u2NUDKZ5qZp5vP5/GVVVd/IZDLfGR8fv6uzs7OIiJhu6GyatP/USvzpuOWd4D8FTn0i5zsRobS0lKmqitra2szhw4ePq6p6YunS
pb8OBAJhAAtlWV5VVV32BVEUGhgTvAAU+2ps2boGE+NxhMMVqLvNKgfoSPjoyDj+sO9DdF4eQE04hHvu/YK9qcZaReWc4+CBFpw5dQVerxcMDBc7enFg/4eY
v2A2JFm0NYFVIOzdg8fQ/N5JjI5OYOOm1SgKeGGF6zlq6yrxxJOb0XWlH1seXmsl/zlbEgkaE5haWVnWxTmdzGSzx8H5+XgiMdjefiFWUlLMV61ayQBAEiXg
U+LU/rn4TEyA6XAmxFNPPQUAbP369U4QJc4Yi508ebK9oqLi95zI6/f7Zrtd7mWiJC4RBXGeKIozG+fWlf7jD74ZlCRJcrkkm/rJiq7MrCzDtkfvRevHHbhv
w0rAHvyOc8xNjkQ8VTBTGGMQRBHptGpFmkgEscl0jXvuW4GBvmGs/OIdKAuVTFmRZQgGi/D0Nx+BrhumorgSIDZummbU5OZFbvKzmqaeSaXSnYLoygyNRbW2
ixf5048/zsLhsPUXFj6TA9/BZ/fJp+AT8o2cz9Tc3IxgMMi8Xi/cbveMQDA4y+Vy1QOokySpXhLFagBVjLEKxliJIAhewzAFLafB5/dOrZjNHE/gwP6j+MHO
n0FV82CCAK9Xwc7vP43ND62Bw6HmrEoRAclkCl6PAtklc865SkQxIhoFMGSYRsQwzB6A9xq62ZNKpfpaW1uvbd26FQBIkiScP3eO/dcHH+Dc+fP0i717gVsk
T+evgc974H8AEWHZsmWsqakJkiSxl19+mZYuXYrdu3dj/u2305tvvcWajza7G+oain0+3wxJlAImN0KiIIUFQagGQ5UoiJWMsTKASgRBDBDIIwqiks3m2Ou/
OcB+98ZhEBEe2b4ef/fVzeT1KmQYhsYYZTmnFIAYEV3jHCMARQxDHzIMY1AQxSgDS2QymVh3X39sx8/35hZVlNMvf7SLvfjii+jp6cGePXsYm0w7/UxL+f8N
/w1el1RXgrtVwwAAAABJRU5ErkJggg==
__E__
W usr/share/tone-os/developer.txt <<'__E__'
開発者：valtanman　連絡先：toneappbildman@appmail.uk　ToneInternetService. 《PC-OpenCafe.　IoT&Digital Software Development Department.》
__E__
for z in 48 64 128 192; do
  mkdir -p "$SRC/overlay/usr/share/icons/hicolor/${z}x${z}/apps"
  convert "$SRC/overlay/usr/share/tone-os/developer-icon.png" -resize ${z}x${z} "$SRC/overlay/usr/share/icons/hicolor/${z}x${z}/apps/tone-os-developer.png"
done
convert "$SRC/overlay/usr/share/tone-os/developer-icon.png" -resize 94x94 "$SRC/overlay/usr/share/tone-os/developer-icon-94.png"   # 2.5cm(96dpi)
mkdir -p "$SRC/overlay/etc/calamares/branding/tone"
cp -f "$SRC/overlay/usr/share/tone-os/developer-icon.png" "$SRC/overlay/etc/calamares/branding/tone/dev-icon.png"
W usr/local/bin/tone-about 755 <<'__E__'
#!/usr/bin/env python3
# TONE OS について ─ 開発者パネル(丸いアイコンは約2.5cm)
import os, sys, subprocess
ICON = os.environ.get("TONE_ABOUT_ICON", "/usr/share/tone-os/developer-icon.png")
LINES = ["開発者：valtanman", "連絡先：toneappbildman@appmail.uk",
         "ToneInternetService. 《PC-OpenCafe.　IoT&Digital Software Development Department.》"]
try: LINES.insert(0, "TONE OS 版 " + open("/usr/share/tone-os/version").read().strip())
except OSError: pass


def main(argv):
    once = "--once" in argv
    if once:        # 初回ログインの1回だけ、静かにご紹介する(インストーラーのライブ環境では出さない)
        marker = os.path.join(os.path.expanduser("~"), ".config", "tone-os", "about-shown")
        try:
            if os.path.exists(marker) or "boot=casper" in open("/proc/cmdline").read(): return 0
        except OSError: pass
        import time; time.sleep(int(os.environ.get("TONE_ABOUT_DELAY", "25")))
        os.makedirs(os.path.dirname(marker), exist_ok=True); open(marker, "w").close()
    from PyQt5.QtWidgets import QApplication, QDialog, QVBoxLayout, QHBoxLayout, QLabel, QPushButton
    from PyQt5.QtGui import QPixmap
    from PyQt5.QtCore import Qt
    app = QApplication(sys.argv); w = QDialog(); w.setWindowTitle("TONE OS について ─ 開発者パネル"); w.resize(560, 300)
    root = QHBoxLayout(w); icon = QLabel(); pm = QPixmap(ICON).scaled(94, 94, Qt.KeepAspectRatio, Qt.SmoothTransformation)   # 約2.5cm
    icon.setPixmap(pm); icon.setFixedSize(100, 100); icon.setAlignment(Qt.AlignTop)
    col = QVBoxLayout(); head = QLabel("<h2>TONE OS</h2>"); sub = QLabel("Ubuntu 24.04 ベース ・ KDE Plasma ・ 日本語専用 ・ amd64")
    txt = QLabel("<br>".join(LINES)); txt.setWordWrap(True); txt.setTextInteractionFlags(Qt.TextSelectableByMouse)
    btns = QHBoxLayout(); mail = QPushButton("メールを書く"); close = QPushButton("閉じる"); btns.addStretch(1); btns.addWidget(mail); btns.addWidget(close)
    for x in (head, sub, txt): col.addWidget(x)
    col.addStretch(1); col.addLayout(btns); root.addWidget(icon); root.addLayout(col, 1)
    mail.clicked.connect(lambda: subprocess.Popen(["xdg-open", "mailto:toneappbildman@appmail.uk"])); close.clicked.connect(w.accept)
    w.show(); return app.exec_()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
__E__
W usr/share/applications/tone-about.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS について(開発者パネル)
Icon=tone-os-developer
Exec=/usr/local/bin/tone-about
Categories=System;Settings;
__E__
W etc/xdg/autostart/tone-about-once.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS 開発者パネル(初回のみ)
Exec=/usr/local/bin/tone-about --once
NoDisplay=true
__E__
W etc/xdg/kcm-about-distrorc <<'__E__'
[General]
Name=TONE OS
Logo=/usr/share/tone-os/developer-icon.png
Website=mailto:toneappbildman@appmail.uk
Variant=開発者: valtanman / ToneInternetService.
__E__
W usr/local/bin/tone-brand 755 <<'__E__'
#!/bin/bash
# OSの名前と開発者表記を、OS情報に反映する(パッケージ更新で元に戻っても、更新の度にやり直す)
f=${TONE_OSRELEASE:-/usr/lib/os-release}
[ -f "$f" ] || exit 0
v=$(cat /usr/share/tone-os/version 2>/dev/null || echo 1.0.0)
sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"TONE OS $v (Ubuntu 24.04 ベース)\"/" "$f"
grep -q '^VENDOR_NAME=' "$f" || printf 'VENDOR_NAME="ToneInternetService."\nVENDOR_URL="mailto:toneappbildman@appmail.uk"\n' >> "$f"
if [ -z "$TONE_OSRELEASE" ]; then
  printf 'TONE OS %s \\n \\l\n' "$v" > /etc/issue; printf 'TONE OS %s\n' "$v" > /etc/issue.net
fi
exit 0
__E__
W etc/update-motd.d/90-tone-developer 755 <<'__E__'
#!/bin/sh
echo
cat /usr/share/tone-os/developer.txt 2>/dev/null
echo
__E__
# ===================================================================
# --- 起動音・終了音 ---------------------------------------------------
mkdir -p "$SRC/overlay/usr/share/tone-os/sounds"
SD=$SRC/overlay/usr/share/tone-os/sounds
sox -n "$SD/startup.wav" synth 0.35 sine 523 : synth 0.35 sine 659 : synth 0.35 sine 784 : synth 0.8 sine 1047 fade h 0.01 1.9 0.5 gain -6 2>/dev/null || true
sox -n "$SD/logoff.wav"  synth 0.35 sine 784 : synth 0.35 sine 659 : synth 0.8 sine 523 fade h 0.01 1.5 0.5 gain -6 2>/dev/null || true
for k in startup logoff; do
  for f in "$IMP"/sounds/$k.*; do [ -f "$f" ] && { rm -f "$SD/$k".*; cp -f "$f" "$SD/"; log "$k 音を取り込みました: $(basename "$f")"; }; done
done
chmod 644 "$SD"/* 2>/dev/null || true
W usr/local/bin/tone-play-sound 755 <<'__E__'
#!/bin/bash
# 使い方: tone-play-sound startup|logoff  (wav/mp3/ogg)
k=$1
for d in "$HOME/.config/tone-os/sounds" /usr/share/tone-os/sounds; do
  for f in "$d/$k".wav "$d/$k".mp3 "$d/$k".ogg "$d/$k".WAV "$d/$k".MP3 "$d/$k".OGG; do
    [ -f "$f" ] && exec mpv --no-video --really-quiet --no-terminal "$f"
  done
done
__E__
W etc/xdg/autostart/tone-startup-sound.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS 起動音
Exec=/usr/local/bin/tone-play-sound startup
NoDisplay=true
__E__
W etc/skel/.config/plasma-workspace/shutdown/tone-logoff.sh 755 <<'__E__'
#!/bin/bash
/usr/local/bin/tone-play-sound logoff
__E__
W usr/local/bin/tone-sound-settings 755 <<'__E__'
#!/bin/bash
# 起動音/終了音の変更(wav/mp3/ogg)
D="$HOME/.config/tone-os/sounds"; mkdir -p "$D"
c=$(zenity --list --title="音の設定 - TONE OS" --text="変更する音を選んでください" --column=項目 "起動音" "終了音(ログオフ)" "標準に戻す") || exit 0
case "$c" in
 起動音) k=startup;; 終了音*) k=logoff;;
 *) rm -f "$D"/*; zenity --info --text="標準の音に戻しました。"; exit 0;;
esac
f=$(zenity --file-selection --title="音声ファイルを選択" --file-filter="音声 | *.wav *.mp3 *.ogg *.WAV *.MP3 *.OGG") || exit 0
rm -f "$D/$k".*; cp -f "$f" "$D/$k.${f##*.}"
tone-play-sound "$k" & zenity --info --text="設定しました。今鳴っているのが新しい音です。"
__E__
W usr/share/applications/tone-sound-settings.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=起動音・終了音の設定
Icon=audio-volume-high
Exec=/usr/local/bin/tone-sound-settings
Categories=Settings;
__E__

find "$SRC/overlay" -type d -exec chmod 755 {} +

# --- インストーラー(Calamares) 日本語化 ---------------------------------
W etc/casper.conf <<'__E__'
export USERNAME="tone"
export USERFULLNAME="TONE OS Live"
export HOST="tone-os"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="TONE OS"
__E__
W etc/sddm.conf.d/live.conf <<'__E__'
[Autologin]
User=tone
Session=plasma.desktop
Relogin=false
__E__
W usr/local/bin/tone-installer-launch 755 <<'__E__'
#!/bin/bash
grep -q boot=casper /proc/cmdline || exit 0
sleep 4; export LANG=ja_JP.UTF-8
setsid /usr/local/bin/tone-install-watch >/dev/null 2>&1 &
# 「全部消してインストール」のおすすめ → 大切なデータの保存(コピーのみ)。保存に失敗したときは、先へ進まない
sudo -E /usr/local/bin/tone-install-guide || exit 0
sudo -E calamares -d >/tmp/calamares-debug.log 2>&1
# インストールが成功していたら、USBの取り外しを案内して再起動する
if grep -aq 'completion: succeeded' /tmp/calamares-debug.log; then
  if zenity --question --width=540 --title="インストール完了" --ok-label="再起動する" --cancel-label="あとで再起動する" \
    --text="<big><b>インストールが完了しました!</b></big>\n\nこのあとPCを再起動します。\n\n<b>【USBメモリについて】</b>\n再起動が始まり、画面が消えたら、<b>USBメモリを安全に取り外していいですよ。</b>\n(USBを挿したままだと、もう一度USBから起動してしまうことがあります)" 2>/dev/null; then
    sleep 1; sudo -n systemctl reboot
  else
    zenity --info --width=420 --title="インストール完了" --text="インストールは完了しています。\nUSBメモリは、PCを終了または再起動したあとに、安全に取り外していいですよ。" 2>/dev/null
  fi
fi
__E__
W usr/local/bin/tone-install-watch 755 <<'__E__'
#!/bin/bash
# インストーラーの失敗を検出したら、原因調査用の診断情報を自動で画面に表示する
L=/tmp/calamares-debug.log; R=/tmp/tone-install-report.txt; last=0
PAT='Installation failed|ERROR|rsync.*(error|failed)|exit code [1-9]|Bad configuration|Failed to unpack'
while sleep 3; do
  [ -f "$L" ] || continue
  cnt=$(grep -aEc "$PAT" "$L")
  [ "$cnt" -gt "$last" ] || continue
  last=$cnt; sleep 4
  {
    echo "=== エラー行 ==="; grep -aE "$PAT" "$L" | tail -n 20
    echo; echo "=== パーティション工程のログ ==="; grep -aiE 'partition|mkfs|mount|format|create|swap' "$L" | grep -av 'Skipping' | head -n 40
    echo; echo "=== ディスク容量(使用中のもの) ==="; df -h 2>/dev/null | grep -vE 'tmpfs|udev|loop|squashfs'
    echo; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
    echo; echo "=== カーネルのエラー(ディスク異常・容量・メモリ不足) ==="
    sudo -n dmesg 2>/dev/null | grep -iE 'I/O error|blk_update|medium error|ext4.*error|squashfs|out of memory|oom|nvme.*(error|timeout)|ata[0-9].*(error|failed)' | tail -n 30
    echo; free -h
    echo; [ -d /sys/firmware/efi ] && echo "起動方式: UEFI" || echo "起動方式: BIOS"
    echo; echo "=== ログ末尾 ==="; tail -n 40 "$L"
  } > "$R" 2>&1
  zenity --text-info --title="インストール失敗の診断情報(この画面を撮影して送ってください)" --filename="$R" --width=1000 --height=720 2>/dev/null
done
__E__
W usr/local/bin/tone-save-log 755 <<'__E__'
#!/bin/bash
# インストール失敗時のログをUSBメモリ等へ保存する
T=$(mktemp -d); N=tone-install-log-$(date +%Y%m%d-%H%M%S)
mkdir -p "$T/$N"
cp -f "$HOME/.cache/calamares/session.log" "$T/$N/" 2>/dev/null
cp -f /root/.cache/calamares/session.log "$T/$N/session-root.log" 2>/dev/null
sudo -n cp -f /root/.cache/calamares/session.log "$T/$N/session-root.log" 2>/dev/null
cp -f /tmp/calamares-debug.log /tmp/tone-install-report.txt "$T/$N/" 2>/dev/null
{ lsblk -f; echo; sudo -n parted -l; echo; sudo -n efibootmgr -v; echo; [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS; free -h; } > "$T/$N/system.txt" 2>&1
sudo -n journalctl -b --no-pager > "$T/$N/journal.txt" 2>&1; sudo -n dmesg > "$T/$N/dmesg.txt" 2>&1
( cd "$T" && tar czf "$N.tar.gz" "$N" )
D=$(zenity --file-selection --directory --title="ログの保存先(USBメモリ等)を選んでください" --filename=/media/) || D="$HOME"
cp -f "$T/$N.tar.gz" "$D/" && sync && zenity --info --text="保存しました:\n$D/$N.tar.gz" || zenity --error --text="保存に失敗しました。"
__E__
W etc/skel/デスクトップ/インストールログを保存.desktop 755 <<'__E__'
[Desktop Entry]
Type=Application
Name=インストールログを保存
Icon=document-save
Exec=/usr/local/bin/tone-save-log
Terminal=false
__E__
W etc/xdg/autostart/tone-installer.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS インストーラー
Exec=/usr/local/bin/tone-installer-launch
NoDisplay=true
__E__
W usr/share/applications/tone-install.desktop <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE OS をインストール
Icon=system-software-install
Exec=sh -c "sudo -E /usr/local/bin/tone-install-guide && sudo -E calamares"
__E__
W etc/calamares/settings.conf <<'__E__'
modules-search: [ local ]
instances:
- id: cleanup
  module: shellprocess
  config: shellprocess-cleanup.conf
- id: checkroot
  module: shellprocess
  config: shellprocess-checkroot.conf
- id: fixkbd
  module: shellprocess
  config: shellprocess-fixkbd.conf
- id: fixgrub
  module: shellprocess
  config: shellprocess-fixgrub.conf
- id: efibak
  module: shellprocess
  config: shellprocess-efibak.conf
sequence:
- show:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - shellprocess@checkroot
  - unpackfs
  - machineid
  - shellprocess@cleanup
  - fstab
  - locale
  - keyboard
  - localecfg
  - shellprocess@fixkbd
  - users
  - displaymanager
  - networkcfg
  - hwclock
  - initramfscfg
  - initramfs
  - grubcfg
  - bootloader
  - shellprocess@fixgrub
  - shellprocess@efibak
  - umount
- show:
  - finished
branding: tone
prompt-install: false
dont-chroot: false
oem-setup: false
disable-cancel: false
__E__
W etc/calamares/modules/welcome.conf <<'__E__'
showSupportUrl: false
showKnownIssuesUrl: false
showReleaseNotesUrl: false
requirements:
  requiredStorage: 16.0
  requiredRam: 2.0
  internetCheckUrl: http://example.com
  check: [ storage, ram, root ]
  required: [ storage, ram, root ]
__E__
W etc/calamares/modules/locale.conf <<'__E__'
region: "Asia"
zone: "Tokyo"
useSystemTimezone: false
localeGenPath: /etc/locale.gen
__E__
W etc/calamares/modules/keyboard.conf <<'__E__'
xOrgConfFileName: "/etc/X11/xorg.conf.d/00-keyboard.conf"
convertedKeymapPath: "/lib/kbd/keymaps/xkb"
writeEtcDefaultKeyboard: true
__E__
W etc/calamares/modules/shellprocess-efibak.conf <<'__E__'
dontChroot: true
timeout: 60
script:
  - "mkdir -p ${ROOT}/var/backups/tone-efi && cp -a /tmp/tone-efi-backup/. ${ROOT}/var/backups/tone-efi/ 2>/dev/null; true"
__E__
W etc/calamares/modules/partition.conf <<'__E__'
# インストール先: 既定は「ディスク全体を消してインストール」。ファイルシステムは Btrfs が標準(@ と @home と @snapshots)。
# Linuxが入っているPCでも、既存のLinuxの上書き(置き換え)を提案せず、まっさらにして入れる。
# (手動のパーティション設定や、Windowsと共存するインストールも、画面から選べる)
efiSystemPartition: "/boot/efi"
efiSystemPartitionSize: 512M
initialPartitioningChoice: erase
allowManualPartitioning: true
alwaysShowPartitionLabels: true
drawNestedPartitions: true
luksGeneration: luks1
userSwapChoices: [ none, small ]
initialSwapChoice: none
defaultFileSystemType: "btrfs"
availableFileSystemTypes: [ "btrfs", "ext4", "xfs" ]
partitionLayout:
  - name: "TONE_ROOT"
    filesystem: "btrfs"
    mountPoint: "/"
    size: 100%
__E__
W etc/calamares/modules/fstab.conf <<'__E__'
mountOptions:
    default: defaults,noatime
    btrfs: defaults,noatime,compress=zstd:1
    ext4: defaults,noatime
efiMountOptions: umask=0077
ssdExtraMountOptions:
    ext4: discard
    btrfs: discard=async
crypttabOptions: luks
__E__
W etc/calamares/modules/mount.conf <<'__E__'
btrfsSubvolumes:
    - mountPoint: /
      subvolume: /@
    - mountPoint: /home
      subvolume: /@home
    - mountPoint: /.snapshots
      subvolume: /@snapshots
mountOptions:
    - filesystem: default
      options: [ defaults, noatime ]
    - filesystem: btrfs
      options: [ defaults, noatime, compress=zstd:1 ]
extraMounts:
    - device: proc
      fs: proc
      mountPoint: /proc
    - device: sys
      fs: sysfs
      mountPoint: /sys
    - device: /dev
      mountPoint: /dev
      options: [ bind ]
    - device: tmpfs
      fs: tmpfs
      mountPoint: /run
    - device: /run/udev
      mountPoint: /run/udev
      options: [ bind ]
extraMountsEfi:
    - device: efivarfs
      fs: efivarfs
      mountPoint: /sys/firmware/efi/efivars
__E__
W etc/calamares/modules/umount.conf <<'__E__'
srcLog: "/root/.cache/calamares/session.log"
destLog: "/var/log/installer/calamares-session.log"
__E__
W etc/calamares/modules/unpackfs.conf <<'__E__'
unpack:
  - source: "/cdrom/casper/filesystem.squashfs"
    sourcefs: "squashfs"
    destination: ""
__E__
W etc/calamares/modules/users.conf <<'__E__'
defaultGroups: [ adm, cdrom, sudo, dip, plugdev, lpadmin, audio, video ]
autologinGroup: autologin
doAutologin: true
sudoersGroup: sudo
setRootPassword: false
doReusePassword: false
passwordRequirements: { minLength: -1, maxLength: -1 }
allowWeakPasswords: true
allowWeakPasswordsDefault: true
userShell: /bin/bash
__E__
W etc/calamares/modules/displaymanager.conf <<'__E__'
displaymanagers: [ sddm ]
defaultDesktopEnvironment: { executable: "startplasma-x11", desktopFile: "plasma" }
basicSetup: false
sddm: { configFile: sddm.conf }
__E__
W etc/calamares/modules/bootloader.conf <<__E__
efiBootLoader: "grub"
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootloaderId: "$TONE_EFI_ID"
installEFIFallback: true
__E__
W etc/calamares/modules/grubcfg.conf <<'__E__'
overwrite: false
kernel_params: [ "quiet", "splash" ]
prefer_grub_d: false
__E__
W etc/calamares/modules/initramfs.conf <<'__E__'
initramfsCommand: "update-initramfs -k all -c"
__E__
W etc/calamares/modules/shellprocess-cleanup.conf <<'__E__'
dontChroot: false
timeout: 60
script:
  - "rm -f /etc/sddm.conf.d/live.conf /etc/casper.conf"
  - "rm -rf /etc/xdg/autostart/tone-installer.desktop"
  - "rm -f /etc/skel/デスクトップ/インストールログを保存.desktop"
__E__
W etc/calamares/modules/shellprocess-checkroot.conf <<'__E__'
dontChroot: true
timeout: 60
script:
  - "/usr/local/bin/tone-check-root"
__E__
W etc/calamares/modules/shellprocess-fixgrub.conf <<__E__
dontChroot: false
timeout: 300
script:
  - "grub-mkconfig -o /boot/grub/grub.cfg"
  - "test -s /boot/grub/grub.cfg"
  - "mkdir -p /boot/efi/EFI/$TONE_EFI_ID"
  - "[ ! -d /boot/efi/EFI/tone ] || cp -a /boot/efi/EFI/tone/. /boot/efi/EFI/$TONE_EFI_ID/"
  - "[ ! -d /boot/efi/EFI/$TONE_EFI_ID ] || { mkdir -p /boot/efi/EFI/BOOT && cp -a /boot/efi/EFI/$TONE_EFI_ID/. /boot/efi/EFI/BOOT/ && cp -f /boot/efi/EFI/$TONE_EFI_ID/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI; }; true"
  - "sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub; grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub; true"
__E__
W etc/calamares/modules/shellprocess-fixkbd.conf <<'__E__'
dontChroot: false
timeout: 60
script:
  - "/usr/local/bin/tone-fixkbd"
__E__
W usr/local/bin/tone-fixkbd 755 <<'__E__'
#!/bin/bash
# 日本語配列(jp)が選ばれた場合のみ、かな配列(kana86)などを避けて標準の日本語106キーボードに揃える。他の配列は触らない。
f=/etc/default/keyboard
[ -f "$f" ] || exit 0
. "$f" 2>/dev/null
if [ "$XKBLAYOUT" = jp ]; then
  sed -i 's/^XKBMODEL=.*/XKBMODEL="jp106"/; s/^XKBVARIANT=.*/XKBVARIANT=""/' "$f"
  rm -f /etc/X11/xorg.conf.d/00-keyboard.conf
fi
exit 0
__E__
W usr/local/bin/tone-check-root 755 <<'__E__'
#!/bin/bash
# インストール先の「/」が実在するディスク領域か確認する。
# ルート領域が作られていないと、ライブ環境のメモリ上に展開してしまい失敗するため、事前に止める。
R=$(ls -d /tmp/calamares-root-* 2>/dev/null | head -1)
[ -n "$R" ] || exit 0
src=$(findmnt -n -o SOURCE -T "$R" 2>/dev/null)
case "$src" in
  /dev/*) exit 0;;
esac
echo "インストール先のルート領域(/)がディスク上に作成・マウントされていません。(source=$src)" >&2
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT >&2
exit 1
__E__
W etc/calamares/modules/finished.conf <<'__E__'
restartNowEnabled: false
restartNowChecked: false
__E__
W etc/calamares/branding/tone/branding.desc <<'__E__'
---
componentName: tone
welcomeStyleCalamares: true
strings:
  productName: TONE OS
  shortProductName: TONE OS
  version: 1.0
  shortVersion: 1.0
  versionedName: TONE OS 1.0
  shortVersionedName: TONE OS 1.0
  bootloaderEntryName: TONE OS
  productUrl: https://www.google.com/
  supportUrl: https://www.google.com/
  knownIssuesUrl: https://www.google.com/
  releaseNotesUrl: https://www.google.com/
images:
  productLogo: "logo.png"
  productIcon: "logo.png"
  productWelcome: "welcome.png"
style:
  sidebarBackground: "#06130d"
  sidebarText: "#FFFFFF"
  sidebarTextSelect: "#0a2a1b"
  sidebarTextHighlight: "#35d08a"
slideshow: "show.qml"
slideshowAPI: 2
__E__
W etc/calamares/branding/tone/show.qml <<'__E__'
import QtQuick 2.0;
import calamares.slideshow 1.0;
Presentation {
    id: presentation
    Timer { interval: 6000; running: presentation.activatedInCalamares; repeat: true; onTriggered: presentation.goToNextSlide() }
    Slide { Rectangle { anchors.fill: parent; color: "#050b08"
        Text { anchors.centerIn: parent; text: "TONE OS をインストールしています…"; color: "#35d08a"; font.pixelSize: 30 } } }
    Slide { Rectangle { anchors.fill: parent; color: "#050b08"
        Column { anchors.centerIn: parent; spacing: 12
            Image { source: "dev-icon.png"; width: 94; height: 94; fillMode: Image.PreserveAspectFit; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "開発者：valtanman"; color: "white"; font.pixelSize: 20; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "連絡先：toneappbildman@appmail.uk"; color: "white"; font.pixelSize: 16; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: "ToneInternetService. 《PC-OpenCafe.　IoT&Digital Software Development Department.》"; color: "#35d08a"; font.pixelSize: 13; anchors.horizontalCenter: parent.horizontalCenter }
        } } }
}
__E__
convert -size 128x128 xc:'#06130d' -fill '#35d08a' -gravity center -font DejaVu-Sans-Bold -pointsize 40 -annotate 0 'TONE' "$SRC/overlay/etc/calamares/branding/tone/logo.png"
convert -size 800x300 xc:'#050b08' -fill white -gravity center -font DejaVu-Sans-Bold -pointsize 64 -annotate 0 'TONE OS' "$SRC/overlay/etc/calamares/branding/tone/welcome.png"

# --- 自己検証(エミュレート用) -----------------------------------------
W usr/local/bin/tone-selftest 755 <<'__E__'
#!/bin/bash
fail=0; step() { echo "TONE-STEP: $*"; }; ng() { echo "TONE-CHECK-NG: $*"; fail=1; }
step packages
for p in rsync dosfstools parted efibootmgr grub-efi-amd64-bin google-chrome-stable steam-installer calamares fcitx5-mozc ufw clamav clamav-freshclam chrony kde-plasma-desktop sddm plymouth casper flatpak plasma-discover unattended-upgrades mpv; do
  dpkg -s "$p" 2>/dev/null | grep -q 'Status: install ok installed' || ng "MISSING-PKG:$p"; done
ls /opt/libreoffice*/program/soffice >/dev/null 2>&1 || command -v libreoffice >/dev/null || ng "MISSING-PKG:libreoffice"
step games
for p in kmahjongg kmines ksudoku kpat; do dpkg -s $p 2>/dev/null | grep -q 'ok installed' && ng "GAME-REMAINS:$p"; done
for f in /usr/share/tone-os/index.html /usr/share/tone-os/sounds/startup.* /etc/calamares/settings.conf /etc/chrony/chrony.conf; do ls $f >/dev/null 2>&1 || ng "MISSING-FILE:$f"; done
step services
for u in ufw chrony tone-freshclam.timer tone-av-full.timer tone-update.timer tone-ntp.timer tone-boot-scan.service sddm NetworkManager; do
  systemctl is-enabled "$u" >/dev/null 2>&1 || ng "NOT-ENABLED:$u"; done
[ ! -e /usr/sbin/policy-rc.d ] || ng "POLICY-RC-D-REMAINS"
[ -L /etc/resolv.conf ] || ng "RESOLV-CONF-NOT-SYMLINK"
grep -q '"SyncDisabled": false' /etc/opt/chrome/policies/managed/tone.json || ng "CHROME-SYNC-POLICY"
grep -q '"HomepageLocation": "file:///usr/share/tone-os/index.html"' /etc/opt/chrome/policies/managed/tone.json || ng "CHROME-HOMEPAGE-POLICY"
grep -q '^ENABLED=yes' /etc/ufw/ufw.conf || ng "UFW-DISABLED"
grep -q 'ntp.nict.jp' /etc/chrony/chrony.conf || ng "NTP-CONF"
grep -q 'OnBootSec=1min' /etc/systemd/system/tone-freshclam.timer || ng "FRESHCLAM-TIMER-BOOT"
grep -q 'OnUnitActiveSec=3h' /etc/systemd/system/tone-freshclam.timer || ng "FRESHCLAM-TIMER-DEFAULT-3H"
step chrome
grep -q tone-chrome /usr/share/applications/google-chrome.desktop || ng "CHROME-LAUNCHER-NOT-WRAPPED"
[ -f /usr/share/tone-os/chrome-policy/tone.json ] || ng "CHROME-POLICY-MASTER"
[ -x /usr/local/bin/tone-chrome ] || ng "CHROME-WRAPPER"
grep -q '"BrowserSignin": *0' /etc/opt/chrome/policies/managed/tone.json && ng "CHROME-SYNC-BLOCKED"
grep -q '"SyncDisabled": *true' /etc/opt/chrome/policies/managed/tone.json && ng "CHROME-SYNC-DISABLED"
grep -q 'file:///usr/share/tone-os/index.html' /etc/opt/chrome/policies/managed/tone.json || ng "CHROME-STARTPAGE-POLICY"
grep -rqs "dl.google.com" /etc/apt/sources.list.d/ || ng "CHROME-APT-SOURCE"
step features
for f in tone-wallpaper tone-index-update tone-index-apply tone-av-settings tone-av-interval tone-av-idle tone-av-full tone-freshclam tone-kernel-sync tone-first-login; do
  [ -x /usr/local/bin/$f ] || ng "MISSING-FILE:/usr/local/bin/$f"; done
[ -f /usr/share/tone-os/start-button.png ] || ng "MISSING-FILE:start-button.png"
systemctl --global is-enabled tone-wallpaper-watch.timer >/dev/null 2>&1 || ng "NOT-ENABLED:tone-wallpaper-watch.timer(global)"
command -v xprintidle >/dev/null || ng "MISSING-PKG:xprintidle"
python3 -c 'import PyQt5' 2>/dev/null || ng "MISSING-PKG:python3-pyqt5"
systemctl is-enabled tone-heartbeat.service >/dev/null 2>&1 || ng "NOT-ENABLED:tone-heartbeat.service"
step developer
for f in tone-about tone-brand tone-health-run; do [ -x /usr/local/bin/$f ] || ng "MISSING-FILE:/usr/local/bin/$f"; done
[ -f /usr/share/tone-os/developer-icon.png ] && [ -f /usr/share/tone-os/developer-icon-94.png ] || ng "MISSING-FILE:developer-icon"
grep -q 'valtanman' /usr/share/tone-os/developer.txt || ng "DEVELOPER-TEXT"
grep -q '^PRETTY_NAME="TONE OS' /usr/lib/os-release || ng "OS-RELEASE-BRAND"
[ -f /etc/xdg/kcm-about-distrorc ] || ng "KCM-ABOUT-DISTRO"
step installer
grep -q 'initialPartitioningChoice: erase' /etc/calamares/modules/partition.conf || ng "CALAMARES-ERASE-DEFAULT"
grep -qF 'availableFileSystemTypes: [ "btrfs", "ext4", "xfs" ]' /etc/calamares/modules/partition.conf || ng "CALAMARES-FSTYPES"
grep -q 'defaultFileSystemType: "btrfs"' /etc/calamares/modules/partition.conf || ng "CALAMARES-BTRFS-DEFAULT"
grep -q 'subvolume: /@home' /etc/calamares/modules/mount.conf || ng "CALAMARES-SUBVOLUMES"
command -v pkexec >/dev/null 2>&1 || ng "PKEXEC"
step update-config
grep -q 'OnBootSec=1min' /etc/systemd/system/tone-update.timer || ng "UPDATE-TIMER-BOOT"
grep -q 'OnUnitActiveSec=3h' /etc/systemd/system/tone-update.timer || ng "UPDATE-TIMER-3H"
grep -q 'Remove-Unused-Kernel-Packages' /etc/apt/apt.conf.d/51tone-unattended || ng "KERNEL-CLEANUP"
dpkg -s linux-generic-hwe-24.04 2>/dev/null | grep -q 'ok installed' || echo "TONE-INFO: HWEカーネル未導入(標準カーネルで動作)"
step v1
v=$(cat /usr/share/tone-os/version 2>/dev/null); [ -n "$v" ] || ng "VERSION-FILE"
grep -q "TONE OS $v" /usr/lib/os-release || ng "VERSION-OSRELEASE"
grep -q "^$v " /usr/share/tone-os/CHANGELOG.txt || grep -q "$v" /usr/share/tone-os/CHANGELOG.txt || ng "VERSION-CHANGELOG"
for f in tone-snapshot tone-restore tone-os-update tone-health-check tone-power tone-theme tone-dolphin-profile tone-input-apply tone-wallpaper-gallery tone-usb-flash tone-gpu-check tone-help-me tone-setup-wizard tone-install-guide tone-boot-anim tone-boot-repair tone-backup tone-app-update tone-lo-update tone-drivers tone-gpu-verify; do
  [ -x /usr/local/bin/$f ] || ng "MISSING-FILE:/usr/local/bin/$f"; done
[ -x /usr/local/lib/tone-usb/usb-root ] || ng "MISSING-FILE:usb-root"
openssl pkey -pubin -in /usr/share/tone-os/keys/update-pub.pem -noout 2>/dev/null || ng "UPDATE-PUBKEY"
for u in tone-snapshot-weekly.timer tone-os-update-check.timer tone-os-update-confirm.service tone-gpu-verify.service; do systemctl is-enabled "$u" >/dev/null 2>&1 || ng "NOT-ENABLED:$u"; done
systemctl --global is-enabled tone-app-update.timer >/dev/null 2>&1 || ng "NOT-ENABLED:tone-app-update.timer(global)"
for w in 1_floyd 2_koya 3_minobu 4_kyoto 5_nara 6_jsdf; do [ "$(ls /usr/share/tone-os/wallpapers/$w/*.jpg 2>/dev/null | wc -l)" -ge 6 ] || ng "WALLPAPERS:$w"; done
for k in wind whirl typhoon; do for f in tone.script spin.png title.png footer.png bar_track.png bar_fill.png tone-$k.plymouth; do [ -f /usr/share/plymouth/themes/tone-$k/$f ] || ng "MISSING-FILE:plymouth/tone-$k/$f"; done; done
[ "$(plymouth-set-default-theme 2>/dev/null)" = tone-wind ] || ng "PLYMOUTH-DEFAULT"
python3 -c 'import json;json.load(open("/usr/share/tone-os/worlds.json"))' || ng "WORLDS-JSON"
[ -f /usr/share/plasma/look-and-feel/jp.tone.win/contents/layouts/org.kde.plasma.desktop-layout.js ] && [ -f /usr/share/plasma/look-and-feel/jp.tone.mac/contents/layouts/org.kde.plasma.desktop-layout.js ] || ng "PLASMA-LAYOUTS"
[ "$(tone-power detect)" = desktop ] || [ "$(tone-power detect)" = notebook ] || ng "TONE-POWER"
if ! grep -q boot=casper /proc/cmdline; then [ "$(findmnt -no FSTYPE /)" = btrfs ] || ng "ROOT-NOT-BTRFS"; fi
grep -rqs 'libreoffice/ppa' /etc/apt/sources.list.d/ || echo "TONE-INFO: LibreOffice公式PPAは未設定(TDF公式版で動作)"
step locale
locale -a | grep -qi 'ja_JP.utf' || ng "LOCALE-JA"
if [ $fail = 0 ]; then echo "TONE-SELFTEST-PASS"; else echo "TONE-SELFTEST-FAIL"; fi
sleep 2
__E__
W etc/systemd/system/tone-plymouth-quit.service <<'__E__'
[Unit]
Description=起動ロゴが残った場合に確実に終了する
After=graphical.target sddm.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 8; plymouth quit 2>/dev/null; exit 0'
[Install]
WantedBy=graphical.target
__E__
W etc/systemd/system/tone-drivers.service <<'__E__'
[Unit]
Description=TONE OS ハードウェアドライバーの自動導入(初回のみ)
ConditionKernelCommandLine=!boot=casper
ConditionKernelCommandLine=!tone.test
ConditionPathExists=!/var/lib/tone-os/drivers-done
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Nice=10
ExecStart=/usr/local/bin/tone-drivers
[Install]
WantedBy=multi-user.target
__E__
W usr/local/bin/tone-health-run 755 <<'__E__'
#!/bin/bash
# 初回ヘルスチェック: 起動を止めず・時間制限つきで実行し、終わらなければ原因調査用の診断を出す
mkdir -p /var/log/tone-os /var/lib/tone-os
if grep -q tone.test /proc/cmdline; then export PS4='+[${SECONDS}s] '; RUN="bash -x /usr/local/bin/tone-selftest"; else RUN=/usr/local/bin/tone-selftest; fi
timeout 150 $RUN 2>&1 | tee /var/log/tone-os/health.log
rc=${PIPESTATUS[0]}
if [ "$rc" = 124 ]; then
  echo "TONE-HEALTH-TIMEOUT: 自己検証が150秒で終わりませんでした(診断情報を出力します)"
  ps -eo pid,stat,wchan:22,pcpu,pmem,args --sort=-pcpu | head -n 15
  dmesg | tail -n 25
  journalctl -n 30 --no-pager 2>/dev/null
fi
touch /var/lib/tone-os/health-done
exit 0
__E__
W etc/systemd/system/tone-health.service <<'__E__'
[Unit]
Description=TONE OS インストール後の初回ヘルスチェック(起動を止めない)
ConditionKernelCommandLine=!boot=casper
ConditionPathExists=!/var/lib/tone-os/health-done
After=network-online.target
[Service]
Type=simple
StandardOutput=journal+console
ExecStart=/usr/local/bin/tone-health-run
[Install]
WantedBy=multi-user.target
__E__
W etc/systemd/system/tone-selftest.service <<'__E__'
[Unit]
Description=TONE OS 自己検証
ConditionKernelCommandLine=tone.selftest
After=multi-user.target
[Service]
Type=oneshot
StandardOutput=journal+console
ExecStart=/usr/local/bin/tone-selftest
ExecStartPost=/usr/bin/systemctl --no-block poweroff
[Install]
WantedBy=multi-user.target
__E__
# =====================================================================
# ===== TONE OS 1.0.0 追加分(設計書 STANDARD 反映) ==================
# =====================================================================
# --- バージョン(主.副.修正。画面表示・HELP・履歴・ISO名・ビルドログ・更新目録を同時に更新する) ---
W usr/share/tone-os/version 644 <<__E__
$TONE_VER
__E__
W usr/share/tone-os/CHANGELOG.txt 644 <<__E__
TONE OS 更新履歴
$TONE_VER ($(date +%F))  最初の完成版(Ubuntu 24.04.5 LTS ベース)。
  Btrfs標準+「元に戻す」/ TONEアップデート受信モジュール / 電源モード / 世界観テーマ(6)+Windows風・Mac風 /
  起動アニメ(カザグルマ・鳴門の渦・台風) / Dolphin改造 / 壁紙ギャラリー / USB書き込み・強制真っ白 / GPU診断v2
__E__

# --- スナップショット(Btrfs)。Btrfs以外では何もせず正常終了する ------------------
W usr/local/bin/tone-snapshot 755 <<'__E__'
#!/bin/bash
# TONE スナップショット管理。 使い方:
#   tone-snapshot create [タグ]   現在のシステム(@)を読み取り専用で保存(ホーム@homeは含めない)
#   tone-snapshot list            一覧(新しい順)
#   tone-snapshot restore 名前    その時点へ戻す(次回起動で反映。ホームのデータは巻き戻らない)
#   tone-snapshot prune           古いものを整理(手動=20件・更新前=10件を残す)
#   tone-snapshot is-btrfs        Btrfsなら 0
# テスト用: TONE_ROOT / TONE_SNAP_DIR / TONE_BTRFS_BIN で差し替え可
SNAPDIR=${TONE_SNAP_DIR:-/.snapshots}
BTRFS=${TONE_BTRFS_BIN:-btrfs}
ROOT=${TONE_ROOT:-/}
is_btrfs() { [ "$(findmnt -no FSTYPE "$ROOT" 2>/dev/null)" = btrfs ] || [ -n "${TONE_FORCE_BTRFS:-}" ]; }
cmd=${1:-}; shift || true
case "$cmd" in
  is-btrfs) is_btrfs ;;
  create)
    is_btrfs || { echo "Btrfsではないため、スナップショットは作りません。"; exit 0; }
    tag=${1:-manual}; tag=${tag//[^A-Za-z0-9_-]/_}
    mkdir -p "$SNAPDIR"
    name="$(date +%Y%m%d-%H%M%S)-$tag"
    $BTRFS subvolume snapshot -r "$ROOT" "$SNAPDIR/$name" >/dev/null || { echo "スナップショットに失敗しました" >&2; exit 1; }
    echo "$name" ;;
  list)
    [ -d "$SNAPDIR" ] || exit 0
    ls -1 "$SNAPDIR" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}-' | sort -r ;;
  restore)
    n=${1:?名前を指定してください}
    case "$n" in */*|*..*) echo "不正な名前です" >&2; exit 2;; esac
    is_btrfs || { echo "Btrfsではないため戻せません" >&2; exit 1; }
    [ -d "$SNAPDIR/$n" ] || { echo "見つかりません: $n" >&2; exit 1; }
    dev=$(findmnt -no SOURCE "$ROOT" | sed 's/\[.*//')
    top=$(mktemp -d /run/tone-top.XXXXXX)
    mount -o subvolid=5 "$dev" "$top" || { rmdir "$top"; exit 1; }
    trap 'umount "$top" 2>/dev/null; rmdir "$top" 2>/dev/null' EXIT
    # 戻す前の状態も残す(取り消せるように)。名前を空けて、スナップショットから書き込み可能な @ を作り直す
    [ -d "$top/@" ] || { echo "@ サブボリュームが見つかりません" >&2; exit 1; }
    bk="@.before-restore-$(date +%Y%m%d-%H%M%S)"
    mv "$top/@" "$top/$bk" || exit 1
    if $BTRFS subvolume snapshot "$top/@snapshots/$n" "$top/@" >/dev/null 2>&1 || $BTRFS subvolume snapshot "$SNAPDIR/$n" "$top/@" >/dev/null 2>&1; then
      echo "戻す準備ができました。再起動すると反映されます。(戻す前の状態: $bk)"
    else
      mv "$top/$bk" "$top/@"; echo "戻せませんでした(元の状態のままです)" >&2; exit 1
    fi ;;
  prune)
    [ -d "$SNAPDIR" ] || exit 0
    keep() { ls -1 "$SNAPDIR" | grep -E "^[0-9]{8}-[0-9]{6}-$1\$" | sort -r | tail -n +"$(( $2 + 1 ))"; }
    for n in $(keep apt 10) $(keep update 10) $(keep manual 20) $(keep boot 10); do
      $BTRFS subvolume delete "$SNAPDIR/$n" >/dev/null 2>&1 || true
    done ;;
  *) echo "使い方: tone-snapshot {create [タグ]|list|restore 名前|prune|is-btrfs}" >&2; exit 2 ;;
esac
__E__
# apt が動く直前に1時間に1回までスナップショットを取る(「更新前に戻れる」ため)
W etc/apt/apt.conf.d/98tone-snapshot 644 <<'__E__'
DPkg::Pre-Invoke { "/usr/local/bin/tone-snapshot-apt || true"; };
__E__
W usr/local/bin/tone-snapshot-apt 755 <<'__E__'
#!/bin/bash
# 1時間に1回まで。Btrfsでなければ何もしない
[ -n "${TONE_SKIP_SNAP:-}" ] && exit 0
ischroot 2>/dev/null && exit 0          # ビルド中のchrootでは、ホストのディスクに触れない
tone-snapshot is-btrfs || exit 0
M=/run/tone-snap-apt.stamp
[ -f "$M" ] && [ $(( $(date +%s) - $(stat -c %Y "$M") )) -lt 3600 ] && exit 0
touch "$M"; tone-snapshot create apt >/dev/null 2>&1; tone-snapshot prune >/dev/null 2>&1; exit 0
__E__
# 週1回の自動スナップショット
W etc/systemd/system/tone-snapshot-weekly.service 644 <<'__E__'
[Unit]
Description=TONE 週次スナップショット
ConditionPathExists=/usr/local/bin/tone-snapshot
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'tone-snapshot is-btrfs && tone-snapshot create boot && tone-snapshot prune; exit 0'
__E__
W etc/systemd/system/tone-snapshot-weekly.timer 644 <<'__E__'
[Unit]
Description=TONE 週次スナップショット
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
__E__
# 起動メニューにスナップショットを載せる(grub-btrfs があるとき。無くても動作に影響しない)
W etc/default/grub-btrfs/config 644 <<'__E__'
GRUB_BTRFS_SUBMENUNAME="TONE OS 以前の状態から起動"
GRUB_BTRFS_LIMIT="10"
GRUB_BTRFS_SHOW_SNAPSHOTS_FOUND="false"
__E__
# 「元に戻す」画面
W usr/local/bin/tone-restore 755 <<'__E__'
#!/bin/bash
# 元に戻す(Windowsの復元ポイントに近い画面)
T="TONE OS 元に戻す"
dlg() { command -v kdialog >/dev/null && return 0; command -v zenity >/dev/null; }
msg() { if command -v kdialog >/dev/null; then kdialog --title "$T" --msgbox "$1"; else zenity --info --title="$T" --text="$1"; fi; }
if ! tone-snapshot is-btrfs; then msg "このPCは、元に戻す機能に対応した形式ではありません。\n(TONE OS を標準の設定でインストールしたPCで使えます。)"; exit 0; fi
mapfile -t L < <(tone-snapshot list)
[ "${#L[@]}" -gt 0 ] || { msg "戻せる時点は、まだありません。\n更新の前などに自動で作られます。"; exit 0; }
pretty() { local n=$1 d t tag; d=${n:0:8}; t=${n:9:6}; tag=${n#*-*-}
  case "$tag" in apt) tag="ソフトの更新の前";; update) tag="TONE更新の前";; boot) tag="定期";; manual) tag="手動";; esac
  echo "${d:0:4}年${d:4:2}月${d:6:2}日 ${t:0:2}:${t:2:2}  ($tag)"; }
if command -v kdialog >/dev/null; then
  args=(); for n in "${L[@]}"; do args+=("$n" "$(pretty "$n")"); done
  pick=$(kdialog --title "$T" --menu "戻したい日時を選んでください。\nホームのデータ(書類・写真など)は戻りません。" "${args[@]}") || exit 0
else
  args=(); for n in "${L[@]}"; do args+=("$n" "$(pretty "$n")"); done
  pick=$(zenity --list --title="$T" --text="戻したい日時を選んでください。ホームのデータは戻りません。" --column=id --column=日時 --hide-column=1 --print-column=1 "${args[@]}") || exit 0
fi
[ -n "$pick" ] || exit 0
if command -v kdialog >/dev/null; then kdialog --title "$T" --warningyesno "選んだ時点に戻します。\n戻す前の状態も保存されます。再起動が必要です。\n\n続けますか?" || exit 0
else zenity --question --title="$T" --text="選んだ時点に戻します。再起動が必要です。続けますか?" || exit 0; fi
if r=$(pkexec /usr/local/bin/tone-snapshot restore "$pick" 2>&1); then
  if command -v kdialog >/dev/null; then kdialog --title "$T" --yesno "準備ができました。今すぐ再起動しますか?" && systemctl reboot
  else zenity --question --title="$T" --text="準備ができました。今すぐ再起動しますか?" && systemctl reboot; fi
else msg "戻せませんでした。\n$r"; fi
__E__
W usr/share/applications/tone-restore.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=元に戻す
Comment=以前の状態に戻します
Exec=/usr/local/bin/tone-restore
Icon=document-revert
Categories=System;Settings;
__E__
# ===== TONEアップデート 受信モジュール(V1) ===========================
# 信頼の根拠は「署名」。署名鍵はサーバーにも ISO にも置かない(手元のオフライン環境だけ)。
W etc/tone-os/update.conf 644 <<'__E__'
# TONEアップデート 更新元(複数持てる。空白区切り。上から順に試す)
SOURCES="https://updates.example.invalid/tos/"
# 更新で書き換えてよい場所(OSのインストール時に記録する一覧)。これ以外へは、署名が正しくても書かない
ALLOW_PREFIXES="usr/share/tone-os usr/local/bin etc/tone-os usr/share/applications usr/share/plymouth/themes usr/share/sddm usr/share/plasma etc/xdg etc/systemd/system etc/systemd/user etc/polkit-1 usr/share/polkit-1 usr/share/color-schemes"
# 更新後の最初の起動で行うヘルスチェック
HEALTH_CMD="/usr/local/bin/tone-health-check"
# 取得の最大待ち(秒)
FETCH_TIMEOUT=30
__E__
W usr/local/bin/tone-os-update 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TONEアップデート 受信モジュール V1(TONE OS 1.0 系)
  tone-os-update check [--delay]     新しい版があるか調べる(終了コード 10=あり / 0=なし / 1=調べられず)
  tone-os-update apply               署名を検証して更新(更新前スナップショット→展開→ヘルスチェック)
  tone-os-update apply-iso DIR       ISO(マウント先)から同じ手順で更新(スタンドアロン用)
  tone-os-update confirm             更新後の最初の起動で実行。ヘルスチェックに通らなければ自動で前の状態へ戻す
  tone-os-update rotate-key PEM SIG  新しい公開鍵へ差し替える(現在の鍵で署名されたものだけ受け付ける)
  tone-os-update status              版・更新元・鍵の状態
守り: 署名のないスクリプトは取得しない/実行しない。スクリプトは、署名を検証できたパッケージの中のものだけ。
      ユーザーデータ(ホーム・localStorage)には触れない。現在より古い版へは更新しない。
テスト用: TONE_ROOT(ルートの代わり) TONE_SNAPSHOT_CMD TONE_NO_REBOOT"""
import os, sys, json, hashlib, subprocess, tarfile, tempfile, shutil, time, random, re, urllib.request, urllib.parse, glob

ROOT = os.environ.get("TONE_ROOT", "")
def P(p): return os.path.join(ROOT, p.lstrip("/"))
SNAP = os.environ.get("TONE_SNAPSHOT_CMD", "/usr/local/bin/tone-snapshot")
STATE = P("/var/lib/tone-os/update")
PUBKEY = P("/usr/share/tone-os/keys/update-pub.pem")
KEYS_D = P("/etc/tone-os/keys.d")
VERFILE = P("/usr/share/tone-os/version")

def say(m): print(m, flush=True)
def hist(m):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "history.log"), "a") as f: f.write("%s %s\n" % (time.strftime("%F %T"), m))
def conf():
    c = {"SOURCES": "https://updates.example.invalid/tos/", "ALLOW_PREFIXES": "usr/share/tone-os", "HEALTH_CMD": "", "FETCH_TIMEOUT": "30"}
    try:
        for l in open(P("/etc/tone-os/update.conf"), encoding="utf-8"):
            m = re.match(r'^\s*([A-Z_]+)\s*=\s*"?(.*?)"?\s*$', l)
            if m and not l.lstrip().startswith("#"): c[m.group(1)] = m.group(2)
    except OSError: pass
    return c
def curver():
    try: return open(VERFILE).read().strip()
    except OSError: return "0.0.0"
def vt(v):
    try: return tuple(int(x) for x in v.strip().split("."))
    except Exception: return None
def keys():
    ks = [PUBKEY] if os.path.isfile(PUBKEY) else []
    return ks + sorted(glob.glob(os.path.join(KEYS_D, "*.pem")))
def verify_sig(data_path, sig_path, keylist=None):
    for k in (keylist or keys()):
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", k, "-signature", sig_path, data_path], capture_output=True)
        if r.returncode == 0: return True
    return False
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
def fetch(src, name, dest, timeout):
    """src: URL または ディレクトリ。取得できなければ例外"""
    if src.startswith(("http://", "https://")):
        url = src.rstrip("/") + "/" + urllib.parse.quote(name)
        req = urllib.request.Request(url, headers={"User-Agent": "TONE-OS-Update/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f: shutil.copyfileobj(r, f)
    else:
        shutil.copyfile(os.path.join(src.replace("file://", ""), name), dest)

def get_manifest(sources, tmp):
    """署名の合う目録を返す。どの更新元も駄目なら None(理由は黙って記録するだけ)"""
    for s in sources:
        try:
            m, g = os.path.join(tmp, "manifest.json"), os.path.join(tmp, "manifest.json.sig")
            fetch(s, "manifest.json", m, int(conf()["FETCH_TIMEOUT"])); fetch(s, "manifest.json.sig", g, int(conf()["FETCH_TIMEOUT"]))
            if not verify_sig(m, g): hist("署名が合わないため捨てました: %s" % s); continue
            d = json.load(open(m, encoding="utf-8"))
            if d.get("format") != 1: hist("未対応の目録形式: %s" % s); continue
            return s, d
        except Exception as e:
            hist("取得できませんでした(%s): %s" % (s, e))
    return None, None

def safe_members(tf, allow):
    """展開してよい中身だけを返す。危ないものが1つでもあれば例外"""
    out = []
    for m in tf.getmembers():
        n = m.name.lstrip("./")
        if n == "": continue
        if os.path.isabs(m.name) or ".." in n.split("/"): raise ValueError("不正なパス: " + m.name)
        if m.isdev() or m.isfifo(): raise ValueError("特殊ファイルは入れられません: " + m.name)
        if m.islnk(): raise ValueError("ハードリンクは入れられません: " + m.name)
        if m.issym():
            t = m.linkname
            if os.path.isabs(t) or ".." in t.split("/"): raise ValueError("外を指すリンク: " + m.name)
        top = n.split("/")[0]
        if n == "scripts" or n.startswith("scripts/"): out.append((m, n)); continue
        if not n.startswith("payload/") and n != "payload": raise ValueError("payload/ か scripts/ の外にあります: " + m.name)
        rel = n[len("payload/"):] if n != "payload" else ""
        if rel and not any(rel == a or rel.startswith(a + "/") or a.startswith(rel + "/") for a in allow):
            raise ValueError("許可されていない場所: " + rel)
        if rel and not any(rel == a or rel.startswith(a + "/") for a in allow) and not m.isdir():
            raise ValueError("許可されていない場所: " + rel)
        out.append((m, n))
    return out

def extract(tf, m, dest):
    try: tf.extract(m, dest, filter="data")        # Python 3.12+: 危険なメタ情報を落として展開
    except TypeError: tf.extract(m, dest)

def install_tree(stage, root):
    for dp, dns, fns in os.walk(stage):
        rel = os.path.relpath(dp, stage); dst = root if rel == "." else os.path.join(root, rel)
        os.makedirs(dst, exist_ok=True)
        for f in fns:
            s, d = os.path.join(dp, f), os.path.join(dst, f)
            if os.path.islink(s):
                tmp = d + ".tone-new"
                if os.path.lexists(tmp): os.remove(tmp)
                os.symlink(os.readlink(s), tmp); os.replace(tmp, d)
            else:
                tmp = d + ".tone-new"; shutil.copyfile(s, tmp); shutil.copymode(s, tmp); os.replace(tmp, d)

def snapshot(tag):
    try:
        r = subprocess.run([SNAP, "create", tag], capture_output=True, text=True, timeout=300)
        n = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        return n if r.returncode == 0 and re.match(r"^\d{8}-\d{6}-", n) else ("" if r.returncode == 0 else None)
    except Exception: return None

def health():
    cmd = conf().get("HEALTH_CMD", "")
    if not cmd: return True
    try: return subprocess.run([cmd], capture_output=True, timeout=300, env=dict(os.environ, TONE_ROOT=ROOT)).returncode == 0
    except Exception: return False

def run_update(sources, label):
    cur = curver(); tmp = tempfile.mkdtemp(prefix="tone-upd.")
    try:
        src, man = get_manifest(sources, tmp)
        if not man: say("更新情報を取得できませんでした(あとで自動で再試行します)。"); return 1
        new, minv = man.get("os_version", ""), man.get("min_version", "0.0.0")
        if vt(new) is None or vt(minv) is None: say("目録の版が不正です。"); hist("目録の版が不正"); return 1
        if vt(new) <= vt(cur): say("TONE OS は最新です(%s)。" % cur); return 0
        if vt(cur) < vt(minv): say("この更新の前に、%s 以上へ更新が必要です(現在 %s)。" % (minv, cur)); hist("min_version 未満"); return 3
        allow = conf()["ALLOW_PREFIXES"].split()
        stage = os.path.join(tmp, "stage"); os.makedirs(stage); scripts = []
        for pk in man.get("packages", []):
            fn = pk.get("file", "")
            if not re.match(r"^[A-Za-z0-9._+-]+$", fn): say("不正なファイル名: %s" % fn); return 1
            dest = os.path.join(tmp, fn)
            fetch(src, fn, dest, int(conf()["FETCH_TIMEOUT"]) * 10)
            if sha256(dest) != pk.get("sha256"): say("パッケージの検査が合いません。更新を中止しました(%s)。" % fn); hist("sha256不一致: " + fn); return 1
            with tarfile.open(dest) as tf:
                mem = safe_members(tf, allow)
                for m, n in mem:
                    if n.startswith("scripts/"): extract(tf, m, tmp)
                    elif n.startswith("payload/"): m.name = n[len("payload/"):] or "."; extract(tf, m, stage)
            if os.path.isdir(os.path.join(tmp, "scripts")): scripts.append(os.path.join(tmp, "scripts"))
        snap = snapshot("update")
        if snap is None: say("更新前の保存に失敗したため、更新を中止しました。"); hist("スナップショット失敗"); return 1
        os.makedirs(STATE, exist_ok=True)
        json.dump({"from": cur, "to": new, "snapshot": snap, "ts": int(time.time())}, open(os.path.join(STATE, "pending.json"), "w"))
        install_tree(stage, ROOT or "/")
        for sd in scripts:
            ps = os.path.join(sd, "post-install")
            if os.path.isfile(ps):   # 署名を検証できたパッケージの中のものだけ
                subprocess.run(["/bin/bash", ps], env=dict(os.environ, TONE_ROOT=ROOT), timeout=600)
        os.makedirs(os.path.dirname(VERFILE), exist_ok=True); open(VERFILE, "w").write(new + "\n")
        with open(P("/usr/share/tone-os/CHANGELOG.txt"), "a", encoding="utf-8") as f:
            f.write("%s (%s)  %s\n" % (new, man.get("released", time.strftime("%F")), man.get("notes", "")))
        hist("%s 更新 %s → %s (%s)" % (label, cur, new, snap or "スナップショットなし"))
        say("更新しました(%s → %s)。次回の起動時に動作を確認します。" % (cur, new)); return 0
    except Exception as e:
        hist("更新中止: %s" % e); say("更新を中止しました(システムは変更していません、または元に戻せます): %s" % e); return 1
    finally: shutil.rmtree(tmp, ignore_errors=True)

def cmd_check(delay):
    if delay: time.sleep(random.randint(0, 600))
    tmp = tempfile.mkdtemp(prefix="tone-chk.")
    try:
        src, man = get_manifest(conf()["SOURCES"].split(), tmp)
        if not man: return 1
        os.makedirs(STATE, exist_ok=True)
        json.dump({"current": curver(), "available": man.get("os_version"), "notes": man.get("notes", ""), "checked": int(time.time())}, open(os.path.join(STATE, "available.json"), "w"))
        if vt(man.get("os_version", "")) and vt(man["os_version"]) > vt(curver()): say("新しい版があります: %s" % man["os_version"]); return 10
        say("TONE OS は最新です(%s)。" % curver()); return 0
    finally: shutil.rmtree(tmp, ignore_errors=True)

def cmd_confirm():
    pf = os.path.join(STATE, "pending.json")
    if not os.path.isfile(pf): return 0
    p = json.load(open(pf))
    if health():
        os.remove(pf); hist("更新後の確認に合格: %s" % p.get("to")); subprocess.run([SNAP, "prune"], capture_output=True); return 0
    hist("更新後の確認に不合格 → 元に戻します: %s" % p.get("snapshot"))
    os.remove(pf)
    if p.get("snapshot"):
        r = subprocess.run([SNAP, "restore", p["snapshot"]], capture_output=True, text=True)
        hist("restore rc=%s %s" % (r.returncode, r.stdout.strip()))
        if r.returncode == 0 and not os.environ.get("TONE_NO_REBOOT"): subprocess.run(["systemctl", "reboot"])
    return 4

def cmd_rotate(pem, sig):
    if not verify_sig(pem, sig): say("現在の鍵で署名されていないため、差し替えできません。"); return 1
    r = subprocess.run(["openssl", "pkey", "-pubin", "-in", pem, "-noout"], capture_output=True)
    if r.returncode != 0: say("公開鍵として読めません。"); return 1
    os.makedirs(KEYS_D, exist_ok=True); dst = os.path.join(KEYS_D, "rot-%s.pem" % time.strftime("%Y%m%d%H%M%S"))
    shutil.copyfile(pem, dst); hist("鍵を追加: " + dst); say("新しい鍵を追加しました。"); return 0

def main(a):
    if not a: print(__doc__); return 2
    c = a[0]
    if c == "check": return cmd_check("--delay" in a)
    if c == "apply": return run_update(conf()["SOURCES"].split(), "ネット")
    if c == "apply-iso" and len(a) > 1: return run_update([a[1]], "ISO")
    if c == "confirm": return cmd_confirm()
    if c == "rotate-key" and len(a) > 2: return cmd_rotate(a[1], a[2])
    if c == "status":
        print("版: %s\n更新元: %s\n鍵: %d 個" % (curver(), conf()["SOURCES"], len(keys()))); return 0
    print(__doc__); return 2
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
__E__
W usr/local/bin/tone-health-check 755 <<'__E__'
#!/bin/bash
# 更新後に「OSが正常か」を確かめる最小の検査(通らなければ自動で前の状態へ戻す)
R=${TONE_ROOT:-}
for f in /usr/local/bin/tone-os-update /usr/local/bin/tone-snapshot /usr/share/tone-os/version; do [ -e "$R$f" ] || exit 1; done
[ -n "$R" ] && exit 0
systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' || exit 1
systemctl is-active --quiet sddm || systemctl is-active --quiet NetworkManager || exit 1
exit 0
__E__
W etc/systemd/system/tone-os-update-confirm.service 644 <<'__E__'
[Unit]
Description=TONE アップデート後の動作確認(通らなければ自動で戻す)
ConditionKernelCommandLine=!boot=casper
ConditionPathExists=/var/lib/tone-os/update/pending.json
After=multi-user.target
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/usr/local/bin/tone-os-update confirm
[Install]
WantedBy=multi-user.target
__E__
W etc/systemd/system/tone-os-update-check.service 644 <<'__E__'
[Unit]
Description=TONE アップデート 更新確認(通知だけ。勝手には入れない)
ConditionKernelCommandLine=!boot=casper
After=network-online.target
[Service]
Type=oneshot
Nice=15
ExecStart=/usr/local/bin/tone-os-update-notify
__E__
W etc/systemd/system/tone-os-update-check.timer 644 <<'__E__'
[Unit]
Description=TONE アップデート 更新確認(1日1回・端末ごとにずらす)
[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=2h
Persistent=true
[Install]
WantedBy=timers.target
__E__
W usr/local/bin/tone-os-update-notify 755 <<'__E__'
#!/bin/bash
# 取得に失敗しても利用者には見せない(後で再試行)。新しい版があるときだけ1回だけ知らせる
/usr/local/bin/tone-os-update check; rc=$?
[ "$rc" = 10 ] || exit 0
v=$(python3 -c 'import json;print(json.load(open("/var/lib/tone-os/update/available.json")).get("available",""))' 2>/dev/null)
S=/var/lib/tone-os/update/notified; [ "$(cat "$S" 2>/dev/null)" = "$v" ] && exit 0
echo "$v" > "$S"
for u in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | sort -u); do
  id=$(id -u "$u" 2>/dev/null) || continue
  sudo -u "$u" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$id/bus" notify-send -i system-software-update "TONE OS の新しい版 $v があります" "メニューの「TONEを更新する」から入れられます。" 2>/dev/null
done
exit 0
__E__
W usr/local/bin/tone-os-update-gui 755 <<'__E__'
#!/bin/bash
# ワンクリックの「TONEを更新する」(OSに最初から入っている。サーバーから取ってきたスクリプトは実行しない)
T="TONE OS 更新"
say() { if command -v kdialog >/dev/null; then kdialog --title "$T" --msgbox "$1"; else zenity --info --title="$T" --text="$1"; fi; }
tone-os-update check >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then say "いまは更新情報を取得できませんでした。\nしばらくしてからもう一度お試しください。"; exit 0; fi
if [ "$rc" = 0 ]; then say "TONE OS は最新です。(版 $(cat /usr/share/tone-os/version 2>/dev/null))"; exit 0; fi
v=$(python3 -c 'import json;d=json.load(open("/var/lib/tone-os/update/available.json"));print(d.get("available",""),"\n",d.get("notes",""))' 2>/dev/null)
if command -v kdialog >/dev/null; then kdialog --title "$T" --yesno "新しい版があります。\n$v\n\n更新の前に、元に戻せるよう自動で保存します。更新しますか?" || exit 0
else zenity --question --title="$T" --text="新しい版があります。$v\n更新しますか?" || exit 0; fi
r=$(pkexec /usr/local/bin/tone-os-update apply 2>&1)
say "$r"
__E__
W usr/share/applications/tone-os-update.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=TONEを更新する
Comment=TONE OS の新しい版を確認して入れます
Exec=/usr/local/bin/tone-os-update-gui
Icon=system-software-update
Categories=System;Settings;
__E__
# --- スタンドアロン用: 更新ISOに入れる入口(OS内の更新プログラムを呼ぶだけ) ---
W usr/share/tone-os/tools/tone-update-from-iso.sh 755 <<'__E__'
#!/bin/bash
# 更新ISOの入口。ISOの中身はそのまま信用しない: OSに入っている tone-os-update が、署名を検証してから展開する。
D=$(cd "$(dirname "$0")" && pwd)
if ! command -v tone-os-update >/dev/null 2>&1; then
  echo "このPCには TONE OS の更新プログラムが見つかりません。TONE OS 上で実行してください。"; exit 1
fi
if [ "$(id -u)" != 0 ]; then exec pkexec tone-os-update apply-iso "$D"; fi
exec tone-os-update apply-iso "$D"
__E__
# --- 配布側(手元のオフライン環境)で使う道具。鍵・署名はここだけ。OSの更新鍵は焼き込み済みの公開鍵のみ ---
W usr/share/tone-os/tools/tone-release 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TONE リリース道具(手元のオフライン環境で使う。秘密鍵をサーバーや ISO に置かない)
  tone-release genkey DIR                        署名鍵(ECDSA P-256)を作る  DIR/update-key.pem  DIR/update-pub.pem
  tone-release pack OUT VERSION SRC [--min V] [--notes 文]   SRC(root相当のツリー)から目録とパッケージを作り署名
  tone-release makeiso OUT ISOFILE               OUT の中身+入口スクリプトで更新ISOを作る
  環境変数 TONE_SIGN_KEY=秘密鍵のパス"""
import os, sys, json, hashlib, subprocess, tarfile, shutil, time
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
def sign(path, key): subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", path + ".sig", path], check=True)
def main(a):
    if len(a) < 2: print(__doc__); return 2
    if a[0] == "genkey":
        os.makedirs(a[1], exist_ok=True); k = os.path.join(a[1], "update-key.pem")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", k], check=True); os.chmod(k, 0o600)
        subprocess.run(["openssl", "ec", "-in", k, "-pubout", "-out", os.path.join(a[1], "update-pub.pem")], check=True, capture_output=True)
        print("作成しました。update-key.pem(秘密)は手元のオフライン環境だけに保管してください。"); return 0
    if a[0] == "pack" and len(a) >= 4:
        out, ver, src = a[1], a[2], a[3]; key = os.environ.get("TONE_SIGN_KEY")
        if not key or not os.path.isfile(key): print("TONE_SIGN_KEY を指定してください"); return 1
        minv = a[a.index("--min") + 1] if "--min" in a else "1.0.0"; notes = a[a.index("--notes") + 1] if "--notes" in a else ""
        os.makedirs(out, exist_ok=True); fn = "tone-core-%s.tar.xz" % ver; fp = os.path.join(out, fn)
        with tarfile.open(fp, "w:xz") as tf:
            for dp, dns, fns in os.walk(src):
                for n in sorted(dns + fns):
                    full = os.path.join(dp, n); tf.add(full, arcname="payload/" + os.path.relpath(full, src), recursive=False)
            if os.path.isdir(os.path.join(src, "..", "scripts-" + ver)): tf.add(os.path.join(src, "..", "scripts-" + ver), arcname="scripts")
        man = {"format": 1, "os_version": ver, "min_version": minv, "released": time.strftime("%F"), "notes": notes,
               "packages": [{"name": "tone-core", "version": ver, "file": fn, "sha256": sha(fp), "size": os.path.getsize(fp)}]}
        mp = os.path.join(out, "manifest.json"); json.dump(man, open(mp, "w"), ensure_ascii=False, indent=1); sign(mp, key)
        print("作成: %s / %s / manifest.json(+.sig)" % (out, fn)); return 0
    if a[0] == "makeiso" and len(a) >= 3:
        out, iso = a[1], a[2]; here = os.path.dirname(os.path.abspath(__file__))
        stage = out.rstrip("/") + ".isostage"; shutil.rmtree(stage, ignore_errors=True); shutil.copytree(out, stage)
        ent = os.path.join(here, "tone-update-from-iso.sh")
        if os.path.isfile(ent): shutil.copy(ent, stage)
        subprocess.run(["xorriso", "-as", "mkisofs", "-V", "TONE_UPDATE", "-J", "-r", "-o", iso, stage], check=True)
        shutil.rmtree(stage, ignore_errors=True); print("作成: " + iso); return 0
    print(__doc__); return 2
sys.exit(main(sys.argv[1:]))
__E__
# ===== 電源モード(デスクPC / ノートPC) ===============================
W usr/local/bin/tone-power 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TONE 電源モード
  tone-power detect            機種を判別(desktop / notebook。判別できなければ notebook)
  tone-power status            いまの設定と状態
  tone-power mode auto|desktop|notebook   モードを選ぶ(いつでも変更可)
  tone-power lid-run on|off    ふたを閉じても稼働(温度センサーがある機種だけ)
  tone-power ai-on | ai-off    AI導入時/撤去時に呼ばれる(導入前の値を記録して戻す)
  tone-power watch             常駐(見張り): 電源の状態に合わせて「眠らせない」を入り切りし、熱を見張る
  tone-power battery           電池の状態(残量・劣化)を表示
  tone-power charge-limit N    充電上限(対応機種のみ。例 80)
ディスプレイの設定(消灯・スクリーンセーバー)には一切触れない。通信も切らない。
テスト用: TONE_ROOT TONE_SYS(/sys の代わり)"""
import os, sys, json, time, glob, subprocess, signal

ROOT = os.environ.get("TONE_ROOT", ""); SYS = os.environ.get("TONE_SYS", "/sys")
def P(p): return os.path.join(ROOT, p.lstrip("/"))
CONF = P("/etc/tone-os/power.conf"); STATE = P("/var/lib/tone-os/power.json")
HOT_C = 85; WARM_RESUME = 70; LOW_BATT = 15

def jl(p, d):
    try: return json.load(open(p))
    except Exception: return d
def js(p, o):
    os.makedirs(os.path.dirname(p), exist_ok=True); tmp = p + ".new"; json.dump(o, open(tmp, "w"), ensure_ascii=False); os.replace(tmp, p)
def rd(p, d=""):
    try: return open(p).read().strip()
    except Exception: return d

def detect():
    ct = rd(SYS + "/class/dmi/id/chassis_type")
    if ct.isdigit():
        c = int(ct)
        if c in (3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 35, 36): return "desktop"
        if c in (8, 9, 10, 11, 14, 30, 31, 32): return "notebook"
    return "notebook"   # バッテリーがある/判別できない → 安全側のノート扱い

def temps():
    v = []
    for f in glob.glob(SYS + "/class/thermal/thermal_zone*/temp") + glob.glob(SYS + "/class/hwmon/hwmon*/temp*_input"):
        t = rd(f)
        if t.lstrip("-").isdigit():
            n = int(t); v.append(n / 1000.0 if abs(n) > 500 else float(n))
    return v
def has_temp_sensor(): return len(temps()) > 0

def on_ac():
    sup = glob.glob(SYS + "/class/power_supply/*")
    mains = [s for s in sup if rd(s + "/type") in ("Mains", "USB", "USB_PD") ]
    if mains: return any(rd(s + "/online") == "1" for s in mains)
    return not glob.glob(SYS + "/class/power_supply/BAT*") or any(rd(b + "/status") in ("Charging", "Full", "Not charging") for b in glob.glob(SYS + "/class/power_supply/BAT*"))
def batt():
    b = glob.glob(SYS + "/class/power_supply/BAT*")
    if not b: return None
    b = b[0]; cap = rd(b + "/capacity")
    def num(*names):
        for n in names:
            x = rd(b + "/" + n)
            if x.isdigit(): return int(x)
        return None
    full, design = num("energy_full", "charge_full"), num("energy_full_design", "charge_full_design")
    return {"capacity": int(cap) if cap.isdigit() else None, "status": rd(b + "/status"),
            "health_pct": round(full * 100.0 / design, 1) if full and design else None, "cycles": num("cycle_count")}

def conf():
    c = {"MODE": "auto", "LID_RUN": "0"}
    for l in rd(CONF).splitlines():
        if "=" in l and not l.startswith("#"): k, v = l.split("=", 1); c[k.strip()] = v.strip()
    return c
def wconf(c):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    open(CONF, "w").write("".join("%s=%s\n" % kv for kv in sorted(c.items())))
def eff_mode():
    m = conf()["MODE"]; return detect() if m == "auto" else m
def ai_on_flag(): return jl(STATE, {}).get("ai_on", False)

def desired():
    """(眠らせない?, ふたを閉じても動く?)"""
    if not ai_on_flag(): return (False, False)
    mode = eff_mode(); stay = mode == "desktop" or on_ac()
    lid = stay and mode == "notebook" and conf()["LID_RUN"] == "1" and has_temp_sensor()
    return (stay, lid)

def cmd_status():
    b = batt(); c = conf()
    print("モード設定: %s(判別: %s)" % (c["MODE"], detect()))
    print("AI導入による「眠らせない」: %s" % ("入" if ai_on_flag() else "切"))
    print("電源: %s" % ("AC" if on_ac() else "電池"))
    print("ふたを閉じても稼働: %s(温度センサー: %s)" % ("入" if c["LID_RUN"] == "1" else "切", "あり" if has_temp_sensor() else "なし"))
    if b: print("電池: 残量 %s%% / 状態 %s / 劣化の目安(健康度) %s%% / 充放電回数 %s" % (b["capacity"], b["status"], b["health_pct"], b["cycles"]))
    return 0

def cmd_ai(on):
    st = jl(STATE, {})
    if on:
        st.setdefault("prev", {"mode": conf()["MODE"], "lid_run": conf()["LID_RUN"]})   # 導入前の値を記録
        st["ai_on"] = True
    else:
        prev = st.get("prev")
        if prev:
            c = conf(); c["MODE"] = prev.get("mode", "auto"); c["LID_RUN"] = prev.get("lid_run", "0"); wconf(c)
        st["ai_on"] = False; st.pop("prev", None)
    js(STATE, st)
    if not ROOT:
        if on: subprocess.run(["systemctl", "enable", "--now", "tone-power-watch.service"], capture_output=True)
        else: subprocess.run(["systemctl", "disable", "--now", "tone-power-watch.service"], capture_output=True)
    print("電源の「眠らせない」設定を%sにしました。" % ("入" if on else "切(導入前へ戻す)")); return 0

def cmd_mode(m):
    if m not in ("auto", "desktop", "notebook"): print("auto / desktop / notebook のどれかを指定してください"); return 2
    c = conf(); c["MODE"] = m; wconf(c); print("モード: %s(いまの判別 %s)" % (m, eff_mode())); return 0
def cmd_lid(v):
    if v == "on" and not has_temp_sensor(): print("温度センサーがない機種のため、このモードは用意できません。"); return 1
    if v == "on" and eff_mode() != "notebook": print("ノートPCのときだけ選べます。"); return 1
    c = conf(); c["LID_RUN"] = "1" if v == "on" else "0"; wconf(c); print("ふたを閉じて動かすモード: %s" % v); return 0

def cmd_charge(n):
    cands = glob.glob(SYS + "/class/power_supply/BAT*/charge_control_end_threshold")
    if not cands: print("この機種は充電上限の設定に対応していません。"); return 1
    if not n.isdigit() or not 50 <= int(n) <= 100: print("50〜100 で指定してください"); return 2
    for f in cands: open(f, "w").write(n)
    c = conf(); c["CHARGE_LIMIT"] = n; wconf(c); print("充電上限を %s%% にしました。" % n); return 0

class Inhib:
    def __init__(self): self.sleep = None; self.lid = None
    def _start(self, what, why):
        return subprocess.Popen(["systemd-inhibit", "--what=" + what, "--who=TONE OS", "--why=" + why, "--mode=block", "sleep", "infinity"])
    def set(self, want_sleep, want_lid):
        if want_sleep and not self.sleep: self.sleep = self._start("sleep:idle", "TONE OS: AI本体を動かし続けます")
        if not want_sleep and self.sleep: self.sleep.terminate(); self.sleep.wait(); self.sleep = None
        if want_lid and not self.lid: self.lid = self._start("handle-lid-switch", "TONE OS: ふたを閉じて稼働モード")
        if not want_lid and self.lid: self.lid.terminate(); self.lid.wait(); self.lid = None
    def stop(self): self.set(False, False)

def cmd_watch():
    inh = Inhib(); signal.signal(signal.SIGTERM, lambda *a: (inh.stop(), sys.exit(0)))
    hot = False
    while True:
        stay, lid = desired()
        t = max(temps() or [0])
        if lid:
            if t >= HOT_C:                 # 高温: 自動でサスペンド
                hot = True; subprocess.run(["systemctl", "suspend", "-i"], capture_output=True)
            if hot and t > WARM_RESUME: lid = False
            if t <= WARM_RESUME: hot = False
        b = batt()
        if b and b["capacity"] is not None and not on_ac() and b["capacity"] <= LOW_BATT: stay = False
        inh.set(stay, lid); time.sleep(15)

def cmd_battery():
    b = batt()
    if not b: print("電池は見つかりません(デスクPC)。"); return 0
    print("残量 %s%% / 状態 %s" % (b["capacity"], b["status"]))
    if b["health_pct"] is not None:
        h = b["health_pct"]; print("電池の健康度: %s%%(%s)" % (h, "良好" if h >= 80 else ("劣化が進んでいます" if h >= 60 else "交換の目安です")))
    return 0

def main(a):
    if not a: print(__doc__); return 2
    c = a[0]
    if c == "detect": print(detect()); return 0
    if c == "status": return cmd_status()
    if c == "ai-on": return cmd_ai(True)
    if c == "ai-off": return cmd_ai(False)
    if c == "mode" and len(a) > 1: return cmd_mode(a[1])
    if c == "lid-run" and len(a) > 1: return cmd_lid(a[1])
    if c == "watch": return cmd_watch()
    if c == "battery": return cmd_battery()
    if c == "charge-limit" and len(a) > 1: return cmd_charge(a[1])
    print(__doc__); return 2
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
__E__
W etc/systemd/system/tone-power-watch.service 644 <<'__E__'
[Unit]
Description=TONE 電源の見張り(AI導入時だけ有効。眠らせない設定の入り切りと熱の見張り)
ConditionKernelCommandLine=!boot=casper
ConditionPathExists=/var/lib/tone-os/power.json
[Service]
ExecStart=/usr/local/bin/tone-power watch
Restart=on-failure
Nice=10
[Install]
WantedBy=multi-user.target
__E__
# 明るさの自動調整(利用者が「使う」と答えたときだけ。既定はオフ)
W usr/local/bin/tone-autobright 755 <<'__E__'
#!/bin/bash
# 明るさの自動調整。対応する装置を調べ、あるときだけ「使いますか」と聞く。答えるまで何もしない(既定はオフ)。
#   tone-autobright probe      対応装置: als(照度センサー) / camera / none
#   tone-autobright ask        対応していれば、使うかどうかを聞く(一度答えたら聞かない)
#   tone-autobright run        利用者が「使う」と答えているときだけ実行(常駐)
CFG="$HOME/.config/tone-os/autobright"
probe() {
  ls /sys/bus/iio/devices/iio:device*/in_illuminance_raw /sys/bus/iio/devices/iio:device*/in_illuminance_input >/dev/null 2>&1 && { echo als; return; }
  ls /dev/video0 >/dev/null 2>&1 && { echo camera; return; }
  echo none
}
ask() {
  p=$(probe); [ "$p" = none ] && exit 0
  [ -f "$CFG" ] && exit 0
  mkdir -p "$(dirname "$CFG")"
  case "$p" in
    als) t="明るさセンサーが見つかりました。\n周りの明るさに合わせて、画面の明るさを自動で調整しますか?\n(いつでも設定から変えられます)";;
    camera) t="カメラが見つかりました。\nカメラで周りの明るさだけを測って、画面の明るさを自動で調整しますか?\n・処理はこのPCの中だけで、画像は保存しません。\n・1回に1コマだけ読み取り、そのときカメラのランプが点きます。";;
  esac
  if kdialog --title "明るさの自動調整" --yesno "$t" 2>/dev/null; then echo "on=$p" > "$CFG"; else echo "off" > "$CFG"; fi
}
run() {
  grep -q '^on=' "$CFG" 2>/dev/null || exit 0
  mode=$(sed -n 's/^on=//p' "$CFG")
  max=$(cat /sys/class/backlight/*/max_brightness 2>/dev/null | head -1); [ -n "$max" ] || exit 0
  dev=$(ls -d /sys/class/backlight/* | head -1)
  while sleep 60; do
    if [ "$mode" = als ]; then v=$(cat /sys/bus/iio/devices/iio:device*/in_illuminance_raw 2>/dev/null | head -1); v=${v%.*}; v=${v:-100}
      pct=$(( v > 400 ? 100 : (v < 10 ? 20 : 20 + v * 80 / 400 )))
    else
      f=$(mktemp /tmp/tb.XXXXXX.jpg); ffmpeg -loglevel quiet -f v4l2 -i /dev/video0 -frames:v 1 -y "$f" 2>/dev/null || { rm -f "$f"; continue; }
      l=$(convert "$f" -colorspace Gray -format '%[fx:int(mean*100)]' info: 2>/dev/null || echo 50); rm -f "$f"   # 保存しない
      pct=$(( 20 + l * 80 / 100 ))
    fi
    brightnessctl -q -d "$(basename "$dev")" set "${pct}%" 2>/dev/null || true
  done
}
case "${1:-}" in probe) probe;; ask) ask;; run) run;; *) echo "probe | ask | run";; esac
__E__
W etc/xdg/autostart/tone-autobright-ask.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE 明るさの自動調整の確認
Exec=/bin/sh -c '/usr/local/bin/tone-autobright ask; /usr/local/bin/tone-autobright run'
NoDisplay=true
OnlyShowIn=KDE;
__E__
# ===== 世界観(6) × 操作の形(Windows風 / Mac風) =========================
# 世界観は Windows のテーマと同じ扱い: 色・壁紙・ログイン画面をまとめて切り替える。GRUB(起動の選択画面)は触らない。
W usr/share/tone-os/worlds.json 644 <<'__E__'
{"worlds":[
 {"id":"1_floyd","name":"ピンク・フロイド","bg":"#0d0b1a","bg2":"#171329","accent":"#e0559a","fg":"#eceaf5"},
 {"id":"2_koya","name":"高野山(空海)","bg":"#101a14","bg2":"#18261d","accent":"#c9a24a","fg":"#ecefe6"},
 {"id":"3_minobu","name":"身延山(日蓮)","bg":"#0f1a17","bg2":"#172823","accent":"#6fbf8a","fg":"#e8f0ec"},
 {"id":"4_kyoto","name":"京都の歴史","bg":"#1a1012","bg2":"#281a1d","accent":"#d0453a","fg":"#f3e9e9"},
 {"id":"5_nara","name":"奈良の歴史","bg":"#15181a","bg2":"#1f2427","accent":"#d98c4a","fg":"#eceeee"},
 {"id":"6_jsdf","name":"陸海空自衛隊","bg":"#0c1522","bg2":"#142234","accent":"#5aa0e0","fg":"#e8eef6"}
]}
__E__
W usr/local/bin/tone-theme 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TONE テーマ
  tone-theme list
  tone-theme set 世界観ID [--style win|mac]    色・壁紙・ログイン画面・Dolphinの使い方をまとめて切り替える
  tone-theme style win|mac                     操作の形だけ変える
  tone-theme apply                             保存した設定を適用(ログイン時)
  tone-theme scheme 世界観ID 出力先             色の定義ファイルだけ作る(テスト用)
テスト用: TONE_THEME_DRY=1 で外部コマンドを実行しない"""
import os, sys, json, subprocess, configparser, glob, shutil
HOME = os.environ.get("HOME", os.path.expanduser("~"))
CFG = os.path.join(HOME, ".config", "tone-os", "theme.json")
WORLDS = os.environ.get("TONE_WORLDS", "/usr/share/tone-os/worlds.json")
WPDIRS = [os.path.join(HOME, ".local/share/tone-os/wallpapers"), "/usr/share/tone-os/wallpapers"]
DRY = bool(os.environ.get("TONE_THEME_DRY"))
def sh(*c):
    if DRY: print("RUN", " ".join(c)); return 0
    try: return subprocess.run(list(c), capture_output=True, timeout=60).returncode
    except Exception: return 1
def worlds(): return {w["id"]: w for w in json.load(open(WORLDS, encoding="utf-8"))["worlds"]}
def load():
    try: return json.load(open(CFG))
    except Exception: return {"world": "1_floyd", "style": "win"}
def save(c): os.makedirs(os.path.dirname(CFG), exist_ok=True); json.dump(c, open(CFG, "w"))
def hex2rgb(h): h = h.lstrip("#"); return "%d,%d,%d" % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

def make_scheme(w, out):
    base = None
    for c in ("/usr/share/color-schemes/BreezeDark.colors",):
        if os.path.isfile(c): base = c
    cp = configparser.RawConfigParser(); cp.optionxform = str
    if base: cp.read(base, encoding="utf-8")
    bg, bg2, ac, fg = hex2rgb(w["bg2"]), hex2rgb(w["bg"]), hex2rgb(w["accent"]), hex2rgb(w["fg"])
    for sec in ("Colors:Window", "Colors:Button", "Colors:Tooltip", "Colors:Complementary", "Colors:Header"):
        if not cp.has_section(sec): cp.add_section(sec)
        cp.set(sec, "BackgroundNormal", bg); cp.set(sec, "ForegroundNormal", fg); cp.set(sec, "DecorationFocus", ac); cp.set(sec, "DecorationHover", ac)
    for sec in ("Colors:View",):
        if not cp.has_section(sec): cp.add_section(sec)
        cp.set(sec, "BackgroundNormal", bg2); cp.set(sec, "ForegroundNormal", fg); cp.set(sec, "DecorationFocus", ac); cp.set(sec, "DecorationHover", ac)
    if not cp.has_section("Colors:Selection"): cp.add_section("Colors:Selection")
    cp.set("Colors:Selection", "BackgroundNormal", ac); cp.set("Colors:Selection", "ForegroundNormal", "255,255,255"); cp.set("Colors:Selection", "DecorationFocus", ac)
    if not cp.has_section("General"): cp.add_section("General")
    cp.set("General", "Name", "TONE " + w["name"]); cp.set("General", "ColorScheme", "TONE" + w["id"].replace("_", ""))
    if not cp.has_section("WM"): cp.add_section("WM")
    cp.set("WM", "activeBackground", bg2); cp.set("WM", "activeForeground", fg); cp.set("WM", "inactiveBackground", bg2); cp.set("WM", "inactiveForeground", fg)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f: cp.write(f, space_around_delimiters=False)
    return "TONE" + w["id"].replace("_", "")

def first_wall(wid):
    for d in WPDIRS:
        fs = sorted(glob.glob(os.path.join(d, wid, "*.jpg")) + glob.glob(os.path.join(d, wid, "*.png")))
        if fs: return fs[0]
    return ""

def apply(c):
    W = worlds(); w = W.get(c["world"])
    if not w: print("世界観が見つかりません"); return 2
    name = make_scheme(w, os.path.join(HOME, ".local/share/color-schemes", "%s.colors" % ("TONE" + w["id"].replace("_", ""))))
    sh("plasma-apply-colorscheme", name)
    wp = first_wall(w["id"])
    if wp: sh("plasma-apply-wallpaperimage", wp)
    sh("plasma-apply-lookandfeel", "-a", "jp.tone." + c["style"], "--resetLayout") if c.get("relayout") else None
    sh("/usr/local/bin/tone-dolphin-profile", c["style"])
    sh("/usr/local/bin/tone-input-apply", c["style"])
    sh("pkexec", "/usr/local/bin/tone-theme-sddm", w["id"])     # ログイン画面も世界観に合わせる(GRUBは触らない)
    print("適用しました: %s / %s風" % (w["name"], "Windows" if c["style"] == "win" else "Mac")); return 0

def main(a):
    if not a: print(__doc__); return 2
    if a[0] == "list":
        for k, w in worlds().items(): print(k, w["name"])
        return 0
    if a[0] == "scheme" and len(a) > 2: print(make_scheme(worlds()[a[1]], a[2])); return 0
    c = load()
    if a[0] == "apply": c["relayout"] = False; return apply(c)
    if a[0] == "style" and len(a) > 1 and a[1] in ("win", "mac"):
        c["style"] = a[1]; c["relayout"] = True; save(dict(c, relayout=False)); return apply(c)
    if a[0] == "set" and len(a) > 1:
        if a[1] not in worlds(): print("世界観IDが違います(list で確認)"); return 2
        c["world"] = a[1]
        if "--style" in a: c["style"] = a[a.index("--style") + 1]; c["relayout"] = True
        else: c["relayout"] = False
        save(dict(c, relayout=False)); return apply(c)
    print(__doc__); return 2
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
__E__
# ログイン画面(SDDM)を世界観に合わせる。管理者権限で動くため、世界観IDは英数字のみ許可し、画像はOS同梱のものだけ使う
W usr/local/bin/tone-theme-sddm 755 <<'__E__'
#!/bin/bash
w=${1:-}; [[ "$w" =~ ^[1-6]_[a-z]+$ ]] || exit 2
img=$(ls /usr/share/tone-os/wallpapers/"$w"/*.jpg 2>/dev/null | sort | head -1); [ -n "$img" ] || exit 0
d=/usr/share/sddm/themes/breeze; [ -d "$d" ] || exit 0
printf '[General]\ntype=image\nbackground=%s\n' "$img" > "$d/theme.conf.user"
exit 0
__E__
W usr/local/bin/tone-theme-gui 755 <<'__E__'
#!/bin/bash
T="世界観とスタイル"
st=$(kdialog --title "$T" --menu "操作の形を選んでください" win "Windows風(エクスプローラーの使い方)" mac "Mac風(Finderの使い方)") || exit 0
mapfile -t L < <(tone-theme list); args=(); for l in "${L[@]}"; do args+=("${l%% *}" "${l#* }"); done
w=$(kdialog --title "$T" --menu "世界観を選んでください(色・壁紙・ログイン画面が変わります)" "${args[@]}") || exit 0
tone-theme set "$w" --style "$st" >/dev/null 2>&1 && kdialog --title "$T" --msgbox "切り替えました。\n一部は、いちど画面から出入りすると反映されます。"
__E__
W usr/share/applications/tone-theme.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=世界観とスタイル
Comment=色・壁紙・ログイン画面と、Windows風/Mac風を切り替えます
Exec=/usr/local/bin/tone-theme-gui
Icon=preferences-desktop-theme
Categories=Settings;
__E__
W etc/xdg/autostart/tone-theme-apply.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE テーマ適用
Exec=/usr/local/bin/tone-input-apply
NoDisplay=true
OnlyShowIn=KDE;
__E__
# Plasma のレイアウト(Windows風 / Mac風)
W usr/share/plasma/look-and-feel/jp.tone.win/metadata.json 644 <<'__E__'
{"KPlugin":{"Id":"jp.tone.win","Name":"TONE Windows風","Description":"下にタスクバー。スタートメニュー","Authors":[{"Name":"TONE OS"}],"Version":"1.0","License":"GPL-2.0+"},"KPackageStructure":"Plasma/LookAndFeel","X-Plasma-APIVersion":"2"}
__E__
W usr/share/plasma/look-and-feel/jp.tone.win/contents/layouts/org.kde.plasma.desktop-layout.js 644 <<'__E__'
var panel = new Panel;
panel.location = "bottom";
panel.height = Math.round(gridUnit * 2.6);
panel.addWidget("org.kde.plasma.kickoff");
panel.addWidget("org.kde.plasma.icontasks");
panel.addWidget("org.kde.plasma.marginsseparator");
panel.addWidget("org.kde.plasma.systemtray");
panel.addWidget("org.kde.plasma.digitalclock");
panel.addWidget("org.kde.plasma.showdesktop");
__E__
W usr/share/plasma/look-and-feel/jp.tone.mac/metadata.json 644 <<'__E__'
{"KPlugin":{"Id":"jp.tone.mac","Name":"TONE Mac風","Description":"上にメニューバー、下にドック","Authors":[{"Name":"TONE OS"}],"Version":"1.0","License":"GPL-2.0+"},"KPackageStructure":"Plasma/LookAndFeel","X-Plasma-APIVersion":"2"}
__E__
W usr/share/plasma/look-and-feel/jp.tone.mac/contents/layouts/org.kde.plasma.desktop-layout.js 644 <<'__E__'
var top = new Panel;
top.location = "top";
top.height = Math.round(gridUnit * 1.7);
top.addWidget("org.kde.plasma.kickoff");
top.addWidget("org.kde.plasma.appmenu");
top.addWidget("org.kde.plasma.panelspacer");
top.addWidget("org.kde.plasma.systemtray");
top.addWidget("org.kde.plasma.digitalclock");
var dock = new Panel;
dock.location = "bottom";
dock.height = Math.round(gridUnit * 3.6);
dock.alignment = "center";
try { dock.minimumLength = gridUnit * 20; dock.maximumLength = gridUnit * 44; } catch (e) {}
dock.addWidget("org.kde.plasma.icontasks");
__E__
# Dolphin(標準のファイルマネージャー)を、Windows風=エクスプローラー、Mac風=Finder の使い方に近づける
W usr/local/bin/tone-dolphin-profile 755 <<'__E__'
#!/bin/bash
# 使い方: tone-dolphin-profile win|mac   (利用者の設定フォルダだけを書き換える。システム全体には広げない)
st=${1:-win}; H=${HOME:?}
RC="$H/.local/share/kxmlgui5/dolphin/dolphinui.rc"
VP="$H/.local/share/dolphin/view_properties/global/.directory"
kw() { command -v kwriteconfig5 >/dev/null && kwriteconfig5 "$@"; }
kw --file "$H/.config/kdeglobals" --group KDE --key SingleClick false      # ダブルクリックで開く(両方)
mkdir -p "$(dirname "$VP")"
# 表示: どちらも「詳細」。DolphinにはFinderの「列表示」が無いため、Macは詳細表示(フォルダーを展開できる)で代用する
printf '[Dolphin]\nVersion=4\nViewMode=2\nSortOrder=0\nSorting=name\nSortFoldersFirst=true\n' > "$VP"
if [ "$st" = mac ]; then
  mkdir -p "$(dirname "$RC")"
  # Command の代わりに Ctrl。Enterで名前の変更、スペースで内容の確認(情報パネル)。Dolphinなど、TONEが整えるアプリだけ
  cat > "$RC" <<'RCEOF'
<!DOCTYPE gui SYSTEM "kpartgui.dtd">
<gui name="dolphin" version="99999">
 <ActionProperties>
  <Action name="rename" shortcut="Return; F2"/>
  <Action name="movetotrash" shortcut="Ctrl+Backspace; Delete"/>
  <Action name="go_up" shortcut="Ctrl+Up; Alt+Up"/>
  <Action name="go_back" shortcut="Ctrl+[; Alt+Left"/>
  <Action name="go_forward" shortcut="Ctrl+]; Alt+Right"/>
  <Action name="show_information_panel" shortcut="Space; F11"/>
 </ActionProperties>
</gui>
RCEOF
else
  rm -f "$RC"       # Windows風はエクスプローラーと同じ標準の割り当て(F2・Delete・Shift+Delete・Alt+矢印)
fi
exit 0
__E__
# スクロールの向き: ホイール付きマウスは従来どおり。タッチパッドだけ、Mac風では自然なスクロール
W usr/local/bin/tone-input-apply 755 <<'__E__'
#!/bin/bash
st=${1:-$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/tone-os/theme.json"))).get("style","win"))' 2>/dev/null || echo win)}
want=0; [ "$st" = mac ] && want=1
if [ -n "${DISPLAY:-}" ] && command -v xinput >/dev/null; then
  for id in $(xinput list --id-only 2>/dev/null); do
    p=$(xinput list-props "$id" 2>/dev/null) || continue
    echo "$p" | grep -q 'libinput Tapping Enabled (' || continue          # タッチパッドだけ
    echo "$p" | grep -q 'libinput Natural Scrolling Enabled (' && xinput set-prop "$id" 'libinput Natural Scrolling Enabled' "$want" 2>/dev/null
  done
fi
if command -v qdbus >/dev/null && [ -n "${WAYLAND_DISPLAY:-}" ]; then
  for d in $(qdbus org.kde.KWin 2>/dev/null | grep '^/org/kde/KWin/InputDevice/event'); do
    [ "$(qdbus org.kde.KWin "$d" org.kde.KWin.InputDevice.touchpad 2>/dev/null)" = true ] && qdbus org.kde.KWin "$d" org.kde.KWin.InputDevice.naturalScroll "$([ $want = 1 ] && echo true || echo false)" >/dev/null 2>&1
  done
fi
exit 0
__E__
# --- 壁紙ギャラリー(Tone21 /tos/wp/ から、選んだ差分だけ取る) ---
W usr/local/bin/tone-wallpaper-gallery 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TONE 壁紙ギャラリー: Tone21 の /tos/wp/ の目録(wp-manifest.json +.sig)を取り、まだ持っていないものをサムネイルで見せ、選んだものだけ取る。
目録は署名付き(OS焼き込みの公開鍵で検証)。JPEG/PNG のみ・サイズ上限あり・ハッシュが合わないものは捨てる。自動で全部は取らない。
目録の形: {"format":1,"wallpapers":[{"world":"1_floyd","file":"1_floyd/7.jpg","thumb":"thumbs/1_floyd/7.jpg","sha256":"..","size":123456,"license":"CC0","author":"..","title":".."}]}
  tone-wallpaper-gallery            画面を開く
  tone-wallpaper-gallery --list     まだ持っていないものを文字で表示
  tone-wallpaper-gallery --get FILE 1枚取る"""
import os, sys, json, hashlib, subprocess, tempfile, urllib.request, urllib.parse, shutil, re
HOME = os.environ.get("HOME", os.path.expanduser("~"))
BASE = os.environ.get("TONE_WP_BASE", "https://updates.example.invalid/tos/wp/")
if not BASE.endswith("/"): BASE += "/"
PUB = os.environ.get("TONE_UPDATE_PUB", "/usr/share/tone-os/keys/update-pub.pem")
DEST = os.environ.get("TONE_WP_DEST", os.path.join(HOME, ".local/share/tone-os/wallpapers"))
MAXB = 15 * 1024 * 1024
def fetch(rel, dest, timeout=30):
    if BASE.startswith(("http://", "https://")):
        req = urllib.request.Request(BASE + urllib.parse.quote(rel), headers={"User-Agent": "TONE-OS-WP/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f: shutil.copyfileobj(r, f)
    else: shutil.copyfile(os.path.join(BASE.replace("file://", ""), rel), dest)
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
def load_manifest():
    t = tempfile.mkdtemp(prefix="tone-wp.")
    try:
        m, g = os.path.join(t, "m.json"), os.path.join(t, "m.sig")
        fetch("wp-manifest.json", m); fetch("wp-manifest.json.sig", g)
        if subprocess.run(["openssl", "dgst", "-sha256", "-verify", PUB, "-signature", g, m], capture_output=True).returncode != 0: return None
        return json.load(open(m, encoding="utf-8"))
    except Exception: return None
    finally: shutil.rmtree(t, ignore_errors=True)
def valid_entry(e):
    f = e.get("file", "")
    return (re.match(r"^[1-6]_[a-z]+/[A-Za-z0-9._-]+\.(jpg|jpeg|png)$", f, re.I) is not None and isinstance(e.get("size"), int)
            and 0 < e["size"] <= MAXB and re.match(r"^[0-9a-f]{64}$", e.get("sha256", "")) is not None
            and e.get("license") in ("CC0", "PD", "OWN"))
def missing(man):
    have = set()
    for dp, _, fs in os.walk(DEST):
        for f in fs: have.add(sha(os.path.join(dp, f)))
    return [e for e in man.get("wallpapers", []) if valid_entry(e) and e["sha256"] not in have]
def get(e):
    dst = os.path.join(DEST, e["file"]); os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".part"; fetch(e["file"], tmp)
    if os.path.getsize(tmp) > MAXB or sha(tmp) != e["sha256"]: os.remove(tmp); return False   # 合わないものは捨てる
    os.replace(tmp, dst); return True
def gui(man):
    from PyQt5 import QtWidgets, QtGui, QtCore
    app = QtWidgets.QApplication(sys.argv); w = QtWidgets.QWidget(); w.setWindowTitle("壁紙ギャラリー"); lay = QtWidgets.QVBoxLayout(w)
    lst = QtWidgets.QListWidget(); lst.setViewMode(QtWidgets.QListView.IconMode); lst.setIconSize(QtCore.QSize(220, 124)); lst.setResizeMode(QtWidgets.QListView.Adjust); lst.setSpacing(8)
    new = missing(man)
    if not new: lay.addWidget(QtWidgets.QLabel("新しい壁紙はありません。")); w.resize(420, 120); w.show(); return app.exec_()
    t = tempfile.mkdtemp(prefix="tone-wp-th.")
    for i, e in enumerate(new):
        it = QtWidgets.QListWidgetItem("%s\n%s" % (e.get("title", e["file"]), e.get("author", ""))); it.setFlags(it.flags() | QtCore.Qt.ItemIsUserCheckable); it.setCheckState(QtCore.Qt.Unchecked); it.setData(QtCore.Qt.UserRole, e)
        try:
            tp = os.path.join(t, "%d.jpg" % i); fetch(e.get("thumb", ""), tp, 15); it.setIcon(QtGui.QIcon(tp))
        except Exception: pass
        lst.addItem(it)
    btn = QtWidgets.QPushButton("選んだ壁紙をダウンロード"); lay.addWidget(QtWidgets.QLabel("気に入ったものにチェックを入れてください(自動では取りません)。")); lay.addWidget(lst); lay.addWidget(btn)
    def go():
        ok = 0
        for i in range(lst.count()):
            it = lst.item(i)
            if it.checkState() == QtCore.Qt.Checked:
                try: ok += 1 if get(it.data(QtCore.Qt.UserRole)) else 0
                except Exception: pass
        QtWidgets.QMessageBox.information(w, "壁紙ギャラリー", "%d枚を保存しました。" % ok); w.close()
    btn.clicked.connect(go); w.resize(820, 560); w.show(); return app.exec_()
def main(a):
    man = load_manifest()
    if man is None:
        if not a: print("いまは壁紙の一覧を取得できませんでした。"); 
        return 1
    if a[:1] == ["--list"]:
        for e in missing(man): print(e["file"], e.get("title", ""), e.get("license"))
        return 0
    if a[:1] == ["--get"] and len(a) > 1:
        for e in missing(man):
            if e["file"] == a[1]: return 0 if get(e) else 1
        return 1
    return gui(man)
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
__E__
W usr/share/applications/tone-wallpaper-gallery.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=壁紙ギャラリー
Comment=新しい壁紙を見て、好きなものだけ取り込みます
Exec=/usr/local/bin/tone-wallpaper-gallery
Icon=preferences-desktop-wallpaper
Categories=Settings;
__E__
# ===== USB ISO 書き込み・初期化ツール(標準アプリ) =======================
# 元: USB_ISO_Flash_Manager_GUI v2.0.0 の本体を土台に、強制真っ白・書き込み前消去・検証・候補の絞り込みを追加
W usr/local/lib/tone-usb/usb-root 755 <<'__E__'
#!/bin/bash
# 管理者権限で動く部分。対象は引数で渡す(ファイル名の引用符問題が起きない)。
#   usb-root flash ISO DEV SIZE_BYTES SERIAL            書き込み前に簡易消去→dd→SHA-256で検証
#   usb-root wipe  DEV quick|full SIZE_BYTES SERIAL [any]   強制真っ白(any = USBではない内蔵ディスクも許す。画面側で全体名の入力確認済みのとき)
# 守り: いま動いているシステム(/ /boot /boot/efi /usr /var とライブ媒体)を支えるディスクと、ISOが入っているディスクは、何があっても受け付けない。
#       選んだ後に入れ替わっていないか調べ直す。強制: 使用中でも外し、書き込み禁止の表示は解除を試し、消えたかを読み直して確かめる。
set -u
act=${1:-}; shift || true
test_mode=${TONE_USB_TEST:-}
# 文言は出さない。「@@コード|値|値」だけを出し、表示は画面側が言語ファイルで翻訳する(rootの処理に言語ファイルを読み込ませないため)
die() { echo "@@$1" >&2; exit "${2:-1}"; }
msg() { echo "@@$1"; }
disks_of() { lsblk -slnpo NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print $1}'; }
src_of() { findmnt -n -o SOURCE "$@" 2>/dev/null | sed 's/\[.*//' | head -1; }
sysdisks() { local mp s; for mp in / /boot /boot/efi /usr /var /cdrom /run/live/medium /isodevice; do s=$(src_of "$mp"); [ -n "$s" ] && disks_of "$s"; done | sort -u; }
usbish() { local d=$1 rm tran hp; rm=$(lsblk -dnno RM "$d" 2>/dev/null); tran=$(lsblk -dnno TRAN "$d" 2>/dev/null); hp=$(lsblk -dnno HOTPLUG "$d" 2>/dev/null)
  if [ "$rm" = 1 ] || [ "$tran" = usb ] || [ "$hp" = 1 ]; then return 0; fi
  case "$d" in /dev/mmcblk*) return 0;; esac; return 1; }
check_target() { # DEV SIZE SERIAL ISO ANY
  local dev=$1 size=$2 serial=$3 iso=${4:-} any=${5:-}
  if [ ! -b "$dev" ]; then   # テスト専用(TONE_USB_TEST=1)のときだけ、通常ファイルを対象にできる
    [ -n "$test_mode" ] && [ -f "$dev" ] || {
      if [ -e "$dev" ]; then die "E_PLAINFILE|$dev" 3
      else die "E_NODEV|$dev" 3; fi; }
    [ "$(stat -c %s "$dev")" = "$size" ] || die "E_SIZECHG" 7
    return 0
  fi
  [ "$(lsblk -dnno TYPE "$dev" 2>/dev/null)" = disk ] || { [ -n "$test_mode" ] && [ "$(lsblk -dnno TYPE "$dev" 2>/dev/null)" = loop ]; } || die "E_NOTDISK|$dev" 3
  if sysdisks | grep -qx "$dev"; then die "E_SYSDISK" 6; fi
  if [ -n "$iso" ]; then local id; id=$(src_of -T "$iso"); [ -z "$id" ] || ! disks_of "$id" | grep -qx "$dev" || die "E_ISODISK" 6; fi
  if [ "$any" != any ] && [ -z "$test_mode" ]; then usbish "$dev" || die "E_NOTUSB|$dev" 6; fi
  [ "$(blockdev --getsize64 "$dev" 2>/dev/null)" = "$size" ] || die "E_SIZECHG" 7
  [ "$(lsblk -dnno SERIAL "$dev" 2>/dev/null)" = "$serial" ] || die "E_SERIALCHG" 7
}
# 自分(と、この処理を起動した親: 画面・端末)は、何があっても終了させない
ancestors() { local p=$$ q; while [ -n "$p" ] && [ "$p" -gt 1 ]; do echo "$p"; q=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null); [ "$q" = "$p" ] && break; p=$q; done; }
kill_users() { # マウント先を使っているプロセスを、止められるものだけ止める(終了を頼み、残れば強制)
  local mp=$1 pid comm keep sig
  keep=" $(ancestors | tr '\n' ' ')$PPID "
  for sig in TERM KILL; do
    for pid in $(fuser -m "$mp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$'); do
      case "$keep" in *" $pid "*) continue;; esac
      comm=$(cat "/proc/$pid/comm" 2>/dev/null)
      case "$comm" in tone-usb-flash|zenity|kdialog|pkexec|polkit*|Xorg|Xwayland|gnome-shell|plasmashell|kwin*|systemd|sddm*|gdm*|lightdm|login) continue;; esac
      kill -"$sig" "$pid" 2>/dev/null
    done
    sleep 1
  done
}
# 強制解放: スワップ・暗号化/LVM/RAID・マウントを、使っているものごと外す(外せなくても先へ進み、最後に消えたかを確かめる)
force_release() {
  local dev=$1 p t mp
  [ -b "$dev" ] || return 0
  while read -r p; do grep -q "^$p " /proc/swaps 2>/dev/null && swapoff "$p" 2>/dev/null; done < <(lsblk -lnpo NAME "$dev" 2>/dev/null)
  while read -r p; do
    findmnt -rn -S "$p" -o TARGET 2>/dev/null | while IFS= read -r mp; do
      mp=$(printf '%b' "$mp")
      umount "$mp" 2>/dev/null || { kill_users "$mp"; umount -f "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true; }
    done
  done < <(lsblk -lnpo NAME "$dev" 2>/dev/null | tac)
  while read -r p t; do
    case "$t" in
      crypt) cryptsetup close "$p" 2>/dev/null || dmsetup remove -f "$p" 2>/dev/null || true;;
      lvm|dm) dmsetup remove -f "$p" 2>/dev/null || true;;
      raid*) mdadm --stop "$p" 2>/dev/null || true;;
    esac
  done < <(lsblk -lnpo NAME,TYPE "$dev" 2>/dev/null | tac)
  sync; udevadm settle >/dev/null 2>&1 || true
}
# 書き込み可能にする。カーネルは、開いているパーティション(マウント中など)があると読み取り専用の解除を断るので、必ず force_release のあとに呼ぶ
make_writable() {
  local dev=$1 b sysb=${TONE_SYSBLOCK:-/sys/block}
  [ -b "$dev" ] || [ -n "${TONE_SYSBLOCK:-}" ] || return 0
  b=$(basename "$dev")
  ro() { cat "$sysb/$b/ro" 2>/dev/null; }
  for _ in 1 2 3; do
    [ "$(ro)" = 0 ] && return 0
    blockdev --setrw "$dev" >/dev/null 2>&1 || true; sleep 1
  done
  [ "$(ro)" = 0 ] && return 0
  # それでも駄目なら、機器の状態を読み直させて(書き込み禁止の表示を再確認)、もう一度解除する
  [ -w "$sysb/$b/device/rescan" ] && echo 1 > "$sysb/$b/device/rescan" 2>/dev/null; sleep 2
  for _ in 1 2; do blockdev --setrw "$dev" >/dev/null 2>&1 || true; sleep 1; [ "$(ro)" = 0 ] && return 0; done
  local why; why=$(dmesg 2>/dev/null | grep -i "\[$b\].*Write Protect is" | tail -n 1)
  die "E_ROSTUCK|${why:-}|$dev" 4
}
blank_ends() { # 先頭と末尾の4MiB(小さい物は1MiB)がすべてゼロか
  local dev=$1 size n; size=$(blockdev --getsize64 "$dev" 2>/dev/null || stat -c %s "$dev"); n=4194304; [ "$size" -lt 16777216 ] && n=1048576
  [ "$(head -c $n "$dev" 2>/dev/null | tr -d '\0' | wc -c)" = 0 ] && [ "$(tail -c $n "$dev" 2>/dev/null | tr -d '\0' | wc -c)" = 0 ]
}
# デバイスの実体(/dev の名前)が一瞬消えることがある(USBの再認識)。戻るまで待ち、戻らなければ書かずに止める
wait_node() {
  local dev=$1
  [ -n "$test_mode" ] && [ ! -b "$dev" ] && return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -b "$dev" ] && return 0; udevadm settle >/dev/null 2>&1 || true; sleep 1; done
  udevadm trigger --subsystem-match=block --action=add >/dev/null 2>&1 || true; udevadm settle >/dev/null 2>&1 || true; sleep 2
  [ -b "$dev" ] || die "E_GONE|$dev" 10
}
quick_wipe() { # 署名・パーティション表・先頭と末尾をゼロ埋め(消えていなければ直接書き込みでやり直す)
  local dev=$1 size mb tail_off; size=$(blockdev --getsize64 "$dev" 2>/dev/null || stat -c %s "$dev")
  mb=4; [ "$size" -lt 16777216 ] && mb=1
  wipefs -a -f "$dev" >/dev/null 2>&1 || true
  command -v sgdisk >/dev/null && sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
  for _ in 1 2; do
    wait_node "$dev"
    dd if=/dev/zero of="$dev" bs=1M count=$mb conv=nocreat,fsync,notrunc status=none 2>/dev/null
    tail_off=$(( size / 1048576 - mb )); [ "$tail_off" -gt 0 ] && dd if=/dev/zero of="$dev" bs=1M seek="$tail_off" count=$mb conv=nocreat,fsync,notrunc status=none 2>/dev/null
    sync; blockdev --flushbufs "$dev" >/dev/null 2>&1 || true
    blank_ends "$dev" && break
    [ -b "$dev" ] && { force_release "$dev"; wipefs -a -f "$dev" >/dev/null 2>&1 || true; }
  done
  blockdev --rereadpt "$dev" >/dev/null 2>&1 || true; udevadm settle >/dev/null 2>&1 || true
}
# ISOの隣の .sha256(または SHA256SUMS)があれば、書く前に照合する。無ければ何もしない
iso_check() {
  local iso=$1 d f want have base; d=$(dirname "$iso"); base=$(basename "$iso")
  for f in "$iso.sha256" "$iso.sha256sum" "${iso%.*}.sha256" "$d/SHA256SUMS"; do
    [ -r "$f" ] || continue
    want=$(grep -F "$base" "$f" 2>/dev/null | head -n 1 | awk '{print $1}')
    [ -z "$want" ] && [ "$(wc -l < "$f")" -le 1 ] && want=$(awk '{print $1}' "$f" | head -n 1)
    [ -n "$want" ] || continue
    msg "M_ISOCHK|${f##*/}"; have=$(sha256sum < "$iso" | cut -d' ' -f1)
    [ "$want" = "$have" ] || die "E_ISOBAD|${f##*/}" 3
    msg "M_ISOOK"; return 0
  done
  msg "M_ISONOCHK"
}
eject_dev() { # 安全な取り外し(電源も落とす)。できなくても失敗にはしない
  local dev=$1
  sync; force_release "$dev" >/dev/null 2>&1 || true
  [ -b "$dev" ] || { msg "M_SYNCED"; return 0; }
  if command -v udisksctl >/dev/null 2>&1 && udisksctl power-off -b "$dev" >/dev/null 2>&1; then msg "M_EJECTED_OFF"
  elif command -v eject >/dev/null 2>&1 && eject "$dev" >/dev/null 2>&1; then msg "M_EJECTED"
  else msg "M_EJECT_MANUAL"; fi
}
case "$act" in
  flash)
    iso=${1:-}; dev=${2:-}; size=${3:-}; serial=${4:-}; shift 4 2>/dev/null || true; opts=" $* "
    [ -n "$iso" ] && [ -n "$dev" ] && [ -n "$size" ] || die "E_NOARGS3|$iso|$dev|$size" 2
    [ "$serial" = - ] && serial=""
    [ -r "$iso" ] && [ -s "$iso" ] || die "E_ISOREAD|$iso" 2
    check_target "$dev" "$size" "$serial" "$iso" ""
    msg "M_S1"; iso_check "$iso"
    msg "M_S2"; force_release "$dev"; make_writable "$dev"; sync
    msg "M_S3"; quick_wipe "$dev"
    case "$opts" in *" full "*) msg "M_FULL"; blkdiscard -z -f "$dev" >/dev/null 2>&1 || blkdiscard -z "$dev" >/dev/null 2>&1 || dd if=/dev/zero of="$dev" bs=4M iflag=count_bytes count="$size" conv=nocreat,fsync,notrunc status=none 2>/dev/null || true; sync;; esac
    msg "M_S4"; wait_node "$dev"
    dd if="$iso" of="$dev" bs=4M conv=nocreat,fsync,notrunc status=progress 2>&1 | tr '\r' '\n'; [ "${PIPESTATUS[0]}" = 0 ] || die "E_WRITEFAIL" 11
    wait_node "$dev"
    sync; blockdev --rereadpt "$dev" >/dev/null 2>&1 || true; udevadm settle >/dev/null 2>&1 || true
    n=$(stat -c %s "$iso"); msg "M_S5"
    a=$(sha256sum < "$iso" | cut -d' ' -f1); b=$(head -c "$n" "$dev" | sha256sum | cut -d' ' -f1)
    [ "$a" = "$b" ] || die "E_VERIFY" 8
    msg "M_VERIFIED|$a"
    case "$opts" in *" eject "*) eject_dev "$dev";; esac ;;
  wipe)
    dev=${1:-}; level=${2:-quick}; size=${3:-}; serial=${4:-}; any=${5:-}
    [ -n "$dev" ] && [ -n "$size" ] || die "E_NOARGS2|$dev|$size" 2
    [ "$serial" = - ] && serial=""
    check_target "$dev" "$size" "$serial" "" "$any"
    msg "M_WIPE_REL"; force_release "$dev"; make_writable "$dev"
    msg "M_WIPE_ERASE"; quick_wipe "$dev"
    if [ "$level" = full ]; then
      msg "M_WIPE_FULL"
      blkdiscard -z -f "$dev" >/dev/null 2>&1 || blkdiscard -z "$dev" >/dev/null 2>&1 || dd if=/dev/zero of="$dev" bs=4M iflag=count_bytes count="$size" conv=nocreat,fsync,notrunc status=progress 2>&1 | tr '\r' '\n' || true
      sync
    fi
    [ -z "$(wipefs "$dev" 2>/dev/null)" ] || die "E_SIGLEFT" 9
    blank_ends "$dev" || die "E_DATALEFT" 9
    msg "M_WIPED" ;;
  eject) eject_dev "${1:?}" ;;   # 検査用
  isocheck) iso_check "${1:?}" ;;   # 検査用
  makewritable) make_writable "${1:?}" ;;   # 検査用
  killusers) kill_users "${1:?}" ;;   # 検査用
  ancestors) ancestors ;;   # 検査用
  sysdisks) sysdisks ;;   # 検査用: いま動いているシステムを支えるディスクの一覧
  *) die "E_USAGE" 2 ;;
esac
__E__
W usr/local/bin/tone-usb-flash 755 <<'__E__'
#!/bin/bash
# TONE USB 書き込み・初期化(KDE標準の kdialog を優先。zenity は予備)
APP="TONE USB Tool"; ROOT_HELPER=/usr/local/lib/tone-usb/usb-root
GUI=""; for t in kdialog zenity; do command -v $t >/dev/null 2>&1 && { GUI=$t; break; }; done
[ -n "$GUI" ] || { echo "kdialog or zenity is required / kdialog か zenity が必要です" >&2; exit 1; }
err() { if [ $GUI = kdialog ]; then kdialog --title "$APP" --error "$1"; else zenity --error --title="$APP" --text="$1"; fi; }
info() { if [ $GUI = kdialog ]; then kdialog --title "$APP" --msgbox "$1"; else zenity --info --title="$APP" --text="$1"; fi; }
yn() { if [ $GUI = kdialog ]; then kdialog --title "$APP" --warningyesno "$1"; else zenity --question --title="$APP" --text="$1"; fi; }
ask() { if [ $GUI = kdialog ]; then kdialog --title "$APP" --inputbox "$1"; else zenity --entry --title="$APP" --text="$1"; fi; }
# ---- 言語: 言語ファイル(key=value)をデータとして読む。実行はしない。足りない文言は英語で補う ----
declare -A TL
load_lang() { # 1ファイル読む(コメントと不正な行は飛ばす)
  local f=$1 line k v; [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    k=${line%%=*}; v=${line#*=}; case "$k" in ''|*[!A-Za-z0-9_]*) continue;; esac
    v=${v//\\n/$'\n'}; TL[$k]=$v
  done < "$f"
}
SELF_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
LANG_DIRS=("${TONE_LANG_DIR:-}" "$SELF_DIR/../share/tone-usb/lang" /usr/local/share/tone-usb/lang /usr/share/tone-usb/lang "$HOME/.config/tone-usb/lang")
pick_lang() { # 環境の言語 (ja_JP.UTF-8 → ja_JP → ja)。分からなければ英語
  # 優先順: 環境変数 TONE_LANG → 設定ファイル ~/.config/tone-usb/language (中身は ja や en) → 環境の言語
  local cfg="" f="$HOME/.config/tone-usb/language"; [ -r "$f" ] && cfg=$(head -n 1 "$f" | tr -dc 'A-Za-z_')
  local raw=${TONE_LANG:-${cfg:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}}; raw=${raw%%.*}; raw=${raw%%@*}
  case "$raw" in ''|C|POSIX) echo en;; *) echo "$raw";; esac
}
load_all_lang() {
  local d want base; want=$(pick_lang); base=${want%%_*}
  for d in "${LANG_DIRS[@]}"; do [ -n "$d" ] && load_lang "$d/en.lang"; done
  [ "$base" = en ] && return 0
  for d in "${LANG_DIRS[@]}"; do [ -n "$d" ] || continue; load_lang "$d/$base.lang"; [ "$want" != "$base" ] && load_lang "$d/$want.lang"; done
}
load_all_lang
t() { # t キー 値1 値2 …  (%1 %2 … に差し込む)
  local k=$1 v i=1 a pat; shift; v=${TL[$k]-}; [ -n "$v" ] || v=$k
  for a in "$@"; do pat="%$i"; v=${v//"$pat"/"$a"}; i=$((i+1)); done
  printf '%s' "$v"
}
tlog() { # root側の「@@コード|値…」を翻訳して表示する。それ以外の行(dd の進み具合など)はそのまま
  local l P
  while IFS= read -r l; do
    case "$l" in
      @@*) IFS='|' read -r -a P <<<"${l#@@}"; [ "${P[0]}" = E_ROSTUCK ] && [ -z "${P[1]:-}" ] && P[1]=$(t ro_none); t "${P[@]}"; printf '\n';;
      *) printf '%s\n' "$l";;
    esac
  done
}
ADV=0; [ -f "$HOME/.config/tone-os/usb-advanced" ] && ADV=1
cd / || true   # 作業フォルダがUSBの中だと、USBを外すときに巻き込まれる
ISO=${1:-}
disks_of() { lsblk -slnpo NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print $1}'; }
src_of() { findmnt -n -o SOURCE "$@" 2>/dev/null | sed 's/\[.*//' | head -1; }
# いま動いているシステムを支えるディスク(起動ディスク・ライブ媒体)。これだけは、どの操作でも出さない
SYS=$(for mp in / /boot /boot/efi /usr /var /cdrom /run/live/medium /isodevice; do s=$(src_of "$mp"); [ -n "$s" ] && disks_of "$s"; done | sort -u)
ISOD=""; [ -n "$ISO" ] && { s=$(src_of -T "$ISO"); [ -n "$s" ] && ISOD=$(disks_of "$s"); }
key() { printf '%s\n' "$2" | sed -n "s/.*\b$1=\"\([^\"]*\)\".*/\1/p"; }   # evalを使わずに値を取り出す
# 全ディスクを調べ、1行ずつ  デバイス|容量|型番|シリアル|接続|種別|除外理由  で出す
#   種別: usb=USB/SD/リムーバブル  hdd=容量500GB以上でUSB接続の回転式(外付けHDD)  int=それ以外(内蔵)
#   ※ USBメモリが「回転式」と報告されることは普通にあるので、回転式だけでは外さない
scan() {
  lsblk -bdnP -o KNAME,TYPE,SIZE,RM,TRAN,MODEL,ROTA,SERIAL,HOTPLUG 2>/dev/null | while IFS= read -r l; do
    kn=$(key KNAME "$l"); ty=$(key TYPE "$l"); by=$(key SIZE "$l"); rmv=$(key RM "$l"); tr=$(key TRAN "$l")
    md=$(key MODEL "$l"); ro=$(key ROTA "$l"); sr=$(key SERIAL "$l"); hp=$(key HOTPLUG "$l"); dv="/dev/$kn"
    [ "$ty" = disk ] || continue
    [ "${by:-0}" -gt 0 ] 2>/dev/null || continue; [[ $kn == zram* ]] && continue   # 容量0・圧縮メモリは対象外
    szh=$(numfmt --to=iec "${by:-0}" 2>/dev/null || echo "${by}B")
    kind=int
    if [ "$rmv" = 1 ] || [ "$tr" = usb ] || [ "$hp" = 1 ] || [[ $kn == mmcblk* ]]; then
      kind=usb; [ "$ro" = 1 ] && [ "${by:-0}" -ge 500000000000 ] && kind=hdd
    fi
    why=""
    printf '%s\n' "$SYS" | grep -qx "$dv" && why=$(t why_system)
    [ -z "$why" ] && [ -n "$ISOD" ] && printf '%s\n' "$ISOD" | grep -qx "$dv" && why=$(t why_isodisk)
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$dv" "$szh" "${md:-}" "$sr" "${tr:--}" "$kind" "$why" "$by"
  done
}
pick() { # $1: flash | wipe | all
  scan | while IFS= read -r l; do
    IFS='|' read -r p s m sr t kind why bytes <<<"$l"; [ -z "$why" ] || continue
    case "$1:$kind" in flash:usb) ;; flash:hdd) [ "$ADV" = 1 ] || continue;; wipe:usb|wipe:hdd) ;; all:*) ;; *) continue;; esac
    printf '%s\n' "$l"
  done
}
explain() { # 見つかったディスクと、候補にならなかった理由
  scan | while IFS='|' read -r p s m sr t kind why bytes; do
    if [ -n "$why" ]; then r=$(t exp_excluded "$why")
    elif [ "$kind" = int ]; then r=$(t exp_notusb)
    elif [ "$kind" = hdd ]; then r=$(t exp_bighdd)
    else r=$(t exp_cand); fi
    t exp_line "$p" "$s" "${m:-$(t unknown)}" "$r"; printf '\n'
  done
}
kindname() { case "$1" in usb) t kind_usb;; hdd) t kind_hdd;; *) t kind_int;; esac; }
MC=$(t menu_combo); MF=$(t menu_flash); MW=$(t menu_wipe)
mode=$( if [ $GUI = kdialog ]; then kdialog --title "$APP" --menu "$(t menu_title)" combo "$MC" flash "$MF" wipe "$MW"; else zenity --list --title="$APP" --column=id --column="$(t col_op)" --hide-column=1 --print-column=1 combo "$MC" flash "$MF" wipe "$MW"; fi ) || exit 0
COMBO=0; [ "$mode" = combo ] && { COMBO=1; mode=flash; }
if [ "$mode" = flash ] && [ -z "$ISO" ]; then
  if [ $GUI = kdialog ]; then ISO=$(kdialog --getopenfilename "$HOME" "*.iso|$(t iso_filter)" --title "$(t pick_iso)") || exit 0
  else ISO=$(zenity --file-selection --title="$(t pick_iso)" --file-filter='ISO | *.iso') || exit 0; fi
  [ -s "$ISO" ] || { err "$(t iso_unreadable)"; exit 1; }
  case "$ISO" in *.[iI][sS][oO]) ;; *) err "$(t iso_wrong_ext)"; exit 1;; esac
  s=$(src_of -T "$ISO"); ISOD=""; [ -n "$s" ] && ISOD=$(disks_of "$s")
fi
mapfile -t C < <(pick "$mode")
if [ "${#C[@]}" -eq 0 ]; then
  if [ "$mode" = wipe ]; then
    L=$(explain)
    yn "$(t no_usb_wipe "$L")" || exit 0
    mapfile -t C < <(pick all)
    [ "${#C[@]}" -gt 0 ] || { err "$(t no_disks "$L")"; exit 0; }
  else
    err "$(t no_usb_flash "$(explain)")"; exit 0
  fi
fi
args=(); for l in "${C[@]}"; do IFS='|' read -r p s m sr t kind why bytes <<<"$l"; args+=("$p" "$p  $s  ${m:-$(t unknown)}  [$(kindname "$kind")]"); done
if [ $GUI = kdialog ]; then DEV=$(kdialog --title "$APP" --menu "$(t pick_target)" "${args[@]}") || exit 0
else DEV=$(zenity --list --title="$APP" --column=id --column="$(t col_target)" --hide-column=1 --print-column=1 "${args[@]}") || exit 0; fi
line=""; for l in "${C[@]}"; do [ "${l%%|*}" = "$DEV" ] && line=$l; done
[ -n "$line" ] || { err "$(t dev_unconfirmed)"; exit 1; }
IFS='|' read -r p s m SERIAL t KIND why BYTES <<<"$line"
SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || lsblk -bdno SIZE "$DEV")
case "$SIZE" in ''|*[!0-9]*) SIZE=$(lsblk -bdno SIZE "$DEV" 2>/dev/null | head -n 1 | tr -dc 0-9);; esac
case "$SIZE" in ''|0|*[!0-9]*) n=$(cat "/sys/block/${DEV##*/}/size" 2>/dev/null); [ -n "$n" ] && SIZE=$((n*512));; esac
case "$SIZE" in ''|0|*[!0-9]*) SIZE=${BYTES:-};; esac
case "$SIZE" in ''|0) err "$(t size_fail "$DEV")"; exit 1;; esac
SERIAL_ARG=${SERIAL:--}   # pkexec は空の引数を落とすことがあるので、無いときは - を渡す
mkdir -p "$HOME/.cache/tone-os" 2>/dev/null; LOG="$HOME/.cache/tone-os/usb-last.log"; : > "$LOG"
notify() { command -v notify-send >/dev/null 2>&1 && notify-send -i drive-removable-media "$APP" "$1" 2>/dev/null; true; }
WORKPID=""; KREF=""
work_start() { # 処理中の表示(終わるまで出しておく。終わっても何も出ない、を防ぐ)
  notify "$1"
  if [ $GUI = zenity ]; then
    ( n=0; while :; do l=$(tail -n 1 "$LOG" 2>/dev/null | tr -d '\r' | tlog | cut -c1-70); echo "# $(t progress_line "$1" "$n" "$l")"; n=$((n+2)); sleep 2; done ) | zenity --progress --pulsate --no-cancel --title="$APP" --width=480 --text="$1" >/dev/null 2>&1 &
    WORKPID=$!
  else
    KREF=$(kdialog --title "$APP" --progressbar "$(t progress_keep "$1")" 0 2>/dev/null) || KREF=""
  fi
}
work_stop() {
  [ -n "$WORKPID" ] && { kill "$WORKPID" 2>/dev/null; WORKPID=""; }
  if [ -n "$KREF" ]; then
    local qd; for qd in qdbus qdbus6 qdbus-qt5; do command -v $qd >/dev/null 2>&1 && break; qd=""; done
    # shellcheck disable=SC2086
    [ -n "$qd" ] && $qd $KREF close >/dev/null 2>&1; KREF=""
  fi
}
runroot() { work_start "$WORKMSG"; pkexec "$ROOT_HELPER" "$@" >"$LOG" 2>&1; local rc=$?; work_stop; return $rc; }
done_ok() { notify "$1"; info "$1"; }
done_ng() { notify "$(t failed_title)"; err "$(t failed_body "$(tail -n 8 "$LOG" | tlog)" "$LOG")"; }
if [ "$mode" = flash ]; then
  CN=""; [ $COMBO = 1 ] && CN=$(t combo_note)
  yn "$(t flash_confirm "$ISO" "$DEV" "$s" "${m:-$(t unknown)}" "$CN")" || exit 0
  WORKMSG=$(t work_flash); FOPT=()
  [ $COMBO = 1 ] && { FOPT=(full eject); WORKMSG=$(t work_combo); }
  runroot flash "$ISO" "$DEV" "$SIZE" "$SERIAL_ARG" "${FOPT[@]}"; rc=$?
  if [ $rc = 0 ]; then
    if [ $COMBO = 1 ]; then done_ok "$(t combo_done "$(grep -E '^@@M_(EJECTED|SYNCED|EJECT_MANUAL)' "$LOG" | tail -n 1 | tlog)")"
    else done_ok "$(t flash_done)"; fi
  else done_ng; fi
else
  QK=$(t how_quick); QF=$(t how_full)
  lv=$( if [ $GUI = kdialog ]; then kdialog --title "$APP" --menu "$(t wipe_how)" quick "$QK" full "$QF"; else zenity --list --title="$APP" --column=id --column="$(t col_how)" --hide-column=1 --print-column=1 quick "$QK" full "$QF"; fi ) || exit 0
  SRL=$(t serial_label "${SERIAL:-$(t none)}"); MD=${m:-$(t unknown)}
  ANY=""
  if [ "$KIND" = int ]; then   # 内蔵ディスク(USBではない)だけは、取り違えると取り返しがつかないので、デバイス名の全体を入力してもらう
    ANY=any
    ans=$(ask "$(t int_prompt "$DEV" "$s" "$MD" "$SRL")") || exit 0
    [ "$ans" = "$DEV" ] || { err "$(t input_mismatch)"; exit 0; }
  fi
  yn "$(t wipe_confirm "$DEV" "$s" "$MD" "$SRL")" || exit 0
  WORKMSG=$(t work_wipe); [ "$lv" = full ] && WORKMSG=$(t work_wipe_full)
  runroot wipe "$DEV" "$lv" "$SIZE" "$SERIAL_ARG" $ANY; rc=$?
  if [ $rc = 0 ]; then done_ok "$(t wipe_done)"; else done_ng; fi
fi
exit 0
__E__
W usr/local/share/tone-usb/lang/ja.lang 644 <<'__E__'
# TONE USB ツール 日本語  (key=value。\n は改行、%1 %2… は値の差し込み。この形式のファイルは「実行」されず、データとして読むだけです)
lang_name=日本語
unknown=不明
none=なし
menu_title=何をしますか?
menu_combo=全部入り(真っ白→書き込み→検証→取り外し)
menu_flash=ISOをUSBに書き込む
menu_wipe=USBを真っ白にする(強制)
col_op=操作
col_target=対象
col_how=消し方
pick_iso=書き込むISOを選択
iso_filter=ISOファイル (*.iso)
iso_unreadable=ISOファイルを読めません。
iso_wrong_ext=ISOファイル(*.iso)を選んでください。
kind_usb=USB
kind_hdd=USB・外付けHDD
kind_int=内蔵・USBではない
why_system=いま動いているシステムのディスク
why_isodisk=ISOが入っているディスク
exp_line=・%1  %2  %3  → %4
exp_excluded=除外: %1
exp_notusb=USBではない(内蔵)
exp_bighdd=大容量の外付けHDD(書き込みでは隠しています。消去では選べます)
exp_cand=候補
no_usb_wipe=USBとして見つかったディスクがありません。\n\n見つかったディスク:\n%1\n\n内蔵ディスクを含めて、動いているシステム以外のすべてから選びますか?\n(内蔵ディスクを選ぶときは、デバイス名の全体を入力する確認が入ります)
no_disks=選べるディスクがありません。\n\n%1
no_usb_flash=書き込める USB が見つかりませんでした。\n\n見つかったディスク:\n%1
pick_target=対象を選んでください。中のデータは消えます。
dev_unconfirmed=選んだデバイスを確認できません。最初からやり直してください。
size_fail=容量を取得できませんでした: %1\nUSBを挿し直して、もう一度試してください。
progress_keep=%1\n終わるまで抜かないでください。
progress_line=# %1(%2秒) %3
failed_title=失敗しました
failed_body=失敗しました。\n\n%1\n\n(記録: %2)
flash_confirm=ISO:\n%1\n\n書き込み先: %2\n容量: %3 / 型番: %4\n\n選んだUSBのデータは完全に消えます。\n書き込み後に、内容が正しいか確認します。%5\n書き込みを始めますか?
combo_note=\n(全部入り: 完全消去→書き込み→検証→取り外しを続けて行います)
work_flash=ISOをUSBに書き込んでいます(数分かかります)
work_combo=全部入り: 完全消去→書き込み→検証→取り外し(時間がかかります)
flash_done=書き込みと検証が終わりました(検証済み)。\n安全に取り外してください。
combo_done=全部入り完了: 真っ白→書き込み→検証済み。\n%1\nUSBを抜いて使えます。
wipe_how=消し方を選んでください
how_quick=かんたん消去(数秒)
how_full=完全消去(時間がかかります)
serial_label=シリアル:%1
int_prompt=【強制真っ白】★内蔵ディスクです。パソコンのデータが入っている可能性があります。\n%1  %2  %3  %4\n\n中のすべてのデータが消えます。実行するには、デバイス名の全体「%1」を入力してください。
input_mismatch=入力が違うため、中止しました。
wipe_confirm=【強制真っ白】\n%1  %2  %3  %4\n\n中のすべてのデータとパーティションが消えます。使用中でも、強制的に外して消します。\n元には戻せません。真っ白にしますか?
work_wipe=真っ白にしています
work_wipe_full=完全消去しています(容量によっては数十分かかります)
wipe_done=真っ白になりました。
ro_none=カーネルの記録なし
E_PLAINFILE=%1 はUSBの実体ではなく、普通のファイルになっています(前回の失敗の残りです)。次を実行してUSBを挿し直してください: sudo rm -f %1 %1[0-9]*
E_NODEV=対象デバイスが見つかりません: %1(USBが再認識中か、外れています。挿し直してください)
E_SIZECHG=選んだ後に、デバイスの容量が変わりました(入れ替わった可能性)
E_NOTDISK=ディスクではありません: %1
E_SYSDISK=いま動いているシステム(または起動に使っている媒体)のディスクです。これだけは消せません
E_ISODISK=ISOが入っているディスクは選べません
E_NOTUSB=USB/リムーバブルではないため、受け付けません: %1
E_SERIALCHG=選んだ後に、デバイスのシリアルが変わりました(入れ替わった可能性)
E_ROSTUCK=読み取り専用のままです。機器が書き込み禁止だと答えています(%1)。USB本体に書き込み禁止スイッチがあれば解除し、USBを抜いて別の口(USB2.0の口がおすすめ)に挿し直してください: %2
E_GONE=デバイスが見えなくなりました(%1)。USBを挿し直してもう一度試してください。何も書いていません
E_ISOBAD=ISOが壊れているか、別のファイルです(照合に失敗: %1)。書き込みを中止しました
E_NOARGS3=引数が足りません(ISO=%1 デバイス=%2 容量=%3)。画面側が容量を取得できていません
E_NOARGS2=引数が足りません(デバイス=%1 容量=%2)。画面側が容量を取得できていません
E_ISOREAD=ISOが読めません: %1
E_WRITEFAIL=書き込みに失敗しました(デバイスが消えた可能性があります)
E_VERIFY=検証に失敗しました(書いた内容がISOと一致しません)
E_SIGLEFT=ファイルシステムの署名が残っています
E_DATALEFT=先頭か末尾にデータが残っています(機器が書き込みを受け付けていない可能性。別のUSB口やケーブルで試してください)
E_USAGE=使い方: usb-root {flash ISO DEV SIZE SERIAL [full] [eject] | wipe DEV quick|full SIZE SERIAL [any]}
M_ISOCHK=ISOの照合中(%1)…
M_ISOOK=ISO照合OK
M_ISONOCHK=ISOの照合ファイルは見つかりません(照合は省略)
M_SYNCED=同期は済みました
M_EJECTED_OFF=取り外せる状態にしました(電源オフ)
M_EJECTED=取り外せる状態にしました
M_EJECT_MANUAL=同期は済みました。表示の「安全に取り外す」を使ってください
M_S1=[1/5] ISOの確認
M_S2=[2/5] 使っているものを外す
M_S3=[3/5] 書き込み前の消去
M_FULL=完全消去中(時間がかかります)…
M_S4=[4/5] 書き込み中…
M_S5=[5/5] 検証中…
M_VERIFIED=検証済み: SHA-256 %1
M_WIPE_REL=強制真っ白: 使っているものを外しています…
M_WIPE_ERASE=強制真っ白: 消去中…
M_WIPE_FULL=完全消去: 全体を消しています(時間がかかります)…
M_WIPED=真っ白になりました。
__E__
W usr/local/share/tone-usb/lang/en.lang 644 <<'__E__'
# TONE USB Tool - English  (key=value. \n = newline, %1 %2 ... = inserted values. Files in this format are read as data and never executed.)
lang_name=English
unknown=unknown
none=none
menu_title=What would you like to do?
menu_combo=All-in-one (wipe → write → verify → eject)
menu_flash=Write an ISO to a USB drive
menu_wipe=Wipe a USB drive (forced)
col_op=Action
col_target=Target
col_how=Method
pick_iso=Select the ISO to write
iso_filter=ISO files (*.iso)
iso_unreadable=Cannot read the ISO file.
iso_wrong_ext=Please choose an ISO file (*.iso).
kind_usb=USB
kind_hdd=USB external HDD
kind_int=Internal / not USB
why_system=disk of the running system
why_isodisk=disk that holds the ISO
exp_line=* %1  %2  %3  → %4
exp_excluded=Excluded: %1
exp_notusb=Not USB (internal)
exp_bighdd=Large external HDD (hidden for writing; selectable for wiping)
exp_cand=Candidate
no_usb_wipe=No USB disk was found.\n\nDisks found:\n%1\n\nDo you want to choose from all disks except the running system, including internal ones?\n(For an internal disk you will have to type the full device name to confirm.)
no_disks=There is no disk to choose.\n\n%1
no_usb_flash=No writable USB drive was found.\n\nDisks found:\n%1
pick_target=Choose the target. All data on it will be erased.
dev_unconfirmed=Cannot confirm the selected device. Please start over.
size_fail=Could not read the capacity of %1.\nPlease re-plug the USB drive and try again.
progress_keep=%1\nDo not unplug it until this finishes.
progress_line=# %1 (%2 s) %3
failed_title=Failed
failed_body=Failed.\n\n%1\n\n(Log: %2)
flash_confirm=ISO:\n%1\n\nTarget: %2\nSize: %3 / Model: %4\n\nAll data on the selected USB drive will be erased.\nThe written data will be verified afterwards.%5\nStart writing?
combo_note=\n(All-in-one: full wipe → write → verify → eject, in one go)
work_flash=Writing the ISO to the USB drive (takes a few minutes)
work_combo=All-in-one: full wipe → write → verify → eject (takes a while)
flash_done=Written and verified (verified).\nYou can remove the drive safely.
combo_done=All-in-one finished: wiped → written → verified.\n%1\nYou can unplug the USB drive now.
wipe_how=Choose how to erase
how_quick=Quick erase (a few seconds)
how_full=Full erase (takes a long time)
serial_label=Serial: %1
int_prompt=[FORCED WIPE] ★ This is an INTERNAL disk. It may contain your computer's data.\n%1  %2  %3  %4\n\nEverything on it will be erased. To continue, type the full device name "%1".
input_mismatch=The input did not match. Cancelled.
wipe_confirm=[FORCED WIPE]\n%1  %2  %3  %4\n\nAll data and partitions on it will be erased. Anything using it will be forcibly detached.\nThis cannot be undone. Wipe it?
work_wipe=Wiping
work_wipe_full=Fully erasing (may take tens of minutes depending on size)
wipe_done=The drive is now blank.
ro_none=no kernel record
E_PLAINFILE=%1 is not a real device but a plain file (a leftover of an earlier failure). Run this and re-plug the USB drive: sudo rm -f %1 %1[0-9]*
E_NODEV=Device not found: %1 (the USB drive may be re-enumerating or unplugged; please re-plug it)
E_SIZECHG=The device capacity changed after you chose it (it may have been swapped)
E_NOTDISK=Not a disk: %1
E_SYSDISK=This is the disk of the running system (or the boot medium). It can never be erased
E_ISODISK=The disk that holds the ISO cannot be chosen
E_NOTUSB=Not a USB/removable device, refused: %1
E_SERIALCHG=The device serial changed after you chose it (it may have been swapped)
E_ROSTUCK=Still read-only. The device reports it is write-protected (%1). If the drive has a write-protect switch, turn it off, then unplug it and re-plug into another port (a USB 2.0 port is recommended): %2
E_GONE=The device disappeared (%1). Re-plug the USB drive and try again. Nothing was written
E_ISOBAD=The ISO is corrupted or a different file (checksum mismatch: %1). Writing was cancelled
E_NOARGS3=Missing arguments (ISO=%1 device=%2 size=%3). The front end could not read the capacity
E_NOARGS2=Missing arguments (device=%1 size=%2). The front end could not read the capacity
E_ISOREAD=Cannot read the ISO: %1
E_WRITEFAIL=Writing failed (the device may have disappeared)
E_VERIFY=Verification failed (what was written does not match the ISO)
E_SIGLEFT=A filesystem signature is still present
E_DATALEFT=Data remains at the start or end (the device may not be accepting writes; try another USB port or cable)
E_USAGE=Usage: usb-root {flash ISO DEV SIZE SERIAL [full] [eject] | wipe DEV quick|full SIZE SERIAL [any]}
M_ISOCHK=Checking the ISO checksum (%1)…
M_ISOOK=ISO checksum OK
M_ISONOCHK=No checksum file found for the ISO (check skipped)
M_SYNCED=Synced
M_EJECTED_OFF=Ready to unplug (powered off)
M_EJECTED=Ready to unplug
M_EJECT_MANUAL=Synced. Please use "Safely remove" in your desktop
M_S1=[1/5] Checking the ISO
M_S2=[2/5] Detaching anything using the drive
M_S3=[3/5] Erasing before writing
M_FULL=Full erase in progress (takes a while)…
M_S4=[4/5] Writing…
M_S5=[5/5] Verifying…
M_VERIFIED=Verified: SHA-256 %1
M_WIPE_REL=Forced wipe: detaching anything using the drive…
M_WIPE_ERASE=Forced wipe: erasing…
M_WIPE_FULL=Full erase: erasing everything (takes a while)…
M_WIPED=The drive is now blank.
__E__
W usr/share/applications/tone-usb-flash.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE USB Tool
Name[ja]=TONE USB ツール
Comment=Write an ISO to USB / wipe a USB drive
Comment[ja]=ISOをUSBに書き込む/USBを真っ白にする
Exec=/usr/local/bin/tone-usb-flash %f
Icon=tone-usb-flash
MimeType=application/x-cd-image;
Categories=System;Utility;
__E__
WB usr/share/icons/hicolor/256x256/apps/tone-usb-flash.png 644 <<'__E__'
iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAMAAABrrFhUAAACOlBMVEUAAADW2NzY2N3SyNLN0tvE
xs3HytXW2uN7gYyFhYqGiZVsdYJNUVtBRVFUWWiYoqvb4urHxst1eoVqcXw9QU0+RFBAQ06WmqXj
5uu1uMS1s7unq7hgY2txdH1lanY3OkZMVGaLkZzw7fKrsbtcYWvh3uOmpKq3w8Xn6/EoKzMoN0ox
Mz0tMTrO1+Hn9/h9hZKntML7/Pybp7WIlabGusjLvMy9rsC0rbzRxMtRVF3Etbuyy9HBwL+WlJpT
cJETO2EXSGkRRmpWZotleJMmU3UdUXQbTXFohJtwkKp3q8lsprNomrjI7/a35vpJZHkjSWum3PJJ
Z4ep4/qu6O2RzdCLt8yMzeyW1PGj3O5pwWh4xayDvuBXhJwyU2syVHnX9/iV0+1/zchVuTVfu1pS
jLGKrLmLzfBdwTxaY3S22+low06o8Hc6ZYiu3qBJdpknQlm47eUdKTsiIykXFxwcHCHV+esnTHIe
ICQxXITJ9ee27d248ONMe6MTLVAgHiSmrsG38N4xZ5FQS1BJYIRJi7U2dKqRjI2VjJZPWnCil55y
bXeIlrCCe4kQFTUHBwwMDBKoaE2xaDSpUimXSiKaeEU4pO85meQ6kNc2Lyi3TBfBThS7URm4ViOl
ShxDlNPNqp+2jFfzrFH8ulZVRCvGWiH+wVz9xWQ3IhvEVhrMZB78s0xXMiJxUC7fn1T6qUX8ozz6
mDRiXW5JKBprNRv3fSn4hSx8Yjr0ynAlGBXSaiTkbyX4iTGSTi32kS7teL/oAAAAAXRSTlMAQObY
ZgAAM+RJREFUeNrtnYljE9e1/ytZlizJkm1JliUvkjdsC9mxYwzGOIABYyABjFkCadjaBwRSHiGS
QBCoSNqEJU1xmzQrJL++FMKSlPCD0Ibw43/7nXO3uXfmjiSzmKXvYLSMZrnnc7/n3GVGo1/9iphD
Micx8sJR4XK5KiqfUXNj6T1Owwz/HE7HrxSz+E9W9lRWeb0+f/XsWsBueaDM9QNkzUAQyl5VU8sc
FgA4DTMAmY8AUBcKhbzhSCAirD5SXx8IRPAvGilmsKJ5SX09PpBdRNjr4jvQfh7A4+vWrzetXx0K
VYUaCABD1cI/MwBD9ooCCAAgGqhHv3VWzz7BJ/HavE6gtOHmfH+aY9XXmz+gb8ijUQbyQFgE6ikA
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
8MyyIvP8/wM/Yw8p572U8AAAAABJRU5ErkJggg==
__E__
# ===== LibreOffice(公式PPA優先 → だめなら従来のTDF公式deb) =================
W usr/local/bin/tone-lo-update 755 <<'__E__'
#!/bin/bash
# LibreOffice: LibreOffice 公式PPA(ppa:libreoffice/ppa・Fresh)が設定済みならそれで導入/更新。無いときだけ TDF 公式deb(LO_VER)へ。 --force で強制
STATE=/var/lib/tone-os/lo-version; mkdir -p /var/lib/tone-os
if grep -rqs 'ppa.launchpadcontent.net/libreoffice/ppa' /etc/apt/sources.list.d/ 2>/dev/null; then
  apt-get update -qq >/dev/null 2>&1 || true
  if [ "$1" = "--force" ] || ! dpkg -s libreoffice-core 2>/dev/null | grep -q 'ok installed'; then
    apt-get -y install libreoffice libreoffice-l10n-ja libreoffice-help-ja libreoffice-kf5 && ok=1
  else
    apt-get -y install --only-upgrade libreoffice libreoffice-l10n-ja libreoffice-help-ja libreoffice-kf5 && ok=1
  fi
  if [ "${ok:-0}" = 1 ]; then dpkg-query -W -f='${Version}' libreoffice-core > "$STATE" 2>/dev/null; echo "LibreOffice (PPA) $(cat "$STATE")"; exit 0; fi
  echo "PPAからの導入に失敗したため、TDF公式版へ切り替えます"
fi
BASEURL=https://download.documentfoundation.org/libreoffice/stable
want=${LO_VER:-}
if [ -z "$want" ]; then want=$(curl -fsL "$BASEURL/" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+/"' | tr -d '/"' | sort -V | tail -1); fi
[ -n "$want" ] || { echo "LibreOfficeの最新版を取得できません"; exit 0; }
have=$(cat "$STATE" 2>/dev/null || true)
if [ "$1" != "--force" ] && [ "$have" = "$want" ]; then exit 0; fi
if [ "$1" != "--force" ] && [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -1)" = "$have" ]; then exit 0; fi
D=$(mktemp -d); cd "$D" || exit 1
u=$BASEURL/$want/deb/x86_64
ok=1
for f in "LibreOffice_${want}_Linux_x86-64_deb.tar.gz" "LibreOffice_${want}_Linux_x86-64_deb_langpack_ja.tar.gz" "LibreOffice_${want}_Linux_x86-64_deb_helppack_ja.tar.gz"; do
  curl -fL --retry 3 -O "$u/$f" || { echo "取得失敗: $f"; [ "${f##*deb.}" = "tar.gz" ] && ok=0; }
done
if [ "$ok" = 1 ]; then
  for t in *.tar.gz; do tar xf "$t"; done
  apt-get -y purge 'libreoffice*' >/dev/null 2>&1 || true
  for d in LibreOffice_*_deb LibreOffice_*_deb_langpack_ja LibreOffice_*_deb_helppack_ja; do
    [ -d "$d/DEBS" ] || continue
    echo "導入: $d"
    find "$d/DEBS" -name '*.deb' | sort | xargs -r dpkg -i 2>&1 || true
  done
  apt-get -y -f install
  echo "$want" > "$STATE"; echo "LibreOffice $want 導入完了"
else
  echo "公式版($want)を取得できなかったため標準リポジトリ版を導入します"
  apt-get -y install libreoffice libreoffice-l10n-ja libreoffice-help-ja libreoffice-kf5 || true
fi
rm -rf "$D"; exit 0
__E__
W etc/apt/preferences.d/50-tone-libreoffice-ppa 644 <<'__E__'
# 公式PPAは LibreOffice のパッケージにだけ適用し、他のパッケージには一切影響させない
Package: *
Pin: release o=LP-PPA-libreoffice
Pin-Priority: -10

Package: libreoffice* libobasis* ure uno-libs-private python3-uno python3-scriptforge liblibreoffice* libuno* fonts-opensymbol
Pin: release o=LP-PPA-libreoffice
Pin-Priority: 600
__E__

# ===== アプリの更新のお知らせ(版の検出・比較・導入はプログラム。AIは説明だけ) ==========
W usr/share/tone-os/app-sources.json 644 <<'__E__'
{"apps":[
 {"id":"libreoffice","label":"LibreOffice","packages":["libreoffice-core"],"source":"apt(公式PPA)"},
 {"id":"chrome","label":"Google Chrome","packages":["google-chrome-stable"],"source":"apt(Google公式)"},
 {"id":"steam","label":"Steam","packages":["steam-installer"],"source":"apt(Ubuntu)"},
 {"id":"kde","label":"KDE デスクトップ","packages":["kde-plasma-desktop"],"source":"apt(Ubuntu)"}
]}
__E__
W usr/local/bin/tone-app-update 755 <<'__E__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""アプリの更新のお知らせ
  tone-app-update check     登録済みの更新元と、インスコ済みの版を比べる(JSONで表示)
  tone-app-update notify    新しい版があれば、同じ版については1回だけ知らせる
  tone-app-update apply ID  更新前にスナップショットを取り、そのアプリだけ更新(要管理者)
入れる経路は登録済みの更新元(apt)だけ。AIが見つけたURLからは入れない。テスト用: TONE_APT_POLICY=スクリプト"""
import os, sys, json, subprocess, re
SRC = os.environ.get("TONE_APP_SOURCES", "/usr/share/tone-os/app-sources.json")
SEEN = os.path.expanduser("~/.config/tone-os/app-update-seen.json")
def policy(pkg):
    cmd = os.environ.get("TONE_APT_POLICY")
    r = subprocess.run([cmd, pkg] if cmd else ["apt-cache", "policy", pkg], capture_output=True, text=True)
    ins = re.search(r"Installed:\s*(\S+)", r.stdout); cand = re.search(r"Candidate:\s*(\S+)", r.stdout)
    return (ins.group(1) if ins else "(none)"), (cand.group(1) if cand else "(none)")
def newer(cand, ins):
    if ins in ("(none)", "") or cand in ("(none)", ""): return False
    return subprocess.run(["dpkg", "--compare-versions", cand, "gt", ins]).returncode == 0
def check():
    out = []
    for a in json.load(open(SRC, encoding="utf-8"))["apps"]:
        for p in a["packages"]:
            ins, cand = policy(p)
            if newer(cand, ins): out.append({"id": a["id"], "label": a["label"], "from": ins, "to": cand, "source": a["source"]})
    return out
def main(a):
    c = a[0] if a else "check"
    if c == "check": print(json.dumps(check(), ensure_ascii=False)); return 0
    if c == "notify":
        try: seen = json.load(open(SEEN))
        except Exception: seen = {}
        for u in check():
            k = u["id"] + "=" + u["to"]
            if seen.get(k): continue
            seen[k] = True
            subprocess.run(["notify-send", "-i", "system-software-update", "%s の新しい版があります" % u["label"], "%s → %s\nメニューの「アプリの更新」から更新できます。" % (u["from"], u["to"])])
        os.makedirs(os.path.dirname(SEEN), exist_ok=True); json.dump(seen, open(SEEN, "w")); return 0
    if c == "apply" and len(a) > 1:
        ids = {x["id"]: x for x in json.load(open(SRC, encoding="utf-8"))["apps"]}
        if a[1] not in ids: print("登録されていないアプリです"); return 2
        subprocess.run(["/usr/local/bin/tone-snapshot", "create", "update"])
        r = subprocess.run(["apt-get", "install", "-y", "--only-upgrade"] + ids[a[1]]["packages"]); return r.returncode
    print(__doc__); return 2
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
__E__
W usr/local/bin/tone-app-update-gui 755 <<'__E__'
#!/bin/bash
T="アプリの更新"
J=$(tone-app-update check); n=$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$J")
[ "$n" -gt 0 ] || { kdialog --title "$T" --msgbox "更新できるアプリはありません。"; exit 0; }
mapfile -t L < <(python3 -c 'import json,sys
for u in json.loads(sys.argv[1]): print(u["id"]+"\t"+u["label"]+"  "+u["from"]+" → "+u["to"])' "$J")
args=(); for l in "${L[@]}"; do args+=("${l%%$'\t'*}" "${l#*$'\t'}"); done
id=$(kdialog --title "$T" --menu "新しい版があります。更新するものを選んでください(更新の前に、元に戻せるよう保存します)" "${args[@]}") || exit 0
if r=$(pkexec /usr/local/bin/tone-app-update apply "$id" 2>&1); then kdialog --title "$T" --msgbox "更新しました。"; else kdialog --title "$T" --error "更新できませんでした。\n$(echo "$r" | tail -n 5)"; fi
__E__
W usr/share/applications/tone-app-update.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=アプリの更新
Comment=インストール済みのアプリの新しい版を確認します
Exec=/usr/local/bin/tone-app-update-gui
Icon=system-software-update
Categories=System;Settings;
__E__
W etc/systemd/user/tone-app-update.service 644 <<'__E__'
[Unit]
Description=TONE アプリの更新のお知らせ
[Service]
Type=oneshot
Nice=15
ExecStart=/usr/local/bin/tone-app-update notify
__E__
W etc/systemd/user/tone-app-update.timer 644 <<'__E__'
[Unit]
Description=TONE アプリの更新のお知らせ(1日1回)
[Timer]
OnStartupSec=15min
OnUnitActiveSec=1d
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
__E__

# ===== 困ったときボタン =====================================================
W usr/local/bin/tone-help-me 755 <<'__E__'
#!/bin/bash
# 症状を選ぶ → TONE診断(読み取りだけ)→ 個人情報を外す → AIが入っていれば平易な日本語で説明。
# 電池で動いているときも、利用者が押したときだけ動く(自動では起動しない)。
T="困ったときは"
sym=$(kdialog --title "$T" --menu "どんな状態ですか?" freeze "画面が固まる・ちらつく" slow "動きが遅い" net "ネットにつながらない" sound "音が出ない" other "その他・よくわからない") || exit 0
R=$(mktemp /tmp/tone-helpme.XXXXXX)
{
  echo "症状: $sym"; echo "--- GPU診断 ---"; TONE_REPORT_DIR=/tmp /usr/local/bin/tone-gpu-check 2>&1
  echo "--- 電池 ---"; tone-power battery 2>&1
  echo "--- メモリ・容量 ---"; free -h; df -h / /home 2>/dev/null
  echo "--- 失敗しているサービス ---"; systemctl --failed --no-legend 2>/dev/null | head -n 10
  echo "--- 最近のエラー ---"; journalctl -p err -b --no-pager -n 30 2>/dev/null
  [ "$sym" = net ] && { echo "--- ネットワーク ---"; nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null; }
} > "$R" 2>&1
# 個人情報を外す(ユーザー名・ホスト名・IP・MAC・メール・ホームのパス)
U=$(id -un); H=$(hostname)
sed -i -E "s#/home/$U#/home/(利用者)#g; s#\b$U\b#(利用者)#g; s#\b$H\b#(PC名)#g; s#([0-9]{1,3}\.){3}[0-9]{1,3}#(IP)#g; s#([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}#(MAC)#g; s#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+#(メール)#g" "$R"
kdialog --title "$T" --textbox "$R" 700 500
rm -f "$R"
__E__
W usr/share/applications/tone-help-me.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=困ったときは
Comment=症状を選ぶと、原因を調べてやさしく説明します
Exec=/usr/local/bin/tone-help-me
Icon=help-browser
Categories=System;
__E__
# ===== 診断スクリプトを標準コマンドに =======================================
W usr/local/bin/tone-gpu-check 755 <<'__E__'
#!/usr/bin/env bash
# TONE GPU診断 v2 — 画面の固まり・ちらつき・描画の遅さの原因(GPUドライバー)を調べる
# 対応: NVIDIA / AMD / Intel / 仮想マシン / 複数GPU(ハイブリッド) / その他
# 既定: 読み取りだけ(何も変更しない)。--fix を付けたときだけ、確認のうえ修復する。
#   使い方:  bash tone-gpu-check.sh          # 診断のみ
#            bash tone-gpu-check.sh --fix    # 診断+(確認のうえ)修復
set -u
LC_ALL=C.UTF-8; export LC_ALL
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
OUT="${TONE_REPORT_DIR:-$HOME}/tone-gpu-report-$(date +%Y%m%d-%H%M%S).txt"
have(){ command -v "$1" >/dev/null 2>&1; }
R(){ printf '%s\n' "$*" | tee -a "$OUT"; }
SEC(){ R ""; R "■ $*"; }
SUDO=""; [ "$(id -u 2>/dev/null)" != 0 ] && SUDO="sudo"

: > "$OUT" 2>/dev/null || { OUT="/tmp/tone-gpu-report-$$.txt"; : > "$OUT"; }
R "TONE GPU診断  $(date '+%F %T')"

# ---------- 1. 基本情報 ----------
SEC "基本情報"
R "カーネル: $(uname -r)"
SES="${XDG_SESSION_TYPE:-}"
[ -z "$SES" ] && have loginctl && SES=$(loginctl show-session "$(loginctl 2>/dev/null | awk 'NR==2{print $1}')" -p Type --value 2>/dev/null)
R "セッション: ${SES:-不明}"
SB="不明"; have mokutil && SB=$(mokutil --sb-state 2>/dev/null | head -1)
R "Secure Boot: ${SB:-不明}"
VIRT="none"; have systemd-detect-virt && VIRT=$(systemd-detect-virt 2>/dev/null || true)
[ -z "$VIRT" ] && VIRT="none"
[ "$VIRT" != "none" ] && R "仮想マシン: $VIRT"

# ---------- 2. GPU(1枚ずつ読む) ----------
SEC "GPUとドライバー"
G_VID=(); G_DRV=(); G_DESC=(); CUR=0; DESC=""; DRV=""; VID=""
flush(){ if [ "$CUR" = 1 ]; then G_VID+=("$VID"); G_DRV+=("${DRV:-なし}"); G_DESC+=("$DESC"); fi; CUR=0; DESC=""; DRV=""; VID=""; }
if have lspci; then
  while IFS= read -r line; do
    case "$line" in
      [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].*|[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*)
        flush
        if printf '%s' "$line" | grep -Eq 'VGA compatible|3D controller|Display controller'; then
          CUR=1; DESC="$line"
          VID=$(printf '%s' "$line" | sed -n 's/.*\[\([0-9a-f]\{4\}\):[0-9a-f]\{4\}\].*/\1/p' | tail -1)
        fi ;;
      *"Kernel driver in use:"*) [ "$CUR" = 1 ] && DRV="${line##*: }" ;;
    esac
    case "$line" in *Subsystem:*) ;; *) [ "$CUR" = 1 ] && printf '%s\n' "$line" >> "$OUT.tmp" ;; esac
  done < <(lspci -nnk 2>/dev/null)
  flush
  if [ -f "$OUT.tmp" ]; then cat "$OUT.tmp" | tee -a "$OUT"; rm -f "$OUT.tmp"; fi
  [ "${#G_VID[@]}" = 0 ] && R "GPUが見つかりません"
else
  R "lspci がありません(pciutils を入れると詳しく調べられます)"
fi
NG=${#G_VID[@]}
[ "$NG" -ge 2 ] && R "※GPUが ${NG} 枚あります(ハイブリッド構成を含む)。"

REND=""; have glxinfo && REND=$(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer string/{print $2}')
[ -n "$REND" ] && R "描画(OpenGL): $REND"
SOFT=0; printf '%s' "$REND" | grep -Eqi 'llvmpipe|softpipe|swrast' && SOFT=1
ZINK=0; printf '%s' "$REND" | grep -qi 'zink' && ZINK=1
if have vulkaninfo; then
  VK=$(vulkaninfo --summary 2>/dev/null | awk -F'= ' '/deviceName/{print $2}' | sort -u | paste -sd, -)
  [ -n "$VK" ] && R "Vulkan: $VK"
fi

# ---------- 3. カーネルのGPUエラー(今回・前回の起動) ----------
SEC "GPUエラーの記録"
PAT='nouveau.*(mmu fault|fifo|errored|timeout|channel)|NVRM.*Xid|GPU HANG|i915.*(hang|reset)|\bxe\b.*(GT reset|timeout)|amdgpu.*(timeout|GPU reset|VM fault|ring .* timeout|\*ERROR\*)|radeon.*(lockup|GPU reset)'
FWPAT='(Direct firmware load for|failed to load firmware|firmware: failed to load).*(amdgpu|radeon|i915|nouveau|nvidia|xe/)'
LOGS=""; FWMISS=""
if have journalctl; then
  for b in 0 -1; do
    L=$(journalctl -b $b -k --no-pager 2>/dev/null | grep -Ei "$PAT" | tail -8)
    [ -n "$L" ] && LOGS="$LOGS$L"$'\n'
    F=$(journalctl -b $b -k --no-pager 2>/dev/null | grep -Ei "$FWPAT" | tail -4)
    [ -n "$F" ] && FWMISS="$FWMISS$F"$'\n'
  done
fi
if [ -n "$LOGS" ]; then R "$LOGS"; else R "GPUのエラー記録は見つかりませんでした(権限不足の場合は sudo で実行してください)"; fi
if [ -n "$FWMISS" ]; then R ""; R "ファームウェア(GPU用の部品)の読み込み失敗:"; R "$FWMISS"; fi

# ---------- 4. 推奨ドライバー(NVIDIA) ----------
HAS_NV=0; for v in "${G_VID[@]:-}"; do [ "$v" = "10de" ] && HAS_NV=1; done
REC=""
if [ "$HAS_NV" = 1 ] && have ubuntu-drivers; then
  SEC "推奨ドライバー(NVIDIA)"
  UD=$(ubuntu-drivers devices 2>/dev/null)
  REC=$(printf '%s\n' "$UD" | awk '/recommended/{for(i=1;i<=NF;i++) if($i ~ /^nvidia-/){print $i; exit}}')
  R "${UD:-(取得できません)}"
fi

# ---------- 5. 判定(GPUごと→全体) ----------
SEC "判定"
WORST=0; MSGS=(); ACT_NV=0; ACT_FW=0
add(){ # 重さ(0=OK 1=注意 2=NG) メッセージ
  [ "$1" -gt "$WORST" ] && WORST=$1
  MSGS+=("$2")
}
has_err(){ printf '%s' "$LOGS" | grep -Eqi "$1"; }

i=0
while [ "$i" -lt "$NG" ]; do
  V="${G_VID[$i]}"; D="${G_DRV[$i]}"; N="GPU$((i+1))"
  case "$V" in
    10de) # NVIDIA
      case "$D" in
        nouveau)
          if [ -n "$REC" ]; then
            if has_err 'nouveau'; then add 2 "$N(NVIDIA)が標準ドライバー(nouveau)で動き、エラーも記録されています。固まり・ちらつきの原因の可能性が高いです。専用ドライバー($REC)をお勧めします。"
            else add 1 "$N(NVIDIA)が標準ドライバー(nouveau)で動いています。新しいGPUでは不安定になりやすいため、専用ドライバー($REC)をお勧めします。"; fi
            ACT_NV=1
          else
            add 1 "$N(NVIDIA)は標準ドライバー(nouveau)で動いています。この GPU 向けの専用ドライバーは見つかりませんでした(古い世代の可能性)。"
          fi ;;
        nvidia) if has_err 'NVRM.*Xid'; then add 1 "$N(NVIDIA)は専用ドライバーで動いていますが、Xid エラーが記録されています。"; else add 0 "$N(NVIDIA)は専用ドライバーで動いています。"; fi ;;
        なし) add 1 "$N(NVIDIA)のドライバーが読み込まれていません。Secure Boot が有効で署名が合っていない可能性があります。"
              [ -n "$REC" ] && ACT_NV=1 ;;
        *) add 0 "$N(NVIDIA)はドライバー $D で動いています。" ;;
      esac ;;
    1002) # AMD
      case "$D" in
        amdgpu) if has_err 'amdgpu'; then add 1 "$N(AMD)は amdgpu で動いていますが、タイムアウト/リセットが記録されています。"; else add 0 "$N(AMD)は標準ドライバー amdgpu で動いています(追加の導入は不要)。"; fi ;;
        radeon) if has_err 'radeon'; then add 1 "$N(AMD)は旧ドライバー radeon で動き、ロックアップが記録されています。GCN 世代(HD 7000 / R7 / R9 など)なら amdgpu への切り替えで改善する場合があります。"
                else add 0 "$N(AMD)は旧ドライバー radeon で動いています(古い世代では正常です)。"; fi ;;
        なし) add 1 "$N(AMD)のドライバーが読み込まれていません。ファームウェア(linux-firmware)の不足の可能性があります。"; ACT_FW=1 ;;
        *) add 0 "$N(AMD)はドライバー $D で動いています。" ;;
      esac ;;
    8086) # Intel
      case "$D" in
        i915|xe) if has_err 'i915|\bxe\b'; then add 1 "$N(Intel)は $D で動いていますが、ハング/リセットが記録されています。"; else add 0 "$N(Intel)は標準ドライバー $D で動いています(追加の導入は不要)。"; fi ;;
        なし) add 1 "$N(Intel)のドライバーが読み込まれていません。ファームウェア(linux-firmware)の不足の可能性があります。"; ACT_FW=1 ;;
        *) add 0 "$N(Intel)はドライバー $D で動いています。" ;;
      esac ;;
    1af4|1b36|15ad|80ee|1234|1414|1ab8) add 0 "$N は仮想マシンのGPU($D)です。実機のような専用ドライバーは不要です。" ;;
    *) add 0 "$N(ベンダー ID $V)はドライバー $D で動いています。このスクリプトでは自動修復の対象外です。" ;;
  esac
  i=$((i+1))
done
[ "$NG" = 0 ] && add 1 "GPUを検出できませんでした。lspci の有無や権限を確認してください。"

if [ -n "$FWMISS" ]; then add 1 "GPU用ファームウェアの読み込み失敗が記録されています。linux-firmware の更新で直る場合があります。"; ACT_FW=1; fi
if [ "$SOFT" = 1 ] && [ "$VIRT" = "none" ]; then
  add 2 "描画がソフトウェア(CPU)で行われています(${REND})。GPUが使われておらず、画面が重く不安定になります。ドライバーを確認してください。"
elif [ "$ZINK" = 1 ]; then
  add 1 "描画が zink(変換経由)で動いています。実験的な経路なので、不安定になる場合があります。"
fi
if [ -n "$LOGS" ] && [ "$WORST" = 0 ]; then add 1 "GPUのエラー記録があります。内容を確認してください。"; fi

case "$WORST" in 0) VERDICT="OK";; 1) VERDICT="注意";; *) VERDICT="NG";; esac
R "結果: $VERDICT"
for m in "${MSGS[@]}"; do R "・$m"; done
if [ "$WORST" = 0 ] && [ "$NG" -ge 1 ]; then R "問題は見つかりませんでした。"; fi
case "$SB" in *enabled*) [ "$HAS_NV" = 1 ] && R "※Secure Boot が有効です。署名済みドライバー(ubuntu-drivers の推奨)を使えば、登録画面(MOK)は出ません。";; esac
if [ "$NG" -ge 2 ] && have prime-select; then R "※PRIME の現在の設定: $(prime-select query 2>/dev/null)"; fi
R ""
R "レポート保存先: $OUT"

# ---------- 6. 修復(--fix のときだけ・確認つき) ----------
confirm(){ if [ -t 0 ]; then read -r -p "$1 [y/N] " ANS; else ANS=n; fi; case "$ANS" in y|Y) return 0;; *) return 1;; esac; }
if [ "$FIX" = 1 ]; then
  SEC "修復"
  DONE=0
  if [ "$ACT_NV" = 1 ] && have ubuntu-drivers; then
    R "NVIDIA の専用ドライバーを入れます(推奨: ${REC:-自動選択})。システムを変更します(再起動が必要です)。"
    if confirm "実行しますか?"; then
      if $SUDO "$(command -v ubuntu-drivers)" install; then R "導入しました。再起動してください。再起動後にもう一度このスクリプトで確認できます。"
      else R "導入に失敗しました。システムは変更前のままのはずです。レポートを共有してください。"; fi
    else R "中止しました。何も変更していません。"; fi
    DONE=1
  fi
  if [ "$ACT_FW" = 1 ] && have apt-get; then
    R "GPU用ファームウェア(linux-firmware)を入れ直します。再起動が必要です。"
    if confirm "実行しますか?"; then
      if $SUDO apt-get install -y --reinstall linux-firmware; then R "導入しました。再起動してください。"
      else R "導入に失敗しました。ネットワークを確認してください。"; fi
    else R "中止しました。何も変更していません。"; fi
    DONE=1
  fi
  [ "$DONE" = 0 ] && R "修復の対象はありませんでした。何も変更していません。"
fi
__E__
# ===== ドライバー自動切替(v2): NVIDIAなら専用ドライバーへ。署名済みの事前ビルド版のみ(Secure Boot)。失敗したら元へ戻す =====
W usr/local/bin/tone-drivers 755 <<'__E__'
#!/bin/bash
# 初回起動時(ネット接続時のみ・成功したら以後は実行しない): 専用ドライバーが要るGPU/無線なら導入する
mkdir -p /var/lib/tone-os /var/log/tone-os; L=/var/log/tone-os/drivers.log
[ -n "${TONE_DRIVERS_TEST:-}" ] || curl -fsI --max-time 15 http://archive.ubuntu.com/ubuntu/dists/noble/Release >/dev/null 2>&1 || exit 0
sb=0; command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled' && sb=1
{
  echo "=== $(date) ドライバー自動導入 (SecureBoot=$sb) ==="
  if lspci -nn 2>/dev/null | grep -qiE 'nvidia'; then
    tone-snapshot create driver 2>/dev/null
    ubuntu-drivers devices
    DEBIAN_FRONTEND=noninteractive ubuntu-drivers install; echo "install rc=$?"
    if [ "$sb" = 1 ] && dpkg -l 2>/dev/null | grep -qE '^ii\s+nvidia-dkms'; then
      echo "Secure Boot が有効で、署名済みの事前ビルド版がないため、画面を守るために専用ドライバーを取り消します"
      DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nvidia-*' 'libnvidia-*' 'xserver-xorg-video-nvidia-*' 2>&1 | tail -n 3
      apt-get -y autoremove 2>&1 | tail -n 1; update-initramfs -u 2>&1 | tail -n 1
    else touch /var/lib/tone-os/gpu-verify; fi        # 次の起動で、実際にGPUが動いているか確かめる
  fi
  lspci -nn 2>/dev/null | grep -qiE 'broadcom.*(wireless|network)' && DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall
} >>"$L" 2>&1
touch /var/lib/tone-os/drivers-done; exit 0
__E__
W usr/local/bin/tone-gpu-verify 755 <<'__E__'
#!/bin/bash
# 専用ドライバーへ切り替えたあと、実際にGPUが動いているかを確かめる。動かなければ元(nouveau)へ戻す(画面が真っ暗にならないことが最優先)
[ -f /var/lib/tone-os/gpu-verify ] || exit 0
rm -f /var/lib/tone-os/gpu-verify
lspci -nn | grep -qi nvidia || exit 0
if nvidia-smi -L >/dev/null 2>&1; then echo "$(date) NVIDIA 動作確認OK" >> /var/log/tone-os/drivers.log; exit 0; fi
echo "$(date) NVIDIA が動いていないため、元の状態へ戻します" >> /var/log/tone-os/drivers.log
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nvidia-*' 'libnvidia-*' 'xserver-xorg-video-nvidia-*' >> /var/log/tone-os/drivers.log 2>&1
apt-get -y autoremove >/dev/null 2>&1; update-initramfs -u >/dev/null 2>&1
touch /var/lib/tone-os/gpu-reverted
exit 0
__E__
W etc/systemd/system/tone-gpu-verify.service 644 <<'__E__'
[Unit]
Description=TONE GPUドライバー切替後の動作確認
ConditionKernelCommandLine=!boot=casper
ConditionPathExists=/var/lib/tone-os/gpu-verify
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tone-gpu-verify
[Install]
WantedBy=multi-user.target
__E__
# ===== 起動の修復(インストール後も押せる) ===================================
W usr/local/bin/tone-boot-repair 755 <<'__E__'
#!/bin/bash
# 起動の修復: GRUBを入れ直し、起動メニューを作り直す。他のOSがあれば起動メニューに載せる。
set -u
if [ "$(id -u)" != 0 ]; then exec pkexec "$0" "$@"; fi
log() { echo "$*"; }
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub; grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
if [ -d /sys/firmware/efi ]; then
  id=${TONE_EFI_ID:-ubuntu}
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$id" --recheck || log "GRUBのEFI入れ直しに失敗"
  mkdir -p /boot/efi/EFI/BOOT; cp -a /boot/efi/EFI/"$id"/. /boot/efi/EFI/BOOT/ 2>/dev/null && cp -f /boot/efi/EFI/"$id"/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null
else
  d=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE / | sed 's/\[.*//')" | head -1); grub-install --target=i386-pc --recheck "/dev/$d" || log "GRUBの入れ直しに失敗"
fi
update-grub && log "起動メニューを作り直しました。"
__E__
W usr/share/applications/tone-boot-repair.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=起動の修復
Comment=起動の画面(GRUB)を入れ直して直します
Exec=/usr/local/bin/tone-boot-repair
Icon=system-run
Categories=System;
__E__
# ===== 初回のおまかせセットアップ + バックアップ ============================
W usr/local/bin/tone-backup 755 <<'__E__'
#!/bin/bash
# 利用者のデータ(書類・写真など)を、別の場所へコピーするだけ(元は動かさない・消さない)。
#   tone-backup dest [フォルダ]   保存先を決める/表示   tone-backup run   コピーする
CFG="$HOME/.config/tone-os/backup-dest"
case "${1:-}" in
  dest) if [ -n "${2:-}" ]; then mkdir -p "$(dirname "$CFG")"; echo "$2" > "$CFG"; fi; cat "$CFG" 2>/dev/null ;;
  run)
    D=$(cat "$CFG" 2>/dev/null); [ -d "$D" ] || exit 0
    case "$(realpath "$D")" in "$(realpath "$HOME")"/*|"$(realpath "$HOME")") exit 0;; esac     # 保存先がホームの中なら意味がない
    for f in ドキュメント ピクチャ ミュージック ビデオ デスクトップ ダウンロード Documents Pictures Music Videos Desktop Downloads; do
      [ -d "$HOME/$f" ] && rsync -a "$HOME/$f/" "$D/TONE-backup/$f/"
    done ;;
  *) echo "tone-backup dest [フォルダ] | run" ;;
esac
__E__
W etc/systemd/user/tone-backup.service 644 <<'__E__'
[Unit]
Description=TONE バックアップ(コピーのみ)
ConditionPathExists=%h/.config/tone-os/backup-dest
[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/bin/tone-backup run
__E__
W etc/systemd/user/tone-backup.timer 644 <<'__E__'
[Unit]
Description=TONE バックアップ(週1回)
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
__E__
W usr/local/bin/tone-setup-wizard 755 <<'__E__'
#!/bin/bash
# 初回のおまかせセットアップ(どれも後から設定で変えられる)
grep -q boot=casper /proc/cmdline && exit 0
M="$HOME/.config/tone-os/setup-done"; [ -f "$M" ] && exit 0
T="TONE OS へようこそ"
kdialog --title "$T" --yesno "はじめに、使いやすい設定を一緒に決めましょう。\n(あとから、すべて設定で変えられます)" --yes-label "はじめる" --no-label "あとで" || exit 0
st=$(kdialog --title "$T" --menu "操作の形を選んでください" win "Windows風(エクスプローラーの使い方)" mac "Mac風(Finderの使い方)") || st=win
mapfile -t L < <(tone-theme list); args=(); for l in "${L[@]}"; do args+=("${l%% *}" "${l#* }"); done
w=$(kdialog --title "$T" --menu "世界観を選んでください(色・壁紙・ログイン画面)" "${args[@]}") || w=1_floyd
tone-theme set "$w" --style "$st" >/dev/null 2>&1
# ドライバー診断(読み取りだけ)
d=$(TONE_REPORT_DIR=/tmp tone-gpu-check 2>&1 | grep -E '総合|判定' | head -n 3)
if echo "$d" | grep -q 'NG'; then kdialog --title "$T" --msgbox "画面まわりに、直したほうがよい点が見つかりました。\n「困ったときは」から、いつでも詳しく調べられます。"; fi
# バックアップ先
if kdialog --title "$T" --yesno "大切なデータ(書類・写真など)を、別の場所へ定期的にコピーしますか?\n(元のデータは動かしません。外付けディスクなどを選んでください)" --yes-label "設定する" --no-label "あとで"; then
  dir=$(kdialog --getexistingdirectory /media "保存先を選んでください") && tone-backup dest "$dir" >/dev/null && systemctl --user enable --now tone-backup.timer >/dev/null 2>&1
fi
# 保存したデータを戻す(インストール前に保存した場合)
if kdialog --title "$T" --yesno "インストールの前にデータを保存しましたか?\n保存したデータを、いま戻しますか?" --yes-label "戻す" --no-label "いいえ"; then
  src=$(kdialog --getexistingdirectory /media "保存した TONE-backup フォルダを選んでください") && [ -d "$src" ] && rsync -a "$src"/ "$HOME/復元したデータ/" && kdialog --title "$T" --msgbox "「復元したデータ」フォルダに戻しました。"
fi
# 更新の有効化
pkexec systemctl enable --now tone-os-update-check.timer >/dev/null 2>&1
systemctl --user enable --now tone-app-update.timer >/dev/null 2>&1
mkdir -p "$(dirname "$M")"; touch "$M"
kdialog --title "$T" --msgbox "設定が終わりました。困ったときは、メニューの「困ったときは」を押してください。"
__E__
W etc/xdg/autostart/tone-setup-wizard.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=TONE 初回セットアップ
Exec=/usr/local/bin/tone-setup-wizard
NoDisplay=true
OnlyShowIn=KDE;
X-KDE-autostart-after=panel
__E__
# ===== インストールガイド(全消しをおすすめ → データ保存 → インストーラー) ==========
W usr/local/bin/tone-install-guide 755 <<'__E__'
#!/bin/bash
# Calamares の前に出す案内。「全部消してインストール」をおすすめし、大切なデータの保存(コピーのみ)を手伝う。
# 守り: 元データは読み取り専用で開く/保存先は消えるディスクとは別の外付けだけ/コピー後に件数と容量を照合し、合わなければ先へ進ませない
set -u
T="TONE OS のインストール"
# 件数と容量(と、ファイルの中身の比較)が、元と一致するか確かめる。1つでも違えば失敗(=先へ進ませない)
verify_copy() {
  local a b sa sb
  a=$(find "$1" -type f | wc -l); b=$(find "$2" -type f | wc -l)
  sa=$(find "$1" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}'); sb=$(find "$2" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}')
  [ "$a" = "$b" ] && [ "$sa" = "$sb" ] || return 1
  [ -z "$(rsync -rcn --out-format=x "$1/" "$2/" 2>/dev/null)" ]
}
[ -n "${TONE_GUIDE_LIB:-}" ] && return 0 2>/dev/null
SRC=/mnt/tone-src; mkdir -p $SRC
cleanup() { for m in $(mount | awk -v p="$SRC" '$3 ~ "^"p {print $3}' | sort -r); do umount "$m" 2>/dev/null; done; }
trap cleanup EXIT
kdialog --title "$T" --msgbox "<h3>おすすめ: ディスクを全部消してインストール</h3>
・前に入っていた OS と、TONE OS が、起動のときに喧嘩しません。<br>
・迷う設定がなくなり、一番安定して動きます。<br>
・同じ構成で動くので、困ったときにすぐ直せます。<br>
・<b>今入っているデータはすべて消えます。大切なものは先に保存しましょう。</b>" 2>/dev/null
# 既存のLinuxがあれば、共存時の注意を先に案内する
if lsblk -rno FSTYPE 2>/dev/null | grep -qE 'ext4|btrfs|xfs' ; then
  kdialog --title "$T" --msgbox "このPCには、すでに Linux が入っているようです。\n全部消さずに共存させる場合は、起動の画面が変わることがあります(上級者向け)。\n迷ったら「全部消してインストール」をおすすめします。" 2>/dev/null
fi
# 共存に備え、EFIの中身と起動項目の一覧を保存しておく(消さない・戻せるように)
B=/tmp/tone-efi-backup; mkdir -p $B
efibootmgr -v > $B/efibootmgr.txt 2>/dev/null || true
for p in $(lsblk -rpno NAME,PARTTYPE 2>/dev/null | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1}'); do
  mkdir -p $SRC/efi; mount -o ro "$p" $SRC/efi 2>/dev/null && { mkdir -p "$B/$(basename "$p")"; cp -a $SRC/efi/. "$B/$(basename "$p")/" 2>/dev/null; umount $SRC/efi; }
done
kdialog --title "$T" --yesno "大切なデータを保存しますか?\n(コピーだけで、今あるデータは動かしません)" --yes-label "保存する" --no-label "保存しない" 2>/dev/null || exit 0
# 1) 既存ディスクのユーザーフォルダを自動で探す(読み取り専用で開く)
found=(); n=0
for p in $(lsblk -rpno NAME,TYPE,FSTYPE | awk '$2=="part" && $3 ~ /^(ext4|btrfs|xfs|ntfs|exfat|vfat)$/ {print $1}'); do
  case "$(lsblk -rno RM,TRAN "$p" | head -1)" in "1 "*|*usb*) continue;; esac     # 外付けは保存先の候補。ここでは内蔵だけ
  d=$SRC/p$n; n=$((n+1)); mkdir -p $d
  mount -o ro,noload "$p" $d 2>/dev/null || mount -o ro "$p" $d 2>/dev/null || continue
  for u in $d/home/* $d/@home/* $d/Users/*; do
    [ -d "$u" ] || continue
    for f in ドキュメント Documents ピクチャ Pictures ミュージック Music ビデオ Videos デスクトップ Desktop ダウンロード Downloads; do
      [ -d "$u/$f" ] && found+=("$u/$f")
    done
  done
done
[ "${#found[@]}" -gt 0 ] || { kdialog --title "$T" --msgbox "保存できるフォルダが見つかりませんでした。\nこのまま進みます。" 2>/dev/null; exit 0; }
args=()
for f in "${found[@]}"; do sz=$(du -sb "$f" 2>/dev/null | cut -f1); args+=("$f" "${f#$SRC/}  ($(numfmt --to=iec "${sz:-0}"))" on); done
sel=$(kdialog --title "$T" --separate-output --checklist "保存するフォルダを選んでください" "${args[@]}" 2>/dev/null) || exit 0
[ -n "$sel" ] || exit 0
need=0; while IFS= read -r f; do need=$((need + $(du -sb "$f" | cut -f1))); done <<<"$sel"
# 2) 保存先: 外付け(USB・外付けディスク)だけ。消える側は候補に出さない
dargs=(); for p in $(lsblk -rpno NAME,TYPE | awk '$2=="part"{print $1}'); do
  case "$(lsblk -rno RM,TRAN "$p" | head -1)" in "1 "*|*usb*) ;; *) continue;; esac
  dargs+=("$p" "$p $(lsblk -rno SIZE,LABEL "$p" | head -1)")
done
[ "${#dargs[@]}" -gt 0 ] || { kdialog --title "$T" --msgbox "保存先にできる外付けのUSB・ディスクが見つかりません。\nつないでから、もう一度やり直してください。" 2>/dev/null; exit 1; }
dev=$(kdialog --title "$T" --menu "保存先(外付け)を選んでください" "${dargs[@]}" 2>/dev/null) || exit 0
mkdir -p $SRC/dest; mount "$dev" $SRC/dest 2>/dev/null || { kdialog --title "$T" --error "保存先を開けませんでした。" 2>/dev/null; exit 1; }
free=$(df -B1 --output=avail $SRC/dest | tail -1)
[ "$free" -gt "$need" ] || { kdialog --title "$T" --error "保存先の空き容量が足りません。" 2>/dev/null; exit 1; }
# 3) コピー(元は動かさない)→ 件数と容量を照合
D=$SRC/dest/TONE-backup-$(date +%Y%m%d-%H%M); mkdir -p "$D"; ok=1
while IFS= read -r f; do
  name=$(echo "${f#$SRC/}" | tr '/' '_')
  rsync -a "$f/" "$D/$name/" || ok=0
  verify_copy "$f" "$D/$name" || ok=0
done <<<"$sel"
cp -a /tmp/tone-efi-backup "$D/EFI-backup" 2>/dev/null || true
sync
if [ "$ok" != 1 ]; then kdialog --title "$T" --error "保存したデータの件数または容量が、元と一致しませんでした。\n安全のため、先へ進みません。もう一度やり直してください。" 2>/dev/null; exit 1; fi
kdialog --title "$T" --msgbox "保存できました(件数と容量の一致を確認しました)。\n保存先: $(basename "$D")\nインストール後の最初の画面で、戻す案内が出ます。" 2>/dev/null
exit 0
__E__
# ===== 起動アニメの選択(世界観とは独立) =====================================
W usr/local/bin/tone-boot-anim 755 <<'__E__'
#!/bin/bash
# 起動アニメ(回転体)を選ぶ。 tone-boot-anim [wind|whirl|typhoon]   引数なしなら選択画面
a=${1:-}
if [ -z "$a" ]; then
  a=$(kdialog --title "起動アニメ" --menu "起動のときに回る形を選んでください(細いシークバーは、いつも一緒に出ます)" wind "カザグルマ" whirl "鳴門の渦" typhoon "台風") || exit 0
fi
case "$a" in wind|whirl|typhoon) ;; *) echo "wind / whirl / typhoon"; exit 2;; esac
[ "$(id -u)" = 0 ] || exec pkexec "$0" "$a"
plymouth-set-default-theme -R "tone-$a" && echo "切り替えました。次の起動から変わります。"
__E__
W usr/share/applications/tone-boot-anim.desktop 644 <<'__E__'
[Desktop Entry]
Type=Application
Name=起動アニメの選択
Comment=起動のときの回転体(カザグルマ・鳴門の渦・台風)を選びます
Exec=/usr/local/bin/tone-boot-anim
Icon=preferences-desktop-theme
Categories=Settings;
__E__
# ===== 更新の公開鍵の焼き込み ===============================================
KEYDIR=$BASE/keys; mkdir -p "$KEYDIR"
PUBSRC=""
for c in "$IMP/update-pub.pem" "$KEYDIR/update-pub.pem" "${TONE_UPDATE_PUBKEY:-/nonexistent}"; do [ -f "$c" ] && { PUBSRC=$c; break; }; done
if [ -z "$PUBSRC" ]; then
  log "▲更新の公開鍵がありません。テスト用の鍵を作ります。本番では、手元のオフライン環境で 'tone-release genkey' を実行し、公開鍵を $KEYDIR/update-pub.pem に置いて再ビルドしてください"
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/test-update-key.pem"; chmod 600 "$KEYDIR/test-update-key.pem"
  openssl ec -in "$KEYDIR/test-update-key.pem" -pubout -out "$KEYDIR/update-pub.pem" 2>/dev/null
  PUBSRC=$KEYDIR/update-pub.pem; KEYSTATE=test
else KEYSTATE=production; fi
mkdir -p "$SRC/overlay/usr/share/tone-os/keys" "$SRC/overlay/etc/tone-os/keys.d"
cp -f "$PUBSRC" "$SRC/overlay/usr/share/tone-os/keys/update-pub.pem"; chmod 644 "$SRC/overlay/usr/share/tone-os/keys/update-pub.pem"
echo "$KEYSTATE" > "$SRC/overlay/usr/share/tone-os/keys/KEYSTATE"
log "更新の公開鍵: $KEYSTATE ($(openssl dgst -sha256 -r "$PUBSRC" | cut -c1-16))"
# ===== 壁紙(各世界観 6 枚の基本セット) =======================================
WPD=$SRC/overlay/usr/share/tone-os/wallpapers; mkdir -p "$WPD"
WPZIP=""
for c in "${WP_SRC:-}" "$IMP/TONE-wallpapers.zip" "$BASE/TONE-wallpapers.zip" "/home/$REAL_USER/TONE-wallpapers.zip" "/home/$REAL_USER/ダウンロード/TONE-wallpapers.zip" "/home/$REAL_USER/Downloads/TONE-wallpapers.zip"; do [ -n "$c" ] && [ -f "$c" ] && { WPZIP=$c; break; }; done
if [ -n "$WPZIP" ]; then
  WT=$(mktemp -d); unzip -q -o "$WPZIP" -d "$WT"
  for w in 1_floyd 2_koya 3_minobu 4_kyoto 5_nara 6_jsdf; do
    src=$(find "$WT" -maxdepth 2 -type d -name "$w" | head -1); [ -n "$src" ] && { mkdir -p "$WPD/$w"; cp -f "$src"/*.jpg "$WPD/$w/" 2>/dev/null; }
  done
  f=$(find "$WT" -maxdepth 2 -name CREDITS.tsv | head -1); [ -n "$f" ] && cp -f "$f" "$WPD/CREDITS.tsv"
  rm -rf "$WT"; log "壁紙パックを取り込みました: $WPZIP"
else
  log "▲壁紙パック(TONE-wallpapers.zip)が見つかりません。仮の壁紙(単色グラデーション)で代用します。本番では $BASE/TONE-wallpapers.zip に置いて再ビルドしてください"
fi
python3 - "$SRC/overlay/usr/share/tone-os/worlds.json" "$WPD" <<'__PY__'
import json, sys, os, subprocess
for w in json.load(open(sys.argv[1], encoding="utf-8"))["worlds"]:
    d = os.path.join(sys.argv[2], w["id"]); os.makedirs(d, exist_ok=True)
    have = len([f for f in os.listdir(d) if f.endswith(".jpg")])
    for i in range(have + 1, 7):    # 足りない分だけ仮の壁紙で補う
        subprocess.run(["convert", "-size", "1920x1080", "gradient:%s-%s" % (w["bg2"], w["accent"]), "-quality", "85", os.path.join(d, "%d.jpg" % i)], check=True)
__PY__
chmod -R a+rX "$SRC/overlay/usr/share/tone-os/wallpapers"
# Calamaresの表示名の版を、TONE_VER に合わせる
sed -i -E "s/^(  )(version|shortVersion): .*/\1\2: $TONE_VER/; s/^(  )(versionedName|shortVersionedName): .*/\1\2: TONE OS $TONE_VER/" "$SRC/overlay/etc/calamares/branding/tone/branding.desc"
log "ソース生成完了: $(find "$SRC/overlay" -type f | wc -l) ファイル"
# ===== 新しい部品の単体検査(ビルド中に毎回実行。ここで落ちたらビルドを止める) =========
test_modules() {
  local OV=$SRC/overlay T; T=$(mktemp -d /tmp/tone-modtest.XXXXXX); local ok=1
  chk() { if eval "$2"; then echo "  OK  $1"; else echo "  NG  $1"; ok=0; fi; }
  log "新しい部品の単体検査を実行します(安全な一時フォルダ内だけで動きます)"
  # --- スナップショット(btrfsコマンドを偽物に差し替え) ---
  mkdir -p "$T/bin" "$T/snaps"; cat > "$T/bin/fakebtrfs" <<'__F__'
#!/bin/bash
# subvolume snapshot [-r] SRC DEST / subvolume delete DEST
if [ "$1 $2" = "subvolume snapshot" ]; then shift 2; [ "$1" = "-r" ] && shift; mkdir -p "$2"; echo snap > "$2/.snap"; exit 0; fi
if [ "$1 $2" = "subvolume delete" ]; then rm -rf "$3"; exit 0; fi; exit 1
__F__
  chmod +x "$T/bin/fakebtrfs"
  export TONE_SNAP_DIR=$T/snaps TONE_BTRFS_BIN=$T/bin/fakebtrfs TONE_FORCE_BTRFS=1 TONE_ROOT_SNAP=1
  n=$(TONE_ROOT=/ bash "$OV/usr/local/bin/tone-snapshot" create update)
  chk "snapshot create" "[ -d '$T/snaps/$n' ] && [[ '$n' =~ ^[0-9]{8}-[0-9]{6}-update\$ ]]"
  chk "snapshot list"   "bash '$OV/usr/local/bin/tone-snapshot' list | grep -q '$n'"
  for i in $(seq 1 13); do mkdir -p "$T/snaps/2026010$((i%9+1))-0000$((i%10))$((i/10))-apt"; done
  bash "$OV/usr/local/bin/tone-snapshot" prune
  chk "snapshot prune(apt は10件まで)" "[ \$(ls '$T/snaps' | grep -c -- '-apt\$') -le 10 ]"
  chk "snapshot 不正名を拒否" "! bash '$OV/usr/local/bin/tone-snapshot' restore '../x' 2>/dev/null"
  unset TONE_SNAP_DIR TONE_BTRFS_BIN TONE_FORCE_BTRFS TONE_ROOT_SNAP
  # --- TONEアップデート ---
  local U=$OV/usr/local/bin/tone-os-update R=$OV/usr/share/tone-os/tools/tone-release K=$KEYDIR/test-update-key.pem
  if [ -f "$K" ]; then
    local ROOT=$T/root REL=$T/rel PAY=$T/pay
    mkdir -p "$ROOT"/{usr/share/tone-os/keys,etc/tone-os,var/lib/tone-os,usr/local/bin} "$PAY/usr/share/tone-os"
    cp "$OV/usr/share/tone-os/keys/update-pub.pem" "$ROOT/usr/share/tone-os/keys/"; cp "$OV/etc/tone-os/update.conf" "$ROOT/etc/tone-os/"
    echo 1.0.0 > "$ROOT/usr/share/tone-os/version"; : > "$ROOT/usr/share/tone-os/CHANGELOG.txt"
    printf '#!/bin/bash\nif [ "$1" = create ]; then echo 20261010-120000-update; fi; if [ "$1" = restore ]; then echo "$2" > %s/restored; fi; exit 0\n' "$T" > "$T/bin/snapstub"; chmod +x "$T/bin/snapstub"
    echo hello > "$PAY/usr/share/tone-os/hello.txt"
    sed -i "s#^SOURCES=.*#SOURCES=\"file://$REL\"#; s#^HEALTH_CMD=.*#HEALTH_CMD=\"\"#" "$ROOT/etc/tone-os/update.conf"
    export TONE_ROOT=$ROOT TONE_SNAPSHOT_CMD=$T/bin/snapstub TONE_NO_REBOOT=1 TONE_SIGN_KEY=$K
    python3 "$R" pack "$REL" 1.0.1 "$PAY" --notes "テスト" >/dev/null
    python3 "$U" check >/dev/null; rc=$?; chk "update check rc=10" "[ $rc = 10 ]"
    python3 "$U" apply >/dev/null; chk "update apply(署名OK→反映)" "[ -f '$ROOT/usr/share/tone-os/hello.txt' ] && [ \"\$(cat '$ROOT/usr/share/tone-os/version')\" = 1.0.1 ]"
    python3 "$U" apply >/dev/null; chk "同じ版・古い版へは更新しない" "[ \"\$(cat '$ROOT/usr/share/tone-os/version')\" = 1.0.1 ]"
    # 改ざん: 目録 / パッケージ / 危険なパス / 許可外の場所
    echo 1.0.0 > "$ROOT/usr/share/tone-os/version"; rm -f "$ROOT/usr/share/tone-os/hello.txt"
    cp "$REL/manifest.json" "$T/m.bak"; sed -i 's/"1.0.1"/"1.0.9"/' "$REL/manifest.json"
    python3 "$U" apply >/dev/null; chk "目録を改ざん→署名不一致で拒否" "[ ! -f '$ROOT/usr/share/tone-os/hello.txt' ]"
    cp "$T/m.bak" "$REL/manifest.json"; cp "$REL"/tone-core-1.0.1.tar.xz "$T/p.bak"; echo x >> "$REL/tone-core-1.0.1.tar.xz"
    python3 "$U" apply >/dev/null; chk "パッケージを改ざん→ハッシュ不一致で拒否" "[ ! -f '$ROOT/usr/share/tone-os/hello.txt' ]"
    cp "$T/p.bak" "$REL/tone-core-1.0.1.tar.xz"
    mkdir -p "$T/bad/etc"; echo evil > "$T/bad/etc/passwd"; python3 "$R" pack "$T/rel2" 1.0.2 "$T/bad" >/dev/null
    sed -i "s#^SOURCES=.*#SOURCES=\"file://$T/rel2\"#" "$ROOT/etc/tone-os/update.conf"; python3 "$U" apply >/dev/null
    chk "許可されていない場所(etc/passwd)は署名が正しくても拒否" "[ ! -f '$ROOT/etc/passwd' ] && [ \"\$(cat '$ROOT/usr/share/tone-os/version')\" = 1.0.0 ]"
    python3 - "$T" <<'__PY__'
import tarfile, io, sys, os, subprocess, hashlib, json
t = sys.argv[1]; os.makedirs(t + "/rel3", exist_ok=True)
with tarfile.open(t + "/rel3/tone-core-1.0.3.tar.xz", "w:xz") as tf:
    i = tarfile.TarInfo("payload/../../escape.txt"); d = b"x"; i.size = 1; tf.addfile(i, io.BytesIO(d))
h = hashlib.sha256(open(t + "/rel3/tone-core-1.0.3.tar.xz", "rb").read()).hexdigest()
json.dump({"format": 1, "os_version": "1.0.3", "min_version": "1.0.0", "packages": [{"file": "tone-core-1.0.3.tar.xz", "sha256": h}]}, open(t + "/rel3/manifest.json", "w"))
subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["TONE_SIGN_KEY"], "-out", t + "/rel3/manifest.json.sig", t + "/rel3/manifest.json"], check=True)
__PY__
    sed -i "s#^SOURCES=.*#SOURCES=\"file://$T/rel3\"#" "$ROOT/etc/tone-os/update.conf"; python3 "$U" apply >/dev/null
    chk "../ を含むパッケージは署名が正しくても拒否" "[ ! -e '$T/escape.txt' ] && [ \"\$(cat '$ROOT/usr/share/tone-os/version')\" = 1.0.0 ]"
    # ヘルスチェック不合格 → 自動で戻す(スナップショットの restore が呼ばれる)
    sed -i "s#^SOURCES=.*#SOURCES=\"file://$REL\"#; s#^HEALTH_CMD=.*#HEALTH_CMD=\"/bin/false\"#" "$ROOT/etc/tone-os/update.conf"
    python3 "$U" apply >/dev/null; python3 "$U" confirm >/dev/null
    chk "更新後の確認に不合格→自動で元へ(restore呼び出し)" "[ -f '$T/restored' ] && grep -q 20261010-120000-update '$T/restored'"
    # 鍵の差し替え: 現在の鍵で署名された新しい公開鍵だけ受け付ける
    openssl ecparam -name prime256v1 -genkey -noout -out "$T/k2.pem"; openssl ec -in "$T/k2.pem" -pubout -out "$T/k2pub.pem" 2>/dev/null
    openssl dgst -sha256 -sign "$K" -out "$T/k2pub.sig" "$T/k2pub.pem"; python3 "$U" rotate-key "$T/k2pub.pem" "$T/k2pub.sig" >/dev/null
    chk "鍵の差し替え(現在の鍵の署名つき)" "ls '$ROOT'/etc/tone-os/keys.d/*.pem >/dev/null 2>&1"
    openssl dgst -sha256 -sign "$T/k2.pem" -out "$T/k3.sig" "$T/k2pub.pem"; rm -f "$ROOT"/etc/tone-os/keys.d/*.pem
    python3 "$U" rotate-key "$T/k2pub.pem" "$T/k3.sig" >/dev/null; chk "鍵の差し替え(署名なし/他人の鍵)は拒否" "! ls '$ROOT'/etc/tone-os/keys.d/*.pem >/dev/null 2>&1"
    unset TONE_ROOT TONE_SNAPSHOT_CMD TONE_NO_REBOOT TONE_SIGN_KEY
  else log "公開鍵が本番用のため、署名つき更新の通し検査は省略します(秘密鍵はこのPCにありません)"; fi
  # --- 電源 ---
  local SYS=$T/sys; mkdir -p "$SYS/class/dmi/id" "$SYS/class/power_supply/BAT0" "$SYS/class/power_supply/AC" "$SYS/class/thermal/thermal_zone0"
  echo 10 > "$SYS/class/dmi/id/chassis_type"; echo Mains > "$SYS/class/power_supply/AC/type"; echo 1 > "$SYS/class/power_supply/AC/online"
  echo 55000 > "$SYS/class/thermal/thermal_zone0/temp"; echo 60 > "$SYS/class/power_supply/BAT0/capacity"; echo Discharging > "$SYS/class/power_supply/BAT0/status"
  echo 40000000 > "$SYS/class/power_supply/BAT0/energy_full"; echo 50000000 > "$SYS/class/power_supply/BAT0/energy_full_design"; echo 120 > "$SYS/class/power_supply/BAT0/cycle_count"
  local PW="python3 $OV/usr/local/bin/tone-power"; export TONE_ROOT=$T/proot TONE_SYS=$SYS; mkdir -p "$T/proot"
  chk "電源: ノート判別(chassis=10)" "[ \"\$($PW detect)\" = notebook ]"
  echo 3 > "$SYS/class/dmi/id/chassis_type"; chk "電源: デスク判別(chassis=3)" "[ \"\$($PW detect)\" = desktop ]"
  rm -f "$SYS/class/dmi/id/chassis_type"; chk "電源: 判別できなければノート(安全側)" "[ \"\$($PW detect)\" = notebook ]"
  chk "電源: 電池の劣化表示(80%)" "$PW battery | grep -q '80.0%'"
  $PW ai-on >/dev/null; chk "電源: AI導入で前の値を記録" "grep -q prev '$T/proot/var/lib/tone-os/power.json'"
  $PW mode desktop >/dev/null; $PW ai-off >/dev/null
  chk "電源: AI撤去で導入前のモードへ戻る" "grep -q 'MODE=auto' '$T/proot/etc/tone-os/power.conf'"
  rm -rf "$SYS/class/thermal"; chk "電源: 温度センサーなしでは、ふた閉じ稼働を選べない" "! $PW lid-run on >/dev/null 2>&1"
  mkdir -p "$SYS/class/thermal/thermal_zone0"; echo 50000 > "$SYS/class/thermal/thermal_zone0/temp"; $PW mode notebook >/dev/null
  chk "電源: 温度センサーありのノートでは、ふた閉じ稼働を選べる" "$PW lid-run on >/dev/null 2>&1"
  unset TONE_ROOT TONE_SYS
  # --- 世界観テーマ ---
  export HOME=$T/home TONE_THEME_DRY=1 TONE_WORLDS=$OV/usr/share/tone-os/worlds.json; mkdir -p "$HOME"
  chk "テーマ: 6つの世界観" "[ \$(python3 '$OV/usr/local/bin/tone-theme' list | wc -l) = 6 ]"
  python3 "$OV/usr/local/bin/tone-theme" set 4_kyoto --style mac >/dev/null
  chk "テーマ: 色の定義ができる" "grep -q 'Name=TONE 京都の歴史' '$HOME/.local/share/color-schemes/TONE4kyoto.colors'"
  chk "テーマ: 設定を保存" "grep -q 4_kyoto '$HOME/.config/tone-os/theme.json' && grep -q mac '$HOME/.config/tone-os/theme.json'"
  chk "テーマ: 不正な世界観IDを拒否" "! python3 '$OV/usr/local/bin/tone-theme' set ../x >/dev/null 2>&1"
  bash "$OV/usr/local/bin/tone-dolphin-profile" mac; chk "Dolphin(Mac風): Enterで名前の変更・Ctrl系の割り当て" "grep -q 'name=\"rename\" shortcut=\"Return; F2\"' '$HOME/.local/share/kxmlgui5/dolphin/dolphinui.rc'"
  bash "$OV/usr/local/bin/tone-dolphin-profile" win; chk "Dolphin(Windows風): 標準の割り当てに戻る" "[ ! -f '$HOME/.local/share/kxmlgui5/dolphin/dolphinui.rc' ]"
  for w in 1_floyd 2_koya 3_minobu 4_kyoto 5_nara 6_jsdf; do n=$(ls "$OV/usr/share/tone-os/wallpapers/$w"/*.jpg 2>/dev/null | wc -l); chk "壁紙: $w が6枚以上" "[ $n -ge 6 ]"; done
  unset TONE_THEME_DRY TONE_WORLDS; export HOME=/root
  # --- 壁紙ギャラリー(署名つき目録・ハッシュ不一致は捨てる) ---
  if [ -f "$K" ]; then
    local WP=$T/wp; mkdir -p "$WP/1_floyd" "$T/wpdest"; convert -size 64x64 xc:red "$WP/1_floyd/7.jpg"; convert -size 64x64 xc:blue "$WP/1_floyd/8.jpg"
    python3 - "$WP" <<'__PY__'
import json, hashlib, sys
w = sys.argv[1]; sh = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
L = [{"world": "1_floyd", "file": "1_floyd/7.jpg", "thumb": "1_floyd/7.jpg", "sha256": sh(w + "/1_floyd/7.jpg"), "size": 1000, "license": "CC0", "author": "t", "title": "七"},
     {"world": "1_floyd", "file": "1_floyd/8.jpg", "thumb": "1_floyd/8.jpg", "sha256": "0" * 64, "size": 1000, "license": "CC0", "author": "t", "title": "八(ハッシュ偽)"},
     {"world": "1_floyd", "file": "../evil.jpg", "thumb": "", "sha256": "0" * 64, "size": 10, "license": "CC0"},
     {"world": "1_floyd", "file": "1_floyd/9.jpg", "thumb": "", "sha256": "1" * 64, "size": 10, "license": "著作権あり"}]
json.dump({"format": 1, "wallpapers": L}, open(w + "/wp-manifest.json", "w"), ensure_ascii=False)
__PY__
    openssl dgst -sha256 -sign "$K" -out "$WP/wp-manifest.json.sig" "$WP/wp-manifest.json"
    export TONE_WP_BASE=file://$WP TONE_WP_DEST=$T/wpdest TONE_UPDATE_PUB=$OV/usr/share/tone-os/keys/update-pub.pem
    chk "壁紙ギャラリー: 不正な項目(../・ライセンス不明)は一覧に出ない" "[ \$(python3 '$OV/usr/local/bin/tone-wallpaper-gallery' --list | wc -l) = 2 ]"
    python3 "$OV/usr/local/bin/tone-wallpaper-gallery" --get 1_floyd/7.jpg; chk "壁紙ギャラリー: 選んだ1枚だけ取る" "[ -f '$T/wpdest/1_floyd/7.jpg' ]"
    python3 "$OV/usr/local/bin/tone-wallpaper-gallery" --get 1_floyd/8.jpg; chk "壁紙ギャラリー: ハッシュが合わないものは捨てる" "[ ! -f '$T/wpdest/1_floyd/8.jpg' ]"
    chk "壁紙ギャラリー: 取得済みは差分に出ない" "[ \$(python3 '$OV/usr/local/bin/tone-wallpaper-gallery' --list | wc -l) = 1 ]"
    echo x >> "$WP/wp-manifest.json"; chk "壁紙ギャラリー: 目録の署名が合わなければ使わない" "! python3 '$OV/usr/local/bin/tone-wallpaper-gallery' --list >/dev/null 2>&1"
    unset TONE_WP_BASE TONE_WP_DEST TONE_UPDATE_PUB
  fi
  # --- アプリ更新(版の比較はプログラム) ---
  printf '#!/bin/bash\ncase "$1" in libreoffice-core) printf "Installed: 4:26.2.5-0\\nCandidate: 4:26.2.6-0\\n";; google-chrome-stable) printf "Installed: 1.0\\nCandidate: 1.0\\n";; *) printf "Installed: (none)\\nCandidate: (none)\\n";; esac\n' > "$T/bin/aptpol"; chmod +x "$T/bin/aptpol"
  r=$(TONE_APT_POLICY=$T/bin/aptpol TONE_APP_SOURCES=$OV/usr/share/tone-os/app-sources.json python3 "$OV/usr/local/bin/tone-app-update" check)
  chk "アプリ更新: LibreOfficeだけ新しい版を検出" "echo '$r' | grep -q 'libreoffice' && ! echo '$r' | grep -q chrome"
  # --- USB(書き込み・検証・強制真っ白): ループデバイスが使えれば本物のブロックデバイスで、無ければ通常ファイルで ---
  head -c 8M /dev/urandom > "$T/t.iso"; truncate -s 64M "$T/usb.img"
  export TONE_LANG=ja; export TONE_USB_TEST=1; US="$OV/usr/local/lib/tone-usb/usb-root"
  sz=$(stat -c %s "$T/usb.img")
  bash "$US" flash "$T/t.iso" "$T/usb.img" "$sz" "" >"$T/usb.log" 2>&1; chk "USB: 書き込み+SHA-256検証 → 検証済み" "grep -q '^@@M_VERIFIED' '$T/usb.log'"
  chk "USB: 容量が違えば(入れ替わり)拒否" "! bash '$US' flash '$T/t.iso' '$T/usb.img' 999 '' >/dev/null 2>&1"
  command -v sgdisk >/dev/null && sgdisk -n1:2048:+20M "$T/usb.img" >/dev/null 2>&1; mkfs.ext4 -q -F "$T/usb.img" >/dev/null 2>&1 || true
  bash "$US" wipe "$T/usb.img" quick "$sz" "" >"$T/usb3.log" 2>&1; chk "USB: 強制真っ白(先頭と末尾がゼロ)" "[ \"\$(head -c 1048576 '$T/usb.img' | tr -d '\\0' | wc -c)\" = 0 ] && [ \"\$(tail -c 1048576 '$T/usb.img' | tr -d '\\0' | wc -c)\" = 0 ]"
  chk "USB: 強制真っ白(ファイルシステム署名が残らない)" "[ -z \"\$(wipefs '$T/usb.img' 2>/dev/null)\" ]"
  command -v sgdisk >/dev/null && chk "USB: 強制真っ白(パーティション表が残らない)" "! sgdisk -p '$T/usb.img' 2>&1 | grep -q 'GPT: present'"
  dd if=/dev/urandom of="$T/usb.img" bs=1M count=64 conv=notrunc status=none; ( ulimit -f 262144; bash "$US" wipe "$T/usb.img" full "$sz" "" >"$T/usb4.log" 2>&1 )
  chk "USB: 完全消去(全体がゼロ)" "[ \"\$(tr -d '\\0' < '$T/usb.img' | wc -c)\" = 0 ]"
  # 全部入り: 完全消去→書き込み→検証(+ISO照合)。工程番号が出る
  dd if=/dev/urandom of="$T/usb.img" bs=1M count=64 conv=notrunc status=none; ( cd "$T" && sha256sum t.iso > t.iso.sha256 )
  ( ulimit -f 262144; bash "$US" flash "$T/t.iso" "$T/usb.img" "$sz" "" full eject >"$T/usb5.log" 2>&1 ); rc=$?
  chk "USB(全部入り): 照合OK→書き込み→検証済みまで通る(工程1〜5が出る)" "[ $rc = 0 ] && grep -q '^@@M_ISOOK' '$T/usb5.log' && grep -q '^@@M_S5' '$T/usb5.log' && grep -q '^@@M_VERIFIED' '$T/usb5.log'"
  chk "USB(全部入り): 書いた内容がISOと一致" "[ \"\$(head -c $(stat -c %s $T/t.iso) '$T/usb.img' | sha256sum)\" = \"\$(sha256sum < '$T/t.iso')\" ]"
  chk "USB(全部入り): 取り外しの案内が出る(失敗にはしない)" "grep -qE '^@@M_(EJECTED|SYNCED|EJECT_MANUAL)' '$T/usb5.log'"
  echo "0000000000000000000000000000000000000000000000000000000000000000  t.iso" > "$T/t.iso.sha256"
  dd if=/dev/zero of="$T/usb.img" bs=1M count=2 conv=notrunc status=none
  bash "$US" flash "$T/t.iso" "$T/usb.img" "$sz" "" full >"$T/usb6.log" 2>&1; rc=$?
  chk "USB(全部入り): ISOの照合が違えば、USBに触らず中止(終了コード3)" "[ $rc = 3 ] && grep -q '^@@E_ISOBAD' '$T/usb6.log' && [ \"\$(head -c 1048576 '$T/usb.img' | tr -d '\\0' | wc -c)\" = 0 ]"
  rm -f "$T/t.iso.sha256"
  # 本物のブロックデバイス用の名前が消えても、dd が普通のファイルを作らない(TONE_USB_TEST を外して確認)
  ( unset TONE_USB_TEST; ND=$T/nodev; : > "$ND"; rm -f "$ND"; dd if="$T/t.iso" of="$ND" bs=1M conv=nocreat,notrunc status=none 2>/dev/null; echo $? > "$T/nc.rc" )
  chk "USB: 名前の消えたデバイスへ dd しても、普通のファイルを作らない" "[ ! -e '$T/nodev' ] && [ \"\$(cat '$T/nc.rc')\" != 0 ]"
  chk "USB: usb-root の dd はすべて conv=nocreat つき" "! grep 'of=\"\$dev\"' '$US' | grep -v nocreat | grep -q ."
  bash "$US" flash "$T/t.iso" >"$T/usb7.log" 2>&1; rc=$?
  chk "USB: 引数が足りなければ、理由を言って中止(謎の「3: パラメータ」を出さない)" "[ $rc = 2 ] && grep -q '^@@E_NOARGS3' '$T/usb7.log'"
  bash "$US" flash "$T/t.iso" "$T/usb.img" "$sz" - >"$T/usb8.log" 2>&1; chk "USB: シリアルが無いときの「-」を受け付ける" "grep -q '^@@M_VERIFIED' '$T/usb8.log'"
  # --- 言語(ja/en/追加言語)。言語ファイルは「データ」として読み、実行しない ---
  GU="$OV/usr/local/bin/tone-usb-flash"; LD="$OV/usr/local/share/tone-usb/lang"
  chk "言語: 日本語と英語の言語ファイルのキーが一致" "diff <(grep -v '^#' '$LD/ja.lang' | cut -d= -f1) <(grep -v '^#' '$LD/en.lang' | cut -d= -f1)"
  chk "言語: usb-root が出す全コード(E_/M_)が、ja・en 両方の言語ファイルにある" "for c in \$(grep -o '\"\(E\|M\)_[A-Z0-9_]*[|\"]' '$US' | tr -d '\"|' | sort -u); do grep -q \"^\$c=\" '$LD/ja.lang' && grep -q \"^\$c=\" '$LD/en.lang' || { echo missing \$c; exit 1; }; done"
  mk_t() { sed -n '/^declare -A TL/,/^load_all_lang$/{/^load_all_lang$/!p}' "$GU"; echo "LANG_DIRS=(\"$1\"); TONE_LANG=$2; HOME=/nonexistent"; echo load_all_lang; sed -n '/^t() {/,/^}/p' "$GU"; sed -n '/^tlog() {/,/^}/p' "$GU"; }
  mk_t "$LD" ja > "$T/tfn_ja.sh"; mk_t "$LD" en > "$T/tfn_en.sh"; mk_t "$LD" fr_FR > "$T/tfn_fr.sh"
  chk "言語: 日本語環境なら日本語の文言" "[ \"\$(bash -c 'source $T/tfn_ja.sh; t wipe_done')\" = '真っ白になりました。' ]"
  chk "言語: 英語環境なら英語の文言" "[ \"\$(bash -c 'source $T/tfn_en.sh; t wipe_done')\" = 'The drive is now blank.' ]"
  chk "言語: 未対応の言語(fr)は英語に切り替わる" "[ \"\$(bash -c 'source $T/tfn_fr.sh; t wipe_done')\" = 'The drive is now blank.' ]"
  chk "言語: 値の差し込み(%1 %2)と、root側コードの翻訳" "[ \"\$(printf '@@E_NOARGS2|/dev/x|0\n' | bash -c 'source $T/tfn_en.sh; tlog')\" = 'Missing arguments (device=/dev/x size=0). The front end could not read the capacity' ]"
  mkdir -p "$T/ul"; printf 'wipe_done=ARABIC TEST\nevil=$(touch %s/PWNED)\nM_WIPED=`touch %s/PWNED2`\n' "$T" "$T" > "$T/ul/ar.lang"
  mk_t "$LD\" \"$T/ul" ar > "$T/tfn_ar.sh"
  chk "言語: 追加した言語ファイル(ar.lang)が使え、足りない文言は英語で補う" "[ \"\$(bash -c 'source $T/tfn_ar.sh; t wipe_done')\" = 'ARABIC TEST' ] && [ \"\$(bash -c 'source $T/tfn_ar.sh; t how_quick')\" = 'Quick erase (a few seconds)' ]"
  chk "言語: 言語ファイルに書かれたコマンドは実行されない(データとして読むだけ)" "bash -c 'source $T/tfn_ar.sh; t M_WIPED' >/dev/null; [ ! -e '$T/PWNED' ] && [ ! -e '$T/PWNED2' ]"
  # 言語の設定ファイル(環境が英語でも、日本語に固定できる)
  mkdir -p "$T/cfgh/.config/tone-usb"; echo ja > "$T/cfgh/.config/tone-usb/language"
  chk "言語: 設定ファイル(language に ja)があれば、環境が英語でも日本語になる" "[ \"\$(env -u TONE_LANG LANG=en_US.UTF-8 HOME=$T/cfgh bash -c 'source <(sed -n \"/^pick_lang()/,/^}/p\" \"$GU\"); pick_lang')\" = ja ]"
  chk "言語: 環境変数 TONE_LANG は設定ファイルより優先" "[ \"\$(env TONE_LANG=en LANG=ja_JP.UTF-8 HOME=$T/cfgh bash -c 'source <(sed -n \"/^pick_lang()/,/^}/p\" \"$GU\"); pick_lang')\" = en ]"
  unset TONE_USB_TEST
  # --- インストールガイド: 保存したデータの照合(1つでも違えば先へ進ませない) ---
  mkdir -p "$T/g/src/a/b" "$T/g/dst"; echo one > "$T/g/src/a/1.txt"; head -c 5000 /dev/urandom > "$T/g/src/a/b/2.bin"
  rsync -a "$T/g/src/" "$T/g/dst/"
  chk "ガイド: 正しくコピーできたら照合に合格" "( TONE_GUIDE_LIB=1; source '$OV/usr/local/bin/tone-install-guide'; verify_copy '$T/g/src' '$T/g/dst' )"
  echo two > "$T/g/dst/a/1.txt"; chk "ガイド: 中身が1文字違えば失敗(同じ件数・同じ容量でも)" "! ( TONE_GUIDE_LIB=1; source '$OV/usr/local/bin/tone-install-guide'; verify_copy '$T/g/src' '$T/g/dst' )"
  rsync -a "$T/g/src/" "$T/g/dst/"; rm "$T/g/dst/a/b/2.bin"; chk "ガイド: ファイルが欠けたら失敗" "! ( TONE_GUIDE_LIB=1; source '$OV/usr/local/bin/tone-install-guide'; verify_copy '$T/g/src' '$T/g/dst' )"
  # --- USBツールの画面部分(偽の lsblk/kdialog で、候補の絞り込みと root へ渡す引数を確かめる) ---
  mkdir -p "$T/stub"
  cat > "$T/stub/lsblk" <<'__F__'
#!/bin/bash
case "$*" in
  *"-bdnP"*)
    if [ "${LSBLK_SET:-usbs}" = none ]; then cat <<'__L__'
KNAME="sda" TYPE="disk" SIZE="500000000000" RM="0" TRAN="sata" MODEL="Internal SSD" ROTA="0" SERIAL="INT1" HOTPLUG="0"
KNAME="sdf" TYPE="disk" SIZE="1000000000000" RM="0" TRAN="sata" MODEL="Data Disk" ROTA="1" SERIAL="INT2" HOTPLUG="0"
__L__
    else cat <<'__L__'
KNAME="sda" TYPE="disk" SIZE="500000000000" RM="0" TRAN="sata" MODEL="Internal SSD" ROTA="0" SERIAL="INT1" HOTPLUG="0"
KNAME="sdb" TYPE="disk" SIZE="16000000000" RM="1" TRAN="usb" MODEL="USB Stick" ROTA="0" SERIAL="ABC123" HOTPLUG="1"
KNAME="sdc" TYPE="disk" SIZE="2000000000000" RM="0" TRAN="usb" MODEL="USB HDD" ROTA="1" SERIAL="HDD1" HOTPLUG="1"
KNAME="sdd" TYPE="disk" SIZE="8000000000" RM="1" TRAN="usb" MODEL="ISO holder" ROTA="0" SERIAL="ISO1" HOTPLUG="1"
KNAME="sde" TYPE="disk" SIZE="32000000000" RM="1" TRAN="usb" MODEL="Rotational Stick" ROTA="1" SERIAL="STK1" HOTPLUG="1"
KNAME="sdf" TYPE="disk" SIZE="1000000000000" RM="0" TRAN="sata" MODEL="Data Disk" ROTA="1" SERIAL="INT2" HOTPLUG="0"
KNAME="loop0" TYPE="loop" SIZE="1000" RM="0" TRAN="" MODEL="" ROTA="0" SERIAL="" HOTPLUG="0"
__L__
    fi ;;
  *"-slnpo"*"/dev/sda2"*) printf '/dev/sda2 part\n/dev/sda disk\n' ;;
  *"-slnpo"*"/dev/sdd1"*) printf '/dev/sdd1 part\n/dev/sdd disk\n' ;;
  *"-bdno SIZE"*) echo 16000000000 ;;
esac
__F__
  printf '#!/bin/bash\ncase "$*" in "-n -o SOURCE /") echo /dev/sda2;; "-n -o SOURCE -T"*) echo /dev/sdd1;; esac\n' > "$T/stub/findmnt"
  printf '#!/bin/bash\necho 16000000000\n' > "$T/stub/blockdev"
  printf '#!/bin/bash\necho "$@" >> %s/pk.log; exit 0\n' "$T" > "$T/stub/pkexec"
  cat > "$T/stub/kdialog" <<'__F__'
#!/bin/bash
echo "ARGS: $*" >> "$KD_LOG"
case "$*" in
  *"--menu"*"何をしますか"*|*"--menu"*"What would you like"*) echo "${KD_MODE:-flash}";;
  *"--menu"*"消し方"*) echo quick;;
  *"--menu"*"対象を選んで"*|*"--menu"*"Choose the target"*) echo "$@" | tr ' ' '\n' | grep '^/dev/' | head -1;;
  *"--inputbox"*) echo "${KD_ANS:-}";;
  *"--yesno"*|*"--warningyesno"*) exit 0;;
  *"--msgbox"*|*"--error"*) echo "MSG: $*" >> "$KD_LOG"; exit 0;;
esac
__F__
  chmod +x "$T/stub"/*; head -c 1000 /dev/urandom > "$T/pick.iso"
  env KD_MODE=flash PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash' '$T/pick.iso'" >/dev/null 2>&1
  M=$(grep -- '--menu.*対象を選んで' "$T/kd.log")
  chk "USBツール(書き込み): 候補は sdb と、回転式と報告するUSBメモリ sde だけ" "echo \"\$M\" | grep -q '/dev/sdb ' && echo \"\$M\" | grep -q '/dev/sde ' && ! echo \"\$M\" | grep -qE '/dev/sd[acdf] |/dev/loop'"
  chk "USBツール(書き込み): 大容量の外付けHDD・起動ディスク・ISOの入った装置・内蔵2台目は出ない" "! echo \"\$M\" | grep -qE '/dev/sdc |/dev/sda |/dev/sdd |/dev/sdf '"
  chk "USBツール: root へ ISO・デバイス・容量・シリアルを引数で渡す" "grep -q 'usb-root flash $T/pick.iso /dev/sdb 16000000000 ABC123' '$T/pk.log'"
  env KD_MODE=combo PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash' '$T/pick.iso'" >/dev/null 2>&1
  chk "USBツール(全部入り): root へ full eject つきで渡す" "grep -q 'usb-root flash $T/pick.iso /dev/sdb 16000000000 ABC123 full eject' '$T/pk.log'"
  chk "USBツール: 終わったら結果のダイアログを必ず出す(成功でも失敗でも)" "grep -q '^MSG: .*検証済み' '$T/kd.log'"
  env KD_MODE=wipe KD_ANS=/sdb PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash'" >/dev/null 2>&1
  M=$(grep -- '--menu.*対象を選んで' "$T/kd.log")
  chk "USBツール(強制真っ白): 外付けHDDも含めて出る。起動ディスクと内蔵2台目は出ない" "echo \"\$M\" | grep -q '/dev/sdc ' && echo \"\$M\" | grep -q '/dev/sdb ' && echo \"\$M\" | grep -q '/dev/sde ' && ! echo \"\$M\" | grep -qE '/dev/sda |/dev/sdf '"
  chk "USBツール(強制真っ白): root へ消去を引数で渡す(USBなので any は付かない)" "grep -qx '.*usb-root wipe /dev/sdb quick 16000000000 ABC123' '$T/pk.log'"
  chk "USBツール(強制真っ白): USBでは文字の入力を求めない(はい/いいえの確認だけ)" "! grep -q -- '--inputbox' '$T/kd.log' && grep -q -- '--warningyesno.*強制真っ白' '$T/kd.log'"
  env KD_MODE=wipe KD_ANS=xxxx LSBLK_SET=none PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash'" >/dev/null 2>&1
  chk "USBツール(強制真っ白): 内蔵ディスクで入力が違えば消さない" "grep -q -- '--inputbox' '$T/kd.log' && [ ! -s '$T/pk.log' ]"
  env KD_MODE=wipe KD_ANS=/dev/sdf LSBLK_SET=none PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash'" >/dev/null 2>&1
  chk "USBツール(強制真っ白): USBが無ければ、内蔵を含む全ディスクから選べる(起動ディスクは出ない)" "grep -q '見つかったディスク' '$T/kd.log' && grep -q -- '--menu.*対象を選んで.*/dev/sdf ' '$T/kd.log' && ! grep -- '--menu.*対象を選んで' '$T/kd.log' | grep -q '/dev/sda '"
  chk "USBツール(強制真っ白): 内蔵ディスクは、全体名の入力で初めて any つきで渡す" "grep -qx '.*usb-root wipe /dev/sdf quick 16000000000 INT2 any' '$T/pk.log'"
  env KD_MODE=flash LSBLK_SET=none PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash' '$T/pick.iso'" >/dev/null 2>&1
  chk "USBツール(書き込み): 見つからないときは、見つかったディスクと除外の理由を表示する" "grep -q '除外: いま動いているシステムのディスク' '$T/kd.log' && grep -q 'USBではない' '$T/kd.log'"
  env TONE_LANG=en KD_MODE=combo PATH=$T/stub:$PATH KD_LOG=$T/kd.log HOME=$T/uhome bash -c ": > $T/kd.log; : > $T/pk.log; bash '$OV/usr/local/bin/tone-usb-flash' '$T/pick.iso'" >/dev/null 2>&1
  chk "言語: 英語環境では、メニューも確認も完了表示も英語で出る" "grep -q -- '--menu.*What would you like to do' '$T/kd.log' && grep -q -- '--menu.*Choose the target' '$T/kd.log' && grep -q '^MSG: .*All-in-one finished' '$T/kd.log'"
  mkdir -p "$T/sysb/sda"; echo 1 > "$T/sysb/sda/ro"
  printf '#!/bin/bash\n[ "$1" = --setrw ] || exit 0\nn=$(cat %s/n 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s/n\n[ $n -ge ${OK_AT:-2} ] && echo 0 > %s/sysb/sda/ro\nexit 0\n' "$T" "$T" "$T" > "$T/stub/blockdev"; chmod +x "$T/stub/blockdev"
  PATH=$T/stub:$PATH TONE_SYSBLOCK=$T/sysb OK_AT=2 bash "$OV/usr/local/lib/tone-usb/usb-root" makewritable /dev/sda >/dev/null 2>&1
  chk "USB: 読み取り専用の表示は、使っているものを外したあとに何度か解除を試して書き込み可能にする" "[ \"\$(cat '$T/sysb/sda/ro')\" = 0 ]"
  echo 1 > "$T/sysb/sda/ro"; rm -f "$T/n"
  PATH=$T/stub:$PATH TONE_SYSBLOCK=$T/sysb OK_AT=99 bash "$OV/usr/local/lib/tone-usb/usb-root" makewritable /dev/sda >"$T/ro.log" 2>&1; rc=$?
  chk "USB: どうしても書き込み禁止なら、理由と対処つきで失敗する(消したふりをしない)" "[ $rc = 4 ] && grep -q '^@@E_ROSTUCK' '$T/ro.log'"
  chk "USB: 動いているシステムを支えるディスクの判定(root は sda)" "[ \"\$(PATH=$T/stub:\$PATH bash '$OV/usr/local/lib/tone-usb/usb-root' sysdisks)\" = /dev/sda ]"
  # --- 構文 ---
  for f in "$OV"/usr/local/bin/tone-{snapshot,snapshot-apt,restore,os-update-notify,os-update-gui,health-check,autobright,theme-sddm,theme-gui,dolphin-profile,input-apply,app-update-gui,help-me,drivers,gpu-verify,boot-repair,backup,setup-wizard,install-guide,boot-anim,usb-flash} "$OV"/usr/local/lib/tone-usb/usb-root "$OV"/usr/share/tone-os/tools/tone-update-from-iso.sh; do
    bash -n "$f" 2>"$T/syn.err" || { echo "  NG  構文: $f"; cat "$T/syn.err"; ok=0; }
  done
  for f in "$OV"/usr/local/bin/tone-{os-update,power,theme,wallpaper-gallery,app-update} "$OV"/usr/share/tone-os/tools/tone-release; do python3 -m py_compile "$f" 2>"$T/syn.err" || { echo "  NG  構文(py): $f"; cat "$T/syn.err"; ok=0; }; done
  bash -n "$OV/usr/local/bin/tone-gpu-check" || ok=0
  rm -rf "$T"
  [ "$ok" = 1 ] || { log "★新しい部品の単体検査に失敗しました。上の NG を確認してください"; return 1; }
  log "新しい部品の単体検査: すべて合格"
}
test_modules || exit 1


# ---------------------------------------------------------------- 4. 起動画面テーマ生成
step "4. 起動アニメ(Plymouth)テーマ生成(回転体3種×細いシークバー・TONE OS・ToneInternetService.)"
PTH=$SRC/overlay/usr/share/plymouth/themes; rm -rf "$PTH"/tone*; mkdir -p "$PTH"
mkdir -p "$SRC/tools"; cat > "$SRC/tools/spin.py" <<'__PY__'
#!/usr/bin/env python3
# 起動アニメの回転体(カザグルマ/鳴門の渦/台風)を ImageMagick の -draw だけで描く(SVG対応に依存しない)
import sys, math, subprocess
kind, out = sys.argv[1], sys.argv[2]
S = 8.0; C = 400.0           # 100単位 = 800px(2倍)で描き、400pxへ縮小して滑らかにする
def pt(x, y): return "%.1f,%.1f" % (C + x * S, C + y * S)
def poly(pts): return "polygon " + " ".join(pt(*p) for p in pts)
def line(pts): return "polyline " + " ".join(pt(*p) for p in pts)
def rot(p, a): c, s = math.cos(a), math.sin(a); return (p[0] * c - p[1] * s, p[0] * s + p[1] * c)
def quad(p0, p1, p2, n=20):
    return [((1-t)**2*p0[0]+2*(1-t)*t*p1[0]+t*t*p2[0], (1-t)**2*p0[1]+2*(1-t)*t*p1[1]+t*t*p2[1]) for t in [i/n for i in range(n+1)]]
a = ["convert", "-size", "800x800", "xc:none", "-stroke", "none"]
if kind == "wind":
    cols = ["#f2f4fa", "#c9d2e6", "#9fb0d0", "#6f84ad"]
    for i in range(4):
        petal = [(0, 0), (0, -46)] + quad((0, -46), (30, -40), (40, -12))[1:]
        a += ["-fill", cols[i], "-draw", poly([rot(p, i * math.pi / 2) for p in petal])]
    a += ["-fill", "#0b0e14", "-stroke", "#e8ecf4", "-strokewidth", "12", "-draw", "circle %s %s" % (pt(0, 0), pt(4.5, 0))]
elif kind == "typhoon":
    a += ["-fill", "rgba(111,132,173,0.14)", "-draw", "circle %s %s" % (pt(0, 0), pt(44, 0))]
    arms = 4
    for k in range(arms):
        p1, p2 = [], []
        for i in range(41):
            t = i / 40.0; r = 9 + t * 36; an = k * 2 * math.pi / arms + t * 2.6
            w = (0.30 * (1 - t) + 0.05) * (1 + 0.3 * math.sin(t * 3))
            p1.append((r * math.cos(an - w), r * math.sin(an - w))); p2.append((r * math.cos(an + w), r * math.sin(an + w)))
        a += ["-fill", "rgba(230,237,248,%.2f)" % (0.95 - k * 0.07), "-draw", poly(p1 + p2[::-1])]
    a += ["-fill", "#0b0e14", "-stroke", "#cfe0f5", "-strokewidth", "10", "-draw", "circle %s %s" % (pt(0, 0), pt(7.5, 0))]
else:  # whirl
    n = 140; pts = [((3 + i / n * 44) * math.cos(i / n * math.pi * 5.2), (3 + i / n * 44) * math.sin(i / n * math.pi * 5.2)) for i in range(n + 1)]
    a += ["-fill", "none", "-stroke", "rgba(95,134,184,0.25)", "-strokewidth", "56", "-draw", line(pts),
          "-stroke", "rgba(207,224,245,0.9)", "-strokewidth", "24", "-draw", line(pts)]
a += ["-filter", "Lanczos", "-resize", "400x400", "-depth", "8", "PNG32:" + out]
subprocess.run(a, check=True)
__PY__
FONT=DejaVu-Sans
TMPB=$(mktemp -d)
# 文字は2倍の解像度(112px/40px)で作り、画面の高さ/2160 に縮小して 1080p で 56px/20px 相当にする
convert -background none -fill '#e8ecf4' -font "$FONT" -pointsize 112 -kerning 43 label:'TONE OS' -trim +repage "PNG32:$TMPB/title.png"
convert -background none -fill '#8b94a8' -font "$FONT" -pointsize 40 -kerning 5 label:'ToneInternetService.' -trim +repage "PNG32:$TMPB/footer.png"
convert -size 360x3 xc:'#2a3142' "PNG32:$TMPB/bar_track.png"          # 細いシークバー(線だけ・ロゴなし)
convert -size 360x3 xc:'#cfd6e6' "PNG32:$TMPB/bar_fill.png"
for kind in wind whirl typhoon; do python3 "$SRC/tools/spin.py" "$kind" "$TMPB/spin_$kind.png"; done
for kind in wind whirl typhoon; do
  TH=$PTH/tone-$kind; mkdir -p "$TH"
  cp "$TMPB"/title.png "$TMPB"/footer.png "$TMPB"/bar_track.png "$TMPB"/bar_fill.png "$TH/"; cp "$TMPB/spin_$kind.png" "$TH/spin.png"
  cat > "$TH/tone.script" <<'__PS__'
// TONE OS 起動アニメ: 上から「TONE OS」→ 回転体 → 細いシークバー(回転体の少し下)→ 下端にコーポレート表示
// 1920x1080 の基準値: タイトル上端430 / 回転体 中心578・直径100 / シークバー 656・幅360・太さ3 / コーポレート 下端から56
Window.SetBackgroundTopColor(0.043, 0.055, 0.078);
Window.SetBackgroundBottomColor(0.043, 0.055, 0.078);
sw = Window.GetWidth();
sh = Window.GetHeight();
k = sh / 1080;
k2 = sh / 2160;
t_src = Image("title.png");
f_src = Image("footer.png");
s_src = Image("spin.png");
tr_src = Image("bar_track.png");
fl_src = Image("bar_fill.png");
t = t_src.Scale(Math.Int(t_src.GetWidth() * k2), Math.Int(t_src.GetHeight() * k2));
f = f_src.Scale(Math.Int(f_src.GetWidth() * k2), Math.Int(f_src.GetHeight() * k2));
d = Math.Int(100 * k);
sp = s_src.Scale(d, d);
bw = Math.Int(360 * k);
bh = Math.Int(3 * k);
if (bh < 2) bh = 2;
tr = tr_src.Scale(bw, bh);
title = Sprite(t);
title.SetPosition(Math.Int((sw - t.GetWidth()) / 2), Math.Int(430 * k), 10);
footer = Sprite(f);
footer.SetPosition(Math.Int((sw - f.GetWidth()) / 2), Math.Int(sh - f.GetHeight() - 56 * k), 10);
cx = sw / 2;
cy = 578 * k;
spinner = Sprite(sp);
spinner.SetPosition(Math.Int(cx - d / 2), Math.Int(cy - d / 2), 10);
bx = Math.Int((sw - bw) / 2);
by = Math.Int(656 * k);
track = Sprite(tr);
track.SetPosition(bx, by, 10);
fill = Sprite(fl_src.Scale(1, bh));
fill.SetPosition(bx, by, 11);
angle = 0;
speed = 0.10;
frames = 0;
real = 0;
shown = 0;
fun set_bar(p) {
  w = Math.Int(global.bw * p);
  if (w < 1) w = 1;
  global.fill.SetImage(global.fl_src.Scale(w, global.bh));
  global.shown = p;
}
fun refresh_cb() {
  global.frames = global.frames + 1;
  global.angle = global.angle + global.speed;
  r = global.sp.Rotate(global.angle);
  global.spinner.SetImage(r);
  global.spinner.SetPosition(Math.Int(global.cx - r.GetWidth() / 2), Math.Int(global.cy - r.GetHeight() / 2), 10);
  // 進み具合の報告が無い起動でも、バーが止まって見えないように、ゆっくり進める(最大85%)
  fake = 0.85 * global.frames / (global.frames + 400);
  want = global.real;
  if (fake > want) want = fake;
  if (want > global.shown + 0.004) set_bar(want);
}
Plymouth.SetRefreshFunction(refresh_cb);
fun progress_cb(time, progress) {
  global.real = progress;
  global.speed = 0.08 + 0.22 * progress;
}
Plymouth.SetBootProgressFunction(progress_cb);
__PS__
  cat > "$TH/tone-$kind.plymouth" <<__PL__
[Plymouth Theme]
Name=TONE OS ($kind)
Description=TONE OS boot animation ($kind) with thin seek bar
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/tone-$kind
ScriptFile=/usr/share/plymouth/themes/tone-$kind/tone.script
__PL__
done
rm -rf "$TMPB"; chmod -R a+rX "$SRC/overlay/usr/share/plymouth"

# ---------------------------------------------------------------- 5. ベースシステム
mount_chroot() { for m in dev dev/pts proc sys run; do mountpoint -q "$ROOTFS/$m" || mount --bind "/$( [ $m = dev/pts ] && echo dev/pts || echo $m)" "$ROOTFS/$m"; done; }
umount_chroot() { for m in run sys proc dev/pts dev; do umount -lf "$ROOTFS/$m" 2>/dev/null || true; done; }
trap 'umount_chroot; type inst_cleanup >/dev/null 2>&1 && inst_cleanup' EXIT

step "5. debootstrap (Ubuntu 24.04 noble amd64)"
if [ ! -x "$ROOTFS/bin/bash" ]; then
  rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
  debootstrap --arch=amd64 --components=main,restricted,universe,multiverse noble "$ROOTFS" "$MIRROR"
fi
cat > "$ROOTFS/etc/apt/sources.list" <<__S__
deb $MIRROR noble main restricted universe multiverse
deb $MIRROR noble-updates main restricted universe multiverse
deb $MIRROR noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
__S__
net_on() { # ビルド中だけ: DNS共有・サービス自動起動を抑止
  rm -f "$ROOTFS/etc/resolv.conf"; cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"; chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"
}
net_off() { # 出荷前: ビルド専用の設定を撤去し、個体情報を空にする
  chroot "$ROOTFS" apt-get clean >/dev/null 2>&1 || true
  rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
  : > "$ROOTFS/etc/machine-id"; rm -f "$ROOTFS/var/lib/dbus/machine-id" "$ROOTFS"/etc/ssh/ssh_host_*
  rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* "$ROOTFS"/root/.bash_history "$ROOTFS"/root/.cache
  chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp" 2>/dev/null || true
}
net_on
echo tone-os > "$ROOTFS/etc/hostname"

# ---------------------------------------------------------------- 6. システム構成
step "6. システム構成(chroot)"
cat > "$ROOTFS/tmp/stage.sh" <<'__STAGE__'
#!/bin/bash
set -x
export DEBIAN_FRONTEND=noninteractive LANG=C TONE_SKIP_SNAP=1
apt_i() { apt-get install -y "$@"; }
opt()   { for p in "$@"; do apt-get install -y "$p" || echo "任意パッケージ導入失敗: $p"; done; }
dpkg --add-architecture i386
apt-get update
apt_i locales language-pack-ja language-pack-ja-base language-pack-kde-ja
sed -i 's/^# *ja_JP.UTF-8/ja_JP.UTF-8/' /etc/locale.gen; grep -q '^ja_JP.UTF-8' /etc/locale.gen || echo 'ja_JP.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen ja_JP.UTF-8; update-locale LANG=ja_JP.UTF-8 LANGUAGE=ja:en
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime; echo Asia/Tokyo > /etc/timezone

apt_i linux-generic linux-firmware casper initramfs-tools systemd-sysv sudo network-manager ca-certificates curl wget gnupg zip unzip \
  ubuntu-minimal ubuntu-standard grub-efi-amd64-signed shim-signed grub-pc os-prober squashfs-tools
apt_i rsync dosfstools parted gdisk efibootmgr grub-efi-amd64-bin xfsprogs btrfs-progs e2fsprogs udisks2 cryptsetup software-properties-common openssl
opt grub-btrfs inotify-tools mokutil lm-sensors iio-sensor-proxy brightnessctl upower smartmontools xinput ffmpeg
apt_i kde-plasma-desktop sddm plasma-nm plasma-pa plasma-discover plasma-discover-backend-flatpak flatpak
opt dolphin kate konsole ark okular gwenview kdialog zenity libnotify-bin kio-extras breeze-icon-theme kde-spectacle
opt plasma-firewall kde-config-gtk-style kde-config-sddm sddm-theme-breeze packagekit-tools xdg-desktop-portal-kde
apt_i fcitx5 fcitx5-mozc fcitx5-config-qt kde-config-fcitx5 im-config
opt fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-frontend-qt6 fcitx5-module-xorg
apt_i fonts-noto-cjk fonts-noto-color-emoji fonts-ipafont fonts-dejavu-core
apt_i python3-pyqt5 plymouth plymouth-label mpv imagemagick sox libsox-fmt-all
apt_i pipewire-audio wireplumber bluez cups system-config-printer ntfs-3g exfatprogs p7zip-full ubuntu-drivers-common fwupd packagekit
apt_i ufw clamav clamav-daemon clamav-freshclam unattended-upgrades chrony pciutils
# あらゆるamd64 PCに対応するための追加(任意扱い: 取得できなくても全体は止めない)
opt linux-generic-hwe-24.04 linux-generic-hwe-24.04-edge intel-microcode amd64-microcode thermald switcheroo-control
opt mesa-vulkan-drivers mesa-va-drivers intel-media-va-driver xserver-xorg-video-all xserver-xorg-input-all firmware-sof-signed
opt xprintidle dkms linux-headers-generic-hwe-24.04 qdbus-qt5
opt pkexec polkitd polkit-kde-agent-1 apparmor apparmor-utils apport zsh
opt partitionmanager gparted ntfs-3g
opt wpasupplicant iw rfkill modemmanager lvm2 mdadm systemd-zram-generator
opt open-vm-tools-desktop spice-vdagent qemu-guest-agent
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
opt calamares
apt-get install -y calamares || apt-get install -y calamares-settings-ubuntu
opt steam-installer
# Chrome
install -d /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update; apt_i google-chrome-stable
# 標準ゲーム削除(KDE/GNOME系)
apt-get purge -y 'kmahjongg*' 'kmines*' 'ksudoku*' 'kpat*' 'kdegames*' 'ksnakeduel*' 'kreversi*' 'klines*' 'kolf*' 'gnome-games*' 'aisleriot*' 'gnome-mines*' 'gnome-sudoku*' || true
apt-get autoremove -y || true
# LibreOffice: 公式PPA(ppa:libreoffice/ppa)を、LibreOfficeのパッケージだけに適用して使う(鍵は導入済み・指紋を確認)
if curl -fsI --max-time 20 https://ppa.launchpadcontent.net/libreoffice/ppa/ubuntu/dists/noble/Release >/dev/null 2>&1; then
  add-apt-repository -y ppa:libreoffice/ppa || echo "LibreOffice PPAの追加に失敗"
  if ! gpg --show-keys --with-colons /etc/apt/keyrings/*libreoffice* /etc/apt/trusted.gpg.d/*libreoffice* 2>/dev/null | grep -q 'CDDE43BA4DE3F09D7CE7016673AEE920AD55F5A0'; then
    echo "PPAの鍵の指紋が想定と違う/見つからないため、PPAは使いません(TDF公式版へ)"; rm -f /etc/apt/sources.list.d/*libreoffice*
  fi
  apt-get update || true
else echo "LibreOffice PPAに接続できません(TDF公式版へ)"; fi
/usr/local/bin/tone-lo-update --force || true
# 必須パッケージの最終確認(欠けていれば再導入)
for p in kde-plasma-desktop flatpak plasma-discover sddm fcitx5-mozc calamares ufw clamav chrony google-chrome-stable; do
  dpkg -s "$p" 2>/dev/null | grep -q 'ok installed' || apt-get install -y "$p"
done
# 設定
sed -i 's/^#\?DIR_MODE=.*/DIR_MODE=0755/' /etc/adduser.conf
grep -q '^HOME_MODE' /etc/login.defs && sed -i 's/^HOME_MODE.*/HOME_MODE 0755/' /etc/login.defs || echo 'HOME_MODE 0755' >> /etc/login.defs
sed -i 's/^ENABLED=.*/ENABLED=yes/; ' /etc/ufw/ufw.conf; sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
if grep -q '^Checks' /etc/clamav/freshclam.conf; then sed -i 's/^Checks.*/Checks 24/' /etc/clamav/freshclam.conf; else echo 'Checks 24' >> /etc/clamav/freshclam.conf; fi
cat /etc/environment.d/90-tone-ime.conf >> /etc/environment
echo 'ja' > /etc/skel/.config/.tone-lang 2>/dev/null || true
mkdir -p /usr/share/tone-os/chrome-policy
cp -f /etc/opt/chrome/policies/managed/tone.json /usr/share/tone-os/chrome-policy/tone.json
cp -f /usr/share/tone-os/index.html /usr/share/tone-os/index.html.master
/usr/local/bin/tone-fix-chrome
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
mkdir -p /etc/skel/ダウンロード /etc/skel/ドキュメント /etc/skel/ミュージック /etc/skel/ピクチャ /etc/skel/ビデオ
chmod -R a+rX /etc/skel /usr/share/tone-os
chmod 0440 /etc/sudoers.d/90-tone-nopasswd
for u in ufw chrony tone-freshclam.timer tone-av-full.timer tone-update.timer tone-ntp.timer tone-boot-scan.service tone-selftest.service tone-health.service tone-drivers.service tone-plymouth-quit.service tone-snapshot-weekly.timer tone-os-update-check.timer tone-os-update-confirm.service tone-gpu-verify.service sddm NetworkManager unattended-upgrades; do
  systemctl enable "$u" || echo "enable失敗: $u"; done
systemctl disable systemd-timesyncd 2>/dev/null || true
systemctl disable clamav-freshclam 2>/dev/null || true   # 定義更新は tone-freshclam.timer(起動1分後+選択間隔)に一本化
systemctl enable tone-heartbeat.service || echo "enable失敗: 見張り番"
# クラッシュ報告(Apport)
mkdir -p /etc/zsh; touch /etc/zsh/zshrc
[ -f /etc/default/apport ] && sed -i 's/^enabled=.*/enabled=1/' /etc/default/apport
systemctl enable apport.service 2>/dev/null || true
/usr/local/bin/tone-brand
systemctl --global enable tone-wallpaper-watch.timer || echo "enable失敗: tone-wallpaper-watch.timer"
systemctl --global enable tone-app-update.timer || echo "enable失敗: tone-app-update.timer"
systemctl enable grub-btrfsd.service 2>/dev/null || echo "任意: grub-btrfsd なし(起動メニューのスナップショット項目は手動更新)"
plymouth-set-default-theme tone-wind || update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/tone-wind/tone-wind.plymouth 200
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/; s/^#\?GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="TONE OS"/' /etc/default/grub
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub; grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
update-initramfs -u -k all
__STAGE__
mount_chroot
cp -a "$SRC/overlay/." "$ROOTFS/"
chmod 440 "$ROOTFS/etc/sudoers.d/90-tone-nopasswd"
run_stage() { chroot "$ROOTFS" env LO_VER="$LO_VER" /bin/bash /tmp/stage.sh; }
run_stage
log "chroot構成完了"

# ---------------------------------------------------------------- 7. ISO生成関数
make_iso() { # $1=test|prod
  step "ISO生成($1)"
  umount_chroot
  rm -rf "$ISODIR"; mkdir -p "$ISODIR"/{casper,boot/grub,.disk}
  local k i; k=$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1); i=$(ls "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)
  cp -L "$k" "$ISODIR/casper/vmlinuz"; cp -L "$i" "$ISODIR/casper/initrd"
  if [ ! -f "$WORK/filesystem.squashfs" ] || [ "${REBUILD_SQ:-1}" = 1 ]; then
    rm -f "$WORK/filesystem.squashfs"
    mount_chroot; net_off; umount_chroot
    log "squashfs圧縮中(時間がかかります)"
    mksquashfs "$ROOTFS" "$WORK/filesystem.squashfs" -comp xz -b 1M -noappend \
      -e "$ROOTFS/tmp/stage.sh" -e "$ROOTFS/var/cache/apt/archives" -e "$ROOTFS/var/lib/apt/lists"
    REBUILD_SQ=0
  fi
  cp "$WORK/filesystem.squashfs" "$ISODIR/casper/filesystem.squashfs"
  du -sx --block-size=1 "$ROOTFS" | cut -f1 > "$ISODIR/casper/filesystem.size"
  echo "TONE OS $TONE_VER amd64 ($(date +%F))" > "$ISODIR/.disk/info"; touch "$ISODIR/.disk/base_installable"
  {
    echo 'insmod all_video'; echo 'insmod gfxterm'; echo 'set gfxmode=auto'; echo 'terminal_output gfxterm'
    echo 'set timeout_style=menu'
    if [ "$1" = test ]; then echo 'set default=3'; echo 'set timeout=1'; else echo 'set default=0'; echo 'set timeout=60'; fi
    echo 'menuentry "TONE OS - Install" {'; echo '  linux /casper/vmlinuz boot=casper noprompt quiet splash ---'; echo '  initrd /casper/initrd'; echo '}'
    echo 'menuentry "TONE OS - Safe graphics (nomodeset)" {'; echo '  linux /casper/vmlinuz boot=casper noprompt nomodeset ---'; echo '  initrd /casper/initrd'; echo '}'
    echo 'menuentry "TONE OS - Show boot messages" {'; echo '  linux /casper/vmlinuz boot=casper noprompt ---'; echo '  initrd /casper/initrd'; echo '}'
    if [ "$1" = test ]; then
      echo 'menuentry "TONE-SELFTEST" {'
      echo '  linux /casper/vmlinuz boot=casper noprompt console=tty0 console=ttyS0,115200 tone.selftest systemd.unit=multi-user.target ---'
      echo '  initrd /casper/initrd'; echo '}'
    fi
  } > "$ISODIR/boot/grub/grub.cfg"
  ( cd "$ISODIR" && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )
  rm -f "$ISO"
  # squashfsが4GiBを超えるためISO9660 level3(マルチエクステント)が必須
  grub-mkrescue -V TONE_OS -o "$ISO" "$ISODIR" -iso-level 3 \
   || { log "代替方式(--付き)で再試行"; rm -f "$ISO"; grub-mkrescue -V TONE_OS -o "$ISO" "$ISODIR" -- -iso-level 3; } \
   || { log "代替方式(-compliance)で再試行"; rm -f "$ISO"; grub-mkrescue -V TONE_OS -o "$ISO" "$ISODIR" -- -compliance iso_9660_level=3; }
  log "ISO作成: $ISO ($(du -h "$ISO" | cut -f1))"
}

# ---------------------------------------------------------------- 8. エミュレート検証ループ(バグがなくなるまで)
emulate() { # 戻り値0=PASS
  local mode=$1 acc="-accel tcg" tmo=2400 bios=() sl
  sl="$LOGDIR/emu-$mode-$TS.log"
  [ -w /dev/kvm ] && { acc="-accel kvm"; tmo=900; }
  [ "$mode" = uefi ] && { [ -f /usr/share/ovmf/OVMF.fd ] || { log "OVMFなし: UEFI検証をスキップ"; return 0; }; bios=(-bios /usr/share/ovmf/OVMF.fd); }
  : > "$sl"
  log "QEMU検証($mode): $acc タイムアウト${tmo}s"
  if [ "$mode" = uefi ]; then
    # UEFIはメニュー操作が必要なためブート確認のみ(grubに到達しカーネルが起動すること)
    timeout 240 qemu-system-x86_64 $acc -m 4096 -smp 2 -cdrom "$ISO" -boot d "${bios[@]}" -display none -serial "file:$sl" -no-reboot || true
    return 0
  fi
  # BIOS: テスト用ISOは検証エントリを自動で起動する
  timeout "$tmo" qemu-system-x86_64 $acc -m 4096 -smp 2 -cdrom "$ISO" -boot d -display none -serial "file:$sl" -no-reboot >/dev/null 2>&1 || true
  grep -a 'TONE-' "$sl" || true
  grep -aq 'TONE-SELFTEST-PASS' "$sl"
}
repair() {
  log "★不具合を検出: 自動修復を実行します"
  local sl; sl=$(ls -t "$LOGDIR"/emu-bios-*.log | head -1)
  mount_chroot; net_on
  chroot "$ROOTFS" /bin/bash -c 'dpkg --configure -a; apt-get -f install -y; apt-get update' || true
  for p in $( (grep -ao 'MISSING-PKG:[^ ]*' "$sl" 2>/dev/null || true) | cut -d: -f2 | tr -d '\r' | sort -u || true); do
    log "欠落パッケージを再導入: $p"
    case "$p" in libreoffice) chroot "$ROOTFS" /usr/local/bin/tone-lo-update --force || true;; *) chroot "$ROOTFS" apt-get install -y "$p" || true;; esac
  done
  for u in $( (grep -ao 'NOT-ENABLED:[^ ]*' "$sl" 2>/dev/null || true) | cut -d: -f2 | tr -d '\r' | sort -u || true); do chroot "$ROOTFS" systemctl enable "$u" || true; done
  grep -aq 'GAME-REMAINS' "$sl" 2>/dev/null && chroot "$ROOTFS" apt-get purge -y 'kmahjongg*' 'kmines*' 'ksudoku*' 'kpat*' || true
  chroot "$ROOTFS" update-initramfs -u -k all || true
  chroot "$ROOTFS" apt-get clean || true
  REBUILD_SQ=1
}

INST_IMG=$WORK/installed.img; INST_MNT=$WORK/instroot; INST_LOOP=""
inst_cleanup() {
  for m in run sys proc dev/pts dev boot/efi .snapshots home ""; do mountpoint -q "$INST_MNT/$m" 2>/dev/null && umount -lf "$INST_MNT/$m" 2>/dev/null || true; done
  [ -n "$INST_LOOP" ] && losetup -d "$INST_LOOP" 2>/dev/null || true; INST_LOOP=""
}
# Calamaresのインストール手順を再現して仮想ディスクへ導入する。$1=uefi|bios
install_to_image() {
  local mode=$1 rid eid i d
  inst_cleanup; rm -f "$INST_IMG"; mkdir -p "$INST_MNT"
  truncate -s 14G "$INST_IMG"
  if [ "$mode" = bios ]; then sgdisk -Z -n1:2048:+2M -t1:ef02 -n2:0:0 -t2:8300 "$INST_IMG" >/dev/null
  else sgdisk -Z -n1:0:+512M -t1:ef00 -n2:0:0 -t2:8300 "$INST_IMG" >/dev/null; fi
  INST_LOOP=$(losetup -fP --show "$INST_IMG")
  for i in $(seq 1 20); do [ -b "${INST_LOOP}p2" ] && break; sleep 1; done
  # Calamaresの結果(Btrfs: @ / @home / @snapshots)を再現する
  mkfs.btrfs -q -f "${INST_LOOP}p2"; mount "${INST_LOOP}p2" "$INST_MNT"
  for sv in @ @home @snapshots; do btrfs subvolume create "$INST_MNT/$sv" >/dev/null; done
  umount "$INST_MNT"
  BOPT="noatime,compress=zstd:1"
  mount -o "subvol=@,$BOPT" "${INST_LOOP}p2" "$INST_MNT"; mkdir -p "$INST_MNT/home" "$INST_MNT/.snapshots"
  mount -o "subvol=@home,$BOPT" "${INST_LOOP}p2" "$INST_MNT/home"; mount -o "subvol=@snapshots,$BOPT" "${INST_LOOP}p2" "$INST_MNT/.snapshots"
  if [ "$mode" = uefi ]; then mkfs.vfat -F32 "${INST_LOOP}p1" >/dev/null; mkdir -p "$INST_MNT/boot/efi"; mount "${INST_LOOP}p1" "$INST_MNT/boot/efi"; fi
  log "ファイル展開(rsync): $mode"
  rsync -aHAX --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' --exclude='/tmp/*' "$ROOTFS/" "$INST_MNT/"
  rid=$(blkid -s UUID -o value "${INST_LOOP}p2")
  printf 'UUID=%s / btrfs subvol=@,%s 0 0\nUUID=%s /home btrfs subvol=@home,%s 0 0\nUUID=%s /.snapshots btrfs subvol=@snapshots,%s 0 0\n' "$rid" "$BOPT" "$rid" "$BOPT" "$rid" "$BOPT" > "$INST_MNT/etc/fstab"
  if [ "$mode" = uefi ]; then eid=$(blkid -s UUID -o value "${INST_LOOP}p1"); printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$eid" >> "$INST_MNT/etc/fstab"; fi
  rm -f "$INST_MNT/etc/sddm.conf.d/live.conf" "$INST_MNT/etc/casper.conf" "$INST_MNT/etc/xdg/autostart/tone-installer.desktop"
  # テスト専用: 重い常駐処理を止める(本番イメージには入らない)
  for d in clamav-daemon clamav-freshclam apt-daily apt-daily-upgrade unattended-upgrades; do
    mkdir -p "$INST_MNT/etc/systemd/system/$d.service.d"
    printf '[Unit]\nConditionKernelCommandLine=!tone.test\n' > "$INST_MNT/etc/systemd/system/$d.service.d/tone-test.conf"
  done
  mkdir -p "$INST_MNT"/{proc,sys,dev,run}
  mount --bind /dev "$INST_MNT/dev"; mount --bind /proc "$INST_MNT/proc"; mount --bind /sys "$INST_MNT/sys"; mount --bind /run "$INST_MNT/run"
  { echo 'GRUB_DISABLE_OS_PROBER=true'; echo 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0 tone.test"'; echo 'GRUB_TERMINAL="console serial"'
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"'; echo 'GRUB_TIMEOUT=1'; echo 'GRUB_TIMEOUT_STYLE=menu'; } >> "$INST_MNT/etc/default/grub"
  chroot "$INST_MNT" update-initramfs -u -k all || true
  if [ "$mode" = bios ]; then
    chroot "$INST_MNT" grub-install --target=i386-pc --recheck "$INST_LOOP"
  else
    # Calamaresと同じ引数(efiBootloaderId=$TONE_EFI_ID)。NVRAMが無いので --no-nvram を追加
    chroot "$INST_MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$TONE_EFI_ID" --force --no-nvram
  fi
  chroot "$INST_MNT" grub-mkconfig -o /boot/grub/grub.cfg
  [ -s "$INST_MNT/boot/grub/grub.cfg" ] || { log "★grub.cfg が生成されていません"; inst_cleanup; return 1; }
  if [ "$mode" = uefi ]; then   # インストール時のfixgrub工程と同じフォールバック(EFI/BOOT)
    mkdir -p "$INST_MNT/boot/efi/EFI/BOOT"; cp -a "$INST_MNT"/boot/efi/EFI/"$TONE_EFI_ID"/. "$INST_MNT/boot/efi/EFI/BOOT/"
    cp -f "$INST_MNT/boot/efi/EFI/$TONE_EFI_ID/shimx64.efi" "$INST_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
  fi
  rm -rf "$INST_MNT/tmp/"*; sync; inst_cleanup
}
# 仮想ディスクをQEMUで起動し、ログイン画面(=OS起動成功)と初回ヘルスチェック結果を確認する。$1=ラベル 以降=QEMU追加引数
boot_installed() {
  local label=$1; shift
  local sl="$LOGDIR/emu-installed-$label-$TS.log" acc="-accel tcg" tmo=1500 i qpid
  [ -w /dev/kvm ] && { acc="-accel kvm"; tmo=600; }
  : > "$sl"; log "QEMU起動($label): $acc"
  qemu-system-x86_64 $acc -m 4096 -smp 2 -drive file="$INST_IMG",format=raw "$@" -display none -serial "file:$sl" -no-reboot >/dev/null 2>&1 &
  qpid=$!
  for i in $(seq 1 $((tmo/5))); do   # 1) ログイン画面まで
    sleep 5; grep -aq 'login:' "$sl" && break; kill -0 "$qpid" 2>/dev/null || break
  done
  if grep -aq 'login:' "$sl"; then
    for i in $(seq 1 52); do   # 2) 初回ヘルスチェック(最大約4分)
      grep -aq 'TONE-SELFTEST-PASS\|TONE-SELFTEST-FAIL' "$sl" && break; kill -0 "$qpid" 2>/dev/null || break; sleep 5
    done
  fi
  kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  grep -a 'TONE-\|grub>' "$sl" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -6 || true
  if ! grep -aq 'login:' "$sl"; then
    grep -aq 'grub>' "$sl" && log "★GRUBのコマンド入力画面で停止しました"
    log "★起動失敗($label): $sl"; return 1
  fi
  if grep -aq 'TONE-SELFTEST-PASS' "$sl"; then log "★起動 合格($label): ログイン画面+ヘルスチェック合格"
  else log "▲起動 合格($label): ログイン画面まで到達。ヘルスチェックは未完了/要確認 → $sl"; fi
  return 0
}
test_installed_boot() {
  [ "${SKIP_INSTALL_TEST:-0}" = 1 ] && { log "インストール後起動テスト: スキップ指定"; return 0; }
  [ -f /usr/share/ovmf/OVMF.fd ] || { log "OVMFなし: インストール後起動テストをスキップ"; return 0; }
  local code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd vars=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
  step "インストール後の起動テスト(1/2) UEFI機 / Secure Boot有効機"
  install_to_image uefi || return 1
  boot_installed uefi -bios /usr/share/ovmf/OVMF.fd || { rm -f "$INST_IMG"; return 1; }
  if [ -f "$code" ] && [ -f "$vars" ]; then
    cp -f "$vars" "$WORK/OVMF_VARS.fd"
    boot_installed secureboot -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
      -drive if=pflash,format=raw,unit=0,file="$code",readonly=on -drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd" \
      || log "▲Secure Boot有効での起動に失敗(ログ確認)。BIOS/UEFI機の検証は続行します"
  else log "Secure Boot用OVMFなし: Secure Boot検証をスキップ"; fi
  step "インストール後の起動テスト(2/2) 旧式BIOS機(Legacy)"
  install_to_image bios || return 1
  boot_installed bios || { rm -f "$INST_IMG"; return 1; }
  rm -f "$INST_IMG" "$WORK/OVMF_VARS.fd"
  return 0
}

step "7-8. ISO生成とエミュレート検証(合格までループ)"
REBUILD_SQ=1; passed=0
for a in $(seq 1 "$MAX_ATTEMPTS"); do
  log "---- 検証サイクル $a / $MAX_ATTEMPTS ----"
  make_iso test
  if emulate bios; then
    emulate uefi
    test_installed_boot || { log "★インストール後の起動に失敗しました。ログ: $LOGDIR/emu-installed-*-$TS.log (SKIP_INSTALL_TEST=1 で回避可)"; exit 1; }
    passed=1; log "★エミュレート検証 合格 (サイクル $a)"; break
  fi
  sl=$(ls -t "$LOGDIR"/emu-bios-*.log 2>/dev/null | head -1)
  sig=$( { grep -ao 'TONE-CHECK-NG:[^ ]*' "$sl" 2>/dev/null || true; } | tr -d '\r' | sort -u | tr '\n' ' ' || true)
  if [ -n "$sig" ] && [ "$sig" = "${prev_sig:-}" ]; then
    log "★同じ不具合が修復後も繰り返されました: $sig  → 自動修復できない種類のため停止します"; exit 1
  fi
  prev_sig=$sig
  repair
done
[ "$passed" = 1 ] || { log "★$MAX_ATTEMPTS 回の検証でも合格しませんでした。ログ: $LOGDIR/emu-*-$TS.log"; exit 1; }
make_iso prod   # 検証用メニューを除いた最終ISO(squashfsは再利用)
sha256sum "$ISO" > "$ISO.sha256"

# ---------------------------------------------------------------- 9. 説明書PDF / ソースZip
step "9. 使用説明書PDF"
PDF=$OUT/TONE_OS_使用説明書-$TONE_VER-$TS.pdf
python3 - "$PDF" "$SRC/overlay/usr/share/tone-os/developer-icon.png" "$TONE_VER" <<'__PY__'
import sys, os
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, Image
F=None
for fp in ('/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf','/usr/share/fonts/truetype/fonts-japanese-gothic.ttf','/usr/share/fonts/truetype/takao-gothic/TakaoPGothic.ttf'):
    if os.path.exists(fp):
        try:
            from reportlab.pdfbase.ttfonts import TTFont
            pdfmetrics.registerFont(TTFont('TONEJP', fp)); F='TONEJP'; break      # フォントを埋め込む(どのPDFビューアーでも文字が出る)
        except Exception: pass
if F is None:
    pdfmetrics.registerFont(UnicodeCIDFont('HeiseiKakuGo-W5')); F='HeiseiKakuGo-W5'
H1=ParagraphStyle('h1',fontName=F,fontSize=26,leading=34,spaceAfter=10)
H2=ParagraphStyle('h2',fontName=F,fontSize=15,leading=22,spaceBefore=12,spaceAfter=6)
B=ParagraphStyle('b',fontName=F,fontSize=10.5,leading=18,wordWrap='CJK')
ICON=sys.argv[2] if len(sys.argv) > 2 else ""
S=[]
if ICON and os.path.exists(ICON): S+=[Image(ICON,25*mm,25*mm,hAlign='LEFT'),Spacer(1,6)]    # 2.5cmの丸いアイコン
VER=sys.argv[3] if len(sys.argv) > 3 else ""
S+=[Paragraph("TONE OS 使用説明書",H1),Paragraph("版 "+VER+"  ToneInternetService.",B),Spacer(1,8)]
sec=[
("1. TONE OSとは","Ubuntu 24.04をベースにした、日本語専用・KDEデスクトップのPCインストール専用OSです。Chrome、LibreOffice、Steamを標準搭載し、標準ゲームは削除しています。"),
("2. インストール","USBメモリ等にISOを書き込み、PCを起動すると日本語のインストーラーが自動で開きます。画面の案内に従って進めてください。インストール後は再起動するだけで使えます。"),
("3. 日本語入力","半角/全角キー(または Ctrl+Space)で日本語入力(Mozc)と英字入力を切り替えます。ローマ字入力・かな入力・全角英数・半角カナはタスクバーの入力アイコンから切り替えられます。"),
("4. 起動画面","起動画面は、上に「TONE OS」、その下に回転体(カザグルマ・鳴門の渦・台風のどれか)、そのすぐ下に細いシークバー、画面の下に「ToneInternetService.」が表示されます。回転体は「起動アニメの選択」で選べます(世界観とは別に選べます)。"),
("1.0.0 の新機能(1) 元に戻す","ファイルシステムは Btrfs が標準です。ソフトの更新の前、TONEアップデートの前、週1回、自動で「その時点」を保存します。「元に戻す」から日付を選ぶと、システムをその時点へ戻せます(ホームの書類・写真は戻りません)。起動メニューからも、以前の状態で起動できます。"),
("1.0.0 の新機能(2) TONEアップデート","「TONEを更新する」を押すだけで、署名を確認してから更新します。更新の前に自動で保存し、更新後の最初の起動で動作を確認して、おかしければ自動で元に戻ります。インターネットにつながらない環境では、更新用ISOをマウントして、ISOの中の入口スクリプトを実行します(中身の署名は、OSに入っている更新プログラムが確認します)。ユーザーのデータには触れません。"),
("1.0.0 の新機能(3) 世界観とスタイル","「世界観とスタイル」で、6つの世界観(ピンク・フロイド/高野山/身延山/京都/奈良/陸海空自衛隊)と、Windows風・Mac風を選べます。色・壁紙・ログイン画面がまとめて切り替わります(起動の選択画面 GRUB は変わりません)。Windows風は エクスプローラー、Mac風は Finder の使い方に近づけた Dolphin になります(Mac風の Command の代わりは Ctrl で、Dolphinなど TONE が整えるアプリだけです)。ホイール付きマウスは従来どおり、タッチパッドだけ Mac風では自然なスクロールです。"),
("1.0.0 の新機能(4) 壁紙ギャラリー","各世界観の基本の壁紙は6枚ずつ入っています。「壁紙ギャラリー」を開くと、サーバーにある新しい壁紙が一覧(サムネイル)で出て、選んだものだけダウンロードできます(署名の確認つき)。"),
("1.0.0 の新機能(5) 電源","AIを入れると、デスクPCは常に、ノートPCは電源をつないでいるときだけ、本体を動かし続けます。電池のときは、軽い見張りだけが動き、不測の事態のときだけAIを1回起動します(残量が15%以下のときは起動しません)。ふたを閉じても動くモードは、温度センサーがあるノートPCだけで、熱くなると自動でサスペンドします。電池の健康度は「困ったときは」や診断で見られます。ディスプレイの設定には触れません。"),
("1.0.0 の新機能(6) 困ったときは","「困ったときは」で症状を選ぶと、TONE診断が原因を調べ、個人情報を外したうえで。画面の固まり・ちらつきの原因になるGPUドライバーは、診断と自動切替(NVIDIA)で整えます。"),
("1.0.0 の新機能(7) USB 書き込み・初期化","「USB 書き込み・初期化」で、ISOをUSBに書き込み、書いた内容をSHA-256で確認します。「強制真っ白」では、選んだUSB1台のパーティションをすべて消して空にできます(起動ディスク・内蔵ディスク・ISOが入っているディスクは候補に出ません)。"),
("1.0.0 の新機能(8) インストール","インストールの最初に、「全部消してインストール」をおすすめする案内が出ます。大切なデータは、外付けのUSB・ディスクへコピーして保存できます(元は動かさず、件数と容量が一致するまで先へ進みません)。インストール後の最初の画面で、戻す案内が出ます。「起動の修復」は、インストール後も押せます。"),
("Chromeの同期","Chromeの右上のプロフィールからGoogleアカウントでログインすると、他のPCやAndroidとブックマーク・パスワード・履歴が同期されます。起動時に開くスタートページ(index.html)は、同期していても維持されます。Chromeは自動で更新されます。"),
("5. 起動音・終了音の変更","「起動音・終了音の設定」から、wav / mp3 / ogg のファイルを起動音とログオフ音に別々に設定できます。標準に戻すこともできます。"),
("6. 自動アップデート","OS本体、周辺ソフト、アプリストア(Discover)のアプリ、LibreOffice、Chromeは自動で更新されます(起動1分後と3時間毎)。操作は不要です。"),
("7. セキュリティ","ファイアウォール(ufw)が常に有効です。ウイルス対策(ClamAV)は、定義ファイルをOS起動の1分後に更新し、その後は設定した間隔(2・3・5・12時間。既定は3時間)で更新します。間隔は「ウイルス対策の設定」で選べます。パソコンを操作していないときに簡易スキャンを行い、5日に1回フルスキャンを行います。フルスキャンを実施できなかった場合は通知でお知らせします。"),
("スタートページの更新","新しい index.html を受け取ったら、「スタートページの更新(index.html)」を開いてファイルを選び、「更新」を押すと上書きされます。Chromeのアップデート後も、スタートページは必ず表示されます。"),
("壁紙スライドショー","「壁紙スライドショー」から、インターネット上の壁紙を読み込んで、KDE標準のスライドショーに設定できます。更新間隔は、5分・15分・60分・120分・6時間・更新選択なしから選べます。この機能は、サービス開始(2027年1月以降の予定)までご利用いただけません。サービスが始まると通知でお知らせします。"),
("カーネルの更新","Ubuntu公式の最新のカーネル(HWE)が、自動アップデートで入ります。新しいカーネルが入ると、ヘッダー・ドライバー・起動設定が自動で整えられ、再起動をお知らせします。"),
("開発者","開発者：valtanman　連絡先：toneappbildman@appmail.uk　ToneInternetService. 《PC-OpenCafe.　IoT&amp;Digital Software Development Department.》 ─ 「TONE OS について(開発者パネル)」でも確認できます。"),
("8. 外部アプリのインストール","ダウンロードした.debファイルを開くと、自動でウイルススキャンを行い、結果を表示した上で、ご自身の判断でインストールできます。パスワード入力は不要です。"),
("9. 時刻","ntp.nict.jp に15分毎に接続して時刻を自動調整します。"),
("10. 困ったとき","更新履歴: /var/log/tone-os/update.log  ウイルスチェック履歴: /var/log/tone-os/boot-scan.log"),
]
for t,p in sec: S+= [Paragraph(t,H2),Paragraph(p,B)]
SimpleDocTemplate(sys.argv[1],pagesize=A4,leftMargin=20*mm,rightMargin=20*mm,topMargin=20*mm,bottomMargin=20*mm,title="TONE OS 使用説明書").build(S)
__PY__
log "PDF作成: $PDF"

step "10. ソースコードZip化"
cp -f "$0" "$SRC/build-tone-os.sh" 2>/dev/null || true
SRCZIP=$OUT/TONE_OS_source-$TONE_VER-$TS.zip
( cd "$SRC" && zip -qr "$SRCZIP" . )
log "ソースZip: $SRCZIP"

# ---------------------------------------------------------------- 11. 後始末
step "11. 後始末"
umount_chroot
[ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$ROOTFS" "$ISODIR" "$WORK/filesystem.squashfs"
chown -R "$REAL_USER":"$REAL_USER" "$BASE"
chmod -R u+rwX,go+rX "$BASE"
find "$BASE" -type f -perm /077 -a ! -perm -044 -exec chmod a+r {} + 2>/dev/null || true
log "★★★ 完了 ★★★  TONE OS 版 $TONE_VER"
log "ISO   : $ISO"
log "説明書: $PDF"
log "ソース: $SRCZIP"
log "ログ  : $LOG"
log "SHA256: $(cut -d' ' -f1 "$ISO.sha256")"
REL=$OUT/TONE_OS_release-$TONE_VER-$TS.json
cat > "$REL" <<EOF2
{"os_version":"$TONE_VER","iso":"$(basename "$ISO")","sha256":"$(cut -d' ' -f1 "$ISO.sha256")","built":"$(date -Is)","efi_id":"$TONE_EFI_ID","update_key":"$(cat "$SRC/overlay/usr/share/tone-os/keys/KEYSTATE")"}
EOF2
log "リリース情報(更新目録の元): $REL"
[ "$(cat "$SRC/overlay/usr/share/tone-os/keys/KEYSTATE")" = test ] && log "▲更新の公開鍵はテスト用です。配布前に、本番の鍵(手元のオフライン環境で作成)を $BASE/keys/update-pub.pem に置いて再ビルドしてください"
log "所要時間: $(( ($(date +%s) - START_TS) / 60 )) 分"
log "USB書込: Rufus は「DDイメージモード」/ Linux は sudo dd if=$ISO of=/dev/sdX bs=4M status=progress conv=fsync"
log "         書込後に PC の BIOS/UEFI で Secure Boot を無効にして起動してください"
notify "TONE OS ビルド完了" "ISOができました: $ISO"
