#import "PDSlicer.h"
#import "PDPrinter.h"
#import "PDToolpath.h"
#import "PDFilesCard.h"
#import "PDUtil.h"
#import <CommonCrypto/CommonDigest.h>
#include <spawn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>

NSString *const PDSlicerNotification = @"PDSlicerNotification";
NSString *const PDSliceSettingsChangedNotification = @"PDSliceSettingsChangedNotification";
static NSString *const PDSliceSettingsKey = @"PDSliceSettings";

static NSNumber *PDN(double v) { return [NSNumber numberWithDouble:v]; }

@interface PDSliceProfiles (Notes)   // called by PDSliceSettings when the user edits by hand
+ (void)noteEdited:(NSString *)key;
+ (void)notePrinterForNozzle:(double)nozzle;
@end

// The iPhoneOS9.3 SDK stubs don't export some libc string functions for armv7 (iOS 5 has them; the linker
// can't see them), so the few compares here are done by hand.
static int PDHasPrefix(const char *s, const char *pre) { while (*pre) if (*s++ != *pre++) return 0; return 1; }
static int PDEqual(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

#pragma mark - Settings

// One settings row. `extra` holds the kind-specific keys (see PDSlicer.h).
static NSDictionary *PDRow(NSString *key, NSString *title, NSString *kind, NSString *hint, NSDictionary *extra) {
	NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:extra ?: [NSDictionary dictionary]];
	[r setObject:key forKey:@"key"];
	[r setObject:title forKey:@"title"];
	[r setObject:kind forKey:@"kind"];
	if (hint) [r setObject:hint forKey:@"hint"];
	return r;
}
static NSDictionary *PDNumRow(NSString *key, NSString *title, double min, double max, double step, NSString *unit, int decimals, NSString *hint) {
	return PDRow(key, title, @"number", hint, [NSDictionary dictionaryWithObjectsAndKeys:PDN(min), @"min", PDN(max), @"max", PDN(step), @"step",
		unit ?: @"", @"unit", [NSNumber numberWithInt:decimals], @"decimals", nil]);
}
static NSDictionary *PDSliderRow(NSString *key, NSString *title, double min, double max, double step, NSString *unit, NSString *hint) {
	NSMutableDictionary *r = [PDNumRow(key, title, min, max, step, unit, 0, hint) mutableCopy];
	[r setObject:@"slider" forKey:@"kind"];
	return r;
}
static NSDictionary *PDChoiceRow(NSString *key, NSString *title, NSArray *options, NSArray *values, NSString *hint) {
	return PDRow(key, title, @"choice", hint, [NSDictionary dictionaryWithObjectsAndKeys:options, @"options", values, @"values", nil]);
}
static NSDictionary *PDWhen(NSDictionary *row, NSString *key, id value) {   // row applies only when key == value (or key is on)
	NSMutableDictionary *r = [row mutableCopy];
	[r setObject:key forKey:@"when"];
	if (value) [r setObject:value forKey:@"whenValue"];
	return r;
}
static NSArray *PDNums(int n, const double *v) {
	NSMutableArray *a = [NSMutableArray array];
	for (int i = 0; i < n; i++) [a addObject:PDN(v[i])];
	return a;
}

@implementation PDSliceSettings

// Laid out like OrcaSlicer / ElegooSlicer: three editors (printer, filament, process), each with tabs, each tab with
// titled groups. Rows marked advanced show only with the Advanced switch on (as in Orca). Choices with three or
// more options are drop-down menus; two-option ones are segments.
+ (NSArray *)sections {
	static NSArray *sections;
	if (sections) return sections;
	const double nozzles[] = {0.2, 0.4, 0.6, 0.8};
	const double filaments[] = {1.75, 2.85};
	const double patterns[] = {0, 1, 2, 3, 4};
	const double zeroToThree[] = {0, 1, 2, 3};
	const double zeroToTwo[] = {0, 1, 2};
	const double zeroOne[] = {0, 1};
	const double repair[] = {0, 1, 8};
	const double chamberPcts[] = {-1, 0, 30, 50, 70, 100};
	NSDictionary *(^S)(NSString *, NSString *, NSString *, NSArray *) = ^NSDictionary *(NSString *editor, NSString *tab, NSString *t, NSArray *rows) {
		return [NSDictionary dictionaryWithObjectsAndKeys:t, @"title", editor, @"editor", tab, @"tab", rows, @"rows", nil]; };
	NSDictionary *(^Adv)(NSDictionary *) = ^NSDictionary *(NSDictionary *r) { NSMutableDictionary *m = [r mutableCopy]; [m setObject:[NSNumber numberWithBool:YES] forKey:@"advanced"]; return m; };
	NSString *P = @"process", *F = @"filament", *M = @"printer";
	sections = [NSArray arrayWithObjects:
		// Printer
		S(M, @"Extruder", @"Nozzle", [NSArray arrayWithObjects:
			PDChoiceRow(@"nozzle", @"Nozzle diameter", [NSArray arrayWithObjects:@"0.2 mm", @"0.4 mm", @"0.6 mm", @"0.8 mm", nil], PDNums(4, nozzles),
				@"Sets line width and first layer; picks that nozzle's stock printer"),
			nil]),
		S(M, @"Extruder", @"Retraction", [NSArray arrayWithObjects:
			PDRow(@"retract", @"Retract on travel", @"switch", nil, nil),
			PDWhen(PDNumRow(@"retractDistance", @"Length", 0.2, 3.0, 0.1, @"mm", 1, nil), @"retract", nil),
			PDWhen(PDNumRow(@"retractSpeed", @"Retraction speed", 10, 60, 5, @"mm/s", 0, nil), @"retract", nil),
			PDWhen(PDNumRow(@"zHop", @"Z hop when retracting", 0, 3.0, 0.1, @"mm", 1, nil), @"retract", nil),
			PDWhen(PDNumRow(@"retractMinTravel", @"Travel distance threshold", 0.4, 5, 0.2, @"mm", 1, @"Shorter travels don't retract"), @"retract", nil),
			Adv(PDWhen(PDNumRow(@"retractMinExtrude", @"Minimum extrusion", 0, 2, 0.1, @"mm", 1, @"Filament between two retractions"), @"retract", nil)),
			Adv(PDWhen(PDNumRow(@"retractPrime", @"Extra length on restart", 0, 0.5, 0.05, @"mm", 2, nil), @"retract", nil)),
			nil]),
		// Filament
		S(F, @"Filament", @"Basic information", [NSArray arrayWithObjects:
			PDChoiceRow(@"material", @"Type", [NSArray arrayWithObjects:@"PLA", @"PETG", @"ABS", @"ASA", @"PC", @"PA", @"TPU", nil],
				[NSArray arrayWithObjects:@"PLA", @"PETG", @"ABS", @"ASA", @"PC", @"PA", @"TPU", nil], @"Picking a type loads its typical temperatures and fans"),
			PDChoiceRow(@"filamentDiameter", @"Diameter", [NSArray arrayWithObjects:@"1.75", @"2.85", nil], PDNums(2, filaments), @"mm"),
			PDSliderRow(@"flow", @"Flow ratio", 80, 120, 1, @"%", nil),
			nil]),
		S(F, @"Filament", @"Temperature", [NSArray arrayWithObjects:
			PDNumRow(@"nozzleTemp", @"Nozzle", 170, 300, 5, @"°C", 0, nil),
			PDNumRow(@"bedTemp", @"Bed (high temp plate)", 0, 110, 5, @"°C", 0, nil),
			nil]),
		S(F, @"Cooling", @"Part cooling fan", [NSArray arrayWithObjects:
			PDSliderRow(@"fan", @"Fan speed", 0, 100, 5, @"%", @"Normal layers"),
			PDSliderRow(@"fanMax", @"Fan speed, short layers", 0, 100, 5, @"%", @"Rises to this as layers slow down to cool"),
			PDNumRow(@"fanFullLayer", @"Full fan speed at layer", 1, 10, 1, nil, 0, nil),
			nil]),
		S(F, @"Cooling", @"Cooling slowdown", [NSArray arrayWithObjects:
			PDNumRow(@"minLayerTime", @"Layer time", 1, 30, 1, @"s", 0, @"Layers faster than this slow down"),
			Adv(PDNumRow(@"minSpeed", @"Min print speed", 5, 50, 5, @"mm/s", 0, nil)),
			Adv(PDRow(@"liftHead", @"Lift head", @"switch", @"If still too fast at min speed, wait beside the part", nil)),
			nil]),
		S(F, @"Cooling", @"Auxiliary fans", [NSArray arrayWithObjects:
			PDSliderRow(@"auxFan", @"Aux (side) fan", 0, 100, 5, @"%", nil),
			PDChoiceRow(@"chamberFanPct", @"Exhaust (chamber) fan", [NSArray arrayWithObjects:@"Auto", @"Off", @"30 %", @"50 %", @"70 %", @"100 %", nil], PDNums(6, chamberPcts),
				@"Auto: on for PLA on a hot bed"),
			nil]),
		// Process
		S(P, @"Quality", @"Layer height", [NSArray arrayWithObjects:
			PDNumRow(@"layerHeight", @"Layer height", 0.04, 0.64, 0.02, @"mm", 2, @"At most 75 % of the nozzle"),
			PDNumRow(@"firstLayerHeight", @"First layer height", 0.10, 0.60, 0.02, @"mm", 2, nil),
			nil]),
		S(P, @"Quality", @"Line width", [NSArray arrayWithObjects:
			PDNumRow(@"lineWidth", @"Default", 0.20, 1.20, 0.02, @"mm", 2, nil),
			Adv(PDSliderRow(@"firstLayerWidth", @"First layer", 100, 160, 5, @"%", @"Of the default width")),
			nil]),
		S(P, @"Strength", @"Walls", [NSArray arrayWithObjects:
			PDNumRow(@"walls", @"Wall loops", 1, 20, 1, nil, 0, nil),
			Adv(PDRow(@"wallsFirst", @"Walls before infill", @"switch", nil, nil)),
			nil]),
		S(P, @"Strength", @"Top/bottom shells", [NSArray arrayWithObjects:
			PDNumRow(@"topLayers", @"Top shell layers", 0, 15, 1, nil, 0, nil),
			PDNumRow(@"bottomLayers", @"Bottom shell layers", 0, 15, 1, nil, 0, nil),
			nil]),
		S(P, @"Strength", @"Sparse infill", [NSArray arrayWithObjects:
			PDSliderRow(@"infill", @"Sparse infill density", 0, 100, 5, @"%", nil),
			PDChoiceRow(@"infillPattern", @"Sparse infill pattern", [NSArray arrayWithObjects:@"Auto", @"Grid", @"Lines", @"Concentric", @"Gyroid", nil], PDNums(5, patterns),
				nil),
			Adv(PDSliderRow(@"infillOverlap", @"Infill/wall overlap", 0, 50, 5, @"%", nil)),
			nil]),
		S(P, @"Speed", @"First layer speed", [NSArray arrayWithObjects:
			PDNumRow(@"firstLayerSpeed", @"Initial layer", 10, 80, 5, @"mm/s", 0, nil),
			Adv(PDNumRow(@"slowLayers", @"Number of slow layers", 1, 10, 1, nil, 0, nil)),
			nil]),
		S(P, @"Speed", @"Other layers speed", [NSArray arrayWithObjects:
			PDNumRow(@"outerWallSpeed", @"Outer wall", 20, 300, 10, @"mm/s", 0, nil),
			PDNumRow(@"innerWallSpeed", @"Inner wall", 20, 300, 10, @"mm/s", 0, nil),
			PDNumRow(@"infillSpeed", @"Sparse infill", 20, 300, 10, @"mm/s", 0, nil),
			PDNumRow(@"skinSpeed", @"Top / solid infill", 20, 300, 10, @"mm/s", 0, nil),
			PDNumRow(@"printSpeed", @"Support / other", 20, 300, 10, @"mm/s", 0, nil),
			nil]),
		S(P, @"Speed", @"Travel and acceleration", [NSArray arrayWithObjects:
			PDNumRow(@"travelSpeed", @"Travel", 50, 500, 25, @"mm/s", 0, nil),
			PDNumRow(@"acceleration", @"Acceleration", 1000, 20000, 1000, @"mm/s²", 0, @"Sent as M204; also used for the time estimate"),
			nil]),
		S(P, @"Support", @"Support", [NSArray arrayWithObjects:
			PDChoiceRow(@"support", @"Enable support", [NSArray arrayWithObjects:@"Off", @"On build plate only", @"Everywhere", nil], PDNums(3, zeroToTwo), nil),
			PDWhen(PDNumRow(@"supportAngle", @"Overhang angle", 30, 85, 5, @"°", 0, @"From vertical: steeper overhangs get support"), @"support", nil),
			PDWhen(PDSliderRow(@"supportDensity", @"Density", 5, 40, 5, @"%", nil), @"support", nil),
			PDWhen(PDChoiceRow(@"supportPattern", @"Pattern", [NSArray arrayWithObjects:@"Grid", @"Lines", nil], PDNums(2, zeroOne), nil), @"support", nil),
			PDWhen(PDNumRow(@"supportGap", @"Top Z distance", 0.10, 0.50, 0.05, @"mm", 2, nil), @"support", nil),
			Adv(PDWhen(PDNumRow(@"supportXY", @"Support/object XY distance", 0.3, 2.0, 0.05, @"mm", 2, nil), @"support", nil)),
			nil]),
		S(P, @"Support", @"Raft", [NSArray arrayWithObjects:
			PDWhen(PDNumRow(@"raftLayers", @"Raft top layers", 1, 4, 1, nil, 0, @"Turn the raft on in Others → Bed adhesion"), @"adhesion", PDN(3)),
			PDWhen(PDNumRow(@"raftMargin", @"Raft expansion", 1, 15, 1, @"mm", 0, nil), @"adhesion", PDN(3)),
			PDWhen(PDNumRow(@"raftGap", @"Raft contact Z distance", 0, 0.5, 0.05, @"mm", 2, nil), @"adhesion", PDN(3)),
			nil]),
		S(P, @"Others", @"Bed adhesion", [NSArray arrayWithObjects:
			PDChoiceRow(@"adhesion", @"Type", [NSArray arrayWithObjects:@"None", @"Skirt", @"Brim", @"Raft", nil], PDNums(4, zeroToThree), nil),
			PDWhen(PDNumRow(@"skirtLines", @"Skirt loops", 1, 5, 1, nil, 0, nil), @"adhesion", PDN(1)),
			PDWhen(PDNumRow(@"skirtDistance", @"Skirt distance", 1, 10, 0.5, @"mm", 1, nil), @"adhesion", PDN(1)),
			Adv(PDWhen(PDNumRow(@"skirtMinLength", @"Skirt minimum length", 0, 500, 50, @"mm", 0, @"Filament primed by the skirt"), @"adhesion", PDN(1))),
			PDWhen(PDNumRow(@"brimLines", @"Brim loops", 1, 30, 1, nil, 0, nil), @"adhesion", PDN(2)),
			nil]),
		S(P, @"Others", @"Special mode", [NSArray arrayWithObjects:
			PDRow(@"vase", @"Spiral vase", @"switch", @"One spiralled outer wall; no infill or top", nil),
			nil]),
		S(P, @"Others", @"Advanced", [NSArray arrayWithObjects:
			Adv(PDChoiceRow(@"combing", @"Avoid crossing walls", [NSArray arrayWithObjects:@"Off", @"On", @"Not on skins", nil], PDNums(3, zeroToTwo), @"Travel inside the part instead of retracting")),
			Adv(PDChoiceRow(@"repair", @"Mesh repair", [NSArray arrayWithObjects:@"Off", @"Union overlaps", @"Stitch holes", nil], PDNums(3, repair), nil)),
			Adv(PDNumRow(@"sink", @"Sink into bed", 0, 10, 0.5, @"mm", 1, @"Cut this much off the bottom")),
			nil]),
		nil];
	return sections;
}

