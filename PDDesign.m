#import "PDDesign.h"
#import "PDSlicer.h"
#include "PDCSG.h"
#include "PDPrimitives.h"
#include "PDParts.h"

#pragma mark - Mesh storage

// A unit mesh, shared by every copy of a shape (and by every shape of one primitive kind).
@interface PDMeshData : NSObject {
@public
	float *tris;
	int count;
}
@end
@implementation PDMeshData
- (void)dealloc { free(tris); }
@end

static NSArray *PDMatrixArray(GLKMatrix4 m) {
	NSMutableArray *a = [NSMutableArray arrayWithCapacity:16];
	for (int i = 0; i < 16; i++) [a addObject:[NSNumber numberWithFloat:m.m[i]]];
	return a;
}

static GLKMatrix4 PDMatrixFromArray(NSArray *a) {
	GLKMatrix4 m = GLKMatrix4Identity;
	if ([a isKindOfClass:[NSArray class]] && [a count] == 16)
		for (int i = 0; i < 16; i++) m.m[i] = [[a objectAtIndex:(NSUInteger)i] floatValue];
	return m;
}

#pragma mark - Shape

@interface PDShape () {
	GLKVector3 _bmin, _bmax;
	BOOL _boundsValid;
}
@property (nonatomic, readwrite, copy) NSString *kind;
@property (nonatomic, readwrite, strong) NSArray *children;
@property (nonatomic, strong) PDMeshData *mesh;
@property (nonatomic, readwrite, copy) NSString *partType;
@property (nonatomic, readwrite, copy) NSDictionary *parameters;
@property (nonatomic, readwrite, copy) NSString *meshName;
@property (nonatomic, copy) NSString *meshId;
@property (nonatomic, readwrite, copy) NSDictionary *options;
@end

@implementation PDShape

+ (NSArray *)kinds {
	return [NSArray arrayWithObjects:@"box", @"cylinder", @"sphere", @"dome", @"cone", @"pyramid", @"roof", @"wedge", @"tube", @"torus", nil];
}

+ (NSString *)titleForKind:(NSString *)kind {
	if ([kind isEqualToString:@"group"]) return @"Group";
	if ([kind isEqualToString:@"dome"]) return @"Half sphere";
	return [kind capitalizedString];
}

// One mesh per primitive kind, made on first use.
+ (PDMeshData *)primitive:(NSString *)kind {
	static NSMutableDictionary *cache;
	@synchronized (self) {
		if (!cache) cache = [NSMutableDictionary dictionary];
		PDMeshData *m = [cache objectForKey:kind];
		if (!m) {
			PDCSGMesh pm;
			if (PDPrimitiveMesh([kind UTF8String], &pm) != 0) return nil;
			m = [[PDMeshData alloc] init];
			m->tris = pm.tris; m->count = pm.count;
			[cache setObject:m forKey:kind];
		}
		return m;
	}
}

+ (PDShape *)shapeOfKind:(NSString *)kind size:(GLKVector3)size x:(float)x y:(float)y {
	PDMeshData *m = [self primitive:kind];
	if (!m) return nil;
	PDShape *s = [[PDShape alloc] init];
	s.kind = kind;
	s.mesh = m;
	s.color = 0x3B8FE0;
	s.matrix = GLKMatrix4Multiply(GLKMatrix4MakeTranslation(x, y, size.z / 2), GLKMatrix4MakeScale(size.x, size.y, size.z));
	return s;
}

- (id)copyWithZone:(NSZone *)zone {
	PDShape *s = [[PDShape alloc] init];
	s.kind = self.kind;
	s.children = self.children;   // immutable once grouped
	s.mesh = self.mesh;
	s.hole = self.hole;
	s.color = self.color;
	s.matrix = self.matrix;
	s.partType = self.partType;
	s.parameters = self.parameters;
	s.meshName = self.meshName;
	s.meshId = self.meshId;
	s.options = self.options;
	return s;
}

- (NSString *)title {
	if ([self.kind isEqualToString:@"part"]) return [PDShape shortTitleForPart:self.partType parameters:self.parameters];
	if ([self.kind isEqualToString:@"mesh"]) return self.meshName ?: @"Model";
	return [PDShape titleForKind:self.kind];
}

- (void)setMatrix:(GLKMatrix4)m { _matrix = m; _boundsValid = NO; }

- (const float *)unitTriangles:(int *)count {
	*count = self.mesh ? self.mesh->count : 0;
	return self.mesh ? self.mesh->tris : NULL;
}

- (id)meshObject { return self.mesh; }

- (float *)newWorldTriangles:(int *)count {
	int n = self.mesh ? self.mesh->count : 0;
	*count = 0;
	float *out = n ? malloc((size_t)n * 9 * sizeof(float)) : NULL;
	if (!out) return NULL;
	GLKMatrix4 m = self.matrix;
	const float *t = self.mesh->tris;
	// A mirrored shape (negative determinant) turns inside out: swap two corners to keep it facing outward.
	GLKMatrix3 r = GLKMatrix4GetMatrix3(m);
	float det = r.m00 * (r.m11 * r.m22 - r.m12 * r.m21) - r.m01 * (r.m10 * r.m22 - r.m12 * r.m20) + r.m02 * (r.m10 * r.m21 - r.m11 * r.m20);
	for (int i = 0; i < n; i++) for (int v = 0; v < 3; v++) {
		int src = det < 0 && v > 0 ? 3 - v : v;
		GLKVector3 p = GLKMatrix4MultiplyVector3WithTranslation(m, GLKVector3Make(t[i * 9 + src * 3], t[i * 9 + src * 3 + 1], t[i * 9 + src * 3 + 2]));
		out[i * 9 + v * 3] = p.x; out[i * 9 + v * 3 + 1] = p.y; out[i * 9 + v * 3 + 2] = p.z;
	}
	*count = n;
	return out;
}

- (void)updateBounds {
	if (_boundsValid) return;
	_bmin = GLKVector3Make(1e30f, 1e30f, 1e30f);
	_bmax = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	int n = self.mesh ? self.mesh->count * 3 : 0;
	const float *t = self.mesh ? self.mesh->tris : NULL;
	GLKMatrix4 m = self.matrix;
	for (int i = 0; i < n; i++) {
		GLKVector3 p = GLKMatrix4MultiplyVector3WithTranslation(m, GLKVector3Make(t[i * 3], t[i * 3 + 1], t[i * 3 + 2]));
		_bmin = GLKVector3Minimum(_bmin, p);
		_bmax = GLKVector3Maximum(_bmax, p);
	}
	if (!n) _bmin = _bmax = GLKVector3Make(m.m[12], m.m[13], m.m[14]);
	_boundsValid = YES;
}
- (GLKVector3)worldMin { [self updateBounds]; return _bmin; }
- (GLKVector3)worldMax { [self updateBounds]; return _bmax; }

- (GLKVector3)axisLengths {
	GLKMatrix4 m = self.matrix;
	return GLKVector3Make(GLKVector3Length(GLKVector3Make(m.m[0], m.m[1], m.m[2])), GLKVector3Length(GLKVector3Make(m.m[4], m.m[5], m.m[6])),
		GLKVector3Length(GLKVector3Make(m.m[8], m.m[9], m.m[10])));
}

