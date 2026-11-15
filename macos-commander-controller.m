// macOS Commander Controller: a standalone Desktop Commander-style MCP server for modern macOS.
// Files, shell sessions, search, screenshots, and mouse/keyboard control. One file, no dependencies beyond the system.
//
//   build:  clang -O2 -fobjc-arc -framework Foundation -framework ApplicationServices -o macos-commander-controller macos-commander-controller.m
//   stdio:  macos-commander-controller                      (MCP, one JSON message per line)
//   daemon: macos-commander-controller --socket ~/.mac-commander.sock   (run from a LaunchAgent in the GUI session)
//   other:  --check (permission state)   --request (show the system permission prompts)   --version
//
// Environment: MC_ALLOWED = colon-separated folders that limit the file tools (shell commands are not limited).

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <mach-o/dyld.h>
#import <poll.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <termios.h>
#import <unistd.h>
#import <util.h>

#define VERSION "2.0.0"
#define CAP 100000
#define MAX_SESSIONS 12          // live shell sessions; the least recently used is closed to make room
#define BUFFER_LIMIT (4 << 20)   // unread output kept per session (newest part wins)

static NSArray<NSString *> *allowedRoots;
static NSString *exePath;
static __thread int curConn;     // the client connection the current request came from
static double screenScale = 1.0; // screen points per pixel of the last screenshot

#define FAIL(...) @throw [NSException exceptionWithName:@"MCFail" reason:[NSString stringWithFormat:__VA_ARGS__] userInfo:nil]

static double Now(void) { return CFAbsoluteTimeGetCurrent(); }

// ---------------------------------------------------------------- arguments

static id Arg(NSDictionary *a, NSString *k, Class c)
{
    id v = a[k];
    if (v && ![v isKindOfClass:c]) FAIL(@"%@ has the wrong type", k);
    return v;
}

static NSString *Str(NSDictionary *a, NSString *k, NSString *def)
{
    NSString *v = Arg(a, k, [NSString class]);
    if (v) return v;
    if (!def) FAIL(@"missing argument %@", k);
    return def;
}

static double Num(NSDictionary *a, NSString *k, double def)   // def NAN = required
{
    id v = a[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]] && [v length]) return [v doubleValue];
    if (isnan(def)) FAIL(@"missing number %@", k);
    return def;
}

static NSString *Path(NSString *p)
{
    NSString *r = [p stringByExpandingTildeInPath];
    if (![r isAbsolutePath]) r = [NSHomeDirectory() stringByAppendingPathComponent:r];
    r = [[r stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (allowedRoots.count) {
        BOOL ok = NO;
        for (NSString *root in allowedRoots)
            if ([r isEqualToString:root] || [r hasPrefix:[root stringByAppendingString:@"/"]]) ok = YES;
        if (!ok) FAIL(@"%@ is outside the allowed folders", r);
    }
    return r;
}

static NSString *Clip(NSString *s) { return s.length <= CAP ? s : [[s substringToIndex:CAP] stringByAppendingFormat:@"\n[output cut at %d characters]", CAP]; }

static NSString *Decode(NSData *d)
{
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

static id Image(NSString *path, NSString *text)
{
    NSString *ext = path.pathExtension.lowercaseString;
    NSDictionary *mimes = @{@"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"gif": @"image/gif", @"webp": @"image/webp"};
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!mimes[ext] || !d) FAIL(@"cannot read %@ as an image", path);
    return @{@"text": text, @"image": [d base64EncodedStringWithOptions:0], @"mime": mimes[ext]};
}

// Run a program without a shell; returns its exit code (-1 if killed or not started).
static int Run(NSArray<NSString *> *argv, double timeout, NSString **out)
{
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:argv[0]];
    t.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = p;
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { if (out) *out = e.localizedDescription; return -1; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{ if (t.isRunning) kill(t.processIdentifier, SIGKILL); });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (out) *out = Decode(d);
    return t.terminationReason == NSTaskTerminationReasonUncaughtSignal ? -1 : t.terminationStatus;
}

// ---------------------------------------------------------------- files

static id tReadFile(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"path", nil));
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"webp"] containsObject:p.pathExtension.lowercaseString]) return Image(p, [@"image " stringByAppendingString:p]);
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) FAIL(@"cannot read %@", p);
    NSArray *lines = [Decode(d) componentsSeparatedByString:@"\n"];
    long off = (long)Num(a, @"offset", 0), n = (long)Num(a, @"length", 1000), total = (long)lines.count;
    if (off < 0) off = MAX(0, total + off);
    if (off > total) off = total;
    n = MIN(n, total - off);
    return [NSString stringWithFormat:@"[lines %ld-%ld of %ld]\n%@", off, off + n, total, [[lines subarrayWithRange:NSMakeRange(off, n)] componentsJoinedByString:@"\n"]];
}

