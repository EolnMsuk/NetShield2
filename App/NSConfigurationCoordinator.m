#import "NSConfigurationCoordinator.h"
#import "NSFilterBootPolicy.h"
#import "../Shared/NSStore.h"
#include <errno.h>
#import <CommonCrypto/CommonDigest.h>
#import "../Shared/NSValidation.h"
#import "../Shared/NSBootSession.h"

@protocol NSReceiptConfiguration <NSObject>
@property(nonatomic, copy) NSDictionary *vendorConfiguration;
@end

@protocol NSConfigurationPreferences <NSObject>
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
@optional
- (id<NSReceiptConfiguration>)providerConfiguration;
- (BOOL)isEnabled;
@end

@interface NSConfigurationCoordinator ()
@property(nonatomic, strong) NSStoreLock *lock;
@property(nonatomic, copy) NSString *operation;
@property(nonatomic) NSUInteger phase;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL readOnly;
@property(nonatomic) BOOL pendingWrite;
@property(nonatomic) BOOL saveProbeInFlight;
@property(nonatomic, readwrite) BOOL uncertain;
@property(nonatomic, readwrite) BOOL reconciledMarker;
@property(nonatomic, readwrite) BOOL pendingRemoval;
@property(nonatomic, readwrite) NSConfigurationMarkerState markerState;
@property(nonatomic, readwrite) NSError *markerError;
@property(nonatomic, copy) NSDictionary *recoverySave;
@property(nonatomic, copy) void (^checkSave)(void);
@property(nonatomic, copy) void (^phaseCompletion)(NSError *);
@property(nonatomic, readwrite) NSError *acknowledgementError;
@property(nonatomic, strong) dispatch_source_t phaseTimer;
@property(nonatomic, strong) dispatch_source_t overallTimer;
@end

