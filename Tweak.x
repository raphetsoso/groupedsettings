#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>
#import <fcntl.h>
#import <unistd.h>

// ---------------------------------------------------------------------------
// GroupedSettings v6 : imitation de .grouped dans Réglages (iOS 17, rootless)
//
// On ne remplace JAMAIS le style de la table à l'init. Quatre couches, toutes
// protégées (méthode présente + signature vérifiée avant chaque hook) :
//
//   A. PSListController : interrupteur natif edgeToEdgeCells.
//   B. UITableView      : si une table reste en insetGrouped, on annule ses
//                         marges de section / rayon de section / retrait droit
//                         des séparateurs.
//   C. UITableViewCell / UITableViewHeaderFooterView : backgroundConfiguration
//      (cornerRadius 0, insets 0), layers legacy (highlight plat pleine
//      largeur), marges des en-têtes/pieds de section.
//   D. UICollectionView (listes compositionnelles, ex. panneaux SwiftUI /
//      UIHostingController dans Réglages) : UICollectionLayoutListConfiguration
//      insetGrouped -> grouped (API publique, sans risque), plus filet de
//      sécurité sur UICollectionViewListCell.
//
// Les couches B et C sont des no-op si la table est déjà en style .grouped.
// ---------------------------------------------------------------------------

#ifndef GS_DEBUG
#define GS_DEBUG 1
#endif
#ifndef GS_FORCE_GROUPED_STYLE
#define GS_FORCE_GROUPED_STYLE 0   // dernier recours, voir plus bas
#endif
#ifndef GS_COLLECTION
#define GS_COLLECTION 1            // couche D (listes UICollectionView)
#endif
// Masque de couches actives (pour isoler un crash, voir Makefile : GS_LAYERS) :
//   1 = A  PSListController (edgeToEdgeCells)       <- le plus sûr
//   2 = B  UITableView (marges de section, séparateurs)
//   4 = C  cellules (fond, highlight, PSTableCell)
//   8 = D  UICollectionView (listes SwiftUI)
//  16 = H  en-têtes / pieds de section
#ifndef GS_LAYERS
#define GS_LAYERS 1
#endif
#define GS_ON(bit) ((GS_LAYERS) & (bit))
#ifndef GS_HEADER_MARGIN
#define GS_HEADER_MARGIN 20.0      // retrait latéral des en-têtes/pieds (.grouped classique)
#endif

#if GS_DEBUG
// Journal fichier (survit à un crash / kill) : lisible ensuite avec Filza.
// Chaque ligne est écrite et fermée immédiatement, donc la DERNIÈRE ligne
// indique où le processus est mort.
static void GSWriteCrumb(NSString *msg) {
    static const char *paths[] = {
        "/var/mobile/Library/Preferences/GroupedSettings.log",
        "/var/mobile/GroupedSettings.log",
        "/tmp/GroupedSettings.log"
    };
    const char *line = [[msg stringByAppendingString:@"\n"] UTF8String];
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, line, strlen(line)); close(fd); return; }
    }
}
#define GSLog(fmt, ...) do { \
    NSString *_gsm = [NSString stringWithFormat:@"[GroupedSettings] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _gsm); GSWriteCrumb(_gsm); } while (0)
#else
#define GSLog(...) do {} while (0)
#endif

@interface PSListController : UIViewController
- (void)setEdgeToEdgeCells:(BOOL)arg;
- (BOOL)edgeToEdgeCells;
- (BOOL)_isRegularWidth;
- (UITableView *)table;
@end

@interface PSTableCell : UITableViewCell
@end

// --- Helpers : vérification des signatures ----------------------------------

static BOOL GSReturnsOneOf(Class cls, SEL sel, const char *chars) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] != '\0' && strchr(chars, rt[0]) != NULL);
    free(rt);
    return ok;
}

static BOOL GSReturnsStruct(Class cls, SEL sel, const char *structName) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '{' && strstr(rt, structName) != NULL);
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

#if GS_DEBUG
static void GSDumpMethods(Class cls, const char **needles, size_t n) {
    if (!cls) return;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(list[i]));
        for (size_t j = 0; j < n; j++) {
            if (strcasestr(name, needles[j])) {
                char *rt = method_copyReturnType(list[i]);
                GSLog(@"%s  -%s  -> %s", class_getName(cls), name, rt ? rt : "?");
                free(rt);
                break;
            }
        }
    }
    free(list);
}
#endif

