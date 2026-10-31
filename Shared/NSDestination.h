#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static inline BOOL NSValidDestination(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] > 5) {
        return NO;
    }
    for (id key in value) {
        if ([key isEqual:@"protocol"]) {
            if (![@[ @"tcp", @"udp", @"other" ] containsObject:value[key]]) {
                return NO;
            }
            continue;
        }
        if ([key isEqual:@"port"] || [key isEqual:@"localPort"]) {
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
    if ([@[ @"tcp", @"udp" ] containsObject:destination[@"protocol"]]) {
        [parts addObject:[destination[@"protocol"] uppercaseString]];
    }
    if (domain.length) {
        [parts addObject:[@"Domain: " stringByAppendingString:domain]];
    }
    if (address.length) {
        [parts addObject:[@"IP: " stringByAppendingString:address]];
    }
    NSNumber *localPort = destination[@"localPort"];
    if (localPort.integerValue >= 1 && localPort.integerValue <= 65535) {
        [parts addObject:[NSString stringWithFormat:@"Local port: %@", localPort]];
    }
    NSNumber *port = destination[@"port"];
    if (port.integerValue >= 1 && port.integerValue <= 65535) {
        [parts addObject:[NSString stringWithFormat:@"Remote port: %@", port]];
    }
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"Destination unavailable from iOS";
}

// Dedicated detail rows for connection sheets; keep compact dashboard summaries unchanged.
static inline NSArray<NSArray<NSString *> *> *NSConnectionDetailRows(NSDictionary *destination,
                                                                     NSString *direction) {
    NSString *directionTitle = [direction isEqual:@"inbound"]    ? @"Incoming"
                               : [direction isEqual:@"outbound"] ? @"Outgoing"
                                                                 : @"Unavailable from iOS";
    NSString *protocol = destination[@"protocol"];
    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
        @[ @"Direction", directionTitle ],
        @[ @"Protocol", protocol.length ? protocol.uppercaseString : @"Unavailable from iOS" ]
    ]];
    for (NSArray *field in @[ @[ @"domain", @"Domain" ], @[ @"address", @"IP address" ] ]) {
        NSString *value = NSCleanDestinationHost(destination[field[0]]);
        if (value.length) {
            [rows addObject:@[ field[1], value ]];
        }
    }
    for (NSArray *field in @[ @[ @"localPort", @"Local port" ], @[ @"port", @"Remote port" ] ]) {
        NSNumber *port = destination[field[0]];
        if (port.integerValue >= 1 && port.integerValue <= 65535) {
            [rows addObject:@[ field[1], port.stringValue ]];
        }
    }
    if (rows.count == 2) {
        [rows addObject:@[ @"Endpoints", @"Unavailable from iOS" ]];
    }
    return rows;
}
