export TARGET = iphone:clang:latest:12.0
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DoubleClick

DoubleClick_FILES = Tweak.x
DoubleClick_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
DoubleClick_FRAMEWORKS = UIKit AudioToolbox

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