NSNotificationName const NSConfigurationLateAcknowledgement = @"NSConfigurationLateAcknowledgement";
NSString *const NSPreferenceSaveReceiptKey = @"netShieldPreferenceSaveReceipt";
static __weak NSConfigurationCoordinator *NSPendingSaveOwner;
static const NSUInteger NSMarkerDecodeLimit = 8192;
static NSError *NSConfigurationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Configuration"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSError *NSMarkerError(NSString *message, NSError *underlying) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey : message} mutableCopy];
    if (underlying) {
        info[NSLocalizedDescriptionKey] =
            [NSString stringWithFormat:@"%@ %@ (%@ %ld).", message, underlying.localizedDescription,
                                       underlying.domain, (long)underlying.code];
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:@"NetShield2.Configuration"
                               code:underlying ? underlying.code : EINVAL
                           userInfo:info];
}
static NSString *NSNormalizedUUID(id value) {
    return NSBoundedString(value, 36, YES) ? [[NSUUID alloc] initWithUUIDString:value].UUIDString : nil;
}
static id<NSReceiptConfiguration> NSReceiptProvider(id<NSConfigurationPreferences> manager) {
    id provider =
        [manager respondsToSelector:@selector(providerConfiguration)] ? manager.providerConfiguration : nil;
    return [provider respondsToSelector:@selector(vendorConfiguration)] ? provider : nil;
}
static NSString *NSSavedReceipt(id<NSConfigurationPreferences> manager) {
    id vendor = NSReceiptProvider(manager).vendorConfiguration;
    return [vendor isKindOfClass:NSDictionary.class] ? NSNormalizedUUID(vendor[NSPreferenceSaveReceiptKey])
                                                     : nil;
}
static NSDictionary *NSDecodeMarker(NSData *data) {
    if (!data || data.length > NSMarkerDecodeLimit) {
        return nil;
    }
    id document = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:NULL];
    return [document isKindOfClass:NSDictionary.class] ? document : nil;
}
static NSData *NSMarkerFingerprint(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
static BOOL NSVersionOne(id version) {
    return NSUnsignedInteger(version, 1) && [version unsignedIntegerValue] == 1;
}

// If writing the acknowledgement itself failed, retain evidence of this exact
// submitted record in this process. Only one write can own the lock at a time.
static NSDictionary *NSLocalAcknowledgement;
static struct stat NSAcknowledgedDirectory;
static BOOL NSMatchesLocalAcknowledgement(NSDictionary *record, NSSharedDirectory *directory) {
    struct stat info;
    return NSLocalAcknowledgement && [NSLocalAcknowledgement isEqual:record] &&
           !fstat(directory.descriptor, &info) && info.st_ino == NSAcknowledgedDirectory.st_ino &&
           info.st_dev == NSAcknowledgedDirectory.st_dev;
}

static void NSDeliverPreferenceCallback(void (^work)(void)) {
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

@implementation NSConfigurationCoordinator
+ (void)checkPendingSave {
    NSConfigurationCoordinator *owner = NSPendingSaveOwner;
    if (owner.checkSave) {
        owner.checkSave();
    }
}
- (instancetype)init {
    if ((self = [super init])) {
        _durableFence = YES;
        _acquireLock = ^NSStoreLock *(NSError **error) {
            return [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:NSConfigurationLockFile error:error];
        };
        _bootIdentifier = ^{
            return NSBootSessionIdentifier();
        };
        _retireDocument = ^BOOL(NSSharedDirectory *directory, NSString *leaf, NSError **error) {
            return NSUnlinkBoundedFile(directory, leaf, error);
        };
    }
    return self;
}
- (NSSharedDirectory *)directory {
    return self.lock.directory;
}
- (NSError *)writeErrorWithPreferenceError:(NSError *)preferenceError readbackError:(NSError *)readbackError {
    NSError *primary = preferenceError ?: self.acknowledgementError ?: readbackError;
    if ((!self.acknowledgementError || primary == self.acknowledgementError) &&
        (!readbackError || primary == readbackError)) {
        return primary;
    }
    NSMutableDictionary *info = [primary.userInfo mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray *details = [NSMutableArray arrayWithObject:primary.localizedDescription];
    if (self.acknowledgementError && primary != self.acknowledgementError) {
        info[@"acknowledgementError"] = self.acknowledgementError;
        [details addObject:self.acknowledgementError.localizedDescription];
    }
    if (readbackError && primary != readbackError) {
        info[@"readbackError"] = readbackError;
        [details addObject:[NSString stringWithFormat:@"Saved preference readback: %@ (%@ %ld).",
                                                      readbackError.localizedDescription,
                                                      readbackError.domain, (long)readbackError.code]];
    }
    info[NSLocalizedDescriptionKey] = [details componentsJoinedByString:@" "];
    return [NSError errorWithDomain:primary.domain code:primary.code userInfo:info];
}
- (BOOL)retireMarker:(NSError **)error {
    if (!self.retireDocument(self.directory, NSPendingConfigurationFile, error)) {
        return NO;
    }
    NSLocalAcknowledgement = nil;
    return self.retireDocument(self.directory, NSConfigurationRecoveryFile, error);
}
- (NSConfigurationMarkerState)reconcile:(NSError **)error {
    if (!self.durableFence) {
        return NSConfigurationMarkerNone;
    }
    NSError *storageError = nil;
    NSData *bytes = NSReadBoundedFile(self.directory, NSPendingConfigurationFile, &storageError);
    if (!bytes) {
        if (NSFileIsAbsent(storageError)) {
            if (self.retireDocument(self.directory, NSConfigurationRecoveryFile, &storageError)) {
                return NSConfigurationMarkerNone;
            }
            if (error) {
                *error = NSMarkerError(@"Clear the remaining local preference recovery record, then refresh.",
                                       storageError);
            }
            return NSConfigurationMarkerAcknowledged;
        }
        if (error) {
            *error = NSMarkerError(@"The pending preference record is unreadable. Restore shared storage "
                                   @"access and refresh. Filter settings remain available in iOS Settings.",
                                   storageError);
        }
        return NSConfigurationMarkerInvalid;
    }
    NSDictionary *marker = NSDecodeMarker(bytes);
    id version = marker[@"version"];
    BOOL legacy = version == nil;
    BOOL receiptVersion = NSUnsignedInteger(version, 2) && [version isEqual:@2];
    NSString *receipt = receiptVersion ? NSNormalizedUUID(marker[@"receipt"]) : nil;
    if (!legacy && !receiptVersion && !NSVersionOne(version)) {
        if (error) {
            *error = NSMarkerError(@"The pending preference record uses an unsupported format. Open it with "
                                   @"a compatible NetShield2 version or check the filter in iOS Settings.",
                                   nil);
        }
        return NSConfigurationMarkerInvalid;
    }
    NSString *boot = NSNormalizedUUID(self.bootIdentifier());
    NSString *recordedBoot = NSNormalizedUUID(marker[@"boot"]);
    BOOL acknowledged = [marker[@"state"] isEqual:@"acknowledged"];
    BOOL valid = NSNormalizedUUID(marker[@"operation"]) &&
                 NSUnsignedInteger(marker[@"phase"], NSUIntegerMax) &&
                 [marker[@"phase"] unsignedIntegerValue] > 0 &&
                 (legacy || (([marker[@"kind"] isEqual:@"save"] || [marker[@"kind"] isEqual:@"remove"]) &&
                             (!receiptVersion || (receipt && [marker[@"kind"] isEqual:@"save"])) &&
                             (acknowledged || [marker[@"state"] isEqual:@"pending"]) &&
                             ((recordedBoot && [marker[@"bootState"] isEqual:@"known"]) ||
                              (!marker[@"boot"] && [marker[@"bootState"] isEqual:@"unavailable"]))));
    NSConfigurationMarkerState state = NSConfigurationMarkerInvalid;
    if (valid && ((!legacy && acknowledged) || NSMatchesLocalAcknowledgement(marker, self.directory))) {
        state = NSConfigurationMarkerAcknowledged;
    } else if (valid && recordedBoot) {
        state = boot && ![recordedBoot isEqual:boot] ? NSConfigurationMarkerPriorBoot
                                                     : NSConfigurationMarkerUnresolved;
    } else {
        if (valid && !legacy) {
            state = NSConfigurationMarkerUnresolved;
        }
        NSData *fingerprint = NSMarkerFingerprint(bytes);
        NSError *witnessError = nil;
        NSData *witnessBytes = NSReadBoundedFile(self.directory, NSConfigurationRecoveryFile, &witnessError);
        NSDictionary *witness = NSDecodeMarker(witnessBytes);
        NSString *witnessBoot = NSVersionOne(witness[@"version"]) ? NSNormalizedUUID(witness[@"boot"]) : nil;
        BOOL sameMarker = witnessBoot && [fingerprint isEqual:witness[@"fingerprint"]];
        if (!witnessBytes && !NSFileIsAbsent(witnessError)) {
            if (error) {
                *error = NSMarkerError(@"Read the preference recovery witness failed. Restore shared storage "
                                       @"access and refresh.",
                                       witnessError);
            }
            return NSConfigurationMarkerInvalid;
        }
        if (boot && sameMarker && ![witnessBoot isEqual:boot]) {
            state = NSConfigurationMarkerPriorBoot;
        } else if (boot && !sameMarker &&
                   !NSWriteDocumentIn(self.directory,
                                      @{@"version" : @1, @"fingerprint" : fingerprint, @"boot" : boot},
                                      NSConfigurationRecoveryFile, &witnessError)) {
            if (error) {
                *error = NSMarkerError(@"Record the kernel boot for preference recovery failed. "
                                       @"Restore shared storage access and refresh.",
                                       witnessError);
            }
            return NSConfigurationMarkerInvalid;
        }
    }
    if (state == NSConfigurationMarkerAcknowledged || state == NSConfigurationMarkerPriorBoot) {
        // Match the same record under the configuration lock before unlinking.
        NSData *current = NSReadBoundedFile(self.directory, NSPendingConfigurationFile, &storageError);
        if ([bytes isEqual:current] && [self retireMarker:&storageError]) {
            self.reconciledMarker = YES;
            return NSConfigurationMarkerNone;
        }
        if (error) {
            *error = NSMarkerError(
                state == NSConfigurationMarkerAcknowledged
                    ? @"The OS acknowledged the preference write. Local cleanup is pending. Refresh to retry."
                    : @"A prior kernel boot was verified. Local preference record cleanup is pending. "
                      @"Refresh to retry.",
                storageError);
        }
        return state;
    }
    self.pendingRemoval =
        state == NSConfigurationMarkerUnresolved && !legacy && [marker[@"kind"] isEqual:@"remove"];
    if (state == NSConfigurationMarkerUnresolved && receipt) {
        self.recoverySave = marker;
    }
    if (error) {
        NSString *message;
        if (!boot) {
            message = @"The kernel boot identity is unavailable. The preference write cannot be ruled out. "
                      @"Check the filter in iOS Settings and refresh when boot identity is available.";
        } else if (state == NSConfigurationMarkerUnresolved && recordedBoot) {
            NSString *operation =
                legacy ? @"preference write" : (self.pendingRemoval ? @"filter removal" : @"filter save");
            message = [NSString stringWithFormat:@"An earlier %@ may still complete. If the original app "
                                                 @"session has ended, fully reboot the device, return to the "
                                                 @"jailbreak and refresh. A respring "
                                                 @"does not clear this recovery state.",
                                                 operation];
        } else {
            message = @"The pending preference record has no usable boot evidence. This boot has been "
                      @"recorded for recovery. Reboot the device, then refresh. A respring is insufficient.";
        }
        *error = NSMarkerError(message, nil);
    }
    return state;
}
- (void)deadline:(NSTimeInterval)delay overall:(BOOL)overall work:(void (^)(void))work {
    if (self.schedule) {
        self.schedule(delay, work);
        return;
    }
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) {
        work();
        return;
    }
    if (overall) {
        self.overallTimer = timer;
    } else {
        self.phaseTimer = timer;
    }
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    dispatch_source_set_event_handler(timer, work);
    dispatch_resume(timer);
}
- (void)cancelPhaseTimer {
    if (self.phaseTimer) {
        dispatch_source_cancel(self.phaseTimer);
    }
    self.phaseTimer = nil;
}
- (BOOL)begin:(NSError **)error {
    return [self beginWithDeadline:120 error:error];
}
- (BOOL)beginWithAuthorizationBudget:(NSError **)error {
    // Initial staging and activation can each need a separate authorization phase.
    return [self beginWithDeadline:180 error:error];
}
- (BOOL)beginWithDeadline:(NSTimeInterval)duration error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (self.active || self.pendingWrite || self.saveProbeInFlight) {
        if (error) {
            *error =
                NSConfigurationError(EBUSY, @"A configuration operation or unresolved write is pending.");
        }
        return NO;
    }
    self.reconciledMarker = NO;
    self.pendingRemoval = NO;
    self.lock = self.acquireLock(error);
    if (!self.lock) {
        if (error && !*error) {
            *error = NSConfigurationError(EBUSY, @"Configuration ownership is unavailable.");
        }
        return NO;
    }
    [self inspectMarker];
    if (self.markerState != NSConfigurationMarkerNone && !self.recoverySave) {
        if (error) {
            *error = self.markerError;
        }
        [self.lock unlock];
        self.lock = nil;
        return NO;
    }
    self.acknowledgementError = nil;
    self.readOnly = NO;
    self.operation = NSUUID.UUID.UUIDString;
    self.active = YES;
    self.uncertain = NO;
    NSString *operation = self.operation;
    __weak typeof(self) weakSelf = self;
    [self deadline:duration
           overall:YES
              work:^{
                  NSConfigurationCoordinator *owner = weakSelf;
                  if (owner.active && [owner.operation isEqual:operation]) {
                      owner.uncertain = YES;
                      void (^abort)(NSError *) = owner.abort;
                      if (abort) {
                          abort(NSConfigurationError(
                              ETIMEDOUT,
                              @"The overall configuration deadline expired. Saved state is unverified."));
                      }
                  }
              }];
    return self.active;
}
- (void)inspectMarker {
    self.recoverySave = nil;
    NSError *error = nil;
    self.markerState = [self reconcile:&error];
    self.markerError = error;
}
- (NSConfigurationMarkerState)beginReadOnly:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (self.active || self.pendingWrite || self.saveProbeInFlight) {
        if (error) {
            *error = NSConfigurationError(EBUSY, @"Configuration inspection is busy.");
        }
        return NSConfigurationMarkerUnavailable;
    }
    self.reconciledMarker = NO;
    self.pendingRemoval = NO;
    NSError *lockError = nil;
    self.lock = self.acquireLock(&lockError);
    self.readOnly = YES;
    self.active = YES;
    self.uncertain = NO;
    if (!self.lock) {
        self.markerState = NSConfigurationMarkerUnavailable;
        self.markerError = lockError;
        if (error) {
            *error = lockError;
        }
        return self.markerState;
    }
    [self inspectMarker];
    if (error) {
        *error = self.markerError;
    }
    return self.markerState;
}