+ (NSArray *)tabsForEditor:(NSString *)editor {
	NSMutableArray *tabs = [NSMutableArray array];
	for (NSDictionary *s in [self sections])
		if ([[s objectForKey:@"editor"] isEqualToString:editor] && ![tabs containsObject:[s objectForKey:@"tab"]]) [tabs addObject:[s objectForKey:@"tab"]];
	return tabs;
}

+ (NSArray *)sectionsForEditor:(NSString *)editor tab:(NSString *)tab advanced:(BOOL)advanced {
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *s in [self sections]) {
		if (![[s objectForKey:@"editor"] isEqualToString:editor] || ![[s objectForKey:@"tab"] isEqualToString:tab]) continue;
		NSMutableArray *rows = [NSMutableArray array];
		for (NSDictionary *r in [s objectForKey:@"rows"]) if (advanced || ![[r objectForKey:@"advanced"] boolValue]) [rows addObject:r];
		if ([rows count]) { NSMutableDictionary *m = [s mutableCopy]; [m setObject:rows forKey:@"rows"]; [out addObject:m]; }
	}
	return out;
}

+ (NSString *)editorForKey:(NSString *)key {
	if ([key hasPrefix:@"filament"]) return @"filament";   // filamentName/Density/Colour/Diameter
	for (NSDictionary *s in [self sections]) for (NSDictionary *r in [s objectForKey:@"rows"])
		if ([[r objectForKey:@"key"] isEqualToString:key]) return [s objectForKey:@"editor"];
	return @"process";
}

+ (NSArray *)keysForEditor:(NSString *)editor {
	NSMutableArray *a = [NSMutableArray array];
	for (NSString *k in [self defaults]) if ([[self editorForKey:k] isEqualToString:editor]) [a addObject:k];
	return a;
}

// Layer height for a quality preset: 30 / 40 / 50 / 60 / 70 % of the nozzle, rounded to 0.02 mm (0.6 mm nozzle:
// 0.18 / 0.24 / 0.30 / 0.36 / 0.42, matching ElegooSlicer's 0.6 mm process presets).
static double PDPresetLayer(double nozzle, int preset) {
	double f = 0.3 + 0.1 * MAX(0, MIN(4, preset));
	return MAX(0.04, round(nozzle * f / 0.02) * 0.02);
}

+ (NSDictionary *)defaults {
	static NSDictionary *d;
	if (!d) d = [NSDictionary dictionaryWithObjectsAndKeys:
		PDN(0.6), @"nozzle", PDN(1.75), @"filamentDiameter", PDN(5000), @"acceleration",
		@"PLA", @"material", PDN(220), @"nozzleTemp", PDN(60), @"bedTemp", PDN(100), @"flow",
		PDN(1), @"quality", PDN(0.24), @"layerHeight", PDN(0.30), @"firstLayerHeight", PDN(0.62), @"lineWidth", PDN(120), @"firstLayerWidth",
		PDN(2), @"walls", PDN(4), @"topLayers", PDN(3), @"bottomLayers", PDN(15), @"infill", PDN(0), @"infillPattern",
		PDN(15), @"infillOverlap", PDN(0), @"wallsFirst",
		PDN(0), @"support", PDN(50), @"supportAngle", PDN(15), @"supportDensity", PDN(1), @"supportPattern", PDN(0.20), @"supportGap", PDN(0.7), @"supportXY",
		PDN(1), @"adhesion", PDN(3), @"skirtDistance", PDN(1), @"skirtLines", PDN(0), @"skirtMinLength", PDN(8), @"brimLines",
		PDN(5), @"raftMargin", PDN(0.25), @"raftGap", PDN(2), @"raftLayers",
		PDN(120), @"printSpeed", PDN(80), @"outerWallSpeed", PDN(120), @"innerWallSpeed", PDN(140), @"infillSpeed",
		PDN(100), @"skinSpeed", PDN(30), @"firstLayerSpeed", PDN(4), @"slowLayers", PDN(300), @"travelSpeed",
		PDN(100), @"fan", PDN(100), @"fanMax", PDN(3), @"fanFullLayer", PDN(6), @"minLayerTime", PDN(10), @"minSpeed", PDN(0), @"liftHead",
		PDN(0), @"auxFan", PDN(-1), @"chamberFanPct",
		PDN(0), @"filamentDensity", @"", @"filamentName", @"#3C8CE6", @"filamentColor",   // no rows: set by filament profiles / the swatch
		PDN(1), @"retract", PDN(0.8), @"retractDistance", PDN(40), @"retractSpeed", PDN(0), @"zHop", PDN(1.5), @"retractMinTravel",
		PDN(0.1), @"retractMinExtrude", PDN(0), @"retractPrime",
		PDN(1), @"combing", PDN(0), @"vase", PDN(0), @"repair", PDN(0), @"sink",
		nil];
	return d;
}

+ (NSDictionary *)current {
	NSMutableDictionary *d = [[self defaults] mutableCopy];
	NSDictionary *mine = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PDSliceSettingsKey];
	for (NSString *k in mine) if ([d objectForKey:k]) [d setObject:[mine objectForKey:k] forKey:k];
	return d;
}