- (GLKVector3)rotationDegrees {
	GLKMatrix4 m = self.matrix;
	GLKVector3 c[3];
	for (int i = 0; i < 3; i++) {
		c[i] = GLKVector3Make(m.m[i * 4], m.m[i * 4 + 1], m.m[i * 4 + 2]);
		float l = GLKVector3Length(c[i]);
		if (l > 0) c[i] = GLKVector3DivideScalar(c[i], l);
	}
	if (GLKVector3DotProduct(c[0], GLKVector3CrossProduct(c[1], c[2])) < 0) {   // mirrored: undo it along the axis pointing most backwards
		int flip = 0; float worst = 2;
		for (int i = 0; i < 3; i++) if (c[i].v[i] < worst) { worst = c[i].v[i]; flip = i; }
		c[flip] = GLKVector3Negate(c[flip]);
	}
	// R = Rz · Ry · Rx; R[row][col] = c[col].v[row]
	float sy = -c[0].z;
	sy = MAX(-1, MIN(1, sy));
	float x, y = asinf(sy), z;
	if (fabsf(sy) < 0.9999f) { x = atan2f(c[1].z, c[2].z); z = atan2f(c[0].y, c[0].x); }
	else { x = atan2f(-c[2].y, c[1].y); z = 0; }   // gimbal lock: put it all on X
	GLKVector3 d = GLKVector3Make(GLKMathRadiansToDegrees(x), GLKMathRadiansToDegrees(y), GLKMathRadiansToDegrees(z));
	for (int i = 0; i < 3; i++) { d.v[i] = roundf(d.v[i] * 10) / 10; if (fabsf(d.v[i]) < 0.05f || d.v[i] <= -179.95f) d.v[i] = fabsf(d.v[i]) < 0.05f ? 0 : 180; }
	return d;
}

+ (NSString *)rotationTextFor:(NSArray *)shapes {
	if (![shapes count]) return @"";
	GLKVector3 r = [(PDShape *)[shapes objectAtIndex:0] rotationDegrees];
	for (PDShape *s in shapes) {
		GLKVector3 q = [s rotationDegrees];
		for (int i = 0; i < 3; i++) if (fabsf(q.v[i] - r.v[i]) > 0.05f) return @"mixed";
	}
	return [NSString stringWithFormat:@"X %g°  Y %g°  Z %g°", r.x, r.y, r.z];
}

#pragma mark Groups

// Members' world meshes in, the combined mesh out (in the same frame). NO when it comes out empty.
+ (BOOL)combine:(NSArray *)shapes into:(PDCSGMesh *)out hole:(BOOL *)allHoles {
	NSUInteger n = [shapes count];
	PDCSGMesh *solids = calloc(n ? n : 1, sizeof(PDCSGMesh)), *holes = calloc(n ? n : 1, sizeof(PDCSGMesh));
	int ns = 0, nh = 0;
	for (PDShape *s in shapes) {
		PDCSGMesh m;
		m.tris = [s newWorldTriangles:&m.count];
		if (!m.tris) continue;
		if (s.hole) holes[nh++] = m; else solids[ns++] = m;
	}
	int r = PDCSGCombine(solids, ns, holes, nh, out);
	for (int i = 0; i < ns; i++) free(solids[i].tris);
	for (int i = 0; i < nh; i++) free(holes[i].tris);
	free(solids); free(holes);
	if (allHoles) *allHoles = ns == 0;
	if (r != 0 || out->count == 0) { PDCSGFree(out); return NO; }
	return YES;
}

+ (PDShape *)groupOf:(NSArray *)shapes {
	if (![shapes count]) return nil;
	PDCSGMesh out;
	BOOL allHoles = NO;
	if (![self combine:shapes into:&out hole:&allHoles]) return nil;
	GLKVector3 lo = GLKVector3Make(1e30f, 1e30f, 1e30f), hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	for (int i = 0; i < out.count * 3; i++) {
		GLKVector3 p = GLKVector3Make(out.tris[i * 3], out.tris[i * 3 + 1], out.tris[i * 3 + 2]);
		lo = GLKVector3Minimum(lo, p); hi = GLKVector3Maximum(hi, p);
	}
	GLKVector3 size = GLKVector3Maximum(GLKVector3Subtract(hi, lo), GLKVector3Make(0.01f, 0.01f, 0.01f));
	GLKVector3 c = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	// The group's frame: its bounding box is the unit cube.
	GLKMatrix4 G = GLKMatrix4Multiply(GLKMatrix4MakeTranslation(c.x, c.y, c.z), GLKMatrix4MakeScale(size.x, size.y, size.z));
	bool ok;
	GLKMatrix4 Gi = GLKMatrix4Invert(G, &ok);
	for (int i = 0; i < out.count * 3; i++) {
		out.tris[i * 3] = (out.tris[i * 3] - c.x) / size.x;
		out.tris[i * 3 + 1] = (out.tris[i * 3 + 1] - c.y) / size.y;
		out.tris[i * 3 + 2] = (out.tris[i * 3 + 2] - c.z) / size.z;
	}
	NSMutableArray *kids = [NSMutableArray array];
	PDShape *firstSolid = nil;
	for (PDShape *s in shapes) {
		PDShape *k = [s copy];
		k.matrix = GLKMatrix4Multiply(Gi, s.matrix);
		[kids addObject:k];
		if (!s.hole && !firstSolid) firstSolid = s;
	}
	PDShape *g = [[PDShape alloc] init];
	g.kind = @"group";
	g.children = kids;
	PDMeshData *md = [[PDMeshData alloc] init];
	md->tris = out.tris; md->count = out.count;
	g.mesh = md;
	g.hole = allHoles;
	g.color = firstSolid ? firstSolid.color : ((PDShape *)[shapes objectAtIndex:0]).color;
	g.matrix = G;
	return g;
}

- (NSArray *)ungrouped {
	NSMutableArray *a = [NSMutableArray array];
	for (PDShape *k in self.children) {
		PDShape *c = [k copy];
		c.matrix = GLKMatrix4Multiply(self.matrix, k.matrix);
		[a addObject:c];
	}
	return a;
}

#pragma mark Saving

- (NSDictionary *)plist {
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys:self.kind, @"kind", [NSNumber numberWithBool:self.hole], @"hole",
		[NSNumber numberWithUnsignedInt:self.color], @"color", PDMatrixArray(self.matrix), @"matrix", nil];
	if (self.partType) { [d setObject:self.partType forKey:@"partType"]; [d setObject:self.parameters ?: [NSDictionary dictionary] forKey:@"parameters"]; }
	if (self.meshId) { [d setObject:self.meshId forKey:@"meshId"]; [d setObject:self.meshName ?: @"Model" forKey:@"meshName"]; }
	if (self.options) [d setObject:self.options forKey:@"options"];
	if (self.children) {
		NSMutableArray *k = [NSMutableArray array];
		for (PDShape *c in self.children) [k addObject:[c plist]];
		[d setObject:k forKey:@"children"];
	}
	return d;
}

+ (PDShape *)shapeFromPlist:(NSDictionary *)d {
	if (![d isKindOfClass:[NSDictionary class]]) return nil;
	NSString *kind = [d objectForKey:@"kind"];
	PDShape *s = nil;
	if ([kind isEqualToString:@"group"]) {
		NSMutableArray *kids = [NSMutableArray array];
		for (NSDictionary *c in [d objectForKey:@"children"]) { PDShape *k = [self shapeFromPlist:c]; if (k) [kids addObject:k]; }
		PDCSGMesh out;
		if (![kids count] || ![self combine:kids into:&out hole:NULL]) return nil;   // members are already in the unit frame
		s = [[PDShape alloc] init];
		s.kind = kind;
		s.children = kids;
		PDMeshData *md = [[PDMeshData alloc] init];
		md->tris = out.tris; md->count = out.count;
		s.mesh = md;
	} else if ([kind isEqualToString:@"part"]) {
		NSString *type = [d objectForKey:@"partType"];
		NSDictionary *params = [d objectForKey:@"parameters"];
		if (![type isKindOfClass:[NSString class]] || ![params isKindOfClass:[NSDictionary class]]) return nil;
		PDMeshData *m = [self partMesh:type parameters:params size:NULL];
		if (!m) return nil;
		s = [[PDShape alloc] init];
		s.kind = kind;
		s.mesh = m;
		s.partType = type;
		s.parameters = params;
	} else if ([kind isEqualToString:@"mesh"]) {
		NSString *mid = [d objectForKey:@"meshId"];
		PDMeshData *m = [mid isKindOfClass:[NSString class]] ? [self storedMesh:mid] : nil;
		if (!m) return nil;
		s = [[PDShape alloc] init];
		s.kind = kind;
		s.mesh = m;
		s.meshId = mid;
		s.meshName = [d objectForKey:@"meshName"];
	} else {
		NSDictionary *o = [d objectForKey:@"options"];
		if (![o isKindOfClass:[NSDictionary class]] || ![self kindHasOptions:kind]) o = nil;
		PDMeshData *m = o ? [self optionMesh:kind options:o] : nil;
		if (!m) { m = [kind isKindOfClass:[NSString class]] ? [self primitive:kind] : nil; o = nil; }
		if (!m) return nil;
		s = [[PDShape alloc] init];
		s.kind = kind;
		s.mesh = m;
		s.options = o;
	}
	s.hole = [[d objectForKey:@"hole"] boolValue];
	s.color = [[d objectForKey:@"color"] unsignedIntValue];
	s.matrix = PDMatrixFromArray([d objectForKey:@"matrix"]);
	return s;
}


