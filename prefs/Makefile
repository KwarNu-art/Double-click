include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DoubleClickPrefs

DoubleClickPrefs_FILES = DoubleClickRootListController.m
DoubleClickPrefs_INSTALL_PATH = /Library/PreferenceBundles
DoubleClickPrefs_FRAMEWORKS = UIKit
DoubleClickPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# Preferences.framework is private and already loaded inside Settings, so resolve it at runtime.
DoubleClickPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