+ (id)valueForKey:(NSString *)key { return [[self current] objectForKey:key]; }
+ (double)numberForKey:(NSString *)key { id v = [self valueForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }

// Picking a filament type loads its usual temperatures, fan and outer-wall speed (and forgets the stock
// filament profile's name and density, since it's no longer that filament).
+ (void)applyMaterial:(NSString *)m into:(NSMutableDictionary *)d {
	double noz = 220, bed = 60, fan = 100, outer = 80, all = 120;
	if ([m isEqualToString:@"PETG"]) { noz = 240; bed = 70; fan = 40; }
	else if ([m isEqualToString:@"ABS"]) { noz = 250; bed = 90; fan = 0; }
	else if ([m isEqualToString:@"ASA"]) { noz = 260; bed = 100; fan = 20; }
	else if ([m isEqualToString:@"PC"]) { noz = 270; bed = 110; fan = 0; }
	else if ([m isEqualToString:@"PA"]) { noz = 290; bed = 80; fan = 0; }
	else if ([m isEqualToString:@"TPU"]) { noz = 225; bed = 40; fan = 60; outer = 25; all = 30; }
	[d setObject:@"" forKey:@"filamentName"];
	[d setObject:PDN(0) forKey:@"filamentDensity"];   // (the colour stays: it's the spool's, not the type's)
	[d setObject:PDN(noz) forKey:@"nozzleTemp"];
	[d setObject:PDN(bed) forKey:@"bedTemp"];
	[d setObject:PDN(fan) forKey:@"fan"];
	BOOL hot = [m isEqualToString:@"ABS"] || [m isEqualToString:@"ASA"] || [m isEqualToString:@"PC"] || [m isEqualToString:@"PA"];
	[d setObject:PDN(MAX(fan, hot ? 30 : 100)) forKey:@"fanMax"];
	[d setObject:PDN(outer) forKey:@"outerWallSpeed"];
	for (NSString *k in [NSArray arrayWithObjects:@"printSpeed", @"innerWallSpeed", @"infillSpeed", @"skinSpeed", nil])
		[d setObject:PDN([m isEqualToString:@"TPU"] ? all : [[[self defaults] objectForKey:k] doubleValue]) forKey:k];
}

+ (void)setValue:(id)value forKey:(NSString *)key {
	if (!value || ![[self defaults] objectForKey:key]) return;
	if ([key isEqualToString:@"nozzle"]) {
		for (NSDictionary *q in [PDSliceProfiles printers])
			if (fabs([[q objectForKey:@"nozzle"] doubleValue] - [value doubleValue]) < 1e-6) { [PDSliceProfiles applyPrinter:q]; return; }
	}
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *mine = [[ud dictionaryForKey:PDSliceSettingsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	[mine setObject:value forKey:key];
	if ([key isEqualToString:@"material"]) [self applyMaterial:value into:mine];
	[self applyNozzleRulesFor:key into:mine];
	[ud setObject:mine forKey:PDSliceSettingsKey];
	[PDSliceProfiles noteEdited:key];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDSliceSettingsChangedNotification object:nil];
}

// Writes many values at once (a profile): clamped to each row's range, no side effects, one notification.
+ (void)applyValues:(NSDictionary *)values replacingAll:(BOOL)replace {
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *mine = replace ? [NSMutableDictionary dictionary] : ([[ud dictionaryForKey:PDSliceSettingsKey] mutableCopy] ?: [NSMutableDictionary dictionary]);
	NSDictionary *defs = [self defaults];
	for (NSString *k in values) {
		id v = [values objectForKey:k];
		if (![defs objectForKey:k] || ![v isKindOfClass:[[defs objectForKey:k] isKindOfClass:[NSString class]] ? [NSString class] : [NSNumber class]]) continue;
		NSDictionary *row = [self rowForKey:k];
		if ([v isKindOfClass:[NSNumber class]] && [row objectForKey:@"min"])
			v = PDN(MAX([[row objectForKey:@"min"] doubleValue], MIN([[row objectForKey:@"max"] doubleValue], [v doubleValue])));
		[mine setObject:v forKey:k];
	}
	[self applyNozzleRulesFor:@"layerHeight" into:mine];   // clamp to the nozzle and match the quality preset
	[ud setObject:mine forKey:PDSliceSettingsKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDSliceSettingsChangedNotification object:nil];
}

// Nozzle size and quality preset drive the layer height and line widths; editing the layer height by hand
// clears the preset (no segment selected) and keeps it within 75 % of the nozzle.
+ (void)applyNozzleRulesFor:(NSString *)key into:(NSMutableDictionary *)mine {
	NSMutableDictionary *cur = [[self defaults] mutableCopy];
	[cur addEntriesFromDictionary:mine];
	double nozzle = [[cur objectForKey:@"nozzle"] doubleValue];
	if ([key isEqualToString:@"nozzle"]) {
		[PDSliceProfiles notePrinterForNozzle:nozzle];
		[mine setObject:PDN(round(nozzle * 1.05 / 0.02) * 0.02) forKey:@"lineWidth"];
		[mine setObject:PDN(round(nozzle * 0.5 / 0.02) * 0.02) forKey:@"firstLayerHeight"];
		int q = [[cur objectForKey:@"quality"] intValue];
		if (q < 0) q = 2;
		[mine setObject:PDN(q) forKey:@"quality"];
		[mine setObject:PDN(PDPresetLayer(nozzle, q)) forKey:@"layerHeight"];
	} else if ([key isEqualToString:@"quality"]) {
		[mine setObject:PDN(PDPresetLayer(nozzle, [[cur objectForKey:@"quality"] intValue])) forKey:@"layerHeight"];
	} else if ([key isEqualToString:@"layerHeight"]) {
		double lh = MIN([[cur objectForKey:@"layerHeight"] doubleValue], floor(nozzle * 0.75 / 0.02 + 1e-6) * 0.02);
		[mine setObject:PDN(lh) forKey:@"layerHeight"];
		int match = -1;
		for (int q = 0; q < 5; q++) if (fabs(PDPresetLayer(nozzle, q) - lh) < 1e-6) match = q;
		[mine setObject:PDN(match) forKey:@"quality"];
	}
}

+ (void)resetToDefaults {
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:PDSliceSettingsKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDSliceSettingsChangedNotification object:nil];
}

+ (NSDictionary *)rowForKey:(NSString *)key {
	for (NSDictionary *s in [self sections]) for (NSDictionary *r in [s objectForKey:@"rows"]) if ([[r objectForKey:@"key"] isEqualToString:key]) return r;
	return nil;
}

+ (NSString *)displayValueForRow:(NSDictionary *)row {
	NSString *kind = [row objectForKey:@"kind"];
	id v = [self valueForKey:[row objectForKey:@"key"]];
	if ([kind isEqualToString:@"switch"]) return [v boolValue] ? @"On" : @"Off";
	if ([kind isEqualToString:@"choice"]) {
		NSArray *vals = [row objectForKey:@"values"], *opts = [row objectForKey:@"options"];
		for (NSUInteger i = 0; i < [vals count]; i++) {
			id x = [vals objectAtIndex:i];
			if ([x isEqual:v] || ([x isKindOfClass:[NSNumber class]] && [v isKindOfClass:[NSNumber class]] && fabs([x doubleValue] - [v doubleValue]) < 1e-6))
				return [opts objectAtIndex:i];
		}
		return [v description];
	}
	int dec = [[row objectForKey:@"decimals"] intValue];
	NSString *unit = [row objectForKey:@"unit"];
	NSString *num = [NSString stringWithFormat:@"%.*f", dec, [v doubleValue]];
	return [unit length] ? [NSString stringWithFormat:@"%@ %@", num, unit] : num;
}

@end

#pragma mark - Profiles

static NSString *const PDSliceProfileStateKey = @"PDSliceProfile";
static NSString *const PDSlicePresetsKey = @"PDSlicePresets";
static NSString *const PDDefaultPrinter = @"Elegoo Centauri Carbon 0.6 nozzle";
static NSString *const PDDefaultProcess = @"0.24mm Optimal @Elegoo CC 0.6 nozzle";
static NSString *const PDDefaultFilament = @"Elegoo PLA @ECC";

@interface PDSliceSettings (Profiles)
+ (void)applyValues:(NSDictionary *)values replacingAll:(BOOL)replace;
@end

@implementation PDSliceProfiles

+ (NSDictionary *)stock {
	static NSDictionary *stock;
	if (!stock) stock = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"StockProfiles" ofType:@"plist"]] ?: [NSDictionary dictionary];
	return stock;
}
+ (NSArray *)printers { return [[self stock] objectForKey:@"printers"]; }

+ (NSDictionary *)named:(NSString *)name in:(NSString *)list {
	for (NSDictionary *d in [[self stock] objectForKey:list]) if ([[d objectForKey:@"name"] isEqualToString:name]) return d;
	return nil;
}
+ (NSArray *)list:(NSString *)list forPrinter:(NSString *)printer {
	NSMutableArray *a = [NSMutableArray array];
	for (NSDictionary *d in [[self stock] objectForKey:list]) if ([[d objectForKey:@"printers"] containsObject:printer]) [a addObject:d];
	return a;
}
+ (NSArray *)processesForPrinter:(NSString *)printer { return [self list:@"processes" forPrinter:printer]; }
+ (NSArray *)filamentsForPrinter:(NSString *)printer { return [self list:@"filaments" forPrinter:printer]; }

// state: printer / filament / process = the selected preset's name (a stock name, or a user preset's name with
// user<editor> = YES), and edited<editor> = YES once a setting of that editor was changed by hand.
+ (NSDictionary *)state { return [[NSUserDefaults standardUserDefaults] dictionaryForKey:PDSliceProfileStateKey] ?: [NSDictionary dictionaryWithObjectsAndKeys:PDDefaultPrinter, @"printer", nil]; }
+ (void)setState:(NSDictionary *)st { [[NSUserDefaults standardUserDefaults] setObject:st forKey:PDSliceProfileStateKey]; }
+ (void)updateState:(void (^)(NSMutableDictionary *st))change {
	NSMutableDictionary *st = [[self state] mutableCopy];
	change(st);
	[self setState:st];
}
+ (void)select:(NSString *)name editor:(NSString *)editor user:(BOOL)user {
	[self updateState:^(NSMutableDictionary *st) {
		if (name) [st setObject:name forKey:editor]; else [st removeObjectForKey:editor];
		[st setObject:[NSNumber numberWithBool:user] forKey:[@"user" stringByAppendingString:editor]];
		[st removeObjectForKey:[@"edited" stringByAppendingString:editor]];
	}];
}

+ (NSDictionary *)currentPrinter {
	NSDictionary *st = [self state];
	NSDictionary *p = [self named:[st objectForKey:@"printer"] in:@"printers"];
	if (!p && [[st objectForKey:@"userprinter"] boolValue]) p = [self named:[[self userPreset:[st objectForKey:@"printer"] editor:@"printer"] objectForKey:@"printer"] in:@"printers"];
	double nozzle = [PDSliceSettings numberForKey:@"nozzle"];
	if (p && fabs([[p objectForKey:@"nozzle"] doubleValue] - nozzle) < 1e-6) return p;
	for (NSDictionary *q in [self printers]) if (fabs([[q objectForKey:@"nozzle"] doubleValue] - nozzle) < 1e-6) return q;
	return p;
}

+ (void)noteEdited:(NSString *)key {
	NSString *editor = [PDSliceSettings editorForKey:key];
	[self updateState:^(NSMutableDictionary *st) { [st setObject:[NSNumber numberWithBool:YES] forKey:[@"edited" stringByAppendingString:editor]]; }];
}
+ (void)notePrinterForNozzle:(double)nozzle {}

