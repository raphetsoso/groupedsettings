TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GroupedSettings17Prefs

GroupedSettings17Prefs_FILES = GSPRootListController.m
GroupedSettings17Prefs_FRAMEWORKS = UIKit Foundation
GroupedSettings17Prefs_INSTALL_PATH = /Library/PreferenceBundles
GroupedSettings17Prefs_CFLAGS = -fobjc-arc
# Preferences.framework est privé et absent du SDK Xcode : PSListController est
# résolu au chargement (le bundle n'est chargé que dans Réglages, qui l'a déjà).
GroupedSettings17Prefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
