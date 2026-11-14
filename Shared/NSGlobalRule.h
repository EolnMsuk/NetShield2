#import <Foundation/Foundation.h>
#import "NSConstants.h"
#import "NSDestination.h"
#import "NSPolicy.h"

// Schema 5 accepts only condition:<sorted JSON object> global rule keys.
// Host keys identify observed endpoints/DNS entries, never saved global rules.
FOUNDATION_EXPORT NSString *NSGlobalHostKey(id value);
FOUNDATION_EXPORT NSString *NSGlobalPortKey(id value);
FOUNDATION_EXPORT NSString *NSGlobalLocalPortKey(id value);
FOUNDATION_EXPORT NSDictionary *NSCanonicalConnectionDestination(NSDictionary *destination);
FOUNDATION_EXPORT BOOL NSGlobalActionIsAllow(NSString *action);
FOUNDATION_EXPORT NSString *NSMergeGlobalActions(NSString *left, NSString *right);
FOUNDATION_EXPORT NSString *NSGlobalCoverage(NSString *action);

// Empty arrays mean unrestricted. Destination fields are AND; alternatives OR.
FOUNDATION_EXPORT NSArray *NSGlobalParseDestinations(NSString *text);
FOUNDATION_EXPORT NSArray *NSGlobalParsePorts(NSString *text);
FOUNDATION_EXPORT NSString *NSGlobalDestinationsText(NSArray *destinations);
FOUNDATION_EXPORT NSString *NSGlobalPortsText(NSArray *ports);
FOUNDATION_EXPORT NSDictionary *NSGlobalCondition(NSArray *identities, NSArray *destinations,
                                                  NSArray *remotePorts, NSArray *localPorts,
                                                  NSArray *protocols, NSString *direction,
                                                  BOOL resolveDomains);
FOUNDATION_EXPORT NSString *NSGlobalRuleKey(NSDictionary *condition);
FOUNDATION_EXPORT NSDictionary *NSGlobalRuleCondition(NSString *key);
FOUNDATION_EXPORT NSString *NSExactGlobalRuleKey(NSArray<NSString *> *identities, NSDictionary *destination,
                                                 NSString *coverage);
FOUNDATION_EXPORT BOOL NSValidGlobalRuleKey(id key);
FOUNDATION_EXPORT BOOL NSGlobalCoverageAgrees(NSString *key, NSString *action);
FOUNDATION_EXPORT NSUInteger NSGlobalConditionCost(NSDictionary *condition);

// Compile once, then share byte intervals and sets between validation/evaluation.
FOUNDATION_EXPORT NSDictionary *NSCompileGlobalCondition(NSDictionary *condition);
FOUNDATION_EXPORT BOOL NSGlobalConditionsIntersect(NSDictionary *left, NSDictionary *right);
FOUNDATION_EXPORT NSArray *NSCompileGlobalRules(NSDictionary *rules, NSError **error);
FOUNDATION_EXPORT BOOL NSValidateGlobalRuleChange(NSDictionary *rules, NSString *key, NSString *action,
                                                  NSString *original, NSError **error);
FOUNDATION_EXPORT NSDictionary *NSGlobalRuleConditions(NSDictionary *rules);

typedef NS_ENUM(NSInteger, NSGlobalMatch) {
    NSGlobalMismatch,
    NSGlobalMissingEndpoints,
    NSGlobalMatched,
};
FOUNDATION_EXPORT NSGlobalMatch NSMatchGlobalCondition(NSDictionary *compiled, NSString *identity,
                                                       NSFlowDirection direction, NSDictionary *destination,
                                                       BOOL allow, NSDictionary *document);
