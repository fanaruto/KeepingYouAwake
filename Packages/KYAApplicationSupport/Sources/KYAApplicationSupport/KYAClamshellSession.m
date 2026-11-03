#import <KYAApplicationSupport/KYAClamshellSession.h>
#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import "KYAClamshellWatchdog.inc"

NSNotificationName const KYAClamshellSessionDidStopNotification = @"KYAClamshellSessionDidStopNotification";
NSString * const KYAClamshellSessionErrorDomain = @"KYAClamshellSessionErrorDomain";

static NSString *KYAShellQuote(NSString *text)
{
    return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSError *KYAClamshellError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:KYAClamshellSessionErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * _Nullable KYARunTask(NSString *path, NSArray<NSString *> *arguments, NSError **error)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"LC_ALL"] = @"C";
    task.environment = environment;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if(![task launchAndReturnError:error]) return nil;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if(task.terminationStatus != 0)
    {
        if(error != NULL)
        {
            BOOL cancelled = [text containsString:@"(-128)"];
            *error = KYAClamshellError(cancelled ? NSUserCancelledError : task.terminationStatus,
                                      cancelled ? @"已取消管理员授权，未开启合盖运行。" :
                                      [NSString stringWithFormat:@"系统授权未完成：%@", text]);
        }
        return nil;
    }
    return text;
}

@interface KYAClamshellSession ()
@property(nonatomic) dispatch_queue_t workQueue;
@property(nonatomic, nullable) dispatch_source_t monitor;
@property(atomic, nullable) NSURL *sessionDirectory;
@end

@implementation KYAClamshellSession

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        _workQueue = dispatch_queue_create("com.webfooo.KeepingYouAwake.clamshell", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isActive
{
    NSURL *directory = self.sessionDirectory;
    if(directory == nil) return NO;
    if([NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"done"].path]) return NO;
    NSString *ready = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:@"ready"]
                                              encoding:NSUTF8StringEncoding error:NULL];
    pid_t watchdogPID = (pid_t)ready.longLongValue;
    if(watchdogPID <= 1) return NO;
    return kill(watchdogPID, 0) == 0 || errno == EPERM;
}

- (BOOL)restorationRequired
{
    NSURL *directory = self.sessionDirectory;
    if(directory == nil) return NO;
    NSString *done = [self marker:@"done"];
    if([done isEqualToString:@"error:restore"]) return YES;
    if(done != nil) return NO;
    NSString *owned = [self marker:@"owned"];
    pid_t watchdogPID = (pid_t)owned.longLongValue;
    return watchdogPID > 1 && kill(watchdogPID, 0) != 0 && errno != EPERM;
}

