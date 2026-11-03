//
//  KYAAppController.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import "KYAAppController.h"
#import <KYACommon/KYACommon.h>
#import "KYALocalizedStrings.h"
#import "KYAMainMenu.h"
#import "KYABatteryCapacityThreshold.h"
#import "KYAActivationDurationsMenuController.h"
#import "KYAActivationUserNotification.h"

// Deprecated!
#define KYA_MINUTES(m) (m * 60.0f)
#define KYA_HOURS(h) (h * 3600.0f)

@interface KYAAppController () <KYAStatusItemControllerDataSource, KYAStatusItemControllerDelegate, KYAActivationDurationsMenuControllerDelegate, KYASleepWakeTimerDelegate>
@property (nonatomic, readwrite) KYASleepWakeTimer *sleepWakeTimer;
@property (nonatomic, readwrite) KYAStatusItemController *statusItemController;
@property (nonatomic) KYAActivationDurationsMenuController *menuController;
@property (nonatomic) KYAClamshellSession *clamshellSession;
@property (nonatomic) BOOL changingClamshellMode;

@property (nonatomic) NSTimeInterval workspaceScheduledTimeInterval;

// Battery Status
@property (nonatomic, direct, getter=isBatteryOverrideEnabled) BOOL batteryOverrideEnabled;

// Menu
@property (nonatomic) NSMenu *menu;
@end

@implementation KYAAppController

#pragma mark - Life Cycle

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        self.clamshellSession = [KYAClamshellSession new];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(clamshellSessionDidStop:)
                                                   name:KYAClamshellSessionDidStopNotification
                                                 object:self.clamshellSession];
        [self configureStatusItemController];
        [self configureSleepWakeTimer];
        [self configureEventHandler];
        [self configureUserNotificationCenter];
        [self configureMainMenu];

        Auto center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(applicationWillFinishLaunching:)
                       name:NSApplicationWillFinishLaunchingNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(applicationDidChangeScreenParameters:)
                       name:NSApplicationDidChangeScreenParametersNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(batteryCapacityThresholdDidChange:)
                       name:kKYABatteryCapacityThresholdDidChangeNotification
                     object:nil];
        
        [self registerForWorkspaceSessionNotifications];
    }
    return self;
}

- (void)dealloc
{
    Auto center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
    [center removeObserver:self name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [center removeObserver:self name:kKYABatteryCapacityThresholdDidChangeNotification object:nil];
    [center removeObserver:self name:KYAClamshellSessionDidStopNotification object:self.clamshellSession];
    
    [self unregisterFromWorkspaceSessionNotifications];
}

#pragma mark - Main Menu

- (void)configureMainMenu
{
    Auto menuController = [KYAActivationDurationsMenuController new];
    menuController.delegate = self;
    self.menuController = menuController;
    
    self.menu = KYACreateMainMenuWithActivationDurationsSubMenu(menuController.menu);

    Auto keepRunning = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Keep Running", nil)
                                                action:@selector(toggleKeepRunning:)
                                         keyEquivalent:@""];
    keepRunning.target = self;
    [self.menu insertItem:keepRunning atIndex:0];

    Auto displayOff = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Keep Running and Turn Display Off", nil)
                                               action:@selector(keepRunningAndTurnDisplayOff:)
                                        keyEquivalent:@""];
    displayOff.target = self;
    displayOff.image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil];
    [self.menu insertItem:displayOff atIndex:1];

    Auto closedLid = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Enable Closed-Lid Mode…", nil)
                                              action:@selector(toggleClosedLidMode:)
                                       keyEquivalent:@""];
    closedLid.target = self;
    closedLid.image = [NSImage imageWithSystemSymbolName:@"laptopcomputer" accessibilityDescription:nil];
    closedLid.toolTip = NSLocalizedString(@"Administrator authorization is required. Normal sleep settings are restored when this app exits.", nil);
    [self.menu insertItem:closedLid atIndex:2];
    [self.menu insertItem:NSMenuItem.separatorItem atIndex:3];

    Auto project = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open Project Page", nil)
                                            action:@selector(openProjectPage:)
                                     keyEquivalent:@""];
    project.target = self;
    [self.menu insertItem:project atIndex:self.menu.numberOfItems - 2];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if(item.action == @selector(toggleKeepRunning:))
    {
        item.title = [self.sleepWakeTimer isScheduled]
            ? NSLocalizedString(@"Stop Keeping Awake", nil) : NSLocalizedString(@"Keep Running", nil);
    }
    if(item.action == @selector(toggleClosedLidMode:))
    {
        item.title = self.clamshellSession.restorationRequired ? NSLocalizedString(@"Retry Restoring System Sleep…", nil) : self.clamshellSession.active
            ? NSLocalizedString(@"Disable Closed-Lid Mode", nil) : NSLocalizedString(@"Enable Closed-Lid Mode…", nil);
        item.state = (self.clamshellSession.active || self.clamshellSession.restorationRequired) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    else if(self.clamshellSession.restorationRequired && item.action != @selector(openProjectPage:)) { return NO; }
    return !self.changingClamshellMode;
}

