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

# 3. mlterm — full palette: copy theme .color, patch ~/.mlterm/main,
#    then push live via OSC (10/11/12/4) into every open window's pty.
mlterm_themes_dir="${MLTERM_THEMES_DIR:-$HOME/Desktop/themes/terminal-themes/mlterm}"
ml_main="$HOME/.mlterm/main"
ml_color="$HOME/.mlterm/color"
if [[ -d "$mlterm_themes_dir" ]]; then
    if [[ "$alacritty_mode" == "dark" ]]; then ml_base="dark-harmony"; else ml_base="light"; fi
    t_main="$mlterm_themes_dir/$ml_base.main"
    t_color="$mlterm_themes_dir/$ml_base.color"
    if [[ -f "$t_main" && -f "$t_color" ]]; then
        osc=$(python3 - "$t_main" "$t_color" "$ml_main" "$ml_color" "$theme" <<'PY'
import os, re, shutil, sys
tmain, tcolor, dmain, dcolor, theme = sys.argv[1:6]
shutil.copyfile(tcolor, dcolor)
vals = {}
for line in open(tmain):
    m = re.match(r'\s*(fg_color|bg_color|cursor_bg_color|cursor_fg_color)\s*=\s*#([0-9a-fA-F]{6})', line)
    if m:
        vals[m.group(1)] = "#" + m.group(2)
# Scrollbar colours live in the color file; patch them into main as well so the
# scrollbar follows the theme on the next window start whichever of the two
# config files mlterm prefers for sb_*. Live repaint uses OSC 5379 (see below),
# the same sequence `mlcc sb_fg_color ...` emits.
for line in open(tcolor):
    m = re.match(r'\s*(sb_fg_color|sb_bg_color)\s*=\s*#([0-9a-fA-F]{6})', line)
    if m:
        vals[m.group(1)] = "#" + m.group(2)

# Prefer the GTK theme's own scrollbar palette: mlterm draws a plain window,
# so this is the only way its bar looks like the system one. Falls back to the
# theme file's sb_* values when the CSS is not readable.
def css_rgb(value):
    m = re.match(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)', value)
    if m:
        return "#%02x%02x%02x" % tuple(int(x) for x in m.groups())
    m = re.match(r'#([0-9a-fA-F]{6})', value)
    return "#" + m.group(1).lower() if m else None

css_path = f"/usr/share/themes/{theme}/gtk-3.0/gtk.css"
sb_fg = sb_bg = None
if os.path.exists(css_path):
    css = open(css_path).read()
    m = re.search(r'(?m)^scrollbar\s*\{([^}]*)\}', css)
    if m:
        b = re.search(r'background-color:\s*([^;]+);', m.group(1))
        if b:
            sb_bg = css_rgb(b.group(1).strip())
    m = re.search(r'(?m)^\s*scrollbar slider\s*\{([^}]*)\}', css)
    if m:
        b = re.search(r'background-color:\s*([^;]+);', m.group(1))
        if b:
            sb_fg = css_rgb(b.group(1).strip())
if sb_fg and sb_bg:
    vals["sb_fg_color"] = sb_fg
    vals["sb_bg_color"] = sb_bg

def patch(text, k, v):
    if re.search(r'(?m)^\s*' + k + r'\s*=', text):
        return re.sub(r'(?m)^(\s*' + k + r'\s*=\s*)#[0-9a-fA-F]+',
                      lambda mm, v=v: mm.group(1) + v, text, count=1)
    return text.rstrip("\n") + f"\n{k} = {v}\n"

txt = open(dmain).read() if os.path.exists(dmain) else ""
for k, v in vals.items():
    txt = patch(txt, k, v)
open(dmain, "w").write(txt)

# The copied .color keeps the theme's green sb_* lines; align them too so no
# config source disagrees with the system palette.
ctxt = open(dcolor).read()
for k in ("sb_fg_color", "sb_bg_color"):
    if k in vals:
        ctxt = patch(ctxt, k, vals[k])
open(dcolor, "w").write(ctxt)

def rgb(h):
    return f"{h[1:3]}/{h[3:5]}/{h[5:7]}"
NAMES = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
colors = {}
for line in open(tcolor):
    m = re.match(r'\s*(hl_)?(black|red|green|yellow|blue|magenta|cyan|white)\s*=\s*#([0-9a-fA-F]{6})', line)
    if m:
        idx = NAMES.index(m.group(2)) + (8 if m.group(1) else 0)
        colors[idx] = "#" + m.group(3)
osc = ""
if "fg_color" in vals:
    osc += f"\033]10;rgb:{rgb(vals['fg_color'])}\033\\"
if "bg_color" in vals:
    osc += f"\033]11;rgb:{rgb(vals['bg_color'])}\033\\"
if "cursor_bg_color" in vals:
    osc += f"\033]12;rgb:{rgb(vals['cursor_bg_color'])}\033\\"
for idx, h in sorted(colors.items()):
    osc += f"\033]4;{idx};rgb:{rgb(h)}\033\\"
# Live scrollbar repaint: OSC 5379;key=value BEL (identical to `mlcc key value`).
for k in ("sb_fg_color", "sb_bg_color"):
    if k in vals:
        osc += f"\033]5379;{k}={vals[k]}\007"
sys.stdout.write(osc)
PY
)
        if [[ -n "$osc" ]]; then
            for pid in $(pgrep -x mlterm); do
                ptses=$(ls -l /proc/$pid/fd 2>/dev/null | grep -oE '/dev/pts/[0-9]+' | sort -u)
                for pts in $ptses; do
                    printf '%s' "$osc" > "$pts" 2>/dev/null || true
                done
            done
        fi
        echo "mlterm palette <- $ml_base (live OSC pushed: $(printf '%s' "$osc" | grep -o ']4;' | wc -l) colors + scrollbar; $(pgrep -cx mlterm) windows)"
    else
        echo "WARNING: mlterm theme files not found for $ml_base" >&2
    fi
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
