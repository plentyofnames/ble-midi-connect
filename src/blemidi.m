// blemidi — connect a BLE-MIDI device through macOS's own CoreMIDI Bluetooth
// driver, so it runs at the driver's low-latency connection instead of a
// third-party CoreBluetooth central's relaxed (~30 ms) default interval.
//
// Why this exists: a normal app that connects a BLE-MIDI keyboard with its own
// CBCentralManager and services the notifications itself gets macOS's default
// connection interval (~30 ms), which smears chords and backs up fast runs.
// Audio MIDI Setup avoids this by doing discovery/pairing and then HANDING THE
// CONNECTION OFF to the CoreMIDI Bluetooth driver (in midiserver), which owns
// the data path at a fast interval. This tool reproduces that handoff by driving
// Apple's own CoreAudioKit connection engine (AMSBTLEConnectionManager), then
// gets out of the way. See README.md for the full story.
//
// Commands:
//   blemidi list                  scan and print "UUID<TAB>NAME" for BLE-MIDI devices
//   blemidi status [UUID]         exit 0 if connected (online); prints all if no UUID
//   blemidi connect <UUID>        discovery + pairing, then hand off to the driver
//   blemidi disconnect <UUID>     ask the driver to drop the device
//
// `connect`/`list` use CoreBluetooth and need the launching app to hold a
// Bluetooth (TCC) grant; `status`/`disconnect` are CoreMIDI-only.

#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static const char *kCoreMIDIPath =
    "/System/Library/Frameworks/CoreMIDI.framework/CoreMIDI";
// Bundle id of the companion .app (see build.sh) — lets the app default to
// `connect` when LaunchServices launches it without a clean argv.
static NSString *const kAppBundleID = @"com.plentyofnames.blemidiconnect";

// --- private BLEMIDIAccessor: map between CoreMIDI device and BLE UUID -------

static Class accessorClass(void) { return NSClassFromString(@"BLEMIDIAccessor"); }

static MIDIDeviceRef deviceForUUID(NSString *uuid) {
    Class A = accessorClass(); if (!A || !uuid) return 0;
    typedef unsigned int (*Fn)(id, SEL, id);
    SEL sel = @selector(midiDeviceForUUID:);
    Fn fn = (Fn)class_getMethodImplementation(object_getClass(A), sel);
    return fn ? fn(A, sel, uuid) : 0;
}

static NSString *uuidForDevice(MIDIDeviceRef dev) {
    Class A = accessorClass(); if (!A || !dev) return nil;
    typedef id (*Fn)(id, SEL, unsigned int);
    SEL sel = @selector(uuidForMIDIDevice:);
    Fn fn = (Fn)class_getMethodImplementation(object_getClass(A), sel);
    id u = fn ? fn(A, sel, (unsigned int)dev) : nil;
    return [u description];
}

static bool deviceOnline(MIDIDeviceRef dev) {
    if (!dev) return false;
    SInt32 offline = 1;
    MIDIObjectGetIntegerProperty(dev, kMIDIPropertyOffline, &offline);
    return offline == 0;
}

static NSString *deviceName(MIDIDeviceRef d) {
    CFStringRef nm = NULL;
    MIDIObjectGetStringProperty(d, kMIDIPropertyName, &nm);
    NSString *s = nm ? [(__bridge NSString *)nm copy] : @"?";
    if (nm) CFRelease(nm);
    return s;
}

static NSArray<NSNumber *> *bleDevices(void) {
    NSMutableArray *r = [NSMutableArray array];
    for (ItemCount i = 0; i < MIDIGetNumberOfDevices(); i++) {
        MIDIDeviceRef d = MIDIGetDevice(i);
        CFStringRef drv = NULL;
        MIDIObjectGetStringProperty(d, kMIDIPropertyDriverOwner, &drv);
        bool ble = drv && CFStringFind(drv, CFSTR("Bluetooth"), 0).location != kCFNotFound;
        if (drv) CFRelease(drv);
        if (ble) [r addObject:@(d)];
    }
    return r;
}