// --- Helpers : aplatissement -------------------------------------------------

static inline BOOL GSInsetsAreZero(NSDirectionalEdgeInsets i) {
    return i.top == 0 && i.leading == 0 && i.bottom == 0 && i.trailing == 0;
}

static UITableView *GSTableViewForView(UIView *view) {
    UIView *v = view.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    return (UITableView *)v;
}

// Une vue n'est aplatie que si sa table est encore en insetGrouped.
// Si la couche A a réussi (table en .grouped), tout ce qui suit est un no-op.
static BOOL GSViewNeedsFlattening(UIView *view) {
    UITableView *table = GSTableViewForView(view);
    return table && table.style == UITableViewStyleInsetGrouped;
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

// Rayon des cellules insetGrouped (repéré par l'approche de liquidass :
// balayage des vues de la cellule dont le rayon vaut ~10 pt).
#define GS_INSET_RADIUS 10.0

// Balaie les vues de fond de la cellule (HORS contentView : les icônes et
// contrôles y ont leurs propres rayons, qu'il ne faut pas toucher).
static void GSFlattenBackgroundTree(UIView *view, UIView *skip, NSUInteger depth) {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if (sub == skip) continue;
        CGFloat r = sub.layer.cornerRadius;
        if (r != 0) {
            BOOL partialCorners = sub.layer.maskedCorners != (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                                              kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
            if (fabs(r - GS_INSET_RADIUS) <= 0.25 || partialCorners) sub.layer.cornerRadius = 0;
        }
        GSFlattenBackgroundTree(sub, skip, depth + 1);
    }
}

#if GS_DEBUG
// Sonde : une fois par classe de cellule, journalise la hiérarchie de fond
// (classe, frame, rayon) pour identifier la vue qui reste arrondie.
static void GSProbeAppend(NSMutableString *out, UIView *v, NSUInteger depth, NSUInteger maxDepth) {
    if (depth > maxDepth) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"\n%@%@ f=%@ radius=%.1f clips=%d", pad, NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.layer.cornerRadius, v.clipsToBounds];
    for (UIView *s in v.subviews) GSProbeAppend(out, s, depth + 1, maxDepth);
}

static void GSProbeCell(UITableViewCell *cell) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = NSStringFromClass([cell class]);
    if ([seen containsObject:key] || seen.count > 12 || !cell.window) return;
    [seen addObject:key];
    UITableView *t = GSTableViewForView(cell);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"[GroupedSettings][PROBE] cell=%@ table.style=%ld cellFrame=%@ tableFrame=%@ bgConfig.radius=%.1f",
        key, (long)t.style, NSStringFromCGRect(cell.frame), NSStringFromCGRect(t.frame),
        cell.backgroundConfiguration ? cell.backgroundConfiguration.cornerRadius : -1.0];
    GSProbeAppend(out, cell, 0, 3);
    NSLog(@"%@", out);
}
#endif

static void GSFlattenCell(UITableViewCell *cell) {
    if (!GSViewNeedsFlattening(cell)) return;

    UIBackgroundConfiguration *cfg = cell.backgroundConfiguration;
    if (cfg) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) cell.backgroundConfiguration = flat;
    }

    // Chemin legacy (backgroundView / selectedBackgroundView posés par
    // PSTableCell ou par UIKit) : même règle, coins à 0.
    GSFlattenView(cell);
    GSFlattenView(cell.backgroundView);
    GSFlattenView(cell.selectedBackgroundView);
    GSFlattenView(cell.multipleSelectionBackgroundView);
    GSFlattenBackgroundTree(cell, cell.contentView, 0);
#if GS_DEBUG
    GSProbeCell(cell);
#endif
}

static void GSAdjustHeaderFooter(UITableViewHeaderFooterView *view) {
    if (!GSViewNeedsFlattening(view)) return;
    NSDirectionalEdgeInsets m = view.directionalLayoutMargins;
    if (m.leading == GS_HEADER_MARGIN && m.trailing == GS_HEADER_MARGIN) return; // garde anti-boucle
    m.leading = GS_HEADER_MARGIN;
    m.trailing = GS_HEADER_MARGIN;
    view.directionalLayoutMargins = m;
}

// ===========================================================================
// COUCHE A : PSListController (interrupteurs natifs)
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

