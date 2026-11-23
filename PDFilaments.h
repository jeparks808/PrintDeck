#import <Foundation/Foundation.h>

// The four filament slots of a CANVAS print, as ElegooSlicer keeps them, and the flushing volumes between them.
//
// Each slot (NSDictionary): title ("SUNLU PLA Black"), type ("PLA"), color ("#RRGGBB"), profile (a stock or user
// filament preset name, may be empty), user (YES = a user preset), nozzleTemp. The model prints with the active
// slot; that slot always mirrors the Filament editor (the current slicing settings), so editing the filament
// edits the active slot. Picking another slot as active loads its preset (or type) and colour into the settings.
//
// Flushing: a 4 × 4 matrix of mm³ (row = from, column = to; ElegooSlicer's flush_volumes_matrix) and a
// multiplier. With "auto" on, the matrix follows the slot colours using ElegooSlicer's rule (below).
// A filament change purges flush × multiplier ÷ the filament's cross-section (mm of filament: M6211 L…).
//
// Kept in NSUserDefaults; every change posts PDFilamentSlotsChangedNotification.

extern NSString *const PDFilamentSlotsChangedNotification;

#define PD_SLOTS 4

@interface PDFilamentSlots : NSObject
+ (NSArray *)slots;                               // 4 slot dictionaries
+ (NSDictionary *)slot:(int)i;
+ (int)activeSlot;                                // 0..3: the slot the model prints with (T<n>)
+ (void)setActiveSlot:(int)i;                     // loads that slot's filament into the settings
+ (void)setSlot:(int)i values:(NSDictionary *)values;   // merged into the slot
+ (void)assignFilament:(NSDictionary *)profile user:(BOOL)user toSlot:(int)i;   // a stock / user filament preset
+ (void)syncActiveFromSettings;                   // the active slot := the Filament editor's filament
// CANVAS (SDCP Cmd 324 data): copies each loaded tray's type, colour and name into the slot with the same number.
// Returns how many slots it filled.
+ (int)fillFromCanvas:(NSDictionary *)info;

// Flushing
+ (NSArray *)flushMatrix;                         // 16 NSNumbers, mm³, row-major from → to (diagonal 0)
+ (double)flushFrom:(int)a to:(int)b;
+ (void)setFlush:(double)mm3 from:(int)a to:(int)b;   // turns auto off
+ (double)flushMultiplier;
+ (void)setFlushMultiplier:(double)m;
+ (BOOL)autoFlush;
+ (void)setAutoFlush:(BOOL)on;                    // on: recalculates now and whenever a colour changes
+ (void)recalculateFlush;
// ElegooSlicer 1.5's colour rule (FlushVolCalculator::calc_flush_vol, nozzle_flush_dataset 0): the measured value
// for the standard colour pairs it knows, else a model of how much it takes to hide `from` under `to`: brightness
// difference (darker → lighter costs most) combined with hue/saturation distance, at least 60 mm³, at most 800.
+ (int)flushVolumeFrom:(NSString *)fromHex to:(NSString *)toHex;

+ (NSString *)signature;                          // changes with anything that changes the G-code
@end
