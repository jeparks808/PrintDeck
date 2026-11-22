#import "PDDesignView.h"
#import "PDDesign.h"
#import "PDSlicer.h"
#import "PDUtil.h"
#import "PDBedShape.h"
#import <OpenGLES/ES2/gl.h>
#import <QuartzCore/QuartzCore.h>

static const char *PDDVS =
	"attribute vec3 aPos;\n"
	"attribute vec3 aNrm;\n"
	"uniform mat4 uMVP;\n"
	"uniform mat3 uNrm;\n"
	"uniform vec4 uColor;\n"
	"uniform float uLit;\n"
	"varying lowp vec4 vColor;\n"
	"void main() {\n"
	"  gl_Position = uMVP * vec4(aPos, 1.0);\n"
	"  vec3 n = normalize(uNrm * aNrm + vec3(0.0, 0.0, 1e-5));\n"
	"  float d = max(dot(n, normalize(vec3(-0.45, -0.6, 0.75))), 0.0);\n"
	"  float back = max(dot(n, normalize(vec3(0.6, 0.5, 0.2))), 0.0);\n"
	"  float k = mix(1.0, 0.34 + 0.6 * d + 0.18 * back, uLit);\n"
	"  vColor = vec4(uColor.rgb * k, uColor.a);\n"
	"}\n";

static const char *PDDFS =
	"varying lowp vec4 vColor;\n"
	"void main() { gl_FragColor = vColor; }\n";

// A unit mesh uploaded once: float xyz + float face normal per vertex.
@interface PDGLMesh : NSObject
@property (nonatomic) GLuint vbo;
@property (nonatomic) GLsizei verts;
@property (nonatomic, strong) id mesh;   // keeps the mesh (and so its address, the cache key) alive
@property (nonatomic) BOOL used;
@end
@implementation PDGLMesh
@end

@interface PDDesignView () <GLKViewDelegate, UIGestureRecognizerDelegate> {
	GLuint _prog, _bedVbo, _lineVbo;
	GLint _uMVP, _uNrm, _uColor, _uLit;
	GLsizei _plateVerts, _minorVerts, _majorVerts, _areaVerts, _edgeVerts;
	GLKMatrix4 _vp;
	// drag
	NSInteger _dragMode;            // 0 none, 1 orbit, 2 slide shapes, 3 move along an axis, 4 turn about an axis
	float _dragZ;
	// gizmo drags
	int _gAxis, _hotAxis;           // 0-2; _hotAxis -1 when no handle is held
	GLKVector3 _gCentre;
	float _gT0, _gPrev, _gTurned, _gBottom, _gStartRaw, _gRing, _gRingScreen, _gShown, _gMoved;
	BOOL _gOnPlane, _gRest, _gFine;
	GLKVector3 _dragStart;
	NSArray *_dragOriginal;         // matrices (NSValue) of the selected shapes at the start
}
@property (nonatomic, strong) EAGLContext *ctx;
@property (nonatomic, strong) GLKView *glView;
@property (nonatomic, strong) NSMutableDictionary *meshes;   // NSValue(mesh pointer) -> PDGLMesh
@property (nonatomic) GLKVector3 target;
@property (nonatomic) float azimuth, elevation, distance;
@property (nonatomic, strong) UIView *messageBox;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *readout;
@property (nonatomic, strong) NSArray *marks;          // UILabels over the ruler / protractor
@property (nonatomic, strong) UILabel *turnInfo;       // Rotate mode: the selection's turn about X, Y, Z
@end

@implementation PDDesignView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		_snap = 1;
		_selection = [NSIndexSet indexSet];
		_meshes = [NSMutableDictionary dictionary];
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
		[self fitView];

		UIPanGestureRecognizer *one = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
		one.maximumNumberOfTouches = 1;
		UIPanGestureRecognizer *two = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan2:)];
		two.minimumNumberOfTouches = 2;
		two.delegate = self;
		UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
		pinch.delegate = self;
		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
		UITapGestureRecognizer *dtap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
		dtap.numberOfTapsRequired = 2;
		for (UIGestureRecognizer *g in [NSArray arrayWithObjects:one, two, pinch, tap, dtap, nil]) [self addGestureRecognizer:g];

		_messageBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 50)];
		_messageBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
		_messageBox.layer.cornerRadius = 12;
		_messageBox.hidden = YES;
		_messageBox.userInteractionEnabled = NO;
		_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
		_spinner.frame = CGRectMake(16, 15, 20, 20);
		_messageLabel = PDLabel([UIFont boldSystemFontOfSize:15], [UIColor whiteColor]);
		_messageLabel.frame = CGRectMake(46, 0, 240, 50);
		[_messageBox addSubview:_spinner];
		[_messageBox addSubview:_messageLabel];
		[self addSubview:_messageBox];

		_hotAxis = -1;
		_readout = PDLabel([UIFont boldSystemFontOfSize:15], [UIColor whiteColor]);
		_readout.textAlignment = NSTextAlignmentCenter;
		_readout.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
		_readout.layer.cornerRadius = 10;
		_readout.clipsToBounds = YES;
		_readout.hidden = YES;
		[self addSubview:_readout];
		_turnInfo = PDLabel([UIFont boldSystemFontOfSize:14], [UIColor whiteColor]);
		_turnInfo.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
		_turnInfo.textAlignment = NSTextAlignmentCenter;
		_turnInfo.layer.cornerRadius = 10;
		_turnInfo.clipsToBounds = YES;
		_turnInfo.hidden = YES;
		_turnInfo.userInteractionEnabled = NO;
		[self addSubview:_turnInfo];
	}
	return self;
}

- (void)dealloc {
	[EAGLContext setCurrentContext:_ctx];
	for (PDGLMesh *m in [_meshes allValues]) { GLuint b = m.vbo; glDeleteBuffers(1, &b); }
	if (_bedVbo) glDeleteBuffers(1, &_bedVbo);
	if (_lineVbo) glDeleteBuffers(1, &_lineVbo);
	if (_prog) glDeleteProgram(_prog);
	[EAGLContext setCurrentContext:nil];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.messageBox.center = CGPointMake(CGRectGetMidX(self.bounds), 60);
	self.readout.frame = CGRectMake(CGRectGetMidX(self.bounds) - 125, self.bounds.size.height - 50, 250, 34);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
	return ![a isKindOfClass:[UITapGestureRecognizer class]] && ![b isKindOfClass:[UITapGestureRecognizer class]];
}

#pragma mark GL setup

static GLuint PDDCompile(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log); NSLog(@"PrintDeck: design shader: %s", log); }
	return s;
}

