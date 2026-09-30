include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Control
NetShield2Control_FILES = FilterControlProvider.m NSPermissionNotifications.m NSDomainResolver.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSStoreLock.m ../Shared/NSPolicyCache.m ../Shared/NSPermissionQueue.m
NetShield2Control_FRAMEWORKS = Foundation NetworkExtension UserNotifications
NetShield2Control_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
NetShield2Control_CODESIGN_FLAGS = -SEntitlements.plist
NetShield2Control_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
NetShield2Control_LIBRARIES = dns_sd
include $(THEOS_MAKE_PATH)/appex.mk