static id tReadMultiple(NSDictionary *a)
{
    NSArray *paths = Arg(a, @"paths", [NSArray class]);
    if (!paths) FAIL(@"missing argument paths");
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in paths) {
        @try { id r = tReadFile(@{@"path": p}); [out addObject:[NSString stringWithFormat:@"== %@ ==\n%@", p, [r isKindOfClass:[NSString class]] ? r : r[@"text"]]]; }
        @catch (NSException *e) { [out addObject:[NSString stringWithFormat:@"== %@ ==\nerror: %@", p, e.reason]]; }
    }
    return [out componentsJoinedByString:@"\n\n"];
}

static id tWriteFile(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"path", nil)), *text = Str(a, @"content", nil);
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    [[NSFileManager defaultManager] createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([Str(a, @"mode", @"rewrite") isEqualToString:@"append"] && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!h) FAIL(@"cannot open %@", p);
        [h seekToEndOfFile];
        [h writeData:d];
        [h closeFile];
    } else if (![d writeToFile:p atomically:NO]) FAIL(@"cannot write %@", p);
    return [NSString stringWithFormat:@"wrote %lu bytes to %@", (unsigned long)d.length, p];
}

static id tEditBlock(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"file_path", nil)), *old = Str(a, @"old_string", nil), *new = Str(a, @"new_string", nil);
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) FAIL(@"cannot read %@", p);
    NSString *t = Decode(d);
    long want = (long)Num(a, @"expected_replacements", 1), have = (long)[t componentsSeparatedByString:old].count - 1;
    if (!old.length || have != want) FAIL(@"found %ld occurrences of old_string, expected %ld", have, want);
    if (![[t stringByReplacingOccurrencesOfString:old withString:new] writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:NULL]) FAIL(@"cannot write %@", p);
    return [NSString stringWithFormat:@"replaced %ld occurrence(s) in %@", want, p];
}

static id tListDirectory(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"path", @"~"));
    NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    if (!names) FAIL(@"cannot list %@", p);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        BOOL dir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:[p stringByAppendingPathComponent:n] isDirectory:&dir];
        [out addObject:[(dir ? @"[DIR] " : @"[FILE] ") stringByAppendingString:n]];
    }
    return out.count ? [out componentsJoinedByString:@"\n"] : @"(empty)";
}

static id tCreateDirectory(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"path", nil));
    if (![[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL]) FAIL(@"cannot create %@", p);
    return [@"created " stringByAppendingString:p];
}

static id tMoveFile(NSDictionary *a)
{
    NSString *s = Path(Str(a, @"source", nil)), *d = Path(Str(a, @"destination", nil));
    NSError *e = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:s toPath:d error:&e]) FAIL(@"%@", e.localizedDescription);
    return [NSString stringWithFormat:@"moved %@ to %@", s, d];
}

static id tFileInfo(NSDictionary *a)
{
    NSString *p = Path(Str(a, @"path", nil));
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    if (!at) FAIL(@"no such file: %@", p);
    return [NSString stringWithFormat:@"path: %@\ntype: %@\nsize: %@\nmodified: %@\nmode: %lo", p, at[NSFileType], at[NSFileSize], at[NSFileModificationDate], (unsigned long)[at[NSFilePosixPermissions] unsignedLongValue]];
}

static id tSearch(NSDictionary *a)
{
    NSString *root = Path(Str(a, @"path", nil)), *pat = Str(a, @"pattern", nil), *kind = Str(a, @"searchType", @"files");
    NSString *max = [NSString stringWithFormat:@"%d", (int)Num(a, @"maxResults", 200)], *glob = Str(a, @"filePattern", @""), *out = nil;
    NSString *script = [kind isEqualToString:@"content"]
        ? @"grep -rIn -m 20 --exclude-dir=.git --exclude-dir=node_modules ${4:+--include=\"$4\"} -e \"$2\" \"$1\" 2>/dev/null | head -n \"$3\""
        : @"find \"$1\" -iname \"*$2*\" -not -path \"*/.git/*\" 2>/dev/null | head -n \"$3\"";
    Run(@[@"/bin/sh", @"-c", script, @"sh", root, pat, max, glob], 60, &out);
    return out.length ? Clip(out) : @"no matches";
}

// ---------------------------------------------------------------- shell sessions (pty, so REPLs and prompts work)

@interface Sess : NSObject
@property pid_t pid;
@property int master, owner;
@property NSString *cmd;
@property NSMutableData *buf;
@property NSUInteger pos;
@property double lastOut, lastUsed, doneAt;
@property BOOL done, closing;
@property int status;
@end

static NSMutableDictionary<NSNumber *, Sess *> *sessions;   // guarded by @synchronized(sessions)

@implementation Sess

- (void)reap:(BOOL)block
{
    @synchronized(self) {
        if (_done) return;
        int st = 0;
        if (waitpid(_pid, &st, block ? 0 : WNOHANG) == _pid) { _done = YES; _status = st; _doneAt = Now(); }
    }
}

