#import "PDFilaments.h"
#import "PDSlicer.h"
#include <math.h>

NSString *const PDFilamentSlotsChangedNotification = @"PDFilamentSlotsChanged";

static NSString *const PDSlotsKey = @"PDFilamentSlots";
static NSString *const PDActiveSlotKey = @"PDFilamentActiveSlot";
static NSString *const PDFlushKey = @"PDFlushMatrix";
static NSString *const PDFlushMulKey = @"PDFlushMultiplier";
static NSString *const PDFlushAutoKey = @"PDFlushAuto";

#pragma mark Flush rule

// resources/flush/flush_data_standard.txt from ElegooSlicer 1.5.3.5 (GenericFlushPredictor): measured volumes
// for pairs of standard colours, used as they are when both colours match exactly.
static const struct { unsigned from, to; int flush; } PDFlushData[] = {
	{0x000000,0x545454,236}, {0x000000,0xF4EE2A,386}, {0x000000,0x5E43B7,266}, {0x000000,0x0A2989,236}, {0xC12E1F,0x000000,26},
	{0xC12E1F,0x00AE42,326}, {0xC12E1F,0xF4EE2A,356}, {0xC12E1F,0xFF6A13,146}, {0x00AE42,0x000000,26}, {0x00AE42,0xC12E1F,146},
	{0x00AE42,0x545454,56}, {0x00AE42,0xD1D3D5,266}, {0x00AE42,0xF4EE2A,176}, {0x00AE42,0x9D432C,86}, {0x00AE42,0xFF6A13,206},
	{0x00AE42,0x8E9089,206}, {0x545454,0xC12E1F,146}, {0x545454,0x00AE42,116}, {0x545454,0xD1D3D5,176}, {0x545454,0x5B6579,86},
	{0x545454,0xF4EE2A,206}, {0x545454,0x9D432C,86}, {0x545454,0x5E43B7,56}, {0x545454,0xFF6A13,236}, {0x545454,0x8E9089,56},
	{0xD1D3D5,0xC12E1F,116}, {0xD1D3D5,0x00AE42,116}, {0xD1D3D5,0xF4EE2A,56}, {0xD1D3D5,0x9D432C,86}, {0xD1D3D5,0x5E43B7,86},
	{0xD1D3D5,0xFF6A13,86}, {0x5B6579,0x000000,26}, {0x5B6579,0xC12E1F,56}, {0x5B6579,0x00AE42,26}, {0x5B6579,0x545454,26},
	{0x5B6579,0xD1D3D5,56}, {0x5B6579,0xF4EE2A,116}, {0x5B6579,0x9D432C,56}, {0x5B6579,0x5E43B7,26}, {0x5B6579,0x0A2989,26},
	{0x5B6579,0xFF6A13,116}, {0x5B6579,0x8E9089,26}, {0xF4EE2A,0x000000,56}, {0xF4EE2A,0xC12E1F,26}, {0xF4EE2A,0x00AE42,86},
	{0xF4EE2A,0x545454,146}, {0xF4EE2A,0x9D432C,86}, {0xF4EE2A,0x5E43B7,146}, {0xF4EE2A,0xFF6A13,26}, {0x9D432C,0x000000,56},
	{0x9D432C,0xC12E1F,56}, {0x9D432C,0x00AE42,176}, {0x9D432C,0x545454,86}, {0x9D432C,0xD1D3D5,236}, {0x9D432C,0xF4EE2A,206},
	{0x9D432C,0x5E43B7,116}, {0x9D432C,0x0A2989,86}, {0x9D432C,0xFF6A13,116}, {0x9D432C,0x8E9089,146}, {0x5E43B7,0xC12E1F,176},
	{0x5E43B7,0x00AE42,116}, {0x5E43B7,0x545454,56}, {0x5E43B7,0xD1D3D5,206}, {0x5E43B7,0x5B6579,116}, {0x5E43B7,0xF4EE2A,206},
	{0x5E43B7,0x9D432C,86}, {0x5E43B7,0x0A2989,56}, {0x5E43B7,0xFF6A13,206}, {0x5E43B7,0x8E9089,146}, {0x0A2989,0x000000,26},
	{0x0A2989,0xC12E1F,266}, {0x0A2989,0x00AE42,146}, {0x0A2989,0x545454,86}, {0x0A2989,0xD1D3D5,386}, {0x0A2989,0x5B6579,176},
	{0x0A2989,0xF4EE2A,566}, {0x0A2989,0x9D432C,206}, {0x0A2989,0x5E43B7,116}, {0x0A2989,0xFF6A13,326}, {0x0A2989,0x8E9089,206},
	{0xFF6A13,0x000000,56}, {0xFF6A13,0xC12E1F,26}, {0xFF6A13,0x545454,86}, {0xFF6A13,0xD1D3D5,146}, {0xFF6A13,0xF4EE2A,146},
	{0xFF6A13,0x9D432C,56}, {0xFF6A13,0x5E43B7,146}, {0xFF6A13,0x0A2989,146}, {0xFF6A13,0x8E9089,116}, {0x8E9089,0xC12E1F,86},
	{0x8E9089,0x00AE42,56}, {0x8E9089,0xD1D3D5,86}, {0x8E9089,0xF4EE2A,206}, {0x8E9089,0x9D432C,86}, {0x8E9089,0xFF6A13,86}
};