#pragma mark Library parts

+ (NSArray *)partTypes {
	return [NSArray arrayWithObjects:@"bolt", @"nut", @"threadedHole", @"screwHole", @"edgeHole", @"roundedBox", @"roundedCylinder", @"gear", nil];
}

+ (NSString *)titleForPartType:(NSString *)t {
	if ([t hasPrefix:@"shape."]) return [NSString stringWithFormat:@"%@ options", [self titleForKind:[t substringFromIndex:6]]];
	NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:@"Bolt", @"bolt", @"Nut", @"nut", @"Threaded hole", @"threadedHole",
		@"Screw hole", @"screwHole", @"Rounded hole", @"edgeHole", @"Rounded box", @"roundedBox", @"Rounded cylinder", @"roundedCylinder", @"Gear", @"gear", nil];
	return [d objectForKey:t] ?: t;
}

+ (BOOL)partTypeIsHole:(NSString *)t {
	return [t isEqualToString:@"threadedHole"] || [t isEqualToString:@"screwHole"] || [t isEqualToString:@"edgeHole"];
}

static NSDictionary *PDNum(NSString *key, NSString *title, double min, double max, double step, NSString *unit) {
	return [NSDictionary dictionaryWithObjectsAndKeys:key, @"key", title, @"title", @"number", @"kind", [NSNumber numberWithDouble:min], @"min",
		[NSNumber numberWithDouble:max], @"max", [NSNumber numberWithDouble:step], @"step", unit ?: @"", @"unit", nil];
}
static NSDictionary *PDChoice(NSString *key, NSString *title, NSArray *choices) {
	return [NSDictionary dictionaryWithObjectsAndKeys:key, @"key", title, @"title", @"choice", @"kind", choices, @"choices", nil];
}
static NSDictionary *PDSwitch(NSString *key, NSString *title) {
	return [NSDictionary dictionaryWithObjectsAndKeys:key, @"key", title, @"title", @"switch", @"kind", nil];
}
static NSArray *PDSizeNames(void) {
	NSMutableArray *a = [NSMutableArray array];
	for (int i = 0; i < PDMetricCount(); i++) [a addObject:[NSString stringWithUTF8String:PDMetricSize(i)->name]];
	return a;
}

+ (NSArray *)parameterSpecForPartType:(NSString *)t {
	if ([t hasPrefix:@"shape."]) return [self optionSpecForKind:[t substringFromIndex:6]];
	NSArray *edges = [NSArray arrayWithObjects:@"Fillet", @"Chamfer", @"None", nil];
	if ([t isEqualToString:@"bolt"]) return [NSArray arrayWithObjects:PDChoice(@"size", @"Size", PDSizeNames()), PDNum(@"length", @"Length", 2, 200, 1, @"mm"),
		PDChoice(@"head", @"Head", [NSArray arrayWithObjects:@"Hex", @"Socket", @"Flat", @"None", nil]), PDSwitch(@"threaded", @"Threaded"),
		PDNum(@"clearance", @"Clearance", 0, 0.6, 0.05, @"mm"), nil];
	if ([t isEqualToString:@"nut"]) return [NSArray arrayWithObjects:PDChoice(@"size", @"Size", PDSizeNames()),
		PDChoice(@"height", @"Height", [NSArray arrayWithObjects:@"Standard", @"Thin", @"Thick", nil]), PDSwitch(@"threaded", @"Threaded"),
		PDNum(@"clearance", @"Clearance", 0, 0.6, 0.05, @"mm"), nil];
	if ([t isEqualToString:@"threadedHole"]) return [NSArray arrayWithObjects:PDChoice(@"size", @"Size", PDSizeNames()), PDNum(@"depth", @"Depth", 1, 200, 1, @"mm"),
		PDNum(@"clearance", @"Clearance", 0, 0.6, 0.05, @"mm"), nil];
	if ([t isEqualToString:@"screwHole"]) return [NSArray arrayWithObjects:PDChoice(@"size", @"Size", PDSizeNames()),
		PDChoice(@"head", @"Head", [NSArray arrayWithObjects:@"Countersink", @"Counterbore", @"Plain", nil]), PDNum(@"depth", @"Depth", 1, 200, 1, @"mm"), nil];
	if ([t isEqualToString:@"edgeHole"]) return [NSArray arrayWithObjects:PDNum(@"diameter", @"Diameter", 0.5, 200, 0.5, @"mm"), PDNum(@"depth", @"Depth", 0.5, 200, 1, @"mm"),
		PDChoice(@"edge", @"Rim", [NSArray arrayWithObjects:@"Fillet", @"Chamfer", nil]), PDNum(@"edgeSize", @"Rim size", 0.2, 30, 0.2, @"mm"), PDSwitch(@"bothEnds", @"Both ends"), nil];
	if ([t isEqualToString:@"roundedBox"]) return [NSArray arrayWithObjects:PDNum(@"width", @"Width", 1, 256, 1, @"mm"), PDNum(@"depth", @"Depth", 1, 256, 1, @"mm"),
		PDNum(@"height", @"Height", 1, 256, 1, @"mm"), PDChoice(@"edge", @"Edges", edges), PDNum(@"radius", @"Radius", 0.2, 50, 0.5, @"mm"), nil];
	if ([t isEqualToString:@"roundedCylinder"]) return [NSArray arrayWithObjects:PDNum(@"diameter", @"Diameter", 1, 256, 1, @"mm"), PDNum(@"height", @"Height", 1, 256, 1, @"mm"),
		PDChoice(@"topEdge", @"Top", edges), PDNum(@"topSize", @"Top size", 0.2, 50, 0.5, @"mm"),
		PDChoice(@"bottomEdge", @"Bottom", edges), PDNum(@"bottomSize", @"Bottom size", 0.2, 50, 0.5, @"mm"), nil];
	if ([t isEqualToString:@"gear"]) return [NSArray arrayWithObjects:PDNum(@"teeth", @"Teeth", 6, 150, 1, @""), PDNum(@"module", @"Module", 0.5, 6, 0.25, @"mm"),
		PDNum(@"thickness", @"Thickness", 1, 100, 1, @"mm"), PDNum(@"bore", @"Bore", 0, 100, 0.5, @"mm"), nil];
	return [NSArray array];
}

static NSNumber *N(double v) { return [NSNumber numberWithDouble:v]; }