- (void)dealloc
{
    if(_monitor != nil) dispatch_source_cancel(_monitor);
    if(_sessionDirectory != nil)
    {
        // The watchdog performs restoration even when this object or the app exits.
        [@"stop" writeToURL:[_sessionDirectory URLByAppendingPathComponent:@"stop"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

- (void)complete:(void (^)(NSError * _Nullable))completion error:(NSError * _Nullable)error
{
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (NSString * _Nullable)marker:(NSString *)name
{
    if(self.sessionDirectory == nil) return nil;
    NSString *value = [NSString stringWithContentsOfURL:[self.sessionDirectory URLByAppendingPathComponent:name]
                                             encoding:NSUTF8StringEncoding error:NULL];
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    return value.length > 0 ? value : nil;
}

- (void)heartbeat
{
    if(self.sessionDirectory != nil)
    {
        [@"alive" writeToURL:[self.sessionDirectory URLByAppendingPathComponent:@"heartbeat"]
                  atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

- (NSError * _Nullable)errorForReason:(NSString *)reason
{
    if([reason isEqualToString:@"already-running"])
        return KYAClamshellError(14, @"另一个合盖会话正在运行或尚未清理，未更改系统设置。");
    if([reason isEqualToString:@"already-disabled"])
        return KYAClamshellError(2, @"系统已由其他设置禁止睡眠，本次未接管，也未更改原设置。");
    if([reason isEqualToString:@"low-battery"])
        return KYAClamshellError(3, @"电池电量已降至 10% 或以下，已恢复正常合盖休眠。");
    if([reason isEqualToString:@"heartbeat-expired"])
        return KYAClamshellError(4, @"应用心跳已超时，已恢复正常合盖休眠。");
    if([reason isEqualToString:@"error:watchdog"])
        return KYAClamshellError(13, @"恢复守护进程已意外结束。请在终端运行 sudo pmset -a disablesleep 0 恢复。");
    if([reason isEqualToString:@"error:restore"])
        return KYAClamshellError(5, @"自动恢复睡眠设置失败。请在终端运行 sudo pmset -a disablesleep 0 恢复。");
    if([reason hasPrefix:@"error:"])
        return KYAClamshellError(6, [NSString stringWithFormat:@"未能验证合盖运行状态（%@），已尝试恢复原设置。", reason]);
    return nil;
}

- (void)finishSessionWithReason:(NSString *)reason
{
    if([reason isEqualToString:@"error:watchdog"])
        reason = [self marker:@"done"] ?: reason;
    if(self.monitor != nil) dispatch_source_cancel(self.monitor);
    self.monitor = nil;
    BOOL requiresRestoration = [reason isEqualToString:@"error:restore"] || [reason isEqualToString:@"error:watchdog"];
    if(!requiresRestoration)
    {
        if(self.sessionDirectory != nil)
            [NSFileManager.defaultManager removeItemAtURL:self.sessionDirectory error:NULL];
        self.sessionDirectory = nil;
    }
    NSError *error = [self errorForReason:reason];
    NSDictionary *info = error == nil ? @{@"reason": reason} : @{@"reason": reason, NSUnderlyingErrorKey: error};
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:KYAClamshellSessionDidStopNotification
                                                          object:self userInfo:info];
    });
}

- (void)startMonitor
{
    dispatch_source_t monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.workQueue);
    self.monitor = monitor;
    dispatch_source_set_timer(monitor, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak KYAClamshellSession *weakSelf = self;
    dispatch_source_set_event_handler(monitor, ^{
        KYAClamshellSession *session = weakSelf;
        if(session == nil) return;
        NSString *done = [session marker:@"done"];
        if(done != nil) [session finishSessionWithReason:done];
        else if(session.restorationRequired)
            [session finishSessionWithReason:@"error:watchdog"];
        else [session heartbeat];
    });
    dispatch_resume(monitor);
}

- (void)startWithCompletion:(void (^)(NSError * _Nullable))completion
{
    dispatch_async(self.workQueue, ^{
        if(self.active) { [self complete:completion error:nil]; return; }
        if(self.sessionDirectory != nil)
        {
            [self complete:completion error:KYAClamshellError(7, @"上一个会话仍在恢复睡眠设置，请稍后再试。")];
            return;
        }
        NSError *error = nil;
        NSString *ownerStart = KYARunTask(@"/bin/ps", @[@"-p", [NSString stringWithFormat:@"%d", getpid()], @"-o", @"lstart="], &error);
        ownerStart = [ownerStart stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if(ownerStart.length == 0)
        {
            [self complete:completion error:error ?: KYAClamshellError(8, @"无法读取应用进程启动时间，未开启合盖运行。")];
            return;
        }
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"KYAClamshell.XXXXXX"];
        char *buffer = strdup(template.fileSystemRepresentation);
        char *created = mkdtemp(buffer);
        if(created == NULL)
        {
            free(buffer);
            [self complete:completion error:KYAClamshellError(9, @"无法创建合盖会话控制目录。")];
            return;
        }
        self.sessionDirectory = [NSURL fileURLWithFileSystemRepresentation:created isDirectory:YES relativeToURL:nil];
        free(buffer);
        [self heartbeat];
        NSData *scriptData = [[NSString stringWithUTF8String:KYAClamshellWatchdogScript] dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encoded = [scriptData base64EncodedStringWithOptions:0];
        NSString *command = [NSString stringWithFormat:
            @"( /bin/echo %@ | /usr/bin/base64 -D | /bin/sh -s -- %@ %d %@ ) </dev/null >/dev/null 2>&1 &",
            KYAShellQuote(encoded), KYAShellQuote(self.sessionDirectory.path), getpid(), KYAShellQuote(ownerStart)];
        NSString *escaped = [[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                             stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString *source = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", escaped];
        NSString *result = KYARunTask(@"/usr/bin/osascript", @[@"-e", source], &error);
        if(result == nil)
        {
            // Signal stop in case the administrator command launched before failing.
            [@"stop" writeToURL:[self.sessionDirectory URLByAppendingPathComponent:@"stop"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            if(self.active) [self startMonitor];
            else [self finishSessionWithReason:@"authorization-failed"];
            [self complete:completion error:error];
            return;
        }
        [self heartbeat];
        for(NSUInteger attempt = 0; attempt < 100; attempt++)
        {
            NSString *done = [self marker:@"done"];
            if(done != nil)
            {
                error = [self errorForReason:done] ?: KYAClamshellError(10, @"合盖会话在启用前已结束。");
                [self finishSessionWithReason:done];
                [self complete:completion error:error];
                return;
            }
            if(self.active)
            {
                [self startMonitor];
                [self complete:completion error:nil];
                return;
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        [@"stop" writeToURL:[self.sessionDirectory URLByAppendingPathComponent:@"stop"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [self startMonitor];
        [self complete:completion error:KYAClamshellError(11, @"合盖会话启动超时，已请求恢复原设置。")];
    });
}

- (void)stopWithCompletion:(void (^)(NSError * _Nullable))completion
{
    dispatch_async(self.workQueue, ^{
        if(self.sessionDirectory == nil) { [self complete:completion error:nil]; return; }
        NSError *error = nil;
        if(self.restorationRequired)
        {
            // This path is only entered on an explicit user stop after the original
            // watchdog has failed. A fresh admin grant is needed; never claim that
            // the persistent system flag was restored based on process state alone.
            NSString *token = [self marker:@"lock-token"] ?: @"";
            NSString *command = [NSString stringWithFormat:
                @"/usr/bin/pmset -a disablesleep 0; state=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == \"SleepDisabled\" {print $2; exit}'); [ \"$state\" = 0 ] || exit 1; "
                 "if [ \"$(/bin/cat /var/run/com.webfooo.KeepingYouAwake.clamshell/owner 2>/dev/null)\" = %@ ]; then /bin/rm -f /var/run/com.webfooo.KeepingYouAwake.clamshell/owner; /bin/rmdir /var/run/com.webfooo.KeepingYouAwake.clamshell 2>/dev/null || :; fi",
                KYAShellQuote(token)];
            NSString *escaped = [[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                 stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            NSString *source = [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", escaped];
            if(KYARunTask(@"/usr/bin/osascript", @[@"-e", source], &error) != nil)
            {
                [self finishSessionWithReason:@"restored"];
                [self complete:completion error:nil];
            }
            else [self complete:completion error:error];
            return;
        }
        BOOL signaled = [@"stop" writeToURL:[self.sessionDirectory URLByAppendingPathComponent:@"stop"]
                               atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if(!signaled) { [self complete:completion error:error]; return; }
        for(NSUInteger attempt = 0; attempt < 100; attempt++)
        {
            NSString *done = [self marker:@"done"];
            if(done != nil)
            {
                error = [self errorForReason:done];
                [self finishSessionWithReason:done];
                [self complete:completion error:error];
                return;
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        [self complete:completion error:KYAClamshellError(12, @"恢复尚未完成；独立守护进程仍会继续恢复，请稍后查看状态。")];
    });
}

@end