+ (void)applyPrinter:(NSDictionary *)printer {
	if (!printer) return;
	NSString *name = [printer objectForKey:@"name"];
	NSDictionary *process = [self named:[printer objectForKey:@"defaultProcess"] in:@"processes"];
	NSDictionary *filament = [self named:[[self state] objectForKey:@"filament"] in:@"filaments"];
	if (![[filament objectForKey:@"printers"] containsObject:name]) filament = [self named:[printer objectForKey:@"defaultFilament"] in:@"filaments"];
	NSMutableDictionary *v = [NSMutableDictionary dictionary];
	[v addEntriesFromDictionary:[printer objectForKey:@"settings"]];
	[v addEntriesFromDictionary:[process objectForKey:@"settings"]];
	if (filament) {
		NSMutableDictionary *fv = [[filament objectForKey:@"settings"] mutableCopy];
		[fv removeObjectForKey:@"filamentColor"];   // keep the spool colour the user picked
		[v addEntriesFromDictionary:fv];   // a filament's own retraction wins
	}
	BOOL keepUserFilament = [[[self state] objectForKey:@"userfilament"] boolValue];
	NSString *keptFilament = [[self state] objectForKey:@"filament"];
	[self setState:[NSDictionary dictionaryWithObjectsAndKeys:name, @"printer", [process objectForKey:@"name"] ?: @"", @"process",
		(filament ? [filament objectForKey:@"name"] : keptFilament) ?: @"", @"filament",
		[NSNumber numberWithBool:(!filament && keepUserFilament)], @"userfilament", nil]];
	[PDSliceSettings applyValues:v replacingAll:NO];
}

+ (void)applyProcess:(NSDictionary *)process {
	if (!process) return;
	[self select:[process objectForKey:@"name"] editor:@"process" user:NO];
	[PDSliceSettings applyValues:[process objectForKey:@"settings"] replacingAll:NO];
}

+ (void)applyFilament:(NSDictionary *)filament {
	if (!filament) return;
	[self select:[filament objectForKey:@"name"] editor:@"filament" user:NO];
	NSMutableDictionary *v = [[filament objectForKey:@"settings"] mutableCopy];
	// Retraction comes from the printer unless the filament overrides it.
	NSDictionary *printer = [self currentPrinter];
	for (NSString *k in [NSArray arrayWithObjects:@"retractDistance", @"retractSpeed", @"retractMinTravel", @"zHop", nil])
		if (![v objectForKey:k] && [[printer objectForKey:@"settings"] objectForKey:k]) [v setObject:[[printer objectForKey:@"settings"] objectForKey:k] forKey:k];
	[PDSliceSettings applyValues:v replacingAll:NO];
}

// Resources/ImportedPresets.plist (tools/import-user-presets.py: the user presets from ElegooSlicer / OrcaSlicer on
// the build computer) joins the user presets once: each is added the first time this build carries it, unless a
// preset of that name exists; deleting one keeps it deleted.
+ (void)importBundledPresets {
	NSString *f = [[NSBundle mainBundle] pathForResource:@"ImportedPresets" ofType:@"plist"];
	NSArray *incoming = f ? [[NSDictionary dictionaryWithContentsOfFile:f] objectForKey:@"presets"] : nil;
	if (![incoming count]) return;
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSMutableArray *done = [[ud arrayForKey:@"PDSliceImported"] mutableCopy] ?: [NSMutableArray array];
	NSMutableArray *all = [([ud arrayForKey:PDSlicePresetsKey] ?: [NSArray array]) mutableCopy];
	BOOL changed = NO;
	for (NSDictionary *p in incoming) {
		NSString *editor = [p objectForKey:@"editor"], *name = [p objectForKey:@"name"];
		NSString *ident = [NSString stringWithFormat:@"%@|%@|%@", [p objectForKey:@"from"], editor, name];
		if (![name length] || [done containsObject:ident]) continue;
		[done addObject:ident];
		BOOL exists = NO;
		for (NSDictionary *q in all)
			if ([[q objectForKey:@"name"] isEqualToString:name] && [[q objectForKey:@"editor"] ?: @"process" isEqualToString:editor]) exists = YES;
		if (exists) continue;
		NSMutableDictionary *m = [p mutableCopy];
		[m setObject:[NSDate date] forKey:@"date"];
		[all addObject:m];
		changed = YES;
	}
	[ud setObject:done forKey:@"PDSliceImported"];
	if (changed) [ud setObject:all forKey:PDSlicePresetsKey];
}

+ (NSArray *)allUserPresets {
	static dispatch_once_t once;
	dispatch_once(&once, ^{ [self importBundledPresets]; });
	NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:PDSlicePresetsKey] ?: [NSArray array];
	return [a sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) { return [[x objectForKey:@"name"] caseInsensitiveCompare:[y objectForKey:@"name"]]; }];
}
+ (NSArray *)userPresets { return [self allUserPresets]; }

// A user's printer presets are for any printer; filament and process presets belong to the printer (machine +
// nozzle) they were saved on, as in Orca.
+ (NSArray *)userPresetsForEditor:(NSString *)editor {
	NSString *printer = [[self currentPrinter] objectForKey:@"name"];
	NSMutableArray *a = [NSMutableArray array];
	for (NSDictionary *p in [self allUserPresets]) {
		if (![[p objectForKey:@"editor"] ?: @"process" isEqualToString:editor]) continue;
		// An imported preset can fit several nozzles ("printers"); one saved here belongs to one ("printer").
		if ([editor isEqualToString:@"printer"] || !printer || [[p objectForKey:@"printer"] isEqualToString:printer] ||
			[[p objectForKey:@"printers"] containsObject:printer]) [a addObject:p];
	}
	return a;
}
+ (NSDictionary *)userPreset:(NSString *)name editor:(NSString *)editor {
	for (NSDictionary *p in [self allUserPresets])
		if ([[p objectForKey:@"name"] isEqualToString:name] && [[p objectForKey:@"editor"] ?: @"process" isEqualToString:editor]) return p;
	return nil;
}

+ (void)saveUserPreset:(NSString *)name { [self saveUserPreset:name editor:@"process"]; }
+ (void)saveUserPreset:(NSString *)name editor:(NSString *)editor {
	name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![name length]) return;
	NSString *printer = [[self currentPrinter] objectForKey:@"name"] ?: PDDefaultPrinter;
	NSDictionary *cur = [PDSliceSettings current];
	NSMutableDictionary *values = [NSMutableDictionary dictionary];
	for (NSString *k in [PDSliceSettings keysForEditor:editor]) if ([cur objectForKey:k]) [values setObject:[cur objectForKey:k] forKey:k];
	NSDictionary *preset = [NSDictionary dictionaryWithObjectsAndKeys:name, @"name", editor, @"editor", printer, @"printer", [NSDate date], @"date", values, @"settings", nil];
	NSMutableArray *all = [NSMutableArray array];
	for (NSDictionary *p in [self allUserPresets])
		if (!([[p objectForKey:@"name"] isEqualToString:name] && [[p objectForKey:@"editor"] ?: @"process" isEqualToString:editor])) [all addObject:p];
	[all addObject:preset];
	[[NSUserDefaults standardUserDefaults] setObject:all forKey:PDSlicePresetsKey];
	[self select:name editor:editor user:YES];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDSliceSettingsChangedNotification object:nil];
}

+ (void)applyUserPreset:(NSDictionary *)preset {
	if (!preset) return;
	NSString *editor = [preset objectForKey:@"editor"] ?: @"process";
	[self select:[preset objectForKey:@"name"] editor:editor user:YES];
	[PDSliceSettings applyValues:[preset objectForKey:@"settings"] replacingAll:NO];
}

+ (void)deleteUserPreset:(NSDictionary *)preset {
	NSString *editor = [preset objectForKey:@"editor"] ?: @"process";
	NSMutableArray *all = [NSMutableArray array];
	for (NSDictionary *p in [self allUserPresets])
		if (!([[p objectForKey:@"name"] isEqualToString:[preset objectForKey:@"name"]] && [[p objectForKey:@"editor"] ?: @"process" isEqualToString:editor])) [all addObject:p];
	[[NSUserDefaults standardUserDefaults] setObject:all forKey:PDSlicePresetsKey];
	NSDictionary *st = [self state];
	if ([[st objectForKey:[@"user" stringByAppendingString:editor]] boolValue] && [[st objectForKey:editor] isEqualToString:[preset objectForKey:@"name"]])
		[self updateState:^(NSMutableDictionary *s2) { [s2 setObject:[NSNumber numberWithBool:YES] forKey:[@"edited" stringByAppendingString:editor]]; }];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDSliceSettingsChangedNotification object:nil];
}

+ (void)resetToDefaults {
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:PDSliceSettingsKey];
	[self setState:[NSDictionary dictionaryWithObjectsAndKeys:PDDefaultPrinter, @"printer", PDDefaultFilament, @"filament", nil]];
	NSDictionary *printer = [self named:PDDefaultPrinter in:@"printers"];
	if (!printer) { [PDSliceSettings resetToDefaults]; return; }
	[self applyPrinter:printer];
	[self applyProcess:[self named:PDDefaultProcess in:@"processes"]];
}

// The name a combo shows for an editor: the stock profile's title, or the user preset's name.
+ (NSString *)selectedTitleForEditor:(NSString *)editor {
	NSDictionary *st = [self state];
	NSString *name = [st objectForKey:editor];
	if (![name length]) return nil;
	if ([[st objectForKey:[@"user" stringByAppendingString:editor]] boolValue]) return name;
	NSString *list = [editor isEqualToString:@"printer"] ? @"printers" : [editor isEqualToString:@"filament"] ? @"filaments" : @"processes";
	NSDictionary *d = [self named:name in:list];
	return [d objectForKey:@"title"] ?: [d objectForKey:@"name"] ?: name;
}
+ (BOOL)isEdited:(NSString *)editor { return [[[self state] objectForKey:[@"edited" stringByAppendingString:editor]] boolValue]; }
+ (BOOL)isUser:(NSString *)editor { return [[[self state] objectForKey:[@"user" stringByAppendingString:editor]] boolValue]; }

+ (NSString *)summary {
	NSMutableArray *parts = [NSMutableArray array];
	for (NSString *e in [NSArray arrayWithObjects:@"process", @"filament", nil]) {
		NSString *t = [self selectedTitleForEditor:e] ?: ([e isEqualToString:@"process"] ? @"Custom" : [PDSliceSettings valueForKey:@"material"]);
		[parts addObject:[self isEdited:e] ? [t stringByAppendingString:@"*"] : t];
	}
	return [parts componentsJoinedByString:@" · "];
}

@end

#pragma mark - Model

@interface PDModel () {
	float *_tris;
	NSUInteger _ntri;
	BOOL _boundsValid;
	GLKVector3 _bmin, _bmax;
}
@property (nonatomic, readwrite, copy) NSString *name, *source;
@end

@implementation PDModel

- (id)init { if ((self = [super init])) { _scale = 1; } return self; }
- (void)dealloc { free(_tris); }
- (NSUInteger)triangleCount { return _ntri; }
- (const float *)triangles { return _tris; }
- (void)setQuarterX:(int)q { _quarterX = ((q % 4) + 4) % 4; _boundsValid = NO; }
- (void)setQuarterY:(int)q { _quarterY = ((q % 4) + 4) % 4; _boundsValid = NO; }
- (void)setRotZ:(float)r { _rotZ = fmodf(fmodf(r, 360) + 360, 360); _boundsValid = NO; }
- (void)setScale:(float)s { _scale = MAX(0.01f, MIN(100.0f, s)); _boundsValid = NO; }

#define PD_MAX_TRIANGLES 400000

+ (PDModel *)withTriangles:(float *)t count:(NSUInteger)n name:(NSString *)name source:(NSString *)source {
	PDModel *m = [[PDModel alloc] init];
	m->_tris = t; m->_ntri = n;
	m.name = name; m.source = source;
	return m;
}

