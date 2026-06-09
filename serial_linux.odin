package serial

import "core:os"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

foreign import libc "system:c"

Result :: enum {
	Okay,
	Fail,
}

Serial :: struct {
	stdin_tio_org: posix.termios,
	stdout_tio_org: posix.termios,
	handle: ^os.File,
	speed: posix.speed_t,
	device: string,
}

Flags :: enum {
	Flag_Lf_Eol,
}

open :: proc(s: ^Serial, dev: string, baud: int, flags: bit_set[Flags]) -> Result {
	s.speed = get_speed_t(baud) or_return
	s.device = dev
	if s.device == "" {
		if os.exists("/dev/ttyUSB0") {
			s.device = "/dev/ttyUSB0"
		} else if os.exists("/dev/ttyACM0") {
			s.device = "/dev/ttyACM0"
		} else {
			fmt.eprintln("no serial device found")
			return .Fail
		}
	}
	f, err := os.open(s.device, os.O_RDWR | os.O_SYNC)
	if err != nil {
		fmt.eprintf("Open %s: %s\n", s.device, os.error_string(err))
		return .Fail
	}
	s.handle = f

	return _configure(s, flags)
}

close :: proc(s: ^Serial) {
	if s.handle != nil {
		os.close(s.handle)
	}
	posix.tcflush(posix.FD(os.fd(os.stdout)), .TCIFLUSH)
	posix.tcsetattr(posix.FD(os.fd(os.stdout)), .TCSANOW, &s.stdout_tio_org)
	posix.tcflush(posix.FD(os.fd(os.stdin)), .TCIFLUSH)
	posix.tcsetattr(posix.FD(os.fd(os.stdin)), .TCSANOW, &s.stdin_tio_org)
}

read_stdin :: proc(buf: []u8) -> (int, Result) {
	n, err := os.read(os.stdin, buf)
	if err != nil && err != .EOF {
		err_str := os.error_string(err)
		fmt.eprintln("stdin:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

read :: proc(s: ^Serial, buf: []u8) -> (int, Result) {
	{
		pfds: [1]linux.Poll_Fd = {
			{
				fd = linux.Fd(os.fd(s.handle)),
				events = {.IN},
			},
		}
		ts: linux.Time_Spec = {
			time_sec  = 0,
			time_nsec = 100_000_000,
		}
		n, err := linux.ppoll(pfds[:], &ts, nil)
		if err != .NONE {
			fmt.eprintln("ppoll err:", err)
			return 0, .Fail
		}

		if n == 0 {
			return 0, .Okay
		}

		if .HUP in pfds[0].revents {
			fmt.eprintln("connection closed")
			return 0, .Fail
		}

		if .ERR in pfds[0].revents {
			fmt.eprintln("connection error")
			return 0, .Fail
		}

		if .IN not_in pfds[0].revents {
			return 0, .Okay
		}
	}
	n, err := os.read(s.handle, buf)
	if err != nil && err != .EOF {
		err_str := os.error_string(err)
		fmt.eprintln("read serial:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

write :: proc(s: ^Serial, data: []u8) -> (int, Result) {
	n, err := os.write(s.handle, data)
	if err != nil {
		err_str := os.error_string(err)
		fmt.eprintln("write:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

CRTSCTS :: 0o020000000000

_configure :: proc(s: ^Serial, flags: bit_set[Flags]) -> Result {
	serial_tio: posix.termios
	posix.tcgetattr(posix.FD(os.fd(s.handle)), &serial_tio)
	posix.cfsetospeed(&serial_tio, posix.speed_t(s.speed))
	posix.cfsetispeed(&serial_tio, posix.speed_t(s.speed))

	/* clear CSIZE bits; no parity */
	serial_tio.c_cflag -= (posix.CSIZE | transmute(posix.CControl_Flags)u32(posix.PARENB | posix.PARODD | posix.CSTOPB | CRTSCTS ))
	/* 8-bit data; ignore modem controls; enable read */
	serial_tio.c_cflag += transmute(posix.CControl_Flags)u32(posix.CS8 | posix.CLOCAL | posix.CREAD)

	/* disable break processing; no lf -> cr; turn off xon/xoff */
	serial_tio.c_iflag -= {.IGNBRK, .ICRNL, .IXON, .IXOFF, .IXANY}
	serial_tio.c_lflag = {}       /* no signaling chars; no echo; no canonical */
	serial_tio.c_oflag = {}       /* no remapping; no delays */
	serial_tio.c_cc[.VMIN] = 0    /* non-blocking read */
	serial_tio.c_cc[.VTIME] = 0   /* 100ms read timeout */
	posix.tcflush(posix.FD(os.fd(s.handle)), .TCIFLUSH)
	posix.tcsetattr(posix.FD(os.fd(s.handle)), .TCSANOW, &serial_tio)

	/* adjustments to stdin */
	posix.tcgetattr(posix.FD(os.fd(os.stdin)), &s.stdin_tio_org)
	stdin_tio: posix.termios = s.stdin_tio_org
	stdin_tio.c_lflag -= {.ECHO, .ICANON} /* no echo; no canonical */
	stdin_tio.c_cc[.VMIN] = 0             /* min read = 0 bytes */
	stdin_tio.c_cc[.VTIME] = 1            /* max block time = 100 ms */
	posix.tcflush(posix.FD(os.fd(os.stdin)), .TCIFLUSH)
	posix.tcsetattr(posix.FD(os.fd(os.stdin)), .TCSANOW, &stdin_tio)

	/* adjustments to stdout */
	posix.tcgetattr(posix.FD(os.fd(os.stdout)), &s.stdout_tio_org)
	if .Flag_Lf_Eol not_in flags {
		stdout_tio: posix.termios = s.stdout_tio_org
		stdout_tio.c_oflag = {.OPOST, .ONLRET}
		posix.tcflush(posix.FD(os.fd(os.stdout)), .TCIFLUSH)
		posix.tcsetattr(posix.FD(os.fd(os.stdout)), .TCSANOW, &stdout_tio)
	}

	return .Okay
}

get_speed_t :: proc(baud: int) -> (speed: posix.speed_t, res: Result) {
	spd: int
	switch baud {
	case 0      : spd = 0; res = .Fail
	case 50     : spd = 50
	case 75     : spd = 75
	case 110    : spd = 110
	case 134    : spd = 134
	case 150    : spd = 150
	case 200    : spd = 200
	case 300    : spd = 300
	case 600    : spd = 600
	case 1200   : spd = 1200
	case 1800   : spd = 1800
	case 2400   : spd = 2400
	case 4800   : spd = 4800
	case 9600   : spd = 9600
	case 19200  : spd = 19200
	case 38400  : spd = 38400
	case 57600  : spd = 57600
	case 115200 : spd = 115200
	case 230400 : spd = 230400
	case 460800 : spd = 460800
	case 500000 : spd = 500000
	case 576000 : spd = 576000
	case 921600 : spd = 921600
	case 1000000: spd = 1000000
	case 1152000: spd = 1152000
	case 1500000: spd = 1500000
	case 2000000: spd = 2000000
	case 2500000: spd = 2500000
	case 3000000: spd = 3000000
	case 3500000: spd = 3500000
	case 4000000: spd = 4000000
	case: spd = 0; res = .Fail
	}
	return posix.speed_t(spd), res
}