- (void)pump   // reader thread: collects output, reaps the child, closes the terminal when everything is read
{
    char tmp[16384];
    for (;;) {
        struct pollfd pf = {_master, POLLIN, 0};
        int r = poll(&pf, 1, 200);
        [self reap:NO];
        if (_closing) break;
        if (r > 0) {
            ssize_t n = read(_master, tmp, sizeof tmp);
            if (n > 0) {
                @synchronized(self) {
                    [_buf appendBytes:tmp length:n];
                    _lastOut = Now();
                    if (_buf.length - _pos > BUFFER_LIMIT) {   // nobody is reading: keep the newest part
                        NSUInteger drop = _buf.length - BUFFER_LIMIT / 2;
                        [_buf replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
                        _pos = _pos > drop ? _pos - drop : 0;
                    }
                }
            } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) break;
        } else if (r == 0 && _done) break;       // child gone, nothing left to read
        else if (r < 0 && errno != EINTR) break;
    }
    close(_master);
    _master = -1;
    if (!_done) { for (int i = 0; i < 10 && !_done; i++) { [self reap:NO]; usleep(100000); } }
}

- (NSString *)waitFor:(double)timeout idle:(double)idle
{
    double end = Now() + timeout;
    _lastUsed = Now();
    for (;;) {
        [self reap:NO];
        BOOL fresh, d;
        double since;
        @synchronized(self) { fresh = _buf.length > _pos; since = Now() - _lastOut; d = _done; }
        if (d && since > 0.15) break;
        if (fresh && since > idle) break;
        if (Now() >= end) break;
        usleep(50000);
    }
    NSString *text;
    @synchronized(self) {
        NSData *d = [_buf subdataWithRange:NSMakeRange(_pos, _buf.length - _pos)];
        NSUInteger len = d.length, used = len;
        text = nil;
        for (NSUInteger cut = 0; cut <= 3 && cut <= len; cut++) {   // do not split a UTF-8 character across reads
            text = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, len - cut)] encoding:NSUTF8StringEncoding];
            if (text) { used = len - cut; break; }
        }
        if (!text) text = Decode(d);
        _pos += used;
        if (_pos > (1 << 20)) { [_buf replaceBytesInRange:NSMakeRange(0, _pos) withBytes:NULL length:0]; _pos = 0; }
    }
    NSString *state = !_done ? @"running"
        : WIFEXITED(_status) ? [NSString stringWithFormat:@"finished (exit %d)", WEXITSTATUS(_status)]
        : [NSString stringWithFormat:@"finished (signal %d)", WTERMSIG(_status)];
    return Clip([NSString stringWithFormat:@"pid %d %@\n%@", _pid, state, text]);
}

- (void)terminate
{
    _closing = YES;
    killpg(_pid, SIGKILL);
    kill(_pid, SIGKILL);
    [self reap:YES];
}

@end

static void SessReap(void)   // forget sessions that finished and were read (or finished long ago)
{
    @synchronized(sessions) {
        for (NSNumber *k in [sessions allKeys]) {
            Sess *s = sessions[k];
            [s reap:NO];
            if (s.done && (s.pos >= s.buf.length || Now() - s.doneAt > 120)) { s.closing = YES; [sessions removeObjectForKey:k]; }
        }
    }
}

static void SessKillOwner(int conn)   // a client went away: its shells go with it
{
    NSArray *mine;
    @synchronized(sessions) {
        NSMutableArray *m = [NSMutableArray array];
        for (Sess *s in sessions.allValues) if (s.owner == conn) [m addObject:s];
        mine = m;
        for (Sess *s in m) [sessions removeObjectForKey:@(s.pid)];
    }
    for (Sess *s in mine) [s terminate];
}

static Sess *SessGet(NSDictionary *a)
{
    NSNumber *k = @((pid_t)Num(a, @"pid", NAN));
    Sess *s;
    @synchronized(sessions) { s = sessions[k]; }
    if (!s) FAIL(@"no session with pid %@ (finished sessions are forgotten once read; list_sessions shows the live ones)", k);
    return s;
}

