; DeciLoad 8.1kbaud Loader v1.1
; (c) 2026 Jonah Nuttgens
; Unit Interval = 432 T-states
; Baud rate = 8102baud at 3.5MHz

; Assembled length = 246 bytes

; Note use of undocumented Z80 opcode ED 70 at "detedge".
; This is coded as either "in (c)" or "in f,(c)" depending on the assembler.
; Undocumented instruction "sll" is also used.

	org 65288
; Enter with HL = load start address, IX = byte count (excluding checksum), interrupts disabled.
decld8	ld iy,lutbase	;Base address of the 3b/4b decode LUT. 5b/6b LUT is offset by -32 bytes, with the first and last 5 entries unused.
	xor a		;Initialise checksum to zero
	ld c,a		;C = polarity (00 or FF), B = status / pilot counter, starting from $FE
	ex af,af'
	exx
	ld bc,$FFFE	;IN port address = $FFFE
	ld hl,retpepo	;Address of self-modifying opcode
	exx
	ld (iy+(eborder-lutbase)),$1D	;Initialise "eborder" opcode to "dec e"
	call nopilot	;Jump in to the "nopilot" routine, saving the "return" address as the "edgedet" routine.

;This section is reached if we detect an edge (change of EAR signal state) during the tape input polling loop, which triggers the condition RET instruction, either RET PE or RET PO.
edgedet	dec sp		;Edge detected
	dec sp		;Decrement Stack Pointer so the return address can be reused next time
	xor e		;Flip A between $E0 and $E8, opcodes for ret po and ret pe respectively
	ld (hl),a	;Update opcode at address HL
	sll e		;Shift E left and add 1
runout	inc e
eborder	nop		;This instruction initialised at "dec e" - modified at runtime to "nop" to start modifying the border colour.
	dec d
	jr nz,runout	;24T loop to count down the remaining value of D
	srl e		;Restore bit 3, halving the count value

;This section is reached at the end of each UI.
noedge	ret m		;5T padding
endui	exx
	cp $E8		;Test whether A (holding the conditional RET opcode) is $E0 or $E8, setting the Carry flag accordingly
	rl e		;Shift the received bit into DE'
	rl d
	jr c,process	;If a 1 pops out the other end of the shift register, then we have captured a complete data word. Go and process it.
	exx
	out (c),e	;Update border colour. This will be black (E=$08) if no edge was detected, else the colour indicates the relative timing of the edge.
	ld de,$0B08	;Reset polling loop counter D and default OUT data value E
	jp detedge	;Start next Unit Interval.

;TIMINGS:
;Define n = initial value of polling loop counter; m = value of polling loop counter when an edge was detected...
;
;From "endui" to first "detedge" = 70T
;
;If no edge is detected:
;From first execution of "detedge" to "endui" (including the 5T RET NZ padding) = (32n+10)T
;Total loop time = 1UI = (32n+80)T
;
;If an edge is detected:
;From first execution of "detedge" to "edgedet" = (32(n-m)+27)T
;From "edgedet" to "endui" = (24m+39)T
;Total from first execution of "detedge" to "endui" = (32n-8m+66)T
;Total loop time = (32n-8m+136)T, which equals 1UI when m=7.

;Theoretical "perfect" edge timing is midway between IN samples for D=8 and D=7. Time from first "detedge" to this point is 32(n-7.5) = 112T
;Centre of eye is 0.5UI either side of this = 216T away = -104T from first "detedge".

;Time from "endui" to "process" = 39T


;Now the LUT, starting from index 5 for the 5b/6b decodes (since values 0-4 are unused)
;The 3b/4b decoding table overlaps with a 32-byte offset
;Bits 7:5 are the 3b/4b decode values, inverted; bits 4:0 are the 5b/6b decode values.
;Special values: $E0 = error (all 0's or all 1's in the 4b data), and $3C = K28 (for possible future use).
	defb $17,$08,$07
	defb $00,$1B,$04,$14,$18,$0C,$1C,$3C
	defb $00,$1D,$02,$12,$1F,$0A,$1A,$0F
	defb $00,$06,$16,$10,$0E,$01,$1E,$00
lutbase	defb $E0,$1E,$61,$91,$F0,$A9,$39,$00
	defb $0F,$C5,$55,$FF,$8D,$62,$1D,$E0
	defb $3C,$03,$13,$18,$0B,$04,$1B,$00
	defb $07,$08,$17


;Next section deals with interpreting / decoding a string of bits captured from tape
process	ld a,e		;Invert contents of E first. D will be dealt with later if necessary.
	xor c
	inc b		;test B. If FF, then we are in the data segment. If 0 then we are waiting for sync. Else pilot tone.
	jp z,decode
	djnz pilot
sync	cp $35		;Test for sync byte
	jr z,datago	;Found sync byte - now start reading data
	cp $CA		;Test for pilot byte
	jr nz,nopilot	;Neither sync nor pilot byte received. Reset pilot counter.
nextpil	ld d,2		;Pilot byte matches - capture next 8 bits
	ld a,18
	jr jrpad	;Effectively this extra jump adds 12T
