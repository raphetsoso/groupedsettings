THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GroupedSettings

GroupedSettings_FILES = Tweak.x
GroupedSettings_FRAMEWORKS = UIKit Foundation QuartzCore
# Couches actives (bitmask) : 1=A edgeToEdge, 2=B table, 4=C cellules, 8=D collection, 16=en-tetes
# Exemple : make package install GS_LAYERS=7   (A+B+C)
GS_LAYERS ?= 1
GroupedSettings_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -DGS_LAYERS=$(GS_LAYERS)

# Logs [GroupedSettings] actifs en build debug, coupés avec FINALPACKAGE=1
ifeq ($(FINALPACKAGE),1)
GroupedSettings_CFLAGS += -DGS_DEBUG=0
endif

include $(THEOS_MAKE_PATH)/tweak.mk