+ (NSDictionary *)stockParametersForPartType:(NSString *)t {
	if ([t hasPrefix:@"shape."]) return [self stockOptionsForKind:[t substringFromIndex:6]];
	if ([t isEqualToString:@"bolt"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(2), @"size", N(12), @"length", N(0), @"head", N(1), @"threaded", N(0.15), @"clearance", nil];
	if ([t isEqualToString:@"nut"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(2), @"size", N(0), @"height", N(1), @"threaded", N(0.2), @"clearance", nil];
	if ([t isEqualToString:@"threadedHole"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(2), @"size", N(10), @"depth", N(0.2), @"clearance", nil];
	if ([t isEqualToString:@"screwHole"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(2), @"size", N(0), @"head", N(10), @"depth", nil];
	if ([t isEqualToString:@"edgeHole"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(8), @"diameter", N(10), @"depth", N(0), @"edge", N(1.5), @"edgeSize", N(0), @"bothEnds", nil];
	if ([t isEqualToString:@"roundedBox"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(30), @"width", N(20), @"depth", N(15), @"height", N(0), @"edge", N(3), @"radius", nil];
	if ([t isEqualToString:@"roundedCylinder"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(20), @"diameter", N(20), @"height", N(0), @"topEdge", N(2), @"topSize", N(2), @"bottomEdge", N(1), @"bottomSize", nil];
	if ([t isEqualToString:@"gear"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(20), @"teeth", N(1), @"module", N(6), @"thickness", N(5), @"bore", nil];
	return [NSDictionary dictionary];
}

+ (NSDictionary *)defaultParametersForPartType:(NSString *)t {
	NSMutableDictionary *d = [[self stockParametersForPartType:t] mutableCopy];
	NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[@"PDPartLast." stringByAppendingString:t]];
	for (NSString *k in [d allKeys]) if ([[last objectForKey:k] isKindOfClass:[NSNumber class]]) [d setObject:[last objectForKey:k] forKey:k];
	return d;
}

+ (void)rememberParameters:(NSDictionary *)p forPartType:(NSString *)t {
	if (p && t) [[NSUserDefaults standardUserDefaults] setObject:p forKey:[@"PDPartLast." stringByAppendingString:t]];
}

static double PV(NSDictionary *p, NSString *k) { return [[p objectForKey:k] doubleValue]; }
static int PI_(NSDictionary *p, NSString *k) { return (int)lround([[p objectForKey:k] doubleValue]); }
static NSString *PSize(NSDictionary *p) { const PDMetric *m = PDMetricSize(PI_(p, @"size")); return m ? [NSString stringWithUTF8String:m->name] : @"M?"; }
static NSString *PEdgeWord(int e) { return e == 0 ? @"rounded" : e == 1 ? @"chamfered" : @"plain"; }

+ (NSString *)describePart:(NSString *)t parameters:(NSDictionary *)p {
	if ([t hasPrefix:@"shape."]) return [self describeOptions:p kind:[t substringFromIndex:6]];
	if ([t isEqualToString:@"bolt"]) {
		int h = PI_(p, @"head");
		NSString *kind = h == 3 ? @"threaded rod" : [NSString stringWithFormat:@"%@ head bolt", [[NSArray arrayWithObjects:@"hex", @"socket", @"flat", @"", nil] objectAtIndex:(NSUInteger)MAX(0, MIN(3, h))]];
		return [NSString stringWithFormat:@"%@ × %g %@%@", PSize(p), PV(p, @"length"), kind, PI_(p, @"threaded") ? @"" : @" (unthreaded)"];
	}
	if ([t isEqualToString:@"nut"]) return [NSString stringWithFormat:@"%@ %@nut%@", PSize(p), PI_(p, @"height") == 1 ? @"thin " : PI_(p, @"height") == 2 ? @"thick " : @"", PI_(p, @"threaded") ? @"" : @" (plain hole)"];
	if ([t isEqualToString:@"threadedHole"]) return [NSString stringWithFormat:@"%@ threaded hole, %g mm deep", PSize(p), PV(p, @"depth")];
	if ([t isEqualToString:@"screwHole"]) return [NSString stringWithFormat:@"%@ %@ screw hole, %g mm deep", PSize(p), [[NSArray arrayWithObjects:@"countersunk", @"counterbored", @"plain", nil] objectAtIndex:(NSUInteger)MAX(0, MIN(2, PI_(p, @"head")))], PV(p, @"depth")];
	if ([t isEqualToString:@"edgeHole"]) return [NSString stringWithFormat:@"Ø%g mm hole, %@ rim%@", PV(p, @"diameter"), PEdgeWord(PI_(p, @"edge")), PI_(p, @"bothEnds") ? @"s" : @""];
	if ([t isEqualToString:@"roundedBox"]) return [NSString stringWithFormat:@"%g × %g × %g mm box, %@ edges", PV(p, @"width"), PV(p, @"depth"), PV(p, @"height"), PEdgeWord(PI_(p, @"edge"))];
	if ([t isEqualToString:@"roundedCylinder"]) return [NSString stringWithFormat:@"Ø%g × %g mm cylinder", PV(p, @"diameter"), PV(p, @"height")];
	if ([t isEqualToString:@"gear"]) return [NSString stringWithFormat:@"%d-tooth gear, module %g, Ø%.1f mm", PI_(p, @"teeth"), PV(p, @"module"), PV(p, @"module") * (PI_(p, @"teeth") + 2)];
	return [self titleForPartType:t];
}

+ (NSString *)shortTitleForPart:(NSString *)t parameters:(NSDictionary *)p {
	if ([t isEqualToString:@"bolt"]) return [NSString stringWithFormat:@"%@ %@", PSize(p), PI_(p, @"head") == 3 ? @"rod" : @"bolt"];
	if ([t isEqualToString:@"nut"]) return [NSString stringWithFormat:@"%@ nut", PSize(p)];
	if ([t isEqualToString:@"threadedHole"]) return [NSString stringWithFormat:@"%@ threaded", PSize(p)];
	if ([t isEqualToString:@"screwHole"]) return [NSString stringWithFormat:@"%@ screw", PSize(p)];
	if ([t isEqualToString:@"edgeHole"]) return PI_(p, @"edge") == 1 ? @"Chamfered" : @"Rounded";
	if ([t isEqualToString:@"roundedBox"]) return PI_(p, @"edge") == 1 ? @"Chamfered box" : PI_(p, @"edge") == 2 ? @"Box" : @"Rounded box";
	if ([t isEqualToString:@"roundedCylinder"]) return @"Rounded cylinder";
	if ([t isEqualToString:@"gear"]) return [NSString stringWithFormat:@"%d-tooth gear", PI_(p, @"teeth")];
	return [self titleForPartType:t];
}

// The part's mesh in mm (PDParts.c). 0 on success.
static int PDMakePart(NSString *t, NSDictionary *p, PDCSGMesh *m) {
	int edgeMap[3] = {PDEdgeFillet, PDEdgeChamfer, PDEdgeNone};
	#define EDGE(k) edgeMap[MAX(0, MIN(2, PI_(p, k)))]
	if ([t isEqualToString:@"bolt"]) return PDPartBolt(PI_(p, @"size"), (float)PV(p, @"length"), PI_(p, @"head"), PI_(p, @"threaded"), (float)PV(p, @"clearance"), m);
	if ([t isEqualToString:@"nut"]) {
		const PDMetric *mm = PDMetricSize(PI_(p, @"size"));
		if (!mm) return -1;
		float h = mm->nutH * (PI_(p, @"height") == 1 ? 0.6f : PI_(p, @"height") == 2 ? 1.5f : 1);
		return PDPartNut(PI_(p, @"size"), h, PI_(p, @"threaded"), (float)PV(p, @"clearance"), m);
	}
	if ([t isEqualToString:@"threadedHole"]) return PDPartThreadedHole(PI_(p, @"size"), (float)PV(p, @"depth"), (float)PV(p, @"clearance"), m);
	if ([t isEqualToString:@"screwHole"]) return PDPartScrewHole(PI_(p, @"size"), (float)PV(p, @"depth"), PI_(p, @"head"), m);
	if ([t isEqualToString:@"edgeHole"]) return PDPartEdgeHole((float)PV(p, @"diameter"), (float)PV(p, @"depth"), PI_(p, @"edge") == 1 ? PDEdgeChamfer : PDEdgeFillet, (float)PV(p, @"edgeSize"), PI_(p, @"bothEnds"), m);
	if ([t isEqualToString:@"roundedBox"]) return PDPartRoundedBox((float)PV(p, @"width"), (float)PV(p, @"depth"), (float)PV(p, @"height"), (float)PV(p, @"radius"), EDGE(@"edge"), m);
	if ([t isEqualToString:@"roundedCylinder"]) return PDPartRoundedCylinder((float)PV(p, @"diameter"), (float)PV(p, @"height"), EDGE(@"topEdge"), (float)PV(p, @"topSize"), EDGE(@"bottomEdge"), (float)PV(p, @"bottomSize"), m);
	if ([t isEqualToString:@"gear"]) return PDPartGear(PI_(p, @"teeth"), (float)PV(p, @"module"), (float)PV(p, @"thickness"), (float)PV(p, @"bore"), m);
	#undef EDGE
	return -1;
}

// Triangles in mm -> a unit mesh (its bounding box becomes [-0.5, 0.5]³); size gets the box's size. Takes the buffer.
static PDMeshData *PDUnitMesh(float *tris, int count, GLKVector3 *size) {
	GLKVector3 lo = GLKVector3Make(1e30f, 1e30f, 1e30f), hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	for (int i = 0; i < count * 3; i++) {
		GLKVector3 p = GLKVector3Make(tris[i * 3], tris[i * 3 + 1], tris[i * 3 + 2]);
		lo = GLKVector3Minimum(lo, p); hi = GLKVector3Maximum(hi, p);
	}
	GLKVector3 sz = GLKVector3Maximum(GLKVector3Subtract(hi, lo), GLKVector3Make(0.01f, 0.01f, 0.01f));
	GLKVector3 c = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	for (int i = 0; i < count * 3; i++) for (int k = 0; k < 3; k++) tris[i * 3 + k] = (tris[i * 3 + k] - c.v[k]) / sz.v[k];
	if (size) *size = sz;
	PDMeshData *md = [[PDMeshData alloc] init];
	md->tris = tris; md->count = count;
	return md;
}

+ (PDMeshData *)partMesh:(NSString *)t parameters:(NSDictionary *)p size:(GLKVector3 *)size {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 40; });
	NSMutableString *key = [NSMutableString stringWithString:t];
	for (NSString *k in [[p allKeys] sortedArrayUsingSelector:@selector(compare:)]) [key appendFormat:@"|%@=%@", k, [p objectForKey:k]];
	NSArray *hit = [cache objectForKey:key];
	if (hit) { if (size) [[hit objectAtIndex:1] getValue:size]; return [hit objectAtIndex:0]; }
	PDCSGMesh m = {0};
	if (PDMakePart(t, p, &m) != 0 || !m.count) { PDCSGFree(&m); return nil; }
	GLKVector3 sz;
	PDMeshData *md = PDUnitMesh(m.tris, m.count, &sz);
	[cache setObject:[NSArray arrayWithObjects:md, [NSValue valueWithBytes:&sz objCType:@encode(GLKVector3)], nil] forKey:key];
	if (size) *size = sz;
	return md;
}

+ (PDShape *)partOfType:(NSString *)t parameters:(NSDictionary *)p x:(float)x y:(float)y {
	GLKVector3 size;
	PDMeshData *m = [self partMesh:t parameters:p size:&size];
	if (!m) return nil;
	PDShape *s = [[PDShape alloc] init];
	s.kind = @"part";
	s.mesh = m;
	s.partType = t;
	s.parameters = p;
	s.hole = [self partTypeIsHole:t];
	s.color = 0x3B8FE0;
	s.matrix = GLKMatrix4Multiply(GLKMatrix4MakeTranslation(x, y, size.z / 2), GLKMatrix4MakeScale(size.x, size.y, size.z));
	return s;
}

- (PDShape *)withParameters:(NSDictionary *)p {
	if (!self.partType) return nil;
	GLKVector3 size;
	PDMeshData *m = [PDShape partMesh:self.partType parameters:p size:&size];
	if (!m) return nil;
	PDShape *s = [self copy];
	s.mesh = m;
	s.parameters = p;
	GLKMatrix4 o = self.matrix, n = o;
	for (int c = 0; c < 3; c++) {   // same turn (and mirroring), new size
		GLKVector3 col = GLKVector3Make(o.m[c * 4], o.m[c * 4 + 1], o.m[c * 4 + 2]);
		float l = GLKVector3Length(col);
		if (l > 0) col = GLKVector3MultiplyScalar(col, size.v[c] / l);
		n.m[c * 4] = col.x; n.m[c * 4 + 1] = col.y; n.m[c * 4 + 2] = col.z;
	}
	s.matrix = n;
	float dz = [self worldMin].z - [s worldMin].z;   // same bottom
	n.m[14] += dz;
	s.matrix = n;
	return s;
}

#pragma mark Shape options

+ (BOOL)kindHasOptions:(NSString *)kind {
	return [[NSArray arrayWithObjects:@"box", @"cylinder", @"cone", @"tube", @"pyramid", @"sphere", @"dome", @"torus", nil] containsObject:kind];
}

static NSArray *PDSideChoices(BOOL smooth) {
	NSArray *a = [NSArray arrayWithObjects:@"3", @"4", @"5", @"6", @"8", @"12", @"16", nil];
	return smooth ? [[NSArray arrayWithObject:@"Smooth"] arrayByAddingObjectsFromArray:a] : a;
}
static int PDSidesFor(NSDictionary *p, NSString *k, BOOL smooth) {   // a choice index -> sides (0: smooth)
	static const int v[8] = {0, 3, 4, 5, 6, 8, 12, 16};
	int i = PI_(p, k) + (smooth ? 0 : 1);
	return v[MAX(smooth ? 0 : 1, MIN(7, i))];
}
static const int PDSmoothSegments[4] = {24, 48, 72, 96};

+ (NSArray *)optionSpecForKind:(NSString *)k {
	NSArray *edges = [NSArray arrayWithObjects:@"None", @"Fillet", @"Chamfer", nil];
	if ([k isEqualToString:@"box"]) return [NSArray arrayWithObjects:PDChoice(@"edge", @"Edges", edges), PDNum(@"radius", @"Size", 0.2, 100, 0.5, @"mm"),
		PDChoice(@"which", @"Which", [NSArray arrayWithObjects:@"All", @"Not bottom", @"Upright", nil]), nil];
	if ([k isEqualToString:@"cylinder"]) return [NSArray arrayWithObjects:PDChoice(@"sides", @"Sides", PDSideChoices(YES)),
		PDChoice(@"topEdge", @"Top edge", edges), PDNum(@"topSize", @"Top size", 0.2, 100, 0.5, @"mm"),
		PDChoice(@"bottomEdge", @"Bottom edge", edges), PDNum(@"bottomSize", @"Bottom size", 0.2, 100, 0.5, @"mm"), nil];
	if ([k isEqualToString:@"cone"]) return [NSArray arrayWithObjects:PDChoice(@"sides", @"Sides", PDSideChoices(YES)),
		PDNum(@"top", @"Top Ø", 0, 256, 1, @"mm"), nil];
	if ([k isEqualToString:@"tube"]) return [NSArray arrayWithObjects:PDNum(@"wall", @"Wall", 0.4, 128, 0.5, @"mm"), PDChoice(@"sides", @"Sides", PDSideChoices(YES)),
		PDChoice(@"edge", @"Rim edges", edges), PDNum(@"edgeSize", @"Rim size", 0.2, 50, 0.2, @"mm"), PDSwitch(@"bothEnds", @"Both ends"), nil];
	if ([k isEqualToString:@"pyramid"]) return [NSArray arrayWithObjects:PDChoice(@"sides", @"Sides", PDSideChoices(NO)), nil];
	NSArray *smooth = [NSArray arrayWithObjects:@"Low", @"Medium", @"High", @"Finest", nil];
	if ([k isEqualToString:@"sphere"] || [k isEqualToString:@"dome"]) return [NSArray arrayWithObjects:PDChoice(@"smooth", @"Smoothness", smooth), nil];
	if ([k isEqualToString:@"torus"]) return [NSArray arrayWithObjects:PDNum(@"tube", @"Tube Ø", 0.5, 200, 0.5, @"mm"), PDChoice(@"sides", @"Sides", PDSideChoices(YES)),
		PDChoice(@"smooth", @"Tube", smooth), nil];
	return [NSArray array];
}

+ (NSDictionary *)stockOptionsForKind:(NSString *)k {
	// as the plain primitive stands (so changing one option changes only that)
	if ([k isEqualToString:@"box"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(0), @"edge", N(2), @"radius", N(0), @"which", nil];
	if ([k isEqualToString:@"cylinder"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(0), @"sides", N(0), @"topEdge", N(2), @"topSize", N(0), @"bottomEdge", N(1), @"bottomSize", nil];
	if ([k isEqualToString:@"cone"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(0), @"sides", N(0), @"top", nil];
	if ([k isEqualToString:@"tube"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(2), @"wall", N(0), @"sides", N(0), @"edge", N(0.6), @"edgeSize", N(0), @"bothEnds", nil];
	if ([k isEqualToString:@"pyramid"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(1), @"sides", nil];
	if ([k isEqualToString:@"sphere"] || [k isEqualToString:@"dome"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(1), @"smooth", nil];
	if ([k isEqualToString:@"torus"]) return [NSDictionary dictionaryWithObjectsAndKeys:N(5), @"tube", N(0), @"sides", N(1), @"smooth", nil];
	return [NSDictionary dictionary];
}

+ (NSString *)describeOptions:(NSDictionary *)p kind:(NSString *)k {
	NSString *(^edge)(NSString *, NSString *, NSString *) = ^NSString *(NSString *ek, NSString *sk, NSString *where) {
		int e = PI_(p, ek);
		return e == 0 ? [NSString stringWithFormat:@"sharp %@", where] : [NSString stringWithFormat:@"%g mm %@ %@", PV(p, sk), e == 1 ? @"fillet" : @"chamfer", where];
	};
	NSString *(^sides)(BOOL) = ^NSString *(BOOL smooth) { int n = PDSidesFor(p, @"sides", smooth); return n ? [NSString stringWithFormat:@"%d sides", n] : @"round"; };
	if ([k isEqualToString:@"box"]) return edge(@"edge", @"radius", [[NSArray arrayWithObjects:@"on every edge", @"on all but the bottom edges", @"on the upright edges", nil] objectAtIndex:(NSUInteger)MAX(0, MIN(2, PI_(p, @"which")))]);
	if ([k isEqualToString:@"cylinder"]) return [NSString stringWithFormat:@"%@: %@, %@", [sides(YES) capitalizedString], edge(@"topEdge", @"topSize", @"top"), edge(@"bottomEdge", @"bottomSize", @"bottom")];
	if ([k isEqualToString:@"cone"]) return [NSString stringWithFormat:@"%@, %@", [sides(YES) capitalizedString], PV(p, @"top") > 0 ? [NSString stringWithFormat:@"Ø%g mm flat top", PV(p, @"top")] : @"pointed"];
	if ([k isEqualToString:@"tube"]) return [NSString stringWithFormat:@"%g mm wall, %@, %@", PV(p, @"wall"), sides(YES), edge(@"edge", @"edgeSize", PI_(p, @"bothEnds") ? @"rims" : @"top rim")];
	if ([k isEqualToString:@"pyramid"]) return [NSString stringWithFormat:@"%d-sided base", PDSidesFor(p, @"sides", NO)];
	if ([k isEqualToString:@"sphere"] || [k isEqualToString:@"dome"]) return [NSString stringWithFormat:@"%d segments round", PDSmoothSegments[MAX(0, MIN(3, PI_(p, @"smooth")))]];
	if ([k isEqualToString:@"torus"]) return [NSString stringWithFormat:@"Ø%g mm tube, %@", PV(p, @"tube"), sides(YES)];
	return [self titleForKind:k];
}

// The shape in mm at options' w × d × h. 0 on success.
static int PDMakeShape(NSString *k, NSDictionary *p, PDCSGMesh *m) {
	float w = (float)PV(p, @"w"), d = (float)PV(p, @"d"), h = (float)PV(p, @"h"), dia = MIN(w, d);
	int seg = PDSmoothSegments[MAX(0, MIN(3, PI_(p, @"smooth")))];
	if (w <= 0 || d <= 0 || h <= 0) return -1;
	if ([k isEqualToString:@"box"]) return PDShapeBox(w, d, h, PI_(p, @"edge"), (float)PV(p, @"radius"), PI_(p, @"which"), m);
	if ([k isEqualToString:@"cylinder"]) return PDShapeCylinder(dia, h, PDSidesFor(p, @"sides", YES), PI_(p, @"topEdge"), (float)PV(p, @"topSize"), PI_(p, @"bottomEdge"), (float)PV(p, @"bottomSize"), m);
	if ([k isEqualToString:@"cone"]) return PDShapeCone(dia, (float)PV(p, @"top"), h, PDSidesFor(p, @"sides", YES), m);
	if ([k isEqualToString:@"tube"]) return PDShapeTube(dia, h, (float)PV(p, @"wall"), PDSidesFor(p, @"sides", YES), PI_(p, @"edge"), (float)PV(p, @"edgeSize"), PI_(p, @"bothEnds"), m);
	if ([k isEqualToString:@"pyramid"]) return PDShapePyramid(dia, h, PDSidesFor(p, @"sides", NO), m);
	if ([k isEqualToString:@"sphere"] || [k isEqualToString:@"dome"]) return PDShapeSphere(dia, seg, [k isEqualToString:@"dome"], m);
	if ([k isEqualToString:@"torus"]) return PDShapeTorus(dia, (float)PV(p, @"tube"), PDSidesFor(p, @"sides", YES), seg / 3, m);
	return -1;
}

+ (PDMeshData *)optionMesh:(NSString *)kind options:(NSDictionary *)p {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 60; });
	NSMutableString *key = [NSMutableString stringWithString:kind];
	for (NSString *k in [[p allKeys] sortedArrayUsingSelector:@selector(compare:)]) [key appendFormat:@"|%@=%@", k, [p objectForKey:k]];
	PDMeshData *md = [cache objectForKey:key];
	if (md) return md;
	PDCSGMesh m = {0};
	if (PDMakeShape(kind, p, &m) != 0 || !m.count) { PDCSGFree(&m); return nil; }
	md = PDUnitMesh(m.tris, m.count, NULL);
	[cache setObject:md forKey:key];
	return md;
}

- (NSDictionary *)editableOptions {
	if (self.options) return self.options;
	NSMutableDictionary *d = [[PDShape stockOptionsForKind:self.kind] mutableCopy];
	GLKVector3 sz = [self axisLengths];
	if ([self.kind isEqualToString:@"torus"]) [d setObject:N(round(sz.z * 2) / 2) forKey:@"tube"];   // as it stands
	if ([self.kind isEqualToString:@"tube"]) [d setObject:N(MAX(0.5, round(MIN(sz.x, sz.y) * 0.2 * 2) / 2)) forKey:@"wall"];   // the plain tube's wall
	return d;
}

// o at this shape's size (mm, rounded so tiny drags don't each make a mesh).
- (NSDictionary *)options:(NSDictionary *)o atSize:(GLKVector3)sz {
	NSMutableDictionary *d = [o mutableCopy];
	[d setObject:N(round(sz.x * 100) / 100) forKey:@"w"];
	[d setObject:N(round(sz.y * 100) / 100) forKey:@"d"];
	[d setObject:N(round(sz.z * 100) / 100) forKey:@"h"];
	return d;
}

- (PDShape *)withOptions:(NSDictionary *)o {
	if (![PDShape kindHasOptions:self.kind]) return nil;
	GLKVector3 sz = [self axisLengths];
	BOOL torusHeight = [self.kind isEqualToString:@"torus"] && PV(o, @"tube") > 0;
	if (torusHeight) sz.z = (float)MIN(PV(o, @"tube"), MIN(sz.x, sz.y) * 0.98);
	NSDictionary *full = [self options:o atSize:sz];
	PDMeshData *m = [PDShape optionMesh:self.kind options:full];
	if (!m) return nil;
	PDShape *s = [self copy];
	s.mesh = m;
	s.options = full;
	if (torusHeight) {   // the tube's thickness is the torus's height; same bottom
		GLKMatrix4 n = s.matrix;
		float l = GLKVector3Length(GLKVector3Make(n.m[8], n.m[9], n.m[10]));
		if (l > 0) for (int k = 0; k < 3; k++) n.m[8 + k] *= sz.z / l;
		s.matrix = n;
		n.m[14] += [self worldMin].z - [s worldMin].z;
		s.matrix = n;
	}
	return s;
}

- (BOOL)remakeOptionsMesh {
	if (!self.options) return YES;
	NSDictionary *full = [self options:self.options atSize:[self axisLengths]];
	PDMeshData *m = [PDShape optionMesh:self.kind options:full];
	if (!m) return NO;
	self.mesh = m;
	self.options = full;
	_boundsValid = NO;
	return YES;
}

#pragma mark Imported models

+ (NSString *)meshDirectory {
	NSString *d = [[PDDesign directory] stringByAppendingPathComponent:@"Meshes"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}

+ (NSMutableDictionary *)meshCache {
	static NSMutableDictionary *c;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ c = [NSMutableDictionary dictionary]; });
	return c;
}

+ (PDMeshData *)storedMesh:(NSString *)mid {
	NSMutableDictionary *cache = [self meshCache];
	@synchronized (cache) {
		PDMeshData *m = [cache objectForKey:mid];
		if (m) return m;
		NSData *d = [NSData dataWithContentsOfFile:[[self meshDirectory] stringByAppendingPathComponent:[mid stringByAppendingPathExtension:@"mesh"]]];
		if ([d length] < 4) return nil;
		uint32_t n;
		[d getBytes:&n length:4];
		if (!n || [d length] < 4 + (NSUInteger)n * 36) return nil;
		float *t = malloc((size_t)n * 36);
		if (!t) return nil;
		[d getBytes:t range:NSMakeRange(4, (NSUInteger)n * 36)];
		m = [[PDMeshData alloc] init];
		m->tris = t; m->count = (int)n;
		[cache setObject:m forKey:mid];
		return m;
	}
}

+ (PDShape *)shapeFromTriangles:(const float *)tris count:(int)count name:(NSString *)name x:(float)x y:(float)y error:(NSString **)error {
	if (count <= 0 || !tris) { if (error) *error = @"The model has no triangles."; return nil; }
	float *t = malloc((size_t)count * 36);
	if (!t) { if (error) *error = @"Not enough memory for the model."; return nil; }
	memcpy(t, tris, (size_t)count * 36);
	GLKVector3 size;
	PDMeshData *md = PDUnitMesh(t, count, &size);
	CFUUIDRef u = CFUUIDCreate(NULL);
	NSString *mid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, u);
	CFRelease(u);
	NSMutableData *d = [NSMutableData dataWithCapacity:4 + (NSUInteger)count * 36];
	uint32_t n = (uint32_t)count;
	[d appendBytes:&n length:4];
	[d appendBytes:md->tris length:(NSUInteger)count * 36];
	if (![d writeToFile:[[self meshDirectory] stringByAppendingPathComponent:[mid stringByAppendingPathExtension:@"mesh"]] atomically:YES]) {
		if (error) *error = @"Couldn't store the model.";
		return nil;
	}
	@synchronized ([self meshCache]) { [[self meshCache] setObject:md forKey:mid]; }
	PDShape *s = [[PDShape alloc] init];
	s.kind = @"mesh";
	s.mesh = md;
	s.meshId = mid;
	s.meshName = [name length] ? name : @"Model";
	s.color = 0x3B8FE0;
	s.matrix = GLKMatrix4Multiply(GLKMatrix4MakeTranslation(x, y, size.z / 2), GLKMatrix4MakeScale(size.x, size.y, size.z));
	return s;
}

// A minimal OBJ reader: v lines and f lines (polygons fanned; "v/vt/vn" and negative indexes allowed).
static float *PDReadOBJ(NSString *path, int *count, NSString **error) {
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data) { *error = @"Couldn't read the file."; return NULL; }
	const char *p = [data bytes], *end = p + [data length];
	int nv = 0, cv = 1024, nt = 0, ct = 1024;
	float *v = malloc((size_t)cv * 12), *t = malloc((size_t)ct * 36);
	if (!v || !t) { free(v); free(t); *error = @"Not enough memory."; return NULL; }
	while (p < end) {
		const char *eol = p;
		while (eol < end && *eol != '\n' && *eol != '\r') eol++;
		size_t len = (size_t)(eol - p);
		if (len > 2 && p[0] == 'v' && p[1] == ' ') {
			char buf[256]; size_t l = len < 255 ? len : 255; memcpy(buf, p, l); buf[l] = 0;
			float x, y, z;
			if (sscanf(buf + 2, "%f %f %f", &x, &y, &z) == 3) {
				if (nv == cv) { cv *= 2; float *nvp = realloc(v, (size_t)cv * 12); if (!nvp) break; v = nvp; }
				v[nv * 3] = x; v[nv * 3 + 1] = y; v[nv * 3 + 2] = z; nv++;
			}
		} else if (len > 2 && p[0] == 'f' && p[1] == ' ') {
			int idx[64], ni = 0;
			const char *q = p + 2;
			while (q < eol && ni < 64) {
				while (q < eol && (*q == ' ' || *q == '\t')) q++;
				if (q >= eol) break;
				int k = (int)strtol(q, NULL, 10);
				if (k < 0) k = nv + k + 1;
				idx[ni++] = k - 1;
				while (q < eol && *q != ' ' && *q != '\t') q++;
			}
			for (int i = 1; i + 1 < ni; i++) {
				int a = idx[0], b = idx[i], c = idx[i + 1];
				if (a < 0 || b < 0 || c < 0 || a >= nv || b >= nv || c >= nv) continue;
				if (nt == ct) { ct *= 2; float *ntp = realloc(t, (size_t)ct * 36); if (!ntp) break; t = ntp; }
				memcpy(t + nt * 9, v + a * 3, 12); memcpy(t + nt * 9 + 3, v + b * 3, 12); memcpy(t + nt * 9 + 6, v + c * 3, 12);
				nt++;
			}
		}
		p = eol + 1;
	}
	free(v);
	if (!nt) { free(t); *error = @"No faces found in the OBJ file."; return NULL; }
	*count = nt;
	return t;
}

+ (PDShape *)shapeFromModelFile:(NSString *)path x:(float)x y:(float)y error:(NSString **)error {
	NSString *err = nil, *name = [[path lastPathComponent] stringByDeletingPathExtension];
	PDShape *s = nil;
	if ([[[path pathExtension] lowercaseString] isEqualToString:@"obj"]) {
		int n = 0;
		float *t = PDReadOBJ(path, &n, &err);
		if (t && n > 400000) err = [NSString stringWithFormat:@"The model has %d triangles; the Design page takes up to 400,000.", n];
		else if (t) s = [self shapeFromTriangles:t count:n name:name x:x y:y error:&err];
		free(t);
	} else {
		PDModel *m = [PDModel loadFile:path error:&err];
		if (m) s = [self shapeFromTriangles:m.triangles count:(int)m.triangleCount name:name x:x y:y error:&err];
	}
	if (!s && error) *error = err ?: @"Couldn't read the model.";
	return s;
}

static BOOL PDWriteBinarySTL(NSString *path, const float *tris, int count) {
	NSMutableData *d = [NSMutableData dataWithLength:80];
	uint32_t n = (uint32_t)count;
	[d appendBytes:&n length:4];
	for (int i = 0; i < count; i++) {
		const float *t = tris + i * 9;
		GLKVector3 a = GLKVector3Make(t[0], t[1], t[2]), b = GLKVector3Make(t[3], t[4], t[5]), c = GLKVector3Make(t[6], t[7], t[8]);
		GLKVector3 nr = GLKVector3CrossProduct(GLKVector3Subtract(b, a), GLKVector3Subtract(c, a));
		float l = GLKVector3Length(nr);
		nr = l > 0 ? GLKVector3DivideScalar(nr, l) : GLKVector3Make(0, 0, 1);
		[d appendBytes:nr.v length:12];
		[d appendBytes:t length:36];
		uint16_t attr = 0;
		[d appendBytes:&attr length:2];
	}
	return [d writeToFile:path atomically:YES];
}

- (BOOL)writeSTL:(NSString *)path {
	int n = 0;
	float *t = [self newWorldTriangles:&n];
	if (!t) return NO;
	// stand it on z = 0
	float lo = 1e30f;
	for (int i = 0; i < n * 3; i++) lo = MIN(lo, t[i * 3 + 2]);
	for (int i = 0; i < n * 3; i++) t[i * 3 + 2] -= lo;
	BOOL ok = PDWriteBinarySTL(path, t, n);
	free(t);
	return ok;
}

@end

#pragma mark - Library

@implementation PDLibrary

+ (NSString *)directory {
	NSString *d = [[PDSlicer libraryDirectory] stringByAppendingPathComponent:@"Library"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}

+ (NSArray *)modelFilesIn:(NSString *)dir {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray *items = [NSMutableArray array];
	for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
		NSString *ext = [[f pathExtension] lowercaseString];
		if (![ext isEqualToString:@"stl"] && ![ext isEqualToString:@"obj"]) continue;
		NSString *p = [dir stringByAppendingPathComponent:f];
		NSDate *d = [[fm attributesOfItemAtPath:p error:NULL] fileModificationDate] ?: [NSDate distantPast];
		[items addObject:[NSArray arrayWithObjects:d, p, nil]];
	}
	[items sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [[b objectAtIndex:0] compare:[a objectAtIndex:0]]; }];
	NSMutableArray *paths = [NSMutableArray array];
	for (NSArray *i in items) [paths addObject:[i objectAtIndex:1]];
	return paths;
}

+ (NSArray *)savedParts { return [self modelFilesIn:[self directory]]; }
+ (NSArray *)models { return [self modelFilesIn:[PDSlicer libraryDirectory]]; }

+ (NSString *)unusedPathFor:(NSString *)name {
	NSString *safe = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
	if (![safe length]) safe = @"Part";
	NSString *dir = [self directory], *p = [dir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"stl"]];
	for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:p]; i++)
		p = [dir stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %d", safe, i] stringByAppendingPathExtension:@"stl"]];
	return p;
}

@end

#pragma mark - Design

@implementation PDDesign

+ (NSString *)directory {
	NSString *d = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0]
		stringByAppendingPathComponent:@"PrintDeck/Designs"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}

+ (NSString *)fileFor:(NSString *)name {
	NSString *safe = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
	return [[self directory] stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"pddesign"]];
}

+ (NSArray *)savedNames {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [self directory];
	NSMutableArray *items = [NSMutableArray array];
	for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
		if (![[f pathExtension] isEqualToString:@"pddesign"]) continue;
		NSDate *d = [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:NULL] fileModificationDate] ?: [NSDate distantPast];
		[items addObject:[NSArray arrayWithObjects:d, [f stringByDeletingPathExtension], nil]];
	}
	[items sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [[b objectAtIndex:0] compare:[a objectAtIndex:0]]; }];
	NSMutableArray *names = [NSMutableArray array];
	for (NSArray *i in items) [names addObject:[i objectAtIndex:1]];
	return names;
}