+ (PDModel *)loadFile:(NSString *)file error:(NSString **)error {
	NSData *d = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:NULL];
	NSString *name = [[file lastPathComponent] stringByDeletingPathExtension];
	if (!d) { if (error) *error = @"Couldn't read the file."; return nil; }
	const uint8_t *b = [d bytes];
	NSUInteger len = [d length];
	uint32_t n = 0;
	if (len >= 84) memcpy(&n, b + 80, 4);
	BOOL binary = len >= 84 && (uint64_t)84 + (uint64_t)n * 50 == len;
	if (binary) {
		if (n == 0) { if (error) *error = @"The STL has no triangles."; return nil; }
		if (n > PD_MAX_TRIANGLES) { if (error) *error = [NSString stringWithFormat:@"Too detailed: %u triangles (the iPad handles up to %d).", n, PD_MAX_TRIANGLES]; return nil; }
		float *t = malloc((size_t)n * 9 * sizeof(float));
		for (uint32_t i = 0; i < n; i++) memcpy(t + i * 9, b + 84 + (size_t)i * 50 + 12, 36);
		return [self withTriangles:t count:n name:name source:file];
	}
	// ASCII: every "vertex x y z"; three make a triangle.
	size_t cap = 3 * 1024, nv = 0;
	float *v = malloc(cap * 3 * sizeof(float));
	const char *p = (const char *)b, *end = p + len;
	while (p < end) {
		const char *hit = NULL;
		for (const char *q = p; q + 6 <= end; q++) if (q[0] == 'v' && memcmp(q, "vertex", 6) == 0) { hit = q; break; }
		if (!hit) break;
		char tmp[160];
		size_t take = MIN((size_t)(end - hit - 6), sizeof tmp - 1);
		memcpy(tmp, hit + 6, take); tmp[take] = 0;
		char *e1, *e2, *e3;
		float x = strtof(tmp, &e1), y = strtof(e1, &e2), z = strtof(e2, &e3);
		if (e1 == tmp || e2 == e1 || e3 == e2) break;
		if (nv == cap) { cap *= 2; v = realloc(v, cap * 3 * sizeof(float)); }
		v[nv * 3] = x; v[nv * 3 + 1] = y; v[nv * 3 + 2] = z; nv++;
		p = hit + 6 + (e3 - tmp);
		if (nv / 3 > PD_MAX_TRIANGLES) { free(v); if (error) *error = [NSString stringWithFormat:@"Too detailed: more than %d triangles.", PD_MAX_TRIANGLES]; return nil; }
	}
	if (nv < 3) { free(v); if (error) *error = @"Not an STL file (no triangles found)."; return nil; }
	return [self withTriangles:v count:nv / 3 name:name source:file];
}

#pragma mark Built-in shapes

+ (NSArray *)builtinNames { return [NSArray arrayWithObjects:@"Calibration cube", @"Cylinder", @"Sphere", @"Support test", nil]; }

typedef struct { float *t; NSUInteger n, cap; } PDTriBuf;
static void pdt_add(PDTriBuf *b, GLKVector3 p, GLKVector3 q, GLKVector3 r) {
	if (b->n == b->cap) { b->cap = b->cap ? b->cap * 2 : 256; b->t = realloc(b->t, b->cap * 9 * sizeof(float)); }
	float *o = b->t + b->n * 9;
	o[0] = p.x; o[1] = p.y; o[2] = p.z; o[3] = q.x; o[4] = q.y; o[5] = q.z; o[6] = r.x; o[7] = r.y; o[8] = r.z;
	b->n++;
}
static void pdt_quad(PDTriBuf *b, GLKVector3 p, GLKVector3 q, GLKVector3 r, GLKVector3 s) { pdt_add(b, p, q, r); pdt_add(b, p, r, s); }
static void pdt_box(PDTriBuf *b, float x0, float y0, float z0, float x1, float y1, float z1) {
	GLKVector3 v[8];
	for (int i = 0; i < 8; i++) v[i] = GLKVector3Make(i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0);
	pdt_quad(b, v[0], v[2], v[3], v[1]);   // bottom (outward = -z)
	pdt_quad(b, v[4], v[5], v[7], v[6]);   // top
	pdt_quad(b, v[0], v[1], v[5], v[4]);   // y0
	pdt_quad(b, v[2], v[6], v[7], v[3]);   // y1
	pdt_quad(b, v[0], v[4], v[6], v[2]);   // x0
	pdt_quad(b, v[1], v[3], v[7], v[5]);   // x1
}

+ (PDModel *)builtin:(NSString *)name {
	PDTriBuf b = {0};
	if ([name isEqualToString:@"Calibration cube"]) {
		pdt_box(&b, 0, 0, 0, 20, 20, 20);
	} else if ([name isEqualToString:@"Cylinder"]) {   // Ø20 × 20 mm
		const int n = 72; const float r = 10, h = 20;
		for (int i = 0; i < n; i++) {
			float a0 = 2 * M_PI * i / n, a1 = 2 * M_PI * (i + 1) / n;
			GLKVector3 p0 = GLKVector3Make(r * cosf(a0), r * sinf(a0), 0), p1 = GLKVector3Make(r * cosf(a1), r * sinf(a1), 0);
			GLKVector3 q0 = GLKVector3Make(p0.x, p0.y, h), q1 = GLKVector3Make(p1.x, p1.y, h);
			pdt_quad(&b, p0, p1, q1, q0);
			pdt_add(&b, GLKVector3Make(0, 0, 0), p1, p0);
			pdt_add(&b, GLKVector3Make(0, 0, h), q0, q1);
		}
	} else if ([name isEqualToString:@"Sphere"]) {     // Ø30 mm, the bottom cap cut flat so it stands
		const int seg = 64, rings = 32; const float r = 15;
		const int lo = 3;   // skip the lowest rings: a flat base ~ 4.4 mm across
		GLKVector3 (^P)(int, int) = ^GLKVector3(int i, int j) {
			float th = M_PI * i / rings, ph = 2 * M_PI * j / seg;
			return GLKVector3Make(r * sinf(th) * cosf(ph), r * sinf(th) * sinf(ph), -r * cosf(th));
		};
		for (int i = lo; i < rings; i++)
			for (int j = 0; j < seg; j++) {
				GLKVector3 a = P(i, j), c = P(i + 1, j + 1), d = P(i + 1, j), bb = P(i, j + 1);
				if (i + 1 == rings) pdt_add(&b, a, bb, c); else pdt_quad(&b, a, bb, c, d);
			}
		GLKVector3 centre = GLKVector3Make(0, 0, P(lo, 0).z);
		for (int j = 0; j < seg; j++) pdt_add(&b, centre, P(lo, j + 1), P(lo, j));
	} else if ([name isEqualToString:@"Support test"]) {   // a "T": 10 mm post, 50 mm arms overhanging both ways
		pdt_box(&b, 20, 0, 0, 30, 10, 20);
		pdt_box(&b, 0, 0, 20, 50, 10, 25);
	} else return nil;
	return [self withTriangles:b.t count:b.n name:name source:[@"builtin:" stringByAppendingString:name]];
}

#pragma mark Transform

- (GLKMatrix3)matrix {
	GLKMatrix3 rx = GLKMatrix3MakeXRotation((float)M_PI_2 * self.quarterX);
	GLKMatrix3 ry = GLKMatrix3MakeYRotation((float)M_PI_2 * self.quarterY);
	GLKMatrix3 rz = GLKMatrix3MakeZRotation(GLKMathDegreesToRadians(self.rotZ));
	GLKMatrix3 r = GLKMatrix3Multiply(rz, GLKMatrix3Multiply(ry, rx));
	return GLKMatrix3Multiply(GLKMatrix3MakeScale(self.scale, self.scale, self.scale), r);
}

- (void)computeBounds {
	if (_boundsValid) return;
	GLKMatrix3 m = [self matrix];
	GLKVector3 lo = GLKVector3Make(1e30f, 1e30f, 1e30f), hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	for (NSUInteger i = 0; i < _ntri * 3; i++) {
		GLKVector3 p = GLKMatrix3MultiplyVector3(m, GLKVector3Make(_tris[i * 3], _tris[i * 3 + 1], _tris[i * 3 + 2]));
		lo = GLKVector3Minimum(lo, p); hi = GLKVector3Maximum(hi, p);
	}
	if (!_ntri) lo = hi = GLKVector3Make(0, 0, 0);
	_bmin = lo; _bmax = hi; _boundsValid = YES;
}
- (GLKVector3)size { [self computeBounds]; return GLKVector3Subtract(_bmax, _bmin); }
- (GLKVector3)minCorner { [self computeBounds]; return _bmin; }

- (BOOL)writeSTL:(NSString *)file {
	[self computeBounds];
	GLKMatrix3 m = [self matrix];
	GLKVector3 off = GLKVector3Make(-(_bmin.x + _bmax.x) / 2, -(_bmin.y + _bmax.y) / 2, -_bmin.z);
	FILE *f = fopen([file fileSystemRepresentation], "wb");
	if (!f) return NO;
	char header[80] = {0};
	strncpy(header, "PrintDeck", sizeof header);
	uint32_t n = (uint32_t)_ntri;
	fwrite(header, 1, 80, f);
	fwrite(&n, 4, 1, f);
	float det = m.m00 * (m.m11 * m.m22 - m.m21 * m.m12) - m.m10 * (m.m01 * m.m22 - m.m21 * m.m02) + m.m20 * (m.m01 * m.m12 - m.m11 * m.m02);
	BOOL mirrored = det < 0;   // never with rotations + a positive scale, but stay correct
	uint8_t rec[50];
	for (NSUInteger i = 0; i < _ntri; i++) {
		GLKVector3 v[3];
		for (int k = 0; k < 3; k++) {
			const float *s = _tris + i * 9 + k * 3;
			v[k] = GLKVector3Add(GLKMatrix3MultiplyVector3(m, GLKVector3Make(s[0], s[1], s[2])), off);
		}
		if (mirrored) { GLKVector3 t = v[1]; v[1] = v[2]; v[2] = t; }
		GLKVector3 nrm = GLKVector3CrossProduct(GLKVector3Subtract(v[1], v[0]), GLKVector3Subtract(v[2], v[0]));
		float l = GLKVector3Length(nrm);
		if (l > 0) nrm = GLKVector3DivideScalar(nrm, l);
		float out[12] = {nrm.x, nrm.y, nrm.z, v[0].x, v[0].y, v[0].z, v[1].x, v[1].y, v[1].z, v[2].x, v[2].y, v[2].z};
		memcpy(rec, out, 48); rec[48] = rec[49] = 0;
		fwrite(rec, 1, 50, f);
	}
	return fclose(f) == 0;
}

- (NSString *)signature {
	return [NSString stringWithFormat:@"%@|%lu|%d|%d|%.2f|%.4f", self.source, (unsigned long)_ntri, self.quarterX, self.quarterY, self.rotZ, self.scale];
}

@end

#pragma mark - Slicer

