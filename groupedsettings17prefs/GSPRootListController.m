#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

// Déclaration minimale (pas besoin des headers privés de Preferences).
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plist target:(id)target;
@end

@interface GSPRootListController : PSListController
@end

extern char **environ;

static BOOL GSSpawn(const char *path, const char *arg1) {
    if (access(path, X_OK) != 0) return NO;
    const char *argv[] = { path, arg1, NULL };
    pid_t pid;
    return posix_spawn(&pid, path, NULL, NULL, (char *const *)argv, environ) == 0;
}

@implementation GSPRootListController

// PSListController garde ses spécificateurs dans l'ivar _specifiers ;
// on y accède par KVC pour ne pas dépendre de la disposition des ivars.
- (NSArray *)specifiers {
    NSArray *specs = [self valueForKey:@"_specifiers"];
    if (!specs) {
        specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self setValue:specs forKey:@"_specifiers"];
    }
    return specs;
}

// Bouton "Respring" : enregistre les préférences, relance SpringBoard, puis
// ferme Réglages pour qu'il relise l'interrupteur au prochain lancement.
- (void)applyAndRespring {
    CFPreferencesAppSynchronize(CFSTR("com.raphetsoso.groupedsettings17"));

    // sbreload d'abord ; sinon killall SpringBoard (SpringBoard tourne en mobile).
    if (!GSSpawn("/var/jb/usr/bin/sbreload", NULL)) {
        GSSpawn("/var/jb/usr/bin/killall", "SpringBoard");
    }

    // Même si le respring échoue, quitter Réglages suffit pour appliquer
    // l'interrupteur : il est lu au lancement de Réglages.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(0);
    });
}

@end
