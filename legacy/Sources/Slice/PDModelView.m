#import "PDModelView.h"
#import "PDSlicer.h"
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/gl.h>
#import "PDBedShape.h"

#define PD_MODEL_VIEW_MAX_TRIS 150000   // display budget for the A4's GPU; more are thinned evenly

static const char *PDMVS =
	"attribute vec3 aPos;\n"
	"attribute vec3 aNrm;\n"
	"uniform mat4 uMVP;\n"
	"uniform mat3 uRot;\n"
	"uniform vec4 uColor;\n"
	"uniform float uLit;\n"
	"varying lowp vec4 vColor;\n"
	"void main() {\n"
	"  gl_Position = uMVP * vec4(aPos, 1.0);\n"
	"  vec3 n = normalize(uRot * aNrm + vec3(0.0, 0.0, 1e-4));\n"
	"  float d = max(dot(n, normalize(vec3(-0.45, -0.6, 0.75))), 0.0);\n"
	"  float back = max(dot(n, normalize(vec3(0.6, 0.5, 0.2))), 0.0);\n"
	"  float k = mix(1.0, 0.32 + 0.62 * d + 0.18 * back, uLit);\n"
	"  vColor = vec4(uColor.rgb * k, uColor.a);\n"
	"}\n";

static const char *PDMFS =
	"varying lowp vec4 vColor;\n"
	"void main() { gl_FragColor = vColor; }\n";

@interface PDModelView () <GLKViewDelegate> {
	GLuint _prog, _vbo, _bedVbo;
	GLint _uMVP, _uRot, _uColor, _uLit;
	GLsizei _bedVerts, _verts, _plateVerts, _gridVerts, _areaVerts;   // bed VBO: plate, grid, printable area, plate edge
	BOOL _needsUpload;
}
@property (nonatomic, strong) EAGLContext *ctx;
@property (nonatomic, strong) GLKView *glView;
@property (nonatomic) float azimuth, elevation, zoom, minZoom;
@end

@implementation PDModelView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
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
		UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetView)];
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

static GLuint PDMCompile(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log); NSLog(@"PrintDeck: model shader: %s", log); }
	return s;
}

- (void)setupGL {
	[EAGLContext setCurrentContext:self.ctx];
	GLuint vs = PDMCompile(GL_VERTEX_SHADER, PDMVS), fs = PDMCompile(GL_FRAGMENT_SHADER, PDMFS);
	_prog = glCreateProgram();
	glAttachShader(_prog, vs); glAttachShader(_prog, fs);
	glBindAttribLocation(_prog, 0, "aPos");
	glBindAttribLocation(_prog, 1, "aNrm");
	glLinkProgram(_prog);
	glDeleteShader(vs); glDeleteShader(fs);
	_uMVP = glGetUniformLocation(_prog, "uMVP");
	_uRot = glGetUniformLocation(_prog, "uRot");
	_uColor = glGetUniformLocation(_prog, "uColor");
	_uLit = glGetUniformLocation(_prog, "uLit");
	// Bed: the physical plate (PDBedShape.h, triangles just under z = 0), the grid every 32 mm and the outline of the
	// printable area, then the plate's own edge (float xyz + 3 normal bytes + pad, like the model's vertices).
	int cap = PDBedTriCount * 3 + 2 * 14 * 2 + 8 + PDBedEdgeCount * 2;
	GLfloat *bed = calloc((size_t)cap * 4, sizeof(GLfloat));
	int n = 0;
	#define PDV(X, Y, Z) do { bed[n * 4] = (X); bed[n * 4 + 1] = (Y); bed[n * 4 + 2] = (Z); n++; } while (0)
	for (int i = 0; i < PDBedTriCount * 3; i++) PDV(PDBedTris[i * 2], PDBedTris[i * 2 + 1], -0.05f);
	_plateVerts = n;
	for (int i = 1; i < 8; i++) { GLfloat c = i * 32.0f; PDV(c, 0, 0); PDV(c, PD_BED_MM, 0); PDV(0, c, 0); PDV(PD_BED_MM, c, 0); }
	_gridVerts = n - _plateVerts;
	GLfloat area[5][2] = {{0, 0}, {PD_BED_MM, 0}, {PD_BED_MM, PD_BED_MM}, {0, PD_BED_MM}, {0, 0}};
	for (int k = 0; k < 4; k++) { PDV(area[k][0], area[k][1], 0); PDV(area[k + 1][0], area[k + 1][1], 0); }
	_areaVerts = 8;
	for (int i = 0; i < PDBedEdgeCount; i++) { PDV(PDBedOutline[i * 4], PDBedOutline[i * 4 + 1], -0.02f); PDV(PDBedOutline[i * 4 + 2], PDBedOutline[i * 4 + 3], -0.02f); }
	#undef PDV
	_bedVerts = n;
	glGenBuffers(1, &_bedVbo);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glBufferData(GL_ARRAY_BUFFER, n * 4 * sizeof(GLfloat), bed, GL_STATIC_DRAW);
	free(bed);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
}

