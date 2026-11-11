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

# 1.5 + 2. Alacritty: swap the FULL palette from theme files
#      (dark-harmony / light), push it live into open windows, rewrite the config.
alacritty="${ALACRITTY_BIN:-alacritty}"
themes_dir="${ALACRITTY_THEMES_DIR:-$HOME/Desktop/themes/terminal-themes/alacritty}"
theme_file=""
if [[ -f "$ALACRITTY_CONF" ]]; then
    if [[ "$alacritty_mode" == "dark" ]]; then
        theme_file="$themes_dir/dark-harmony.toml"
    else
        theme_file="$themes_dir/light.toml"
    fi
fi
if [[ -n "$theme_file" && -f "$theme_file" ]]; then
    # One pass: rewrite [colors.*] blocks in the config, print live-push pairs.
    mapfile -t push_pairs < <(python3 - "$ALACRITTY_CONF" "$theme_file" <<'PY'
import re, sys
conf, theme_path = sys.argv[1], sys.argv[2]
theme = open(theme_path).read()
sections = {}
for m in re.finditer(r'^\[(colors\.[a-z]+)\]\n([\s\S]*?)(?=\n\[|\Z)', theme, re.M):
    sections[m.group(1)] = m.group(2).rstrip() + "\n"
bg = re.search(r'^\[colors\.primary\]\n[\s\S]*?background\s*=\s*(["\'])(.*?)\1', theme, re.M)
if not bg:
    sys.exit("theme: primary background not found")
bg = bg.group(2)
txt = open(conf).read()
for name, block in sections.items():
    pat = re.escape(f"[{name}]") + r"\n([\s\S]*?)(?=\n\[|\Z)"
    m = re.search(pat, txt)
    if m:
        txt = txt[:m.start(1)] + block + txt[m.end(1):]
    else:
        # section missing in conf: append it before EOF
        txt = txt.rstrip("\n") + f"\n\n[{name}]\n{block}"
# ensure cursor.text = background (square cursor readable on the palette)
cm = re.search(r'\[colors\.cursor\]\n([\s\S]*?)(?=\n\[|\Z)', txt)
if cm:
    b = cm.group(1)
    if re.search(r'(?m)^\s*text\s*=', b):
        b = re.sub(r"(?m)^(\s*text\s*=\s*)['\"].*?['\"]",
                   lambda mm: mm.group(1) + f"'{bg}'", b, count=1)
    else:
        b = b.rstrip("\n") + "\n" + f"text = '{bg}'\n"
    txt = txt[:cm.start(1)] + b + txt[cm.end(1):]
open(conf, "w").write(txt)
for name, block in sections.items():
    for km in re.finditer(r'^\s*([a-z_]+)\s*=\s*(["\'])(.*?)\2', block, re.M):
        print(f"{name}.{km.group(1)}='{km.group(3)}'")
print(f"colors.cursor.text='{bg}'")
PY
)
    rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    for sock in "$rt"/Alacritty-:0-*.sock "$rt"/alacritty/*; do
        [[ -S "$sock" ]] || continue
        ALACRITTY_SOCKET="$sock" "$alacritty" msg config -w -1 \
            "${push_pairs[@]}" >/dev/null 2>&1 || true
    done
    echo "alacritty palette <- $(basename "$theme_file") ($alacritty_mode, ${#push_pairs[@]} keys live-pushed)"
else
    echo "WARNING: theme file not found: $theme_file" >&2
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