- (void)setupGL {
	[EAGLContext setCurrentContext:self.ctx];
	GLuint vs = PDDCompile(GL_VERTEX_SHADER, PDDVS), fs = PDDCompile(GL_FRAGMENT_SHADER, PDDFS);
	_prog = glCreateProgram();
	glAttachShader(_prog, vs); glAttachShader(_prog, fs);
	glBindAttribLocation(_prog, 0, "aPos");
	glBindAttribLocation(_prog, 1, "aNrm");
	glLinkProgram(_prog);
	glDeleteShader(vs); glDeleteShader(fs);
	_uMVP = glGetUniformLocation(_prog, "uMVP");
	_uNrm = glGetUniformLocation(_prog, "uNrm");
	_uColor = glGetUniformLocation(_prog, "uColor");
	_uLit = glGetUniformLocation(_prog, "uLit");
	// The plate (triangles just under z = 0), a 10 mm grid with every fifth line stronger, the printable area's
	// outline and the plate's edge. 6 floats per vertex (xyz + an unused normal), like the shapes.
	int cap = PDBedTriCount * 3 + 2 * 2 * 27 + 8 + PDBedEdgeCount * 2;
	GLfloat *b = calloc((size_t)cap * 6, sizeof(GLfloat));
	int n = 0;
	#define PDV(X, Y, Z) do { b[n * 6] = (X); b[n * 6 + 1] = (Y); b[n * 6 + 2] = (Z); b[n * 6 + 5] = 1; n++; } while (0)
	for (int i = 0; i < PDBedTriCount * 3; i++) PDV(PDBedTris[i * 2], PDBedTris[i * 2 + 1], -0.05f);
	_plateVerts = n;
	for (int i = 1; i < 26; i++) if (i % 5) { GLfloat c = i * 10.0f; PDV(c, 0, 0); PDV(c, PD_BED_MM, 0); PDV(0, c, 0); PDV(PD_BED_MM, c, 0); }
	_minorVerts = n - _plateVerts;
	for (int i = 5; i < 26; i += 5) { GLfloat c = i * 10.0f; PDV(c, 0, 0); PDV(c, PD_BED_MM, 0); PDV(0, c, 0); PDV(PD_BED_MM, c, 0); }
	_majorVerts = n - _plateVerts - _minorVerts;
	GLfloat area[5][2] = {{0, 0}, {PD_BED_MM, 0}, {PD_BED_MM, PD_BED_MM}, {0, PD_BED_MM}, {0, 0}};
	for (int k = 0; k < 4; k++) { PDV(area[k][0], area[k][1], 0); PDV(area[k + 1][0], area[k + 1][1], 0); }
	_areaVerts = 8;
	for (int i = 0; i < PDBedEdgeCount; i++) { PDV(PDBedOutline[i * 4], PDBedOutline[i * 4 + 1], -0.02f); PDV(PDBedOutline[i * 4 + 2], PDBedOutline[i * 4 + 3], -0.02f); }
	#undef PDV
	_edgeVerts = n - _plateVerts - _minorVerts - _majorVerts - _areaVerts;
	glGenBuffers(1, &_bedVbo);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 6 * sizeof(GLfloat), b, GL_STATIC_DRAW);
	free(b);
	glGenBuffers(1, &_lineVbo);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
}

- (PDGLMesh *)glMeshFor:(PDShape *)s {
	id mesh = [s meshObject];
	if (!mesh) return nil;
	NSValue *key = [NSValue valueWithPointer:(__bridge const void *)mesh];
	PDGLMesh *g = [self.meshes objectForKey:key];
	if (!g) {
		int n = 0;
		const float *t = [s unitTriangles:&n];
		GLfloat *buf = malloc((size_t)n * 3 * 6 * sizeof(GLfloat));
		if (!buf) return nil;
		for (int i = 0; i < n; i++) {
			const float *a = t + i * 9;
			GLKVector3 p0 = GLKVector3Make(a[0], a[1], a[2]), p1 = GLKVector3Make(a[3], a[4], a[5]), p2 = GLKVector3Make(a[6], a[7], a[8]);
			GLKVector3 nr = GLKVector3CrossProduct(GLKVector3Subtract(p1, p0), GLKVector3Subtract(p2, p0));
			float l = GLKVector3Length(nr);
			nr = l > 0 ? GLKVector3DivideScalar(nr, l) : GLKVector3Make(0, 0, 1);
			for (int v = 0; v < 3; v++) {
				GLfloat *o = buf + (i * 3 + v) * 6;
				o[0] = a[v * 3]; o[1] = a[v * 3 + 1]; o[2] = a[v * 3 + 2];
				o[3] = nr.x; o[4] = nr.y; o[5] = nr.z;
			}
		}
		g = [[PDGLMesh alloc] init];
		GLuint vbo;
		glGenBuffers(1, &vbo);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)n * 3 * 6 * sizeof(GLfloat), buf, GL_STATIC_DRAW);
		free(buf);
		g.vbo = vbo; g.verts = n * 3; g.mesh = mesh;
		[self.meshes setObject:g forKey:key];
	}
	g.used = YES;
	return g;
}

#pragma mark Properties

- (void)setShapes:(NSArray *)shapes { _shapes = [shapes copy]; [self redraw]; }
- (void)setSelection:(NSIndexSet *)sel { _selection = [sel copy] ?: [NSIndexSet indexSet]; [self redraw]; }
- (void)setGizmo:(NSInteger)gizmo { _gizmo = gizmo; [self redraw]; }

- (void)setMessage:(NSString *)message {
	_message = [message copy];
	self.messageLabel.text = message;
	self.messageBox.hidden = ![message length];
	if ([message length]) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}

- (void)redraw {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	[self.glView setNeedsDisplay];
}

#pragma mark Camera

- (void)fitView {
	GLKVector3 lo = GLKVector3Make(1e30f, 1e30f, 1e30f), hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	for (PDShape *s in self.shapes) { lo = GLKVector3Minimum(lo, [s worldMin]); hi = GLKVector3Maximum(hi, [s worldMax]); }
	if (![self.shapes count]) { lo = GLKVector3Make(0, 0, 0); hi = GLKVector3Make(PD_BED_MM, PD_BED_MM, 10); }
	self.target = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	float r = MAX(25.0f, 0.5f * GLKVector3Length(GLKVector3Subtract(hi, lo)));
	self.distance = MIN(900.0f, [self.shapes count] ? MAX(30.0f, r) * 3.9f : r * 2.6f);   // shapes: whole bounding sphere in the 36° view; empty: the plate
	self.azimuth = -0.55f;
	self.elevation = 0.62f;
	[self redraw];
}

- (GLKVector3)focusPoint {
	GLKVector3 t = self.target;
	return GLKVector3Make(MAX(10, MIN(PD_BED_MM - 10, t.x)), MAX(10, MIN(PD_BED_MM - 10, t.y)), 0);
}

- (GLKVector3)eye {
	float ce = cosf(self.elevation);
	GLKVector3 t = self.target;
	return GLKVector3Make(t.x + self.distance * ce * sinf(self.azimuth), t.y - self.distance * ce * cosf(self.azimuth), t.z + self.distance * sinf(self.elevation));
}

- (GLKMatrix4)viewProjection {
	CGSize sz = self.bounds.size;
	float aspect = sz.height > 0 ? (float)(sz.width / sz.height) : 1;
	GLKVector3 e = [self eye], t = self.target;
	float nearZ = MAX(1.0f, self.distance * 0.05f), farZ = self.distance * 4 + PD_BED_MM * 3;
	return GLKMatrix4Multiply(GLKMatrix4MakePerspective(GLKMathDegreesToRadians(36), aspect, nearZ, farZ),
		GLKMatrix4MakeLookAt(e.x, e.y, e.z, t.x, t.y, t.z, 0, 0, 1));
}

// The ray through a point of the view, in world space.
- (void)rayAt:(CGPoint)p origin:(GLKVector3 *)o direction:(GLKVector3 *)d {
	CGSize sz = self.bounds.size;
	float x = (float)(2 * p.x / sz.width - 1), y = (float)(1 - 2 * p.y / sz.height);
	bool ok;
	GLKMatrix4 inv = GLKMatrix4Invert([self viewProjection], &ok);
	GLKVector4 a = GLKMatrix4MultiplyVector4(inv, GLKVector4Make(x, y, -1, 1)), b = GLKMatrix4MultiplyVector4(inv, GLKVector4Make(x, y, 1, 1));
	GLKVector3 pa = GLKVector3Make(a.x / a.w, a.y / a.w, a.z / a.w), pb = GLKVector3Make(b.x / b.w, b.y / b.w, b.z / b.w);
	*o = pa;
	*d = GLKVector3Normalize(GLKVector3Subtract(pb, pa));
}

