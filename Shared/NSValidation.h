#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
static inline BOOL NSBoundedString(id value, NSUInteger limit, BOOL nonempty) {
    return [value isKindOfClass:NSString.class] && [value length] <= limit && (!nonempty || [value length]);
}
static inline BOOL NSBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static inline BOOL NSUnsignedInteger(id value, unsigned long long maximum) {
    return [value isKindOfClass:NSNumber.class] && !NSBoolean(value) &&
           [value compare:@0] != NSOrderedAscending && [value compare:@(maximum)] != NSOrderedDescending &&
           [value isEqual:@([value unsignedLongLongValue])];
}
