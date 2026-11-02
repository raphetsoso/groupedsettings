TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GroupedSettings17Prefs

GroupedSettings17Prefs_FILES = GSPRootListController.m
GroupedSettings17Prefs_FRAMEWORKS = UIKit Foundation
GroupedSettings17Prefs_INSTALL_PATH = /Library/PreferenceBundles
GroupedSettings17Prefs_CFLAGS = -fobjc-arc
# Preferences.framework is private and missing from the Xcode SDK: PSListController
# is resolved at load time (the bundle is only loaded inside Settings, which already has it).
GroupedSettings17Prefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
