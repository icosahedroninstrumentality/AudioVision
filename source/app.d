import std.stdio;
import std.string;
import std.array;
import std.conv;
import std.algorithm;
import std.process;
import std.exception;
import jitkernel;

import core.sys.posix.unistd;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

enum WINDOW_W = Radian(256);
enum WINDOW_H = Radian(256);
enum MAX_BAR_VALUE = Radian(1000);
enum BARNUMi = 256;
enum BARNUM = Radian(BARNUMi);

int barsCount;
Radian[] bars = new Radian[256];

ProcessPipes cavaPipe;

// Persistent buffer to accumulate partial data across frames
char[] buffer;

void spawnCava() {
	string[] args = ["cava", "-p", "./cava_config"];
	cavaPipe = pipeProcess(args);
	fcntl(cavaPipe.stdout.fileno, F_SETFL, O_NONBLOCK);
}

void pollCava () { try {
	import core.sys.posix.unistd : read;
	import std.algorithm.iteration : splitter;
	import std.conv : to;

	// 1. Read new data and append to accumulation buffer
	char[4096] tmp;
	auto n = read(cavaPipe.stdout.fileno, tmp.ptr, tmp.length);
	if (n > 0) {
		buffer ~= tmp[0 .. n];
	}

	if (buffer.length < 2) return;
	while (buffer[0] != '\n') {
		if (buffer.length < 2) return;
		buffer = buffer[1 .. $];
	}

	ulong newlines = 0;
	foreach (char c; buffer) if (c == '\n') newlines++;
	if (newlines == 1) return;
	
	ulong lineEnd;
	for (ulong i = 1; i < buffer.length; i++) {
		if (buffer[i] == '\n') lineEnd = i;
	}

	char[] line = buffer[1 .. lineEnd];
	if (newlines > 2) buffer = []; // don't handle out of control buffers
	else buffer = buffer[lineEnd - 1 .. $]; // remove found line
	
	if (line.length == 0) return;

	int idx = 0;
	foreach (token; splitter(line, ';')) {
		if (token.length == 0) continue;
		try {
			if (idx < bars.length) {
				bars[idx] = Radian(to!float(token)) / MAX_BAR_VALUE;
				idx++;
			} else break;
		} catch (Exception) { }
	}
} catch (Exception e) {}}

ulong rand = 19230281737;
jitkernel.Vector2 random = jitkernel.Vector2(Radian.zero, Radian.zero);

void main() {
	Kernel blob = new Kernel((Kernel k) {
		KernelStored!(Radian[]) levels = k.link!(Radian[])(bars, BARNUMi);
		KernelStored!Vector2 offset = k.link(random);
		auto uv = k.uv;
		auto sub = levels[127]+levels[128];
		auto high = levels[0]+levels[255];
		auto center = k.compose(Radian(0.5), Radian(0.5));
		auto p = uv - center + offset * sub * k.literal!Radian(Radian(1) / WINDOW_W * Radian(16));
		auto distv = (k.length(p) * Radian(2)).clamp(Radian.zero, Radian.one);
		
		auto angle = (k.atan2(p.component!"x", Radian.zero-p.component!"y") / Radian(6.283185307179586) + Radian.one) * Radian(0.5);
		auto levelIndex = (angle * Radian(BARNUM)).clamp(Radian.zero, BARNUM - Radian(1)).opCast!int;
		auto level = levels[levelIndex];
		
		auto dist = k.abs(distv - Radian(0.5) * level) * (Radian.one + level);
		auto invdist = (Radian.one - dist).clamp(Radian.zero, Radian.one);

		auto l = Radian.one - k.pow(Radian.one - level, k.pi);
		auto d = k.pow(invdist, Radian.two);
		auto burst = k.pow(d, Radian(5) - (l+sub) * Radian.two);
		auto star = burst + d * l * Radian.two - sub;
		auto hue = level + Radian(.1) - sub + high * Radian(2);
		auto rgb = (k.compose(
			k.cos((hue) * invdist * k.pi * Radian.two),
			k.cos((hue) * invdist * k.pi * Radian.two - Radian.two * k.pi / Radian(3)),
			k.cos((hue) * invdist * k.pi * Radian.two + Radian.two * k.pi / Radian(3)),
		)) * d * l + star;
		
		k.output(k.compose(rgb.component!"x", rgb.component!"y", rgb.component!"z", d * l + star));
	});

	{
		import bindbc.opengl;
		import raylib;

		SetConfigFlags(
			ConfigFlags.FLAG_BORDERLESS_WINDOWED_MODE |
				ConfigFlags.FLAG_WINDOW_TRANSPARENT |
				ConfigFlags.FLAG_WINDOW_MOUSE_PASSTHROUGH |
				ConfigFlags.FLAG_WINDOW_UNDECORATED |
				ConfigFlags.FLAG_WINDOW_ALWAYS_RUN |
				ConfigFlags.FLAG_WINDOW_UNFOCUSED |
				ConfigFlags.FLAG_WINDOW_TOPMOST |
				ConfigFlags.FLAG_WINDOW_HIGHDPI
		);

		InitWindow(cast (int) WINDOW_W.raw, cast (int) WINDOW_H.raw, "AudioVision");
		auto openglSupport = loadOpenGL();
		if (openglSupport == GLSupport.noLibrary || openglSupport < GLSupport.gl33)
			throw new Exception("OpenGL 3.3+ is required for JITKernel");
		SetTargetFPS(30);

		Vector2 target = Vector2(
			GetMonitorWidth(GetCurrentMonitor()) / 2.0f - WINDOW_W.raw / 2.0f,
			0
		);
		SetWindowPosition(cast(int) target.x, cast(int) target.y);

		jitkernel.Texture.screen = new jitkernel.Texture(jitkernel.Vector2(WINDOW_W, WINDOW_H));

		spawnCava();

		while (!WindowShouldClose()) {
			rand *= 92370;
			rand += 3242938746;
			rand %= 194652042630542;
			random.x = Radian((Radian(rand) / Radian(10000)) % Radian(1));
			rand *= 92370;
			rand += 3242938746;
			rand %= 194652042630542;
			random.y = Radian((Radian(rand) / Radian(10000)) % Radian(1));

			pollCava();
			BeginDrawing();
			BeginBlendMode(BlendMode.BLEND_ADDITIVE);

			if (bars.length == BARNUMi) {
				jitkernel.Texture.clearRaw(jitkernel.Vector4.zero);
				blob.draw(jitkernel.Texture.raw, jitkernel.Texture.screen.rect);
			}
			EndDrawing();
		}

		CloseWindow();
	}
}