static unsigned PDHexRGB(NSString *hex) {
	NSString *h = [hex stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]];
	unsigned v = 0;
	if ([h length] < 6 || ![[NSScanner scannerWithString:[h substringToIndex:6]] scanHexInt:&v]) return 0x808080;
	return v;
}

static void PDHSV(float r, float g, float b, float *h, float *s, float *v) {
	float mx = fmaxf(r, fmaxf(g, b)), mn = fminf(r, fminf(g, b)), d = mx - mn;
	*v = mx;
	*s = mx > 0 ? d / mx : 0;
	if (d <= 0) { *h = 0; return; }
	float hh = mx == r ? fmodf((g - b) / d, 6) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
	hh *= 60;
	if (hh < 0) hh += 360;
	*h = hh;
}

// FlushVolCalculator::calc_flush_vol_rgb, as disassembled from the ElegooSlicer 1.5.3.5 Linux build.
static int PDFlushRGB(unsigned from, unsigned to) {
	float r1 = ((from >> 16) & 255) / 255.f, g1 = ((from >> 8) & 255) / 255.f, b1 = (from & 255) / 255.f;
	float r2 = ((to >> 16) & 255) / 255.f, g2 = ((to >> 8) & 255) / 255.f, b2 = (to & 255) / 255.f;
	float h1, s1, v1, h2, s2, v2;
	PDHSV(r1, g1, b1, &h1, &s1, &v1);
	PDHSV(r2, g2, b2, &h2, &s2, &v2);
	float a1 = h1 / 180.f * (float)M_PI, a2 = h2 / 180.f * (float)M_PI;
	float dx = cosf(a1) * s1 * v1 - cosf(a2) * s2 * v2, dy = sinf(a1) * s1 * v1 - sinf(a2) * s2 * v2;
	float hs = fminf(sqrtf(dx * dx + dy * dy), 1.2f);
	float l1 = 0.3f * r1 + 0.59f * g1 + 0.11f * b1, l2 = 0.3f * r2 + 0.59f * g2 + 0.11f * b2;
	float lf;
	if (l2 >= l1) lf = powf(l2 - l1, 0.7f) * 560.f;
	else { lf = (l1 - l2) * 80.f; hs = fminf(hs, 0.67f * v2 + 0.33f * v1); }
	float hf = 230.f * hs;
	float f = sqrtf(lf * lf + hf * hf + hf * lf);
	return (int)fmaxf(f, 60.f);
}