- (NSError *)acknowledge:(NSDictionary *)expected {
    if (!fstat(self.directory.descriptor, &NSAcknowledgedDirectory)) {
        NSLocalAcknowledgement = expected;
    }
    NSError *error = nil;
    NSDictionary *pending = NSReadDocumentIn(self.directory, NSPendingConfigurationFile, &error);
    // Equality includes the captured operation ID and phase, even after a timeout.
    if (![expected isEqual:pending]) {
        return NSMarkerError(@"The OS acknowledged the write, but its local preference record could "
                             @"not be matched. Refresh to inspect it again.",
                             error);
    }
    NSMutableDictionary *acknowledged = [expected mutableCopy];
    acknowledged[@"state"] = @"acknowledged";
    NSError *writeError = nil;
    if (!NSWriteDocumentIn(self.directory, acknowledged, NSPendingConfigurationFile, &writeError)) {
        // A failed publication can leave either representation. Never remove
        // a record belonging to another phase or operation.
        pending = NSReadDocumentIn(self.directory, NSPendingConfigurationFile, &error);
        if (![expected isEqual:pending] && ![acknowledged isEqual:pending]) {
            return NSMarkerError(@"The OS acknowledged the write, but its acknowledgement could not "
                                 @"be stored or matched. Refresh to retry.",
                                 error ?: writeError);
        }
    }
    if (![self retireMarker:&error]) {
        return NSMarkerError(@"The OS acknowledged the preference write. Local cleanup is pending. "
                             @"Refresh to retry.",
                             error ?: writeError);
    }
    return nil;
}

