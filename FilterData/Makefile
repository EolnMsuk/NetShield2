include $(THEOS)/makefiles/common.mk
APPEX_NAME = NetShieldData
NetShieldData_FILES = FilterDataProvider.m ../Shared/NSPolicy.m ../Shared/NSStore.m
NetShieldData_FRAMEWORKS = Foundation NetworkExtension
NetShieldData_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
NetShieldData_CODESIGN_FLAGS = -SEntitlements.plist
NetShieldData_INSTALL_PATH = /Applications/NetShield.app/PlugIns
include $(THEOS_MAKE_PATH)/appex.mk
