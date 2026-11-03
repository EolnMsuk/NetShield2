#import <Foundation/Foundation.h>

static NSString *const NSUpdateCheckModeKey = @"updateCheckMode";
static NSString *const NSUpdateCheckLastAttemptKey = @"updateCheckLastAttempt";
static NSString *const NSUpdateCheckDaily = @"daily";
static NSString *const NSUpdateCheckEveryLaunch = @"everyLaunch";
static NSString *const NSUpdateCheckOff = @"off";

static inline NSString *NSUpdateCheckMode(NSUserDefaults *defaults) {
    id mode = [defaults objectForKey:NSUpdateCheckModeKey];
    if (![mode isKindOfClass:NSString.class]) {
        return NSUpdateCheckDaily;
    }
    return [@[ NSUpdateCheckDaily, NSUpdateCheckEveryLaunch, NSUpdateCheckOff ] containsObject:mode]
               ? mode
               : NSUpdateCheckDaily;
}

static inline BOOL NSAutomaticUpdateCheckDue(NSUserDefaults *defaults, NSDate *now) {
    NSString *mode = NSUpdateCheckMode(defaults);
    if ([mode isEqual:NSUpdateCheckOff]) {
        return NO;
    }
    if ([mode isEqual:NSUpdateCheckEveryLaunch]) {
        return YES;
    }
    id lastAttempt = [defaults objectForKey:NSUpdateCheckLastAttemptKey];
    return ![lastAttempt isKindOfClass:NSDate.class] ||
           [now timeIntervalSinceDate:lastAttempt] >= 24 * 60 * 60 ||
           [now timeIntervalSinceDate:lastAttempt] < -24 * 60 * 60;
}

static inline void NSResetAppPreferences(NSUserDefaults *defaults, NSString *domain) {
    [defaults removePersistentDomainForName:domain];
}