- (void)reconcileLoadedSave:(id<NSConfigurationPreferences>)manager {
    NSDictionary *record = self.recoverySave;
    if (!record || ![NSSavedReceipt(manager) isEqual:NSNormalizedUUID(record[@"receipt"])]) {
        return;
    }
    // The unique receipt can only reach the saved profile through this
    // submission. A matching enabled flag or an older profile proves nothing.
    NSError *error = [self acknowledge:record];
    self.markerError = error;
    self.markerState = error ? NSConfigurationMarkerAcknowledged : NSConfigurationMarkerNone;
    if (!error) {
        self.reconciledMarker = YES;
        self.recoverySave = nil;
        NSLog(@"NetShield2 preference save receipt verified during refresh");
    }
}

- (void)completePhase:(NSUInteger)phase error:(NSError *)error {
    if (!self.active || self.phase != phase) {
        return;
    }
    void (^completion)(NSError *) = self.phaseCompletion;
    self.phaseCompletion = nil;
    self.phase++;
    [self cancelPhaseTimer];
    completion(error);
}

- (void)completeWritePhase:(NSUInteger)phase error:(NSError *)error {
    if (self.active && self.phase == phase) {
        [self completePhase:phase error:error];
        return;
    }
    if (!self.active && !self.pendingWrite && !self.saveProbeInFlight) {
        [self.lock unlock];
        self.lock = nil;
    }
    // A late proof releases ownership without resuming an expired transaction.
    [NSNotificationCenter.defaultCenter postNotificationName:NSConfigurationLateAcknowledgement object:nil];
}

