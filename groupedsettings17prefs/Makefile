TARGET = iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GroupedSettings17Prefs

GroupedSettings17Prefs_FILES = GSPRootListController.m
GroupedSettings17Prefs_FRAMEWORKS = UIKit Foundation
GroupedSettings17Prefs_PRIVATE_FRAMEWORKS = Preferences
GroupedSettings17Prefs_INSTALL_PATH = /Library/PreferenceBundles
GroupedSettings17Prefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
