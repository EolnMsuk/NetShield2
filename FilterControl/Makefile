include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Control
NetShield2Control_FILES = FilterControlProvider.m NSProviderWorkQueue.m NSPermissionNotifications.m NSDomainResolver.m ../Shared/NSGlobalRule.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSConfigurationRecord.m ../Shared/NSStoreLock.m ../Shared/NSBoundedFile.m ../Shared/NSMonitorSchema.m ../Shared/NSExport.m ../Shared/NSPolicyReader.m ../Shared/NSPolicyCache.m ../Shared/NSPermissionQueue.m
NetShield2Control_FRAMEWORKS = Foundation NetworkExtension UserNotifications
NetShield2Control_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
# Theos signs a temporary .unsigned file; never use its basename as the signing identity.
NetShield2Control_CODESIGN_FLAGS = -SEntitlements.plist -Icom.eolnmsuk.netshield.control
NetShield2Control_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
# DNSService APIs are supplied by the automatically linked libSystem on iOS.
include $(THEOS_MAKE_PATH)/appex.mk
include ../scripts/bundle_metadata.mk
