#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const KYAClamshellSessionDidStopNotification;
FOUNDATION_EXPORT NSString * const KYAClamshellSessionErrorDomain;

/// A separately authorized system-wide session that can prevent lid-close sleep.
/// A root watchdog restores the previous setting on stop, process exit, missing
/// heartbeat (60 seconds), or battery power at 10% or less. No sudoers is installed.
@interface KYAClamshellSession : NSObject

/// YES only after the watchdog has enabled and verified SleepDisabled.
@property(atomic, readonly, getter=isActive) BOOL active;

/// Restoration could not be verified. Keep the session visible until a user-
/// initiated stop retries the privileged restoration and verifies SleepDisabled=0.
@property(atomic, readonly) BOOL restorationRequired;

/// Native administrator authentication is shown by osascript on a worker queue.
/// Completions and DidStop notifications are delivered on the main queue.
- (void)startWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)stopWithCompletion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
