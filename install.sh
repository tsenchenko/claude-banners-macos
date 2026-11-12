#!/usr/bin/env bash
#
# Installs Claude Code notifications for macOS.
#
# Sets up Claude Code hooks (Stop, Notification, PermissionRequest, PreToolUse) to fire native
# macOS notifications via terminal-notifier. Installs terminal-notifier (Homebrew
# if available, otherwise a per-user download — no admin), copies the hook
# scripts to ~/.claude/hooks/, and merges the hooks block into
# ~/.claude/settings.json without overwriting existing keys.
#
# Hooks are written with portable "$HOME/.claude/hooks/notify.sh" commands (not
# absolute paths), so a settings.json synced across machines keeps working — each
# machine resolves $HOME to its own hook scripts.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/tsenchenko/claude-banners-macos/main/install.sh | bash
#
# Override the source location (e.g. a fork) with:
#   REPO_BASE_URL=https://raw.githubusercontent.com/you/your-fork/main bash install.sh

set -euo pipefail

REPO_BASE_URL="${REPO_BASE_URL:-https://raw.githubusercontent.com/tsenchenko/claude-banners-macos/main}"
TN_RELEASE_URL="https://github.com/julienXX/terminal-notifier/releases/download/2.0.0/terminal-notifier-2.0.0.zip"

HOOKS_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.claude/bin"
SETTINGS="$HOME/.claude/settings.json"

