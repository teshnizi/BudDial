#import "ReplacementsSheet.h"

static NSString *const kHeard = @"heard", *const kWrite = @"write";

@interface APReplacementsSheet () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property NSMutableArray<NSMutableDictionary *> *rows;
@property NSTableView *table;
@property NSButton *removeButton;
@property(copy) void (^completion)(NSArray<NSDictionary *> *);
@end

@implementation APReplacementsSheet
- (instancetype)initWithPairs:(NSArray<NSDictionary *> *)pairs completion:(void (^)(NSArray<NSDictionary *> *))completion {
    self = [super initWithContentRect:NSMakeRect(0, 0, 460, 330) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    if (!self) return nil;
    _completion = completion;
    _rows = [NSMutableArray array];
    for (NSDictionary *pair in pairs) [_rows addObject:[@{kHeard: pair[kHeard] ?: @"", kWrite: pair[kWrite] ?: @""} mutableCopy]];
    self.releasedWhenClosed = NO;

    NSTextField *title = [NSTextField labelWithString:@"Replacements"];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *caption = [NSTextField wrappingLabelWithString:@"When a transcript contains the left side, Buddial writes the right side instead. Whole words, any capitalization. The right side is also given to the speech engine as a word you use."];
    caption.font = [NSFont systemFontOfSize:11];
    caption.textColor = NSColor.secondaryLabelColor;
    caption.preferredMaxLayoutWidth = 420;

    self.table = [NSTableView new];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.style = NSTableViewStyleFullWidth;
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    for (NSArray<NSString *> *column in @[@[kHeard, @"When it writes"], @[kWrite, @"Write instead"]]) {
        NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:column[0]];
        tableColumn.title = column[1];
        tableColumn.width = 200;
        [self.table addTableColumn:tableColumn];
    }
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSButton *add = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameAddTemplate] target:self action:@selector(addRow:)];
    self.removeButton = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameRemoveTemplate] target:self action:@selector(removeRow:)];
    for (NSButton *button in @[add, self.removeButton]) { button.bezelStyle = NSBezelStyleSmallSquare; [button.widthAnchor constraintEqualToConstant:24].active = YES; }
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)];
    done.keyEquivalent = @"\r";

    NSView *content = self.contentView;
    for (NSView *view in @[title, caption, scroll, add, self.removeButton, done]) { view.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [caption.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [caption.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [caption.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:caption.trailingAnchor],
        [add.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-1],
        [add.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [self.removeButton.topAnchor constraintEqualToAnchor:add.topAnchor],
        [self.removeButton.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:-1],
        [done.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [done.topAnchor constraintEqualToAnchor:add.bottomAnchor constant:14],
        [done.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18]]];
    if (!self.rows.count) [self.rows addObject:[@{kHeard: @"", kWrite: @""} mutableCopy]];
    [self.table reloadData];
    [self updateRemove];
    return self;
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return (NSInteger)self.rows.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTextField *field = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (!field) {
        field = [NSTextField textFieldWithString:@""];
        field.identifier = column.identifier;
        field.bordered = NO;
        field.drawsBackground = NO;
        field.delegate = self;
        field.placeholderString = [column.identifier isEqual:kHeard] ? @"clawed code" : @"Claude Code";
    }
    field.stringValue = self.rows[(NSUInteger)row][column.identifier] ?: @"";
    return field;
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    NSInteger row = [self.table rowForView:field];
    if (row >= 0 && (NSUInteger)row < self.rows.count) self.rows[(NSUInteger)row][field.identifier] = field.stringValue;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification { (void)notification; [self updateRemove]; }
- (void)updateRemove { self.removeButton.enabled = self.table.selectedRow >= 0; }

#pragma mark Actions

- (void)addRow:(id)sender {
    (void)sender;
    [self makeFirstResponder:nil];   // keep what is being typed
    [self.rows addObject:[@{kHeard: @"", kWrite: @""} mutableCopy]];
    [self.table reloadData];
    NSInteger last = (NSInteger)self.rows.count - 1;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)last] byExtendingSelection:NO];
    [self.table editColumn:0 row:last withEvent:nil select:YES];
}
- (void)removeRow:(id)sender {
    (void)sender;
    NSInteger row = self.table.selectedRow;
    [self makeFirstResponder:nil];
    if (row < 0 || (NSUInteger)row >= self.rows.count) return;
    [self.rows removeObjectAtIndex:(NSUInteger)row];
    [self.table reloadData];
    [self updateRemove];
}
- (void)done:(id)sender {
    (void)sender;
    [self makeFirstResponder:nil];   // commits the field being edited
    NSMutableArray<NSDictionary *> *pairs = [NSMutableArray array];
    for (NSDictionary *row in self.rows) {
        NSString *heard = [row[kHeard] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *write = [row[kWrite] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (heard.length) [pairs addObject:@{kHeard: heard, kWrite: write ?: @""}];
    }
    if (self.completion) self.completion(pairs);
    [self.sheetParent endSheet:self];
}
@end
