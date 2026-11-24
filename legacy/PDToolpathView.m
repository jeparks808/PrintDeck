#import "PDToolpathView.h"
#import "PDToolpath.h"
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/gl.h>
#import "PDBedShape.h"

static const GLfloat PDBedSize = 256.0f;  // mm, Centauri Carbon build plate

// aPos.w carries the segment's PDLineType (low 4 bits) and filament/tool (high 4 bits). uMode 0: uLo→uHi by height;
// 1: the line type's colour (uTypes); 2: the tool's own uToolLo→uToolHi (a multi-colour file). Each stays darker
// toward the bed, so the height cue stays.
static const char *PDVS =
	"attribute vec4 aPos;\n"
	"uniform mat4 uMVP;\n"
	"uniform vec4 uLo, uHi;\n"
	"uniform vec4 uTypes[12];\n"
	"uniform vec4 uToolLo[8], uToolHi[8];\n"
	"uniform float uMode;\n"
	"uniform float uInvZ, uFogA, uFogB;\n"
	"varying lowp vec4 vColor;\n"
	"void main() {\n"
	"  vec4 p = uMVP * vec4(aPos.xyz, 1.0);\n"
	"  gl_Position = p;\n"
	"  float t = clamp(aPos.z * uInvZ, 0.0, 1.0);\n"
	"  float fog = clamp(p.w * uFogA + uFogB, 0.4, 1.0);\n"
	"  vec4 c = mix(uLo, uHi, t);\n"
	"  float tool = floor((aPos.w + 0.5) / 16.0);\n"
	"  if (uMode > 1.5) { int k = int(min(tool, 7.0) + 0.5); float st = min(floor(t * 10.0), 9.0) / 9.0;\n"
	"    c = mix(uToolLo[k], uToolHi[k], mix(t, st, 0.75)); }\n"
	"  else if (uMode > 0.5) { int i = int(aPos.w - tool * 16.0 + 0.5); c = vec4(uTypes[i].rgb * (0.62 + 0.38 * t), c.a); }\n"
	"  vColor = vec4(c.rgb * fog, c.a);\n"
	"}\n";

static const char *PDFS =
	"varying lowp vec4 vColor;\n"
	"void main() { gl_FragColor = vColor; }\n";

// The radius of a sphere around the whole plate (and a part zt mm tall on it).
static float PDPlateRadius(float zt) { return 0.5f * sqrtf(262.0f * 262.0f + 278.0f * 278.0f + zt * zt); }

@interface PDToolpathView () <GLKViewDelegate> {
	GLuint _prog, _vbo, _bedVbo;
	GLint _uMVP, _uLo, _uHi, _uInvZ, _uFogA, _uFogB, _uTypes, _uMode, _uToolLo, _uToolHi;
	GLsizei _bedVerts, _plateVerts, _gridVerts, _areaVerts;   // in the bed VBO, in that order, then the plate edge
	NSUInteger _uploadedSegs;
	BOOL _needsUpload;
}
@property (nonatomic, strong) EAGLContext *ctx;
@property (nonatomic, strong) GLKView *glView;
@property (nonatomic) float azimuth, elevation, zoom, minZoom;
@end

@implementation PDToolpathView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		_currentLayer = -1;
		_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
		_glView = [[GLKView alloc] initWithFrame:self.bounds context:_ctx];
		_glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_glView.delegate = self;
		_glView.enableSetNeedsDisplay = YES;
		_glView.drawableDepthFormat = GLKViewDrawableDepthFormat16;
		_glView.drawableMultisample = GLKViewDrawableMultisample4X;
		_glView.opaque = YES;
		[self addSubview:_glView];
		[self setupGL];
		[self resetView];
		[self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
		[self addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
		UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap)];
		dt.numberOfTapsRequired = 2;
		[self addGestureRecognizer:dt];
	}
	return self;
}

