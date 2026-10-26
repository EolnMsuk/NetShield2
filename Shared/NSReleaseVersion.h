#import <Foundation/Foundation.h>

// Release tags may have a leading v. Compare numeric components, not strings
// (2.10.0 is newer than 2.9.0); missing trailing components are zero.
static inline NSArray<NSNumber *> *NSReleaseVersionComponents(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 64) {
        return nil;
    }
    NSString *version =
        [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
        version = [version substringFromIndex:1];
    }
    NSArray *parts = [version componentsSeparatedByString:@"."];
    if (parts.count > 4) {
        return nil;
    }
    NSMutableArray *numbers = [NSMutableArray new];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (NSString *part in parts) {
        if (!part.length || part.length > 9 ||
            [part rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            return nil;
        }
        [numbers addObject:@(part.integerValue)];
    }
    return numbers;
}
static inline NSNumber *NSCompareReleaseVersions(id latest, id installed) {
    NSArray *left = NSReleaseVersionComponents(latest), *right = NSReleaseVersionComponents(installed);
    if (!left || !right) {
        return nil;
    }
    for (NSUInteger index = 0; index < MAX(left.count, right.count); index++) {
        NSInteger a = index < left.count ? [left[index] integerValue] : 0;
        NSInteger b = index < right.count ? [right[index] integerValue] : 0;
        if (a != b) {
            return @(a > b ? NSOrderedDescending : NSOrderedAscending);
        }
    }
    return @(NSOrderedSame);
}
static inline NSString *NSPublishedReleaseVersion(id release) {
    if (![release isKindOfClass:NSDictionary.class] || ![release[@"draft"] isEqual:@NO] ||
        ![release[@"prerelease"] isEqual:@NO] || !NSReleaseVersionComponents(release[@"tag_name"])) {
        return nil;
    }
    return release[@"tag_name"];
}
