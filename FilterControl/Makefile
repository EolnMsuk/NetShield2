include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Control
NetShield2Control_FILES = FilterControlProvider.m NSPermissionNotifications.m NSDomainResolver.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSStoreLock.m ../Shared/NSPolicyCache.m ../Shared/NSPermissionQueue.m
NetShield2Control_FRAMEWORKS = Foundation NetworkExtension UserNotifications
NetShield2Control_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
# RootHide relocates executable bundles and containers; use its documented
# jailbreak entitlements only for that deployment (see Tests/IOS18-COMPATIBILITY.md).
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetShield2Control_CODESIGN_FLAGS = -SEntitlements-roothide.plist
else
NetShield2Control_CODESIGN_FLAGS = -SEntitlements.plist
endif
NetShield2Control_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
# DNSService APIs are supplied by the automatically linked libSystem on iOS.
include $(THEOS_MAKE_PATH)/appex.mk
