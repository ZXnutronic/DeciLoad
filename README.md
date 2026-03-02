# DeciLoad
DeciLoad is a fast tape-loading system for the ZX Spectrum, using the 8b/10b encoding scheme.

Compared to the standard ZX Spectrum loading routing which uses Frequency Shift Keying (FSK) modulation for encoding data onto tape, DeciLoad uses 8b/10b encoding. For the same minimum "pulse" length encoded onto tape, 8b/10b encoding is approximately 2.4 times more efficient than FSK, enabling loading speeds to be dramatically increased. Further speed increase is obtained by significantly increasing the raw symbol rate (baud rate) of the encoded data, compared to standard ZX Spectrum loader timings. The encoder employs sophisticated pulse-shaping and equalisation techniques to optimise the signal waveform in preparation for storage on tape, enabling reliable operation at high baud rates using only a basic, low-bandwidth (voice-oriented) cassette player for loading onto a ZX Spectrum. Raw loading speed is typically around 6-7 times faster than the standard Spectrum ROM loading routine, enabling an entire 48k game to be loaded from tape in well under one minute (including allowance for a BASIC stub-loader containing the DeciLoad loader code). For best results, recording of encoded data onto tape should be performed using a reasonably high-quality cassette recorder. (Typical "shoebox" cassette recorders have very rudimentary recording abilities and usually an Automatic Gain Control circuit that can impair signal quality, so whilst being adequate for playback duties they are usually not optimal for recording DeciLoad encoded data).

The DeciLoad system consists of a command-line encoder for offline encoding of binary data into the WAV audio file format ready for recording on tape, and a loader routine for execution on a ZX Spectrum, for real-time decoding of encoded data played through the tape interface.

The DeciLoad encoder is written in C and is supplied compiled for Windows PCs (and may be compiled for other Operating Systems). It takes a binary input file, which could be typically a memory dump from a ZX Spectrum emulator or raw data extracted from a TZX tape image file. The binary data is encoded in 8b/10b format and appended with a short lead-in sequence and a checksum, and output to a WAV format audio file at a specified baud rate. The encoder provides configurable options for pulse-shaping and equalisation of the encoded data waveform, pre-compensating for losses and distortion arising from the tape recording process and ZX Spectrum tape interface circuitry.

The DeciLoad loader is written in Z80 assembly, and is also supplied as compiled binaries. Currently two versions of the loader are provided for two different baud-rates: 10.4kbaud and 11.5kbaud. The loader recognises the DeciLoad lead-in sequence, analogous to the Pilot Tone used by the standard Spectrum loader, and loads data of specified length starting at a specified memory address, performing real-time decoding of the 8b/10b-encoded data stream. The loader continuously monitors the timings of "edges" in the input data waveform, adjusting its timing to track small variations in tape speed.


DeciLoad Encoder - USAGE
========================

deciload [options] [input filename] [output filename]

Options (note no space between the specifier letter and the value):

-r[sample rate] : Sample rate for output WAV file (default 44100)

-b[baud rate] : Baud rate for encoded data (default 10417)
	
-s[sync byte] : Sync byte value, in hexadecimal (default 0x35)
	
-l[frequency] : Corner frequency for first low-frequency correction filter, in Hz (default 1200)

-L[frequency] : Corner frequency for second low-frequency correction filter, in Hz (default 0)
	
-a[amplitude] : Amplitude of impulse response, in decimal (default 11000)
	
-e[emphasis] : Percentage pre-emphasis, from 0 to 100 (default 50)
	
-o[offset] : Offset pre-emphasis waveform, to correct tape phase distortion. Valid range -1 to +1 (default -0.5)

-p[time] : Time-constant for phase-correction filter (default 0)

Input filename: binary input data, e.g. memory dump from a ZX Spectrum emulator or raw binary data extracted from a TZX file
Output filename: output audio file in .WAV file format. The filename should include the .wav extension.

The default values for pre-emphasis and low-frequency compensation have been found to be roughly optimal for reliable operation when recorded to cassette tape and loaded on a 48k ZX Spectrum. The pre-compensation process manipulates the input waveform quite strongly, to the extent that the data is generally unrecognisable if it has NOT been passed through a tape recording / playback process and through the tape input circuitry of a real ZX Spectrum. Spectrum emulators generally do NOT model the signal manipulation effects of real tape and ZX Spectrum hardware, and so will fail to load an encoded WAV file using the default settings. To generate a DeciLoad-encoded WAV file suitable for loading into an emulator, some of the pre-compensation options must be disabled or significantly reduced in magnitude.

Currently the output WAV file is always in 16-bit (signed) format. Generally the output will easily tolerate conversion to 8-bit resolution without affecting reliability. (I would NOT recommend compressing it with a lossy codec such as MP3!)