// --- status / disconnect (CoreMIDI only) ------------------------------------

static int doStatus(NSString *uuid) {
    if (uuid) {
        bool on = deviceOnline(deviceForUUID(uuid));
        printf("%s\n", on ? "connected" : "disconnected");
        return on ? 0 : 1;
    }
    bool any = false;
    for (NSNumber *n in bleDevices()) {
        MIDIDeviceRef d = (MIDIDeviceRef)n.unsignedIntValue;
        NSString *nm = deviceName(d);
        if ([nm isEqualToString:@"Bluetooth"]) continue; // driver control device
        bool on = deviceOnline(d);
        NSString *u = uuidForDevice(d) ?: @"?";
        printf("%s\t%s\t%s\n", on ? "connected" : "disconnected", u.UTF8String, nm.UTF8String);
        any |= on;
    }
    return any ? 0 : 1;
}

static int doDisconnect(NSString *uuid) {
    if (!uuid) { fprintf(stderr, "disconnect requires a UUID\n"); return 64; }
    void *h = dlopen(kCoreMIDIPath, RTLD_NOW);
    typedef OSStatus (*Fn)(CFStringRef);
    Fn fn = h ? (Fn)dlsym(h, "MIDIBluetoothDriverDisconnect") : NULL;
    if (!fn) { fprintf(stderr, "MIDIBluetoothDriverDisconnect unavailable\n"); return 2; }
    OSStatus rc = fn((__bridge CFStringRef)uuid);
    return rc == noErr ? 0 : 1;
}

// --- connect / list (CoreBluetooth via CoreAudioKit) ------------------------

@interface Stub : NSObject @end
@implementation Stub
- (void)setUIEnabled:(BOOL)e {}
- (void)setBadPluginList:(id)l {}
- (void)updatePeripheralTable {}
@end

static id makeManager(void) {
    Class C = NSClassFromString(@"AMSBTLEConnectionManager");
    if (!C) return nil;
    // AMSBTLEConnectionManager keeps a NON-owning reference to its UI controller,
    // so the stub must outlive the manager. Hold it in a process-lifetime static;
    // otherwise ARC frees it when this function returns and the manager messages a
    // dangling pointer from centralManagerDidUpdateState: (use-after-free / SIGSEGV).
    static Stub *stub = nil;
    if (!stub) stub = [Stub new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id mgr = [[C alloc] performSelector:@selector(initWithUIController:) withObject:stub];
    [mgr performSelector:@selector(startScan)];
#pragma clang diagnostic pop
    return mgr;
}

static NSString *peripheralName(id p) {
    @try {
        id n = [p valueForKey:@"name"];
        if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    } @catch (NSException *e) {}
    return @"";
}

static int doList(void) {
    id mgr = makeManager();
    if (!mgr) { fprintf(stderr, "AMSBTLEConnectionManager unavailable\n"); return 2; }
    NSMutableSet *seen = [NSMutableSet set];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        for (id p in [mgr valueForKey:@"peripheralList"]) {
            NSString *u = [[p valueForKey:@"uuid"] description];
            if (u && ![seen containsObject:u]) {
                [seen addObject:u];
                printf("%s\t%s\n", u.UTF8String, peripheralName(p).UTF8String);
                fflush(stdout);
            }
        }
    }];
    [NSTimer scheduledTimerWithTimeInterval:6.0 repeats:NO block:^(NSTimer *t) {
        CFRunLoopStop(CFRunLoopGetCurrent());
    }];
    CFRunLoopRun();
    return 0;
}

