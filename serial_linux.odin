package serial

import "core:c"
import "core:fmt"
import "core:os/os2"
import "core:sys/linux"

foreign import libc "system:c"

Result :: enum {
	Okay,
	Fail,
}

Serial :: struct {
	stdin_tio_org: Termios,
	stdout_tio_org: Termios,
	handle: ^os2.File,
	speed: Speed,
	device: string,
}

Flags :: enum {
	Flag_Lf_Eol,
}

open :: proc(s: ^Serial, dev: string, baud: int, flags: bit_set[Flags]) -> Result {
	s.speed = get_speed_t(baud) or_return
	s.device = dev
	if s.device == "" {
		if os2.exists("/dev/ttyUSB0") {
			s.device = "/dev/ttyUSB0"
		} else if os2.exists("/dev/ttyACM0") {
			s.device = "/dev/ttyACM0"
		} else {
			fmt.eprintln("no serial device found")
			return .Fail
		}
	}
	f, err := os2.open(s.device, os2.O_RDWR | os2.O_SYNC)
	if err != nil {
		fmt.eprintf("Open %s: %s\n", s.device, os2.error_string(err))
		return .Fail
	}
	s.handle = f

	return _configure(s, flags)
}

close :: proc(s: ^Serial) {
	if s.handle != nil {
		os2.close(s.handle)
	}
	_libc_tcflush(c.int(os2.fd(os2.stdout)), TCIFLUSH)
	_libc_tcsetattr(c.int(os2.fd(os2.stdout)), TCSANOW, &s.stdout_tio_org)
	_libc_tcflush(c.int(os2.fd(os2.stdin)), TCIFLUSH)
	_libc_tcsetattr(c.int(os2.fd(os2.stdin)), TCSANOW, &s.stdin_tio_org)
}

