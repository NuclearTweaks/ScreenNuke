// ScreenNuke — shrink the whole UI so more content fits on screen.
//
// The trick is exactly what Apple's "Display Zoom → More Space" does, made
// continuous: every layout decision on iOS is points, and points become
// pixels via UIScreen.scale. If we honestly tell UIKit the display packs
// FEWER pixels per point (scale × density), then the same physical pixels
// buy MORE points — bounds grow, every app re-lays out, and text, icons,
// buttons and rows all come out proportionally smaller. One coherent lie,
// told at the source (UIScreen), instead of patching fonts piecemeal:
//
//   effectiveScale = realScale × f         (f = density, 0.55…1.00)
//   effectiveBounds = realBounds ÷ f       (pixels map exactly: bounds×scale
//                                          is unchanged, so nothing blurs —
//                                          it's the "1080p into a 720p
//                                          monitor" case: the GPU lays out
//                                          big, the panel shows it small.)
//
// The snapshot of the REAL scale/bounds is taken lazily on the first hooked
// read (window-server connection is guaranteed up by then, and it happens
// before any window exists), then every read answers from the snapshot —
// zero recursion, zero drift.
//
// Density lives in com.nucleartweaks.screen-nuke (key "density"); the
// Settings pane posts a Darwin notification and every process updates its
// factor in place. Already-visible layouts refresh when apps re-layout
// (rotation, new scenes); a respring applies it to everything at once.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>

typedef void (*SN_MSHook)(Class, SEL, IMP, IMP *);

static NSString *const kDomain   = @"com.nucleartweaks.screen-nuke";
static NSString *const kDensityKey = @"density";
static NSString *const kTinyKey  = @"tinyText";
static NSString *const kChanged  = @"com.nucleartweaks.screen-nuke/changed";

static CGFloat gDensity = 0.85;          // 0.55 = tiny, 1.0 = stock
static BOOL    gTinyText = NO;           // bonus: force XS content size
static os_log_t gLog;
static int gBudget = 8;

// real values, snapshotted on first hook invocation
static BOOL     gSnapDone = NO;
static UIScreen *gMain = nil;
static CGFloat  gRealScale = 3.0, gRealNative = 3.0;
static CGRect   gRealBounds = { {0, 0}, {0, 0} };   // CGRectZero is not a C constant initializer

// original IMPs (set when the hooks install, before any read can happen)
typedef CGFloat (*SN_CGFloat_Get)(id, SEL);
typedef CGRect  (*SN_CGRect_Get)(id, SEL);
typedef id      (*SN_Objc_Get)(id, SEL);
static SN_CGFloat_Get orig_scale, orig_nativeScale;
static SN_CGRect_Get  orig_bounds, orig_appAvailBounds;
static SN_Objc_Get    orig_category;

static inline CGRect SNNewBounds(void) {
    if (!gSnapDone || gDensity == 1.0) return gRealBounds;
    return CGRectMake(0, 0, gRealBounds.size.width / gDensity,
                            gRealBounds.size.height / gDensity);
}

static void SNProof(const char *why) {
    if (gBudget <= 0) return;
    gBudget--;
    CGRect nb = SNNewBounds();
    os_log(gLog, "%{public}s: density %{public}.2f — bounds %{public}.0fx%{public}.0f -> %{public}.0fx%{public}.0f, scale %{public}.2f -> %{public}.2f",
           why, gDensity, gRealBounds.size.width, gRealBounds.size.height,
           nb.size.width, nb.size.height, gRealScale, gRealScale * gDensity);
    NSLog(@"[ScreenNuke] %s: density %.2f bounds %.0fx%.0f -> %.0fx%.0f scale %.2f -> %.2f (tiny text %d)",
          why, gDensity, gRealBounds.size.width, gRealBounds.size.height,
          nb.size.width, nb.size.height, gRealScale, gRealScale * gDensity, gTinyText);
    FILE *pf = fopen("/Users/spencer/screennuke-proof.txt", "a");   // JB-sim host FS; absent on device
    if (pf) {
        fprintf(pf, "%s [%s pid %d]: density %.2f bounds %.0fx%.0f -> %.0fx%.0f scale %.2f -> %.2f tiny=%d\n",
                why, [[NSProcessInfo processInfo].processName UTF8String],
                [[NSProcessInfo processInfo] processIdentifier],
                gDensity, gRealBounds.size.width, gRealBounds.size.height,
                nb.size.width, nb.size.height, gRealScale, gRealScale * gDensity, gTinyText);
        fclose(pf);
    }
}

// ─── preferences ────────────────────────────────────────────────────────────

