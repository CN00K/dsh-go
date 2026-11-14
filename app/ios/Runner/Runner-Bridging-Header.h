//  Runner-Bridging-Header.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.2).
//
//  Exposes the iSH ObjC/C bridge to Swift (RootfsManager.swift and the
//  stage 2.3 channel layer). The original file only imported
//  GeneratedPluginRegistrant.h; the ISH imports below are additive.
//
//  BUILD NOTE: <sqlite3.h> requires linking libsqlite3.tbd, and the
//  ISH headers require HEADER_SEARCH_PATHS to include
//  IShArtifacts/include (see ISHKernel.h's build notes). Both are wired
//  in stage 4.

#import "GeneratedPluginRegistrant.h"

#import <sqlite3.h>

#import "ISHKernel.h"
#import "ISHShellExecutor.h"
#import "ISHFakefsMeta.h"
#import "ISHCrashHandler.h"
#import "ISHZip.h"
