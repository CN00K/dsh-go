//  Runner-Bridging-Header.h
//  dsh-go — native bridge layer.
//
//  Exposes the iSH ObjC/C bridge to Swift (RootfsManager.swift and the
//  stage 2.3 channel layer) alongside the upstream phone self-runner
//  header. The ISH imports below are additive (feat, stage 2.2).
//
//  BUILD NOTE: <sqlite3.h> requires linking libsqlite3.tbd, and the
//  ISH headers require HEADER_SEARCH_PATHS to include
//  IShArtifacts/include (see ISHKernel.h's build notes). Both are wired
//  in stage 4.

#import "GeneratedPluginRegistrant.h"
#import "../../../tooling/ios/phone-self-runner/include/dsh_phone_self_runner.h"

#import <sqlite3.h>

#import "ISHKernel.h"
#import "ISHShellExecutor.h"
#import "ISHFakefsMeta.h"
#import "ISHCrashHandler.h"
#import "ISHZip.h"
