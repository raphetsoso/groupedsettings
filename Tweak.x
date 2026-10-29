#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
// GroupedSettings17 v8 : Réglages en edge-to-edge (style .grouped classique)
//
//   A. PSListController : interrupteur natif edgeToEdgeCells (panneaux Réglages).
//   B. UITableView      : marges et rayon de section à 0 (zones qui ne passent pas
//                         par PSListController, ex. Wi-Fi).
//   C. UITableViewCell  : fond de cellule et highlight plats, pleine largeur.
//
// Un seul interrupteur (panneau GroupedSettings17) désactive tout : aucun hook
// n'est installé quand il est coupé. Chaque hook vérifie sa signature avant
// d'être installé.
// ---------------------------------------------------------------------------

#define GS_DOMAIN CFSTR("com.raphetsoso.groupedsettings17")
#define GS_INSET_RADIUS 10.0   // rayon des cellules "inset" d'iOS 17

#ifndef GS_DEBUG
#define GS_DEBUG 1   // journal : /var/mobile/Library/Preferences/GroupedSettings17.log (mettre 0 pour publier)
#endif

#if GS_DEBUG
static void GSWriteCrumb(NSString *msg) {
    static const char *paths[] = {
        "/var/mobile/Library/Preferences/GroupedSettings17.log",
        "/var/mobile/GroupedSettings17.log",
        "/tmp/GroupedSettings17.log"
    };
    const char *line = [[msg stringByAppendingString:@"\n"] UTF8String];
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, line, strlen(line)); close(fd); return; }
    }
}
#define GSLog(fmt, ...) do { \
    NSString *_gsm = [NSString stringWithFormat:@"[GS17] " fmt, ##__VA_ARGS__]; \
    GSWriteCrumb(_gsm); } while (0)
#else
#define GSLog(...) do {} while (0)
#endif

@interface PSListController : UIViewController
- (void)setEdgeToEdgeCells:(BOOL)arg;
- (BOOL)edgeToEdgeCells;
- (BOOL)_isRegularWidth;
@end

@interface PSTableCell : UITableViewCell
@end

// --- Vérification des signatures ---------------------------------------------

static BOOL GSReturnsBool(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && (rt[0] == 'B' || rt[0] == 'c'));
    free(rt);
    return ok;
}

static BOOL GSReturnsDouble(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == 'd');
    free(rt);
    return ok;
}

static BOOL GSReturnsInsets(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '{' && strstr(rt, "UIEdgeInsets") != NULL);
    free(rt);
    return ok;
}

static BOOL GSReturnsObject(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '@');
    free(rt);
    return ok;
}

static BOOL GSHasArgCount(Class cls, SEL sel, unsigned int count) {
    Method m = class_getInstanceMethod(cls, sel);
    return m && method_getNumberOfArguments(m) == count;
}

// --- Préférence "enabled" (défaut : activé) ----------------------------------

static BOOL GSIsEnabled(void) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), GS_DOMAIN));
    if (value && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return YES;
}

// --- Aplatissement -----------------------------------------------------------

static inline BOOL GSInsetsAreZero(NSDirectionalEdgeInsets i) {
    return i.top == 0 && i.leading == 0 && i.bottom == 0 && i.trailing == 0;
}

static UITableView *GSTableViewForView(UIView *view) {
    UIView *v = view.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    return (UITableView *)v;
}

// Dans Réglages iOS 17 les tables rapportent souvent style=1 (.grouped) avec
// un aspect "inset" venant de _sectionContentInset / _sectionCornerRadius :
// on traite donc .grouped ET .insetGrouped (aplatir une table déjà plate est
// sans effet).
static BOOL GSViewNeedsFlattening(UIView *view) {
    UITableView *table = GSTableViewForView(view);
    return table && (table.style == UITableViewStyleInsetGrouped ||
                     table.style == UITableViewStyleGrouped);
}

static UIBackgroundConfiguration *GSFlatConfiguration(UIBackgroundConfiguration *cfg) {
    if (!cfg) return nil;
    if (cfg.cornerRadius == 0 &&
        GSInsetsAreZero(cfg.backgroundInsets) &&
        cfg.edgesAddingLayoutMarginsToBackgroundInsets == NSDirectionalRectEdgeNone) {
        return cfg; // déjà plat : même instance (idempotent, pas de boucle)
    }
    UIBackgroundConfiguration *flat = [cfg copy];
    flat.cornerRadius = 0;
    flat.backgroundInsets = NSDirectionalEdgeInsetsZero;
    flat.edgesAddingLayoutMarginsToBackgroundInsets = NSDirectionalRectEdgeNone;
    return flat;
}

static void GSFlattenView(UIView *view) {
    if (view && view.layer.cornerRadius != 0) view.layer.cornerRadius = 0;
}