// The frontmost shape under a point (and where the ray meets it), or -1.
- (NSInteger)shapeAt:(CGPoint)p hit:(GLKVector3 *)hit {
	GLKVector3 o, d;
	[self rayAt:p origin:&o direction:&d];
	float best = 1e30f;
	NSInteger bi = -1;
	NSUInteger idx = 0;
	for (PDShape *s in self.shapes) {
		bool ok;
		GLKMatrix4 mi = GLKMatrix4Invert(s.matrix, &ok);
		if (!ok) { idx++; continue; }
		GLKVector3 lo = GLKMatrix4MultiplyVector3WithTranslation(mi, o), ld = GLKMatrix4MultiplyVector3(mi, d);
		int n = 0;
		const float *t = [s unitTriangles:&n];
		for (int i = 0; i < n; i++) {   // Möller–Trumbore; the ray parameter is the same in both frames
			const float *a = t + i * 9;
			GLKVector3 v0 = GLKVector3Make(a[0], a[1], a[2]);
			GLKVector3 e1 = GLKVector3Make(a[3] - a[0], a[4] - a[1], a[5] - a[2]), e2 = GLKVector3Make(a[6] - a[0], a[7] - a[1], a[8] - a[2]);
			GLKVector3 pv = GLKVector3CrossProduct(ld, e2);
			float det = GLKVector3DotProduct(e1, pv);
			if (fabsf(det) < 1e-12f) continue;
			float inv = 1 / det;
			GLKVector3 tv = GLKVector3Subtract(lo, v0);
			float u = GLKVector3DotProduct(tv, pv) * inv;
			if (u < 0 || u > 1) continue;
			GLKVector3 qv = GLKVector3CrossProduct(tv, e1);
			float v = GLKVector3DotProduct(ld, qv) * inv;
			if (v < 0 || u + v > 1) continue;
			float tt = GLKVector3DotProduct(e2, qv) * inv;
			if (tt > 0 && tt < best) { best = tt; bi = (NSInteger)idx; }
		}
		idx++;
	}
	if (bi >= 0 && hit) *hit = GLKVector3Add(o, GLKVector3MultiplyScalar(d, best));
	return bi;
}

// Where the ray through p meets the horizontal plane at height z.
- (BOOL)planePointAt:(CGPoint)p z:(float)z out:(GLKVector3 *)out {
	GLKVector3 o, d;
	[self rayAt:p origin:&o direction:&d];
	if (fabsf(d.z) < 1e-4f) return NO;
	float t = (z - o.z) / d.z;
	if (t <= 0) return NO;
	*out = GLKVector3Add(o, GLKVector3MultiplyScalar(d, t));
	return YES;
}

#pragma mark Gizmo

static GLKVector3 PDAxis(int a) { return GLKVector3Make(a == 0, a == 1, a == 2); }

// The selection's world bounds; NO when nothing is selected.
- (BOOL)selectionLo:(GLKVector3 *)lo hi:(GLKVector3 *)hi {
	*lo = GLKVector3Make(1e30f, 1e30f, 1e30f); *hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	NSArray *shapes = self.shapes;
	for (NSUInteger k = [self.selection firstIndex]; k != NSNotFound; k = [self.selection indexGreaterThanIndex:k]) {
		if (k >= [shapes count]) continue;
		PDShape *s = [shapes objectAtIndex:k];
		*lo = GLKVector3Minimum(*lo, [s worldMin]); *hi = GLKVector3Maximum(*hi, [s worldMax]);
	}
	return lo->x <= hi->x;
}

// Handle sizes: a base unit that stays about the same on screen, the arrows' start and end along each axis
// (from the centre: just outside the selection's box) and the rings' radius.
- (BOOL)gizmoCentre:(GLKVector3 *)c base:(float *)base from:(float *)from to:(float *)to ring:(float *)ring {
	GLKVector3 lo, hi;
	if (![self selectionLo:&lo hi:&hi]) return NO;
	*c = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	if (_dragMode == 4) *c = _gCentre;   // turning: stay on the centre the turn started about
	GLKVector3 h = GLKVector3MultiplyScalar(GLKVector3Subtract(hi, lo), 0.5f);
	float b = MAX(4.0f, self.distance * 0.06f);
	*base = b;
	for (int a = 0; a < 3; a++) { from[a] = h.v[a] + b * 0.15f; to[a] = from[a] + b * 1.6f; }
	*ring = MAX(GLKVector3Length(h) * 1.05f, b * 2.2f);
	return YES;
}

static void PDBasis(int a, GLKVector3 *u, GLKVector3 *v) {   // u × v = axis a
	*u = PDAxis((a + 1) % 3); *v = PDAxis((a + 2) % 3);
}

- (BOOL)project:(GLKVector3)p to:(CGPoint *)out {
	GLKVector4 q = GLKMatrix4MultiplyVector4([self viewProjection], GLKVector4Make(p.x, p.y, p.z, 1));
	if (q.w <= 1e-4f) return NO;
	CGSize sz = self.bounds.size;
	out->x = (q.x / q.w + 1) * 0.5f * sz.width;
	out->y = (1 - q.y / q.w) * 0.5f * sz.height;
	return YES;
}

static CGFloat PDSegDist(CGPoint p, CGPoint a, CGPoint b) {
	CGFloat dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy;
	CGFloat t = l > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / l : 0;
	t = MAX(0, MIN(1, t));
	CGFloat x = a.x + t * dx - p.x, y = a.y + t * dy - p.y;
	return sqrt(x * x + y * y);
}

// The handle under a point: its axis, or -1.
- (int)handleAt:(CGPoint)p {
	if (!self.gizmo || ![self.selection count]) return -1;
	GLKVector3 c; float base, from[3], to[3], ring;
	if (![self gizmoCentre:&c base:&base from:from to:to ring:&ring]) return -1;
	int best = -1;
	CGFloat bestD = self.gizmo == 1 ? 26 : 20;
	for (int a = 0; a < 3; a++) {
		GLKVector3 ax = PDAxis(a);
		if (self.gizmo == 1) {
			CGPoint s0, s1;
			if (![self project:GLKVector3Add(c, GLKVector3MultiplyScalar(ax, from[a])) to:&s0]) continue;
			if (![self project:GLKVector3Add(c, GLKVector3MultiplyScalar(ax, to[a])) to:&s1]) continue;
			if (hypot(s1.x - s0.x, s1.y - s0.y) < 14) continue;   // pointing at the eye: can't be dragged
			CGFloat d = PDSegDist(p, s0, s1);
			if (d < bestD) { bestD = d; best = a; }
		} else {
			GLKVector3 u, v;
			PDBasis(a, &u, &v);
			CGPoint prev = CGPointZero;
			BOOL have = NO;
			for (int k = 0; k <= 64; k++) {
				float t = 2 * (float)M_PI * k / 64;
				GLKVector3 q = GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, ring * cosf(t)), GLKVector3MultiplyScalar(v, ring * sinf(t))));
				CGPoint sp;
				if (![self project:q to:&sp]) { have = NO; continue; }
				if (have) { CGFloat d = PDSegDist(p, prev, sp); if (d < bestD) { bestD = d; best = a; } }
				prev = sp; have = YES;
			}
		}
	}
	return best;
}