- (void)setModel:(PDModel *)m {
	if (m == _model) return;
	_model = m;
	_needsUpload = YES;
	[self resetView];
}

- (void)setWarn:(BOOL)w { if (w != _warn) { _warn = w; [self redraw]; } }
- (void)modelTransformChanged { [self redraw]; }

// Triangles -> vertices of float xyz + a face normal in 3 signed bytes (+1 pad): 16 bytes each.
- (void)upload {
	_needsUpload = NO;
	if (!_vbo) glGenBuffers(1, &_vbo);
	glBindBuffer(GL_ARRAY_BUFFER, _vbo);
	PDModel *m = self.model;
	NSUInteger nt = m.triangleCount;
	NSUInteger step = nt > PD_MODEL_VIEW_MAX_TRIS ? (nt + PD_MODEL_VIEW_MAX_TRIS - 1) / PD_MODEL_VIEW_MAX_TRIS : 1;
	NSUInteger keep = nt ? (nt + step - 1) / step : 0;
	uint8_t *buf = keep ? malloc(keep * 3 * 16) : NULL;
	const float *t = m.triangles;
	NSUInteger k = 0;
	for (NSUInteger i = 0; i < nt; i += step, k++) {
		const float *a = t + i * 9;
		GLKVector3 p0 = GLKVector3Make(a[0], a[1], a[2]), p1 = GLKVector3Make(a[3], a[4], a[5]), p2 = GLKVector3Make(a[6], a[7], a[8]);
		GLKVector3 nrm = GLKVector3CrossProduct(GLKVector3Subtract(p1, p0), GLKVector3Subtract(p2, p0));
		float l = GLKVector3Length(nrm);
		nrm = l > 0 ? GLKVector3DivideScalar(nrm, l) : GLKVector3Make(0, 0, 1);
		int8_t nb[4] = {(int8_t)lroundf(nrm.x * 127), (int8_t)lroundf(nrm.y * 127), (int8_t)lroundf(nrm.z * 127), 0};
		for (int v = 0; v < 3; v++) {
			uint8_t *o = buf + (k * 3 + v) * 16;
			memcpy(o, a + v * 3, 12);
			memcpy(o + 12, nb, 4);
		}
	}
	glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(keep * 3 * 16), buf, GL_STATIC_DRAW);
	free(buf);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	_verts = (GLsizei)(keep * 3);
}

- (void)resetView { self.azimuth = -0.55f; self.elevation = 0.50f; self.zoom = 1.0f; [self redraw]; }

- (void)redraw {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	[self.glView setNeedsDisplay];
}