- (NSDictionary *)prepareWrite:(NSUInteger)kind
                       manager:(id<NSConfigurationPreferences>)manager
                         phase:(NSUInteger)phase
                         error:(NSError **)error {
    NSString *boot = NSNormalizedUUID(self.bootIdentifier());
    id<NSReceiptConfiguration> provider = kind == 1 ? NSReceiptProvider(manager) : nil;
    NSString *receipt = provider ? NSUUID.UUID.UUIDString : nil;
    NSMutableDictionary *prepared = [@{
        @"version" : receipt ? @2 : @1,
        @"operation" : self.operation,
        @"phase" : @(phase),
        @"kind" : kind == 1 ? @"save" : @"remove",
        @"state" : @"pending",
        @"bootState" : boot ? @"known" : @"unavailable"
    } mutableCopy];
    prepared[@"boot"] = boot;
    prepared[@"receipt"] = receipt;
    NSDictionary *record = [prepared copy];
    NSError *prepareError = nil;
    BOOL published = NSWriteDocumentIn(self.directory, record, NSPendingConfigurationFile, &prepareError);
    NSError *readError = nil;
    NSDictionary *checked = NSReadDocumentIn(self.directory, NSPendingConfigurationFile, &readError);
    BOOL checkedRecord = [record isEqual:checked];
    if (published && checkedRecord &&
        (!receipt || [self stampReceipt:receipt provider:provider manager:manager error:&prepareError])) {
        return record;
    }

    // No OS call happened. Retire only our own preparation, if identifiable.
    NSError *cleanupError = nil;
    if (checkedRecord && ![self retireMarker:&cleanupError] &&
        !fstat(self.directory.descriptor, &NSAcknowledgedDirectory)) {
        NSLocalAcknowledgement = record;
    }
    self.acknowledgementError =
        cleanupError ? NSMarkerError(@"Local preference preparation cleanup is pending. Refresh to retry.",
                                     cleanupError)
                     : nil;
    *error = NSMarkerError(@"Prepare preference write failed before dispatch.", prepareError ?: readError);
    return nil;
}

