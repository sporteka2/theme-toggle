#!/usr/bin/env bash
# Toggle system themes: Mint UI + Alacritty + Firefox Dev Edition (Super+Z)
set -euo pipefail

IFACE="org.cinnamon.desktop.interface"
METACITY="org.cinnamon.theme"
WM_THEME="org.cinnamon.desktop.wm.preferences"
ALACRITTY_CONF="$HOME/.config/alacritty/alacritty.toml"

if [[ "$(gsettings get "$IFACE" gtk-theme)" == "'Mint-Y-Dark'" ]]; then
    theme="Mint-Y"
    alacritty_mode="light"
    ff_scheme=1
    ff_devtools="light"
else
    theme="Mint-Y-Dark"
    alacritty_mode="dark"
    ff_scheme=2
    ff_devtools="dark"
fi

# 1. Mint (windows, panels, borders)
gsettings set "$IFACE" gtk-theme "$theme"
gsettings set "$METACITY" name "$theme"
gsettings set "$WM_THEME" theme "$theme"
# GTK4/Adwaita apps, sites и новые рамки: prefer-dark ⇄ default
if [[ "$theme" == "Mint-Y-Dark" ]]; then cs="prefer-dark"; else cs="default"; fi
gsettings set org.gnome.desktop.interface color-scheme "$cs"
# XApps settings portal feed — ЭТО читают Firefox/Chromium как системную схему.
# Без этого портал отдаёт 0 (светлый), и первое окно Firefox красится светлым.
if [[ "$theme" == "Mint-Y-Dark" ]]; then xcs="prefer-dark"; else xcs="prefer-light"; fi
gsettings set org.x.apps.portal color-scheme "$xcs"

# 1.5 Alacritty: push palette into all already-open windows (live)
if [[ "$alacritty_mode" == "dark" ]]; then
    alt_bg="#1e1e2e"; alt_fg="#cdd6f4"; alt_ctext="#1e1e2e"; alt_ccursor="#f5e0dc"
else
    alt_bg="#ffffff"; alt_fg="#000000"; alt_ctext="#ffffff"; alt_ccursor="#000000"
fi
alacritty="${ALACRITTY_BIN:-alacritty}"
rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for sock in "$rt"/Alacritty-:0-*.sock "$rt"/alacritty/*; do
    [[ -S "$sock" ]] || continue
    ALACRITTY_SOCKET="$sock" "$alacritty" msg config -w -1 \
    "colors.primary.background=\"$alt_bg\"" \
    "colors.primary.foreground=\"$alt_fg\"" \
    "colors.cursor.text=\"$alt_ctext\"" \
    "colors.cursor.cursor=\"$alt_ccursor\"" >/dev/null 2>&1 || true
done

# 2. Alacritty — swap palette in place (Alacritty reloads the config itself)
if [[ -f "$ALACRITTY_CONF" ]]; then
    python3 - "$ALACRITTY_CONF" "$alacritty_mode" <<'PY'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
LIGHT = {"background": "#ffffff", "foreground": "#000000"}
DARK  = {"background": "#1e1e2e", "foreground": "#cdd6f4"}
cur = LIGHT if mode == "light" else DARK
txt = open(path).read()
blocks = {
    "[colors.primary]": ("background", "foreground"),
    "[colors.cursor]":  ("text", "cursor"),
}
for section, keys in blocks.items():
    m = re.search(re.escape(section) + r"\n([\s\S]*?)(?=\n\[|\Z)", txt)
    if not m:
        sys.exit(f"alacritty: нет секции {section}")
    block = m.group(1)
    for key in keys:
        if section == "[colors.primary]":
            val = cur[key]
        elif cur is LIGHT:
            val = LIGHT["background"] if key == "text" else LIGHT["foreground"]
        else:
            val = DARK[key if key == "foreground" else "background"] if key == "text" else "#f5e0dc"
        block, n = re.subn(r"(?m)^(\s*" + key + r"\s*=\s*)'[^']*'",
                           lambda m: m.group(1) + f"'{val}'", block, count=1)
        if n != 1:
            sys.exit(f"alacritty: не найдено {key} в {section}")
    txt = txt[:m.start(1)] + block + txt[m.end(1):]
open(path, "w").write(txt)
PY
fi

# 3.5 Qt: CopyQ — write its theme palette (copyq.conf) and restart.
#      Live repaint is impossible for CopyQ (Qt has no live theme relay here);
#      history is stored on disk so a restart is safe.
copyq_theme_ini="$HOME/.config/copyq/themes/system-$([[ "$theme" == "Mint-Y-Dark" ]] && echo dark || echo light).ini"
if [[ -f "$copyq_theme_ini" ]]; then
    python3 - "$copyq_theme_ini" "$HOME/.config/copyq/copyq.conf" <<'PY'
import sys, configparser
ini, conf = sys.argv[1], sys.argv[2]
src = configparser.ConfigParser(interpolation=None); src.read(ini)
vals = dict(src['General'])
cp = configparser.ConfigParser(interpolation=None); cp.optionxform = str; cp.read(conf)
if 'Options' not in cp:
    cp['Options'] = {}
cp['Options'].update(vals)
with open(conf, 'w') as f:
    cp.write(f)
PY
    # Live apply on the running server: loadTheme re-reads the palette without
    # a restart, so the tray icon never blinks out.
    COPYQ_BIN="${COPYQ_BIN:-copyq}"
    "$COPYQ_BIN" eval "loadTheme(\"$copyq_theme_ini\")" \
        >/dev/null 2>&1 || true
    echo "copyq re-themed -> $(basename "$copyq_theme_ini")"
fi

# 4. Firefox Dev — prefs via user.js (applied on next Firefox start).
#    Пишем во ВСЕ профили (основной, dev-edition и выделенный профиль OpenCode
#    из ~/.mozilla), иначе меню-приложение OpenCode живёт по старым префам.
for FF_DIR in "$HOME"/.config/mozilla/firefox/*/ "$HOME"/.mozilla/firefox/*/; do
    [ -d "$FF_DIR" ] || continue
    FF_USERJS="$FF_DIR/user.js"
    [ -e "$FF_USERJS" ] || touch "$FF_USERJS"
    python3 - "$FF_USERJS" "$ff_scheme" "$ff_devtools" <<'PY'
import re, sys
path, scheme, devtools = sys.argv[1], sys.argv[2], sys.argv[3]
prefs = {
    "layout.css.prefers-color-scheme": scheme,
    "devtools.theme": f'"{devtools}"',
}
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
out, seen = [], set()
for line in lines:
    m = re.match(r'\s*user_pref\("([^"]+)"', line)
    if m and m.group(1) in prefs:
        key = m.group(1)
        if key in seen:
            continue
        seen.add(key)
        out.append(f'user_pref("{key}", {prefs[key]});')
    else:
        out.append(line)
for key, val in prefs.items():
    if key not in seen:
        out.append(f'user_pref("{key}", {val});')
open(path, "w").write("\n".join(out) + "\n")
PY
done

echo "theme=$theme alacritty=$alacritty_mode firefox=scheme:$ff_scheme"
