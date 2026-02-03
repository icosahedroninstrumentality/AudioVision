import std.stdio;
import std.string;
import std.array;
import std.conv;
import std.algorithm;
import std.process;
import std.exception;

import core.sys.posix.unistd;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

import raylib;

enum WINDOW_W = 256;
enum WINDOW_H = 64 + 16;
enum MAX_BAR_VALUE = 2048;

int[] bars;

ProcessPipes cavaPipe;

void spawnCava () {
	string[] args = [
		"cava", "-p", "./cava_config"
	];

	cavaPipe = pipeProcess(args);

	// Set non-blocking mode
	fcntl(cavaPipe.stdout.fileno, F_SETFL, O_NONBLOCK);
}

void pollCava () {
	import core.sys.posix.unistd : read;

	char[1028] buf;
	auto n = read(cavaPipe.stdout.fileno, buf.ptr, buf.length);
	if (n <= 0) return; // nothing to read

	auto data = cast(string)buf[0 .. n];

	foreach (line; data.split("\n")) {
		if (line.length == 0) continue;

		try {
			bars = line
				.strip()
				.split(';')
				.filter!(s => s.length)
				.map!(to!int)
				.array;
		} catch (Exception) {
			// ignore bad lines
		}
	}
}

void main () {
	SetConfigFlags(
		ConfigFlags.FLAG_BORDERLESS_WINDOWED_MODE |
		ConfigFlags.FLAG_WINDOW_TRANSPARENT |
		ConfigFlags.FLAG_WINDOW_MOUSE_PASSTHROUGH |
		ConfigFlags.FLAG_WINDOW_UNDECORATED |
		ConfigFlags.FLAG_WINDOW_ALWAYS_RUN |
		ConfigFlags.FLAG_WINDOW_UNFOCUSED |
		ConfigFlags.FLAG_WINDOW_TOPMOST
	);

	InitWindow(WINDOW_W, WINDOW_H, "AudioVision");
	SetTargetFPS(30);

	spawnCava();

	while (!WindowShouldClose()) {
		// center on screen horizontally
		Vector2 pos = GetWindowPosition();
		Vector2 target = Vector2(GetMonitorWidth(GetCurrentMonitor()) / 2 - cast (float) WINDOW_W / 2, 32);
		if (pos.x != target.x || pos.y != target.y) SetWindowPosition(cast (int) target.x, cast (int) target.y);

		pollCava();
		import core.thread;
		import core.time;
		Thread.sleep(1.msecs);

		if (bars.length == 128) {
			BeginDrawing();
			ClearBackground(Colors.BLANK);
			float barW = cast(float)WINDOW_W / bars.length;
			foreach (i, v; bars)
			{
				import std.math;
				
				float xNorm = cast(float)i / cast(float)bars.length;

				float barHeight = (cast(float)v / 64.0) * (WINDOW_H / 2);
				float centerY = WINDOW_H / 2.0;

				ubyte r = cast(ubyte)clamp(256.0 * pow(1.0 - abs(xNorm - 0.5), 5.0) + 64, 0.0, 255.0);
				ubyte g = cast(ubyte)clamp(256.0 * abs(xNorm - 0.5) + 64, 0.0, 255.0);

				DrawRectangle(
					cast(int)(i * barW),
					cast(int)(centerY - barHeight),
					cast(int)barW - 1,
					cast(int)(barHeight * 2),
					Color(r, g, 64)
				);
			}
			EndDrawing();
		}
	}

	CloseWindow();
}