- (IBAction)toggleKeepRunning:(id)sender
{
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
    else
    {
        [self activateTimerWithTimeInterval:KYASleepWakeTimeIntervalIndefinite];
    }
}

- (IBAction)keepRunningAndTurnDisplayOff:(id)sender
{
    NSUserDefaults.standardUserDefaults.kya_allowDisplaySleep = YES;
    // Restart caffeinate so a previous display-awake assertion is released.
    [self.sleepWakeTimer invalidate];
    [self activateTimerWithTimeInterval:KYASleepWakeTimeIntervalIndefinite];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        Auto task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
        task.arguments = @[@"displaysleepnow"];
        task.terminationHandler = ^(NSTask *finished) {
            if(finished.terminationStatus != 0)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showPowerError:nil title:NSLocalizedString(@"Display Sleep Failed", nil)];
                });
            }
        };
        NSError *error = nil;
        if(![task launchAndReturnError:&error])
        {
            [self showPowerError:error title:NSLocalizedString(@"Display Sleep Failed", nil)];
        }
    });
}

- (IBAction)toggleClosedLidMode:(id)sender
{
    if(self.changingClamshellMode) { return; }
    self.changingClamshellMode = YES;
    Auto completion = ^(NSError *error) {
        self.changingClamshellMode = NO;
        if(error)
        {
            [self showPowerError:error title:NSLocalizedString(@"Closed-Lid Mode Failed", nil)];
        }
        else if(self.clamshellSession.active)
        {
            NSUserDefaults.standardUserDefaults.kya_allowDisplaySleep = YES;
            [self.sleepWakeTimer invalidate];
            [self activateTimerWithTimeInterval:KYASleepWakeTimeIntervalIndefinite];
        }
    };
    if(self.clamshellSession.active || self.clamshellSession.restorationRequired)
    {
        [self.clamshellSession stopWithCompletion:completion];
    }
    else
    {
        [self.clamshellSession startWithCompletion:completion];
    }
}

- (void)showPowerError:(NSError *)error title:(NSString *)title
{
    Auto alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: NSLocalizedString(@"Your Mac is still being kept awake. Turn off the display from macOS or try again.", nil);
    [alert runModal];
}

- (IBAction)openProjectPage:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/fanaruto/KeepingYouAwake"]];
}

- (void)clamshellSessionDidStop:(NSNotification *)notification
{
    NSError *error = notification.userInfo[NSUnderlyingErrorKey];
    // A pending user action reports its own result through its completion.
    if(error && !self.changingClamshellMode)
    {
        if(!self.clamshellSession.restorationRequired) { [self.sleepWakeTimer invalidate]; }
        [self showPowerError:error title:NSLocalizedString(@"Closed-Lid Mode Failed", nil)];
    }
}

#pragma mark - Status Item Controller

- (void)configureStatusItemController
{
    Auto statusItemController = [KYAStatusItemController new];
    statusItemController.dataSource = self;
    statusItemController.delegate = self;
    self.statusItemController = statusItemController;
}

#pragma mark - Sleep Wake Timer