// Where along axis a (through the gizmo centre) the ray through p passes closest, in mm from the centre.
- (BOOL)axisParam:(CGPoint)p out:(float *)t {
	GLKVector3 o, d, a = PDAxis(_gAxis);
	[self rayAt:p origin:&o direction:&d];
	GLKVector3 w = GLKVector3Subtract(_gCentre, o);
	float b = GLKVector3DotProduct(a, d), den = 1 - b * b;
	if (den < 1e-4f) return NO;
	*t = (b * GLKVector3DotProduct(d, w) - GLKVector3DotProduct(a, w)) / den;
	return YES;
}

// The angle of p around the axis (right-handed): on the ring's plane when it faces the view well enough,
// else around the centre on the screen.
- (float)axisAngle:(CGPoint)p { return [self axisAngle:p frac:NULL]; }

// Also how far out from the centre p is, as a fraction of the ring's radius (the protractor's coarse / fine zones).
- (float)axisAngle:(CGPoint)p frac:(float *)frac {
	GLKVector3 a = PDAxis(_gAxis), u, v;
	PDBasis(_gAxis, &u, &v);
	if (_gOnPlane) {
		GLKVector3 o, d;
		[self rayAt:p origin:&o direction:&d];
		float den = GLKVector3DotProduct(a, d);
		if (fabsf(den) > 1e-4f) {
			GLKVector3 q = GLKVector3Add(o, GLKVector3MultiplyScalar(d, GLKVector3DotProduct(a, GLKVector3Subtract(_gCentre, o)) / den));
			GLKVector3 r = GLKVector3Subtract(q, _gCentre);
			if (frac) *frac = _gRing > 0 ? GLKVector3Length(r) / _gRing : 1;
			return atan2f(GLKVector3DotProduct(r, v), GLKVector3DotProduct(r, u));
		}
	}
	CGPoint sc;
	if (![self project:_gCentre to:&sc]) return _gPrev;
	if (frac) *frac = _gRingScreen > 0 ? (float)hypot(p.x - sc.x, p.y - sc.y) / _gRingScreen : 1;
	float ang = atan2f((float)(sc.y - p.y), (float)(p.x - sc.x));   // counter-clockwise on screen
	return GLKVector3DotProduct(a, GLKVector3Subtract([self eye], _gCentre)) >= 0 ? ang : -ang;
}

- (void)applyToSelection:(GLKMatrix4 (^)(GLKMatrix4 original))f {
	__block NSUInteger n = 0;
	[self.selection enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
		GLKMatrix4 m;
		[[self->_dragOriginal objectAtIndex:n++] getValue:&m];
		((PDShape *)[self.shapes objectAtIndex:k]).matrix = f(m);
	}];
}

- (void)gizmoDrag:(CGPoint)loc {
	static const char *names[3] = {"X", "Y", "Z"};
	if (_dragMode == 3) {
		float t;
		if (![self axisParam:loc out:&t]) return;
		float s = self.snap > 0 ? self.snap : 1, dt = roundf((t - _gT0) / s) * s;
		int a = _gAxis;
		[self applyToSelection:^GLKMatrix4(GLKMatrix4 m) { m.m[12 + a] += dt; return m; }];
		_gMoved = dt;
		self.readout.text = [NSString stringWithFormat:s < 1 ? @"Move %s  %+.1f mm" : @"Move %s  %+.0f mm", names[a], dt];
	} else {
		float frac = 1, raw = [self axisAngle:loc frac:&frac], d = raw - _gPrev;
		_gFine = frac > 1.1f;   // inside the pie-slice disc (to just past the ring): 30° snaps; out beyond it: 1° steps
		while (d > M_PI) d -= 2 * (float)M_PI;
		while (d < -M_PI) d += 2 * (float)M_PI;
		_gTurned += d; _gPrev = raw;
		float step = _gFine ? 1 : 30, deg = roundf(GLKMathRadiansToDegrees(_gTurned) / step) * step;
		_gShown = deg;
		GLKVector3 c = _gCentre, ax = PDAxis(_gAxis);
		GLKMatrix4 r = GLKMatrix4Multiply(GLKMatrix4Multiply(GLKMatrix4MakeTranslation(c.x, c.y, c.z),
			GLKMatrix4MakeRotation(GLKMathDegreesToRadians(deg), ax.x, ax.y, ax.z)), GLKMatrix4MakeTranslation(-c.x, -c.y, -c.z));
		[self applyToSelection:^GLKMatrix4(GLKMatrix4 m) { return GLKMatrix4Multiply(r, m); }];
		if (_gRest) {   // it stood on the plate: keep it there
			GLKVector3 lo, hi;
			if ([self selectionLo:&lo hi:&hi]) {
				float dz = self->_gBottom - lo.z;
				[self.selection enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
					PDShape *s = [self.shapes objectAtIndex:k]; GLKMatrix4 m = s.matrix; m.m[14] += dz; s.matrix = m;
				}];
			}
		}
		float shown = fmodf(deg, 360);
		self.readout.text = [NSString stringWithFormat:@"Turn %s  %+.0f°   %@", names[_gAxis], shown, _gFine ? @"fine (1°)" : @"snap 30°"];
	}
	[self redraw];
	if (self.moved) self.moved(NO);
}

// Rotate mode: the selection's turn, always on show (top left, under Select more).
- (void)updateTurnInfo {
	NSMutableArray *sel = [NSMutableArray array];
	for (NSUInteger k = [self.selection firstIndex]; k != NSNotFound; k = [self.selection indexGreaterThanIndex:k])
		if (k < [self.shapes count]) [sel addObject:[self.shapes objectAtIndex:k]];
	self.turnInfo.hidden = self.gizmo != 2 || ![sel count];
	if (self.turnInfo.hidden) return;
	NSString *t = [NSString stringWithFormat:@"Rotation  %@", [PDShape rotationTextFor:sel]];
	if (![t isEqualToString:self.turnInfo.text]) {
		self.turnInfo.text = t;
		CGSize sz = [t sizeWithFont:self.turnInfo.font];
		self.turnInfo.frame = CGRectMake(10, 52, sz.width + 24, 30);
	}
}

#pragma mark Touch

- (void)tap:(UITapGestureRecognizer *)g {
	if ([self handleAt:[g locationInView:self]] >= 0) return;   // a tap on a handle keeps the selection
	NSInteger i = [self shapeAt:[g locationInView:self] hit:NULL];
	NSMutableIndexSet *sel = [self.selection mutableCopy];
	if (i < 0) { if (!self.multiSelect) [sel removeAllIndexes]; }
	else if (self.multiSelect) { if ([sel containsIndex:(NSUInteger)i]) [sel removeIndex:(NSUInteger)i]; else [sel addIndex:(NSUInteger)i]; }
	else { [sel removeAllIndexes]; [sel addIndex:(NSUInteger)i]; }
	self.selection = sel;
	if (self.selectionChanged) self.selectionChanged();
}

- (void)doubleTap:(UITapGestureRecognizer *)g {
	if ([self shapeAt:[g locationInView:self] hit:NULL] < 0) [self fitView];
}

- (void)pan:(UIPanGestureRecognizer *)g {
	[self panState:g.state location:[g locationInView:self] translation:[g translationInView:self] gesture:g];
}

