/*

DeciLoad Encoder v1.1.1 (c) 2026 Jonah Nuttgens
=============================================

Fast tape-loading system for the ZX Spectrum, using the 8b/10b encoding scheme.

This command-line encoder utility converts a binary file to an 8b/10b-encoded WAV file, ready to be recorded on tape and subsequently loaded into a ZX Spectrum using the DeciLoad loader routine.

Basic operation of the encoder is as follows:

Data is read from a binary input file, and each byte is encoded to a 10-bit word using the widely-published 8b/10b encoding scheme.
The encoding tables and use of Running Disparity are as published on Wikipedia:

https://en.wikipedia.org/wiki/8b/10b_encoding

Only the Data symbols (including the "Primary" and "Alternate" D.x.7 codes) are used. Control symbols (K.xx.x) are not used at present.

The audio WAV file is constructed from the encoded bit sequence by shaping each bit with a predefined impulse response, multiplied by -1 for a logic "0" or +1 for a logic "1", and then overlaying these impulse responses at fixed intervals. The impulse response shape is pre-computed in the "wsinc" array, oversampled at (typically) 32x the baud-rate. Linear interpolation is used between the points in this array to allow the impulse function to be shifted with floating-point precision relative to the WAV sample-rate. Successive impulse response functions are summed into the WAV output buffer, at fixed intervals defined by the baud-rate.

The impulse response started life as a windowed-sinc function (hence the array name "wsinc"). This has subsequently changed to a raised-cosine function, and then later to two superimposed raised-cosines (of different frequencies and opposite polarity, to implement a pre-emphasis feature), which was found to give better overall results. The name "wsinc" for the impulse response array and associated variables has stuck!

The encoded data is prefixed with a lead-in sequence consisting of a "pilot tone" and a "sync byte". The "pilot tone" is not really a tone, but actually a repeated 8-bit sequence, defaulting to $CA (11001010 binary). This allows the loader to synchronise its bit-clock, word-clock, and simultaneously to determine the tape signal polarity. The "sync byte", defaulting to $35 (00110101 binary) indicates the end of the pilot tone and the start of 10-bit encoded data words.

At the end of the payload data, a final checksum byte and one additional dummy lead-out byte are appended (also 8b/10b-encoded). The checksum is calculated so that the modulo-256 sum of every byte in the input data plus the checksum is always equal to zero. This is used by the loader to verify the decoded data at the end of loading, and to flag a loading error if the total is other than zero. The lead-out byte is added to avoid issues with truncation of the WAV file in some applications.

The waveform data constructed from the overlaid impulse responses is further (optionally) post-processed before writing to the output WAV file, to pre-compensate for losses in the tape-recording process and the tape input circuitry of the ZX Spectrum. The processing steps consist of:
	- Up to two stages of low-frequency correction, primarily to compensate for the (undersized) AC-coupling capacitor in the EAR input of the 48k Spectrum. Can also be used to compensate low-frequency losses in the tape recording process. Best results seem to be obtained with just one correction stage enabled, with a corner-frequency around 1.2kHz being roughly optimal for loading on the 48k Spectrum.
	- Phase correction using an all-pass filter, to compensate for phase nonlinerity of cassette tape. Optimal values of the time-constant variable for the cassette recorders I've tested range between about 25-70us (2.5e-5 to 7e-5). However, better results have been obtained in practice by leaving this feature disabled (t_apf=0), and instead using "offset pre-emphasis" in the impulse response.


USAGE:
======

deciload <options> <input filename> <output filename>

Options (note no space between the specifier letter and the value):
	-r<sample rate> : Sample rate for output WAV file (default 44100)
	-b<baud rate> : Baud rate for encoded data (default 10417)
	-s<sync byte> : Sync byte value, in hexadecimal (default 0x35)
	-l<frequency> : Corner frequency for first low-frequency correction filter, in Hz (default 1200)
	-L<frequency> : Corner frequency for second low-frequency correction filter, in Hz (default 0)
	-a<amplitude> : Amplitude of impulse response, in decimal (default 43)
	-e<emphasis %> : Percentage pre-emphasis, from 0 to 100 (default 50)
	-o<offset> : Offset pre-emphasis waveform, to correct tape phase distortion. Valid range -1 to +1 (default -0.5)
	-p<time> : Time-constant for phase-correction filter (default 0)

 */


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
  short          wFormatTag;
  unsigned short wChannels;
  unsigned long  dwSamplesPerSec;
  unsigned long  dwAvgBytesPerSec;
  unsigned short wBlockAlign;
  unsigned short wBitsPerSample;
} FormatChunk;