static id tStartProcess(NSDictionary *a)
{
    NSString *cmd = Str(a, @"command", nil), *shell = Str(a, @"shell", @"/bin/zsh"), *note = @"";
    SessReap();
    @synchronized(sessions) {
        for (;;) {
            Sess *oldest = nil;
            int live = 0;
            for (Sess *s in sessions.allValues) if (!s.done) { live++; if (!oldest || s.lastUsed < oldest.lastUsed) oldest = s; }
            if (live < MAX_SESSIONS) break;
            [sessions removeObjectForKey:@(oldest.pid)];
            [oldest terminate];
            note = [note stringByAppendingFormat:@"[closed idle session pid %d (%@) to stay under %d sessions]\n", oldest.pid, [oldest.cmd substringToIndex:MIN((NSUInteger)40, oldest.cmd.length)], MAX_SESSIONS];
        }
    }
    const char *sh = shell.fileSystemRepresentation, *c = cmd.UTF8String;
    struct winsize ws = {40, 120, 0, 0};
    int m;
    pid_t pid = forkpty(&m, NULL, NULL, &ws);
    if (pid < 0) FAIL(@"could not open a terminal: %s", strerror(errno));
    if (pid == 0) { execl(sh, sh, "-c", c, (char *)NULL); _exit(127); }
    struct termios t;
    if (tcgetattr(m, &t) == 0) { t.c_lflag &= ~ECHO; tcsetattr(m, TCSANOW, &t); }
    Sess *s = [Sess new];
    s.pid = pid; s.master = m; s.cmd = cmd; s.buf = [NSMutableData data]; s.owner = curConn; s.lastOut = s.lastUsed = Now();
    @synchronized(sessions) { sessions[@(pid)] = s; }
    [NSThread detachNewThreadWithBlock:^{ [s pump]; }];
    return [note stringByAppendingString:[s waitFor:Num(a, @"timeout_ms", 10000) / 1000 idle:0.4]];
}

static id tInteract(NSDictionary *a)
{
    Sess *s = SessGet(a);
    NSString *in = Str(a, @"input", nil);
    if (s.done || s.master < 0) FAIL(@"process has finished");
    if (![in hasSuffix:@"\n"]) in = [in stringByAppendingString:@"\n"];
    NSData *d = [in dataUsingEncoding:NSUTF8StringEncoding];
    if (write(s.master, d.bytes, d.length) < 0) FAIL(@"could not write to the session: %s", strerror(errno));
    return [s waitFor:Num(a, @"timeout_ms", 8000) / 1000 idle:0.4];
}

static id tReadOutput(NSDictionary *a) { return [SessGet(a) waitFor:Num(a, @"timeout_ms", 5000) / 1000 idle:0.4]; }

static id tForceTerminate(NSDictionary *a)
{
    Sess *s = SessGet(a);
    @synchronized(sessions) { [sessions removeObjectForKey:@(s.pid)]; }
    [s terminate];
    return [NSString stringWithFormat:@"terminated %d", s.pid];
}

static id tListSessions(NSDictionary *a)
{
    SessReap();
    NSMutableArray *out = [NSMutableArray array];
    @synchronized(sessions) { for (Sess *s in sessions.allValues) [out addObject:[NSString stringWithFormat:@"%d %@ %@", s.pid, s.done ? @"finished" : @"running", [s.cmd substringToIndex:MIN((NSUInteger)80, s.cmd.length)]]]; }
    return out.count ? [out componentsJoinedByString:@"\n"] : @"no sessions";
}

static id tListProcesses(NSDictionary *a)
{
    NSString *out = nil;
    Run(@[@"/bin/ps", @"-axo", @"pid,pcpu,pmem,comm"], 20, &out);
    return Clip(out);
}

static id tKillProcess(NSDictionary *a)
{
    pid_t p = (pid_t)Num(a, @"pid", NAN);
    if (p <= 1 || kill(p, SIGTERM) != 0) FAIL(@"could not signal %d: %s", p, strerror(errno));
    return [NSString stringWithFormat:@"sent SIGTERM to %d", p];
}

// ---------------------------------------------------------------- screen

static void NeedAccess(void)
{
    if (!AXIsProcessTrusted())
        FAIL(@"this program has no Accessibility permission, so mouse and keyboard events are ignored. Add %@ in System Settings > Privacy & Security > Accessibility (run it with --request to show the prompt).", exePath);
}

static void Post(CGEventRef e) { CGEventPost(kCGHIDEventTap, e); CFRelease(e); usleep(12000); }

static CGPoint PointFrom(NSDictionary *a, NSString *kx, NSString *ky)
{
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    double x = Num(a, kx, NAN) * screenScale, y = Num(a, ky, NAN) * screenScale;
    if (x < 0 || y < 0 || x >= b.size.width || y >= b.size.height)
        FAIL(@"(%@, %@) is outside the screen (%d x %d points). Coordinates are pixels of the last screenshot.", a[kx], a[ky], (int)b.size.width, (int)b.size.height);
    return CGPointMake(x, y);
}

static void Mouse(CGEventType type, CGPoint p, CGMouseButton button, int clicks)
{
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, button);
    if (clicks) CGEventSetIntegerValueField(e, kCGMouseEventClickState, clicks);
    Post(e);
}

static id tScreenInfo(NSDictionary *a)
{
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    CGEventRef e = CGEventCreate(NULL);
    CGPoint at = CGEventGetLocation(e);
    CFRelease(e);
    return [NSString stringWithFormat:@"screen: %d x %d points (main display), %d pixels wide\nmouse: %d, %d points\naccessibility: %s\nscreen recording: %s\ncoordinates for screen_* tools are pixels of the last take_screenshot picture (%.3f points per pixel)\nprogram: %@",
        (int)b.size.width, (int)b.size.height, (int)CGDisplayPixelsWide(CGMainDisplayID()), (int)at.x, (int)at.y,
        AXIsProcessTrusted() ? "granted" : "NOT granted", CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted", screenScale, exePath];
}

static id tScreenMove(NSDictionary *a)
{
    NeedAccess();
    CGPoint p = PointFrom(a, @"x", @"y");
    Mouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0);
    return [NSString stringWithFormat:@"mouse at %d, %d", (int)p.x, (int)p.y];
}