// Developer aid (printdeck://drag): the pan handler fed a straight one-finger drag, in this view's points.
// hold: stop short of lifting the finger (a later call with release lifts it where it is).
- (void)devDragFrom:(CGPoint)a to:(CGPoint)b hold:(BOOL)hold release:(BOOL)release {
	static CGPoint last, first;
	if (release) { [self panState:UIGestureRecognizerStateEnded location:last translation:CGPointMake(last.x - first.x, last.y - first.y) gesture:nil]; return; }
	int steps = 12;
	[self panState:UIGestureRecognizerStateBegan location:a translation:CGPointZero gesture:nil];
	for (int i = 1; i <= steps; i++) {
		CGPoint p = CGPointMake(a.x + (b.x - a.x) * i / steps, a.y + (b.y - a.y) * i / steps);
		[self panState:i == steps && !hold ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateChanged location:p
			translation:CGPointMake(p.x - a.x, p.y - a.y) gesture:nil];
	}
	first = a; last = b;
}

- (void)panState:(UIGestureRecognizerState)state location:(CGPoint)loc translation:(CGPoint)tr gesture:(UIPanGestureRecognizer *)g {
	if (state == UIGestureRecognizerStateBegan) {
		CGPoint start = CGPointMake(loc.x - tr.x, loc.y - tr.y);
		int axis = [self handleAt:start];
		if (axis >= 0) {
			GLKVector3 c; float base, from[3], to[3], ring;
			[self gizmoCentre:&c base:&base from:from to:to ring:&ring];
			_gAxis = axis; _gCentre = c;
			BOOL ok;
			if (self.gizmo == 1) ok = [self axisParam:start out:&_gT0];
			else {
				GLKVector3 o, d;
				[self rayAt:start origin:&o direction:&d];
				_gOnPlane = fabsf(GLKVector3DotProduct(PDAxis(axis), d)) > 0.25f;
				_gRing = ring; _gRingScreen = 0; _gShown = 0; _gFine = NO;
				CGPoint sc, sp;
				GLKVector3 u, v;
				PDBasis(axis, &u, &v);
				if ([self project:c to:&sc]) for (int k = 0; k < 16; k++) {
					float t = 2 * (float)M_PI * k / 16;
					if ([self project:GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, ring * cosf(t)), GLKVector3MultiplyScalar(v, ring * sinf(t)))) to:&sp])
						_gRingScreen = MAX(_gRingScreen, (float)hypot(sp.x - sc.x, sp.y - sc.y));
				}
				_gPrev = [self axisAngle:start]; _gTurned = 0;
				_gStartRaw = _gPrev;
				GLKVector3 lo, hi;
				[self selectionLo:&lo hi:&hi];
				_gBottom = lo.z;
				_gRest = fabsf(lo.z) < 0.05f;
				ok = YES;
			}
			if (ok) {
				_dragMode = self.gizmo == 1 ? 3 : 4;
				_hotAxis = axis;
				if (self.willMove) self.willMove();
				NSMutableArray *orig = [NSMutableArray array];
				[self.selection enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
					GLKMatrix4 m = ((PDShape *)[self.shapes objectAtIndex:k]).matrix;
					[orig addObject:[NSValue valueWithBytes:&m objCType:@encode(GLKMatrix4)]];
				}];
				_dragOriginal = orig;
				self.readout.text = @"";
				self.readout.hidden = NO;
				_gMoved = 0;
				[self gizmoDrag:loc];
				return;
			}
		}
		GLKVector3 hit;
		NSInteger i = [self shapeAt:start hit:&hit];
		_dragMode = 1;
		if (i >= 0 && [self planePointAt:start z:hit.z out:&_dragStart]) {
			if (![self.selection containsIndex:(NSUInteger)i]) {
				NSMutableIndexSet *sel = self.multiSelect ? [self.selection mutableCopy] : [NSMutableIndexSet indexSet];
				[sel addIndex:(NSUInteger)i];
				self.selection = sel;
				if (self.selectionChanged) self.selectionChanged();
			}
			_dragMode = 2;
			_dragZ = hit.z;
			if (self.willMove) self.willMove();
			NSMutableArray *orig = [NSMutableArray array];
			[self.selection enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
				GLKMatrix4 m = ((PDShape *)[self.shapes objectAtIndex:k]).matrix;
				[orig addObject:[NSValue valueWithBytes:&m objCType:@encode(GLKMatrix4)]];
			}];
			_dragOriginal = orig;
		} else [g setTranslation:CGPointZero inView:self];
		return;
	}
	if (_dragMode == 3 || _dragMode == 4) {
		if (state == UIGestureRecognizerStateChanged || state == UIGestureRecognizerStateEnded) [self gizmoDrag:loc];
		if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled) {
			_dragMode = 0; _dragOriginal = nil; _hotAxis = -1;
			self.readout.hidden = YES;
			[self redraw];
			if (self.moved) self.moved(YES);
		}
		return;
	}
	if (_dragMode == 2) {
		GLKVector3 p;
		if ([self planePointAt:loc z:_dragZ out:&p]) {
			float s = self.snap > 0 ? self.snap : 1;
			float dx = roundf((p.x - _dragStart.x) / s) * s, dy = roundf((p.y - _dragStart.y) / s) * s;
			__block NSUInteger n = 0;
			[self.selection enumerateIndexesUsingBlock:^(NSUInteger k, BOOL *stop) {
				GLKMatrix4 m;
				[[self->_dragOriginal objectAtIndex:n++] getValue:&m];
				m.m[12] += dx; m.m[13] += dy;
				((PDShape *)[self.shapes objectAtIndex:k]).matrix = m;
			}];
			[self redraw];
			if (self.moved) self.moved(NO);
		}
		if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled) {
			_dragMode = 0; _dragOriginal = nil;
			if (self.moved) self.moved(YES);
		}
		return;
	}
	[g setTranslation:CGPointZero inView:self];
	self.azimuth -= tr.x * 0.010f;
	self.elevation = MAX(-0.15f, MIN(1.55f, self.elevation + tr.y * 0.008f));
	if (state == UIGestureRecognizerStateEnded) _dragMode = 0;
	[self redraw];
}

- (void)pan2:(UIPanGestureRecognizer *)g {
	CGPoint tr = [g translationInView:self];
	[g setTranslation:CGPointZero inView:self];
	// move the target across the screen plane, by as much as the plate moves under the fingers
	float k = self.distance * 0.0016f;
	float ca = cosf(self.azimuth), sa = sinf(self.azimuth);
	GLKVector3 right = GLKVector3Make(ca, sa, 0), fwd = GLKVector3Make(-sa, ca, 0);
	GLKVector3 t = self.target;
	t = GLKVector3Subtract(t, GLKVector3MultiplyScalar(right, tr.x * k));
	t = GLKVector3Add(t, GLKVector3MultiplyScalar(fwd, tr.y * k));
	t.x = MAX(-100, MIN(PD_BED_MM + 100, t.x)); t.y = MAX(-100, MIN(PD_BED_MM + 100, t.y));
	self.target = t;
	[self redraw];
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
	self.distance = MAX(20.0f, MIN(1200.0f, self.distance / g.scale));
	g.scale = 1;
	[self redraw];
}

#pragma mark Drawing