FILE* write_wav_head(char *filename, FormatChunk *fmt_chunk, unsigned long data_size);
float bessel(float x);
short int enc8b10b(char input_byte, char rdp);


int main(int argc, char *argv[]){

/* Variables */
float		*wsinc;			/* Pointer to windowed-sinc array */
int		wsinc_res=32;		/* resolution (oversampling ratio) of windowed sinc function */
int		wsinc_len=4;		/* Length of impulse response. Set to 4 for dual raised-cosine */
char		input_fname[64];
char		output_fname[64];
float		kbw_b=12;		/* B parameter of Kaiser-Bessel window function */
int		i;			/* Index used in various FOR loops */
float		temp, temp1;
FILE		*input_ptr;
FormatChunk	wave_fmt_chunk;
unsigned long	input_data_size;
char		input_data[256];	/* Process 256 bytes of input file at a time */
float		*wav_process;		/* Storage for intermediate processing of WAV data */
char		*wav_data_out;		/* Storage space for WAV data */
FILE		*output_ptr;
int		wsinc_size;
float		kbw;
unsigned long	output_data_size;
unsigned long	wav_sample_rate = 44100;
float		baud_rate = 10417;	/* Baud rate for 1UI = 336T at 3.5MHz */
int		wav_buffer_size;
int		input_file_pos;		/* Position of input file at beginning of input data buffer */
int		output_file_pos;	/* Sample number of output file being worked on */
int		block_size;		/* Size of data block being processed in current iteration of main loop */
unsigned long	bit_number;		/* Number of current bit being processed in output stream */
float		output_pos;		/* Position of current bit in units of wav samples */
int		impulse_duration;
int		subsample_num;
int		sample_index;
short int	bit_mask;
short int	data_enc;		/* 10-bit encoded data byte */
char		rdp;			/* Running disparity: 0 means -1, 1 means +1 */
float		bit_value;
float		wsinc_pos;		/* Exact position into windowed-sinc array to be interpolated */
int		wsinc_pos_int;
float		wsinc_pos_frac;
int		rdp_debug = -1;
float		emphasis = 50;		/* Percentage pre-emphasis */
float		emph_offset = -0.5;	/* Offset of de-emphasis pulse, range -1 to +1 */
float		f_lf = 1200;		/* Corner frequency for first LF compensation stage */
float		f_lf2 = 0;		/* Corner frequency for second LF compensation stage */
float		t_apf = 0;		/* Time-constant for all-pass filter */
float		int_coef;
float		int_coef2;
float		apf_coef;
float		integrator = 0;
float		integrator2 = 0;
float		c_apf = 0;		/* Low-pass filter forming part of the all-pass filter */
float		wav_amp = 43;
int		leadin_bytes = 500;	/* Number of lead-in bytes, including sync byte */
char		pilot_byte = 0xCA;
char		sync_byte = 0x35;
char		checksum = 0;


/* Get command-line parameters */
input_fname[0] = '\0';
output_fname[0] = '\0';

for(i=1; i<argc; i++)
	if(*argv[i] == '-')
		switch(*(argv[i]+1)){
			case 'r': sscanf(argv[i]+2, "%d", &wav_sample_rate); break;
			case 'b': sscanf(argv[i]+2, "%f", &baud_rate); break;
			case 's': sscanf(argv[i]+2, "%x", &sync_byte); break;
			case 'l': sscanf(argv[i]+2, "%f", &f_lf); break;
			case 'L': sscanf(argv[i]+2, "%f", &f_lf2); break;
			case 'a': sscanf(argv[i]+2, "%f", &wav_amp); break;
			case 'e': sscanf(argv[i]+2, "%f", &emphasis); break;
			case 'o': sscanf(argv[i]+2, "%f", &emph_offset); break;
			case 'p': sscanf(argv[i]+2, "%f", &t_apf); break;
		}
	else{
		strcpy(input_fname, output_fname);
		strcpy(output_fname, argv[i]);
	}

if(input_fname[0]=='\0'){
	puts("No input filename specified");
	return(1);
}


wsinc_size = (wsinc_len * wsinc_res)+1;

/* Open input file and find length */
if((input_ptr=fopen(input_fname, "rb")) == NULL){
	printf("File %s could not be opened.\n", input_fname);
	return(1);
}
input_data_size = 0;
do{
	block_size = fread(input_data, 1, 256, input_ptr);
	input_data_size += block_size;
} while (block_size != 0);
fseek(input_ptr, 0, SEEK_SET);

printf("Data Size = %u\n", input_data_size);

/* Increase by 2 to include checksum byte and lead-out byte */
input_data_size = input_data_size + 2;

output_data_size = (int)(((input_data_size*10+leadin_bytes*8)+(2*wsinc_len))*(wav_sample_rate/baud_rate));
/* Note that the above calculation includes 10 bits for the encoded checksum, and 10 bits for the encoded lead-out byte */
wav_buffer_size = (((256*10)+(2*wsinc_len))*wav_sample_rate/baud_rate)+1;
impulse_duration = (wsinc_len*wav_sample_rate/baud_rate)+1;	/* +1 to round up. Exact integer gets 1 added. */

printf("Output Data Size = %u\n", output_data_size+512);
printf("Output Buffer Size = %u\n", wav_buffer_size);

wave_fmt_chunk.wFormatTag = 1;
wave_fmt_chunk.wChannels = 1;
wave_fmt_chunk.dwSamplesPerSec = wav_sample_rate;
wave_fmt_chunk.dwAvgBytesPerSec = wav_sample_rate;
wave_fmt_chunk.wBlockAlign = 1;
wave_fmt_chunk.wBitsPerSample = 8;


/* Open output file and write header */
/* This includes 256 samples padding at end */
if((output_ptr=write_wav_head(output_fname, &wave_fmt_chunk, output_data_size+256)) == NULL){
	printf("Unable to open output file\n");
	return(1);
	}


/* Allocate memory for data arrays */
wsinc = (float*)malloc(wsinc_size*sizeof(float)); /* Space for half of Windowed-Sinc function (symmetrical) */
wav_process = (float*)malloc(wav_buffer_size*sizeof(float));
wav_data_out = (char*)malloc(wav_buffer_size); /* Allocate enough space for (wav_buffer_size) output samples */

if((wav_data_out == NULL) || (wav_process == NULL) \
	|| (wsinc == NULL)){
	puts("Memory allocation failed");
	return(1);
}


/* Generate windowed-sinc function */
/* Replaced for this version with a raised-cosine pulse */

emphasis = 0.005 * emphasis; /* Convert emphasis from percentage to mult factor */

/* temp1 = bessel(kbw_b); */

for (i=0; i<wsinc_size; i++){
	/* Calculate Kaiser-Bessel window function */
	/* temp = 2 * i / ((float)wsinc_res * wsinc_len - 1);
	temp = kbw_b * pow(1 - pow(temp, 2), 0.5);
	kbw = bessel(temp) / temp1; */
	/* Calculate sinc function */
	/* temp = M_PI * (float)i / wsinc_res;
	*(wsinc+i) = kbw * sin(temp) / temp; */

	/* Calculate raised cosine function (Bessel window is unused) */
	temp = (float)i / wsinc_res - wsinc_len/2;
	*(wsinc+i) = -emphasis - (emphasis * cos(M_PI * 0.5 * temp));
	temp += emph_offset;
	if ((temp > -1) && (temp < 1))
		*(wsinc+i) += 0.5 + emphasis + ((0.5 + emphasis) * cos(M_PI * temp));
}


int_coef = 6.283 * f_lf / wav_sample_rate;
int_coef2 = 6.283 * f_lf2 / wav_sample_rate;
if (t_apf == 0)
	apf_coef = 0;
else
	apf_coef = exp(-0.5/(wav_sample_rate*t_apf));

/* Start of main processing block */

bit_number = 0;
output_pos = 0;
output_file_pos = 0;
rdp = 0;

/* Clear output buffer */
for (i=0; i<wav_buffer_size; i++)
	wav_process[i] = 0;

printf("Starting processing...\n");

while(input_data_size){

	if(leadin_bytes > 256)
		block_size = 256;
	else if(leadin_bytes)
		block_size = leadin_bytes;
	else{
		if (input_data_size > 258)
			block_size = 256;
		else if (input_data_size > 2)
			block_size = input_data_size-2;
		else
			block_size = 0;

		if (block_size)
			fread(input_data, 1, block_size, input_ptr);
		else{	/* Final block, containing only the checksum and lead-out byte */
			input_data[0] = 0 - checksum;
			input_data[1] = 0x4A;	/* Lead-out byte, encodes as 0101010101 */
			block_size = 2;
		}

		input_data_size -= block_size;
	}

	for(i=0; i<block_size; i++){

		if(!leadin_bytes){
			/* Encode data byte */
			data_enc = enc8b10b(input_data[i], rdp);
			checksum += input_data[i];
			if(data_enc&0x0400)
				rdp = 1;
			else
				rdp = 0;
			bit_mask = 512;
			}
		else{
			if(leadin_bytes == 1)
				data_enc = sync_byte;
			else
				data_enc = pilot_byte;
			leadin_bytes--;
			bit_mask = 128;
			}

		for(; bit_mask!=0; bit_mask>>=1){
			if(bit_mask & data_enc)
				bit_value = 1;
			else
				bit_value = -1;

			rdp_debug += bit_value;
			if ((rdp_debug == 4) || (rdp_debug == -4)){
				printf("RDP out of range; input byte = %d\nRDP = %d; encoded value = %d\n", input_data[i], rdp_debug, data_enc);
				return(1);
			}

			/* Core function... */

			for (subsample_num=0; subsample_num<impulse_duration; subsample_num++){

				sample_index = output_pos+subsample_num+1; /* Plus 1 to round up */
				wsinc_pos = wsinc_res*((sample_index-output_pos)*baud_rate/wav_sample_rate);

				if(sample_index>=wav_buffer_size){
					printf("Index out of range: %d\n", sample_index);
					return(1);
				}

				wsinc_pos_int = wsinc_pos;
				wsinc_pos_frac = wsinc_pos - wsinc_pos_int;

				if((wsinc_pos_int+1)<wsinc_size)
					wav_process[sample_index] += bit_value*(wsinc[wsinc_pos_int]*(1-wsinc_pos_frac)+wsinc[wsinc_pos_int+1]*wsinc_pos_frac);

			}

			bit_number++;
			output_pos = (bit_number * (wav_sample_rate / baud_rate))-output_file_pos; /* This is the exact (fractional) position in the output wave array where the current impulse response begins */
		}

	}

/*	printf("%d bytes left; output_pos = %f\n", input_data_size, output_pos); */

	/* Now calculate how many samples to write to the WAV file, and shunt the buffer contents along */
	/* Note that block_size changes meaning here, from number of input data bytes processed to number of WAV samples */

	block_size = output_pos;
	
	for(i=0; i<block_size; i++){
		temp = integrator + wav_process[i]; 	/* Output of first LF correction stage */
		integrator = 0.98 * integrator + int_coef * wav_process[i];
		temp1 = integrator2 + temp;
		integrator2 = 0.98 * integrator2 + int_coef2 * temp;
		c_apf = c_apf * apf_coef + temp1 * (1.0 - apf_coef);
		temp = wav_amp * (2 * c_apf - temp1);	/* Output of all-pass filter */
		c_apf = c_apf * apf_coef + temp1 * (1.0 - apf_coef);
		if (temp > 127)
			wav_data_out[i] = (char)255;
		else if (temp < -128)
			wav_data_out[i] = (char)0;
		else
			wav_data_out[i] = (char)(temp+128);
	}

	fwrite(wav_data_out, 1, block_size, output_ptr);
	output_file_pos += block_size;
	output_pos -= block_size;

	for(i=0; i<wav_buffer_size-block_size; i++)
		wav_process[i] = wav_process[i+block_size];
	for(i=wav_buffer_size-block_size; i<wav_buffer_size; i++)
		wav_process[i] = 0;



} /* End of main loop */

/* Write remaining contents of buffer to WAV file */

block_size = (int)(output_data_size)-output_file_pos;



for(i=0; i<block_size; i++){
	temp = integrator + wav_process[i]; 	/* Output of first LF correction stage */
	integrator = 0.98 * integrator + int_coef * wav_process[i];
	temp1 = integrator2 + temp;
	integrator2 = 0.98 * integrator2 + int_coef2 * temp;
	c_apf = c_apf * apf_coef + temp1 * (1.0 - apf_coef);
	temp = wav_amp * (2 * c_apf - temp1);	/* Output of all-pass filter */
	c_apf = c_apf * apf_coef + temp1 * (1.0 - apf_coef);
	if (temp > 127)
		wav_data_out[i] = (char)255;
	else if (temp < -128)
		wav_data_out[i] = (char)0;
	else
		wav_data_out[i] = (char)(temp+128);
	}

fwrite(wav_data_out, 1, block_size, output_ptr);

/* Append silence */
for(i=0; i<256; i++){
	wav_data_out[i] = (char)(wav_amp*(integrator+integrator2)+128);
	integrator2 = 0.98 * integrator2 + int_coef2 * integrator;
	integrator = 0.98 * integrator;
	}

fwrite(wav_data_out, 1, 256, output_ptr);

output_file_pos += block_size+256;
printf("%d samples written\n", output_file_pos);
printf("RDP at end = %d\n", rdp_debug);



/* Free memory allocations */
free(wav_data_out);
free(wav_process);
free(wsinc);

fclose(output_ptr);
fclose(input_ptr);



return(0);
} /* End of main function */






