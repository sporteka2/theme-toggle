# theme-toggle

One hotkey (`Super+Z` by default) to switch a Linux Mint / Cinnamon desktop
between light and dark — including live updates for the pieces that normally
need a restart.

## What it switches

| Component | Mechanism |
|---|---|
| Mint UI (windows, panels, borders) | `gsettings` — `gtk-theme`, metacity theme, WM theme |
| GTK4/Adwaita frames | `org.gnome.desktop.interface color-scheme` (`prefer-dark`/`default`) |
| **Firefox, Chrome, Electron** | `org.x.apps.portal color-scheme` — the XApps **settings portal** is what browsers actually read for the system colour scheme |
| Alacritty | full palette (primary/cursor/normal/bright) swapped from theme files — `dark-harmony.toml` (dark) / `light.toml` (light) — plus a live `alacritty msg config` push of every color key into open windows |
| Firefox (all profiles) | `user.js` prefs (`layout.css.prefers-color-scheme`, `devtools.theme`) rewritten for every profile under `~/.config/mozilla/firefox/` and `~/.mozilla/firefox/` |
| CopyQ | palette written to `copyq.conf` (next start) **and** `loadTheme()` applied live via the running server — no restart, so the tray icon never blinks |
| QtPass (Qt apps) | `QT_QPA_PLATFORMTHEME=gtk3` wrapper — the first painted frame already matches the system palette (no black flash) |

### The portal gotcha

On Cinnamon, `org.gnome.desktop.interface color-scheme` is **not** enough for
browser-family apps: they read `org.freedesktop.appearance color-scheme` from
xdg-desktop-portal, whose XApp backend mirrors `org.x.apps.portal color-scheme`.
Without writing that key the portal keeps reporting `0` (light) and the **first**
Firefox window opens light under a dark system, while later windows (after the
lazy system-theme detection) are dark. This script writes both keys.

## Install

```bash
cp toggle-theme.sh ~/.local/bin/toggle-theme.sh
chmod +x ~/.local/bin/toggle-theme.sh
cp -r copyq/themes ~/.config/copyq/     # optional, CopyQ palette
```

Requirements: bash, python3, gsettings, xdotool (for testing), alacritty
(optional), copyq (optional), Firefox (optional), QtPass (optional).

Install the QtPass wrapper so the menu entry uses it:

```bash
mkdir -p ~/.local/bin ~/.local/share/applications
install -m755 qtpass/qtpass ~/.local/bin/qtpass
install -m644 qtpass/qtpass.desktop ~/.local/share/applications/qtpass.desktop
```

## Hotkey (the Cinnamon tilde trap)

```bash
gsettings set org.cinnamon.desktop.keybindings custom-keybindings \
  "['/org/cinnamon/desktop/keybindings/custom-keybindings/customN/']"

dconf write /org/cinnamon/desktop/keybindings/custom-keybindings/customN/binding "['<Super>z']"
dconf write /org/cinnamon/desktop/keybindings/custom-keybindings/customN/command "'/home/USER/.local/bin/toggle-theme.sh'"   # ABSOLUTE path, no ~ !
dconf write /org/cinnamon/desktop/keybindings/custom-keybindings/customN/name "'Toggle theme light/dark'"
```

**Cinnamon runs the command without a shell**, so `~/.local/bin/...` fails with
*"Failed to execute child process ... (No such file or directory)"*. Always use
an absolute path. After changing bindings reload cinnamon: `Alt+F2` → `r` → Enter.

## Env overrides

| Var | Default | Purpose |
|---|---|---|
| `ALACRITTY_BIN` | `alacritty` | alacritty executable |
| `COPYQ_BIN` | `copyq` | copyq executable (point at a wrapper if you need `QT_QPA_PLATFORMTHEME=gtk3`) |
| `ALACRITTY_CONF` | `$HOME/.config/alacritty/alacritty.toml` | alacritty config |
| `ALACRITTY_THEMES_DIR` | `$HOME/Desktop/themes/terminal-themes/alacritty` | directory holding `dark-harmony.toml` (dark) and `light.toml` (light) palette files |

## Known limitations

- **opencode TUI** reads colors only at startup; running sessions must be
  restarted in their tab (upstream issue: [anomalyco/opencode#61598](https://github.com/anomalyco/opencode/issues/61598)).
- Cinnamon does not repaint already-drawn SSD frames live; new windows follow.
