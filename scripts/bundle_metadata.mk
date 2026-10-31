# Include after application.mk/appex.mk. Both pinned Theos variants copy resources
# in shared-instance-bundle-all. Its double-colon recipes run in definition order.
# Each instance/architecture writes only its own output; source plists stay templates.
ifneq ($(_LOCAL_INSTANCE_TARGET),)
shared-instance-bundle-all::
	python3 ../scripts/sync_version.py --template Resources/Info.plist --output "$(_THEOS_SHARED_BUNDLE_BUILD_PATH)$(_THEOS_TARGET_BUNDLE_INFO_PLIST_SUBDIRECTORY)/Info.plist"

# Also order resource generation before signing in non-parallel Theos mode and
# direct compile invocations. Linking may run concurrently; signing must wait.
$(THEOS_OBJ_DIR)/$(_LOCAL_INSTANCE_TARGET): | shared-instance-bundle-all
endif
