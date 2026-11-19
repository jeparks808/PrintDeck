// Small shared helpers. iOS 5 rules: no object subscripting (objectForKey:/objectAtIndex:),
// no Auto Layout, ARC at compile time only.
#import <UIKit/UIKit.h>
#include <math.h>

static inline id PDGet(id obj, NSString *key) {
	if (![obj isKindOfClass:[NSDictionary class]]) return nil;
	id v = [(NSDictionary *)obj objectForKey:key];
	return (v == [NSNull null]) ? nil : v;
}
static inline NSNumber *PDNum(id obj, NSString *key) {
	id v = PDGet(obj, key);
	return [v isKindOfClass:[NSNumber class]] ? v : nil;
}
static inline NSString *PDStr(id obj, NSString *key) {
	id v = PDGet(obj, key);
	return [v isKindOfClass:[NSString class]] ? v : nil;
}
static inline NSDictionary *PDDict(id obj, NSString *key) {
	id v = PDGet(obj, key);
	return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}
static inline NSArray *PDArr(id obj, NSString *key) {
	id v = PDGet(obj, key);
	return [v isKindOfClass:[NSArray class]] ? v : nil;
}
static inline UILabel *PDLabel(UIFont *font, UIColor *color) {
	UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
	l.font = font;
	l.textColor = color;
	l.backgroundColor = [UIColor clearColor];
	l.adjustsFontSizeToFitWidth = YES;
	l.minimumFontSize = 10;
	return l;
}
static inline UIFont *PDLightFont(CGFloat size) {
	return [UIFont fontWithName:@"HelveticaNeue-Light" size:size] ?: [UIFont systemFontOfSize:size];
}
static inline UIFont *PDBoldFont(CGFloat size) {
	return [UIFont fontWithName:@"HelveticaNeue-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}
// 1h 05m / 12m 30s / 45s
static inline NSString *PDDuration(double secs) {
	if (secs < 0 || isnan(secs)) secs = 0;
	long s = lround(secs), h = s / 3600, m = (s % 3600) / 60;
	if (h > 0) return [NSString stringWithFormat:@"%ldh %02ldm", h, m];
	if (m > 0) return [NSString stringWithFormat:@"%ldm %02lds", m, s % 60];
	return [NSString stringWithFormat:@"%lds", s];
}
// "/local/ECC_0.6_Kendama_Mount_SUNLU PLA _0.24_55m11s.gcode" -> "Kendama Mount"
// Elegoo slicer names files ECC_<nozzle>_<model>_<filament>_<layer>_<time>.gcode; fall back to the bare name.
static inline NSString *PDPrettyFileName(NSString *path) {
	NSString *n = [[path lastPathComponent] stringByDeletingPathExtension];
	if (![n length]) return @"";
	NSArray *parts = [n componentsSeparatedByString:@"_"];
	if ([parts count] >= 6 && [[parts objectAtIndex:0] isEqualToString:@"ECC"]) {
		NSArray *model = [parts subarrayWithRange:NSMakeRange(2, [parts count] - 5)];
		NSString *m = [[model componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([m length]) return m;
	}
	return [n stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

#define PD_BG       [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0]
#define PD_TILE     [UIColor colorWithWhite:1.0 alpha:0.06]
#define PD_TILE_HI  [UIColor colorWithWhite:1.0 alpha:0.14]
#define PD_DIM      [UIColor colorWithWhite:1.0 alpha:0.55]
#define PD_FAINT    [UIColor colorWithWhite:1.0 alpha:0.30]
#define PD_ACCENT   [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0]
#define PD_GREEN    [UIColor colorWithRed:0.40 green:0.85 blue:0.45 alpha:1.0]
#define PD_AMBER    [UIColor colorWithRed:1.0 green:0.72 blue:0.25 alpha:1.0]
#define PD_RED      [UIColor colorWithRed:1.0 green:0.40 blue:0.35 alpha:1.0]
#define PD_HOT      [UIColor colorWithRed:1.0 green:0.50 blue:0.30 alpha:1.0]