FILE* write_wav_head(char *filename, FormatChunk *fmt_chunk, unsigned long data_size){

FILE* ptr;
char ID[5]="RIFF";
unsigned long file_length;
long fmt_chunksize=16;

if ((ptr=fopen(filename, "wb"))==NULL){	/* Open file and test if successful */
	printf("File %s could not be opened.\n", filename);
	return(ptr);
}
file_length=data_size+36;
if (fwrite(ID, 1, 4, ptr)+fwrite(&file_length, 4, 1, ptr)!=5){
	puts("File write error");
	return(NULL);
}
strcpy(ID, "WAVE");
if (fwrite(ID, 1, 4, ptr)!=4){
	puts("File write error");
	return(NULL);
}
strcpy(ID, "fmt ");
if (fwrite(ID, 1, 4, ptr)+fwrite(&fmt_chunksize, 4, 1, ptr)+fwrite(fmt_chunk, 16, 1, ptr)!=6){
	puts("File write error");
	return(NULL);
}
strcpy(ID, "data");
if (fwrite(ID, 1, 4, ptr)+fwrite(&data_size, 4, 1, ptr)!=5){
	puts("File write error");
	return(NULL);
}
return(ptr);
}



float bessel(float x){
	float v=1;
	float t=1;
	int i;
	for(i=1; i<20; i++){
		t *= i;
		v += pow(x*x/4, i)/(t*t);
	}
	return v;
}


