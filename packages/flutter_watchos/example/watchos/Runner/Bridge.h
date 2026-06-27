#ifndef RUNNER_BRIDGE_H_
#define RUNNER_BRIDGE_H_

#include <stdint.h>
#include "flutter_embedder.h"

// Raw Digital Crown bridge — defined in the statically-linked flutter_watchos
// package (flutter_watchos_ffi). The host reads the routing mode on each crown
// sample and, in raw mode, pushes the rotation for a Dart app to consume via
// WatchCrown.
int32_t flutter_watchos_crown_mode(void);
void flutter_watchos_crown_push_delta(double delta);

#endif  // RUNNER_BRIDGE_H_
