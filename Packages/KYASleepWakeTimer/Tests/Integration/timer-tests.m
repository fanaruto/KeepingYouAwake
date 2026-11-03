#import <Cocoa/Cocoa.h>
#import <KYASleepWakeTimer/KYASleepWakeTimer.h>
#import <unistd.h>

// These integration checks launch only caffeinate -i. They never sleep a display,
// change pmset settings, or request administrator privileges.
static BOOL WaitFor(NSTimeInterval timeout, BOOL (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if(condition()) return YES;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while(deadline.timeIntervalSinceNow > 0);
    return condition();
}

static NSUInteger CaffeinateChildren(void)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pgrep"];
    task.arguments = @[@"-P", [NSString stringWithFormat:@"%d", getpid()], @"-x", @"caffeinate"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    [task launchAndReturnError:NULL];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     componentsSeparatedByString:@"\n"];
    return text.length == 0 ? 0 : lines.count;
}

@interface TimerDelegate : NSObject <KYASleepWakeTimerDelegate>
@property(nonatomic) NSUInteger deactivations;
@end
@implementation TimerDelegate
- (void)sleepWakeTimerDidDeactivate:(KYASleepWakeTimer *)timer
{
    self.deactivations += 1;
}
@end

#define CHECK(condition, message) do { \
    if(!(condition)) { fprintf(stderr, "FAIL: %s\n", message); return NO; } \
} while(0)

static BOOL TestNaturalExpiration(void)
{
    KYASleepWakeTimer *timer = [KYASleepWakeTimer new];
    __block BOOL finished = NO;
    __block BOOL cancelled = YES;
    [timer scheduleWithTimeInterval:1 completion:^(BOOL wasCancelled) {
        cancelled = wasCancelled;
        finished = YES;
    }];
    CHECK(timer.scheduled, "timed caffeinate starts");
    CHECK(timer.fireDate != nil, "timed session exposes expiration");
    CHECK(CaffeinateChildren() == 1, "timed session owns one real caffeinate child");
    CHECK(WaitFor(4, ^BOOL{ return finished; }), "caffeinate -t expires without manual invalidation");
    CHECK(!cancelled && !timer.scheduled, "natural expiration reports cancelled=NO");
    CHECK(timer.fireDate == nil, "natural expiration clears expiration date");
    CHECK(WaitFor(1, ^BOOL{ return CaffeinateChildren() == 0; }), "expired child is reaped");
    puts("PASS: real timed expiration");
    return YES;
}

static BOOL TestInvalidationCleanup(void)
{
    KYASleepWakeTimer *timer = [KYASleepWakeTimer new];
    __block BOOL finished = NO;
    __block BOOL cancelled = NO;
    [timer scheduleWithTimeInterval:KYASleepWakeTimeIntervalIndefinite completion:^(BOOL wasCancelled) {
        cancelled = wasCancelled;
        finished = YES;
    }];
    CHECK(timer.scheduled && timer.fireDate == nil, "indefinite session has no expiration");
    CHECK(CaffeinateChildren() == 1, "indefinite session owns one child");
    [timer invalidate];
    CHECK(WaitFor(2, ^BOOL{ return finished && CaffeinateChildren() == 0; }), "invalidate terminates its child");
    CHECK(cancelled && !timer.scheduled, "invalidate reports cancellation");
    puts("PASS: invalidate cleans up real child");
    return YES;
}

static BOOL TestRestartIsolation(void)
{
    KYASleepWakeTimer *timer = [KYASleepWakeTimer new];
    TimerDelegate *delegate = [TimerDelegate new];
    timer.delegate = delegate;
    __block NSUInteger oldCompletions = 0;
    __block NSUInteger newCompletions = 0;
    __block BOOL newCancelled = NO;
    [timer scheduleWithTimeInterval:1 completion:^(BOOL cancelled) { oldCompletions += 1; }];
    // Leave the main queue idle while the real child expires, so its termination
    // callback competes with the invalidate/restart performed below.
    usleep(1250000);
    [timer invalidate];
    [timer scheduleWithTimeInterval:KYASleepWakeTimeIntervalIndefinite completion:^(BOOL cancelled) {
        newCompletions += 1;
        newCancelled = cancelled;
    }];
    CHECK(WaitFor(2, ^BOOL{ return oldCompletions == 1; }), "old completion is delivered once");
    CHECK(timer.scheduled && timer.fireDate == nil, "stale task exit does not cancel replacement");
    CHECK(newCompletions == 0, "old cancellation does not invoke replacement completion");
    CHECK(delegate.deactivations == 0, "stale deactivation does not mark active replacement inactive");
    CHECK(WaitFor(1, ^BOOL{ return CaffeinateChildren() == 1; }), "restart leaves only the replacement child");
    [timer invalidate];
    CHECK(WaitFor(2, ^BOOL{ return newCompletions == 1 && CaffeinateChildren() == 0; }), "replacement cancels once and cleans up");
    CHECK(newCancelled, "replacement cancellation is reported to its own completion");
    puts("PASS: immediate restart isolates callbacks and child lifetime");
    return YES;
}

int main(void)
{
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *arguments = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [NSMutableDictionary dictionary];
        arguments[KYAUserDefaultsKeyAllowDisplaySleep] = @YES;
        [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
        if(!TestNaturalExpiration() || !TestInvalidationCleanup() || !TestRestartIsolation()) return 1;
        puts("All sleep/wake timer integration checks passed.");
    }
    return 0;
}