pilot	dec b
	cp $CA		;Test received byte against pilot pattern $CA
	jr z,nextpil
	dec de		;6T padding. Safe to corrupt DE at this point
nopilot	ld b,$FE	;Reset pilot counter
	xor a
	cpl		;A=$FF
	xor c		;Invert polarity for next pilot byte search
	ld c,a
	add a,2
	ld d,a		;Next word captured is either 8 bits or 9 bits long, depending on polarity setting
	ld a,17
jrpad	jr decpad
datago	xor a
	ld (eborder),a	;Change "eborder" instruction to "nop", to start showing border colours
	ld a,18
	djnz datago2	;Revert B to $FF. Jump is always taken.

;Time from "process" to "decode" = 22T
;Therefore time from "endui" to "decode" = 61T
;Time from "process" to "sample1" (through all possible branches) = 383T
;(additional 4T via "sync" and "nopilot", but this is a rare error condition so it shouldn't matter.)


;Main tape input polling loop, with repetition rate of 32T. It is placed here to put it within reach of relative jumps in and out of the routine.
retpepo	ret po		;This will be modified at runtime, alternating between ret po and ret pe
	dec d
	jr z,noedge	;If D reaches zero during this loop, then it means no data edge was detected in this Unit Interval.
detedge	in (c)		;Loop entry point.
	jp (hl)		;Loop back to retpepo


;Now the 8b/10b decoding routine. Will need to reset B to FF at end.
decode	and $0F		;Decode the 3b/4b section first
	ld (fetch3b+2),a	;Set the LUT address for the 3b decode
	ld a,e
	sra d		;Shift the LSB of D into carry
	rra		;and onwards into the MSB of A
	sra d		;D should now contain $E0
	rra		;A now contains the 6b code in the upper 6 bits
	xor c		;Apply polarity inversion. This instruction also clears the carry flag,
	rra		;so RRA will put a zero in bit7
	srl a		;but for the final shift we need to use the (slower) SRL instruction to fill bit 7 with a zero
	add a,d		;Adding $E0 is equivalent to subtracting 32, to offset the base address for the 5b/6b LUT
	ld (fetch5b+2),a	;Set the LUT address for the 5b decode
fetch3b	ld a,(iy+0)	;Fetch 3b/4b LUT decode result
	cp d		;Test for error, indicated by LUT byte value = $E0
	jr z,error
	and d		;D=$E0. Set the lower 5 bits to zero, keeping only the 3b decode result in the 3 top bits
	ld e,a		;Store intermediate result
fetch5b	ld a,(iy+0)	;Fetch 5b/6b LUT decode result
	;Possible future upgrade here by adding cp $3C / jr z,nn to test for K28 control codes.
	or d		;D=$E0. Set the upper 3 bits to one, keeping only the 5b decode result in the lower 5 bits
	xor e		;Combine 3b and 5b results. The 3b value will end up inverted from the LUT contents.
	ld d,a		;Final decode result
	ex af,af'
	add a,d		;Update checksum
	ex af,af'
	ld a,ixl
	or ixh		;Test whether IX=0, and if so, then this was the final checksum byte
	jr z,exit
	dec ix		;Else, decrement byte counter IX
	dec b		;Revert B to $FF
	ld a,8		;Set delay time for padding loop
	ld (hl),d	;Finally, write the decoded byte to memory
	inc hl		;and increment write address ready for next byte.
	ret z		;5T padding. Zero flag will have been cleared by previous dec b instruction.
datago2	ld de,$0060	;Prepare to capture 10 bits
decpad	dec a
	jr nz,decpad	;16T delay loop. Delay = (16a-5)T

;Timing:
;Time from "process" to "decode" = 22T
;Time from "decode" to "datago2" = 224T
;Time from "datago2" to "sample1" = 137T
;Time from "process" to "sample1" = 383T
;Time from "decode" to "sample1" = 361T
;Total time from "endui" to "detedge" via decode = 61+361+80 = 502T
;Compared to "endui" to "detedge" directly, which takes 70T, route via decode is 432T longer, which equals 1UI

;Capture first bit of next data word. Note that E is shifted left in this process, but D is not.
bit1	exx
sample1	in a,(c)	;80T from here to "detedge"
	ld de,$0B08
	add a,e		;A is expected to be either $FF or $BF. This is a quick method of setting or clearing the Carry flag accordingly.
	sbc a,a		;Set A to either $FF or $00, preserving Carry flag
	exx
	rl e		;Shift received bit into E. No need to shift D, since there is not yet any useful data to shift into it.
	exx
	and e
	xor $E8		;Construct RET PE / RET PO opcode
	ld (hl),a	;Place at "retpepo" address
	nop		;4T padding
	jr detedge

;Exit and return
exit	ex af,af'
;Arriving here via "error" jump skips the ex af,af' instruction, leaving A=$E0
error	pop hl		;Dummy pop to clear the call return address from the stack
	exx
	out (c),d	;Clear port FE, setting border black
	ret