- (void)configureSleepWakeTimer
{
    Auto sleepWakeTimer = [KYASleepWakeTimer new];
    sleepWakeTimer.delegate = self;
    self.sleepWakeTimer = sleepWakeTimer;
    
    // Activate on launch if needed
    if([NSUserDefaults.standardUserDefaults kya_isActivatedOnLaunch])
    {
        [self activateTimer];
    }
}

- (void)activateTimer
{
    [self activateTimerWithTimeInterval:self.defaultTimeInterval];
}

- (void)activateTimerWithTimeInterval:(NSTimeInterval)timeInterval
{
    // Do not allow negative time intervals
    if(timeInterval < 0)
    {
        return;
    }

    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    Auto timerCompletion = ^(BOOL cancelled) {
        // Restarting a session should not emit a stale "stopped" notification.
        if(cancelled && [self.sleepWakeTimer isScheduled]) { return; }
        // Post deactivation notification
        Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:nil activating:NO];
        [KYAUserNotificationCenter.sharedCenter postNotification:notification];

        // A timed closed-lid session must restore lid sleep when its timer ends.
        if(!cancelled && self.clamshellSession.active) { [self terminateTimer]; }

        // Quit on timer expiration
        if(cancelled == NO && [defaults kya_isQuitOnTimerExpirationEnabled])
        {
            [NSApplication.sharedApplication terminate:nil];
        }
    };
    [self.sleepWakeTimer scheduleWithTimeInterval:timeInterval completion:timerCompletion];

    // Post activation notification
    Auto fireDate = self.sleepWakeTimer.fireDate;
    Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:fireDate activating:YES];
    [KYAUserNotificationCenter.sharedCenter postNotification:notification];
}

- (void)terminateTimer
{
    if(self.clamshellSession.restorationRequired) { return; }
    if(self.clamshellSession.active)
    {
        self.changingClamshellMode = YES;
        [self.clamshellSession stopWithCompletion:^(NSError *error) {
            self.changingClamshellMode = NO;
            if(error)
                [self showPowerError:error title:NSLocalizedString(@"Closed-Lid Mode Failed", nil)];
            else
                [self terminateTimer];
        }];
        return;
    }
    [self disableBatteryOverride];

    if([self.sleepWakeTimer isScheduled])
    {
        [self.sleepWakeTimer invalidate];
    }
}

#pragma mark - Default Time Interval

- (NSTimeInterval)defaultTimeInterval
{
    return NSUserDefaults.standardUserDefaults.kya_defaultTimeInterval;
}

#pragma mark - Activate on Launch

- (IBAction)toggleActivateOnLaunch:(id)sender
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    defaults.kya_activateOnLaunch = ![defaults kya_isActivatedOnLaunch];
    [defaults synchronize];
}

#pragma mark - User Notification Center

- (void)configureUserNotificationCenter
{
    Auto center = KYAUserNotificationCenter.sharedCenter;
    [center requestAuthorizationIfUndetermined];
    [center clearAllDeliveredNotifications];
}

#pragma mark - Device Power Monitoring

- (void)checkAndEnableBatteryOverride
{
    Auto batteryMonitor = KYADevice.currentDevice.batteryMonitor;
    CGFloat currentCapacity = batteryMonitor.currentCapacity;
    CGFloat threshold = NSUserDefaults.standardUserDefaults.kya_batteryCapacityThreshold;

    self.batteryOverrideEnabled = (currentCapacity <= threshold);
}

- (void)disableBatteryOverride
{
    self.batteryOverrideEnabled = NO;
}

- (void)deviceParameterDidChange:(NSNotification *)notification
{
    NSParameterAssert(notification);
    
    Auto device = (KYADevice *)notification.object;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    Auto userInfo = notification.userInfo;
    Auto deviceParameter = (KYADeviceParameter)userInfo[KYADeviceParameterKey];
    if([deviceParameter isEqualToString:KYADeviceParameterBattery])
    {
        if([defaults kya_isBatteryCapacityThresholdEnabled] == NO) { return; }
        
        CGFloat threshold = defaults.kya_batteryCapacityThreshold;
        Auto capacity = device.batteryMonitor.currentCapacity;
        if([self.sleepWakeTimer isScheduled] && (capacity <= threshold) && ![self isBatteryOverrideEnabled])
        {
            [self terminateTimer];
        }
    }
    else if([deviceParameter isEqualToString:KYADeviceParameterLowPowerMode])
    {
        if([defaults kya_isLowPowerModeMonitoringEnabled] == NO) { return; }
        
        if([device.lowPowerModeMonitor isLowPowerModeEnabled] && [self.sleepWakeTimer isScheduled])
        {
            [self terminateTimer];
        }
    }
}

