include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = NetShield2
NetShield2_FILES = main.m NSFilterRemoval.m NSAppDelegate.m NSDashboard.m NSDashboard+Table.m NSDashboard+Configuration.m NSDashboard+Notifications.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSStoreLock.m ../Shared/NSPolicyCache.m
NetShield2_FRAMEWORKS = UIKit Foundation NetworkExtension UserNotifications
NetShield2_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
NetShield2_CODESIGN_FLAGS = -SEntitlements.plist
NetShield2_INSTALL_PATH = /Applications
include $(THEOS_MAKE_PATH)/application.mk
