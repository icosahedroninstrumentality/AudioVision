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

enum WINDOW_W = 220;
enum WINDOW_H = 220;
enum MAX_BAR_VALUE = 64;

float[256] barsBuffer;
int barsCount;
float[] bars;

ProcessPipes cavaPipe;

// Persistent buffer to accumulate partial data across frames
char[4096] accumBuffer;
size_t accumLen;

void spawnCava() {
	string[] args = ["cava", "-p", "./cava_config"];
	cavaPipe = pipeProcess(args);
	fcntl(cavaPipe.stdout.fileno, F_SETFL, O_NONBLOCK);
}

void pollCava() {
	import core.sys.posix.unistd : read;
	import std.algorithm.iteration : splitter;
	import std.conv : to;

	// 1. Read new data and append to accumulation buffer
	char[4096] tmp;
	auto n = read(cavaPipe.stdout.fileno, tmp.ptr, tmp.length);
	if (n > 0) {
		if (accumLen + n <= accumBuffer.length) {
			accumBuffer[accumLen .. accumLen + n] = tmp[0 .. n];
			accumLen += n;
		} else {
			// Buffer overflow – discard everything to avoid infinite growth
			accumLen = 0;
			return;
		}
	}

	// 2. Process complete lines
	size_t lineStart = 0;
	for (size_t i = 0; i < accumLen; ++i) {
		if (accumBuffer[i] == '\n') {
			// Found a complete line
			auto line = accumBuffer[lineStart .. i];
			lineStart = i + 1;

			// Skip empty lines
			if (line.length == 0) continue;

			int idx = 0;
			foreach (token; splitter(line, ';')) {
				if (token.length == 0) continue;
				try {
					if (idx < barsBuffer.length) {
						barsBuffer[idx] = to!float(token);
						idx++;
					} else break;
				} catch (Exception) {}
			}

			barsCount = idx;
			bars = barsBuffer[0 .. idx];
		}
	}

	// 3. Remove processed lines from buffer
	if (lineStart > 0) {
		if (lineStart < accumLen) {
			// Shift remaining partial data to front
			accumBuffer[0 .. accumLen - lineStart] = accumBuffer[lineStart .. accumLen];
			accumLen -= lineStart;
		} else {
			accumLen = 0;
		}
	}
}

void main() {
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

	// Center window once at startup
	Vector2 target = Vector2(
		GetMonitorWidth(GetCurrentMonitor()) / 2.0f - WINDOW_W / 2.0f,
		32
	);
	SetWindowPosition(cast(int)target.x, cast(int)target.y);

	spawnCava();

	while (!WindowShouldClose()) {
		pollCava();

		if (bars.length == 256) {
			import std.math;
			BeginDrawing();
			ClearBackground(Colors.BLANK);

			float centerX = WINDOW_W / 2.0f;
			float centerY = WINDOW_H / 2.0f;
			float baseRadiusX = 80.0f;
			float baseRadiusY = 80.0f;
			float barWidth = 2.0f;
			float barMaxLength = 60.0f;

			foreach (i, v; bars) {
				float angle = (cast(float)i / cast(float)bars.length) * PI * 2.0f + PI;
				float normalized = v / MAX_BAR_VALUE;
				float barLength = normalized * barMaxLength;
				float innerX = centerX + sin(angle) * (baseRadiusX - barLength);
				float innerY = centerY + cos(angle) * (baseRadiusY - barLength);
				float outerX = centerX + sin(angle) * (baseRadiusX + barLength * 0.5f);
				float outerY = centerY + cos(angle) * (baseRadiusY + barLength * 0.5f);

				float p = pow(normalized, 0.5);
				ubyte r = cast(ubyte)(p * 255.0f);
				ubyte g = cast(ubyte)((1.0f - p) * 255.0f);
				ubyte b = cast(ubyte)(p * 128.0f + 64.0f);

				DrawLineEx(
					Vector2(innerX, innerY),
					Vector2(outerX, outerY),
					barWidth,
					Color(r, g, b)
				);
			}

			EndDrawing();
		}
	}

	CloseWindow();
}