/* 8B10B Encoding function */
/* Encoding table implemented as per Wikipedia 8b/10b page. Output placed in bits 9:0 of output word, to be transmitted MSB first. */
/* Running Disparity bit is placed in bit 10 of output word. This needs to be passed to the rdp input for the subsequent call of the function. */

short int enc8b10b(char input_byte, char rdp){
	unsigned char sub_word;
	short int output_word;
	char da7; /* Flag to indicate potential use of D.x.A.7 in 3b4b code */
	
	da7 = 0;
	sub_word = input_byte&31;
	switch(sub_word){
		case 0: output_word = rdp ? 0x18 : 0x27; rdp = 1-rdp; break;
		case 1: output_word = rdp ? 0x22 : 0x1D; rdp = 1-rdp; break;
		case 2: output_word = rdp ? 0x12 : 0x2D; rdp = 1-rdp; break;
		case 3: output_word = 0x31; break;
		case 4: output_word = rdp ? 0x0A : 0x35; rdp = 1-rdp; break;
		case 5: output_word = 0x29; break;
		case 6: output_word = 0x19; break;
		case 7: output_word = rdp ? 0x07 : 0x38; break;
		case 8: output_word = rdp ? 0x06 : 0x39; rdp = 1-rdp; break;
		case 9: output_word = 0x25; break;
		case 10: output_word = 0x15; break;
		case 11: output_word = 0x34; da7 = rdp; break;
		case 12: output_word = 0x0D; break;
		case 13: output_word = 0x2C; da7 = rdp; break;
		case 14: output_word = 0x1C; da7 = rdp; break;
		case 15: output_word = rdp ? 0x28 : 0x17; rdp = 1-rdp; break;
		case 16: output_word = rdp ? 0x24 : 0x1B; rdp = 1-rdp; break;
		case 17: output_word = 0x23; da7 = 1-rdp; break;
		case 18: output_word = 0x13; da7 = 1-rdp; break;
		case 19: output_word = 0x32; break;
		case 20: output_word = 0x0B; da7 = 1-rdp; break;
		case 21: output_word = 0x2A; break;
		case 22: output_word = 0x1A; break;
		case 23: output_word = rdp ? 0x05 : 0x3A; rdp = 1-rdp; break;
		case 24: output_word = rdp ? 0x0C : 0x33; rdp = 1-rdp; break;
		case 25: output_word = 0x26; break;
		case 26: output_word = 0x16; break;
		case 27: output_word = rdp ? 0x09 : 0x36; rdp = 1-rdp; break;
		case 28: output_word = 0x0E; break;
		case 29: output_word = rdp ? 0x11 : 0x2E; rdp = 1-rdp; break;
		case 30: output_word = rdp ? 0x21 : 0x1E; rdp = 1-rdp; break;
		case 31: output_word = rdp ? 0x14 : 0x2B; rdp = 1-rdp; break;
	}

	output_word <<= 4;

	sub_word = (input_byte&224)>>5;
	switch(sub_word){
		case 0: output_word |= rdp ? 0x4 : 0xB; rdp = 1-rdp; break;
		case 1: output_word |= 0x9; break;
		case 2: output_word |= 0x5; break;
		case 3: output_word |= rdp ? 0x3 : 0xC; break;
		case 4: output_word |= rdp ? 0x2 : 0xD; rdp = 1-rdp; break;
		case 5: output_word |= 0xA; break;
		case 6: output_word |= 0x6; break;
		case 7: {
			if(da7) output_word |= rdp ? 0x8 : 0x7;
			else output_word |= rdp ? 0x1 : 0xE;
			rdp = 1-rdp;
		}; break;
	}
	
	if(rdp) output_word |= 0x0400;

	return(output_word);
	
}

