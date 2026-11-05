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
@property(nonatomic, readwrite, strong) NSSharedDirectory *directory;
@property(nonatomic, copy) NSDictionary *reservation;
@property(nonatomic, strong) NSMutableArray<NSConfigurationAccess *> *localAccesses;
@property(nonatomic, copy) void (^resumePhase)(void);
@property(nonatomic, copy) void (^resumeAcknowledgement)(void);
@property(nonatomic, copy) NSString *operation;
@property(nonatomic) NSUInteger phase;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL readOnly;
@property(nonatomic) BOOL pendingWrite;
@property(nonatomic) BOOL acknowledging;
@property(nonatomic, weak) id preferenceManager;
@property(nonatomic) BOOL readInFlight;
@property(nonatomic) BOOL abandonedRead;
@property(nonatomic) NSUInteger probeGeneration;
@property(nonatomic) NSTimeInterval phaseExpiry;
@property(nonatomic) NSTimeInterval overallExpiry;
@property(nonatomic) NSConfigurationRecoveryAction markerRecovery;
@property(nonatomic, readwrite) BOOL uncertain;
@property(nonatomic, readwrite) BOOL reconciledMarker;
@property(nonatomic, readwrite) BOOL pendingRemoval;
@property(nonatomic, readwrite) NSConfigurationMarkerState markerState;
@property(nonatomic, readwrite) NSError *markerError;
@property(nonatomic, copy) NSDictionary *recoverySave;
@property(nonatomic, copy) void (^checkSave)(BOOL finalCheck);
@property(nonatomic, copy) void (^phaseCompletion)(NSError *);
@property(nonatomic, strong) NSError *preferenceCallbackError;
@property(nonatomic, readwrite) NSError *acknowledgementError;
@property(nonatomic, strong) dispatch_source_t phaseTimer;
@property(nonatomic, strong) dispatch_source_t overallTimer;
@end

