#!/usr/bin/env python3
"""macOS Commander Controller: a standalone Desktop Commander-style MCP server for modern macOS (stdio or unix socket, stdlib only).
Files, shell sessions, search, screenshots and mouse/keyboard control. Run it over ssh or locally:
    ssh jr@host python3 mac-commander.py
Mouse and keyboard need Accessibility permission for the process that launches it; screenshots need Screen Recording.
Environment: MC_ALLOWED (colon-separated roots limiting the file tools, default: everything)."""
import base64, ctypes, json, os, pty, re, shutil, signal, subprocess, sys, tempfile, termios, threading, time

ALLOWED = [os.path.realpath(p) for p in os.environ.get("MC_ALLOWED", "").split(":") if p]
CAP = 100000

def fail(msg): raise RuntimeError(msg)

def path_ok(p):
    p = os.path.realpath(os.path.expanduser(p))
    if ALLOWED and not any(p == a or p.startswith(a + os.sep) for a in ALLOWED):
        fail("%s is outside the allowed directories" % p)
    return p

def clip(s): return s if len(s) <= CAP else s[:CAP] + "\n[output cut at %d characters]" % CAP

# ---------------------------------------------------------------- files
IMG = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}

def image(p, text):
    with open(p, "rb") as f: data = base64.b64encode(f.read()).decode()
    return {"text": text, "image": data, "mime": IMG[os.path.splitext(p)[1].lower()]}

def read_file(a):
    p = path_ok(a["path"])
    if os.path.splitext(p)[1].lower() in IMG: return image(p, "image " + p)
    off, n = int(a.get("offset", 0)), int(a.get("length", 1000))
    with open(p, "rb") as f: lines = f.read().decode("utf-8", "replace").split("\n")
    sel = lines[off:] if off >= 0 else lines[off:]
    if off >= 0: sel = sel[:n]
    return "[lines %d-%d of %d]\n%s" % (max(off, 0), max(off, 0) + len(sel), len(lines), "\n".join(sel))

def write_file(a):
    p = path_ok(a["path"])
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "a" if a.get("mode") == "append" else "w") as f: f.write(a["content"])
    return "wrote %d characters to %s" % (len(a["content"]), p)

def edit_block(a):
    p = path_ok(a["file_path"])
    with open(p) as f: t = f.read()
    old, want = a["old_string"], int(a.get("expected_replacements", 1))
    if t.count(old) != want: fail("found %d occurrences of old_string, expected %d" % (t.count(old), want))
    with open(p, "w") as f: f.write(t.replace(old, a["new_string"]))
    return "replaced %d occurrence(s) in %s" % (want, p)

def list_directory(a):
    p = path_ok(a.get("path", "~"))
    return "\n".join(("[DIR] " if os.path.isdir(os.path.join(p, n)) else "[FILE] ") + n for n in sorted(os.listdir(p)))

def create_directory(a):
    os.makedirs(path_ok(a["path"]), exist_ok=True); return "created " + a["path"]

def move_file(a):
    shutil.move(path_ok(a["source"]), path_ok(a["destination"])); return "moved"

def get_file_info(a):
    p = path_ok(a["path"]); s = os.stat(p)
    return "\n".join("%s: %s" % kv for kv in [("path", p), ("size", s.st_size), ("modified", time.ctime(s.st_mtime)),
        ("mode", oct(s.st_mode)), ("type", "directory" if os.path.isdir(p) else "file")])

def read_multiple_files(a):
    out = []
    for p in a["paths"]:
        try: r = read_file({"path": p}); out.append("== %s ==\n%s" % (p, r if isinstance(r, str) else r["text"]))
        except Exception as e: out.append("== %s ==\nerror: %s" % (p, e))
    return "\n\n".join(out)

