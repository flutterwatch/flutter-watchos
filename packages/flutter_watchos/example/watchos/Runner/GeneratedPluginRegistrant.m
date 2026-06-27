//
//  Generated file. Do not edit.
//

#import "GeneratedPluginRegistrant.h"


// FFI plugins resolve their C symbols at runtime via dlsym
// (DynamicLibrary.process()), so nothing in the compiled app references
// them. When such a plugin is linked statically through the generated
// Swift Package Manager umbrella, the linker would drop its unreferenced
// archive member and the symbols would be absent from the binary. The
// references that prevent that are emitted inside the (always-linked,
// always-reachable) registerWithRegistry: method below — see
// _renderFfiForcedReferenceBody. Forward declarations:
extern void flutter_watchos_is_watchos(void);
extern void flutter_watchos_system_version(void);
extern void flutter_watchos_device_model(void);
extern void flutter_watchos_machine_id(void);
extern void flutter_watchos_is_simulator(void);
extern void flutter_watchos_screen_width(void);
extern void flutter_watchos_screen_height(void);
extern void flutter_watchos_screen_scale(void);
extern void flutter_watchos_play_haptic(void);
extern void flutter_watchos_crown_mode(void);
extern void flutter_watchos_crown_set_mode(void);
extern void flutter_watchos_crown_push_delta(void);
extern void flutter_watchos_crown_consume_delta(void);

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {

  // Force the linker to keep the statically-linked FFI plugin archive
  // member(s); see the file-scope note above.
  const void *_flutterWatchosFfiForcedReferences[] = {
    (const void *)&flutter_watchos_is_watchos,
    (const void *)&flutter_watchos_system_version,
    (const void *)&flutter_watchos_device_model,
    (const void *)&flutter_watchos_machine_id,
    (const void *)&flutter_watchos_is_simulator,
    (const void *)&flutter_watchos_screen_width,
    (const void *)&flutter_watchos_screen_height,
    (const void *)&flutter_watchos_screen_scale,
    (const void *)&flutter_watchos_play_haptic,
    (const void *)&flutter_watchos_crown_mode,
    (const void *)&flutter_watchos_crown_set_mode,
    (const void *)&flutter_watchos_crown_push_delta,
    (const void *)&flutter_watchos_crown_consume_delta,
  };
  for (unsigned long _i = 0;
       _i < sizeof(_flutterWatchosFfiForcedReferences) / sizeof(_flutterWatchosFfiForcedReferences[0]);
       _i++) {
    __asm__ volatile("" : : "r"(_flutterWatchosFfiForcedReferences[_i]));
  }
}

@end
