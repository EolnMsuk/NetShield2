#import <UIKit/UIKit.h>

static inline UIFont *NSSectionTitleFont(void) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:16]];
}

static inline void NSStyleSectionHeader(UIView *view) {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
        label.font = NSSectionTitleFont();
        label.adjustsFontForContentSizeCategory = YES;
    }
}