- (void)setColor:(uint32_t)c alpha:(float)a lift:(float)lift {
	float r = ((c >> 16) & 255) / 255.0f, gg = ((c >> 8) & 255) / 255.0f, b = (c & 255) / 255.0f;
	glUniform4f(_uColor, r + (1 - r) * lift, gg + (1 - gg) * lift, b + (1 - b) * lift, a);
}

- (void)drawShape:(PDShape *)s {
	PDGLMesh *m = [self glMeshFor:s];
	if (!m) return;
	GLKMatrix4 mvp = GLKMatrix4Multiply(_vp, s.matrix);
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, mvp.m);
	bool inv;
	GLKMatrix3 nm = GLKMatrix3Transpose(GLKMatrix3Invert(GLKMatrix4GetMatrix3(s.matrix), &inv));
	glUniformMatrix3fv(_uNrm, 1, GL_FALSE, nm.m);
	glBindBuffer(GL_ARRAY_BUFFER, m.vbo);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
	glDrawArrays(GL_TRIANGLES, 0, m.verts);
}

// Arrows (a shaft and a cone) or rings in X red, Y green, Z blue, over everything; the held one in yellow
// (and while dragging only it, plus its axis line when moving).
- (void)drawGizmo {
	GLKVector3 c; float base, from[3], to[3], ring;
	if (![self gizmoCentre:&c base:&base from:from to:to ring:&ring]) return;
	static const float col[3][3] = {{0.95f, 0.32f, 0.32f}, {0.38f, 0.86f, 0.34f}, {0.36f, 0.56f, 1.0f}};
	enum { CAP = 3 * (2 + 12 * 6) + 3 * 65 + 2 };
	GLfloat *L = malloc(CAP * 6 * sizeof(GLfloat));
	if (!L) return;
	int n = 0;
	#define PDG(P) do { GLKVector3 q_ = (P); L[n * 6] = q_.x; L[n * 6 + 1] = q_.y; L[n * 6 + 2] = q_.z; L[n * 6 + 3] = 0; L[n * 6 + 4] = 0; L[n * 6 + 5] = 1; n++; } while (0)
	int first[3][3], count[3][3];   // per axis: lines, triangles, guide
	for (int a = 0; a < 3; a++) {
		GLKVector3 ax = PDAxis(a), u, v;
		PDBasis(a, &u, &v);
		first[a][0] = n;
		if (self.gizmo == 1) {
			float headL = base * 0.5f, headR = base * 0.2f;
			PDG(GLKVector3Add(c, GLKVector3MultiplyScalar(ax, from[a])));
			PDG(GLKVector3Add(c, GLKVector3MultiplyScalar(ax, to[a] - headL)));
			count[a][0] = 2;
			first[a][1] = n;
			GLKVector3 tip = GLKVector3Add(c, GLKVector3MultiplyScalar(ax, to[a])), b = GLKVector3Add(c, GLKVector3MultiplyScalar(ax, to[a] - headL));
			for (int k = 0; k < 12; k++) {
				float t0 = 2 * (float)M_PI * k / 12, t1 = 2 * (float)M_PI * (k + 1) / 12;
				GLKVector3 p0 = GLKVector3Add(b, GLKVector3Add(GLKVector3MultiplyScalar(u, headR * cosf(t0)), GLKVector3MultiplyScalar(v, headR * sinf(t0))));
				GLKVector3 p1 = GLKVector3Add(b, GLKVector3Add(GLKVector3MultiplyScalar(u, headR * cosf(t1)), GLKVector3MultiplyScalar(v, headR * sinf(t1))));
				PDG(tip); PDG(p0); PDG(p1);
				PDG(b); PDG(p1); PDG(p0);
			}
			count[a][1] = n - first[a][1];
			first[a][2] = n;
			PDG(GLKVector3Add(c, GLKVector3MultiplyScalar(ax, -2000))); PDG(GLKVector3Add(c, GLKVector3MultiplyScalar(ax, 2000)));
			count[a][2] = 2;
		} else {
			for (int k = 0; k <= 64; k++) {
				float t = 2 * (float)M_PI * k / 64;
				PDG(GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, ring * cosf(t)), GLKVector3MultiplyScalar(v, ring * sinf(t)))));
			}
			count[a][0] = 65;
			first[a][1] = first[a][2] = n; count[a][1] = count[a][2] = 0;
		}
	}
	#undef PDG
	glBindBuffer(GL_ARRAY_BUFFER, _lineVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 6 * sizeof(GLfloat), L, GL_STREAM_DRAW);
	free(L);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, _vp.m);
	glUniform1f(_uLit, 0);
	glDisable(GL_DEPTH_TEST);
	BOOL dragging = _dragMode == 3 || _dragMode == 4;
	for (int a = 0; a < 3; a++) {
		if (dragging && a != _hotAxis) continue;
		BOOL hot = a == _hotAxis;
		float r = hot ? 1.0f : col[a][0], gg = hot ? 0.84f : col[a][1], b = hot ? 0.25f : col[a][2];
		if (dragging && self.gizmo == 1) {
			glLineWidth(1.0f);
			glUniform4f(_uColor, r, gg, b, 0.45f);
			glDrawArrays(GL_LINES, first[a][2], count[a][2]);
		}
		glUniform4f(_uColor, r, gg, b, 1);
		glLineWidth(self.gizmo == 1 ? 4.0f : 3.0f);
		glDrawArrays(self.gizmo == 1 ? GL_LINES : GL_LINE_STRIP, first[a][0], count[a][0]);
		if (count[a][1]) glDrawArrays(GL_TRIANGLES, first[a][1], count[a][1]);
	}
	if (_dragMode == 4) [self drawProtractor:c ring:ring];
	else if (_dragMode == 3) [self drawRuler:c base:base];
	else [self hideMarks];
	glLineWidth(1.0f);
	glEnable(GL_DEPTH_TEST);
}

