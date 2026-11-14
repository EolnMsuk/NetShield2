include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Data
NetShield2Data_FILES = FilterDataProvider.m ../Shared/NSGlobalRule.m ../Shared/NSPolicy.m ../Shared/NSPolicyReader.m ../Shared/NSPolicyCache.m ../Shared/NSBoundedFile.m
NetShield2Data_FRAMEWORKS = Foundation NetworkExtension
NetShield2Data_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
# Theos signs a temporary .unsigned file; never use its basename as the signing identity.
NetShield2Data_CODESIGN_FLAGS = -SEntitlements.plist -Icom.eolnmsuk.netshield.data
NetShield2Data_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
include $(THEOS_MAKE_PATH)/appex.mk
include ../scripts/bundle_metadata.mk