def search(a):
    root, pat, kind = path_ok(a["path"]), a["pattern"], a.get("searchType", "files")
    if kind == "content":
        cmd = ["grep", "-rIn", "-m", "20", "--exclude-dir=.git", "--exclude-dir=node_modules", "-e", pat, root]
        if a.get("filePattern"): cmd[2:2] = ["--include=" + a["filePattern"]]
    else: cmd = ["find", root, "-iname", "*%s*" % pat, "-not", "-path", "*/.git/*"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    lines = r.stdout.splitlines()[:int(a.get("maxResults", 200))]
    return "\n".join(lines) or "no matches"

# ---------------------------------------------------------------- processes (pty sessions, so REPLs and prompts work)
SESS = {}

class Sess:
    def __init__(s, cmd, shell):
        s.cmd, s.buf, s.pos, s.last, s.done = cmd, "", 0, time.time(), False
        s.master, slave = pty.openpty()
        attr = termios.tcgetattr(slave); attr[3] &= ~termios.ECHO; termios.tcsetattr(slave, termios.TCSANOW, attr)
        s.p = subprocess.Popen([shell, "-c", cmd], stdin=slave, stdout=slave, stderr=slave, start_new_session=True, close_fds=True)
        os.close(slave)
        threading.Thread(target=s.pump, daemon=True).start()
    def pump(s):
        while True:
            try: d = os.read(s.master, 65536)
            except OSError: d = b""
            if not d: break
            s.buf += d.decode("utf-8", "replace"); s.last = time.time()
        s.p.wait(); s.done = True
    def wait(s, timeout, idle=0.4):
        end = time.time() + timeout
        while time.time() < end:
            fresh = len(s.buf) > s.pos
            if s.done and (fresh or time.time() - s.last > 0.1): break
            if fresh and time.time() - s.last > idle: break
            time.sleep(0.05)
        out, s.pos = s.buf[s.pos:], len(s.buf)
        state = "finished (exit %s)" % s.p.returncode if s.done else "running"
        return clip("pid %d %s\n%s" % (s.p.pid, state, out))

def start_process(a):
    s = Sess(a["command"], a.get("shell", "/bin/zsh")); SESS[s.p.pid] = s
    return s.wait(float(a.get("timeout_ms", 10000)) / 1000)

def sess(a):
    s = SESS.get(int(a["pid"]))
    if not s: fail("no session with pid %s" % a["pid"])
    return s

def interact(a):
    s = sess(a)
    if s.done: fail("process has finished")
    os.write(s.master, (a["input"] + ("" if a["input"].endswith("\n") else "\n")).encode())
    return s.wait(float(a.get("timeout_ms", 8000)) / 1000)

def read_output(a): return sess(a).wait(float(a.get("timeout_ms", 5000)) / 1000)

def force_terminate(a):
    s = sess(a)
    try: os.killpg(s.p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    return "terminated %d" % s.p.pid

def list_sessions(a):
    return "\n".join("%d %s %s" % (p, "finished" if s.done else "running", s.cmd[:80]) for p, s in SESS.items()) or "no sessions"

def list_processes(a):
    return clip(subprocess.run(["ps", "-axo", "pid,pcpu,pmem,comm"], capture_output=True, text=True).stdout)

def kill_process(a):
    os.kill(int(a["pid"]), signal.SIGTERM); return "sent SIGTERM to %s" % a["pid"]

# ---------------------------------------------------------------- screen (CoreGraphics through ctypes)
class Pt(ctypes.Structure): _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
class Sz(ctypes.Structure): _fields_ = [("w", ctypes.c_double), ("h", ctypes.c_double)]
class Rc(ctypes.Structure): _fields_ = [("o", Pt), ("s", Sz)]

_cg = None
def cg():
    global _cg
    if _cg: return _cg
    L = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    C = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    v, u32, u16, i32, d = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint16, ctypes.c_int32, ctypes.c_double
    def sig(f, res, *args): f.restype, f.argtypes = res, list(args)
    sig(L.CGEventCreateMouseEvent, v, v, u32, Pt, u32)
    sig(L.CGEventCreateKeyboardEvent, v, v, u16, ctypes.c_bool)
    sig(L.CGEventCreateScrollWheelEvent2, v, v, u32, u32, i32, i32, i32)
    sig(L.CGEventKeyboardSetUnicodeString, None, v, ctypes.c_ulong, ctypes.POINTER(u16))
    sig(L.CGEventSetFlags, None, v, ctypes.c_uint64)
    sig(L.CGEventSetIntegerValueField, None, v, u32, ctypes.c_int64)
    sig(L.CGEventPost, None, u32, v)
    sig(L.CGEventCreate, v, v)
    sig(L.CGEventGetLocation, Pt, v)
    sig(L.CGMainDisplayID, u32)
    sig(L.CGDisplayBounds, Rc, u32)
    sig(L.CGDisplayPixelsWide, ctypes.c_size_t, u32)
    sig(L.AXIsProcessTrusted, ctypes.c_bool)
    sig(C.CFRelease, None, v)
    L.cf = C.CFRelease; _cg = L
    return L

scale = 1.0   # screen points per pixel of the last screenshot

def post(e):
    cg().CGEventPost(0, e); cg().cf(e); time.sleep(0.012)

def check_trust():
    if not cg().AXIsProcessTrusted():
        fail("this process has no Accessibility permission, so mouse and keyboard events are ignored. Grant it to the app that launched this server (System Settings > Privacy & Security > Accessibility).")

def pt(a, kx="x", ky="y"):
    b = cg().CGDisplayBounds(cg().CGMainDisplayID())
    x, y = float(a[kx]) * scale, float(a[ky]) * scale
    if not (0 <= x < b.s.w and 0 <= y < b.s.h):
        fail("(%s, %s) is outside the screen (%d x %d points). Coordinates are pixels of the last screenshot." % (a[kx], a[ky], b.s.w, b.s.h))
    return Pt(x, y)

def mouse(kind, p, button=0, clicks=0):
    e = cg().CGEventCreateMouseEvent(None, kind, p, button)
    if clicks: cg().CGEventSetIntegerValueField(e, 1, clicks)
    post(e)

def screen_info(a):
    L = cg(); b = L.CGDisplayBounds(L.CGMainDisplayID()); e = L.CGEventCreate(None); at = L.CGEventGetLocation(e); L.cf(e)
    return ("screen: %d x %d points (main display), %d pixels wide\nmouse: %d, %d points\naccessibility: %s\n"
            "coordinates for screen_* tools are pixels of the last take_screenshot picture (%.3f points per pixel)"
            % (b.s.w, b.s.h, L.CGDisplayPixelsWide(L.CGMainDisplayID()), at.x, at.y, "granted" if L.AXIsProcessTrusted() else "NOT granted", scale))

def screen_move(a):
    check_trust(); p = pt(a); mouse(5, p); return "mouse at %d, %d" % (p.x, p.y)

def screen_click(a):
    check_trust(); p = pt(a); right = a.get("button", "left") == "right"; n = int(a.get("clicks", 1))
    if n not in (1, 2, 3): fail("clicks must be 1, 2 or 3")
    mouse(5, p); time.sleep(0.15)   # let the window server see the pointer over the target before pressing
    for i in range(1, n + 1):
        mouse(3 if right else 1, p, int(right), i); time.sleep(0.05); mouse(4 if right else 2, p, int(right), i); time.sleep(0.05)
    return "clicked %s x%d at %d, %d" % ("right" if right else "left", n, p.x, p.y)

def screen_drag(a):
    check_trust(); f, t = pt(a), pt(a, "to_x", "to_y")
    mouse(5, f); mouse(1, f, 0, 1)
    for i in range(1, 11):
        mouse(6, Pt(f.x + (t.x - f.x) * i / 10, f.y + (t.y - f.y) * i / 10)); time.sleep(0.02)
    mouse(2, t, 0, 1)
    return "dragged from %d, %d to %d, %d" % (f.x, f.y, t.x, t.y)

def screen_scroll(a):
    check_trust(); n = int(a["amount"])
    if n == 0 or abs(n) > 50: fail("amount must be -50..50 and not 0 (positive scrolls up)")
    if "x" in a and "y" in a: mouse(5, pt(a))
    post(cg().CGEventCreateScrollWheelEvent2(None, 1, 1, n, 0, 0)); return "scrolled %d" % n

def tap(code, down, text=None, flags=0):
    e = cg().CGEventCreateKeyboardEvent(None, code, down)
    if text: u = text.encode("utf-16-le"); buf = (ctypes.c_uint16 * (len(u) // 2)).from_buffer_copy(u); cg().CGEventKeyboardSetUnicodeString(e, len(buf), buf)
    cg().CGEventSetFlags(e, flags | 0x100)   # always set explicitly (NonCoalesced): events with the default flags were dropped by apps
    post(e)

SHIFTED = dict(zip('!@#$%^&*()_+{}|:"<>?~', '1234567890-=[]\\;\',./`'))

def screen_type(a):
    check_trust(); text = a["text"]
    if len(text) > 2000: fail("at most 2000 characters at a time")
    for ch in text:
        if ch in "\r\n": code, fl, uni = 36, 0, None
        elif ch == "\t": code, fl, uni = 48, 0, None
        elif ch == " ": code, fl, uni = 49, 0, None
        elif ch.isascii() and ch.lower() in KEYS and len(ch) == 1: code, fl, uni = KEYS[ch.lower()], MODS["shift"] if ch.isupper() else 0, None
        elif ch in SHIFTED: code, fl, uni = KEYS[SHIFTED[ch]], MODS["shift"], None
        else: code, fl, uni = 0, 0, ch   # not on a US keyboard: send it as a Unicode string
        tap(code, True, uni, fl); tap(code, False, uni, fl)
    return "typed %d characters" % len(text)

KEYS = dict(a=0, s=1, d=2, f=3, h=4, g=5, z=6, x=7, c=8, v=9, b=11, q=12, w=13, e=14, r=15, y=16, t=17, o=31, u=32, i=34, p=35, l=37, j=38, k=40, n=45, m=46)
KEYS.update({"1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "[": 33, "'": 39, ";": 41,
    "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50, "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111})
MODS = {"cmd": 0x100000, "command": 0x100000, "shift": 0x20000, "option": 0x80000, "alt": 0x80000, "control": 0x40000, "ctrl": 0x40000}

def screen_key(a):
    check_trust(); key = a["key"].strip().lower(); mods = [m.lower() for m in a.get("modifiers", [])]
    if key not in KEYS: fail("unknown key %s. Use a letter/digit/punctuation, return, tab, space, delete, escape, arrows, home, end, pageup, pagedown, forwarddelete, f1-f12." % key)
    for m in mods:
        if m not in MODS: fail("unknown modifier %s (cmd, shift, option, control)" % m)
    flags = 0
    for m in mods: flags |= MODS[m]
    tap(KEYS[key], True, None, flags); tap(KEYS[key], False, None, flags)
    return "pressed %s%s" % ("+".join(mods) + "+" if mods else "", key)

def take_screenshot(a):
    global scale
    width = max(320, min(2048, int(a.get("max_width", 1024))))
    d = tempfile.mkdtemp(); png, jpg = d + "/s.png", d + "/s.jpg"
    try:
        r = subprocess.run(["/usr/sbin/screencapture", "-x", "-C", png], capture_output=True, text=True, timeout=20)
        if not os.path.exists(png) or not os.path.getsize(png):
            fail("could not capture the screen (%s). Someone must be logged in with the display awake, and Screen Recording must be allowed." % r.stderr.strip())
        subprocess.run(["/usr/bin/sips", "-Z", str(width), "-s", "format", "jpeg", "-s", "formatOptions", "60", png, "--out", jpg], capture_output=True, timeout=30)
        L = cg(); b = L.CGDisplayBounds(L.CGMainDisplayID())
        sh = subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", jpg], capture_output=True, text=True).stdout
        px = int(re.search(r"pixelWidth: (\d+)", sh).group(1))
        scale = b.s.w / px
        r = image(jpg, "Screenshot of the main display (%d pixels wide, JPEG). Click coordinates are pixels of this picture." % px)
        return r
    finally: shutil.rmtree(d, ignore_errors=True)

def view_image(a): return image(path_ok(a["path"]), "image " + a["path"])

# ---------------------------------------------------------------- MCP
def P(props, req=()):
    return {"type": "object", "properties": {k: {"type": v[0], "description": v[1]} if len(v) > 1 else {"type": v[0]} for k, v in props.items()}, "required": list(req)}

TOOLS = [
    ("read_file", "Read a text file (offset/length in lines; negative offset reads from the end) or view an image.", read_file, P({"path": ("string",), "offset": ("number",), "length": ("number",)}, ["path"])),
    ("read_multiple_files", "Read several files.", read_multiple_files, P({"paths": ("array",)}, ["paths"])),
    ("write_file", "Write a file (mode rewrite or append).", write_file, P({"path": ("string",), "content": ("string",), "mode": ("string", "rewrite or append")}, ["path", "content"])),
    ("edit_block", "Replace old_string with new_string in a file.", edit_block, P({"file_path": ("string",), "old_string": ("string",), "new_string": ("string",), "expected_replacements": ("number",)}, ["file_path", "old_string", "new_string"])),
    ("list_directory", "List a directory.", list_directory, P({"path": ("string",)}, ["path"])),
    ("create_directory", "Create a directory (and parents).", create_directory, P({"path": ("string",)}, ["path"])),
    ("move_file", "Move or rename.", move_file, P({"source": ("string",), "destination": ("string",)}, ["source", "destination"])),
    ("get_file_info", "Size, times, type of a path.", get_file_info, P({"path": ("string",)}, ["path"])),
    ("start_search", "Search by file name (searchType files) or file contents (content). Returns the results directly.", search, P({"path": ("string",), "pattern": ("string",), "searchType": ("string", "files or content"), "filePattern": ("string", "glob such as *.py"), "maxResults": ("number",)}, ["path", "pattern"])),
    ("start_process", "Run a shell command in a terminal session; returns when output goes idle or timeout_ms passes, leaving it running. REPLs work.", start_process, P({"command": ("string",), "timeout_ms": ("number",), "shell": ("string",)}, ["command"])),
    ("interact_with_process", "Send a line of input to a running session.", interact, P({"pid": ("number",), "input": ("string",), "timeout_ms": ("number",)}, ["pid", "input"])),
    ("read_process_output", "Read new output from a session.", read_output, P({"pid": ("number",), "timeout_ms": ("number",)}, ["pid"])),
    ("force_terminate", "Kill a session started with start_process.", force_terminate, P({"pid": ("number",)}, ["pid"])),
    ("list_sessions", "List sessions started here.", list_sessions, P({})),
    ("list_processes", "List running processes.", list_processes, P({})),
    ("kill_process", "SIGTERM a process by pid.", kill_process, P({"pid": ("number",)}, ["pid"])),
    ("take_screenshot", "Screenshot of the main display. Take one before using screen_* coordinates.", take_screenshot, P({"max_width": ("number", "picture width in pixels, 320-2048, default 1024")})),
    ("view_image", "View an image file.", view_image, P({"path": ("string",)}, ["path"])),
    ("screen_info", "Screen size, mouse position, permission state and coordinate scale.", screen_info, P({})),
    ("screen_click", "Click at x,y (pixels of the last screenshot). button left/right, clicks 1-3.", screen_click, P({"x": ("number",), "y": ("number",), "button": ("string",), "clicks": ("number",)}, ["x", "y"])),
    ("screen_move", "Move the pointer to x,y.", screen_move, P({"x": ("number",), "y": ("number",)}, ["x", "y"])),
    ("screen_drag", "Press at x,y, drag to to_x,to_y, release.", screen_drag, P({"x": ("number",), "y": ("number",), "to_x": ("number",), "to_y": ("number",)}, ["x", "y", "to_x", "to_y"])),
    ("screen_scroll", "Scroll the wheel (positive up), optionally after moving to x,y.", screen_scroll, P({"amount": ("number",), "x": ("number",), "y": ("number",)}, ["amount"])),
    ("screen_type", "Type text (any Unicode) into whatever has keyboard focus.", screen_type, P({"text": ("string",)}, ["text"])),
    ("screen_key", "Press one key with optional modifiers (cmd, shift, option, control), e.g. key w, modifiers [cmd].", screen_key, P({"key": ("string",), "modifiers": ("array",)}, ["key"])),
]
HANDLERS = {n: f for n, _, f, _ in TOOLS}

def call(name, args):
    if name not in HANDLERS: fail("unknown tool " + name)
    r = HANDLERS[name](args or {})
    if isinstance(r, dict): return [{"type": "text", "text": r["text"]}, {"type": "image", "data": r["image"], "mimeType": r["mime"]}]
    return [{"type": "text", "text": clip(str(r))}]

def handle(m):
    meth, id_ = m.get("method"), m.get("id")
    if id_ is None: return None
    if meth == "initialize":
        res = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "macos-commander-controller", "version": "1.0.0"}}
    elif meth == "tools/list":
        res = {"tools": [{"name": n, "description": d, "inputSchema": s} for n, d, _, s in TOOLS]}
    elif meth == "tools/call":
        try: res = {"content": call(m["params"]["name"], m["params"].get("arguments"))}
        except Exception as e: res = {"content": [{"type": "text", "text": "Error: %s" % e}], "isError": True}
    elif meth == "ping": res = {}
    else: return {"jsonrpc": "2.0", "id": id_, "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": id_, "result": res}

def serve(inp, out):
    for line in inp:
        if not line.strip(): continue
        try: r = handle(json.loads(line))
        except Exception as e: r = None; sys.stderr.write("bad request: %s\n" % e)
        if r: out.write(json.dumps(r) + "\n"); out.flush()

def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--socket":
        # Background mode: run from a LaunchAgent in the GUI login session (needed for clicks and drags), listening on a
        # private unix socket. Connect with:  ssh host nc -U ~/.mac-commander.sock
        import socket
        path = os.path.expanduser(sys.argv[2])
        if os.path.exists(path): os.unlink(path)
        srv = socket.socket(socket.AF_UNIX); srv.bind(path); os.chmod(path, 0o600); srv.listen(4)
        while True:
            c, _ = srv.accept()
            threading.Thread(target=lambda c=c: serve(c.makefile("r"), c.makefile("w")), daemon=True).start()
    serve(sys.stdin, sys.stdout)
    for s in SESS.values():
        try: os.killpg(s.p.pid, signal.SIGKILL)
        except Exception: pass

if __name__ == "__main__": main()
