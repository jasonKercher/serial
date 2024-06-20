package serial

import "core:fmt"
import "core:strconv"
import "core:unicode/utf16"
import win32 "core:sys/windows"

Result :: enum {
	Okay,
	Fail,
}

Restore :: enum {
	Mode,
	Dcb,
	Codepage,
}

Serial :: struct {
	baud: int,
	dev_buf: [24]u8,
	device: string,
	handle: win32.HANDLE,
	dcb: win32.DCB,
	old_mode: win32.DWORD,
	in_cp: win32.UINT,
	out_cp: win32.UINT,
	restores: bit_set[Restore],
}

Flags :: enum {
	Flag_Lf_Eol,
}

open :: proc(s: ^Serial, dev: string, baud: int, flags: bit_set[Flags]) -> Result {
	dev := dev
	if dev == "" {
		defer free_all(context.temp_allocator)

		found: int
		comm_number: int = -1

		for i := 0; i < 256; i += 1 {
			dev = fmt.bprintf(s.dev_buf[:], `\\.\COM%d`, i)
			dev_wstring := win32.utf8_to_wstring(dev)
			h := win32.CreateFileW(dev_wstring,
		                             win32.GENERIC_READ,
		                             0,
		                             nil,
		                             win32.OPEN_EXISTING,
		                             win32.FILE_ATTRIBUTE_NORMAL,
		                             nil)

			err: win32.System_Error
			if h == win32.INVALID_HANDLE {
				err = win32.System_Error(win32.GetLastError())
				win32.SetLastError(0)
				if err == .ACCESS_DENIED {
					fmt.println("found:", i, "(in use)")
				}
				continue
			}
			found += 1
			comm_number = i
			fmt.println("found:", i)
			win32.CloseHandle(h)
		}

		if found <= 0 {
			fmt.eprintln("No comm ports found")
			return .Fail
		}

		if found > 1 {
			// found more than 1, go interactive
			stdin := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
			_check_error("get stdin handle")

			fmt.print("Enter a comm port number:")

			buf16: [16]u16
			buf8: [32]u8
			read_len: u32
			if okay := win32.ReadConsoleW(stdin, &buf16[0], len(buf16), &read_len, nil); okay == win32.FALSE {
				_check_error("stdin for comm port failure") or_return
			}
			if read_len <= 2 {
				fmt.eprintln("input too short")
				return .Fail
			}
			if read_len >= 12 {
				fmt.eprintln("input too long")
				return .Fail
			}

			// - 2 to cutoff \r\n
			buflen := utf16.decode_to_utf8(buf8[:], buf16[:read_len - 2])

			okay: bool
			comm_number, okay = strconv.parse_int(string(buf8[:buflen]))
			if !okay {
				fmt.eprintln("Failed to parse comm number:", string(buf8[:buflen]))
				return .Fail
			}
		}

		dev = fmt.bprintf(s.dev_buf[:], `\\.\COM%d`, comm_number)
	}

	s.device = dev
	s.baud = baud
	return _open(s, flags)
}

close :: proc(s: ^Serial) {
	if .Codepage in s.restores {
		win32.SetConsoleCP(s.in_cp)
		_check_error("(re)SetConsoleCP")
		//win32.SetConsoleOutputCP(s.out_cp)
		//_check_error("(re)SetConsoleOutputCP")
	}
	if .Mode in s.restores {
		stdin := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
		_check_error("get stdin handle")
		win32.SetConsoleMode(stdin, s.old_mode)
		_check_error("(re)SetConsoleMode")
	}
	if .Dcb in s.restores {
		// don't restore this???
	}
	win32.CloseHandle(s.handle)
	_check_error("CloseHandle")
}

read :: proc(s: ^Serial, buf: []u8) -> (read_len: int, res: Result) {
	res = .Okay

	read_u32: u32
	if win32.ReadFile(s.handle, &buf[0], u32(len(buf)), &read_u32, nil) == win32.FALSE {
		_check_error("serial read fail") or_return
	}
	read_len = int(read_u32)

	return
}

write :: proc(s: ^Serial, data: []u8) -> (write_len: int, res: Result) {
	if len(data) == 0 {
		return 0, .Okay
	}
	res = .Okay
	write_u32: u32
	if win32.WriteFile(s.handle, &data[0], u32(len(data)), &write_u32, nil) == win32.FALSE {
		_check_error("serial write fail") or_return
	}
	write_len = int(write_u32)
	return
}

