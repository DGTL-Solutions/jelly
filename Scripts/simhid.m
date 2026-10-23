// simhid UDID key [key …] — sends hardware-keyboard presses to a booted simulator (tvOS: arrows = remote, select = Return, menu = Escape).
// Keys: up down left right select menu playpause, wait (0.5 s pause), or sleep:<seconds>.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef void *(*KeyMessage)(uint32_t keyCode, uint32_t direction);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: simhid UDID key…\n"); return 2; }
        NSString *developer = @"/Applications/Xcode-27.1.0.app/Contents/Developer";
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        void *kit = dlopen("/Applications/Xcode-27.1.0.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
        if (!kit) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        KeyMessage keyMessage = (KeyMessage)dlsym(kit, "IndigoHIDMessageForKeyboardArbitrary");
        if (!keyMessage) { fprintf(stderr, "no IndigoHIDMessageForKeyboardArbitrary\n"); return 1; }
        NSError *error = nil;
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"),
            NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), developer, &error);
        id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
        id device = nil;
        for (id candidate in [set valueForKey:@"devices"]) {
            if ([[[candidate valueForKey:@"UDID"] UUIDString] isEqualToString:@(argv[1])]) device = candidate;
        }
        if (!device) { fprintf(stderr, "device not found (%s)\n", error.description.UTF8String); return 1; }
        Class clientClass = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient");
        if (!clientClass) { fprintf(stderr, "no SimDeviceLegacyHIDClient\n"); return 1; }
        id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([clientClass alloc], NSSelectorFromString(@"initWithDevice:error:"), device, &error);
        if (!client) { fprintf(stderr, "hid client: %s\n", error.description.UTF8String); return 1; }
        NSDictionary<NSString *, NSNumber *> *codes = @{ @"right": @0x4F, @"left": @0x50, @"down": @0x51, @"up": @0x52,
                                                       @"select": @0x28, @"menu": @0x29, @"playpause": @0x2C };
        dispatch_queue_t queue = dispatch_queue_create("simhid", DISPATCH_QUEUE_SERIAL);
        SEL send = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
        for (int index = 2; index < argc; index++) {
            NSString *name = @(argv[index]);
            if ([name isEqualToString:@"wait"]) { usleep(500000); continue; }
            if ([name hasPrefix:@"sleep:"]) { usleep((useconds_t)([[name substringFromIndex:6] doubleValue] * 1e6)); continue; }
            NSNumber *code = codes[name];
            if (!code) { fprintf(stderr, "unknown key %s\n", argv[index]); return 2; }
            for (uint32_t direction = 1; direction <= 2; direction++) {
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                ((void (*)(id, SEL, void *, BOOL, dispatch_queue_t, void (^)(NSError *)))objc_msgSend)(client, send,
                    keyMessage(code.unsignedIntValue, direction), YES, queue, ^(NSError *sendError) {
                        if (sendError) fprintf(stderr, "send: %s\n", sendError.description.UTF8String);
                        dispatch_semaphore_signal(done);
                    });
                dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
                usleep(60000);
            }
            usleep(350000);
        }
    }
    return 0;
}
