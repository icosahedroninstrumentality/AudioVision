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

enum WINDOW_W = Radian(220);
enum WINDOW_H = Radian(220);
enum MAX_BAR_VALUE = Radian(1000);

Radian[256] barsBuffer;
int barsCount;
Radian[] bars;

ProcessPipes cavaPipe;

// Persistent buffer to accumulate partial data across frames
char[4096] accumBuffer;
size_t accumLen;

void spawnCava()
{
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
	if (n > 0)
	{
		if (accumLen + n <= accumBuffer.length)
		{
			accumBuffer[accumLen .. accumLen + n] = tmp[0 .. n];
			accumLen += n;
		}
		else
		{
			// Buffer overflow – discard everything to avoid infinite growth
			accumLen = 0;
			return;
		}
	}

	// 2. Process complete lines
	size_t lineStart = 0;
	for (size_t i = 0; i < accumLen; ++i)
	{
		if (accumBuffer[i] == '\n')
		{
			// Found a complete line
			auto line = accumBuffer[lineStart .. i];
			lineStart = i + 1;

			// Skip empty lines
			if (line.length == 0)
				continue;

			int idx = 0;
			foreach (token; splitter(line, ';'))
			{
				if (token.length == 0)
					continue;
				try
				{
					if (idx < barsBuffer.length)
					{
						barsBuffer[idx] = Radian(to!float(token));
						idx++;
					}
					else
						break;
				}
				catch (Exception)
				{
				}
			}

			bars = new Radian[256];
			for (int x = 0; x < idx; ++x)
			{
				bars[x] = barsBuffer[x].clamp(Radian.zero, MAX_BAR_VALUE) / MAX_BAR_VALUE;
			}
		}
	}

	// 3. Remove processed lines from buffer
	if (lineStart > 0)
	{
		if (lineStart < accumLen)
		{
			// Shift remaining partial data to front
			accumBuffer[0 .. accumLen - lineStart] = accumBuffer[lineStart .. accumLen];
			accumLen -= lineStart;
		}
		else
		{
			accumLen = 0;
		}
	}
} catch (Exception e) {}}

void main()
{
	Kernel blob = new Kernel((Kernel k) {
		KernelStored!(Radian[]) levels = k.link!(Radian[])(bars, 256);
		auto uv = k.uv;
		auto center = k.compose(Radian(0.5), Radian(0.5));
		auto p = uv - center;
		
		auto angle = (k.atan2(p.component!"x", Radian.zero-p.component!"y") / Radian(6.283185307179586) + Radian.one) * Radian(0.5);
		auto levelIndex = (angle * Radian(256)).clamp(Radian.zero, Radian(255)).opCast!int;
		auto level = levels[levelIndex];
		
		auto dist = (k.length(p) * Radian(2)).clamp(Radian.zero, Radian.one);
		auto invdist = (Radian.one - dist).clamp(Radian.zero, Radian.one);

		auto l = level * level;
		auto d = k.pow(invdist, Radian.two);
		auto burst = k.pow(d, Radian(5));
		auto star = burst + d * level * Radian.two;
		auto rgb = (k.compose(
			k.cos(l * invdist * k.pi * Radian.two),
			k.cos(l * invdist * k.pi * Radian.two - Radian.two * k.pi / Radian(3)),
			k.cos(l * invdist * k.pi * Radian.two + Radian.two * k.pi / Radian(3)),
		)) * d * l + star;
		
		k.output(k.compose(rgb.component!"x", rgb.component!"y", rgb.component!"z", d * l + star));
	});

	Vector4 rect = Vector4(
		Radian(0),
		Radian(0),
		Radian(WINDOW_W),
		Radian(WINDOW_H),
	);

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
			32
		);
		SetWindowPosition(cast(int) target.x, cast(int) target.y);

		jitkernel.Texture.screen = new jitkernel.Texture(jitkernel.Vector2(WINDOW_W, WINDOW_H));

		spawnCava();

		while (!WindowShouldClose())
		{
			pollCava();
			BeginDrawing();

			if (bars.length == 256)
			{
				jitkernel.Texture.clearRaw(jitkernel.Vector4.zero);
				blob.draw(jitkernel.Texture.raw, jitkernel.Texture.screen.rect);
			}
			EndDrawing();
		}

		CloseWindow();
	}
}
