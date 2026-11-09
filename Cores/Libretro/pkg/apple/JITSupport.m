//
//  JITSupport.m
//  RetroArchiOS
//
//  Created by Yoshi Sugawara on 9/25/21.
//  Copyright © 2021 RetroArch. All rights reserved.
//
//  Copied from UTMApp, original author: osy
//
//  2026-10-07 (Gamuroid, App Review): this App Store build never uses JIT and must not call private
//  APIs. The csops()/ptrace() declarations and calls, the CS_DEBUGGED check, the PT_TRACE_ME
//  "ptrace hack" with its Mach exception handler, and the jailbreak probing (/Applications,
//  pspawn_payload, dlsym "jbdswDebugMe") were removed. jit_available() keeps its name and
//  signature for the RetroArch callers (runloop.c, menu_displaylist.c) and always reports "no JIT".
//

#import <Foundation/Foundation.h>

#import "JITSupport.h"

/// Always false: JIT is never available in this App Store build (no private APIs, no JIT).
bool jit_available(void)
{
   return false;
}
