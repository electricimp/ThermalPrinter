// Thermal Printer Impee
// Uses CSN-A2-T thermal receipt printer from Adafruit
// Imp sends serial commands to the printer on UART57

// Lots of ASCII to be used, so we'll define the relevant non-printables here
const LF    = 0x0A;
const HT    = 0x09; // Horizontal TAB
const ESC   = 0x1B;
const GS    = 0x1D; // group seperator
const SP    = 0x20; // space
const FF    = 0x0C; // NP form feed; new page
// chunk size for downloading image data buffers from the agent
// equal to one paper width
const CHUNK_SIZE = 384;

class ThermalPrinter {

    // some basic printer parameters
    static printDensity        = 14         // yields 120% density, experimentally determined to be good
    static printBreakTime      = 4          // 500 us; slower but darker
    static dotPrintTime        = 30000      // time to print a single-dot line in us
    static dotFeedTime         = 2100       // time to feed a single-dot line in us

    static uartChunkSize       = 60         // max # of bytes to send in one go via UART (images)

    // current mode of the printer, in case we need to check and see
    lineSpacing         = 32
    bold                = false
    underline           = false
    justify             = "left"
    reverse             = false
    updown              = false
    emphasized          = false
    doubleHeight        = false
    doubleWidth         = false
    deleteLine          = false

    // the actual byte sent to the printer to select modes.
    // masked in methods below to set mode
    _modeByte            = 0x00

    // pointers for image download from the agent
    _imageDataLength     = null
    _loadedDataLength    = null

    // image parameters need to be written out on each row as we stream in an image
    _imageWidth          = null
    _imageHeight         = null

    // a UART object will be passed into the constructor
    _uart = null

    constructor(myUart, myBaud) {
        // the imp can be reset without resetting the printer
        // clear the mode and the buffer every time we construct a new printer
        _uart = myUart;
        _uart.configure(myBaud, 8, PARITY_NONE, 1, NO_CTSRTS);
        reset();
    }

    // reset printer to default mode and print settings
    function reset() {
        // reset the class parameters
        _modeByte = 0x00;
        reverse = false;
        updown = false;
        emphasized = false;
        doubleHeight = false;
        doubleWidth = false;
        deleteLine = false;
        justify = "left";
        bold = false;
        underline = false;
        lineSpacing = 32;

        // reset the image download pointer
        _imageDataLength = 0;
        _loadedDataLength = 0;
        // and the image parameters
        _imageWidth = 0;
        _imageHeight = 0;

        // send the printer reset command
        _uart.write(ESC);
        _uart.write('@');

        // set the basic printer settings
        _uart.write(ESC);
        _uart.write('7');
        // ESC 7 n1 n2 n3
        // n1 = 0-255: max printing dots, unit = 8 dots, default = 7 (64 dots)
        // n2 = 3-255: heating time, unit = 10 us, default = 80 (800 us)
        // n3 = 0-255: heating interval, unit = 10 us, default = 2 (20 us)
        // first, set the "printing dots"
        // more max dots -> faster printing. Max heating dots is 8*(n1+1)
        // more heating -> slower printing
        // not enough heating -> blank page
        _uart.write(20); // Adafruit's library uses this default setting as well
        // now set the heating time
        _uart.write(255); // max heating time
        // last, the heat interval
        _uart.write(250); // 500 us -> slower but darker

        // set the print density as well
        _uart.write(18);
        _uart.write(35);
        // 18 35 N
        // N[4:0] sets printing density (50% + 5% * N[4:0])
        // N[7:5] sets printing break time (250us * N[5:7])
        _uart.write((printBreakTime << 5) | printDensity);

        imp.sleep(1);
        server.log("Printer Ready.");
    }

    // Load a buffer and print it immediately
    function print(printStr) {
        // load the string into the buffer
        _uart.write(printStr);
        _uart.write("\n");
        // print the buffer
        _uart.write(FF);
    }

    // load buffer into the printer's buffer without printing
    function load(buffer) {
        _uart.write(buffer);
    }

    // this function pulls data from the agent down to the imp, which can then push it to the printer
    // part of the printer class because it eventually calls the "print downloaded image command" itself
    function pull() {
        if(_loadedDataLength < _imageDataLength) {
            agent.send("pull", CHUNK_SIZE);
        } else {
            // reset image download pointers
            _imageDataLength = 0;
            _loadedDataLength = 0;
            // tell the agent we're done and it should reset download pointers too
            agent.send("imageDone", 0);
            imp.sleep(0.5);
            reset();
            server.log("Device: done loading image");
        }
    }

