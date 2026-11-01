// ScreenNuke — Shrink the whole UI — continuous More-Space mode: slide everything smaller and fit far more on screen, iOS-8-style.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

//%hook SomeClass
//- (void)someMethod {
//    NSLog(@"[ScreenNuke] someMethod");
//    %orig;
//}
//%end

%ctor {
    NSLog(@"[ScreenNuke] loaded into %@ (pid %d)",
          [NSProcessInfo processInfo].processName,
          [[NSProcessInfo processInfo] processIdentifier]);
}