#if GS_DEBUG
%group Diagnostics
%hook PSListController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UITableView *t = [self respondsToSelector:@selector(table)] ? [self table] : nil;
    BOOL e2e = [self respondsToSelector:@selector(edgeToEdgeCells)] ? [self edgeToEdgeCells] : NO;
    // style : 0 plain, 1 grouped, 2 insetGrouped
    GSLog(@"%@ table.style=%ld edgeToEdge=%d", NSStringFromClass([self class]), (long)t.style, (int)e2e);
}
%end
%end
#endif

// ===========================================================================
// COUCHE B : UITableView (si la table reste en insetGrouped)
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

%group TableSeparator
%hook UITableView
- (void)setSeparatorInset:(UIEdgeInsets)inset {
    // Retrait gauche d'origine conservé, séparateur jusqu'au bord droit.
    if (self.style == UITableViewStyleInsetGrouped) inset.right = 0;
    %orig(inset);
}
%end
%end

// ===========================================================================
// COUCHE C : UITableViewCell (backgroundConfiguration + highlight) et
//            UITableViewHeaderFooterView (alignement en-têtes / pieds)
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

// Fond "système" par défaut (c'est lui qui porte l'arrondi insetGrouped et le
// fond de sélection) : on l'aplatit à la source.
%group CellDefaultBackground
%hook UITableViewCell
- (UIBackgroundConfiguration *)defaultBackgroundConfiguration {
    UIBackgroundConfiguration *cfg = %orig;
    return GSViewNeedsFlattening(self) ? GSFlatConfiguration(cfg) : cfg;
}
%end
%end

// PSTableCell (cellules de Réglages) : ses layoutSubviews/setSelected: peuvent
// ré-appliquer un fond arrondi après le hook UITableViewCell ; on repasse
// donc derrière elle (même approche que liquidass : hook direct PSTableCell).
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

%group HeaderFooterAlign
%hook UITableViewHeaderFooterView
- (void)layoutSubviews {
    GSAdjustHeaderFooter(self);
    %orig;
}
%end
%end

// ===========================================================================
// COUCHE D : UICollectionView (listes compositionnelles)
// ===========================================================================
#if GS_COLLECTION

static inline UICollectionLayoutListAppearance GSMapAppearance(UICollectionLayoutListAppearance a) {
    return a == UICollectionLayoutListAppearanceInsetGrouped
        ? UICollectionLayoutListAppearanceGrouped : a;
}

%group CollectionListConfig
%hook UICollectionLayoutListConfiguration
- (instancetype)initWithAppearance:(UICollectionLayoutListAppearance)appearance {
    return %orig(GSMapAppearance(appearance));
}
- (void)setAppearance:(UICollectionLayoutListAppearance)appearance {
    %orig(GSMapAppearance(appearance));
}
%end
%end

// Filet de sécurité : cellule de liste dont le fond resterait arrondi/inséré.
%group CollectionCellFlatten
%hook UICollectionViewListCell
- (void)updateConfigurationUsingState:(UICellConfigurationState *)state {
    %orig;
    UIBackgroundConfiguration *cfg = self.backgroundConfiguration;
    if (cfg && cfg.cornerRadius != 0) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) self.backgroundConfiguration = flat;
    }
}
%end
%end

#endif // GS_COLLECTION

// ===========================================================================
// DERNIER RECOURS (désactivé par défaut) : conversion insetGrouped -> grouped
// à l'init. À activer avec -DGS_FORCE_GROUPED_STYLE=1 UNIQUEMENT si la couche A
// n'a aucun effet (voir les logs table.style=2 persistants).
// ===========================================================================
#if GS_FORCE_GROUPED_STYLE
%group ForcedStyle
%hook UITableView
- (instancetype)initWithFrame:(CGRect)frame style:(UITableViewStyle)style {
    return %orig(frame, style == UITableViewStyleInsetGrouped ? UITableViewStyleGrouped : style);
}
%end
%end
#endif

// ===========================================================================
// Installation
// ===========================================================================