NSNotificationName const NSConfigurationLateAcknowledgement = @"NSConfigurationLateAcknowledgement";
NSString *const NSPreferenceSaveReceiptKey = @"netShieldPreferenceSaveReceipt";
static __weak NSConfigurationCoordinator *NSPendingSaveOwner;
// The manager is mutable and its loads cannot be cancelled. Keep the lane
// reserved even when a caller has stopped waiting for the callback.
static NSMapTable *NSPreferenceOwners(void) {
    static NSMapTable *owners;
    if (!owners) {
        owners = [NSMapTable
            mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsStrongMemory];
    }
    return owners;
}
static NSHashTable *NSConfigurationOwners(void) {
    static NSHashTable *owners;
    if (!owners) {
        owners = [NSHashTable weakObjectsHashTable];
    }
    return owners;
}
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
static NSData *NSMarkerFingerprint(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
static BOOL NSVersionOne(id version) {
    return NSUnsignedInteger(version, 1) && [version unsignedIntegerValue] == 1;
}

// Delivered OS proof is main-queue memory, keyed by exact record and pinned
// directory. A stale callback must not overwrite proof for a newer write.
static NSMutableArray<NSDictionary *> *NSLocalAcknowledgements;
static void NSRememberAcknowledgement(NSDictionary *record, NSSharedDirectory *directory) {
    if (!record || !directory) {
        return;
    }
    if (!NSLocalAcknowledgements) {
        NSLocalAcknowledgements = [NSMutableArray new];
    }
    for (NSDictionary *proof in NSLocalAcknowledgements) {
        if ([record isEqual:proof[@"record"]] &&
            NSConfigurationSameDirectory(directory, proof[@"directory"])) {
            return;
        }
    }
    [NSLocalAcknowledgements addObject:@{@"record" : record, @"directory" : directory}];
}
static BOOL NSMatchesLocalAcknowledgement(NSDictionary *record, NSSharedDirectory *directory) {
    for (NSDictionary *proof in NSLocalAcknowledgements) {
        if ([record isEqual:proof[@"record"]] &&
            NSConfigurationSameDirectory(directory, proof[@"directory"])) {
            return YES;
        }
    }
    return NO;
}
static void NSForgetAcknowledgement(NSSharedDirectory *directory) {
    for (NSDictionary *proof in [NSLocalAcknowledgements copy]) {
        if (NSConfigurationSameDirectory(directory, proof[@"directory"])) {
            [NSLocalAcknowledgements removeObjectIdenticalTo:proof];
        }
    }
}
static void NSDiscardAcknowledgement(NSDictionary *record, NSSharedDirectory *directory) {
    for (NSDictionary *proof in [NSLocalAcknowledgements copy]) {
        if ([record isEqual:proof[@"record"]] &&
            NSConfigurationSameDirectory(directory, proof[@"directory"])) {
            [NSLocalAcknowledgements removeObjectIdenticalTo:proof];
        }
    }
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
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    for (NSConfigurationCoordinator *waiting in NSConfigurationOwners().allObjects) {
        void (^acknowledge)(void) = waiting.resumeAcknowledgement;
        waiting.resumeAcknowledgement = nil;
        if (acknowledge) {
            acknowledge();
        }
        void (^resume)(void) = waiting.resumePhase;
        waiting.resumePhase = nil;
        if (resume) {
            resume();
        }
    }
    NSConfigurationCoordinator *owner = NSPendingSaveOwner;
    if (owner.checkSave) {
        owner.checkSave(NO);
    }
}
+ (NSConfigurationRecoveryAction)recoveryForManager:(id)manager {
    NSConfigurationCoordinator *owner = [NSPreferenceOwners() objectForKey:manager];
    if (!owner) {
        return NSConfigurationRecoveryNone;
    }
    return owner.abandonedRead ? NSConfigurationRecoveryReopenApp : NSConfigurationRecoveryWaitForWrite;
}
+ (NSString *)guidanceForRecovery:(NSConfigurationRecoveryAction)action {
    switch (action) {
    case NSConfigurationRecoveryWaitForWrite:
        return @"An earlier preference operation is still pending. Refresh to check again. If an "
               @"unresolved write persists, close NetShield2 from the app switcher and reopen it to "
               @"check the saved record.";
    case NSConfigurationRecoveryRetryRead:
        return @"Refresh saved preferences to retry the read or local cleanup.";
    case NSConfigurationRecoveryReopenApp:
        return @"A preference read timed out. Close NetShield2 from the app switcher and reopen it. "
               @"Returning to the foreground alone does not restart the app.";
    case NSConfigurationRecoveryRetryEnable:
        return @"If saved preferences show Firewall off, use the Firewall switch to retry.";
    case NSConfigurationRecoveryProvider:
        return @"Refresh and check Content Filter in iOS Settings. If an explicit retry still fails or "
               @"iOS shows Invalid, a full reboot and re-jailbreak may be needed.";
    case NSConfigurationRecoveryConsent:
        return @"iOS did not grant content filter authorization. Use the Firewall switch to try again.";
    case NSConfigurationRecoveryExternalChange:
        return @"Saved settings changed during setup. Check the refreshed state before trying again.";
    case NSConfigurationRecoveryReboot:
    case NSConfigurationRecoveryCheckStorageOrSettings:
    case NSConfigurationRecoveryNone:
        return nil; // These marker states carry their specific reason and next action.
    }
}
- (NSConfigurationRecoveryAction)recoveryAction {
    if (self.abandonedRead) {
        return NSConfigurationRecoveryReopenApp;
    }
    if (self.pendingWrite) {
        return NSConfigurationRecoveryWaitForWrite;
    }
    if (self.acknowledgementError || self.uncertain) {
        return NSConfigurationRecoveryRetryRead;
    }
    return self.markerRecovery;
}
- (instancetype)init {
    if ((self = [super init])) {
        _durableFence = YES;
        _replaceIdleReservation = YES;
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
// All uses of this helper are synchronous and main-queue confined. Storage
// workers receive localAccess instead of reading coordinator state.
- (BOOL)withSection:(BOOL (^)(NSError **))work error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    return NSConfigurationSection(
        self.acquireLock,
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            if (self.durableFence) {
                if (self.directory && !NSConfigurationSameDirectory(self.directory, directory)) {
                    if (localError) {
                        *localError = NSConfigurationError(
                            ESTALE, @"The shared directory changed. Reopen the app and check storage.");
                    }
                    return NO;
                }
                self.directory = directory;
                if (!directory) {
                    if (localError) {
                        *localError = NSConfigurationError(ENOENT, @"Shared storage is unavailable.");
                    }
                    return NO;
                }
            }
            return work(localError);
        },
        error);
}
- (NSConfigurationAccess *)localAccess {
    NSAssert(NSThread.isMainThread, @"Snapshot configuration ownership on the main queue");
    if (!self.active || !self.reservation || self.pendingWrite || self.acknowledging || self.uncertain ||
        self.acknowledgementError) {
        return nil;
    }
    NSConfigurationAccess *access = [[NSConfigurationAccess alloc] initWithDirectory:self.directory
                                                                              record:self.reservation
                                                                              expiry:self.overallExpiry];
    if (access) {
        if (!self.localAccesses) {
            self.localAccesses = [NSMutableArray new];
        }
        [self.localAccesses addObject:access];
    }
    return access;
}
- (NSDictionary *)newReservation {
    NSString *boot = NSNormalizedUUID(self.bootIdentifier());
    NSMutableDictionary *record = [@{
        @"version" : @3,
        @"operation" : self.operation,
        @"phase" : @1,
        @"kind" : @"transaction",
        @"state" : @"reserved",
        @"bootState" : boot ? @"known" : @"unavailable"
    } mutableCopy];
    record[@"boot"] = boot;
    return record;
}
- (BOOL)publishReservation:(NSDictionary *)record error:(NSError **)error {
    if (!NSWriteDocumentIn(self.directory, record, NSPendingConfigurationFile, error) ||
        ![record isEqual:NSReadDocumentIn(self.directory, NSPendingConfigurationFile, error)]) {
        if (error && !*error) {
            *error = NSConfigurationError(EIO, @"Could not verify the configuration reservation.");
        }
        return NO;
    }
    self.reservation = record;
    return YES;
}
- (BOOL)validateReservation:(NSError **)error {
    if (!self.durableFence) {
        return YES;
    }
    if (!self.reservation) {
        if (error) {
            *error =
                NSConfigurationError(ESTALE, @"This operation has no writable configuration reservation.");
        }
        return NO;
    }
    return NSConfigurationAdmission(self.directory, self.reservation, error);
}
// Retry local acknowledgement, never the OS write. Refused lifecycle work waits
// for foreground signals; brief physical contention gets at most three retries.
- (void)localWork:(BOOL (^)(NSError **))work
    acknowledgement:(BOOL)acknowledgement
            retries:(NSUInteger)retries
         completion:(void (^)(NSError *))completion {
    NSError *error = nil;
    if (work(&error)) {
        completion(nil);
        return;
    }
    __weak typeof(self) weakSelf = self;
    void (^retry)(void) = ^{
        NSConfigurationCoordinator *owner = weakSelf;
        if (owner) {
            [owner localWork:work acknowledgement:acknowledgement retries:retries + 1 completion:completion];
        }
    };
    if (NSConfigurationExecutionDeferred(error)) {
        if (acknowledgement) {
            self.resumeAcknowledgement = retry;
        } else if (self.active) {
            self.resumePhase = retry;
        }
        return;
    }
    if (NSIsLockContention(error) && retries < 3) {
        [self scheduleProbeWork:0.1 work:retry];
        return;
    }
    completion(error
                   ?: NSConfigurationError(
                          ESTALE, @"Configuration ownership is no longer available. Refresh and retry."));
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
    NSForgetAcknowledgement(self.directory);
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
    NSDictionary *marker = NSDecodeConfigurationRecord(bytes);
    id version = marker[@"version"];
    BOOL legacy = version == nil;
    BOOL receiptVersion = [version isEqual:@2] || [version isEqual:@3];
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
    BOOL valid = NSConfigurationRecordValid(marker);
    if (valid && [version isEqual:@3] && [marker[@"state"] isEqual:@"reserved"]) {
        // Never steal a reservation from a passive refresh. Explicit begin may
        // replace it; every old continuation must still match its exact token.
        self.markerRecovery = NSConfigurationRecoveryRetryEnable;
        if (error) {
            *error =
                NSConfigurationError(EBUSY, @"A configuration reservation has no outstanding OS write. Retry "
                                            @"an explicit Firewall or removal action to replace it.");
        }
        return NSConfigurationMarkerReserved;
    }
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
        NSDictionary *witness = NSDecodeConfigurationRecord(witnessBytes);
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
                                                 @"session has ended, fully reboot, re-jailbreak and reopen "
                                                 @"NetShield2. A respring "
                                                 @"does not clear this recovery state.",
                                                 operation];
        } else {
            message = @"The pending preference record has no usable boot evidence. This boot has been "
                      @"recorded for recovery. Fully reboot, re-jailbreak and reopen NetShield2. "
                      @"A respring is insufficient.";
        }
        *error = NSMarkerError(message, nil);
    }
    self.markerRecovery =
        boot ? NSConfigurationRecoveryReboot : NSConfigurationRecoveryCheckStorageOrSettings;
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
- (void)expireOverall {
    self.uncertain = YES;
    NSError *error = NSConfigurationError(
        ETIMEDOUT, @"The overall configuration deadline expired. Saved state is unverified.");
    if (self.abort) {
        self.abort(error);
    } else {
        [self finish];
    }
}
- (BOOL)expireIfNeeded {
    if (self.active && self.overallExpiry && !self.schedule &&
        NSProcessInfo.processInfo.systemUptime >= self.overallExpiry) {
        [self expireOverall];
        return YES;
    }
    return NO;
}
- (BOOL)beginWithDeadline:(NSTimeInterval)duration error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (self.active || self.pendingWrite || self.readInFlight || self.acknowledging) {
        if (error) {
            *error =
                NSConfigurationError(EBUSY, @"A configuration operation or unresolved write is pending.");
        }
        return NO;
    }
    self.reconciledMarker = NO;
    self.pendingRemoval = NO;
    self.directory = nil;
    self.reservation = nil;
    self.operation = NSUUID.UUID.UUIDString;
    self.readOnly = NO;
    self.acknowledgementError = nil;
    BOOL admitted = [self
        withSection:^BOOL(NSError **localError) {
            [self inspectMarker];
            if (self.markerState == NSConfigurationMarkerReserved && !self.replaceIdleReservation) {
                if (localError) {
                    *localError = self.markerError;
                }
                return NO;
            }
            if (self.markerState == NSConfigurationMarkerNone ||
                self.markerState == NSConfigurationMarkerReserved) {
                if (!self.durableFence || [self publishReservation:[self newReservation] error:localError]) {
                    self.markerState = NSConfigurationMarkerNone;
                    self.markerError = nil;
                    self.markerRecovery = NSConfigurationRecoveryNone;
                    return YES;
                }
                return NO;
            }
            if (self.recoverySave) {
                return YES;
            } // Read admission only until exact receipt proof.
            if (localError) {
                *localError = self.markerError;
            }
            return NO;
        }
              error:error];
    if (!admitted) {
        return NO;
    }
    self.active = YES;
    self.uncertain = NO;
    [NSConfigurationOwners() addObject:self];
    self.overallExpiry = NSProcessInfo.processInfo.systemUptime + duration;
    NSString *operation = self.operation;
    __weak typeof(self) weakSelf = self;
    [self deadline:duration
           overall:YES
              work:^{
                  NSConfigurationCoordinator *owner = weakSelf;
                  if (owner.active && [owner.operation isEqual:operation]) {
                      [owner expireOverall];
                  }
              }];
    return self.active;
}
- (void)inspectMarker {
    self.recoverySave = nil;
    self.markerRecovery = NSConfigurationRecoveryNone;
    NSError *error = nil;
    self.markerState = [self reconcile:&error];
    self.markerError = error;
    if (self.markerRecovery == NSConfigurationRecoveryNone) {
        if (self.markerState == NSConfigurationMarkerAcknowledged ||
            self.markerState == NSConfigurationMarkerPriorBoot) {
            self.markerRecovery = NSConfigurationRecoveryRetryRead;
        } else if (self.markerState != NSConfigurationMarkerNone) {
            self.markerRecovery = NSConfigurationRecoveryCheckStorageOrSettings;
        }
    }
}
- (NSConfigurationMarkerState)beginReadOnly:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (self.active || self.pendingWrite || self.readInFlight || self.acknowledging) {
        if (error) {
            *error = NSConfigurationError(EBUSY, @"Configuration inspection is busy.");
        }
        return NSConfigurationMarkerUnavailable;
    }
    self.reconciledMarker = NO;
    self.pendingRemoval = NO;
    self.directory = nil;
    self.reservation = nil;
    self.operation = NSUUID.UUID.UUIDString;
    self.readOnly = YES;
    self.acknowledgementError = nil;
    self.overallExpiry = 0;
    self.active = YES;
    self.uncertain = NO;
    [NSConfigurationOwners() addObject:self];
    NSError *localError = nil;
    BOOL inspected = [self
        withSection:^BOOL(NSError **sectionError) {
            [self inspectMarker];
            // Reserve an empty lane for a possible queued bootstrap. An explicit
            // action can replace this idle reservation before that worker executes.
            return self.markerState != NSConfigurationMarkerNone || !self.durableFence ||
                   [self publishReservation:[self newReservation] error:sectionError];
        }
              error:&localError];
    if (!inspected) {
        self.markerState = NSConfigurationMarkerUnavailable;
        self.markerError = localError;
        self.markerRecovery = NSIsLockContention(localError) ? NSConfigurationRecoveryWaitForWrite
                                                             : NSConfigurationRecoveryRetryRead;
    }
    if (error) {
        *error = self.markerError;
    }
    return self.markerState;
}