    // this function writes a row of bitmap image data to the printer
    function printImg(width, height, data, text=null) {

        // round width up to next byte boundary
        local rowBytes = (width + 7) / 8;

        // enforce max width (384 pixels / 8 = 48 bytes)
        local rowBytesClipped = (rowBytes >= 48) ? 48 : rowBytes;

        // print up to 255 rows at a time
        for (local rowStart = 0; rowStart < height; rowStart += 255) {
            local chunkHeight = height - rowStart;
            if (chunkHeight > 255) chunkHeight = 255;
            // put printer in print-bitmap mode with some nasty magic numbers
            _uart.write(18);
            _uart.write(42);
            _uart.write(chunkHeight);
            _uart.write(rowBytesClipped);

            for (local row = 0; row < chunkHeight; row++) {
                _uart.write(data.readblob(rowBytes));
                _uart.flush();
                server.log("Printing row "+row+" of chunk "+(rowStart / 255));
            }
        }
        server.log("Done Printing Image");
        if (text == null) {
            feed(1);
        } else {
            print(text);
            feed(1);
        }
    }

    // print the buffer and feed n lines
    function feed(lines) {
        while(lines--) {
            print("\n");
        }
    }

    // set line spacing to 'n' dots (default is 32)
    function setLineSpacing(dots = 32) {
        hardware.uart57.write(ESC);
        if (dots == 32) {
            // just set default line spacing if called with no or an invalid argument
            _uart.write('2');
            lineSpacing = 32;
        } else if (dots > 0 && dots < 256) {
            _uart.write('3');
            _uart.write(dots);
            lineSpacing = dots;
        } else {
            server.error("Setting line spacing to invalid value (0-255 dots per line)");
        }
    }

    // select justification
    function setJustify(justifyValue) {
        local justifyByte = 0;
        if (justifyValue == "left") {
            justifyByte = 0;
            justify = "left";
        } else if (justifyValue == "center") {
            justifyByte = 1;
            justify = "center";
        } else if (justifyValue == "right") {
            justifyByte = 2;
            justify = "right";
        } else {
            server.error("Invalid Justify (left, center, right)");
            return;
        }
        _uart.write(ESC);
        _uart.write('a');
        _uart.write(justifyByte);
    }

    // write mode byte to device
    // functions below are used to mask modes on and off in the mode byte
    function writeMode() {
        _uart.write(ESC);
        _uart.write('!');
        _uart.write(_modeByte);
    }

    // toggle bold print
    // takes one boolean argument
    // defaults to true
    function setBold(value = true) {
        _uart.write(ESC);
        _uart.write(SP);
        if (value) {
            _uart.write(1);
            bold = true;
        } else {
            _uart.write(0);
            bold = false;
        }
    }

    // set underline weight
    function setUnderline(value = true) {
        // send the command to set underline weight
        _uart.write(ESC);
        _uart.write(0x2D);
        // we'll just support two weights: none and "2" (max)
        if (value) {
            _uart.write(2);
            underline = true;
        } else {
            _uart.write(0);
            underline = false;
        }
    }

    // toggle reverse mode
    function setReverse(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x02;
            reverse = true;
        } else {
            _modeByte = _modeByte & 0xFD;
            reverse = false;
        }
        writeMode();
    }

    // toggle updown mode
    function setUpdown(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x04;
            updown = true;
        } else {
            _modeByte = _modeByte & 0xFB;
            updown = false;
        }
        writeMode();
    }

    // toggle emphasized mode
    function setEmphasized(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x08;
            emphasized = true;
        } else {
            _modeByte = _modeByte & 0xF7;
            emphasized = false;
        }
        writeMode();
    }

    // toggle double height mode
    function setDoubleHeight(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x10;
            doubleHeight = true;
        } else {
            _modeByte = _modeByte & 0xEF;
            doubleHeight = false;
        }
        writeMode();
    }

    // toggle double width mode
    function setDoubleWidth(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x20;
            doubleWidth = true;
        } else {
            _modeByte = _modeByte & 0xDF;
            doubleWidth = false;
        }
        writeMode();
    }

    // toggle deleteLine mode
    function setDeleteLine(value = true) {
        if (value) {
            _modeByte = _modeByte | 0x40;
            deleteLine = true;
        } else {
            _modeByte = _modeByte & 0xBF;
            deleteLine = false;
        }
        writeMode();
    }
}