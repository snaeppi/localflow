// Tells SystemAudio whether something is playing. Not part of the Swift package: scripts/build-app.sh
// compiles it into Contents/Resources/NowPlaying.dylib, which /usr/bin/perl loads (see SystemAudio.swift).
//
// Why perl: since macOS 15.4 MediaRemote only answers Apple's own binaries when asked what is playing
// (sending commands still works from any process), and /usr/bin/perl is one of them.
// Prints {"playing":true,"pid":123} and nothing else; titles and other metadata are user data.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*PIDFn)(dispatch_queue_t, void (^)(int));

// Called by perl as an XS function (the signature is the interpreter and the CV); arguments unused.
void localflow_now_playing(void *interpreter, void *cv) {
    static NSString *const path = @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";
    void *framework = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    IsPlayingFn isPlaying = (IsPlayingFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    PIDFn playerPID = (PIDFn)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!isPlaying || !playerPID) { printf("{\"playing\":false,\"pid\":0}\n"); return; }

    dispatch_queue_t queue = dispatch_queue_create("io.github.snaeppi.localflow.now-playing", NULL);
    dispatch_group_t group = dispatch_group_create();
    __block Boolean playing = false;
    __block int pid = 0;
    dispatch_group_enter(group);
    isPlaying(queue, ^(Boolean value) { playing = value; dispatch_group_leave(group); });
    dispatch_group_enter(group);
    playerPID(queue, ^(int value) { pid = value; dispatch_group_leave(group); });
    // Bounded, so a stalled mediaremoted can't keep perl alive.
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    printf("{\"playing\":%s,\"pid\":%d}\n", playing ? "true" : "false", pid);
    fflush(stdout);
}