// Called only inside a short section. A receipt reader may have already changed
// this exact pending record to the same reservation. That race is idempotent.
- (NSError *)acknowledgeLocked:(NSDictionary *)expected {
    NSError *error = nil;
    NSDictionary *current = NSReadDocumentIn(self.directory, NSPendingConfigurationFile, &error);
    NSMutableDictionary *reserved = [expected mutableCopy];
    reserved[@"version"] = @3;
    reserved[@"state"] = @"reserved";
    if (![expected isEqual:current] && ![reserved isEqual:current]) {
        if (current || NSFileIsAbsent(error)) {
            NSDiscardAcknowledgement(expected, self.directory);
        }
        return NSMarkerError(
            @"The OS write settled, but its configuration token was replaced. Refresh before another change.",
            error && !NSFileIsAbsent(error)
                ? error
                : NSConfigurationError(ESTALE, @"Configuration ownership changed."));
    }
    NSRememberAcknowledgement(expected, self.directory);
    BOOL ownLiveWrite = self.active && !self.uncertain && [expected[@"operation"] isEqual:self.operation];
    BOOL recovering = self.recoverySave && [expected isEqual:self.recoverySave];
    if (ownLiveWrite || recovering) {
        // A passive reader preserves the original owner's reservation so its
        // live callback can advance. An explicit recovery replaces it atomically.
        BOOL claimRecovery =
            recovering && self.active && !self.uncertain && !self.readOnly && self.replaceIdleReservation;
        NSDictionary *next = claimRecovery ? [self newReservation] : reserved;
        if (![next isEqual:current] &&
            !NSWriteDocumentIn(self.directory, next, NSPendingConfigurationFile, &error)) {
            return NSMarkerError(@"The OS write settled. Local acknowledgement is pending; refresh to retry.",
                                 error);
        }
        if (![next isEqual:NSReadDocumentIn(self.directory, NSPendingConfigurationFile, &error)]) {
            return NSMarkerError(@"Could not verify the settled configuration reservation.", error);
        }
        if (ownLiveWrite || claimRecovery) {
            self.reservation = next;
        }
        NSForgetAcknowledgement(self.directory);
        return nil;
    }
    // Persist late acknowledgement before retirement, so a cleanup failure is
    // recoverable after relaunch even without an exact receipt (e.g. removal).
    NSMutableDictionary *acknowledged = [expected mutableCopy];
    acknowledged[@"state"] = @"acknowledged";
    if (!NSWriteDocumentIn(self.directory, acknowledged, NSPendingConfigurationFile, &error)) {
        return NSMarkerError(@"The OS write settled. Store its local acknowledgement on refresh.", error);
    }
    return [self retireMarker:&error]
               ? nil
               : NSMarkerError(@"The OS write settled. Local cleanup is pending; refresh to retry.", error);
}
- (void)acknowledge:(NSDictionary *)record completion:(void (^)(NSError *))completion {
    self.acknowledging = YES;
    // Keep delivered OS proof even if protection/lock reacquisition is refused.
    // Reconciliation still compares this exact record and directory under lock.
    NSRememberAcknowledgement(record, self.directory);
    [self
        localWork:^BOOL(NSError **error) {
            return [self
                withSection:^BOOL(NSError **localError) {
                    NSError *result = [self acknowledgeLocked:record];
                    if (localError) {
                        *localError = result;
                    }
                    return !result;
                }
                      error:error];
        }
        acknowledgement:YES
        retries:0
        completion:^(NSError *error) {
            self.acknowledging = NO;
            completion(error);
        }];
}

