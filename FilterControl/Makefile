include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShieldControl
NetShieldControl_FILES = FilterControlProvider.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSPermissionQueue.m
NetShieldControl_FRAMEWORKS = Foundation NetworkExtension UserNotifications
NetShieldControl_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
NetShieldControl_CODESIGN_FLAGS = -SEntitlements.plist
NetShieldControl_INSTALL_PATH = /Applications/NetShield.app/PlugIns
include $(THEOS_MAKE_PATH)/appex.mk