read_stdin :: proc(buf: []u8) -> (read_len: int, res: Result) {
	win32.SetLastError(0)

	res = .Okay
	stdin := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
	_check_error("get stdin handle") or_return

	events_read: u32
	event_buf: [8]win32.INPUT_RECORD

	if win32.GetNumberOfConsoleInputEvents(stdin, &events_read) == win32.FALSE {
		_check_error("GetNumberOfConsoleInputEvents") or_return
	}
	if events_read == 0 {
		return 0, .Okay
	}

	if win32.ReadConsoleInputW(stdin, &event_buf[0], size_of(event_buf), &events_read) == win32.FALSE {
		_check_error("read stdin") or_return
	}
	for i: u32 = 0; i < events_read && read_len < len(buf); i += 1 {
		if event_buf[i].EventType == .KEY_EVENT && event_buf[i].Event.KeyEvent.bKeyDown {
			ke := event_buf[i].Event.KeyEvent
			if ke.uChar.AsciiChar == 0x3 /* || 0x4? */ { /* <Ctrl-C> */
				return read_len, .Fail
			}

			if ke.uChar.AsciiChar == 0 {
				continue
			}
			buf[read_len] = ke.uChar.AsciiChar
			read_len += 1
		}
	}
	return
}

_open :: proc(s: ^Serial, flags: bit_set[Flags]) -> Result {
	win32.SetLastError(0)
	device_wstring := win32.utf8_to_wstring(s.device)

	s.handle = win32.CreateFileW(device_wstring,
	                             win32.GENERIC_READ | win32.GENERIC_WRITE,
	                             0,
	                             nil,
	                             win32.OPEN_EXISTING,
	                             win32.FILE_ATTRIBUTE_NORMAL,
	                             nil)
	if s.handle == win32.INVALID_HANDLE {
		_check_error(s.device)
		return .Fail
	}

	stat: win32.COMSTAT
	errors: win32.Com_Error
	if win32.ClearCommError(s.handle, &errors, &stat) == win32.FALSE {
		fmt.eprintln("comm errors:", errors)
		_check_error("ClearCommError")
	}

	s.dcb.DCBlength = size_of(s.dcb)

	win32.GetCommState(s.handle, &s.dcb)
	_check_error("GetCommState") or_return

	new_dcb := s.dcb
	new_dcb.BaudRate = u32(s.baud)
	new_dcb.ByteSize = 8
	new_dcb.StopBits = .One
	new_dcb.Parity   = .None
	new_dcb.DCBlength = size_of(s.dcb) // never know...

	win32.SetCommState(s.handle, &new_dcb)
	_check_error("SetCommState") or_return

	s.restores += {.Dcb}

	timeouts: win32.COMMTIMEOUTS = {
		ReadIntervalTimeout = max(win32.DWORD), // instant return
		ReadTotalTimeoutConstant = 0,
		ReadTotalTimeoutMultiplier = 0,
		WriteTotalTimeoutConstant = 50,
		WriteTotalTimeoutMultiplier = 10,
	}

	win32.SetCommTimeouts(s.handle, &timeouts)
	_check_error("SetCommTimeouts") or_return

	stdin := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
	_check_error("get stdin handle") or_return
	if win32.GetFileType(s.handle) != win32.FILE_TYPE_CHAR {
		fmt.eprintln("Expected stdin to be TYPE_CHAR")
		return .Fail
	}
	_check_error("GetFileType") or_return
	win32.GetConsoleMode(stdin, &s.old_mode)
	_check_error("GetConsoleMode") or_return
	s.restores += {.Mode}

	win32.SetConsoleMode(stdin, 0)
	_check_error("SetConsoleMode") or_return
	win32.FlushConsoleInputBuffer(stdin)
	_check_error("FlushConsoleInputBuffer") or_return

	s.in_cp = win32.GetConsoleCP()
	_check_error("GetConsoleCP") or_return
	s.out_cp = win32.GetConsoleOutputCP()
	_check_error("GetConsoleOutputCP") or_return
	s.restores += {.Codepage}

	win32.SetConsoleCP(win32.CP_UTF8)
	_check_error("SetConsoleCP") or_return
	//win32.SetConsoleOutputCP(win32.CP_UTF8)
	//_check_error("SetConsoleOutputCP") // or_return SEM_NOT_FOUND !?

	return .Okay
}

// or_return everywhere =]
_check_error :: proc(msg: string = "", loc := #caller_location) -> Result {
	err := win32.System_Error(win32.GetLastError())
	if err != .SUCCESS {
		defer win32.SetLastError(0) // Success
		fmt.eprintln(msg, "{", loc, ":", err, "}")
		return .Fail
	}
	return .Okay
}
