//
//  JITSupport.h
//  RetroArchiOS
//
//  Created by Yoshi Sugawara on 9/25/21.
//  Copyright © 2021 RetroArch. All rights reserved.
//

#ifndef JITSupport_h
#define JITSupport_h

#include <stdbool.h>

/* Gamuroid App Store build (2026-10-07): always returns false. No JIT, no private APIs
 * (csops/ptrace) and no jailbreak probing; see JITSupport.m. */
bool jit_available(void);

#endif /* JITSupport_h */
