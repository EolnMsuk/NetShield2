include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShield2Data
NetShield2Data_FILES = FilterDataProvider.m ../Shared/NSPolicy.m ../Shared/NSStore.m
NetShield2Data_FRAMEWORKS = Foundation NetworkExtension
NetShield2Data_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability
NetShield2Data_CODESIGN_FLAGS = -SEntitlements.plist
NetShield2Data_INSTALL_PATH = /Applications/NetShield2.app/PlugIns
include $(THEOS_MAKE_PATH)/appex.mk