- (void)enableDevicePowerMonitoring
{
    [self disableDevicePowerMonitoring];
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    // Check battery overrides and register for capacity changes.
    [self checkAndEnableBatteryOverride];
    
    [center addObserver:self
               selector:@selector(deviceParameterDidChange:)
                   name:KYADeviceParameterDidChangeNotification
                 object:device];
    
    if([defaults kya_isBatteryCapacityThresholdEnabled])
    {
        device.batteryMonitoringEnabled = YES;
    }
    if([defaults kya_isLowPowerModeMonitoringEnabled])
    {
        device.lowPowerModeMonitoringEnabled = YES;
    }
}

- (void)disableDevicePowerMonitoring
{
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    
    [center removeObserver:self
                      name:KYADeviceParameterDidChangeNotification
                    object:device];
    
    device.batteryMonitoringEnabled = NO;
    device.lowPowerModeMonitoringEnabled = NO;
}

#pragma mark - Battery Capacity Threshold Changes

- (void)batteryCapacityThresholdDidChange:(NSNotification *)notification
{
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
}

#pragma mark - Workspace Session Handling

- (void)registerForWorkspaceSessionNotifications
{
    Auto workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self
                        selector:@selector(workspaceSessionDidBecomeActive:)
                            name:NSWorkspaceSessionDidBecomeActiveNotification
                          object:nil];
    [workspaceCenter addObserver:self
                        selector:@selector(workspaceSessionDidResignActive:)
                            name:NSWorkspaceSessionDidResignActiveNotification
                          object:nil];
}

- (void)unregisterFromWorkspaceSessionNotifications
{
    Auto workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter removeObserver:self
                               name:NSWorkspaceSessionDidBecomeActiveNotification
                             object:nil];
    [workspaceCenter removeObserver:self
                               name:NSWorkspaceSessionDidResignActiveNotification
                             object:nil];
}

- (void)workspaceSessionDidBecomeActive:(NSNotification *)notification
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    if([defaults kya_isDeactivateOnUserSwitchEnabled] && self.workspaceScheduledTimeInterval >= 0)
    {
        [self activateTimerWithTimeInterval:self.workspaceScheduledTimeInterval];
        self.workspaceScheduledTimeInterval = -1;
    }
}

- (void)workspaceSessionDidResignActive:(NSNotification *)notification
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    if([defaults kya_isDeactivateOnUserSwitchEnabled] && [self.sleepWakeTimer isScheduled])
    {
        self.workspaceScheduledTimeInterval = self.sleepWakeTimer.scheduledTimeInterval;
        [self terminateTimer];
    }
}

#pragma mark - Event Handling

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    [KYAEventHandler.defaultHandler registerAsDefaultEventHandler];
}

- (void)configureEventHandler
{
    Auto eventHandler = KYAEventHandler.defaultHandler;
    
    AutoWeak weakSelf = self;
    [eventHandler registerActionNamed:@"activate" block:^(KYAEvent *event) {
        [weakSelf handleActivateActionForEvent:event];
    }];
    
    [eventHandler registerActionNamed:@"deactivate" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        if(strongSelf.changingClamshellMode) { return; }
        [strongSelf terminateTimer];
    }];
    
    [eventHandler registerActionNamed:@"toggle" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        [strongSelf statusItemControllerShouldPerformPrimaryAction:strongSelf.statusItemController];
    }];
}

