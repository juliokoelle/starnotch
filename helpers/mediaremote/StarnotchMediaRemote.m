// Starnotch MediaRemote helper: what plays system-wide (any app, browsers included), and its
// controls. Since macOS 15.4 only Apple-signed processes may read MediaRemote, so the app never
// loads this library itself: it runs /usr/bin/perl, which macOS still lets through, and perl
// loads this library and calls one of the functions below (see MediaRemoteBridge.swift).
//
// The technique is the one described by mediaremote-adapter (github.com/ungive/mediaremote-adapter,
// BSD 3-Clause, (c) 2025 Jonas van den Berg and contributors); this file is a smaller rewrite for
// Starnotch's needs, not a copy. Everything stays on the Mac: the library only prints to stdout.
//
//   starnotch_mr_stream    one JSON object per line whenever the now-playing item changes,
//                          until stdin closes (the app quit) or SIGTERM; `artworkHash` in every
//                          line with a cover, `artwork` (base64) only when that hash changed
//   starnotch_mr_control   env STARNOTCH_MR_COMMAND (MRCommand id) or STARNOTCH_MR_SEEK (seconds)
//
// Build (scripts/build-app.sh): clang -dynamiclib -fobjc-arc -framework Foundation -framework AppKit

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (^MRInfoBlock)(NSDictionary *info);
typedef void (^MRPIDBlock)(int pid);
typedef void (^MRBoolBlock)(bool value);
typedef void (^MRClientBlock)(id client);

static void (*MRRegister)(dispatch_queue_t);
static void (*MRGetInfo)(dispatch_queue_t, MRInfoBlock);
static void (*MRGetPID)(dispatch_queue_t, MRPIDBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, MRBoolBlock);
static void (*MRGetClient)(dispatch_queue_t, MRClientBlock);
static bool (*MRSendCommand)(int, id);
static void (*MRSetElapsedTime)(double);

static bool load(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!lib) return false;
    MRRegister = dlsym(lib, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetInfo = dlsym(lib, "MRMediaRemoteGetNowPlayingInfo");
    MRGetPID = dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetIsPlaying = dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient = dlsym(lib, "MRMediaRemoteGetNowPlayingClient");
    MRSendCommand = dlsym(lib, "MRMediaRemoteSendCommand");
    MRSetElapsedTime = dlsym(lib, "MRMediaRemoteSetElapsedTime");
    return MRRegister && MRGetInfo && MRGetPID && MRGetIsPlaying && MRSendCommand;
}

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *string(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static NSNumber *number(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }

static dispatch_queue_t queue;
static NSUInteger lastArtworkHash;
static BOOL scheduled;

/// Reads everything MediaRemote knows and prints one snapshot; the artwork's data only when it changed.
static void snapshot(void) {
    __block NSDictionary *info;
    __block int pid = 0;
    __block bool playing = false;
    __block NSString *parent;
    __block NSString *clientID;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    MRGetInfo(queue, ^(NSDictionary *value) { info = value; dispatch_group_leave(group); });
    dispatch_group_enter(group);
    MRGetPID(queue, ^(int value) { pid = value; dispatch_group_leave(group); });
    dispatch_group_enter(group);
    MRGetIsPlaying(queue, ^(bool value) { playing = value; dispatch_group_leave(group); });
    if (MRGetClient) {
        dispatch_group_enter(group);
        MRGetClient(queue, ^(id client) {
            if ([client respondsToSelector:@selector(parentApplicationBundleIdentifier)])
                parent = string([client performSelector:@selector(parentApplicationBundleIdentifier)]);
            if ([client respondsToSelector:@selector(bundleIdentifier)])
                clientID = string([client performSelector:@selector(bundleIdentifier)]);
            dispatch_group_leave(group);
        });
    }
    // Callbacks arrive on `queue`, so wait on another thread's time, not this queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) return;
        dispatch_async(queue, ^{
            NSString *title = string(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            if (title.length == 0) {
                lastArtworkHash = 0;
                emit(@{ @"title": @"" });
                return;
            }
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"title"] = title;
            out[@"playing"] = @(playing);
            NSString *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
            if (app) out[@"bundleID"] = app;
            if (clientID) out[@"clientID"] = clientID;
            if (parent) out[@"parentID"] = parent;
            if (string(info[@"kMRMediaRemoteNowPlayingInfoArtist"])) out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            if (string(info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
            if (number(info[@"kMRMediaRemoteNowPlayingInfoDuration"])) out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
            if (number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
            if (number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);
            id identifier = info[@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier"] ?: info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"];
            if (identifier) out[@"id"] = [identifier description];
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
                NSUInteger hash = artwork.length ^ [[artwork subdataWithRange:NSMakeRange(0, MIN(artwork.length, 4096))] hash];
                // Every line names its cover; the data comes only when it changed, so the next
                // track of an album (same cover) finds it under the same hash in the app.
                out[@"artworkHash"] = [NSString stringWithFormat:@"%lx", (unsigned long)hash];
                if (hash != lastArtworkHash) {
                    lastArtworkHash = hash;
                    out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                }
            }
            emit(out);
        });
    });
}

/// Notifications come in bursts (title, then artist, then artwork): one snapshot per burst.
static void schedule(void) {
    dispatch_async(queue, ^{
        if (scheduled) return;
        scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), queue, ^{
            scheduled = NO;
            snapshot();
        });
    });
}

void starnotch_mr_stream(void) {
    if (!load()) {
        fprintf(stderr, "MediaRemote not available\n");
        exit(2);
    }
    signal(SIGTERM, SIG_DFL);
    queue = dispatch_queue_create("app.starnotch.mediaremote", DISPATCH_QUEUE_SERIAL);
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ];
    for (NSString *name in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { schedule(); }];
    }
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                                                                object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) { schedule(); }];
    MRRegister(queue);
    schedule();
    // A slow refresh catches seeks a player doesn't announce.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ schedule(); });
    dispatch_resume(timer);
    // The app holds our stdin open; when it goes away (even after a crash), so do we.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(input, ^{
        char buffer[256];
        if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
    });
    dispatch_resume(input);
    CFRunLoopRun();
}

void starnotch_mr_control(void) {
    if (!load()) exit(2);
    const char *command = getenv("STARNOTCH_MR_COMMAND");
    const char *seek = getenv("STARNOTCH_MR_SEEK");
    if (seek && MRSetElapsedTime) {
        MRSetElapsedTime(atof(seek));
    } else if (command) {
        int id = atoi(command);
        // Play, pause, toggle, stop, next, previous, back 15 s, ahead 15 s.
        if ((id >= 0 && id <= 5) || id == 12 || id == 13) MRSendCommand(id, nil);
    }
    // Give the command a moment to leave the process before it exits.
    usleep(100 * 1000);
}
