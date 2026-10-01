include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Data
NetShield2Data_FILES = FilterDataProvider.m ../Shared/NSPolicy.m ../Shared/NSStore.m ../Shared/NSStoreLock.m ../Shared/NSPolicyCache.m
NetShield2Data_FRAMEWORKS = Foundation NetworkExtension
NetShield2Data_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
# RootHide relocates executable bundles and containers; use its documented
# jailbreak entitlements only for that deployment (see Tests/IOS18-COMPATIBILITY.md).
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
NetShield2Data_CODESIGN_FLAGS = -SEntitlements-roothide.plist
else
NetShield2Data_CODESIGN_FLAGS = -SEntitlements.plist
endif
NetShield2Data_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
include $(THEOS_MAKE_PATH)/appex.mk
