# Uses the selected Xcode; override with XCODE_PATH=/path/to/Xcode.app.
XCODE_PATH ?= $(patsubst %/Contents/Developer,%,$(shell xcode-select -p))
SDK_PRIVATE_FRAMEWORKS := $(XCODE_PATH)/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks
BUILD_DIR := build
SOURCES_DIR := Sources
GLUE := $(BUILD_DIR)/mercury_glue.o $(BUILD_DIR)/mercury_abi.o \
        $(BUILD_DIR)/universalhid_glue.o $(BUILD_DIR)/universalhid_abi.o \
        $(BUILD_DIR)/uhid_request_abi.o

DEVICE_LDFLAGS = -Xlinker -rpath -Xlinker /Library/Apple/System/Library/PrivateFrameworks \
	-F/Library/Developer/PrivateFrameworks \
	-F/Library/Developer/PrivateFrameworks/CoreDevice.framework/Frameworks \
	-F/Library/Apple/System/Library/PrivateFrameworks \
	-F$(SDK_PRIVATE_FRAMEWORKS) \
	-framework Foundation -framework CoreFoundation \
	-framework CoreDevice -framework CoreDeviceUtilities \
	-framework RemoteXPC -framework Mercury -framework UniversalHID

.PHONY: all clean
all: $(BUILD_DIR)/libLayerLensDevice.dylib $(BUILD_DIR)/lease-guardian

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/%.o: $(SOURCES_DIR)/%.S | $(BUILD_DIR)
	clang -c $< -o $@

$(BUILD_DIR)/%.o: $(SOURCES_DIR)/%.swift | $(BUILD_DIR)
	swiftc -parse-as-library -c $< -o $@

$(BUILD_DIR)/native_bridge.o: $(SOURCES_DIR)/native_bridge.m $(SOURCES_DIR)/native_bridge.h $(SOURCES_DIR)/bounded_sender.h $(SOURCES_DIR)/display_geometry.h $(SOURCES_DIR)/device_control.h $(SOURCES_DIR)/keyboard_input.h | $(BUILD_DIR)
	clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -c $< -o $@

$(BUILD_DIR)/libLayerLensDevice.dylib: $(BUILD_DIR)/native_bridge.o $(GLUE) Makefile
	swiftc -emit-library $(filter %.o,$^) -o $@ $(DEVICE_LDFLAGS) -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -Xlinker -undefined -Xlinker dynamic_lookup

$(BUILD_DIR)/lease-guardian: $(SOURCES_DIR)/lease_guardian.c | $(BUILD_DIR)
	clang -Wall -Wextra -Werror -O2 $< -o $@

clean:
	rm -rf $(BUILD_DIR)