@implementation PDFilamentSlots

+ (int)flushVolumeFrom:(NSString *)fromHex to:(NSString *)toHex {
	unsigned a = PDHexRGB(fromHex), b = PDHexRGB(toHex);
	if (a == b) return 0;
	int f = -1;
	for (size_t i = 0; i < sizeof PDFlushData / sizeof PDFlushData[0]; i++)
		if (PDFlushData[i].from == a && PDFlushData[i].to == b) { f = PDFlushData[i].flush; break; }
	if (f < 0) f = PDFlushRGB(a, b);
	return MIN(800, MAX(0, f));   // + the minimum flush (0 here), capped at ElegooSlicer's maximum
}

#pragma mark Slots

+ (NSUserDefaults *)ud { return [NSUserDefaults standardUserDefaults]; }
+ (void)post { [[NSNotificationCenter defaultCenter] postNotificationName:PDFilamentSlotsChangedNotification object:nil]; }

// First run: slot 1 becomes whatever the Filament editor holds (synced on first use); 2-4 generic PLA in
// yellow, red and green, as in the first 4-colour ElegooSlicer print.
+ (NSArray *)defaultSlots {
	NSArray *cols = [NSArray arrayWithObjects:@"#000000", @"#FFFF00", @"#FF0000", @"#00FF00", nil];
	NSMutableArray *a = [NSMutableArray array];
	for (int i = 0; i < PD_SLOTS; i++)
		[a addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"Generic PLA", @"title", @"PLA", @"type", [cols objectAtIndex:(NSUInteger)i], @"color",
			@"", @"profile", [NSNumber numberWithBool:NO], @"user", [NSNumber numberWithInt:220], @"nozzleTemp", nil]];
	return a;
}

+ (NSArray *)slots {
	NSArray *a = [[self ud] arrayForKey:PDSlotsKey];
	if ([a count] != PD_SLOTS) a = [self defaultSlots];
	return a;
}
+ (NSDictionary *)slot:(int)i { return [[self slots] objectAtIndex:(NSUInteger)MAX(0, MIN(PD_SLOTS - 1, i))]; }

+ (int)activeSlot { return MAX(0, MIN(PD_SLOTS - 1, (int)[[self ud] integerForKey:PDActiveSlotKey])); }

// Merges values into slot i; YES if anything changed. Recalculates the flush matrix (auto mode) on a colour change.
+ (BOOL)store:(int)i values:(NSDictionary *)values {
	if (i < 0 || i >= PD_SLOTS) return NO;
	NSMutableArray *a = [[self slots] mutableCopy];
	NSMutableDictionary *d = [[a objectAtIndex:(NSUInteger)i] mutableCopy];
	NSString *oldColor = [d objectForKey:@"color"];
	[d addEntriesFromDictionary:values];
	if ([d isEqualToDictionary:[a objectAtIndex:(NSUInteger)i]]) return NO;
	[a replaceObjectAtIndex:(NSUInteger)i withObject:d];
	[[self ud] setObject:a forKey:PDSlotsKey];
	if ([self autoFlush] && ![oldColor isEqualToString:[d objectForKey:@"color"]]) [self recalculateFlushQuietly];
	return YES;
}

+ (void)setSlot:(int)i values:(NSDictionary *)values {
	if (![self store:i values:values]) return;
	if (i == [self activeSlot] && [values objectForKey:@"color"]) [PDSliceSettings setValue:[values objectForKey:@"color"] forKey:@"filamentColor"];
	[self post];
}

