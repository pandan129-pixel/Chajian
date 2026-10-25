TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = JBBPrefs
JBBPrefs_FILES = JBBRootListController.m JBBAppSettingsController.m JBBAppPickerController.m JBBTweakAppsController.m JBBPrefsCommon.m
JBBPrefs_FRAMEWORKS = UIKit
JBBPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
JBBPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
JBBPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/bundle.mk
