#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// GroupedSettings17 v7 : Réglages en edge-to-edge (style .grouped classique)
//
// Uniquement la couche A (celle qui fonctionne) : on force l'interrupteur
// natif edgeToEdgeCells de PSListController. Réglages fait alors lui-même
// le rendu pleine largeur, sans coins arrondis.
//
// Activation / désactivation : panneau "GroupedSettings17" dans Réglages
// (clé "enabled" du domaine com.raphetsoso.groupedsettings17, lue au lancement de
// Réglages). Pas de crash possible si désactivé : aucun hook n'est installé.
// ---------------------------------------------------------------------------

#define GS_DOMAIN CFSTR("com.raphetsoso.groupedsettings17")

@interface PSListController : UIViewController
- (void)setEdgeToEdgeCells:(BOOL)arg;
- (BOOL)edgeToEdgeCells;
- (BOOL)_isRegularWidth;
@end

// --- Vérification des signatures avant chaque hook --------------------------

static BOOL GSReturnsBool(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && (rt[0] == 'B' || rt[0] == 'c'));
    free(rt);
    return ok;
}

static BOOL GSHasArgCount(Class cls, SEL sel, unsigned int count) {
    Method m = class_getInstanceMethod(cls, sel);
    return m && method_getNumberOfArguments(m) == count;
}

// --- Préférence "enabled" (défaut : activé) ---------------------------------

static BOOL GSIsEnabled(void) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), GS_DOMAIN));
    if (value && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return YES;
}

// --- Hooks -------------------------------------------------------------------

%group EdgeSetter
%hook PSListController
- (void)setEdgeToEdgeCells:(BOOL)arg {
    %orig(YES);
}
%end
%end

%group EdgeGetter
%hook PSListController
- (BOOL)edgeToEdgeCells {
    return YES;
}
%end
%end

%group RegularWidth
%hook PSListController
- (BOOL)_isRegularWidth {
    return NO;
}
%end
%end

static BOOL GSInstallPreferencesHooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class listClass = objc_getClass("PSListController");
    if (!listClass) return NO;
    installed = YES;

    if (GSHasArgCount(listClass, @selector(setEdgeToEdgeCells:), 3)) {
        %init(EdgeSetter);
    }
    if (GSReturnsBool(listClass, @selector(edgeToEdgeCells))) {
        %init(EdgeGetter);
    }
    if (GSReturnsBool(listClass, @selector(_isRegularWidth))) {
        %init(RegularWidth);
    }
    return YES;
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.Preferences"]) return;
        if (!GSIsEnabled()) return;

        if (!GSInstallPreferencesHooks()) {
            // PSListController pas encore chargé : nouvelle tentative au lancement.
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                GSInstallPreferencesHooks();
            }];
        }
    }
}