- (void)dealloc {
	[EAGLContext setCurrentContext:_ctx];
	if (_vbo) glDeleteBuffers(1, &_vbo);
	if (_bedVbo) glDeleteBuffers(1, &_bedVbo);
	if (_prog) glDeleteProgram(_prog);
	[EAGLContext setCurrentContext:nil];
}

static GLuint PDCompile(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log);
		NSLog(@"PrintDeck: shader compile failed: %s", log);
	}
	return s;
}

- (void)setupGL {
	[EAGLContext setCurrentContext:self.ctx];
	GLuint vs = PDCompile(GL_VERTEX_SHADER, PDVS), fs = PDCompile(GL_FRAGMENT_SHADER, PDFS);
	_prog = glCreateProgram();
	glAttachShader(_prog, vs); glAttachShader(_prog, fs);
	glBindAttribLocation(_prog, 0, "aPos");
	glLinkProgram(_prog);
	glDeleteShader(vs); glDeleteShader(fs);
	_uMVP = glGetUniformLocation(_prog, "uMVP");
	_uLo = glGetUniformLocation(_prog, "uLo");
	_uHi = glGetUniformLocation(_prog, "uHi");
	_uInvZ = glGetUniformLocation(_prog, "uInvZ");
	_uFogA = glGetUniformLocation(_prog, "uFogA");
	_uFogB = glGetUniformLocation(_prog, "uFogB");
	_uTypes = glGetUniformLocation(_prog, "uTypes");
	_uMode = glGetUniformLocation(_prog, "uMode");
	_uToolLo = glGetUniformLocation(_prog, "uToolLo");
	_uToolHi = glGetUniformLocation(_prog, "uToolHi");

	// Bed: the physical plate (PDBedShape.h, triangles just under z = 0), the grid every 32 mm and the outline of the
	// printable 0-256 mm area, then the plate's own edge (int16, 0.01 mm, xyz + pad).
	int cap = PDBedTriCount * 3 + 2 * 18 + 8 + PDBedEdgeCount * 2;
	int16_t *bed = malloc((size_t)cap * 4 * sizeof(int16_t));
	int n = 0;
	#define PDV(X, Y, Z) do { bed[n * 4] = (int16_t)lrintf((X) * 100); bed[n * 4 + 1] = (int16_t)lrintf((Y) * 100); bed[n * 4 + 2] = (Z); bed[n * 4 + 3] = 0; n++; } while (0)
	for (int i = 0; i < PDBedTriCount * 3; i++) PDV(PDBedTris[i * 2], PDBedTris[i * 2 + 1], -3);
	_plateVerts = n;
	for (int i = 1; i < 8; i++) { float c = i * 32.0f; PDV(c, 0, 0); PDV(c, PDBedSize, 0); PDV(0, c, 0); PDV(PDBedSize, c, 0); }
	_gridVerts = n - _plateVerts;
	float area[5][2] = {{0, 0}, {PDBedSize, 0}, {PDBedSize, PDBedSize}, {0, PDBedSize}, {0, 0}};
	for (int k = 0; k < 4; k++) { PDV(area[k][0], area[k][1], 0); PDV(area[k + 1][0], area[k + 1][1], 0); }
	_areaVerts = 8;
	for (int i = 0; i < PDBedEdgeCount; i++) { PDV(PDBedOutline[i * 4], PDBedOutline[i * 4 + 1], -1); PDV(PDBedOutline[i * 4 + 2], PDBedOutline[i * 4 + 3], -1); }
	#undef PDV
	_bedVerts = n;
	glGenBuffers(1, &_bedVbo);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 4 * sizeof(int16_t), bed, GL_STATIC_DRAW);
	free(bed);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
}

- (void)setToolpath:(PDToolpath *)t {
	if (t == _toolpath) return;
	_toolpath = t;
	_needsUpload = YES;
	[self resetView];
}

