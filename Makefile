# PrintDeck: live panel for an Elegoo Centauri Carbon (SDCP over Wi-Fi), for iPad 1 (iOS 5.1.1, armv7).
THEOS ?= $(HOME)/theos
TARGET := iphone:clang:9.3:5.0
ARCHS := armv7
THEOS_DEVICE_IP ?= ipad
THEOS_PLATFORM_DEB_COMPRESSION_TYPE := gzip
INSTALL_TARGET_PROCESSES = PrintDeck

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PrintDeck
PrintDeck_FILES = main.m PDAppDelegate.m PDWebSocket.m PDDiscovery.m PDPrinter.m PDMJPEGView.m PDSparklineView.m PDViews.m PDPanels.m PDMainViewController.m
PrintDeck_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CFNetwork AudioToolbox
PrintDeck_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "su mobile -c uicache; sleep 1; su mobile -c 'uiopen printdeck://'"