+ (void)syncActiveFromSettings {
	NSDictionary *s = [PDSliceSettings current];
	NSString *material = [s objectForKey:@"material"] ?: @"PLA";
	NSString *title = [PDSliceProfiles selectedTitleForEditor:@"filament"];
	if (![title length]) title = [[s objectForKey:@"filamentName"] length] ? [s objectForKey:@"filamentName"] : [@"Generic " stringByAppendingString:material];
	NSDictionary *st = [PDSliceProfiles state];
	NSDictionary *v = [NSDictionary dictionaryWithObjectsAndKeys:title, @"title", material, @"type",
		[s objectForKey:@"filamentColor"] ?: @"#3C8CE6", @"color", [st objectForKey:@"filament"] ?: @"", @"profile",
		[NSNumber numberWithBool:[PDSliceProfiles isUser:@"filament"]], @"user",
		[NSNumber numberWithInt:(int)lround([[s objectForKey:@"nozzleTemp"] doubleValue])], @"nozzleTemp", nil];
	if ([self store:[self activeSlot] values:v]) [self post];
}

+ (NSDictionary *)stockFilamentNamed:(NSString *)name {
	for (NSDictionary *f in [[PDSliceProfiles stock] objectForKey:@"filaments"]) if ([[f objectForKey:@"name"] isEqualToString:name]) return f;
	return nil;
}
+ (NSDictionary *)userFilamentNamed:(NSString *)name {
	for (NSDictionary *p in [PDSliceProfiles userPresetsForEditor:@"filament"]) if ([[p objectForKey:@"name"] isEqualToString:name]) return p;
	return nil;
}

// The stock "Generic <type>" filament for this printer (or any printer), for a slot that names only a material.
+ (NSDictionary *)genericFilamentFor:(NSString *)type {
	if (![type length]) return nil;
	NSDictionary *any = nil;
	NSString *printer = [[PDSliceProfiles currentPrinter] objectForKey:@"name"];
	for (NSDictionary *f in [[PDSliceProfiles stock] objectForKey:@"filaments"]) {
		if (![[f objectForKey:@"vendor"] isEqualToString:@"Generic"] || [[f objectForKey:@"type"] caseInsensitiveCompare:type] != NSOrderedSame) continue;
		if (!printer || [[f objectForKey:@"printers"] containsObject:printer]) return f;
		if (!any) any = f;
	}
	return any;
}

+ (void)setActiveSlot:(int)i {
	if (i < 0 || i >= PD_SLOTS || i == [self activeSlot]) return;
	[self syncActiveFromSettings];   // keep what the old slot had
	NSDictionary *slot = [self slot:i];
	[[self ud] setInteger:i forKey:PDActiveSlotKey];
	BOOL user = [[slot objectForKey:@"user"] boolValue];
	NSString *profile = [slot objectForKey:@"profile"];
	NSDictionary *preset = ![profile length] ? nil : user ? [self userFilamentNamed:profile] : [self stockFilamentNamed:profile];
	if (!preset) { user = NO; preset = [self genericFilamentFor:[slot objectForKey:@"type"]]; }   // e.g. filled from the CANVAS
	if (preset && user) [PDSliceProfiles applyUserPreset:preset];
	else if (preset) [PDSliceProfiles applyFilament:preset];
	else if ([[slot objectForKey:@"type"] length] && ![[slot objectForKey:@"type"] isEqualToString:[PDSliceSettings valueForKey:@"material"]])
		[PDSliceSettings setValue:[slot objectForKey:@"type"] forKey:@"material"];
	if ([[slot objectForKey:@"color"] length]) [PDSliceSettings setValue:[slot objectForKey:@"color"] forKey:@"filamentColor"];
	[self syncActiveFromSettings];
	[self post];
}