static id tScreenClick(NSDictionary *a)
{
    NeedAccess();
    CGPoint p = PointFrom(a, @"x", @"y");
    BOOL right = [Str(a, @"button", @"left") isEqualToString:@"right"];
    int n = (int)Num(a, @"clicks", 1);
    if (n < 1 || n > 3) FAIL(@"clicks must be 1, 2 or 3");
    Mouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0);
    usleep(150000);   // let the window server see the pointer over the target before pressing
    for (int i = 1; i <= n; i++) {
        Mouse(right ? kCGEventRightMouseDown : kCGEventLeftMouseDown, p, right ? kCGMouseButtonRight : kCGMouseButtonLeft, i);
        usleep(50000);
        Mouse(right ? kCGEventRightMouseUp : kCGEventLeftMouseUp, p, right ? kCGMouseButtonRight : kCGMouseButtonLeft, i);
        usleep(50000);
    }
    return [NSString stringWithFormat:@"clicked %@ x%d at %d, %d", right ? @"right" : @"left", n, (int)p.x, (int)p.y];
}

static id tScreenDrag(NSDictionary *a)
{
    NeedAccess();
    CGPoint f = PointFrom(a, @"x", @"y"), t = PointFrom(a, @"to_x", @"to_y");
    Mouse(kCGEventMouseMoved, f, kCGMouseButtonLeft, 0);
    usleep(150000);
    Mouse(kCGEventLeftMouseDown, f, kCGMouseButtonLeft, 1);
    usleep(80000);
    for (int i = 1; i <= 15; i++) {
        Mouse(kCGEventLeftMouseDragged, CGPointMake(f.x + (t.x - f.x) * i / 15, f.y + (t.y - f.y) * i / 15), kCGMouseButtonLeft, 0);
        usleep(25000);
    }
    usleep(150000);   // hover over the drop target before releasing
    Mouse(kCGEventLeftMouseUp, t, kCGMouseButtonLeft, 1);
    return [NSString stringWithFormat:@"dragged from %d, %d to %d, %d", (int)f.x, (int)f.y, (int)t.x, (int)t.y];
}

static id tScreenScroll(NSDictionary *a)
{
    NeedAccess();
    int n = (int)Num(a, @"amount", NAN);
    if (n == 0 || abs(n) > 50) FAIL(@"amount must be -50..50 and not 0 (positive scrolls up)");
    if (a[@"x"] && a[@"y"]) Mouse(kCGEventMouseMoved, PointFrom(a, @"x", @"y"), kCGMouseButtonLeft, 0);
    Post(CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitLine, 1, n, 0, 0));
    return [NSString stringWithFormat:@"scrolled %d", n];
}

static NSDictionary *KeyCodes(void)
{
    static NSDictionary *k;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        const char *letters = "a\x00" "s\x01" "d\x02" "f\x03" "h\x04" "g\x05" "z\x06" "x\x07" "c\x08" "v\x09" "b\x0b" "q\x0c" "w\x0d" "e\x0e" "r\x0f" "y\x10" "t\x11"
            "1\x12" "2\x13" "3\x14" "4\x15" "6\x16" "5\x17" "=\x18" "9\x19" "7\x1a" "-\x1b" "8\x1c" "0\x1d" "]\x1e" "o\x1f" "u\x20" "[\x21" "i\x22" "p\x23"
            "l\x25" "j\x26" "'\x27" "k\x28" ";\x29" "\\\x2a" ",\x2b" "/\x2c" "n\x2d" "m\x2e" ".\x2f" "`\x32";
        for (const char *p = letters; *p; p += 2) d[[NSString stringWithFormat:@"%c", *p]] = @((unsigned char)p[1]);
        [d addEntriesFromDictionary:@{@"return": @36, @"enter": @36, @"tab": @48, @"space": @49, @"delete": @51, @"backspace": @51, @"escape": @53, @"esc": @53,
            @"left": @123, @"right": @124, @"down": @125, @"up": @126, @"home": @115, @"end": @119, @"pageup": @116, @"pagedown": @121, @"forwarddelete": @117,
            @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97, @"f7": @98, @"f8": @100, @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111}];
        k = d;
    });
    return k;
}

static CGEventFlags ModFlag(NSString *m)
{
    m = m.lowercaseString;
    if ([m isEqualToString:@"cmd"] || [m isEqualToString:@"command"]) return kCGEventFlagMaskCommand;
    if ([m isEqualToString:@"shift"]) return kCGEventFlagMaskShift;
    if ([m isEqualToString:@"option"] || [m isEqualToString:@"alt"]) return kCGEventFlagMaskAlternate;
    if ([m isEqualToString:@"control"] || [m isEqualToString:@"ctrl"]) return kCGEventFlagMaskControl;
    FAIL(@"unknown modifier %@ (cmd, shift, option, control)", m);
}

