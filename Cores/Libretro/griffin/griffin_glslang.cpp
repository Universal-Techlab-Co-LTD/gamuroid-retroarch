
/*
 * Symbol visibility: this file is compiled with per-file compiler flags
 * -fvisibility=hidden -fvisibility-inlines-hidden (set in the Xcode
 * project's PBXBuildFile settings for griffin_glslang.cpp).
 *
 * Unlike #pragma GCC visibility push(hidden) — which overrides ALL
 * declarations including system headers (std::string, etc.) and causes
 * linker fixup errors — the compiler flag only hides symbols that lack
 * an explicit visibility attribute.  System/libc++ headers use
 * __attribute__((visibility("default"))) on their public API, so those
 * symbols remain visible while glslang-specific symbols become hidden.
 *
 * Why this matters:
 * Both the main executable (this file) and GamuDolphin.framework link
 * their own copy of glslang.  C++ weak/template/inline symbols
 * (TPoolAllocator::allocate, TIntermNode::operator new, template
 * instantiations of TIntermediate::addSwizzle) would normally leak
 * into the global namespace and get coalesced by the dynamic linker.
 * GamuDolphin's emu-thread then calls the coalesced (Libretro) copy
 * whose thread-local TPoolAllocator is uninitialised → crash.
 *
 * With -fvisibility=hidden, these glslang symbols are not exported,
 * so GamuDolphin.framework resolves its own internal copy instead.
 */
#ifdef WANT_GLSLANG

#ifdef _MSC_VER
#include <compat/msvc.h>
#ifdef strtoull
#undef strtoull
#endif
#endif

#include "../gfx/drivers_shader/glslang.cpp"
#include "../deps/glslang/glslang/SPIRV/GlslangToSpv.cpp"
#include "../deps/glslang/glslang/SPIRV/InReadableOrder.cpp"
#include "../deps/glslang/glslang/SPIRV/Logger.cpp"
#include "../deps/glslang/glslang/SPIRV/SpvBuilder.cpp"

#include "../deps/glslang/glslang/glslang/GenericCodeGen/CodeGen.cpp"
#include "../deps/glslang/glslang/glslang/GenericCodeGen/Link.cpp"

#include "../deps/glslang/glslang/OGLCompilersDLL/InitializeDll.cpp"

#include "../deps/glslang/glslang/glslang/MachineIndependent/attribute.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/Constant.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/glslang_tab.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/InfoSink.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/Initialize.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/Intermediate.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/intermOut.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/IntermTraverse.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/iomapper.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/limits.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/linkValidate.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/parseConst.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/ParseContextBase.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/ParseHelper.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/PoolAlloc.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/propagateNoContraction.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/reflection.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/RemoveTree.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/Scan.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/ShaderLang.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/SymbolTable.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/Versions.cpp"

#include "../deps/glslang/glslang/glslang/MachineIndependent/preprocessor/Pp.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/preprocessor/PpAtom.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/preprocessor/PpContext.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/preprocessor/PpScanner.cpp"
#include "../deps/glslang/glslang/glslang/MachineIndependent/preprocessor/PpTokens.cpp"

#ifdef __APPLE__
#include "../deps/glslang/glslang/glslang/OSDependent/Unix/ossource.cpp"
#endif

#endif