static void GSInstallUIKitHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class tableClass  = objc_getClass("UITableView");
        Class cellClass   = objc_getClass("UITableViewCell");
        Class headerClass = objc_getClass("UITableViewHeaderFooterView");

        if (tableClass && GS_ON(2)) {
            if (GSReturnsStruct(tableClass, @selector(_sectionContentInset), "UIEdgeInsets")) {
                %init(TableContentInset);
                GSLog(@"hook UITableView _sectionContentInset installe");
            } else {
                GSLog(@"UITableView _sectionContentInset absent ou signature inattendue");
            }
            if (GSReturnsOneOf(tableClass, @selector(_sectionCornerRadius), "d")) {
                %init(TableSectionRadius);
                GSLog(@"hook UITableView _sectionCornerRadius installe");
            } else {
                GSLog(@"UITableView _sectionCornerRadius absent ou signature inattendue");
            }
            if (GSHasArgCount(tableClass, @selector(setSeparatorInset:), 3)) {
                %init(TableSeparator);
            }
#if GS_FORCE_GROUPED_STYLE
            %init(ForcedStyle);
            GSLog(@"ATTENTION : GS_FORCE_GROUPED_STYLE actif");
#endif
        }

        if (cellClass && GS_ON(4)) {
            %init(CellFlatten);
            GSLog(@"hooks UITableViewCell installes");
            if (GSReturnsObject(cellClass, @selector(defaultBackgroundConfiguration))) {
                %init(CellDefaultBackground);
                GSLog(@"hook defaultBackgroundConfiguration installe");
            }
        }

        if (headerClass && GS_ON(16)) {
            %init(HeaderFooterAlign);
        }

#if GS_COLLECTION
        Class listConfigClass = objc_getClass("UICollectionLayoutListConfiguration");
        Class listCellClass   = objc_getClass("UICollectionViewListCell");
        if (GS_ON(8) && listConfigClass &&
            GSHasArgCount(listConfigClass, @selector(initWithAppearance:), 3) &&
            GSHasArgCount(listConfigClass, @selector(setAppearance:), 3)) {
            %init(CollectionListConfig);
            GSLog(@"hooks UICollectionLayoutListConfiguration installes");
        } else {
            GSLog(@"UICollectionLayoutListConfiguration : signature inattendue");
        }
        if (GS_ON(8) && listCellClass) {
            %init(CollectionCellFlatten);
        }
#endif

#if GS_DEBUG
        const char *tableNeedles[] = { "sectionContentInset", "sectionCornerRadius", "insetGrouped" };
        GSDumpMethods(tableClass, tableNeedles, 3);
#endif
    });
}

static BOOL GSInstallPreferencesHooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class listClass = objc_getClass("PSListController");
    if (!listClass) return NO;
    installed = YES;

    if (GS_ON(1) && GSHasArgCount(listClass, @selector(setEdgeToEdgeCells:), 3)) {
        %init(EdgeSetter);
        GSLog(@"hook setEdgeToEdgeCells: installe");
    } else {
        GSLog(@"setEdgeToEdgeCells: absent");
    }
    if (GS_ON(1) && GSReturnsOneOf(listClass, @selector(edgeToEdgeCells), "Bc")) {
        %init(EdgeGetter);
        GSLog(@"hook edgeToEdgeCells installe");
    } else {
        GSLog(@"edgeToEdgeCells absent");
    }
    if (GS_ON(1) && GSReturnsOneOf(listClass, @selector(_isRegularWidth), "Bc")) {
        %init(RegularWidth);
        GSLog(@"hook _isRegularWidth installe");
    } else {
        GSLog(@"_isRegularWidth absent");
    }

    if (GS_ON(4) && objc_getClass("PSTableCell")) {
        %init(PSCellFlatten);
        GSLog(@"hooks PSTableCell installes");
    }

#if GS_DEBUG
    %init(Diagnostics);
    const char *psNeedles[] = { "edgeToEdge", "RegularWidth", "tableViewStyle", "insetGrouped", "TableStyle" };
    GSDumpMethods(listClass, psNeedles, 5);
#endif
    return YES;
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.Preferences"]) return;
        GSLog(@"ctor: dylib charge dans Preferences, pid=%d", (int)getpid());

        GSLog(@"v6.2 charge layers=%d (iOS %@)", (int)(GS_LAYERS), [[UIDevice currentDevice] systemVersion]);
        GSInstallUIKitHooks();

        if (!GSInstallPreferencesHooks()) {
            GSLog(@"PSListController pas encore charge, nouvelle tentative au lancement");
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                if (!GSInstallPreferencesHooks()) {
                    GSLog(@"PSListController introuvable, aucun hook PS installe");
                }
            }];
        }
    }
}