static void Tap(CGKeyCode code, BOOL down, NSString *uni, CGEventFlags flags)
{
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
    if (uni) { UniChar u[8]; NSUInteger n = MIN((NSUInteger)8, uni.length); [uni getCharacters:u range:NSMakeRange(0, n)]; CGEventKeyboardSetUnicodeString(e, n, u); }
    CGEventSetFlags(e, flags | 0x100);   // always set explicitly (NonCoalesced): events left at the default flags were dropped by apps
    Post(e);
}

static id tScreenKey(NSDictionary *a)
{
    NeedAccess();
    NSString *key = [Str(a, @"key", nil).lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSNumber *code = KeyCodes()[key];
    if (!code) FAIL(@"unknown key %@. Use a letter, digit or punctuation key, return, tab, space, delete, escape, left, right, up, down, home, end, pageup, pagedown, forwarddelete, f1-f12.", key);
    NSArray *mods = Arg(a, @"modifiers", [NSArray class]) ?: @[];
    CGEventFlags fl = 0;
    for (NSString *m in mods) fl |= ModFlag(m);
    Tap(code.unsignedShortValue, YES, nil, fl);
    Tap(code.unsignedShortValue, NO, nil, fl);
    return [NSString stringWithFormat:@"pressed %@%@", mods.count ? [[mods componentsJoinedByString:@"+"] stringByAppendingString:@"+"] : @"", key];
}

static id tScreenType(NSDictionary *a)
{
    NeedAccess();
    NSString *text = Str(a, @"text", nil);
    if (text.length > 2000) FAIL(@"at most 2000 characters at a time");
    NSString *shifted = @"!@#$%^&*()_+{}|:\"<>?~", *base = @"1234567890-=[]\\;',./`";
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        NSNumber *code = nil;
        CGEventFlags fl = 0;
        if ([ch isEqualToString:@"\n"] || [ch isEqualToString:@"\r"]) code = @36;
        else if ([ch isEqualToString:@"\t"]) code = @48;
        else if ([ch isEqualToString:@" "]) code = @49;
        else if (ch.length == 1 && [ch characterAtIndex:0] < 127) {
            NSRange s = [shifted rangeOfString:ch];
            if (s.location != NSNotFound) { code = KeyCodes()[[base substringWithRange:s]]; fl = kCGEventFlagMaskShift; }
            else {
                code = KeyCodes()[ch.lowercaseString];
                if (![ch isEqualToString:ch.lowercaseString]) fl = kCGEventFlagMaskShift;
            }
        }
        CGKeyCode k = code ? code.unsignedShortValue : 0;
        NSString *uni = code ? nil : ch;   // not on a US keyboard: send it as a Unicode string
        Tap(k, YES, uni, fl);
        Tap(k, NO, uni, fl);
        count++;
    }];
    return [NSString stringWithFormat:@"typed %lu characters", (unsigned long)count];
}

