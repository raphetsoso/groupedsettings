THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GroupedSettings17

GroupedSettings17_FILES = Tweak.x
GroupedSettings17_FRAMEWORKS = UIKit Foundation
GroupedSettings17_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function

SUBPROJECTS += groupedsettings17prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
