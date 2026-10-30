#import "NSRecoveryViewController.h"
#import "NSRecoveryDiagnostics.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface NSRecoveryViewController ()
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSDictionary *lastResult;
@property(nonatomic) BOOL busy;
@end

@implementation NSRecoveryViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NetShield2 Recovery";
    self.message = @"Phase 0 preview: compatibility is unverified. Inspect first. Disable and Remove "
                   @"are independent tests. Neither proves connectivity. Rules and settings are preserved.";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : section == 1 ? 6 : (NSRecoveryIsPlainPoC() ? 1 : 2);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"Offline recovery", @"Actions", @"Build gate" ][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) {
        cell.textLabel.text = self.message;
        cell.detailTextLabel.text = self.lastResult.description;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        cell.textLabel.text = @[
            @"Inspect configuration", @"Turn Off NetShield2 Firewall", @"Remove NetShield2 Filter",
            @"Export local diagnostics / owner evidence", @"Import original-owner report",
            @"Record original-owner observation (legacy only)"
        ][path.row];
        cell.textLabel.textColor = path.row == 2 ? UIColor.systemRedColor : UIColor.systemBlueColor;
        cell.userInteractionEnabled = !self.busy;
        cell.textLabel.enabled = !self.busy;
        if (path.row == 5 && NSRecoveryIsPlainPoC()) {
            cell.userInteractionEnabled = NO;
            cell.textLabel.enabled = NO;
        }
    } else if (path.row == 0) {
        cell.textLabel.text =
            NSRecoveryIsPlainPoC()
                ? @"Plain TrollStore PoC. Normal controls and all enable paths are gated pending device "
                  @"proof."
                : @"Legacy baseline build. Installer ownership and the existing uninstall path are retained.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Open normal firewall controls (jailbroken baseline)";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.userInteractionEnabled = !self.busy;
    }
    return cell;
}
- (void)confirm:(NSString *)title message:(NSString *)message action:(void (^)(void))action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *unused) {
                                                action();
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)run:(NSString *)operation capture:(BOOL)capture {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    self.message = @"Loading filter preferences...";
    [self.tableView reloadData];
    NSRecoveryPerform(operation, ^(NSDictionary *result) {
        self.lastResult = result;
        self.message = NSRecoveryMessage(result);
        if (capture) {
            NSError *error = nil;
            BOOL loaded =
                [@[ @"ownershipUnverified", @"foundRecordedConfiguration" ] containsObject:result[@"status"]];
            if (loaded && NSRecoveryCaptureEvidence(result[@"before"], &error)) {
                self.message = @"Original-owner observation recorded locally. Export the report now. "
                               @"A later changed activation/configuration requires a new observation.";
            } else {
                self.message = error.localizedDescription ?: self.message;
            }
        }
        self.busy = NO;
        [self.tableView reloadData];
    });
}
- (void)exportReport:(NSIndexPath *)path {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:NSRecoveryReport()
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"NetShield2-Phase0-%@.plist",
                                                               NSUUID.UUID.UUIDString]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        self.message = error.localizedDescription ?: @"Diagnostic export failed.";
        [self.tableView reloadData];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.tableView;
    share.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
    [self presentViewController:share animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy) {
        return;
    }
    if (path.section == 2 && path.row == 1 && !NSRecoveryIsPlainPoC()) {
        [self confirm:@"Jailbroken baseline controls"
              message:
                  @"Continue only in your active jailbreak. "
                  @"These are the existing controls and can start providers, access rules and check updates."
               action:^{
                   if (self.openDashboard) {
                       self.openDashboard();
                   }
               }];
    }
    if (path.section != 1) {
        return;
    }
    if (path.row == 0) {
        [self run:@"status" capture:NO];
    } else if (path.row == 1) {
        [self run:@"disable" capture:NO];
    } else if (path.row == 2) {
        [self confirm:@"Remove NetShield2 Filter"
              message:@"Attempt removal independently of disable. "
                      @"The app, saved rules and settings are kept. No other configuration is selected."
               action:^{
                   [self run:@"remove" capture:NO];
               }];
    } else if (path.row == 3) {
        [self exportReport:path];
    } else if (path.row == 4) {
        [self
            confirm:@"Import original-owner evidence"
            message:@"Use only the unmodified report you "
                    @"recorded on this phone in the confirmed original legacy app while jailbroken, with no "
                    @"managed/unknown filter. Import is corroboration, not proof of ownership or permission."
             action:^{
                 UIDocumentPickerViewController *picker =
                     [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ]
                                                                                 asCopy:YES];
                 picker.delegate = self;
                 [self presentViewController:picker animated:YES completion:nil];
             }];
    } else if (!NSRecoveryIsPlainPoC()) {
        [self
            confirm:@"Confirm original legacy owner"
            message:
                @"Record only while jailbroken in the "
                @"known original NetShield2 owner, after confirming its intended configuration and excluding "
                @"managed/unknown ownership. Matching names or bundle IDs alone do not establish this. "
                @"This reads preferences and writes only local evidence."
             action:^{
                 [self run:@"status" capture:YES];
             }];
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSError *error = nil;
    BOOL saved = urls.count && NSRecoveryImportEvidence(urls.firstObject, &error);
    self.message = saved ? @"Original-owner evidence imported. Inspect to compare the actual visible "
                            @"configuration before attempting recovery."
                         : error.localizedDescription ?: @"Evidence import failed.";
    [self.tableView reloadData];
}
@end