read_stdin :: proc(buf: []u8) -> (int, Result) {
	n, err := os2.read(os2.stdin, buf)
	if err != nil && err != .EOF {
		err_str := os2.error_string(err)
		fmt.eprintln("stdin:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

read :: proc(s: ^Serial, buf: []u8) -> (int, Result) {
	{
		pfds: [1]linux.Poll_Fd = {
			{
				fd = linux.Fd(os2.fd(s.handle)),
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
	n, err := os2.read(s.handle, buf)
	if err != nil && err != .EOF {
		err_str := os2.error_string(err)
		fmt.eprintln("read serial:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

write :: proc(s: ^Serial, data: []u8) -> (int, Result) {
	n, err := os2.write(s.handle, data)
	if err != nil {
		err_str := os2.error_string(err)
		fmt.eprintln("write:", err_str)
		return 0, .Fail
	}
	return n, .Okay
}

/* Got these constants from asm-generic/termbits.h */

cc_t :: c.uchar
speed_t :: c.uint
tcflag_t :: c.uint

NCCS :: 32
C_Cc_Idx :: enum {
	VINTR,
	VQUIT,
	VERASE,
	VKILL,
	VEOF,
	VTIME,
	VMIN,
	VSWTC,
	VSTART,
	VSTOP,
	VSUSP,
	VEOL,
	VREPRINT,
	VDISCARD,
	VWERASE,
	VLNEXT,
	VEOL2,
	_end = NCCS - 1,
}

C_Iflag_Bits :: enum {
	IGNBRK,
	BRKINT,
	IGNPAR,
	PARMRK,
	INPCK,
	ISTRIP,
	INLCR,
	IGNCR,
	ICRNL,
	IUCLC,
	IXON,
	IXANY,
	IXOFF,
	IMAXBEL,
	IUTF8,
}

C_Oflag_Bits :: enum {
	OPOST,
	OLCUC,
	ONLCR,
	OCRNL,
	ONOCR,
	ONLRET,
	OFILL,
	OFDEL,
	NLDLY,
	NL0,
	NL1,
	CRDLY,
	CR0,
	CR1,
	CR2,
	CR3,
	TABDLY,
	TAB0,
	TAB1,
	TAB2,
	TAB3,
	XTABS,
	BSDLY,
	BS0,
	BS1,
	VTDLY,
	VT0,
	VT1,
	FFDLY,
	FF0,
	FF1,
}

C_Lflag_Bits :: enum {
	ISIG,
	ICANON,
	XCASE,
	ECHO,
	ECHOE,
	ECHOK,
	ECHONL,
	NOFLSH,
	TOSTOP,
	ECHOCTL,
	ECHOPRT,
	ECHOKE,
	FLUSHO,
	PENDIN,
	IEXTEN,
	EXTPROC,
}

/* tcflush queue_selector args */
TCIFLUSH  : c.int : 0
TCOFLUSH  : c.int : 1
TCIOFLUSH : c.int : 2

/* tcsetattr option args */
TCSANOW   : c.int : 0
TCSADRAIN : c.int : 1
TCSAFLUSH : c.int : 2


/* c_cflag bit masks */
CSIZE   : tcflag_t : 0o000000000060
CS5     : tcflag_t : 0o000000000000
CS6     : tcflag_t : 0o000000000020
CS7     : tcflag_t : 0o000000000040
CS8     : tcflag_t : 0o000000000060
CSTOPB  : tcflag_t : 0o000000000100
CREAD   : tcflag_t : 0o000000000200
PARENB  : tcflag_t : 0o000000000400
PARODD  : tcflag_t : 0o000000001000
HUPCL   : tcflag_t : 0o000000002000
CLOCAL  : tcflag_t : 0o000000004000
CBAUDEX : tcflag_t : 0o000000010000
BOTHER  : tcflag_t : 0o000000010000
CIBAUD  : tcflag_t : 0o002003600000
CMSPAR  : tcflag_t : 0o010000000000
CRTSCTS : tcflag_t : 0o020000000000

Speed :: enum {
	B0       = 0o0000000,
	B50      = 0o0000001,
	B75      = 0o0000002,
	B110     = 0o0000003,
	B134     = 0o0000004,
	B150     = 0o0000005,
	B200     = 0o0000006,
	B300     = 0o0000007,
	B600     = 0o0000010,
	B1200    = 0o0000011,
	B1800    = 0o0000012,
	B2400    = 0o0000013,
	B4800    = 0o0000014,
	B9600    = 0o0000015,
	B19200   = 0o0000016,
	B38400   = 0o0000017,
	B57600   = 0o0010001,
	B115200  = 0o0010002,
	B230400  = 0o0010003,
	B460800  = 0o0010004,
	B500000  = 0o0010005,
	B576000  = 0o0010006,
	B921600  = 0o0010007,
	B1000000 = 0o0010010,
	B1152000 = 0o0010011,
	B1500000 = 0o0010012,
	B2000000 = 0o0010013,
	B2500000 = 0o0010014,
	B3000000 = 0o0010015,
	B3500000 = 0o0010016,
	B4000000 = 0o0010017,
}

Tcflag_Bitset :: bit_set[0 ..< (8*size_of(tcflag_t)); tcflag_t]

Termios :: struct {
	c_iflag:  bit_set[C_Iflag_Bits; tcflag_t],
	c_oflag:  bit_set[C_Oflag_Bits; tcflag_t],
	c_cflag:  Tcflag_Bitset,
	c_lflag:  bit_set[C_Lflag_Bits; tcflag_t],
	c_line:   cc_t,
	c_cc:     #sparse [C_Cc_Idx]cc_t,
	c_ispeed: speed_t,
	c_ospeed: speed_t,
}

/* sizeof struct termios in C */
#assert(size_of(Termios) == 60)

// TODO: just call ioctl ourselves instead of this
foreign libc {
	@(link_name="tcgetattr")   _libc_tcgetattr   :: proc(fd: c.int, tios: ^Termios) -> c.int ---
	@(link_name="tcsetattr")   _libc_tcsetattr   :: proc(fd, options: c.int, tios: ^Termios) -> c.int ---
	@(link_name="tcflush")     _libc_tcflush     :: proc(fd, queue_selector: c.int) -> c.int ---
	@(link_name="cfsetospeed") _libc_cfsetospeed :: proc(tios: ^Termios, speed: speed_t) -> c.int ---
	@(link_name="cfsetispeed") _libc_cfsetispeed :: proc(tios: ^Termios, speed: speed_t) -> c.int ---
}


_configure :: proc(s: ^Serial, flags: bit_set[Flags]) -> Result {
	serial_tio: Termios
	_libc_tcgetattr(c.int(os2.fd(s.handle)), &serial_tio)
	_libc_cfsetospeed(&serial_tio, speed_t(s.speed))
	_libc_cfsetispeed(&serial_tio, speed_t(s.speed))

	/* clear CSIZE bits; no parity */
	serial_tio.c_cflag -= transmute(Tcflag_Bitset)(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS )
	/* 8-bit data; ignore modem controls; enable read */
	serial_tio.c_cflag += transmute(Tcflag_Bitset)(CS8 | CLOCAL | CREAD)

	/* disable break processing; no lf -> cr; turn off xon/xoff */
	serial_tio.c_iflag -= {.IGNBRK, .ICRNL, .IXON, .IXOFF, .IXANY}
	serial_tio.c_lflag = {}       /* no signaling chars; no echo; no canonical */
	serial_tio.c_oflag = {}       /* no remapping; no delays */
	serial_tio.c_cc[.VMIN] = 0    /* non-blocking read */
	serial_tio.c_cc[.VTIME] = 0   /* 100ms read timeout */
	_libc_tcflush(c.int(os2.fd(s.handle)), TCIFLUSH)
	_libc_tcsetattr(c.int(os2.fd(s.handle)), TCSANOW, &serial_tio)

	/* adjustments to stdin */
	_libc_tcgetattr(c.int(os2.fd(os2.stdin)), &s.stdin_tio_org)
	stdin_tio: Termios = s.stdin_tio_org
	stdin_tio.c_lflag -= {.ECHO, .ICANON} /* no echo; no canonical */
	stdin_tio.c_cc[.VMIN] = 0             /* min read = 0 bytes */
	stdin_tio.c_cc[.VTIME] = 1            /* max block time = 100 ms */
	_libc_tcflush(c.int(os2.fd(os2.stdin)), TCIFLUSH)
	_libc_tcsetattr(c.int(os2.fd(os2.stdin)), TCSANOW, &stdin_tio)

	/* adjustments to stdout */
	_libc_tcgetattr(c.int(os2.fd(os2.stdout)), &s.stdout_tio_org)
	if .Flag_Lf_Eol not_in flags {
		stdout_tio: Termios = s.stdout_tio_org
		stdout_tio.c_oflag = {.OPOST, .ONLRET}
		_libc_tcflush(c.int(os2.fd(os2.stdout)), TCIFLUSH)
		_libc_tcsetattr(c.int(os2.fd(os2.stdout)), TCSANOW, &stdout_tio)
	}

	return .Okay
}

get_speed_t :: proc(baud: int) -> (spd: Speed, res: Result) {
	switch baud {
	case 0      : spd = .B0; res = .Fail
	case 50     : spd = .B50
	case 75     : spd = .B75
	case 110    : spd = .B110
	case 134    : spd = .B134
	case 150    : spd = .B150
	case 200    : spd = .B200
	case 300    : spd = .B300
	case 600    : spd = .B600
	case 1200   : spd = .B1200
	case 1800   : spd = .B1800
	case 2400   : spd = .B2400
	case 4800   : spd = .B4800
	case 9600   : spd = .B9600
	case 19200  : spd = .B19200
	case 38400  : spd = .B38400
	case 57600  : spd = .B57600
	case 115200 : spd = .B115200
	case 230400 : spd = .B230400
	case 460800 : spd = .B460800
	case 500000 : spd = .B500000
	case 576000 : spd = .B576000
	case 921600 : spd = .B921600
	case 1000000: spd = .B1000000
	case 1152000: spd = .B1152000
	case 1500000: spd = .B1500000
	case 2000000: spd = .B2000000
	case 2500000: spd = .B2500000
	case 3000000: spd = .B3000000
	case 3500000: spd = .B3500000
	case 4000000: spd = .B4000000
	case: spd = .B0; res = .Fail
	}
	return
}