- (void)handleActivateActionForEvent:(KYAEvent *)event
{
    if(self.changingClamshellMode) { return; }
    Auto parameters = event.arguments;
    NSString *seconds = parameters[@"seconds"];
    NSString *minutes = parameters[@"minutes"];
    NSString *hours = parameters[@"hours"];

    // Replacing the idle timer keeps the independently authorized lid session.
    // Natural timer expiration will stop that session; no asynchronous stop races
    // with the new timer here.
    [self.sleepWakeTimer invalidate];
    
    Auto statusItemController = self.statusItemController;

    // Activate indefinitely if there are no parameters
    if(parameters == nil || parameters.count == 0)
    {
        [self activateTimer];
        statusItemController.appearance = KYAStatusItemAppearanceActive;
    }
    else if(seconds != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)ceil(seconds.doubleValue)];
        statusItemController.appearance = KYAStatusItemAppearanceActive;
    }
    else if(minutes != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_MINUTES(ceil(minutes.doubleValue))];
        statusItemController.appearance = KYAStatusItemAppearanceActive;
    }
    else if(hours != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_HOURS(ceil(hours.doubleValue))];
        statusItemController.appearance = KYAStatusItemAppearanceActive;
    }
    else
    {
        statusItemController.appearance = KYAStatusItemAppearanceInactive;
    }
}

#pragma mark - Internal / External Screen Parameter Changes

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
    if([NSUserDefaults.standardUserDefaults kya_isActivateOnExternalDisplayConnectedEnabled] == NO)
    {
        return;
    }
    
    NSUInteger numberOfExternalScreens = KYADisplayParametersGetNumberOfExternalDisplays();
    Auto sleepWakeTimer = self.sleepWakeTimer;
    
    if(numberOfExternalScreens == 0)
    {
        // Only the main screen is connected, deactivate!
        if([sleepWakeTimer isScheduled])
        {
            [self terminateTimer];
        }
    }
    else
    {
        // The main screen and at least one external screen, activate!
        if([sleepWakeTimer isScheduled] == NO)
        {
            [self activateTimer];
        }
    }
}

#pragma mark - KYAStatusItemControllerDataSource

- (NSMenu *)menuForStatusItemController:(KYAStatusItemController *)controller
{
    for(NSMenuItem *item in self.menu.itemArray)
    {
        if(item.submenu != nil)
        {
            item.enabled = !self.changingClamshellMode;
            for(NSMenuItem *duration in item.submenu.itemArray)
                duration.enabled = !self.changingClamshellMode;
        }
    }
    return self.menu;
}

#pragma mark - KYAStatusItemControllerDelegate

- (void)statusItemControllerShouldPerformPrimaryAction:(KYAStatusItemController *)controller
{
    if(self.changingClamshellMode) { return; }
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
    else
    {
        [self activateTimer];
    }
}

#pragma mark - KYAActivationDurationsMenuControllerDelegate

- (KYAActivationDuration *)currentActivationDuration
{
    Auto sleepWakeTimer = self.sleepWakeTimer;
    if(![sleepWakeTimer isScheduled])
    {
        return nil;
    }

    NSTimeInterval seconds = sleepWakeTimer.scheduledTimeInterval;
    return [[KYAActivationDuration alloc] initWithSeconds:seconds];
}

- (void)activationDurationsMenuController:(KYAActivationDurationsMenuController *)controller didSelectActivationDuration:(KYAActivationDuration *)activationDuration
{
    if(self.changingClamshellMode) { return; }
    [self.sleepWakeTimer invalidate];

    AutoWeak weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval seconds = activationDuration.seconds;
        [weakSelf activateTimerWithTimeInterval:seconds];
    });
}

- (NSDate *)fireDateForMenuController:(KYAActivationDurationsMenuController *)controller
{
    return self.sleepWakeTimer.fireDate;
}

#pragma mark - KYASleepWakeTimerDelegate

- (void)sleepWakeTimer:(KYASleepWakeTimer *)sleepWakeTimer willActivateWithTimeInterval:(NSTimeInterval)timeInterval
{
    // Update the status item
    self.statusItemController.appearance = KYAStatusItemAppearanceActive;
    
    [self enableDevicePowerMonitoring];
}

- (void)sleepWakeTimerDidDeactivate:(KYASleepWakeTimer *)sleepWakeTimer
{
    // Update the status item
    self.statusItemController.appearance = KYAStatusItemAppearanceInactive;
    
    [self disableDevicePowerMonitoring];
}

@end