static id tScreenshot(NSDictionary *a)
{
    int width = MAX(320, MIN(2048, (int)Num(a, @"max_width", 1024)));
    char tmpl[] = "/tmp/mcc.XXXXXX";
    if (!mkdtemp(tmpl)) FAIL(@"cannot make a temporary folder");
    NSString *dir = @(tmpl), *png = [dir stringByAppendingPathComponent:@"s.png"], *jpg = [dir stringByAppendingPathComponent:@"s.jpg"], *out = nil;
    @try {
        Run(@[@"/usr/sbin/screencapture", @"-x", @"-C", png], 20, &out);
        if (![[NSFileManager defaultManager] fileExistsAtPath:png])
            FAIL(@"could not capture the screen (%@). Someone must be logged in with the display awake, and Screen Recording must be allowed for %@.", [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], exePath);
        Run(@[@"/usr/bin/sips", @"-Z", @(width).stringValue, @"-s", @"format", @"jpeg", @"-s", @"formatOptions", @"60", png, @"--out", jpg], 30, &out);
        Run(@[@"/usr/bin/sips", @"-g", @"pixelWidth", jpg], 10, &out);
        NSRange r = [out rangeOfString:@"pixelWidth: "];
        double px = r.location == NSNotFound ? 0 : [[out substringFromIndex:NSMaxRange(r)] doubleValue];
        if (px < 1) FAIL(@"could not shrink the screenshot");
        screenScale = CGDisplayBounds(CGMainDisplayID()).size.width / px;
        return Image(jpg, [NSString stringWithFormat:@"Screenshot of the main display (%d pixels wide, JPEG). Click coordinates are pixels of this picture.", (int)px]);
    } @finally {
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
}

static id tViewImage(NSDictionary *a) { NSString *p = Path(Str(a, @"path", nil)); return Image(p, [@"image " stringByAppendingString:p]); }

// ---------------------------------------------------------------- MCP

typedef id (*ToolFn)(NSDictionary *);
static const struct { const char *name, *desc, *props, *required; ToolFn fn; } tools[] = {
    {"read_file", "Read a text file (offset/length in lines; negative offset reads from the end) or view an image.", "path:string offset:number length:number", "path", tReadFile},
    {"read_multiple_files", "Read several files.", "paths:array", "paths", tReadMultiple},
    {"write_file", "Write a file. mode is rewrite (default) or append.", "path:string content:string mode:string", "path content", tWriteFile},
    {"edit_block", "Replace old_string with new_string in a file (expected_replacements defaults to 1).", "file_path:string old_string:string new_string:string expected_replacements:number", "file_path old_string new_string", tEditBlock},
    {"list_directory", "List a directory.", "path:string", "path", tListDirectory},
    {"create_directory", "Create a directory and its parents.", "path:string", "path", tCreateDirectory},
    {"move_file", "Move or rename a file or folder.", "source:string destination:string", "source destination", tMoveFile},
    {"get_file_info", "Size, times, type of a path.", "path:string", "path", tFileInfo},
    {"start_search", "Search by file name (searchType files) or file contents (content). Returns the results directly. filePattern is a glob such as *.py.", "path:string pattern:string searchType:string filePattern:string maxResults:number", "path pattern", tSearch},
    {"start_process", "Run a shell command in a terminal session; returns when output goes idle or timeout_ms passes, leaving it running. REPLs work. At most 12 sessions stay open (the least recently used is closed); finished sessions are forgotten once read, and a client's sessions end when it disconnects.", "command:string timeout_ms:number shell:string", "command", tStartProcess},
    {"interact_with_process", "Send a line of input to a running session.", "pid:number input:string timeout_ms:number", "pid input", tInteract},
    {"read_process_output", "Read new output from a session.", "pid:number timeout_ms:number", "pid", tReadOutput},
    {"force_terminate", "Kill a session started with start_process.", "pid:number", "pid", tForceTerminate},
    {"list_sessions", "List the live shell sessions.", "", "", tListSessions},
    {"list_processes", "List running processes.", "", "", tListProcesses},
    {"kill_process", "SIGTERM a process by pid.", "pid:number", "pid", tKillProcess},
    {"take_screenshot", "Screenshot of the main display. Take one before using screen_* coordinates. max_width is the picture width in pixels (320-2048, default 1024).", "max_width:number", "", tScreenshot},
    {"view_image", "View an image file.", "path:string", "path", tViewImage},
    {"screen_info", "Screen size, mouse position, permission state and coordinate scale.", "", "", tScreenInfo},
    {"screen_click", "Click at x,y (pixels of the last screenshot). button left or right, clicks 1-3.", "x:number y:number button:string clicks:number", "x y", tScreenClick},
    {"screen_move", "Move the pointer to x,y.", "x:number y:number", "x y", tScreenMove},
    {"screen_drag", "Press at x,y, drag to to_x,to_y and release: moves windows, files, selections.", "x:number y:number to_x:number to_y:number", "x y to_x to_y", tScreenDrag},
    {"screen_scroll", "Scroll the wheel (positive up), optionally after moving to x,y.", "amount:number x:number y:number", "amount", tScreenScroll},
    {"screen_type", "Type text into whatever has keyboard focus.", "text:string", "text", tScreenType},
    {"screen_key", "Press one key with optional modifiers (cmd, shift, option, control), e.g. key w, modifiers [cmd].", "key:string modifiers:array", "key", tScreenKey},
};
#define NTOOLS (sizeof tools / sizeof tools[0])

static NSArray *ToolList(void)
{
    NSMutableArray *list = [NSMutableArray array];
    for (size_t i = 0; i < NTOOLS; i++) {
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        for (NSString *pair in [@(tools[i].props) componentsSeparatedByString:@" "]) {
            NSArray *kv = [pair componentsSeparatedByString:@":"];
            if (kv.count == 2) props[kv[0]] = [kv[1] isEqualToString:@"array"] ? @{@"type": @"array", @"items": @{@"type": @"string"}} : @{@"type": kv[1]};
        }
        NSString *req = @(tools[i].required);
        [list addObject:@{@"name": @(tools[i].name), @"description": @(tools[i].desc),
            @"inputSchema": @{@"type": @"object", @"properties": props, @"required": req.length ? [req componentsSeparatedByString:@" "] : @[]}}];
    }
    return list;
}

static NSArray *CallTool(NSString *name, NSDictionary *args)
{
    for (size_t i = 0; i < NTOOLS; i++) {
        if (strcmp(tools[i].name, name.UTF8String)) continue;
        id r = tools[i].fn(args ?: @{});
        if ([r isKindOfClass:[NSDictionary class]]) return @[@{@"type": @"text", @"text": r[@"text"]}, @{@"type": @"image", @"data": r[@"image"], @"mimeType": r[@"mime"]}];
        return @[@{@"type": @"text", @"text": Clip(r)}];
    }
    FAIL(@"unknown tool %@", name);
}

static NSDictionary *HandleMessage(NSDictionary *m)
{
    NSString *method = m[@"method"];
    id mid = m[@"id"];
    if (!mid || ![method isKindOfClass:[NSString class]]) return nil;   // notifications get no reply
    NSDictionary *params = [m[@"params"] isKindOfClass:[NSDictionary class]] ? m[@"params"] : @{};
    id result;
    if ([method isEqualToString:@"initialize"])
        result = @{@"protocolVersion": params[@"protocolVersion"] ?: @"2024-11-05", @"capabilities": @{@"tools": @{}}, @"serverInfo": @{@"name": @"macos-commander-controller", @"version": @VERSION}};
    else if ([method isEqualToString:@"tools/list"]) result = @{@"tools": ToolList()};
    else if ([method isEqualToString:@"tools/call"]) {
        @try { result = @{@"content": CallTool(params[@"name"], params[@"arguments"])}; }
        @catch (NSException *e) { result = @{@"content": @[@{@"type": @"text", @"text": [@"Error: " stringByAppendingString:e.reason ?: e.name]}], @"isError": @YES}; }
    } else if ([method isEqualToString:@"ping"]) result = @{};
    else return @{@"jsonrpc": @"2.0", @"id": mid, @"error": @{@"code": @-32601, @"message": @"method not found"}};
    return @{@"jsonrpc": @"2.0", @"id": mid, @"result": result};
}

static void Serve(int infd, int outfd, int conn)
{
    curConn = conn;
    FILE *in = fdopen(infd, "r"), *out = fdopen(outfd, "w");
    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, in) > 0) {
        @autoreleasepool {
            NSData *d = [NSData dataWithBytes:line length:strlen(line)];
            id msg = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            NSDictionary *reply = [msg isKindOfClass:[NSDictionary class]] ? HandleMessage(msg) : nil;
            if (!reply) continue;
            NSData *j = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
            fwrite(j.bytes, 1, j.length, out);
            fputc('\n', out);
            fflush(out);
        }
    }
    free(line);
    fclose(in);
    fclose(out);
    SessKillOwner(conn);
}