// Balaie les vues de fond de la cellule, HORS contentView (les icônes et
// contrôles y ont leurs propres rayons) : rayon ~10 pt ou coins partiels.
static void GSFlattenBackgroundTree(UIView *view, UIView *skip, NSUInteger depth) {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if (sub == skip) continue;
        CGFloat r = sub.layer.cornerRadius;
        if (r != 0) {
            BOOL partial = sub.layer.maskedCorners != (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                                       kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
            if (fabs(r - GS_INSET_RADIUS) <= 0.25 || partial) sub.layer.cornerRadius = 0;
        }
        GSFlattenBackgroundTree(sub, skip, depth + 1);
    }
}

#if GS_DEBUG
static void GSProbeAppend(NSMutableString *out, UIView *v, NSUInteger depth, NSUInteger maxDepth) {
    if (depth > maxDepth) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"\n%@%@ f=%@ radius=%.1f", pad, NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.layer.cornerRadius];
    for (UIView *sub in v.subviews) GSProbeAppend(out, sub, depth + 1, maxDepth);
}

// Une fois par classe de cellule : hiérarchie de fond (identifie la vue arrondie).
static void GSProbeCell(UITableViewCell *cell) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = NSStringFromClass([cell class]);
    if ([seen containsObject:key] || seen.count > 25 || !cell.window) return;
    [seen addObject:key];
    UITableView *t = GSTableViewForView(cell);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"CELL %@ table=%@ style=%ld cellFrame=%@ bgCfgRadius=%.1f",
        key, NSStringFromClass([t class]), (long)t.style, NSStringFromCGRect(cell.frame),
        cell.backgroundConfiguration ? cell.backgroundConfiguration.cornerRadius : -1.0];
    GSProbeAppend(out, cell, 0, 3);
    GSLog(@"%@", out);
}
#endif

// Écrit directement les réglages privés de la table (plus fiable que hooker
// leurs lecteurs, que UIKit peut ne pas appeler). Une seule fois par largeur.
static void *kGSTableWidthKey = &kGSTableWidthKey;

static void GSForceTableFlat(UITableView *t) {
    if (!(t.style == UITableViewStyleInsetGrouped || t.style == UITableViewStyleGrouped)) return;
    if (!t.window) return;
    CGFloat w = t.bounds.size.width;
    NSNumber *last = objc_getAssociatedObject(t, kGSTableWidthKey);
    if (last && fabs(last.doubleValue - w) < 0.5) return;
    objc_setAssociatedObject(t, kGSTableWidthKey, @(w), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sFollow = NSSelectorFromString(@"_setSectionContentInsetFollowsLayoutMargins:");
    SEL sInset  = NSSelectorFromString(@"_setSectionContentInset:");
    SEL sRadius = NSSelectorFromString(@"_setSectionCornerRadius:");
    if ([t respondsToSelector:sFollow]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, sFollow, NO);
    if ([t respondsToSelector:sInset])  ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(t, sInset, UIEdgeInsetsZero);
    if ([t respondsToSelector:sRadius]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(t, sRadius, 0);

#if GS_DEBUG
    SEL sRaw = NSSelectorFromString(@"_rawSectionContentInset");
    UIEdgeInsets raw = [t respondsToSelector:sRaw]
        ? ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(t, sRaw) : UIEdgeInsetsZero;
    id delegate = t.delegate;
    GSLog(@"TABLE %@ style=%ld delegate=%@ frame=%@ rawInset=%@ layoutMargins=%@",
          NSStringFromClass([t class]), (long)t.style,
          delegate ? NSStringFromClass([delegate class]) : @"nil",
          NSStringFromCGRect(t.frame), NSStringFromUIEdgeInsets(raw),
          NSStringFromUIEdgeInsets(t.layoutMargins));
#endif
}

static void GSFlattenCell(UITableViewCell *cell) {
    if (!GSViewNeedsFlattening(cell)) return;

    UIBackgroundConfiguration *cfg = cell.backgroundConfiguration;
    if (cfg) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) cell.backgroundConfiguration = flat;
    }
    GSFlattenView(cell);
    GSFlattenView(cell.backgroundView);
    GSFlattenView(cell.selectedBackgroundView);
    GSFlattenView(cell.multipleSelectionBackgroundView);
    GSFlattenBackgroundTree(cell, cell.contentView, 0);
#if GS_DEBUG
    GSProbeCell(cell);
#endif
}

// ===========================================================================
// COUCHE A : PSListController
// ===========================================================================

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

// PSTableCell : repasse derrière Réglages, qui peut remettre un fond arrondi.
%group PSCellFlatten
%hook PSTableCell
- (void)layoutSubviews {
    %orig;
    GSFlattenCell(self);
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    GSFlattenCell(self);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    GSFlattenCell(self);
}
%end
%end

// ===========================================================================
// COUCHE B : UITableView (zones hors PSListController, ex. Wi-Fi)
// ===========================================================================

%group TableContentInset
%hook UITableView
- (UIEdgeInsets)_sectionContentInset {
    return UIEdgeInsetsZero;
}
%end
%end

%group TableSectionRadius
%hook UITableView
- (CGFloat)_sectionCornerRadius {
    return 0;
}
%end
%end

