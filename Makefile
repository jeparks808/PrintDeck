# PrintDeck: live panel for an Elegoo Centauri Carbon (SDCP over Wi-Fi), for iPad 1 (iOS 5.1.1, armv7).
THEOS ?= $(HOME)/theos
TARGET := iphone:clang:9.3:5.0
ARCHS := armv7
THEOS_DEVICE_IP ?= ipad
THEOS_PLATFORM_DEB_COMPRESSION_TYPE := gzip
INSTALL_TARGET_PROCESSES = PrintDeck

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PrintDeck
PrintDeck_FILES = main.m PDAppDelegate.m PDWebSocket.m PDDiscovery.m PDPrinter.m PDMJPEGView.m PDSparklineView.m PDViews.m PDPanels.m PDMesh.m PDMeshView.m PDDetailView.m PDCardPage.m PDToolpath.m PDToolpathView.m PDFilesCard.m PDCanvasView.m PDScreenMirrorView.m PDFilaments.m PDSlicer.m PDModelView.m PDSlicePage.m PDCSG.c PDPrimitives.c PDParts.c PDDesign.m PDDesignView.m PDDesignPage.m PDMainViewController.m
PrintDeck_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CFNetwork AudioToolbox GLKit OpenGLES
PrintDeck_CFLAGS = -fobjc-arc

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
