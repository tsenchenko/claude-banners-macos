#!/usr/bin/env bash
#
# Removes Claude Code macOS notifications setup for the current user.
#
# Reverses install.sh: deletes the hook scripts, removes the per-user
# terminal-notifier copy (if we installed one), and strips our hook entries from
# ~/.claude/settings.json (other keys and other hooks are preserved).
#
# A Homebrew-installed terminal-notifier is left in place (you may use it
# elsewhere) — remove it yourself with: brew uninstall terminal-notifier
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/tsenchenko/claude-banners-macos/main/uninstall.sh | bash

set -uo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.claude/bin"
SETTINGS="$HOME/.claude/settings.json"

if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_MAGENTA=$'\033[35m'; C_RESET=$'\033[0m'
else C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_MAGENTA=""; C_RESET=""; fi
step() { printf '%s==> %s%s\n' "$C_CYAN" "$1" "$C_RESET"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$1" "$C_RESET"; }

printf '\n%sClaude Code Notifications for macOS — uninstaller%s\n\n' "$C_MAGENTA" "$C_RESET"

# 1. hook scripts
step "Removing hook scripts"
for f in notify.sh focus-vscode.sh; do
  if [ -f "$HOOKS_DIR/$f" ]; then rm -f "$HOOKS_DIR/$f"; ok "Deleted $f"; fi
done
if [ -d "$HOOKS_DIR" ] && [ -z "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ]; then
  rmdir "$HOOKS_DIR" && ok "Removed empty hooks directory"
fi

# 2. per-user terminal-notifier copy (only the one we installed)
step "Removing per-user terminal-notifier copy (if any)"
if [ -d "$BIN_DIR/terminal-notifier.app" ]; then
  rm -rf "$BIN_DIR/terminal-notifier.app"
  ok "Removed $BIN_DIR/terminal-notifier.app"
  if [ -d "$BIN_DIR" ] && [ -z "$(ls -A "$BIN_DIR" 2>/dev/null)" ]; then rmdir "$BIN_DIR"; fi
fi

# 3. remove ONLY our hook entries from settings.json.
# We identify our entries by the notify.sh command path and drop just those,
# leaving SessionStart and any other user hooks intact. The marker matches both
# the portable "$HOME/..." form and older absolute-path installs. An event key is
# removed only if it becomes empty, and the "hooks" object only if it becomes empty.
step "Cleaning settings.json"
if [ -f "$SETTINGS" ]; then
  RT=""
  if command -v node >/dev/null 2>&1; then RT="node"
  elif command -v python3 >/dev/null 2>&1; then RT="python3"; fi
  if [ "$RT" = "node" ]; then
    CT_SETTINGS="$SETTINGS" node -e '
      const fs=require("fs");
      const file=process.env.CT_SETTINGS;
      const marker="/.claude/hooks/notify.sh";
      let raw="";try{raw=fs.readFileSync(file,"utf8");}catch(e){process.exit(0);}
      if(!raw.trim())process.exit(0);
      let s;try{s=JSON.parse(raw);}catch(e){console.error("    Could not parse settings.json — leaving it alone.");process.exit(0);}
      if(!s||typeof s!=="object"||typeof s.hooks!=="object"||s.hooks===null)process.exit(0);
      // Strip OUR hook entries, not whole groups (a group may hold other hooks).
      const isOurHook=h=>h&&typeof h.command==="string"&&h.command.includes(marker);
      const strip=arr=>arr.flatMap(g=>{
        if(!g||!Array.isArray(g.hooks)||!g.hooks.some(isOurHook)) return [g];
        const rest=g.hooks.filter(h=>!isOurHook(h));
        return rest.length?[Object.assign({},g,{hooks:rest})]:[];
      });
      let changed=false;
      for(const ev of ["Stop","Notification","PermissionRequest","PreToolUse","PostToolUse"]){
        if(Array.isArray(s.hooks[ev])){
          const kept=strip(s.hooks[ev]);
          if(JSON.stringify(kept)!==JSON.stringify(s.hooks[ev]))changed=true;
          if(kept.length>0)s.hooks[ev]=kept; else delete s.hooks[ev];
        }
      }
      if(Object.keys(s.hooks).length===0)delete s.hooks;
      if(changed){fs.writeFileSync(file,JSON.stringify(s,null,2)+"\n");console.log("    our hook entries removed (other hooks preserved)");}
      else console.log("    nothing of ours to remove");
    '
  elif [ "$RT" = "python3" ]; then
    CT_SETTINGS="$SETTINGS" python3 -c '
import os,sys,json
f=os.environ["CT_SETTINGS"]; marker="/.claude/hooks/notify.sh"
try:
    with open(f,"r",encoding="utf-8") as fh: raw=fh.read()
except Exception: sys.exit(0)
if not raw.strip(): sys.exit(0)
try: s=json.loads(raw)
except Exception:
    print("    Could not parse settings.json — leaving it alone."); sys.exit(0)
if not isinstance(s,dict) or not isinstance(s.get("hooks"),dict): sys.exit(0)
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
changed=False
for ev in ["Stop","Notification","PermissionRequest","PreToolUse","PostToolUse"]:
    if isinstance(s["hooks"].get(ev),list):
        kept=strip(s["hooks"][ev])
        if kept!=s["hooks"][ev]: changed=True
        if kept: s["hooks"][ev]=kept
        else: del s["hooks"][ev]
if not s["hooks"]: del s["hooks"]
if changed:
    with open(f,"w",encoding="utf-8") as fh: fh.write(json.dumps(s,indent=2)+"\n")
    print("    our hook entries removed (other hooks preserved)")
else:
    print("    nothing of ours to remove")
'
  else
    printf '    %sNo node/python3 found — edit %s by hand to remove the notify.sh hook entries.%s\n' "$C_YELLOW" "$SETTINGS" "$C_RESET"
  fi
fi

printf '\n%sDone. Restart Claude Code so it stops calling the (now removed) hooks.%s\n\n' "$C_GREEN" "$C_RESET"
