// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter_watchos_ffi.h"
#import <WatchKit/WatchKit.h>
#import <TargetConditionals.h>
#include <sys/sysctl.h>
#include <string.h>

// Static buffers for string results (device info doesn't change at runtime).
static char s_system_version[64] = {0};
static char s_device_model[128] = {0};
static char s_machine_id[64] = {0};
static bool s_initialized = false;

static void _ensure_initialized(void) {
    if (s_initialized) return;
    s_initialized = true;

    @autoreleasepool {
        WKInterfaceDevice *device = [WKInterfaceDevice currentDevice];

        NSString *version = [device systemVersion];
        if (version) {
            strncpy(s_system_version, [version UTF8String], sizeof(s_system_version) - 1);
        }

        NSString *model = [device model];
        if (model) {
            strncpy(s_device_model, [model UTF8String], sizeof(s_device_model) - 1);
        }

        // Machine identifier (e.g., "Watch7,1"). On the simulator `hw.machine`
        // reports the host Mac's arch ("arm64"/"x86_64"), so prefer the model id
        // the simulator advertises via its environment.
#if TARGET_OS_SIMULATOR
        const char *simModel = getenv("SIMULATOR_MODEL_IDENTIFIER");
        if (simModel && simModel[0] != '\0') {
            strncpy(s_machine_id, simModel, sizeof(s_machine_id) - 1);
        }
#endif
        if (s_machine_id[0] == '\0') {
            size_t size = 0;
            sysctlbyname("hw.machine", NULL, &size, NULL, 0);
            if (size > 0 && size < sizeof(s_machine_id)) {
                sysctlbyname("hw.machine", s_machine_id, &size, NULL, 0);
            }
        }
    }
}

bool flutter_watchos_is_watchos(void) {
#if TARGET_OS_WATCH
    return true;
#else
    return false;
#endif
}

const char* flutter_watchos_system_version(void) {
    _ensure_initialized();
    return s_system_version;
}

const char* flutter_watchos_device_model(void) {
    _ensure_initialized();
    return s_device_model;
}

const char* flutter_watchos_machine_id(void) {
    _ensure_initialized();
    return s_machine_id;
}

bool flutter_watchos_is_simulator(void) {
#if TARGET_OS_SIMULATOR
    return true;
#else
    return false;
#endif
}

int32_t flutter_watchos_screen_width(void) {
    @autoreleasepool {
        WKInterfaceDevice *device = [WKInterfaceDevice currentDevice];
        return (int32_t)(device.screenBounds.size.width * device.screenScale);
    }
}

int32_t flutter_watchos_screen_height(void) {
    @autoreleasepool {
        WKInterfaceDevice *device = [WKInterfaceDevice currentDevice];
        return (int32_t)(device.screenBounds.size.height * device.screenScale);
    }
}

float flutter_watchos_screen_scale(void) {
    @autoreleasepool {
        return (float)[WKInterfaceDevice currentDevice].screenScale;
    }
}

void flutter_watchos_play_haptic(int32_t type) {
#if TARGET_OS_WATCH
    // WKInterfaceDevice.playHaptic is a WatchKit UI API and must run on the main
    // thread. This is reached over dart:ffi, which runs synchronously on the
    // Flutter UI/isolate thread — NOT the main thread — so calling playHaptic
    // directly here makes the Taptic Engine drop or weakly fire the haptic (it
    // "feels off"). Hop to the main queue so it plays reliably and at full
    // strength. async (not sync) to avoid blocking the isolate / deadlock risk.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WKInterfaceDevice currentDevice] playHaptic:(WKHapticType)type];
    });
#else
    (void)type;
#endif
}