- (BOOL)stampReceipt:(NSString *)receipt
            provider:(id<NSReceiptConfiguration>)provider
             manager:(id<NSConfigurationPreferences>)manager
               error:(NSError **)error {
    NSDictionary *vendor = provider.vendorConfiguration ?: @{};
    if ([vendor isKindOfClass:NSDictionary.class] &&
        [provider respondsToSelector:@selector(setVendorConfiguration:)]) {
        NSMutableDictionary *metadata = [vendor mutableCopy];
        metadata[NSPreferenceSaveReceiptKey] = receipt;
        provider.vendorConfiguration = metadata;
        if ([NSSavedReceipt(manager) isEqual:receipt]) {
            if (![manager respondsToSelector:@selector(isEnabled)] || ![manager isEnabled]) {
                return YES;
            }
            BOOL fallback = NO;
            if (!NSFilterBootPolicyRead(provider, &fallback, error)) {
                return NO;
            }
            if (fallback) {
                return YES;
            }
        }
    }
    *error = NSConfigurationError(EINVAL, @"Could not verify the save receipt and required fallback.");
    return NO;
}

- (void)expirePhase:(NSUInteger)phase {
    if (!self.active || self.phase != phase) {
        return;
    }
    self.uncertain = YES;
    NSString *message = self.pendingWrite
                            ? @"Preference write timed out and may still complete. Saved state is unverified."
                            : @"Preference completion or readback timed out. Saved state is unverified.";
    [self completePhase:phase error:NSConfigurationError(ETIMEDOUT, message)];
}