+ (PDDesign *)loadNamed:(NSString *)name {
	NSData *data = [NSData dataWithContentsOfFile:[self fileFor:name]];
	NSDictionary *d = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
	if (![d isKindOfClass:[NSDictionary class]]) return nil;
	PDDesign *g = [[PDDesign alloc] init];
	g.name = name;
	NSMutableArray *shapes = [NSMutableArray array];
	for (NSDictionary *s in [d objectForKey:@"shapes"]) { PDShape *sh = [PDShape shapeFromPlist:s]; if (sh) [shapes addObject:sh]; }
	g.shapes = shapes;
	return g;
}

+ (BOOL)deleteNamed:(NSString *)name { return [[NSFileManager defaultManager] removeItemAtPath:[self fileFor:name] error:NULL]; }

+ (NSString *)unusedName:(NSString *)base {
	NSArray *names = [self savedNames];
	if (![names containsObject:base] && ![base hasPrefix:@"Design"]) return base;
	for (int i = 1; ; i++) {
		NSString *n = [NSString stringWithFormat:@"%@ %d", base, i];
		if (![names containsObject:n]) return n;
	}
}

+ (BOOL)renameDesign:(NSString *)from to:(NSString *)to {
	if ([from isEqualToString:to]) return YES;
	if ([[NSFileManager defaultManager] fileExistsAtPath:[self fileFor:to]]) return NO;
	return [[NSFileManager defaultManager] moveItemAtPath:[self fileFor:from] toPath:[self fileFor:to] error:NULL];
}