@interface PDSlicer () <NSURLConnectionDataDelegate>
@property (nonatomic, readwrite) PDSliceState state;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, readwrite, copy) NSString *phase, *error;
@property (nonatomic, readwrite, copy) NSString *resultFile, *resultName, *resultSignature;
@property (nonatomic, readwrite) int resultLayers;
@property (nonatomic, readwrite) double resultSeconds, resultFilamentMM, resultGrams, resultSliceTime;
@property (nonatomic, readwrite, strong) PDToolpath *resultToolpath;
@property (nonatomic, readwrite) PDUploadState uploadState;
@property (nonatomic, readwrite) double uploadProgress;
@property (nonatomic, readwrite, copy) NSString *uploadError, *uploadedName;
@property (nonatomic, assign) dispatch_queue_t queue;   // not an object under a 5.0 deployment target
@property (nonatomic) pid_t pid;
@property (nonatomic) int generation;
// upload
@property (nonatomic, strong) NSURLConnection *conn;
@property (nonatomic, strong) NSMutableData *reply;
@property (nonatomic, copy) NSString *upMD5, *upUUID, *upFile, *upName, *upHost;
@property (nonatomic) int upPort;
@property (nonatomic) long long upOffset, upTotal, upChunk;
@property (nonatomic) BOOL upPrint, upCosmos;
@end

@implementation PDSlicer

+ (PDSlicer *)shared {
	static PDSlicer *s;
	if (!s) { s = [[PDSlicer alloc] init]; s.queue = dispatch_queue_create("printdeck.slicer", NULL); }
	return s;
}

// PrintDeck lives in /Applications (no sandbox), so its Documents is the shared /var/mobile/Documents: keep the
// models in a folder of their own there.
+ (NSString *)libraryDirectory {
	NSString *d = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"PrintDeck"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}
+ (NSString *)workDirectory {
	NSString *d = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"slicer"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}
+ (NSString *)engineVersion { return @"CuraEngine 15.04.6"; }

- (void)post { [[NSNotificationCenter defaultCenter] postNotificationName:PDSlicerNotification object:self]; }

- (NSString *)currentSignature {
	NSDictionary *s = [PDSliceSettings current];
	NSMutableArray *parts = [NSMutableArray array];
	for (NSString *k in [[s allKeys] sortedArrayUsingSelector:@selector(compare:)]) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, [s objectForKey:k]]];
	return [NSString stringWithFormat:@"%@#%@", [self.model signature] ?: @"", [parts componentsJoinedByString:@","]];
}

#pragma mark Config

static int PDum(double mm) { return (int)lround(mm * 1000.0); }

// The CuraEngine config (microns, mm/s) for the current settings, with the Centauri's start/end G-code.
- (NSString *)configText {
	NSDictionary *s = [PDSliceSettings current];
	double (^V)(NSString *) = ^double(NSString *k) { return [[s objectForKey:k] doubleValue]; };
	NSString *material = [s objectForKey:@"material"];
	int nozzle = (int)V(@"nozzleTemp"), bed = (int)V(@"bedTemp");
	double lw = V(@"lineWidth");
	BOOL vase = V(@"vase") > 0;
	NSMutableString *c = [NSMutableString string];
	void (^set)(NSString *, long) = ^(NSString *k, long v) { [c appendFormat:@"%@ = %ld\n", k, v]; };

	double nz = V(@"nozzle") > 0 ? V(@"nozzle") : 0.6, k = nz / 0.6;   // k scales the raft from the 0.6 mm values
	set(@"nozzleSize", PDum(nz));
	set(@"filamentDiameter", PDum(V(@"filamentDiameter")));
	set(@"filamentFlow", lround(V(@"flow")));
	set(@"layerThickness", PDum(V(@"layerHeight")));
	set(@"initialLayerThickness", PDum(V(@"firstLayerHeight")));
	set(@"extrusionWidth", PDum(lw));
	set(@"layer0extrusionWidth", PDum(lw * V(@"firstLayerWidth") / 100.0));
	set(@"insetCount", vase ? 1 : lround(V(@"walls")));
	int infill = (int)lround(V(@"infill"));
	long down = lround(V(@"bottomLayers")), up = lround(V(@"topLayers")), sparse;
	if (infill <= 0) sparse = -1;
	else if (infill >= 100) { sparse = -1; down = up = 10000; }   // solid: everything is skin
	else sparse = lround(100.0 * PDum(lw) / infill);
	if (vase) { sparse = -1; up = 0; }
	set(@"downSkinCount", down);
	set(@"upSkinCount", up);
	set(@"sparseInfillLineDistance", sparse);
	set(@"infillOverlap", lround(V(@"infillOverlap")));
	set(@"perimeterBeforeInfill", V(@"wallsFirst") > 0 ? 1 : 0);
	set(@"infillPattern", lround(V(@"infillPattern")));
	set(@"spiralizeMode", vase ? 1 : 0);

	int adhesion = (int)V(@"adhesion");
	set(@"skirtDistance", adhesion == 2 ? 0 : PDum(V(@"skirtDistance")));
	set(@"skirtLineCount", adhesion == 0 ? 0 : adhesion == 2 ? lround(V(@"brimLines")) : adhesion == 3 ? 1 : lround(V(@"skirtLines")));
	set(@"skirtMinLength", adhesion == 1 ? PDum(V(@"skirtMinLength")) : 0);
	if (adhesion == 3) {   // raft: Cura 15.04's defaults, sized for the 0.6 mm nozzle and scaled by k for others
		set(@"raftMargin", PDum(V(@"raftMargin"))); set(@"raftLineSpacing", lround(3000 * k));
		set(@"raftBaseThickness", lround(360 * k)); set(@"raftBaseLinewidth", lround(1200 * k)); set(@"raftBaseSpeed", 20);
		set(@"raftInterfaceThickness", lround(270 * k)); set(@"raftInterfaceLinewidth", lround(600 * k)); set(@"raftInterfaceLineSpacing", lround(1200 * k));
		set(@"raftAirGap", 0); set(@"raftAirGapLayer0", PDum(V(@"raftGap")));
		set(@"raftSurfaceLayers", lround(V(@"raftLayers"))); set(@"raftSurfaceThickness", PDum(V(@"layerHeight"))); set(@"raftSurfaceLinewidth", PDum(lw));
		set(@"raftSurfaceLineSpacing", PDum(lw)); set(@"raftSurfaceSpeed", 30); set(@"raftFanSpeed", 0);
	}

	int support = (int)V(@"support");
	set(@"supportAngle", support ? lround(V(@"supportAngle")) : -1);
	set(@"supportEverywhere", support == 2 ? 1 : 0);
	set(@"supportType", lround(V(@"supportPattern")));
	set(@"supportLineDistance", lround(100.0 * PDum(lw) / MAX(1.0, V(@"supportDensity"))));
	set(@"supportXYDistance", PDum(V(@"supportXY")));
	set(@"supportZDistance", PDum(V(@"supportGap")));

	set(@"printSpeed", lround(V(@"printSpeed")));
	set(@"inset0Speed", lround(V(@"outerWallSpeed")));
	set(@"insetXSpeed", lround(V(@"innerWallSpeed")));
	set(@"infillSpeed", lround(V(@"infillSpeed")));
	set(@"skinSpeed", lround(V(@"skinSpeed")));
	set(@"initialLayerSpeed", lround(V(@"firstLayerSpeed")));
	set(@"initialSpeedupLayers", lround(V(@"slowLayers")));
	set(@"moveSpeed", lround(V(@"travelSpeed")));

	set(@"fanSpeedMin", lround(V(@"fan")));
	set(@"fanSpeedMax", lround(MAX(V(@"fan"), V(@"fanMax"))));
	set(@"fanFullOnLayerNr", lround(V(@"fanFullLayer")));
	set(@"minimalLayerTime", lround(V(@"minLayerTime")));
	set(@"minimalFeedrate", lround(V(@"minSpeed")));
	set(@"coolHeadLift", V(@"liftHead") > 0 ? 1 : 0);

	BOOL retract = V(@"retract") > 0;
	set(@"retractionAmount", retract ? PDum(V(@"retractDistance")) : 0);
	set(@"retractionSpeed", lround(V(@"retractSpeed")));
	set(@"retractionMinimalDistance", PDum(V(@"retractMinTravel")));
	set(@"minimalExtrusionBeforeRetraction", PDum(V(@"retractMinExtrude")));
	set(@"retractionAmountPrime", retract ? PDum(V(@"retractPrime")) : 0);
	set(@"retractionZHop", retract ? PDum(V(@"zHop")) : 0);

	set(@"enableCombing", lround(V(@"combing")));
	set(@"fixHorrible", lround(V(@"repair")) | ([self.model.source hasSuffix:@" (design).stl"] ? 1 : 0));
	set(@"posx", 128000);
	set(@"posy", 128000);
	set(@"autoCenter", 1);
	set(@"objectSink", PDum(V(@"sink")));
	set(@"acceleration", lround(V(@"acceleration") * 1000));   // time estimate only; the start G-code sends M204
	set(@"gcodeFlavor", 0);

	// Start: ElegooSlicer's CC_START_GCODE for the Centauri Carbon (heat, home, nozzle wipe, prime line), ending in
	// M82 because CuraEngine writes absolute E values. Tagged ;TYPE:Custom so viewers don't count it as the part.
	NSMutableString *start = [NSMutableString string];
	[start appendFormat:@";TYPE:Custom\n;===== PrintDeck start (Centauri Carbon) =====\n;printer_model:Elegoo Centauri Carbon\n;initial_filament:%@\n", material];
	[start appendString:@"M400\nM220 S100\nM221 S100\nM104 S140\n"];
	// COSMOS (Klipper) e-stops on Elegoo's M729/M8213/M8212 and doesn't know M6211, and its M106 has no P (fan
	// index): there, fans go by name (SET_FAN_SPEED) and the light by SET_LED, as in COSMOS's own CC1 profile.
	PDPrinter *pr = [PDPrinter shared];
	BOOL cosmos = pr.cosmos;
	NSString *(^fanCmd)(int, double, NSString *) = ^NSString *(int idx, double pct, NSString *note) {
		NSString *name = idx == 3 ? pr.chamberFanName : pr.auxFanName;
		if (!cosmos) return [NSString stringWithFormat:@"M106 P%d S%ld ;%@\n", idx, lround(pct * 2.55), note];
		return name ? [NSString stringWithFormat:@"SET_FAN_SPEED FAN=%@ SPEED=%.2f ;%@\n", name, pct / 100.0, note] : @"";
	};
	[start appendFormat:@"M140 S%d\nG90\nM83\nG28 ;home\n%@", bed, cosmos ? @"" : @"M729 ;clean nozzle\n"];
	if (cosmos && pr.caseLedName) [start appendFormat:@"SET_LED LED=%@ WHITE=1\n", pr.caseLedName];
	if (bed > 0) [start appendFormat:@"M190 S%d\n", bed];
	if (cosmos) [start appendFormat:@"M109 S%d\n", nozzle];
	else [start appendFormat:@"M109 S%d\nM6211 A1 L200 T0 Q%d R%d S%d\nT0\n", nozzle, nozzle, nozzle, nozzle];
	double chamber = V(@"chamberFanPct");
	if (chamber < 0 && [material isEqualToString:@"PLA"]) [start appendString:bed > 50 ? fanCmd(3, 100, @"chamber fan, keeps PLA from jamming") : bed > 45 ? fanCmd(3, 180 / 2.55, @"chamber fan") : @""];
	else if (chamber > 0) [start appendString:fanCmd(3, chamber, @"chamber fan")];
	if (V(@"auxFan") > 0) [start appendString:fanCmd(2, V(@"auxFan"), @"aux fan")];
	[start appendFormat:@"M204 S%ld\n", lround(V(@"acceleration"))];
	// (Klipper only knows G2/G3 with [gcode_arcs], so COSMOS gets a plain lift instead of the arc.)
	[start appendFormat:@"G1 X128 Y-1.2 F20000\nG1 Z0.3 F900\nG90\nM83\nG92 E0\nG1 F4800\n"
		"G1 X0 E10.156 ;prime line\nG1 Y98.8 E7.934\nG1 X0.9 Y100 E0.1\nG1 Y-0.3 E7.934\nG1 X78 E6.284\n"
		"%@\nG1 F20000\nG92 E0\nG21\nM82 ;CuraEngine writes absolute E\nG92 E0", cosmos ? @"G1 Z0.6 F1200" : @"G3 I-1 J0 Z0.6 F1200.0"];
	NSString *end = [NSString stringWithFormat:@";TYPE:Custom\n;===== PrintDeck end (Centauri Carbon) =====\nM400\nM140 S0\nM106 S255\nM83\nG92 E0\nG1 E-0.8 F1800\n"
		"G91\nG1 Z0.5 F3000\nG90\nG1 Z100 F20000\nM204 S5000\n%@M400\nG1 X202 F20000\nM400\nG1 Y250 F20000\nG1 Y264.5 F1200\nM400\n"
		"G92 E0\nM104 S0\nM140 S0\nM106 S0\n%@%@M84", cosmos ? @"" : @"M749\n", fanCmd(2, 0, @"aux fan off"), fanCmd(3, 0, @"chamber fan off")];
	[c appendFormat:@"startCode = \"\"\"\n%@\n\"\"\"\nendCode = \"\"\"\n%@\n\"\"\"\n", start, end];
	return c;
}