# --- pretty output ---------------------------------------------------------
if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_MAGENTA=$'\033[35m'; C_RESET=$'\033[0m'
else C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_MAGENTA=""; C_RESET=""; fi
step() { printf '%s==> %s%s\n' "$C_CYAN" "$1" "$C_RESET"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn() { printf '    %s%s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }

printf '\n%sClaude Code Notifications for macOS%s\n' "$C_MAGENTA" "$C_RESET"
printf '%s==================================%s\n\n' "$C_MAGENTA" "$C_RESET"

# --- 0. guard --------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

# Find a JSON-capable runtime (node preferred, python3 fallback) for the merge.
JSON_RT=""
if command -v node >/dev/null 2>&1; then JSON_RT="node"
elif command -v python3 >/dev/null 2>&1; then JSON_RT="python3"; fi
if [ -z "$JSON_RT" ]; then
  echo "Need node or python3 to update settings.json safely. Install one and re-run." >&2
  exit 1
fi

# --- 1. terminal-notifier --------------------------------------------------
step "Checking terminal-notifier"
TN_PATH=""
if command -v terminal-notifier >/dev/null 2>&1; then
  TN_PATH="$(command -v terminal-notifier)"
  ok "Found on PATH: $TN_PATH"
elif [ -x "$BIN_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier" ]; then
  TN_PATH="$BIN_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier"
  ok "Found per-user install"
elif command -v brew >/dev/null 2>&1; then
  warn "Not found. Installing via Homebrew..."
  brew install terminal-notifier
  TN_PATH="$(command -v terminal-notifier || true)"
  ok "Installed via Homebrew"
else
  warn "Not found and Homebrew unavailable. Downloading a per-user copy (no admin)..."
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -d)"
  curl -fsSL "$TN_RELEASE_URL" -o "$tmp/tn.zip"
  unzip -oq "$tmp/tn.zip" -d "$tmp"
  app="$(/usr/bin/find "$tmp" -maxdepth 3 -name 'terminal-notifier.app' -type d | head -1)"
  if [ -z "$app" ]; then echo "Could not find terminal-notifier.app in the download." >&2; exit 1; fi
  rm -rf "$BIN_DIR/terminal-notifier.app"
  cp -R "$app" "$BIN_DIR/terminal-notifier.app"
  # Strip the download quarantine so the binary runs without a Gatekeeper prompt.
  xattr -dr com.apple.quarantine "$BIN_DIR/terminal-notifier.app" 2>/dev/null || true
  rm -rf "$tmp"
  TN_PATH="$BIN_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier"
  ok "Installed to $BIN_DIR/terminal-notifier.app"
fi

# --- 2. hook scripts -------------------------------------------------------
step "Installing hook scripts to ~/.claude/hooks/"
mkdir -p "$HOOKS_DIR"

# Run from a local clone? Copy the sibling hooks. Otherwise download them.
SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [ -n "$SOURCE" ] && [ -f "$SOURCE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
fi
for f in notify.sh focus-vscode.sh; do
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/hooks/$f" ]; then
    cp "$SCRIPT_DIR/hooks/$f" "$HOOKS_DIR/$f"
    ok "Copied $f"
  else
    curl -fsSL "$REPO_BASE_URL/hooks/$f" -o "$HOOKS_DIR/$f"
    ok "Downloaded $f"
  fi
  chmod +x "$HOOKS_DIR/$f"
done

# --- 3. merge hooks into settings.json -------------------------------------
# Surgical merge: only our events (Stop, Notification, PermissionRequest,
# PreToolUse) are touched, and within each event only OUR entry (identified by
# the notify.sh command) is replaced. Our PostToolUse entry from older versions
# (the removed "waiting detector") is dropped. Any other hooks — SessionStart, a user's
# own Stop hook, unrelated matchers — are preserved. Idempotent: re-running drops
# our previous entry before re-adding, so it never duplicates. The marker
# "/.claude/hooks/notify.sh" also matches older absolute-path installs, so
# re-running migrates them to the portable "$HOME/..." form.
step "Wiring hooks into ~/.claude/settings.json"
if [ "$JSON_RT" = "node" ]; then
  CT_SETTINGS="$SETTINGS" node -e '
    const fs=require("fs"),path=require("path");
    const file=process.env.CT_SETTINGS;
    const notify="\"$HOME/.claude/hooks/notify.sh\"";   // portable across machines
    const marker="/.claude/hooks/notify.sh";            // matches old absolute installs too
    let settings={};
    try{const raw=fs.readFileSync(file,"utf8");if(raw.trim())settings=JSON.parse(raw);}
    catch(e){if(e.code!=="ENOENT"){console.error("settings.json is not valid JSON. Fix it and re-run.");process.exit(3);}}
    if(typeof settings!=="object"||settings===null||Array.isArray(settings)){console.error("settings.json is not a JSON object.");process.exit(3);}
    if(typeof settings.hooks!=="object"||settings.hooks===null||Array.isArray(settings.hooks)) settings.hooks={};
    // Strip OUR hook entries, not whole groups: a group may also hold someone
    // other hook (e.g. another Stop command), and that one must survive.
    const isOurHook=h=>h&&typeof h.command==="string"&&h.command.includes(marker);
    const strip=arr=>arr.flatMap(g=>{
      if(!g||!Array.isArray(g.hooks)||!g.hooks.some(isOurHook)) return [g];
      const rest=g.hooks.filter(h=>!isOurHook(h));
      return rest.length?[Object.assign({},g,{hooks:rest})]:[];
    });
    const upsert=(event,matcher,arg)=>{
      const arr=Array.isArray(settings.hooks[event])?strip(settings.hooks[event]):[];
      arr.push({matcher:matcher,hooks:[{type:"command",command:notify+" "+arg}]});
      settings.hooks[event]=arr;
    };
    const drop=event=>{
      if(!Array.isArray(settings.hooks[event])) return;
      const arr=strip(settings.hooks[event]);
      if(arr.length) settings.hooks[event]=arr; else delete settings.hooks[event];
    };
    upsert("Stop","","Stop");
    upsert("Notification","","Notification");
    upsert("PermissionRequest","","PermissionRequest");
    upsert("PreToolUse","AskUserQuestion|ExitPlanMode","PreToolUse");
    drop("PostToolUse");   // older versions hooked every Read/Edit/Write here
    fs.mkdirSync(path.dirname(file),{recursive:true});
    fs.writeFileSync(file,JSON.stringify(settings,null,2)+"\n");
  '
else
  CT_SETTINGS="$SETTINGS" python3 -c '
import os,sys,json
f=os.environ["CT_SETTINGS"]
notify="\"$HOME/.claude/hooks/notify.sh\""   # portable across machines
marker="/.claude/hooks/notify.sh"            # matches old absolute installs too
settings={}
if os.path.exists(f):
    try:
        with open(f,"r",encoding="utf-8") as fh:
            raw=fh.read()
        if raw.strip(): settings=json.loads(raw)
    except Exception:
        sys.stderr.write("settings.json is not valid JSON. Fix it and re-run.\n"); sys.exit(3)
if not isinstance(settings,dict):
    sys.stderr.write("settings.json is not a JSON object.\n"); sys.exit(3)
hooks=settings.get("hooks")
if not isinstance(hooks,dict): hooks={}
# Strip OUR hook entries, not whole groups: a group may also hold someone
# other hook (e.g. another Stop command), and that one must survive.
def is_our_hook(h):
    return isinstance(h,dict) and isinstance(h.get("command"),str) and marker in h["command"]
def strip(arr):
    out=[]
    for g in arr:
        if isinstance(g,dict) and isinstance(g.get("hooks"),list) and any(is_our_hook(h) for h in g["hooks"]):
            rest=[h for h in g["hooks"] if not is_our_hook(h)]
            if rest: out.append(dict(g,hooks=rest))
        else: out.append(g)
    return out
def upsert(event,matcher,arg):
    arr=strip(hooks[event]) if isinstance(hooks.get(event),list) else []
    arr.append({"matcher":matcher,"hooks":[{"type":"command","command":notify+" "+arg}]})
    hooks[event]=arr
def drop(event):
    if not isinstance(hooks.get(event),list): return
    arr=strip(hooks[event])
    if arr: hooks[event]=arr
    else: hooks.pop(event,None)
upsert("Stop","","Stop")
upsert("Notification","","Notification")
upsert("PermissionRequest","","PermissionRequest")
upsert("PreToolUse","AskUserQuestion|ExitPlanMode","PreToolUse")
drop("PostToolUse")   # older versions hooked every Read/Edit/Write here
settings["hooks"]=hooks
os.makedirs(os.path.dirname(f),exist_ok=True)
with open(f,"w",encoding="utf-8") as fh:
    fh.write(json.dumps(settings,indent=2)+"\n")
'
fi
ok "Hooks added (existing hooks preserved)"

# --- 4. test notification --------------------------------------------------
step "Sending a test notification"
if "$TN_PATH" -title "Claude Code" -subtitle "Notifications installed" -message "You'll see a banner like this when Claude finishes or needs you." -sound default >/dev/null 2>&1; then
  ok "Test notification sent"
else
  warn "Could not send a test notification — check System Settings > Notifications."
fi

printf '\n%sDone.%s\n' "$C_GREEN" "$C_RESET"
printf '%sRestart any open Claude Code session so it picks up the new hooks.%s\n' "$C_GREEN" "$C_RESET"
printf '%sIf the test banner did not appear, allow "terminal-notifier" in System Settings > Notifications (set it to "Alerts" to make banners stay on screen).%s\n' "$C_YELLOW" "$C_RESET"
printf '%sFocus-aware suppression (no banner while you are looking at that project'\''s VS Code window) needs Accessibility permission for the app running the hook — grant it in System Settings > Privacy & Security > Accessibility. Without it, banners simply always show.%s\n\n' "$C_YELLOW" "$C_RESET"
