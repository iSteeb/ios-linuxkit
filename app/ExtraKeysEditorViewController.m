//
//  ExtraKeysEditorViewController.m
//  LinuxKit (ios-linuxkit)
//
//  Edit the scrollable center section of the keyboard bar.
//  Entries are literal keys (inserted as text). The special token
//  ":settings" renders the settings gear button.
//

#import "ExtraKeysEditorViewController.h"
#import "ExtraKeysBarView.h"
#import "UserPreferences.h"

static NSString *const CellIdentifier = @"ExtraKeyCell";

@interface ExtraKeysEditorViewController ()
@property (nonatomic, copy) NSArray<NSString *> *keys;
@end

@implementation ExtraKeysEditorViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Extra Keys";
        self.keys = UserPreferences.shared.extraKeys;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    // Non-editing: the system back button shows (pushed onto the About stack).
    // Editing: back hides and "+" (add) takes the left slot until Done.
    [self refreshLeftBarButtonItem];

    self.tableView.allowsSelectionDuringEditing = YES;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.navigationItem.hidesBackButton = editing;
    [self refreshLeftBarButtonItem];
}

- (void)refreshLeftBarButtonItem {
    if (self.isEditing) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
            target:self
            action:@selector(addKey)];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (void)persist {
    UserPreferences.shared.extraKeys = self.keys;
}

- (void)setKeys:(NSArray<NSString *> *)keys {
    _keys = [keys copy];
    [self.tableView reloadData];
}

#pragma mark - Add

- (void)addKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Key"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"/";
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = alert.textFields.firstObject.text;
        if (key.length == 0)
            return;
        NSMutableArray *keys = [weakSelf.keys mutableCopy];
        [keys addObject:key];
        weakSelf.keys = keys;
        [weakSelf persist];
    }]];
    UINavigationController *presentingController = self.navigationController;
    if (presentingController != nil) {
        [presentingController presentViewController:alert animated:YES completion:nil];
    } else {
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Table view data source

- (NSString *)displayTitleForKey:(NSString *)key {
    if ([key isEqualToString:ExtraKeysSettingsToken])
        return @"⚙  Settings";
    return key;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.text = @"Entries are sent to the terminal as-is. \":settings\" shows the settings button. Edit to reorder or delete.";
    return label;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.keys.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    cell.textLabel.text = [self displayTitleForKey:self.keys[indexPath.row]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    NSMutableArray *keys = [self.keys mutableCopy];
    [keys removeObjectAtIndex:indexPath.row];
    self.keys = keys;
    [self persist];
}

- (void)tableView:(UITableView *)tableView
        moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
        toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSMutableArray *keys = [self.keys mutableCopy];
    NSString *key = keys[sourceIndexPath.row];
    [keys removeObjectAtIndex:sourceIndexPath.row];
    [keys insertObject:key atIndex:destinationIndexPath.row];
    self.keys = keys;
    [self persist];
}

@end