- (BOOL)save {
	NSMutableArray *a = [NSMutableArray array];
	for (PDShape *s in self.shapes) [a addObject:[s plist]];
	NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1], @"version", a, @"shapes", nil];
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
	return data && [data writeToFile:[PDDesign fileFor:self.name] atomically:YES];
}

- (NSString *)exportSTL:(NSString **)error looseHoles:(int *)looseHoles {
	NSMutableArray *solids = [NSMutableArray array];
	int holes = 0;
	for (PDShape *s in self.shapes) { if (s.hole) holes++; else [solids addObject:s]; }
	if (looseHoles) *looseHoles = holes;
	if (![solids count]) { if (error) *error = @"There are no solid shapes to slice."; return nil; }
	PDCSGMesh m = {0};
	if ([solids count] == 1) m.tris = [[solids objectAtIndex:0] newWorldTriangles:&m.count];
	else if (![PDShape combine:solids into:&m hole:NULL]) { if (error) *error = @"Couldn't combine the shapes."; return nil; }
	if (!m.tris || !m.count) { free(m.tris); if (error) *error = @"The design is empty."; return nil; }
	NSString *safe = [[self.name stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
	NSString *path = [[PDSlicer libraryDirectory] stringByAppendingPathComponent:[safe stringByAppendingString:@" (design).stl"]];
	BOOL wrote = PDWriteBinarySTL(path, m.tris, m.count);
	free(m.tris);
	if (!wrote) { if (error) *error = @"Couldn't write the STL file."; return nil; }
	return path;
}

@end
