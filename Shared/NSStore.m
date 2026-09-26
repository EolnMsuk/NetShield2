#import "NSStore.h"

NSString *const NSGroupIdentifier = @"group.com.eolnmsuk.netshield";
static NSError *NSStorageError(NSString *message) {
    return [NSError errorWithDomain:@"NetShield.Storage" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
NSURL *NSSharedURL(NSString *name) {
    NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:NSGroupIdentifier];
    return root ? [root URLByAppendingPathComponent:name] : nil;
}
NSDictionary *NSReadDocument(NSString *name, NSError **error) {
    NSURL *url = NSSharedURL(name);
    if (!url) {
        if (error) *error = NSStorageError(@"The shared app-group container is unavailable. Check entitlements and app/extension registration; filtering is not verified.");
        return nil;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
    if (!attributes) return nil;
    if ([attributes fileSize] > 2 * 1024 * 1024) {
        if (error) *error = NSStorageError(@"Shared document exceeds the 2 MiB limit.");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = NSStorageError(@"Shared document is not a dictionary.");
        return nil;
    }
    return value;
}
BOOL NSWriteDocument(NSDictionary *document, NSString *name, NSError **error) {
    NSURL *url = NSSharedURL(name);
    if (!url) {
        if (error) *error = NSStorageError(@"The shared app-group container is unavailable.");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    if (data.length > 2 * 1024 * 1024) {
        if (error) *error = NSStorageError(@"Shared document exceeds the 2 MiB limit.");
        return NO;
    }
    // Rename an entire snapshot atomically. No preferences cache and no partial rules.
    return [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionNone error:error];
}
NSPolicy *NSReadPolicy(NSError **error) {
    NSDictionary *document = NSReadDocument(@"policy.plist", error);
    return document ? [NSPolicy policyWithDocument:document error:error] : nil;
}
NSDictionary *NSReadMonitor(void) {
    NSDictionary *d = NSReadDocument(@"monitor.plist", NULL);
    if (![d[@"schema"] isEqual:@2] || ![d[@"updated"] isKindOfClass:NSDate.class] ||
        ![d[@"lastReport"] isKindOfClass:NSDate.class] || ![d[@"controlRunning"] isKindOfClass:NSNumber.class] ||
        ![d[@"policyError"] isKindOfClass:NSString.class] || ![d[@"events"] isKindOfClass:NSArray.class] ||
        [d[@"events"] count] > 300) return @{};
    for (id e in d[@"events"]) {
        if (![e isKindOfClass:NSDictionary.class]) return @{};
        for (NSString *key in @[@"identity", @"action", @"direction", @"flow"])
            if (![e[key] isKindOfClass:NSString.class]) return @{};
        for (NSString *key in @[@"bytesIn", @"bytesOut", @"event"])
            if (![e[key] isKindOfClass:NSNumber.class]) return @{};
        if (![e[@"time"] isKindOfClass:NSDate.class]) return @{};
    }
    return d;
}