// While a ring is dragged, Tinkercad-style: the ring's disc in 30° pie slices counted from where the drag
// started (inside it the turn snaps to them), labelled; outside it the turn is free in 1° steps and 5° ticks
// show round the rim. The turn so far is a yellow wedge between the start spoke and the current one.
- (void)drawProtractor:(GLKVector3)c ring:(float)R {
	GLKVector3 u, v;
	PDBasis(_gAxis, &u, &v);
	float a0 = _gOnPlane ? _gStartRaw : 0;   // edge-on drags measure on the screen: count from the ring's own zero
	enum { CAP = 12 * 6 * 3 + 12 * 2 + 72 * 2 + 4 + 72 * 3 };
	GLfloat *L = malloc(CAP * 6 * sizeof(GLfloat));
	if (!L) return;
	int n = 0;
	#define PDP(RAD, ANG) do { float a_ = (ANG); GLKVector3 q_ = GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, (RAD) * cosf(a_)), GLKVector3MultiplyScalar(v, (RAD) * sinf(a_)))); \
		L[n * 6] = q_.x; L[n * 6 + 1] = q_.y; L[n * 6 + 2] = q_.z; L[n * 6 + 3] = 0; L[n * 6 + 4] = 0; L[n * 6 + 5] = 1; n++; } while (0)
	float deg = (float)M_PI / 180;
	int slices[2] = {n, 0};   // even slices, then odd ones (two shades)
	for (int odd = 0; odd < 2; odd++) {
		if (odd) slices[1] = n;
		for (int k = odd; k < 12; k += 2)
			for (int j = 0; j < 6; j++) { PDP(0, 0); PDP(R, a0 + (k * 30 + j * 5) * deg); PDP(R, a0 + (k * 30 + j * 5 + 5) * deg); }
	}
	int evenN = slices[1] - slices[0], oddN = n - slices[1], spokes = n;
	for (int k = 0; k < 12; k++) { PDP(0, 0); PDP(R, a0 + k * 30 * deg); }
	int spokesN = n - spokes, rim = n;
	for (int k = 0; k < 72; k++) { float ang = a0 + k * 5 * deg; PDP(R, ang); PDP(R * (k % 6 == 0 ? 1.12f : k % 2 == 0 ? 1.08f : 1.05f), ang); }
	int rimN = n - rim, turn = n;
	float turned = _gShown * deg;
	PDP(0, 0); PDP(R, a0);
	PDP(0, 0); PDP(R, a0 + turned);
	int turnN = n - turn, fan = n, steps = MAX(1, MIN(72, (int)ceilf(fabsf(_gShown) / 5)));
	for (int k = 0; k < steps; k++) { PDP(0, 0); PDP(R * 0.92f, a0 + turned * k / steps); PDP(R * 0.92f, a0 + turned * (k + 1) / steps); }
	int fanN = n - fan;
	#undef PDP
	glBindBuffer(GL_ARRAY_BUFFER, _lineVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 6 * sizeof(GLfloat), L, GL_STREAM_DRAW);
	free(L);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
	float k = _gFine ? 0.45f : 1;   // the snapping disc fades back while turning freely outside it
	glUniform4f(_uColor, 1, 1, 1, 0.07f * k); glDrawArrays(GL_TRIANGLES, slices[0], evenN);
	glUniform4f(_uColor, 1, 1, 1, 0.16f * k); glDrawArrays(GL_TRIANGLES, slices[1], oddN);
	if (_gShown != 0) { glUniform4f(_uColor, 1.0f, 0.84f, 0.25f, 0.30f); glDrawArrays(GL_TRIANGLES, fan, fanN); }
	glLineWidth(1.5f);
	glUniform4f(_uColor, 1, 1, 1, 0.55f * k); glDrawArrays(GL_LINES, spokes, spokesN);
	if (_gFine) { glLineWidth(1.5f); glUniform4f(_uColor, 1, 1, 1, 0.85f); glDrawArrays(GL_LINES, rim, rimN); }
	glLineWidth(2.5f);
	glUniform4f(_uColor, 1.0f, 0.84f, 0.25f, 0.95f); glDrawArrays(GL_LINES, turn, turnN);

	// labels: every 30° just outside the ring, and the turn at the current spoke
	for (int i = 0; i < 12; i++) {
		int d = i <= 6 ? i * 30 : (i - 12) * 30;
		[self placeMark:i text:[NSString stringWithFormat:@"%d°", d] at:GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, R * 1.2f * cosf(a0 + i * 30 * deg)),
			GLKVector3MultiplyScalar(v, R * 1.2f * sinf(a0 + i * 30 * deg)))) color:[UIColor colorWithWhite:1 alpha:_gFine ? 0.5f : 0.95f]];
	}
	[self placeMark:12 text:[NSString stringWithFormat:@"%+g°", _gShown] at:GLKVector3Add(c, GLKVector3Add(GLKVector3MultiplyScalar(u, R * 0.55f * cosf(a0 + turned * 0.5f)),
		GLKVector3MultiplyScalar(v, R * 0.55f * sinf(a0 + turned * 0.5f)))) color:[UIColor colorWithRed:1 green:0.84f blue:0.25f alpha:1]];
}

// While an arrow is dragged: a ruler along the axis from where the selection started (1/5/10 mm ticks as the
// zoom allows, every 10 mm (or 50) labelled), the distance moved in yellow, and its length by the arrow.
- (void)drawRuler:(GLKVector3)c base:(float)base {
	GLKVector3 a = PDAxis(_gAxis), o = _gCentre;
	CGPoint p0, p1;
	float ppm = 1;
	if ([self project:o to:&p0] && [self project:GLKVector3Add(o, GLKVector3MultiplyScalar(a, 10)) to:&p1]) ppm = (float)hypot(p1.x - p0.x, p1.y - p0.y) / 10;
	float minor = ppm >= 7 ? 1 : ppm * 5 >= 7 ? 5 : 10, major = minor < 10 ? 10 : (ppm * 10 >= 25 ? 10 : 50);
	GLKVector3 side = GLKVector3CrossProduct(a, GLKVector3Subtract([self eye], o));
	float sl = GLKVector3Length(side);
	side = sl > 1e-4f ? GLKVector3DivideScalar(side, sl) : PDAxis((_gAxis + 1) % 3);
	float d = _gMoved, lo = floorf((MIN(0, d) - 2 * major) / minor) * minor, hi = MAX(0, d) + 2 * major;
	enum { CAP = 2 * 402 + 4 };
	GLfloat *L = malloc(CAP * 6 * sizeof(GLfloat));
	if (!L) return;
	int n = 0;
	#define PDR(P) do { GLKVector3 q_ = (P); L[n * 6] = q_.x; L[n * 6 + 1] = q_.y; L[n * 6 + 2] = q_.z; L[n * 6 + 3] = 0; L[n * 6 + 4] = 0; L[n * 6 + 5] = 1; n++; } while (0)
	int mark = 0;
	for (float t = lo; t <= hi + 1e-3f && n < 2 * 400; t += minor) {
		BOOL big = fabsf(remainderf(t, major)) < 1e-3f;
		GLKVector3 q = GLKVector3Add(o, GLKVector3MultiplyScalar(a, t));
		PDR(q); PDR(GLKVector3Add(q, GLKVector3MultiplyScalar(side, base * (big ? 0.45f : 0.22f))));
		if (big && mark < 12) [self placeMark:mark++ text:[NSString stringWithFormat:@"%g", roundf(t)] at:GLKVector3Add(q, GLKVector3MultiplyScalar(side, base * 0.75f))
			color:[UIColor colorWithWhite:1 alpha:0.8f]];
	}
	for (; mark < 12; mark++) [self placeMark:mark text:nil at:o color:nil];
	int ticksN = n, moved = n;
	PDR(o); PDR(GLKVector3Add(o, GLKVector3MultiplyScalar(a, d)));
	#undef PDR
	glBindBuffer(GL_ARRAY_BUFFER, _lineVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 6 * sizeof(GLfloat), L, GL_STREAM_DRAW);
	free(L);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
	glLineWidth(1.5f);
	glUniform4f(_uColor, 1, 1, 1, 0.7f); glDrawArrays(GL_LINES, 0, ticksN);
	glLineWidth(5.0f);
	glUniform4f(_uColor, 1.0f, 0.84f, 0.25f, 0.95f); glDrawArrays(GL_LINES, moved, 2);
	static const char *names[3] = {"X", "Y", "Z"};
	float s = self.snap > 0 ? self.snap : 1;
	[self placeMark:12 text:[NSString stringWithFormat:s < 1 ? @"%s %+.1f mm" : @"%s %+.0f mm", names[_gAxis], d]
		at:GLKVector3Add(GLKVector3Add(o, GLKVector3MultiplyScalar(a, d)), GLKVector3MultiplyScalar(side, -base * 0.9f)) color:[UIColor colorWithRed:1 green:0.84f blue:0.25f alpha:1]];
}