#pragma mark Slicing

static NSString *PDTimeTag(double secs) {   // Elegoo-style: 2h18m / 48m39s
	long s = lround(secs);
	if (s >= 3600) return [NSString stringWithFormat:@"%ldh%ldm", s / 3600, (s % 3600) / 60];
	return [NSString stringWithFormat:@"%ldm%lds", s / 60, s % 60];
}

static NSString *PDSafeName(NSString *n) {
	NSMutableString *o = [NSMutableString string];
	for (NSUInteger i = 0; i < [n length] && [o length] < 60; i++) {
		unichar ch = [n characterAtIndex:i];
		[o appendString:(ch == '/' || ch == '\\' || ch == ':' || ch == '"' || ch == '%' || ch < 32) ? @"-" : [NSString stringWithCharacters:&ch length:1]];
	}
	NSString *t = [o stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	return [t length] ? t : @"Model";
}

- (void)slice {
	if (self.state == PDSliceRunning || !self.model) return;
	NSString *engine = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"CuraEngine"];
	if (![[NSFileManager defaultManager] isExecutableFileAtPath:engine]) { self.state = PDSliceFailed; self.error = @"The slicing engine is missing from the app."; [self post]; return; }
	GLKVector3 sz = [self.model size];
	if (sz.x > PD_BED_MM || sz.y > PD_BED_MM || sz.z > PD_BED_MM) { self.state = PDSliceFailed; self.error = @"The model doesn't fit on the bed."; [self post]; return; }

	NSString *dir = [PDSlicer workDirectory];
	NSString *stl = [dir stringByAppendingPathComponent:@"input.stl"], *cfg = [dir stringByAppendingPathComponent:@"job.cfg"];
	NSString *raw = [dir stringByAppendingPathComponent:@"raw.gcode"];
	NSString *config = [self configText];
	NSString *signature = [self currentSignature];
	NSDictionary *settings = [PDSliceSettings current];
	PDModel *model = self.model;
	int gen = ++self.generation;
	self.state = PDSliceRunning;
	self.progress = 0; self.phase = @"Preparing"; self.error = nil;
	self.uploadState = PDUploadIdle; self.uploadError = nil; self.uploadedName = nil;
	[self post];

	dispatch_async(self.queue, ^{
		CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
		NSString *err = nil;
		double printSecs = 0, filamentMM = 0;
		if (![model writeSTL:stl] || ![config writeToFile:cfg atomically:YES encoding:NSUTF8StringEncoding error:NULL]) err = @"Couldn't write the slicer's input files.";
		[[NSFileManager defaultManager] removeItemAtPath:raw error:NULL];
		if (!err) err = [self runEngine:engine cfg:cfg stl:stl out:raw gen:gen printSecs:&printSecs filament:&filamentMM];
		if (gen != self.generation) return;   // cancelled meanwhile
		NSString *final = nil, *name = nil;
		int layers = 0;
		double grams = 0;
		PDToolpath *tp = nil;
		if (!err) {
			dispatch_async(dispatch_get_main_queue(), ^{ if (gen == self.generation) { self.phase = @"Finishing"; self.progress = 0.99; [self post]; } });
			NSString *material = [settings objectForKey:@"material"];
			double density = [[settings objectForKey:@"filamentDensity"] doubleValue];
			if (density <= 0) density = [material isEqualToString:@"PETG"] ? 1.27 : [material isEqualToString:@"ABS"] ? 1.04 : [material isEqualToString:@"ASA"] ? 1.07
				: [material isEqualToString:@"PC"] ? 1.20 : [material isEqualToString:@"PA"] ? 1.14 : [material isEqualToString:@"TPU"] ? 1.21 : 1.24;
			double r = [[settings objectForKey:@"filamentDiameter"] doubleValue] / 2;
			grams = filamentMM * M_PI * r * r / 1000.0 * density;
			name = [NSString stringWithFormat:@"ECC_%g_%@_%@_%.2f_%@.gcode", [[settings objectForKey:@"nozzle"] doubleValue], PDSafeName(model.name), material,
				[[settings objectForKey:@"layerHeight"] doubleValue], PDTimeTag(printSecs)];
			final = [dir stringByAppendingPathComponent:@"result.gcode"];
			err = [self wrap:raw into:final settings:settings seconds:printSecs filament:filamentMM grams:grams layers:&layers];
			if (!err) tp = [PDToolpath toolpathFromFile:final path:[@"/local/" stringByAppendingString:name] allTypes:YES];
		}
		[[NSFileManager defaultManager] removeItemAtPath:raw error:NULL];
		double took = CFAbsoluteTimeGetCurrent() - t0;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (gen != self.generation) return;
			self.pid = 0;
			if (err) { self.state = PDSliceFailed; self.error = err; self.phase = nil; [self post]; return; }
			self.resultFile = final; self.resultName = name; self.resultSignature = signature;
			self.resultLayers = layers; self.resultSeconds = printSecs; self.resultFilamentMM = filamentMM; self.resultGrams = grams;
			self.resultSliceTime = took; self.resultToolpath = tp;
			self.state = PDSliceDone; self.progress = 1; self.phase = nil;
			[self post];
		});
	});
}

