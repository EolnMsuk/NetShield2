export ARCHS = arm64
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME ?= rootless
export FINALPACKAGE ?= 1

# Theos uses an empty scheme for rootful; our packaging tools use its name.
NETSHIELD_PACKAGE_VARIANT := $(if $(strip $(THEOS_PACKAGE_SCHEME)),$(THEOS_PACKAGE_SCHEME),rootful)

include $(THEOS)/makefiles/common.mk
SUBPROJECTS = App FilterData FilterControl
include $(THEOS_MAKE_PATH)/aggregate.mk

before-all::
	python3 scripts/sync_version.py

before-package::
	python3 scripts/prepare_package.py --stage "$(THEOS_STAGING_DIR)" --scheme "$(NETSHIELD_PACKAGE_VARIANT)"
	chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"

after-package::
	python3 scripts/validate.py --stage "$(THEOS_STAGING_DIR)" --scheme "$(NETSHIELD_PACKAGE_VARIANT)"
