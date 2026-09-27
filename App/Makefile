include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = NetShield
NetShield_FILES = main.m ../Shared/NSPolicy.m ../Shared/NSStore.m
NetShield_FRAMEWORKS = UIKit Foundation NetworkExtension UserNotifications
NetShield_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
NetShield_CODESIGN_FLAGS = -SEntitlements.plist
NetShield_INSTALL_PATH = /Applications
include $(THEOS_MAKE_PATH)/application.mk