// Runs CuraEngine and follows its progress lines ("Progress:inset:12:166") on stderr.
- (NSString *)runEngine:(NSString *)engine cfg:(NSString *)cfg stl:(NSString *)stl out:(NSString *)outFile gen:(int)gen
	printSecs:(double *)printSecs filament:(double *)filament {
	int fds[2];
	if (pipe(fds) != 0) return @"Couldn't start the slicing engine.";
	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
	posix_spawn_file_actions_addclose(&fa, fds[0]);
	const char *argv[] = {"CuraEngine", "-v", "-p", "-c", [cfg fileSystemRepresentation], "-o", [outFile fileSystemRepresentation], [stl fileSystemRepresentation], NULL};
	pid_t pid = 0;
	int rc = posix_spawn(&pid, [engine fileSystemRepresentation], &fa, NULL, (char *const *)argv, NULL);
	posix_spawn_file_actions_destroy(&fa);
	close(fds[1]);
	if (rc != 0) { close(fds[0]); return [NSString stringWithFormat:@"Couldn't start the slicing engine (%d).", rc]; }
	dispatch_sync(dispatch_get_main_queue(), ^{ if (gen == self.generation) self.pid = pid; });

	// Progress phases and the share of the total time they take (measured on the iPad 1).
	static const char *names[] = {"optimized", "process", "inset", "skin", "export"};
	static const double from[] = {0.00, 0.03, 0.08, 0.30, 0.65}, to[] = {0.03, 0.08, 0.30, 0.65, 0.98};
	NSArray *titles = [NSArray arrayWithObjects:@"Loading", @"Slicing", @"Walls", @"Skins & infill", @"Writing G-code", nil];
	FILE *f = fdopen(fds[0], "r");
	char line[512];
	NSMutableString *tail = [NSMutableString string];
	double lastPosted = -1;
	while (f && fgets(line, sizeof line, f)) {
		int v = 0, n = 0;
		char type[32];
		if (sscanf(line, "Progress:%31[^:]:%d:%d", type, &v, &n) == 3 && n > 0) {
			for (int i = 0; i < 5; i++) if (PDEqual(type, names[i])) {
				double p = from[i] + (to[i] - from[i]) * v / n;
				if (p - lastPosted >= 0.005 || v == n) {
					lastPosted = p;
					NSString *ph = i >= 2 ? [NSString stringWithFormat:@"%@ %d/%d", [titles objectAtIndex:i], v, n] : [titles objectAtIndex:i];
					dispatch_async(dispatch_get_main_queue(), ^{ if (gen == self.generation) { self.progress = p; self.phase = ph; [self post]; } });
				}
			}
			continue;
		}
		int iv;
		if (sscanf(line, "Print time: %d", &iv) == 1) *printSecs = iv;
		else if (sscanf(line, "Filament: %d", &iv) == 1) *filament = iv;
		else if (!PDHasPrefix(line, "Arg:")) { [tail appendString:[NSString stringWithUTF8String:line] ?: @""]; if ([tail length] > 2000) [tail deleteCharactersInRange:NSMakeRange(0, [tail length] - 2000)]; }
	}
	if (f) fclose(f); else close(fds[0]);
	int status = 0;
	waitpid(pid, &status, 0);
	if (gen != self.generation) return @"Cancelled.";
	if (WIFSIGNALED(status)) return [NSString stringWithFormat:@"The slicing engine crashed (signal %d).", WTERMSIG(status)];
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		NSString *last = [[[tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"] lastObject];
		return [NSString stringWithFormat:@"Slicing failed%@", [last length] ? [@": " stringByAppendingString:last] : @"."];
	}
	if (![[NSFileManager defaultManager] fileExistsAtPath:outFile]) return @"The slicer produced no G-code.";
	return nil;
}

// ElegooSlicer-style metadata around CuraEngine's G-code. The Centauri's firmware only reads layers / time /
// weight (Cmd 258/260) when the "; generated by" line mentions ElegooSlicer, hence the "compatible" wording.
- (NSString *)wrap:(NSString *)raw into:(NSString *)final settings:(NSDictionary *)s seconds:(double)secs
	filament:(double)mm grams:(double)g layers:(int *)layersOut {
	FILE *in = fopen([raw fileSystemRepresentation], "rb");
	if (!in) return @"The slicer's output is missing.";
	int layers = 0;
	double maxZ = 0;
	char line[1024];
	while (fgets(line, sizeof line, in)) {
		if (PDHasPrefix(line, ";LAYER_CHANGE")) layers++;
		else if (line[0] == ';' && line[1] == 'Z' && line[2] == ':') maxZ = MAX(maxZ, atof(line + 3));
	}
	if (layers == 0) { fclose(in); return @"Nothing to print: the model produced no layers."; }
	rewind(in);
	FILE *out = fopen([final fileSystemRepresentation], "wb");
	if (!out) { fclose(in); return @"Couldn't write the G-code."; }
	NSString *material = [s objectForKey:@"material"];
	double fr = [[s objectForKey:@"filamentDiameter"] doubleValue] / 2;
	if (fr <= 0) fr = 0.875;
	NSString *hms = secs >= 3600 ? [NSString stringWithFormat:@"%ldh %ldm %lds", lround(secs) / 3600, (lround(secs) % 3600) / 60, lround(secs) % 60]
		: [NSString stringWithFormat:@"%ldm %lds", lround(secs) / 60, lround(secs) % 60];
	NSString *head = [NSString stringWithFormat:@"; HEADER_BLOCK_START\n; generated by PrintDeck %@ (ElegooSlicer compatible)\n"
		"; total layer number: %d\n; filament_density: %.2f\n; filament_diameter: %g\n; max_z_height: %.2f\n; HEADER_BLOCK_END\n\n; EXECUTABLE_BLOCK_START\n",
		[PDSlicer engineVersion], layers, g > 0 && mm > 0 ? g / (mm * M_PI * fr * fr / 1000.0) : 1.24, 2 * fr, maxZ];
	fputs([head UTF8String], out);
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
	fclose(in);
	NSString *foot = [NSString stringWithFormat:@"\n; EXECUTABLE_BLOCK_END\n\n; filament used [mm] = %.2f\n; filament used [cm3] = %.2f\n"
		"; filament used [g] = %.2f\n; total filament used [g] = %.2f\n; total layers count = %d\n; estimated printing time (normal mode) = %@\n\n"
		"; CONFIG_BLOCK_START\n; layer_height = %.2f\n; nozzle_diameter = %g\n; filament_diameter = %g\n; printer_model = Elegoo Centauri Carbon\n; filament_type = %@\n"
		"; filament_colour = %@\n; filament_settings_id = \"%@\"\n; print_settings_id = \"%@\"\n"
		"; sparse_infill_density = %.0f%%\n; wall_loops = %.0f\n; nozzle_temperature = %.0f\n; hot_plate_temp = %.0f\n; CONFIG_BLOCK_END\n",
		mm, mm * M_PI * fr * fr / 1000.0, g, g, layers, hms,
		[[s objectForKey:@"layerHeight"] doubleValue], [[s objectForKey:@"nozzle"] doubleValue], 2 * fr, material,
		[s objectForKey:@"filamentColor"] ?: @"#3C8CE6", [[s objectForKey:@"filamentName"] length] ? [s objectForKey:@"filamentName"] : material,
		[PDSliceProfiles selectedTitleForEditor:@"process"] ?: @"PrintDeck", [[s objectForKey:@"infill"] doubleValue], [[s objectForKey:@"walls"] doubleValue],
		[[s objectForKey:@"nozzleTemp"] doubleValue], [[s objectForKey:@"bedTemp"] doubleValue]];
	fputs([foot UTF8String], out);
	if (fclose(out) != 0) return @"Couldn't write the G-code (disk full?).";
	*layersOut = layers;
	return nil;
}

- (void)cancel {
	if (self.state != PDSliceRunning) return;
	self.generation++;
	if (self.pid > 0) kill(self.pid, SIGKILL);
	self.pid = 0;
	self.state = self.resultFile ? PDSliceDone : PDSliceIdle;
	self.phase = nil; self.progress = 0;
	[self post];
}

#pragma mark Upload

static NSString *PDFileMD5(NSString *file) {
	FILE *f = fopen([file fileSystemRepresentation], "rb");
	if (!f) return nil;
	CC_MD5_CTX ctx;
	CC_MD5_Init(&ctx);
	uint8_t buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) CC_MD5_Update(&ctx, buf, (CC_LONG)n);
	fclose(f);
	unsigned char d[CC_MD5_DIGEST_LENGTH];
	CC_MD5_Final(d, &ctx);
	NSMutableString *s = [NSMutableString string];
	for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
	return s;
}

#define PD_UPLOAD_CHUNK (1024 * 1024)

// ElegooSlicer's upload: POST http://<printer>:3030/uploadFile/upload, multipart (Check, S-File-MD5, Offset,
// Uuid, TotalSize, File), in chunks of at most 1 MiB; each answers {"code":"000000"} on success.
- (void)uploadAndPrint:(BOOL)print {
	PDPrinter *p = [PDPrinter shared];
	if (self.uploadState == PDUploadRunning || self.state != PDSliceDone || !self.resultFile) return;
	if (!p.connected) { self.uploadState = PDUploadFailed; self.uploadError = @"Not connected to the printer."; [self post]; return; }
	NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:self.resultFile error:NULL];
	self.upTotal = [[attr objectForKey:NSFileSize] longLongValue];
	self.upMD5 = PDFileMD5(self.resultFile);
	if (!self.upTotal || !self.upMD5) { self.uploadState = PDUploadFailed; self.uploadError = @"The sliced file is missing."; [self post]; return; }
	CFUUIDRef u = CFUUIDCreate(NULL);
	self.upUUID = [(__bridge_transfer NSString *)CFUUIDCreateString(NULL, u) lowercaseString];
	CFRelease(u);
	self.upFile = self.resultFile; self.upName = self.resultName;
	self.upHost = p.host; self.upPort = p.cosmos ? p.moonrakerPort : (p.port ?: 3030);
	self.upCosmos = p.cosmos;
	self.upOffset = 0; self.upPrint = print;
	self.uploadState = PDUploadRunning; self.uploadProgress = 0; self.uploadError = nil; self.uploadedName = nil;
	[self post];
	[self sendChunk];
}

// COSMOS: Moonraker takes the whole file in one multipart POST /server/files/upload (root=gcodes) and answers
// {"item": {"path": …}, "action": "create_file"}.
- (void)sendCosmosUpload {
	NSData *file = [NSData dataWithContentsOfFile:self.upFile options:NSDataReadingMappedIfSafe error:NULL];
	if (![file length]) { [self uploadFailed:@"Couldn't read the sliced file."]; return; }
	self.upChunk = (long long)[file length];
	NSString *boundary = [NSString stringWithFormat:@"----printdeck%08x%08x", arc4random(), arc4random()];
	NSMutableData *body = [NSMutableData data];
	[body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\ngcodes\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, self.upName] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:file];
	[body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
	NSURL *url = [[PDPrinter shared] moonrakerURL:@"/server/files/upload"];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300];
	[req setHTTPMethod:@"POST"];
	[req setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
	[req setHTTPBody:body];
	self.reply = [NSMutableData data];
	self.conn = [NSURLConnection connectionWithRequest:req delegate:self];
}

- (void)sendChunk {
	if (self.upCosmos) { [self sendCosmosUpload]; return; }
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:self.upFile];
	[fh seekToFileOffset:(unsigned long long)self.upOffset];
	NSData *chunk = [fh readDataOfLength:PD_UPLOAD_CHUNK];
	[fh closeFile];
	self.upChunk = (long long)[chunk length];
	if (!self.upChunk) { [self uploadFailed:@"Couldn't read the sliced file."]; return; }
	NSString *boundary = [NSString stringWithFormat:@"----printdeck%08x%08x", arc4random(), arc4random()];
	NSMutableData *body = [NSMutableData data];
	NSArray *fields = [NSArray arrayWithObjects:@"Check", @"1", @"S-File-MD5", self.upMD5, @"Offset", [NSString stringWithFormat:@"%lld", self.upOffset],
		@"Uuid", self.upUUID, @"TotalSize", [NSString stringWithFormat:@"%lld", self.upTotal], nil];
	for (NSUInteger i = 0; i + 1 < [fields count]; i += 2)
		[body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, [fields objectAtIndex:i], [fields objectAtIndex:i + 1]] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"File\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n", boundary, self.upName] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:chunk];
	[body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/uploadFile/upload", self.upHost, self.upPort]];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
	[req setHTTPMethod:@"POST"];
	[req setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
	[req setHTTPBody:body];
	self.reply = [NSMutableData data];
	self.conn = [NSURLConnection connectionWithRequest:req delegate:self];
}

- (void)connection:(NSURLConnection *)c didSendBodyData:(NSInteger)sent totalBytesWritten:(NSInteger)written totalBytesExpectedToWrite:(NSInteger)expected {
	if (c != self.conn || expected <= 0) return;
	double part = (double)written / expected * self.upChunk;
	self.uploadProgress = MIN(0.99, (self.upOffset + part) / self.upTotal);
	[self post];
}
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)d { if (c == self.conn) [self.reply appendData:d]; }
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)e { if (c == self.conn) [self uploadFailed:[NSString stringWithFormat:@"Upload failed: %@", [e localizedDescription]]]; }

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
	if (c != self.conn) return;
	self.conn = nil;
	id j = [NSJSONSerialization JSONObjectWithData:self.reply options:0 error:NULL];
	NSString *code = PDStr(j, @"code");
	if (self.upCosmos) {   // Moonraker: {"item": {"path": "<name>"}, …} or {"error": {"message": …}}
		NSString *saved = PDStr(PDDict(j, @"item"), @"path") ?: PDStr(PDDict(PDDict(j, @"result"), @"item"), @"path");
		if (![saved length]) {
			NSString *msg = PDStr(PDDict(j, @"error"), @"message");
			[self uploadFailed:[NSString stringWithFormat:@"The printer refused the upload (%@).", msg ?: @"no answer"]];
			return;
		}
		self.upName = saved;
		code = @"000000";
	}
	if (![code isEqualToString:@"000000"]) {
		NSString *body = [[NSString alloc] initWithData:self.reply encoding:NSUTF8StringEncoding];
		[self uploadFailed:[NSString stringWithFormat:@"The printer refused the upload (%@).", code ?: ([body length] ? [body substringToIndex:MIN((NSUInteger)80, [body length])] : @"no answer")]];
		return;
	}
	self.upOffset += self.upChunk;
	if (self.upOffset < self.upTotal) { [self sendChunk]; return; }
	self.uploadState = PDUploadDone;
	self.uploadProgress = 1;
	self.uploadedName = self.upName;
	NSString *path = [@"/local/" stringByAppendingString:self.upName];
	PDPrinter *p = [PDPrinter shared];
	[p refreshFiles];
	[PDFilesCard setSelectedPath:path];
	if (self.upPrint) {
		// Give the printer a moment to index the new file before starting it.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (!p.isBusy) [p startFile:path];
		});
	}
	[self post];
}

- (void)uploadFailed:(NSString *)why {
	[self.conn cancel];
	self.conn = nil;
	self.uploadState = PDUploadFailed;
	self.uploadError = why;
	[self post];
}

@end