%group TableForce
%hook UITableView
- (void)layoutSubviews {
    %orig;
    GSForceTableFlat(self);
}
%end
%end

// ===========================================================================
// COUCHE D : listes UICollectionView (panneaux SwiftUI de Réglages)
// Une liste insetGrouped est convertie en grouped (API publique d'UIKit) :
// pleine largeur, sans coins arrondis.
// ===========================================================================

static inline UICollectionLayoutListAppearance GSMapAppearance(UICollectionLayoutListAppearance a) {
    return a == UICollectionLayoutListAppearanceInsetGrouped
        ? UICollectionLayoutListAppearanceGrouped : a;
}

#if GS_DEBUG
static void GSLogAppearanceOnce(const char *tag, long value) {
    static BOOL seen[16];
    if (value < 0 || value > 15) return;
    int idx = (int)value;
    if (seen[idx]) return;
    seen[idx] = YES;
    GSLog(@"LISTCONFIG %s appearance=%ld (2=insetGrouped, 1=grouped, 0=plain)", tag, value);
}
#endif

%group CollectionListInit
%hook UICollectionLayoutListConfiguration
- (instancetype)initWithAppearance:(UICollectionLayoutListAppearance)appearance {
#if GS_DEBUG
    GSLogAppearanceOnce("init", (long)appearance);
#endif
    return %orig(GSMapAppearance(appearance));
}
%end
%end

%group CollectionListSetter
%hook UICollectionLayoutListConfiguration
- (void)setAppearance:(UICollectionLayoutListAppearance)appearance {
#if GS_DEBUG
    GSLogAppearanceOnce("set", (long)appearance);
#endif
    %orig(GSMapAppearance(appearance));
}
%end
%end

#if GS_DEBUG
// Sonde : une fois par classe de UICollectionView, journalise sa mise en page.
%group CollectionProbe
%hook UICollectionView
- (void)didMoveToWindow {
    %orig;
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    if (!self.window) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]),
                     NSStringFromClass([self.collectionViewLayout class])];
    if ([seen containsObject:key] || seen.count > 25) return;
    [seen addObject:key];
    GSLog(@"COLLECTION %@ frame=%@ delegate=%@", key, NSStringFromCGRect(self.frame),
          self.delegate ? NSStringFromClass([(NSObject *)self.delegate class]) : @"nil");
}
%end
%end
#endif

// ===========================================================================
// COUCHE C : UITableViewCell (fond et highlight plats)
// ===========================================================================

%group CellFlatten
%hook UITableViewCell
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)configuration {
    if (configuration && GSViewNeedsFlattening(self)) {
        %orig(GSFlatConfiguration(configuration));
        return;
    }
    %orig(configuration);
}

- (void)updateConfigurationUsingState:(UICellConfigurationState *)state {
    %orig;
    GSFlattenCell(self);
}

- (void)layoutSubviews {
    %orig;
    GSFlattenCell(self);
}
%end
%end

// Fond "système" par défaut (porte l'arrondi et le fond de sélection).
%group CellDefaultBackground
%hook UITableViewCell
- (UIBackgroundConfiguration *)defaultBackgroundConfiguration {
    UIBackgroundConfiguration *cfg = %orig;
    return GSViewNeedsFlattening(self) ? GSFlatConfiguration(cfg) : cfg;
}
%end
%end

// ===========================================================================
// Installation
// ===========================================================================

static void GSInstallUIKitHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class tableClass = objc_getClass("UITableView");
        Class cellClass  = objc_getClass("UITableViewCell");

        if (tableClass) {
            if (GSReturnsInsets(tableClass, @selector(_sectionContentInset))) {
                %init(TableContentInset);
            }
            if (GSReturnsDouble(tableClass, @selector(_sectionCornerRadius))) {
                %init(TableSectionRadius);
            }
            %init(TableForce);
        }
        Class listConfig = objc_getClass("UICollectionLayoutListConfiguration");
        BOOL hasInit = listConfig && GSHasArgCount(listConfig, @selector(initWithAppearance:), 3);
        BOOL hasSet  = listConfig && GSHasArgCount(listConfig, @selector(setAppearance:), 3);
        GSLog(@"COUCHE D : classe=%d initWithAppearance:=%d setAppearance:=%d", listConfig != Nil, hasInit, hasSet);
        if (hasInit) { %init(CollectionListInit); }
        if (hasSet)  { %init(CollectionListSetter); }
#if GS_DEBUG
        %init(CollectionProbe);
#endif

        if (cellClass) {
            %init(CellFlatten);
            if (GSReturnsObject(cellClass, @selector(defaultBackgroundConfiguration))) {
                %init(CellDefaultBackground);
            }
        }
    });
}

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
    if (objc_getClass("PSTableCell")) {
        %init(PSCellFlatten);
    }
    return YES;
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.Preferences"]) return;
        if (!GSIsEnabled()) return;

        GSLog(@"v8.2 charge (iOS %@)", [[UIDevice currentDevice] systemVersion]);
        GSInstallUIKitHooks();

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