static void SNReload(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyValue((__bridge CFStringRef)kDensityKey,
                        dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    double v = 0.85;                                // default: noticeably smaller
    if (n) { CFNumberGetValue(n, kCFNumberDoubleType, &v); CFRelease(n); }
    if (v < 0.55) v = 0.55;
    if (v > 1.0)  v = 1.0;
    BOOL tiny = NO;
    CFBooleanRef b = (CFBooleanRef)CFPreferencesCopyValue((__bridge CFStringRef)kTinyKey,
                        dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (b) { tiny = CFBooleanGetValue(b); CFRelease(b); }
    if (v != gDensity || tiny != gTinyText) {
        gDensity = v; gTinyText = tiny;
        gBudget = MAX(gBudget, 3);
        if (gSnapDone) SNProof("prefs-reload");
    }
}

static void SNPrefsChanged(CFNotificationCenterRef c, void *obs,
                           CFNotificationName n, const void *p, CFDictionaryRef u) {
    SNReload();
}

// ─── lazy real-value snapshot ───────────────────────────────────────────────
// Whoever reads the main screen first captures the truth (via the orig IMPs,
// so it is unhooked cost-free math), then everyone answers from the snapshot.

static void SNSnapshotIfNeeded(id self, SEL _cmd) {
    if (gSnapDone) return;
    if (!gMain || self != gMain) return;   // gMain only via the +mainScreen capture — non-main reads must not snapshot
    if (!orig_scale || !orig_nativeScale || !orig_bounds) return;
    gRealScale  = orig_scale(self, @selector(scale));
    gRealNative = orig_nativeScale(self, @selector(nativeScale));
    gRealBounds = orig_bounds(self, @selector(bounds));
    if (gRealBounds.size.width <= 0) return;    // window server not ready — try again later
    gSnapDone = YES;
    SNProof("init");
}

// ─── +mainScreen capture ────────────────────────────────────────────────────
// Calling [UIScreen mainScreen] ourselves from the ctor ABORTS SpringBoard
// (UIKit asserts during the launch transition — measured). Instead we hook
// +mainScreen and capture the instance every time UIKit itself calls it:
// zero new call paths, capture happens exactly when UIKit deems it legal.

typedef id (*SN_MainScreen)(Class, SEL);
static SN_MainScreen orig_mainScreen;

static void SNHookInstance(Class c, SEL sel, IMP rep, IMP *orig);
static CGFloat rep_scale(id self, SEL s);
static CGFloat rep_nativeScale(id self, SEL s);
static CGRect  rep_bounds(id self, SEL s);
static CGRect  rep_appAvailBounds(id self, SEL s);

static id rep_mainScreen(Class c, SEL s) {
    id m = orig_mainScreen(c, s);
    if (!gMain && m) {
        gMain = m;
        // Install instance hooks on the REAL class of the main-screen object
        // (class-cluster proof: whatever +[UIScreen mainScreen] vends is what
        // every process actually reads — the abstract superclass could miss).
        Class real = object_getClass(m);
        SNHookInstance(real, @selector(scale),        (IMP)rep_scale,        (IMP *)&orig_scale);
        SNHookInstance(real, @selector(nativeScale),  (IMP)rep_nativeScale,  (IMP *)&orig_nativeScale);
        SNHookInstance(real, @selector(bounds),       (IMP)rep_bounds,       (IMP *)&orig_bounds);
        if (class_getInstanceMethod(real, NSSelectorFromString(@"applicationAvailableBounds")))
            SNHookInstance(real, NSSelectorFromString(@"applicationAvailableBounds"),
                           (IMP)rep_appAvailBounds, (IMP *)&orig_appAvailBounds);
        NSLog(@"[ScreenNuke] main screen captured (%@), instance hooks installed", NSStringFromClass(real));
    }
    return m;
}

// ─── UIScreen replacements ──────────────────────────────────────────────────

static CGFloat rep_scale(id self, SEL s) {
    CGFloat v = orig_scale(self, s);
    SNSnapshotIfNeeded(self, s);
    if (self == gMain && gSnapDone && gDensity != 1.0) return gRealScale * gDensity;
    return v;
}
static CGFloat rep_nativeScale(id self, SEL s) {
    CGFloat v = orig_nativeScale(self, s);
    SNSnapshotIfNeeded(self, s);
    if (self == gMain && gSnapDone && gDensity != 1.0) return gRealNative * gDensity;
    return v;
}
static CGRect rep_bounds(id self, SEL s) {
    CGRect v = orig_bounds(self, s);
    SNSnapshotIfNeeded(self, s);
    if (self == gMain && gSnapDone && gDensity != 1.0) return SNNewBounds();
    return v;
}
static CGRect rep_appAvailBounds(id self, SEL s) {
    CGRect v = orig_appAvailBounds(self, s);
    SNSnapshotIfNeeded(self, s);
    if (self == gMain && gSnapDone && gDensity != 1.0 && !CGRectIsNull(v) && !CGRectIsEmpty(v)) {
        // same proportional growth, origin scaled so insets shrink too
        CGFloat k = 1.0 / gDensity;
        return CGRectMake(v.origin.x * k, v.origin.y * k, v.size.width * k, v.size.height * k);
    }
    return v;
}

// ─── bonus: system-wide extra-small text ────────────────────────────────────

static id rep_preferredContentSizeCategory(id self, SEL s) {
    if (gTinyText) return @"UICTContentSizeCategoryXS";
    return orig_category(self, s);
}

// ─── scene/window frame ─────────────────────────────────────────────────────
// Apps size their UIWindow from the FBSSceneSettings frame handed over by
// SpringBoard — NOT from UIScreen.bounds — so without this layer apps keep
// laying out on the stock grid inside stock windows (measured: 2 % pixel
// delta = the screen hooks alone only touch direct UIScreen readers). When
// the incoming frame IS the whole stock screen, we widen it to the new
// bounds; any other rect (split view, PIP) passes through untouched.
// Pixel math stays exact: newBoundsPt × liedScale == real pixel size.

static SN_CGRect_Get orig_sceneFrameFBS, orig_sceneFrameUIS;

static CGRect rep_sceneFrameImpl(id self, SEL s, SN_CGRect_Get orig) {
    CGRect v = orig(self, s);
    if (gSnapDone && gDensity != 1.0 &&
        fabs(v.size.width - gRealBounds.size.width) < 0.5 &&
        fabs(v.size.height - gRealBounds.size.height) < 0.5) {
        CGRect nb = SNNewBounds();
        return CGRectMake(v.origin.x, v.origin.y, nb.size.width, nb.size.height);
    }
    return v;
}
static CGRect rep_sceneFrameFBS(id self, SEL s) { return rep_sceneFrameImpl(self, s, orig_sceneFrameFBS); }
static CGRect rep_sceneFrameUIS(id self, SEL s) { return rep_sceneFrameImpl(self, s, orig_sceneFrameUIS); }

// iOS 27 measures the scene through its coordinate SPACE, not settings
// (measured: keyWindow stays stock while screen lies — UIWindowSceneGeometry
// .coordinateSpace is the sizing authority). Lie there: full-screen spaces
// get the grown bounds and the scaled scale; anything smaller (split view,
// PIP) passes through untouched. MSHookMessageEx adds a -scale override on
// this class when it only inherits one (orig = superclass IMP) — fine.

static SN_CGRect_Get  orig_csBounds, orig_sysFrame;
static SN_CGFloat_Get orig_csScale;

static inline BOOL SNIsFullStock(CGRect r) {
    return gSnapDone && gDensity != 1.0 &&
           fabs(r.size.width  - gRealBounds.size.width)  < 0.5 &&
           fabs(r.size.height - gRealBounds.size.height) < 0.5;
}

static CGRect rep_csBounds(id self, SEL s) {
    CGRect v = orig_csBounds(self, s);
    if (SNIsFullStock(v)) { CGRect nb = SNNewBounds(); return CGRectMake(v.origin.x, v.origin.y, nb.size.width, nb.size.height); }
    return v;
}
static CGFloat rep_csScale(id self, SEL s) {
    CGFloat v = orig_csScale(self, s);
    CGRect b = orig_csBounds(self, @selector(bounds));
    if (SNIsFullStock(b)) return v * gDensity;
    return v;
}
static CGRect rep_sysFrame(id self, SEL s) {
    CGRect v = orig_sysFrame(self, s);
    if (SNIsFullStock(v)) { CGRect nb = SNNewBounds(); return CGRectMake(v.origin.x, v.origin.y, nb.size.width, nb.size.height); }
    return v;
}

// ─── installation ───────────────────────────────────────────────────────────

static SN_MSHook gHook;

static void SNHookInstance(Class c, SEL sel, IMP rep, IMP *orig) {
    if (gHook && c && class_getInstanceMethod(c, sel)) gHook(c, sel, rep, orig);
}

static SN_MSHook SNFindSubstrate(void) {
    SN_MSHook h = (SN_MSHook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (h) return h;
    static const char *homes[] = {
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",        // rootful (JB sim)
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libellekit.dylib",                                   // ElleKit (Dopamine etc.)
        "/var/jb/usr/lib/libsubstitute.dylib",
        "/var/jb/usr/lib/TweakLoader.dylib",
        "/usr/lib/libsubstitute.dylib",
    };
    for (size_t i = 0; i < sizeof(homes)/sizeof(homes[0]) && !h; i++) {
        void *img = dlopen(homes[i], RTLD_LAZY);
        if (img) h = (SN_MSHook)dlsym(img, "MSHookMessageEx");
    }
    return h;
}

%ctor {
    @autoreleasepool {
        gLog = os_log_create("com.nucleartweaks", "ScreenNuke");
        if (!NSClassFromString(@"UIApplication")) return;   // GUI processes only

        // Display-infrastructure daemons must see the TRUTH — lying to the
        // window server side would shrink the panel itself, not the UI.
        NSString *proc = [NSProcessInfo processInfo].processName;
        static NSSet *skip = nil;
        static dispatch_once_t tok;
        dispatch_once(&tok, ^{ skip = [NSSet setWithArray:@[
            @"backboardd", @"backboardd_helper", @"displaypolicyd", @"displayd",
            // PosterBoard verifies screen bounds against its OWN reference
            // table of the device's stock metrics and traps on any deviation
            // (PBFGenericDisplayContext assert — measured on iOS 27 sim).
            // It degrades to default poster behaviour, everything else wins.
            @"PosterBoard"]]; });
        if ([skip containsObject:proc]) {
            NSLog(@"[ScreenNuke] display-infrastructure process (%@) — idle", proc);
            return;
        }

        SNReload();
        gHook = SNFindSubstrate();
        if (!gHook) { os_log(gLog, "no substrate symbol found — idle (no hooks)"); NSLog(@"[ScreenNuke] no substrate symbol — idle"); return; }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, SNPrefsChanged,
                                        (__bridge CFStringRef)kChanged, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        // Hook +mainScreen on the metaclass; the instance hooks install
        // themselves against the REAL screen class the first time UIKit
        // legitimately calls it (see rep_mainScreen). Never call mainScreen
        // ourselves — UIKit asserts during SpringBoard's launch transition.
        Class uiScreen = NSClassFromString(@"UIScreen");
        SNHookInstance(object_getClass(uiScreen), @selector(mainScreen),
                       (IMP)rep_mainScreen, (IMP *)&orig_mainScreen);

        Class uiApp = NSClassFromString(@"UIApplication");
        if (uiApp && class_getInstanceMethod(uiApp, NSSelectorFromString(@"preferredContentSizeCategory")))
            SNHookInstance(uiApp, NSSelectorFromString(@"preferredContentSizeCategory"),
                           (IMP)rep_preferredContentSizeCategory, (IMP *)&orig_category);

        // Scene frame: FBS base class + the modern UISceneSettings override —
        // hook whichever exist; each keeps its own orig (subclass overrides
        // would bypass a base-class hook).
        Class fbs = NSClassFromString(@"FBSSceneSettings");
        if (fbs && class_getInstanceMethod(fbs, @selector(frame)))
            SNHookInstance(fbs, @selector(frame), (IMP)rep_sceneFrameFBS, (IMP *)&orig_sceneFrameFBS);
        Class uiss = NSClassFromString(@"UISceneSettings");
        if (uiss && class_getInstanceMethod(uiss, @selector(frame)))
            SNHookInstance(uiss, @selector(frame), (IMP)rep_sceneFrameUIS, (IMP *)&orig_sceneFrameUIS);

        // Scene coordinate space (the iOS 27 sizing authority) + geometry systemFrame.
        Class cs = NSClassFromString(@"_UIWindowSceneCoordinateSpace");
        if (cs) {
            if (class_getInstanceMethod(cs, @selector(bounds)))
                SNHookInstance(cs, @selector(bounds), (IMP)rep_csBounds, (IMP *)&orig_csBounds);
            if (orig_csBounds && class_getInstanceMethod(cs, @selector(scale)))
                SNHookInstance(cs, @selector(scale), (IMP)rep_csScale, (IMP *)&orig_csScale);
        }
        Class geom = NSClassFromString(@"UIWindowSceneGeometry");
        if (geom && class_getInstanceMethod(geom, @selector(systemFrame)))
            SNHookInstance(geom, @selector(systemFrame), (IMP)rep_sysFrame, (IMP *)&orig_sysFrame);

        NSLog(@"[ScreenNuke] installed in %@ (density %.2f, tinyText %d)", proc, gDensity, gTinyText);
    }
}