- (void)perform:(NSUInteger)kind
    authorization:(BOOL)authorization
          manager:(id<NSConfigurationPreferences>)manager
       completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (kind && (self.acknowledgementError || self.recoverySave)) {
        completion(self.acknowledgementError ?: self.markerError);
        return;
    }
    if (!self.active || self.pendingWrite || self.saveProbeInFlight || self.uncertain ||
        (kind && self.readOnly)) {
        completion(NSConfigurationError(EBUSY, @"Configuration is busy or an earlier result is unverified."));
        return;
    }
    NSUInteger phase = ++self.phase;
    self.phaseCompletion = completion;
    __weak typeof(self) weakSelf = self;
    __weak id<NSConfigurationPreferences> weakManager = manager;
    [self deadline:authorization ? 60 : 10
           overall:NO
              work:^{
                  NSConfigurationCoordinator *owner = weakSelf;
                  if (!owner.active || owner.phase != phase) {
                      return;
                  }
                  if (!owner.checkSave || owner.saveProbeInFlight) {
                      [owner expirePhase:phase];
                      return;
                  }
                  // One final bounded check also covers a missing configuration-change
                  // notification. A nonmatching read leaves the original fence intact.
                  [owner cancelPhaseTimer];
                  [owner deadline:10
                          overall:NO
                             work:^{
                                 [weakSelf expirePhase:phase];
                             }];
                  if (owner.active && owner.phase == phase && owner.checkSave) {
                      owner.checkSave();
                  }
              }];
    if (!self.active || self.phase != phase) {
        return;
    }
    NSDictionary *record = nil;
    if (kind && self.durableFence) {
        NSError *prepareError = nil;
        record = [self prepareWrite:kind manager:manager phase:phase error:&prepareError];
        if (!record) {
            [self completePhase:phase error:prepareError];
            return;
        }
    }
    __block BOOL settled = NO;
    __block NSError *settledError = nil;
    void (^settle)(NSConfigurationCoordinator *, NSError *, BOOL) =
        ^(NSConfigurationCoordinator *owner, NSError *error, BOOL receipt) {
            if (!owner || settled) {
                return;
            }
            settled = YES;
            settledError = error;
            if (kind) {
                owner.pendingWrite = NO;
                owner.checkSave = nil;
                if (NSPendingSaveOwner == owner) {
                    NSPendingSaveOwner = nil;
                }
                if (record) {
                    owner.acknowledgementError = [owner acknowledge:record];
                    NSLog(@"NetShield2 preference %@ %@ phase=%lu os=%@/%ld local=%@/%ld", record[@"kind"],
                          receipt ? @"receipt verified" : @"callback", (unsigned long)phase,
                          error.domain ?: @"ok", (long)error.code, owner.acknowledgementError.domain ?: @"ok",
                          (long)owner.acknowledgementError.code);
                }
                if (!owner.saveProbeInFlight) {
                    [owner completeWritePhase:phase error:error];
                }
                return;
            } else if (owner.active && owner.phase == phase && !error) {
                [owner reconcileLoadedSave:weakManager];
                if (!owner.readOnly && owner.recoverySave) {
                    settledError = owner.markerError;
                }
            }
            [owner completePhase:phase error:settledError];
        };
    if (record[@"receipt"]) {
        NSPendingSaveOwner = self;
        self.checkSave = ^{
            NSConfigurationCoordinator *owner = weakSelf;
            id<NSConfigurationPreferences> currentManager = weakManager;
            if (settled || owner.saveProbeInFlight || !owner.pendingWrite || !currentManager) {
                return;
            }
            owner.saveProbeInFlight = YES;
            __block BOOL delivered = NO;
            [currentManager loadFromPreferencesWithCompletionHandler:^(NSError *readError) {
                NSDeliverPreferenceCallback(^{
                    if (delivered) {
                        return;
                    }
                    delivered = YES;
                    owner.saveProbeInFlight = NO;
                    if (settled) {
                        // A save callback that arrived during this read already
                        // retired its marker. Wait for this read before advancing.
                        [owner completeWritePhase:phase error:settledError];
                    } else if (!readError &&
                               [NSSavedReceipt(weakManager) isEqual:NSNormalizedUUID(record[@"receipt"])]) {
                        settle(owner, nil, YES);
                    }
                });
            }];
        };
    }
    // The OS retains this owner while it retains the callback. A lost callback
    // can also be reconciled from the durable record on a subsequent launch.
    void (^callback)(NSError *) = ^(NSError *error) {
        NSDeliverPreferenceCallback(^{
            settle(self, error, NO);
        });
    };
    self.pendingWrite = kind != 0;
    if (kind && self.durableFence) {
        NSLog(@"NetShield2 preference %@ submitted phase=%lu authorization=%d",
              kind == 1 ? @"save" : @"remove", (unsigned long)phase, authorization);
    }
    if (kind == 1) {
        [manager saveToPreferencesWithCompletionHandler:callback];
    } else if (kind == 2) {
        [manager removeFromPreferencesWithCompletionHandler:callback];
    } else {
        [manager loadFromPreferencesWithCompletionHandler:callback];
    }
}
- (void)load:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:0 authorization:NO manager:manager completion:completion];
}
- (void)save:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:1 authorization:NO manager:manager completion:completion];
}
- (void)saveWithAuthorization:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:1 authorization:YES manager:manager completion:completion];
}
- (void)remove:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:2 authorization:NO manager:manager completion:completion];
}
- (void)finish {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    self.active = NO;
    self.phase++;
    self.phaseCompletion = nil;
    self.abort = nil;
    [self cancelPhaseTimer];
    if (self.overallTimer) {
        dispatch_source_cancel(self.overallTimer);
    }
    self.overallTimer = nil;
    if (!self.pendingWrite && !self.saveProbeInFlight) {
        [self.lock unlock];
        self.lock = nil;
    }
}
@end