static void Check(BOOL request)
{
    if (request) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
        CGRequestScreenCaptureAccess();
    }
    printf("program: %s\naccessibility: %s\nscreen recording: %s\n", exePath.UTF8String, AXIsProcessTrusted() ? "granted" : "NOT granted", CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        char buf[4096];
        uint32_t size = sizeof buf;
        exePath = _NSGetExecutablePath(buf, &size) == 0 ? [@(buf) stringByStandardizingPath] : @(argv[0]);
        sessions = [NSMutableDictionary dictionary];
        NSString *roots = @(getenv("MC_ALLOWED") ?: "");
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *p in [roots componentsSeparatedByString:@":"]) if (p.length) [r addObject:[[p stringByExpandingTildeInPath] stringByResolvingSymlinksInPath]];
        allowedRoots = r;
        signal(SIGPIPE, SIG_IGN);
        chdir(NSHomeDirectory().fileSystemRepresentation);
        setenv("TERM", "xterm-256color", 0);
        setenv("PATH", [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:@(getenv("PATH") ?: "/usr/bin:/bin:/usr/sbin:/sbin")].UTF8String, 1);   // launchd's PATH is minimal
        if (argc > 1 && !strcmp(argv[1], "--version")) { printf("macos-commander-controller %s\n", VERSION); return 0; }
        if (argc > 1 && (!strcmp(argv[1], "--check") || !strcmp(argv[1], "--request"))) { Check(!strcmp(argv[1], "--request")); return 0; }
        if (argc > 2 && !strcmp(argv[1], "--socket")) {
            NSString *path = [@(argv[2]) stringByExpandingTildeInPath];
            struct sockaddr_un sa = {.sun_family = AF_UNIX};
            if (path.length >= sizeof sa.sun_path) { fprintf(stderr, "socket path too long\n"); return 1; }
            strcpy(sa.sun_path, path.fileSystemRepresentation);
            unlink(sa.sun_path);
            int srv = socket(AF_UNIX, SOCK_STREAM, 0);
            umask(077);
            if (srv < 0 || bind(srv, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(srv, 8) != 0) { perror("socket"); return 1; }
            chmod(sa.sun_path, 0600);
            for (int conn = 1;; conn++) {
                int c = accept(srv, NULL, NULL);
                if (c < 0) { if (errno == EINTR) continue; usleep(100000); continue; }
                int id = conn, d = dup(c);
                [NSThread detachNewThreadWithBlock:^{ Serve(c, d, id); }];
            }
        }
        Serve(0, 1, 0);
    }
    return 0;
}