+ (void)assignFilament:(NSDictionary *)profile user:(BOOL)user toSlot:(int)i {
	if (!profile || i < 0 || i >= PD_SLOTS) return;
	if (i == [self activeSlot]) {
		if (user) [PDSliceProfiles applyUserPreset:profile]; else [PDSliceProfiles applyFilament:profile];
		[self syncActiveFromSettings];
		return;
	}
	NSDictionary *fs = [profile objectForKey:@"settings"];
	NSString *title = user ? [profile objectForKey:@"name"] : ([profile objectForKey:@"title"] ?: [profile objectForKey:@"name"]);
	NSString *type = [fs objectForKey:@"material"] ?: [profile objectForKey:@"type"] ?: @"PLA";
	int temp = [[fs objectForKey:@"nozzleTemp"] intValue];
	NSMutableDictionary *v = [NSMutableDictionary dictionaryWithObjectsAndKeys:title ?: @"Filament", @"title", type, @"type",
		[profile objectForKey:@"name"] ?: @"", @"profile", [NSNumber numberWithBool:user], @"user", [NSNumber numberWithInt:temp > 0 ? temp : 220], @"nozzleTemp", nil];
	if (user && [[fs objectForKey:@"filamentColor"] length]) [v setObject:[fs objectForKey:@"filamentColor"] forKey:@"color"];
	if ([self store:i values:v]) [self post];
}

