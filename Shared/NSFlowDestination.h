#import <NetworkExtension/NetworkExtension.h>
#import "NSDestination.h"
#import "NSGlobalRule.h"

static inline NSDictionary *NSDestinationForFlow(NEFilterFlow *flow) {
    NSString *domain = NSCleanDestinationHost(flow.URL.host);
    NSString *address = @"";
    NSNumber *port = flow.URL.port;
    if (!port && [flow.URL.scheme.lowercaseString isEqual:@"https"]) {
        port = @443;
    }
    if (!port && [flow.URL.scheme.lowercaseString isEqual:@"http"]) {
        port = @80;
    }
    if ([flow isKindOfClass:NEFilterSocketFlow.class]) {
        NEFilterSocketFlow *socket = (NEFilterSocketFlow *)flow;
        NSString *hostname = NSCleanDestinationHost(socket.remoteHostname);
        if (hostname.length) {
            domain = hostname;
        }
        if ([socket.remoteEndpoint isKindOfClass:NWHostEndpoint.class]) {
            NSString *portKey = NSGlobalPortKey(((NWHostEndpoint *)socket.remoteEndpoint).port);
            port = portKey ? @([[portKey substringFromIndex:5] integerValue]) : nil;
            NSString *host = NSCleanDestinationHost(((NWHostEndpoint *)socket.remoteEndpoint).hostname);
            struct in6_addr bytes;
            if (inet_pton(AF_INET, host.UTF8String, &bytes) == 1 ||
                inet_pton(AF_INET6, host.UTF8String, &bytes) == 1) {
                address = host;
            } else if (!domain.length) {
                domain = host;
            }
        }
    }
    // URL hosts can themselves be literal IP addresses.
    NSString *hostKey = NSGlobalHostKey(domain);
    if ([hostKey hasPrefix:@"ip:"]) {
        if (!address.length) {
            address = [hostKey substringFromIndex:3];
        }
        domain = @"";
    }
    NSMutableDictionary *destination = [@{@"domain" : domain, @"address" : address} mutableCopy];
    if (port.integerValue >= 1 && port.integerValue <= 65535) {
        destination[@"port"] = port;
    }
    return destination;
}
