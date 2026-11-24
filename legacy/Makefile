# PrintDeck: live panel for an Elegoo Centauri Carbon (SDCP over Wi-Fi), for iPad 1 (iOS 5.1.1, armv7).
THEOS ?= $(HOME)/theos
TARGET := iphone:clang:9.3:5.0
ARCHS := armv7
THEOS_DEVICE_IP ?= ipad
THEOS_PLATFORM_DEB_COMPRESSION_TYPE := gzip
INSTALL_TARGET_PROCESSES = PrintDeck

include $(THEOS)/makefiles/common.mk

# The app's code is in Sources/, one folder per part of the app (App, Common, Printer, Dashboard, Viewers,
# Slice, Design). Every folder is on the include path, so #import "PDPrinter.h" works from anywhere.

APPLICATION_NAME = PrintDeck
PrintDeck_FILES = \
	Sources/App/main.m \
	Sources/App/PDAppDelegate.m \
	Sources/Printer/PDWebSocket.m \
	Sources/Printer/PDDiscovery.m \
	Sources/Printer/PDPrinter.m \
	Sources/Dashboard/PDMJPEGView.m \
	Sources/Dashboard/PDSparklineView.m \
	Sources/Dashboard/PDViews.m \
	Sources/Dashboard/PDPanels.m \
	Sources/Viewers/PDMesh.m \
	Sources/Viewers/PDMeshView.m \
	Sources/Dashboard/PDDetailView.m \
	Sources/Dashboard/PDCardPage.m \
	Sources/Viewers/PDToolpath.m \
	Sources/Viewers/PDToolpathView.m \
	Sources/Dashboard/PDFilesCard.m \
	Sources/Dashboard/PDCanvasView.m \
	Sources/Dashboard/PDScreenMirrorView.m \
	Sources/Slice/PDFilaments.m \
	Sources/Slice/PDSlicer.m \
	Sources/Slice/PDModelView.m \
	Sources/Slice/PDSlicePage.m \
	Sources/Design/PDCSG.c \
	Sources/Design/PDPrimitives.c \
	Sources/Design/PDParts.c \
	Sources/Design/PDDesign.m \
	Sources/Design/PDDesignView.m \
	Sources/Design/PDDesignPage.m \
	Sources/App/PDMainViewController.m
PrintDeck_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CFNetwork AudioToolbox GLKit OpenGLES
PrintDeck_CFLAGS = -fobjc-arc $(foreach d,$(wildcard Sources/*),-I$(d))

# The slicer: CuraEngine, built as a helper executable (engine/build.sh) and shipped inside PrintDeck.app;
# PDSlicer runs it as a child process.
before-all::
	@engine/build.sh

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@cp engine/build/CuraEngine $(THEOS_STAGING_DIR)/Applications/PrintDeck.app/CuraEngine
# Resources/ImportedPresets.plist holds the builder's own slicer presets (tools/import-user-presets.py, not in git).
# Development builds carry it; release builds (FINALPACKAGE=1) never do.
ifeq ($(FINALPACKAGE),1)
	@rm -f $(THEOS_STAGING_DIR)/Applications/PrintDeck.app/ImportedPresets.plist
endif

after-install::
	install.exec "su mobile -c uicache; sleep 1; su mobile -c 'uiopen printdeck://'"