static int doConnect(NSString *uuid) {
    if (!uuid) { fprintf(stderr, "connect requires a UUID\n"); return 64; }
    if (deviceOnline(deviceForUUID(uuid))) { fprintf(stderr, "already online\n"); return 0; }
    id mgr = makeManager();
    if (!mgr) { fprintf(stderr, "AMSBTLEConnectionManager unavailable\n"); return 2; }

    __block bool issued = false;
    NSString *want = uuid.uppercaseString;
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        if (deviceOnline(deviceForUUID(uuid))) { CFRunLoopStop(CFRunLoopGetCurrent()); return; }
        for (id p in [mgr valueForKey:@"peripheralList"]) {
            NSString *u = [[p valueForKey:@"uuid"] description].uppercaseString;
            if (u && [u isEqualToString:want] && !issued) {
                issued = true;
                fprintf(stderr, "issuing connect to %s\n", u.UTF8String);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                if ([p respondsToSelector:@selector(connect)]) [p performSelector:@selector(connect)];
#pragma clang diagnostic pop
            }
        }
    }];
    [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:NO block:^(NSTimer *t) {
        CFRunLoopStop(CFRunLoopGetCurrent());
    }];
    CFRunLoopRun();
    return deviceOnline(deviceForUUID(uuid)) ? 0 : 1;
}

// --- probe: three-state availability via a short scan, cached to a file ------
// Writes "connected" / "available" / "off" (or "unknown") to
// /tmp/blemidi-<UUID>.state so a menu-bar plugin can show it without doing its
// own (permission-gated) Bluetooth scan. Run this from the signed .app.

static NSString *stateFilePath(NSString *uuid) {
    return [NSString stringWithFormat:@"/tmp/blemidi-%@.state", uuid.uppercaseString];
}

static int doProbe(NSString *uuid) {
    if (!uuid) { fprintf(stderr, "probe requires a UUID\n"); return 64; }
    NSString *state;
    if (deviceOnline(deviceForUUID(uuid))) {
        state = @"connected";
    } else {
        id mgr = makeManager();
        if (!mgr) {
            state = @"unknown";
        } else {
            __block bool available = false;
            NSString *want = uuid.uppercaseString;
            // A peripheral can be in peripheralList just because the system *knows*
            // it, not because it's advertising right now. The wrapper's isAvailable
            // flag is only set on didDiscoverPeripheral, so it — not mere list
            // membership — is the real "keyboard is on and reachable" signal.
            [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
                for (id p in [mgr valueForKey:@"peripheralList"]) {
                    NSString *u = [[p valueForKey:@"uuid"] description].uppercaseString;
                    if (u && [u isEqualToString:want] && [[p valueForKey:@"isAvailable"] boolValue]) {
                        available = true; CFRunLoopStop(CFRunLoopGetCurrent()); return;
                    }
                }
            }];
            [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer *t) {
                CFRunLoopStop(CFRunLoopGetCurrent());
            }];
            CFRunLoopRun();
            state = available ? @"available" : @"off";
        }
    }
    [state writeToFile:stateFilePath(uuid) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("%s\n", state.UTF8String);
    return 0;
}

// --- main -------------------------------------------------------------------

static bool isUUID(NSString *s) {
    return [[NSUUID alloc] initWithUUIDString:s] != nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Robust parse: pick the first recognized verb and the first UUID-shaped
        // token anywhere in argv (LaunchServices can inject extra args).
        NSString *cmd = nil, *uuid = nil;
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            NSString *al = a.lowercaseString;
            if (!cmd && ([al isEqualToString:@"list"] || [al isEqualToString:@"status"]
                         || [al isEqualToString:@"connect"] || [al isEqualToString:@"disconnect"]
                         || [al isEqualToString:@"probe"])) {
                cmd = al;
            } else if (!uuid && isUUID(a)) {
                uuid = a.uppercaseString;
            }
        }
        if (!cmd) {
            BOOL isApp = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:kAppBundleID];
            cmd = isApp ? (uuid ? @"connect" : @"list") : @"status";
        }

        if ([cmd isEqualToString:@"list"]) return doList();
        if ([cmd isEqualToString:@"status"]) return doStatus(uuid);
        if ([cmd isEqualToString:@"connect"]) return doConnect(uuid);
        if ([cmd isEqualToString:@"disconnect"]) return doDisconnect(uuid);
        if ([cmd isEqualToString:@"probe"]) return doProbe(uuid);

        fprintf(stderr, "usage: blemidi list | status [UUID] | probe <UUID> | connect <UUID> | disconnect <UUID>\n");
        return 64;
    }
}