Examples:

To encode input file "data.bin" at the default baud-rate of 10.4kbaud, using default tape pre-compensation settings:

deciload data.bin output.wav

To encode input file "data.bin" without any pre-emphasis or equalisation (suitable for reading into a ZX Spectrum emulator), at the higher rate of 11.5kbaud:

deciload -e0 -l0 -b11513 input.bin output.wav


Further explanation of options:

-r[sample rate] : This can usually be left at the default 44.1kHz, which is a universally supported standard audio sample rate. The encoded file contains no significant frequency content above about half the baud-rate, so ideally there is no benefit to increasing the sample rate (it will only increase the output file size). However, some Spectrum emulators may benefit if they neglect to perform interpolation between samples when reading a WAV file as an emulated tape.

-b[baud rate] : The encoder will support any baud rate right up to the WAV sample rate itself. There is no requirement for the rates to be integer multiples / fractions of each other (indeed the baud rate variable is a floating-point value). Currently the DeciLoad loader is provided in only two baud-rate options: 10417 baud and 11513 baud. The encoded baud rate must match the baud rate expected by the loader, within a tolerance of about a couple of percent (to allow for tape speed variation).

-s[sync byte] : The sync byte is used by the loader to detect the end of the "pilot" sequence and the start of the encoded data. The sync byte value used in the encoding must match the sync byte value expected by the loader, defaulting to 0x35. This can be changed if desired, for example to uniquely identify multiple data blocks on a tape, analogous to the "flag" byte used by the standard Spectrum loader. The binary sync byte value should always contain four ones and four zeroes, should begin and end with no more than three consecutive ones or zeroes, and must be different from the "pilot tone" byte value of 0xCA.

-l[frequency] / -L[frequency] : Two stages of low-frequency boost with programmable corner frequencies. Best results are obtained with only one stage used (the other set to zero). The boost compensates for the low-frequency cutoff of the AC-coupling capacitor in series with the tape "EAR" input of the ZX Spectrum, and can also help compensate for the low-frequency cutoff of the cassette recorder / playback circuitry. Optimum value for a 48k Spectrum is about 1.2kHz. Optimum value for the 128k Spectrum models is not yet known, but will probably also work adequately with the same value.

-a[amplitude] : Sets the signal amplitude of the encoded data in the WAV file prior to post-processing (low-frequency boost and phase correction). Default value of 11000 should work well with typical settings. If you need to use more aggressive correction values, then check the output WAV file in a wave editor to look for clipping, and reduce the amplitude value if necessary.

-e[emphasis] : Applies an amplitude boost to each data transition, to emphasize edges in the output waveform and attenuate the constant "DC" signal content occurring in runs of consecutive zeroes and ones. Default value of 50% works well when recording on tape.

-o[offset] : Skews the emphasis forwards or backwards, to compensate phase non-linearity in the tape recording / playback process. Default value of -0.5 seems to work well.

-p[time] : Experimental feature for an alternative method of tape phase correction. Implements an all-pass filter in the WAV output post-processing, with programmable time-constant. In practice, better results have been found by leaving this setting at 0 and using the offset emphasis feature (-o option) instead. However, this might be useful in some tape recording situations. Useful values for -p in this case will probably be in the range of about 3e-5 to 7e-5.



DeciLoad Loader - USAGE
=======================

The loader is supplied in Z80 assembly and binaries, in "bare" form for calling from machine code, and in packaged form (filename suffx _usr) for calling from BASIC as a USR function. Two versions of the loader are provided in each form, for baud rates of 10417 baud (UI = 336 T-states) and 11513 baud (UI = 304 T-states). 

Usage instructions - bare form:

Call with interrupts disabled, base address for load data in HL, and data length in IX. Loader code and stack must both be in uncontended memory. 
Provided binaries are assembled with origin and CALL address = 65287. The code contains absolute jumps and cannot be relocated without recompiling.
Sync byte value (default $35) can be changed if required by editing the "cp $35" instruction.
Loader returns with checksum in register A, with 0 indicating a successful load and any other value indicating an error. All other registers (except interrupt vector) corrupt, including shadow and index registers.

Usage instructions - packaged form (filename suffix _usr):

Call from BASIC with USR 65270. Load base address and length are pre-filled with the values 16384 and 6912 respectively, for loading a screen. Alternative values can be POKEd at addresses 65271/2 and 65275/6 respectively (LSByte first). CLEAR address must be below 65270 (the start address of the loader routine), and above about 32800 to ensure that the stack points to uncontended memory.
Sync byte value (default $35) can be changed if required by POKEing an alternative value at address 65346.
The loader checksum is returned in register BC as the result of the USR function. 0 indicates a successful load, any other value indicates an error.

