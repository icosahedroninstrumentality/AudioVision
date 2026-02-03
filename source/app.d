import std.stdio;
import std.string;
import std.array;
import std.conv;
import std.algorithm;

import core.sys.posix.unistd;
import core.sys.posix.sys.select;
import core.sys.posix.sys.time;

import raylib;

enum WINDOW_W = 256;
enum WINDOW_H = 64 + 16;

int cavaFd = -1;
string stdinBuf;
int[] bars;

void spawnCava()
{
	int[2] pipefd;
	if (pipe(pipefd) != 0)
	{
		writeln("pipe() failed");
		return;
	}

	auto pid = fork();
	if (pid == 0)
	{
		// child
		close(pipefd[0]);
		dup2(pipefd[1], 1); // stdout -> pipe
		close(pipefd[1]);

		execlp("cava", "cava", null);
		_exit(1);
	}

	// parent
	close(pipefd[1]);
	cavaFd = pipefd[0];
}

void pollCava()
{
	fd_set rfds;
	FD_ZERO(&rfds);
	FD_SET(cavaFd, &rfds);

	timeval tv;
	tv.tv_sec = 0;
	tv.tv_usec = 0;

	if (select(cavaFd + 1, &rfds, null, null, &tv) <= 0)
		return;

	char[4096] buf;
	auto n = read(cavaFd, buf.ptr, buf.length);
	if (n <= 0)
		return;

	stdinBuf ~= buf[0 .. n];

	size_t nl;
	while ((nl = stdinBuf.indexOf('\n')) != size_t.max)
	{
		auto line = stdinBuf[0 .. nl];
		stdinBuf = stdinBuf[nl + 1 .. $];

		bars = line
			.strip()
			.split(';')
			.filter!(s => s.length)
			.map!(to!int)
			.array;
	}
}

void main()
{
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
	SetTargetFPS(60);

	raylib.SetWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED); // some wms need this again
	// some may even fully ignore all decoration flags

	spawnCava();

	while (!WindowShouldClose()) {
		SetWindowPosition(GetMonitorWidth(GetCurrentMonitor()) / 2 - WINDOW_W / 2, 32);
		pollCava();

		BeginDrawing();
		ClearBackground(Colors.BLANK);

		if (bars.length)
		{
			float barW = cast(float)WINDOW_W / bars.length;

			foreach (i, v; bars)
			{
				float h = (cast(float)v / 64) * WINDOW_H;
				import std.math;
				float x = cast(float)i / cast(float)bars.length;
				ubyte r = cast(ubyte) clamp(
					256.0 * pow(1.0 - abs(x - 0.5), 5.0) + 64,
					0.0,
					255.0
				);

				ubyte g = cast(ubyte) clamp(
					256.0 * abs(x - 0.5) + 64,
					0.0,
					255.0
				);

				float centerY = WINDOW_H / 2.0;
				float barHeight = (cast(float)v / 64) * (WINDOW_H / 2); // half height above and below center

				DrawRectangle(
					cast(int)(i * barW),
					cast(int)(centerY - barHeight), // start at top of the bar
					cast(int)barW - 1,
					cast(int)(barHeight * 2),	   // full height extends down
					Color(r, g, 64)
				);
			}
		}

		EndDrawing();
	}

	CloseWindow();
}