- (void)setDoneLayers:(NSInteger)d { if (d != _doneLayers) { _doneLayers = d; [self redraw]; } }
- (void)setCurrentLayer:(NSInteger)c { if (c != _currentLayer) { _currentLayer = c; [self redraw]; } }

// Segments -> GL_LINES vertices of 4 int16 (x, y, z, 1): 8-byte aligned, which the SGX prefers over 6.
- (void)upload {
	_needsUpload = NO;
	PDToolpath *t = self.toolpath;
	if (!_vbo) glGenBuffers(1, &_vbo);
	glBindBuffer(GL_ARRAY_BUFFER, _vbo);
	NSUInteger ns = t.segmentCount;
	if (!ns) { glBufferData(GL_ARRAY_BUFFER, 0, NULL, GL_STATIC_DRAW); _uploadedSegs = 0; glBindBuffer(GL_ARRAY_BUFFER, 0); return; }
	int16_t *v = malloc(ns * 8 * sizeof(int16_t));
	const int16_t *s = t.segments;
	const uint8_t *types = t.lineTypes;
	for (NSUInteger i = 0; i < ns; i++, s += 6) {
		int16_t *o = v + i * 8;
		int16_t ty = types ? types[i] : 0;
		o[0] = s[0]; o[1] = s[1]; o[2] = s[2]; o[3] = ty;
		o[4] = s[3]; o[5] = s[4]; o[6] = s[5]; o[7] = ty;
	}
	glBufferData(GL_ARRAY_BUFFER, ns * 8 * sizeof(int16_t), v, GL_STATIC_DRAW);
	free(v);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	_uploadedSegs = ns;
}

- (void)resetView { self.azimuth = -0.55f; self.elevation = 0.55f; self.zoom = 1.0f; [self redraw]; }

- (void)redraw {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;  // no GL in the background
	[self.glView setNeedsDisplay];
}

- (void)pan:(UIPanGestureRecognizer *)g {
	CGPoint t = [g translationInView:self];
	[g setTranslation:CGPointZero inView:self];
	self.azimuth -= t.x * 0.010f;
	self.elevation = MAX(-0.2f, MIN(1.50f, self.elevation + t.y * 0.008f));
	if (self.interacted) self.interacted();
	[self redraw];
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
	self.zoom = MAX(self.minZoom, MIN(12.0f, self.zoom * g.scale));
	g.scale = 1.0;
	if (self.interacted) self.interacted();
	[self redraw];
}

- (void)doubleTap { [self resetView]; if (self.interacted) self.interacted(); }

- (void)benchmark:(double)secs done:(void (^)(double fps))done {
	CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
	int frames = 0;
	while (CFAbsoluteTimeGetCurrent() - t0 < secs) {
		self.azimuth += 0.03f;
		[self.glView display];   // synchronous draw + present
		frames++;
	}
	double fps = frames / (CFAbsoluteTimeGetCurrent() - t0);
	if (done) done(fps);
}

// OrcaSlicer's line-type legend colours, indexed by PDLineType.
static const float PDTypeRGB[PDLineTypeCount][3] = {
	{0.55f, 0.55f, 0.55f},   // other
	{1.00f, 0.90f, 0.30f},   // outer wall
	{1.00f, 0.55f, 0.15f},   // inner wall
	{0.10f, 0.40f, 1.00f},   // overhang wall
	{0.70f, 0.18f, 0.18f},   // sparse infill
	{0.59f, 0.33f, 0.80f},   // internal solid infill
	{0.94f, 0.25f, 0.25f},   // top surface
	{0.30f, 0.50f, 0.73f},   // bridge
	{1.00f, 1.00f, 1.00f},   // gap infill
	{0.00f, 0.53f, 0.43f},   // skirt / brim
	{0.00f, 1.00f, 0.00f},   // support
	{0.12f, 0.38f, 0.10f},   // support interface
};

