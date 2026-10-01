include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = NetShield2
NetShield2_FILES = main.m NSFilterRemoval.m NSFilterRestart.m NSAppDelegate.m NSDashboard.m NSDashboard+Table.m NSDashboard+Configuration.m NSDashboard+Notifications.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSStoreLock.m ../Shared/NSPolicyCache.m
NetShield2_FRAMEWORKS = UIKit Foundation NetworkExtension UserNotifications
NetShield2_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
# RootHide relocates executable bundles and containers; use its documented
# jailbreak entitlements only for that deployment (see Tests/IOS18-COMPATIBILITY.md).
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetShield2_CODESIGN_FLAGS = -SEntitlements-roothide.plist
else
NetShield2_CODESIGN_FLAGS = -SEntitlements.plist
endif
NetShield2_INSTALL_PATH = /Applications
include $(THEOS_MAKE_PATH)/application.mk
