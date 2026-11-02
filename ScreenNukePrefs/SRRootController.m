// ScreenNukePrefs — Settings pane (PreferenceLoader bundle).
//
// Same runtime-resolved private-Preferences pattern as AnimationNukePrefs:
// minimal declarations, everything bound at runtime via -undefined
// dynamic_lookup, so iOS drift can't break linking.

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
- (NSMutableDictionary *)properties;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
@end

// ─── density mapping ────────────────────────────────────────────────────────
// Slider position 0…100 maps logarithmically onto density 1.00…0.55:
// right side of the slider = smaller everything ("more nuked").  Default
// density 0.85 sits at position ~46.

static NSString *const kDomain  = @"com.nucleartweaks.screen-nuke";
static NSString *const kChanged = @"com.nucleartweaks.screen-nuke/changed";

static double SNPosToDensity(double pos) {
    if (pos < 0) pos = 0; if (pos > 100) pos = 100;
    return pow(0.55, pos / 100.0);                 // 1.0 … 0.55
}
static double SNDensityToPos(double d) {
    if (d > 1.0) d = 1.0; if (d < 0.55) d = 0.55;
    return 100.0 * log(d) / log(0.55);
}

static double SNStoredDensity(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyValue(CFSTR("density"), dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    double v = 0.85;
    if (n) { CFNumberGetValue(n, kCFNumberDoubleType, &v); CFRelease(n); }
    if (v < 0.55) v = 0.55; if (v > 1.0) v = 1.0;
    return v;
}

static BOOL SNStoredTiny(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFBooleanRef b = (CFBooleanRef)CFPreferencesCopyValue(CFSTR("tinyText"), dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL v = NO;
    if (b) { v = CFBooleanGetValue(b); CFRelease(b); }
    return v;
}

static NSString *SFFooterText(double density) {
    int pct = (int)lround(density * 100.0);
    int more = (int)lround((1.0 / (density * density) - 1.0) * 100.0);   // area gain
    if (density <= 0.60)
        return [NSString stringWithFormat:@"Size: %d%% — tiny. %d%% more content on screen; icons and text get pocket-sized.", pct, more];
    if (density <= 0.75)
        return [NSString stringWithFormat:@"Size: %d%% — much smaller. About %d%% more content fits on screen.", pct, more];
    if (density < 0.99)
        return [NSString stringWithFormat:@"Size: %d%% — everything %d%% smaller, roughly %d%% more room.", pct, 100 - pct, more];
    return @"Size: 100% — stock iOS. Drag right to shrink everything and fit more on screen.";
}

// ─── root controller ────────────────────────────────────────────────────────

@interface SRRootController : PSListController
@end

@implementation SRRootController {
    PSSpecifier *_footerSpec;
}

- (NSArray *)specifiers {
    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}

- (PSSpecifier *)liveFooter {
    if (!_footerSpec) {
        for (PSSpecifier *s in [self specifiers]) {
            if ([[s properties] objectForKey:@"footerText"]) { _footerSpec = s; break; }
        }
    }
    return _footerSpec;
}

- (void)updateFooter {
    PSSpecifier *g = [self liveFooter];
    [[g properties] setObject:SFFooterText(SNStoredDensity()) forKey:@"footerText"];
    SEL r = NSSelectorFromString(@"reloadSpecifier:");
    if ([self respondsToSelector:r]) {
        IMP imp = [self methodForSelector:r];
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))imp;
        fn(self, r, g);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:NO];
    [self updateFooter];
}

// ─── slider Get/Set (slider value = position 0…100) ─────────────────────────

- (id)readDensityPos:(id)spec {
    return @(SNDensityToPos(SNStoredDensity()));
}

- (void)writeDensity:(id)val forSpecifier:(id)spec {
    double density = SNPosToDensity([val doubleValue]);
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &density);
    CFPreferencesSetValue(CFSTR("density"), n, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(n);
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.nucleartweaks.screen-nuke/changed"), NULL, NULL, true);
    [self updateFooter];
}

// ─── tiny-text switch Get/Set ───────────────────────────────────────────────

- (id)readTiny:(id)spec {
    return SNStoredTiny() ? (id)kCFBooleanTrue : (id)kCFBooleanFalse;
}

- (void)writeTiny:(id)val forSpecifier:(id)spec {
    BOOL on = [val boolValue];
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesSetValue(CFSTR("tinyText"), on ? kCFBooleanTrue : kCFBooleanFalse,
                          dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.nucleartweaks.screen-nuke/changed"), NULL, NULL, true);
}

@end