+ (UIColor *)colorForLineType:(PDLineType)t {
	if ((int)t < 0 || t >= PDLineTypeCount) t = PDLineOther;
	return [UIColor colorWithRed:PDTypeRGB[t][0] green:PDTypeRGB[t][1] blue:PDTypeRGB[t][2] alpha:1];
}
+ (NSString *)nameForLineType:(PDLineType)t {
	static NSString *const names[PDLineTypeCount] = {@"Other", @"Outer wall", @"Inner wall", @"Overhang wall", @"Sparse infill",
		@"Internal solid infill", @"Top surface", @"Bridge", @"Gap infill", @"Skirt / brim", @"Support", @"Support interface"};
	return ((int)t >= 0 && t < PDLineTypeCount) ? names[t] : names[0];
}

- (void)setColorScheme:(PDToolpathColorScheme)c { if (c != _colorScheme) { _colorScheme = c; [self redraw]; } }
- (void)setFilamentColor:(UIColor *)c { _filamentColor = c; [self redraw]; }

// The printed layers' colours for the current scheme. Filament: the filament's real colour, darker at the bed
// and a little lighter at the top (dark filaments are lifted so they stay visible on the dark background).
// A filament's colour graded by height: darker at the bed, lighter at the top (dark filaments are lifted so
// they stay visible on the dark background).
static void PDGrade(uint32_t rgb, GLfloat *lo, GLfloat *hi) {
	float c[3] = {((rgb >> 16) & 255) / 255.0f, ((rgb >> 8) & 255) / 255.0f, (rgb & 255) / 255.0f};
	float lum = 0.3f * c[0] + 0.59f * c[1] + 0.11f * c[2], lift = lum < 0.25f ? (0.25f - lum) : 0;
	// Bed: 30 % brightness; top: the true colour (8 % toward white), so it stays saturated. The shader steps it in
	// 10 bands by height (75 % stepped, 25 % smooth) so the height reads at a glance.
	for (int i = 0; i < 3; i++) { lo[i] = c[i] * 0.3f + lift * 0.5f; hi[i] = MIN(1.0f, c[i] + (1 - c[i]) * 0.08f + lift); }
	lo[3] = hi[3] = 1;
}