- (void)validateLoadedSave:(id<NSConfigurationPreferences>)manager
                completion:(void (^)(NSError *))completion {
    NSDictionary *record = self.recoverySave;
    if (record && [NSSavedReceipt(manager) isEqual:NSNormalizedUUID(record[@"receipt"])]) {
        [self
            acknowledge:record
             completion:^(NSError *error) {
                 self.markerError = error;
                 self.markerState =
                     error ? NSConfigurationMarkerAcknowledged
                           : (self.reservation ? NSConfigurationMarkerNone : NSConfigurationMarkerReserved);
                 self.markerRecovery = error ? NSConfigurationRecoveryRetryRead : NSConfigurationRecoveryNone;
                 if (!error) {
                     self.reconciledMarker = YES;
                     self.recoverySave = nil;
                     NSLog(@"NetShield2 preference save receipt verified during refresh");
                 }
                 completion(
                     error
                         ?: (!self.readOnly && !self.reservation
                                 ? NSConfigurationError(
                                       EBUSY,
                                       @"The earlier write settled. Retry an explicit configuration action.")
                                 : nil));
             }];
        return;
    }
    if (self.reservation) {
        [self
                  localWork:^BOOL(NSError **error) {
                      return [self
                          withSection:^BOOL(NSError **localError) {
                              return [self validateReservation:localError];
                          }
                                error:error];
                  }
            acknowledgement:NO
                    retries:0
                 completion:completion];
    } else {
        completion(!self.readOnly && record ? self.markerError : nil);
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
    [self releaseIdleOwnership];
    // A late proof releases ownership without resuming an expired transaction.
    [NSNotificationCenter.defaultCenter postNotificationName:NSConfigurationLateAcknowledgement object:nil];
}

- (void)releaseIdleOwnership {
    if (!self.active && !self.pendingWrite) {
        NSDictionary *reservation = self.reservation;
        if (reservation) {
            NSError *error = nil;
            [self
                withSection:^BOOL(NSError **localError) {
                    if (![reservation
                            isEqual:NSReadDocumentIn(self.directory, NSPendingConfigurationFile, NULL)]) {
                        return YES; // Never retire a pending write or a replacement token.
                    }
                    return [self retireMarker:localError];
                }
                      error:&error];
            self.reservation = nil; // An unretired idle reservation is explicitly recoverable.
            if (error) {
                NSLog(@"NetShield2 reservation cleanup deferred: %@", error);
            }
        }
        id manager = self.preferenceManager;
        if (!self.readInFlight && manager && [NSPreferenceOwners() objectForKey:manager] == self &&
            !self.acknowledging) {
            [NSPreferenceOwners() removeObjectForKey:manager];
            self.preferenceManager = nil;
        }
    }
}

- (NSDictionary *)prepareWrite:(NSUInteger)kind
                       manager:(id<NSConfigurationPreferences>)manager
                         phase:(NSUInteger)phase
                         error:(NSError **)error {
    if (![self validateReservation:error]) {
        return nil;
    }
    NSString *boot = NSNormalizedUUID(self.bootIdentifier());
    id<NSReceiptConfiguration> provider = kind == 1 ? NSReceiptProvider(manager) : nil;
    NSString *receipt = provider ? NSUUID.UUID.UUIDString : nil;
    NSMutableDictionary *prepared = [@{
        @"version" : @3,
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
    if (checkedRecord && ![self publishReservation:self.reservation error:&cleanupError]) {
        NSRememberAcknowledgement(record, self.directory);
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
    self.abandonedRead = self.readInFlight;
    NSString *message = self.abandonedRead ? @"Preference read timed out. Saved state is unverified."
                        : self.pendingWrite
                            ? @"Preference write timed out and may still complete. Saved state is unverified."
                            : @"Preference completion or readback timed out. Saved state is unverified.";
    NSError *timeout = NSConfigurationError(ETIMEDOUT, message);
    [self completePhase:phase
                  error:[self writeErrorWithPreferenceError:self.preferenceCallbackError
                                              readbackError:timeout]];
}

- (void)checkDeliveryDeadline:(NSUInteger)phase {
    if (![self expireIfNeeded] && self.active && self.phase == phase && !self.schedule &&
        NSProcessInfo.processInfo.systemUptime >= self.phaseExpiry) {
        [self expirePhase:phase];
    }
}

- (void)scheduleProbeWork:(NSTimeInterval)delay work:(void (^)(void))work {
    if (self.schedule) {
        self.schedule(delay, work);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), work);
    }
}

- (void)cancelPreparedRecord:(NSDictionary *)record {
    // The API was never invoked. Only this exact preparation can be retired;
    // failure leaves conservative evidence and an exact in-process witness.
    NSRememberAcknowledgement(record, self.directory);
    NSError *error = nil;
    [self
        withSection:^BOOL(NSError **localError) {
            if (![record isEqual:NSReadDocumentIn(self.directory, NSPendingConfigurationFile, NULL)]) {
                return YES;
            }
            return [self retireMarker:localError];
        }
              error:&error];
    if (error) {
        NSLog(@"NetShield2 unsubmitted preparation cleanup deferred: %@", error);
    }
}

- (void)perform:(NSUInteger)kind
    authorization:(BOOL)authorization
          manager:(id<NSConfigurationPreferences>)manager
       completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if ([self expireIfNeeded]) {
        return;
    }
    if (kind && (self.acknowledgementError || self.recoverySave)) {
        completion(self.acknowledgementError ?: self.markerError);
        return;
    }
    if (!self.active || self.pendingWrite || self.acknowledging || self.readInFlight || self.uncertain ||
        self.phaseCompletion || (kind && self.readOnly)) {
        completion(NSConfigurationError(EBUSY, @"Configuration is busy or an earlier result is unverified."));
        return;
    }
    NSConfigurationCoordinator *existing = [NSPreferenceOwners() objectForKey:manager];
    if (existing && existing != self) {
        NSConfigurationRecoveryAction action = [NSConfigurationCoordinator recoveryForManager:manager];
        completion(NSConfigurationError(EBUSY, [NSConfigurationCoordinator guidanceForRecovery:action]));
        return;
    }
    [NSPreferenceOwners() setObject:self forKey:manager];
    self.preferenceManager = manager;
    self.preferenceCallbackError = nil;
    NSUInteger phase = ++self.phase;
    self.phaseCompletion = completion;
    NSTimeInterval budget = authorization ? 60 : 10;
    self.phaseExpiry = NSProcessInfo.processInfo.systemUptime + budget;
    __weak typeof(self) weakSelf = self;
    [self deadline:budget
           overall:NO
              work:^{
                  NSConfigurationCoordinator *owner = weakSelf;
                  if (!owner.active || owner.phase != phase) {
                      return;
                  }
                  [owner checkDeliveryDeadline:phase];
                  if (!owner.active || owner.phase != phase) {
                      return;
                  }
                  if (!owner.checkSave || owner.readInFlight) {
                      [owner expirePhase:phase];
                      return;
                  }
                  // One final bounded check also covers a missing configuration-change
                  // notification. A nonmatching read leaves the original fence intact.
                  [owner cancelPhaseTimer];
                  owner.checkSave(YES);
              }];
    if (!self.active || self.phase != phase) {
        return;
    }
    __block NSDictionary *record = nil;
    [self
        localWork:^BOOL(NSError **error) {
            [self checkDeliveryDeadline:phase];
            if (!self.active || self.phase != phase) {
                return YES;
            }
            return [self
                withSection:^BOOL(NSError **localError) {
                    if (kind && self.durableFence) {
                        record = [self prepareWrite:kind manager:manager phase:phase error:localError];
                        return record != nil;
                    }
                    return !self.reservation || [self validateReservation:localError];
                }
                      error:error];
        }
        acknowledgement:NO
        retries:0
        completion:^(NSError *error) {
            [self checkDeliveryDeadline:phase];
            if (!self.active || self.phase != phase) {
                if (record) {
                    [self cancelPreparedRecord:record];
                }
                return;
            }
            if (error) {
                if (error.code == ESTALE) {
                    self.uncertain = YES;
                }
                [self completePhase:phase error:error];
                return;
            }
            [self submit:kind authorization:authorization manager:manager phase:phase record:record];
        }];
}
- (void)submit:(NSUInteger)kind
    authorization:(BOOL)authorization
          manager:(id<NSConfigurationPreferences>)manager
            phase:(NSUInteger)phase
           record:(NSDictionary *)record {
    __weak typeof(self) weakSelf = self;
    __weak id<NSConfigurationPreferences> weakManager = manager;
    __block BOOL settled = NO;
    __block BOOL settlementReady = NO;
    __block NSError *settledError = nil;
    void (^settle)(NSConfigurationCoordinator *, NSError *, BOOL) = ^(NSConfigurationCoordinator *owner,
                                                                      NSError *error, BOOL receipt) {
        if (!owner || settled) {
            return;
        }
        settled = YES;
        settledError = error;
        if (kind) {
            owner.pendingWrite = NO;
            owner.preferenceCallbackError = error;
            owner.checkSave = nil;
            if (NSPendingSaveOwner == owner) {
                NSPendingSaveOwner = nil;
            }
            void (^acknowledged)(NSError *) = ^(NSError *localError) {
                owner.acknowledgementError = localError;
                settlementReady = YES;
                if (localError.code == ESTALE) {
                    owner.uncertain = YES;
                }
                NSLog(@"NetShield2 preference %@ %@ phase=%lu os=%@/%ld local=%@/%ld", record[@"kind"],
                      receipt ? @"receipt verified" : @"callback", (unsigned long)phase,
                      error.domain ?: @"ok", (long)error.code, localError.domain ?: @"ok",
                      (long)localError.code);
                [owner checkDeliveryDeadline:phase];
                if (!owner.readInFlight) {
                    [owner completeWritePhase:phase error:error];
                }
            };
            if (record) {
                [owner acknowledge:record completion:acknowledged];
            } else {
                acknowledged(nil);
            }
            return;
        }
        owner.readInFlight = NO;
        BOOL abandoned = owner.abandonedRead;
        owner.abandonedRead = NO;
        void (^loaded)(NSError *) = ^(NSError *localError) {
            if (localError && localError.code == ESTALE) {
                owner.uncertain = YES;
            }
            [owner completePhase:phase error:error ?: localError];
            if (abandoned) {
                [owner releaseIdleOwnership];
                [NSNotificationCenter.defaultCenter postNotificationName:NSConfigurationLateAcknowledgement
                                                                  object:nil];
            }
        };
        if (owner.active && owner.phase == phase && !error) {
            [owner validateLoadedSave:weakManager completion:loaded];
            return;
        }
        if (error && owner.recoverySave) {
            owner.markerRecovery = NSConfigurationRecoveryRetryRead;
            owner.markerError = NSMarkerError(@"The saved receipt could not be checked.", error);
        }
        [owner completePhase:phase error:settledError];
        if (abandoned) {
            [owner releaseIdleOwnership];
            [NSNotificationCenter.defaultCenter postNotificationName:NSConfigurationLateAcknowledgement
                                                              object:nil];
        }
    };
    if (record[@"receipt"]) {
        self.phaseExpiry += 10;
        NSPendingSaveOwner = self;
        __block NSUInteger earlyChecks = 0;
        self.checkSave = ^(BOOL finalCheck) {
            NSConfigurationCoordinator *owner = weakSelf;
            id<NSConfigurationPreferences> currentManager = weakManager;
            if (settled || owner.readInFlight || !owner.pendingWrite || !currentManager) {
                if (finalCheck) {
                    [owner expirePhase:phase];
                }
                return;
            }
            [owner checkDeliveryDeadline:phase];
            BOOL live = owner.active && owner.phase == phase;
            // Consent can hold up a load on this same manager. Wait for the
            // save callback, or for the bounded final check if it never arrives.
            if (live && authorization && !finalCheck) {
                return;
            }
            if (live && !finalCheck && earlyChecks >= 2) {
                return;
            }
            if (live && !finalCheck) {
                earlyChecks++;
            }
            NSUInteger probe = ++owner.probeGeneration;
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval probeBudget = live && !owner.schedule ? MIN(10, owner.phaseExpiry - now) : 10;
            NSTimeInterval probeExpiry = now + probeBudget;
            owner.readInFlight = YES;
            [owner
                scheduleProbeWork:MAX(0, probeBudget)
                             work:^{
                                 NSConfigurationCoordinator *current = weakSelf;
                                 if (!current.readInFlight || current.probeGeneration != probe) {
                                     return;
                                 }
                                 current.abandonedRead = YES;
                                 NSLog(@"NetShield2 receipt-probe timed out phase=%lu", (unsigned long)phase);
                                 [current expirePhase:phase];
                             }];
            [currentManager loadFromPreferencesWithCompletionHandler:^(NSError *readError) {
                NSDeliverPreferenceCallback(^{
                    if (!owner.readInFlight || owner.probeGeneration != probe) {
                        return;
                    }
                    [owner checkDeliveryDeadline:phase];
                    if (!owner.schedule && NSProcessInfo.processInfo.systemUptime >= probeExpiry) {
                        owner.abandonedRead = YES;
                        [owner expirePhase:phase];
                    }
                    owner.readInFlight = NO;
                    BOOL abandoned = owner.abandonedRead;
                    owner.abandonedRead = NO;
                    NSLog(@"NetShield2 receipt-probe returned phase=%lu error=%@/%ld late=%d",
                          (unsigned long)phase, readError.domain ?: @"ok", (long)readError.code, abandoned);
                    if (settled) {
                        // The save callback handled the marker independently.
                        // Only the live phase may advance after this load drains.
                        if (settlementReady) {
                            [owner completeWritePhase:phase error:settledError];
                        }
                    } else if (!readError &&
                               [NSSavedReceipt(weakManager) isEqual:NSNormalizedUUID(record[@"receipt"])]) {
                        settle(owner, nil, YES);
                    } else if (finalCheck) {
                        [owner expirePhase:phase];
                    } else if (live && owner.active && owner.phase == phase && earlyChecks < 2) {
                        // The first OS signal can precede commit visibility. A second
                        // signal can use this slot sooner, invalidating the queued retry.
                        [owner scheduleProbeWork:0.75
                                            work:^{
                                                NSConfigurationCoordinator *current = weakSelf;
                                                if (current.active && current.phase == phase &&
                                                    current.probeGeneration == probe && current.checkSave) {
                                                    current.checkSave(NO);
                                                }
                                            }];
                    }
                    if (abandoned && owner.pendingWrite) {
                        // The in-process write fence remains. Refresh can now probe again.
                        [NSNotificationCenter.defaultCenter
                            postNotificationName:NSConfigurationLateAcknowledgement
                                          object:nil];
                    }
                });
            }];
        };
    }
    // The OS retains this owner while it retains the callback. A lost callback
    // can also be reconciled from the durable record on a subsequent launch.
    void (^callback)(NSError *) = ^(NSError *error) {
        NSDeliverPreferenceCallback(^{
            if (settled) {
                return;
            }
            if (kind) {
                self.preferenceCallbackError = error;
            }
            [self checkDeliveryDeadline:phase];
            settle(self, error, NO);
        });
    };
    self.pendingWrite = kind != 0;
    self.readInFlight = kind == 0;
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
- (void)performLocalMutation:(BOOL (^)(NSSharedDirectory *, NSError **))work
                  completion:(void (^)(NSError *))completion {
    if ([self expireIfNeeded]) {
        return;
    }
    NSError *error = nil;
    if (!self.active || self.pendingWrite || self.acknowledging || self.readInFlight || self.uncertain) {
        error = NSConfigurationError(
            ESTALE, @"Configuration no longer owns local cleanup. Shared state was preserved.");
    } else {
        BOOL performed = [self
            withSection:^BOOL(NSError **localError) {
                return [self validateReservation:localError] && work(self.directory, localError);
            }
                  error:&error];
        if (!performed && !error) {
            error =
                NSConfigurationError(ESTALE, @"Local configuration ownership or saved state is unavailable.");
        }
    }
    completion(error);
}
- (void)whenLocalExecutionAvailable:(void (^)(void))work {
    NSString *operation = self.operation;
    self.resumePhase = ^{
        if (!self.active || self.pendingWrite || self.acknowledging || self.readInFlight || self.uncertain) {
            return;
        }
        if ([self.operation isEqual:operation] && ![self expireIfNeeded]) {
            work();
        }
    };
}
- (void)finish {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    for (NSConfigurationAccess *access in self.localAccesses) {
        [access invalidate];
    }
    self.localAccesses = nil;
    self.active = NO;
    self.resumePhase = nil;
    self.abandonedRead = self.readInFlight;
    self.phase++;
    self.phaseCompletion = nil;
    self.abort = nil;
    [self cancelPhaseTimer];
    if (self.overallTimer) {
        dispatch_source_cancel(self.overallTimer);
    }
    self.overallTimer = nil;
    [self releaseIdleOwnership];
}
@end