+ (int)fillFromCanvas:(NSDictionary *)info {
	NSArray *units = [info objectForKey:@"canvas_list"];
	if (![units isKindOfClass:[NSArray class]]) return 0;
	NSDictionary *unit = nil;
	int want = [[info objectForKey:@"active_canvas_id"] intValue];
	for (NSDictionary *u in units) {
		if (![u isKindOfClass:[NSDictionary class]] || ![[u objectForKey:@"connected"] intValue]) continue;
		if (!unit || [[u objectForKey:@"canvas_id"] intValue] == want) unit = u;
	}
	NSArray *trays = [unit objectForKey:@"tray_list"];
	if (![trays isKindOfClass:[NSArray class]]) return 0;
	int n = 0, active = [self activeSlot];
	BOOL activeColor = NO;
	for (NSUInteger k = 0; k < [trays count]; k++) {
		NSDictionary *t = [trays objectAtIndex:k];
		if (![t isKindOfClass:[NSDictionary class]] || [[t objectForKey:@"status"] intValue] == 0) continue;
		int i = [t objectForKey:@"tray_id"] ? [[t objectForKey:@"tray_id"] intValue] : (int)k;
		if (i < 0 || i >= PD_SLOTS) continue;
		NSString *type = [[t objectForKey:@"filament_type"] description] ?: @"";
		NSString *color = [[t objectForKey:@"filament_color"] description] ?: @"";
		if ([color length] == 6) color = [@"#" stringByAppendingString:color];
		NSString *brand = [[t objectForKey:@"brand"] description] ?: @"", *name = [[t objectForKey:@"filament_name"] description] ?: @"";
		NSString *title = [[NSString stringWithFormat:@"%@ %@", brand, [name length] ? name : type] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSMutableDictionary *v = [NSMutableDictionary dictionary];
		if ([color length] == 7) [v setObject:[color uppercaseString] forKey:@"color"];
		if (i != active) {   // the active slot's filament is the Filament editor's: only its colour follows the CANVAS
			NSDictionary *old = [self slot:i];
			if ([type length]) [v setObject:type forKey:@"type"];
			if ([title length]) [v setObject:title forKey:@"title"];
			// Another material or another spool name: the slot's preset no longer describes it.
			if (![[old objectForKey:@"type"] isEqualToString:type] || ([title length] && ![[old objectForKey:@"title"] isEqualToString:title]) || ![[old objectForKey:@"profile"] length]) {
				[v setObject:@"" forKey:@"profile"];
				[v setObject:[NSNumber numberWithBool:NO] forKey:@"user"];
			}
			int hi = [[t objectForKey:@"max_nozzle_temp"] intValue], lo = [[t objectForKey:@"min_nozzle_temp"] intValue];
			if (hi > 0 && lo > 0 && (![[old objectForKey:@"profile"] length] || [v objectForKey:@"profile"])) [v setObject:[NSNumber numberWithInt:(hi + lo) / 2] forKey:@"nozzleTemp"];
		} else if ([v objectForKey:@"color"]) activeColor = YES;
		[self store:i values:v];
		n++;
	}
	if (activeColor) [PDSliceSettings setValue:[[self slot:active] objectForKey:@"color"] forKey:@"filamentColor"];
	[self post];
	return n;
}

#pragma mark Flushing

// ElegooSlicer's own matrix for black, yellow, red, green PLA (the first 4-colour print), until edited or recalculated.
+ (NSArray *)defaultFlush {
	const double v[16] = {0, 145, 165, 210, 120, 0, 165, 115, 180, 135, 0, 165, 120, 155, 175, 0};
	NSMutableArray *a = [NSMutableArray array];
	for (int i = 0; i < 16; i++) [a addObject:[NSNumber numberWithDouble:v[i]]];
	return a;
}
+ (NSArray *)flushMatrix {
	NSArray *a = [[self ud] arrayForKey:PDFlushKey];
	return [a count] == 16 ? a : [self defaultFlush];
}
+ (double)flushFrom:(int)a to:(int)b {
	if (a == b || a < 0 || b < 0 || a >= PD_SLOTS || b >= PD_SLOTS) return 0;
	return [[[self flushMatrix] objectAtIndex:(NSUInteger)(a * PD_SLOTS + b)] doubleValue];
}
+ (void)setFlush:(double)mm3 from:(int)a to:(int)b {
	if (a == b || a < 0 || b < 0 || a >= PD_SLOTS || b >= PD_SLOTS) return;
	NSMutableArray *m = [[self flushMatrix] mutableCopy];
	[m replaceObjectAtIndex:(NSUInteger)(a * PD_SLOTS + b) withObject:[NSNumber numberWithDouble:MAX(0, MIN(900, round(mm3)))]];
	[[self ud] setObject:m forKey:PDFlushKey];
	[[self ud] setBool:NO forKey:PDFlushAutoKey];
	[self post];
}
+ (double)flushMultiplier { id v = [[self ud] objectForKey:PDFlushMulKey]; return v ? MAX(0, MIN(3, [v doubleValue])) : 1; }
+ (void)setFlushMultiplier:(double)m { [[self ud] setDouble:MAX(0, MIN(3, round(m * 10) / 10)) forKey:PDFlushMulKey]; [self post]; }
+ (BOOL)autoFlush { return [[self ud] boolForKey:PDFlushAutoKey]; }
+ (void)setAutoFlush:(BOOL)on {
	[[self ud] setBool:on forKey:PDFlushAutoKey];
	if (on) [self recalculateFlushQuietly];
	[self post];
}
+ (void)recalculateFlushQuietly {
	NSArray *s = [self slots];
	NSMutableArray *m = [NSMutableArray array];
	for (int a = 0; a < PD_SLOTS; a++) for (int b = 0; b < PD_SLOTS; b++)
		[m addObject:[NSNumber numberWithInt:a == b ? 0 : [self flushVolumeFrom:[[s objectAtIndex:(NSUInteger)a] objectForKey:@"color"] to:[[s objectAtIndex:(NSUInteger)b] objectForKey:@"color"]]]];
	[[self ud] setObject:m forKey:PDFlushKey];
}
+ (void)recalculateFlush { [self recalculateFlushQuietly]; [self post]; }

+ (NSString *)signature {
	NSMutableArray *p = [NSMutableArray array];
	for (NSDictionary *s in [self slots]) [p addObject:[NSString stringWithFormat:@"%@/%@/%@/%@", [s objectForKey:@"title"], [s objectForKey:@"type"], [s objectForKey:@"color"], [s objectForKey:@"nozzleTemp"]]];
	return [NSString stringWithFormat:@"T%d|%@|%@|%g", [self activeSlot], [p componentsJoinedByString:@";"], [[self flushMatrix] componentsJoinedByString:@","], [self flushMultiplier]];
}

@end
