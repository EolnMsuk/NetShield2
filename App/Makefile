include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = NetShield2
NetShield2_FILES = main.m NSAppStorage.m NSReleaseFetch.m NSConfigurationCoordinator.m NSFilterRemoval.m NSFilterRestart.m NSFilterBootPolicy.m NSRespring.m NSAppDelegate.m NSDashboard.m NSGlobalRuleEditor.m NSRuleActionController.m NSDashboard+Table.m NSDashboard+Configuration.m NSDashboard+Notifications.m NSDashboard+Updates.m ../Shared/NSGlobalRule.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSConfigurationRecord.m ../Shared/NSStoreLock.m ../Shared/NSBoundedFile.m ../Shared/NSMonitorSchema.m ../Shared/NSExport.m ../Shared/NSPolicyReader.m ../Shared/NSPolicyCache.m
NetShield2_FRAMEWORKS = UIKit Foundation NetworkExtension UserNotifications UniformTypeIdentifiers
NetShield2_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetShield2_CFLAGS += -DNS_JAILBREAK_TYPE=\"roothide\"
else ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
NetShield2_CFLAGS += -DNS_JAILBREAK_TYPE=\"rootless\"
else
NetShield2_CFLAGS += -DNS_JAILBREAK_TYPE=\"rootful\"
endif
# Theos signs a temporary .unsigned file; never use its basename as the signing identity.
NetShield2_CODESIGN_FLAGS = -SEntitlements.plist -Icom.eolnmsuk.netshield
NetShield2_INSTALL_PATH = /Applications
include $(THEOS_MAKE_PATH)/application.mk
include ../scripts/bundle_metadata.mk