// The overlay labels (12 scale marks and one value), placed over 3D points; nil text hides one.
- (void)placeMark:(int)i text:(NSString *)t at:(GLKVector3)p color:(UIColor *)col {
	if (!self.marks) {
		NSMutableArray *a = [NSMutableArray array];
		for (int k = 0; k < 13; k++) {
			UILabel *l = PDLabel([UIFont boldSystemFontOfSize:k == 12 ? 15 : 11], [UIColor whiteColor]);
			l.textAlignment = NSTextAlignmentCenter;
			l.backgroundColor = [UIColor colorWithWhite:0 alpha:k == 12 ? 0.7f : 0.45f];
			l.layer.cornerRadius = 6;
			l.clipsToBounds = YES;
			l.userInteractionEnabled = NO;
			l.hidden = YES;
			[self insertSubview:l belowSubview:self.messageBox];
			[a addObject:l];
		}
		self.marks = a;
	}
	UILabel *l = [self.marks objectAtIndex:(NSUInteger)i];
	CGPoint sp;
	if (!t || ![self project:p to:&sp]) { l.hidden = YES; return; }
	l.text = t;
	l.textColor = col;
	CGSize sz = [t sizeWithFont:l.font];
	l.frame = CGRectMake(round(sp.x - sz.width / 2 - 5), round(sp.y - sz.height / 2 - 1), sz.width + 10, sz.height + 2);
	l.hidden = NO;
}

- (void)hideMarks { for (UILabel *l in self.marks) l.hidden = YES; }

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	glClearColor(0.055f, 0.065f, 0.085f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	_vp = [self viewProjection];
	for (PDGLMesh *m in [self.meshes allValues]) m.used = NO;
	if (_dragMode != 3 && _dragMode != 4) [self hideMarks];

	glUseProgram(_prog);
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_LEQUAL);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	GLKMatrix3 ident = GLKMatrix3Identity;

	// plate and grid
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, _vp.m);
	glUniformMatrix3fv(_uNrm, 1, GL_FALSE, ident.m);
	glUniform1f(_uLit, 0);
	glDepthMask(GL_FALSE);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
	glUniform4f(_uColor, 0.16f, 0.17f, 0.19f, 1);
	glDrawArrays(GL_TRIANGLES, 0, _plateVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.05f);
	glDrawArrays(GL_LINES, _plateVerts, _minorVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.12f);
	glDrawArrays(GL_LINES, _plateVerts + _minorVerts, _majorVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.25f);
	glDrawArrays(GL_LINES, _plateVerts + _minorVerts + _majorVerts, _areaVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.5f);
	glLineWidth(2.0f);
	glDrawArrays(GL_LINES, _plateVerts + _minorVerts + _majorVerts + _areaVerts, _edgeVerts);
	glLineWidth(1.0f);
	glDepthMask(GL_TRUE);

	// solids
	glUniform1f(_uLit, 1);
	NSUInteger i = 0;
	for (PDShape *s in self.shapes) {
		if (!s.hole) {
			[self setColor:s.color alpha:1 lift:[self.selection containsIndex:i] ? 0.22f : 0];
			[self drawShape:s];
		}
		i++;
	}
	// holes: see-through, front faces only
	glDepthMask(GL_FALSE);
	glEnable(GL_CULL_FACE);
	glCullFace(GL_BACK);
	i = 0;
	for (PDShape *s in self.shapes) {
		if (s.hole) {
			GLKMatrix3 r = GLKMatrix4GetMatrix3(s.matrix);
			float det = r.m00 * (r.m11 * r.m22 - r.m12 * r.m21) - r.m01 * (r.m10 * r.m22 - r.m12 * r.m20) + r.m02 * (r.m10 * r.m21 - r.m11 * r.m20);
			glFrontFace(det < 0 ? GL_CW : GL_CCW);
			BOOL sel = [self.selection containsIndex:i];
			glUniform4f(_uColor, sel ? 0.55f : 0.62f, sel ? 0.78f : 0.64f, sel ? 1.0f : 0.70f, sel ? 0.45f : 0.32f);
			[self drawShape:s];
		}
		i++;
	}
	glFrontFace(GL_CCW);
	glDisable(GL_CULL_FACE);
	glDepthMask(GL_TRUE);

	// the selection's box (world bounds), and its footprint on the plate
	if ([self.selection count]) {
		GLKVector3 lo = GLKVector3Make(1e30f, 1e30f, 1e30f), hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
		NSArray *shapes = self.shapes;
		for (NSUInteger k = [self.selection firstIndex]; k != NSNotFound; k = [self.selection indexGreaterThanIndex:k]) {
			if (k >= [shapes count]) continue;
			PDShape *s = [shapes objectAtIndex:k];
			lo = GLKVector3Minimum(lo, [s worldMin]); hi = GLKVector3Maximum(hi, [s worldMax]);
		}
		if (lo.x <= hi.x) {
			GLfloat L[24 * 6 + 8 * 6];
			int n = 0;
			float xs[2] = {lo.x, hi.x}, ys[2] = {lo.y, hi.y}, zs[2] = {lo.z, hi.z};
			#define PDL(X, Y, Z) do { L[n * 6] = (X); L[n * 6 + 1] = (Y); L[n * 6 + 2] = (Z); L[n * 6 + 3] = 0; L[n * 6 + 4] = 0; L[n * 6 + 5] = 1; n++; } while (0)
			for (int a = 0; a < 2; a++) for (int b = 0; b < 2; b++) {
				PDL(xs[0], ys[a], zs[b]); PDL(xs[1], ys[a], zs[b]);
				PDL(xs[a], ys[0], zs[b]); PDL(xs[a], ys[1], zs[b]);
				PDL(xs[a], ys[b], zs[0]); PDL(xs[a], ys[b], zs[1]);
			}
			int box = n;
			PDL(lo.x, lo.y, 0.02f); PDL(hi.x, lo.y, 0.02f); PDL(hi.x, lo.y, 0.02f); PDL(hi.x, hi.y, 0.02f);
			PDL(hi.x, hi.y, 0.02f); PDL(lo.x, hi.y, 0.02f); PDL(lo.x, hi.y, 0.02f); PDL(lo.x, lo.y, 0.02f);
			#undef PDL
			glBindBuffer(GL_ARRAY_BUFFER, _lineVbo);
			glBufferData(GL_ARRAY_BUFFER, n * 6 * sizeof(GLfloat), L, GL_STREAM_DRAW);
			glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0);
			glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (const void *)12);
			glUniformMatrix4fv(_uMVP, 1, GL_FALSE, _vp.m);
			glUniformMatrix3fv(_uNrm, 1, GL_FALSE, ident.m);
			glUniform1f(_uLit, 0);
			glDisable(GL_DEPTH_TEST);
			glLineWidth(1.5f);
			glUniform4f(_uColor, 0.35f, 0.75f, 1.0f, 0.9f);
			glDrawArrays(GL_LINES, 0, box);
			glUniform4f(_uColor, 0.35f, 0.75f, 1.0f, 0.5f);
			glDrawArrays(GL_LINES, box, n - box);
			glLineWidth(1.0f);
			glEnable(GL_DEPTH_TEST);
		}
		if (self.gizmo) [self drawGizmo];
	}
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glDisableVertexAttribArray(0);
	glDisableVertexAttribArray(1);

	[self updateTurnInfo];

	// meshes no shape uses any more
	for (NSValue *k in [self.meshes allKeys]) {
		PDGLMesh *m = [self.meshes objectForKey:k];
		if (!m.used) { GLuint b = m.vbo; glDeleteBuffers(1, &b); [self.meshes removeObjectForKey:k]; }
	}
}

@end
