//
//  main.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <KYAApplicationSupport/KYAApplicationSupport.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        // Defaults belong to this fork's bundle, leaving the upstream app alone.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if(![defaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier][@"AppleLanguages"])
        {
            [defaults setObject:@[@"zh-Hans", @"en"] forKey:@"AppleLanguages"];
        }
        [defaults registerDefaults:@{
            KYAUserDefaultsKeyAllowDisplaySleep: @YES,
            KYAUserDefaultsKeyActivateOnLaunch: @YES,
            @"AppleLanguages": @[@"zh-Hans", @"en"]
        }];
    }
    return NSApplicationMain(argc, argv);
}