- (void)pan:(UIPanGestureRecognizer *)g {
	CGPoint t = [g translationInView:self];
	[g setTranslation:CGPointZero inView:self];
	self.azimuth -= t.x * 0.010f;
	self.elevation = MAX(-0.3f, MIN(1.50f, self.elevation + t.y * 0.008f));
	[self redraw];
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
	self.zoom = MAX(self.minZoom, MIN(12.0f, self.zoom * g.scale));
	g.scale = 1.0;
	[self redraw];
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
	if (_needsUpload) [self upload];
	glClearColor(0.055f, 0.065f, 0.085f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	PDModel *m = self.model;
	GLKVector3 size = m ? [m size] : GLKVector3Make(40, 40, 20), lo = m ? [m minCorner] : GLKVector3Make(0, 0, 0);
	// Placement, as the slicer does it: centred on the bed, standing on z = 0.
	GLKMatrix3 r = m ? [m matrix] : GLKMatrix3Identity;
	GLKVector3 off = GLKVector3Make(PD_BED_MM / 2 - (lo.x + size.x / 2), PD_BED_MM / 2 - (lo.y + size.y / 2), -lo.z);
	GLKMatrix4 place = GLKMatrix4Make(r.m00, r.m01, r.m02, 0, r.m10, r.m11, r.m12, 0, r.m20, r.m21, r.m22, 0, off.x, off.y, off.z, 1);

	// Zoom 1 fits the part (at the plate's centre, where the slicer puts it); zooming out shows the whole plate.
	float br = 0.5f * sqrtf(262.0f * 262.0f + 278.0f * 278.0f + size.z * size.z), pr = MAX(20.0f, 0.5f * GLKVector3Length(size));
	float toPlate = self.zoom >= 1 || br <= pr ? 0 : MIN(1.0f, logf(1 / self.zoom) / logf(br / pr));
	GLKVector3 target = GLKVector3Make(PD_BED_MM / 2, PD_BED_MM / 2 - 2 * toPlate, size.z * (0.5f - 0.25f * toPlate));
	float radius = pr + (br - pr) * toPlate;
	self.minZoom = br > pr ? 0.9f * pr / br : 1;
	float aspect = view.drawableWidth > 0 && view.drawableHeight > 0 ? (float)view.drawableWidth / view.drawableHeight : 1;
	const float fov = GLKMathDegreesToRadians(32);
	float dist = pr * 1.25f / (tanf(fov / 2) * MIN(1.0f, aspect)) / self.zoom;
	float ce = cosf(self.elevation);
	GLKVector3 eye = GLKVector3Make(target.x + dist * ce * sinf(self.azimuth), target.y - dist * ce * cosf(self.azimuth), target.z + dist * sinf(self.elevation));
	float nearZ = MAX(1.0f, dist - radius * 4), farZ = dist + radius * 6 + PD_BED_MM * 2;
	GLKMatrix4 vp = GLKMatrix4Multiply(GLKMatrix4MakePerspective(fov, aspect, nearZ, farZ),
		GLKMatrix4MakeLookAt(eye.x, eye.y, eye.z, target.x, target.y, target.z, 0, 0, 1));

	glUseProgram(_prog);
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_LEQUAL);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);

	// bed
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, vp.m);
	GLKMatrix3 ident = GLKMatrix3Identity;
	glUniformMatrix3fv(_uRot, 1, GL_FALSE, ident.m);
	glUniform1f(_uLit, 0);
	glDepthMask(GL_FALSE);
	glBindBuffer(GL_ARRAY_BUFFER, _bedVbo);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 16, 0);
	glVertexAttribPointer(1, 3, GL_BYTE, GL_TRUE, 16, (const void *)12);
	glUniform4f(_uColor, 0.16f, 0.17f, 0.19f, 1);   // the plate
	glDrawArrays(GL_TRIANGLES, 0, _plateVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.08f);
	glDrawArrays(GL_LINES, _plateVerts, _gridVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.22f);   // the printable area
	glDrawArrays(GL_LINES, _plateVerts + _gridVerts, _areaVerts);
	glUniform4f(_uColor, 1, 1, 1, 0.5f);   // the plate's edge
	glLineWidth(2.0f);
	glDrawArrays(GL_LINES, _plateVerts + _gridVerts + _areaVerts, _bedVerts - _plateVerts - _gridVerts - _areaVerts);
	glLineWidth(1.0f);
	glDepthMask(GL_TRUE);

	// model
	if (m && _verts) {
		GLKMatrix4 mvp = GLKMatrix4Multiply(vp, place);
		glUniformMatrix4fv(_uMVP, 1, GL_FALSE, mvp.m);
		// Normals only need the rotation; the scale is uniform and positive, and the shader renormalises.
		glUniformMatrix3fv(_uRot, 1, GL_FALSE, r.m);
		glUniform1f(_uLit, 1);
		if (self.warn) glUniform4f(_uColor, 1.0f, 0.42f, 0.36f, 1);
		else glUniform4f(_uColor, 0.38f, 0.72f, 1.0f, 1);
		glBindBuffer(GL_ARRAY_BUFFER, _vbo);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 16, 0);
		glVertexAttribPointer(1, 3, GL_BYTE, GL_TRUE, 16, (const void *)12);
		glDrawArrays(GL_TRIANGLES, 0, _verts);
	}
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glDisableVertexAttribArray(0);
	glDisableVertexAttribArray(1);
}

@end
