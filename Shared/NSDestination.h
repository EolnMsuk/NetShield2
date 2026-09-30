#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static inline BOOL NSValidDestination(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] > 3) {
        return NO;
    }
    for (id key in value) {
        if ([key isEqual:@"port"]) {
            id port = value[key];
            if (![port isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)port) == CFBooleanGetTypeID() || [port integerValue] < 1 ||
                [port integerValue] > 65535 || ![port isEqual:@([port integerValue])]) {
                return NO;
            }
            continue;
        }
        if (![@[ @"domain", @"address" ] containsObject:key] || ![value[key] isKindOfClass:NSString.class] ||
            [value[key] length] > 253) {
            return NO;
        }
    }
    return YES;
}

// Keep only host information, never URL paths, credentials, queries or payloads.
static inline NSString *NSCleanDestinationHost(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 253) {
        return @"";
    }
    NSCharacterSet *unsafe = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_%[]"] invertedSet];
    return [value rangeOfCharacterFromSet:unsafe].location == NSNotFound ? value : @"";
}

static inline NSString *NSDestinationSummary(NSDictionary *destination) {
    NSString *domain = NSCleanDestinationHost(destination[@"domain"]);
    NSString *address = NSCleanDestinationHost(destination[@"address"]);
    NSMutableArray *parts = [NSMutableArray new];
    if (domain.length) {
        [parts addObject:[@"Domain: " stringByAppendingString:domain]];
    }
    if (address.length) {
        [parts addObject:[@"IP: " stringByAppendingString:address]];
    }
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"Destination unavailable from iOS";
}
