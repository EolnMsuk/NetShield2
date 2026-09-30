export ARCHS = arm64
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide
export FINALPACKAGE ?= 1

include $(THEOS)/makefiles/common.mk
SUBPROJECTS = App FilterData FilterControl
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"

after-package::
	python3 scripts/validate.py --stage "$(THEOS_STAGING_DIR)"