static uint32_t PDRGBOf(UIColor *c) {
	CGFloat r = 0.5f, g = 0.5f, b = 0.5f, a = 1;
	if (![c getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w = 0.5f; [c getWhite:&w alpha:&a]; r = g = b = w; }
	return ((uint32_t)lroundf((float)r * 255) << 16) | ((uint32_t)lroundf((float)g * 255) << 8) | (uint32_t)lroundf((float)b * 255);
}

// The printed layers' colours for the current scheme. Filament: each filament's real colour (the override, or the
// file's "; filament_colour" list per T<n>), graded by height.
- (void)setPrintedColors {
	PDToolpathColorScheme sch = self.colorScheme;
	PDToolpath *t = self.toolpath;
	NSUInteger n = self.filamentColor ? 1 : t.filamentColorCount;
	if (sch == PDToolpathColorFilament && !n) sch = PDToolpathColorHeight;
	if (sch == PDToolpathColorLineType) {
		GLfloat u[PDLineTypeCount * 4];
		for (int i = 0; i < PDLineTypeCount; i++) { u[i * 4] = PDTypeRGB[i][0]; u[i * 4 + 1] = PDTypeRGB[i][1]; u[i * 4 + 2] = PDTypeRGB[i][2]; u[i * 4 + 3] = 1; }
		glUniform4fv(_uTypes, PDLineTypeCount, u);
		glUniform1f(_uMode, 1);
		[self setColorLo:GLKVector4Make(1, 1, 1, 1) hi:GLKVector4Make(1, 1, 1, 1)];
		return;
	}
	if (sch == PDToolpathColorFilament) {
		GLfloat lo[8 * 4], hi[8 * 4];
		uint32_t one = self.filamentColor ? PDRGBOf(self.filamentColor) : 0;
		for (NSUInteger k = 0; k < 8; k++)   // tools past the list reuse its colours
			PDGrade(self.filamentColor ? one : t.filamentColors[k % n], lo + k * 4, hi + k * 4);
		glUniform4fv(_uToolLo, 8, lo);
		glUniform4fv(_uToolHi, 8, hi);
		glUniform1f(_uMode, 2);
		[self setColorLo:GLKVector4Make(lo[0], lo[1], lo[2], 1) hi:GLKVector4Make(hi[0], hi[1], hi[2], 1)];
		return;
	}
	glUniform1f(_uMode, 0);
	[self setColorLo:GLKVector4Make(0.22f, 0.55f, 1.0f, 1) hi:GLKVector4Make(1.0f, 0.55f, 0.32f, 1)];
}

- (void)setColorLo:(GLKVector4)lo hi:(GLKVector4)hi {
	glUniform4f(_uLo, lo.r, lo.g, lo.b, lo.a);
	glUniform4f(_uHi, hi.r, hi.g, hi.b, hi.a);
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	if (_needsUpload) [self upload];
	glClearColor(0.055f, 0.065f, 0.085f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	PDToolpath *t = self.toolpath;
	float x0 = 0, y0 = 0, x1 = PDBedSize, y1 = PDBedSize, zt = 20;
	if (t && t.segmentCount) { x0 = t.minX; y0 = t.minY; x1 = t.maxX; y1 = t.maxY; zt = MAX(1.0f, t.maxZ); }
	// Zoom 1 fits the part; zooming out glides the camera back to the whole plate (the part stays where it sits on it).
	float pr = MAX(15.0f, 0.5f * sqrtf((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + zt * zt));
	float br = PDPlateRadius(zt);
	float toPlate = self.zoom >= 1 || br <= pr ? 0 : MIN(1.0f, logf(1 / self.zoom) / logf(br / pr));
	GLKVector3 target = GLKVector3Lerp(GLKVector3Make((x0 + x1) / 2, (y0 + y1) / 2, zt / 2), GLKVector3Make(PDBedSize / 2, PDBedSize / 2 - 2, zt / 4), toPlate);
	float radius = pr + (br - pr) * toPlate;   // for the clip planes and fog
	self.minZoom = br > pr ? 0.9f * pr / br : 1;
	float aspect = view.drawableWidth > 0 && view.drawableHeight > 0 ? (float)view.drawableWidth / view.drawableHeight : 1;
	const float fov = GLKMathDegreesToRadians(32);
	float dist = pr * 1.12f / (tanf(fov / 2) * MIN(1.0f, aspect)) / self.zoom;   // zoom 1: the part fills the narrower side
	float ce = cosf(self.elevation);
	GLKVector3 eye = GLKVector3Make(target.x + dist * ce * sinf(self.azimuth), target.y - dist * ce * cosf(self.azimuth), target.z + dist * sinf(self.elevation));
	float nearZ = MAX(1.0f, dist - radius * 4), farZ = dist + radius * 6 + PDBedSize * 2;
	GLKMatrix4 proj = GLKMatrix4MakePerspective(fov, aspect, nearZ, farZ);
	GLKMatrix4 look = GLKMatrix4MakeLookAt(eye.x, eye.y, eye.z, target.x, target.y, target.z, 0, 0, 1);
	GLKMatrix4 mvp = GLKMatrix4Multiply(GLKMatrix4Multiply(proj, look), GLKMatrix4MakeScale(0.01f, 0.01f, 0.01f));
	float fn = dist - radius, ff = dist + radius;
	float fogA = -0.6f / MAX(1.0f, ff - fn), fogB = 1.0f + 0.6f * fn / MAX(1.0f, ff - fn);

	glUseProgram(_prog);
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, mvp.m);
	glUniform1f(_uFogA, fogA);
	glUniform1f(_uFogB, fogB);
	glUniform1f(_uInvZ, 1.0f / (zt * 100.0f));
	glEnableVertexAttribArray(0);
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_LEQUAL);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

	// bed grid
	glDepthMask(GL_FALSE);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glVertexAttribPointer(0, 4, GL_SHORT, GL_FALSE, 8, 0);
	glUniform1f(_uFogA, 0); glUniform1f(_uFogB, 1);
	glUniform1f(_uMode, 0);
	[self setColorLo:GLKVector4Make(0.16f, 0.17f, 0.19f, 1) hi:GLKVector4Make(0.16f, 0.17f, 0.19f, 1)];   // the plate
	glDrawArrays(GL_TRIANGLES, 0, _plateVerts);
	[self setColorLo:GLKVector4Make(1, 1, 1, 0.08f) hi:GLKVector4Make(1, 1, 1, 0.08f)];
	glLineWidth(1.0f);
	glDrawArrays(GL_LINES, _plateVerts, _gridVerts);
	[self setColorLo:GLKVector4Make(1, 1, 1, 0.22f) hi:GLKVector4Make(1, 1, 1, 0.22f)];   // the printable area
	glDrawArrays(GL_LINES, _plateVerts + _gridVerts, _areaVerts);
	[self setColorLo:GLKVector4Make(1, 1, 1, 0.5f) hi:GLKVector4Make(1, 1, 1, 0.5f)];   // the plate's edge
	glLineWidth(2.0f);
	glDrawArrays(GL_LINES, _plateVerts + _gridVerts + _areaVerts, _bedVerts - _plateVerts - _gridVerts - _areaVerts);
	glLineWidth(1.0f);
	glUniform1f(_uFogA, fogA); glUniform1f(_uFogB, fogB);

	if (t && _uploadedSegs) {
		NSInteger nl = (NSInteger)t.layerCount;
		const uint32_t *ls = t.layerStart;
		NSInteger done = MAX(0, MIN(nl, self.doneLayers));
		NSInteger cur = (self.currentLayer >= 0 && self.currentLayer < nl) ? self.currentLayer : -1;
		glBindBuffer(GL_ARRAY_BUFFER, _vbo);
		glVertexAttribPointer(0, 4, GL_SHORT, GL_FALSE, 8, 0);
		glDepthMask(GL_TRUE);
		// printed
		if (done > 0) {
			[self setPrintedColors];
			glDrawArrays(GL_LINES, 0, (GLsizei)(2 * ls[done]));
			glUniform1f(_uMode, 0);
		}
		// current layer
		if (cur >= 0 && ls[cur + 1] > ls[cur]) {
			[self setColorLo:GLKVector4Make(0.6f, 1.0f, 0.6f, 1) hi:GLKVector4Make(0.6f, 1.0f, 0.6f, 1)];
			glUniform1f(_uFogA, 0); glUniform1f(_uFogB, 1);
			glLineWidth(2.0f);
			glDrawArrays(GL_LINES, (GLint)(2 * ls[cur]), (GLsizei)(2 * (ls[cur + 1] - ls[cur])));
			glLineWidth(1.0f);
			glUniform1f(_uFogA, fogA); glUniform1f(_uFogB, fogB);
		}
		// still to print: a faint ghost that doesn't hide anything
		NSInteger from = MAX(done, cur + 1);
		if (from < nl) {
			glDepthMask(GL_FALSE);
			[self setColorLo:GLKVector4Make(0.75f, 0.85f, 1.0f, 0.07f) hi:GLKVector4Make(0.75f, 0.85f, 1.0f, 0.07f)];
			glDrawArrays(GL_LINES, (GLint)(2 * ls[from]), (GLsizei)(2 * (ls[nl] - ls[from])));
		}
	}
	glDepthMask(GL_TRUE);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glDisableVertexAttribArray(0);
}

@end
